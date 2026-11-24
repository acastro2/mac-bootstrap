#!/bin/bash
# burn: free the agent VM fast. Run it INSIDE the guest when it is starved.
# Kills every process of this user that is not an agent, an agent's MCP server
# or infrastructure, then stops all Docker containers. No prompt.
#   burn         list, kill, stop containers, show uptime and free
#   burn -n      list only; kill nothing, stop nothing
#   burn --plan  pure classifier: a TAB process table on stdin
#                (pid, ppid, user, comm, args) -> KILL/KEEP lines. For tests.
# The rules live in one awk program, so live mode and --plan cannot drift.
set -u

say() { printf 'burn: %s\n' "$*"; }

# classify: process table on stdin, one KILL/KEEP line per process of $user.
# First matching rule wins (see the README: "burn: free the guest fast").
classify() { # classify USER SELF
  awk -v user="$1" -v self="$2" '
BEGIN { FS = "\t" }
{
  pid = $1; par[pid] = $2; usr[pid] = $3; cm[pid] = $4
  a = $5
  for (i = 6; i <= NF; i++) a = a "\t" $i
  ar[pid] = a; order[++n] = pid
}
function isshell(c) { return c == "zsh" || c == "bash" || c == "sh" || c == "fish" || c == "dash" }
# istofu(pid): 1 when pid or any ancestor is tofu or terraform.
function istofu(p,   g) {
  for (g = 0; p != "" && (p in par) && g < 4096; g++) {
    if (cm[p] == "tofu" || cm[p] == "terraform") return 1
    p = par[p]
  }
  return 0
}
function isagent(c) { return c == "claude" || c == "opencode" || c ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ }
function isinfra(c) {
  return c == "systemd" || c == "(sd-pam)" || c == "dbus-daemon" || c == "rex" || c == "sshd" ||
    c == "ssh-agent" || c == "gpg-agent" || c == "tmux"
}
function iseditor(c) {
  return c == "vim" || c == "nvim" || c == "nano" || c == "less" || c == "man" ||
    c == "htop" || c == "top" || c == "btop"
}
# up(pid, needle): 1 when pid or any ancestor has needle in its args.
function up(p, needle,   g) {
  for (g = 0; p != "" && (p in par) && g < 4096; g++) {
    if (index(ar[p], needle) > 0) return 1
    p = par[p]
  }
  return 0
}
END {
  p = self
  while (p != "" && !(p in sa)) { sa[p] = 1; if (!(p in par)) break; p = par[p] }
  for (k = 1; k <= n; k++) {
    pid = order[k]
    if (usr[pid] != user) continue
    c = cm[pid]; v = "KILL"; why = "not an agent"
    if (pid in sa) { v = "KEEP"; why = "self" }
    else if (isagent(c)) { v = "KEEP"; why = "agent" }
    else if (isinfra(c)) { v = "KEEP"; why = "infra" }
    else if (up(pid, "/.vscode-server/")) { v = "KEEP"; why = "vscode" }
    else if (up(pid, "ob sync") || up(pid, "obsidian-headless")) { v = "KEEP"; why = "obsidian" }
    else if (iseditor(c)) { v = "KEEP"; why = "editor" }
    else if (isshell(c) && (par[pid] in cm) &&
             (cm[par[pid]] == "rex" || cm[par[pid]] == "sshd" || cm[par[pid]] == "tmux")) {
      v = "KEEP"; why = "pane shell"
    } else {
      # Any shell between the process and its nearest agent makes it a tool
      # run: a sandbox wrapper (bwrap) may sit between the agent and the shell.
      q = pid; found = 0; sh = 0
      for (g = 0; (q in par) && g < 4096; g++) {
        if (isshell(cm[q])) sh = 1
        if (!(par[q] in cm)) break
        if (isagent(cm[par[q]])) { found = 1; break }
        q = par[q]
      }
      if (found) {
        if (sh) { v = "KILL"; why = "agent tool run" }
        else { v = "KEEP"; why = "agent MCP or helper" }
      }
    }
    # tofu, terraform and their providers get SIGINT only (see main).
    if (v == "KILL" && istofu(pid)) why = "tofu"
    gsub(/ /, "_", c)
    print v, pid, c, why
  }
}'
}

# table: this host process table as the TAB format classify reads. Drops the
# helpers of this script (ppid = $$), so burn never lists its own ps and awk.
# comm is padded to 16 columns so a comm with spaces still parses.
table() { # table SELF
  ps -e -w -w -o pid=,ppid=,user:32=,comm:16=,args= | awk -v self="$1" '
{
  line = $0
  sub(/^ +/, "", line); pid = line; sub(/ .*/, "", pid); sub(/^[^ ]+ +/, "", line)
  ppid = line; sub(/ .*/, "", ppid); sub(/^[^ ]+ +/, "", line)
  usr = line; sub(/ .*/, "", usr); sub(/^[^ ]+ +/, "", line)
  comm = substr(line, 1, 16); sub(/ +$/, "", comm)
  args = substr(line, 18)
  if (ppid == self) next
  printf "%s\t%s\t%s\t%s\t%s\n", pid, ppid, usr, comm, args
}'
}

# stat_of PID: field 22 of /proc/PID/stat (clock ticks since boot), the one
# value that tells a reused PID from the process we listed. Prints the state
# letter too, so a zombie counts as gone.
stat_of() { # stat_of PID -> "STATE START"
  local s
  s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  s=${s##*) } # cut "pid (comm) "; the comm may hold spaces and parentheses
  local -a f
  read -ra f <<<"$s"
  printf '%s %s\n' "${f[0]}" "${f[19]}"
}

# ticks_of PLAN: "pid ticks" (utime + stime, fields 14 and 15 of the full
# stat line) for every pid in the plan; a pid that is gone prints nothing.
ticks_of() { # ticks_of PLAN
  local pid s
  local -a f
  while read -r _ pid _; do
    s=$(cat "/proc/$pid/stat" 2>/dev/null) || continue
    s=${s##*) } # cut "pid (comm) "; the comm may hold spaces and parentheses
    read -ra f <<<"$s"
    printf '%s %s\n' "$pid" $((${f[11]:-0} + ${f[12]:-0}))
  done <"$1"
}

# sample_cpu PLAN: "pid cpu%" per plan pid, from two /proc samples 1 s apart
# (CPU use now, not the lifetime average of ps). "-" when a pid is gone.
sample_cpu() { # sample_cpu PLAN
  local t1 t2 e0 e1 hz
  t1=$(mktemp)
  t2=$(mktemp)
  hz=$(getconf CLK_TCK 2>/dev/null) || hz=100
  e0=${EPOCHREALTIME:-0}
  ticks_of "$1" >"$t1"
  sleep 1
  ticks_of "$1" >"$t2"
  e1=${EPOCHREALTIME:-1}
  awk -v hz="$hz" -v e0="${e0/,/.}" -v e1="${e1/,/.}" -v f1="$t1" -v f2="$t2" '
FILENAME == f1 { a[$1] = $2; next }
FILENAME == f2 { b[$1] = $2; next }
{
  el = e1 - e0; if (el <= 0) el = 1
  if (($1 in a) && ($1 in b)) printf "%s %.1f\n", $1, (b[$1] - a[$1]) / hz / el * 100
  else printf "%s -\n", $1
}' "$t1" "$t2" "$1"
  rm -f "$t1" "$t2"
}

# render_table PLAN PSFILE CPUFILE: the kill list as an aligned table, sorted by
# RSS then CPU, with a totals row and the summary line. PLAN is KILL lines,
# PSFILE is "pid rss-KiB etime", CPUFILE is "pid cpu%" ("-" = gone).
render_table() { # render_table PLAN PSFILE CPUFILE
  awk -v f1="$1" -v f2="$2" -v f3="$3" '
FILENAME == f1 {
  if ($1 != "KILL" || ($2 in seen)) next
  seen[$2] = 1; ids[++n] = $2; cm[$2] = $3
  w = $4; for (i = 5; i <= NF; i++) w = w " " $i
  why[$2] = w; next
}
FILENAME == f2 { rss[$1] = $2; et[$1] = $3; next }
FILENAME == f3 { cpu[$1] = $2; next }
function pad(s, w, right) { return sprintf(right ? "%" w "s" : "%-" w "s", s) }
function cv(p) { return ((p in cpu) && cpu[p] != "-") ? cpu[p] + 0 : -1 }
function cs(p) { return cv(p) < 0 ? "-" : sprintf("%.1f", cv(p)) }
# kc(p): the command to kill this one row by hand, the same way burn would:
# SIGTERM, but SIGINT for tofu/terraform; their providers end with tofu.
function kc(p) {
  if (why[p] != "tofu") return "kill " p
  return (cm[p] == "tofu" || cm[p] == "terraform") ? "kill -INT " p : "# ends with its tofu"
}
END {
  if (n == 0) { print "burn: nothing to kill"; exit }
  # insertion sort: RSS desc, then CPU desc
  for (i = 1; i <= n; i++) {
    x = ids[i]; j = i - 1
    while (j >= 1 && (rss[ids[j]] + 0 < rss[x] + 0 ||
           (rss[ids[j]] + 0 == rss[x] + 0 && cv(ids[j]) < cv(x)))) { ids[j + 1] = ids[j]; j-- }
    ids[j + 1] = x
  }
  wp = 3; wg = 7; wc = 4; wr = 7; wa = 3
  for (i = 1; i <= n; i++) {
    p = ids[i]; m = int(rss[p] / 1024); tr += m; tk += rss[p]; if (cv(p) >= 0) tc += cv(p)
    if (length(p) > wp) wp = length(p)
    if (length(cm[p]) > wg) wg = length(cm[p])
    if (length(cs(p)) > wc) wc = length(cs(p))
    if (length(m) > wr) wr = length(m)
    e = (p in et) ? et[p] : "-"; if (length(e) > wa) wa = length(e)
  }
  tl = "TOTAL  " n " processes"; ts = sprintf("%.1f", tc); tm = int(tk / 1024)
  if (length(tl) > wp + 2 + wg) wg = length(tl) - wp - 2
  if (length(ts) > wc) wc = length(ts)
  if (length(tm) > wr) wr = length(tm)
  ww = 3; wk = 9
  for (i = 1; i <= n; i++) {
    if (length(why[ids[i]]) > ww) ww = length(why[ids[i]])
    if (length(kc(ids[i])) > wk) wk = length(kc(ids[i]))
  }
  tw = wp + 2 + wg + 2 + wc + 2 + wr + 2 + wa + 2 + ww + 2 + wk
  rule = ""; for (i = 1; i <= tw; i++) rule = rule "-"
  print pad("PID", wp, 1) "  " pad("PROGRAM", wg, 0) "  " pad("CPU%", wc, 1) "  " pad("RSS MiB", wr, 1) "  " pad("AGE", wa, 0) "  " pad("WHY", ww, 0) "  KILL WITH"
  print rule
  for (i = 1; i <= n; i++) {
    p = ids[i]; e = (p in et) ? et[p] : "-"
    print pad(p, wp, 1) "  " pad(cm[p], wg, 0) "  " pad(cs(p), wc, 1) "  " pad(int(rss[p] / 1024), wr, 1) "  " pad(e, wa, 0) "  " pad(why[p], ww, 0) "  " kc(p)
  }
  print rule
  print pad(tl, wp + 2 + wg, 0) "  " pad(ts, wc, 1) "  " pad(tm, wr, 1)
  printf "burn: %d process(es) to kill, %d MiB RSS, %s%% CPU now\n", n, tm, ts
}' "$1" "$2" "$3"
}

K_PIDS=()
K_START=()

alive() { # alive IDX: the listed process still runs (same start time, not a zombie)
  local st
  st=$(stat_of "${K_PIDS[$1]}") || return 1
  [ "${st%% *}" != Z ] && [ "${st##* }" = "${K_START[$1]}" ]
}

sig() { # sig SIGNAL IDX: signal only an owned, live, same-start process
  local pid=${K_PIDS[$2]}
  [ "$pid" -gt 1 ] || return 0
  [ -O "/proc/$pid" ] || return 0
  alive "$2" || return 0
  kill "-$1" "$pid" 2>/dev/null || true
}

wait_gone() { # wait_gone SECONDS IDXS...: up to SECONDS for them all to exit
  local secs=$1 i n left
  shift
  for ((n = 0; n < secs * 5; n++)); do
    left=0
    for i in "$@"; do alive "$i" && left=1; done
    [ "$left" = 0 ] && return 0
    sleep 0.2
  done
  return 0
}

stop_containers() {
  if ! command -v docker >/dev/null 2>&1; then
    say "docker is not installed; no containers to stop"
    return 0
  fi
  local ids names id
  if ! ids=$(docker ps -q 2>/dev/null); then
    say "docker does not answer; containers not stopped"
    return 0
  fi
  if [ -z "$ids" ]; then
    say "no running containers"
    return 0
  fi
  names=$(docker ps --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
  local -a list=()
  while IFS= read -r id; do list+=("$id"); done <<<"$ids"
  say "stopping ${#list[@]} container(s): $names"
  docker stop -t 5 "${list[@]}" >/dev/null 2>&1 || say "docker stop reported an error"
}

main() {
  local mode=live
  case ${1:-} in
  "") ;;
  -n) mode=dry ;;
  --plan) mode=plan ;;
  *)
    printf 'usage: burn [-n | --plan]\n' >&2
    return 2
    ;;
  esac

  local user=${BURN_USER:-${USER:-$(id -un)}}
  local self=${BURN_SELF:-$$}

  if [ "$mode" = plan ]; then
    classify "$user" "$self"
    return 0
  fi

  local tbl plan rss cpu
  tbl=$(mktemp)
  plan=$(mktemp)
  rss=$(mktemp)
  cpu=$(mktemp)
  # No $(...) around ps: its children must have this shell as parent (table()).
  table "$self" >"$tbl"
  classify "$user" "$self" <"$tbl" | awk '$1 == "KILL"' >"$plan"
  ps -e -o pid=,rss=,etime= >"$rss" 2>/dev/null

  if [ -s "$plan" ]; then
    say "sampling CPU for 1 s..."
    sample_cpu "$plan" >"$cpu"
  fi
  render_table "$plan" "$rss" "$cpu"

  if [ "$mode" = dry ]; then
    say "dry run: nothing killed, no container stopped"
    rm -f "$tbl" "$plan" "$rss" "$cpu"
    return 0
  fi

  local pid st why comm i
  local tofu=() rest=() tfint=() # tofu: SIGINT only; rest: STOP, TERM, KILL
  while read -r _ pid comm why; do
    [ "$pid" -gt 1 ] 2>/dev/null || continue
    st=$(stat_of "$pid") || continue
    K_PIDS+=("$pid")
    K_START+=("${st##* }")
    i=$((${#K_PIDS[@]} - 1))
    if [ "$why" = tofu ]; then
      tofu+=("$i")
      case $comm in tofu | terraform) tfint+=("$i") ;; esac
    else
      rest+=("$i")
    fi
  done <"$plan"
  rm -f "$tbl" "$plan" "$rss" "$cpu"

  if [ "${#K_PIDS[@]}" -gt 0 ]; then
    # 1. Freeze the rest so a loop cannot start a new job between steps.
    say "freezing ${#rest[@]} process(es)"
    for i in "${rest[@]}"; do sig STOP "$i"; done
    # 2. tofu and terraform only get INT, so they can release state locks.
    say "SIGINT to ${#tfint[@]} tofu/terraform process(es)"
    for i in "${tfint[@]}"; do sig INT "$i"; done
    # 3. TERM, then CONT so stopped processes can act on the TERM.
    say "SIGTERM"
    for i in "${rest[@]}"; do sig TERM "$i"; done
    for i in "${rest[@]}"; do sig CONT "$i"; done
    # 4. Give them 5 s, then SIGKILL what is left.
    wait_gone 5 "${rest[@]}"
    local left=0
    for i in "${rest[@]}"; do
      if alive "$i"; then
        left=$((left + 1))
        sig KILL "$i"
      fi
    done
    say "SIGKILL to $left stubborn process(es)"
  fi

  # 5. Containers.
  stop_containers

  # 6. Give tofu up to 60 s to finish; it never gets STOP, TERM or KILL.
  if [ "${#tofu[@]}" -gt 0 ]; then
    wait_gone 60 "${tofu[@]}"
    for i in "${tofu[@]}"; do
      alive "$i" && say "tofu ${K_PIDS[$i]} still finishing; let it end, or run tofu force-unlock later if its lock stays"
    done
  fi

  uptime
  free -h
}

main "$@"
