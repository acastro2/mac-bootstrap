#!/usr/bin/env bats
# Lane D acceptance: stage 0, safe clean and sessions, doctor roll-up,
# non-interactive wizard, update, dashboard. Contract: docs/den/CONTRACT.md.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  export DEN_UI=plain DEN_PROBE_NET=ok DEN_STATE_DIR="$TMP/state"
  export DEN_PHASE_DIR="$TMP/phases" RAN="$TMP/ran.log" CALLS="$TMP/calls.log"
  mkdir -p "$HOME/.local/bin" "$DEN_PHASE_DIR" "$TMP/bin"
  export PATH="$TMP/bin:/usr/bin:/bin:/opt/homebrew/bin"
  printf 'den_phase one --title one --about "about one" --os any\nphase_one() { echo one >> "$RAN"; }\n' > "$DEN_PHASE_DIR/10-one.sh"
  for c in brew git limactl launchctl; do
    printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "$CALLS"\nexit 0\n' "$c" > "$TMP/bin/$c"; chmod +x "$TMP/bin/$c"
  done
}

teardown() { /bin/rm -rf "$TMP"; }

@test "bootstrap.sh inside the repo hands its flags to den up" {
  run "$REPO/bootstrap.sh" --only=one
  [ "$status" -eq 0 ]
  [ "$(cat "$RAN")" = one ]
}

@test "bootstrap.sh never reads config.env from the current directory" {
  mkdir -p "$TMP/cwd"; printf 'touch "%s/pwned"\n' "$TMP" > "$TMP/cwd/config.env"
  cd "$TMP/cwd"
  run "$REPO/bootstrap.sh" --only=one
  [ ! -e "$TMP/pwned" ]
}

@test "bootstrap.sh maps the old flags" {
  run "$REPO/bootstrap.sh" --dump-tools
  [ "$status" -eq 0 ]
  [[ "$output" == *"opencode|"* ]]
}

@test "den clean without --dry-run and without a terminal removes nothing" {
  : > "$HOME/.local/bin/claude"
  run "$REPO/bin/den" clean </dev/null
  [ "$status" -ne 0 ]
  [ -f "$HOME/.local/bin/claude" ]
  ! grep -q '^brew \(remove\|uninstall\)' "$CALLS"
}

@test "den clean --dry-run never touches packages the Brewfiles do not declare" {
  printf '#!/bin/sh\nprintf "brew %%s\\n" "$*" >> "%s"\ncase "$*" in "list --formula") printf "jq\\nsomething-personal\\n";; "list --cask") printf "steam\\n";; esac\nexit 0\n' "$CALLS" > "$TMP/bin/brew"
  run "$REPO/bin/den" clean --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"something-personal"* ]]
  [[ "$output" != *"steam"* ]]
}

@test "den sessions import keeps the current data when the archive is bad" {
  mkdir -p "$HOME/.claude/projects/p"; echo keep > "$HOME/.claude/projects/p/chat.jsonl"
  echo "not a tarball" > "$TMP/bad.tar.gz"
  run "$REPO/bin/den" sessions import "$TMP/bad.tar.gz" --yes
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/.claude/projects/p/chat.jsonl")" = keep ]
}

@test "den sessions import snapshots before it replaces" {
  mkdir -p "$HOME/.claude/projects/p"; echo old > "$HOME/.claude/projects/p/chat.jsonl"
  mkdir -p "$TMP/src/.claude/projects/p"; echo new > "$TMP/src/.claude/projects/p/chat.jsonl"
  tar -czf "$TMP/good.tar.gz" -C "$TMP/src" .claude
  run "$REPO/bin/den" sessions import "$TMP/good.tar.gz" --yes
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.claude/projects/p/chat.jsonl")" = new ]
  snap="$(ls "$HOME"/.local/state/den/snapshots/*.tar.gz 2>/dev/null | head -1)"
  [ -n "$snap" ]
  tar -xzOf "$snap" .claude/projects/p/chat.jsonl | grep -qx old
}

@test "den doctor rolls up every check and --strict fails on a broken one" {
  printf 'den_cmd_fakecheck() { :; }\nden_doctor_fake() { ui_err "fake is broken"; return 1; }\n' > "$TMP/fake.sh"
  export DEN_EXTRA_LIBS="$TMP/fake.sh"
  run "$REPO/bin/den" doctor --strict
  [ "$status" -eq 1 ]
  [[ "$output" == *"fake is broken"* ]]
  run "$REPO/bin/den" doctor
  [ "$status" -eq 0 ]
}

@test "den setup without a terminal never blocks and says how to configure" {
  run "$REPO/bin/den" setup </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"config.env"* ]]
}

@test "den update pulls fast-forward only, then runs den up" {
  run "$REPO/bin/den" update
  grep -q '^git .*pull --ff-only' "$CALLS"
  [ "$(cat "$RAN")" = one ]
}

@test "den with no arguments shows the last run" {
  run "$REPO/bin/den" up
  run "$REPO/bin/den"
  [ "$status" -eq 0 ]
  [[ "$output" == *"one"* ]]
  [[ "$output" == *"done"* || "$output" == *"✓"* ]]
}

@test "den sessions import of a 4000-file archive finishes in under 25 s" {
  mkdir -p "$TMP/src/.claude/projects"
  i=0
  while [ "$i" -lt 40 ]; do
    mkdir -p "$TMP/src/.claude/projects/p$i"
    j=0
    while [ "$j" -lt 100 ]; do
      : > "$TMP/src/.claude/projects/p$i/c$j.jsonl"
      j=$((j + 1))
    done
    i=$((i + 1))
  done
  tar -czf "$TMP/big.tar.gz" -C "$TMP/src" .claude
  start=$(date +%s)
  run "$REPO/bin/den" sessions import "$TMP/big.tar.gz" --yes
  took=$(( $(date +%s) - start ))
  echo "took ${took}s" >&3
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/projects/p39/c99.jsonl" ]
  [ "$took" -lt 25 ]
}

@test "den sessions import still refuses a member outside the session paths" {
  mkdir -p "$TMP/src/.claude/projects/p" "$TMP/src/.ssh"
  echo x > "$TMP/src/.claude/projects/p/c.jsonl"; echo key > "$TMP/src/.ssh/id_ed25519"
  tar -czf "$TMP/mixed.tar.gz" -C "$TMP/src" .claude .ssh
  run "$REPO/bin/den" sessions import "$TMP/mixed.tar.gz" --yes
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/.ssh/id_ed25519" ]
}

@test "den sessions export writes a private file outside the Desktop" {
  mkdir -p "$HOME/.claude/projects/p" "$HOME/Desktop"; echo x > "$HOME/.claude/projects/p/c.jsonl"
  run "$REPO/bin/den" sessions export
  [ "$status" -eq 0 ]
  [ -z "$(ls "$HOME/Desktop")" ]
  out="$(ls "$HOME"/.local/state/den/exports/agent-sessions-*.tar.gz | head -1)"
  [ -n "$out" ]
  [ "$(stat -f %Lp "$HOME/.local/state/den/exports")" = 700 ]
  [ "$(stat -f %Lp "$out")" = 600 ]
}

@test "den help sessions does not claim credentials are left out" {
  run "$REPO/bin/den" help sessions
  [ "$status" -eq 0 ]
  [[ "$output" != *"Credential files are left out"* ]]
  [[ "$output" == *".claude.json"* ]]
}

@test "den sessions import keeps only the newest 5 snapshots" {
  mkdir -p "$HOME/.local/state/den/snapshots"
  for n in 1 2 3 4 5 6 7; do
    printf x | gzip > "$HOME/.local/state/den/snapshots/sessions-2026010${n}-000000.tar.gz"
  done
  mkdir -p "$TMP/src/.claude/projects/p"; echo new > "$TMP/src/.claude/projects/p/c.jsonl"
  tar -czf "$TMP/good.tar.gz" -C "$TMP/src" .claude
  run "$REPO/bin/den" sessions import "$TMP/good.tar.gz" --yes
  [ "$status" -eq 0 ]
  [ "$(ls "$HOME"/.local/state/den/snapshots/*.tar.gz | wc -l | tr -d ' ')" -le 5 ]
  [ ! -e "$HOME/.local/state/den/snapshots/sessions-20260101-000000.tar.gz" ]
}
