# shellcheck shell=bash
# lib/registry.sh — managed installs and host drift. Contract: docs/den/CONTRACT.md.
# Package managers keep their own registries (Brewfile, mise); this table is the
# only place that knows where a directly installed tool lives.

# Fields: name|kind|target|spec|remove
#   kind    script (installer), uv (uv tool), app (symlink into an app bundle)
#   target  path that must exist, relative to $HOME
#   spec    uv package, or the app binary for kind app
#   remove  what den clean deletes, relative to $HOME (empty: the target)
den_registry_rows() {
  local os=${1:-$(den_os)}
  case $os in
    macos)
      cat <<'EOF'
opencode|script|.opencode/bin/opencode||.opencode
claude|script|.local/bin/claude||.local/bin/claude .local/share/claude
code|app|.local/bin/code|Applications/Visual Studio Code.app/Contents/Resources/app/bin/code|.local/bin/code
EOF
      ;;
    linux)
      cat <<'EOF'
opencode|script|.opencode/bin/opencode||.opencode
claude|script|.local/bin/claude||.local/bin/claude .local/share/claude
cortex|script|.local/bin/cortex||.local/bin/cortex
tgrep|script|.local/bin/tgrep||.local/bin/tgrep
playwright|uv|.local/bin/playwright|playwright|.local/bin/playwright .local/share/uv/tools/playwright
browser-use|uv|.local/bin/browser-use|browser-use|.local/bin/browser-use .local/share/uv/tools/browser-use
EOF
      ;;
  esac
}

den_registry_names() {
  local _name _kind _target _spec _remove
  while IFS='|' read -r _name _kind _target _spec _remove; do
    if [ -n "$_name" ]; then
      printf '%s\n' "$_name"
    fi
  done < <(den_registry_rows "$(den_os)")
}

# Load one row of this host into DEN_ROW_KIND, DEN_ROW_TARGET, DEN_ROW_SPEC and
# DEN_ROW_REMOVE. Returns 1 when the name is not in the registry.
# shellcheck disable=SC2034  # the four DEN_ROW_* are read by callers, not here.
den_registry_row() {
  local want=${1:-} name kind target spec remove
  DEN_ROW_KIND=""
  DEN_ROW_TARGET=""
  DEN_ROW_SPEC=""
  DEN_ROW_REMOVE=""
  while IFS='|' read -r name kind target spec remove; do
    if [ "$name" = "$want" ]; then
      DEN_ROW_KIND=$kind
      DEN_ROW_TARGET=$target
      DEN_ROW_SPEC=$spec
      DEN_ROW_REMOVE=$remove
      return 0
    fi
  done < <(den_registry_rows "$(den_os)")
  return 1
}

# Status: 0 present, 1 shadowed, 2 missing, 3 skipped, 4 not on PATH.
# Sets DEN_CHECK_DETAIL to the line the caller prints.
# shellcheck disable=SC2088  # DEN_CHECK_DETAIL is display text; the tilde is literal.
den_registry_check_fields() {
  local name=$1 kind=$2 rel=$3 spec=$4 target resolved link
  DEN_CHECK_DETAIL=""
  target=$HOME/$rel
  case $kind in
    app)
      if [ ! -e "$HOME/$spec" ]; then
        DEN_CHECK_DETAIL="app not installed"
        return 3
      fi
      ;;
    uv)
      if ! command -v uv >/dev/null 2>&1; then
        DEN_CHECK_DETAIL="uv not installed"
        return 3
      fi
      if uv tool list 2>/dev/null | grep -q "^$spec v"; then
        DEN_CHECK_DETAIL="~/$rel (uv $spec)"
        return 0
      fi
      DEN_CHECK_DETAIL="uv tool $spec not installed"
      return 2
      ;;
  esac
  if [ ! -e "$target" ]; then
    DEN_CHECK_DETAIL="missing at ~/$rel"
    return 2
  fi
  if [ "$kind" = app ]; then
    link=$(readlink "$target" 2>/dev/null) || link=""
    if [ "$link" != "$HOME/$spec" ]; then
      DEN_CHECK_DETAIL="~/$rel points at ${link:-nothing}"
      return 1
    fi
  fi
  resolved=$(command -v "$name" 2>/dev/null) || resolved=""
  if [ -z "$resolved" ]; then
    DEN_CHECK_DETAIL="~/$rel (not on PATH in this shell)"
    return 4
  fi
  if [ "$resolved" != "$target" ]; then
    DEN_CHECK_DETAIL="$resolved shadows ~/$rel"
    return 1
  fi
  DEN_CHECK_DETAIL="~${resolved#"$HOME"}"
  return 0
}

den_registry_print() {
  local name=$1 status=$2
  case $status in
    0) printf '  ✓ %-24s %s\n' "$name" "$DEN_CHECK_DETAIL" ;;
    1|2) printf '  ✗ %-24s %s\n' "$name" "$DEN_CHECK_DETAIL" ;;
    3) printf '  – %-24s %s\n' "$name" "$DEN_CHECK_DETAIL" ;;
    *) printf '  ⚠ %-24s %s\n' "$name" "$DEN_CHECK_DETAIL" ;;
  esac
}

# Print "token|App.app" for every cask in the Mac Brewfile that lands in the
# default appdir. A cask with its own appdir: (1Password) is not ours to move.
den_registry_cask_apps() {
  local brewfile=${DEN_ROOT:-}/Brewfile token rest apps app
  if [ ! -r "$brewfile" ] || ! command -v brew >/dev/null 2>&1 ||
    ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  while IFS='|' read -r token rest; do
    if [ -z "$token" ]; then
      continue
    fi
    case $rest in
      *appdir:*) continue ;;
    esac
    apps=$(brew info --cask --json=v2 "$token" </dev/null 2>/dev/null |
      jq -r '.casks[0].artifacts[] | select(.app) | .app[] | strings' 2>/dev/null) || apps=""
    printf '%s\n' "$apps" | while IFS= read -r app; do
      if [ -n "$app" ]; then
        printf '%s|%s\n' "$token" "$app"
      fi
    done
  done < <(sed -n 's/^[[:space:]]*cask "\([^"]*\)"\(.*\)$/\1|\2/p' "$brewfile")
}

den_registry_system_appdir() {
  printf '%s' "${SYSTEM_APPDIR:-/Applications}"
}

# A managed app still outside ~/Applications is a doctor failure: an app there
# needs admin for every self-update.
den_registry_system_apps_check() {
  local sys token app found=0
  sys=$(den_registry_system_appdir)
  while IFS='|' read -r token app; do
    if [ -z "$app" ] || [ ! -d "$sys/$app" ]; then
      continue
    fi
    printf '  ✗ %s still in %s (should be in ~/Applications; run den up --only=appdir)\n' "$app" "$sys"
    found=1
  done < <(den_registry_cask_apps)
  for app in "Rex.app" "Rex Beta.app"; do
    if [ -d "$sys/$app" ]; then
      printf '  ✗ %s still in %s (should be in ~/Applications; run den up --only=appdir)\n' "$app" "$sys"
      found=1
    fi
  done
  if [ "$found" -eq 1 ]; then
    return 1
  fi
  return 0
}

# The doctor for managed installs. Prints one line per row, plus the appdir
# rows, and returns 1 when a row is shadowed or missing (a skipped row is not
# broken). The Mac also reports the uv tools that belong to the VM, so a stray
# Mac install or a broken uv is visible; those never count as broken.
den_doctor_registry() {
  local name kind target spec remove status broken=0
  while IFS='|' read -r name kind target spec remove; do
    status=0
    if den_registry_check_fields "$name" "$kind" "$target" "$spec"; then
      status=0
    else
      status=$?
    fi
    den_registry_print "$name" "$status"
    case $status in
      1|2) broken=$((broken + 1)) ;;
    esac
  done < <(den_registry_rows "$(den_os)")
  if [ "$(den_os)" = macos ]; then
    while IFS='|' read -r name kind target spec remove; do
      if [ "$kind" != uv ]; then
        continue
      fi
      status=0
      if den_registry_check_fields "$name" "$kind" "$target" "$spec"; then
        status=0
      else
        status=$?
      fi
      if [ "$status" = 0 ]; then
        DEN_CHECK_DETAIL="uv tool $spec installed (VM only)"
      else
        DEN_CHECK_DETAIL="$DEN_CHECK_DETAIL (VM only)"
      fi
      den_registry_print "$name" 3
    done < <(den_registry_rows linux)
    if ! den_registry_system_apps_check; then
      broken=$((broken + 1))
    fi
  fi
  if [ "$broken" -eq 0 ]; then
    return 0
  fi
  return 1
}

# Homebrew leaves and mise tools the Mac Brewfile does not declare. Drift is a
# warning, never a failure: only den clean --host-drift removes anything.
den_doctor_host_drift() {
  local brewfile=${DEN_ROOT:-}/Brewfile declared_formulae declared_casks name short version found=0
  if [ "$(den_os)" != macos ] || [ ! -r "$brewfile" ]; then
    return 0
  fi
  declared_formulae=" $(den_brewfile_entries "$brewfile" | awk '$1 == "brew" { printf "%s ", $2 }')"
  declared_casks=" $(den_brewfile_entries "$brewfile" | awk '$1 == "cask" { printf "%s ", $2 }')"
  if command -v brew >/dev/null 2>&1; then
    while IFS= read -r name; do
      if [ -z "$name" ]; then
        continue
      fi
      # brew leaves prints a tap formula as tap/name; the Brewfile is short.
      short=${name##*/}
      case $declared_formulae in
        *" $short "*) continue ;;
      esac
      printf '  ! %s is not in Brewfile (remove: brew uninstall %s)\n' "$name" "$name"
      found=1
    done < <(brew leaves 2>/dev/null)
    while IFS= read -r name; do
      if [ -z "$name" ]; then
        continue
      fi
      case $declared_casks in
        *" $name "*) continue ;;
      esac
      printf '  ! cask %s is not in Brewfile (remove by hand: brew uninstall --cask %s; den never removes apps)\n' \
        "$name" "$name"
      found=1
    done < <(brew list --cask 2>/dev/null)
  fi
  if command -v mise >/dev/null 2>&1; then
    while IFS=' ' read -r name version _source; do
      case ${name:-} in
        ''|Tool) continue ;;
      esac
      printf '  ! mise %s %s is on the Mac (remove: mise uninstall %s@%s)\n' \
        "$name" "$version" "$name" "$version"
      found=1
    done < <(mise ls --installed 2>/dev/null)
  fi
  if [ "$found" -eq 0 ]; then
    printf '  ✓ no host drift\n'
  fi
  return 0
}

# Print "brew x", "cask y" and "tap z" for one Brewfile. A formula's tap prefix
# is dropped: pattont/rex-agent-restore/rex-agent-restore prints rex-agent-restore.
den_brewfile_entries() {
  local file=${1:-} kind name
  if [ -z "$file" ] || [ ! -r "$file" ]; then
    return 0
  fi
  while IFS=' ' read -r kind name; do
    if [ -z "$kind" ] || [ -z "$name" ]; then
      continue
    fi
    case $kind in
      brew) name=${name##*/} ;;
    esac
    printf '%s %s\n' "$kind" "$name"
  done < <(sed -E -n 's/^[[:space:]]*(brew|cask|tap) "([^"]+)".*/\1 \2/p' "$file")
}

# Delete one row's paths, or print them when dry is 1 or DEN_CLEAN_DRY_RUN=1.
den_registry_remove() {
  local name=${1:-} dry=${2:-0} paths path
  if [ "${DEN_CLEAN_DRY_RUN:-0}" = 1 ]; then
    dry=1
  fi
  if ! den_registry_row "$name"; then
    ui_warn "no registry row for $name"
    return 0
  fi
  paths=${DEN_ROW_REMOVE:-$DEN_ROW_TARGET}
  for path in $paths; do
    if [ -z "$path" ]; then
      continue
    fi
    if [ "$dry" = 1 ]; then
      printf '  would remove: ~/%s\n' "$path"
    else
      rm -rf "${HOME:?}/$path"
    fi
  done
}

den_cmd_registry() {
  local sub=${1:-list} strict=0
  if [ $# -gt 0 ]; then
    shift
  fi
  case $sub in
    list)
      if [ $# -gt 0 ]; then
        den_die "den registry list takes no arguments"
      fi
      den_registry_rows "$(den_os)"
      exit 0
      ;;
    check)
      while [ $# -gt 0 ]; do
        case $1 in
          --strict) strict=1 ;;
          *) den_die "den registry check: unknown option $1" ;;
        esac
        shift
      done
      if den_doctor_registry; then
        exit 0
      fi
      if [ "$strict" = 1 ]; then
        exit 1
      fi
      exit 0
      ;;
    *) den_die "unknown registry command: $sub (try list or check)" ;;
  esac
}
