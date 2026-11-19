#!/usr/bin/env bats
# den core: the phase runner, needs, state, toggles, dry-run, fix, UI modes and
# secrets. Fake phases live in a temp dir (DEN_PHASE_DIR); nothing touches the
# real machine. Contract: docs/den/CONTRACT.md.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  export DEN_PHASE_DIR="$TMP/phases"
  export DEN_STATE_DIR="$TMP/state"
  export DEN_CONFIG="$TMP/config.env"
  export DEN_UI=plain
  export RAN="$TMP/ran.log"
  mkdir -p "$HOME" "$DEN_PHASE_DIR" "$TMP/bin"
  export PATH="$TMP/bin:/usr/bin:/bin:/opt/homebrew/bin"
  : > "$DEN_CONFIG"
  # No network, no 1Password, no gh, no sudo unless a test says so.
  for c in op gh sudo; do printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/$c"; chmod +x "$TMP/bin/$c"; done
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/curl"; chmod +x "$TMP/bin/curl"
}

teardown() { /bin/rm -rf "$TMP"; }

phase() { # phase NN name body [extra den_phase args...]
  local nn="$1" name="$2" body="$3"; shift 3
  local fn="phase_${name//-/_}"
  printf 'den_phase %s --title "%s" --about "about %s" --os any %s\n%s() { echo %s >> "$RAN"; %s; }\n' \
    "$name" "$name" "$name" "$*" "$fn" "$name" "$body" > "$DEN_PHASE_DIR/$nn-$name.sh"
}

den() { "$REPO/bin/den" "$@"; }

@test "a failing phase is recorded and the run continues; exit 1" {
  phase 10 one true
  phase 20 two false
  phase 30 three true
  run den up
  [ "$status" -eq 1 ]
  [ "$(cat "$RAN")" = "$(printf 'one\ntwo\nthree')" ]
  jq -e '.results | map(.status) == ["done","failed","done"]' "$DEN_STATE_DIR/last-run.json"
  jq -e '.results[1].fix | test("den up --only=two")' "$DEN_STATE_DIR/last-run.json"
}

@test "an unmet need skips the phase with reason and fix, body never runs" {
  phase 10 needs-gh true --needs gh
  run den up
  [ "$status" -eq 0 ]
  [ ! -s "$RAN" ]
  jq -e '.results[0].status == "skipped" and (.results[0].reason|length>0) and (.results[0].fix|length>0)' "$DEN_STATE_DIR/last-run.json"
}

@test "den_skip and den_fail inside a phase set status, reason and fix" {
  phase 10 soft 'den_skip "no thing" "do thing"'
  phase 20 hard 'den_fail "broke" "fix it"'
  run den up
  [ "$status" -eq 1 ]
  jq -e '.results[0] | .status=="skipped" and .reason=="no thing" and .fix=="do thing"' "$DEN_STATE_DIR/last-run.json"
  jq -e '.results[1] | .status=="failed" and .reason=="broke" and .fix=="fix it"' "$DEN_STATE_DIR/last-run.json"
}

@test "unknown phase in --only or --skip is a usage error listing valid phases" {
  phase 10 one true
  run den up --only=nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"one"* ]]
  run den up --skip=nope
  [ "$status" -eq 2 ]
  [ ! -s "$RAN" ]
}

@test "--only and --skip select phases" {
  phase 10 one true
  phase 20 two true
  run den up --only=two
  [ "$(cat "$RAN")" = "two" ]
  : > "$RAN"
  run den up --skip=two
  [ "$(cat "$RAN")" = "one" ]
}

@test "--dry-run runs nothing and records dry-run" {
  phase 10 one true
  run den up --dry-run
  [ "$status" -eq 0 ]
  [ ! -s "$RAN" ]
  jq -e '.results[0].status == "dry-run"' "$DEN_STATE_DIR/last-dry-run.json"
  [[ "$output" == *"about one"* ]]
}

@test "--dry-run leaves the real last run untouched" {
  phase 10 one true
  run den up
  [ "$status" -eq 0 ]
  before=$(shasum "$DEN_STATE_DIR/last-run.json")
  run den up --dry-run
  [ "$status" -eq 0 ]
  [ "$(shasum "$DEN_STATE_DIR/last-run.json")" = "$before" ]
  jq -e '.results[0].status == "done"' "$DEN_STATE_DIR/last-run.json"
}

@test "a partial run keeps the rows of phases it did not run" {
  phase 10 one true
  phase 20 two true
  run den up
  [ "$status" -eq 0 ]
  run den up --only=two
  [ "$status" -eq 0 ]
  jq -e '[.results[].phase] | sort == ["one","two"]' "$DEN_STATE_DIR/last-run.json"
}

@test "a toggle set to 0 hides the phase" {
  phase 10 one true --toggle DEN_ONE
  echo 'DEN_ONE=0' > "$DEN_CONFIG"
  run den up
  [ ! -s "$RAN" ]
  jq -e '.results | length == 0' "$DEN_STATE_DIR/last-run.json"
}

@test "den fix reruns only what was skipped or failed" {
  phase 10 one true
  phase 20 two 'test -f "$HOME/ok" || false'
  run den up
  : > "$RAN"; touch "$HOME/ok"
  run den fix
  [ "$status" -eq 0 ]
  [ "$(cat "$RAN")" = "two" ]
}

@test "state file is mode 600 valid JSON with metadata" {
  phase 10 one true
  run den up
  jq -e '.version==1 and (.started|length>0) and (.finished|length>0) and (.host|length>0)' "$DEN_STATE_DIR/last-run.json"
  [ "$(stat -c %a "$DEN_STATE_DIR/last-run.json" 2>/dev/null || stat -f %Lp "$DEN_STATE_DIR/last-run.json")" = "600" ]
}

@test "plain UI prints no escape codes" {
  phase 10 one true
  run den up
  [ "$status" -eq 0 ]
  [[ "$output" == *"one"* ]]
  ! printf '%s' "$output" | grep -q $'\033'
}

@test "den phases lists name, about and needs" {
  phase 10 one true --needs gh
  run den phases
  [ "$status" -eq 0 ]
  [[ "$output" == *"one"* && "$output" == *"about one"* && "$output" == *"gh"* ]]
}

@test "config.env is never read from the current directory" {
  phase 10 one 'test -z "${EVIL:-}"'
  mkdir -p "$TMP/cwd"; echo 'EVIL=1' > "$TMP/cwd/config.env"
  cd "$TMP/cwd"
  unset DEN_CONFIG
  run den up --only=one
  jq -e '.results[0].status == "done"' "$DEN_STATE_DIR/last-run.json"
}

# ── Secrets ──────────────────────────────────────────────────────────

bundle() { # bundle FILE: a den.json with tricky values
  cat > "$1" <<'EOF'
{"version":1,"env":{"PLAIN":"abc","DOLLAR":"p$HOME$(echo PWNED)`echo X`","QUOTE":"it's"},
 "opencode_web":{"password":"pw"},"rex":{"appcast":"https://example.invalid/a.xml","mcp":""}}
EOF
}

@test "secrets: ~/den.json is rendered with literal values, mode 600, then purged" {
  bundle "$HOME/den.json"
  phase 10 render 'den_render_env "$HOME/.config/zsh/.api-keys.zsh"' --needs secrets
  run den up
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/den.json" ]
  f="$HOME/.config/zsh/.api-keys.zsh"
  [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" = "600" ]
  out="$(zsh -fc "source '$f'; print -r -- \"\$DOLLAR|\$QUOTE|\$PLAIN\"")"
  [ "$out" = 'p$HOME$(echo PWNED)`echo X`|it'"'"'s|abc' ]
  [[ "$output" == *"den.json"* ]]
}

@test "secrets: no source means needs-secrets phases are skipped with a fix" {
  phase 10 render 'den_render_env "$HOME/x.zsh"' --needs secrets
  run den up
  jq -e '.results[0].status=="skipped" and (.results[0].fix|test("den.json"))' "$DEN_STATE_DIR/last-run.json"
}

@test "secrets: an empty env never replaces an existing keys file" {
  mkdir -p "$HOME/.config/zsh"; echo "export KEEP='1'" > "$HOME/.config/zsh/.api-keys.zsh"
  echo '{"version":1,"env":{}}' > "$HOME/den.json"
  phase 10 render 'den_render_env "$HOME/.config/zsh/.api-keys.zsh"' --needs secrets
  run den up
  jq -e '.results[0].status=="skipped"' "$DEN_STATE_DIR/last-run.json"
  grep -q KEEP "$HOME/.config/zsh/.api-keys.zsh"
}

@test "secrets: den_secret reads one value and never puts it in argv" {
  bundle "$HOME/den.json"
  phase 10 read '[ "$(den_secret .opencode_web.password)" = pw ]' --needs secrets
  run den up
  jq -e '.results[0].status=="done"' "$DEN_STATE_DIR/last-run.json"
}

@test "secrets: an invalid den.json is rejected and kept for the user to fix" {
  echo '{"env":"nope"}' > "$HOME/den.json"
  phase 10 render 'den_render_env "$HOME/x.zsh"' --needs secrets
  run den up
  [ -e "$HOME/den.json" ]
  jq -e '.results[0].status=="skipped"' "$DEN_STATE_DIR/last-run.json"
}

@test "den fix drops a phase that is no longer selected, and stops asking for it" {
  phase 10 one false --toggle DEN_ONE
  phase 20 two true
  run den up
  [ "$status" -eq 1 ]
  printf 'DEN_ONE=0\n' > "$DEN_CONFIG"
  : > "$RAN"
  run den fix
  [ "$status" -eq 0 ]
  [ ! -s "$RAN" ]
  ! jq -e '.results[] | select(.phase=="one")' "$DEN_STATE_DIR/last-run.json"
  run den
  [[ "$output" != *"den fix"* ]]
}

@test "secrets: a ~/den.json you put there wins over 1Password, which is not asked" {
  printf '#!/bin/sh\nprintf "op %%s\\n" "$*" >> "%s/op.calls"\nsleep 30\nexit 1\n' "$TMP" > "$TMP/bin/op"; chmod +x "$TMP/bin/op"
  printf '{"version":1,"env":{"A_KEY":"v"}}' > "$HOME/den.json"
  phase 10 render 'den_render_env "$HOME/x.zsh"' --needs secrets
  start=$(date +%s)
  run den up
  [ "$status" -eq 0 ]
  [ $(( $(date +%s) - start )) -lt 20 ]
  [ ! -s "$TMP/op.calls" ]
  grep -q "A_KEY='v'" "$HOME/x.zsh"
}

@test "the dashboard summary never prints '0 dry-run'" {
  phase 10 one true
  run den up
  run den
  [ "$status" -eq 0 ]
  [[ "$output" != *"0 dry-run"* ]]
}

@test "den finds its own checkout even when DEN_ROOT points somewhere else" {
  phase 10 one true
  DEN_ROOT="$TMP/not-a-checkout" run den phases
  [ "$status" -eq 0 ]
  [[ "$output" == *"one"* ]]
  [[ "$output" != *"den: missing"* ]]
}
