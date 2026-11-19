# shellcheck shell=bash
# lib/core.sh — config, phase registry, needs, preflight, runner, state.
# Bash 3.2. Contract: docs/den/CONTRACT.md.

DEN_STATE_DIR=${DEN_STATE_DIR:-$HOME/.local/state/den}
DEN_PHASE_DIR=${DEN_PHASE_DIR:-${DEN_ROOT:-}/lib/phases}
DEN_CONFIG=${DEN_CONFIG:-${DEN_ROOT:-}/config.env}
DEN_RUNTIME=${DEN_RUNTIME:-}

DEN_PHASE_NAMES=()
DEN_PHASE_TITLES=()
DEN_PHASE_ABOUTS=()
DEN_PHASE_OSES=()
DEN_PHASE_TOGGLES=()
DEN_PHASE_NEEDS=()
DEN_PHASE_COUNT=0

DEN_RESULT_PHASE=()
DEN_RESULT_STATUS=()
DEN_RESULT_SECONDS=()
DEN_RESULT_REASON=()
DEN_RESULT_FIX=()
DEN_RESULT_COUNT=0

DEN_ONLY=""
DEN_SKIP=""
DEN_DRY_RUN=0
DEN_RUN_STARTED=""
DEN_RUN_SECONDS=0
DEN_RUN_ARGS=""

DEN_NEED_REASON=""
DEN_NEED_FIX=""

# Probe caches. An inherited value is kept (tests preset DEN_PROBE_NET=ok).
DEN_PROBE_NET="${DEN_PROBE_NET:-}"
DEN_PROBE_BREW="${DEN_PROBE_BREW:-}"
DEN_PROBE_SUDO=""
DEN_PROBE_GH=""

DEN_SUDO_KEEPALIVE_PID=""

den_die() {
  ui_err "$*"
  exit 2
}

den_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

den_hostname() {
  hostname 2>/dev/null || uname -n
}

den_os() {
  case $(uname -s) in
    Darwin) printf macos ;;
    Linux) printf linux ;;
    *) printf other ;;
  esac
}

den_is_tty() {
  if [ -t 0 ] && [ -t 1 ]; then
    return 0
  fi
  return 1
}

den_config_load() {
  if [ -r "$DEN_CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$DEN_CONFIG"
  fi
  if [ -r "$HOME/.config/den/local.env" ]; then
    # shellcheck source=/dev/null
    . "$HOME/.config/den/local.env"
  fi
  if [ -z "${OP_VAULT:-}" ]; then
    OP_VAULT=Private
  fi
}

den_phase() {
  local name=${1:-} title="" about="" os=any toggle="" needs=""
  if [ -z "$name" ]; then
    den_die "den_phase: a name is required"
  fi
  if [ $# -gt 0 ]; then
    shift
  fi
  while [ $# -gt 0 ]; do
    case $1 in
      --title) title=${2:-}; shift 2 || den_die "den_phase $name: --title needs a value" ;;
      --about) about=${2:-}; shift 2 || den_die "den_phase $name: --about needs a value" ;;
      --os) os=${2:-}; shift 2 || den_die "den_phase $name: --os needs a value" ;;
      --toggle) toggle=${2:-}; shift 2 || den_die "den_phase $name: --toggle needs a value" ;;
      --needs) needs=${2:-}; shift 2 || den_die "den_phase $name: --needs needs a value" ;;
      *) den_die "den_phase $name: unknown option $1" ;;
    esac
  done
  case $os in
    any|macos|linux) ;;
    *) den_die "den_phase $name: --os must be any, macos or linux" ;;
  esac
  if [ -z "$title" ]; then
    title=$name
  fi
  DEN_PHASE_NAMES[DEN_PHASE_COUNT]=$name
  DEN_PHASE_TITLES[DEN_PHASE_COUNT]=$title
  DEN_PHASE_ABOUTS[DEN_PHASE_COUNT]=$about
  DEN_PHASE_OSES[DEN_PHASE_COUNT]=$os
  DEN_PHASE_TOGGLES[DEN_PHASE_COUNT]=$toggle
  DEN_PHASE_NEEDS[DEN_PHASE_COUNT]=$needs
  DEN_PHASE_COUNT=$((DEN_PHASE_COUNT + 1))
}

den_phase_fn() {
  printf 'phase_%s' "${1//-/_}"
}

den_phase_index() {
  local want=${1:-} i
  for ((i = 0; i < DEN_PHASE_COUNT; i++)); do
    if [ "${DEN_PHASE_NAMES[$i]}" = "$want" ]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

den_phase_names_join() {
  local i out=""
  for ((i = 0; i < DEN_PHASE_COUNT; i++)); do
    if [ -z "$out" ]; then
      out=${DEN_PHASE_NAMES[$i]}
    else
      out="$out, ${DEN_PHASE_NAMES[$i]}"
    fi
  done
  if [ -z "$out" ]; then
    out="(none)"
  fi
  printf '%s' "$out"
}

den_phases_load() {
  local file
  if [ ! -d "$DEN_PHASE_DIR" ]; then
    return 0
  fi
  for file in "$DEN_PHASE_DIR"/*.sh; do
    if [ -e "$file" ]; then
      # shellcheck disable=SC1090
      . "$file"
    fi
  done
}

den_toggle_on() {
  local var=${1:-} value=""
  if [ -z "$var" ]; then
    return 0
  fi
  case $var in
    *[!A-Za-z0-9_]*) return 0 ;;
  esac
  eval "value=\${$var:-}"
  case $value in
    0|false|False|FALSE|no|No|NO) return 1 ;;
  esac
  return 0
}

den_phase_selected() {
  local i=${1:-} name os
  name=${DEN_PHASE_NAMES[$i]}
  if [ -n "$DEN_ONLY" ]; then
    case ",$DEN_ONLY," in
      *",$name,"*) ;;
      *) return 1 ;;
    esac
  fi
  if [ -n "$DEN_SKIP" ]; then
    case ",$DEN_SKIP," in
      *",$name,"*) return 1 ;;
    esac
  fi
  if ! den_toggle_on "${DEN_PHASE_TOGGLES[$i]}"; then
    return 1
  fi
  os=${DEN_PHASE_OSES[$i]}
  case $os in
    any) ;;
    macos|linux)
      if [ "$os" != "$(den_os)" ]; then
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
  return 0
}

den_validate_list() {
  local kind=${1:-} list=${2:-} old_ifs=$IFS name
  if [ -z "$list" ]; then
    return 0
  fi
  IFS=,
  for name in $list; do
    if [ -n "$name" ] && ! den_phase_index "$name" >/dev/null; then
      IFS=$old_ifs
      den_die "unknown phase in --$kind: $name (valid phases: $(den_phase_names_join))"
    fi
  done
  IFS=$old_ifs
}

den_validate_selection() {
  den_validate_list only "$DEN_ONLY"
  den_validate_list skip "$DEN_SKIP"
}

den_selected_needs() {
  local i need out=" "
  for ((i = 0; i < DEN_PHASE_COUNT; i++)); do
    if ! den_phase_selected "$i"; then
      continue
    fi
    for need in ${DEN_PHASE_NEEDS[$i]}; do
      case $out in
        *" $need "*) ;;
        *) out="$out$need " ;;
      esac
    done
  done
  printf '%s' "$out"
}

den_record() {
  local phase=$1 status=$2 seconds=$3 reason=${4:-} fix=${5:-} i=$DEN_RESULT_COUNT
  DEN_RESULT_PHASE[i]=$phase
  DEN_RESULT_STATUS[i]=$status
  DEN_RESULT_SECONDS[i]=$seconds
  DEN_RESULT_REASON[i]=$reason
  DEN_RESULT_FIX[i]=$fix
  DEN_RESULT_COUNT=$((i + 1))
}

den_run_exit_code() {
  local i
  for ((i = 0; i < DEN_RESULT_COUNT; i++)); do
    if [ "${DEN_RESULT_STATUS[$i]}" = failed ]; then
      printf '1'
      return 0
    fi
  done
  printf '0'
}

den_runtime_cleanup() {
  den_sudo_keepalive_stop
  if [ -n "${DEN_RUNTIME:-}" ] && [ -d "$DEN_RUNTIME" ]; then
    rm -rf "$DEN_RUNTIME"
  fi
}

den_runtime_init() {
  DEN_RUNTIME=$(mktemp -d "${TMPDIR:-/tmp}/den.XXXXXX")
  export DEN_RUNTIME
  export DEN_PHASE_STATUS_FILE="$DEN_RUNTIME/phase-status"
  mkdir -p "$DEN_RUNTIME/needs" "$DEN_RUNTIME/secrets"
  # A trapped signal runs its handler and then the script carries on (bash 3.2
  # too), so a Ctrl-C must exit, or the run goes on with its runtime deleted.
  trap den_runtime_cleanup EXIT
  trap 'den_runtime_cleanup; trap - EXIT; exit 130' INT
  trap 'den_runtime_cleanup; trap - EXIT; exit 143' TERM
  trap 'den_runtime_cleanup; trap - EXIT; exit 129' HUP
}

den_sudo_keepalive_stop() {
  if [ -n "${DEN_SUDO_KEEPALIVE_PID:-}" ]; then
    kill "$DEN_SUDO_KEEPALIVE_PID" 2>/dev/null || true
    DEN_SUDO_KEEPALIVE_PID=""
  fi
}

den_sudo_keepalive_start() {
  if [ -n "${DEN_SUDO_KEEPALIVE_PID:-}" ]; then
    return 0
  fi
  (
    while :; do
      sleep 50
      sudo -n -v >/dev/null 2>&1 || exit 0
    done
  ) &
  DEN_SUDO_KEEPALIVE_PID=$!
}

den_free_gib() {
  local kb
  kb=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')
  case ${kb:-} in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$((kb / 1048576))"
}

den_rex_app_found() {
  local path
  for path in "$HOME/Applications"/Rex*.app /Applications/Rex*.app; do
    if [ -d "$path" ]; then
      return 0
    fi
  done
  return 1
}

den_probe_net() {
  if [ -z "$DEN_PROBE_NET" ]; then
    if curl -fsS -m 5 https://github.com >/dev/null 2>&1; then
      DEN_PROBE_NET=ok
    else
      DEN_PROBE_NET=no
    fi
  fi
  if [ "$DEN_PROBE_NET" = ok ]; then
    return 0
  fi
  return 1
}

den_probe_brew() {
  if [ -z "$DEN_PROBE_BREW" ]; then
    if command -v brew >/dev/null 2>&1; then
      DEN_PROBE_BREW=ok
    else
      DEN_PROBE_BREW=missing
    fi
  fi
  if [ "$DEN_PROBE_BREW" = ok ]; then
    return 0
  fi
  return 1
}

den_probe_sudo() {
  if [ -z "$DEN_PROBE_SUDO" ]; then
    if sudo -n true >/dev/null 2>&1; then
      DEN_PROBE_SUDO=ok
    else
      DEN_PROBE_SUDO=no
    fi
  fi
  if [ "$DEN_PROBE_SUDO" = ok ]; then
    return 0
  fi
  return 1
}

den_probe_gh() {
  if [ -z "$DEN_PROBE_GH" ]; then
    if ! command -v gh >/dev/null 2>&1; then
      DEN_PROBE_GH=missing
    elif gh auth status >/dev/null 2>&1; then
      DEN_PROBE_GH=ok
    else
      DEN_PROBE_GH=signed-out
    fi
  fi
  if [ "$DEN_PROBE_GH" = ok ]; then
    return 0
  fi
  return 1
}

den_need_probe() {
  DEN_NEED_REASON=""
  DEN_NEED_FIX=""
  case ${1:-} in
    sudo)
      if den_probe_sudo; then
        return 0
      fi
      DEN_NEED_REASON="sudo needs a password"
      DEN_NEED_FIX="sudo -v"
      return 1
      ;;
    net)
      if den_probe_net; then
        return 0
      fi
      DEN_NEED_REASON="no network access to github.com"
      DEN_NEED_FIX="check the network, then run den fix"
      return 1
      ;;
    brew)
      if den_probe_brew; then
        return 0
      fi
      DEN_NEED_REASON="Homebrew is not installed"
      DEN_NEED_FIX="/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
      return 1
      ;;
    gh)
      if ! command -v gh >/dev/null 2>&1; then
        DEN_NEED_REASON="gh is not installed"
        DEN_NEED_FIX="brew install gh"
        return 1
      fi
      if den_probe_gh; then
        return 0
      fi
      DEN_NEED_REASON="gh is not signed in"
      DEN_NEED_FIX="gh auth login --web"
      return 1
      ;;
    op)
      # `op account list` answers without a prompt; `op whoami` says "not
      # signed in" under the app integration even when reads work.
      if command -v op >/dev/null 2>&1 &&
        [ -n "$(den_with_timeout 15 op account list --format json 2>/dev/null | jq -r '.[0].url // empty' 2>/dev/null)" ]; then
        return 0
      fi
      DEN_NEED_REASON="1Password CLI has no account"
      DEN_NEED_FIX="turn on Settings > Developer > Integrate with 1Password CLI, or op account add"
      return 1
      ;;
    secrets)
      case ${DEN_SECRETS_STATUS:-missing} in
        ok) return 0 ;;
        invalid)
          DEN_NEED_REASON="the secrets bundle is invalid (want version 1 and env of strings)"
          DEN_NEED_FIX="fix ~/den.json, then run den fix"
          return 1
          ;;
        *)
          DEN_NEED_REASON="no secrets bundle found"
          DEN_NEED_FIX="sign in with \`op signin\`, or drop den.json at ~/den.json"
          return 1
          ;;
      esac
      ;;
    tty)
      if den_is_tty; then
        return 0
      fi
      DEN_NEED_REASON="stdin and stdout are not a terminal"
      DEN_NEED_FIX="run den from a terminal"
      return 1
      ;;
    macos)
      if [ "$(den_os)" = macos ]; then
        return 0
      fi
      DEN_NEED_REASON="this is not macOS"
      DEN_NEED_FIX="run den on a Mac"
      return 1
      ;;
    linux)
      if [ "$(den_os)" = linux ]; then
        return 0
      fi
      DEN_NEED_REASON="this is not Linux"
      DEN_NEED_FIX="run den on Linux"
      return 1
      ;;
    disk:*)
      den_need_disk "${1#disk:}"
      return $?
      ;;
    vm)
      den_need_vm
      return $?
      ;;
    rex-app)
      if den_rex_app_found; then
        return 0
      fi
      DEN_NEED_REASON="the Rex app is not in ~/Applications or /Applications"
      DEN_NEED_FIX="install the Rex app, then run den fix"
      return 1
      ;;
    *)
      DEN_NEED_REASON="unknown need: ${1:-}"
      DEN_NEED_FIX=""
      return 1
      ;;
  esac
}

den_need_disk() {
  local want=${1:-} avail
  case $want in
    ''|*[!0-9]*)
      DEN_NEED_REASON="bad disk need: disk:$want"
      DEN_NEED_FIX=""
      return 1
      ;;
  esac
  avail=$(den_free_gib) || avail=""
  if [ -n "$avail" ] && [ "$avail" -ge "$want" ]; then
    return 0
  fi
  DEN_NEED_REASON="only ${avail:-0} GiB free, $want GiB needed"
  DEN_NEED_FIX="free up disk space"
  return 1
}

den_need_vm() {
  local out=""
  if ! command -v limactl >/dev/null 2>&1; then
    DEN_NEED_REASON="limactl is not installed"
    DEN_NEED_FIX="brew install lima"
    return 1
  fi
  if [ -z "${AGENT_VM:-}" ]; then
    DEN_NEED_REASON="AGENT_VM is empty in config.env"
    DEN_NEED_FIX="set AGENT_VM in config.env"
    return 1
  fi
  out=$(limactl list 2>/dev/null) || out=""
  if printf '%s\n' "$out" | awk -v n="$AGENT_VM" '$1 == n && /Running/ { found = 1 } END { exit !found }'; then
    return 0
  fi
  DEN_NEED_REASON="VM $AGENT_VM is not running"
  DEN_NEED_FIX="den vm up"
  return 1
}

den_need() {
  local need=${1:-} key dir
  DEN_NEED_REASON=""
  DEN_NEED_FIX=""
  if [ -z "${DEN_RUNTIME:-}" ]; then
    den_need_probe "$need"
    return $?
  fi
  key=${need//:/_}
  key=${key//\//_}
  dir="$DEN_RUNTIME/needs"
  if [ -f "$dir/$key.ok" ]; then
    return 0
  fi
  # gh and brew can be installed by an earlier phase of this same run (a fresh
  # VM gets gh from the packages phase), so a "no" for them is probed again.
  case $need in
    gh | brew)
      rm -f "$dir/$key.no"
      [ "$DEN_PROBE_GH" = missing ] && DEN_PROBE_GH=""
      [ "$DEN_PROBE_BREW" = missing ] && DEN_PROBE_BREW=""
      ;;
  esac
  if [ -f "$dir/$key.no" ]; then
    DEN_NEED_REASON=$(cat "$dir/$key.reason" 2>/dev/null) || DEN_NEED_REASON=""
    DEN_NEED_FIX=$(cat "$dir/$key.fix" 2>/dev/null) || DEN_NEED_FIX=""
    return 1
  fi
  if den_need_probe "$need"; then
    : >"$dir/$key.ok"
    return 0
  fi
  printf '%s' "${DEN_NEED_REASON:-not available}" >"$dir/$key.reason"
  printf '%s' "${DEN_NEED_FIX:-}" >"$dir/$key.fix"
  : >"$dir/$key.no"
  return 1
}

den_preflight_line() {
  local line
  line="os=$(den_os)"
  if den_is_tty; then
    line="$line tty=yes"
  else
    line="$line tty=no"
  fi
  if [ -n "${DEN_PROBE_NET:-}" ]; then
    line="$line net=$DEN_PROBE_NET"
  fi
  if [ -n "${DEN_PROBE_BREW:-}" ]; then
    line="$line brew=$DEN_PROBE_BREW"
  fi
  if [ -n "${DEN_PROBE_SUDO:-}" ]; then
    line="$line sudo=$DEN_PROBE_SUDO"
  fi
  if [ -n "${DEN_PROBE_GH:-}" ]; then
    line="$line gh=$DEN_PROBE_GH"
  fi
  if [ -n "${DEN_SECRETS_STATUS:-}" ] && [ "$DEN_SECRETS_STATUS" != missing ]; then
    line="$line secrets=$DEN_SECRETS_STATUS"
  fi
  printf '%s' "$line"
}

den_preflight() {
  local needs i need has_sudo=0 has_secrets=0 has_gh=0
  needs=$(den_selected_needs)
  case " $needs " in *" sudo "*) has_sudo=1 ;; esac
  case " $needs " in *" secrets "*) has_secrets=1 ;; esac
  case " $needs " in *" gh "*) has_gh=1 ;; esac
  case " $needs " in *" net "*) den_probe_net >/dev/null 2>&1 || true ;; esac
  case " $needs " in *" brew "*) den_probe_brew >/dev/null 2>&1 || true ;; esac
  if [ "$has_sudo" = 1 ]; then
    if den_is_tty; then
      ui_info "sudo: asking once, then keeping it alive for the run"
      sudo -v || true
      den_sudo_keepalive_start
    fi
    den_probe_sudo >/dev/null 2>&1 || true
  fi
  if [ "$has_secrets" = 1 ]; then
    den_secrets_load
  fi
  if [ "$has_gh" = 1 ] && den_is_tty && ! den_probe_gh; then
    ui_warn "gh: not signed in, starting gh auth login"
    gh auth login --web --git-protocol https || true
    DEN_PROBE_GH=""
    den_probe_gh >/dev/null 2>&1 || true
  fi
  # Hooks: a lib adds its own up-front human step as den_preflight_hook_<x>,
  # called with the selected needs. It must not prompt without a TTY.
  local hook
  for hook in $(declare -F | awk '{print $3}' | grep '^den_preflight_hook_' | sort); do
    "$hook" "$needs" || true
  done
  ui_section "Preflight"
  ui_info "$(den_preflight_line)"
  for ((i = 0; i < DEN_PHASE_COUNT; i++)); do
    if ! den_phase_selected "$i"; then
      continue
    fi
    for need in ${DEN_PHASE_NEEDS[$i]}; do
      if ! den_need "$need"; then
        ui_skip "${DEN_PHASE_NAMES[$i]} will skip: $DEN_NEED_REASON"
        break
      fi
    done
  done
}

den_run_one() {
  local i=${1:-} name title about needs need fn status reason fix rc start end secs
  name=${DEN_PHASE_NAMES[$i]}
  title=${DEN_PHASE_TITLES[$i]}
  about=${DEN_PHASE_ABOUTS[$i]}
  needs=${DEN_PHASE_NEEDS[$i]}

  for need in $needs; do
    if ! den_need "$need"; then
      ui_section "$title"
      ui_skip "$title: needs $need ($DEN_NEED_REASON)"
      if [ -n "$DEN_NEED_FIX" ]; then
        ui_info "fix: $DEN_NEED_FIX"
      fi
      den_record "$name" skipped 0 "needs $need: $DEN_NEED_REASON" "$DEN_NEED_FIX"
      return 0
    fi
  done

  if [ "$DEN_DRY_RUN" = 1 ]; then
    ui_section "$title"
    ui_info "$about"
    ui_info "needs: ${needs:-none}"
    den_record "$name" dry-run 0 "" ""
    return 0
  fi

  fn=$(den_phase_fn "$name")
  if ! declare -F "$fn" >/dev/null 2>&1; then
    ui_section "$title"
    ui_err "$title: no $fn function in its phase file"
    den_record "$name" failed 0 "no $fn function" "add $fn to its phase file"
    return 0
  fi

  ui_section "$title"
  if [ "$DEN_UI" != plain ] && [ -n "$about" ]; then
    ui_info "$about"
  fi
  rm -f "$DEN_PHASE_STATUS_FILE"
  start=$(date +%s)
  rc=0
  ( set -euo pipefail; DEN_PHASE_NAME=$name; export DEN_PHASE_NAME; "$fn" ) || rc=$?
  end=$(date +%s)
  secs=$((end - start))
  if [ "$secs" -lt 0 ]; then
    secs=0
  fi

  if [ -f "$DEN_PHASE_STATUS_FILE" ]; then
    status=$(sed -n '1p' "$DEN_PHASE_STATUS_FILE")
    reason=$(sed -n '2p' "$DEN_PHASE_STATUS_FILE")
    fix=$(sed -n '3p' "$DEN_PHASE_STATUS_FILE")
    if [ -z "$status" ]; then
      status=failed
    fi
  elif [ "$rc" -eq 0 ]; then
    status="done"
    reason=""
    fix=""
  else
    status=failed
    reason="exited $rc"
    fix="den up --only=$name"
  fi

  den_record "$name" "$status" "$secs" "$reason" "$fix"
  case $status in
    done) ui_ok "$title" ;;
    skipped)
      ui_skip "$title: $reason"
      if [ -n "$fix" ]; then
        ui_info "fix: $fix"
      fi
      ;;
    *)
      ui_err "$title: $reason"
      if [ -n "$fix" ]; then
        ui_info "fix: $fix"
      fi
      ;;
  esac
  return 0
}

den_run() {
  local i t0 t1
  DEN_RUN_STARTED=$(den_now)
  t0=$(date +%s)
  for ((i = 0; i < DEN_PHASE_COUNT; i++)); do
    if ! den_phase_selected "$i"; then
      continue
    fi
    den_run_one "$i"
  done
  t1=$(date +%s)
  DEN_RUN_SECONDS=$((t1 - t0))
  if [ "$DEN_RUN_SECONDS" -lt 0 ]; then
    DEN_RUN_SECONDS=0
  fi
}

den_phase_status_write() {
  local status=${1:-failed} reason=${2:-} fix=${3:-} file=${DEN_PHASE_STATUS_FILE:-}
  if [ -z "$file" ]; then
    return 0
  fi
  reason=$(printf '%s' "$reason" | tr '\n\r' '  ')
  fix=$(printf '%s' "$fix" | tr '\n\r' '  ')
  {
    printf '%s\n' "$status"
    printf '%s\n' "$reason"
    printf '%s\n' "$fix"
  } >"$file"
}

den_skip() {
  den_phase_status_write skipped "${1:-}" "${2:-}"
  exit 0
}

den_fail() {
  den_phase_status_write failed "${1:-}" "${2:-}"
  exit 1
}

den_json_escape() {
  local text=${1:-}
  text=${text//\\/\\\\}
  text=${text//\"/\\\"}
  text=${text//$'\n'/\\n}
  text=${text//$'\r'/\\r}
  text=${text//$'\t'/\\t}
  printf '%s' "$text" | tr -d '\001-\010\013\014\016-\037'
}

den_state_dir_init() {
  mkdir -p "$DEN_STATE_DIR"
  chmod 700 "$DEN_STATE_DIR" 2>/dev/null || true
}

# last-run.json is what `den` and `den fix` read. A dry run changes nothing on
# the machine, so it goes to last-dry-run.json and leaves the real record be.
# A partial run (--only, which `den fix` uses) keeps the rows of phases it did
# not run; a full run replaces the file.
den_state_write() {
  local tmp="$DEN_STATE_DIR/.last-run.json.$$" i old="" row name keep wrote=0
  local target="$DEN_STATE_DIR/last-run.json"
  den_state_dir_init
  if [ "$DEN_DRY_RUN" = 1 ]; then
    target="$DEN_STATE_DIR/last-dry-run.json"
  elif [ -n "${DEN_ONLY:-}" ] && [ -f "$target" ]; then
    old=$(grep -oE '\{"phase":"[^"]*","status":"[^"]*","seconds":[0-9]+,"reason":"([^"\\]|\\.)*","fix":"([^"\\]|\\.)*"\}' \
      "$target" 2>/dev/null) || old=""
  fi
  if [ -z "$DEN_RUN_STARTED" ]; then
    DEN_RUN_STARTED=$(den_now)
  fi
  {
    printf '{"version":1,"started":"%s","finished":"%s","host":"%s","os":"%s","args":"%s","results":[' \
      "$(den_json_escape "$DEN_RUN_STARTED")" \
      "$(den_json_escape "$(den_now)")" \
      "$(den_json_escape "$(den_hostname)")" \
      "$(den_json_escape "$(den_os)")" \
      "$(den_json_escape "$DEN_RUN_ARGS")"
    for ((i = 0; i < DEN_RESULT_COUNT; i++)); do
      if [ "$i" -gt 0 ]; then
        printf ','
      fi
      printf '{"phase":"%s","status":"%s","seconds":%s,"reason":"%s","fix":"%s"}' \
        "$(den_json_escape "${DEN_RESULT_PHASE[$i]}")" \
        "$(den_json_escape "${DEN_RESULT_STATUS[$i]}")" \
        "${DEN_RESULT_SECONDS[$i]}" \
        "$(den_json_escape "${DEN_RESULT_REASON[$i]}")" \
        "$(den_json_escape "${DEN_RESULT_FIX[$i]}")"
      wrote=1
    done
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      name=$(printf '%s\n' "$row" | sed -n 's/^{"phase":"\([^"]*\)".*/\1/p')
      keep=1
      for ((i = 0; i < DEN_RESULT_COUNT; i++)); do
        if [ "${DEN_RESULT_PHASE[$i]}" = "$name" ]; then
          keep=0
          break
        fi
      done
      if [ "$keep" = 1 ]; then
        if [ "$wrote" = 1 ]; then
          printf ','
        fi
        printf '%s' "$row"
        wrote=1
      fi
    done <<EOF
$old
EOF
    printf ']}\n'
  } >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$target"
}

den_state_fixable() {
  local file="$DEN_STATE_DIR/last-run.json"
  if [ ! -f "$file" ]; then
    return 1
  fi
  grep -o '"phase":"[^"]*","status":"\(skipped\|failed\)"' "$file" 2>/dev/null |
    sed -e 's/^"phase":"//' -e 's/","status".*$//' || true
}
