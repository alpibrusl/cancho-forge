#!/bin/sh
# The gate (CLAUDE.md): nothing is done until this passes.
#   cancho fmt --check   every .cho file is canonical
#   cancho check         every program type-checks, under its declared authority
#   cancho test          every `fn test_*` passes (pure logic: tasks, journal replay)
#   conformance          tests/conformance/*.cho, programs that need an Fs, which
#                        `cancho test` cannot hand a test: built, run against a
#                        scratch directory made here and removed, exit 0 = held
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

echo "== conformance (file layer)"
# Each program needs the library without src/main.cho (a program has one main)
# and the shared helpers in tests/conformance/support.cho. They are built and
# run against a scratch directory made here and removed on exit.
libs=$(ls src/*.cho | grep -v '/main\.cho$')
scratch=$(mktemp -d "${TMPDIR:-/tmp}/forge-conformance.XXXXXX") || exit 1
trap 'rm -rf "$scratch"' EXIT
held=0
for prog in journal_files snapshot_files; do
  echo "-- $prog"
  $C check tests/conformance/$prog.cho tests/conformance/support.cho $libs --std || fail=1
  mkdir "$scratch/$prog" || exit 1
  if $C build tests/conformance/$prog.cho tests/conformance/support.cho $libs --std -o "$scratch/$prog.bin"; then
    "$scratch/$prog.bin" "$scratch/$prog" > "$scratch/$prog.out" || fail=1
    cat "$scratch/$prog.out"
    held=$((held + $(grep -c '^ok ' "$scratch/$prog.out")))
    if grep -q '^FAIL ' "$scratch/$prog.out"; then fail=1; fi
  else
    echo "conformance: $prog did not build"
    fail=1
  fi
done
echo "conformance cases held: $held"

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
