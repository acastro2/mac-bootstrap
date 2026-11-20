# shellcheck shell=bash
# lib/phases/74-vm-backup.sh — the encrypted off-Mac copy of the agent VM:
# the restic repo in OneDrive. `den vm backup` runs vm/vm-backup.sh by hand;
# this phase only creates the repo. The password is vm.backup_password in the
# den bundle. Bash 3.2.
# Contract: docs/den/CONTRACT.md ("CLI", "VM guest").
# shellcheck disable=SC2154  # AGENT_VM, DEN_ROOT come from config/lib.

den_phase vm-backup \
  --title "VM backup (restic)" \
  --about "encrypted copy of the VM into OneDrive, run by hand: restic repo" \
  --os macos \
  --toggle DEN_VM \
  --needs "secrets"

phase_vm_backup() {
  local vm=${AGENT_VM:-} repo="" pw="" cmd

  if [ -z "$vm" ]; then
    den_skip "AGENT_VM is empty in config.env" "set AGENT_VM in config.env"
  fi
  if ! command -v restic >/dev/null 2>&1; then
    den_skip "restic is not installed" "brew install restic"
  fi
  repo=$(den_vm_backup_repo)
  if [ -z "$repo" ]; then
    den_skip "no OneDrive folder and VM_BACKUP_REPO is empty" "sign in to OneDrive, or set VM_BACKUP_REPO in config.env, then den up --only=vm-backup"
  fi
  pw=$(den_secret .vm.backup_password)
  if [ -z "$pw" ]; then
    den_skip "the den bundle has no vm.backup_password" "add vm.backup_password to the den document (openssl rand -base64 32), then den up --only=vm-backup"
  fi

  pw=""
  # restic runs this command without a shell; only the bundle's path rides argv.
  cmd="jq -r .vm.backup_password ${DEN_SECRETS_FILE:-}"
  if [ ! -f "$repo/config" ]; then
    if ! mkdir -p "$repo"; then
      den_fail "could not create $repo" "check the OneDrive folder, then den up --only=vm-backup"
    fi
    if RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD_COMMAND="$cmd" restic init >/dev/null 2>&1; then
      ui_ok "restic repo created at $repo"
    else
      den_fail "could not create the restic repo at $repo" "check the path, then den up --only=vm-backup"
    fi
  elif ! RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD_COMMAND="$cmd" restic cat config >/dev/null 2>&1; then
    den_fail "the restic repo at $repo does not open with the den password" "fix vm.backup_password in the den document, then den up --only=vm-backup"
  else
    ui_info "restic repo at $repo opens with the den password"
  fi
}
