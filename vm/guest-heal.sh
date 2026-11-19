#!/bin/bash
# guest-heal.sh: repairs inside the agent VM that need no Mac input.
# vm-up.sh pipes it in (`limactl shell agent -- bash -s`), so it runs even when
# the guest's clone of this repo is stale. Idempotent and quiet when healthy.
set -u
say() { echo "guest-heal: $*"; }

# Toolchain on PATH: a bash -s shell has neither brew nor mise.
[ -x /home/linuxbrew/.linuxbrew/bin/brew ] && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

# 1. Rex server: the socket unit starts it on demand.
if command -v systemctl >/dev/null && ! systemctl --user is-active --quiet rex.socket; then
  systemctl --user start rex.socket && say "started rex.socket"
fi

# 2. browse CLI: link the native binary of the current mise node. A node
#    upgrade moves it; a missing package means a fresh guest.
if command -v mise >/dev/null; then
  if [ "$(uname -m)" = x86_64 ]; then arch=x64; else arch=arm64; fi
  root="$(mise exec -- npm root -g 2>/dev/null)"
  bin="$root/@opencode/browse/node_modules/@opencode/browse-linux-$arch/bin/browse"
  if [ -n "$root" ] && [ ! -x "$bin" ]; then
    mise exec -- npm install -g @opencode/browse >/dev/null 2>&1 && say "installed browse"
  fi
  if [ -x "$bin" ] && [ "$(readlink "$HOME/.local/bin/browse")" != "$bin" ]; then
    mkdir -p "$HOME/.local/bin" && ln -sfn "$bin" "$HOME/.local/bin/browse" && say "relinked browse"
  fi
fi

# 3. The `code` bridge inbox (read by vm-up.sh on the Mac).
mkdir -p "$HOME/.local/state/vm-open" && touch "$HOME/.local/state/vm-open/requests"
exit 0
