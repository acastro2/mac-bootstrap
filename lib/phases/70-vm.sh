# shellcheck shell=bash
# lib/phases/70-vm.sh — the Lima agent VM: size it, start it, hand it the
# keys, and provision the guest (Docker, sudoers, repo, Obsidian, Rex).
# Contract: docs/den/CONTRACT.md ("Host vs VM", "VM guest"). Bash 3.2.
# shellcheck disable=SC2154  # AGENT_VM, REPO_URL, DEN_ROOT, VM_* come from config/lib.

den_phase vm \
  --title "Agent VM (Lima)" \
  --about "The Linux dev box: Docker, every key, Obsidian sync, the Rex server" \
  --os macos \
  --toggle DEN_VM \
  --needs "brew"

phase_vm() {
  local vm=${AGENT_VM:-}
  if [ -z "$vm" ]; then
    den_skip "AGENT_VM is empty in config.env" "set AGENT_VM in config.env"
  fi
  if ! command -v limactl >/dev/null 2>&1; then
    den_skip "limactl is not installed" "brew install lima"
  fi
  den_vm_resources
  vm_create_or_resize "$vm"
  if ! limactl autostart enable "$vm" --tty=false; then
    ui_warn "could not register $vm for autostart; run: limactl autostart enable $vm"
  fi
  den_vm_ssh_include
  vm_sync_keys "$vm"
  vm_sync_relay_token "$vm"
  vm_guest_provision "$vm"
  vm_browse_cli "$vm"
  vm_rex_server "$vm"
  vm_restart_if_requested "$vm"
  vm_code_ssh
  if ! AGENT_VM="$vm" "${DEN_ROOT}/vm/vm-up.sh" --heal; then
    ui_warn "vm-up heal pass failed; see ~/.local/state/rex-vm/vm-up.log"
  fi
  den_vm_up_agent
  if [ "${VM_REX_INSTALLED:-0}" = 1 ]; then
    ui_info "Rex.app, once per Mac: Cmd-Shift-P > Add Remote Host... > ssh://lima-$vm, then Switch Host"
  fi
}

# vm_restart_if_requested <vm>: the guest asks for one restart when its
# systemd user manager (started before the docker group was added) has no
# docker group. Stop with den_vm_stop (never hangs), start, and drop the
# request only when the same /proc check now passes. At most 2 attempts per
# request: a restart that cannot fix it must not loop.
vm_restart_if_requested() {
  # shellcheck disable=SC2016  # $HOME expands in the guest
  local vm=$1 flag='$HOME/.local/state/den/restart-requested' n=""
  # shellcheck disable=SC2016
  local tries='$HOME/.local/state/den/restart-attempts' started=0
  if ! den_vm_to 20 limactl shell "$vm" -- bash -c "test -f $flag" </dev/null >/dev/null 2>&1; then
    return 0
  fi
  n=$(den_vm_to 20 limactl shell "$vm" -- bash -c "cat $tries 2>/dev/null || echo 0" </dev/null 2>/dev/null |
    tr -d '\r ' | head -n 1) || n=""
  case ${n:-} in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -ge 2 ]; then
    den_vm_to 20 limactl shell "$vm" -- bash -c "rm -f $flag $tries" </dev/null >/dev/null 2>&1 || true
    ui_warn "$vm was restarted twice and its user manager still lacks the docker group; run: den vm shell, then sudo reboot"
    return 0
  fi
  n=$((n + 1))
  den_vm_to 20 limactl shell "$vm" -- bash -c "printf '%s\n' $n > $tries" </dev/null >/dev/null 2>&1 || true
  ui_step "restarting $vm (attempt $n of 2) so new sessions get the docker group"
  # vm-up must not start the VM again while den stops it on purpose. Inside
  # the agent there is no separate vm-up to race: this process is it.
  if [ "${VM_UP_AGENT:-}" != 1 ]; then
    launchctl bootout "gui/$(id -u)/$DEN_VM_LABEL" >/dev/null 2>&1 || true
  fi
  den_vm_stop "$vm" || ui_warn "could not stop $vm cleanly"
  if den_vm_to 300 limactl start "$vm" --tty=false >/dev/null 2>&1; then
    started=1
  fi
  if [ "${VM_UP_AGENT:-}" != 1 ]; then
    den_vm_up_agent
  fi
  if [ "$started" = 0 ]; then
    ui_warn "could not start $vm after the restart; run: den vm up"
    return 0
  fi
  # The flag means "the user manager has no docker group": drop it only when
  # that same /proc check passes. A fresh `docker info` proves nothing, since
  # the ssh command is a new process that already has the group.
  # shellcheck disable=SC2016  # expands in the guest
  if den_vm_to 60 limactl shell "$vm" -- bash -c \
    'mgr=$(pgrep -u "$(id -un)" -f "systemd --user" | head -n 1 || true); gid=$(getent group docker | cut -d: -f3); [ -n "$mgr" ] && [ -n "$gid" ] && awk -v g="$gid" "/^Groups:/ { for (i = 2; i <= NF; i++) if (\$i == g) f = 1 } END { exit !f }" "/proc/$mgr/status"' \
    </dev/null >/dev/null 2>&1; then
    den_vm_to 20 limactl shell "$vm" -- bash -c "rm -f $flag $tries" </dev/null >/dev/null 2>&1 || true
    ui_ok "$vm restarted; its user manager has the docker group"
  else
    ui_warn "$vm restarted but its user manager still lacks the docker group; den up --only=vm tries again"
  fi
}

# Create, resize or start. Never shrink; never stop a Running VM to resize it.
vm_create_or_resize() {
  local vm=$1 state status have_cpus have_mem have_disk need=0 disk_gib
  state=$(den_vm_json "$vm") || state=""
  if [ -z "$state" ]; then
    ui_step "creating $vm: ${VM_CPUS:-8} CPUs, ${VM_MEM_GB:-16} GiB RAM, ${VM_DISK_GB:-40} GiB disk"
    if [ "${VM_LOW_DISK:-false}" = true ]; then
      ui_warn "low disk: ${VM_FREE_GB:-0} GiB free; the VM takes ${VM_DISK_GB:-40} GiB"
    fi
    if ! den_vm_to 600 limactl create --name="$vm" --cpus="${VM_CPUS:-8}" --memory="${VM_MEM_GB:-16}" \
      --disk="${VM_DISK_GB:-40}" --tty=false "${DEN_ROOT}/vm/lima-dev.yaml"; then
      den_fail "could not create $vm" "den up --only=vm"
    fi
    if ! den_vm_to 900 limactl start "$vm" --tty=false --timeout 10m; then
      ui_warn "could not start $vm; run: limactl start $vm"
    fi
    return 0
  fi

  status=$(den_vm_field "$state" status)
  have_cpus=$(den_vm_field "$state" cpus)
  have_mem=$(den_vm_field "$state" memory)
  have_disk=$(den_vm_field "$state" disk)
  have_cpus=${have_cpus:-0}
  have_mem=${have_mem:-0}
  have_disk=${have_disk:-0}
  if [ "$have_cpus" -lt "${VM_CPUS:-8}" ]; then
    need=1
  fi
  if [ "$have_mem" -lt $((${VM_MEM_GB:-16} * 1073741824)) ]; then
    need=1
  fi
  if [ "$have_disk" -lt $((${VM_DISK_GB:-40} * 1073741824)) ]; then
    disk_gib=$((have_disk / 1073741824))
    ui_warn "$vm disk is ${disk_gib} GiB, below the ${VM_DISK_GB:-40} GiB target; disks never shrink, so it stays"
  fi

  # Escape path U1 (docs/den/JAILBREAK.md): an instance made before the
  # template set networkOpts.hostLoopback: false still reaches the Mac loopback.
  if ! grep -Eq '^[[:space:]]+hostLoopback:[[:space:]]*false' "$HOME/.lima/$vm/lima.yaml" 2>/dev/null; then
    if [ "$status" = Running ]; then
      ui_warn "$vm can reach the Mac loopback; run: den vm down && den up --only=vm"
    else
      ui_step "blocking the Mac loopback for $vm (networkOpts.hostLoopback: false)"
      if ! den_vm_to 120 limactl edit "$vm" --set '.networkOpts.hostLoopback = false' --tty=false; then
        den_fail "could not edit $vm" "limactl edit $vm --set '.networkOpts.hostLoopback = false'"
      fi
    fi
  fi

  # Escape path U7: without a guestPortRange rule, Lima mirrors every guest
  # port, so the VM could take a Mac port a CLI login waits on.
  if ! grep -q 'guestPortRange' "$HOME/.lima/$vm/lima.yaml" 2>/dev/null; then
    if [ "$status" = Running ]; then
      ui_warn "$vm mirrors every port to the Mac; run: den vm down && den up --only=vm"
    else
      ui_step "limiting the port mirror for $vm to 1024-9999"
      if ! den_vm_to 120 limactl edit "$vm" --set '.portForwards = [{"guestPort":19988,"ignore":true},{"guestPortRange":[1024,9999]},{"guestIP":"0.0.0.0","guestIPMustBeZero":false,"proto":"any","ignore":true}]' --tty=false; then
        den_fail "could not edit $vm" "den vm down && den up --only=vm"
      fi
    fi
  fi

  if [ "$need" = 1 ]; then
    if [ "$status" = Running ]; then
      ui_warn "$vm is smaller than this Mac allows; run: den vm down && den up --only=vm"
      return 0
    fi
    ui_step "resizing $vm: ${VM_CPUS:-8} CPUs, ${VM_MEM_GB:-16} GiB RAM (disk untouched)"
    if ! den_vm_to 120 limactl edit "$vm" --cpus="${VM_CPUS:-8}" --memory="${VM_MEM_GB:-16}" --tty=false; then
      den_fail "could not edit $vm" "limactl edit $vm --cpus=${VM_CPUS:-8} --memory=${VM_MEM_GB:-16}"
    fi
    if ! den_vm_to 900 limactl start "$vm" --tty=false --timeout 10m; then
      ui_warn "could not start $vm; run: limactl start $vm"
    fi
    return 0
  fi

  if [ "$status" != Running ]; then
    ui_step "starting $vm"
    if ! den_vm_to 900 limactl start "$vm" --tty=false --timeout 10m; then
      ui_warn "could not start $vm; run: limactl start $vm"
    fi
  else
    ui_info "$vm is Running and sized as this Mac allows"
  fi
}

vm_sync_keys() {
  local vm=$1 src="$HOME/.config/zsh/.api-keys.zsh"
  if [ ! -f "$src" ]; then
    ui_info "no ~/.config/zsh/.api-keys.zsh; nothing to sync"
    return 0
  fi
  # shellcheck disable=SC2016  # $HOME is the guest's, expanded there.
  den_vm_to 20 limactl shell "$vm" -- bash -c 'mkdir -p "$HOME/.config/zsh" && chmod 700 "$HOME/.config/zsh"' ||
    ui_warn "could not create ~/.config/zsh in $vm"
  if den_vm_to 60 limactl copy "$src" "$vm:.config/zsh/.api-keys.zsh"; then
    # shellcheck disable=SC2016
    den_vm_to 20 limactl shell "$vm" -- bash -c 'chmod 600 "$HOME/.config/zsh/.api-keys.zsh"' ||
      ui_warn "could not set mode 600 on the guest API keys"
  else
    ui_warn "could not copy the API keys into $vm"
  fi
}

vm_sync_relay_token() {
  local vm=$1 src="$HOME/.local/share/browse/relay-token"
  if [ ! -f "$src" ]; then
    return 0
  fi
  # shellcheck disable=SC2016  # $HOME is the guest's, expanded there.
  den_vm_to 20 limactl shell "$vm" -- bash -c 'mkdir -p "$HOME/.local/share/browse" && chmod 700 "$HOME/.local/share/browse"' ||
    ui_warn "could not create the browse dir in $vm"
  if den_vm_to 60 limactl copy "$src" "$vm:.local/share/browse/relay-token"; then
    # shellcheck disable=SC2016
    den_vm_to 20 limactl shell "$vm" -- bash -c 'chmod 600 "$HOME/.local/share/browse/relay-token"' ||
      ui_warn "could not set mode 600 on the guest relay token"
  else
    ui_warn "could not copy the browse relay token into $vm"
  fi
}

# Pipe every provisioning script in; tests capture stdin on "bash -s".
vm_guest_provision() {
  local vm=$1 script vault=""
  vault=${OBSIDIAN_SYNC_VAULT:-}
  [ -n "$vault" ] || vault=$(den_secret .obsidian.vault) || vault=""
  if [ -z "$vault" ]; then
    ui_info "obsidian: no vault name in the secrets bundle; sync setup skipped"
  fi
  # The guest runs exactly the Mac's den: stream this checkout in (Mac -> VM,
  # the safe direction). No push, no clone, no version drift between them.
  local gdir='.local/share/den'
  if tar -C "$DEN_ROOT" --exclude .git -czf - . 2>/dev/null |
    den_vm_to 120 limactl shell "$vm" -- bash -c \
      "rm -rf \"\$HOME/$gdir.new\" && mkdir -p \"\$HOME/$gdir.new\" && tar -xzf - -C \"\$HOME/$gdir.new\" && rm -rf \"\$HOME/$gdir\" && mv \"\$HOME/$gdir.new\" \"\$HOME/$gdir\""; then
    ui_ok "den copied into $vm (~/$gdir)"
  else
    ui_warn "could not copy den into $vm; the guest falls back to a git clone"
  fi
  for script in "${DEN_ROOT}"/vm/guest-*.sh; do
    [ -e "$script" ] || continue
    case ${script##*/} in
      guest-heal.sh) continue ;;
    esac
    if ! den_vm_to 3600 limactl shell "$vm" -- env \
      "DEN_REPO_URL=${REPO_URL:-}" "DEN_GUEST_DIR=$gdir" "DEN_VM_NAME=$vm" "OBSIDIAN_VAULT=$vault" \
      bash -s <"$script"; then
      ui_warn "${script##*/} failed in $vm"
    fi
  done
}

# The browse CLI's npm package name must be visible in argv: the guest's own
# paths live under mise and a fresh guest has no `browse` yet.
vm_browse_cli() {
  local vm=$1
  # shellcheck disable=SC2016  # the whole script runs in the guest.
  if ! den_vm_to 300 limactl shell "$vm" -- bash -c "${DEN_GUEST_ENV}"'
    command -v browse >/dev/null 2>&1 && exit 0
    if command -v mise >/dev/null 2>&1; then
      arch=arm64
      [ "$(uname -m)" = x86_64 ] && arch=x64
      root=$(mise exec -- npm root -g 2>/dev/null) || root=""
      [ -n "$root" ] || exit 0
      mise exec -- npm install -g @opencode/browse >/dev/null 2>&1 || exit 0
      bin="$root/@opencode/browse/node_modules/@opencode/browse-linux-$arch/bin/browse"
      if [ -x "$bin" ]; then
        mkdir -p "$HOME/.local/bin"
        ln -sfn "$bin" "$HOME/.local/bin/browse"
      fi
    fi
  '; then
    ui_warn "could not install the browse CLI in $vm"
  fi
}

# vm_user_bus <vm>: make sure the guest's systemd user manager answers.
# On a fresh VM's first boot systemd-logind can spin at 100% CPU and stop
# answering D-Bus (seen 2026-11-18 on Ubuntu 24.04 under VZ; a normal boot is
# fine). Then every `systemctl --user` fails with "No medium found" and the
# Rex server cannot install. A logind restart clears it, but it drops every
# session in the guest, so it runs only for that fault and once per boot.
vm_user_bus() {
  local vm=$1
  # shellcheck disable=SC2016  # expands in the guest
  if den_vm_to 60 limactl shell "$vm" -- bash -c '
    uid=$(id -u); export XDG_RUNTIME_DIR=/run/user/$uid
    systemctl --user show-environment >/dev/null 2>&1 && exit 0
    pcpu=$(ps -o pcpu= -C systemd-logind 2>/dev/null | awk "{ if (\$1 + 0 > m) m = \$1 + 0 } END { print m + 0 }") || pcpu=0
    if awk -v c="${pcpu:-0}" "BEGIN { exit !(c >= 80) }" &&
      ! sudo -n test -e /run/den-logind-restarted >/dev/null 2>&1 &&
      sudo -n touch /run/den-logind-restarted >/dev/null 2>&1; then
      sudo -n systemctl restart systemd-logind >/dev/null 2>&1
      sudo -n systemctl start "user@$uid.service" >/dev/null 2>&1
    fi
    systemctl --user show-environment >/dev/null 2>&1
  ' </dev/null >/dev/null 2>&1; then
    return 0
  fi
  ui_warn "the systemd user manager in $vm does not answer; restart the VM once (den vm down, den vm up)"
  return 1
}

vm_rex_server() {
  local vm=$1 cli=""
  vm_user_bus "$vm" || true
  # shellcheck disable=SC2016  # expands in the guest
  if den_vm_to 20 limactl shell "$vm" -- bash -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user is-active --quiet rex.socket' </dev/null >/dev/null 2>&1; then
    ui_info "rex server already running in $vm"
    return 0
  fi
  cli=$(den_vm_rex_cli) || cli=""
  if [ -z "$cli" ]; then
    ui_warn "Rex CLI not found; open Rex once, then run: den up --only=vm"
    return 0
  fi
  if den_vm_to 300 "$cli" server install "ssh://lima-$vm" --label vm --yes; then
    VM_REX_INSTALLED=1
    ui_ok "Rex server installed in $vm (host label: vm)"
  else
    ui_warn "Rex server install failed; run it from Rex.app"
  fi
}

vm_code_ssh() {
  local code_bin=""
  code_bin=$(command -v code 2>/dev/null) || code_bin=""
  if [ -z "$code_bin" ]; then
    ui_info "VS Code is not on PATH; Remote-SSH skipped"
    return 0
  fi
  # Both calls can hang on a VS Code that wants a window: bound them.
  if den_with_timeout 60 "$code_bin" --list-extensions 2>/dev/null | grep -qx ms-vscode-remote.remote-ssh; then
    return 0
  fi
  if den_with_timeout 60 "$code_bin" --install-extension ms-vscode-remote.remote-ssh >/dev/null 2>&1; then
    ui_ok "VS Code Remote-SSH extension installed"
  else
    ui_warn "could not install the VS Code Remote-SSH extension"
  fi
}
