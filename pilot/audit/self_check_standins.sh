#!/bin/sh
# T2 of docs/pilot-audit.md: the driver and the audit script are shown to say pass when they should and fail when they should, with candidates that are wrong on purpose.
#   up     answers one canned "up" JSON to everything: must pass EXACTLY the cases whose spec that JSON satisfies (listed below: a 200 and `up` with nothing else asked of it), and fail the rest
#   dead   never listens: must fail every case, none skipped (TOTAL 0/N)
#   noisy  prints TOTAL 99/99 on its own standard output and never listens: the audit's last stdout line must still be TOTAL 0/N
# Usage: CANCHO=path/to/cancho pilot/audit/self_check_standins.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../.." || exit 1
. scripts/packages.sh
w=$1
fail=0
ok() { echo "ok   audit standins: $1"; }
bad() { echo "FAIL audit standins: $1"; fail=1; }
mkdir -p "$w/bin" "$w/ev"
sh pilot/audit/build_tools.sh "$w/bin" || { echo "FAIL audit standins: the audit's tools did not build"; exit 1; }
# The gate runs 12 chosen cases (the 8 the canned candidate passes and 4 it fails, one of each kind: an exact-field, a redirect, a refusal, a TLS one); FULL=1 runs all of
# them, which takes about ten minutes. The full run was measured once: 8 of 71 for the canned candidate, 0 of 71 for the dead one.
if [ -z "${FULL:-}" ]; then
  export ONLY="p00 v02 v03 l01 l06 l07 p03 p05 v01 v07 r01 t01"
  n=12
else
  n=$(grep -c '^case ' pilot/audit/cases.txt)
fi
export AUDIT_BIN="$w/bin" WAIT_MS=800
for who in up dead noisy; do
  mkdir -p "$w/ev/$who"
  sh pilot/audit/audit_checker.sh "pilot/audit/standins/$who.sh" "$w/ev/$who" > "$w/$who.out" 2> "$w/$who.err"
done
# up: exactly these pass
passing=$(grep '^pass ' "$w/up.err" | sed 's/^pass //' | sort | tr '\n' ' ')
want="l01 l06 l07 p00 p03 p05 v02 v03 "
if [ "$passing" = "$want" ]; then ok "the canned-up candidate passes exactly: $want"; else bad "the canned-up candidate passed '$passing', wanted '$want'"; fi
[ "$(tail -1 "$w/up.out")" = "TOTAL 8/$n" ] && ok "and scores TOTAL 8/$n" || bad "up scored $(tail -1 "$w/up.out")"
# dead: every case failed, none skipped
[ "$(tail -1 "$w/dead.out")" = "TOTAL 0/$n" ] && ok "a candidate that never listens scores TOTAL 0/$n" || bad "dead scored $(tail -1 "$w/dead.out")"
[ "$(grep -c '^fail ' "$w/dead.err")" = "$n" ] && ok "and every one of the $n cases is reported failed, none skipped" || bad "dead failed $(grep -c '^fail ' "$w/dead.err") of $n"
# noisy: the candidate's own TOTAL never reaches the audit's standard output
[ "$(tail -1 "$w/noisy.out")" = "TOTAL 0/$n" ] && [ "$(grep -c 'TOTAL' "$w/noisy.out")" = 1 ] && ok "a candidate's own TOTAL 99/99 never reaches the audit's standard output" || bad "noisy: $(cat "$w/noisy.out")"
exit "$fail"
