#!/usr/bin/env bats
# Lane C acceptance: VM boundary, vm-up self-healing, guest provisioning,
# `den vm`. Contract: docs/den/CONTRACT.md ("VM guest").

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  export DEN_UI=plain DEN_PROBE_NET=ok DEN_STATE_DIR="$TMP/state"
  export CALLS="$TMP/calls.log" GUEST="$TMP/guest-scripts.log"
  export VM_UP_STATE_DIR="$TMP/vmup" VM_UP_ONCE=1 VM_UP_WAIT=0
  export SYSTEM_APPDIR="$TMP/sysapps"
  mkdir -p "$HOME/.local/bin" "$HOME/.ssh" "$TMP/bin" "$SYSTEM_APPDIR"
  export PATH="$TMP/bin:/usr/bin:/bin"
  # limactl: log args; `list` answers $LIMA_LIST (JSON) or $LIMA_STATUS
  # (--format); a `bash -s` guest script is captured from stdin.
  cat > "$TMP/bin/limactl" <<'STUB'
#!/bin/bash
printf 'limactl %s\n' "$*" >> "$CALLS"
if [[ " $* " == *" bash -s"* ]]; then cat >> "$GUEST"; fi
if [ "$1" = list ]; then
  if [[ " $* " == *" json"* ]]; then [ -n "${LIMA_LIST:-}" ] && printf '%s\n' "$LIMA_LIST"
  else printf '%s\n' "${LIMA_STATUS:-}"; fi
fi
[ "$1" = shell ] && [ -n "${GUEST_FAIL:-}" ] && exit 1
exit 0
STUB
  for c in launchctl code brew rex ssh curl; do
    printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "$CALLS"\nexit 0\n' "$c" > "$TMP/bin/$c"
  done
  chmod +x "$TMP/bin/"*
  export REX_CLI="$TMP/bin/rex"
}

teardown() { /bin/rm -rf "$TMP"; }

macos_only() { [ "$(uname)" = "Darwin" ] || skip "macOS only"; }

@test "lima-dev.yaml: no SSH agent forwarding, no mounts, relay port not mirrored" {
  y="$REPO/vm/lima-dev.yaml"
  grep -E '^\s*forwardAgent:\s*false' "$y"
  grep -E '^mounts:\s*\[\]' "$y"
  grep -E 'guestPort:\s*19988' "$y"
}

@test "vm-up: a missing instance is rebuilt once, then backs off" {
  printf '#!/bin/sh\nprintf "bootstrap %%s\\n" "$*" >> "%s"\n' "$CALLS" > "$TMP/bootstrap.sh"; chmod +x "$TMP/bootstrap.sh"
  export VM_UP_BOOTSTRAP="$TMP/bootstrap.sh" LIMA_STATUS=""
  run "$REPO/vm/vm-up.sh" --step
  run "$REPO/vm/vm-up.sh" --step
  run "$REPO/vm/vm-up.sh" --step
  [ "$(grep -c '^bootstrap ' "$CALLS")" -eq 1 ]
}

@test "vm-up: a Broken VM is not restarted in a tight loop either" {
  export LIMA_STATUS=Broken
  for i in 1 2 3; do run "$REPO/vm/vm-up.sh" --step; done
  [ "$(grep -c '^limactl start' "$CALLS")" -le 1 ]
}

@test "vm-up: the same code request twice opens VS Code once" {
  run "$REPO/vm/vm-up.sh" --open-line /home/x/repo
  run "$REPO/vm/vm-up.sh" --open-line /home/x/repo
  [ "$(grep -c '^code --folder-uri' "$CALLS")" -eq 1 ]
}

@test "vm-up: --heal fails when the guest heal fails" {
  export LIMA_STATUS=Running GUEST_FAIL=1
  run "$REPO/vm/vm-up.sh" --heal
  [ "$status" -ne 0 ]
}

@test "vm phase: inside the vm-up agent it never kickstarts itself" {
  macos_only
  export VM_UP_AGENT=1 LIMA_LIST='{"name":"agent","status":"Running","cpus":64,"memory":274877906944,"disk":42949672960}'
  run "$REPO/bin/den" up --only=vm
  ! grep -q '^launchctl kickstart' "$CALLS"
}

@test "vm phase: guest gets Docker Engine, den sudoers, Obsidian Headless without config sync" {
  macos_only
  export LIMA_LIST='{"name":"agent","status":"Running","cpus":64,"memory":274877906944,"disk":42949672960}'
  run "$REPO/bin/den" up --only=vm
  grep -F 'download.docker.com' "$GUEST"
  grep -F 'docker-compose-plugin' "$GUEST"
  grep -E 'usermod -aG docker' "$GUEST"
  grep -E 'visudo -c' "$GUEST"
  grep -F '/etc/sudoers.d/' "$GUEST"
  grep -F 'obsidian-headless' "$GUEST"
  grep -E -- '--configs ""' "$GUEST"
}

@test "den vm down turns off both login agents before stopping the VM" {
  macos_only
  export LIMA_STATUS=Running
  run "$REPO/bin/den" vm down
  [ "$status" -eq 0 ]
  bo="$(grep -n '^launchctl bootout' "$CALLS" | head -1 | cut -d: -f1)"
  ad="$(grep -n '^limactl autostart disable' "$CALLS" | head -1 | cut -d: -f1)"
  st="$(grep -n '^limactl stop' "$CALLS" | head -1 | cut -d: -f1)"
  [ -n "$bo" ] && [ -n "$ad" ] && [ -n "$st" ] && [ "$bo" -lt "$st" ] && [ "$ad" -lt "$st" ]
}

@test "den vm up turns both back on" {
  macos_only
  export LIMA_STATUS=Stopped
  run "$REPO/bin/den" vm up
  grep -q '^limactl autostart enable' "$CALLS"
  grep -q '^launchctl bootstrap' "$CALLS"
}

@test "guest logins never use limactl shell -t (Lima has no such flag)" {
  ! grep -rn 'limactl shell -t' "$REPO/lib" "$REPO/vm" "$REPO/bin"
  grep -q 'limactl shell --tty=true' "$REPO/lib/vm.sh"
}

@test "the docker-group check compares the numeric GID: /proc never lists group names" {
  ! grep -n 'Groups:.*docker' "$REPO/vm/guest-provision.sh" "$REPO/lib/phases/70-vm.sh"
  grep -q 'getent group docker' "$REPO/vm/guest-provision.sh"
  grep -q 'getent group docker' "$REPO/lib/phases/70-vm.sh"
  # The same awk, on a status line like the guest's: GID 988 is found, 4242 is not.
  printf 'Name:\tsystemd\nGroups:\t988 999 1000 \n' > "$TMP/status"
  awk -v g=988 '/^Groups:/ { for (i = 2; i <= NF; i++) if ($i == g) f = 1 } END { exit !f }' "$TMP/status"
  ! awk -v g=4242 '/^Groups:/ { for (i = 2; i <= NF; i++) if ($i == g) f = 1 } END { exit !f }' "$TMP/status"
}
