#!/usr/bin/env bash
# vm-up.sh — keep the agent VM and everything around it working, with no
# manual steps. Run by the io.mac-bootstrap.vm-up login agent (KeepAlive
# restarts it on exit), or by hand from `den vm`.
#
# What it keeps true:
#   VM           Running; a stopped VM is started at most once per backoff
#                window (10s, 1m, 10m, 1h), a missing instance is rebuilt with
#                the vm phase at most once an hour. Never a bare
#                `limactl start` on a missing instance: Lima would create a
#                default VM with the home folder mounted.
#   browse relay 127.0.0.1:19988 answers on the Mac, else `browse serve` (PID
#                tracked, one try a minute).
#   tunnel       `rex -S vm forward new -R 19988...` in the foreground; every
#                minute the relay is probed inside the guest too, and the
#                script exits so launchd rebuilds a dead tunnel.
#   heal         every 5 min: copy the API keys and relay token when their
#                hash changed, then run guest-heal.sh in the guest.
#   code bridge  the guest appends an absolute path to a request file; this
#                opens VS Code on the Mac at that folder over Remote-SSH,
#                resuming at a persisted byte offset, one open per path per
#                10s, at most 5 a minute.
#
# State: $VM_UP_STATE_DIR (default ~/.local/state/rex-vm).
# Modes: (none) everything; --step one VM step; --heal one heal pass (its
# exit code); --open-line PATH one bridge request.
# Test seams: VM_UP_ONCE, VM_UP_WAIT, VM_UP_BOOTSTRAP, VM_UP_STATE_DIR, REX_CLI,
#             VM_UP_SESSION_TIMEOUT.
set -u

VM="${AGENT_VM:-agent}"
PORT=19988
WAIT="${VM_UP_WAIT:-300}"
TUNNEL="${DEN_BROWSE_TUNNEL:-1}"
BRIDGE_LIMIT=5
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEN_ROOT="$(cd "$HERE/.." && pwd)"
STATE="${VM_UP_STATE_DIR:-$HOME/.local/state/rex-vm}"
BOOTSTRAP="${VM_UP_BOOTSTRAP:-$DEN_ROOT/bin/den up}"
BROWSE="$HOME/.local/bin/browse"
REX_CLI="${REX_CLI:-$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex}"
SSH_CFG="$HOME/.lima/$VM/ssh.config"
# launchd gives a bare PATH; Homebrew goes AFTER the caller's PATH so a
# caller's (or a test's) commands win.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"

mkdir -p "$STATE" 2>/dev/null || true

log() { printf '%s vm-up: %s\n' "$(date '+%F %T')" "$*"; }

HAVE_PERL=0
if command -v perl >/dev/null 2>&1; then
  HAVE_PERL=1
fi

# Bound an external call with SIGALRM and kill its whole process group on
# timeout: a killed child can otherwise leave a descendant holding the
# caller's pipe open forever. Without perl, run it plainly.
to_run() { # to_run SECONDS CMD...
  local secs=${1:-30}
  if [ $# -gt 0 ]; then
    shift
  fi
  if [ "$HAVE_PERL" = 1 ]; then
    perl -e '
      my $secs = shift;
      my $pid = fork();
      exit 127 unless defined $pid;
      if ($pid == 0) { setpgrp(0, 0); exec @ARGV; exit 127; }
      $SIG{ALRM} = sub {
        kill "TERM", -$pid;
        $SIG{ALRM} = sub { kill "KILL", -$pid; exit 124 };
        alarm 2;
        waitpid($pid, 0);
        exit 124;
      };
      alarm $secs;
      waitpid($pid, 0);
      alarm 0;
      my $st = $?;
      exit(($st & 127) ? 128 + ($st & 127) : ($st >> 8));
    ' "$secs" "$@"
  else
    "$@"
  fi
}

state_get() {
  local v=""
  if [ -f "$STATE/$1" ]; then
    v=$(cat "$STATE/$1" 2>/dev/null) || v=""
  fi
  printf '%s' "$v"
}
state_set() { printf '%s' "${2:-}" >"$STATE/$1" 2>/dev/null || true; }

vm_status() {
  local s=""
  s=$(to_run 15 limactl list "$VM" --format '{{.Status}}' 2>/dev/null | tr -d '\r' | head -n 1) || s=""
  printf '%s' "${s:-}"
}

relay_up() { to_run 10 curl -fsS -m 3 "http://127.0.0.1:$PORT/version" >/dev/null 2>&1; }
guest_relay_up() {
  to_run 20 limactl shell "$VM" -- curl -fsS -m 3 "http://127.0.0.1:$PORT/version" >/dev/null 2>&1
}

next_backoff() {
  case ${1:-10} in
    10) printf 60 ;;
    60) printf 600 ;;
    600) printf 3600 ;;
    *) printf 3600 ;;
  esac
}

# ── VM ───────────────────────────────────────────────────────────────
bootstrap_vm() {
  if [ "$BOOTSTRAP" = "${BOOTSTRAP%% *}" ]; then
    to_run 3600 "$BOOTSTRAP" --only=vm
  else
    # shellcheck disable=SC2086  # BOOTSTRAP is a command line, not one path.
    to_run 3600 $BOOTSTRAP --only=vm
  fi
}

# One step towards a running VM. Returns 0 only when it is Running.
vm_step() {
  local s now next backoff shown
  if ! command -v limactl >/dev/null 2>&1; then
    shown=$(state_get last-status)
    if [ "$shown" != no-limactl ]; then
      log "limactl is not installed; cannot manage $VM (brew install lima)"
    fi
    state_set last-status no-limactl
    return 1
  fi
  s=$(vm_status)
  if [ "$s" = Running ]; then
    shown=$(state_get last-status)
    if [ "$shown" != Running ]; then
      log "VM $VM is Running"
    fi
    state_set last-status Running
    state_set down.next 0
    state_set down.backoff 10
    return 0
  fi

  if [ -z "$s" ]; then
    shown=$(state_get last-status)
    if [ "$shown" != missing ]; then
      log "instance $VM is missing"
    fi
    state_set last-status missing
    now=$(date +%s)
    next=$(state_get bootstrap.next)
    case ${next:-} in ''|*[!0-9]*) next=0 ;; esac
    if [ "$now" -lt "$next" ]; then
      shown=$(state_get bootstrap.logged)
      if [ "$shown" != "$next" ]; then
        log "rebuild of $VM backed off until the hour is up"
        state_set bootstrap.logged "$next"
      fi
      return 1
    fi
    state_set bootstrap.next "$((now + 3600))"
    log "rebuilding $VM with the vm phase"
    bootstrap_vm || log "the vm phase did not finish"
    return 1
  fi

  shown=$(state_get last-status)
  if [ "$shown" != "$s" ]; then
    log "VM $VM is $s"
  fi
  state_set last-status "$s"
  now=$(date +%s)
  next=$(state_get down.next)
  if [ -z "$next" ]; then
    next=$((now + WAIT))
    state_set down.backoff 10
  fi
  case $next in ''|*[!0-9]*) next=0 ;; esac
  if [ "$now" -lt "$next" ]; then
    return 1
  fi
  backoff=$(state_get down.backoff)
  case ${backoff:-} in ''|*[!0-9]*) backoff=10 ;; esac
  log "starting $VM (was $s); next try no sooner than ${backoff}s"
  state_set down.backoff "$(next_backoff "$backoff")"
  state_set down.next "$((now + backoff))"
  if to_run 660 limactl start "$VM" --tty=false --timeout 10m; then
    log "limactl start returned; waiting for the status to say Running"
  else
    log "limactl start failed; next try in ${backoff}s"
  fi
  return 1
}

ensure_vm() {
  until vm_step; do
    if [ -n "${VM_UP_ONCE:-}" ]; then
      return 0
    fi
    sleep 10
  done
}

# ── Relay ────────────────────────────────────────────────────────────
ensure_relay() {
  local pid now last
  relay_up && return 0
  pid=$(state_get browse.pid)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  now=$(date +%s)
  last=$(state_get browse.tried)
  case ${last:-} in ''|*[!0-9]*) last=0 ;; esac
  if [ "$((now - last))" -lt 60 ]; then
    return 1
  fi
  [ -x "$BROWSE" ] || return 1
  log "browse relay down; starting browse serve"
  nohup "$BROWSE" serve >>"$STATE/browse.log" 2>&1 &
  printf '%s' "$!" >"$STATE/browse.pid" 2>/dev/null || true
  state_set browse.tried "$now"
  return 0
}

# ── Heal ─────────────────────────────────────────────────────────────
hash_file() {
  local file=${1:-} out=""
  if command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1)
  elif command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)
  fi
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# sync_file SRC DEST: copy SRC to the guest's DEST (relative to its home)
# with mode 600, only when the content differs. An unreadable hash is a
# failure, not a "different content".
sync_file() {
  local src=$1 dest=$2 mine theirs
  [ -f "$src" ] || return 0
  mine=$(hash_file "$src") || {
    log "cannot hash $src; not syncing $dest"
    return 1
  }
  # shellcheck disable=SC2016  # expanded by the guest's bash.
  theirs=$(to_run 20 limactl shell "$VM" -- bash -c 'sha256sum "$HOME/$1" 2>/dev/null | cut -d" " -f1' _ "$dest" 2>/dev/null |
    tr -d '\r' | head -n 1) || theirs=""
  [ "$mine" = "$theirs" ] && return 0
  # shellcheck disable=SC2016
  to_run 20 limactl shell "$VM" -- bash -c 'mkdir -p "$HOME/$(dirname "$1")" && chmod 700 "$HOME/$(dirname "$1")"' _ "$dest" >/dev/null 2>&1 || true
  if to_run 60 limactl copy "$src" "$VM:$dest"; then
    # shellcheck disable=SC2016
    to_run 20 limactl shell "$VM" -- bash -c 'chmod 600 "$HOME/$1"' _ "$dest" >/dev/null 2>&1 || true
    log "synced $dest into $VM"
  else
    log "copy of $dest failed"
    return 1
  fi
}

heal() {
  local rc=0
  if [ "$(vm_status)" != Running ]; then
    log "heal skipped: $VM is not Running"
    return 0
  fi
  sync_file "$HOME/.config/zsh/.api-keys.zsh" ".config/zsh/.api-keys.zsh" || rc=1
  sync_file "$HOME/.local/share/browse/relay-token" ".local/share/browse/relay-token" || rc=1
  # 660s: the browse install inside the guest gets 600s of its own, so the
  # pass that carries it must outlast that bound.
  if ! to_run 660 limactl shell "$VM" -- bash -s <"$HERE/guest-heal.sh"; then
    log "guest heal failed"
    rc=1
  fi
  return "$rc"
}

# ── Code bridge ──────────────────────────────────────────────────────
recent_opens() {
  local now cutoff n=0 t
  now=$(date +%s)
  cutoff=$((now - 60))
  if [ ! -f "$STATE/open-line.log" ]; then
    printf 0
    return 0
  fi
  while IFS= read -r t; do
    case $t in ''|*[!0-9]*) continue ;; esac
    if [ "$t" -ge "$cutoff" ]; then
      n=$((n + 1))
    fi
  done <"$STATE/open-line.log"
  awk -v c="$cutoff" '$1 >= c' "$STATE/open-line.log" >"$STATE/open-line.log.tmp" 2>/dev/null &&
    mv "$STATE/open-line.log.tmp" "$STATE/open-line.log" 2>/dev/null || true
  printf '%s' "$n"
}

# open_line PATH: the one thing the guest may ask the Mac to do.
open_line() {
  local p=${1:-} enc="" now last last_t last_p
  if [ -z "$p" ]; then
    log "refused code request: empty path"
    return 1
  fi
  if [ "${p#/}" = "$p" ]; then
    log "refused code request: not an absolute path: ${p:0:80}"
    return 1
  fi
  if [ "${#p}" -gt 1024 ] || printf '%s' "$p" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    log "refused code request: ${p:0:80}"
    return 1
  fi
  now=$(date +%s)
  last=$(state_get open-line.last)
  case $last in
    *' '*)
      last_t=${last%% *}
      last_p=${last#* }
      ;;
    *) last_t=0 last_p="" ;;
  esac
  case ${last_t:-} in ''|*[!0-9]*) last_t=0 ;; esac
  if [ "$p" = "$last_p" ] && [ "$((now - last_t))" -le 10 ]; then
    log "rejected duplicate code request: ${p:0:80}"
    return 1
  fi
  if [ "$(recent_opens)" -ge "$BRIDGE_LIMIT" ]; then
    log "rejected code request over ${BRIDGE_LIMIT}/minute: ${p:0:80}"
    return 1
  fi
  if ! command -v code >/dev/null 2>&1; then
    log "refused code request: the code CLI is not on PATH"
    return 1
  fi
  state_set open-line.last "$now $p"
  printf '%s\n' "$now" >>"$STATE/open-line.log" 2>/dev/null || true
  enc=$(printf '%s' "$p" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/#/%23/g' -e 's/?/%3F/g')
  # </dev/null: code would otherwise inherit the request stream as stdin and
  # eat the requests behind this one. Backgrounded so a slow launch never
  # stalls the bridge; the caller waits for it.
  code --folder-uri "vscode-remote://ssh-remote+lima-$VM$enc" </dev/null >/dev/null 2>&1 &
  log "opened VS Code on $p"
}

open_bridge() {
  local off line size
  while :; do
    if [ "$(vm_status)" = Running ] && [ -f "$SSH_CFG" ]; then
      if [ ! -f "$STATE/bridge.offset" ]; then
        # First run: start at the end of the inbox, never replay old requests.
        # shellcheck disable=SC2016
        size=$(to_run 15 limactl shell "$VM" -- bash -c 'stat -c %s "$HOME/.local/state/vm-open/requests" 2>/dev/null || echo 0' 2>/dev/null |
          tr -d '\r' | head -n 1) || size=0
        case ${size:-} in ''|*[!0-9]*) size=0 ;; esac
        state_set bridge.offset "$size"
      fi
      off=$(state_get bridge.offset)
      case ${off:-} in ''|*[!0-9]*) off=0 ;; esac
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        open_line "$line" || true
        # wc -c counts bytes, so the offset survives a UTF-8 path.
        off=$((off + $(printf '%s' "$line" | wc -c | tr -d ' ') + 1))
        state_set bridge.offset "$off"
      done < <(ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=10 \
        -F "$SSH_CFG" "lima-$VM" "tail -c +$((off + 1)) -F \"\$HOME/.local/state/vm-open/requests\"" 2>/dev/null)
    fi
    sleep 10
  done
}

# ── Loops ────────────────────────────────────────────────────────────
watch_loop() {
  local tick=0
  while :; do
    vm_step || true
    if [ "$TUNNEL" = 1 ]; then
      ensure_relay || true
      # The relay answers on the Mac but not inside the guest: the tunnel is
      # gone. Exit, and launchd starts a fresh one. Only while the VM is
      # Running: a stopped VM fails the guest probe too, and exiting then
      # would have launchd churn the agent every pass.
      if [ "$tick" -ge 2 ] && [ "$(vm_status)" = Running ] && relay_up && ! guest_relay_up; then
        log "relay answers on the Mac but not in $VM; restarting for launchd"
        kill -TERM "$$" 2>/dev/null || true
        exit 1
      fi
    fi
    if [ "$((tick % 5))" -eq 0 ]; then
      heal || true
    fi
    tick=$((tick + 1))
    sleep 60
  done
}

# ── Entry ────────────────────────────────────────────────────────────
case "${1:-}" in
  --heal)
    heal
    exit $?
    ;;
  --step)
    vm_step
    exit $?
    ;;
  --open-line)
    open_line "${2:-}"
    rc=$?
    wait 2>/dev/null || true
    exit "$rc"
    ;;
  '')
    ;;
  *)
    printf 'vm-up.sh: unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

if ! command -v limactl >/dev/null 2>&1; then
  log "limactl is not installed; nothing to do (brew install lima)"
  exit 0
fi

# A forward lives as a block in a Rex session, and a fresh guest server has
# none ("session target default not found: no sessions"). Keep one named
# session for the tunnel, so it never depends on a tab being open.
TUNNEL_SESSION=den
SESSION_TIMEOUT="${VM_UP_SESSION_TIMEOUT:-30}"
# A Rex call that times out can leave a child holding the pipe it wrote to,
# and the reader would then wait for that child. Capture to a file instead.
tunnel_session() {
  local list="$STATE/tunnel-sessions"
  if to_run "$SESSION_TIMEOUT" "$REX_CLI" -S vm session ls >"$list" 2>/dev/null &&
    awk 'NR > 1 { print $1 }' "$list" | grep -qx "$TUNNEL_SESSION"; then
    return 0
  fi
  if to_run "$SESSION_TIMEOUT" "$REX_CLI" -S vm session new "$TUNNEL_SESSION" >/dev/null 2>&1; then
    log "tunnel: created the $TUNNEL_SESSION session in the VM Rex server"
    return 0
  fi
  log "tunnel: could not create the $TUNNEL_SESSION session in the VM Rex server"
  return 1
}

# A forward block from an earlier run keeps its listener in the guest, so every
# new `forward new` collides on the port, exits at once, and the relay looks
# down. Close the blocks no client owns before asking for a new one.
tunnel_reap() {
  local list="$STATE/tunnel-forwards"
  if to_run "$SESSION_TIMEOUT" "$REX_CLI" -S vm forward ls >"$list" 2>/dev/null &&
    awk '$1 == "orphaned"' "$list" | grep -q .; then
    if to_run "$SESSION_TIMEOUT" "$REX_CLI" -S vm forward close --orphaned >/dev/null 2>&1; then
      log "tunnel: closed an orphaned forward block from an earlier run"
    else
      log "tunnel: could not close the orphaned forward block"
    fi
  fi
}

ensure_vm
if [ -n "${VM_UP_ONCE:-}" ]; then
  if [ "$(vm_status)" != Running ]; then
    exit 0
  fi
  if [ "$TUNNEL" = 1 ]; then
    ensure_relay || true
    if [ -x "$REX_CLI" ]; then
      tunnel_session && tunnel_reap &&
        "$REX_CLI" -S vm forward new --session "$TUNNEL_SESSION" -R "127.0.0.1:$PORT:127.0.0.1:$PORT"
    else
      log "Rex CLI not found at $REX_CLI; the tunnel is not up"
    fi
  fi
  exit 0
fi

watch_loop &
open_bridge &
# shellcheck disable=SC2046  # one PID per word on purpose.
trap 'kill $(jobs -p) 2>/dev/null' EXIT
if [ "$TUNNEL" = 1 ]; then
  if [ ! -x "$REX_CLI" ]; then
    log "Rex CLI not found at $REX_CLI; exiting so launchd retries after Rex is installed"
    exit 1
  fi
  log "tunnel: vm 127.0.0.1:$PORT -> Mac 127.0.0.1:$PORT"
  if tunnel_session && tunnel_reap; then
    "$REX_CLI" -S vm forward new --session "$TUNNEL_SESSION" -R "127.0.0.1:$PORT:127.0.0.1:$PORT"
  fi
  log "forward exited"
else
  wait
fi
