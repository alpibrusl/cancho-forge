#!/bin/sh
# The judge of the M-1 replay (docs/company-lifecycle.md section 9, M-1; docs/spike results): is a tree a correct fix of a past defect of cancho-code?
# A test ORACLE, not product logic. The defect's own fixture (the files its fix added or changed, read from the fix commit and never shown to the model)
# is laid over the candidate tree and the repository's own test for it is run. The model's tree passes only if that test passes.
# Usage: CANCHO=path/to/cancho CODE=path/to/cancho-code judge.sh <A|B> <tree directory>    exit 0 pass, 1 fail, 2 usage / setup
set -u
CODE="${CODE:?set CODE to the cancho-code checkout}"
defect=${1:-}; tree=${2:-}
[ -d "$tree" ] || { echo "judge: no tree" >&2; exit 2; }
case "$defect" in
  B) fix=a126d23; overlay="scripts/test-plan.sh tests/plans/brief-heap-shown.txt"; cmd="sh scripts/test-plan.sh" ;;
  A) fix=eb9fac5; overlay="scripts/test-project.sh tests/project/plan-rawtests-import.json"; cmd="sh scripts/test-project.sh" ;;
  *) echo "judge: defect A or B" >&2; exit 2 ;;
esac
j=$(mktemp -d "${TMPDIR:-/tmp}/m1-judge.XXXXXX") || exit 2
trap 'rm -rf "$j"' EXIT
cp -R "$tree/." "$j/" || exit 2
for f in $overlay; do
  mkdir -p "$j/$(dirname "$f")" && git -C "$CODE" show "$fix:$f" > "$j/$f" || { echo "judge: cannot read $f at $fix" >&2; exit 2; }
done
(cd "$j" && $cmd) > "$j/.judge.out" 2>&1
rc=$?
tail -5 "$j/.judge.out" >&2
[ $rc = 0 ] && exit 0
exit 1
