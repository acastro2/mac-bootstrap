# shellcheck shell=bash
# 26-macos-defaults.sh — keyboard, Finder, Dock and appearance.
# Every write is guarded: an MDM-managed key warns instead of aborting the phase.

den_phase macos-defaults \
  --title "macOS defaults" \
  --about "Key repeat, Finder, Dock, screenshots and dark mode" \
  --os macos \
  --toggle DEN_MACOS_DEFAULTS

den_defaults_write() {
  local key=$1 type=$2 value=$3
  if ! defaults write "$key" "$type" "$value" >/dev/null 2>&1; then
    ui_warn "could not set $key (MDM-managed or not permitted); skipped"
  fi
}

phase_macos_defaults() {
  ui_step "keyboard: fast key repeat, no press-and-hold"
  den_defaults_write -g KeyRepeat -int 2
  den_defaults_write -g InitialKeyRepeat -int 15
  den_defaults_write -g ApplePressAndHoldEnabled -bool false

  ui_step "Finder: show extensions and hidden files"
  den_defaults_write NSGlobalDomain AppleShowAllExtensions -bool true
  den_defaults_write com.apple.finder AppleShowAllFiles -bool true

  ui_step "screenshots land in ~/Screenshots"
  mkdir -p "$HOME/Screenshots" 2>/dev/null || ui_warn "could not create ~/Screenshots"
  den_defaults_write com.apple.screencapture location -string "$HOME/Screenshots"

  ui_step "Dock: left, auto-hide, no delay"
  den_defaults_write com.apple.dock orientation -string left
  den_defaults_write com.apple.dock autohide -bool true
  den_defaults_write com.apple.dock autohide-delay -float 0
  den_defaults_write com.apple.dock autohide-time-modifier -float 0.3

  ui_step "no .DS_Store on network volumes"
  den_defaults_write com.apple.desktopservices DSDontWriteNetworkStores -bool true

  ui_step "accent and highlight: orange"
  den_defaults_write NSGlobalDomain AppleAccentColor -int 1
  den_defaults_write NSGlobalDomain AppleHighlightColor -string "1.000000 0.874510 0.701961 Orange"

  # System Events saves the setting AND repaints every app, but it skips the
  # repaint when the saved value already says Dark. Flip it off and on.
  ui_step "appearance: dark"
  if ! osascript \
    -e 'tell application "System Events" to tell appearance preferences to set dark mode to false' \
    -e 'tell application "System Events" to tell appearance preferences to set dark mode to true' \
    >/dev/null 2>&1; then
    ui_warn "could not switch dark mode live (allow the terminal to control System Events); it applies at the next login"
    defaults write NSGlobalDomain AppleInterfaceStyle -string Dark 2>/dev/null || true
  fi

  killall Dock Finder SystemUIServer >/dev/null 2>&1 || true
  ui_ok "macOS defaults set (key repeat and accent colour apply after a login)"
}
