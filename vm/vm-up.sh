#!/usr/bin/env bash
# vm-up.sh: keep the agent VM and everything around it working, with no
# manual steps. Run by the io.mac-bootstrap.vm-up login agent (KeepAlive
# restarts it if it exits), or by hand with the `vm-up` zsh function.
#
# What it keeps true, and how:
#   VM           every 60 s: Running, or start it after a grace period; if the
#                instance is gone, rebuild it with `bootstrap.sh --only=vm`
#                (never a bare `limactl start`, which creates a default
#                instance that mounts your home folder).
#   browse relay every 60 s: Mac 127.0.0.1:19988 answers, else `browse serve`.
#   tunnel       `rex -S vm forward new -R 19988...` in the foreground; it
#                reconnects on its own, KeepAlive covers a hard exit.
#   heal         every 5 min: copy the API keys and the relay token into the
#                guest when they changed; run guest-heal.sh in the guest.
#   code bridge  the guest's `code` appends a folder to a request file; this
#                opens VS Code on the Mac at that folder over Remote-SSH. It
#                accepts one thing only: an absolute path, passed as one argv.
#
# Modes: (none) run everything; --heal one heal pass; --open-line PATH one
# bridge request. Test seams: VM_UP_ONCE=1, VM_UP_WAIT, VM_UP_BOOTSTRAP, REX_CLI.
set -u

VM="${AGENT_VM:-agent}"
PORT=19988
WAIT="${VM_UP_WAIT:-300}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="${VM_UP_BOOTSTRAP:-$HERE/../bootstrap.sh}"
BROWSE="$HOME/.local/bin/browse"
REX_CLI="${REX_CLI:-$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex}"
SSH_CFG="$HOME/.lima/$VM/ssh.config"
# launchd gives a bare PATH; Homebrew goes AFTER the caller's PATH so a
# caller's (or a test's) commands win.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"

log() { printf '%s vm-up: %s\n' "$(date '+%F %T')" "$*"; }

vm_status() { limactl list "$VM" --format '{{.Status}}' 2>/dev/null; }

# One step towards a running VM. Returns 0 when it is Running.
VM_DOWN_SINCE=""
vm_step() {
  local s now
  s="$(vm_status)"
  [[ "$s" == "Running" ]] && { VM_DOWN_SINCE=""; return 0; }
  if [[ -z "$s" ]]; then
    log "instance $VM is missing; rebuilding it with the vm phase"
    "$BOOTSTRAP" --only=vm || log "vm phase failed"
    return 1
  fi
  now="$(date +%s)"
  [[ -n "$VM_DOWN_SINCE" ]] || VM_DOWN_SINCE="$now"
  if (( now - VM_DOWN_SINCE >= WAIT )); then
    log "$VM is $s after $((now - VM_DOWN_SINCE))s; starting it"
    limactl start "$VM" --tty=false --timeout 10m || log "limactl start failed"
    VM_DOWN_SINCE=""
  fi
  return 1
}

ensure_vm() {
  until vm_step; do
    [[ -n "${VM_UP_ONCE:-}" ]] && return 0
    sleep 10
  done
}

relay_up() { curl -fsS -m 3 "http://127.0.0.1:$PORT/version" >/dev/null 2>&1; }

ensure_relay() {
  relay_up && return 0
  if [[ -x "$BROWSE" ]]; then
    log "browse relay down; starting it"
    nohup "$BROWSE" serve >/dev/null 2>&1 &
  fi
}

# sync_file SRC DEST: copy SRC to the guest's DEST (relative to its home)
# with mode 600, only when the content differs.
sync_file() {
  local src="$1" dest="$2" mine theirs
  [[ -f "$src" ]] || return 0
  mine="$(shasum -a 256 "$src" | cut -d' ' -f1)"
  # shellcheck disable=SC2016  # expanded by the guest's bash.
  theirs="$(limactl shell "$VM" -- bash -c 'sha256sum "$HOME/$1" 2>/dev/null | cut -d" " -f1' _ "$dest" 2>/dev/null)"
  [[ "$mine" == "$theirs" ]] && return 0
  # shellcheck disable=SC2016
  limactl shell "$VM" -- bash -c 'mkdir -p "$HOME/$(dirname "$1")" && chmod 700 "$HOME/$(dirname "$1")"' _ "$dest" >/dev/null 2>&1
  if limactl copy "$src" "$VM:$dest"; then
    # shellcheck disable=SC2016
    limactl shell "$VM" -- bash -c 'chmod 600 "$HOME/$1"' _ "$dest" >/dev/null 2>&1
    log "synced $dest into $VM"
  fi
}

heal() {
  [[ "$(vm_status)" == "Running" ]] || return 0
  sync_file "$HOME/.config/zsh/.api-keys.zsh" ".config/zsh/.api-keys.zsh"
  sync_file "$HOME/.local/share/browse/relay-token" ".local/share/browse/relay-token"
  limactl shell "$VM" -- bash -s < "$HERE/guest-heal.sh" || log "guest heal failed"
}

# open_line PATH: the one thing the guest may ask the Mac to do.
open_line() {
  local p="$1" enc
  if [[ "$p" != /* || "$p" == *[[:cntrl:]]* || ${#p} -gt 1024 ]]; then
    log "refused code request: ${p:0:80}"
    return 1
  fi
  enc="$(jq -rn --arg p "$p" '$p | @uri' | sed 's|%2F|/|g')"
  code --folder-uri "vscode-remote://ssh-remote+lima-$VM$enc"
}

open_bridge() {
  local line
  while :; do
    if [[ "$(vm_status)" == "Running" && -f "$SSH_CFG" ]]; then
      while IFS= read -r line; do
        open_line "$line" || true
      done < <(ssh -F "$SSH_CFG" "lima-$VM" 'tail -n0 -F "$HOME/.local/state/vm-open/requests"' 2>/dev/null)
    fi
    sleep 10
  done
}

watch_loop() {
  local tick=0
  while :; do
    vm_step >/dev/null || true
    ensure_relay
    (( tick % 5 == 0 )) && heal
    tick=$((tick + 1))
    sleep 60
  done
}

case "${1:-}" in
  --heal) heal; exit 0 ;;
  --open-line) open_line "${2:-}"; exit $? ;;
esac

ensure_vm
if [[ -n "${VM_UP_ONCE:-}" ]]; then
  [[ "$(vm_status)" == "Running" ]] || exit 0
  ensure_relay
  "$REX_CLI" -S vm forward new -R "127.0.0.1:$PORT:127.0.0.1:$PORT"
  exit 0
fi

watch_loop &
open_bridge &
trap 'kill $(jobs -p) 2>/dev/null' EXIT
log "tunnel: vm 127.0.0.1:$PORT -> Mac 127.0.0.1:$PORT"
"$REX_CLI" -S vm forward new -R "127.0.0.1:$PORT:127.0.0.1:$PORT"
log "forward exited ($?)"
