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
for prog in journal_files snapshot_files evidence_files; do
  echo "-- $prog"
  $C check tests/conformance/$prog.cho tests/conformance/support.cho $libs --std || fail=1
  mkdir "$scratch/$prog" || exit 1
  if [ "$prog" = evidence_files ]; then
    # What the language cannot make (spike S10): links to files and a directory outside the execution
    # directory, a directory, and two sparse files, at the 64 MiB cap and one byte past it.
    mkdir "$scratch/$prog/sub" "$scratch/outside" || exit 1
    echo secret > "$scratch/outside/s.txt"
    ln -s "$scratch/outside/s.txt" "$scratch/$prog/link" || exit 1
    ln -s "$scratch/outside" "$scratch/$prog/dirlink" || exit 1
    truncate -s 67108865 "$scratch/$prog/big.bin" || exit 1
    truncate -s 67108864 "$scratch/$prog/cap.bin" || exit 1
  fi
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

echo "== conformance (kill at every crash point)"
# crash_points starts crash_writer as a child and kills it at each step of
# append, sync, snapshot and rename. `narrow` takes only a literal (cancho
# #534, gap G1), so the child is built into the literal directory the parent
# is narrowed to. Both are checked, built and run here.
crash_bin=/tmp/forge-crash-bin
mkdir -p "$crash_bin" || exit 1
for prog in crash_writer crash_points; do
  $C check tests/conformance/$prog.cho tests/conformance/support.cho $libs --std || fail=1
done
mkdir "$scratch/crash_points" || exit 1
if $C build tests/conformance/crash_writer.cho tests/conformance/support.cho $libs --std -o "$crash_bin/crash_writer" \
  && $C build tests/conformance/crash_points.cho tests/conformance/support.cho $libs --std -o "$scratch/crash_points.bin"; then
  "$scratch/crash_points.bin" "$scratch/crash_points" > "$scratch/crash_points.out" || fail=1
  cat "$scratch/crash_points.out"
  if grep -q '^FAIL ' "$scratch/crash_points.out"; then fail=1; fi
else
  echo "conformance: crash_points did not build"
  fail=1
fi

echo "== forge CLI (status, history) against a workspace the crash writer made"
# The workspace is the finished session of crash_writer (4 records, a snapshot
# at 4). `cp` only names its files the way the CLI expects; the oracle is
# `cmp` against the text below and the exit codes.
if $C build src/*.cho --std -o "$scratch/forge"; then
  ws="$scratch/ws"; mkdir "$ws" || exit 1
  "$crash_bin/crash_writer" "$scratch/session" 999 > /dev/null || fail=1
  cp "$scratch/session.journal.jsonl" "$ws/journal.jsonl"
  cp "$scratch/session.snapshot.json" "$ws/snapshot.json"
  cat > "$scratch/want_status" <<'EOT'
records: 4
bytes: 272
torn tail bytes: 0
tasks: 2
  approved: 2
snapshot: used, covers 4 records
EOT
  cat > "$scratch/want_history" <<'EOT'
#1 kind=task.proposed task=t-1 actor=human
#2 kind=task.proposed task=t-2 actor=human
#3 kind=task.approved task=t-1 actor=human
#4 kind=task.approved task=t-2 actor=human
EOT
  cat > "$scratch/want_t2" <<'EOT'
#2 kind=task.proposed task=t-2 actor=human
#4 kind=task.approved task=t-2 actor=human
EOT
  cli_ok() { # name, want file, exit code wanted, command...
    name=$1; want=$2; code=$3; shift 3
    "$@" > "$scratch/got" 2> "$scratch/got_err"; rc=$?
    if [ "$rc" -eq "$code" ] && { [ -z "$want" ] || cmp -s "$scratch/got" "$want"; }; then
      echo "ok   cli: $name"
    else
      echo "FAIL cli: $name (exit $rc, wanted $code)"; fail=1
    fi
  }
  cli_ok "status" "$scratch/want_status" 0 "$scratch/forge" status "$ws"
  cli_ok "history" "$scratch/want_history" 0 "$scratch/forge" history "$ws"
  cli_ok "history of one task" "$scratch/want_t2" 0 "$scratch/forge" history "$ws" t-2
  cli_ok "no verb is usage, exit 2" "" 2 "$scratch/forge"
  cli_ok "unknown verb is usage, exit 2" "" 2 "$scratch/forge" frobnicate "$ws"
  cli_ok "a relative directory is path-invalid, exit 2" "" 2 "$scratch/forge" status ws
  cli_ok "a .. directory is path-invalid, exit 2" "" 2 "$scratch/forge" status "$ws/../ws"
  cli_ok "no journal there, exit 3" "" 3 "$scratch/forge" status "$scratch/nowhere"
  printf 'garbage\n{"v":1,"seq":6,"ki' >> "$ws/journal.jsonl"
  before=$(cksum < "$ws/journal.jsonl")
  cli_ok "a corrupt journal is refused, exit 1" "" 1 "$scratch/forge" status "$ws"
  grep -q 'journal: refused (journal-corrupt) at line 5' "$scratch/got" && echo "ok   cli: and it names the rule and the line" || { echo "FAIL cli: no rule line"; fail=1; }
  [ "$(cksum < "$ws/journal.jsonl")" = "$before" ] && echo "ok   cli: looking changed no byte of the journal" || { echo "FAIL cli: the journal changed"; fail=1; }
  cli_ok "history of a corrupt journal shows the valid records, exit 1" "" 1 "$scratch/forge" history "$ws"
  [ "$(grep -c '^#' "$scratch/got")" -eq 4 ] && echo "ok   cli: four valid records shown before the refusal" || { echo "FAIL cli: wrong history before the refusal"; fail=1; }
else
  echo "forge: did not build"
  fail=1
fi

echo "== authority report (docs/authority.txt is the review artefact)"
# `cancho authority` for the forge binary, up to the list of provably pure
# functions. A change that widens it must change docs/authority.txt, and the
# commit message says so (CLAUDE.md).
$C authority src/*.cho --std | sed -n '/^performs/,/^provably/p' | sed '$d' > "$scratch/authority.txt"
if cmp -s "$scratch/authority.txt" docs/authority.txt; then
  echo "ok   authority: the forge binary's report is the checked-in one"
else
  echo "FAIL authority: differs from docs/authority.txt"; diff docs/authority.txt "$scratch/authority.txt"; fail=1
fi

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
