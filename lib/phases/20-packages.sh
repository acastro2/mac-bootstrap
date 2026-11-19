# shellcheck shell=bash
# 20-packages.sh — Homebrew bundle for this host: Brewfile on the Mac,
# Brewfile.linux in the VM.

den_phase packages \
  --title "Packages" \
  --about "Homebrew bundle: the Mac package list, or the VM list on Linux" \
  --os any \
  --needs "brew net"

# Print "tap|url" for every tap the Brewfile declares; url is empty when the
# repo is named homebrew-* and brew can find it by name.
den_packages_taps() {
  local file=$1
  awk -F'"' '/^[[:space:]]*tap[[:space:]]/ { url = ""; if (NF >= 4) url = $4; print $2 "|" url }' "$file"
}

phase_packages() {
  local brewfile trusts tap tap_url
  brewfile=${DEN_ROOT:-}/Brewfile
  if [ "$(den_os)" = linux ]; then
    brewfile=${DEN_ROOT:-}/Brewfile.linux
  fi
  if [ ! -r "$brewfile" ]; then
    den_fail "cannot read ${brewfile##*/}" \
      "restore ${brewfile##*/} in the den repo, then run den up --only=packages"
  fi

  # Homebrew refuses formulae from a third-party tap until it is trusted. A tap
  # whose repo is not named homebrew-* needs its URL (tap "a/b", "URL").
  trusts=0
  if brew trust --help >/dev/null 2>&1; then
    trusts=1
  fi
  while IFS='|' read -r tap tap_url; do
    if [ -z "$tap" ]; then
      continue
    fi
    if [ "$trusts" = 1 ]; then
      if [ -n "$tap_url" ]; then
        brew tap "$tap" "$tap_url" >/dev/null 2>&1 || true
      else
        brew tap "$tap" >/dev/null 2>&1 || true
      fi
      brew trust "$tap" >/dev/null 2>&1 || ui_warn "could not trust tap $tap"
    fi
  done < <(den_packages_taps "$brewfile")

  # A cask whose app Jamf/MDM already keeps in /Applications is left out, so
  # brew never installs a second copy into ~/Applications (lib/registry.sh).
  local external="" filtered="" label=${brewfile##*/}
  if [ "$(den_os)" = macos ]; then
    external=$(den_registry_external_casks | tr '\n' ' ')
  fi
  if [ -n "${external// /}" ]; then
    filtered=$(mktemp "${TMPDIR:-/tmp}/den-Brewfile.XXXXXX") || filtered=""
  fi
  if [ -n "$filtered" ]; then
    awk -v skip=" $external " '
      /^[[:space:]]*cask[[:space:]]+"/ {
        t = $0; sub(/^[[:space:]]*cask[[:space:]]+"/, "", t); sub(/".*/, "", t)
        if (index(skip, " " t " ")) next
      }
      { print }' "$brewfile" >"$filtered"
    ui_info "managed in /Applications (Jamf/MDM), not installed by brew: ${external% }"
    brewfile=$filtered
  fi

  # --no-upgrade maps the machine to an installed set; upgrades stay explicit.
  # </dev/null keeps brew from reading the loop's stdin.
  ui_step "brew bundle --file=$label --no-upgrade"
  # One retry: on a fresh host, formulae from a just-tapped tap can fail inside
  # the first bundle and then install cleanly (seen on a new VM with
  # opentunnel and rex-agent-restore). The second pass only does what is left.
  if ! brew bundle --file="$brewfile" --no-upgrade </dev/null &&
    ! { ui_step "brew bundle again (the first pass had failures)"; brew bundle --file="$brewfile" --no-upgrade </dev/null; }; then
    [ -z "$filtered" ] || rm -f "$filtered"
    den_fail "brew bundle had failures" \
      "fix the failing line in $label, then run den up --only=packages"
  fi
  [ -z "$filtered" ] || rm -f "$filtered"
  ui_ok "packages from $label are installed"
}
