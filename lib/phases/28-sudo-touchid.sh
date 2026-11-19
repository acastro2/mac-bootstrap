# shellcheck shell=bash
# 28-sudo-touchid.sh — Touch ID for sudo, with pam_reattach so it also works
# inside tmux and ssh sessions.

den_phase sudo-touchid \
  --title "Touch ID for sudo" \
  --about "pam_tid plus pam_reattach, so a finger works inside tmux and ssh" \
  --os macos \
  --toggle DEN_TOUCHID_SUDO \
  --needs "sudo brew"

phase_sudo_touchid() {
  local target=${DEN_PAM_SUDO_LOCAL:-/etc/pam.d/sudo_local}
  local prefix module desired current tmp

  prefix=$(brew --prefix pam-reattach 2>/dev/null) || prefix=""
  module=$prefix/lib/pam/pam_reattach.so
  if [ -z "$prefix" ] || [ ! -f "$module" ]; then
    ui_step "installing pam-reattach"
    brew install pam-reattach </dev/null || den_fail "pam-reattach is not installed" \
      "brew install pam-reattach, then den up --only=sudo-touchid"
    prefix=$(brew --prefix pam-reattach 2>/dev/null) || prefix=""
    module=$prefix/lib/pam/pam_reattach.so
  fi
  if [ ! -f "$module" ]; then
    den_fail "pam_reattach.so is missing at $module" \
      "brew reinstall pam-reattach, then den up --only=sudo-touchid"
  fi

  # pam_reattach first: it reattaches sudo to the GUI session, then pam_tid asks
  # for the finger.
  desired=$(printf 'auth optional %s ignore_ssh\nauth sufficient pam_tid.so\n' "$module")
  current=""
  if [ -f "$target" ]; then
    current=$(cat "$target")
  fi
  if [ "$current" = "$desired" ]; then
    ui_ok "Touch ID for sudo is already set in $target"
    return 0
  fi

  tmp=$(mktemp "${TMPDIR:-/tmp}/den-sudo-local.XXXXXX")
  printf '%s\n' "$desired" > "$tmp"
  if ! sudo install -m 444 "$tmp" "$target"; then
    rm -f "$tmp"
    den_fail "could not write $target" \
      "sudo install -m 444 <the sudo_local file> $target"
  fi
  rm -f "$tmp"
  if [ ! -f "$target" ]; then
    den_fail "$target does not exist after the write" \
      "check the permissions on $(dirname "$target"), then den up --only=sudo-touchid"
  fi
  ui_ok "Touch ID for sudo is on ($target)"
}
