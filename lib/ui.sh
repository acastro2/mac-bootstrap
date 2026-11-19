# shellcheck shell=bash
# lib/ui.sh — den output and prompts. Contract: docs/den/CONTRACT.md.
# Modes: gum (gum + TTY), ansi (TTY), plain (no escape codes).

den_ui_pick() {
  case ${DEN_UI:-auto} in
    gum|ansi|plain) printf '%s' "$DEN_UI" ;;
    *)
      if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && command -v gum >/dev/null 2>&1; then
        printf gum
      elif [ -t 1 ]; then
        printf ansi
      else
        printf plain
      fi
      ;;
  esac
}

DEN_UI=$(den_ui_pick)
export DEN_UI

DEN_C_RESET=""
DEN_C_BOLD=""
DEN_C_DIM=""
DEN_C_GREEN=""
DEN_C_YELLOW=""
DEN_C_RED=""
DEN_C_CYAN=""
if [ "$DEN_UI" != plain ]; then
  DEN_C_RESET=$'\033[0m'
  DEN_C_BOLD=$'\033[1m'
  DEN_C_DIM=$'\033[2m'
  DEN_C_GREEN=$'\033[32m'
  DEN_C_YELLOW=$'\033[33m'
  DEN_C_RED=$'\033[31m'
  DEN_C_CYAN=$'\033[36m'
fi

ui_quip() {
  case $((RANDOM % 6)) in
    0) printf 'A second run changes nothing. That is the whole trick.' ;;
    1) printf 'The cave is warm. The brew is cold.' ;;
    2) printf 'No phase left behind.' ;;
    3) printf 'Sudo wants a cookie every fifty seconds.' ;;
    4) printf 'Idempotent is a love language.' ;;
    *) printf 'If it breaks, the fix line tells you what to type.' ;;
  esac
}

ui_banner() {
  if [ "$DEN_UI" = plain ]; then
    return 0
  fi
  printf '\n'
  printf '   /\\_/\\    %sden%s %s- a warm cave for cold tools%s\n' \
    "$DEN_C_BOLD" "$DEN_C_RESET" "$DEN_C_DIM" "$DEN_C_RESET"
  printf '  ( o.o )   %s%s%s\n' "$DEN_C_DIM" "$(ui_quip)" "$DEN_C_RESET"
  printf '   > ^ <\n'
  printf '\n'
}

ui_section() {
  local title=${1:-}
  if [ "$DEN_UI" = plain ]; then
    printf '\n== %s ==\n' "$title"
  else
    printf '\n%s%s%s\n' "$DEN_C_BOLD" "$title" "$DEN_C_RESET"
  fi
}

ui_step() {
  if [ "$DEN_UI" = plain ]; then
    printf '  - %s\n' "${1:-}"
  else
    printf '  %s->%s %s\n' "$DEN_C_CYAN" "$DEN_C_RESET" "${1:-}"
  fi
}

ui_ok() {
  if [ "$DEN_UI" = plain ]; then
    printf '[ok] %s\n' "${1:-}"
  else
    printf '%s✓%s %s\n' "$DEN_C_GREEN" "$DEN_C_RESET" "${1:-}"
  fi
}

ui_warn() {
  if [ "$DEN_UI" = plain ]; then
    printf '[warn] %s\n' "${1:-}" >&2
  else
    printf '%s!%s %s\n' "$DEN_C_YELLOW" "$DEN_C_RESET" "${1:-}" >&2
  fi
}

ui_err() {
  if [ "$DEN_UI" = plain ]; then
    printf '[err] %s\n' "${1:-}" >&2
  else
    printf '%s✗%s %s\n' "$DEN_C_RED" "$DEN_C_RESET" "${1:-}" >&2
  fi
}

ui_skip() {
  if [ "$DEN_UI" = plain ]; then
    printf '[skip] %s\n' "${1:-}"
  else
    printf '%s↷%s %s\n' "$DEN_C_DIM" "$DEN_C_RESET" "${1:-}"
  fi
}

ui_info() {
  if [ "$DEN_UI" = plain ]; then
    printf '[info] %s\n' "${1:-}"
  else
    printf '%s·%s %s\n' "$DEN_C_DIM" "$DEN_C_RESET" "${1:-}"
  fi
}

ui_spin() {
  local title=${1:-}
  local out="" rc=0
  if [ $# -gt 0 ]; then
    shift
  fi
  if [ $# -eq 0 ]; then
    return 0
  fi
  if [ "$DEN_UI" = gum ]; then
    gum spin --spinner dot --title "$title" -- "$@"
    return $?
  fi
  out=$("$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    ui_err "$title"
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | sed 's/^/    /' >&2
    fi
  elif [ -n "$title" ]; then
    ui_step "$title"
  fi
  return "$rc"
}

ui_confirm() {
  local question=${1:-continue?} answer=""
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    return 1
  fi
  if [ "$DEN_UI" = gum ]; then
    gum confirm "$question"
    return $?
  fi
  printf '%s [y/N] ' "$question" >&2
  IFS= read -r answer || answer=""
  case $answer in
    y|Y|yes|Yes|YES) return 0 ;;
  esac
  return 1
}

ui_input() {
  local prompt=${1:-} default=${2:-} value=""
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    printf '%s\n' "$default"
    return 0
  fi
  if [ "$DEN_UI" = gum ]; then
    gum input --prompt "$prompt " --value "$default"
    return 0
  fi
  printf '%s [%s]: ' "$prompt" "$default" >&2
  IFS= read -r value || value=""
  if [ -z "$value" ]; then
    value=$default
  fi
  printf '%s\n' "$value"
}

ui_choose() {
  local prompt=${1:-}
  if [ $# -gt 0 ]; then
    shift
  fi
  if [ $# -eq 0 ]; then
    return 1
  fi
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    printf '%s\n' "$1"
    return 0
  fi
  if [ "$DEN_UI" = gum ]; then
    gum choose --header "$prompt" "$@"
    return 0
  fi
  local i=1 option answer picked=""
  printf '%s\n' "$prompt" >&2
  for option in "$@"; do
    printf '  %s) %s\n' "$i" "$option" >&2
    i=$((i + 1))
  done
  printf '> ' >&2
  IFS= read -r answer || answer=""
  case $answer in
    ''|*[!0-9]*) printf '%s\n' "$1"; return 0 ;;
  esac
  i=1
  for option in "$@"; do
    if [ "$i" = "$answer" ]; then
      picked=$option
    fi
    i=$((i + 1))
  done
  if [ -z "$picked" ]; then
    picked=$1
  fi
  printf '%s\n' "$picked"
}

ui_trim() {
  local text=${1:-} max=${2:-44}
  if [ "${#text}" -le "$max" ]; then
    printf '%s' "$text"
    return 0
  fi
  printf '%s...' "${text:0:$((max - 3))}"
}

ui_status_text() {
  local status=${1:-}
  if [ "$DEN_UI" = plain ]; then
    case $status in
      done) printf 'done' ;;
      skipped) printf 'skip' ;;
      failed) printf 'fail' ;;
      dry-run) printf 'dry' ;;
      *) printf '%s' "$status" ;;
    esac
    return 0
  fi
  case $status in
    done) printf '%s✓%s' "$DEN_C_GREEN" "$DEN_C_RESET" ;;
    skipped) printf '%s↷%s' "$DEN_C_DIM" "$DEN_C_RESET" ;;
    failed) printf '%s✗%s' "$DEN_C_RED" "$DEN_C_RESET" ;;
    dry-run) printf '%s◇%s' "$DEN_C_CYAN" "$DEN_C_RESET" ;;
    *) printf '%s' "$status" ;;
  esac
}

ui_summary() {
  local n=${DEN_RESULT_COUNT:-0} i status phase secs
  local w_phase=5 w_secs=4 w_reason=6
  local done_n=0 skip_n=0 fail_n=0 dry_n=0
  local reason fix cell pad
  for ((i = 0; i < n; i++)); do
    phase=${DEN_RESULT_PHASE[$i]}
    status=${DEN_RESULT_STATUS[$i]}
    if [ "${#phase}" -gt "$w_phase" ]; then
      w_phase=${#phase}
    fi
    reason=$(ui_trim "${DEN_RESULT_REASON[$i]}" 44)
    if [ "${#reason}" -gt "$w_reason" ]; then
      w_reason=${#reason}
    fi
    secs="${DEN_RESULT_SECONDS[$i]}s"
    if [ "${#secs}" -gt "$w_secs" ]; then
      w_secs=${#secs}
    fi
    case $status in
      done) done_n=$((done_n + 1)) ;;
      skipped) skip_n=$((skip_n + 1)) ;;
      failed) fail_n=$((fail_n + 1)) ;;
      dry-run) dry_n=$((dry_n + 1)) ;;
    esac
  done
  if [ "$n" -gt 0 ]; then
    printf '\n'
    printf '  %-*s  %-6s  %*s  %-*s  %s\n' \
      "$w_phase" "phase" "status" "$w_secs" "secs" "$w_reason" "reason" "fix"
    for ((i = 0; i < n; i++)); do
      phase=${DEN_RESULT_PHASE[$i]}
      status=${DEN_RESULT_STATUS[$i]}
      secs=${DEN_RESULT_SECONDS[$i]}
      reason=$(ui_trim "${DEN_RESULT_REASON[$i]}" 44)
      fix=$(ui_trim "${DEN_RESULT_FIX[$i]}" 44)
      cell=$(ui_status_text "$status")
      if [ "$DEN_UI" = plain ]; then
        pad=$((6 - ${#cell}))
      else
        pad=5
      fi
      if [ "$pad" -lt 0 ]; then
        pad=0
      fi
      printf '  %-*s  %s%*s  %*s' "$w_phase" "$phase" "$cell" "$pad" "" "$w_secs" "${secs}s"
      if [ -n "$reason" ] || [ -n "$fix" ]; then
        printf '  %-*s  %s' "$w_reason" "$reason" "$fix"
      fi
      printf '\n'
    done
  fi
  local sep=" · "
  if [ "$DEN_UI" = plain ]; then
    sep=" | "
  fi
  local tail=""
  if [ "$dry_n" -gt 0 ]; then
    tail=" · $dry_n dry-run"
    if [ "$DEN_UI" = plain ]; then
      tail=" | $dry_n dry-run"
    fi
  fi
  if [ "$n" -gt 0 ]; then
    printf '\n'
  fi
  printf '%d done%s%d skipped%s%d failed%s in %ss\n' \
    "$done_n" "$sep" "$skip_n" "$sep" "$fail_n" "$tail" "${DEN_RUN_SECONDS:-0}"
}
