#!/usr/bin/env bash
# vm-backup.sh — one full, encrypted, off-Mac copy of the Lima agent VM.
# Run by hand from `den vm backup` / `den vm restore`; nothing schedules it.
#
# Backup: freeze the guest's root filesystem for the ~0.1 s a copy-on-write
# clone of the disk needs (no VM stop), clone disk, vz-efi, vz-identifier and
# lima.yaml into a fixed stage dir, thaw, then `restic backup` the stage into a
# repo inside the OneDrive folder. It keeps one copy: forget+prune runs only
# after the new snapshot succeeded, so a failed run never drops the old copy.
# Restore: put the latest copy back into an empty $LIMA_HOME/$AGENT_VM.
#
# The repo password is vm.backup_password in the den bundle: den loads it and
# hands the file over in DEN_SECRETS_FILE. The script never creates the repo:
# `den up --only=vm-backup` does.
#
# Modes: (none) backup; --restore restore. Anything else: usage, exit 2.
# Test seams: DEN_SECRETS_FILE, AGENT_VM, LIMA_HOME, VM_BACKUP_REPO, VM_BACKUP_STATE,
#             VM_BACKUP_CLONE, VM_BACKUP_KEEP, VM_BACKUP_FREEZE_MAX.
set -u

VM="${AGENT_VM:-agent}"
LIMA_HOME="${LIMA_HOME:-$HOME/.lima}"
STATE="${VM_BACKUP_STATE:-$HOME/.local/state/den/vm-backup}"
CLONE="${VM_BACKUP_CLONE:-cp -c}"
KEEP="${VM_BACKUP_KEEP:-1}"
# The guest thaws itself after this many seconds if the Mac side goes away.
FREEZE_MAX="${VM_BACKUP_FREEZE_MAX:-10}"
REPO="${VM_BACKUP_REPO:-}"
STAGE="$STATE/stage/$VM"
LOCK="$STATE/lock"
# launchd gives a bare PATH; the caller's (or a test's) commands win.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

HAVE_LOCK=0
JOB=""
TMP_RESTORE=""

log() { printf '%s vm-backup: %s\n' "$(date '+%F %T')" "$*"; }
die() {
  log "$*" >&2
  exit 1
}

bounded() { # bounded SECONDS CMD...
  local secs=$1
  shift
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  else
    "$@"
  fi
}

cleanup() {
  # A live freeze job here means we left early: give the guest its thaw line.
  if [ -n "$JOB" ] && kill -0 "$JOB" 2>/dev/null; then
    { printf 'thaw\n' >&3; } 2>/dev/null || true
    { exec 3>&-; } 2>/dev/null || true
    sleep 1
    kill "$JOB" 2>/dev/null || true
  fi
  if [ -n "$TMP_RESTORE" ]; then
    rm -rf "$TMP_RESTORE" 2>/dev/null || true
  fi
  # Only the lock holder owns the stage: a skipped second run must not wipe it.
  if [ "$HAVE_LOCK" = 1 ]; then
    rm -f "$STATE/freeze.fifo" "$STATE/freeze.out" 2>/dev/null || true
    rm -rf "$STAGE" "$LOCK" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

usage() { printf 'usage: vm-backup.sh [--restore]\n' >&2; }

# ── Lock ─────────────────────────────────────────────────────────────
acquire_lock() {
  local pid=""
  if ! mkdir "$LOCK" 2>/dev/null; then
    pid=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [ -z "$pid" ]; then
      # The owner may sit between mkdir and writing its pid.
      sleep 1
      pid=$(cat "$LOCK/pid" 2>/dev/null || true)
    fi
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log "already running (pid $pid); skipping"
      exit 0
    fi
    log "taking over a stale lock (pid ${pid:-unknown})"
    rm -rf "$LOCK"
    if ! mkdir "$LOCK" 2>/dev/null; then
      log "already running (lost the race for the lock); skipping"
      exit 0
    fi
  fi
  printf '%s\n' "$$" >"$LOCK/pid"
  HAVE_LOCK=1
}

# ── Repo and password ────────────────────────────────────────────────
# Fail before the VM is touched: a freeze with nowhere to send the copy is
# pure risk.
prepare_repo() {
  local pw="" d
  if [ -z "$REPO" ]; then
    for d in "$HOME"/Library/CloudStorage/OneDrive-*; do
      if [ -d "$d" ]; then
        REPO="$d/den-vm-backup"
        break
      fi
    done
  fi
  if [ -z "$REPO" ]; then
    die "no OneDrive folder and no VM_BACKUP_REPO; set it, then run: den up --only=vm-backup"
  fi
  export RESTIC_REPOSITORY="$REPO"
  unset RESTIC_PASSWORD RESTIC_PASSWORD_FILE
  if [ -z "${DEN_SECRETS_FILE:-}" ] || [ ! -r "$DEN_SECRETS_FILE" ] || ! command -v jq >/dev/null 2>&1; then
    die "no den bundle: vm.backup_password is missing; run: den vm backup (den loads the bundle itself)"
  fi
  pw=$(jq -r '.vm.backup_password // empty' "$DEN_SECRETS_FILE" 2>/dev/null) || pw=""
  if [ -z "$pw" ]; then
    die "the den bundle has no vm.backup_password; add it (openssl rand -base64 32), then run: den vm backup"
  fi
  pw=""
  # restic runs this command without a shell and reads the password from its
  # stdout: only the bundle's path rides argv, never the password.
  case $DEN_SECRETS_FILE in
    *[[:space:]\'\"]*) die "the den bundle path has a space or quote in it: $DEN_SECRETS_FILE" ;;
  esac
  export RESTIC_PASSWORD_COMMAND="jq -r .vm.backup_password $DEN_SECRETS_FILE"
  if [ ! -f "$REPO/config" ]; then
    die "no restic repo at $REPO; run: den up --only=vm-backup"
  fi
  if ! command -v restic >/dev/null 2>&1; then
    die "restic is not installed; run: brew install restic"
  fi
}

# ── Backup ───────────────────────────────────────────────────────────
vm_status() {
  local s=""
  s=$(bounded 15 limactl list "$VM" --format '{{.Status}}' 2>/dev/null | tr -d '\r' | head -n 1) || s=""
  printf '%s' "${s:-}"
}

# The guest runs as the user first: sudo's secure_path drops Homebrew's sbin,
# so fsfreeze is resolved before sudo and handed in as an argument.
# shellcheck disable=SC2016  # both scripts run in the guest.
GUEST_OUTER='PATH="$PATH:/home/linuxbrew/.linuxbrew/sbin:/usr/sbin:/sbin"
fz=$(command -v fsfreeze) || { echo freezefail; exit 1; }
exec sudo -n bash -c "$1" _ "$fz" "$2"'
# shellcheck disable=SC2016
GUEST_INNER='fz=$1; max=$2
sync
"$fz" -f / || { echo freezefail; exit 1; }
echo frozen
read -r -t "$max" _
"$fz" -u / || { echo thawfail; exit 1; }
echo thawed'

# Instance files that make a restorable VM. disk is required.
stage_files() {
  local f
  for f in disk vz-efi vz-identifier lima.yaml; do
    if [ -e "$LIMA_HOME/$VM/$f" ]; then
      printf '%s\n' "$f"
    fi
  done
}

clone_all() {
  local f rc=0
  while IFS= read -r f; do
    # shellcheck disable=SC2086  # CLONE is a command line, not one path.
    if ! $CLONE "$LIMA_HOME/$VM/$f" "$STAGE/$f"; then
      log "ERROR: clone of $f failed"
      rc=1
    fi
  done < <(stage_files)
  return "$rc"
}

# One freeze, the clone, one thaw. The thaw line is written even when a clone
# fails: a frozen guest hangs every write.
freeze_clone() {
  local fifo="$STATE/freeze.fifo" out="$STATE/freeze.out" i seen=0 rc=0 torn=0
  rm -f "$fifo"
  mkfifo "$fifo" || return 1
  : >"$out"
  limactl shell "$VM" -- bash -c "$GUEST_OUTER" _ "$GUEST_INNER" "$FREEZE_MAX" <"$fifo" >"$out" 2>&1 &
  JOB=$!
  exec 3>"$fifo"

  for ((i = 0; i < 300; i++)); do
    if tr -d '\r' <"$out" | grep -qx frozen; then
      seen=1
      break
    fi
    if tr -d '\r' <"$out" | grep -qx freezefail; then
      break
    fi
    if ! kill -0 "$JOB" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if [ "$seen" = 0 ]; then
    log "ERROR: the guest did not freeze (no clone, no snapshot): $(tr -d '\r' <"$out" | tail -n 3 | tr '\n' ' ')"
    exec 3>&-
    kill "$JOB" 2>/dev/null || true
    wait "$JOB" 2>/dev/null || true
    JOB=""
    return 1
  fi

  sync
  clone_all || rc=1
  # A guest that thawed on its own timer before we finished may have written
  # under the clone: the copy is not point-in-time.
  if tr -d '\r' <"$out" | grep -qx thawed; then
    log "ERROR: the guest thawed itself before the clone finished; the copy is not consistent"
    torn=1
  fi
  { printf 'thaw\n' >&3; } 2>/dev/null || log "ERROR: could not send the thaw line"
  exec 3>&-

  for ((i = 0; i < 200; i++)); do
    kill -0 "$JOB" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$JOB" 2>/dev/null; then
    kill "$JOB" 2>/dev/null || true
  fi
  wait "$JOB" 2>/dev/null || true
  JOB=""
  if ! tr -d '\r' <"$out" | grep -qx thawed; then
    log "ERROR: the guest did not report thawed; it thaws itself within ${FREEZE_MAX}s, check: limactl shell $VM -- sudo fsfreeze -u /"
  fi
  rm -f "$fifo" "$out"
  [ "$rc" = 0 ] && [ "$torn" = 0 ]
}

backup() {
  local s
  acquire_lock
  prepare_repo
  if ! command -v limactl >/dev/null 2>&1; then
    die "limactl is not installed (brew install lima)"
  fi
  if [ ! -d "$LIMA_HOME/$VM" ]; then
    die "no instance $VM in $LIMA_HOME; nothing to back up"
  fi
  if [ ! -e "$LIMA_HOME/$VM/disk" ]; then
    die "$LIMA_HOME/$VM/disk is missing; nothing to back up"
  fi
  s=$(vm_status)
  rm -rf "$STAGE"
  mkdir -p "$STAGE" || die "cannot create $STAGE"
  case $s in
    Running)
      log "$VM is Running: freezing the guest for the clone"
      freeze_clone || die "clone under freeze failed; no snapshot made"
      ;;
    Stopped)
      log "$VM is Stopped: cloning without a freeze"
      clone_all || die "clone failed; no snapshot made"
      if [ "$(vm_status)" != Stopped ]; then
        die "$VM started during the clone; the copy is not consistent, no snapshot made"
      fi
      ;;
    *)
      die "cannot read the status of $VM (got '${s:-nothing}'); no backup this time"
      ;;
  esac

  log "restic backup of $STAGE"
  restic backup --tag den-vm --host den "$STAGE" || die "restic backup failed"
  restic forget --tag den-vm --keep-last "$KEEP" --prune || die "restic forget failed"
  date -u '+%Y-%m-%dT%H:%M:%SZ' >"$STATE/last-ok"
  log "backup done"
}

# ── Restore ──────────────────────────────────────────────────────────
restore() {
  local src
  if [ -e "$LIMA_HOME/$VM" ]; then
    die "$LIMA_HOME/$VM exists; restore only fills an empty Lima home. Remove it first: den vm down; rm -rf $LIMA_HOME/$VM"
  fi
  prepare_repo
  TMP_RESTORE=$(mktemp -d "$STATE/restore.XXXXXX") || die "cannot create a restore dir in $STATE"
  log "restoring the latest copy from $REPO"
  # restic 0.16 has no snapshot:subpath on restore; restore it all and find
  # the stage dir (restic keeps the original absolute path under the target).
  restic restore latest --tag den-vm --sparse --target "$TMP_RESTORE" || die "restic restore failed"
  src=$(find "$TMP_RESTORE" -type d -path "*/stage/$VM" | head -n 1)
  if [ -z "$src" ] || [ ! -e "$src/disk" ]; then
    die "the restored copy has no $VM/disk"
  fi
  mkdir -p "$LIMA_HOME" || die "cannot create $LIMA_HOME"
  mv "$src" "$LIMA_HOME/$VM" || die "cannot move the copy into $LIMA_HOME/$VM"
  log "restored $LIMA_HOME/$VM; next: limactl start $VM"
}

# ── Entry ────────────────────────────────────────────────────────────
if [ $# -gt 1 ]; then
  usage
  exit 2
fi
mkdir -p "$STATE" 2>/dev/null || true
case "${1:-}" in
  '') backup ;;
  --restore) restore ;;
  *)
    usage
    exit 2
    ;;
esac
