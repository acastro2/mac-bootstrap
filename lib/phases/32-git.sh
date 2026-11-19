# shellcheck shell=bash
# 32-git.sh — global git defaults and identity.

den_phase git \
  --title "Git config" \
  --about "Global git defaults: branch, rebase, rerere, and your identity" \
  --os any

# Set one key only when it has no value, so a local choice survives.
den_git_default() {
  local key=$1 value=$2 current
  current=$(git config --global --get "$key" 2>/dev/null) || current=""
  if [ -n "$current" ]; then
    return 0
  fi
  if ! git config --global "$key" "$value"; then
    den_fail "could not set git $key" "git config --global $key $value"
  fi
  ui_step "git config $key = $value"
}

# Set identity from config.env when it differs; an empty key keeps the current.
den_git_identity() {
  local key=$1 value=$2 current
  if [ -z "$value" ]; then
    return 0
  fi
  current=$(git config --global --get "$key" 2>/dev/null) || current=""
  if [ "$current" = "$value" ]; then
    return 0
  fi
  if ! git config --global "$key" "$value"; then
    den_fail "could not set git $key" "git config --global $key \"$value\""
  fi
  ui_step "git config $key = $value"
}

phase_git() {
  if ! command -v git >/dev/null 2>&1; then
    den_skip "git is not installed" "brew install git, then run den up --only=git"
  fi
  den_git_default init.defaultBranch main
  den_git_default pull.rebase true
  den_git_default rerere.enabled true
  if [ -z "${GIT_NAME:-}" ] && [ -z "${GIT_EMAIL:-}" ]; then
    ui_info "GIT_NAME and GIT_EMAIL are not set; keeping the current identity"
  else
    den_git_identity user.name "${GIT_NAME:-}"
    den_git_identity user.email "${GIT_EMAIL:-}"
  fi
  ui_ok "git globals are set"
}
