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

# The stand-in for `cancho-build <checker> <brief> <workdir> <agent> --provider P --model M ...`. The first line of the brief
# says what to do. It is a test oracle's fixture, not product logic: nothing Forge decides is written in it.
cat > "$tools/cancho-build" <<'STANDIN'
#!/bin/sh
brief=$2
work=$3
read -r mode < "$brief"
log() { printf 'ran\n' > "$work/run.log"; }
report() { # stage units_verified verdict
  printf '{"brief":"b","stage":"%s","plan_valid":true,"units_total":2,"units_verified":%s,"verdict":"%s"}\n' "$1" "$2" "$3" > "$work/build.json"
}
case "$mode" in
  done)      log; report done 2 done; printf 'product\n' > "$work/project.cho"; printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;
  stuck)     log; report done 1 stuck; printf 'product\n' > "$work/project.cho"; printf '[BUILD_VERDICT]\tstuck\n'; exit 1 ;;
  stuck0)    log; report done 0 stuck; printf '[BUILD_VERDICT]\tstuck\n'; exit 1 ;;
  gate)      log; report done 2 gate_failed; printf 'product\n' > "$work/project.cho"; printf '[BUILD_VERDICT]\tgate_failed\n'; exit 1 ;;
  plan)      log; report plan 0 plan_failed; printf '[BUILD_VERDICT]\tplan_failed\n'; exit 3 ;;
  provider)  log; report build 1 provider_error; printf 'product\n' > "$work/project.cho"; printf '[BUILD_VERDICT]\tprovider_error\n'; exit 4 ;;
  usage)     echo 'usage: cancho-build ...' >&2; exit 2 ;;
  disagree)  log; report done 2 done; printf '[BUILD_VERDICT]\tdone\n'; exit 1 ;;
  disagree0) log; report done 1 stuck; printf '[BUILD_VERDICT]\tstuck\n'; exit 0 ;;
  badjson)   log; printf 'this is not json\n' > "$work/build.json"; exit 0 ;;
  nojson)    log; exit 0 ;;
  link)      log; printf '{"verdict":"done","units_verified":9}\n' > "$work/../outside_secret.json"; ln -s "$work/../outside_secret.json" "$work/build.json"; exit 0 ;;
  hang)      log; report build 0 ""; sleep 79 & wait ;;
  noisy)     log; report build 0 ""; head -c 1100000 /dev/zero | tr '\0' x ;;
  sig)       log; kill -9 $$ ;;
  args)      log; report done 2 done; printf 'product\n' > "$work/project.cho"; for a in "$@"; do printf 'A:%s\n' "$a"; done > "$work/args.txt"; printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;
  args2)     log; report done 2 done; printf 'product\n' > "$work/project.cho"; for a in "$@"; do printf 'A:%s\n' "$a"; done > "$work/args.txt"; printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;
  env)       log; report done 2 done; printf 'product\n' > "$work/project.cho"; env > "$work/env.txt"; printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;
  *)         log; report done 1 wat; exit 1 ;;
esac
STANDIN
chmod +x "$tools/cancho-build" || exit 1

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
  oracle "notool: only the brief was written; the tool was not there" sh -c "[ \"\$(ls '$cc/ev_notool')\" = brief.txt ]"
  oracle "refusals ran nothing: no file written (ev_refuse is shared by all of them)" sh -c "[ -z \"\$(ls -A '$cc/ev_refuse')\" ]"
  oracle "briefdir: the tool never ran: no build.json, no build.out" sh -c "[ ! -e '$cc/ev_briefdir/build.json' ] && [ ! -e '$cc/ev_briefdir/build.out' ]"
  oracle "nowhere: an execution directory that is not there was not created" sh -c "[ ! -e '$cc/ev_nowhere' ]"
  oracle "big: a brief of exactly 16 KiB was written whole" sh -c "[ \$(wc -c < '$cc/ev_big/brief.txt') -eq 16384 ]"
  oracle "forge: the files are there and say done" sh -c "grep -q '\"verdict\":\"done\"' '$cc/ev_forge/build.json'"
  oracle "no adapter and no build outlived the run" sh -c ". scripts/procs.sh; ! leftover -x cancho_code > /dev/null && ! leftover -f '[c]ancho-build' > /dev/null"
else
  echo "cancho code adapter: did not build"
  fail=1
fi
exit $fail
