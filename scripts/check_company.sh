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
  # run <name> <exit wanted> <stdout wanted exactly; '' means stdout must be empty, '-' means any> <command...>; stdout in $scratch/out
  run() {
    name=$1; code=$2; want=$3; shift 3
    "$@" > "$scratch/out" 2> "$scratch/err"; rc=$?
    if [ "$rc" -eq "$code" ] && { [ "$want" = "-" ] || [ "$(cat "$scratch/out")" = "$want" ]; }; then
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
  run "status: a torn tail is counted and not read" 0 - "$F" company status "$ws"
  has "status: and the torn bytes are named" "torn tail bytes: 10"
  [ "$(cksum < "$J")" = "$before_torn" ] && echo "ok   company: status cut no byte of the journal" || { echo "FAIL company: the journal changed"; fail=1; }
  [ ! -e "$ws/lock" ] && echo "ok   company: status took no lock" || { echo "FAIL company: a lock file appeared"; fail=1; }
  [ "$(ls "$ws" | tr '\n' ' ')" = "company.journal company.json " ] && echo "ok   company: status created no file" || { echo "FAIL company: files in the company directory changed"; fail=1; }
  printf 'garbage\n' >> "$J"
  run "status: a corrupt journal is refused, exit 1" 1 - "$F" company status "$ws"
  has "status: the refusal is named" "refusal: journal-corrupt"
  has "status: and its line" "line: 4"
  has "status: and what replayed before it is shown" "brief accepted"
  rm "$J"; mkdir "$J"
  run "status: a journal that cannot be read, exit 3" 3 "error: cannot read company.journal" "$F" company status "$ws"
  rmdir "$J"
  mkdir "$scratch/empty-co"
  run "status: no company.json is a manifest-malformed" 1 "refusal: manifest-malformed" "$F" company status "$scratch/empty-co"
  cp "$fx/cycle.json" "$scratch/empty-co/company.json"
  run "status: a refused manifest names its rule" 1 "refusal: step-cycle" "$F" company status "$scratch/empty-co"
  run "status: a relative directory is path-invalid, exit 2" 2 "refusal: path-invalid" "$F" company status co
  run "status: no directory is usage, exit 2" 2 "" "$F" company status
  # ---- decide: takes the lock, appends company.gate.decided, authenticates nothing (the OS user is USER, "unknown" without it)
  dw="$scratch/dec"; mkdir "$dw" || exit 1
  cp "$fx/good.json" "$dw/company.json"
  DJ="$dw/company.journal"
  run "decide: no reason is usage, exit 2" 2 "" "$F" company decide "$dw" product-brief approved
  run "decide: a verdict that is neither approved nor rejected is usage, exit 2" 2 "" "$F" company decide "$dw" product-brief maybe because
  run "decide: a relative directory is path-invalid, exit 2" 2 "refusal: path-invalid" "$F" company decide dec product-brief approved because
  run "decide: a gate the manifest does not list is gate-unknown, exit 1" 1 "refusal: gate-unknown" "$F" company decide "$dw" nope approved because
  [ ! -e "$DJ" ] && echo "ok   company: a refused decision wrote no journal" || { echo "FAIL company: gate-unknown wrote a journal"; fail=1; }
  mkdir "$scratch/dec-nomanifest"
  run "decide: no company.json is manifest-malformed, exit 1" 1 "refusal: manifest-malformed" "$F" company decide "$scratch/dec-nomanifest" product-brief approved because
  run "decide: approved, exit 0, the gate's state is printed" 0 "gate product-brief: approved" env USER=ana "$F" company decide "$dw" product-brief approved looks good to me
  [ "$(wc -l < "$DJ")" -eq 1 ] && echo "ok   company: decide wrote one journal line" || { echo "FAIL company: not one line"; fail=1; }
  grep -q '"kind":"company.gate.decided".*"gate":"product-brief","verdict":"approved","user":"ana","reason":"looks good to me"' "$DJ" && echo "ok   company: the line holds gate, verdict, the OS user and the reason" || { echo "FAIL company: wrong line"; cat "$DJ"; fail=1; }
  run "decide: after approval status shows the gate decided" 0 "brief ready
lib waiting
gate waiting
spend: input 0 output 0 cache_write 0 cache_read 0
open gates: none" "$F" company status "$dw"
  run "decide: rejected after approved, exit 0" 0 "gate product-brief: rejected" env USER=bob "$F" company decide "$dw" product-brief rejected "scope changed"
  run "decide: a rejected gate leaves its step rejected and its dependents waiting" 0 "brief rejected
lib waiting
gate waiting
spend: input 0 output 0 cache_write 0 cache_read 0
open gates: none" "$F" company status "$dw"
  run "decide: approved again, exit 0 (a later approval is allowed)" 0 "gate product-brief: approved" env -u USER "$F" company decide "$dw" product-brief approved "second thoughts"
  [ "$(wc -l < "$DJ")" -eq 3 ] && echo "ok   company: approve, reject, approve left three journal entries" || { echo "FAIL company: not three entries"; fail=1; }
  [ "$(sed 's/.*"seq":\([0-9]*\).*/\1/' "$DJ" | tr '\n' ' ')" = "1 2 3 " ] && echo "ok   company: and their seq is 1 2 3" || { echo "FAIL company: seq"; fail=1; }
  [ "$(sed 's/.*"verdict":"\([a-z]*\)".*/\1/' "$DJ" | tr '\n' ' ')" = "approved rejected approved " ] && echo "ok   company: in the order they were made" || { echo "FAIL company: verdict order"; fail=1; }
  [ "$(sed -n 3p "$DJ" | sed 's/.*"user":"\([^"]*\)".*/\1/')" = "unknown" ] && echo "ok   company: without USER the user is unknown, and it did not fail" || { echo "FAIL company: user without USER"; fail=1; }
  run "decide: the last decision wins" 0 "brief ready
lib waiting
gate waiting
spend: input 0 output 0 cache_write 0 cache_read 0
open gates: none" "$F" company status "$dw"
  [ -e "$dw/lock" ] && echo "ok   company: decide used the lock file" || { echo "FAIL company: no lock file"; fail=1; }
  printf '{"v":1,"seq":4,"ki' >> "$DJ"
  run "decide: a torn tail is cut before the decision is appended" 0 "gate product-brief: rejected" env USER=ana "$F" company decide "$dw" product-brief rejected "after a crash"
  [ "$(wc -l < "$DJ")" -eq 4 ] && [ "$(tail -c 1 "$DJ" | od -An -c | tr -d ' ')" = '\n' ] && echo "ok   company: four whole lines, none torn" || { echo "FAIL company: torn tail handling"; fail=1; }
  run "decide: and status then reads it clean" 0 "brief rejected
lib waiting
gate waiting
spend: input 0 output 0 cache_write 0 cache_read 0
open gates: none" "$F" company status "$dw"
  printf 'garbage\n' >> "$DJ"
  before_dec=$(cksum < "$DJ")
  run "decide: a corrupt journal is refused as status refuses it, exit 1" 1 "refusal: journal-corrupt
line: 5" env USER=ana "$F" company decide "$dw" product-brief approved nope
  [ "$(cksum < "$DJ")" = "$before_dec" ] && echo "ok   company: a refused decision changed no byte" || { echo "FAIL company: the corrupt journal changed"; fail=1; }
  sed -i '$d' "$DJ"
  if command -v flock > /dev/null 2>&1; then
    flock -x "$dw/lock" sleep 3 &
    sleep 1
    run "decide: while another writer holds the lock it is workspace-locked, exit 1" 1 "refusal: workspace-locked" env USER=ana "$F" company decide "$dw" product-brief approved busy
    wait
    [ "$(wc -l < "$DJ")" -eq 4 ] && echo "ok   company: and it wrote nothing" || { echo "FAIL company: wrote under a held lock"; fail=1; }
    run "decide: the lock is free again after the holder ended" 0 "gate product-brief: approved" env USER=ana "$F" company decide "$dw" product-brief approved "free again"
  else
    echo "skip company: flock is not installed, the held-lock case was not run"
  fi
else
  echo "FAIL company: forge did not build"
  fail=1
fi
exit "$fail"
