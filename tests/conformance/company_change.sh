#!/bin/sh
# `forge company run` of a `repo.change` step end to end (docs/company.md section 16; docs/company-lifecycle.md section 8.1). The programs
# under test are the forge binary and the worker `workers/repo_change.cho`; this script is the oracle only. The build tool is the stand-in
# scripts/standin_cancho_change.sh (no model, no network, no key), whose mode is the first word of the step's `input`. The checkout is a
# throw-away git repository made here; each step's check applies the patch to the worker's fresh copy of the base commit and runs the
# repository's gate (scripts/gate.sh of the fixture), printing a TOTAL line that Forge reads.
#
# The good path (patch accepted with its digest, a `company.step.change` record, the checkout untouched), the build tool writing the copy it
# was given (the checkout and the fresh copy unchanged), one case per refusal tag of the slice (patch-path-denied for a path outside
# publish_allow and one inside publish_deny, patch-kind-invalid for a rename and a binary hunk, patch-too-large, patch-not-applicable,
# repo-checkout-dirty, repo-checkout-changed, repo-pin-mismatch, repo-unconfigured, repo-kind-mismatch, operator-invalid), a lying worker (a
# patch that applies and breaks the gate: check-failed, held, `retry:` frees it), runs that end without a claim, a build that hangs (its group
# killed), spend recorded, a patch edited after acceptance, publish refusing a change step, and a Forge killed in the middle of a change.
# Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
# Usage: CANCHO=path/to/cancho tests/conformance/company_change.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../.." || exit 1
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
w="$scratch/cc"
mkdir "$w" "$w/workers" "$w/tools" || exit 1
cp scripts/standin_cancho_change.sh "$w/tools/cancho-build" && chmod +x "$w/tools/cancho-build" || exit 1
if ! { $C build src/*.cho --std -o "$w/forge" && $C build workers/repo_change.cho $libs --std -o "$w/workers/repo_change" && $C build workers/check_guard.cho $libs --std -o "$w/workers/check_guard" && $C build workers/repo_publish.cho $libs --std -o "$w/workers/repo_publish"; }; then
  echo "FAIL company change: a program did not build"
  exit 1
fi
F="$w/forge"
ok() { echo "ok   company change: $1"; }
bad() { echo "FAIL company change: $1"; fail=1; }
check() { # name, command...
  name=$1; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
REV=f4ead824f33b291a0ad7620a34a0c1346a7abe4f
git_in() { d=$1; shift; git -C "$d" -c user.email=forge@example.invalid -c user.name=forge -c commit.gpgsign=false "$@"; }
mkrepo() { # name: a library with a gate that a BROKEN word in src/a.cho fails
  d="$w/$1"
  mkdir -p "$d/src/secret" "$d/tests" "$d/docs" "$d/scripts" || exit 1
  printf 'one\ntwo\nthree\n' > "$d/src/a.cho"; printf 'secret\n' > "$d/src/secret/k.cho"; printf 'test\n' > "$d/tests/a_test.cho"
  printf 'readme\n' > "$d/README.md"; printf 'doc\n' > "$d/docs/x.md"; printf '%s\n' "$REV" > "$d/.cancho-rev"
  printf '#!/bin/sh\n! grep -q BROKEN src/a.cho\n' > "$d/scripts/gate.sh"; chmod +x "$d/scripts/gate.sh"
  git init -q "$d" && git_in "$d" add -A && git_in "$d" commit -q -m first || exit 1
}
# the operator file: <name> <checkout> [rev] [kind] [max lines]
operator() {
  rev=${3:-$REV}; kind=${4:-library}; lines=${5:-20}
  cat > "$w/$1.json" <<EOT
{"workers":"$w/workers","tools":"$w/tools","checker":"/opt/cancho/bin/cancho","agent":"stand-in-agent","check_timeout_ms":30000,"build_timeout_ms":10000,
 "repos":{"diff":{"kind":"$kind","checkout":"$2","compiler_rev":"$rev","publish_allow":["src/**","tests/**"],"publish_deny":["src/secret/**"],"max_patch_files":3,"max_patch_lines":$lines}}}
EOT
}
# a company: <name> <input of the step chg> [more steps json, comma first]
mkco() {
  co="$w/$1"
  mkdir -p "$co/steps/chg/ev" "$co/steps/chg2/ev" || exit 1
  printf '{"id":"co","mission":"m","model":{"provider":"stand","name":"m1"},"budget":{"input":100000,"output":100000,"cache_write":100000,"cache_read":100000,"max_cost":10,"price_table":"prices.json"},"human_gates":["go"],"roles":["builder"],"repos":[{"id":"diff","kind":"library"}],"steps":[{"id":"chg","role":"builder","task_type":"repo.change","needs":[],"input":"%s","check":"audit_change.sh","repo":"diff","change_kind":"bug"}%s]}' "$2" "${3:-}" > "$co/company.json"
  printf '{"_note":"test","stand":{"m1":{"in":1.0,"cache_write":1.0,"cache_read":1.0,"out":1.0}}}' > "$co/prices.json"
  cat > "$co/audit_change.sh" <<'EOT'
#!/bin/sh
t=$(mktemp -d) || { echo "TOTAL 0/2"; exit 1; }
cp -r "$2/fresh/." "$t/"
a=0; b=0
if (cd "$t" && patch -p1 -s -i "$1") > /dev/null 2>&1; then a=1; fi
if [ $a = 1 ] && (cd "$t" && sh scripts/gate.sh) > /dev/null 2>&1; then b=1; fi
rm -rf "$t"
echo "TOTAL $((a + b))/2"
EOT
  chmod +x "$co/audit_change.sh"
}
run() { # company, operator -> $w/out, $w/rc
  "$F" company run "$1" "$2" > "$w/out" 2> "$w/err"; echo $? > "$w/rc"
}
rc_is() { [ "$(cat "$w/rc")" = "$1" ]; }
out_has() { grep -qx "$1" "$w/out"; }
count() { grep -c "$2" "$1/company.journal"; }
head_of() { git -C "$1" rev-parse HEAD; }
clean() { [ -z "$(git -C "$1" status --porcelain --untracked-files=all)" ]; }

# ---- the good path
mkrepo ck1; operator op1 "$w/ck1"; mkco co1 "good"
base=$(head_of "$w/ck1"); tree=$(git -C "$w/ck1" rev-parse 'HEAD^{tree}')
run "$w/co1" "$w/op1.json"
check "good: exit 0, the step is accepted and the run is done" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'accepted: chg' '$w/out' && grep -qx 'done: steps accepted 1' '$w/out'"
check "good: change.patch is in the step directory and adds the line the stand-in wrote" sh -c "grep -q '^+edited' '$w/co1/steps/chg/ev/change.patch'"
sha=$(sha256sum "$w/co1/steps/chg/ev/change.patch" | cut -c1-64)
check "good: the accepted record carries the patch's digest, as Forge computed it" sh -c "grep 'company.step.accepted' '$w/co1/company.journal' | grep -q '\"artifact\":\"steps/chg/ev/change.patch\"' && grep 'company.step.accepted' '$w/co1/company.journal' | grep -q '$sha'"
check "good: a company.step.change record names the repository, the base commit, its tree, the digest and the counts" sh -c "grep 'company.step.change' '$w/co1/company.journal' | grep -q '\"repo\":\"diff\",\"base\":\"$base\",\"tree\":\"$tree\",\"patch_sha256\":\"$sha\",\"files\":1,\"added\":1'"
check "good: the checkout is the commit it was, clean, byte for byte (no branch, no file written)" sh -c "[ \"\$(git -C '$w/ck1' rev-parse HEAD)\" = '$base' ] && [ \"\$(git -C '$w/ck1' branch | wc -l)\" = 1 ] && git -C '$w/ck1' status --porcelain --untracked-files=all | wc -l | grep -qx 0 && git -C '$w/ck1' show HEAD:src/a.cho | cmp -s - '$w/ck1/src/a.cho'"
check "good: the build tool got a COPY (ev/base), the kind and the model from the manifest, no ceiling the operator did not set" sh -c "grep -qx 'A:--repo' '$w/co1/steps/chg/ev/work/args.txt' && grep -qx 'A:$w/co1/steps/chg/ev/base' '$w/co1/steps/chg/ev/work/args.txt' && grep -qx 'A:bug' '$w/co1/steps/chg/ev/work/args.txt' && grep -qx 'A:m1' '$w/co1/steps/chg/ev/work/args.txt' && grep -qx 'A:stand-in-agent' '$w/co1/steps/chg/ev/work/args.txt' && ! grep -q 'attempts' '$w/co1/steps/chg/ev/work/args.txt'"
check "good: the request text was given as a file, change.txt, and is not in any argument" sh -c "[ \"\$(cat '$w/co1/steps/chg/ev/change.txt')\" = good ] && ! grep -qx 'A:good' '$w/co1/steps/chg/ev/work/args.txt'"
check "good: the fresh copy is the base commit's tracked files, untouched" sh -c "git -C '$w/ck1' show HEAD:src/a.cho | cmp -s - '$w/co1/steps/chg/ev/fresh/src/a.cho' && [ ! -e '$w/co1/steps/chg/ev/fresh/.git' ]"
run "$w/co1" "$w/op1.json"
check "good: a second run admits nothing again (the step was admitted once)" sh -c "[ \$(cat '$w/rc') = 0 ] && [ \$(grep -c 'company.step.admitted' '$w/co1/company.journal') = 1 ]"
"$F" company status "$w/co1" > "$w/status"
check "good: forge company status shows the step accepted" sh -c "grep -q 'accepted' '$w/status'"

# ---- a derived step: a flow of the manifest, instantiated by an admitted change (docs/company.md section 19)
mkrepo ckd; operator opd "$w/ckd"
cod="$w/cod"
mkdir -p "$cod/steps/chg/ev" "$cod/steps/chg-0001.fix/ev" "$cod/changes" || exit 1
cp "$w/co1/prices.json" "$w/co1/audit_change.sh" "$cod/" || exit 1
printf '{"id":"co","mission":"m","model":{"provider":"stand","name":"m1"},"budget":{"input":100000,"output":100000,"cache_write":100000,"cache_read":100000,"max_cost":10,"price_table":"prices.json"},"human_gates":["go"],"roles":["builder"],"repos":[{"id":"diff","kind":"library"}],"flows":{"bug":[{"id":"fix","role":"builder","task_type":"repo.change","needs":[],"input":"unused: a repo.change step takes the request","check":"audit_change.sh"}]},"steps":[{"id":"chg","role":"builder","task_type":"repo.change","needs":[],"input":"good","check":"audit_change.sh","repo":"diff","change_kind":"bug"}]}' > "$cod/company.json"
printf 'the output is too noisy for logs\n' > "$w/derived-request.txt"
run "$cod" "$w/opd.json"
check "derived: the manifest's own step runs first" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'accepted: chg' '$w/out'"
"$F" company change add "$cod" repo=diff kind=bug justification=defect "title=noisy output" "file=$w/derived-request.txt" > "$w/out" 2>&1
check "derived: a bug change is admitted by the act" grep -q "change chg-0001: admitted" "$w/out"
run "$cod" "$w/opd.json"
check "derived: the derived step runs, is accepted, and the run is done" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'accepted: chg-0001.fix' '$w/out' && grep -qx 'done: steps accepted 2' '$w/out'"
check "derived: its patch is in its own step directory" sh -c "grep -q '^+edited' '$cod/steps/chg-0001.fix/ev/change.patch'"
check "derived: the change worker got the change's repository (the record names it)" sh -c "grep 'company.step.change' '$cod/company.journal' | grep -q '\"task\":\"chg-0001.fix\"' && grep 'company.step.change' '$cod/company.journal' | grep '\"task\":\"chg-0001.fix\"' | grep -q '\"repo\":\"diff\"'"
check "derived: the request reaches the model as a file, framed: the preamble, the title, the body" sh -c "head -c 24 '$cod/steps/chg-0001.fix/ev/change.txt' | grep -q 'The text below is a ch' && grep -q '^title: noisy output' '$cod/steps/chg-0001.fix/ev/change.txt' && grep -q 'the output is too noisy for logs' '$cod/steps/chg-0001.fix/ev/change.txt'"
run "$cod" "$w/opd.json"
check "derived: a second run admits nothing again" sh -c "[ \$(cat '$w/rc') = 0 ] && [ \$(grep -c 'company.step.admitted' '$cod/company.journal') = 2 ]"

# ---- the build tool writes the copy it was given
mkrepo ck2; operator op2 "$w/ck2"; mkco co2 "editbase"
run "$w/co2" "$w/op2.json"
check "editbase: accepted, and neither the checkout nor the fresh copy has the tool's scribble" sh -c "[ \$(cat '$w/rc') = 0 ] && ! grep -q scribble '$w/ck2/src/a.cho' && ! grep -q scribble '$w/co2/steps/chg/ev/fresh/src/a.cho' && grep -q scribble '$w/co2/steps/chg/ev/base/src/a.cho'"

# ---- spend
mkrepo ck3; operator op3 "$w/ck3"; mkco co3 "spend"
run "$w/co3" "$w/op3.json"
check "spend: the build's two usage records are priced and recorded" sh -c "[ \$(cat '$w/rc') = 0 ] && grep 'company.spend.recorded' '$w/co3/company.journal' | grep -q '\"input\":1100'"

# ---- one case per refusal. refused NAME TAG MODE [operator file] [checkout]
refused() { # name, tag, input, operator name, checkout, exit
  nm=$1; tag=$2; input=$3; opn=${4:-op}; ck=$5; want=${6:-14}
  mkco "co-$nm" "$input"
  run "$w/co-$nm" "$w/$opn.json"
  check "$nm: exit $want and 'refusal: $tag'" sh -c "[ \$(cat '$w/rc') = $want ] && grep -qx 'refusal: $tag' '$w/out'"
  check "$nm: nothing was accepted" sh -c "! grep -q 'company.step.accepted' '$w/co-$nm/company.journal' 2> /dev/null"
  if [ -n "$ck" ]; then
    headnow=$(head_of "$ck")
    check "$nm: the checkout is still the commit it was" sh -c "[ \"\$(git -C '$ck' rev-parse HEAD)\" = '$headnow' ] && git -C '$ck' show HEAD:src/a.cho | cmp -s - '$ck/src/a.cho'"
  fi
}
for m in outside denied; do
  mkrepo "ck-$m"; operator "op-$m" "$w/ck-$m"
done
refused outside patch-path-denied outside op-outside "$w/ck-outside"
check "outside: it is held, and a later run names the hold (change-refused) and starts nothing" sh -c "run=1; '$F' company run '$w/co-outside' '$w/op-outside.json' > '$w/out2' 2>&1; [ \$? = 14 ] && grep -qx 'refusal: change-refused' '$w/out2' && grep -q 'retry:chg' '$w/out2' && [ \$(grep -c 'company.step.admitted' '$w/co-outside/company.journal') = 1 ]"
refused denied patch-path-denied denied op-denied "$w/ck-denied"
for m in rename binary big stale nopatch linkpatch lie; do
  mkrepo "ck-$m"; operator "op-$m" "$w/ck-$m"
done
refused rename patch-kind-invalid rename op-rename "$w/ck-rename"
refused binary patch-kind-invalid binary op-binary "$w/ck-binary"
refused big patch-too-large big op-big "$w/ck-big"
refused stale patch-not-applicable stale op-stale "$w/ck-stale"
refused nopatch patch-missing nopatch op-nopatch "$w/ck-nopatch"
refused linkpatch patch-missing linkpatch op-linkpatch "$w/ck-linkpatch"

# the checkout moved under the step, and one that was dirty before it began
mkrepo ck-plant; operator op-plant "$w/ck-plant"
refused plant repo-checkout-changed "plant $w/ck-plant" op-plant ""
check "plant: the planted file is still in the checkout (Forge did not touch it) and the step is held" sh -c "[ -e '$w/ck-plant/planted.txt' ] && grep -q '\"reason\":\"repo-checkout-changed\"' '$w/co-plant/company.journal'"
mkrepo ck-dirty; printf 'x\n' > "$w/ck-dirty/untracked.txt"; operator op-dirty "$w/ck-dirty"
refused dirty repo-checkout-dirty good op-dirty ""
check "dirty: the build tool was never started (no work directory)" sh -c "[ ! -e '$w/co-dirty/steps/chg/ev/work' ]"
mkrepo ck-pin; operator op-pin "$w/ck-pin" 1111111111111111111111111111111111111111
refused pin repo-pin-mismatch good op-pin ""
check "pin: nothing was built" sh -c "[ ! -e '$w/co-pin/steps/chg/ev/work' ]"
mkrepo ck-nogit; : > /dev/null
rm -rf "$w/ck-nogit/.git"; operator op-nogit "$w/ck-nogit"
refused nogit repo-unusable good op-nogit ""

# the operator file and the manifest disagree
mkrepo ck-un; printf '{"workers":"%s","tools":"%s","checker":"/opt/cancho/bin/cancho","agent":"stand-in-agent"}' "$w/workers" "$w/tools" > "$w/op-un.json"
refused unconfigured repo-unconfigured good op-un "" 1
operator op-kind "$w/ck-un" "$REV" service
refused kindmismatch repo-kind-mismatch good op-kind "" 1
printf '{"workers":"%s","repos":{"diff":{"kind":"library"}}}' "$w/workers" > "$w/op-bad.json"
refused badrow operator-invalid good op-bad "" 1
check "badrow: the reason names the row" sh -c "grep -q '^reason: repos: ' '$w/out'"
printf '{"workers":"%s","tools":"%s","repos":{"diff":{"kind":"library","checkout":"%s","compiler_rev":"%s","publish_allow":["src/**"],"max_patch_files":3,"max_patch_lines":9}}}' "$w/workers" "$w/tools" "$w/ck-un" "$REV" > "$w/op-noagent.json"
refused noagent operator-invalid good op-noagent "" 1

# ---- a lying worker: the patch applies, the repository's gate fails
refused lie check-failed lie op-lie "$w/ck-lie" 13
check "lie: score 1/2 and no company.step.accepted; retry:chg frees it and the step is admitted again" sh -c "grep -qx 'score: 1/2' '$w/out' && '$F' company decide '$w/co-lie' retry:chg approved again > /dev/null && '$F' company run '$w/co-lie' '$w/op-lie.json' > /dev/null 2>&1; [ \$(grep -c 'company.step.admitted' '$w/co-lie/company.journal') = 2 ]"

# ---- runs that end without a claim: step-failed, nothing held, the next run admits the step again
for m in stuck:change-stuck provider:change-provider-error usage:change-refused-args; do
  mode=${m%%:*}; code=${m##*:}
  mkrepo "ck-$mode"; operator "op-$mode" "$w/ck-$mode"; mkco "co-$mode" "$mode"
  run "$w/co-$mode" "$w/op-$mode.json"
  check "$mode: exit 15 step-failed with worker-error $code, nothing held" sh -c "[ \$(cat '$w/rc') = 15 ] && grep -qx 'refusal: step-failed' '$w/out' && grep -qx 'worker-error: $code' '$w/out' && ! grep -q check_unavailable '$w/co-$mode/company.journal'"
  run "$w/co-$mode" "$w/op-$mode.json"
  check "$mode: the next run admits it again" sh -c "[ \$(grep -c 'company.step.admitted' '$w/co-$mode/company.journal') = 2 ]"
done
mkrepo ck-hang; operator op-hang "$w/ck-hang"; mkco co-hang "hang"
run "$w/co-hang" "$w/op-hang.json"
pid=$(cat "$w/co-hang/steps/chg/ev/work/pids.txt" 2> /dev/null)
check "hang: the build is ended at the worker's deadline (change-timeout, exit 15) and its group is gone" sh -c "[ \$(cat '$w/rc') = 15 ] && grep -qx 'worker-error: change-timeout' '$w/out' && [ -n '$pid' ] && ! kill -0 '$pid' 2> /dev/null"

# ---- publish stays the only verb that writes a checkout, and it does not take a change step
printf '{"workers":"%s","tools":"%s","checker":"/opt/cancho/bin/cancho","agent":"stand-in-agent","repos":{"diff":{"kind":"library","checkout":"%s","compiler_rev":"%s","publish_allow":["src/**"],"max_patch_files":3,"max_patch_lines":9},"x":{"kind":"library","checkout":"%s","compiler_rev":"%s","publish_allow":["src/**"],"max_patch_files":3,"max_patch_lines":9}},"publish":{"chg":{"repo":"alpibrusl/cancho-diff","checkout":"%s","files":{"project.cho":"src/diff.cho"}}}}' "$w/workers" "$w/tools" "$w/ck1" "$REV" "$w/ck1" "$REV" "$w/ck1" > "$w/op-pub.json"
"$F" company publish "$w/co1" "$w/op-pub.json" chg forge/chg > "$w/out" 2> /dev/null; echo $? > "$w/rc"
check "publish: a change step is not a step publish takes (publish-step-not-accepted), the checkout untouched" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'refusal: publish-step-not-accepted' '$w/out' && [ -z \"\$(git -C '$w/ck1' status --porcelain --untracked-files=all)\" ] && [ \"\$(git -C '$w/ck1' branch | wc -l)\" = 1 ]"

# ---- a patch edited after acceptance: the next step that needs it is refused
mkrepo ck4; operator op4 "$w/ck4"
mkco co4 "good" ',{"id":"chg2","role":"builder","task_type":"repo.change","needs":["chg"],"input":"good","check":"audit_change.sh","repo":"diff","gate":"go"}'
run "$w/co4" "$w/op4.json"
check "needs: the first change is accepted and the second waits at its gate (exit 10)" sh -c "[ \$(cat '$w/rc') = 10 ] && grep -qx 'gate: go' '$w/out' && [ \$(grep -c 'company.step.accepted' '$w/co4/company.journal') = 1 ]"
printf 'tampered\n' >> "$w/co4/steps/chg/ev/change.patch"
"$F" company decide "$w/co4" go approved ok > /dev/null
run "$w/co4" "$w/op4.json"
check "needs: an edited patch is a need that changed: artifact-invalid, needs-changed, exit 14, the second step never admitted" sh -c "[ \$(cat '$w/rc') = 14 ] && grep -qx 'refusal: artifact-invalid' '$w/out' && grep -qx 'reason: needs-changed' '$w/out' && ! grep -q '\"task\":\"chg2\"' '$w/co4/company.journal'"

# ---- a Forge killed in the middle of a change: the step is admitted again, once more, and accepted once
mkrepo ck6; operator op6 "$w/ck6"; mkco co6 "slow $w/release6"
"$F" company run "$w/co6" "$w/op6.json" > /dev/null 2>&1 &
fpid=$!
n=0; while [ ! -e "$w/co6/steps/chg/ev/work/building" ] && [ $n -lt 100 ]; do sleep 0.2; n=$((n + 1)); done
kill -9 "$fpid" 2> /dev/null
pkill -9 -f "$w/tools/cancho-build" 2> /dev/null
pkill -9 -f "$w/workers/repo_change" 2> /dev/null
sleep 0.5
check "kill: Forge died with the step admitted and not accepted" sh -c "[ \$(grep -c 'company.step.admitted' '$w/co6/company.journal') = 1 ] && ! grep -q 'company.step.accepted' '$w/co6/company.journal'"
: > "$w/release6"
run "$w/co6" "$w/op6.json"
check "kill: the next run admits it again and accepts it once" sh -c "[ \$(cat '$w/rc') = 0 ] && [ \$(grep -c 'company.step.admitted' '$w/co6/company.journal') = 2 ] && [ \$(grep -c 'company.step.accepted' '$w/co6/company.journal') = 1 ]"
run "$w/co6" "$w/op6.json"
check "kill: and a third run does nothing" sh -c "[ \$(grep -c 'company.step.admitted' '$w/co6/company.journal') = 2 ]"

exit "$fail"
