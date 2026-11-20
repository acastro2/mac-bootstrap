#!/usr/bin/env bats
# Login-item probe: a registered agent is fine even when launchd has not
# loaded it yet (Lima registers at `autostart enable`, macOS loads at login).
# launchctl is a stub; nothing touches the real launchd.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  mkdir -p "$HOME/Library/LaunchAgents" "$TMP/bin"
  export PATH="$TMP/bin:/usr/bin:/bin"
  export STUB_PRINT=1 STUB_DISABLED=""
  cat > "$TMP/bin/launchctl" <<'STUB'
#!/bin/sh
case "$1" in
  print) exit "$STUB_PRINT" ;;
  print-disabled) printf 'disabled services = {\n%s\n}\n' "$STUB_DISABLED" ;;
esac
STUB
  chmod +x "$TMP/bin/launchctl"
  # shellcheck source=/dev/null
  . "$REPO/lib/permissions.sh"
}

teardown() { /bin/rm -rf "$TMP"; }

probe() { den_permissions_agent_probe io.lima-vm.autostart.agent; }
plist() { : > "$HOME/Library/LaunchAgents/io.lima-vm.autostart.agent.plist"; }

@test "loaded agent is granted" {
  STUB_PRINT=0 run probe
  [ "$output" = "granted|loaded" ]
}

@test "registered but not loaded yet is granted, loads at next login" {
  plist
  STUB_DISABLED='"io.lima-vm.autostart.agent" => enabled'
  run probe
  [[ "$output" == granted\|* ]]
  [[ "$output" == *"next login"* ]]
}

@test "registered and disabled in launchd asks for approval" {
  plist
  STUB_DISABLED='"io.lima-vm.autostart.agent" => disabled'
  run probe
  [[ "$output" == unknown\|* ]]
  [[ "$output" == *"Login Items"* ]]
}

@test "no plist says not installed" {
  run probe
  [[ "$output" == unknown\|*"not installed"* ]]
}
