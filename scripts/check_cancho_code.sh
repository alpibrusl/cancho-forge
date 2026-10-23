#!/bin/sh
# The Cancho Code adapter against a real child process and a stand-in build tool (docs/cancho-code-adapter.md, worker-contract
# section 9). workers/cancho_code.cho is built into a workers directory; a stand-in `cancho-build` (a shell script) is written into
# a tools directory, and does one thing for each first line of the brief it is given: finish, get stuck, fail the gate or the
# plan, hit a provider error, refuse its arguments, lie about its verdict, write junk, hang with a grandchild, write too much,
# be killed. tests/conformance/cancho_code.cho starts the adapter beneath the workers directory once per way a build can end
# and once per refusal; the oracle for what the adapter wrote and left behind is outside the programs (cmp, grep, pgrep on the
# files and the process table). Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
# Used by scripts/gate.sh and by scripts/mutate_cancho_code.py (which runs it on a copy of the tree with one break).
# Usage: CANCHO=path/to/cancho scripts/check_cancho_code.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
cc="$scratch/cc"; mkdir "$cc" "$cc/workers" || exit 1
tools="$cc/tools"; mkdir "$tools" "$cc/tools_empty" || exit 1
for e in done stuck stuck0 gate plan provider usage disagree disagree0 badjson nojson unknown link hang noisy sig args env args2 notool big forge; do mkdir "$cc/ev_$e" || exit 1; done
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
  if grep -q '^FAIL ' "$cc/out"; then fail=1; fi
  oracle() { # name, command...
    name=$1; shift
    if "$@"; then echo "ok   cancho code oracle: $name"; else echo "FAIL cancho code oracle: $name"; fail=1; fi
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
  oracle "notool: only the brief and the lock file were written; the tool was not there" sh -c "[ \"\$(ls '$cc/ev_notool' | tr '\\n' ' ')\" = 'brief.txt forge-build.lock ' ]"
  oracle "refusals ran nothing: no file written (ev_refuse is shared by all of them)" sh -c "[ -z \"\$(ls -A '$cc/ev_refuse')\" ]"
  oracle "briefdir: the tool never ran: no build.json, no build.out" sh -c "[ ! -e '$cc/ev_briefdir/build.json' ] && [ ! -e '$cc/ev_briefdir/build.out' ]"
  oracle "nowhere: an execution directory that is not there was not created" sh -c "[ ! -e '$cc/ev_nowhere' ]"
  oracle "big: a brief of exactly 16 KiB was written whole" sh -c "[ \$(wc -c < '$cc/ev_big/brief.txt') -eq 16384 ]"
  oracle "forge: the files are there and say done" sh -c "grep -q '\"verdict\":\"done\"' '$cc/ev_forge/build.json'"
  # --- two adapters on one execution directory (issue #35; docs/cancho-code-adapter.md section 11). The stand-in's `slow` mode
  # waits for a file `release` in the directory, so the first build is still running when the second adapter starts.
  lreq() { # brief as a JSON string, execution directory, timeout_ms
    printf '{"contract":"forge-worker/1","verb":"execute","request_id":"r-1","attempt":1,"task":{"id":"t-1","type":"project.build","input":{"brief":%s}},"limits":{"timeout_ms":%s,"max_output_bytes":1048576},"grants":{"execution_dir":"%s","tools_dir":"%s","build":{"checker":"/opt/cancho/bin/cancho","agent":"stand-in-agent","provider":"stand","model":"m1"}}}' "$1" "$3" "$2" "$tools"
  }
  waitfor() { # path, tenths of a second at most
    n=0; while [ ! -s "$1" ] && [ "$n" -lt "$2" ]; do sleep 0.1; n=$((n + 1)); done
  }
  snap() { (cd "$1" && for f in $(ls -A); do stat -c '%n %s %.9Y' "$f"; done; cksum $(ls -A | grep -v '^forge-build.lock$' | grep -v '^pids.txt$') 2> /dev/null); }
  adapter="$cc/workers/cancho_code"
  # the reference: the same brief, alone, in its own directory
  mkdir "$cc/lk_ref" "$cc/lk" || exit 1
  touch "$cc/lk_ref/release"
  lreq '"slow\nfirst"' "$cc/lk_ref" 60000 | "$adapter" > "$cc/lk_ref.ans"
  # A starts and its build is running; B is started on the same directory; A is released
  lreq '"slow\nfirst"' "$cc/lk" 60000 > "$cc/lk_a.req"; lreq '"slow\nsecond"' "$cc/lk" 60000 > "$cc/lk_b.req"
  "$adapter" < "$cc/lk_a.req" > "$cc/lk_a.ans" 2> /dev/null &
  pa=$!
  waitfor "$cc/lk/pids.txt" 100
  snap "$cc/lk" > "$cc/lk.before"
  "$adapter" < "$cc/lk_b.req" > "$cc/lk_b.ans" 2> /dev/null &
  pb=$!
  waitfor "$cc/lk_b.ans" 30
  sleep 0.5
  snap "$cc/lk" > "$cc/lk.after"
  oracle "lock: the second adapter answered at once, while the first build was still running" sh -c "[ -s '$cc/lk_b.ans' ] && kill -0 $pa 2> /dev/null"
  oracle "lock: it is failed, execution-locked, not retryable, with no evidence" sh -c "grep -q '\"state\":\"failed\"' '$cc/lk_b.ans' && grep -q '\"evidence\":\\[\\]' '$cc/lk_b.ans' && grep -q '\"code\":\"execution-locked\"' '$cc/lk_b.ans' && grep -q '\"retryable\":false' '$cc/lk_b.ans'"
  oracle "lock: the refused start wrote nothing: every file's size and mtime and checksum is what it was (the lock file included)" cmp -s "$cc/lk.before" "$cc/lk.after"
  oracle "lock: brief.txt is still the first brief, and only one build was ever started" sh -c "[ \"\$(sed -n 2p '$cc/lk/brief.txt')\" = first ] && [ \$(wc -l < '$cc/lk/pids.txt') -eq 1 ] && [ \"\$(pgrep -f '[c]ancho-build' | wc -l)\" -eq 1 ]"
  oracle "lock: the lock file is a file of no bytes beside the evidence" sh -c "[ -f '$cc/lk/forge-build.lock' ] && [ ! -s '$cc/lk/forge-build.lock' ]"
  touch "$cc/lk/release"
  wait "$pa"; ra=$?; wait "$pb"; rb=$?
  oracle "lock: both adapters exited 0 (a refusal is an answer)" sh -c "[ $ra -eq 0 ] && [ $rb -eq 0 ]"
  oracle "lock: the first build ended as it would have alone: succeeded, and its files are byte for byte the reference's" sh -c "grep -q '\"state\":\"succeeded\"' '$cc/lk_a.ans' && for f in brief.txt seen_brief.txt build.json build.out run.log project.cho; do cmp -s '$cc/lk/'\$f '$cc/lk_ref/'\$f || exit 1; done"
  oracle "lock: and so is its answer, evidence included" cmp -s "$cc/lk_a.ans" "$cc/lk_ref.ans"
  # the lock is let go with the request: the same directory takes the next one (a resume after an ending)
  lreq '"slow\nthird"' "$cc/lk" 60000 | "$adapter" > "$cc/lk_c.ans"
  oracle "lock: after the first ended, a new request on the directory takes the lock and runs" sh -c "grep -q '\"state\":\"succeeded\"' '$cc/lk_c.ans' && [ \"\$(cat '$cc/lk/project.cho')\" = 'product of third' ]"
  # a killed adapter: the lock goes with it, the build it started does not (spike S13)
  mkdir "$cc/lk_stale" || exit 1
  lreq '"slow\nfirst"' "$cc/lk_stale" 60000 > "$cc/lk_s1.req"; lreq '"slow\nsecond"' "$cc/lk_stale" 60000 > "$cc/lk_s2.req"
  "$adapter" < "$cc/lk_s1.req" > "$cc/lk_s1.ans" 2> /dev/null &
  ps1=$!
  waitfor "$cc/lk_stale/pids.txt" 100
  orphan=$(head -1 "$cc/lk_stale/pids.txt")
  kill -9 "$ps1"; wait "$ps1" 2> /dev/null
  sleep 0.3
  oracle "stale: the adapter was killed with SIGKILL, and the build it started is still running (an orphan: spike S13, gap G4)" sh -c "kill -0 $orphan 2> /dev/null"
  oracle "stale: the orphan holds no descriptor of the lock file" sh -c "[ \"\$(ls -l /proc/$orphan/fd 2> /dev/null | grep -c forge-build.lock)\" -eq 0 ]"
  touch "$cc/lk_stale/release"
  lreq '"slow\nsecond"' "$cc/lk_stale" 60000 | "$adapter" > "$cc/lk_s2.ans"
  oracle "stale: the next adapter takes the lock at once, not refused and not stuck, and its build ends succeeded" sh -c "grep -q '\"state\":\"succeeded\"' '$cc/lk_s2.ans' && ! grep -q execution-locked '$cc/lk_s2.ans'"
  # a deadline kill: the adapter answers and exits, so the lock is let go; the same directory takes the same request again
  lreq '"done"' "$cc/ev_hang" 20000 | "$adapter" > "$cc/lk_h.ans"
  oracle "deadline: after the build-timeout case the same directory takes the lock again, and the build finishes done" sh -c "grep -q '\"state\":\"succeeded\"' '$cc/lk_h.ans' && grep -q '\"verdict\":\"done\"' '$cc/ev_hang/build.json'"
  # a lock file that cannot be opened is a directory that cannot be written: nothing runs
  mkdir "$cc/lk_dir" "$cc/lk_dir/forge-build.lock" || exit 1
  lreq '"done"' "$cc/lk_dir" 20000 | "$adapter" > "$cc/lk_d.ans"
  oracle "lockdir: a lock file that is a directory is workdir-unwritable, and the tool never ran" sh -c "grep -q '\"code\":\"workdir-unwritable\"' '$cc/lk_d.ans' && [ \"\$(ls '$cc/lk_dir')\" = forge-build.lock ]"
  oracle "lock: no adapter and no build is left (the orphan of the stale case ended with its release)" sh -c "sleep 0.5; . scripts/procs.sh; ! leftover -x cancho_code > /dev/null && ! leftover -f '[c]ancho-build' > /dev/null"
  oracle "no adapter and no build outlived the run" sh -c ". scripts/procs.sh; ! leftover -x cancho_code > /dev/null && ! leftover -f '[c]ancho-build' > /dev/null"
else
  echo "cancho code adapter: did not build"
  fail=1
fi
exit $fail
