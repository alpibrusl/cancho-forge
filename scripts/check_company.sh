#!/bin/sh
# `forge company check` and `forge company status` end to end (docs/superpowers/specs/2026-10-27-forge-company-layer-design.md, 4.4).
# The oracle is outside the program: the exit status and output of the forge binary on tests/fixtures/company/*.json and on
# company directories made here with printf, `cmp`, `cksum` and `ls`. Both verbs are read-only: the journal is not changed by one
# byte and no `lock` file appears in the company directory.
# Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or the build failed.
# Usage: CANCHO=path/to/cancho scripts/check_company.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
root=$(pwd)
scratch=$1
fail=0
if $C build src/*.cho --std -o "$scratch/forge"; then
  F="$scratch/forge"
  fx="$root/tests/fixtures/company"
  # run <name> <exit wanted> <stdout wanted, '' for any> <command...>; stdout in $scratch/out
  run() {
    name=$1; code=$2; want=$3; shift 3
    "$@" > "$scratch/out" 2> "$scratch/err"; rc=$?
    if [ "$rc" -eq "$code" ] && { [ -z "$want" ] || [ "$(cat "$scratch/out")" = "$want" ]; }; then
      echo "ok   company: $name"
    else
      echo "FAIL company: $name (exit $rc, wanted $code)"; cat "$scratch/out"; fail=1
    fi
  }
  has() { # name, text that the last output must hold a line of
    if grep -qx "$2" "$scratch/out"; then echo "ok   company: $1"; else echo "FAIL company: $1"; cat "$scratch/out"; fail=1; fi
  }
  # ---- check
  run "check: a valid manifest, exit 0" 0 "valid: statuslite, 3 steps" "$F" company check "$fx/good.json"
  run "check: a step id twice" 1 "refusal: step-id-duplicate" "$F" company check "$fx/dup-step.json"
  run "check: a cycle" 1 "refusal: step-cycle" "$F" company check "$fx/cycle.json"
  run "check: a field the shape does not have" 1 "refusal: manifest-unknown-field" "$F" company check "$fx/unknown-field.json"
  run "check: a file that is not there is a manifest-malformed" 1 "refusal: manifest-malformed" "$F" company check "$scratch/nowhere.json"
  : > "$scratch/empty.json"
  run "check: an empty file" 1 "refusal: manifest-malformed" "$F" company check "$scratch/empty.json"
  run "check: a relative path is path-invalid, exit 2" 2 "refusal: path-invalid" "$F" company check tests/fixtures/company/good.json
  run "check: no path is usage, exit 2" 2 "" "$F" company check
  run "check: two paths is usage, exit 2" 2 "" "$F" company check "$fx/good.json" "$fx/cycle.json"
  run "no sub-verb is usage, exit 2" 2 "" "$F" company
  run "an unknown sub-verb is usage, exit 2" 2 "" "$F" company run "$fx"
  # ---- status
  ws="$scratch/co"; mkdir "$ws" || exit 1
  cp "$fx/good.json" "$ws/company.json"
  run "status: no journal is nothing happened yet" 0 "brief gated
lib waiting
gate waiting
spend: input 0 output 0 cache_write 0 cache_read 0
open gates: product-brief" "$F" company status "$ws"
  J="$ws/company.journal"
  printf '%s\n' '{"v":1,"seq":1,"kind":"company.gate.decided","task":"product-brief","gate":"product-brief","verdict":"approved","user":"u","reason":"r"}' \
    '{"v":1,"seq":2,"kind":"company.step.accepted","task":"brief","artifact":"a.txt","sha256":"abc"}' \
    '{"v":1,"seq":3,"kind":"company.spend.recorded","task":"lib","input":5,"output":6,"cache_write":7,"cache_read":8}' > "$J"
  run "status: an approved gate, an accepted step, spend" 0 "brief accepted
lib ready
gate waiting
spend: input 5 output 6 cache_write 7 cache_read 8
open gates: none" "$F" company status "$ws"
  printf '{"v":1,"se' >> "$J"
  before_torn=$(cksum < "$J")
  run "status: a torn tail is counted and not read" 0 "" "$F" company status "$ws"
  has "status: and the torn bytes are named" "torn tail bytes: 10"
  [ "$(cksum < "$J")" = "$before_torn" ] && echo "ok   company: status cut no byte of the journal" || { echo "FAIL company: the journal changed"; fail=1; }
  [ ! -e "$ws/lock" ] && echo "ok   company: status took no lock" || { echo "FAIL company: a lock file appeared"; fail=1; }
  [ "$(ls "$ws" | tr '\n' ' ')" = "company.journal company.json " ] && echo "ok   company: status created no file" || { echo "FAIL company: files in the company directory changed"; fail=1; }
  printf 'garbage\n' >> "$J"
  run "status: a corrupt journal is refused, exit 1" 1 "" "$F" company status "$ws"
  has "status: the refusal is named" "refusal: journal-corrupt"
  has "status: and its line" "line: 4"
  has "status: and what replayed before it is shown" "brief accepted"
  rm "$J"; mkdir "$J"
  run "status: a journal that cannot be read, exit 3" 3 "" "$F" company status "$ws"
  rmdir "$J"
  mkdir "$scratch/empty-co"
  run "status: no company.json is a manifest-malformed" 1 "refusal: manifest-malformed" "$F" company status "$scratch/empty-co"
  cp "$fx/cycle.json" "$scratch/empty-co/company.json"
  run "status: a refused manifest names its rule" 1 "refusal: step-cycle" "$F" company status "$scratch/empty-co"
  run "status: a relative directory is path-invalid, exit 2" 2 "refusal: path-invalid" "$F" company status co
  run "status: no directory is usage, exit 2" 2 "" "$F" company status
else
  echo "FAIL company: forge did not build"
  fail=1
fi
exit "$fail"
