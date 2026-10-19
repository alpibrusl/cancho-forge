#!/bin/sh
# The gate (CLAUDE.md): nothing is done until this passes.
#   cancho fmt --check   every .cho file is canonical
#   cancho check         every program type-checks, under its declared authority
#   cancho test          every `fn test_*` passes
#   file budget          no source file over 2,000 lines
# Usage: CANCHO=path/to/cancho scripts/gate.sh
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
fail=0

echo "== cancho fmt --check"
$C fmt --check src tests spike || fail=1

echo "== cancho check"
# A library has no `main`, so the program is checked as a whole (src/*.cho);
# each spike program is its own root. Tests are checked by `cancho test`.
$C check src/*.cho --std || fail=1
for f in spike/*.cho; do
  $C check "$f" --std || fail=1
done

echo "== cancho test"
$C test || fail=1

echo "== file budget (2000 lines)"
for f in $(find src tests spike -name '*.cho'); do
  n=$(wc -l < "$f")
  if [ "$n" -gt 2000 ]; then
    echo "$f: $n lines, over the 2000-line budget"
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then echo "gate: PASS"; else echo "gate: FAIL"; fi
exit "$fail"
