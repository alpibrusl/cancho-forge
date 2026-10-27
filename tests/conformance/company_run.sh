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
# And the contract (task 10): a builder step that names a `contract` file is given a Forge-written copy (contract.txt) in its
# execution directory and the build tool is started with `--contract <that path>`; a step that names none is started without the
# option; a missing contract is refused before the step is admitted; a build that changes its contract is not accepted.
# And analyst steps (task 11): `tool.run` through the real tool runner (workers/tool_run.cho) over a stand-in tool the operator file
# names and grants; the check compares the recomputed number with the product's summary (agree: accepted; disagree: check-failed);
# a tool not granted, an argv with a number, an escaping input, no entry for the step: refused before admission.
# Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
# Usage: CANCHO=path/to/cancho tests/conformance/company_run.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../.." || exit 1
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
w="$scratch/cr"
mkdir "$w" "$w/workers" "$w/tools" "$w/atools" || exit 1
cp scripts/standin_cancho_build.sh "$w/tools/cancho-build" && chmod +x "$w/tools/cancho-build" || exit 1
if ! { $C build src/*.cho --std -o "$w/forge" && $C build workers/cancho_code.cho $libs --std -o "$w/workers/cancho_code" && $C build workers/gate_runner.cho $libs --std -o "$w/workers/gate_runner" && $C build workers/check_guard.cho $libs --std -o "$w/workers/check_guard" && $C build workers/tool_run.cho $libs --std -o "$w/workers/tool_run"; }; then
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
 "gates":{"qa":{"repo":"alpibrusl/cancho-hdl","revision":"$rev","checkout":"$w/checkout"}},
 "analyst_tools":"$w/atools","granted_tools":["recount"],"tool_timeout_ms":20000,
 "analysts":{"an":{"tool":"recount","argv":["--status","up"],"input":"checks.log"}}}
EOF
# The analyst's stand-in tool (task 11): `recount --status S <input>` prints how many lines of the check log have the status S (the
# second field), the number a product's summary also states. It answers `introspect` as a cancho-tools tool does.
cat > "$w/atools/recount" <<'EOT'
#!/bin/sh
if [ "$1" = introspect ]; then printf %s '{"tool":"recount","authority":{"bounded":true,"effects":["heap"]}}'; exit 0; fi
if [ "$1" = --sleep ]; then sleep "$2"; fi
awk -v s="$2" '$2 == s { n++ } END { print n+0 }' "$3"
EOT
chmod +x "$w/atools/recount" || exit 1

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

# ---- the contract (task 10): a builder step may name a file of the company directory; Forge copies it to contract.txt in the step's
# execution directory and starts the build tool with `--contract <that path>`. The stand-in's mode `contract` records its argument
# vector and its product is the contract file as it read it; `contractmut` appends to it.
cbuilder() { printf '{"id":"%s","role":"builder","task_type":"project.build","needs":[],"input":"%s","check":"audit_pass.sh","contract":"%s"}' "$1" "$2" "$3"; }
mkco ctr "[$(cbuilder withc contract api.txt),$(builder plain '' contract audit_pass.sh)]" 100000 withc plain
printf 'fn add(a: int, b: int) -> [] int\nfn sub(a: int, b: int) -> [] int\n' > "$w/ctr/api.txt"
run ctr 1
check "contract: the run completes, exit 0, each step admitted once" sh -c "[ '$(rc ctr 1)' = 0 ] && [ $(kinds ctr company.step.admitted withc) -eq 1 ] && [ $(kinds ctr company.step.admitted plain) -eq 1 ]"
check "contract: the build tool got --contract and the path of Forge's copy in the execution directory, once" sh -c "[ \$(grep -c -x 'A:--contract' '$w/ctr/steps/withc/ev/args.txt') -eq 1 ] && grep -x -A1 'A:--contract' '$w/ctr/steps/withc/ev/args.txt' | tail -1 | grep -qx 'A:$w/ctr/steps/withc/ev/contract.txt'"
check "contract: the copy is a regular file, byte for byte the company directory's file, and the build read it (its product is the contract)" sh -c "[ -f '$w/ctr/steps/withc/ev/contract.txt' ] && [ ! -L '$w/ctr/steps/withc/ev/contract.txt' ] && cmp -s '$w/ctr/api.txt' '$w/ctr/steps/withc/ev/contract.txt' && cmp -s '$w/ctr/api.txt' '$w/ctr/steps/withc/ev/project.cho'"
check "contract: a step that names none is started without the option and given no copy (arm A unchanged)" sh -c "! grep -q -e '--contract' '$w/ctr/steps/plain/ev/args.txt' && [ ! -e '$w/ctr/steps/plain/ev/contract.txt' ] && grep -qx 'nocontract' '$w/ctr/steps/plain/ev/project.cho'"
printf 'A:/opt/cancho/bin/cancho\nA:%s/ctr/steps/plain/ev/brief.txt\nA:%s/ctr/steps/plain/ev\nA:stand-in-agent\nA:--provider\nA:stand\nA:--model\nA:m1\nA:--attempts\nA:4\nA:--agent-seconds\nA:30\nA:--rounds\nA:3\nA:--plan-seconds\nA:900\nA:--jobs\nA:4\n' "$w" "$w" > "$w/ctr.plain.want"
check "contract: and the whole argument vector of the step without one is the one it always was" sh -c "cmp -s '$w/ctr.plain.want' '$w/ctr/steps/plain/ev/args.txt'"

# the file is not there: refused before the step is admitted, nothing written; once it is there the step runs
mkco ctrmiss "[$(cbuilder withc contract api.txt)]" 100000 withc
run ctrmiss 1
check "contract missing: artifact-invalid with reason contract-missing, exit 14, naming the step and the file, not admitted, nothing built" sh -c "[ '$(rc ctrmiss 1)' = 14 ] && grep -qx 'refusal: artifact-invalid' '$w/ctrmiss.1.out' && grep -qx 'step: withc' '$w/ctrmiss.1.out' && grep -qx 'contract: api.txt' '$w/ctrmiss.1.out' && grep -qx 'reason: contract-missing' '$w/ctrmiss.1.out' && [ $(kinds ctrmiss company.step.admitted withc) -eq 0 ] && [ ! -e '$w/ctrmiss/steps/withc/journal.jsonl' ] && [ ! -e '$w/ctrmiss/steps/withc/ev/contract.txt' ] && [ ! -e '$w/ctrmiss/company.journal' ]"
printf 'fn one() -> [] int\n' > "$w/ctrmiss/api.txt"
run ctrmiss 2
check "contract missing: with the file in place the next run builds and accepts the step, given the contract" sh -c "[ '$(rc ctrmiss 2)' = 0 ] && [ $(kinds ctrmiss company.step.accepted withc) -eq 1 ] && cmp -s '$w/ctrmiss/api.txt' '$w/ctrmiss/steps/withc/ev/project.cho'"

# a link where the contract should be, and a directory: never read through
mkco ctrlink "[$(cbuilder withc contract api.txt)]" 100000 withc
printf 'secret\n' > "$w/ctrlink.outside"; ln -s "$w/ctrlink.outside" "$w/ctrlink/api.txt"
run ctrlink 1
check "contract as a link: artifact-invalid with reason contract-unreadable, exit 14, not admitted" sh -c "[ '$(rc ctrlink 1)' = 14 ] && grep -qx 'reason: contract-unreadable' '$w/ctrlink.1.out' && [ $(kinds ctrlink company.step.admitted withc) -eq 0 ] && [ ! -e '$w/ctrlink/steps/withc/ev/contract.txt' ]"

# the execution directory was left with a link at contract.txt: replaced by Forge's copy, never written through
mkco ctrhost "[$(cbuilder withc contract api.txt)]" 100000 withc
printf 'fn only() -> [] int\n' > "$w/ctrhost/api.txt"
printf 'untouched\n' > "$w/ctrhost.outside"; ln -s "$w/ctrhost.outside" "$w/ctrhost/steps/withc/ev/contract.txt"
run ctrhost 1
check "contract: a link planted at contract.txt is replaced by a regular copy, its target untouched" sh -c "[ '$(rc ctrhost 1)' = 0 ] && [ ! -L '$w/ctrhost/steps/withc/ev/contract.txt' ] && cmp -s '$w/ctrhost/api.txt' '$w/ctrhost/steps/withc/ev/contract.txt' && [ \"\$(cat '$w/ctrhost.outside')\" = untouched ]"

# the builder cannot change the contract it was given: the copy is compared with the company directory's file when the build ends
mkco ctrmut "[$(cbuilder withc contractmut api.txt)]" 100000 withc
printf 'fn keep() -> [] int\n' > "$w/ctrmut/api.txt"; cp "$w/ctrmut/api.txt" "$w/ctrmut.orig"
run ctrmut 1
check "contract changed by the build: artifact-invalid with reason contract-changed, exit 14, held, never accepted, the check never run" sh -c "[ '$(rc ctrmut 1)' = 14 ] && grep -qx 'refusal: artifact-invalid' '$w/ctrmut.1.out' && grep -qx 'artifact: steps/withc/ev/contract.txt' '$w/ctrmut.1.out' && grep -qx 'reason: contract-changed' '$w/ctrmut.1.out' && ! grep -q 'company.step.accepted' '$w/ctrmut/company.journal' && grep -q '\"kind\":\"company.step.check_unavailable\",\"task\":\"withc\"' '$w/ctrmut/company.journal'"
run ctrmut 2
check "contract changed by the build: the company directory's contract is untouched, and a second run is held (nothing built again)" sh -c "cmp -s '$w/ctrmut.orig' '$w/ctrmut/api.txt' && [ '$(rc ctrmut 2)' = 14 ] && [ $(kinds ctrmut company.step.admitted withc) -eq 1 ]"

# a contract over 256 KiB is refused up front (the plan agent reads 256 KiB of it): contract-unreadable, not admitted
mkco ctrbig "[$(cbuilder withc contract api.txt)]" 100000 withc
head -c 262145 /dev/zero | tr '\0' x > "$w/ctrbig/api.txt"
run ctrbig 1
check "contract over 256 KiB: artifact-invalid with reason contract-unreadable, exit 14, not admitted, nothing written" sh -c "[ '$(rc ctrbig 1)' = 14 ] && grep -qx 'reason: contract-unreadable' '$w/ctrbig.1.out' && [ $(kinds ctrbig company.step.admitted withc) -eq 0 ] && [ ! -e '$w/ctrbig/steps/withc/ev/contract.txt' ]"
head -c 262144 /dev/zero | tr '\0' x > "$w/ctrbig/api.txt"
run ctrbig 2
check "contract of exactly 256 KiB: given" sh -c "[ '$(rc ctrbig 2)' = 0 ] && cmp -s '$w/ctrbig/api.txt' '$w/ctrbig/steps/withc/ev/contract.txt'"

# a contract.txt left in the execution directory of a step that names none (an earlier manifest) is removed before the build
mkco ctrstale "[$(builder plain '' contract audit_pass.sh)]" 100000 plain
printf 'old contract\n' > "$w/ctrstale/steps/plain/ev/contract.txt"
run ctrstale 1
check "no contract named: a stale contract.txt is removed, the build gets no --contract and sees nocontract" sh -c "[ '$(rc ctrstale 1)' = 0 ] && ! grep -q -e '--contract' '$w/ctrstale/steps/plain/ev/args.txt' && grep -qx 'nocontract' '$w/ctrstale/steps/plain/ev/project.cho' && [ ! -e '$w/ctrstale/steps/plain/ev/contract.txt' ]"

# the manifest: a contract on a step that builds nothing, and a bad contract name, are refused by `forge company check`
printf '{"id":"c","mission":"m","model":{"provider":"p","name":"n"},"budget":{"input":1,"output":1,"cache_write":1,"cache_read":1,"max_cost":1,"price_table":"prices.json"},"human_gates":[],"roles":["qa"],"steps":[{"id":"a","role":"qa","task_type":"repo.gate","needs":[],"input":"x","contract":"api.txt"}]}' > "$w/ctr-qa.json"
"$F" company check "$w/ctr-qa.json" > "$w/ctr-qa.out" 2>&1; echo $? > "$w/ctr-qa.rc"
check "manifest: a contract on a qa step is contract-role-invalid, exit 1" sh -c "[ \$(cat '$w/ctr-qa.rc') = 1 ] && grep -qx 'refusal: contract-role-invalid' '$w/ctr-qa.out'"
sed 's|"role":"qa","task_type":"repo.gate"|"role":"builder","task_type":"project.build","check":"c.sh"|; s|"contract":"api.txt"|"contract":"../api.txt"|; s|"roles":\["qa"\]|"roles":["builder"]|' "$w/ctr-qa.json" > "$w/ctr-bad.json"
"$F" company check "$w/ctr-bad.json" > "$w/ctr-bad.out" 2>&1; echo $? > "$w/ctr-bad.rc"
check "manifest: a contract that is a path, not a file name, is manifest-malformed, exit 1" sh -c "[ \$(cat '$w/ctr-bad.rc') = 1 ] && grep -qx 'refusal: manifest-malformed' '$w/ctr-bad.out'"

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
# ---- analyst steps (task 11): tool.run through the tool runner (workers/tool_run.cho); the operator file names the tool, its argv
# and its input, the manifest none of them. The check compares the analyst's number (tool.out, the artifact) with the product's
# summary in the company directory.
analyst() { printf '{"id":"an","role":"analyst","task_type":"tool.run","needs":[],"input":"recompute the uptime count","check":"%s"}' "$1"; }
mkan() { # name, summary's up count
  mkco "$1" "[$(analyst same_up.sh)]" 100000 an
  printf 'svc1 up 12\nsvc1 down 0\nsvc2 up 30\nsvc1 up 15\n' > "$w/$1/steps/an/ev/checks.log"
  printf '{"checks":4,"up":%s}' "$2" > "$w/$1/summary.json"
  cat > "$w/$1/same_up.sh" <<'EOT'
#!/bin/sh
want=$(sed -n 's/.*"up":\([0-9]*\).*/\1/p' summary.json)
got=$(cat "$1")
echo "analyst $got, product $want"
if [ "$got" = "$want" ]; then echo "TOTAL 1/1"; else echo "TOTAL 0/1"; fi
EOT
  chmod +x "$w/$1/same_up.sh" || exit 1
}
an_sha=$(printf '3\n' | sha256sum | cut -c1-64)
auth_sha=$(printf '%s' '{"bounded":true,"effects":["heap"]}' | sha256sum | cut -c1-64)
mkan anl 3
run anl 1
check "analyst: the step runs through the tool runner and its check agrees with the product: accepted, exit 0" sh -c "[ '$(rc anl 1)' = 0 ] && [ \"\$(cat '$w/anl/steps/an/ev/tool.out')\" = 3 ] && grep -q '\"kind\":\"company.step.accepted\",\"task\":\"an\",\"artifact\":\"steps/an/ev/tool.out\",\"sha256\":\"$an_sha\"' '$w/anl/company.journal'"
check "analyst: the runner recorded the tool's authority manifest hash; the tool task is in verification, not accepted" sh -c "grep -q '\"authority_manifest\":{\"source\":\"introspect\",\"sha256\":\"$auth_sha\"}' '$w/anl/steps/an/ev/report.json' && grep -q '\"kind\":\"execution.finished\".*\"verdict\":\"exited\"' '$w/anl/steps/an/journal.jsonl' && ! grep -q 'task.accepted' '$w/anl/steps/an/journal.jsonl'"
check "analyst: no model budget is used (no spend record)" sh -c "! grep -q 'company.spend.recorded' '$w/anl/company.journal'"
mkan anlbad 5
run anlbad 1
check "analyst: a number that disagrees with the product's summary is check-failed, exit 13, not accepted" sh -c "[ '$(rc anlbad 1)' = 13 ] && grep -qx 'refusal: check-failed' '$w/anlbad.1.out' && grep -qx 'score: 0/1' '$w/anlbad.1.out' && ! grep -q 'company.step.accepted' '$w/anlbad/company.journal'"
mkan anlng 3
sed 's|"tool":"recount","argv"|"tool":"seek","argv"|' "$w/operator.json" > "$w/op_ng.json"
run_op anlng 1 "$w/op_ng.json"
check "analyst: a tool the operator did not grant is tool-not-granted, exit 1, not admitted, nothing run" sh -c "[ '$(rc anlng 1)' = 1 ] && grep -qx 'refusal: tool-not-granted' '$w/anlng.1.out' && grep -qx 'step: an' '$w/anlng.1.out' && [ $(kinds anlng company.step.admitted an) -eq 0 ] && [ \$(ls -A '$w/anlng/steps/an/ev') = checks.log ] && [ ! -e '$w/anlng/steps/an/journal.jsonl' ]"
mkan anlargv 3
sed 's|"argv":\["--status","up"\]|"argv":["--status",3]|' "$w/operator.json" > "$w/op_argv.json"
run_op anlargv 1 "$w/op_argv.json"
check "analyst: an argv with a number in the operator file is argv-malformed, exit 1, not admitted" sh -c "[ '$(rc anlargv 1)' = 1 ] && grep -qx 'refusal: argv-malformed' '$w/anlargv.1.out' && [ $(kinds anlargv company.step.admitted an) -eq 0 ]"
mkan anlpath 3
sed 's|"input":"checks.log"|"input":"../../../summary.json"|' "$w/operator.json" > "$w/op_path.json"
run_op anlpath 1 "$w/op_path.json"
check "analyst: an input that escapes the step's execution directory is path-invalid, exit 1, not admitted" sh -c "[ '$(rc anlpath 1)' = 1 ] && grep -qx 'refusal: path-invalid' '$w/anlpath.1.out' && [ $(kinds anlpath company.step.admitted an) -eq 0 ]"
mkan anlnone 3
sed 's|"analysts":{"an"|"analysts":{"other"|' "$w/operator.json" > "$w/op_none.json"
run_op anlnone 1 "$w/op_none.json"
check "analyst: no entry for the step in the operator file is operator-invalid, exit 1 (the manifest cannot name a tool)" sh -c "[ '$(rc anlnone 1)' = 1 ] && grep -qx 'refusal: operator-invalid' '$w/anlnone.1.out' && [ $(kinds anlnone company.step.admitted an) -eq 0 ]"
mkan anlgone 3
rm "$w/anlgone/steps/an/ev/checks.log"
run anlgone 1
check "analyst: an input that is not there is refused by the worker after admission: the operator is told its code (worker-error: input-unusable), the step's journal records it, step-failed, exit 15" sh -c "[ '$(rc anlgone 1)' = 15 ] && grep -qx 'refusal: step-failed' '$w/anlgone.1.out' && grep -qx 'worker-error: input-unusable' '$w/anlgone.1.out' && grep -q '\"kind\":\"refusal\",\"task\":\"tool-1\",\"rule\":\"input-unusable\"' '$w/anlgone/steps/an/journal.jsonl' && [ ! -e '$w/anlgone/steps/an/ev/tool.out' ] && ! grep -q 'company.step.accepted' '$w/anlgone/company.journal'"
# the operator's tool_timeout_ms is the one the run is given: a tool that sleeps 30 s under a 10 s timeout (the runner's own deadline
# is 8 s) ends as tool-timeout, well before the default of 600 s
mkan anlslow 3
sed 's|"tool_timeout_ms":20000|"tool_timeout_ms":10000|; s|"argv":\["--status","up"\]|"argv":["--sleep","30"]|' "$w/operator.json" > "$w/op_slow.json"
slow_start=$(date +%s)
run_op anlslow 1 "$w/op_slow.json"
slow_took=$(( $(date +%s) - slow_start ))
check "analyst: the operator's tool_timeout_ms is honoured: tool-timeout (worker-error) in about 8 s, step-failed, exit 15, the tool gone" sh -c "[ '$(rc anlslow 1)' = 15 ] && grep -qx 'worker-error: tool-timeout' '$w/anlslow.1.out' && [ $slow_took -lt 20 ] && grep -q '\"ending\":\"timeout\"' '$w/anlslow/steps/an/ev/report.json' && ! pgrep -f '^sleep 30\$' > /dev/null"
# an analyst uses no model: a spent budget does not hold it (a build spends 1100 of a 1000-token ceiling first)
mkco anlbudget "[$(builder one '' spend audit_pass.sh),$(analyst same_up.sh)]" 1000 one an
printf 'svc1 up 12\nsvc1 down 0\nsvc2 up 30\nsvc1 up 15\n' > "$w/anlbudget/steps/an/ev/checks.log"
printf '{"checks":4,"up":3}' > "$w/anlbudget/summary.json"
cp "$w/anl/same_up.sh" "$w/anlbudget/same_up.sh" || exit 1
run anlbudget 1
check "analyst: not held by a spent budget: the build spends past the ceiling, the analyst still runs and is accepted, exit 0" sh -c "[ '$(rc anlbudget 1)' = 0 ] && grep -q 'company.spend.recorded' '$w/anlbudget/company.journal' && [ $(kinds anlbudget company.step.accepted one) -eq 1 ] && [ $(kinds anlbudget company.step.accepted an) -eq 1 ]"

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
# ---- task 9 fix round 1: an operator workers directory without the check guard: the check cannot run, check-unavailable, exit 14,
# and the reason says what is missing
mkdir "$w/noguard" && cp "$w/workers/cancho_code" "$w/workers/gate_runner" "$w/noguard/" || exit 1
sed "s|\"workers\":\"$w/workers\"|\"workers\":\"$w/noguard\"|" "$w/operator.json" > "$w/noguard.json"
mkco ng "[$(builder lib '' done audit_pass.sh)]" 100000 lib
run_op ng 1 "$w/noguard.json"
check "no check_guard in the workers directory: check-unavailable, exit 14, the reason printed, lib not accepted" sh -c "[ '$(rc ng 1)' = 14 ] && grep -qx 'refusal: check-unavailable' '$w/ng.1.out' && grep -qx \"reason: the operator's workers directory has no check_guard\" '$w/ng.1.out' && ! grep -q company.step.accepted '$w/ng/company.journal'"

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
# ---- the build's usage.jsonl is read like an artifact (final review I1): beneath ev, no link followed, a regular file of at most
# 16 MiB, never opened when it is a FIFO. A link to /dev/zero must not exhaust memory, a FIFO must not block the run (it holds the
# company's lock), a sparse 17 MB file is refused unread: usage-invalid, recorded and held, exit 14, nothing accepted.
for mode in usagelink usagefifo usagebig usagedir; do
  mkco "$mode" "[$(builder lib '' $mode audit_pass.sh)]" 100000 lib
  # a memory bound of 4 GiB on the run, so that a Forge which did read /dev/zero is stopped by it and not by the machine; and a KILL
  # 10 s after the TERM: a Forge blocked opening a FIFO never looks at its signals (measured on the code before this fix: TERM did
  # not end it in 20 minutes)
  (ulimit -v 4194304; timeout -k 10 60 "$F" company run "$w/$mode" "$w/operator.json") > "$w/$mode.1.out" 2>&1; echo $? > "$w/$mode.1.rc"
  check "$mode: usage-invalid with its reason, exit 14 (no hang, no memory trap), nothing accepted, the step held" sh -c "[ '$(rc $mode 1)' = 14 ] && grep -qx 'refusal: usage-invalid' '$w/$mode.1.out' && grep -q '^reason: ' '$w/$mode.1.out' && ! grep -q 'company.step.accepted' '$w/$mode/company.journal' && grep -q '\"kind\":\"company.step.check_unavailable\",\"task\":\"lib\",\"reason\":\"usage-invalid\"' '$w/$mode/company.journal'"
done
(ulimit -v 4194304; timeout -k 10 60 "$F" company run "$w/usagelink" "$w/operator.json") > "$w/usagelink.2.out" 2>&1; echo $? > "$w/usagelink.2.rc"
check "usage-invalid: a later run names the RECORDED refusal (usage-invalid, not check-unavailable), exit 14, nothing built" sh -c "[ '$(rc usagelink 2)' = 14 ] && grep -qx 'refusal: usage-invalid' '$w/usagelink.2.out' && [ $(kinds usagelink company.step.admitted lib) -eq 1 ]"
timeout 120 "$F" company run "$w/linkart" "$w/operator.json" > "$w/linkart.2.out" 2>&1; echo $? > "$w/linkart.2.rc"
check "artifact-invalid: a later run names the recorded refusal too" sh -c "[ '$(rc linkart 2)' = 14 ] && grep -qx 'refusal: artifact-invalid' '$w/linkart.2.out'"

# ---- a check's background children never outlive it (final review I2): the guard kills the check's group on every ending
mkco bgpass "[$(builder lib '' done audit_bgpass.sh)]" 100000 lib
printf '#!/bin/sh\nsleep 71 &\necho "TOTAL 2/2"\n' > "$w/bgpass/audit_bgpass.sh"; chmod +x "$w/bgpass/audit_bgpass.sh"
run bgpass 1
check "a passing check that leaves a sleep behind: accepted, and no sleep is left" sh -c "[ '$(rc bgpass 1)' = 0 ] && sleep 1 && ! pgrep -f '^sleep 71\$' > /dev/null"
mkco bgfail "[$(builder lib '' done audit_bgfail.sh)]" 100000 lib
printf '#!/bin/sh\nsleep 72 &\necho "TOTAL 1/2"\nexit 1\n' > "$w/bgfail/audit_bgfail.sh"; chmod +x "$w/bgfail/audit_bgfail.sh"
run bgfail 1
check "a failing check that leaves a sleep behind: check-failed, and no sleep is left" sh -c "[ '$(rc bgfail 1)' = 13 ] && sleep 1 && ! pgrep -f '^sleep 72\$' > /dev/null"

# ---- the check lock is busy (a guard of another run): check-unavailable WITH a reason, recorded, not a silent hold (M2)
if command -v flock > /dev/null 2>&1; then
  mkco busy "[$(builder lib '' done audit_pass.sh)]" 100000 lib
  flock -x "$w/busy/check.lock" sleep 9 &
  bp=$!
  sleep 0.5
  run busy 1
  wait "$bp"
  check "a busy check lock: check-unavailable with its reason, exit 14, recorded" sh -c "[ '$(rc busy 1)' = 14 ] && grep -qx 'refusal: check-unavailable' '$w/busy.1.out' && grep -q '^reason: another check guard still holds' '$w/busy.1.out' && grep -q 'company.step.check_unavailable' '$w/busy/company.journal'"
fi
exit $fail
