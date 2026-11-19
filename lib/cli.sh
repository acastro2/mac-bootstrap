# shellcheck shell=bash
# lib/cli.sh — doctor, clean, sessions, setup, update, dashboard.
# Contract: docs/den/CONTRACT.md. Bash 3.2.

den_snapshots_dir() {
  printf '%s' "$HOME/.local/state/den/snapshots"
}

# den_snapshot_paths <prefix> <path...>: tar the paths that exist, relative to
# $HOME, into <snapshots>/<prefix>-<stamp>.tar.gz. Prints the archive.
# Returns 0 with a snapshot, 1 when nothing exists, 2 when the snapshot failed.
den_snapshot_paths() {
  local prefix=${1:-snapshot} dir stamp snap p
  if [ $# -gt 0 ]; then
    shift
  fi
  local existing=()
  for p in "$@"; do
    if [ -e "$HOME/$p" ] || [ -L "$HOME/$p" ]; then
      existing[${#existing[@]}]=$p
    fi
  done
  if [ ${#existing[@]} -eq 0 ]; then
    return 1
  fi
  dir=$(den_snapshots_dir)
  if ! mkdir -p "$dir"; then
    return 2
  fi
  chmod 700 "$dir" 2>/dev/null || true
  stamp=$(date +%Y%m%d-%H%M%S)
  snap="$dir/$prefix-$stamp.tar.gz"
  if ! tar -czf "$snap" -C "$HOME" "${existing[@]}"; then
    return 2
  fi
  chmod 600 "$snap" 2>/dev/null || true
  printf '%s' "$snap"
  return 0
}

# ── doctor ────────────────────────────────────────────────────────────

den_cmd_doctor() {
  local strict=0 fn name rc total=0 broken=0
  while [ $# -gt 0 ]; do
    case $1 in
      --strict) strict=1 ;;
      *) den_die "usage: den doctor [--strict]" ;;
    esac
    shift
  done
  ui_banner
  for fn in $(declare -F | awk '{print $3}' | grep '^den_doctor_' | sort || true); do
    name=${fn#den_doctor_}
    ui_section "Doctor: $name"
    rc=0
    "$fn" || rc=$?
    total=$((total + 1))
    if [ "$rc" -ne 0 ]; then
      broken=$((broken + 1))
    fi
  done
  printf '\n'
  if [ "$total" -eq 0 ]; then
    ui_info "doctor: no checks available"
  fi
  if [ "$broken" -gt 0 ]; then
    ui_warn "doctor: $total checks, $broken broken"
  else
    ui_ok "doctor: $total checks, nothing broken"
  fi
  if [ "$strict" = 1 ] && [ "$broken" -gt 0 ]; then
    exit 1
  fi
  exit 0
}

# ── clean ─────────────────────────────────────────────────────────────
# Only what den declares: registry remove paths, installed Brewfile tokens,
# and (with --host-drift) undeclared Homebrew leaves. Casks are never removed
# by host drift, and local session/config data is never touched.

DEN_CLEAN_PATHS=()
DEN_CLEAN_FORMULAE=()
DEN_CLEAN_CASKS=()
DEN_CLEAN_DRIFT=()
DEN_CLEAN_MISSING_REGISTRY=0
DEN_CLEAN_MISSING_BREWFILE=0
DEN_CLEAN_MISSING_DRIFT=0

den_clean_protected() {
  case ${1:-} in
    .config/zsh/local.zsh|.claude|.claude/*|.local/share/opencode|.local/share/opencode/*|.snowflake|.snowflake/*) return 0 ;;
  esac
  return 1
}

den_clean_plan_registry() {
  local name kind target spec remove path
  if ! declare -F den_registry_rows >/dev/null 2>&1; then
    DEN_CLEAN_MISSING_REGISTRY=1
    return 0
  fi
  # shellcheck disable=SC2034  # kind/spec are part of the row format, not used here
  while IFS='|' read -r name kind target spec remove; do
    if [ -z "${name:-}" ]; then
      continue
    fi
    if [ -z "${remove:-}" ]; then
      remove=$target
    fi
    # shellcheck disable=SC2086  # the remove column is a space list
    for path in $remove; do
      case $path in
        ''|/*) continue ;;
      esac
      if den_clean_protected "$path"; then
        continue
      fi
      if [ -e "$HOME/$path" ] || [ -L "$HOME/$path" ]; then
        DEN_CLEAN_PATHS[${#DEN_CLEAN_PATHS[@]}]=$path
      fi
    done
  done < <(den_registry_rows "$(den_os)" 2>/dev/null || true)
}

den_clean_listed() { # newline-list token
  case "
$1
" in
    *"
$2
"*) return 0 ;;
  esac
  return 1
}

den_clean_plan_brew() {
  local file entry token installed_f installed_c
  if ! declare -F den_brewfile_entries >/dev/null 2>&1; then
    DEN_CLEAN_MISSING_BREWFILE=1
    return 0
  fi
  case $(den_os) in
    linux) file="$DEN_ROOT/Brewfile.linux" ;;
    *) file="$DEN_ROOT/Brewfile" ;;
  esac
  if [ ! -r "$file" ]; then
    DEN_CLEAN_MISSING_BREWFILE=1
    return 0
  fi
  installed_f=$(brew list --formula 2>/dev/null) || installed_f=""
  installed_c=$(brew list --cask 2>/dev/null) || installed_c=""
  while IFS= read -r entry; do
    case ${entry:-} in
      "brew "*)
        token=${entry#brew }
        if den_clean_listed "$installed_f" "$token"; then
          DEN_CLEAN_FORMULAE[${#DEN_CLEAN_FORMULAE[@]}]=$token
        fi
        ;;
      "cask "*)
        token=${entry#cask }
        if den_clean_listed "$installed_c" "$token"; then
          DEN_CLEAN_CASKS[${#DEN_CLEAN_CASKS[@]}]=$token
        fi
        ;;
    esac
  done < <(den_brewfile_entries "$file" 2>/dev/null || true)
}

den_clean_plan_drift() {
  local out line token
  if ! declare -F den_doctor_host_drift >/dev/null 2>&1; then
    DEN_CLEAN_MISSING_DRIFT=1
    return 0
  fi
  out=$(den_doctor_host_drift 2>/dev/null) || out=""
  while IFS= read -r line; do
    case $line in
      *--cask*) continue ;;
      *"brew remove "*|*"brew uninstall "*) ;;
      *) continue ;;
    esac
    token=$(printf '%s\n' "$line" |
      sed -n -E 's/.*brew (remove|uninstall)( --force)? +([A-Za-z0-9@._+/-]+).*/\3/p' |
      head -n 1)
    if [ -n "$token" ]; then
      DEN_CLEAN_DRIFT[${#DEN_CLEAN_DRIFT[@]}]=$token
    fi
  done <<EOF
$out
EOF
}

den_clean_plan_build() {
  den_clean_plan_registry
  den_clean_plan_brew
  if [ "${1:-0}" = 1 ]; then
    den_clean_plan_drift
  fi
}

den_clean_print_plan() {
  local p f empty=1
  if [ "$DEN_CLEAN_MISSING_REGISTRY" = 1 ]; then
    ui_warn "clean: the install registry is unavailable (lib/registry.sh); managed installs are not in this plan"
  fi
  if [ "$DEN_CLEAN_MISSING_BREWFILE" = 1 ]; then
    ui_warn "clean: Brewfile entries are unavailable (lib/registry.sh); packages are not in this plan"
  fi
  if [ "$DEN_CLEAN_MISSING_DRIFT" = 1 ]; then
    ui_warn "clean: host drift is unavailable (lib/registry.sh); --host-drift is not in this plan"
  fi
  if [ ${#DEN_CLEAN_PATHS[@]} -gt 0 ]; then
    empty=0
    for p in "${DEN_CLEAN_PATHS[@]}"; do
      ui_info "would remove: ~/$p"
    done
  fi
  if [ ${#DEN_CLEAN_FORMULAE[@]} -gt 0 ]; then
    empty=0
    for f in "${DEN_CLEAN_FORMULAE[@]}"; do
      ui_info "would run: brew remove $f"
    done
  fi
  if [ ${#DEN_CLEAN_CASKS[@]} -gt 0 ]; then
    empty=0
    for f in "${DEN_CLEAN_CASKS[@]}"; do
      ui_info "would run: brew remove --cask $f"
    done
  fi
  if [ ${#DEN_CLEAN_DRIFT[@]} -gt 0 ]; then
    empty=0
    for f in "${DEN_CLEAN_DRIFT[@]}"; do
      ui_info "would run: brew remove --force $f"
    done
  fi
  if [ "$empty" = 1 ]; then
    ui_info "nothing to remove: every declared item is already gone"
  fi
}

den_clean_snapshot() {
  local snap rc=0
  if [ ${#DEN_CLEAN_PATHS[@]} -eq 0 ]; then
    return 0
  fi
  snap=$(den_snapshot_paths clean "${DEN_CLEAN_PATHS[@]}") || rc=$?
  case $rc in
    0)
      ui_info "snapshot: $snap"
      den_snapshots_prune clean
      ;;
    1) : ;;
    *)
      ui_err "clean: could not snapshot the paths it would delete; nothing removed"
      return 1
      ;;
  esac
  return 0
}

den_clean_apply() {
  local p f rc=0
  if [ ${#DEN_CLEAN_PATHS[@]} -gt 0 ]; then
    for p in "${DEN_CLEAN_PATHS[@]}"; do
      if [ -z "$p" ] || [ "$p" = "/" ]; then
        continue
      fi
      if den_clean_protected "$p"; then
        ui_warn "clean: refusing to remove ~/$p (protected)"
        continue
      fi
      if rm -rf "${HOME:?}/$p"; then
        ui_ok "removed ~/$p"
      else
        ui_warn "clean: could not remove ~/$p"
        rc=1
      fi
    done
  fi
  if [ ${#DEN_CLEAN_FORMULAE[@]} -gt 0 ]; then
    for f in "${DEN_CLEAN_FORMULAE[@]}"; do
      if brew remove "$f" >/dev/null 2>&1; then
        ui_ok "brew remove $f"
      else
        ui_warn "clean: brew remove $f failed"
      fi
    done
  fi
  if [ ${#DEN_CLEAN_CASKS[@]} -gt 0 ]; then
    for f in "${DEN_CLEAN_CASKS[@]}"; do
      if brew remove --cask "$f" >/dev/null 2>&1; then
        ui_ok "brew remove --cask $f"
      else
        ui_warn "clean: brew remove --cask $f failed"
      fi
    done
  fi
  if [ ${#DEN_CLEAN_DRIFT[@]} -gt 0 ]; then
    for f in "${DEN_CLEAN_DRIFT[@]}"; do
      if brew remove --force "$f" >/dev/null 2>&1; then
        ui_ok "brew remove --force $f"
      else
        ui_warn "clean: brew remove --force $f failed"
      fi
    done
  fi
  return "$rc"
}

den_cmd_clean() {
  local dry=0 host_drift=0 yes=0 answer=""
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) dry=1 ;;
      --host-drift) host_drift=1 ;;
      --yes|-y) yes=1 ;;
      *) den_die "usage: den clean [--dry-run] [--host-drift] [--yes]" ;;
    esac
    shift
  done
  # Host drift is everything installed outside the Brewfile: removing it is a
  # human decision every time (CONTRACT: typed confirmation of the exact list).
  # The check sits below the dry-run branch: a dry run removes nothing, so it
  # never needs the typed confirmation.
  den_clean_plan_build "$host_drift"
  ui_section "Clean"
  if [ "$dry" = 1 ]; then
    ui_info "dry run: printing the plan, removing nothing"
    den_clean_print_plan
    exit 0
  fi
  if [ "$host_drift" = 1 ] && [ "$yes" = 1 ]; then
    den_die "den clean --host-drift always asks you to type clean; --yes is refused"
  fi
  if [ "$yes" = 0 ] && ! den_is_tty; then
    ui_err "den clean needs a terminal to confirm, or --yes; nothing removed"
    exit 2
  fi
  den_clean_print_plan
  if [ "$yes" = 0 ]; then
    printf 'Type clean to remove these: ' >&2
    IFS= read -r answer || answer=""
    if [ "$answer" != clean ]; then
      ui_warn "not confirmed; nothing removed"
      exit 2
    fi
  fi
  if ! den_clean_snapshot; then
    exit 1
  fi
  if ! den_clean_apply; then
    exit 1
  fi
  ui_ok "clean complete"
  exit 0
}

# ── sessions ──────────────────────────────────────────────────────────

den_sessions_units() {
  cat <<'EOF'
.local/share/opencode/opencode.db
.claude/projects
.claude/history.jsonl
.claude/sessions
.claude.json
.snowflake/cortex/conversations
.snowflake/cortex/settings.json
.snowflake/cortex/cortex.json
.snowflake/cortex/permissions.json
.snowflake/cortex/skills.json
.snowflake/cortex/skills
.snowflake/cortex/plugins
.snowflake/cortex/commands
.snowflake/cortex/thread_goals.sqlite
.snowflake/cortex/history
.snowflake/config.toml
.snowflake/connections.toml
EOF
}

# den_sessions_unexpected_path <norm-file>: print the first member of the
# normalized archive list that is not a session path, and return 1; print
# nothing and return 0 when every member is allowed. One pass over the members,
# so a 4000-file archive stays linear. The old per-member rescan of the whole
# list was O(N^2). A member is allowed when it is a session unit or under one,
# when it is a parent directory of another member, or when it is a Developer
# .cortex tree.
den_sessions_unexpected_path() { # norm-file
  local file=${1:-}
  # Units go through the environment: `awk -v` would re-lex a literal newline.
  DEN_SESSIONS_UNITS=$(den_sessions_units) awk '
    BEGIN {
      n = split(ENVIRON["DEN_SESSIONS_UNITS"], u, "\n")
      for (i = 1; i <= n; i++) {
        if (u[i] != "") unit[u[i]] = 1
      }
    }
    {
      member[++count] = $0
      dir = $0
      while (match(dir, /\/[^\/]+$/)) {
        dir = substr(dir, 1, RSTART - 1)
        parent[dir] = 1
      }
    }
    END {
      for (i = 1; i <= count; i++) {
        path = member[i]
        if (path in parent) continue
        if (path ~ /^Developer\/(.*\/)?\.cortex(\/.*)?$/) continue
        allowed = 0
        dir = path
        while (1) {
          if (dir in unit) { allowed = 1; break }
          if (!match(dir, /\/[^\/]+$/)) break
          dir = substr(dir, 1, RSTART - 1)
        }
        if (allowed) continue
        print path
        exit 1
      }
    }
  ' "$file"
}

den_sessions_has_member_under() { # members unit
  local members=${1:-} unit=${2:-} m
  while IFS= read -r m; do
    case $m in
      "$unit"|"$unit"/*) return 0 ;;
    esac
  done <<EOF
$members
EOF
  return 1
}

DEN_UNITS=""
den_sessions_add_unit() {
  case "
$DEN_UNITS" in
    *"
$1
"*) ;;
    *) DEN_UNITS="$DEN_UNITS$1"$'\n' ;;
  esac
}

# den_snapshots_prune <prefix>: keep the newest 5 <prefix>-*.tar.gz in the
# snapshots dir. Names carry the stamp, so name order is age order and ties
# cannot happen. Everything else in that dir (other prefixes, dotfiles-* from
# the shell phase) is left alone.
den_snapshots_prune() {
  local prefix=${1:-snapshot} dir f
  local snaps=()
  dir=$(den_snapshots_dir)
  if [ ! -d "$dir" ]; then
    return 0
  fi
  for f in "$dir/$prefix"-*.tar.gz; do
    if [ -f "$f" ]; then
      snaps[${#snaps[@]}]=$f
    fi
  done
  if [ ${#snaps[@]} -eq 0 ]; then
    return 0
  fi
  while IFS= read -r f; do
    if [ -n "$f" ] && [ -f "$f" ]; then
      rm -f -- "$f"
    fi
  done <<EOF
$(printf '%s\n' "${snaps[@]}" | sort -r | sed -n '6,$p')
EOF
  return 0
}

den_sessions_prune_snapshots() {
  den_snapshots_prune sessions
}

den_cmd_sessions_export() {
  if [ $# -gt 0 ]; then
    den_die "usage: den sessions export"
  fi
  local work dest out stamp size p rel db
  local paths=() tarargs=() excl=() skip pat
  ui_section "Sessions: export"
  work=$(mktemp -d "${TMPDIR:-/tmp}/den-export.XXXXXX") || den_die "sessions export: no temp dir"
  DEN_SESSIONS_WORK=$work
  trap 'rm -rf "${DEN_SESSIONS_WORK:-}"' EXIT

  for p in \
    ".claude/projects" \
    ".claude/history.jsonl" \
    ".claude/sessions" \
    ".snowflake/cortex/conversations" \
    ".snowflake/cortex/settings.json" \
    ".snowflake/cortex/cortex.json" \
    ".snowflake/cortex/permissions.json" \
    ".snowflake/cortex/skills.json" \
    ".snowflake/cortex/skills" \
    ".snowflake/cortex/plugins" \
    ".snowflake/cortex/commands" \
    ".snowflake/cortex/thread_goals.sqlite" \
    ".snowflake/cortex/history" \
    ".snowflake/config.toml"; do
    if [ -e "$HOME/$p" ]; then
      paths[${#paths[@]}]=$p
    fi
  done

  if [ -f "$HOME/.claude.json" ]; then
    paths[${#paths[@]}]=.claude.json
    ui_warn "sessions: ~/.claude.json is included; it holds account state and may hold credentials"
  fi

  if [ -d "$HOME/Developer" ]; then
    excl=()
    IFS=' ' read -r -a excl <<<"${DEN_SESSIONS_EXCLUDE:-}"
    while IFS= read -r p; do
      # DEN_SESSIONS_EXCLUDE: space-separated globs of checkouts to leave out
      # (work repos, say). Set it in ~/.config/den/local.env, not in the repo.
      skip=0
      for pat in ${excl[@]+"${excl[@]}"}; do
        # shellcheck disable=SC2254  # the pattern is a glob on purpose
        case $p in
          $pat) skip=1 ;;
        esac
      done
      if [ "$skip" = 1 ]; then
        continue
      fi
      rel=${p#"$HOME"/}
      paths[${#paths[@]}]=$rel
    done <<EOF
$(find "$HOME/Developer" -name .cortex -type d -print 2>/dev/null || true)
EOF
  fi

  db=".local/share/opencode/opencode.db"
  if [ -f "$HOME/$db" ]; then
    if command -v sqlite3 >/dev/null 2>&1; then
      mkdir -p "$work/.local/share/opencode"
      if sqlite3 "$HOME/$db" ".backup '$work/$db'" 2>/dev/null; then
        tarargs[${#tarargs[@]}]=-C
        tarargs[${#tarargs[@]}]=$work
        tarargs[${#tarargs[@]}]=$db
      else
        ui_warn "sessions: sqlite3 backup failed; packing the live database instead"
        tarargs[${#tarargs[@]}]=-C
        tarargs[${#tarargs[@]}]=$HOME
        tarargs[${#tarargs[@]}]=$db
      fi
    else
      tarargs[${#tarargs[@]}]=-C
      tarargs[${#tarargs[@]}]=$HOME
      tarargs[${#tarargs[@]}]=$db
    fi
  fi

  if [ ${#paths[@]} -gt 0 ]; then
    for p in "${paths[@]}"; do
      tarargs[${#tarargs[@]}]=-C
      tarargs[${#tarargs[@]}]=$HOME
      tarargs[${#tarargs[@]}]=$p
    done
  fi
  if [ ${#tarargs[@]} -eq 0 ]; then
    ui_err "sessions export: no session data found"
    exit 1
  fi

  dest="$HOME/.local/state/den/exports"
  if ! mkdir -p "$dest"; then
    ui_err "sessions export: could not create $dest"
    exit 1
  fi
  chmod 700 "$dest" 2>/dev/null || true
  stamp=$(date +%Y%m%d-%H%M%S)
  out="$dest/agent-sessions-$stamp.tar.gz"
  if ! tar -czf "$out" "${tarargs[@]}"; then
    ui_err "sessions export: could not write $out"
    exit 1
  fi
  chmod 600 "$out" 2>/dev/null || true
  size=$(du -h "$out" 2>/dev/null | cut -f1) || size="?"
  ui_ok "wrote $out (${size:-?})"
  ui_info "carry it by AirDrop or USB; restore with: den sessions import $out"
  rm -rf "$work"
  trap - EXIT
  exit 0
}

den_cmd_sessions_import() {
  local file="" yes=0 member p unit u snap stage rc=0 target bad
  while [ $# -gt 0 ]; do
    case $1 in
      --yes|-y) yes=1 ;;
      --) ;;
      -*)
        den_die "usage: den sessions import <file> [--yes]"
        ;;
      *)
        if [ -n "$file" ]; then
          den_die "usage: den sessions import <file> [--yes]"
        fi
        file=$1
        ;;
    esac
    shift
  done
  if [ -z "$file" ]; then
    den_die "usage: den sessions import <file> [--yes]"
  fi
  if [ ! -r "$file" ]; then
    ui_err "sessions import: cannot read $file"
    exit 1
  fi
  ui_section "Sessions: import"

  local work
  work=$(mktemp -d "${TMPDIR:-/tmp}/den-import.XXXXXX") || den_die "sessions import: no temp dir"
  DEN_SESSIONS_WORK=$work
  trap 'rm -rf "${DEN_SESSIONS_WORK:-}"' EXIT
  DEN_UNITS=""

  if ! tar -tzf "$file" >"$work/members" 2>/dev/null; then
    ui_err "sessions import: $file is not a readable .tar.gz; current data untouched"
    exit 1
  fi
  : >"$work/norm"
  while IFS= read -r member; do
    p=${member#./}
    p=${p%/}
    if [ -z "$p" ] || [ "$p" = "." ]; then
      continue
    fi
    case $p in
      /*|..|../*|*/..|*/../*)
        ui_err "sessions import: the archive contains an unsafe path: $member"
        exit 1
        ;;
    esac
    printf '%s\n' "$p" >>"$work/norm"
  done <"$work/members"
  if [ ! -s "$work/norm" ]; then
    ui_err "sessions import: $file is empty; current data untouched"
    exit 1
  fi
  DEN_SESSIONS_MEMBERS=$(cat "$work/norm")
  if ! bad=$(den_sessions_unexpected_path "$work/norm"); then
    ui_err "sessions import: unexpected path in archive: ${bad:-?}; current data untouched"
    exit 1
  fi

  while IFS= read -r unit; do
    if den_sessions_has_member_under "$DEN_SESSIONS_MEMBERS" "$unit"; then
      den_sessions_add_unit "$unit"
    fi
  done <<EOF
$(den_sessions_units)
EOF
  while IFS= read -r p; do
    case $p in
      Developer/*/.cortex|Developer/*/.cortex/*)
        u=$(printf '%s\n' "$p" | sed -E 's#^(.*/\.cortex)(/.*)?$#\1#')
        den_sessions_add_unit "$u"
        ;;
    esac
  done <<EOF
$DEN_SESSIONS_MEMBERS
EOF

  if [ -z "$DEN_UNITS" ]; then
    ui_err "sessions import: $file holds no expected session paths; current data untouched"
    exit 1
  fi

  if [ "$yes" = 0 ]; then
    if ! den_is_tty; then
      ui_err "sessions import needs a terminal to confirm, or --yes; nothing replaced"
      exit 2
    fi
    if ! ui_confirm "replace the current session data from $file?"; then
      ui_warn "not confirmed; nothing replaced"
      exit 1
    fi
  fi

  local existing=()
  while IFS= read -r u; do
    if [ -z "$u" ]; then
      continue
    fi
    if [ -e "$HOME/$u" ] || [ -L "$HOME/$u" ]; then
      existing[${#existing[@]}]=$u
    fi
  done <<EOF
$DEN_UNITS
EOF
  snap=""
  if [ ${#existing[@]} -gt 0 ]; then
    snap=$(den_snapshot_paths sessions "${existing[@]}") || rc=$?
    case $rc in
      0) ui_info "snapshot: $snap" ;;
      1) snap="" ;;
      *)
        ui_err "sessions import: could not snapshot current data; nothing replaced"
        exit 1
        ;;
    esac
  fi
  den_sessions_prune_snapshots

  stage="$work/stage"
  mkdir -p "$stage"
  if ! tar -xzf "$file" -C "$stage"; then
    ui_err "sessions import: could not extract $file; current data untouched"
    exit 1
  fi
  while IFS= read -r u; do
    if [ ! -e "$stage/$u" ] && [ ! -L "$stage/$u" ]; then
      ui_err "sessions import: the archive is missing $u; current data untouched"
      exit 1
    fi
  done <<EOF
$DEN_UNITS
EOF

  while IFS= read -r u; do
    if [ -z "$u" ]; then
      continue
    fi
    target="$HOME/$u"
    if [ -e "$target" ] || [ -L "$target" ]; then
      rm -rf "$target"
    fi
    mkdir -p "$(dirname "$target")" || {
      ui_err "sessions import: could not prepare $(dirname "$target")"
      exit 1
    }
    if ! mv "$stage/$u" "$target"; then
      ui_err "sessions import: could not move $u into place; restoring the snapshot"
      if [ -n "$snap" ]; then
        tar -xzf "$snap" -C "$HOME" || ui_warn "sessions import: snapshot restore failed; it is at $snap"
      fi
      exit 1
    fi
  done <<EOF
$DEN_UNITS
EOF

  ui_ok "sessions restored from $file"
  rm -rf "$work"
  trap - EXIT
  exit 0
}

den_cmd_sessions() {
  local sub=${1:-}
  if [ $# -gt 0 ]; then
    shift
  fi
  case $sub in
    export) den_cmd_sessions_export "$@" ;;
    import) den_cmd_sessions_import "$@" ;;
    *)
      den_die "usage: den sessions export | import <file> [--yes]"
      ;;
  esac
}

# ── setup ─────────────────────────────────────────────────────────────

den_config_write_value() { # key value
  local key=${1:-} value=${2:-} tmp escaped
  if [ -z "$key" ]; then
    return 1
  fi
  # shellcheck disable=SC2016  # the backticks and dollars are sed patterns
  escaped=$(printf '%s' "$value" |
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g' -e 's/`/\\`/g')
  tmp="$DEN_CONFIG.den-tmp.$$"
  if [ -f "$DEN_CONFIG" ]; then
    awk -v k="$key" -v v="$escaped" '
      index($0, k "=") == 1 { printf "%s=\"%s\"\n", k, v; done = 1; next }
      { print }
      END { if (!done) printf "%s=\"%s\"\n", k, v }
    ' "$DEN_CONFIG" >"$tmp" || return 1
  else
    printf '%s="%s"\n' "$key" "$escaped" >"$tmp" || return 1
  fi
  mv "$tmp" "$DEN_CONFIG"
}

den_cmd_setup() {
  local value current toggle answer
  if [ $# -gt 0 ]; then
    den_die "den setup takes no arguments"
  fi
  den_config_load
  if ! den_is_tty; then
    ui_info "no terminal: edit $DEN_CONFIG by hand, then run den up"
    ui_info "keys: OP_VAULT, GIT_NAME, GIT_EMAIL, AGENT_VM, DEN_MACOS_DEFAULTS, DEN_TOUCHID_SUDO, DEN_REX, DEN_OPENCODE_WEB, DEN_VM, DEN_BROWSE_TUNNEL"
    exit 0
  fi
  den_state_dir_init
  ui_banner
  ui_section "Setup"
  ui_info "editing $DEN_CONFIG"
  value=$(ui_input "1Password vault" "${OP_VAULT:-Private}")
  den_config_write_value OP_VAULT "$value" || den_die "setup: could not write $DEN_CONFIG"
  value=$(ui_input "git user name" "${GIT_NAME:-}")
  den_config_write_value GIT_NAME "$value" || den_die "setup: could not write $DEN_CONFIG"
  value=$(ui_input "git user email" "${GIT_EMAIL:-}")
  den_config_write_value GIT_EMAIL "$value" || den_die "setup: could not write $DEN_CONFIG"
  value=$(ui_input "Lima agent VM name" "${AGENT_VM:-agent}")
  den_config_write_value AGENT_VM "$value" || den_die "setup: could not write $DEN_CONFIG"
  for toggle in DEN_MACOS_DEFAULTS DEN_TOUCHID_SUDO DEN_REX DEN_OPENCODE_WEB DEN_VM DEN_BROWSE_TUNNEL; do
    eval "current=\${$toggle:-1}"
    if [ "$current" = 0 ]; then
      eval "current=off"
    else
      eval "current=on"
    fi
    if ui_confirm "$toggle ($current) on?"; then
      answer=1
    else
      answer=0
    fi
    den_config_write_value "$toggle" "$answer" || den_die "setup: could not write $DEN_CONFIG"
  done
  ui_ok "wrote $DEN_CONFIG"
  if ui_confirm "run den up now?"; then
    den_cmd_up
  fi
  exit 0
}

# ── update ────────────────────────────────────────────────────────────

den_cmd_update() {
  ui_section "Update"
  if ! git -C "$DEN_ROOT" pull --ff-only; then
    ui_err "update: git pull --ff-only failed; nothing run"
    exit 1
  fi
  ui_ok "repo updated"
  den_cmd_up "$@"
}

# ── dashboard ─────────────────────────────────────────────────────────

# den_dashboard_now: live state on the Mac: the VM, the browse relay, and the
# tunnel from the VM back to the relay. Read-only; each check has a timeout.
den_dashboard_now() {
  local vm=${AGENT_VM:-agent} st code bin
  [ "$(den_os)" = macos ] || return 0
  ui_section "Now"
  if ! command -v limactl >/dev/null 2>&1; then
    ui_info "vm: Lima is not installed (den up --only=packages)"
    return 0
  fi
  st=$(den_vm_to 10 limactl list "$vm" --format '{{.Status}}' 2>/dev/null) || st=""
  case $st in
    Running)
      ui_ok "vm $vm: running"
      ui_info "Rex.app host: ssh://lima-$vm (once: Cmd-Shift-P > Add Remote Host..., then Switch Host)"
      ;;
    '') ui_warn "vm $vm: not created (den up --only=vm)" ;;
    *) ui_warn "vm $vm: ${st} (den vm up)" ;;
  esac
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 2 http://127.0.0.1:19988/ 2>/dev/null) || code=""
  if [ "$code" = 200 ]; then
    ui_ok "browse relay: up on 127.0.0.1:19988"
    # Pairing codes live in a file on the computer that runs `browse pair`,
    # and the relay reads only the Mac's file: a code made in the VM never works.
    bin="$HOME/.local/bin/browse"
    [ -x "$bin" ] || bin=$(command -v browse 2>/dev/null) || bin=""
    if [ -n "$bin" ] && den_vm_to 5 "$bin" pair --list 2>/dev/null </dev/null | grep -q '^No paired browsers'; then
      ui_warn "browse: no browser paired (run browse pair on the Mac, never in the VM: the relay reads only the Mac's codes)"
    fi
  else
    ui_warn "browse relay: down (vm-up restarts it within a minute; den vm logs)"
  fi
  if [ "$st" = Running ]; then
    code=$(den_vm_to 10 limactl shell "$vm" -- curl -s -o /dev/null -w '%{http_code}' -m 3 http://127.0.0.1:19988/ </dev/null 2>/dev/null) || code=""
    if [ "$code" = 200 ]; then
      ui_ok "tunnel: the VM reaches the relay"
    else
      ui_warn "tunnel: the VM cannot reach the relay (vm-up retries every 30 s; den vm logs)"
    fi
  fi
}

den_cmd_dashboard() {
  local file="$DEN_STATE_DIR/last-run.json" line phase status seconds
  local started host os done_n=0 skip_n=0 fail_n=0 dry_n=0
  ui_banner
  den_config_load
  den_dashboard_now
  if [ ! -f "$file" ]; then
    ui_info "no run recorded yet"
    ui_info "start: den up    phases: den phases    health: den doctor"
    exit 0
  fi
  started=$(sed -n 's/.*"started":"\([^"]*\)".*/\1/p' "$file" | head -n 1)
  host=$(sed -n 's/.*"host":"\([^"]*\)".*/\1/p' "$file" | head -n 1)
  os=$(sed -n 's/.*"os":"\([^"]*\)".*/\1/p' "$file" | head -n 1)
  ui_section "Last run"
  ui_info "${started:-unknown} on ${host:-unknown} (${os:-unknown})"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    phase=$(printf '%s\n' "$line" | sed -n 's/^{"phase":"\([^"]*\)".*/\1/p')
    status=$(printf '%s\n' "$line" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
    seconds=$(printf '%s\n' "$line" | sed -n 's/.*"seconds":\([0-9]*\).*/\1/p')
    case $status in
      done) done_n=$((done_n + 1)) ;;
      skipped) skip_n=$((skip_n + 1)) ;;
      failed) fail_n=$((fail_n + 1)) ;;
      dry-run) dry_n=$((dry_n + 1)) ;;
    esac
    ui_info "$(printf '%-20s %-8s %ss' "${phase:-?}" "${status:-?}" "${seconds:-0}")"
  done <<EOF
$(grep -o '{"phase":"[^"]*","status":"[^"]*","seconds":[0-9]*' "$file" 2>/dev/null || true)
EOF
  ui_section "Summary"
  if [ "$dry_n" -gt 0 ]; then
    ui_info "$done_n done, $skip_n skipped, $fail_n failed, $dry_n dry-run"
  else
    ui_info "$done_n done, $skip_n skipped, $fail_n failed"
  fi
  if [ "$skip_n" -gt 0 ] || [ "$fail_n" -gt 0 ]; then
    ui_info "rerun those: den fix"
  fi
  ui_info "phases: den phases    health: den doctor    help: den help"
  ui_info "$(ui_quip)"
  exit 0
}
