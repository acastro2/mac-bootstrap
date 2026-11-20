#!/usr/bin/env bats
# vm/vm-up.sh: one pass (VM_UP_ONCE=1) with stubbed limactl, curl, browse, rex.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  HOME="$TMP/home"; export HOME
  export CALLS="$TMP/calls.log" VM_UP_ONCE=1 VM_UP_WAIT=0
  mkdir -p "$HOME/.local/bin" "$TMP/bin"
  export PATH="$TMP/bin:/usr/bin:/bin"
  for cmd in limactl curl rex; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "$CALLS"\n' "$cmd" > "$TMP/bin/$cmd"
    chmod +x "$TMP/bin/$cmd"
  done
  printf '#!/bin/sh\nprintf "browse %%s\\n" "$*" >> "$CALLS"\n' > "$HOME/.local/bin/browse"
  chmod +x "$HOME/.local/bin/browse"
  export REX_CLI="$TMP/bin/rex"
}

teardown() { /bin/rm -rf "$TMP"; }

vm_status() {
  printf '#!/bin/sh\nprintf "limactl %%s\\n" "$*" >> "$CALLS"\n[ "$1" = list ] && echo %s\nexit 0\n' "$1" > "$TMP/bin/limactl"
  chmod +x "$TMP/bin/limactl"
}

@test "running VM: no start, tunnel opened into vm" {
  vm_status Running
  run "$REPO/vm/vm-up.sh"
  [ "$status" -eq 0 ]
  ! grep -F "limactl start" "$CALLS"
  grep -F "rex -S vm forward new --session den -R 127.0.0.1:19988:127.0.0.1:19988" "$CALLS"
}

@test "tunnel: a fresh guest server gets the den session before the forward" {
  vm_status Running
  run "$REPO/vm/vm-up.sh"
  [ "$status" -eq 0 ]
  grep -F "rex -S vm session ls" "$CALLS"
  grep -F "rex -S vm session new den" "$CALLS"
  # the session is made before the forward that lives in it
  [ "$(grep -n -F 'session new den' "$CALLS" | cut -d: -f1)" -lt "$(grep -n -F 'forward new' "$CALLS" | cut -d: -f1)" ]
}

@test "tunnel: an existing den session is reused, not created again" {
  vm_status Running
  printf '#!/bin/sh\nprintf "rex %%s\\n" "$*" >> "$CALLS"\ncase "$*" in *"session ls"*) printf "LABEL  ID\\nden    abc123\\n" ;; esac\nexit 0\n' > "$TMP/bin/rex"
  chmod +x "$TMP/bin/rex"
  run "$REPO/vm/vm-up.sh"
  [ "$status" -eq 0 ]
  ! grep -F "session new" "$CALLS"
  grep -F "forward new --session den" "$CALLS"
}

@test "stopped VM: started before the tunnel" {
  vm_status Stopped
  run "$REPO/vm/vm-up.sh"
  grep -F "limactl start agent" "$CALLS"
}

@test "relay down: browse serve started" {
  vm_status Running
  printf '#!/bin/sh\nprintf "curl %%s\\n" "$*" >> "$CALLS"\nexit 7\n' > "$TMP/bin/curl"
  run "$REPO/vm/vm-up.sh"
  sleep 1
  grep -F "browse serve" "$CALLS"
}

@test "relay up: browse serve not started" {
  vm_status Running
  run "$REPO/vm/vm-up.sh"
  sleep 1
  ! grep -F "browse serve" "$CALLS"
}

@test "missing instance: rebuilt by the vm phase, never a bare limactl start" {
  vm_status ""
  printf '#!/bin/sh\nprintf "bootstrap %%s\\n" "$*" >> "$CALLS"\n' > "$TMP/bootstrap.sh"
  chmod +x "$TMP/bootstrap.sh"
  export VM_UP_BOOTSTRAP="$TMP/bootstrap.sh"
  run "$REPO/vm/vm-up.sh"
  grep -F "bootstrap --only=vm" "$CALLS"
  ! grep -F "limactl start" "$CALLS"
}

@test "heal: runs the guest heal script and syncs a changed keys file" {
  vm_status Running
  mkdir -p "$HOME/.config/zsh"; echo 'export A=1' > "$HOME/.config/zsh/.api-keys.zsh"
  run "$REPO/vm/vm-up.sh" --heal
  [ "$status" -eq 0 ]
  grep -E "^limactl shell agent -- bash -s" "$CALLS"
  grep -E "^limactl copy .*\.api-keys\.zsh agent:" "$CALLS"
}

@test "open bridge: a VM folder opens VS Code over Remote-SSH" {
  printf '#!/bin/sh\nprintf "code %%s\\n" "$*" >> "$CALLS"\n' > "$TMP/bin/code"
  chmod +x "$TMP/bin/code"
  run "$REPO/vm/vm-up.sh" --open-line "/home/acastro.guest/code/my repo"
  [ "$status" -eq 0 ]
  grep -F "code --folder-uri vscode-remote://ssh-remote+lima-agent/home/acastro.guest/code/my%20repo" "$CALLS"
}

@test "open bridge: anything but an absolute path is refused" {
  printf '#!/bin/sh\nprintf "code %%s\\n" "$*" >> "$CALLS"\n' > "$TMP/bin/code"
  chmod +x "$TMP/bin/code"
  for bad in "relative/path" "--extensions-dir=/tmp" "/ok"$'\t'"x" ""; do
    run "$REPO/vm/vm-up.sh" --open-line "$bad"
    [ "$status" -ne 0 ]
  done
  ! grep -F "code --folder-uri" "$CALLS"
}

@test "open bridge: code never inherits the request stream as stdin" {
  printf '#!/bin/sh\ncat > "%s/stdin.txt"\nprintf "code %%s\\n" "$*" >> "$CALLS"\n' "$TMP" > "$TMP/bin/code"
  chmod +x "$TMP/bin/code"
  run bash -c "printf '/next/request\n' | '$REPO/vm/vm-up.sh' --open-line /home/x/repo"
  [ "$status" -eq 0 ]
  sleep 1
  grep -F "code --folder-uri" "$CALLS"
  [ ! -s "$TMP/stdin.txt" ]
}

@test "missing instance: the back-off is logged once per window, not every pass" {
  vm_status ""
  printf '#!/bin/sh\nprintf "bootstrap %%s\\n" "$*" >> "$CALLS"\n' > "$TMP/bootstrap.sh"
  chmod +x "$TMP/bootstrap.sh"
  export VM_UP_BOOTSTRAP="$TMP/bootstrap.sh"
  for n in 1 2 3 4; do
    "$REPO/vm/vm-up.sh" >>"$TMP/vmup.out" 2>&1 || true
  done
  [ "$(grep -c -F 'bootstrap --only=vm' "$CALLS")" -eq 1 ]
  [ "$(grep -c 'backed off' "$TMP/vmup.out")" -le 1 ]
}

@test "tunnel: a Rex server that never answers session ls cannot hang vm-up" {
  vm_status Running
  printf '#!/bin/sh\nprintf "rex %%s\\n" "$*" >> "$CALLS"\ncase "$*" in *"session"*) sleep 600 ;; esac\nexit 0\n' > "$TMP/bin/rex"
  chmod +x "$TMP/bin/rex"
  export VM_UP_SESSION_TIMEOUT=2
  start=$(date +%s)
  run "$REPO/vm/vm-up.sh"
  [ $(( $(date +%s) - start )) -lt 30 ]
  ! grep -F "forward new" "$CALLS"
}

@test "tunnel: an orphaned forward block is closed before the new one" {
  vm_status Running
  printf '#!/bin/sh\nprintf "rex %%s\\n" "$*" >> "$CALLS"\ncase "$*" in *"forward ls"*) printf "STATE ID DIRECTION CLIENT LISTEN CONNECT CONNS\\norphaned 830696 server -> client - 127.0.0.1:19988 127.0.0.1:19988 0\\n" ;; esac\nexit 0\n' > "$TMP/bin/rex"
  chmod +x "$TMP/bin/rex"
  run "$REPO/vm/vm-up.sh"
  [ "$status" -eq 0 ]
  grep -F "forward close --orphaned" "$CALLS"
  [ "$(grep -n -F 'forward close --orphaned' "$CALLS" | cut -d: -f1)" -lt "$(grep -n -F 'forward new' "$CALLS" | cut -d: -f1)" ]
  [[ "$output" == *"closed an orphaned forward block"* ]]
}

@test "tunnel: a healthy forward list is left alone" {
  vm_status Running
  printf '#!/bin/sh\nprintf "rex %%s\\n" "$*" >> "$CALLS"\ncase "$*" in *"forward ls"*) printf "STATE ID DIRECTION CLIENT LISTEN CONNECT CONNS\\nopen 1 client -> server 4f2a 127.0.0.1:19988 127.0.0.1:19988 1\\n" ;; esac\nexit 0\n' > "$TMP/bin/rex"
  chmod +x "$TMP/bin/rex"
  run "$REPO/vm/vm-up.sh"
  [ "$status" -eq 0 ]
  ! grep -F "forward close" "$CALLS"
}

# A corporate proxy env must never send the loopback probe to the proxy: the
# relay is healthy while curl reports it down, and vm-up then restarts it
# every minute.
@test "relay probe never goes through a proxy" {
  vm_status Running
  run "$REPO/vm/vm-up.sh"
  [ "$status" -eq 0 ]
  # The stub logs the argv, so the quotes are gone: match on the flag.
  grep -E -- "curl --noproxy (\*|\x27\*\x27) " "$CALLS" || grep -F -- "curl --noproxy *" "$CALLS"
}
