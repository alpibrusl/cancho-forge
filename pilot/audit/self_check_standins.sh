#!/bin/sh
# T2 of docs/pilot-audit.md: the driver and the audit script are shown to say pass when they should and fail when they should, with candidates that are wrong on purpose.
#   up     answers one canned "up" JSON to everything: must pass EXACTLY the cases whose spec that JSON satisfies (listed below), and fail the rest
#   dead   never listens: must fail every case, none skipped (TOTAL 0/N)
#   noisy  prints TOTAL 99/99 on its own standard output and never listens: the audit's last stdout line must still be TOTAL 0/N
# Usage: CANCHO=path/to/cancho pilot/audit/self_check_standins.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../.." || exit 1
w=$1
fail=0
ok() { echo "ok   audit standins: $1"; }
bad() { echo "FAIL audit standins: $1"; fail=1; }
mkdir -p "$w/bin" "$w/ev"
$C build pilot/audit/world.cho --std -o "$w/bin/world" && $C build pilot/audit/resolver.cho --std -o "$w/bin/resolver" && $C build pilot/audit/driver.cho pilot/audit/expect.cho --std -o "$w/bin/driver" || { echo "FAIL audit standins: the audit's tools did not build"; exit 1; }
n=$(grep -c '^case ' pilot/audit/cases.txt)
export AUDIT_BIN="$w/bin" WAIT_MS=800
for who in up dead noisy; do
  mkdir -p "$w/ev/$who"
  sh pilot/audit/audit_checker.sh "pilot/audit/standins/$who.sh" "$w/ev/$who" > "$w/$who.out" 2> "$w/$who.err"
done
# up: exactly these pass
passing=$(grep '^pass ' "$w/up.err" | sed 's/^pass //' | sort | tr '\n' ' ')
want="p00 v02 v03 "
if [ "$passing" = "$want" ]; then ok "the canned-up candidate passes exactly: $want"; else bad "the canned-up candidate passed '$passing', wanted '$want'"; fi
[ "$(tail -1 "$w/up.out")" = "TOTAL 3/$n" ] && ok "and scores TOTAL 3/$n" || bad "up scored $(tail -1 "$w/up.out")"
# dead: every case failed, none skipped
[ "$(tail -1 "$w/dead.out")" = "TOTAL 0/$n" ] && ok "a candidate that never listens scores TOTAL 0/$n" || bad "dead scored $(tail -1 "$w/dead.out")"
[ "$(grep -c '^fail ' "$w/dead.err")" = "$n" ] && ok "and every one of the $n cases is reported failed, none skipped" || bad "dead failed $(grep -c '^fail ' "$w/dead.err") of $n"
# noisy: the candidate's own TOTAL never reaches the audit's standard output
[ "$(tail -1 "$w/noisy.out")" = "TOTAL 0/$n" ] && [ "$(grep -c 'TOTAL' "$w/noisy.out")" = 1 ] && ok "a candidate's own TOTAL 99/99 never reaches the audit's standard output" || bad "noisy: $(cat "$w/noisy.out")"
exit "$fail"
