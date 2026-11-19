# shellcheck shell=bash
# lib/permissions.sh — macOS privacy (TCC) grants: the required-grant table,
# read-only detectors, the preflight walkthrough and the doctor row.
# Facts and sources: docs/den/macos-permissions.md. Contract: docs/den/CONTRACT.md.

DEN_PERM_PRIVACY_URL="x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
DEN_PERM_LOGINITEMS_URL="x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

# Browser prefs: "support dir:label" rows, one per browser.
DEN_PERM_BROWSERS="BraveSoftware/Brave-Browser:Brave
Google/Chrome:Chrome
Microsoft Edge:Edge"

DEN_PERM_WALK_ID=()
DEN_PERM_WALK_LABEL=()
DEN_PERM_WALK_WHY=()
DEN_PERM_WALK_APP=()
DEN_PERM_WALK_PANE=()
DEN_PERM_WALK_DET=()
DEN_PERM_WALK_COUNT=0

DEN_PERM_REX_FETCHED=0
DEN_PERM_REX_JSON=""
DEN_PERM_PEEK_FETCHED=0
DEN_PERM_PEEK_JSON=""

# id|label|why|app|pane|detector|required
den_permissions_rows() {
  cat <<'EOF'
rex_fda|Rex Server: Full Disk Access|scribe reads Voice Memos, and any ~/Library read from a Rex tab needs it|rex|allfiles|rex_full_disk_access|1
rex_accessibility|Rex Server: Accessibility|peekaboo clicks and typing, osascript keystrokes from a Rex tab|rex|accessibility|peekaboo_accessibility|1
rex_screen|Rex Server: Screen Recording|peekaboo screenshots and system audio capture from a Rex tab|rex|screencapture|rex_screen_recording|1
rex_microphone|Rex Server: Microphone|only if a tab records audio; Hex records its own|rex|microphone|rex_microphone|0
hex_microphone|Hex: Microphone|Hex dictation records your voice|hex|microphone|hex_microphone|1
hex_accessibility|Hex: Accessibility|Hex sees its shortcut in every app and pastes the text|hex|accessibility|hex_accessibility|1
vmup_login|Login item: vm-up|starts the agent VM at login (io.mac-bootstrap.vm-up)|-|loginitems|launchagent_vmup|0
lima_login|Login item: Lima autostart|Lima starts its VM at login (io.lima-vm.autostart.agent)|-|loginitems|launchagent_lima|0
browser_js|Browsers: JavaScript from Apple Events|osascript drives tabs; without it every call fails with -1723|-|-|browser_js|0
pam_tid|Touch ID for sudo|sudo asks for a finger, not a password|-|-|pam_tid|0
devtools|Developer Tools|not needed; off is the recommendation|-|devtools|devtools|0
EOF
}

den_permissions_pane() {
  case ${1:-} in
    allfiles) printf '%s?Privacy_AllFiles' "$DEN_PERM_PRIVACY_URL" ;;
    accessibility) printf '%s?Privacy_Accessibility' "$DEN_PERM_PRIVACY_URL" ;;
    screencapture) printf '%s?Privacy_ScreenCapture' "$DEN_PERM_PRIVACY_URL" ;;
    microphone) printf '%s?Privacy_Microphone' "$DEN_PERM_PRIVACY_URL" ;;
    loginitems) printf '%s' "$DEN_PERM_LOGINITEMS_URL" ;;
    devtools) printf '%s?Privacy_DevTools' "$DEN_PERM_PRIVACY_URL" ;;
  esac
}

den_permissions_app() {
  local path
  case ${1:-} in
    rex)
      printf '%s' "$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app"
      ;;
    hex)
      for path in "$HOME/Applications/Hex.app" /Applications/Hex.app; do
        if [ -d "$path" ]; then
          printf '%s' "$path"
          return 0
        fi
      done
      printf '%s' "$HOME/Applications/Hex.app"
      ;;
  esac
}

den_permissions_line() {
  local status=${1:-} text=${2:-} glyph='·' color=${DEN_C_DIM:-}
  case $status in
    granted)
      glyph='✓'
      color=${DEN_C_GREEN:-}
      ;;
    missing)
      glyph='✗'
      color=${DEN_C_RED:-}
      ;;
  esac
  printf '%s%s%s %s\n' "$color" "$glyph" "${DEN_C_RESET:-}" "$text"
}

den_permissions_cache_clear() {
  DEN_PERM_REX_FETCHED=0
  DEN_PERM_REX_JSON=""
  DEN_PERM_PEEK_FETCHED=0
  DEN_PERM_PEEK_JSON=""
}

# ── detectors: read-only, never prompt ────────────────────────────────

den_permissions_rex_bin() {
  local app
  if command -v rex >/dev/null 2>&1; then
    command -v rex
    return 0
  fi
  app=$(den_permissions_app rex)
  if [ -x "$app/Contents/MacOS/rex" ]; then
    printf '%s' "$app/Contents/MacOS/rex"
    return 0
  fi
  return 1
}

den_permissions_rex_json() {
  local bin
  if [ "$DEN_PERM_REX_FETCHED" != 1 ]; then
    DEN_PERM_REX_FETCHED=1
    if bin=$(den_permissions_rex_bin); then
      DEN_PERM_REX_JSON=$(den_with_timeout 15 "$bin" api call server.apple.privacy_status 2>/dev/null) || DEN_PERM_REX_JSON=""
    fi
  fi
  printf '%s' "$DEN_PERM_REX_JSON"
}

den_permissions_rex_probe() {
  local service=${1:-} json status resp
  json=$(den_permissions_rex_json)
  if [ -z "$json" ]; then
    printf 'unknown|the Rex server did not answer; is Rex running?'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'unknown|jq is missing, so the Rex answer cannot be read'
    return 0
  fi
  resp=$(printf '%s' "$json" | jq -r '.responsible_path // empty' 2>/dev/null) || resp=""
  case $resp in
    *'Rex Server.app'*) ;;
    '')
      printf 'unknown|the Rex answer has no responsible_path'
      return 0
      ;;
    *)
      printf 'unknown|the server is responsible as %s, not Rex Server.app; start Rex from the app' "${resp##*/}"
      return 0
      ;;
  esac
  status=$(printf '%s' "$json" | jq -r --arg s "$service" \
    '[.services[]? | select(.service == $s) | .status] | first // empty' 2>/dev/null) || status=""
  case $status in
    granted) printf 'granted|' ;;
    denied) printf 'missing|denied' ;;
    not_determined)
      # Microphone is optional here: only a tab that records audio needs it.
      if [ "$service" = microphone ]; then
        printf 'info|not granted; only needed if a tab records audio'
      else
        printf 'missing|not asked yet'
      fi
      ;;
    '') printf 'unknown|the server does not report %s' "$service" ;;
    *) printf 'unknown|the server says %s' "$status" ;;
  esac
}

den_permissions_peekaboo_json() {
  if [ "$DEN_PERM_PEEK_FETCHED" != 1 ]; then
    DEN_PERM_PEEK_FETCHED=1
    if command -v peekaboo >/dev/null 2>&1; then
      DEN_PERM_PEEK_JSON=$(den_with_timeout 15 peekaboo permissions status --all-sources --json 2>/dev/null) || DEN_PERM_PEEK_JSON=""
    fi
  fi
  printf '%s' "$DEN_PERM_PEEK_JSON"
}

den_permissions_peekaboo_probe() {
  local name=${1:-Accessibility} json source host granted
  json=$(den_permissions_peekaboo_json)
  if [ -z "$json" ]; then
    printf 'unknown|peekaboo did not answer (is it installed?); check the pane'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'unknown|jq is missing, so the peekaboo answer cannot be read'
    return 0
  fi
  source=$(printf '%s' "$json" | jq -r '.data.selectedSource // empty' 2>/dev/null) || source=""
  if [ -z "$source" ]; then
    source=$(printf '%s' "$json" | jq -r '.data.sources[0].source // empty' 2>/dev/null) || source=""
  fi
  host=$(printf '%s' "$json" | jq -r --arg s "$source" \
    '[.data.sources[]? | select(.source == $s) | .displayName] | first // empty' 2>/dev/null) || host=""
  granted=$(printf '%s' "$json" | jq -r --arg s "$source" --arg n "$name" \
    '[.data.sources[]? | select(.source == $s) | .permissions[]? | select(.name == $n) | .isGranted]
     | first | tostring' 2>/dev/null) || granted=""
  case $granted in
    true) printf 'granted|via %s' "${host:-peekaboo}" ;;
    false) printf 'missing|peekaboo reports it off (via %s); check the pane' "${host:-peekaboo}" ;;
    *) printf 'unknown|peekaboo does not report %s; check the pane' "$name" ;;
  esac
}

# Hex exposes no read-only permission API: the pane is the only check.
den_permissions_hex_probe() {
  local what=Accessibility app
  case ${1:-} in
    microphone) what=Microphone ;;
  esac
  app=$(den_permissions_app hex)
  if [ ! -d "$app" ]; then
    printf 'unknown|Hex.app is not installed (looked in ~/Applications and /Applications)'
    return 0
  fi
  printf 'unknown|no read-only detector for Hex %s; check the pane' "$what"
}

den_permissions_agent_probe() {
  local label=${1:-}
  if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    printf 'granted|loaded'
    return 0
  fi
  if [ -f "$HOME/Library/LaunchAgents/$label.plist" ]; then
    printf 'unknown|the plist is there but the agent is not loaded; approve it in Login Items'
  else
    printf 'unknown|not installed yet (den up installs it)'
  fi
}

den_permissions_browser_probe() {
  local name label dir profile value found=0 off="" on="" profile_name
  if ! command -v jq >/dev/null 2>&1; then
    printf 'unknown|jq is missing, so the browser prefs cannot be read'
    return 0
  fi
  while IFS=: read -r name label; do
    if [ -z "$name" ]; then
      continue
    fi
    dir="$HOME/Library/Application Support/$name"
    for profile in "$dir"/*/Preferences; do
      if [ ! -f "$profile" ]; then
        continue
      fi
      profile_name=${profile%/Preferences}
      profile_name=${profile_name##*/}
      case $profile_name in
        'System Profile'|'Guest Profile') continue ;;
      esac
      found=$((found + 1))
      value=$(jq -r '.browser.allow_javascript_apple_events // empty' "$profile" 2>/dev/null) || value=""
      if [ "$value" = true ]; then
        on="$on $label:${profile_name}"
      else
        off="$off $label:${profile_name}"
      fi
    done
  done <<EOF
$DEN_PERM_BROWSERS
EOF
  if [ "$found" -eq 0 ]; then
    printf 'unknown|no Brave, Chrome or Edge profile found'
    return 0
  fi
  if [ -n "$off" ]; then
    printf 'missing|off in%s; turn it on in View > Developer > Allow JavaScript from Apple Events' "$off"
    return 0
  fi
  printf 'granted|on in%s' "$on"
}

den_permissions_pam_probe() {
  if [ -f /etc/pam.d/sudo_local ] &&
    grep -Eq '^[[:space:]]*auth[[:space:]].*pam_tid' /etc/pam.d/sudo_local 2>/dev/null; then
    printf 'granted|pam_tid is in /etc/pam.d/sudo_local'
    return 0
  fi
  printf 'missing|no pam_tid line in /etc/pam.d/sudo_local; the sudo-touchid phase adds one'
}

den_permissions_devtools_probe() {
  local out
  if [ ! -x /usr/sbin/DevToolsSecurity ]; then
    printf 'unknown|DevToolsSecurity is not on this Mac'
    return 0
  fi
  out=$(/usr/sbin/DevToolsSecurity -status 2>&1) || out=""
  case $out in
    *disabled*) printf 'info|off, and that is the recommendation' ;;
    *enabled*) printf 'info|on; den never changes it, and off is the recommendation' ;;
    *) printf 'unknown|could not read DevToolsSecurity -status' ;;
  esac
}

# Prints "status|detail"; status is granted, missing, unknown or info.
den_permissions_probe() {
  case ${1:-} in
    rex_full_disk_access) den_permissions_rex_probe full_disk_access ;;
    rex_screen_recording) den_permissions_rex_probe screen_recording ;;
    rex_microphone) den_permissions_rex_probe microphone ;;
    peekaboo_accessibility) den_permissions_peekaboo_probe Accessibility ;;
    hex_microphone) den_permissions_hex_probe microphone ;;
    hex_accessibility) den_permissions_hex_probe accessibility ;;
    launchagent_vmup) den_permissions_agent_probe io.mac-bootstrap.vm-up ;;
    launchagent_lima) den_permissions_agent_probe io.lima-vm.autostart.agent ;;
    browser_js) den_permissions_browser_probe ;;
    pam_tid) den_permissions_pam_probe ;;
    devtools) den_permissions_devtools_probe ;;
    *) printf 'unknown|no detector named %s' "${1:-}" ;;
  esac
}

# ── doctor ────────────────────────────────────────────────────────────

den_doctor_permissions() {
  local id label why app_key pane_key detector required probe status detail
  local line msg app_path pane_url missing=0

  if [ "$(den_os)" != macos ]; then
    ui_info "permissions: macOS only, nothing to check"
    return 0
  fi
  den_permissions_cache_clear
  while IFS='|' read -r id label why app_key pane_key detector required; do
    if [ -z "$id" ]; then
      continue
    fi
    probe=$(den_permissions_probe "$detector")
    status=${probe%%|*}
    detail=${probe#*|}
    if [ "$detail" = "$probe" ]; then
      detail=""
    fi
    line=$(printf '%-18s %s' "$id" "$label")
    app_path=$(den_permissions_app "$app_key")
    pane_url=$(den_permissions_pane "$pane_key")
    case $status in
      granted)
        if [ -n "$detail" ]; then
          den_permissions_line granted "$line — $detail"
        else
          den_permissions_line granted "$line"
        fi
        ;;
      missing)
        if [ "$required" = 1 ]; then
          missing=$((missing + 1))
        fi
        msg="$line"
        if [ -n "$detail" ]; then
          msg="$msg — $detail"
        fi
        if [ -n "$pane_url" ]; then
          msg="$msg; fix: $pane_url"
        fi
        if [ -n "$app_path" ] && [ -e "$app_path" ]; then
          msg="$msg; add $app_path"
        fi
        den_permissions_line missing "$msg"
        ;;
      info)
        den_permissions_line info "$line — $detail"
        ;;
      *)
        msg="$line — ${detail:-check the pane}"
        if [ -n "$pane_url" ]; then
          msg="$msg; pane: $pane_url"
        fi
        den_permissions_line unknown "$msg"
        ;;
    esac
  done < <(den_permissions_rows)

  if [ "$missing" -gt 0 ]; then
    if [ "$missing" -eq 1 ]; then
      ui_info "permissions: 1 required grant is missing; den permissions fix walks the panes"
    else
      ui_info "permissions: $missing required grants are missing; den permissions fix walks the panes"
    fi
    return 1
  fi
  return 0
}

# ── walkthrough ───────────────────────────────────────────────────────

den_permissions_missing_scan() {
  local id label why app_key pane_key detector required status n=0
  DEN_PERM_WALK_COUNT=0
  while IFS='|' read -r id label why app_key pane_key detector required; do
    if [ -z "$id" ] || [ "$required" != 1 ]; then
      continue
    fi
    status=$(den_permissions_probe "$detector")
    if [ "${status%%|*}" != missing ]; then
      continue
    fi
    DEN_PERM_WALK_ID[n]=$id
    DEN_PERM_WALK_LABEL[n]="$label"
    DEN_PERM_WALK_WHY[n]="$why"
    DEN_PERM_WALK_APP[n]=$app_key
    DEN_PERM_WALK_PANE[n]=$pane_key
    DEN_PERM_WALK_DET[n]=$detector
    n=$((n + 1))
  done < <(den_permissions_rows)
  DEN_PERM_WALK_COUNT=$n
}

den_permissions_walk() {
  local force=${1:-0} i n id label app pane probe status still="" changed_rex=0

  if [ "$(den_os)" != macos ]; then
    ui_info "permissions: macOS only, nothing to walk"
    return 0
  fi
  if ! den_is_tty; then
    ui_info "permissions: the walkthrough needs a terminal; run den permissions fix in one"
    return 0
  fi
  den_permissions_cache_clear
  den_permissions_missing_scan
  n=$DEN_PERM_WALK_COUNT
  if [ "$n" -eq 0 ]; then
    if [ "$force" = 1 ]; then
      ui_ok "permissions: every required grant is in place"
    fi
    return 0
  fi

  ui_section "macOS permissions"
  if [ "$n" -eq 1 ]; then
    ui_info "1 grant needs a click, and nothing else can do it for you:"
  else
    ui_info "$n grants need a click, and nothing else can do it for you:"
  fi
  for ((i = 0; i < n; i++)); do
    ui_step "${DEN_PERM_WALK_LABEL[$i]} — ${DEN_PERM_WALK_WHY[$i]}"
  done
  if ! ui_confirm "Open System Settings for these now?"; then
    ui_skip "permissions: left for later (den permissions fix)"
    return 0
  fi

  for ((i = 0; i < n; i++)); do
    id=${DEN_PERM_WALK_ID[$i]}
    label=${DEN_PERM_WALK_LABEL[$i]}
    pane=$(den_permissions_pane "${DEN_PERM_WALK_PANE[$i]}")
    app=$(den_permissions_app "${DEN_PERM_WALK_APP[$i]}")
    ui_step "$label"
    if [ -n "$pane" ]; then
      open "$pane" >/dev/null 2>&1 || ui_warn "could not open $pane"
    fi
    if [ -n "$app" ] && [ -d "$app" ]; then
      open -R "$app" >/dev/null 2>&1 || true
      ui_info "add this app (Finder shows it, drag it into the list): $app"
    fi
    if ui_confirm "Done?"; then
      den_permissions_cache_clear
      probe=$(den_permissions_probe "${DEN_PERM_WALK_DET[$i]}")
      status=${probe%%|*}
      if [ "$status" = granted ]; then
        ui_ok "$label: granted"
        case $id in
          rex_*) changed_rex=1 ;;
        esac
      else
        ui_warn "$label: not seen as granted yet; macOS can lag, or the row needs a re-add"
      fi
    else
      ui_skip "$label: left for later"
    fi
  done

  if [ "$changed_rex" = 1 ]; then
    ui_warn "quit Rex completely, then reopen it: TCC reads the identity at launch"
  fi

  den_permissions_cache_clear
  den_permissions_missing_scan
  n=$DEN_PERM_WALK_COUNT
  if [ "$n" -eq 0 ]; then
    ui_ok "permissions: every required grant is now in place"
    return 0
  fi
  for ((i = 0; i < n; i++)); do
    if [ -z "$still" ]; then
      still=${DEN_PERM_WALK_ID[$i]}
    else
      still="$still, ${DEN_PERM_WALK_ID[$i]}"
    fi
  done
  ui_info "permissions: still missing: $still (run den permissions fix again)"
  return 0
}

# ── hooks: preflight and the command ──────────────────────────────────

den_preflight_hook_permissions() {
  if [ "$(den_os)" != macos ]; then
    return 0
  fi
  if ! den_is_tty; then
    return 0
  fi
  den_permissions_walk 0
  return 0
}

den_cmd_permissions() {
  local sub=${1:-show} rc=0
  if [ "$(den_os)" != macos ]; then
    ui_info "permissions: macOS only, nothing to do here"
    exit 0
  fi
  case $sub in
    show|status|'')
      den_doctor_permissions || rc=$?
      ;;
    fix)
      den_permissions_walk 1
      rc=0
      ;;
    help|-h|--help)
      cat <<'EOF'
den permissions           one line per macOS privacy grant (read-only)
den permissions fix       open each missing pane, wait, then re-check

Grants are never written by den: a human ticks them in System Settings. The
walkthrough opens the pane and reveals the app in Finder so you can drag it in.
EOF
      rc=0
      ;;
    *)
      den_die "usage: den permissions [fix]"
      ;;
  esac
  exit "$rc"
}
