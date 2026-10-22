#!/bin/sh
# `forge build`, end to end (issue #34; docs/cancho-code-adapter.md section 10): the command takes the lock of a workspace,
# reads the brief file, records the task, starts the Cancho Code adapter (a real child process, found beneath the workers
# directory) which starts a STAND-IN `cancho-build` (scripts/standin_cancho_build.sh, found beneath the tools directory),
# recomputes the evidence, and journals what happened. The oracle is outside the programs: the exit status of the forge
# binary, its output, the journal read back by `forge status` and `forge history`, the files of the execution directory,
# `grep` on the journal and the process table. Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
# Used by scripts/gate.sh and by scripts/mutate_build_run.py (which runs it on a copy of the tree with one break).
# Usage: CANCHO=path/to/cancho scripts/check_build_run.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
br="$scratch/br"; mkdir "$br" "$br/workers" "$br/tools" || exit 1
cp scripts/standin_cancho_build.sh "$br/tools/cancho-build" && chmod +x "$br/tools/cancho-build" || exit 1
$C check src/*.cho --std || fail=1
$C check workers/cancho_code.cho $libs --std || fail=1
if $C build src/*.cho --std -o "$br/forge" && $C build workers/cancho_code.cho $libs --std -o "$br/workers/cancho_code"; then
  ok() { echo "ok   forge build: $1"; }
  bad() { echo "FAIL forge build: $1"; fail=1; }
  check() { # name, command...
    name=$1; shift
    if "$@"; then ok "$name"; else bad "$name"; fi
  }
  # a workspace: an empty directory for the journal and one for the build
  mkws() { mkdir "$br/$1" "$br/$1/ev" || exit 1; }
  brief() { printf '%s' "$2" > "$br/$1.brief"; } # name, text (no newline added)
  build() { # ws, brief file, extra args after the model/agent...; runs `forge build`, output in $br/$ws.out, status in $br/$ws.rc
    ws=$1; bf=$2; shift 2
    "$br/forge" build "$br/$ws" "$br/workers" "$br/tools" "$bf" "$br/$ws/ev" /opt/cancho/bin/cancho stand m1 "stand-in-agent --x" "$@" > "$br/$ws.out" 2> "$br/$ws.err"
    echo $? > "$br/$ws.rc"
  }
  rc() { cat "$br/$1.rc"; }

  # ---- a build that ends done: a claim, never an acceptance
  mkws done; printf 'done\nline with "quotes", a \\ backslash and a\ttab\n' > "$br/done.brief"; build done "$br/done.brief" 20000
  check "done: exit 0" test "$(rc done)" = 0
  check "done: the output names the task, the state and the claimed verdict" sh -c "grep -q '^task: build-1\$' '$br/done.out' && grep -q '^state: verification\$' '$br/done.out' && grep -q '^claimed verdict: done\$' '$br/done.out'"
  check "done: the journal replays to one task in verification, seven records" sh -c "'$br/forge' status '$br/done' > '$br/done.status' && grep -q '^records: 7\$' '$br/done.status' && grep -q '^  verification: 1\$' '$br/done.status'"
  check "done: the verdict is in the journal, claimed, written by the worker" grep -q '"kind":"execution.finished".*"actor":"worker","basis":"claimed","verdict":"done"' "$br/done/journal.jsonl"
  check "done: the intent was written before the outcome" sh -c "[ \$(grep -n 'execution.started' '$br/done/journal.jsonl' | cut -d: -f1) -lt \$(grep -n 'execution.finished' '$br/done/journal.jsonl' | cut -d: -f1) ]"
  check "done: the operator proposed and approved, Forge made it ready and running" sh -c "grep -q '\"kind\":\"task.proposed\".*\"actor\":\"human\"' '$br/done/journal.jsonl' && grep -q '\"kind\":\"task.approved\".*\"actor\":\"human\"' '$br/done/journal.jsonl' && grep -q '\"kind\":\"task.ready\".*\"actor\":\"forge\"' '$br/done/journal.jsonl' && grep -q '\"kind\":\"task.running\".*\"actor\":\"forge\"' '$br/done/journal.jsonl'"
  check "done: no record accepts the task" sh -c "! grep -q 'task.accepted' '$br/done/journal.jsonl'"
  check "done: history shows the whole life of the task, in order" sh -c "'$br/forge' history '$br/done' | cut -d' ' -f2 | tr '\\n' ' ' | grep -q '^kind=task.proposed kind=task.approved kind=task.ready kind=task.running kind=execution.started kind=execution.finished kind=task.verification \$'"
  check "done: the brief reached the tool as a file, byte for byte, with quotes, a backslash and a tab" cmp -s "$br/done.brief" "$br/done/ev/brief.txt"
  check "done: the evidence is in the execution directory" sh -c "grep -q '\"verdict\":\"done\"' '$br/done/ev/build.json' && [ -f '$br/done/ev/project.cho' ] && [ -f '$br/done/ev/build.out' ]"
  check "done: nothing of the operator's configuration is in the journal (checker, agent command, provider, model)" sh -c "! grep -q 'stand-in-agent\|/opt/cancho\|stand\|m1' '$br/done/journal.jsonl'"
  check "done: the lock is let go (a second run takes it and is task build-2)" sh -c "mkdir '$br/done/ev2' && '$br/forge' build '$br/done' '$br/workers' '$br/tools' '$br/done.brief' '$br/done/ev2' /opt/cancho/bin/cancho stand m1 'a' 20000 > '$br/done2.out'; [ \$? -eq 0 ] && grep -q '^task: build-2\$' '$br/done2.out'"

  # ---- no timeout argument: the default is an hour (3 600 000 ms), well inside what a build may be given
  mkws deft; brief deft done
  "$br/forge" build "$br/deft" "$br/workers" "$br/tools" "$br/deft.brief" "$br/deft/ev" /opt/cancho/bin/cancho stand m1 a > "$br/deft.out" 2> "$br/deft.err"; echo $? > "$br/deft.rc"
  check "no timeout argument: the default is accepted and the build runs (exit 0)" sh -c "[ '$(rc deft)' = 0 ] && grep -q '^state: verification\$' '$br/deft.out'"

  # ---- the operator's configuration reaches the tool, one argument each (the oracle is the stand-in's own record of its argv)
  mkws opts; brief opts args2; build opts "$br/opts.brief" 20000 guide=/opt/guides/plan.md attempts=7 agent_seconds=31 rounds=2 plan_seconds=901 jobs=5
  printf 'A:/opt/cancho/bin/cancho\nA:%s/opts/ev/brief.txt\nA:%s/opts/ev\nA:stand-in-agent --x\nA:--provider\nA:stand\nA:--model\nA:m1\nA:--guide\nA:/opt/guides/plan.md\nA:--attempts\nA:7\nA:--agent-seconds\nA:31\nA:--rounds\nA:2\nA:--plan-seconds\nA:901\nA:--jobs\nA:5\n' "$br" "$br" > "$br/want_opts"
  check "options: exit 0 and the tool got the operator's checker, agent (as ONE argument), provider, model, guide and ceilings in order" sh -c "[ '$(rc opts)' = 0 ] && cmp -s '$br/opts/ev/args.txt' '$br/want_opts'"
  mkws defaults; brief defaults args; build defaults "$br/defaults.brief" 20000
  check "defaults: without options the tool got the tool's own defaults" sh -c "grep -q '^A:--attempts\$' '$br/defaults/ev/args.txt' && [ \"\$(sed -n '/--attempts/{n;p}' '$br/defaults/ev/args.txt')\" = A:4 ] && [ \"\$(sed -n '/--jobs/{n;p}' '$br/defaults/ev/args.txt')\" = A:4 ] && ! grep -q 'guide' '$br/defaults/ev/args.txt'"

  # ---- how a build can fail to succeed: blocked, never retried by itself (a build writes)
  mkws stuck; brief stuck stuck; build stuck "$br/stuck.brief" 20000
  check "stuck: exit 4, state blocked, no claim, no execution.finished" sh -c "[ '$(rc stuck)' = 4 ] && grep -q '^state: blocked\$' '$br/stuck.out' && grep -q '^ending: worker-said\$' '$br/stuck.out' && ! grep -q 'execution.finished' '$br/stuck/journal.jsonl' && ! grep -q 'claimed verdict' '$br/stuck.out'"
  mkws provider; brief provider provider; build provider "$br/provider.brief" 20000
  check "provider-error: exit 4, blocked, the retry refused as a write (retry-write-refused), started ONCE" sh -c "[ '$(rc provider)' = 4 ] && grep -q '^state: blocked\$' '$br/provider.out' && grep -q '^refusal: retry-write-refused\$' '$br/provider.out' && [ \$(grep -c 'execution.started' '$br/provider/journal.jsonl') -eq 1 ] && grep -q '\"kind\":\"refusal\".*retry-write-refused' '$br/provider/journal.jsonl'"
  check "provider-error: the work is kept, and the command run again on the same directory is a new task over the same work (build-2, which resumes it)" sh -c "printf done > '$br/provider.again'; '$br/forge' build '$br/provider' '$br/workers' '$br/tools' '$br/provider.again' '$br/provider/ev' /opt/cancho/bin/cancho stand m1 a 20000 > '$br/provider2.out'; [ \$? -eq 0 ] && grep -q '^task: build-2\$' '$br/provider2.out' && grep -q '^state: verification\$' '$br/provider2.out'"
  mkws gate; brief gate gate; build gate "$br/gate.brief" 20000
  check "gate_failed: exit 4, blocked" sh -c "[ '$(rc gate)' = 4 ] && grep -q '^state: blocked\$' '$br/gate.out'"
  mkws plan; brief plan plan; build plan "$br/plan.brief" 20000
  check "plan_failed: exit 4, blocked" sh -c "[ '$(rc plan)' = 4 ] && grep -q '^state: blocked\$' '$br/plan.out'"
  mkws usage; brief usage usage; build usage "$br/usage.brief" 20000
  check "exit 2 of the tool: exit 4, blocked" sh -c "[ '$(rc usage)' = 4 ] && grep -q '^state: blocked\$' '$br/usage.out'"
  mkws disagree; brief disagree disagree; build disagree "$br/disagree.brief" 20000
  check "a tool that lies about its verdict is never a claim: exit 4, blocked, no execution.finished" sh -c "[ '$(rc disagree)' = 4 ] && grep -q '^state: blocked\$' '$br/disagree.out' && ! grep -q 'execution.finished' '$br/disagree/journal.jsonl'"
  mkws hang; brief hang hang; build hang "$br/hang.brief" 10000
  check "hang: the adapter's deadline fires, exit 4, blocked" sh -c "[ '$(rc hang)' = 4 ] && grep -q '^state: blocked\$' '$br/hang.out'"
  check "hang: nothing the build started is left running (its group was killed)" sh -c ". scripts/procs.sh; ! leftover -f '^sleep 79\$' > /dev/null && ! leftover -f '[c]ancho-build' > /dev/null"
  mkws noisy; brief noisy noisy; build noisy "$br/noisy.brief" 20000
  check "noisy: exit 4, blocked" sh -c "[ '$(rc noisy)' = 4 ] && grep -q '^state: blocked\$' '$br/noisy.out'"
  mkdir "$br/notool" "$br/notool/ev" "$br/emptytools" || exit 1
  "$br/forge" build "$br/notool" "$br/workers" "$br/emptytools" "$br/done.brief" "$br/notool/ev" /opt/cancho/bin/cancho stand m1 a 20000 > "$br/notool.out" 2> "$br/notool.err"; echo $? > "$br/notool.rc"
  check "a tools directory without the tool: exit 4, blocked" sh -c "[ '$(rc notool)' = 4 ] && grep -q '^state: blocked\$' '$br/notool.out'"

  # ---- refused before anything runs: the task stays approved, nothing is started, nothing is written in the execution directory
  mkws op; brief op done
  "$br/forge" build "$br/op" "$br/workers" "$br/tools" "$br/op.brief" "$br/op/ev" /opt/cancho/bin/cancho 'a;b' m1 a 20000 > "$br/op.out" 2> "$br/op.err"; echo $? > "$br/op.rc"
  check "a provider with a shell metacharacter: exit 1, refused operator-invalid, the task stays approved" sh -c "[ '$(rc op)' = 1 ] && grep -q '^refused: operator-invalid\$' '$br/op.out' && grep -q '^state: approved\$' '$br/op.out'"
  check "operator-invalid: the journal holds proposed, approved and the refusal, and nothing was started" sh -c "'$br/forge' status '$br/op' > '$br/op.status' && grep -q '^records: 3\$' '$br/op.status' && ! grep -q 'execution.started' '$br/op/journal.jsonl' && grep -q '\"kind\":\"refusal\".*operator-invalid' '$br/op/journal.jsonl' && [ -z \"\$(ls -A '$br/op/ev')\" ]"
  mkws jobs; brief jobs done; build jobs "$br/jobs.brief" 20000 jobs=65
  check "jobs above the tool's range: refused operator-invalid" sh -c "[ '$(rc jobs)' = 1 ] && grep -q '^refused: operator-invalid\$' '$br/jobs.out' && [ -z \"\$(ls -A '$br/jobs/ev')\" ]"
  mkws empty; : > "$br/empty.brief"; build empty "$br/empty.brief" 20000
  check "an empty brief file: refused input-invalid, nothing started" sh -c "[ '$(rc empty)' = 1 ] && grep -q '^refused: input-invalid\$' '$br/empty.out' && grep -q '^state: approved\$' '$br/empty.out' && [ -z \"\$(ls -A '$br/empty/ev')\" ]"
  mkws lim; brief lim done; build lim "$br/lim.brief" 9999
  check "a timeout under ten seconds: refused limits-invalid" sh -c "[ '$(rc lim)' = 1 ] && grep -q '^refused: limits-invalid\$' '$br/lim.out' && [ -z \"\$(ls -A '$br/lim/ev')\" ]"
  mkws nul; printf 'done\0x' > "$br/nul.brief"; build nul "$br/nul.brief" 20000
  check "a brief with a NUL: refused input-invalid" sh -c "[ '$(rc nul)' = 1 ] && grep -q '^refused: input-invalid\$' '$br/nul.out'"
  mkdir "$br/pth" || exit 1
  "$br/forge" build "$br/pth" "$br/workers" "$br/tools" "$br/done.brief" "$br/pth/ev;x" /opt/cancho/bin/cancho stand m1 a 20000 > "$br/pth.out" 2> "$br/pth.err"; echo $? > "$br/pth.rc"
  check "an execution directory with a shell metacharacter: refused path-invalid, nothing started" sh -c "[ '$(rc pth)' = 1 ] && grep -q '^refused: path-invalid\$' '$br/pth.out'"
  mkws two; brief two done
  "$br/forge" build "$br/two" "$br/workers" "$br/tools" "$br/two.brief" "$br/two/ev" relative-checker stand m1 a 20000 > "$br/two.out" 2> "$br/two.err"; echo $? > "$br/two.rc"
  check "a relative checker: refused operator-invalid" sh -c "[ '$(rc two)' = 1 ] && grep -q '^refused: operator-invalid\$' '$br/two.out'"

  # ---- the brief file is read before a task exists: nothing is journalled
  mkws nobrief
  build nobrief "$br/nowhere.brief" 20000
  check "a brief file that is not there: exit 1, brief-unreadable, no journal at all" sh -c "[ '$(rc nobrief)' = 1 ] && grep -q 'brief-unreadable' '$br/nobrief.err' && [ ! -e '$br/nobrief/journal.jsonl' ]"
  mkws bigbrief; head -c 16385 /dev/zero | tr '\0' d > "$br/bigbrief.brief"; build bigbrief "$br/bigbrief.brief" 20000
  check "a brief file of 16 KiB and one byte: exit 1, brief-unreadable, no journal" sh -c "[ '$(rc bigbrief)' = 1 ] && grep -q 'brief-unreadable' '$br/bigbrief.err' && [ ! -e '$br/bigbrief/journal.jsonl' ]"
  mkws exactbrief; head -c 16384 /dev/zero | tr '\0' d > "$br/exactbrief.brief"; build exactbrief "$br/exactbrief.brief" 20000
  check "a brief file of exactly 16 KiB is taken (the stand-in does not know the mode and the tool's verdict is not a claim)" sh -c "[ \$(wc -c < '$br/exactbrief/ev/brief.txt') -eq 16384 ] && grep -q '^task: build-1\$' '$br/exactbrief.out'"
  mkdir "$br/dirbrief" "$br/dirbrief/ev" "$br/dirbrief/b" || exit 1
  "$br/forge" build "$br/dirbrief" "$br/workers" "$br/tools" "$br/dirbrief/b" "$br/dirbrief/ev" /opt/cancho/bin/cancho stand m1 a 20000 > "$br/dirbrief.out" 2> "$br/dirbrief.err"; echo $? > "$br/dirbrief.rc"
  check "a brief 'file' that is a directory: exit 1, brief-unreadable" sh -c "[ '$(rc dirbrief)' = 1 ] && grep -q 'brief-unreadable' '$br/dirbrief.err'"

  # ---- bad usage: exit 2, nothing journalled
  mkws use
  check "too few arguments: exit 2" sh -c "'$br/forge' build '$br/use' '$br/workers' > /dev/null 2>&1; [ \$? -eq 2 ]"
  build use "$br/done.brief" 20000 bogus=1; check "an option that is not on the list: exit 2" test "$(rc use)" = 2
  build use "$br/done.brief" 20000 jobs=1 jobs=2; check "an option twice: exit 2" test "$(rc use)" = 2
  build use "$br/done.brief" 20000 jobs=many; check "an option that is not a number: exit 2" test "$(rc use)" = 2
  build use "$br/done.brief" notanumber; check "a timeout that is not a number: exit 2" test "$(rc use)" = 2
  check "a path that is not absolute: exit 2" sh -c "'$br/forge' build '$br/use' relative-workers '$br/tools' '$br/done.brief' '$br/use/ev' /opt/cancho/bin/cancho stand m1 a > /dev/null 2>&1; [ \$? -eq 2 ]"
  check "a brief file path that is not absolute: exit 2" sh -c "'$br/forge' build '$br/use' '$br/workers' '$br/tools' relative.brief '$br/use/ev' /opt/cancho/bin/cancho stand m1 a > /dev/null 2>&1; [ \$? -eq 2 ]"
  check "bad usage journalled nothing" sh -c "[ ! -e '$br/use/journal.jsonl' ]"

  # ---- the workers directory is not there: exit 3, after the task was journalled? no: nothing started
  mkws nowd
  check "a workers directory that is not there: exit 3" sh -c "'$br/forge' build '$br/nowd' '$br/nowhere-workers' '$br/tools' '$br/done.brief' '$br/nowd/ev' /opt/cancho/bin/cancho stand m1 a 20000 > /dev/null 2>&1; [ \$? -eq 3 ]"

  check "no adapter and no build outlived the run" sh -c ". scripts/procs.sh; ! leftover -x cancho_code > /dev/null && ! leftover -f '[c]ancho-build' > /dev/null"
else
  echo "forge build: did not build"
  fail=1
fi
exit $fail
