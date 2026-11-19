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
  local prefix module desired current tmp line rest bad stamp foreign fix

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

  # visudo validates sudoers, not PAM. Every active line must be an auth rule
  # for one of the two modules above; anything else could lock sudo out.
  bad=""
  while IFS= read -r line; do
    case $line in
      ''|'#'*) continue ;;
    esac
    case $line in
      auth[[:space:]]*) ;;
      *) bad=$line; break ;;
    esac
    case $line in
      *pam_reattach.so*|*pam_tid.so*) ;;
      *) bad=$line; break ;;
    esac
    rest=${line//pam_reattach.so/}
    rest=${rest//pam_tid.so/}
    case $rest in
      *.so*) bad=$line; break ;;
    esac
  done < "$tmp"
  if [ -n "$bad" ]; then
    rm -f "$tmp"
    den_fail "the sudo_local rule is not a safe PAM line: $bad" \
      "fix den's pam_reattach and pam_tid lines, then den up --only=sudo-touchid"
  fi

  # An active line den does not own: replacing the file would drop that rule,
  # so keep the file and ask for den's two lines by hand instead.
  foreign=""
  if [ -f "$target" ]; then
    while IFS= read -r line; do
      case $line in
        ''|'#'*) continue ;;
      esac
      case $line in
        *pam_reattach.so*|*pam_tid.so*) ;;
        *) foreign="$foreign${foreign:+, }$line" ;;
      esac
    done < "$target"
  fi
  if [ -n "$foreign" ]; then
    rm -f "$tmp"
    ui_info "add den's two lines to $target by hand:"
    printf '%s\n' "$desired"
    fix="keep $target as it is and append by hand: auth optional $module ignore_ssh; auth sufficient pam_tid.so"
    den_skip "$target already has rules den does not own: $foreign" "$fix"
  fi

  # Keep the file den replaces: a PAM typo can lock sudo out for good.
  if [ -f "$target" ]; then
    stamp=$(date +%Y%m%d-%H%M%S)
    if ! sudo cp -p "$target" "$target.bak.$stamp"; then
      rm -f "$tmp"
      den_fail "could not back up $target" \
        "check write access to $(dirname "$target"), then den up --only=sudo-touchid"
    fi
    ui_info "kept the previous $target as $target.bak.$stamp"
  fi
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
