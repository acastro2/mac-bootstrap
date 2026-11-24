#!/bin/bash
# burn.test.sh: guard for the burn classifier (burn --plan). Run from anywhere:
#   bash vm/burn.test.sh
# The fixture is a real guest process tree (2026-11-24) plus a bwrap sandbox
# case. Change the fixture or the expected sets only when a rule changes.
set -u
D=$(cd "$(dirname "$0")" && pwd)
out=$(BURN_SELF=8000 BURN_USER=me /bin/bash "$D/burn.sh" --plan <"$D/burn.fixture.tsv") || {
  echo "FAIL: burn --plan exited $?"
  exit 1
}
pids() { printf '%s\n' "$out" | awk -v v="$1" '$1 == v { print $2 }' | sort -n | tr '\n' ' '; }
want_kill="7101 7102 7990 7991 1884027 1908515 1908535 1927405 1959917 1959918 1960313 "
want_keep="916 917 1976 2009 3000 3721 3722 4000 4001 4002 5001 5002 6000 7100 7982 8000 9000 9200 12939 13507 19947 "
# tofu/terraform and their providers: SIGINT only, never STOP/TERM/KILL.
want_tofu="1959918 1960313 "
fail=0
got=$(pids KILL); [ "$got" = "$want_kill" ] || { echo "FAIL kill: got [$got] want [$want_kill]"; fail=1; }
got=$(pids KEEP); [ "$got" = "$want_keep" ] || { echo "FAIL keep: got [$got] want [$want_keep]"; fail=1; }
got=$(printf '%s\n' "$out" | awk '$1 == "KILL" && $4 == "tofu" { print $2 }' | sort -n | tr '\n' ' ')
[ "$got" = "$want_tofu" ] || { echo "FAIL tofu (INT only): got [$got] want [$want_tofu]"; fail=1; }
if printf '%s\n' "$out" | awk '$2 == 1 || $2 == 3720 || $2 == 9100' | grep -q .; then
  echo "FAIL: a root-owned process was listed"
  fail=1
fi
[ "$fail" = 0 ] && echo "PASS burn --plan (11 kill, 2 of them tofu INT-only; 21 keep; root ignored)"
exit "$fail"
