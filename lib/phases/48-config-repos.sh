# shellcheck shell=bash
# lib/phases/48-config-repos.sh — the private config repos behind OpenCode,
# Claude Code and the shared agent skills.
# Contract: docs/den/CONTRACT.md ("Host vs VM").

den_phase config-repos \
  --title "Config repos" \
  --about "OpenCode, Claude Code and agent skills checked out where the tools read them" \
  --os any \
  --needs "gh net"

# ── Which GitHub account ─────────────────────────────────────────────
# The config repos are private to their owner, who need not be the account gh
# has active: a work Mac (and its VM) is signed in as the work account too, and
# `gh repo clone` only ever uses the active one. gh keeps several accounts per
# host, so den takes the owner's token for these repos alone and never changes
# which account is active.
# CONFIG_REPOS_GH_USER overrides the owner (e.g. repos under an org).

# config_repos_gh_user: the account that owns the gh-mode config repos.
config_repos_gh_user() {
  local r=""
  if [ -n "${CONFIG_REPOS_GH_USER:-}" ]; then
    printf '%s' "$CONFIG_REPOS_GH_USER"
    return 0
  fi
  for r in "${OPENCODE_CONFIG_REPO:-}" "${CLAUDE_CONFIG_REPO:-}"; do
    if [ -n "$r" ]; then
      printf '%s' "${r%%/*}"
      return 0
    fi
  done
  return 1
}

# config_repos_token <user>: print that account's working gh token. Returns 1
# when gh has no login for it, 2 when the stored token is dead: GitHub revokes
# the oldest once an account logs in to gh many times (every Mac and VM login
# is one), so it is checked, not trusted.
config_repos_token() {
  local t=""
  t=$(gh auth token --hostname github.com --user "$1" 2>/dev/null | head -n 1) || t=""
  if [ -z "$t" ]; then
    return 1
  fi
  if [ "$(GH_TOKEN=$t den_with_timeout 15 gh api user -q .login 2>/dev/null)" != "$1" ]; then
    return 2
  fi
  printf '%s' "$t"
}

# config_repo_gh <gh args...>: gh as the owner (CONFIG_REPOS_TOKEN, when set).
config_repo_gh() {
  if [ -n "${CONFIG_REPOS_TOKEN:-}" ]; then
    GH_TOKEN=$CONFIG_REPOS_TOKEN gh "$@"
  else
    gh "$@"
  fi
}

# config_repo_git <gh|url> <git args...>: git that talks to github.com as the
# owner for gh-mode repos. The usual credential helper answers with the active
# account (or a keychain entry), so it is replaced for these calls only.
config_repo_git() {
  local mode=$1
  shift
  if [ "$mode" = gh ] && [ -n "${CONFIG_REPOS_TOKEN:-}" ]; then
    GH_TOKEN=$CONFIG_REPOS_TOKEN GIT_TERMINAL_PROMPT=0 git -c credential.helper= \
      -c 'credential.https://github.com.helper=!gh auth git-credential' "$@"
  else
    GIT_TERMINAL_PROMPT=0 git "$@"
  fi
}

# Preflight: add the owner's login next to the active one, once, up front.
den_preflight_hook_config_repos() {
  local idx="" user="" active=""
  idx=$(den_phase_index config-repos) || return 0
  den_phase_selected "$idx" || return 0
  den_is_tty || return 0
  command -v gh >/dev/null 2>&1 || return 0
  user=$(config_repos_gh_user) || return 0
  if [ -n "$(config_repos_token "$user")" ]; then
    return 0
  fi
  active=$(gh api user -q .login 2>/dev/null || true)
  ui_info "config-repos: the config repos belong to $user, and gh has no working $user login; sign in as $user in the browser"
  if ! gh auth login --hostname github.com --web --git-protocol https; then
    ui_warn "config-repos: gh auth login did not finish; the private config repos will fail"
    return 0
  fi
  # gh makes a new login active; give the slot back to the account that had it.
  if [ -n "$active" ] && [ "$active" != "$user" ]; then
    gh auth switch --hostname github.com --user "$active" >/dev/null 2>&1 || true
  fi
}

# config_repo_clone <label> <source> <dir> <gh|url>
config_repo_clone() {
  local label=$1 src=$2 dir=$3 mode=$4 out=""
  ui_step "cloning $label into $dir"
  mkdir -p "$(dirname "$dir")"
  if [ "$mode" = gh ]; then
    if ! out=$(config_repo_gh repo clone "$src" "$dir" 2>&1); then
      ui_err "$label: clone failed"
      printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /' >&2 || true
      return 1
    fi
  else
    if ! out=$(GIT_TERMINAL_PROMPT=0 git clone "$src" "$dir" 2>&1); then
      ui_err "$label: clone failed"
      printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /' >&2 || true
      return 1
    fi
  fi
  ui_ok "$label: cloned into $dir"
  return 0
}

# config_repo_adopt <label> <source> <dir> <gh|url>
# The tool creates its config dir on first launch, so a plain clone would
# fail on a fresh Mac. Adopt in place: copy in the repo's .git, back up every
# local file the checkout would overwrite, and leave sessions and caches be.
config_repo_adopt() {
  local label=$1 src=$2 dir=$3 mode=$4 tmp="" backup="" f="" out=""
  ui_step "$dir already exists; adopting $label in place"
  tmp=$(mktemp -d) || return 1
  if [ "$mode" = gh ]; then
    out=$(config_repo_gh repo clone "$src" "$tmp/repo" -- --no-checkout 2>&1) || {
      ui_err "$label: clone failed"
      printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /' >&2 || true
      rm -rf "$tmp"
      return 1
    }
  else
    out=$(GIT_TERMINAL_PROMPT=0 git clone --no-checkout "$src" "$tmp/repo" 2>&1) || {
      ui_err "$label: clone failed"
      printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /' >&2 || true
      rm -rf "$tmp"
      return 1
    }
  fi
  if ! git -C "$tmp/repo" ls-tree -r --name-only HEAD >"$tmp/files" 2>/dev/null; then
    ui_err "$label: could not list the repo's files"
    rm -rf "$tmp"
    return 1
  fi
  backup="$dir.pre-clone-$(date +%Y%m%d-%H%M%S)"
  if ! while IFS= read -r f; do
    if [ -e "$dir/$f" ]; then
      mkdir -p "$backup/$(dirname "$f")"
      cp -p "$dir/$f" "$backup/$f"
    fi
  done <"$tmp/files"; then
    ui_err "$label: could not back up $dir"
    rm -rf "$tmp"
    return 1
  fi
  if ! mv "$tmp/repo/.git" "$dir/.git"; then
    ui_err "$label: could not adopt $dir"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  if ! git -C "$dir" reset --hard -q HEAD; then
    ui_warn "$label: the checkout in $dir failed; the .git dir is in place"
    return 0
  fi
  if [ -d "$backup" ]; then
    ui_ok "$label: adopted $dir; replaced local files saved to $backup"
  else
    ui_ok "$label: adopted $dir"
  fi
  return 0
}

# repo_remote_url <source> <gh|url>
repo_remote_url() {
  if [ "$2" = gh ]; then
    printf 'https://github.com/%s.git' "$1"
  else
    printf '%s' "$1"
  fi
}

# reset_config_repo <label> <source> <dir> <gh|url>
# The remote is the source of truth: point origin at the configured repo,
# fetch it, and reset the checkout to its default branch. Local edits to
# tracked files are overwritten, but every such file is copied to a backup
# dir first. Untracked files (sessions, caches, history) are left alone.
reset_config_repo() {
  local label=$1 src=$2 dir=$3 mode=$4 ref="" backup="" f="" list=""
  if ! git -C "$dir" remote set-url origin "$(repo_remote_url "$src" "$mode")" 2>/dev/null; then
    git -C "$dir" remote add origin "$(repo_remote_url "$src" "$mode")" 2>/dev/null || true
  fi
  if ! config_repo_git "$mode" -C "$dir" fetch --quiet --prune origin >/dev/null 2>&1; then
    ui_err "$label: could not fetch $src (check the repo name and the gh login for its owner)"
    return 1
  fi
  git -C "$dir" remote set-head origin --auto >/dev/null 2>&1 || true
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || ref=origin/HEAD
  if ! git -C "$dir" rev-parse --verify -q "$ref" >/dev/null; then
    ui_err "$label: $src has no default branch to check out"
    return 1
  fi
  # Back up only what the reset will overwrite: tracked files that differ from
  # the remote, and untracked files that collide with a file the remote has.
  list=$(mktemp) || return 1
  {
    git -C "$dir" diff --name-only "$ref"
    git -C "$dir" ls-files --others --exclude-standard |
      grep -Fxf <(git -C "$dir" ls-tree -r --name-only "$ref") || true
  } | sort -u >"$list"
  backup="$dir.pre-sync-$(date +%Y%m%d-%H%M%S)"
  while IFS= read -r f; do
    if [ -e "$dir/$f" ] || [ -L "$dir/$f" ]; then
      mkdir -p "$backup/$(dirname "$f")"
      cp -Rp "$dir/$f" "$backup/$f"
    fi
  done <"$list"
  rm -f "$list"
  if ! git -C "$dir" reset --hard -q "$ref"; then
    ui_err "$label: could not reset $dir to $ref"
    return 1
  fi
  if [ -d "$backup" ]; then
    ui_ok "$label: synced $dir to $ref; overwritten local files saved to $backup"
  else
    ui_ok "$label: synced $dir to $ref"
  fi
  return 0
}

# sync_config_repo <label> <source> <dir> <gh|url>
# An existing checkout is reset to the remote (see reset_config_repo). A
# plain directory is adopted in place; an empty one is cloned into.
sync_config_repo() {
  local label=$1 src=$2 dir=$3 mode=$4
  if [ -z "$src" ]; then
    ui_info "$label: no repo configured"
    return 0
  fi
  if [ -d "$dir/.git" ]; then
    reset_config_repo "$label" "$src" "$dir" "$mode"
    return $?
  fi
  if [ -e "$dir" ]; then
    if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
      rmdir "$dir" 2>/dev/null || true
    else
      config_repo_adopt "$label" "$src" "$dir" "$mode"
      return $?
    fi
  fi
  config_repo_clone "$label" "$src" "$dir" "$mode"
}

phase_config_repos() {
  local failed="" user="" fix="den up --only=config-repos"
  CONFIG_REPOS_TOKEN=""
  if user=$(config_repos_gh_user); then
    local rc=0
    CONFIG_REPOS_TOKEN=$(config_repos_token "$user") || rc=$?
    case $rc in
      1) ui_warn "gh has no login for $user, who owns the config repos; trying the active account" ;;
      2) ui_warn "gh's saved token for $user no longer works (GitHub revoked it); trying the active account" ;;
    esac
    if [ "$rc" != 0 ]; then
      fix="den fix (it asks you to sign gh in as $user)"
    fi
  fi
  if ! sync_config_repo "OpenCode config" "${OPENCODE_CONFIG_REPO:-}" "$HOME/.config/opencode" gh; then
    failed="$failed opencode"
  fi
  if ! sync_config_repo "Claude Code config" "${CLAUDE_CONFIG_REPO:-}" "$HOME/.claude" gh; then
    failed="$failed claude"
  fi
  if ! sync_config_repo "Agent skills" "${OPENCODE_SKILLS_REPO:-}" "$HOME/.agents/skills" url; then
    failed="$failed skills"
  fi
  if [ -n "$failed" ]; then
    den_fail "these config repos failed to sync:$failed" "$fix"
  fi
}
