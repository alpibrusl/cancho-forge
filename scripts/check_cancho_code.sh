#!/bin/sh
# The Cancho Code adapter against a real child process and a stand-in build tool (docs/cancho-code-adapter.md, worker-contract
# section 9). workers/cancho_code.cho is built into a workers directory; a stand-in `cancho-build` (a shell script) is written into
# a tools directory, and does one thing for each first line of the brief it is given: finish, get stuck, fail the gate or the
# plan, hit a provider error, refuse its arguments, lie about its verdict, write junk, hang with a grandchild, write too much,
# be killed. tests/conformance/cancho_code.cho starts the adapter beneath the workers directory once per way a build can end
# and once per refusal; the oracle for what the adapter wrote and left behind is outside the programs (cmp, grep, pgrep on the
# files and the process table). Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
# Used by scripts/gate.sh and by scripts/mutate_cancho_code.py (which runs it on a copy of the tree with one break, and sets
# FORGE_FAILFAST=1: the script then stops at the first FAIL, which is all a deliberate break needs).
# Usage: CANCHO=path/to/cancho scripts/check_cancho_code.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
cc="$scratch/cc"; mkdir "$cc" "$cc/workers" || exit 1
tools="$cc/tools"; mkdir "$tools" "$cc/tools_empty" || exit 1
for e in done stuck stuck0 gate plan provider usage disagree disagree0 badjson nojson unknown link hang noisy sig args env args2 ctr ctr2 notool big forge; do mkdir "$cc/ev_$e" || exit 1; done
mkdir "$cc/ev_refuse" || exit 1
# a brief.txt that is a directory: the brief cannot be written, while build.out could be
mkdir "$cc/ev_briefdir" "$cc/ev_briefdir/brief.txt" || exit 1

# The stand-in for `cancho-build`: a fixture shared with scripts/check_build_run.sh (scripts/standin_cancho_build.sh).
cp scripts/standin_cancho_build.sh "$tools/cancho-build" && chmod +x "$tools/cancho-build" || exit 1

# The adapter's authority report is its review artefact (docs/authority-cancho-code.txt); a change that widens it changes that
# file in the same commit and says so in the message.
$C authority workers/cancho_code.cho $libs --std | sed -n '/^performs/,/^provably/p' | sed '$d' > "$cc/authority.txt"
if cmp -s "$cc/authority.txt" docs/authority-cancho-code.txt; then
  echo "ok   cancho code adapter authority: the report is the checked-in one"
else
  echo "FAIL cancho code adapter authority: differs from docs/authority-cancho-code.txt"; diff docs/authority-cancho-code.txt "$cc/authority.txt"; fail=1
fi
$C check workers/cancho_code.cho $libs --std || fail=1
$C check tests/conformance/cancho_code.cho tests/conformance/support.cho $libs --std || fail=1
if $C build workers/cancho_code.cho $libs --std -o "$cc/workers/cancho_code" \
  && $C build tests/conformance/cancho_code.cho tests/conformance/support.cho $libs --std -o "$cc/cancho_code_conf"; then
  "$cc/cancho_code_conf" "$cc/workers" "$cc" > "$cc/out" || fail=1
  cat "$cc/out"
  if grep -q '^FAIL ' "$cc/out"; then fail=1; [ "${FORGE_FAILFAST:-}" = 1 ] && exit 1; fi
  oracle() { # name, command...
    name=$1; shift
    if "$@"; then echo "ok   cancho code oracle: $name"; else echo "FAIL cancho code oracle: $name"; fail=1; [ "${FORGE_FAILFAST:-}" = 1 ] && exit 1; fi
  }
  # --- the brief is a file, byte for byte what the task said
  printf 'done' > "$cc/want_brief_done"
  oracle "done: brief.txt is the brief, byte for byte" cmp -s "$cc/ev_done/brief.txt" "$cc/want_brief_done"
  printf 'args\nsecond line with "quotes"; $(x) `y` & | > <\n' > "$cc/want_brief_args"
  oracle "args: a brief with quotes, newlines and shell metacharacters reaches the file unchanged" cmp -s "$cc/ev_args/brief.txt" "$cc/want_brief_args"
  # --- the build's stdout is evidence build.out, as the tool wrote it
  printf '[BUILD_VERDICT]\tdone\n' > "$cc/want_out_done"
  oracle "done: build.out is the tool's standard output" cmp -s "$cc/ev_done/build.out" "$cc/want_out_done"
  oracle "done: build.json, run.log and project.cho are the tool's own files" sh -c "grep -q '\"verdict\":\"done\"' '$cc/ev_done/build.json' && [ -f '$cc/ev_done/run.log' ] && [ -f '$cc/ev_done/project.cho' ]"
  # --- the argument vector: the operator's, one argument each, and the brief nowhere in it
  printf 'A:/opt/cancho/bin/cancho\nA:%s/ev_args/brief.txt\nA:%s/ev_args\nA:stand-in-agent --x\nA:--provider\nA:stand\nA:--model\nA:m1\nA:--attempts\nA:4\nA:--agent-seconds\nA:30\nA:--rounds\nA:3\nA:--plan-seconds\nA:900\nA:--jobs\nA:4\n' "$cc" "$cc" > "$cc/want_args"
  oracle "args: the tool got exactly the checker, the brief path, the work directory, the agent as ONE argument, and the default ceilings" cmp -s "$cc/ev_args/args.txt" "$cc/want_args"
  oracle "args: nothing of the brief is in the argument vector" sh -c "! grep -q 'quotes' '$cc/ev_args/args.txt'"
  printf 'A:/opt/cancho/bin/cancho\nA:%s/ev_args2/brief.txt\nA:%s/ev_args2\nA:stand-in-agent --x\nA:--provider\nA:stand\nA:--model\nA:m1\nA:--guide\nA:/opt/guides/plan.md\nA:--attempts\nA:7\nA:--agent-seconds\nA:31\nA:--rounds\nA:2\nA:--plan-seconds\nA:901\nA:--jobs\nA:5\n' "$cc" "$cc" > "$cc/want_args2"
  oracle "args2: the guide and the operator's ceilings are in the vector, in order" cmp -s "$cc/ev_args2/args.txt" "$cc/want_args2"
  # --- the contract: --contract and its absolute path in the vector, after the model and before the ceilings; nowhere when the task has none
  for e in ctr ctr2; do
    printf 'A:/opt/cancho/bin/cancho\nA:%s/ev_%s/brief.txt\nA:%s/ev_%s\nA:stand-in-agent --x\nA:--provider\nA:stand\nA:--model\nA:m1\nA:--contract\nA:%s/ev_%s/contract.txt\nA:--attempts\nA:4\nA:--agent-seconds\nA:30\nA:--rounds\nA:3\nA:--plan-seconds\nA:900\nA:--jobs\nA:4\n' "$cc" "$e" "$cc" "$e" "$cc" "$e" > "$cc/want_$e"
    oracle "contract: $e: the vector holds --contract and the absolute path beneath the execution directory" cmp -s "$cc/ev_$e/args.txt" "$cc/want_$e"
  done
  oracle "contract: a task without one has no --contract in its vector" sh -c "! grep -q -e '--contract' '$cc/ev_args/args.txt'"
  # --- the environment: empty (what `env -i /bin/sh -c env` shows is the baseline; PWD and the shell's own variables are filtered from both)
  env -i /bin/sh -c env | grep -v '^PWD=\|^_=\|^OLDPWD=\|^SHLVL=' | sort > "$cc/want_env"
  grep -v '^PWD=\|^_=\|^OLDPWD=\|^SHLVL=' "$cc/ev_env/env.txt" | sort > "$cc/got_env"
  oracle "env: the build is started with an empty environment" cmp -s "$cc/got_env" "$cc/want_env"
  # --- the endings
  oracle "stuck0: build.json says stuck with nothing verified, and no project.cho was offered or written" sh -c "grep -q '\"verdict\":\"stuck\"' '$cc/ev_stuck0/build.json' && [ ! -e '$cc/ev_stuck0/project.cho' ]"
  oracle "link: build.json is still a link: it was not followed to be read or offered" sh -c "[ -L '$cc/ev_link/build.json' ]"
  oracle "hang: build.json is there, the build's group was killed (nothing it started is left running, spike S12)" sh -c ". scripts/procs.sh; ! leftover -f '^sleep 79\$' > /dev/null"
  oracle "hang: the stand-in itself is gone" sh -c ". scripts/procs.sh; ! leftover -f '[c]ancho-build' > /dev/null"
  oracle "noisy: build.out is exactly the 1 MiB cap" sh -c "[ \$(wc -c < '$cc/ev_noisy/build.out') -eq 1048576 ]"
  oracle "sig: the log is there and the stand-in is gone" sh -c ". scripts/procs.sh; ! leftover -f '[c]ancho-build' > /dev/null && [ -f '$cc/ev_sig/run.log' ]"
  # --- what could not be started, and the refusals ran nothing
  oracle "notool: only the brief, the lock file and the run's own files were written; the tool was not there" sh -c "[ \"\$(ls '$cc/ev_notool' | tr '\\n' ' ')\" = 'brief.txt forge-build.lock result.json run.json ' ]"
  oracle "refusals ran nothing: no file written (ev_refuse is shared by all of them)" sh -c "[ -z \"\$(ls -A '$cc/ev_refuse')\" ]"
  oracle "briefdir: the tool never ran: no build.json, no build.out" sh -c "[ ! -e '$cc/ev_briefdir/build.json' ] && [ ! -e '$cc/ev_briefdir/build.out' ]"
  oracle "nowhere: an execution directory that is not there was not created" sh -c "[ ! -e '$cc/ev_nowhere' ]"
  oracle "big: a brief of exactly 16 KiB was written whole" sh -c "[ \$(wc -c < '$cc/ev_big/brief.txt') -eq 16384 ]"
  oracle "forge: the files are there and say done" sh -c "grep -q '\"verdict\":\"done\"' '$cc/ev_forge/build.json'"
  # --- the async level and the lock of the execution directory (issues #33 and #35; docs/async-level.md, docs/cancho-code-adapter.md
  # section 11). The adapter is driven by hand here, one process per call as Forge drives it. The stand-in's `slow` mode waits for
  # a file `release` in the directory (`holdgrand` also starts a grandchild, `sleep 78`), so the build is still running when the
  # next call comes.
  adapter="$cc/workers/cancho_code"
  lreq() { # brief as a JSON string, execution directory, timeout_ms, [workers directory, default the real one; "-" for none]
    wd=${4:-$cc/workers}; if [ "$wd" = - ]; then wk=''; else wk=",\"workers_dir\":\"$wd\""; fi
    printf '{"contract":"forge-worker/1","verb":"execute","request_id":"r-1","attempt":1,"task":{"id":"t-1","type":"project.build","input":{"brief":%s}},"limits":{"timeout_ms":%s,"max_output_bytes":1048576},"grants":{"execution_dir":"%s","tools_dir":"%s"%s,"build":{"checker":"/opt/cancho/bin/cancho","agent":"stand-in-agent","provider":"stand","model":"m1"}}}' "$1" "$3" "$2" "$tools" "$wk"
  }
  ctl() { # verb, id of this call, execution directory, target
    printf '{"contract":"forge-worker/1","verb":"%s","request_id":"%s","target":"%s","grants":{"execution_dir":"%s"}}' "$1" "$2" "$4" "$3"
  }
  state_of() { grep -o '"state":"[a-z_]*"' | head -1 | cut -d'"' -f4; }
  waitfor() { # path, tenths of a second at most
    n=0; while [ ! -s "$1" ] && [ "$n" -lt "$2" ]; do sleep 0.1; n=$((n + 1)); done
  }
  until_finished() { # directory, target: status until `finished`, 20 s at most
    n=0; while [ "$n" -lt 200 ]; do
      st=$(ctl status s-w "$1" "$2" | "$adapter" | state_of); [ "$st" = finished ] && return 0
      sleep 0.1; n=$((n + 1))
    done; return 1
  }
  run_through() { # request file, directory, out: execute, wait until finished, result; the final reply is in out
    "$adapter" < "$1" > "$3.accepted" 2> /dev/null; until_finished "$2" r-1; ctl result s-r "$2" r-1 | "$adapter" > "$3"
  }
  snap() { (cd "$1" && for f in $(ls -A); do stat -c '%n %s %.9Y' "$f"; done; cksum $(ls -A | grep -v '^forge-build.lock$' | grep -v '^pids.txt$') 2> /dev/null); }
  ms() { date +%s%N | cut -c1-13; }
  # --- defect 2 of statuslite run arm-a-1 (docs/company.md section 14): a build that ends by itself (done, exit 0) and leaves a
  # process running in its group (`straggle`: what the real tool's agent is once the driver killed its shell at the agent's deadline).
  # The adapter kills the build's group on every ending, its own exit included, so nothing is left once the answer is written.
  mkdir "$cc/strag" || exit 1
  lreq '"straggle\n76"' "$cc/strag" 60000 > "$cc/strag.req"; run_through "$cc/strag.req" "$cc/strag" "$cc/strag.ans"
  oracle "straggle: the build ended done and its answer is succeeded" sh -c "grep -q '\"state\":\"succeeded\"' '$cc/strag.ans' && grep -q '\"verdict\":\"done\"' '$cc/strag/build.json'"
  oracle "straggle: what the build left running in its group (sleep 76) was killed when it ended" sh -c ". scripts/procs.sh; sleep 0.5; ! leftover -f '^sleep 76\$' > /dev/null"
  # the reference: the same brief, alone, in its own directory
  mkdir "$cc/lk_ref" "$cc/lk" || exit 1
  touch "$cc/lk_ref/release"
  lreq '"slow\nfirst"' "$cc/lk_ref" 60000 > "$cc/lk_ref.req"; run_through "$cc/lk_ref.req" "$cc/lk_ref" "$cc/lk_ref.ans"
  # A is accepted and its build runs; B is started on the same directory; A is released
  lreq '"slow\nfirst"' "$cc/lk" 60000 > "$cc/lk_a.req"; lreq '"slow\nsecond"' "$cc/lk" 60000 > "$cc/lk_b.req"
  t0=$(ms); "$adapter" < "$cc/lk_a.req" > "$cc/lk_a.acc"; ta=$(( $(ms) - t0 ))
  waitfor "$cc/lk/pids.txt" 100
  oracle "async: execute answers accepted at once (state accepted, no evidence, no error), the build still running" sh -c "grep -q '\"state\":\"accepted\"' '$cc/lk_a.acc' && grep -q '\"evidence\":\\[\\]' '$cc/lk_a.acc' && grep -q '\"error\":null' '$cc/lk_a.acc' && [ $ta -lt 3000 ] && [ -s '$cc/lk/pids.txt' ] && [ ! -e '$cc/lk/result.json' ]"
  oracle "async: run.json names the request, the task and a start token" sh -c "grep -q '^{\"request_id\":\"r-1\",\"task_id\":\"t-1\",\"token\":[0-9]*}\$' '$cc/lk/run.json'"
  ctl status s-1 "$cc/lk" r-1 | "$adapter" > "$cc/lk_s1.ans"
  ctl result s-2 "$cc/lk" r-1 | "$adapter" > "$cc/lk_r1.ans"
  oracle "async: status of the live run is running, with the build's stage as the step" sh -c "grep -q '\"target\":\"r-1\",\"state\":\"running\",\"progress\":{\"step\":\"build\"}' '$cc/lk_s1.ans'"
  oracle "async: result of the live run is not_ready" sh -c "grep -q '\"state\":\"not_ready\"' '$cc/lk_r1.ans'"
  ctl status s-3 "$cc/lk" r-9 | "$adapter" > "$cc/lk_s9.ans"
  ctl result s-4 "$cc/lk" r-9 | "$adapter" > "$cc/lk_r9.ans"
  ctl cancel s-5 "$cc/lk" r-9 | "$adapter" > "$cc/lk_c9.ans"
  oracle "async: a target that is not the run in the directory is unknown, not_ready, not_running" sh -c "grep -q '\"state\":\"unknown\"' '$cc/lk_s9.ans' && grep -q '\"state\":\"not_ready\"' '$cc/lk_r9.ans' && grep -q '\"state\":\"not_running\"' '$cc/lk_c9.ans' && [ ! -e '$cc/lk/cancel.req' ]"
  snap "$cc/lk" > "$cc/lk.before"
  t0=$(ms); "$adapter" < "$cc/lk_b.req" > "$cc/lk_b.ans" 2> /dev/null; rb=$?; tb=$(( $(ms) - t0 ))
  snap "$cc/lk" > "$cc/lk.after"
  oracle "lock: the second adapter is answered in under three seconds, while the first build is still running" sh -c "[ $rb -eq 0 ] && [ $tb -lt 3000 ] && [ \"\$(pgrep -f '[c]ancho-build' | wc -l)\" -eq 1 ]"
  oracle "lock: it is failed, execution-locked, not retryable, with no evidence" sh -c "grep -q '\"state\":\"failed\"' '$cc/lk_b.ans' && grep -q '\"evidence\":\\[\\]' '$cc/lk_b.ans' && grep -q '\"code\":\"execution-locked\"' '$cc/lk_b.ans' && grep -q '\"retryable\":false' '$cc/lk_b.ans'"
  oracle "lock: the refused start wrote nothing: every file's size and mtime and checksum is what it was (the lock file included)" cmp -s "$cc/lk.before" "$cc/lk.after"
  oracle "lock: brief.txt is still the first brief, and only one build was ever started" sh -c "[ \"\$(sed -n 2p '$cc/lk/brief.txt')\" = first ] && [ \$(wc -l < '$cc/lk/pids.txt') -eq 1 ]"
  oracle "lock: the lock file is a file of no bytes beside the evidence" sh -c "[ -f '$cc/lk/forge-build.lock' ] && [ ! -s '$cc/lk/forge-build.lock' ]"
  # a cancel request for ANOTHER request is ignored by the live supervisor
  printf 'r-other' > "$cc/lk/cancel.req"; sleep 0.5
  ctl status s-6 "$cc/lk" r-1 | "$adapter" > "$cc/lk_s6.ans"
  oracle "async: a cancel request naming another request does not stop the build" sh -c "grep -q '\"state\":\"running\"' '$cc/lk_s6.ans' && [ \"\$(pgrep -f '[c]ancho-build' | wc -l)\" -eq 1 ]"
  touch "$cc/lk/release"
  until_finished "$cc/lk" r-1
  ctl result s-r "$cc/lk" r-1 | "$adapter" > "$cc/lk_a.ans"
  oracle "lock: the first build ended as it would have alone: succeeded, and its files are byte for byte the reference's" sh -c "grep -q '\"state\":\"succeeded\"' '$cc/lk_a.ans' && for f in brief.txt seen_brief.txt build.json build.out run.log project.cho; do cmp -s '$cc/lk/'\$f '$cc/lk_ref/'\$f || exit 1; done"
  oracle "lock: and so is its result, evidence included (the same call id gives the same bytes)" cmp -s "$cc/lk_a.ans" "$cc/lk_ref.ans"
  ctl result s-r "$cc/lk" r-1 | "$adapter" > "$cc/lk_a2.ans"; ctl result s-r2 "$cc/lk" r-1 | "$adapter" > "$cc/lk_a3.ans"
  oracle "async: result is idempotent, and answers each call with its own request id and nothing else changed" sh -c "cmp -s '$cc/lk_a.ans' '$cc/lk_a2.ans' && grep -q '\"request_id\":\"s-r2\"' '$cc/lk_a3.ans' && [ \"\$(sed 's/\"request_id\":\"s-r2\"/\"request_id\":\"s-r\"/' '$cc/lk_a3.ans')\" = \"\$(cat '$cc/lk_a.ans')\" ]"
  ctl status s-7 "$cc/lk" r-1 | "$adapter" > "$cc/lk_s7.ans"; ctl cancel s-8 "$cc/lk" r-1 | "$adapter" > "$cc/lk_c7.ans"
  oracle "async: after the end, status is finished and a cancel is too_late" sh -c "grep -q '\"state\":\"finished\"' '$cc/lk_s7.ans' && grep -q '\"state\":\"too_late\"' '$cc/lk_c7.ans'"
  # the lock is let go with the run: the same directory takes the next request (a resume after an ending)
  rm -f "$cc/lk/release"
  lreq '"slow\nthird"' "$cc/lk" 60000 > "$cc/lk_c.req"; "$adapter" < "$cc/lk_c.req" > "$cc/lk_c.acc" 2> /dev/null
  waitfor "$cc/lk/pids.txt" 100; sleep 0.3
  ctl status s-9 "$cc/lk" r-1 | "$adapter" > "$cc/lk_s9b.ans"; ctl result s-10 "$cc/lk" r-1 | "$adapter" > "$cc/lk_r9b.ans"
  oracle "lock: after the first ended, a new request on the directory takes the lock and is accepted; the result of the old run is gone, so the new run is running and its result is not_ready" sh -c "grep -q '\"state\":\"accepted\"' '$cc/lk_c.acc' && grep -q '\"state\":\"running\"' '$cc/lk_s9b.ans' && grep -q '\"state\":\"not_ready\"' '$cc/lk_r9b.ans'"
  touch "$cc/lk/release"; until_finished "$cc/lk" r-1; ctl result s-r "$cc/lk" r-1 | "$adapter" > "$cc/lk_c.ans"
  oracle "lock: and it ends as its own run: succeeded, with its own product" sh -c "grep -q '\"state\":\"succeeded\"' '$cc/lk_c.ans' && [ \"\$(cat '$cc/lk/project.cho')\" = 'product of third' ]"

  # cancel of a running build: the group is gone, the directory is kept, the same request resumes it
  mkdir "$cc/cx" || exit 1
  lreq '"holdgrand\nfirst"' "$cc/cx" 60000 > "$cc/cx.req"; "$adapter" < "$cc/cx.req" > "$cc/cx.acc" 2> /dev/null
  waitfor "$cc/cx/pids.txt" 100; sleep 0.3
  oracle "cancel: the build and its grandchild are running before the cancel" sh -c ". scripts/procs.sh; leftover -f '^sleep 78\$' > /dev/null && leftover -f '[c]ancho-build' > /dev/null"
  t0=$(ms); ctl cancel c-1 "$cc/cx" r-1 | "$adapter" > "$cc/cx.cancel"; tc=$(( $(ms) - t0 ))
  oracle "cancel: answered cancelled, quickly" sh -c "grep -q '\"state\":\"cancelled\"' '$cc/cx.cancel' && [ $tc -lt 3000 ]"
  oracle "cancel: the build's whole group is gone (the stand-in and its grandchild), and so is the supervisor" sh -c "sleep 0.3; . scripts/procs.sh; ! leftover -f '^sleep 78\$' > /dev/null && ! leftover -f '[c]ancho-build' > /dev/null && ! leftover -x cancho_code > /dev/null"
  ctl status c-2 "$cc/cx" r-1 | "$adapter" > "$cc/cx.status"; ctl result c-3 "$cc/cx" r-1 | "$adapter" > "$cc/cx.result"; ctl result c-3 "$cc/cx" r-1 | "$adapter" > "$cc/cx.result2"
  oracle "cancel: status is finished; result is state cancelled with no error and the evidence there is; and the same twice" sh -c "grep -q '\"state\":\"finished\"' '$cc/cx.status' && grep -q '\"state\":\"cancelled\"' '$cc/cx.result' && grep -q '\"error\":null' '$cc/cx.result' && grep -q '\"ref\":\"build.json\"' '$cc/cx.result' && cmp -s '$cc/cx.result' '$cc/cx.result2'"
  oracle "cancel: the directory is kept (brief, report, log, lock file) and the product is not there" sh -c "[ -s '$cc/cx/brief.txt' ] && [ -s '$cc/cx/build.json' ] && [ -s '$cc/cx/run.log' ] && [ -f '$cc/cx/forge-build.lock' ] && [ ! -e '$cc/cx/project.cho' ]"
  ctl cancel c-4 "$cc/cx" r-1 | "$adapter" > "$cc/cx.cancel2"
  oracle "cancel: asked again, a cancelled run is cancelled (idempotent)" sh -c "grep -q '\"state\":\"cancelled\"' '$cc/cx.cancel2'"
  lreq '"done"' "$cc/cx" 60000 > "$cc/cx2.req"; run_through "$cc/cx2.req" "$cc/cx" "$cc/cx2.ans"
  oracle "cancel: the same request on the same directory resumes: it is accepted, the old cancel request does not stop it, and it ends done" sh -c "grep -q '\"state\":\"accepted\"' '$cc/cx2.ans.accepted' && grep -q '\"state\":\"succeeded\"' '$cc/cx2.ans' && grep -q '\"verdict\":\"done\"' '$cc/cx/build.json' && [ ! -e '$cc/cx/cancel.req' ]"

  # a supervisor killed with SIGKILL: its lock goes with it, its build does not (spike S14, gap G4); status and result say so
  mkdir "$cc/lost" || exit 1
  lreq '"holdgrand\nfirst"' "$cc/lost" 60000 > "$cc/lost.req"; "$adapter" < "$cc/lost.req" > "$cc/lost.acc" 2> /dev/null
  waitfor "$cc/lost/pids.txt" 100; sleep 0.3
  sup=$(. scripts/procs.sh; leftover -x cancho_code | head -1)
  kill -9 "$sup"; sleep 0.3
  ctl status l-1 "$cc/lost" r-1 | "$adapter" > "$cc/lost.status"; ctl cancel l-3 "$cc/lost" r-1 | "$adapter" > "$cc/lost.cancel"
  ctl result l-2 "$cc/lost" r-1 | "$adapter" > "$cc/lost.result"; rm -f "$cc/lost/run.log"; ctl result l-2 "$cc/lost" r-1 | "$adapter" > "$cc/lost.result2"
  ctl cancel l-4 "$cc/lost" r-1 | "$adapter" > "$cc/lost.cancel2"
  oracle "lost: the supervisor was killed and the build it started is still running (an orphan: gap G4, not stopped by anything here)" sh -c ". scripts/procs.sh; ! leftover -x cancho_code > /dev/null && leftover -f '[c]ancho-build' > /dev/null && leftover -f '^sleep 78\$' > /dev/null"
  oracle "lost: status is finished; result is failed, build-supervisor-lost, not retryable, with the evidence there is, and the same twice (even when a file of the directory is gone in between: the result is kept)" sh -c "grep -q '\"state\":\"finished\"' '$cc/lost.status' && grep -q '\"state\":\"failed\"' '$cc/lost.result' && grep -q '\"code\":\"build-supervisor-lost\"' '$cc/lost.result' && grep -q '\"retryable\":false' '$cc/lost.result' && grep -q '\"ref\":\"build.json\"' '$cc/lost.result' && cmp -s '$cc/lost.result' '$cc/lost.result2'"
  oracle "lost: a cancel of a run whose supervisor is gone is not_running; once the loss is settled in the result it is too_late" sh -c "grep -q '\"state\":\"not_running\"' '$cc/lost.cancel' && grep -q '\"state\":\"too_late\"' '$cc/lost.cancel2'"
  kill -9 -- -"$(head -1 "$cc/lost/pids.txt")" 2> /dev/null; pkill -f '^sleep 78$'; sleep 0.3; touch "$cc/lost/release"
  lreq '"done"' "$cc/lost" 60000 > "$cc/lost2.req"; run_through "$cc/lost2.req" "$cc/lost" "$cc/lost2.ans"
  oracle "lost: the next request on the directory takes it at once (the stale lock case is settled, not stuck) and ends done" sh -c "grep -q '\"state\":\"accepted\"' '$cc/lost2.ans.accepted' && grep -q '\"state\":\"succeeded\"' '$cc/lost2.ans'"

  # calls about a directory with no run write nothing
  mkdir "$cc/nothing" || exit 1
  ctl status n-1 "$cc/nothing" r-1 | "$adapter" > "$cc/nothing.s"; ctl result n-2 "$cc/nothing" r-1 | "$adapter" > "$cc/nothing.r"; ctl cancel n-3 "$cc/nothing" r-1 | "$adapter" > "$cc/nothing.c"
  oracle "no run: unknown, not_ready and not_running, and not a byte written to the directory (not even the lock file)" sh -c "grep -q '\"state\":\"unknown\"' '$cc/nothing.s' && grep -q '\"state\":\"not_ready\"' '$cc/nothing.r' && grep -q '\"state\":\"not_running\"' '$cc/nothing.c' && [ -z \"\$(ls -A '$cc/nothing')\" ]"
  printf '{"contract":"forge-worker/1","verb":"status","request_id":"x","target":"r-1","grants":{"execution_dir":"relative/dir"}}' | "$adapter" > "$cc/rel.out" 2> /dev/null; rrel=$?
  printf '{"contract":"forge-worker/1","verb":"cancel","request_id":"x","grants":{"execution_dir":"%s"}}' "$cc/nothing" | "$adapter" > "$cc/notarget.out" 2> /dev/null; rnot=$?
  oracle "status or cancel about a relative directory, or with no target, is not answered (exit 4)" sh -c "[ $rrel -eq 4 ] && [ ! -s '$cc/rel.out' ] && [ $rnot -eq 4 ] && [ ! -s '$cc/notarget.out' ]"

  # execute: the workers directory
  mkdir "$cc/w1" "$cc/w2" "$cc/w3" || exit 1
  lreq '"done"' "$cc/w1" 60000 "$cc/nowhere-workers" | "$adapter" > "$cc/w1.ans"
  lreq '"done"' "$cc/w2" 60000 - | "$adapter" > "$cc/w2.ans"
  lreq '"done"' "$cc/w3" 60000 "$cc/tools_empty" | "$adapter" > "$cc/w3.ans"
  oracle "workers: a directory that is not there, or one without cancho_code, is supervisor-unavailable; none at all is path-invalid; nothing is written" sh -c "grep -q '\"code\":\"supervisor-unavailable\"' '$cc/w1.ans' && grep -q '\"code\":\"path-invalid\"' '$cc/w2.ans' && grep -q '\"code\":\"supervisor-unavailable\"' '$cc/w3.ans' && [ -z \"\$(ls -A '$cc/w1')\" ] && [ -z \"\$(ls -A '$cc/w2')\" ] && [ -z \"\$(ls -A '$cc/w3')\" ]"

  # a deadline kill: the supervisor answers and exits, so the lock is let go; the same directory takes a new request
  lreq '"done"' "$cc/ev_hang" 20000 > "$cc/lk_h.req"; run_through "$cc/lk_h.req" "$cc/ev_hang" "$cc/lk_h.ans"
  oracle "deadline: after the build-timeout case the same directory takes the lock again, and the build finishes done" sh -c "grep -q '\"state\":\"succeeded\"' '$cc/lk_h.ans' && grep -q '\"verdict\":\"done\"' '$cc/ev_hang/build.json'"
  # a lock file that cannot be opened is a directory that cannot be written: nothing runs
  mkdir "$cc/lk_dir" "$cc/lk_dir/forge-build.lock" || exit 1
  lreq '"done"' "$cc/lk_dir" 20000 | "$adapter" > "$cc/lk_d.ans"
  oracle "lockdir: a lock file that is a directory is workdir-unwritable, and the tool never ran" sh -c "grep -q '\"code\":\"workdir-unwritable\"' '$cc/lk_d.ans' && [ \"\$(ls '$cc/lk_dir')\" = forge-build.lock ]"
  oracle "async: no adapter, supervisor or build is left" sh -c "sleep 0.5; . scripts/procs.sh; ! leftover -x cancho_code > /dev/null && ! leftover -f '[c]ancho-build' > /dev/null && ! leftover -f '^sleep 78\$' > /dev/null"
  oracle "no adapter and no build outlived the run" sh -c ". scripts/procs.sh; ! leftover -x cancho_code > /dev/null && ! leftover -f '[c]ancho-build' > /dev/null"
else
  echo "cancho code adapter: did not build"
  fail=1
fi
exit $fail
