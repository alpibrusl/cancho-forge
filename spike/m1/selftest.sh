#!/bin/sh
# The judge must be able to tell: the base of a defect with its fixture laid over it FAILS, the fix commit's tree PASSES. Run this before the model is paid.
# Usage: CANCHO=... CODE=... selftest.sh <scratch dir, empty>
set -u
CODE="${CODE:?}"; w=$1; here=$(cd "$(dirname "$0")" && pwd)
fail=0
tree() { mkdir -p "$w/$1" && git -C "$CODE" archive "$2" | tar -x -C "$w/$1"; }
check() { # name, defect, tree, want rc
  CODE="$CODE" sh "$here/judge.sh" "$2" "$3" > /dev/null 2>&1; rc=$?
  if [ "$rc" = "$4" ]; then echo "ok   m1 judge: $1"; else echo "FAIL m1 judge: $1 (rc $rc, wanted $4)"; fail=1; fi
}
. "$here/defects.sh"
for d in A B; do
  base=$(eval echo \$BASE_$d); fix=$(eval echo \$FIX_$d)
  tree "base-$d" "$base"; tree "fix-$d" "$fix"
  check "defect $d: the base with the fixture over it fails" "$d" "$w/base-$d" 1
  check "defect $d: the fix commit's tree passes" "$d" "$w/fix-$d" 0
done
exit $fail
