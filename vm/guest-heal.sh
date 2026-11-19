#!/bin/bash
# guest-heal.sh: repairs inside the agent VM that need no Mac input.
# vm-up.sh pipes it in (`limactl shell agent -- bash -s`), so it runs even when
# the guest's clone of this repo is stale. Idempotent and quiet when healthy.
# Each repair says what it did; one failure never stops the next repair.
set -euo pipefail
say() { printf 'guest-heal: %s\n' "$*"; }

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
#    first boot systemd-logind can spin and stop answering; a restart clears it.
if command -v systemctl >/dev/null 2>&1; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    say "systemd user manager not answering; restarting systemd-logind"
    sudo -n systemctl restart systemd-logind >/dev/null 2>&1 || say "could not restart systemd-logind"
    sudo -n systemctl start "user@$(id -u).service" >/dev/null 2>&1 || say "could not start user@$(id -u)"
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
#    upgrade moves it; a missing package means a fresh guest.
if command -v mise >/dev/null 2>&1; then
  if [ "$(uname -m)" = x86_64 ]; then arch=x64; else arch=arm64; fi
  root="$(mise exec -- npm root -g 2>/dev/null)" || root=""
  bin="$root/@opencode/browse/node_modules/@opencode/browse-linux-$arch/bin/browse"
  if [ -n "$root" ] && [ ! -x "$bin" ]; then
    if mise exec -- npm install -g @opencode/browse >/dev/null 2>&1; then
      say "installed browse"
    else
      say "browse install failed"
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
