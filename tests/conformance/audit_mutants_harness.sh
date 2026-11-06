#!/bin/sh
# The harness of pilot/audit/self_check_mutants.sh (RV4 defects 3 and 4, docs/review-step.md section 5.3):
#   a mutant's verdict reads the audit's last line: an audit that crashed is not a catch;
#   a relative scratch directory is relative to the caller, not to the repository.
# Usage: CANCHO=... sh tests/conformance/audit_mutants_harness.sh <scratch directory, empty>
set -u
cd "$(dirname "$0")/../.." || exit 1
repo=$(pwd)
. pilot/audit/mutant_verdict.sh
w=$1; fail=0
ok() { echo "ok   audit mutants harness: $1"; }
bad() { echo "FAIL audit mutants harness: $1"; fail=1; }
v() { printf '%s' "$1" > "$w/o"; mutant_verdict "$w/o" "$2"; }
[ "$(v 'x
TOTAL 3/5
' 5)" = caught ] && ok "TOTAL 3/5 of 5 is caught" || bad "TOTAL 3/5 of 5 is caught"
[ "$(v 'TOTAL 5/5
' 5)" = hole ] && ok "TOTAL 5/5 is a hole" || bad "TOTAL 5/5 is a hole"
[ "$(v 'Segmentation fault
' 5)" = crashed ] && ok "a crash is not a catch" || bad "a crash is not a catch"
[ "$(v '' 5)" = crashed ] && ok "empty output is not a catch" || bad "empty output is not a catch"
[ "$(v 'TOTAL 0/1
' 5)" = crashed ] && ok "TOTAL 0/1 (the audit's own 'artifact missing') is not a catch of 5 cases" || bad "TOTAL 0/1 is not a catch"
[ "$(mutant_verdict "$w/nofile" 5)" = crashed ] && ok "a missing output is not a catch" || bad "a missing output is not a catch"
# a relative scratch directory, the caller standing elsewhere
mkdir -p "$w/cwd" && cd "$w/cwd" || exit 1
MUTANTS="m06" sh "$repo/pilot/audit/self_check_mutants.sh" rel > "$w/run.out" 2>&1
if [ -d "$w/cwd/rel/m/m06" ] && [ ! -d "$repo/rel" ]; then ok "a relative scratch directory is the caller's"; else bad "a relative scratch directory is the caller's"; fi
grep -q '^caught m06' "$w/run.out" && ok "m06 is caught through a relative scratch directory" || bad "m06 is not caught through a relative scratch directory"
rm -rf "$repo/rel"
exit "$fail"
