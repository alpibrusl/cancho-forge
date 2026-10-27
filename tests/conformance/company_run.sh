#!/bin/sh
# `forge company run` end to end (docs/superpowers/specs/2026-10-27-forge-company-layer-design.md, sections 4.3, 7 and 10; task 8b).
# The program under test is the forge binary; this script is the oracle only. Every step runs a REAL worker: a builder step the
# Cancho Code adapter (workers/cancho_code.cho) over the stand-in build tool (scripts/standin_cancho_build.sh, whose mode is the
# first line of the brief), a qa step the gate runner (workers/gate_runner.cho) on a real git checkout. Each step's check is a
# shell script in the company directory that prints a TOTAL line, Forge runs it and reads the score. The oracle reads only what is
# outside the program: exit status, stdout, `forge company status`, and `grep -c` on company.journal.
#
# The cases: (1) the lying worker of spec 7, a build that says `done` and an audit that scores 1/2: check-failed, and NO
# company.step.accepted; (2) the good path builder -> qa -> human-gated product: the run stops at the gate (exit 10), `decide`
# approves, the run again completes (exit 0) and no step was admitted twice; a third run admits nothing; (3) the budget: a build
# that spends past the ceiling, the next model step is never admitted, `budget-exhausted` (exit 12), the spend record carries the
# cost Forge derived; (4) a rejected gate blocks its dependents and not an independent step (exit 11); and the other ways a run
# stops: a worker that ends without a claim (15), an audit with no score (14), an artifact missing, no price table, a step
# directory missing, a bad operator file, a corrupt journal, a held lock, bad usage; and resume: a step admitted and never accepted
# (a run killed mid-step) is admitted again, once. And needs (task 8c): a step that needs another is given a copy of its accepted
# artifact and needs.json with the recorded sha256; one whose need changed or is gone is refused artifact-invalid and never admitted.
# Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
# Usage: CANCHO=path/to/cancho tests/conformance/company_run.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../.." || exit 1
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
w="$scratch/cr"
mkdir "$w" "$w/workers" "$w/tools" || exit 1
cp scripts/standin_cancho_build.sh "$w/tools/cancho-build" && chmod +x "$w/tools/cancho-build" || exit 1
if ! { $C build src/*.cho --std -o "$w/forge" && $C build workers/cancho_code.cho $libs --std -o "$w/workers/cancho_code" && $C build workers/gate_runner.cho $libs --std -o "$w/workers/gate_runner"; }; then
  echo "FAIL company run: a program did not build"
  exit 1
fi
F="$w/forge"
ok() { echo "ok   company run: $1"; }
bad() { echo "FAIL company run: $1"; fail=1; }
check() { # name, command...
  name=$1; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

# A git checkout of the row `alpibrusl/cancho-hdl` of the gate runner's allow-list (it runs scripts/gate_cancho.sh), for qa steps.
git_in() { d=$1; shift; git -C "$d" -c user.email=forge@example.invalid -c user.name=forge -c commit.gpgsign=false "$@"; }
mkdir -p "$w/checkout/scripts" && printf '#!/bin/sh\necho hello gate\nexit 0\n' > "$w/checkout/scripts/gate_cancho.sh" && chmod +x "$w/checkout/scripts/gate_cancho.sh" \
  && git init -q "$w/checkout" && git_in "$w/checkout" add -A && git_in "$w/checkout" commit -q -m fixture || exit 1
rev=$(git -C "$w/checkout" rev-parse HEAD)

# The operator file: outside every company directory.
cat > "$w/operator.json" <<EOF
{"workers":"$w/workers","tools":"$w/tools","checker":"/opt/cancho/bin/cancho","agent":"stand-in-agent","check_timeout_ms":20000,"build_timeout_ms":20000,"gate_timeout_ms":20000,
 "gates":{"qa":{"repo":"alpibrusl/cancho-hdl","revision":"$rev","checkout":"$w/checkout"}}}
EOF

# A company directory: <name>, the manifest's steps JSON, the budget's input ceiling; the steps listed after get steps/<id>/ev.
# The price table prices the stand-in's model at $1 per million tokens of every class, one micro-dollar a token.
mkco() { # name, steps json, input ceiling, step ids...
  co="$w/$1"; steps=$2; ceiling=$3; shift 3
  mkdir "$co" || exit 1
  printf '{"id":"co","mission":"m","model":{"provider":"stand","name":"m1"},"budget":{"input":%s,"output":100000,"cache_write":100000,"cache_read":100000,"max_cost":10,"price_table":"prices.json"},"human_gates":["ship","g"],"roles":["builder","qa","product","analyst"],"steps":%s}' "$ceiling" "$steps" > "$co/company.json"
  printf '{"_note":"test","stand":{"m1":{"in":1.0,"cache_write":1.0,"cache_read":1.0,"out":1.0}}}' > "$co/prices.json"
  printf '#!/bin/sh\necho "audit of $1"\necho "TOTAL 2/2"\n' > "$co/audit_pass.sh"
  printf '#!/bin/sh\necho "case 1 ok"\necho "case 2 FAILED"\necho "TOTAL 1/2"\nexit 1\n' > "$co/audit_half.sh"
  printf '#!/bin/sh\necho "no score here"\n' > "$co/audit_none.sh"
  printf '#!/bin/sh\ngrep -q verdict "$1" && echo "TOTAL 1/1"\n' > "$co/audit_report.sh"
  printf '#!/bin/sh\nprintf x >> "$1"\necho "TOTAL 2/2"\n' > "$co/audit_mutate.sh"
  printf '#!/bin/sh\nsleep 37\necho "TOTAL 2/2"\n' > "$co/audit_hang.sh"
  printf '#!/bin/sh\nhead -c 1100000 /dev/zero | tr "\\0" x\necho "TOTAL 2/2"\n' > "$co/audit_noisy.sh"
  chmod +x "$co"/audit_*.sh
  for s in "$@"; do mkdir -p "$co/steps/$s/ev" || exit 1; done
}
run_op() { # company name, tag, operator file
  "$F" company run "$w/$1" "$3" > "$w/$1.$2.out" 2> "$w/$1.$2.err"; echo $? > "$w/$1.$2.rc"
}
run() { # company name, tag of this run: forge company run, stdout in $w/<name>.<tag>.out, status in .rc
  "$F" company run "$w/$1" "$w/operator.json" > "$w/$1.$2.out" 2> "$w/$1.$2.err"; echo $? > "$w/$1.$2.rc"
}
rc() { cat "$w/$1.$2.rc"; }
out_has() { grep -qx "$3" "$w/$1.$2.out"; } # name, tag, whole line
kinds() { # name, kind, step: how many records of that kind for that step (0 with no journal)
  if [ -f "$w/$1/company.journal" ]; then grep -c "\"kind\":\"$2\",\"task\":\"$3\"" "$w/$1/company.journal"; else echo 0; fi
}
builder() { printf '{"id":"%s","role":"builder","task_type":"project.build","needs":[%s],"input":"%s","check":"%s"}' "$1" "$2" "$3" "$4"; }

# ---- (1) the lying worker (spec 7): the build says done, the audit scores 1/2
mkco lie "[$(builder lib '' done audit_half.sh)]" 100000 lib
run lie 1
check "lying worker: the run ends check-failed, exit 13" sh -c "[ '$(rc lie 1)' = 13 ] && grep -qx 'refusal: check-failed' '$w/lie.1.out' && grep -qx 'score: 1/2' '$w/lie.1.out'"
check "lying worker: the worker DID claim done (its own journal holds the claim, in verification)" sh -c "grep -q '\"kind\":\"execution.finished\".*\"verdict\":\"done\"' '$w/lie/steps/lib/journal.jsonl' && grep -qx 'claimed verdict: done' '$w/lie.1.out'"
check "lying worker: company.journal holds NO company.step.accepted, and the check_failed with its score" sh -c "! grep -q 'company.step.accepted' '$w/lie/company.journal' && grep -q '\"kind\":\"company.step.check_failed\",\"task\":\"lib\",\"score\":1,\"total\":2' '$w/lie/company.journal'"
"$F" company status "$w/lie" > "$w/lie.status"
check "lying worker: status shows the step not accepted" sh -c "grep -qx 'lib ready' '$w/lie.status'"
proposed() { grep -c '"kind":"task.proposed"' "$w/$1/steps/$2/journal.jsonl"; } # name, step: builds the step's workspace saw
run lie 2
check "lying worker: a second run does NOT build again (no Forge-level retry): exit 13, the step held, admitted once, one build" sh -c "[ '$(rc lie 2)' = 13 ] && grep -qx 'refusal: check-failed' '$w/lie.2.out' && grep -qx 'retry: forge company decide $w/lie retry:lib approved <reason>' '$w/lie.2.out' && [ $(kinds lie company.step.admitted lib) -eq 1 ] && [ $(proposed lie lib) -eq 1 ] && ! grep -q 'company.step.accepted' '$w/lie/company.journal'"
"$F" company decide "$w/lie" retry:lib rejected "not yet" > /dev/null
run lie 3
check "lying worker: a rejected retry keeps it held, nothing built" sh -c "[ '$(rc lie 3)' = 13 ] && [ $(kinds lie company.step.admitted lib) -eq 1 ] && [ $(proposed lie lib) -eq 1 ]"
"$F" company decide "$w/lie" retry:lib approved "audit looked at" > "$w/lie.decide.out"; echo $? > "$w/lie.decide.rc"
check "lying worker: decide records the retry of a step (retry:<id> is a gate of every step)" sh -c "[ \$(cat '$w/lie.decide.rc') = 0 ] && grep -qx 'gate retry:lib: approved' '$w/lie.decide.out'"
run lie 4
check "lying worker: after an approved retry the next run admits it exactly once more (and its check fails again)" sh -c "[ '$(rc lie 4)' = 13 ] && [ $(kinds lie company.step.admitted lib) -eq 2 ] && [ $(proposed lie lib) -eq 2 ] && [ \$(grep -c 'company.step.check_failed' '$w/lie/company.journal') -eq 2 ]"
run lie 5
check "lying worker: and the new failure holds it again: nothing more is built" sh -c "[ '$(rc lie 5)' = 13 ] && [ $(kinds lie company.step.admitted lib) -eq 2 ] && [ $(proposed lie lib) -eq 2 ] && ! grep -q 'company.step.accepted' '$w/lie/company.journal'"
"$F" company decide "$w/lie" retry:nostep approved "x" > "$w/lie.nostep.out"; echo $? > "$w/lie.nostep.rc"
check "decide: a retry of a step the manifest does not have is gate-unknown, exit 1" sh -c "[ \$(cat '$w/lie.nostep.rc') = 1 ] && grep -qx 'refusal: gate-unknown' '$w/lie.nostep.out'"
mkco liespend "[$(builder lib '' spend audit_half.sh)]" 100000 lib
run liespend 1
run liespend 2
check "lying worker that spends: the held second run spends nothing (one spend record, one build)" sh -c "[ '$(rc liespend 2)' = 13 ] && [ \$(grep -c 'company.spend.recorded' '$w/liespend/company.journal') -eq 1 ] && [ $(proposed liespend lib) -eq 1 ]"

# ---- (2) the good path: lib (builder) -> qa (qa) -> ship (product, gate ship)
steps="[$(builder lib '' done audit_pass.sh),{\"id\":\"qa\",\"role\":\"qa\",\"task_type\":\"repo.gate\",\"needs\":[\"lib\"],\"input\":\"gate\",\"check\":\"audit_report.sh\"},{\"id\":\"ship\",\"role\":\"product\",\"task_type\":\"none\",\"needs\":[\"qa\"],\"input\":\"ship it\",\"gate\":\"ship\"}]"
mkco good "$steps" 100000 lib qa
run good 1
check "good path: the first run stops at the open gate, exit 10, naming it" sh -c "[ '$(rc good 1)' = 10 ] && grep -qx 'refusal: gate-open' '$w/good.1.out' && grep -qx 'gate: ship' '$w/good.1.out' && grep -qx 'step: ship' '$w/good.1.out'"
check "good path: lib and qa are accepted with the artifact and its sha256, ship is not" sh -c "[ \$(grep -c '\"kind\":\"company.step.accepted\"' '$w/good/company.journal') -eq 2 ] && grep -q '\"kind\":\"company.step.accepted\",\"task\":\"lib\",\"artifact\":\"steps/lib/ev/project.cho\",\"sha256\":\"$(sha256sum "$w/good/steps/lib/ev/project.cho" | cut -c1-64)\"' '$w/good/company.journal' && grep -q '\"task\":\"qa\",\"artifact\":\"steps/qa/ev/report.json\"' '$w/good/company.journal'"
check "good path: the builder's own task was left in verification, never accepted by the worker" sh -c "! grep -q 'task.accepted' '$w/good/steps/lib/journal.jsonl'"
"$F" company decide "$w/good" ship approved "looks right" > /dev/null
run good 2
check "good path: after decide approved the run completes, exit 0" sh -c "[ '$(rc good 2)' = 0 ] && grep -q '\"kind\":\"company.step.accepted\",\"task\":\"ship\",\"artifact\":\"company.json\"' '$w/good/company.journal'"
check "good path: every step admitted exactly once over the two runs" sh -c "[ $(kinds good company.step.admitted lib) -eq 1 ] && [ $(kinds good company.step.admitted qa) -eq 1 ] && [ $(kinds good company.step.admitted ship) -eq 1 ]"
run good 3
check "good path: a third run is done at once and admits nothing" sh -c "[ '$(rc good 3)' = 0 ] && [ \$(grep -c 'company.step.admitted' '$w/good/company.journal') -eq 3 ]"
"$F" company status "$w/good" > "$w/good.status"
check "good path: status shows all three accepted" sh -c "grep -qx 'lib accepted' '$w/good.status' && grep -qx 'qa accepted' '$w/good.status' && grep -qx 'ship accepted' '$w/good.status'"

# ---- (3) the budget: the input ceiling is 1000; one build spends 1100 (two calls) and the next model step is never started
mkco budget "[$(builder one '' spend audit_pass.sh),$(builder two '' done audit_pass.sh)]" 1000 one two
run budget 1
check "budget: the run stops budget-exhausted, exit 12" sh -c "[ '$(rc budget 1)' = 12 ] && grep -qx 'refusal: budget-exhausted' '$w/budget.1.out'"
check "budget: the spend is recorded with the cost Forge derived (1130 micro-dollars at one a token)" grep -q '"kind":"company.spend.recorded","task":"one","input":1100,"output":30,"cache_write":0,"cache_read":0,"cost_micro":1130' "$w/budget/company.journal"
check "budget: the step that spent is accepted (its check passed) and the next model step was never admitted" sh -c "[ $(kinds budget company.step.accepted one) -eq 1 ] && [ $(kinds budget company.step.admitted two) -eq 0 ]"
run budget 2
check "budget: run again, the same stop, still nothing admitted for the held step" sh -c "[ '$(rc budget 2)' = 12 ] && [ $(kinds budget company.step.admitted two) -eq 0 ] && [ \$(grep -c 'company.spend.recorded' '$w/budget/company.journal') -eq 1 ]"

# ---- (4) a rejected gate blocks its dependents but not an independent step
steps="[{\"id\":\"brief\",\"role\":\"product\",\"task_type\":\"none\",\"needs\":[],\"input\":\"b\",\"gate\":\"g\"},$(builder lib '"brief"' done audit_pass.sh),$(builder side '' done audit_pass.sh)]"
mkco rej "$steps" 100000 lib side
"$F" company decide "$w/rej" g rejected "not this" > /dev/null
run rej 1
check "rejected gate: the run ends gate-rejected, exit 11, naming the gate" sh -c "[ '$(rc rej 1)' = 11 ] && grep -qx 'refusal: gate-rejected' '$w/rej.1.out' && grep -qx 'gate: g' '$w/rej.1.out'"
check "rejected gate: the independent step ran and was accepted; the gated step and its dependent were never admitted" sh -c "[ $(kinds rej company.step.accepted side) -eq 1 ] && [ $(kinds rej company.step.admitted brief) -eq 0 ] && [ $(kinds rej company.step.admitted lib) -eq 0 ]"

# ---- (5) needs (task 8c): b needs a; Forge re-hashes a's accepted artifact and gives b a copy and needs.json in its execution dir
sha_of() { sha256sum "$1" | cut -c1-64; }
mkco needs "[$(builder a '' done audit_pass.sh),$(builder b '"a"' needs audit_pass.sh)]" 100000 a b
run needs 1
asha=$(sha_of "$w/needs/steps/a/ev/project.cho")
check "needs: the run completes, exit 0, each step admitted once" sh -c "[ '$(rc needs 1)' = 0 ] && [ $(kinds needs company.step.admitted a) -eq 1 ] && [ $(kinds needs company.step.admitted b) -eq 1 ]"
check "needs: b's execution directory holds a copy of a's accepted artifact, byte for byte, as a regular file" sh -c "[ -f '$w/needs/steps/b/ev/needs-a-project.cho' ] && [ ! -L '$w/needs/steps/b/ev/needs-a-project.cho' ] && cmp -s '$w/needs/steps/a/ev/project.cho' '$w/needs/steps/b/ev/needs-a-project.cho'"
printf '[{"step":"a","artifact":"steps/a/ev/project.cho","path":"needs-a-project.cho","sha256":"%s"}]\n' "$asha" > "$w/needs.want"
check "needs: b's needs.json lists a with the path and the sha256 the journal recorded for it" sh -c "cmp -s '$w/needs.want' '$w/needs/steps/b/ev/needs.json' && grep -q '\"kind\":\"company.step.accepted\",\"task\":\"a\",\"artifact\":\"steps/a/ev/project.cho\",\"sha256\":\"$asha\"' '$w/needs/company.journal'"
check "needs: the worker of b read them (its product holds needs.json and a's bytes)" sh -c "grep -q '\"sha256\":\"$asha\"' '$w/needs/steps/b/ev/project.cho' && grep -qx 'product' '$w/needs/steps/b/ev/project.cho'"
check "needs: a step with no needs is given nothing" sh -c "[ ! -e '$w/needs/steps/a/ev/needs.json' ] && ! ls '$w/needs/steps/a/ev' | grep -q '^needs-'"

# ---- a's artifact changed (or gone) between its acceptance and b's start: b is refused, never admitted, nothing written
gated="[$(builder a '' done audit_pass.sh),{\"id\":\"b\",\"role\":\"builder\",\"task_type\":\"project.build\",\"needs\":[\"a\"],\"input\":\"needs\",\"check\":\"audit_pass.sh\",\"gate\":\"g\"}]"
mkco tamper "$gated" 100000 a b
run tamper 1
cp "$w/tamper/steps/a/ev/project.cho" "$w/tamper.a.orig"
printf 'tampered\n' >> "$w/tamper/steps/a/ev/project.cho"
"$F" company decide "$w/tamper" g approved "go" > /dev/null
lines=$(wc -l < "$w/tamper/company.journal")
run tamper 2
check "needs changed: the first run accepted a and stopped at b's gate" sh -c "[ '$(rc tamper 1)' = 10 ] && [ $(kinds tamper company.step.accepted a) -eq 1 ]"
check "needs changed: b is refused artifact-invalid (needs-changed), exit 14, naming the need" sh -c "[ '$(rc tamper 2)' = 14 ] && grep -qx 'refusal: artifact-invalid' '$w/tamper.2.out' && grep -qx 'step: b' '$w/tamper.2.out' && grep -qx 'need: a' '$w/tamper.2.out' && grep -qx 'artifact: steps/a/ev/project.cho' '$w/tamper.2.out' && grep -qx 'reason: needs-changed' '$w/tamper.2.out'"
check "needs changed: b was never admitted, never built, given nothing, and the journal is unchanged" sh -c "[ $(kinds tamper company.step.admitted b) -eq 0 ] && [ ! -e '$w/tamper/steps/b/journal.jsonl' ] && [ ! -e '$w/tamper/steps/b/ev/needs.json' ] && [ ! -e '$w/tamper/steps/b/ev/needs-a-project.cho' ] && [ \$(wc -l < '$w/tamper/company.journal') -eq $lines ]"
rm "$w/tamper/steps/a/ev/project.cho"
run tamper 3
check "needs missing: a's artifact gone, b refused artifact-invalid (needs-missing), exit 14, not admitted" sh -c "[ '$(rc tamper 3)' = 14 ] && grep -qx 'reason: needs-missing' '$w/tamper.3.out' && [ $(kinds tamper company.step.admitted b) -eq 0 ]"
ln -s "$w/tamper.a.orig" "$w/tamper/steps/a/ev/project.cho"
run tamper 4
check "needs as a link to the very bytes accepted: still refused (needs-changed: not a regular file), not admitted" sh -c "[ '$(rc tamper 4)' = 14 ] && grep -qx 'reason: needs-changed' '$w/tamper.4.out' && [ $(kinds tamper company.step.admitted b) -eq 0 ]"
rm "$w/tamper/steps/a/ev/project.cho"; cp "$w/tamper.a.orig" "$w/tamper/steps/a/ev/project.cho"
run tamper 5
check "needs restored: the same bytes again, b runs and is accepted, exit 0, given a's artifact" sh -c "[ '$(rc tamper 5)' = 0 ] && [ $(kinds tamper company.step.admitted b) -eq 1 ] && cmp -s '$w/tamper.a.orig' '$w/tamper/steps/b/ev/needs-a-project.cho'"

# ---- a product step is verified too (not given copies: it has no execution directory)
mkco ptamper "[$(builder lib '' done audit_pass.sh),{\"id\":\"ship\",\"role\":\"product\",\"task_type\":\"none\",\"needs\":[\"lib\"],\"input\":\"x\",\"gate\":\"ship\"}]" 100000 lib
run ptamper 1
printf 'tampered\n' >> "$w/ptamper/steps/lib/ev/project.cho"
"$F" company decide "$w/ptamper" ship approved "go" > /dev/null
run ptamper 2
check "a product step whose need changed: artifact-invalid (needs-changed), exit 14, not admitted, not accepted" sh -c "[ '$(rc ptamper 1)' = 10 ] && [ '$(rc ptamper 2)' = 14 ] && grep -qx 'step: ship' '$w/ptamper.2.out' && grep -qx 'reason: needs-changed' '$w/ptamper.2.out' && [ $(kinds ptamper company.step.admitted ship) -eq 0 ] && [ $(kinds ptamper company.step.accepted ship) -eq 0 ]"

# ---- resume: b admitted and never accepted (a run killed in it), and its execution directory left with stale and hostile files:
# the next run delivers again, replacing them, never writing through a link
mkco redo "$gated" 100000 a b
run redo 1
"$F" company decide "$w/redo" g approved "go" > /dev/null
n=$(($(wc -l < "$w/redo/company.journal") + 1))
printf '{"v":1,"seq":%s,"kind":"company.step.admitted","task":"b","forge_task":"steps/b"}\n{"v":1,"seq":%s,"kind":"compa' "$n" $((n + 1)) >> "$w/redo/company.journal"
printf 'untouched\n' > "$w/redo.outside"
ln -s "$w/redo.outside" "$w/redo/steps/b/ev/needs-a-project.cho"
printf 'stale\n' > "$w/redo/steps/b/ev/needs.json"
printf 'stale\n' > "$w/redo/steps/b/ev/needs.tmp"
run redo 2
check "resume with needs: b admitted again (twice in all), accepted once, exit 0" sh -c "[ '$(rc redo 2)' = 0 ] && [ $(kinds redo company.step.admitted b) -eq 2 ] && [ $(kinds redo company.step.accepted b) -eq 1 ]"
check "resume with needs: delivered again, the link replaced by a regular copy, its target untouched, needs.json rewritten" sh -c "[ ! -L '$w/redo/steps/b/ev/needs-a-project.cho' ] && cmp -s '$w/redo/steps/a/ev/project.cho' '$w/redo/steps/b/ev/needs-a-project.cho' && [ \"\$(cat '$w/redo.outside')\" = untouched ] && grep -q '\"sha256\":\"$(sha_of "$w/redo/steps/a/ev/project.cho")\"' '$w/redo/steps/b/ev/needs.json' && ! grep -q stale '$w/redo/steps/b/ev/needs.json' && [ ! -e '$w/redo/steps/b/ev/needs.tmp' ]"
run redo 3
check "resume with needs: a run after that admits nothing more" sh -c "[ '$(rc redo 3)' = 0 ] && [ $(kinds redo company.step.admitted b) -eq 2 ]"

# ---- fix round 1. I1: a need run by a person (its artifact is company.json) is not byte-verified: editing the manifest after it
# was accepted does not block the step that needs it, and nothing of it is given
pm="[{\"id\":\"brief\",\"role\":\"product\",\"task_type\":\"none\",\"needs\":[],\"input\":\"b\",\"gate\":\"g\"},{\"id\":\"lib\",\"role\":\"builder\",\"task_type\":\"project.build\",\"needs\":[\"brief\"],\"input\":\"needs\",\"check\":\"audit_pass.sh\",\"gate\":\"ship\"}]"
mkco pedit "$pm" 100000 lib
"$F" company decide "$w/pedit" g approved "go" > /dev/null
run pedit 1
printf '\n  \n' >> "$w/pedit/company.json"
"$F" company decide "$w/pedit" ship approved "go" > /dev/null
run pedit 2
check "a product need: company.json edited after it was accepted does not block its dependent (exit 0), nothing of it given" sh -c "[ '$(rc pedit 1)' = 10 ] && [ $(kinds pedit company.step.accepted brief) -eq 1 ] && [ '$(rc pedit 2)' = 0 ] && [ $(kinds pedit company.step.accepted lib) -eq 1 ] && ! ls '$w/pedit/steps/lib/ev' | grep -q '^needs'"

# I2: all needs are verified before anything is written: b needs a1 and a2, a2 is tampered; b's execution directory is unchanged
two="[$(builder a1 '' done audit_pass.sh),$(builder a2 '' done audit_pass.sh),{\"id\":\"b\",\"role\":\"builder\",\"task_type\":\"project.build\",\"needs\":[\"a1\",\"a2\"],\"input\":\"needs\",\"check\":\"audit_pass.sh\",\"gate\":\"g\"}]"
mkco two "$two" 100000 a1 a2 b
run two 1
printf 'tampered\n' >> "$w/two/steps/a2/ev/project.cho"
printf 'earlier\n' > "$w/two/steps/b/ev/needs.json"
"$F" company decide "$w/two" g approved "go" > /dev/null
ls -l --time-style=+%s "$w/two/steps/b/ev" > "$w/two.before"
run two 2
ls -l --time-style=+%s "$w/two/steps/b/ev" > "$w/two.after"
check "two needs, the second changed: refused (need: a2), not admitted, the execution directory unchanged (no copy of a1, needs.json as it was)" sh -c "[ '$(rc two 2)' = 14 ] && grep -qx 'need: a2' '$w/two.2.out' && [ $(kinds two company.step.admitted b) -eq 0 ] && [ ! -e '$w/two/steps/b/ev/needs-a1-project.cho' ] && [ \"\$(cat '$w/two/steps/b/ev/needs.json')\" = earlier ] && cmp -s '$w/two.before' '$w/two.after'"

# Stale needs files in a reused execution directory are Forge's to remove: a builder with no needs is left none, and one with needs
# gets exactly the current ones; the files Forge makes are not group- or world-writable
mkco stale "[$(builder a '' done audit_pass.sh),$(builder b '"a"' needs audit_pass.sh)]" 100000 a b
printf 'stale\n' > "$w/stale/steps/a/ev/needs.json"; printf 'stale\n' > "$w/stale/steps/a/ev/needs-old-project.cho"
printf 'stale\n' > "$w/stale/steps/b/ev/needs-old-project.cho"
run stale 1
check "stale needs: removed from a step with no needs, and only the current copy left beside needs.json for b" sh -c "[ '$(rc stale 1)' = 0 ] && ! ls '$w/stale/steps/a/ev' | grep -q '^needs' && [ \"\$(ls '$w/stale/steps/b/ev' | grep '^needs' | tr '\\n' ' ')\" = 'needs-a-project.cho needs.json ' ]"
check "needs files are not group- or world-writable" sh -c "for f in '$w/stale/steps/b/ev/needs.json' '$w/stale/steps/b/ev/needs-a-project.cho'; do m=\$(stat -c %a \"\$f\"); case \$m in *[2367]?|*[2367]) exit 1;; esac; done"

# A qa step whose need changed is refused too (verified, though it is given nothing)
qm="[$(builder lib '' done audit_pass.sh),{\"id\":\"qa\",\"role\":\"qa\",\"task_type\":\"repo.gate\",\"needs\":[\"lib\"],\"input\":\"gate\",\"check\":\"audit_report.sh\",\"gate\":\"g\"}]"
mkco qtamper "$qm" 100000 lib qa
run qtamper 1
printf 'tampered\n' >> "$w/qtamper/steps/lib/ev/project.cho"
"$F" company decide "$w/qtamper" g approved "go" > /dev/null
run qtamper 2
check "a qa step whose need changed: artifact-invalid (needs-changed), exit 14, not admitted" sh -c "[ '$(rc qtamper 1)' = 10 ] && [ '$(rc qtamper 2)' = 14 ] && grep -qx 'step: qa' '$w/qtamper.2.out' && grep -qx 'reason: needs-changed' '$w/qtamper.2.out' && [ $(kinds qtamper company.step.admitted qa) -eq 0 ]"

# ---- a worker that ends without a claim: no accepted, exit 15
mkco stuck "[$(builder lib '' stuck audit_pass.sh)]" 100000 lib
run stuck 1
check "stuck worker: step-failed, exit 15, the build's exit printed, nothing accepted" sh -c "[ '$(rc stuck 1)' = 15 ] && grep -qx 'refusal: step-failed' '$w/stuck.1.out' && grep -qx 'exit: 4' '$w/stuck.1.out' && ! grep -q 'company.step.accepted' '$w/stuck/company.journal' && [ $(kinds stuck company.step.admitted lib) -eq 1 ]"

# ---- an audit with no score: check-unavailable, exit 14, nothing accepted and no check_failed
mkco none "[$(builder lib '' done audit_none.sh)]" 100000 lib
run none 1
check "audit without a score: check-unavailable, exit 14, recorded, nothing accepted" sh -c "[ '$(rc none 1)' = 14 ] && grep -qx 'refusal: check-unavailable' '$w/none.1.out' && ! grep -q 'company.step.accepted\|check_failed' '$w/none/company.journal' && grep -q '\"kind\":\"company.step.check_unavailable\",\"task\":\"lib\",\"reason\":\"check-unavailable\"' '$w/none/company.journal'"
run none 2
check "audit without a score: a second run is held too (exit 14), nothing built" sh -c "[ '$(rc none 2)' = 14 ] && [ $(kinds none company.step.admitted lib) -eq 1 ] && [ $(proposed none lib) -eq 1 ]"

# ---- a build that claims done and leaves no artifact: Forge hashes nothing, so no check is run and nothing is accepted
mkco noart "[$(builder lib '' bare audit_pass.sh)]" 100000 lib
run noart 1
check "no artifact: artifact-invalid, exit 14, nothing accepted" sh -c "[ '$(rc noart 1)' = 14 ] && grep -qx 'refusal: artifact-invalid' '$w/noart.1.out' && ! grep -q 'company.step.accepted' '$w/noart/company.journal'"

# ---- an artifact that is not a regular file beneath the execution directory: never hashed through, never accepted
mkco linkart "[$(builder lib '' linkart audit_pass.sh)]" 100000 lib
run linkart 1
check "a symlink artifact (to a file outside the company): artifact-invalid, exit 14, not accepted" sh -c "[ -L '$w/linkart/steps/lib/ev/project.cho' ] && [ '$(rc linkart 1)' = 14 ] && grep -qx 'refusal: artifact-invalid' '$w/linkart.1.out' && ! grep -q 'company.step.accepted' '$w/linkart/company.journal'"
mkco dirart "[$(builder lib '' bare audit_pass.sh)]" 100000 lib
mkdir "$w/dirart/steps/lib/ev/project.cho"
run dirart 1
check "a directory where the artifact should be: artifact-invalid, exit 14" sh -c "[ '$(rc dirart 1)' = 14 ] && grep -qx 'refusal: artifact-invalid' '$w/dirart.1.out' && ! grep -q 'company.step.accepted' '$w/dirart/company.journal'"
# A FIFO cannot be left by the build itself here: the Cancho Code adapter opens its evidence files and blocks on one (its own
# deadline ends that build: a finding about the adapter, not about the run). So the FIFO is put in the artifact's place by the
# step's check, after the first hash: the second hash meets it, and must refuse it without opening it.
if command -v mkfifo > /dev/null 2>&1; then
  mkco fifoart "[$(builder lib '' done audit_fifo.sh)]" 100000 lib
  printf '#!/bin/sh\nrm -f "$1"\nmkfifo "$1"\necho "TOTAL 2/2"\n' > "$w/fifoart/audit_fifo.sh"; chmod +x "$w/fifoart/audit_fifo.sh"
  timeout 120 "$F" company run "$w/fifoart" "$w/operator.json" > "$w/fifoart.1.out" 2>&1; echo $? > "$w/fifoart.1.rc"
  check "a FIFO in the artifact's place: artifact-invalid (not a regular file), exit 14, and the run did not hang on it" sh -c "[ -p '$w/fifoart/steps/lib/ev/project.cho' ] && [ '$(rc fifoart 1)' = 14 ] && grep -qx 'refusal: artifact-invalid' '$w/fifoart.1.out' && grep -qx 'reason: not a regular file (a link, a directory, a FIFO or a device)' '$w/fifoart.1.out' && ! grep -q 'company.step.accepted' '$w/fifoart/company.journal'"
fi

# ---- the check itself misbehaves (short deadlines: an operator file of its own)
sed 's/"check_timeout_ms":20000/"check_timeout_ms":10000/' "$w/operator.json" > "$w/operator-short.json"
mkco mutate "[$(builder lib '' done audit_mutate.sh)]" 100000 lib
run mutate 1
check "a check that changes the artifact it judges: artifact-invalid (changed), exit 14, not accepted" sh -c "[ '$(rc mutate 1)' = 14 ] && grep -qx 'refusal: artifact-invalid' '$w/mutate.1.out' && grep -qx 'reason: changed while the check ran' '$w/mutate.1.out' && ! grep -q 'company.step.accepted' '$w/mutate/company.journal'"
mkco hang "[$(builder lib '' done audit_hang.sh)]" 100000 lib
run_op hang 1 "$w/operator-short.json"
check "a check that does not end: its deadline, check-unavailable, exit 14, and its process group is gone" sh -c "[ '$(rc hang 1)' = 14 ] && grep -qx 'refusal: check-unavailable' '$w/hang.1.out' && ! pgrep -f '^sleep 37\$' > /dev/null"
mkco noisy "[$(builder lib '' done audit_noisy.sh)]" 100000 lib
run noisy 1
check "a check that writes more than 1 MiB: check-unavailable, exit 14" sh -c "[ '$(rc noisy 1)' = 14 ] && grep -qx 'refusal: check-unavailable' '$w/noisy.1.out' && ! grep -q 'company.step.accepted' '$w/noisy/company.journal'"
cp "$w/operator.json" "$w/noisy/operator.json"
"$F" company run "$w/noisy" "$w/noisy/operator.json" > "$w/opin.out" 2>&1; echo $? > "$w/opin.rc"
check "an operator file inside the company directory: operator-invalid, exit 1" sh -c "[ \$(cat '$w/opin.rc') = 1 ] && grep -qx 'refusal: operator-invalid' '$w/opin.out'"

# ---- steps the run will not start: nothing admitted, exit 1
mkco nocheck "[{\"id\":\"qa\",\"role\":\"qa\",\"task_type\":\"repo.gate\",\"needs\":[],\"input\":\"gate\"}]" 100000 qa
run nocheck 1
check "a qa step with no check: check-missing (the gate's verdict is a claim), exit 1, not admitted" sh -c "[ '$(rc nocheck 1)' = 1 ] && grep -qx 'refusal: check-missing' '$w/nocheck.1.out' && [ $(kinds nocheck company.step.admitted qa) -eq 0 ]"
mkco person "[{\"id\":\"p\",\"role\":\"product\",\"task_type\":\"none\",\"needs\":[],\"input\":\"x\"}]" 100000
run person 1
check "a product step with neither a gate nor a check: check-missing, exit 1, not admitted" sh -c "[ '$(rc person 1)' = 1 ] && grep -qx 'refusal: check-missing' '$w/person.1.out' && [ $(kinds person company.step.admitted p) -eq 0 ]"
mkco analyst "[{\"id\":\"a\",\"role\":\"analyst\",\"task_type\":\"tool.run\",\"needs\":[],\"input\":\"x\",\"check\":\"audit_pass.sh\"}]" 100000 a
run analyst 1
check "an analyst step (no tool.run adapter yet): task-type-unsupported, exit 1, not admitted" sh -c "[ '$(rc analyst 1)' = 1 ] && grep -qx 'refusal: task-type-unsupported' '$w/analyst.1.out' && [ $(kinds analyst company.step.admitted a) -eq 0 ]"

# ---- resume: a step admitted and never accepted (a run killed mid-step) is admitted again, once, and accepted once
mkco resume "[$(builder lib '' done audit_pass.sh)]" 100000 lib
printf '{"v":1,"seq":1,"kind":"company.step.admitted","task":"lib","forge_task":"steps/lib"}\n{"v":1,"seq":2,"kind":"compa' > "$w/resume/company.journal"
run resume 1
check "resume: the half-run step is admitted again (twice in all), accepted once, the torn tail cut, exit 0" sh -c "[ '$(rc resume 1)' = 0 ] && [ $(kinds resume company.step.admitted lib) -eq 2 ] && [ $(kinds resume company.step.accepted lib) -eq 1 ] && ! grep -q 'compa\$' '$w/resume/company.journal'"
run resume 2
check "resume: a run after that admits nothing more" sh -c "[ '$(rc resume 2)' = 0 ] && [ $(kinds resume company.step.admitted lib) -eq 2 ]"

# ---- refused before any step: exit 1, nothing appended
mkco noprice "[$(builder lib '' done audit_pass.sh)]" 100000 lib
rm "$w/noprice/prices.json"
run noprice 1
check "no price table: price-table-missing, exit 1, no journal written" sh -c "[ '$(rc noprice 1)' = 1 ] && grep -qx 'refusal: price-table-missing' '$w/noprice.1.out' && [ ! -e '$w/noprice/company.journal' ]"
mkco badprice "[$(builder lib '' done audit_pass.sh)]" 100000 lib
printf '{"stand":{"other":{"in":1.0,"cache_write":1.0,"cache_read":1.0,"out":1.0}}}' > "$w/badprice/prices.json"
run badprice 1
check "a price table without the model: price-table-missing, exit 1" sh -c "[ '$(rc badprice 1)' = 1 ] && grep -qx 'refusal: price-table-missing' '$w/badprice.1.out'"
mkco nodir "[$(builder lib '' done audit_pass.sh)]" 100000
run nodir 1
check "a step directory that is not there: step-dir-missing, exit 1, the step not admitted" sh -c "[ '$(rc nodir 1)' = 1 ] && grep -qx 'refusal: step-dir-missing' '$w/nodir.1.out' && [ $(kinds nodir company.step.admitted lib) -eq 0 ]"
mkco corrupt "[$(builder lib '' done audit_pass.sh)]" 100000 lib
printf 'not json\n' > "$w/corrupt/company.journal"
run corrupt 1
check "a corrupt journal: journal-corrupt and its line, exit 1, unchanged" sh -c "[ '$(rc corrupt 1)' = 1 ] && grep -qx 'refusal: journal-corrupt' '$w/corrupt.1.out' && grep -qx 'line: 1' '$w/corrupt.1.out' && [ \"\$(cat '$w/corrupt/company.journal')\" = 'not json' ]"
mkco badop "[$(builder lib '' done audit_pass.sh)]" 100000 lib
printf '{"workers":"relative"}' > "$w/badop.json"
"$F" company run "$w/badop" "$w/badop.json" > "$w/badop.out" 2>&1; echo $? > "$w/badop.rc"
check "an operator file outside its shape: operator-invalid, exit 1" sh -c "[ \$(cat '$w/badop.rc') = 1 ] && grep -qx 'refusal: operator-invalid' '$w/badop.out' && [ ! -e '$w/badop/company.journal' ]"
"$F" company run "$w/badop" "$w/nowhere.json" > "$w/noop.out" 2>&1; echo $? > "$w/noop.rc"
check "an operator file that is not there: operator-invalid, exit 1" sh -c "[ \$(cat '$w/noop.rc') = 1 ] && grep -qx 'refusal: operator-invalid' '$w/noop.out'"
check "bad usage: no operator file is exit 2, a relative company directory is path-invalid exit 2" sh -c "'$F' company run '$w/badop' > /dev/null 2>&1; [ \$? -eq 2 ] && '$F' company run relative '$w/operator.json' > '$w/rel.out' 2>&1; [ \$? -eq 2 ] && grep -qx 'refusal: path-invalid' '$w/rel.out'"
if command -v flock > /dev/null 2>&1; then
  mkco locked "[$(builder lib '' done audit_pass.sh)]" 100000 lib
  flock -x "$w/locked/lock" sleep 3 &
  lp=$!
  sleep 0.5
  run locked 1
  wait "$lp"
  check "a company directory locked by another writer: workspace-locked, exit 1, nothing written" sh -c "[ '$(rc locked 1)' = 1 ] && grep -qx 'refusal: workspace-locked' '$w/locked.1.out' && [ ! -e '$w/locked/company.journal' ]"
else
  echo "skip company run: flock is not installed, the held-lock case was not run"
fi
exit $fail
