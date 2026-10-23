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
  bad() { echo "FAIL forge build: $1"; fail=1; [ "${FORGE_FAILFAST:-}" = 1 ] && exit 1; }
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
  check "done: the journal replays to one task in verification, eight records (the worker took the job: execution.accepted)" sh -c "'$br/forge' status '$br/done' > '$br/done.status' && grep -q '^records: 8\$' '$br/done.status' && grep -q '^  verification: 1\$' '$br/done.status'"
  check "done: the verdict is in the journal, claimed, written by the worker" grep -q '"kind":"execution.finished".*"actor":"worker","basis":"claimed","verdict":"done"' "$br/done/journal.jsonl"
  check "done: the intent was written before the outcome" sh -c "[ \$(grep -n 'execution.started' '$br/done/journal.jsonl' | cut -d: -f1) -lt \$(grep -n 'execution.finished' '$br/done/journal.jsonl' | cut -d: -f1) ]"
  check "done: the operator proposed and approved, Forge made it ready and running" sh -c "grep -q '\"kind\":\"task.proposed\".*\"actor\":\"human\"' '$br/done/journal.jsonl' && grep -q '\"kind\":\"task.approved\".*\"actor\":\"human\"' '$br/done/journal.jsonl' && grep -q '\"kind\":\"task.ready\".*\"actor\":\"forge\"' '$br/done/journal.jsonl' && grep -q '\"kind\":\"task.running\".*\"actor\":\"forge\"' '$br/done/journal.jsonl'"
  check "done: no record accepts the task" sh -c "! grep -q 'task.accepted' '$br/done/journal.jsonl'"
  check "done: history shows the whole life of the task, in order" sh -c "'$br/forge' history '$br/done' | cut -d' ' -f2 | tr '\\n' ' ' | grep -q '^kind=task.proposed kind=task.approved kind=task.ready kind=task.running kind=execution.started kind=execution.accepted kind=execution.finished kind=task.verification \$'"
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

  # ---- two workspaces, one execution directory (issue #35): Forge's lock is the workspace's, the adapter's is the directory's.
  # The stand-in's `slow` mode keeps the first build running until a file `release` is there.
  mkdir "$br/lk1" "$br/lk2" "$br/lkev" || exit 1
  printf 'slow\nfirst' > "$br/lk1.brief"; printf 'slow\nsecond' > "$br/lk2.brief"
  "$br/forge" build "$br/lk1" "$br/workers" "$br/tools" "$br/lk1.brief" "$br/lkev" /opt/cancho/bin/cancho stand m1 a 60000 > "$br/lk1.out" 2> "$br/lk1.err" &
  lkpid=$!
  n=0; while [ ! -s "$br/lkev/pids.txt" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  "$br/forge" build "$br/lk2" "$br/workers" "$br/tools" "$br/lk2.brief" "$br/lkev" /opt/cancho/bin/cancho stand m1 a 60000 > "$br/lk2.out" 2> "$br/lk2.err"; echo $? > "$br/lk2.rc"
  touch "$br/lkev/release"
  wait "$lkpid"; echo $? > "$br/lk1.rc"
  check "two workspaces, one execution directory: the second forge build ends blocked (exit 4), its adapter refused it, and it started no build" sh -c "[ '$(rc lk2)' = 4 ] && grep -q '^state: blocked\$' '$br/lk2.out' && [ \$(wc -l < '$br/lkev/pids.txt') -eq 1 ]"
  check "two workspaces, one execution directory: the first build is undisturbed, ends in verification with its own claim, and brief.txt is its brief" sh -c "[ '$(rc lk1)' = 0 ] && grep -q '^state: verification\$' '$br/lk1.out' && [ \"\$(sed -n 2p '$br/lkev/brief.txt')\" = first ] && [ \"\$(cat '$br/lkev/project.cho')\" = 'product of first' ]"
  check "two workspaces, one execution directory: the refused one wrote no claim, and its task is not accepted" sh -c "! grep -q 'execution.finished\|task.accepted' '$br/lk2/journal.jsonl'"
  check "two forge build on ONE workspace: the second is refused workspace-locked at the workspace, exit 3" sh -c "mkdir '$br/lk3' '$br/lk3ev'; printf 'slow\nfirst' > '$br/lk3.brief'; '$br/forge' build '$br/lk3' '$br/workers' '$br/tools' '$br/lk3.brief' '$br/lk3ev' /opt/cancho/bin/cancho stand m1 a 60000 > /dev/null 2>&1 & p=\$!; n=0; while [ ! -s '$br/lk3ev/pids.txt' ] && [ \$n -lt 100 ]; do sleep 0.1; n=\$((n + 1)); done; '$br/forge' build '$br/lk3' '$br/workers' '$br/tools' '$br/lk3.brief' '$br/lk3ev' /opt/cancho/bin/cancho stand m1 a 60000 > '$br/lk3.out2' 2> '$br/lk3.err2'; rc=\$?; touch '$br/lk3ev/release'; wait \$p; [ \$rc -eq 3 ] && grep -q 'workspace-locked' '$br/lk3.err2' '$br/lk3.out2'"

  # ---- the async level (issue #33; docs/async-level.md): the adapter answers accepted and Forge asks. The stand-in's `holdgrand`
  # mode keeps the build (and a grandchild, `sleep 78`) running until a file `release` is in the execution directory.
  waitfor() { # path, tenths of a second at most
    n=0; while [ ! -s "$1" ] && [ "$n" -lt "$2" ]; do sleep 0.1; n=$((n + 1)); done
  }
  fb_bg() { # ws, brief text, timeout: forge build in the background on $br/$ws, output in $br/$ws.out, pid in $br/$ws.pid
    mkdir "$br/$1" "$br/$1/ev" || exit 1
    printf '%s' "$2" > "$br/$1.brief"
    "$br/forge" build "$br/$1" "$br/workers" "$br/tools" "$br/$1.brief" "$br/$1/ev" /opt/cancho/bin/cancho stand m1 a "$3" > "$br/$1.out" 2> "$br/$1.err" &
    echo $! > "$br/$1.pid"
  }
  jsum() { cksum < "$br/$1/journal.jsonl"; }
  # -- cancel while forge build holds the workspace lock: the group is gone, the directory kept, the same work resumes
  fb_bg cx 'holdgrand
first' 60000
  waitfor "$br/cx/ev/pids.txt" 100; sleep 0.3
  check "async: the build is running and the journal says the worker took the job (execution.accepted with the request and the directory)" sh -c "grep -q '\"kind\":\"execution.accepted\".*\"request\":\"r-build-1\".*\"dir\":\"$br/cx/ev\"' '$br/cx/journal.jsonl' && ! grep -q 'execution.finished' '$br/cx/journal.jsonl'"
  "$br/forge" cancel "$br/cx" "$br/workers" build-1 > "$br/cx.cancel" 2> "$br/cx.cancel.err"; echo $? > "$br/cx.cancel.rc"
  wait "$(cat "$br/cx.pid")"; echo $? > "$br/cx.rc"
  check "async: forge cancel is answered while the build holds the workspace lock (it reads the journal and writes nothing): the worker stopped the run" sh -c "[ '$(rc cx.cancel)' = 0 ] && grep -q '^cancel: cancelled\$' '$br/cx.cancel'"
  check "async: the polling forge build sees it end cancelled: exit 4, state cancelled, execution.cancelled in the journal, no claim" sh -c "[ '$(rc cx)' = 4 ] && grep -q '^state: cancelled\$' '$br/cx.out' && grep -q '^ending: cancelled\$' '$br/cx.out' && grep -q '\"kind\":\"execution.cancelled\"' '$br/cx/journal.jsonl' && grep -q '\"kind\":\"task.cancelled\"' '$br/cx/journal.jsonl' && ! grep -q 'claimed verdict' '$br/cx.out'"
  check "async: the build's whole group is gone, the execution directory is kept, and the lock is let go" sh -c ". scripts/procs.sh; ! leftover -f '^sleep 78\$' > /dev/null && ! leftover -f '[c]ancho-build' > /dev/null && ! leftover -x cancho_code > /dev/null && [ -s '$br/cx/ev/brief.txt' ] && [ -s '$br/cx/ev/build.json' ]"
  printf 'done' > "$br/cx2.brief"
  "$br/forge" build "$br/cx" "$br/workers" "$br/tools" "$br/cx2.brief" "$br/cx/ev" /opt/cancho/bin/cancho stand m1 a 30000 > "$br/cx2.out" 2> "$br/cx2.err"; echo $? > "$br/cx2.rc"
  check "async: the same directory resumes with a new task (build-2): it ends done, in verification" sh -c "[ '$(rc cx2)' = 0 ] && grep -q '^task: build-2\$' '$br/cx2.out' && grep -q '^state: verification\$' '$br/cx2.out'"
  "$br/forge" cancel "$br/cx" "$br/workers" build-1 > /dev/null 2> "$br/cx3.err"; echo $? > "$br/cx3.rc"
  check "async: forge cancel about a task that has ended is refused task-not-awaiting (exit 1), and so is forge await" sh -c "[ '$(rc cx3)' = 1 ] && grep -q 'task-not-awaiting' '$br/cx3.err' && '$br/forge' await '$br/cx' '$br/workers' build-2 > /dev/null 2> '$br/cx4.err'; [ \$? -eq 1 ] && grep -q 'task-not-awaiting' '$br/cx4.err'"

  # -- a Forge killed in the middle of a running build: recover leaves the task running, await settles it
  fb_bg rs 'holdgrand
second' 60000
  waitfor "$br/rs/ev/pids.txt" 100; sleep 0.3
  kill -9 "$(cat "$br/rs.pid")"; wait "$(cat "$br/rs.pid")" 2> /dev/null; sleep 0.3
  check "restart: the build outlived the Forge that started it, and the journal says running with the worker's run accepted" sh -c ". scripts/procs.sh; leftover -f '[c]ancho-build' > /dev/null && leftover -x cancho_code > /dev/null && '$br/forge' status '$br/rs' | grep -q '^  running: 1\$'"
  before=$(jsum rs)
  "$br/forge" recover "$br/rs" > "$br/rs.rec1" 2> "$br/rs.rec1.err"; echo $? > "$br/rs.rec1.rc"
  check "restart: forge recover with no workers directory writes nothing for it: not lost, still running, reported awaiting" sh -c "[ '$(rc rs.rec1)' = 0 ] && grep -q '^awaiting: 1\$' '$br/rs.rec1' && [ \"\$(cksum < '$br/rs/journal.jsonl')\" = \"$before\" ]"
  "$br/forge" recover "$br/rs" "$br/workers" > "$br/rs.rec2" 2> "$br/rs.rec2.err"; echo $? > "$br/rs.rec2.rc"
  check "restart: forge recover with the workers directory asks the worker: it is running, so the task stays running and nothing is written" sh -c "[ '$(rc rs.rec2)' = 0 ] && grep -q '^state: running\$' '$br/rs.rec2' && [ \"\$(cksum < '$br/rs/journal.jsonl')\" = \"$before\" ] && ! grep -q 'execution.lost' '$br/rs/journal.jsonl'"
  touch "$br/rs/ev/release"; sleep 1.5
  "$br/forge" recover "$br/rs" "$br/workers" > "$br/rs.rec3" 2> "$br/rs.rec3.err"; echo $? > "$br/rs.rec3.rc"
  check "restart: after the build ended while Forge was down, forge recover reads the result and moves the task to verification with the claim" sh -c "[ '$(rc rs.rec3)' = 0 ] && grep -q '^state: verification\$' '$br/rs.rec3' && grep -q '^claimed verdict: done\$' '$br/rs.rec3' && grep -q '\"kind\":\"execution.finished\".*\"verdict\":\"done\"' '$br/rs/journal.jsonl' && '$br/forge' status '$br/rs' | grep -q '^  verification: 1\$'"
  "$br/forge" recover "$br/rs" "$br/workers" > "$br/rs.rec4" 2>&1
  check "restart: recovering again finds nothing to do" sh -c "! grep -q 'awaiting' '$br/rs.rec4' && grep -q '^recovered: 0\$' '$br/rs.rec4'"
  # -- the same with forge await, a build still running when Forge comes back
  fb_bg aw 'holdgrand
third' 60000
  waitfor "$br/aw/ev/pids.txt" 100; sleep 0.3
  kill -9 "$(cat "$br/aw.pid")"; wait "$(cat "$br/aw.pid")" 2> /dev/null
  ( sleep 2; touch "$br/aw/ev/release" ) &
  "$br/forge" await "$br/aw" "$br/workers" build-1 30000 > "$br/aw.out" 2> "$br/aw.err"; echo $? > "$br/aw.rc"
  check "restart: forge await waits for the build that was still running, and settles the task: verification, the claim, exit 0" sh -c "[ '$(rc aw)' = 0 ] && grep -q '^state: verification\$' '$br/aw.out' && grep -q '^claimed verdict: done\$' '$br/aw.out'"
  # -- Forge's own deadline: the build is still running at it, so Forge asks the worker to stop it (the group is gone, the directory kept)
  fb_bg dl 'holdgrand
fourth' 60000
  waitfor "$br/dl/ev/pids.txt" 100; sleep 0.3
  kill -9 "$(cat "$br/dl.pid")"; wait "$(cat "$br/dl.pid")" 2> /dev/null
  "$br/forge" await "$br/dl" "$br/workers" build-1 1000 > "$br/dl.out" 2> "$br/dl.err"; echo $? > "$br/dl.rc"
  check "deadline: forge await with a budget the build outruns cancels it: exit 4, worker-timeout (a deadline sends the task back to ready, as for any worker), no claim" sh -c "[ '$(rc dl)' = 4 ] && grep -q '^state: ready\$' '$br/dl.out' && grep -q '^refusal: worker-timeout\$' '$br/dl.out' && grep -q '^ending: retry-or-fail\$' '$br/dl.out' && grep -q '\"rule\":\"worker-timeout\"' '$br/dl/journal.jsonl' && ! grep -q 'claimed verdict' '$br/dl.out'"
  check "deadline: the build's group is gone and the directory is kept" sh -c "sleep 0.3; . scripts/procs.sh; ! leftover -f '^sleep 78\$' > /dev/null && ! leftover -f '[c]ancho-build' > /dev/null && [ -s '$br/dl/ev/build.json' ]"
  # -- a worker that does not know the run it accepted: status unknown is a lost run, never retried, an operator decides
  fb_bg lo 'holdgrand
fifth' 60000
  waitfor "$br/lo/ev/pids.txt" 100; sleep 0.3
  kill -9 "$(cat "$br/lo.pid")"; wait "$(cat "$br/lo.pid")" 2> /dev/null
  rm -f "$br/lo/ev/run.json"
  "$br/forge" await "$br/lo" "$br/workers" build-1 5000 > "$br/lo.out" 2> "$br/lo.err"; echo $? > "$br/lo.rc"
  check "lost: a status of unknown for an accepted run is execution-lost: exit 4, blocked, the tag in the journal, no claim" sh -c "[ '$(rc lo)' = 4 ] && grep -q '^state: blocked\$' '$br/lo.out' && grep -q '^refusal: execution-lost\$' '$br/lo.out' && grep -q '\"rule\":\"execution-lost\"' '$br/lo/journal.jsonl' && ! grep -q 'claimed verdict' '$br/lo.out'"
  touch "$br/lo/ev/release"; sleep 1; pkill -f '^sleep 78$'
  # -- cancelled while no Forge was polling: forge await writes the cancellation
  fb_bg cw 'holdgrand
sixth' 60000
  waitfor "$br/cw/ev/pids.txt" 100; sleep 0.3
  kill -9 "$(cat "$br/cw.pid")"; wait "$(cat "$br/cw.pid")" 2> /dev/null
  "$br/forge" cancel "$br/cw" "$br/workers" build-1 > "$br/cw.cancel" 2> /dev/null; echo $? > "$br/cw.cancel.rc"
  "$br/forge" await "$br/cw" "$br/workers" build-1 10000 > "$br/cw.out" 2> "$br/cw.err"; echo $? > "$br/cw.rc"
  check "cancel with no Forge polling: the worker stops the run; forge await then writes execution.cancelled and the move to cancelled (exit 4, no claim)" sh -c "[ '$(rc cw.cancel)' = 0 ] && [ '$(rc cw)' = 4 ] && grep -q '^state: cancelled\$' '$br/cw.out' && grep -q '\"kind\":\"execution.cancelled\"' '$br/cw/journal.jsonl' && grep -q '\"kind\":\"task.cancelled\"' '$br/cw/journal.jsonl' && ! grep -q 'claimed verdict' '$br/cw.out'"
  # -- a task that is not awaiting
  "$br/forge" await "$br/dl" "$br/workers" build-9 > /dev/null 2> "$br/na.err"; echo $? > "$br/na.rc"
  check "await: a task that does not exist is refused task-not-awaiting, exit 1, nothing written" sh -c "[ '$(rc na)' = 1 ] && grep -q 'task-not-awaiting' '$br/na.err'"
  "$br/forge" await "$br/dl" relative build-1 > /dev/null 2>&1; r1=$?; "$br/forge" await "$br/dl" "$br/workers" > /dev/null 2>&1; r2=$?; "$br/forge" await "$br/dl" "$br/workers" build-1 999 > /dev/null 2>&1; r4=$?; "$br/forge" cancel "$br/nowhere-ws" "$br/workers" build-1 > /dev/null 2>&1; r3=$?
  check "await, cancel: a path that is not absolute, a missing argument, a budget under a second: exit 2; no journal there: exit 3" sh -c "[ $r1 -eq 2 ] && [ $r2 -eq 2 ] && [ $r4 -eq 2 ] && [ $r3 -eq 3 ]"

  check "no adapter and no build outlived the run" sh -c ". scripts/procs.sh; ! leftover -x cancho_code > /dev/null && ! leftover -f '[c]ancho-build' > /dev/null"
else
  echo "forge build: did not build"
  fail=1
fi
exit $fail
