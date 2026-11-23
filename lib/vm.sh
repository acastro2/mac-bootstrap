# shellcheck shell=bash
# lib/vm.sh — the Lima agent VM from the Mac side: sizing, state, the ssh
# include, the vm-up login agent, `den vm`, the doctor check and the
# preflight hook. Contract: docs/den/CONTRACT.md ("Host vs VM", "VM guest",
# "Hooks"). Bash 3.2.
# shellcheck disable=SC2154  # AGENT_VM, DEN_ROOT and HOST_* come from config/lib.

DEN_VM_LABEL=io.mac-bootstrap.vm-up
DEN_VM_PORT=19988

# Bound an external call. perl exists on every macOS; without it, run plainly.
den_vm_to() { # den_vm_to SECONDS CMD...
  local secs=${1:-30}
  if [ $# -gt 0 ]; then
    shift
  fi
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  else
    "$@"
  fi
}

# ── Sizing ───────────────────────────────────────────────────────────
# Every core: an idle vCPU costs the Mac nothing. RAM: the larger of half and
# RAM minus 12 GiB, never above RAM minus 8 GiB, because Apple Virtualization
# never gives RAM the guest touched back to macOS (no free page reporting;
# measured: a guest drop_caches did not shrink the VM process). Half the free
# disk, capped at 200 GiB. HOST_NCPU, HOST_MEM_BYTES and HOST_FREE_BYTES override
# the facts; tests use them so sizing never reads the test machine.
den_vm_resources() {
  local ncpu mem_bytes free_bytes mem_gib free_gib
  ncpu="${HOST_NCPU:-$(sysctl -n hw.ncpu 2>/dev/null || true)}"
  mem_bytes="${HOST_MEM_BYTES:-$(sysctl -n hw.memsize 2>/dev/null || true)}"
  # -P: one line per file, so a long device name cannot push the free column
  # onto a second line (plain df -k does that on macOS).
  free_bytes="${HOST_FREE_BYTES:-$(df -kP "$HOME" 2>/dev/null | awk 'NR==2 {print $4 * 1024}' || true)}"
  case ${ncpu:-} in ''|*[!0-9]*) ncpu=4 ;; esac
  case ${mem_bytes:-} in ''|*[!0-9]*) mem_bytes=8589934592 ;; esac
  case ${free_bytes:-} in ''|*[!0-9]*) free_bytes=0 ;; esac
  mem_gib=$((mem_bytes / 1073741824))
  free_gib=$((free_bytes / 1073741824))

  VM_CPUS=$ncpu
  VM_MEM_GB=$((mem_gib / 2))
  if [ "$VM_MEM_GB" -lt $((mem_gib - 12)) ]; then
    VM_MEM_GB=$((mem_gib - 12))
  fi
  if [ "$VM_MEM_GB" -gt $((mem_gib - 8)) ]; then
    VM_MEM_GB=$((mem_gib - 8))
  fi
  if [ "$VM_MEM_GB" -lt 4 ]; then
    VM_MEM_GB=4
  fi
  VM_DISK_GB=$((free_gib / 2))
  if [ "$VM_DISK_GB" -gt 200 ]; then
    VM_DISK_GB=200
  fi
  if [ "$VM_DISK_GB" -lt 40 ]; then
    VM_DISK_GB=40
  fi
  VM_FREE_GB=$free_gib
  VM_LOW_DISK=false
  if [ "$free_gib" -lt $((VM_DISK_GB + 20)) ]; then
    VM_LOW_DISK=true
  fi
}

den_vm_resources_line() {
  printf 'cpus=%s memory=%s disk=%s' "$VM_CPUS" "$VM_MEM_GB" "$VM_DISK_GB"
  if [ "$VM_LOW_DISK" = true ]; then
    printf ' low disk: %s GiB free' "$VM_FREE_GB"
  fi
  printf '\n'
}

# ── State ────────────────────────────────────────────────────────────
den_vm_json() { # den_vm_json [NAME]: the limactl JSON line for the instance
  local name=${1:-${AGENT_VM:-}}
  [ -n "$name" ] || return 1
  limactl list --format json 2>/dev/null |
    grep -E "\"name\"[[:space:]]*:[[:space:]]*\"$name\"" |
    head -n 1
}

den_vm_field() { # den_vm_field JSON KEY (status|cpus|memory|disk)
  local json=${1:-} key=${2:-}
  case $key in
    status)
      printf '%s' "$json" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
      ;;
    cpus|memory|disk)
      printf '%s' "$json" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p'
      ;;
  esac
}

den_vm_status() { # den_vm_status [NAME]
  local name=${1:-${AGENT_VM:-}} out=""
  [ -n "$name" ] || return 1
  out=$(den_vm_to 15 limactl list "$name" --format '{{.Status}}' 2>/dev/null) || out=""
  printf '%s' "$out" | tr -d '\r' | head -n 1
}

den_vm_hash() { # den_vm_hash FILE: sha256 hex, or nonzero
  local file=${1:-} out=""
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1)
  elif command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)
  fi
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# ── SSH include ──────────────────────────────────────────────────────
# ssh applies an Include after a Host block only inside that block, so the
# Lima include must be line 1. Later copies of the same line are dropped.
den_vm_ssh_include() {
  local cfg="$HOME/.ssh/config" inc='Include ~/.lima/*/ssh.config' count first stamp tmp
  if ! mkdir -p "$HOME/.ssh" 2>/dev/null || ! chmod 700 "$HOME/.ssh" 2>/dev/null; then
    ui_warn "could not prepare ~/.ssh; skipping the Lima ssh include"
    return 0
  fi
  if [ ! -e "$cfg" ]; then
    if printf '%s\n' "$inc" >"$cfg" && chmod 600 "$cfg"; then
      ui_ok "created ~/.ssh/config with the Lima include"
    else
      ui_warn "could not create ~/.ssh/config"
    fi
    return 0
  fi
  first=$(head -n 1 "$cfg" 2>/dev/null || true)
  count=$(grep -cxF "$inc" "$cfg" 2>/dev/null || true)
  count=${count:-0}
  if [ "$first" = "$inc" ] && [ "$count" -eq 1 ]; then
    return 0
  fi
  stamp=$(date +%Y%m%d-%H%M%S)
  if ! cp -p "$cfg" "$cfg.bak.$stamp"; then
    ui_warn "could not back up ~/.ssh/config; leaving it untouched"
    return 0
  fi
  tmp=$(mktemp "$cfg.tmp.XXXXXX") || {
    ui_warn "could not edit ~/.ssh/config"
    return 0
  }
  if ! {
    printf '%s\n' "$inc"
    grep -vxF "$inc" "$cfg" || true
  } >"$tmp"; then
    rm -f "$tmp"
    ui_warn "could not edit ~/.ssh/config"
    return 0
  fi
  if mv "$tmp" "$cfg"; then
    chmod 600 "$cfg"
    ui_ok "added the Lima include as line 1 of ~/.ssh/config (backup: config.bak.$stamp)"
  else
    rm -f "$tmp"
    ui_warn "could not replace ~/.ssh/config"
  fi
}

# ── vm-up login agent ────────────────────────────────────────────────
den_vm_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$DEN_VM_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>${DEN_ROOT}/vm/vm-up.sh</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>AGENT_VM</key><string>${AGENT_VM}</string>
    <key>VM_UP_AGENT</key><string>1</string>
    <key>DEN_BROWSE_TUNNEL</key><string>${DEN_BROWSE_TUNNEL:-1}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$HOME/.local/state/rex-vm/vm-up.log</string>
  <key>StandardErrorPath</key><string>$HOME/.local/state/rex-vm/vm-up.log</string>
</dict>
</plist>
PLIST
}

# Install or refresh the login agent. A kickstart restarts it so a changed
# vm-up.sh takes effect now; it never runs inside the agent itself.
den_vm_up_agent() {
  local label=$DEN_VM_LABEL dir="$HOME/Library/LaunchAgents" plist new hash hashfile loaded=0
  plist="$dir/$label.plist"
  hashfile="$HOME/.local/state/rex-vm/vm-up.sha256"
  mkdir -p "$dir" "$HOME/.local/state/rex-vm" 2>/dev/null || true
  new=$(den_vm_plist)
  hash=$(den_vm_hash "${DEN_ROOT}/vm/vm-up.sh") || hash=""
  if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    loaded=1
  fi

  if [ -f "$plist" ] && [ "$(cat "$plist" 2>/dev/null)" = "$new" ]; then
    if [ "$loaded" = 0 ]; then
      if launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1; then
        if [ -n "$hash" ]; then
          printf '%s\n' "$hash" >"$hashfile" 2>/dev/null || true
        fi
        ui_ok "vm-up login agent loaded"
      else
        ui_warn "could not load $plist; run: launchctl bootstrap gui/$(id -u) $plist"
      fi
    elif [ -n "$hash" ] && [ "$hash" != "$(cat "$hashfile" 2>/dev/null || true)" ]; then
      # Inside the agent, never restart it: leave the stale hash so the next
      # real `den up` does the kickstart.
      if [ "${VM_UP_AGENT:-}" != 1 ]; then
        if launchctl kickstart -k "gui/$(id -u)/$label" >/dev/null 2>&1; then
          printf '%s\n' "$hash" >"$hashfile" 2>/dev/null || true
          ui_info "vm-up login agent restarted (vm-up.sh changed)"
        fi
      fi
    fi
    return 0
  fi

  if [ "$loaded" = 1 ]; then
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$new" >"$plist"
  if launchctl bootstrap "gui/$(id -u)" "$plist"; then
    if [ -n "$hash" ]; then
      printf '%s\n' "$hash" >"$hashfile" 2>/dev/null || true
    fi
    ui_ok "vm-up login agent loaded ($plist)"
  else
    ui_warn "could not load $plist; run: launchctl bootstrap gui/$(id -u) $plist"
  fi
}

# ── vm-backup ────────────────────────────────────────────────────────
# The repo: VM_BACKUP_REPO, else den-vm-backup in the first OneDrive folder.
# Empty when neither exists.
den_vm_backup_repo() {
  local d
  if [ -n "${VM_BACKUP_REPO:-}" ]; then
    printf '%s' "$VM_BACKUP_REPO"
    return 0
  fi
  for d in "$HOME"/Library/CloudStorage/OneDrive-*; do
    if [ -d "$d" ]; then
      printf '%s/den-vm-backup' "$d"
      return 0
    fi
  done
  return 0
}

den_vm_backup_state() {
  printf '%s' "${VM_BACKUP_STATE:-$HOME/.local/state/den/vm-backup}"
}

den_vm_rex_cli() {
  local cand
  if [ -n "${REX_CLI:-}" ] && [ -x "${REX_CLI}" ]; then
    printf '%s' "$REX_CLI"
    return 0
  fi
  for cand in \
    "$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex" \
    "$HOME/Applications/Rex.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex" \
    "$HOME/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex" \
    "/Applications/Rex.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex" \
    "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"; do
    if [ -x "$cand" ]; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

# ── den vm ───────────────────────────────────────────────────────────
den_cmd_vm() {
  local sub=${1:-status}
  if [ $# -gt 0 ]; then
    shift
  fi
  den_config_load
  case $sub in
    resources) den_vm_resources && den_vm_resources_line ;;
    up) den_vm_up "$@" ;;
    down) den_vm_down "$@" ;;
    shell) den_vm_shell "$@" ;;
    status) den_vm_show "$@" ;;
    logs) den_vm_logs "$@" ;;
    rebuild) den_vm_rebuild "$@" ;;
    obsidian-sync) den_vm_obsidian_sync "$@" ;;
    backup) den_vm_backup "$@" ;;
    restore) den_vm_restore "$@" ;;
    *) den_die "usage: den vm resources|up|down|shell|status|logs|rebuild|obsidian-sync|backup|restore" ;;
  esac
}

den_vm_up() {
  local vm=${AGENT_VM:-} s
  if [ $# -gt 0 ]; then
    den_die "den vm up takes no arguments"
  fi
  if [ -z "$vm" ]; then
    den_die "AGENT_VM is empty in config.env"
  fi
  if ! command -v limactl >/dev/null 2>&1; then
    den_die "limactl is not installed (brew install lima)"
  fi
  if ! limactl autostart enable "$vm" --tty=false; then
    ui_warn "could not register $vm for autostart; run: limactl autostart enable $vm"
  fi
  den_vm_up_agent
  s=$(den_vm_status "$vm") || s=""
  if [ "$s" = Running ]; then
    ui_ok "$vm is Running"
    return 0
  fi
  ui_step "starting $vm"
  if den_vm_to 660 limactl start "$vm" --tty=false --timeout 10m; then
    ui_ok "$vm started"
  else
    ui_warn "could not start $vm; run: limactl start $vm"
  fi
}

# den_vm_stop <vm>: stop the VM and never hang. A graceful `limactl stop`
# first. On 2026-11-19 that once hung in the host agent's `ssh -O exit` and
# left the VM running under a half-dead host agent, so if it fails or the VM
# still answers: the guest powers itself off, then `limactl stop -f` cleans up
# only the host processes. Returns 0 when the VM is down; an empty status is
# unknown (limactl could not answer), never "stopped", so it returns 1.
# den_vm_hostagents_reap <vm>: once the VM is down, no host agent of this
# instance may live on. A stop that timed out half-way has left one behind
# (2026-11-19, twice), and a later start then runs next to it.
den_vm_hostagents_reap() {
  local vm=$1 pids
  pids=$(pgrep -f -- "limactl hostagent --pidfile $HOME/.lima/$vm/ha.pid" 2>/dev/null) || pids=""
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086  # one PID per word
  kill $pids 2>/dev/null || true
  sleep 2
  pids=$(pgrep -f -- "limactl hostagent --pidfile $HOME/.lima/$vm/ha.pid" 2>/dev/null) || pids=""
  # shellcheck disable=SC2086
  [ -z "$pids" ] || kill -9 $pids 2>/dev/null || true
  ui_info "cleaned up a leftover host agent of $vm"
}

den_vm_stop() {
  local vm=$1 s=""
  if den_vm_to 60 limactl stop "$vm" --tty=false >/dev/null 2>&1; then
    s=$(den_vm_status "$vm") || s=""
    if [ -z "$s" ]; then
      return 1
    fi
    if [ "$s" != Running ]; then
      den_vm_hostagents_reap "$vm"
      return 0
    fi
  fi
  den_vm_to 20 limactl shell "$vm" -- sudo -n systemctl poweroff </dev/null >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if ! den_vm_to 5 limactl shell "$vm" -- true </dev/null >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
  den_vm_to 60 limactl stop -f "$vm" --tty=false >/dev/null 2>&1 || true
  s=$(den_vm_status "$vm") || s=""
  if [ -n "$s" ] && [ "$s" != Running ]; then
    den_vm_hostagents_reap "$vm"
    return 0
  fi
  return 1
}


# Stop the login agent and autostart BEFORE the VM, so nothing brings it back.
den_vm_down() {
  local vm=${AGENT_VM:-} s
  if [ $# -gt 0 ]; then
    den_die "den vm down takes no arguments"
  fi
  if [ -z "$vm" ]; then
    den_die "AGENT_VM is empty in config.env"
  fi
  launchctl bootout "gui/$(id -u)/$DEN_VM_LABEL" >/dev/null 2>&1 || true
  ui_info "vm-up login agent stopped"
  if ! command -v limactl >/dev/null 2>&1; then
    ui_warn "limactl is not installed"
    return 0
  fi
  den_vm_to 30 limactl autostart disable "$vm" --tty=false >/dev/null 2>&1 || true
  s=$(den_vm_status "$vm") || s=""
  case $s in
    Running)
      if den_vm_stop "$vm"; then
        ui_ok "$vm stopped"
      else
        ui_warn "could not stop $vm; run: limactl stop -f $vm"
      fi
      ;;
    '') ui_info "$vm does not exist" ;;
    *) ui_info "$vm is already $s" ;;
  esac
}

den_vm_shell() {
  if [ $# -gt 0 ]; then
    den_die "den vm shell takes no arguments"
  fi
  if [ -z "${AGENT_VM:-}" ]; then
    den_die "AGENT_VM is empty in config.env"
  fi
  if ! command -v limactl >/dev/null 2>&1; then
    den_die "limactl is not installed (brew install lima)"
  fi
  exec limactl shell "$AGENT_VM"
}

den_vm_show() {
  local vm=${AGENT_VM:-} s relay tunnel agent
  if [ $# -gt 0 ]; then
    den_die "den vm status takes no arguments"
  fi
  if ! command -v limactl >/dev/null 2>&1; then
    printf 'vm: limactl is not installed\n'
    return 0
  fi
  s=$(den_vm_status "$vm") || s=""
  printf 'vm: %s\n' "${s:-missing}"
  if curl --noproxy '*' -fsS -m 3 "http://127.0.0.1:$DEN_VM_PORT/version" >/dev/null 2>&1; then
    relay=up
  else
    relay=down
  fi
  printf 'relay: %s\n' "$relay"
  tunnel=n/a
  if [ "${s:-}" = Running ]; then
    if den_vm_to 15 limactl shell "$vm" -- curl --noproxy '*' -fsS -m 3 "http://127.0.0.1:$DEN_VM_PORT/version" >/dev/null 2>&1; then
      tunnel=up
    else
      tunnel=down
    fi
  fi
  printf 'tunnel: %s\n' "$tunnel"
  if launchctl print "gui/$(id -u)/$DEN_VM_LABEL" >/dev/null 2>&1; then
    agent=loaded
  else
    agent="not loaded"
  fi
  printf 'agent: %s\n' "$agent"
  if [ -n "${s:-}" ]; then
    den_vm_backup_line
  fi
}

den_vm_logs() {
  local file="$HOME/.local/state/rex-vm/vm-up.log"
  if [ $# -gt 0 ]; then
    den_die "den vm logs takes no arguments"
  fi
  if [ ! -f "$file" ]; then
    ui_info "no log yet at $file"
    return 0
  fi
  tail -n 100 "$file"
}

den_vm_rebuild() {
  local vm=${AGENT_VM:-} yes=0 answer=""
  while [ $# -gt 0 ]; do
    case $1 in
      --yes|-y) yes=1 ;;
      *) den_die "usage: den vm rebuild [--yes]" ;;
    esac
    shift
  done
  if [ -z "$vm" ]; then
    den_die "AGENT_VM is empty in config.env"
  fi
  if [ "$yes" != 1 ]; then
    answer=$(ui_input "type the VM name ($vm) to delete and rebuild it" "")
    if [ "$answer" != "$vm" ]; then
      ui_info "aborted: $answer is not $vm"
      return 0
    fi
  fi
  launchctl bootout "gui/$(id -u)/$DEN_VM_LABEL" >/dev/null 2>&1 || true
  if command -v limactl >/dev/null 2>&1; then
    den_vm_to 30 limactl autostart disable "$vm" --tty=false >/dev/null 2>&1 || true
    den_vm_stop "$vm" || true
    den_vm_to 120 limactl delete "$vm" --force --tty=false >/dev/null 2>&1 || true
  fi
  ui_step "rebuilding $vm with the vm and vm-mcp phases"
  "${DEN_ROOT}/bin/den" up --only=vm,vm-mcp
}

# den vm obsidian-sync: restart the guest's obsidian-sync user service.
den_vm_obsidian_sync() {
  local vm=${AGENT_VM:-} s=""
  if [ $# -gt 0 ]; then
    den_die "den vm obsidian-sync takes no arguments"
  fi
  if [ -z "$vm" ]; then
    den_die "AGENT_VM is empty in config.env"
  fi
  if ! command -v limactl >/dev/null 2>&1; then
    den_die "limactl is not installed (brew install lima)"
  fi
  s=$(den_vm_status "$vm") || s=""
  if [ "$s" != Running ]; then
    den_die "$vm is not Running; run: den vm up"
  fi
  if den_vm_to 60 limactl shell "$vm" -- systemctl --user restart obsidian-sync.service </dev/null; then
    ui_ok "obsidian-sync.service restarted in $vm"
  else
    den_die "could not restart obsidian-sync.service in $vm; check it with: den vm shell, then systemctl --user status obsidian-sync.service"
  fi
}

# den vm backup | restore: run vm/vm-backup.sh in the foreground. The restic
# password is vm.backup_password in the den bundle, loaded the way den up loads
# it (recorded file, ~/den.json, or a 1Password prompt) and gone when the run
# ends.
den_vm_backup_run() { # den_vm_backup_run [--restore]
  local own=0 rc=0
  if [ -z "${AGENT_VM:-}" ]; then
    den_die "AGENT_VM is empty in config.env"
  fi
  if [ -z "${DEN_SECRETS_FILE:-}" ] || [ ! -r "${DEN_SECRETS_FILE:-}" ]; then
    if [ -z "${DEN_RUNTIME:-}" ]; then
      den_runtime_init
      own=1
    fi
    den_secrets_load
  fi
  AGENT_VM="$AGENT_VM" VM_BACKUP_REPO="${VM_BACKUP_REPO:-}" "${DEN_ROOT}/vm/vm-backup.sh" "$@" || rc=$?
  if [ "$own" = 1 ]; then
    den_runtime_cleanup
  fi
  return "$rc"
}

den_vm_backup() {
  if [ $# -gt 0 ]; then
    den_die "den vm backup takes no arguments"
  fi
  den_vm_backup_run
}

den_vm_restore() {
  if [ $# -gt 0 ]; then
    den_die "den vm restore takes no arguments"
  fi
  den_vm_backup_run --restore
}

# One status line for the last finished backup. A warning when none finished
# or the last one is over 14 days old.
den_vm_backup_line() {
  local f last
  f="$(den_vm_backup_state)/last-ok"
  if [ ! -s "$f" ]; then
    printf 'vm: backup has not finished yet (fix: den vm backup)\n'
    return 0
  fi
  last=$(cut -c1-10 "$f" 2>/dev/null || true)
  if find "$f" -mmin +20160 2>/dev/null | grep -q .; then
    printf 'vm: backup is old, last %s (fix: den vm backup)\n' "$last"
    return 0
  fi
  printf 'vm: backup OK (last %s)\n' "$last"
}

# ── Doctor ───────────────────────────────────────────────────────────
# Returns 1 when the VM is expected (DEN_VM on) and is not Running.
den_doctor_vm() {
  local vm s out line disk port leak=0
  den_config_load
  vm=${AGENT_VM:-}
  if [ "$(den_os)" != macos ]; then
    return 0
  fi
  if ! command -v limactl >/dev/null 2>&1; then
    printf 'vm: limactl is not installed (brew install lima)\n'
    return 0
  fi
  if [ -z "$vm" ]; then
    printf 'vm: AGENT_VM is empty in config.env\n'
    return 0
  fi
  s=$(den_vm_status "$vm") || s=""
  printf 'vm: %s\n' "${s:-missing}"
  if [ -n "${s:-}" ]; then
    den_vm_backup_line
  fi
  if [ "${s:-}" != Running ]; then
    if den_toggle_on DEN_VM; then
      printf 'vm: the VM is expected but not Running (fix: den vm up)\n'
      return 1
    fi
    return 0
  fi
  if curl --noproxy '*' -fsS -m 3 "http://127.0.0.1:$DEN_VM_PORT/version" >/dev/null 2>&1; then
    printf 'vm: browse relay OK\n'
  else
    printf 'vm: browse relay down (vm-up starts it within a minute)\n'
  fi
  # The probe target: the instance's own SSH forward, which always listens on
  # the Mac's 127.0.0.1 while the VM runs. den_vm_field does not read it.
  port=$(den_vm_json "$vm" | sed -n 's/.*"sshLocalPort"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p') || port=""
  case $port in *[!0-9]*) port="" ;; esac
  out=$(den_vm_to 60 limactl shell "$vm" -- bash -s -- "$port" 2>/dev/null <<'PROBE'
docker info >/dev/null 2>&1 && echo docker=ok || echo docker=down
docker compose version >/dev/null 2>&1 && echo compose=ok || echo compose=down
rex server status >/dev/null 2>&1 && echo rex=ok || echo rex=down
systemctl --user is-active --quiet obsidian-sync.service && echo obsidian=ok || echo obsidian=down
c="$HOME/.local/bin/claude"; [ -x "$c" ] || c=$(command -v claude 2>/dev/null || true)
if [ -z "$c" ]; then echo mcp=noclaude
elif "$c" mcp get superlogical >/dev/null 2>&1; then echo mcp=ok; else echo mcp=missing; fi
b=$(command -v browse 2>/dev/null || true)
if [ -n "$b" ] && [ -x "$b" ]; then echo browse=ok; else echo browse=down; fi
u=$(df -Pk / | sed -n "2s/.* \([0-9]*\)% .*/\1/p")
echo "disk=${u:-?}"
if [ -z "$1" ]; then echo hostloop=unknown
elif timeout 3 bash -c 'exec 3<>/dev/tcp/host.lima.internal/$1' _ "$1" >/dev/null 2>&1; then echo hostloop=open
else echo hostloop=closed; fi
PROBE
  ) || out=""
  if [ -z "$out" ]; then
    printf 'vm: guest probe timed out or failed\n'
    return 0
  fi
  while IFS= read -r line; do
    case $line in
      docker=ok) printf 'vm: docker OK\n' ;;
      docker=*) printf 'vm: docker failed (fix: limactl shell %s -- sudo systemctl start docker)\n' "$vm" ;;
      compose=ok) printf 'vm: docker compose OK\n' ;;
      compose=*) printf 'vm: docker compose failed (fix: rerun den up --only=vm)\n' ;;
      rex=ok) printf 'vm: rex server OK\n' ;;
      rex=*) printf 'vm: rex server down (fix: den up --only=vm)\n' ;;
      obsidian=ok) printf 'vm: obsidian-sync OK\n' ;;
      obsidian=*) printf 'vm: obsidian-sync inactive (fix: limactl shell %s -- systemctl --user start obsidian-sync)\n' "$vm" ;;
      mcp=ok) printf 'vm: superlogical MCP OK\n' ;;
      # den fix cannot help here: vm-mcp would only skip. Point at the vm phase.
      mcp=noclaude) printf 'vm: Claude Code missing in the guest (fix: den up --only=vm)\n' ;;
      mcp=*)
        if den_toggle_on DEN_VM; then
          printf 'vm: superlogical MCP missing in the guest (fix: den fix)\n'
          den_fix_wants vm-mcp
        fi
        ;;
      browse=ok) printf 'vm: browse CLI OK\n' ;;
      browse=*) printf 'vm: browse CLI missing (fix: den up --only=vm)\n' ;;
      hostloop=unknown) printf 'vm: host loopback not checked (no Lima SSH port)\n' ;;
      hostloop=closed) printf 'vm: host loopback blocked\n' ;;
      hostloop=open)
        printf 'vm: host loopback reachable from the guest (escape U1; fix: limactl stop %s && den up --only=vm)\n' "$vm"
        leak=1
        ;;
      disk=*)
        disk=${line#disk=}
        disk=${disk%\%}
        case $disk in
          ''|*[!0-9]*|'?') printf 'vm: guest disk use unknown\n' ;;
          *)
            if [ "$disk" -gt 90 ]; then
              printf 'vm: guest disk is %s%% full (fix: limactl shell %s -- docker system prune)\n' "$disk" "$vm"
            else
              printf 'vm: guest disk %s%%\n' "$disk"
            fi
            ;;
        esac
        ;;
    esac
  done <<<"$out"
  printf 'vm: Rex.app host is ssh://lima-%s (once: Cmd-Shift-P > Add Remote Host..., then Switch Host)\n' "$vm"
  [ "$leak" = 0 ] || return 1
  return 0
}

# ── Preflight hook ───────────────────────────────────────────────────
# Sign in the guest's gh and ob before the unattended phases run. Never
# without a TTY; nothing here is needed when the vm phase is not selected.
# A `limactl shell` command gets no Homebrew and no mise on PATH (zsh itself
# lives in Homebrew). Prefix every guest command that needs them with this.
# shellcheck disable=SC2016  # expanded in the guest.
DEN_GUEST_ENV='eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv 2>/dev/null)" 2>/dev/null; export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$HOME/.opencode/bin:/usr/local/bin:$PATH"; '

den_preflight_hook_vm() {
  local idx=""
  if [ "$(den_os)" != macos ]; then
    return 0
  fi
  idx=$(den_phase_index vm) || return 0
  if ! den_phase_selected "$idx"; then
    return 0
  fi
  den_is_tty || return 0
  if ! command -v limactl >/dev/null 2>&1; then
    return 0
  fi
  if [ -z "${AGENT_VM:-}" ]; then
    return 0
  fi
  if den_vm_to 20 limactl shell "$AGENT_VM" -- bash -c \
    "${DEN_GUEST_ENV}command -v gh >/dev/null 2>&1 && ! gh auth status --active --hostname github.com >/dev/null 2>&1" >/dev/null 2>&1; then
    ui_info "vm: gh is not signed in inside $AGENT_VM; starting gh auth login"
    if ! den_vm_to 600 limactl shell --tty=true "$AGENT_VM" -- bash -c \
      "${DEN_GUEST_ENV}gh auth login --web --git-protocol https && gh auth setup-git"; then
      ui_warn "vm: gh auth login did not finish; the guest still works without it"
    fi
  fi
  # The guest's gh may hold only the work account; the private config repos
  # need their owner's login next to it (see lib/phases/48-config-repos.sh).
  # gh makes a new login active, so the previous account gets the slot back.
  local owner="" q=""
  if declare -F config_repos_gh_user >/dev/null && owner=$(config_repos_gh_user); then
    q=$(printf '%q' "$owner")
    if den_vm_to 20 limactl shell "$AGENT_VM" -- bash -c \
      "${DEN_GUEST_ENV}command -v gh >/dev/null 2>&1 && gh auth status --active --hostname github.com >/dev/null 2>&1 && ! { t=\$(gh auth token --hostname github.com --user $q 2>/dev/null) && [ \"\$(GH_TOKEN=\$t gh api user -q .login 2>/dev/null)\" = $q ]; }" >/dev/null 2>&1; then
      ui_info "vm: the guest's gh has no working $owner login (it owns the config repos); sign in as $owner"
      if ! den_vm_to 600 limactl shell --tty=true "$AGENT_VM" -- bash -c \
        "${DEN_GUEST_ENV}active=\$(gh api user -q .login 2>/dev/null); gh auth login --hostname github.com --web --git-protocol https || exit 1; if [ -n \"\$active\" ] && [ \"\$active\" != $q ]; then gh auth switch --hostname github.com --user \"\$active\" >/dev/null; fi"; then
        ui_warn "vm: gh auth login as $owner did not finish; the guest's private config repos will fail"
      fi
    fi
  fi
  if den_vm_to 20 limactl shell "$AGENT_VM" -- bash -c \
    "${DEN_GUEST_ENV}command -v ob >/dev/null 2>&1 && ! ob sync-list-remote --json >/dev/null 2>&1" >/dev/null 2>&1; then
    ui_info "vm: Obsidian Headless is not signed in; starting ob login (email, password, 2FA)"
    if ! den_vm_to 600 limactl shell --tty=true "$AGENT_VM" -- bash -c "${DEN_GUEST_ENV}ob login"; then
      ui_warn "vm: ob login did not finish; vault sync is skipped"
    fi
  fi
  # First vault setup is interactive too: an end-to-end-encrypted vault asks
  # for its password. The vm phase then applies the sync config unattended.
  if den_vm_to 20 limactl shell "$AGENT_VM" -- bash -c \
    "${DEN_GUEST_ENV}command -v ob >/dev/null 2>&1 && ob sync-list-remote --json >/dev/null 2>&1 && [ ! -d \"\$HOME/Developer/obsidian/.obsidian\" ] && ! ob sync-status --path \"\$HOME/Developer/obsidian\" >/dev/null 2>&1" >/dev/null 2>&1; then
    local vault=${OBSIDIAN_SYNC_VAULT:-}
    if [ -z "$vault" ]; then
      local remotes="" line="" vaults=()
      remotes=$(den_vm_to 30 limactl shell "$AGENT_VM" -- bash -c "${DEN_GUEST_ENV}ob sync-list-remote --json" 2>/dev/null |
        jq -r '(.vaults // .)[]? | (.name // empty)' 2>/dev/null) || remotes=""
      # One name per line: a vault name may hold spaces or quotes.
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        vaults[${#vaults[@]}]=$line
      done <<<"$remotes"
      if [ "${#vaults[@]}" -eq 1 ]; then
        vault=${vaults[0]}
      elif [ "${#vaults[@]}" -gt 1 ]; then
        vault=$(ui_choose "Which Obsidian vault should the VM sync?" "${vaults[@]}")
      fi
    fi
    if [ -n "$vault" ]; then
      ui_info "vm: setting up Obsidian Sync for vault '$vault' in ~/Developer/obsidian"
      # The name travels in the environment: no quoting reaches the guest shell.
      den_vm_to 600 limactl shell --tty=true "$AGENT_VM" -- env OBSIDIAN_VAULT="$vault" bash -c \
        "${DEN_GUEST_ENV}mkdir -p \"\$HOME/Developer\" && ob sync-setup --vault \"\$OBSIDIAN_VAULT\" --path \"\$HOME/Developer/obsidian\" --device-name '$AGENT_VM'" ||
        ui_warn "vm: ob sync-setup did not finish; run it later with: den vm shell, then ob sync-setup"
    fi
  fi
  return 0
}
