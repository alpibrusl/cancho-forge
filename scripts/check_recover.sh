#!/bin/sh
# `forge recover` end to end (docs/architecture.md section 4.4; issue #15, `execution.lost`): the tasks a crash left
# `running` are settled from the journal alone. The oracle is outside the programs: the exit status and output of the
# forge binary, `forge status` and `forge history`, `grep` and `cmp` on the journal, and the process table. The crash
# itself is real: `forge gate` is killed with SIGKILL after it wrote `execution.started` (check 1). The other journals
# are written here with printf, one record at a time, as a crash at each other point would have left them.
# Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
# Used by scripts/gate.sh and by scripts/mutate_recover.py (which runs it on a copy of the tree with one break).
# Usage: CANCHO=path/to/cancho scripts/check_recover.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
rc_dir="$scratch/rc"; mkdir "$rc_dir" "$rc_dir/workers" || exit 1
$C check src/*.cho --std || fail=1
$C check workers/gate_runner.cho $libs --std || fail=1
if $C build src/*.cho --std -o "$rc_dir/forge" && $C build workers/gate_runner.cho $libs --std -o "$rc_dir/workers/gate_runner"; then
  F="$rc_dir/forge"
  ok() { echo "ok   recover: $1"; }
  bad() { echo "FAIL recover: $1"; fail=1; }
  check() { # name, command...
    name=$1; shift
    if "$@"; then ok "$name"; else bad "$name"; fi
  }
  # ---- journals, one record at a time: rec <file> <kind> <task> <actor>, numbered by the file's own length
  rec() {
    n=$(($(wc -l < "$1") + 1))
    case "$2" in
      refusal) printf '{"v":1,"seq":%s,"kind":"refusal","task":"%s","rule":"x"}\n' "$n" "$3" >> "$1" ;;
      *) printf '{"v":1,"seq":%s,"kind":"%s","task":"%s","actor":"%s"}\n' "$n" "$2" "$3" "$4" >> "$1" ;;
    esac
  }
  running() { # file, task
    rec "$1" task.proposed "$2" human; rec "$1" task.approved "$2" human; rec "$1" task.ready "$2" forge; rec "$1" task.running "$2" forge
  }
  mkws() { mkdir "$rc_dir/$1" && : > "$rc_dir/$1/journal.jsonl" || exit 1; }
  recover() { # ws; output in $rc_dir/$ws.out, $rc_dir/$ws.err, status in $rc_dir/$ws.rc
    "$F" recover "$rc_dir/$1" > "$rc_dir/$1.out" 2> "$rc_dir/$1.err"
    echo $? > "$rc_dir/$1.rc"
  }
  rc() { cat "$rc_dir/$1.rc"; }
  J() { echo "$rc_dir/$1/journal.jsonl"; }
  has() { grep -q "$2" "$(J "$1")"; }
  state_is() { "$F" status "$rc_dir/$1" > "$rc_dir/$1.status" && grep -q "^  $2: $3\$" "$rc_dir/$1.status"; }

  # ---- 1. a real crash: forge gate killed with SIGKILL after the intent was written
  git init -q "$rc_dir/co" && mkdir -p "$rc_dir/co/scripts" && printf '#!/bin/sh\nsleep 83 & wait\n' > "$rc_dir/co/scripts/gate_cancho.sh" && chmod +x "$rc_dir/co/scripts/gate_cancho.sh" \
    && git -C "$rc_dir/co" add -A && git -C "$rc_dir/co" -c user.email=forge@example.invalid -c user.name=forge -c commit.gpgsign=false commit -q -m fixture || exit 1
  rev=$(git -C "$rc_dir/co" rev-parse HEAD)
  mkdir "$rc_dir/real" "$rc_dir/real/ev" || exit 1
  "$F" gate "$rc_dir/real" "$rc_dir/workers" alpibrusl/cancho-hdl "$rev" "$rc_dir/co" "$rc_dir/real/ev" 600000 > /dev/null 2>&1 &
  pid=$!
  n=0
  while [ "$n" -lt 100 ] && ! grep -q execution.started "$rc_dir/real/journal.jsonl" 2> /dev/null; do sleep 0.1; n=$((n + 1)); done
  kill -9 "$pid" 2> /dev/null; wait "$pid" 2> /dev/null
  # the runner and what it started outlive their parent (docs/self-hosting.md D7): the oracle cleans them up
  . scripts/procs.sh
  check "real crash: the journal ends at the intent" eval "tail -n 1 '$rc_dir/real/journal.jsonl' | grep -q execution.started"
  check "real crash: before recovery the task is running" state_is real running 1
  rm -f "$rc_dir/real/lock"
  recover real
  check "real crash: recover exits 0 and names the task and the tag" eval "[ '$(rc real)' = 0 ] && grep -q ': execution-lost' '$rc_dir/real.out' && grep -q '^recovered: 1\$' '$rc_dir/real.out'"
  check "real crash: the task is ready, not running, not accepted" eval "'$F' status '$rc_dir/real' | grep -q '^  ready: 1\$' && ! '$F' status '$rc_dir/real' | grep -q 'running\\|accepted'"
  check "real crash: execution.lost, the refusal and task.ready are the last three records, all forge's" eval "tail -n 3 '$rc_dir/real/journal.jsonl' | cut -c1-200 | grep -c '\"actor\":\"forge\"\\|\"rule\":\"execution-lost\"' | grep -q '^3\$' && tail -n 3 '$rc_dir/real/journal.jsonl' | head -n 1 | grep -q execution.lost"
  check "real crash: no worker was started again" eval "[ \$(grep -c execution.started '$rc_dir/real/journal.jsonl') -eq 1 ]"
  # what the killed run left: the gate's own `sleep` and its runner (not the runner we may be running under, `leftover`)
  for p in $(leftover -f '^sleep 83$'; leftover -x gate_runner); do kill "$p" 2> /dev/null; done
  sleep 0.3
  check "real crash: nothing it started is left running" eval "! leftover -f '^sleep 83\$' > /dev/null"
  ! leftover -x gate_runner > /dev/null || kill $(leftover -x gate_runner) 2> /dev/null

  # ---- 2. each phase, from a journal written here
  mkws unstarted; running "$(J unstarted)" t-1
  recover unstarted
  check "unstarted: exit 0, execution-unstarted, ready" eval "[ '$(rc unstarted)' = 0 ] && grep -q 't-1: execution-unstarted' '$rc_dir/unstarted.out' && has unstarted '\"rule\":\"execution-unstarted\"' && state_is unstarted ready 1" 
  check "unstarted: no execution.lost, because nothing was started" eval "! grep -q execution.lost '$(J unstarted)'"
  mkws lost; running "$(J lost)" t-1; rec "$(J lost)" execution.started t-1 forge
  cp "$(J lost)" "$rc_dir/lost.before"
  recover lost
  check "lost: exit 0, execution.lost, execution-lost, ready" eval "[ '$(rc lost)' = 0 ] && grep -q '\"kind\":\"execution.lost\"' '$(J lost)' && grep -q '\"rule\":\"execution-lost\"' '$(J lost)' && '$F' status '$rc_dir/lost' | grep -q '^  ready: 1\$'"
  mkws exhausted; running "$(J exhausted)" t-1; rec "$(J exhausted)" execution.started t-1 forge
  for k in 1 2; do rec "$(J exhausted)" execution.retry t-1 forge; rec "$(J exhausted)" task.ready t-1 forge; rec "$(J exhausted)" task.running t-1 forge; rec "$(J exhausted)" execution.started t-1 forge; done
  recover exhausted
  check "exhausted: three starts, no ending: retry-exhausted and blocked, not ready" eval "[ '$(rc exhausted)' = 0 ] && grep -q '\"rule\":\"retry-exhausted\"' '$(J exhausted)' && '$F' status '$rc_dir/exhausted' | grep -q '^  blocked: 1\$' && ! '$F' status '$rc_dir/exhausted' | grep -q 'ready'"
  mkws two; running "$(J two)" t-1; rec "$(J two)" execution.started t-1 forge; rec "$(J two)" execution.retry t-1 forge; rec "$(J two)" task.ready t-1 forge; rec "$(J two)" task.running t-1 forge; rec "$(J two)" execution.started t-1 forge
  recover two
  check "two starts: the budget is not used up, ready" eval "'$F' status '$rc_dir/two' | grep -q '^  ready: 1\$' && ! grep -q retry-exhausted '$(J two)'"
  mkws finished; running "$(J finished)" t-1; rec "$(J finished)" execution.started t-1 forge; rec "$(J finished)" execution.finished t-1 worker
  recover finished
  check "finished: the claim was recorded and the move was not: verification, no refusal, never accepted" eval "[ '$(rc finished)' = 0 ] && grep -q '^recovered: 1\$' '$rc_dir/finished.out' && '$F' status '$rc_dir/finished' | grep -q '^  verification: 1\$' && ! grep -q 'refusal\\|accepted' '$(J finished)'"
  mkws cut; running "$(J cut)" t-1; rec "$(J cut)" execution.started t-1 forge; rec "$(J cut)" execution.lost t-1 forge
  recover cut
  check "cut short: execution.lost is not written twice" eval "[ \$(grep -c '\"kind\":\"execution.lost\"' '$(J cut)') -eq 1 ] && '$F' status '$rc_dir/cut' | grep -q '^  ready: 1\$'"

  # ---- 3. what recovery must not touch
  mkws nothing; running "$(J nothing)" t-1; rec "$(J nothing)" execution.started t-1 forge; rec "$(J nothing)" execution.finished t-1 worker; rec "$(J nothing)" task.verification t-1 forge
  cp "$(J nothing)" "$rc_dir/nothing.before"
  recover nothing
  check "nothing running: exit 0, 'recovered: 0', the journal is byte for byte what it was" eval "[ '$(rc nothing)' = 0 ] && grep -q '^recovered: 0\$' '$rc_dir/nothing.out' && cmp -s '$(J nothing)' '$rc_dir/nothing.before'"
  cp "$(J lost)" "$rc_dir/lost.after1"
  recover lost
  check "idempotent: a second recover finds nothing and writes nothing" eval "grep -q '^recovered: 0\$' '$rc_dir/lost.out' && cmp -s '$(J lost)' '$rc_dir/lost.after1'"
  check "lost: the records that were there are byte for byte the old ones, and recovery only added" eval "head -c \$(wc -c < '$rc_dir/lost.before') '$(J lost)' | cmp -s - '$rc_dir/lost.before' && [ \$(wc -c < '$(J lost)') -gt \$(wc -c < '$rc_dir/lost.before') ]"
  mkws torn; running "$(J torn)" t-1; rec "$(J torn)" execution.started t-1 forge; printf '{"v":1,"seq":6,"kind":"execution.fin' >> "$(J torn)"
  recover torn
  check "a torn tail is cut, then the task is settled: lost, ready, and the journal replays" eval "[ '$(rc torn)' = 0 ] && ! grep -q 'execution.fin\"' '$(J torn)' && grep -q execution-lost '$(J torn)' && '$F' status '$rc_dir/torn' | grep -q '^torn tail bytes: 0\$' && '$F' status '$rc_dir/torn' | grep -q '^  ready: 1\$'"
  mkws two_tasks; running "$(J two_tasks)" t-1; rec "$(J two_tasks)" execution.started t-1 forge; running "$(J two_tasks)" t-2
  recover two_tasks
  check "two tasks, one lost and one never started: both ready, 'recovered: 2'" eval "'$F' status '$rc_dir/two_tasks' | grep -q '^  ready: 2\$' && grep -q '^recovered: 2\$' '$rc_dir/two_tasks.out'"

  # ---- 4. refusals: nothing is written
  mkws corrupt; running "$(J corrupt)" t-1; rec "$(J corrupt)" execution.started t-1 forge; printf 'garbage\n' >> "$(J corrupt)"
  cp "$(J corrupt)" "$rc_dir/corrupt.before"
  recover corrupt
  check "a corrupt journal: exit 1, journal-corrupt named, no byte changed" eval "[ '$(rc corrupt)' = 1 ] && grep -q 'journal-corrupt' '$rc_dir/corrupt.err' && cmp -s '$(J corrupt)' '$rc_dir/corrupt.before'"
  mkws locked; running "$(J locked)" t-1; rec "$(J locked)" execution.started t-1 forge
  cp "$(J locked)" "$rc_dir/locked.before"
  flock -n "$rc_dir/locked/lock" sleep 6 & holder=$!
  sleep 1
  recover locked
  kill "$holder" 2> /dev/null; wait "$holder" 2> /dev/null
  check "a locked workspace: exit 3, workspace-locked named, no byte changed" eval "[ '$(rc locked)' = 3 ] && grep -q 'workspace-locked' '$rc_dir/locked.err' && cmp -s '$(J locked)' '$rc_dir/locked.before'"
  mkdir "$rc_dir/empty_dir"; recover empty_dir
  check "no journal there: exit 3" test "$(rc empty_dir)" = 3
  "$F" recover relative > /dev/null 2>&1; check "a relative directory: exit 2" test $? -eq 2
  "$F" recover "$rc_dir/../rc/lost" > /dev/null 2>&1; check "a .. directory: exit 2" test $? -eq 2
  "$F" recover > /dev/null 2>&1; check "no directory: exit 2" test $? -eq 2
  "$F" recover "$rc_dir/lost" extra > /dev/null 2>&1; check "an extra argument: exit 2" test $? -eq 2
  # the verbs that only look still only look
  check "forge status still looks only (a running task is still running before recover)" eval "mkdir '$rc_dir/look' && cp '$rc_dir/nothing.before' '$rc_dir/look/journal.jsonl' && '$F' status '$rc_dir/look' > /dev/null && cmp -s '$rc_dir/look/journal.jsonl' '$rc_dir/nothing.before'"
else
  echo "FAIL recover: did not build"
  fail=1
fi
exit "$fail"
