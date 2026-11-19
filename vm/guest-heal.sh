#!/bin/bash
# guest-heal.sh: repairs inside the agent VM that need no Mac input.
# vm-up.sh pipes it in (`limactl shell agent -- bash -s`), so it runs even when
# the guest's clone of this repo is stale. Idempotent and quiet when healthy.
# Each repair says what it did; one failure never stops the next repair.
set -euo pipefail
say() { printf 'guest-heal: %s\n' "$*"; }

# Restarting systemd-logind drops every session in the guest, so it earns one
# only for its real fault (the daemon itself spinning) and only once per boot.
logind_pcpu() {
  ps -o pcpu= -C systemd-logind 2>/dev/null |
    awk '{ if ($1 + 0 > m) m = $1 + 0 } END { print m + 0 }'
}

logind_fault() { # logind_fault PCPU: 0 when logind burns 80% CPU or more
  awk -v c="${1:-0}" 'BEGIN { exit !(c >= 80) }'
}

logind_restart_once() { # restart logind for that fault, once per boot; 0 when it did
  local pcpu
  pcpu=$(logind_pcpu) || pcpu=0
  if ! logind_fault "$pcpu"; then
    say "systemd-logind is not spinning (${pcpu}% CPU); not restarting it"
    return 1
  fi
  if sudo -n test -e /run/den-logind-restarted 2>/dev/null; then
    say "systemd-logind was restarted earlier this boot; not restarting it again"
    return 1
  fi
  if ! sudo -n touch /run/den-logind-restarted 2>/dev/null; then
    say "cannot write /run/den-logind-restarted; not restarting systemd-logind"
    return 1
  fi
  say "systemd-logind is spinning at ${pcpu}% CPU; restarting it once this boot"
  sudo -n systemctl restart systemd-logind >/dev/null 2>&1 || say "could not restart systemd-logind"
  sudo -n systemctl start "user@$(id -u).service" >/dev/null 2>&1 || say "could not start user@$(id -u)"
  return 0
}

# A bash -s shell has neither brew nor mise on PATH.
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" || say "brew shellenv failed"
fi

# 1. Docker: the Rex server and dev containers need the daemon.
if command -v docker >/dev/null 2>&1; then
  docker info >/dev/null 2>&1 || sudo systemctl start docker >/dev/null 2>&1 || say "docker did not start"
  id -nG "${USER:-$(id -un)}" | grep -qw docker || say "docker group missing; the vm phase adds it, then restart the VM once"
else
  say "docker is not installed yet (den up --only=vm)"
fi

# 2. Rex server: the socket unit starts it on demand. First the user bus: a
#    `bash -s` over limactl shell may lack XDG_RUNTIME_DIR, and on a fresh VM's
#    first boot systemd-logind can spin and stop answering. Restarting it drops
#    every session, so logind_restart_once does it only for that fault, once a boot.
if command -v systemctl >/dev/null 2>&1; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    # Not the logind fault: starting the user manager is harmless (it drops
    # no sessions), so try that instead.
    logind_restart_once ||
      sudo -n systemctl start "user@$(id -u).service" >/dev/null 2>&1 ||
      say "could not start user@$(id -u)"
  fi
  systemctl --user is-active --quiet rex.socket ||
    systemctl --user start rex.socket >/dev/null 2>&1 || say "rex.socket did not start"
  # Only once the vault is set up (the unit exists); before that there is
  # nothing to heal.
  if [ -f "$HOME/.config/systemd/user/obsidian-sync.service" ]; then
    systemctl --user is-active --quiet obsidian-sync.service ||
      systemctl --user start obsidian-sync.service >/dev/null 2>&1 || say "obsidian-sync.service did not start"
  fi
fi

# 3. browse CLI: link the native binary of the current mise node. A node
#    upgrade moves it; a missing package means a fresh guest. The install gets
#    600s of its own and is marked before it starts, so a slow network costs
#    one attempt an hour instead of a kill (and a retry) every 5 minutes.
if command -v mise >/dev/null 2>&1; then
  if [ "$(uname -m)" = x86_64 ]; then arch=x64; else arch=arm64; fi
  root="$(mise exec -- npm root -g 2>/dev/null)" || root=""
  bin="$root/@opencode/browse/node_modules/@opencode/browse-linux-$arch/bin/browse"
  if [ -n "$root" ] && [ ! -x "$bin" ]; then
    stamp="$HOME/.local/state/den/browse-install.tried"
    now="$(date +%s)"
    tried="$(cat "$stamp" 2>/dev/null || true)"
    case ${tried:-} in ''|*[!0-9]*) tried=0 ;; esac
    if [ "$((now - tried))" -ge 3600 ]; then
      mkdir -p "${stamp%/*}" 2>/dev/null || true
      printf '%s\n' "$now" >"$stamp" 2>/dev/null || true
      if perl -e 'alarm shift; exec @ARGV' 600 mise exec -- npm install -g @opencode/browse >/dev/null 2>&1; then
        say "installed browse"
      else
        say "browse install failed"
      fi
    fi
  fi
  if [ -x "$bin" ] && [ "$(readlink "$HOME/.local/bin/browse" 2>/dev/null || true)" != "$bin" ]; then
    mkdir -p "$HOME/.local/bin"
    if ln -sfn "$bin" "$HOME/.local/bin/browse"; then
      say "relinked browse"
    else
      say "browse relink failed"
    fi
  fi
fi

# 4. The `code` bridge inbox (read by vm-up.sh on the Mac).
mkdir -p "$HOME/.local/state/vm-open" 2>/dev/null || say "could not create the code inbox dir"
: >>"$HOME/.local/state/vm-open/requests" 2>/dev/null || say "could not create the code inbox file"
exit 0
