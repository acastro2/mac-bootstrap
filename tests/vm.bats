#!/usr/bin/env bats
# The agent VM: how it is sized from the Mac, and what the vm phase asks
# limactl to do. Nothing touches the real machine: HOME is a temp dir, host
# facts come from HOST_* overrides, and limactl and rex are stubs that log.

# Found before setup() narrows PATH.
YQ_BIN=$(command -v yq || true)

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  HOME="$TMP/home"
  export HOME
  # den: plain output, no network probe, state in the temp HOME.
  export DEN_UI=plain DEN_PROBE_NET=ok DEN_STATE_DIR="$TMP/state"
  export LIMA_LOG="$TMP/limactl.log"
  mkdir -p "$HOME/.local/bin" "$HOME/.ssh" "$HOME/.config/zsh" "$TMP/bin"
  export PATH="$TMP/bin:$HOME/.local/bin:/usr/bin:/bin"
  : > "$HOME/.config/zsh/.api-keys.zsh"

  for cmd in npm gh op mise docker uv brew pgrep; do
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$cmd"
    chmod +x "$TMP/bin/$cmd"
  done

  # limactl: log every call. `list --format json` answers from $LIMA_LIST,
  # which a test fills to describe an existing instance (empty = none).
  cat > "$TMP/bin/limactl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LIMA_LOG"
if [ "$1" = "list" ]; then
  [ -n "$LIMA_LIST" ] && printf '%s\n' "$LIMA_LIST"
fi
if [ "$1" = "shell" ] && [ -n "$LIMA_SHELL_OUT" ]; then
  printf '%s\n' "$LIMA_SHELL_OUT"
fi
exit 0
STUB
  chmod +x "$TMP/bin/limactl"

  # launchctl: never reach the real launchd from a test.
  export LAUNCH_LOG="$TMP/launchctl.log"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$LAUNCH_LOG"\nexit 0\n' > "$TMP/bin/launchctl"
  chmod +x "$TMP/bin/launchctl"

  # A Mac with 10 cores, 32 GiB RAM and 200 GiB free.
  export HOST_NCPU=10
  export HOST_MEM_BYTES=$((32 * 1024 * 1024 * 1024))
  export HOST_FREE_BYTES=$((200 * 1024 * 1024 * 1024))
}

teardown() {
  /bin/rm -rf "$TMP"
}

macos_only() {
  [ "$(uname)" = "Darwin" ] || skip "macOS only"
}

@test "vm resources: 10 cores, 32 GiB, roomy disk: all cores, RAM minus 12" {
  run "$REPO/bin/den" vm resources
  [ "$status" -eq 0 ]
  [[ "$output" == *"cpus=10 memory=20 disk=100"* ]]
}

@test "vm resources: small Mac keeps macOS 8 GiB and floors the VM" {
  export HOST_NCPU=4 HOST_MEM_BYTES=$((8 * 1024 * 1024 * 1024))
  run "$REPO/bin/den" vm resources
  [ "$status" -eq 0 ]
  [[ "$output" == *"cpus=4 memory=4 "* ]]
}

@test "vm resources: 16 GiB Mac gives the VM 8" {
  export HOST_NCPU=8 HOST_MEM_BYTES=$((16 * 1024 * 1024 * 1024))
  run "$REPO/bin/den" vm resources
  [ "$status" -eq 0 ]
  [[ "$output" == *"cpus=8 memory=8 "* ]]
}

@test "vm resources: 64 GiB Mac keeps macOS 12 GiB" {
  export HOST_NCPU=16 HOST_MEM_BYTES=$((64 * 1024 * 1024 * 1024))
  run "$REPO/bin/den" vm resources
  [ "$status" -eq 0 ]
  [[ "$output" == *"cpus=16 memory=52 "* ]]
}

@test "vm resources: disk is half the free space, floored at 40" {
  export HOST_FREE_BYTES=$((120 * 1024 * 1024 * 1024))
  run "$REPO/bin/den" vm resources
  [[ "$output" == *"disk=60"* ]]

  export HOST_FREE_BYTES=$((15 * 1024 * 1024 * 1024))
  run "$REPO/bin/den" vm resources
  [[ "$output" == *"disk=40"* ]]
  [[ "$output" == *"low disk"* ]]
}

@test "vm phase creates a sized instance when none exists" {
  macos_only
  run "$REPO/bin/den" up --only=vm
  [ "$status" -eq 0 ]
  grep -E -- "^create --name=agent .*--cpus=10 --memory=20 --disk=100 .*vm/lima-dev.yaml" "$LIMA_LOG"
  grep -E -- "^start agent" "$LIMA_LOG"
}

@test "vm phase resizes a stopped instance that is too small" {
  macos_only
  export LIMA_LIST='{"name":"agent","status":"Stopped","cpus":4,"memory":8589934592,"disk":42949672960}'
  run "$REPO/bin/den" up --only=vm
  [ "$status" -eq 0 ]
  grep -E -- "^edit agent .*--cpus=10 --memory=20" "$LIMA_LOG"
  ! grep -E -- "^create" "$LIMA_LOG"
}

@test "vm phase never resizes a running instance" {
  macos_only
  export LIMA_LIST='{"name":"agent","status":"Running","cpus":4,"memory":8589934592,"disk":42949672960}'
  run "$REPO/bin/den" up --only=vm
  [ "$status" -eq 0 ]
  ! grep -E -- "^edit" "$LIMA_LOG"
  [[ "$output" == *"limactl stop agent"* ]]
}

# Escape path U1 (docs/den/JAILBREAK.md): the guest must not reach the Mac's
# loopback through host.lima.internal.
@test "vm template blocks the guest from the Mac loopback" {
  grep -qE '^networkOpts:' "$REPO/vm/lima-dev.yaml"
  grep -qE '^  hostLoopback: false' "$REPO/vm/lima-dev.yaml"
}

# Escape path U7: Lima mirrors guest ports onto the Mac's localhost. Only
# dev-server ports (1024-9999) may be mirrored, so the VM can never take an
# ephemeral port (49152-65535) that a Mac CLI login waits on. Rules are
# first-match, so the order is the contract.
@test "vm template mirrors only 1024-9999, never the relay, nothing else" {
  [ -n "$YQ_BIN" ] || skip "yq missing"
  run "$YQ_BIN" -o json -I0 '.portForwards' "$REPO/vm/lima-dev.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"guestPort":19988,"ignore":true},{"guestPortRange":[1024,9999]},{"guestIP":"0.0.0.0","guestIPMustBeZero":false,"proto":"any","ignore":true}]' ]
}

@test "vm phase limits the port mirror on a stopped instance that mirrors everything" {
  macos_only
  export LIMA_LIST='{"name":"agent","status":"Stopped","cpus":10,"memory":21474836480,"disk":107374182400}'
  mkdir -p "$HOME/.lima/agent"
  printf 'vmType: vz\nnetworkOpts:\n  hostLoopback: false\nportForwards:\n  - guestPort: 19988\n    ignore: true\n' > "$HOME/.lima/agent/lima.yaml"
  run "$REPO/bin/den" up --only=vm
  [ "$status" -eq 0 ]
  grep -E -- "^edit agent .*--set \.portForwards ?= ?" "$LIMA_LOG"
  grep -F -- '1024' "$LIMA_LOG"
}

@test "vm phase never edits a running instance for the port mirror, and says how" {
  macos_only
  export LIMA_LIST='{"name":"agent","status":"Running","cpus":10,"memory":21474836480,"disk":107374182400}'
  mkdir -p "$HOME/.lima/agent"
  printf 'vmType: vz\nnetworkOpts:\n  hostLoopback: false\nportForwards:\n  - guestPort: 19988\n    ignore: true\n' > "$HOME/.lima/agent/lima.yaml"
  run "$REPO/bin/den" up --only=vm
  [ "$status" -eq 0 ]
  ! grep -E -- "^edit" "$LIMA_LOG"
  [[ "$output" == *"mirrors every port"* ]]
  [[ "$output" == *"limactl stop agent"* ]]
}

@test "vm phase blocks the Mac loopback on a stopped instance that allows it" {
  macos_only
  export LIMA_LIST='{"name":"agent","status":"Stopped","cpus":10,"memory":21474836480,"disk":107374182400}'
  mkdir -p "$HOME/.lima/agent"
  printf 'vmType: vz\n' > "$HOME/.lima/agent/lima.yaml"
  run "$REPO/bin/den" up --only=vm
  [ "$status" -eq 0 ]
  grep -E -- "^edit agent .*--set \.networkOpts\.hostLoopback ?= ?false" "$LIMA_LOG"
}

@test "vm phase leaves a stopped instance alone when the loopback is already blocked" {
  macos_only
  export LIMA_LIST='{"name":"agent","status":"Stopped","cpus":10,"memory":21474836480,"disk":107374182400}'
  mkdir -p "$HOME/.lima/agent"
  printf 'vmType: vz\nnetworkOpts:\n  hostLoopback: false\n' > "$HOME/.lima/agent/lima.yaml"
  run "$REPO/bin/den" up --only=vm
  [ "$status" -eq 0 ]
  ! grep -E -- "^edit agent .*hostLoopback" "$LIMA_LOG"
}

@test "vm phase never edits a running instance for the loopback, and says how" {
  macos_only
  export LIMA_LIST='{"name":"agent","status":"Running","cpus":10,"memory":21474836480,"disk":107374182400}'
  mkdir -p "$HOME/.lima/agent"
  printf 'vmType: vz\n' > "$HOME/.lima/agent/lima.yaml"
  run "$REPO/bin/den" up --only=vm
  [ "$status" -eq 0 ]
  ! grep -E -- "^edit" "$LIMA_LOG"
  [[ "$output" == *"limactl stop agent"* ]]
}

@test "doctor fails when the guest can reach the Mac loopback" {
  macos_only
  export LIMA_LIST='{"name":"agent","status":"Running","cpus":10,"memory":21474836480,"disk":107374182400}'
  export LIMA_SHELL_OUT='hostloop=open'
  run "$REPO/bin/den" doctor --strict
  [ "$status" -eq 1 ]
  [[ "$output" == *"host loopback"* ]]
}

@test "doctor passes the loopback check when the guest is blocked" {
  macos_only
  export LIMA_LIST='{"name":"agent","status":"Running","cpus":10,"memory":21474836480,"disk":107374182400}'
  export LIMA_SHELL_OUT='hostloop=closed'
  run "$REPO/bin/den" doctor
  [[ "$output" == *"host loopback blocked"* ]]
}

@test "vm phase adds the Lima ssh include once and backs up the config" {
  macos_only
  printf 'Host *\n  IdentityAgent x\n' > "$HOME/.ssh/config"
  run "$REPO/bin/den" up --only=vm
  run "$REPO/bin/den" up --only=vm
  [ "$(grep -c 'Include ~/.lima/\*/ssh.config' "$HOME/.ssh/config")" -eq 1 ]
  # The include must come before any Host block, or ssh ignores it there.
  [ "$(head -1 "$HOME/.ssh/config")" = "Include ~/.lima/*/ssh.config" ]
  ls "$HOME"/.ssh/config.bak.* >/dev/null
}

@test "vm phase registers the instance to start at login" {
  macos_only
  run "$REPO/bin/den" up --only=vm
  grep -E -- "^autostart enable agent" "$LIMA_LOG"
}

@test "vm phase copies the keys file into the guest with mode 600" {
  macos_only
  run "$REPO/bin/den" up --only=vm
  grep -E -- "^copy .*\.api-keys\.zsh agent:" "$LIMA_LOG"
  grep -E -- "^shell agent .*chmod 600" "$LIMA_LOG"
}

@test "vm phase installs and loads the vm-up login agent" {
  macos_only
  run "$REPO/bin/den" up --only=vm
  [ "$status" -eq 0 ]
  plist="$HOME/Library/LaunchAgents/io.mac-bootstrap.vm-up.plist"
  [ -f "$plist" ]
  grep -F "vm/vm-up.sh" "$plist"
  grep -F "<key>KeepAlive</key>" "$plist"
  grep -E "^bootstrap gui/[0-9]+ $plist" "$LAUNCH_LOG"
}

@test "vm phase copies the browse relay token with mode 600" {
  macos_only
  mkdir -p "$HOME/.local/share/browse"
  : > "$HOME/.local/share/browse/relay-token"
  run "$REPO/bin/den" up --only=vm
  grep -E -- "^copy .*browse/relay-token agent:" "$LIMA_LOG"
  grep -E -- "^shell agent .*chmod 600 .*relay-token" "$LIMA_LOG"
}

@test "guest bootstrap installs the browse CLI" {
  macos_only
  run "$REPO/bin/den" up --only=vm
  grep -F "@opencode/browse" "$LIMA_LOG"
}
