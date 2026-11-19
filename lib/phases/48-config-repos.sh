# shellcheck shell=bash
# lib/phases/48-config-repos.sh — the private config repos behind OpenCode,
# Claude Code and the shared agent skills.
# Contract: docs/den/CONTRACT.md ("Host vs VM").

den_phase config-repos \
  --title "Config repos" \
  --about "OpenCode, Claude Code and agent skills checked out where the tools read them" \
  --os any \
  --needs "gh net"

# config_repo_clone <label> <source> <dir> <gh|url>
config_repo_clone() {
  local label=$1 src=$2 dir=$3 mode=$4 out=""
  ui_step "cloning $label into $dir"
  mkdir -p "$(dirname "$dir")"
  if [ "$mode" = gh ]; then
    if ! out=$(gh repo clone "$src" "$dir" 2>&1); then
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
    out=$(gh repo clone "$src" "$tmp/repo" -- --no-checkout 2>&1) || {
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

# sync_config_repo <label> <source> <dir> <gh|url>
# A checkout is fast-forwarded. A diverged or dirty checkout is reported, not
# failed: the local branch may hold work the user wants.
sync_config_repo() {
  local label=$1 src=$2 dir=$3 mode=$4
  if [ -z "$src" ]; then
    ui_info "$label: no repo configured"
    return 0
  fi
  if [ -d "$dir/.git" ]; then
    if GIT_TERMINAL_PROMPT=0 git -C "$dir" pull --ff-only >/dev/null 2>&1; then
      ui_ok "$label: up to date in $dir"
    else
      ui_warn "$label: could not fast-forward $dir (diverged or dirty); keeping local state"
    fi
    return 0
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
  local failed=""
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
    den_fail "these config repos failed to sync:$failed" "den up --only=config-repos"
  fi
}
