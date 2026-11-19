# shellcheck shell=bash
# 22-appdir.sh — move casks and Rex into ~/Applications, where a self-update
# needs no admin.

den_phase appdir \
  --title "Apps in ~/Applications" \
  --about "Move every managed app out of /Applications so self-updates need no admin" \
  --os macos \
  --needs "brew"

phase_appdir() {
  local sys appdir token app moved=0
  sys=$(den_registry_system_appdir)
  appdir=$HOME/Applications
  mkdir -p "$appdir"

  # brew uninstall then install: brew reinstall leaves the old copy behind.
  # HOMEBREW_NO_AUTOREMOVE=1 keeps an uninstall from taking unrelated formulae.
  while IFS='|' read -r token app; do
    if [ -z "$app" ] || [ ! -d "$sys/$app" ]; then
      continue
    fi
    moved=1
    if [ -e "$appdir/$app" ]; then
      ui_warn "duplicate $app: $sys and $appdir; delete the $sys copy"
      continue
    fi
    if pgrep -f "$sys/$app/Contents/MacOS/" >/dev/null 2>&1; then
      ui_warn "Quit ${app%.app}, then re-run: den up --only=appdir"
      continue
    fi
    if ! HOMEBREW_NO_AUTOREMOVE=1 brew uninstall --cask "$token" </dev/null; then
      ui_warn "could not uninstall $token; $app stays in $sys"
      continue
    fi
    if ! HOMEBREW_NO_AUTOREMOVE=1 brew install --cask --appdir="$appdir" "$token" </dev/null; then
      den_fail "$token is uninstalled but the reinstall failed" \
        "run den up --only=packages, then den up --only=appdir"
    fi
    ui_ok "$app moved to $appdir"
  done < <(den_registry_cask_apps)

  # Rex has no cask: move the bundle itself.
  for app in "Rex.app" "Rex Beta.app"; do
    if [ ! -d "$sys/$app" ]; then
      continue
    fi
    moved=1
    if pgrep -f "$sys/$app/Contents/MacOS/" >/dev/null 2>&1; then
      ui_warn "Quit Rex, then re-run: den up --only=appdir"
      continue
    fi
    if [ -e "$appdir/$app" ]; then
      ui_warn "duplicate $app: $sys and $appdir; delete the $sys copy"
      continue
    fi
    if mv "$sys/$app" "$appdir/$app"; then
      ui_ok "$app moved to $appdir"
    else
      den_fail "could not move $sys/$app" "sudo mv \"$sys/$app\" \"$appdir/$app\""
    fi
  done

  if [ "$moved" = 0 ]; then
    ui_ok "all managed apps are in $appdir"
  fi
}
