# shellcheck shell=bash
# lib/phases/52-rex.sh — Rex.app, its skill and the superlogical MCP.
# No cask exists, so the app comes from the gated Sparkle appcast kept in the
# den bundle. Neither URL is ever printed: not to the screen, not to state.
# Contract: docs/den/CONTRACT.md ("Host vs VM").

# No net need: an installed Rex needs no network, and a missing one reports
# its own download failure, so an offline Mac still gets the MCP registered.
den_phase rex \
  --title "Rex" \
  --about "the Rex app, its skill and the superlogical MCP in Claude Code" \
  --os macos \
  --toggle DEN_REX \
  --needs "secrets net"

# SYSTEM_APPDIR is the system Applications folder; tests point it elsewhere.
rex_find_app() {
  local dir
  for dir in "$HOME/Applications" "${SYSTEM_APPDIR:-/Applications}"; do
    if [ -d "$dir/Rex.app" ]; then
      printf '%s' "$dir/Rex.app"
      return 0
    fi
    if [ -d "$dir/Rex Beta.app" ]; then
      printf '%s' "$dir/Rex Beta.app"
      return 0
    fi
  done
  return 1
}

# install_rex_app <dest_dir> <appcast_url>: newest DMG from the appcast,
# verified before anything reaches <dest_dir>. A failed install must not
# leave a half app behind.
install_rex_app() {
  local dest=$1 appcast_url=$2
  (
    set -e
    local work="" mnt="" dmg="" appcast="" dmg_url="" team="" app=""
    work=$(mktemp -d) || {
      ui_err "Rex: could not make a work dir"
      exit 1
    }
    mnt="$work/mnt"
    dmg="$work/Rex.dmg"
    appcast="$work/appcast.xml"
    trap 'hdiutil detach "$mnt" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
    mkdir -p "$mnt"

    # curl's own errors can echo a gated URL, so they are dropped.
    if ! curl -fsSL --connect-timeout 15 -o "$appcast" "$appcast_url" 2>/dev/null; then
      ui_err "Rex: could not read the appcast"
      exit 1
    fi
    dmg_url=$(sed -n 's/.*<enclosure url="\([^"]*\.dmg[^"]*\)".*/\1/p' "$appcast" | head -n 1 || true) || dmg_url=""
    if [ -z "$dmg_url" ]; then
      ui_err "Rex: the appcast lists no DMG"
      exit 1
    fi

    ui_step "downloading Rex"
    if ! curl -fsSL --connect-timeout 15 -o "$dmg" "$dmg_url" 2>/dev/null; then
      ui_err "Rex: the download failed"
      exit 1
    fi
    if ! hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null 2>&1; then
      ui_err "Rex: could not mount the DMG"
      exit 1
    fi

    app="$mnt/Rex.app"
    if [ ! -d "$app" ]; then
      app=$(find "$mnt" -maxdepth 1 -type d -name '*.app' | head -n 1 || true) || app=""
    fi
    if [ -z "$app" ] || [ ! -d "$app" ]; then
      ui_err "Rex: the DMG contains no app bundle"
      exit 1
    fi
    if ! codesign --verify --deep --strict "$app" 2>/dev/null; then
      ui_err "Rex: the code signature is broken"
      exit 1
    fi
    team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p' || true) || team=""
    if [ "$team" != "AG92C3PT77" ]; then
      ui_err "Rex: signed by ${team:-an unknown team}, not Superlogical (AG92C3PT77)"
      exit 1
    fi
    if ! spctl -a -vv "$app" >/dev/null 2>&1; then
      ui_err "Rex: Gatekeeper rejected the download"
      exit 1
    fi

    if ! mkdir -p "$dest"; then
      ui_err "Rex: could not create $dest"
      exit 1
    fi
    if ! ditto "$app" "$dest/Rex.app"; then
      ui_err "Rex: could not copy Rex.app to $dest"
      exit 1
    fi
    exit 0
  )
}

phase_rex() {
  local app="" appcast="" cli="" claude="$HOME/.local/bin/claude"
  local mcp="" have="" app_status="" app_reason="" app_fix=""

  if app=$(rex_find_app); then
    ui_ok "Rex is installed at $app"
  else
    appcast=$(den_secret .rex.appcast)
    if [ -z "$appcast" ]; then
      app_status=skip
      app_reason="the den bundle has no rex.appcast"
      app_fix="add rex.appcast to the den bundle, then run den fix"
    elif ! install_rex_app "$HOME/Applications" "$appcast"; then
      app_status=fail
      app_reason="Rex.app was not installed"
      app_fix="check rex.appcast in the den bundle, then run den fix"
    elif app=$(rex_find_app); then
      ui_ok "Rex is installed at $app"
    else
      app_status=fail
      app_reason="Rex.app is still missing after the install"
      app_fix="den fix"
    fi
  fi

  if [ -n "$app" ]; then
    cli=${REX_CLI:-}
    if [ -z "$cli" ]; then
      cli="$app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
    fi
    if [ -x "$cli" ]; then
      if "$cli" skill setup >/dev/null 2>&1; then
        ui_ok "rex skill installed into ~/.claude/skills and ~/.agents/skills"
      else
        ui_warn "rex skill setup failed; run it from the app bundle, then den fix"
      fi
    else
      ui_warn "the Rex CLI is not in the app bundle; open Rex once, then den fix"
    fi
  fi

  # The MCP server is Claude Code config, not app config: it needs only the
  # gated URL, so it is registered even when the app install failed.
  if [ ! -x "$claude" ]; then
    ui_info "Claude Code is not installed here; skipping the superlogical MCP"
  else
    mcp=$(den_secret .rex.mcp)
    if [ -z "$mcp" ]; then
      ui_info "the den bundle has no rex.mcp; skipping the superlogical MCP"
    else
      # Compare without printing either URL: the stored one is gated.
      have=$("$claude" mcp get superlogical 2>/dev/null || true) || have=""
      if printf '%s' "$have" | grep -Fq -- "$mcp"; then
        ui_ok "superlogical MCP is already registered in Claude Code"
      else
        "$claude" mcp remove superlogical >/dev/null 2>&1 || true
        if "$claude" mcp add -s user --transport http superlogical "$mcp" >/dev/null 2>&1; then
          ui_ok "superlogical MCP registered in Claude Code"
        else
          ui_warn "could not register the superlogical MCP in Claude Code"
        fi
      fi
    fi
  fi

  if [ -n "$app_status" ]; then
    if [ "$app_status" = skip ]; then
      den_skip "$app_reason" "$app_fix"
    fi
    den_fail "$app_reason" "$app_fix"
  fi
}
