#!/bin/sh
# The tool runner (workers/tool_run.cho; task 11, docs/worker-contract.md section 12): its authority report against the checked-in
# one (docs/authority-tool-run.txt), then the worker built and run against stand-in tools by tests/conformance/tool_run.sh (real
# child processes, outside oracles). FORGE_CANCHO_TOOLS, when set, is passed on (the real cancho-tools `tally` and `jsonq`).
# Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
# Usage: CANCHO=path/to/cancho scripts/check_tool_run.sh <scratch directory, empty, a path with no component that starts with a dash>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
tr="$scratch/tr"; mkdir "$tr" "$tr/run" || exit 1
# The runner's authority report is its review artefact (docs/authority-tool-run.txt); a change that widens it changes that file in
# the same commit and says so in the message.
$C authority workers/tool_run.cho $libs --std | sed -n '/^performs/,/^provably/p' | sed '$d' > "$tr/authority.txt"
if cmp -s "$tr/authority.txt" docs/authority-tool-run.txt; then
  echo "ok   tool runner authority: the report is the checked-in one"
else
  echo "FAIL tool runner authority: differs from docs/authority-tool-run.txt"; diff docs/authority-tool-run.txt "$tr/authority.txt"; fail=1
fi
$C check workers/tool_run.cho $libs --std || fail=1
if $C build workers/tool_run.cho $libs --std -o "$tr/tool_run"; then
  sh tests/conformance/tool_run.sh "$tr/tool_run" "$tr/run" > "$tr/out" || fail=1
  cat "$tr/out"
  if grep -q '^FAIL ' "$tr/out"; then fail=1; fi
else
  echo "FAIL tool runner: did not build"
  fail=1
fi
exit "$fail"
