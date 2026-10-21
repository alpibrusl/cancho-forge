#!/bin/sh
# The gate runner against real git checkouts and real child processes (docs/self-hosting.md 3.1, worker-contract 10).
# workers/gate_runner.cho is built into a workers directory; tests/conformance/gate_runner.cho starts it beneath that
# directory once per way a run can end, against checkouts made here whose scripts/gate_cancho.sh each do one thing; the oracle
# for what the runner wrote is outside the programs (grep, cmp, pgrep on the files and the process table). Prints
# `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
# Used by scripts/gate.sh and by scripts/mutate_gate_runner.py (which runs it on a copy of the tree with one break).
# Usage: CANCHO=path/to/cancho scripts/check_gate_runner.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
# The runner is built into a workers directory made here; gate_runner (the conformance program) starts it beneath that
# directory once per way a run can end, against checkouts made here whose scripts/gate_cancho.sh each do one thing. The
# oracle for what the runner wrote is outside the programs: grep, cmp and pgrep on the files and the process table.
gr="$scratch/gr"; mkdir "$gr" "$gr/workers" || exit 1
git_in() { dir=$1; shift; git -C "$dir" -c user.email=forge@example.invalid -c user.name=forge -c commit.gpgsign=false "$@"; }
mkfix() { # name, body of scripts/gate_cancho.sh (the gate of the row of alpibrusl/cancho-hdl, which stands for any repository here)
  mkdir -p "$gr/$1/scripts" && printf '#!/bin/sh\n%s\n' "$2" > "$gr/$1/scripts/gate_cancho.sh" && chmod +x "$gr/$1/scripts/gate_cancho.sh" \
    && git init -q "$gr/$1" && git_in "$gr/$1" add -A && git_in "$gr/$1" commit -q -m fixture || exit 1
}
mkfix ws_pass 'echo hello gate; echo "path=$PATH"; echo "home=${HOME-unset}"; echo warn >&2; exit 0'
mkfix ws_fail 'echo failing; exit 3'
mkfix ws_hang 'sleep 79 & wait'
mkfix ws_noisy "head -c 9000000 /dev/zero | tr '\\0' x"
mkfix ws_sig 'kill -9 $PPID'
# the operator's environment (docs/self-hosting.md D7): a gate that prints what it sees; a command that is not found (127);
# a file that is not executable (126)
mkfix ws_env 'echo "path=$PATH"; echo "home=${HOME-unset}"; echo "cc=${CANCHO_CACHE-unset}"; echo "cargo=${CARGO_HOME-unset}"; echo "rustup=${RUSTUP_HOME-unset}"; echo "ld=${LD_PRELOAD-unset}"; exit 0'
mkfix ws_127 'forge_no_such_command_127'
mkfix ws_126 'printf x > data_not_executable; chmod 644 data_not_executable; ./data_not_executable'
# A checkout whose `git rev-parse HEAD` never returns (the HEAD file is a named pipe): the revision check must end at
# its own deadline and kill git's group.
mkdir -p "$gr/ws_headhang/.git" && mkfifo "$gr/ws_headhang/.git/HEAD" || exit 1
for e in pass fail sig mismatch unusable hang noisy refuse forge headhang env envnone 127 126; do mkdir "$gr/ev_$e" || exit 1; done
rev() { git -C "$gr/$1" rev-parse HEAD; }
# The runner's authority report is its review artefact (docs/authority-gate-runner.txt); a change that widens it changes
# that file in the same commit and says so in the message.
$C authority workers/gate_runner.cho $libs --std | sed -n '/^performs/,/^provably/p' | sed '$d' > "$gr/authority.txt"
if cmp -s "$gr/authority.txt" docs/authority-gate-runner.txt; then
  echo "ok   gate runner authority: the report is the checked-in one"
else
  echo "FAIL gate runner authority: differs from docs/authority-gate-runner.txt"; diff docs/authority-gate-runner.txt "$gr/authority.txt"; fail=1
fi
$C check workers/gate_runner.cho $libs --std || fail=1
$C check tests/conformance/gate_runner.cho tests/conformance/support.cho $libs --std || fail=1
if $C build workers/gate_runner.cho $libs --std -o "$gr/workers/gate_runner" \
  && $C build tests/conformance/gate_runner.cho tests/conformance/support.cho $libs --std -o "$gr/gate_runner_conf"; then
  "$gr/gate_runner_conf" "$gr/workers" "$gr" "$(rev ws_pass)" "$(rev ws_fail)" "$(rev ws_hang)" "$(rev ws_noisy)" "$(rev ws_sig)" "$(rev ws_env)" "$(rev ws_127)" "$(rev ws_126)" > "$gr/out" || fail=1
  cat "$gr/out"
  if grep -q '^FAIL ' "$gr/out"; then fail=1; fi
  oracle() { # name, command...
    name=$1; shift
    if "$@"; then echo "ok   gate runner oracle: $name"; else echo "FAIL gate runner oracle: $name"; fail=1; fi
  }
  printf 'hello gate\npath=/usr/local/bin:/usr/bin:/bin\nhome=unset\nwarn\n' > "$gr/want_pass_log"
  oracle "pass: the log is both streams, in order, and the gate's PATH is the fixed one" cmp -s "$gr/ev_pass/gate.log" "$gr/want_pass_log"
  oracle "pass: the report says pass, exit 0, at the revision" sh -c "grep -q '\"verdict\":\"pass\"' '$gr/ev_pass/report.json' && grep -q '\"exit_status\":0' '$gr/ev_pass/report.json' && grep -q '\"revision\":\"$(rev ws_pass)\"' '$gr/ev_pass/report.json'"
  oracle "fail: the report says fail and exit 3" sh -c "grep -q '\"verdict\":\"fail\"' '$gr/ev_fail/report.json' && grep -q '\"exit_status\":3' '$gr/ev_fail/report.json'"
  oracle "fail: the log has the gate's output" grep -q '^failing$' "$gr/ev_fail/gate.log"
  # `signal` is the number std.process reports (spike S7: 256 for KILL), not the POSIX number
  oracle "sig: fail, ended by a signal (KILL, as std.process numbers it: 256)" sh -c "grep -q '\"ending\":\"signaled\"' '$gr/ev_sig/report.json' && grep -q '\"signal\":256' '$gr/ev_sig/report.json' && grep -q '\"verdict\":\"fail\"' '$gr/ev_sig/report.json'"
  printf 'path=/opt/forge-x:/root/.cargo/bin:/usr/local/bin:/usr/bin:/bin\nhome=/work/home\ncc=/work/cache\ncargo=/work/cargo\nrustup=/work/rustup\nld=unset\n' > "$gr/want_env_log"
  oracle "env: the gate sees the operator's PATH in front of the fixed one and the four other variables, and nothing else" cmp -s "$gr/ev_env/gate.log" "$gr/want_env_log"
  printf 'path=/usr/local/bin:/usr/bin:/bin\nhome=unset\ncc=unset\ncargo=unset\nrustup=unset\nld=unset\n' > "$gr/want_envnone_log"
  oracle "env: an empty array is the fixed environment alone" cmp -s "$gr/ev_envnone/gate.log" "$gr/want_envnone_log"
  oracle "127: the report says incomplete, ending environment, exit 127, and no verdict of pass or fail" sh -c "grep -q '\"verdict\":\"incomplete\"' '$gr/ev_127/report.json' && grep -q '\"ending\":\"environment\"' '$gr/ev_127/report.json' && grep -q '\"exit_status\":127' '$gr/ev_127/report.json' && ! grep -q '\"verdict\":\"\(pass\|fail\)\"' '$gr/ev_127/report.json'"
  oracle "127: the log has the shell's complaint" grep -q 'forge_no_such_command_127' "$gr/ev_127/gate.log"
  oracle "126: the report says incomplete, ending environment, exit 126" sh -c "grep -q '\"verdict\":\"incomplete\"' '$gr/ev_126/report.json' && grep -q '\"ending\":\"environment\"' '$gr/ev_126/report.json' && grep -q '\"exit_status\":126' '$gr/ev_126/report.json'"
  oracle "env-invalid refusals ran nothing: no file written (ev_refuse is shared with the other refusals)" sh -c "[ -z \"\$(ls -A '$gr/ev_refuse')\" ]"
  oracle "headhang: nothing the revision check started is left running" sh -c ". scripts/procs.sh; ! leftover -f '[g]it rev-parse HEAD'"
  oracle "headhang: nothing was written" sh -c "[ -z \"\$(ls -A '$gr/ev_headhang')\" ]"
  oracle "hang: incomplete, ended by timeout" sh -c "grep -q '\"verdict\":\"incomplete\"' '$gr/ev_hang/report.json' && grep -q '\"ending\":\"timeout\"' '$gr/ev_hang/report.json'"
  oracle "hang: nothing the gate started is left running (spike S11)" sh -c ". scripts/procs.sh; ! leftover -f '^sleep 79\$' > /dev/null"
  oracle "noisy: incomplete, ended by output-overflow, the log is exactly the 8 MiB cap" sh -c "grep -q '\"ending\":\"output-overflow\"' '$gr/ev_noisy/report.json' && [ \$(wc -c < '$gr/ev_noisy/gate.log') -eq 8388608 ]"
  oracle "a revision mismatch ran nothing: no file written" sh -c "[ -z \"\$(ls -A '$gr/ev_mismatch')\" ]"
  oracle "a workspace that is not a checkout ran nothing: no file written" sh -c "[ -z \"\$(ls -A '$gr/ev_unusable')\" ]"
  oracle "five refusals ran nothing: no file written" sh -c "[ -z \"\$(ls -A '$gr/ev_refuse')\" ]"
  oracle "forge's path: the files are there and say pass" sh -c "grep -q '\"verdict\":\"pass\"' '$gr/ev_forge/report.json' && [ -s '$gr/ev_forge/gate.log' ]"
  oracle "no runner outlived the run (the runner this gate may be running under is an ancestor, not a leak: scripts/procs.sh)" sh -c ". scripts/procs.sh; ! leftover -x gate_runner > /dev/null"
else
  echo "gate runner: did not build"
  fail=1
fi
exit "$fail"
