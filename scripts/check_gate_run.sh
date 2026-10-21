#!/bin/sh
# The first self-hosted task, end to end (docs/self-hosting.md section 3.1; issue #18): `forge gate` takes the lock of a
# workspace, records the task, starts the gate runner (a real child process) on a real git checkout, recomputes the
# evidence, and journals what happened. The oracle is outside the programs: the exit status of the forge binary, its
# output, the journal read back by `forge status` and `forge history`, the files of the execution directory, `grep` on
# the journal and the process table. Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
# Used by scripts/gate.sh and by scripts/mutate_gate_run.py (which runs it on a copy of the tree with one break).
# Usage: CANCHO=path/to/cancho scripts/check_gate_run.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
gr="$scratch/gr"; mkdir "$gr" "$gr/workers" || exit 1
git_in() { dir=$1; shift; git -C "$dir" -c user.email=forge@example.invalid -c user.name=forge -c commit.gpgsign=false "$@"; }
mkfix() { # name, body of scripts/gate_cancho.sh (the gate of the row of alpibrusl/cancho-hdl, which stands for any repository here)
  mkdir -p "$gr/$1/scripts" && printf '#!/bin/sh\n%s\n' "$2" > "$gr/$1/scripts/gate_cancho.sh" && chmod +x "$gr/$1/scripts/gate_cancho.sh" \
    && git init -q "$gr/$1" && git_in "$gr/$1" add -A && git_in "$gr/$1" commit -q -m fixture || exit 1
}
mkfix ws_pass 'echo hello gate; exit 0'
mkfix ws_fail 'echo failing; exit 3'
mkfix ws_hang 'sleep 79 & wait'
# the operator's environment (docs/self-hosting.md D7): what the gate sees; a command not found (127); a file not executable (126)
mkfix ws_env 'echo "path=$PATH"; echo "home=${HOME-unset}"; echo "cc=${CANCHO_CACHE-unset}"; exit 0'
mkfix ws_127 'forge_no_such_command_127'
mkfix ws_126 'printf x > not_executable; chmod 644 not_executable; ./not_executable'
# the row of alpibrusl/cancho-forge: `scripts/gate.sh`, and it needs `cancho` and `git` on the PATH (the preflight of
# gate_task.gate_script); a gate that wraps its commands and exits 1 itself, as the real one does
mkdir -p "$gr/ws_forge/scripts" "$gr/stubbin" && printf '#!/bin/sh\necho forge gate ran\nexit 0\n' > "$gr/ws_forge/scripts/gate.sh" && chmod +x "$gr/ws_forge/scripts/gate.sh" \
  && git init -q "$gr/ws_forge" && git_in "$gr/ws_forge" add -A && git_in "$gr/ws_forge" commit -q -m fixture || exit 1
printf '#!/bin/sh\nexit 0\n' > "$gr/stubbin/cancho" && chmod +x "$gr/stubbin/cancho" || exit 1
rev() { git -C "$gr/$1" rev-parse HEAD; }
$C check src/*.cho --std || fail=1
$C check workers/gate_runner.cho $libs --std || fail=1
if $C build src/*.cho --std -o "$gr/forge" && $C build workers/gate_runner.cho $libs --std -o "$gr/workers/gate_runner"; then
  ok() { echo "ok   gate run: $1"; }
  bad() { echo "FAIL gate run: $1"; fail=1; }
  check() { # name, command...
    name=$1; shift
    if "$@"; then ok "$name"; else bad "$name"; fi
  }
  # a workspace: an empty directory for the journal and one for the evidence; the repository is `alpibrusl/cancho-hdl`,
  # whose row of the allow-list runs `scripts/gate_cancho.sh` in the checkout and needs only `git` (the fixtures above); the
  # row of `alpibrusl/cancho-forge` (`scripts/gate.sh`, needs `cancho` and `git`) is used for the checks of the tools below
  repo=alpibrusl/cancho-hdl
  mkws() { mkdir "$gr/$1" "$gr/$1/ev" || exit 1; }
  gate() { # ws, checkout name, revision, extra args...; runs `forge gate`, output in $gr/$ws.out, status in $gr/$ws.rc
    ws=$1; co=$2; revision=$3; shift 3
    "$gr/forge" gate "$gr/$ws" "$gr/workers" "$repo" "$revision" "$gr/$co" "$gr/$ws/ev" "$@" > "$gr/$ws.out" 2> "$gr/$ws.err"
    echo $? > "$gr/$ws.rc"
  }
  rc() { cat "$gr/$1.rc"; }
  state_is() { # ws, state name, how many tasks
    "$gr/forge" status "$gr/$1" > "$gr/$1.status" && grep -q "^  $2: $3\$" "$gr/$1.status"
  }

  # ---- a gate that passes: a claim, never an acceptance
  mkws pass; gate pass ws_pass "$(rev ws_pass)"
  check "pass: exit 0" test "$(rc pass)" = 0
  check "pass: the output names the task, the state and the claimed verdict" sh -c "grep -q '^task: gate-$(rev ws_pass | cut -c1-12)-1\$' '$gr/pass.out' && grep -q '^state: verification\$' '$gr/pass.out' && grep -q '^claimed verdict: pass\$' '$gr/pass.out'"
  check "pass: the journal replays to one task in verification, seven records" sh -c "'$gr/forge' status '$gr/pass' > '$gr/pass.status' && grep -q '^records: 7\$' '$gr/pass.status' && grep -q '^  verification: 1\$' '$gr/pass.status' && ! grep -qi accepted '$gr/pass.status'"
  check "pass: the verdict is in the journal, claimed, written by the worker" grep -q '"kind":"execution.finished".*"actor":"worker","basis":"claimed","verdict":"pass"' "$gr/pass/journal.jsonl"
  check "pass: the intent was written before the outcome" sh -c "[ \$(grep -n 'execution.started' '$gr/pass/journal.jsonl' | cut -d: -f1) -lt \$(grep -n 'execution.finished' '$gr/pass/journal.jsonl' | cut -d: -f1) ]"
  check "pass: the task has the same id in the journal as in the output, every record of it" sh -c "[ \$(grep -c '\"task\":\"gate-$(rev ws_pass | cut -c1-12)-1\"' '$gr/pass/journal.jsonl') -eq 7 ]"
  check "pass: the operator proposed and approved, Forge made it ready and running, the worker only claimed" sh -c "grep -q '\"kind\":\"task.proposed\".*\"actor\":\"human\"' '$gr/pass/journal.jsonl' && grep -q '\"kind\":\"task.approved\".*\"actor\":\"human\"' '$gr/pass/journal.jsonl' && grep -q '\"kind\":\"task.ready\".*\"actor\":\"forge\"' '$gr/pass/journal.jsonl' && grep -q '\"kind\":\"task.running\".*\"actor\":\"forge\"' '$gr/pass/journal.jsonl' && grep -q '\"kind\":\"task.verification\".*\"actor\":\"forge\"' '$gr/pass/journal.jsonl' && [ \$(grep -c '\"actor\":\"worker\"' '$gr/pass/journal.jsonl') -eq 1 ]"
  check "pass: no record accepts the task" sh -c "! grep -q 'task.accepted' '$gr/pass/journal.jsonl'"
  check "pass: the evidence is in the execution directory" sh -c "grep -q '^hello gate\$' '$gr/pass/ev/gate.log' && grep -q '\"verdict\":\"pass\"' '$gr/pass/ev/report.json'"
  check "pass: history shows the whole life of the task, in order" sh -c "'$gr/forge' history '$gr/pass' | cut -d' ' -f2 | tr '\\n' ' ' | grep -q '^kind=task.proposed kind=task.approved kind=task.ready kind=task.running kind=execution.started kind=execution.finished kind=task.verification \$'"
  check "pass: the lock is let go (a second run takes it)" sh -c "mkdir '$gr/pass/ev2' && '$gr/forge' gate '$gr/pass' '$gr/workers' $repo '$(rev ws_pass)' '$gr/ws_pass' '$gr/pass/ev2' > '$gr/pass2.out'; [ \$? -eq 0 ] && grep -q '^task: gate-.*-2\$' '$gr/pass2.out' && '$gr/forge' status '$gr/pass' | grep -q '^  verification: 2\$'"

  # ---- a gate that fails is the project telling the truth: still a claim, still verification
  mkws fail; gate fail ws_fail "$(rev ws_fail)"
  check "fail: exit 0, claimed verdict fail, state verification" sh -c "[ '$(rc fail)' = 0 ] && grep -q '^claimed verdict: fail\$' '$gr/fail.out' && grep -q '^state: verification\$' '$gr/fail.out'"
  check "fail: the gate's output is the log" grep -q '^failing$' "$gr/fail/ev/gate.log"

  # ---- a checkout at another revision: the runner refuses; the task is blocked and no claim is written
  mkws other; gate other ws_pass "0123456789abcdef0123456789abcdef01234567"
  check "other revision: exit 4, blocked, no claim in the journal" sh -c "[ '$(rc other)' = 4 ] && grep -q '^state: blocked\$' '$gr/other.out' && ! grep -q 'execution.finished' '$gr/other/journal.jsonl' && ! grep -q 'claimed verdict' '$gr/other.out'"

  # ---- a gate that never ends: the runner's own deadline; nothing it started is left
  mkws hang; gate hang ws_hang "$(rev ws_hang)" 2000
  check "hang: exit 4, no claim" sh -c "[ '$(rc hang)' = 4 ] && ! grep -q 'claimed verdict' '$gr/hang.out'"
  check "hang: nothing the gate started is left running" sh -c ". scripts/procs.sh; ! leftover -f '^sleep 79\$' > /dev/null"

  # ---- the operator's environment: trailing NAME=value arguments, after the optional timeout
  mkws env; gate env ws_env "$(rev ws_env)" 20000 PATH=/opt/forge-x HOME=/work/home CANCHO_CACHE=/work/cache
  check "env: exit 0, the gate saw the operator's PATH in front of the fixed one, HOME and CANCHO_CACHE" sh -c "[ '$(rc env)' = 0 ] && grep -q '^claimed verdict: pass\$' '$gr/env.out' && grep -q '^path=/opt/forge-x:/usr/local/bin:/usr/bin:/bin\$' '$gr/env/ev/gate.log' && grep -q '^home=/work/home\$' '$gr/env/ev/gate.log' && grep -q '^cc=/work/cache\$' '$gr/env/ev/gate.log'"
  mkws envnt; gate envnt ws_env "$(rev ws_env)" HOME=/work/home2
  check "env without a timeout: the first argument is already an entry; the default timeout applies" sh -c "[ '$(rc envnt)' = 0 ] && grep -q '^home=/work/home2\$' '$gr/envnt/ev/gate.log' && grep -q '^cc=unset\$' '$gr/envnt/ev/gate.log'"
  mkws envnone; gate envnone ws_env "$(rev ws_env)" 20000
  check "no env: the gate sees the fixed PATH alone and no HOME" sh -c "[ '$(rc envnone)' = 0 ] && grep -q '^path=/usr/local/bin:/usr/bin:/bin\$' '$gr/envnone/ev/gate.log' && grep -q '^home=unset\$' '$gr/envnone/ev/gate.log'"
  mkws envbad; gate envbad ws_env "$(rev ws_env)" 20000 LD_PRELOAD=/x/y.so
  check "env-invalid (a name not on the list): exit 1, journalled with its tag, the task stays approved, nothing ran" sh -c "[ '$(rc envbad)' = 1 ] && grep -q '^refused: env-invalid\$' '$gr/envbad.out' && grep -q '^state: approved\$' '$gr/envbad.out' && grep -q '\"kind\":\"refusal\".*\"rule\":\"env-invalid\"' '$gr/envbad/journal.jsonl' && ! grep -q 'execution' '$gr/envbad/journal.jsonl' && [ -z \"\$(ls -A '$gr/envbad/ev')\" ]"
  mkws envrel; gate envrel ws_env "$(rev ws_env)" HOME=relative/home
  check "env-invalid (a relative path): exit 1" sh -c "[ '$(rc envrel)' = 1 ] && grep -q '^refused: env-invalid\$' '$gr/envrel.out'"
  mkws envtwice; gate envtwice ws_env "$(rev ws_env)" HOME=/a HOME=/b
  check "env-invalid (a name twice): exit 1" sh -c "[ '$(rc envtwice)' = 1 ] && grep -q '^refused: env-invalid\$' '$gr/envtwice.out'"
  mkws envmany; gate envmany ws_env "$(rev ws_env)" HOME=/a PATH=/b CANCHO_CACHE=/c CARGO_HOME=/d RUSTUP_HOME=/e HOME=/f
  check "env-invalid (six entries): exit 1" sh -c "[ '$(rc envmany)' = 1 ] && grep -q '^refused: env-invalid\$' '$gr/envmany.out'"
  mkws envfirst; gate envfirst ws_env "not-a-revision" 20000 LD_PRELOAD=/x
  check "a task with two faults is refused for the first: revision-invalid before env-invalid" sh -c "[ '$(rc envfirst)' = 1 ] && grep -q '^refused: revision-invalid\$' '$gr/envfirst.out'"

  # ---- the environment is the operator's, not the task's: nothing a task names can reach it
  check "the task input has no env: the request Forge builds takes the environment from the command line only (grants.env)" sh -c "! grep -n 'env' src/gate_run.cho | grep -q 'task\.input'"

  # ---- 127 and 126 are the environment failing, not the project: no claim, the task is not moved to verification
  mkws e127; gate e127 ws_127 "$(rev ws_127)" 20000
  check "127: exit 4, no claimed verdict, no execution.finished, not in verification" sh -c "[ '$(rc e127)' = 4 ] && ! grep -q 'claimed verdict' '$gr/e127.out' && ! grep -q 'execution.finished' '$gr/e127/journal.jsonl' && ! grep -q '^state: verification\$' '$gr/e127.out'"
  check "127: the evidence is there for the operator: the log names the command, the report says incomplete" sh -c "grep -q 'forge_no_such_command_127' '$gr/e127/ev/gate.log' && grep -q '\"verdict\":\"incomplete\"' '$gr/e127/ev/report.json'"
  mkws e126; gate e126 ws_126 "$(rev ws_126)" 20000
  check "126: exit 4, no claimed verdict, not in verification" sh -c "[ '$(rc e126)' = 4 ] && ! grep -q 'claimed verdict' '$gr/e126.out' && ! grep -q '^state: verification\$' '$gr/e126.out'"

  # ---- a tool the gate cannot run without (gate_task.required_tools): its absence is the environment's, even when the gate
  # itself would have ended with 1. Only where `cancho` is really not on the fixed PATH of the gate.
  mkws pre; mkws prefound
  if [ -z "$(PATH=/usr/local/bin:/usr/bin:/bin command -v cancho)" ]; then
    "$gr/forge" gate "$gr/pre" "$gr/workers" alpibrusl/cancho-forge "$(rev ws_forge)" "$gr/ws_forge" "$gr/pre/ev" 20000 > "$gr/pre.out" 2>&1; echo $? > "$gr/pre.rc"
    check "a missing required tool (cancho): exit 4, no claimed verdict, the task is not in verification" sh -c "[ '$(rc pre)' = 4 ] && ! grep -q 'claimed verdict' '$gr/pre.out' && ! grep -q '^state: verification\$' '$gr/pre.out' && ! grep -q 'execution.finished' '$gr/pre/journal.jsonl'"
    check "a missing required tool: the log names it, and the report says incomplete, ending environment, exit 127" sh -c "grep -q 'gate-environment: the gate needs cancho, which is not on PATH' '$gr/pre/ev/gate.log' && grep -q '\"verdict\":\"incomplete\"' '$gr/pre/ev/report.json' && grep -q '\"ending\":\"environment\"' '$gr/pre/ev/report.json' && grep -q '\"exit_status\":127' '$gr/pre/ev/report.json' && ! grep -q 'forge gate ran' '$gr/pre/ev/gate.log'"
  else
    echo "skip gate run: a missing required tool (a cancho is on the fixed PATH of this machine)"
  fi
  "$gr/forge" gate "$gr/prefound" "$gr/workers" alpibrusl/cancho-forge "$(rev ws_forge)" "$gr/ws_forge" "$gr/prefound/ev" 20000 PATH="$gr/stubbin" > "$gr/prefound.out" 2>&1; echo $? > "$gr/prefound.rc"
  check "the same task with the operator's PATH holding cancho: the gate runs and passes" sh -c "[ '$(rc prefound)' = 0 ] && grep -q '^claimed verdict: pass\$' '$gr/prefound.out' && grep -q '^forge gate ran\$' '$gr/prefound/ev/gate.log'"

  # ---- refusals: the task is approved, the rule tag is journalled, nothing ran
  mkws scope; "$gr/forge" gate "$gr/scope" "$gr/workers" someone/else "$(rev ws_pass)" "$gr/ws_pass" "$gr/scope/ev" > "$gr/scope.out" 2>&1; echo $? > "$gr/scope.rc"
  check "scope-invalid: exit 1, approved, journalled with its tag, nothing ran" sh -c "[ '$(rc scope)' = 1 ] && grep -q '^refused: scope-invalid\$' '$gr/scope.out' && grep -q '^state: approved\$' '$gr/scope.out' && grep -q '\"kind\":\"refusal\".*\"rule\":\"scope-invalid\"' '$gr/scope/journal.jsonl' && ! grep -q 'execution' '$gr/scope/journal.jsonl' && [ -z \"\$(ls -A '$gr/scope/ev')\" ]"
  mkws rev; gate rev ws_pass "not-a-revision"
  check "revision-invalid: exit 1, journalled with its tag" sh -c "[ '$(rc rev)' = 1 ] && grep -q '^refused: revision-invalid\$' '$gr/rev.out' && grep -q 'gate-x-1' '$gr/rev.out' && grep -q '\"rule\":\"revision-invalid\"' '$gr/rev/journal.jsonl'"
  mkws lim; gate lim ws_pass "$(rev ws_pass)" 1000
  check "limits-invalid: exit 1, journalled with its tag" sh -c "[ '$(rc lim)' = 1 ] && grep -q '^refused: limits-invalid\$' '$gr/lim.out' && grep -q '\"rule\":\"limits-invalid\"' '$gr/lim/journal.jsonl'"
  mkws chk; "$gr/forge" gate "$gr/chk" "$gr/workers" $repo "$(rev ws_pass)" "relative/checkout" "$gr/chk/ev" > "$gr/chk.out" 2>&1; echo $? > "$gr/chk.rc"
  check "path-invalid: a checkout that is not an absolute path is refused" sh -c "[ '$(rc chk)' = 1 ] && grep -q '^refused: path-invalid\$' '$gr/chk.out'"

  # ---- a runner that is not there
  mkws noworker; mkdir "$gr/empty"
  "$gr/forge" gate "$gr/noworker" "$gr/empty" $repo "$(rev ws_pass)" "$gr/ws_pass" "$gr/noworker/ev" > "$gr/noworker.out" 2>&1; echo $? > "$gr/noworker.rc"
  check "no runner: exit 4, worker-unavailable journalled, the task is blocked" sh -c "[ '$(rc noworker)' = 4 ] && grep -q '^refusal: worker-unavailable\$' '$gr/noworker.out' && grep -q '^state: blocked\$' '$gr/noworker.out' && grep -q '\"rule\":\"worker-unavailable\"' '$gr/noworker/journal.jsonl'"

  # ---- the workspace is locked by another process
  if command -v flock > /dev/null; then
    mkws locked
    flock -n "$gr/locked/lock" sleep 6 & holder=$!
    sleep 1
    "$gr/forge" gate "$gr/locked" "$gr/workers" $repo "$(rev ws_pass)" "$gr/ws_pass" "$gr/locked/ev" > "$gr/locked.out" 2> "$gr/locked.err"; echo $? > "$gr/locked.rc"
    check "locked: exit 3 and workspace-locked, nothing written" sh -c "[ '$(rc locked)' = 3 ] && grep -q 'workspace-locked' '$gr/locked.err' && [ ! -e '$gr/locked/journal.jsonl' ]"
    kill "$holder" 2> /dev/null; wait "$holder" 2> /dev/null
  else
    echo "skip gate run: locked (no flock)"
  fi

  # ---- usage and paths
  "$gr/forge" gate > /dev/null 2>&1; check "usage: no arguments is exit 2" test $? = 2
  "$gr/forge" gate "$gr/pass" "$gr/workers" $repo > /dev/null 2>&1; check "usage: too few arguments is exit 2" test $? = 2
  "$gr/forge" gate relative "$gr/workers" $repo "$(rev ws_pass)" "$gr/ws_pass" "$gr/pass/ev" > /dev/null 2>&1; check "usage: a relative workspace is exit 2" test $? = 2
  "$gr/forge" gate "$gr/pass" "$gr/workers/../workers" $repo "$(rev ws_pass)" "$gr/ws_pass" "$gr/pass/ev" > /dev/null 2>&1; check "usage: a workers directory with .. is exit 2" test $? = 2
  "$gr/forge" gate "$gr/pass" "$gr/workers" $repo "$(rev ws_pass)" "$gr/ws_pass" "$gr/pass/ev" 12x > /dev/null 2>&1; check "usage: a timeout that is not a number is exit 2" test $? = 2
  "$gr/forge" gate "$gr/pass" "$gr/workers" $repo "$(rev ws_pass)" "$gr/ws_pass" "$gr/pass/ev" 20000 HOME > /dev/null 2>&1; check "usage: an environment argument with no = is exit 2" test $? = 2
  "$gr/forge" gate "$gr/pass" "$gr/workers" $repo "$(rev ws_pass)" "$gr/ws_pass" "$gr/pass/ev" =/x > /dev/null 2>&1; check "usage: an environment argument with no name is exit 2" test $? = 2
  "$gr/forge" gate "$gr/nowhere" "$gr/workers" $repo "$(rev ws_pass)" "$gr/ws_pass" "$gr/pass/ev" > /dev/null 2>&1; check "a workspace that is not there is exit 3" test $? = 3
  check "no runner outlived the run (the runner this gate may be running under is an ancestor, not a leak: scripts/procs.sh)" sh -c ". scripts/procs.sh; ! leftover -x gate_runner > /dev/null"
else
  echo "gate run: did not build"
  fail=1
fi
exit "$fail"
