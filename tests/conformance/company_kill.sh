#!/bin/sh
# Kill and resume of `forge company run` (docs/superpowers/specs/2026-10-27-forge-company-layer-design.md, sections 7 and 10; task 9).
# The program under test is the forge binary; this script is the oracle only. It starts a REAL `forge company run` in a process
# group of its own (setsid), against a company of three steps: lib (builder: the Cancho Code adapter over the stand-in build tool in
# mode `killable`, which spends a call, starts a grandchild and waits) -> qa (qa: the gate runner on a real git checkout) -> ship
# (product, gate `ship`). It waits until the step is running (a marker file the stub writes), kills the whole process group, and
# then asserts, from outside the program:
#   (1) no process this company started is left: every process whose command line or working directory names the scratch
#       directory, less this script's own ancestors and zombies (read from /proc; no `pgrep -f` on long names, see
#       scripts/check_procs.sh), and the very pids the stubs recorded (pid AND command line, so a reused pid is not mistaken);
#   (2) the lock of the company directory is free: `flock -n` takes it, and the next run is not refused workspace-locked;
#   (3) the journal is intact: `forge company status` exits 0 (a torn tail is appended to make sure it is handled);
#   (4) run again to completion (the stub fast now): every step accepted exactly once, the killed step admitted twice, every
#       other step once, and no company.step.accepted duplicated;
#   (6) the spend: what the killed build spent (a usage.jsonl line written before the kill) is recorded by a later run, once:
#       the input tokens of the spend records sum to those of usage.jsonl.
# The kills: (K) SIGKILL of the group in the middle of the build; (T) SIGTERM of the group in the middle of the build; (C) SIGKILL
# of the group in the middle of the step's check (the build has ended and its spend is recorded, the step is not accepted: this
# is also "between the step finishing and its acceptance"); (CT) SIGTERM of the group in the middle of the check.
# What may be left between the kill and the next run (docs/architecture.md section 7, `stopped`, and the runner's header): after
# SIGKILL mid-build, the adapter's supervisor and the build it started run on, in sessions of their own, until the next run
# cancels them; this script asserts that they are there (so the next run's reaping is what is tested) and that the next run
# leaves nothing. Every other kill leaves nothing once the run is gone (asserted before the next run starts).
# Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
# Usage: CANCHO=path/to/cancho tests/conformance/company_kill.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../.." || exit 1
. scripts/procs.sh
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
w="$scratch/ck"
mkdir "$w" "$w/workers" "$w/tools" || exit 1
cp scripts/standin_cancho_build.sh "$w/tools/cancho-build" && chmod +x "$w/tools/cancho-build" || exit 1
$C build src/*.cho --std -o "$w/forge" || { echo "FAIL company kill: forge did not build"; exit 1; }
for p in workers/*.cho; do
  n=$(basename "$p" .cho)
  $C build "$p" $libs --std -o "$w/workers/$n" || { echo "FAIL company kill: $n did not build"; exit 1; }
done
F="$w/forge"
ok() { echo "ok   company kill: $1"; }
bad() { echo "FAIL company kill: $1"; fail=1; }
check() { # name, command...
  name=$1; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

git_in() { d=$1; shift; git -C "$d" -c user.email=forge@example.invalid -c user.name=forge -c commit.gpgsign=false "$@"; }
mkdir -p "$w/checkout/scripts" && printf '#!/bin/sh\necho hello gate\nexit 0\n' > "$w/checkout/scripts/gate_cancho.sh" && chmod +x "$w/checkout/scripts/gate_cancho.sh" \
  && git init -q "$w/checkout" && git_in "$w/checkout" add -A && git_in "$w/checkout" commit -q -m fixture || exit 1
rev=$(git -C "$w/checkout" rev-parse HEAD)
cat > "$w/operator.json" <<EOF
{"workers":"$w/workers","tools":"$w/tools","checker":"/opt/cancho/bin/cancho","agent":"stand-in-agent","check_timeout_ms":60000,"build_timeout_ms":600000,"gate_timeout_ms":60000,
 "gates":{"qa":{"repo":"alpibrusl/cancho-hdl","revision":"$rev","checkout":"$w/checkout"}}}
EOF
op="$w/operator.json"

# The processes a company left: every live, non-zombie process (not an ancestor of this script) whose command line or working
# directory names the scratch directory. One pid per line; succeeds when there is one.
strays() {
  _anc=$(ancestors)
  { grep -lF "$w/" /proc/[0-9]*/cmdline 2> /dev/null | cut -d/ -f3; find /proc/[0-9]*/cwd -maxdepth 0 -lname "$w/*" 2> /dev/null | cut -d/ -f3; } | sort -u | while read -r _p; do
    if echo "$_anc" | grep -qx "$_p"; then continue; fi
    _st=$(sed 's/^.*) //' "/proc/$_p/stat" 2> /dev/null | cut -c1)
    if [ -n "$_st" ] && [ "$_st" != Z ]; then echo "$_p"; fi
  done | grep .
}
# Is the pid alive and running a command line that contains the text? (A pid reused by another program is not it.)
alive_as() { # pid, text
  [ -r "/proc/$1/cmdline" ] || return 1
  _st=$(sed 's/^.*) //' "/proc/$1/stat" 2> /dev/null | cut -c1)
  [ -n "$_st" ] && [ "$_st" != Z ] && tr '\0' ' ' < "/proc/$1/cmdline" 2> /dev/null | grep -qF "$2"
}
# None of the pids in the file (two per line: the stub and its grandchild) is alive as what it was.
recorded_gone() { # file
  [ -f "$1" ] || return 0
  for _p in $(cat "$1"); do
    if alive_as "$_p" "cancho-build" || alive_as "$_p" "sleep 9" || alive_as "$_p" "audit_wait"; then return 1; fi
  done
  return 0
}
# Wait (up to 10 s) until nothing is left; succeed if so.
settles() {
  _n=0
  while [ "$_n" -lt 100 ] && strays > /dev/null; do sleep 0.1; _n=$((_n + 1)); done
  ! strays > /dev/null
}
show_strays() { for _p in $(strays); do printf '     left: %s %s (cwd %s)\n' "$_p" "$(tr '\0' ' ' < "/proc/$_p/cmdline" 2> /dev/null)" "$(readlink "/proc/$_p/cwd" 2> /dev/null)"; done; }
wait_for() { # file: up to 30 s
  _n=0
  while [ "$_n" -lt 300 ] && [ ! -e "$1" ]; do sleep 0.1; _n=$((_n + 1)); done
  [ -e "$1" ]
}
# A `forge company run` in a process group of its own, in the background: its pid is the group's id (set in $runpid).
start() { # company, tag
  setsid "$F" company run "$w/$1" "$op" > "$w/$1.$2.out" 2> "$w/$1.$2.err" &
  runpid=$!
}
# Kill the group and wait for the forge process to be gone (up to 30 s); its exit status in $w/<co>.<tag>.rc.
kill_group() { # company, tag, signal
  kill -s "$3" -- "-$runpid" 2> /dev/null
  _n=0
  while [ "$_n" -lt 300 ] && kill -0 "$runpid" 2> /dev/null && [ "$(sed 's/^.*) //' "/proc/$runpid/stat" 2> /dev/null | cut -c1)" != Z ]; do sleep 0.1; _n=$((_n + 1)); done
  if [ "$_n" -ge 300 ]; then bad "$1: forge did not end within 30 s of SIG$3 (killed now)"; kill -s KILL -- "-$runpid" 2> /dev/null; fi
  wait "$runpid"; echo $? > "$w/$1.$2.rc"
}
run() { # company, tag: a run in the foreground
  "$F" company run "$w/$1" "$op" > "$w/$1.$2.out" 2> "$w/$1.$2.err"; echo $? > "$w/$1.$2.rc"
}
rc() { cat "$w/$1.$2.rc"; }
kinds() { grep -c "\"kind\":\"$2\",\"task\":\"$3\"" "$w/$1/company.journal"; }
# The sum of a field over the lines of a file that have it.
total() { # file, field
  sed -n "s/.*\"$2\":\\([0-9]*\\).*/\\1/p" "$1" | awk '{ s += $1 } END { print s + 0 }'
}

mkco() { # name
  co="$w/$1"
  mkdir "$co" || exit 1
  printf '{"id":"co","mission":"m","model":{"provider":"stand","name":"m1"},"budget":{"input":100000,"output":100000,"cache_write":100000,"cache_read":100000,"max_cost":10,"price_table":"prices.json"},"human_gates":["ship"],"roles":["builder","qa","product"],"steps":[{"id":"lib","role":"builder","task_type":"project.build","needs":[],"input":"killable","check":"audit_wait.sh"},{"id":"qa","role":"qa","task_type":"repo.gate","needs":["lib"],"input":"gate","check":"audit_report.sh"},{"id":"ship","role":"product","task_type":"none","needs":["qa"],"input":"ship it","gate":"ship"}]}' > "$co/company.json"
  printf '{"_note":"test","stand":{"m1":{"in":1.0,"cache_write":1.0,"cache_read":1.0,"out":1.0}}}' > "$co/prices.json"
  # The check of lib: with `fastcheck` in the execution directory it passes at once; without, it records its pid and that of a
  # grandchild, says it is checking and waits for a `release_check` that never comes.
  printf '#!/bin/sh\nif [ ! -e "$2/fastcheck" ]; then\n  sleep 96 &\n  printf "%%s %%s\\n" "$$" "$!" >> "$2/check.pids"\n  : > "$2/checking"\n  while [ ! -e "$2/release_check" ]; do sleep 0.1; done\nfi\necho "TOTAL 2/2"\n' > "$co/audit_wait.sh"
  printf '#!/bin/sh\ngrep -q verdict "$1" && echo "TOTAL 1/1"\n' > "$co/audit_report.sh"
  chmod +x "$co"/audit_*.sh
  mkdir -p "$co/steps/lib/ev" "$co/steps/qa/ev" || exit 1
}

# After the kill: the lock, the journal (with a torn tail), then the rest of the company to the end, and the counts.
after_kill() { # company, label, the input tokens the builds of lib spend in all
  co="$w/$1"
  check "$2: the lock of the company directory is free after the kill" flock -n "$co/lock" true
  printf '{"v":1,"seq":' >> "$co/company.journal"
  check "$2: the journal is intact: company status exits 0 with a torn tail appended" sh -c "'$F' company status '$co' > '$w/$1.status' 2>&1"
  : > "$co/steps/lib/ev/fast"
  : > "$co/steps/lib/ev/fastcheck"
  run "$1" 2
  check "$2: the next run is not refused workspace-locked and reaches the gate (exit 10)" sh -c "! grep -qx 'refusal: workspace-locked' '$w/$1.2.out' && [ '$(rc "$1" 2)' = 10 ] && grep -qx 'gate: ship' '$w/$1.2.out'"
  if ! settles; then show_strays; fi
  check "$2: after the next run nothing the company started is left (a scan of /proc)" settles
  check "$2: after the next run the pids the stubs recorded are gone (pid and command line)" both_gone "$co"
  "$F" company decide "$co" ship approved "go" > /dev/null
  run "$1" 3
  check "$2: run again to completion, exit 0" sh -c "[ '$(rc "$1" 3)' = 0 ]"
  check "$2: every step accepted exactly once, lib admitted twice, qa and ship once" sh -c "[ $(kinds "$1" company.step.accepted lib) -eq 1 ] && [ $(kinds "$1" company.step.accepted qa) -eq 1 ] && [ $(kinds "$1" company.step.accepted ship) -eq 1 ] && [ $(kinds "$1" company.step.admitted lib) -eq 2 ] && [ $(kinds "$1" company.step.admitted qa) -eq 1 ] && [ $(kinds "$1" company.step.admitted ship) -eq 1 ]"
  check "$2: no company.step.accepted duplicated" sh -c "[ \$(grep -c '\"kind\":\"company.step.accepted\"' '$co/company.journal') -eq 3 ]"
  used=$(total "$co/steps/lib/ev/usage.jsonl" in)
  recorded=$(grep '"kind":"company.spend.recorded"' "$co/company.journal" | sed -n 's/.*"input":\([0-9]*\).*/\1/p' | awk '{ s += $1 } END { print s + 0 }')
  check "$2: the spend of the killed build is recorded once (usage.jsonl input $used, recorded $recorded)" sh -c "[ '$used' = $3 ] && [ '$recorded' = $3 ]"
  run "$1" 4
  check "$2: a run after that admits nothing" sh -c "[ '$(rc "$1" 4)' = 0 ] && [ \$(grep -c company.step.admitted '$co/company.journal') -eq 4 ]"
}
both_gone() { recorded_gone "$1/steps/lib/ev/pids.txt" && recorded_gone "$1/steps/lib/ev/check.pids"; }
# The pids recorded in the file, one at least, are all alive as what they were.
recorded_alive() { # file
  [ -s "$1" ] || return 1
  for _p in $(cat "$1"); do
    if ! alive_as "$_p" "cancho-build" && ! alive_as "$_p" "sleep 9" && ! alive_as "$_p" "audit_wait"; then return 1; fi
  done
  return 0
}
accepted_run() { # company: wait (up to 30 s) until lib's own journal holds the accepted run
  _n=0
  while [ "$_n" -lt 300 ] && ! grep -q '"kind":"execution.accepted"' "$w/$1/steps/lib/journal.jsonl" 2> /dev/null; do sleep 0.1; _n=$((_n + 1)); done
  grep -q '"kind":"execution.accepted"' "$w/$1/steps/lib/journal.jsonl" 2> /dev/null
}

# ---- (K) SIGKILL of the group in the middle of the build
mkco kbuild
start kbuild 1
if wait_for "$w/kbuild/steps/lib/ev/building" && accepted_run kbuild; then ok "K: the build is running (the stub says so) and lib's journal holds the accepted run"; else bad "K: the build never started"; fi
kill_group kbuild 1 KILL
check "K: the forge process is gone, killed by the signal (status 137)" [ "$(rc kbuild 1)" = 137 ]
sleep 0.5
check "K: before the next run the killed build and its grandchild still run (sessions of their own: the next run must reap them)" recorded_alive "$w/kbuild/steps/lib/ev/pids.txt"
after_kill kbuild K 1100
check "K: the next run asked the killed build to stop before it started lib again (reaped: build-1), and lib's own journal settles it cancelled" sh -c "grep -qx 'reaped: build-1' '$w/kbuild.2.out' && grep -q '\"kind\":\"task.cancelled\",\"task\":\"build-1\"' '$w/kbuild/steps/lib/journal.jsonl'"

# ---- (T) SIGTERM of the group in the middle of the build: forge stops the build before it exits
mkco tbuild
start tbuild 1
wait_for "$w/tbuild/steps/lib/ev/building" && accepted_run tbuild || bad "T: the build never started"
kill_group tbuild 1 TERM
check "T: forge stopped on the signal and said so (exit 16, stopped), the build cancelled through its worker" sh -c "[ '$(rc tbuild 1)' = 16 ] && grep -qx 'stopped: signal' '$w/tbuild.1.out' && grep -qx 'state: cancelled' '$w/tbuild.1.out'"
check "T: what the build spent before the signal is recorded by the stopped run itself" grep -q '"kind":"company.spend.recorded","task":"lib","input":600' "$w/tbuild/company.journal"
if ! settles; then show_strays; fi
check "T: once forge is gone nothing the company started is left, BEFORE any next run (a scan of /proc)" settles
check "T: the pids the stub recorded are gone" both_gone "$w/tbuild"
after_kill tbuild T 1100

# ---- (C) SIGKILL of the group in the middle of lib's check: the build ended, its spend is recorded, lib is not accepted
mkco kcheck
: > "$w/kcheck/steps/lib/ev/fast"
start kcheck 1
wait_for "$w/kcheck/steps/lib/ev/checking" || bad "C: the check never started"
check "C: when the check runs the build's spend is recorded and lib is not accepted" sh -c "grep -q '\"kind\":\"company.spend.recorded\",\"task\":\"lib\"' '$w/kcheck/company.journal' && ! grep -q '\"kind\":\"company.step.accepted\"' '$w/kcheck/company.journal'"
kill_group kcheck 1 KILL
check "C: the forge process is gone, killed (status 137)" [ "$(rc kcheck 1)" = 137 ]
if ! settles; then show_strays; fi
check "C: once forge is gone nothing is left, the check and its grandchild included, BEFORE any next run" settles
check "C: the pids the check recorded are gone" both_gone "$w/kcheck"
after_kill kcheck C 1000

# ---- (CT) SIGTERM of the group in the middle of lib's check
mkco tcheck
: > "$w/tcheck/steps/lib/ev/fast"
start tcheck 1
wait_for "$w/tcheck/steps/lib/ev/checking" || bad "CT: the check never started"
kill_group tcheck 1 TERM
if ! settles; then show_strays; fi
check "CT: once forge is gone nothing is left, the check and its grandchild included, BEFORE any next run" settles
check "CT: the pids the check recorded are gone" both_gone "$w/tcheck"
after_kill tcheck CT 1000

# ---- (E) SIGTERM of the group while `execute` itself runs: the adapter has started its supervisor and the build, and has not yet
# answered `accepted` (fix round 1). The adapter in this workers directory is a fixture around the real one: while the file
# `hold_execute` is there, the first call that is not the supervisor's runs the real adapter, keeps its answer and then holds,
# so Forge is still waiting in `execute` when the signal comes. Forge must cancel the run it never heard accepted.
mkdir "$w/eworkers" || exit 1
cp "$w/workers/cancho_code" "$w/eworkers/cancho_code.real" && cp "$w/workers/check_guard" "$w/workers/gate_runner" "$w/eworkers/" || exit 1
cat > "$w/eworkers/cancho_code" <<'WRAP'
#!/bin/sh
# oracle fixture: the real Cancho Code adapter, the answer of one `execute` held back (tests/conformance/company_kill.sh, case E)
pre=$(dd bs=1 count=9 2> /dev/null)
if [ "$pre" != supervise ] && [ -e ./hold_execute ]; then
  rm -f ./hold_execute
  { printf '%s' "$pre"; cat; } | ./cancho_code.real > ./held_answer
  : > ./execute_held
  while :; do sleep 0.1; done
fi
{ printf '%s' "$pre"; cat; } | ./cancho_code.real
WRAP
chmod +x "$w/eworkers/cancho_code"
sed "s|\"workers\":\"$w/workers\"|\"workers\":\"$w/eworkers\"|" "$w/operator.json" > "$w/eoperator.json"
op="$w/eoperator.json"
mkco ebuild
: > "$w/eworkers/hold_execute"
start ebuild 1
if wait_for "$w/eworkers/execute_held" && wait_for "$w/ebuild/steps/lib/ev/building"; then ok "E: the build runs and Forge is still in execute (its accepted answer held back)"; else bad "E: the held execute never came"; fi
check "E: lib's journal has no accepted run yet" sh -c "! grep -q '\"kind\":\"execution.accepted\"' '$w/ebuild/steps/lib/journal.jsonl'"
kill_group ebuild 1 TERM
check "E: forge stopped on the signal and said so (exit 16, stopped: signal)" sh -c "[ '$(rc ebuild 1)' = 16 ] && grep -qx 'stopped: signal' '$w/ebuild.1.out'"
if ! settles; then show_strays; fi
check "E: once forge is gone nothing is left, the supervisor and build included, BEFORE any next run" settles
check "E: the pids the stub recorded are gone" both_gone "$w/ebuild"
after_kill ebuild E 1100
op="$w/operator.json"

# Whatever this script could not see reaped is killed here, so that a FAIL leaves nothing behind.
for p in $(strays); do kill -9 "$p" 2> /dev/null; done
exit $fail
