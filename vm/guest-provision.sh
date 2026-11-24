#!/bin/bash
# guest-provision.sh: set up the agent VM as the dev box. Piped in by the vm
# phase (`limactl shell agent -- bash -s`), so it must work on a bare guest
# and be safe to run again: every step checks its own result first.
#
# The Mac sends no secrets here: the vault name arrives in OBSIDIAN_VAULT,
# the repo URL in DEN_REPO_URL and the instance name in DEN_VM_NAME.
set -euo pipefail

say() { printf 'den guest: %s\n' "$*"; }

USER_NAME=${USER:-$(id -un)}

# ── 0. Homebrew and PATH ──────────────────────────────────────────────
# A `bash -s` shell has no Homebrew or mise on PATH, and a fresh guest has no
# Homebrew at all (stage 0 never runs here), so install it unattended.
if [ ! -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  say "installing Homebrew (first run takes a few minutes)"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL --connect-timeout 15 -m 600 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null >/dev/null ||
    say "Homebrew install failed; the Linux phases will skip until it works"
fi
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$HOME/.opencode/bin:/usr/local/bin:$PATH"

# ── 1. Docker Engine, from Docker's apt repository ────────────────────
# Rootful; the guest is the sandbox. The docker group is added below and
# before the Rex server / the systemd user manager use it.
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  if ! {
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL --connect-timeout 15 -m 300 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    # shellcheck disable=SC1091  # os-release exists on the guest, not here.
    codename=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-noble}")
    arch=$(dpkg --print-architecture)
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
      "$arch" "$codename" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
  }; then
    say "Docker Engine install failed; rerun: den up --only=vm"
  else
    say "installed Docker Engine"
  fi
fi
sudo systemctl enable --now docker >/dev/null 2>&1 || say "docker.service is not active yet"
sudo groupadd -f docker || say "could not create the docker group"
sudo usermod -aG docker "$USER_NAME" || say "could not add $USER_NAME to the docker group"

# A systemd user manager that started before the group was added does not
# have it; only a restart of the guest gives it one.
mgr=$(pgrep -u "$USER_NAME" -f 'systemd --user' | head -n 1 || true)
# /proc lists numeric group IDs, never names: compare the docker GID.
gid=$(getent group docker | cut -d: -f3)
if [ -n "$mgr" ] && [ -n "$gid" ] &&
  ! awk -v g="$gid" '/^Groups:/ { for (i = 2; i <= NF; i++) if ($i == g) f = 1 } END { exit !f }' "/proc/$mgr/status" 2>/dev/null; then
  marker="$HOME/.local/state/den/docker-group-noted"
  if [ ! -f "$marker" ]; then
    mkdir -p "$(dirname "$marker")"
    : >"$marker"
    # The Mac's vm phase sees this file and restarts the VM once, so nobody
    # has to remember that docker needs it. A fresh request starts at 0
    # attempts; the Mac caps itself at 2 and then drops both files.
    : >"$HOME/.local/state/den/restart-requested"
    rm -f "$HOME/.local/state/den/restart-attempts"
    say "the user systemd manager predates the docker group; the vm phase restarts the VM once"
  fi
fi

# ── 2. Passwordless sudo, validated before it lands ───────────────────
# Lima's cloud-init gives the user sudo; den owns a file of its own so the
# rule survives a Lima upgrade and is checked with visudo first.
sudoers_tmp=$(mktemp)
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USER_NAME" >"$sudoers_tmp"
if sudo visudo -cf "$sudoers_tmp" >/dev/null 2>&1; then
  sudo install -m 0440 -o root -g root "$sudoers_tmp" "/etc/sudoers.d/$USER_NAME"
else
  say "the sudoers rule failed visudo -cf; not installed"
fi
rm -f "$sudoers_tmp"

# ── 3. zram swap, compressed, in RAM ──────────────────────────────────
# Agents fill the guest RAM. With no swap, the kernel can only evict code
# pages, so kswapd thrashes. zram keeps idle anonymous memory in RAM, in
# compressed form, with no disk I/O.
# The cloud image kernel has no zram module. The module ships in
# linux-modules-extra-<kernel>. The image tracks kernels with the
# linux-image-virtual meta, which never pulls -extra, so a kernel upgrade would
# boot without zram. The linux-image-generic meta pulls -extra with every
# kernel (same -generic image here), so install it too.
zram_on() { swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/dev/zram'; }
if zram_on && dpkg -s linux-image-generic >/dev/null 2>&1; then
  : # zram swap on and -extra tracks the kernel; nothing to do
else
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  if ! {
    sudo apt-get update -qq
    sudo apt-get install -y -qq linux-image-generic "linux-modules-extra-$(uname -r)" systemd-zram-generator
  }; then
    say "zram: could not install linux-image-generic, linux-modules-extra-$(uname -r) or systemd-zram-generator; zram swap not set"
  elif zram_on; then
    # Never restart a live zram swap: swapoff pulls every page back into RAM.
    say "zram swap already on; linux-image-generic now keeps -extra in step with the kernel"
  elif ! sudo modprobe zram >/dev/null 2>&1; then
    say "zram module missing for kernel $(uname -r); zram swap not set"
  else
    zram_tmp=$(mktemp)
    printf '[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd\n' >"$zram_tmp"
    { sudo install -m 0644 -o root -g root "$zram_tmp" /etc/systemd/zram-generator.conf &&
      sudo systemctl daemon-reload; } || say "zram: could not write /etc/systemd/zram-generator.conf"
    rm -f "$zram_tmp"
    # restart, not start: the package install may already have brought zram0
    # up with the default size; restart applies the config above.
    sudo systemctl restart systemd-zram-setup@zram0.service >/dev/null 2>&1 || true
    # The swap turns on a moment after the restart returns (seen live: swapon
    # empty, free a second later showed it). Wait up to 10 s before judging.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      zram_on && break
      sleep 1
    done
    if zram_on; then
      say "zram swap on (/dev/zram0, half of RAM, zstd)"
    else
      say "zram swap did not start; see: systemctl status systemd-zram-setup@zram0.service"
    fi
  fi
fi

# ── 4. The repo, then the Linux phases ────────────────────────────────
REPO_DIR=${DEN_GUEST_DIR:-$HOME/Developer/github/acastro2/mac-bootstrap}
case $REPO_DIR in /*) ;; *) REPO_DIR=$HOME/$REPO_DIR ;; esac
REPO_URL=${DEN_REPO_URL:-https://github.com/acastro2/mac-bootstrap.git}
if [ -x "$REPO_DIR/bin/den" ] && [ ! -d "$REPO_DIR/.git" ]; then
  say "using den copied from the Mac ($REPO_DIR)"
elif [ ! -d "$REPO_DIR/.git" ]; then
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone "$REPO_URL" "$REPO_DIR" || say "clone failed; the guest keeps no repo yet"
else
  # --ff-only --no-rebase: the guest checkout is a mirror, never edited.
  git -C "$REPO_DIR" pull --ff-only --no-rebase >/dev/null 2>&1 ||
    say "could not fast-forward $REPO_DIR; using the local checkout"
fi
if [ -x "$REPO_DIR/bin/den" ]; then
  # macOS-only phases are gated by --os, so a plain den up is safe here.
  # secrets: the keys come from the Mac (vm-up syncs ~/.config/zsh/.api-keys.zsh).
  ( cd "$REPO_DIR" && DEN_UI=plain ./bin/den up --skip=secrets </dev/null ) || say "den up in the guest hit a failed phase"
  # Phases may have just installed tools; pick them up for the steps below.
  [ -x /home/linuxbrew/.linuxbrew/bin/brew ] && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  hash -r
fi

# ── 5. Shared OpenTofu provider cache ─────────────────────────────────
# Each `tofu init` symlinks into one cache instead of copying the 766 MB AWS
# provider per checkout (agents clone repos often; it filled the disk once).
# A CLI config file, not an env var: environment.d does not reach shells.
# OpenTofu reads ~/.terraformrc when ~/.tofurc is absent, and since 1.10 it
# locks the cache, so parallel inits are safe.
tf_cache="$HOME/.terraform.d/plugin-cache"
if grep -qs '^[[:space:]]*plugin_cache_dir' "$HOME/.terraformrc" "$HOME/.tofurc"; then
  : # already set; leave the user's file alone
elif [ -e "$HOME/.tofurc" ]; then
  say "$HOME/.tofurc exists without plugin_cache_dir; provider cache not set"
elif mkdir -p "$tf_cache"; then
  printf 'plugin_cache_dir = "%s"\n' "$tf_cache" >>"$HOME/.terraformrc" ||
    say "could not write ~/.terraformrc"
else
  say "could not create $tf_cache; provider cache not set"
fi

# ── 6. Obsidian Headless ──────────────────────────────────────────────
# Always installed, so the Mac's preflight can run `ob login` and the first
# `ob sync-setup` interactively (an E2EE vault asks for its password). Here,
# unattended: configure a set-up vault safely and keep it syncing.
if ! command -v ob >/dev/null 2>&1; then
  if command -v mise >/dev/null 2>&1; then
    mise exec -- npm install -g obsidian-headless >/dev/null 2>&1 || say "obsidian-headless install failed"
    hash -r
  else
    say "no mise yet; obsidian-headless not installed"
  fi
fi
ob_bin=$(command -v ob 2>/dev/null || true)
mkdir -p "$HOME/.config/environment.d" "$HOME/Developer"
printf 'OBSIDIAN_VAULT=%s\n' "$HOME/Developer/obsidian" >"$HOME/.config/environment.d/10-den-obsidian.conf" ||
  say "could not write the OBSIDIAN_VAULT environment file"
if [ -n "$ob_bin" ] && "$ob_bin" sync-list-remote --json >/dev/null 2>&1; then
  if ! "$ob_bin" sync-status --path "$HOME/Developer/obsidian" >/dev/null 2>&1 && [ -n "${OBSIDIAN_VAULT:-}" ]; then
    # Works unattended for a vault without end-to-end encryption.
    "$ob_bin" sync-setup --vault "$OBSIDIAN_VAULT" --path "$HOME/Developer/obsidian" \
      --device-name "${DEN_VM_NAME:-vm}" </dev/null >/dev/null 2>&1 ||
      say "obsidian: sync-setup needs you (E2EE password?); den up on the Mac asks in preflight"
  fi
  if "$ob_bin" sync-status --path "$HOME/Developer/obsidian" >/dev/null 2>&1; then
    # Empty --configs: the VM never syncs .obsidian/, so it cannot push plugins
    # (code) to the Mac. File types leave out "unsupported" (e.g. *.pem).
    "$ob_bin" sync-config --path "$HOME/Developer/obsidian" --configs "" --mode bidirectional \
      --conflict-strategy merge --file-types image,audio,video,pdf >/dev/null ||
      say "obsidian sync-config failed"
    mkdir -p "$HOME/.config/systemd/user"
    cat >"$HOME/.config/systemd/user/obsidian-sync.service" <<UNIT
[Unit]
Description=Obsidian Headless sync
After=network-online.target

[Service]
ExecStart=$ob_bin sync --continuous --path %h/Developer/obsidian
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable --now obsidian-sync.service >/dev/null 2>&1 ||
      say "could not enable obsidian-sync.service"
  else
    say "obsidian: ~/Developer/obsidian is not set up yet; den up on the Mac sets it up in preflight"
  fi
else
  say "obsidian: not signed in yet; den up on the Mac runs ob login in preflight"
fi
