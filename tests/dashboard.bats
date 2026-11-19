#!/usr/bin/env bats
# den_dashboard_now: the browse pairing hint. Stubbed curl, limactl, browse.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  HOME="$TMP/home"; export HOME
  mkdir -p "$HOME/.local/bin" "$TMP/bin"
  export PATH="$TMP/bin:/usr/bin:/bin"
  printf '#!/bin/sh\necho 200\n' > "$TMP/bin/curl"
  printf '#!/bin/sh\n[ "$1" = list ] && echo Running\nexit 0\n' > "$TMP/bin/limactl"
  chmod +x "$TMP/bin/curl" "$TMP/bin/limactl"
  for lib in ui core vm cli; do
    # shellcheck source=/dev/null
    . "$REPO/lib/$lib.sh"
  done
  den_os() { printf macos; }
}

teardown() { /bin/rm -rf "$TMP"; }

browse_list() {
  printf '#!/bin/sh\n[ "$1 $2" = "pair --list" ] && echo "%s"\nexit 0\n' "$1" > "$HOME/.local/bin/browse"
  chmod +x "$HOME/.local/bin/browse"
}

@test "no paired browser: tells you to pair from the Mac, not the VM" {
  browse_list "No paired browsers. Run \`browse pair\` for a code."
  run den_dashboard_now
  [ "$status" -eq 0 ]
  printf "%s\n" "$output" | grep -F "no browser paired"
  printf "%s\n" "$output" | grep -F "on the Mac"
}

@test "paired browser: no pairing hint" {
  browse_list "edge-mac  Edge on MAC"
  run den_dashboard_now
  [ "$status" -eq 0 ]
  ! printf "%s\n" "$output" | grep -F "no browser paired"
}
