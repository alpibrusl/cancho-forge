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
if ! { $C build src/*.cho --std -o "$w/forge" && $C build workers/repo_change.cho $libs --std -o "$w/workers/repo_change" && $C build workers/check_guard.cho $libs --std -o "$w/workers/check_guard" && $C build workers/repo_publish.cho $libs --std -o "$w/workers/repo_publish" && $C build workers/authority_review.cho $libs --std -o "$w/workers/authority_review"; }; then
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
  printf 'readme\n' > "$d/README.md"; printf 'doc\n' > "$d/docs/x.md"; printf 'performs\n    clock\nnever touches\n    the network\n' > "$d/docs/authority.txt"; printf '%s\n' "$REV" > "$d/.cancho-rev"
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
mkdir -p "$cod/steps/chg/ev" "$cod/changes" || exit 1
cp "$w/co1/prices.json" "$w/co1/audit_change.sh" "$cod/" || exit 1
printf '{"id":"co","mission":"m","model":{"provider":"stand","name":"m1"},"budget":{"input":100000,"output":100000,"cache_write":100000,"cache_read":100000,"max_cost":10,"price_table":"prices.json"},"human_gates":["go"],"roles":["builder"],"repos":[{"id":"diff","kind":"library"}],"flows":{"bug":[{"id":"fix","role":"builder","task_type":"repo.change","needs":[],"input":"unused: a repo.change step takes the request","check":"audit_change.sh"}]},"steps":[{"id":"chg","role":"builder","task_type":"repo.change","needs":[],"input":"good","check":"audit_change.sh","repo":"diff","change_kind":"bug"}]}' > "$cod/company.json"
printf 'the output is too noisy for logs\n' > "$w/derived-request.txt"
run "$cod" "$w/opd.json"
check "derived: the manifest's own step runs first" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'accepted: chg' '$w/out'"
"$F" company change add "$cod" repo=diff kind=bug justification=defect "title=noisy output" "file=$w/derived-request.txt" > "$w/out" 2>&1
check "derived: a bug change is admitted by the act" grep -q "change chg-0001: admitted" "$w/out"
run "$cod" "$w/opd.json"
check "derived: the derived step runs, is accepted, and the run is done" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'accepted: chg-0001.fix' '$w/out' && grep -qx 'done: steps accepted 2' '$w/out'"
check "derived: Forge made its directory (the provisioner): steps/chg-0001.fix/ev, a real directory, not group- or world-writable" sh -c "[ -d '$cod/steps/chg-0001.fix/ev' ] && [ ! -L '$cod/steps/chg-0001.fix' ] && [ -z \"\$(find '$cod/steps/chg-0001.fix' -maxdepth 0 -perm -020)\" ] && [ -z \"\$(find '$cod/steps/chg-0001.fix' -maxdepth 0 -perm -002)\" ]"
check "derived: its patch is in its own step directory" sh -c "grep -q '^+edited' '$cod/steps/chg-0001.fix/ev/change.patch'"
check "derived: the change worker got the change's repository (the record names it)" sh -c "grep 'company.step.change' '$cod/company.journal' | grep -q '\"task\":\"chg-0001.fix\"' && grep 'company.step.change' '$cod/company.journal' | grep '\"task\":\"chg-0001.fix\"' | grep -q '\"repo\":\"diff\"'"
check "derived: the request reaches the model as a file, framed: the preamble, the title, the body" sh -c "head -c 24 '$cod/steps/chg-0001.fix/ev/change.txt' | grep -q 'The text below is a ch' && grep -q '^title: noisy output' '$cod/steps/chg-0001.fix/ev/change.txt' && grep -q 'the output is too noisy for logs' '$cod/steps/chg-0001.fix/ev/change.txt'"
run "$cod" "$w/opd.json"
check "derived: a second run admits nothing again" sh -c "[ \$(cat '$w/rc') = 0 ] && [ \$(grep -c 'company.step.admitted' '$cod/company.journal') = 2 ]"
printf 'the second one\n' > "$w/derived-request2.txt"
: > "$cod/steps/chg-0002.fix"
"$F" company change add "$cod" repo=diff kind=bug justification=defect "title=second" "file=$w/derived-request2.txt" > "$w/out" 2>&1
run "$cod" "$w/opd.json"
check "derived: a file where its directory should be is not replaced: step-dir-missing, exit 1, the step not admitted" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'refusal: step-dir-missing' '$w/out' && [ -f '$cod/steps/chg-0002.fix' ] && [ \$(grep -c 'company.step.admitted' '$cod/company.journal') = 2 ]"
rm -f "$cod/steps/chg-0002.fix"
run "$cod" "$w/opd.json"
check "derived: with the file gone Forge makes the directory and the second change is done" sh -c "[ \$(cat '$w/rc') = 0 ] && [ -d '$cod/steps/chg-0002.fix/ev' ] && grep -qx 'done: steps accepted 3' '$w/out'"
"$F" company run "$cod" "$w/opd.json" now=2026-11-02 > "$w/out" 2>&1; echo $? > "$w/rc"
check "clock: run with now= puts the day in the journal once (exit 0, one company.clock.set record)" sh -c "[ \$(cat '$w/rc') = 0 ] && [ \$(grep -c 'company.clock.set' '$cod/company.journal') = 1 ] && '$F' company status '$cod' format=json | grep -q '\"clock\":\"2026-11-02\"'"
"$F" company run "$cod" "$w/opd.json" now=2026-11-02 > "$w/out" 2>&1
check "clock: the same day again writes no second record" sh -c "[ \$(grep -c 'company.clock.set' '$cod/company.journal') = 1 ]"
lines_before=$(wc -l < "$cod/company.journal" | tr -d ' ')
"$F" company run "$cod" "$w/opd.json" now=2026-11-01 > "$w/out" 2>&1; echo $? > "$w/rc"
check "clock: an earlier day is clock-went-back, exit 1, nothing written" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'refusal: clock-went-back' '$w/out' && [ \$(wc -l < '$cod/company.journal' | tr -d ' ') = $lines_before ]"

# ---- the rolling and per-change caps (docs/company.md section 23): a run stops before a model step that a cap holds back
# mkcap NAME BUDGET-EXTRA FLOW: a company with one model step of its own and a flow `bug`; the checkout is a fresh repository
mkcap() {
  mkrepo "ck$1"; operator "op$1" "$w/ck$1"
  c="$w/$1"
  mkdir -p "$c/steps/chg/ev" "$c/changes" || exit 1
  cp "$w/co1/prices.json" "$w/co1/audit_change.sh" "$c/" || exit 1
  printf '{"id":"co","mission":"m","model":{"provider":"stand","name":"m1"},"budget":{"input":100000,"output":100000,"cache_write":100000,"cache_read":100000,"max_cost":10,"price_table":"prices.json"%s},"human_gates":["go"],"roles":["builder"],"repos":[{"id":"diff","kind":"library"}],"flows":{"bug":%s},"steps":[{"id":"chg","role":"builder","task_type":"repo.change","needs":[],"input":"good","check":"audit_change.sh","repo":"diff","change_kind":"bug"}]}' "$2" "$3" > "$c/company.json"
}
TWO='[{"id":"fix","role":"builder","task_type":"repo.change","needs":[],"input":"x","check":"audit_change.sh"},{"id":"fix2","role":"builder","task_type":"repo.change","needs":["fix"],"input":"x","check":"audit_change.sh"}]'
printf 'the output is too noisy for logs\n' > "$w/cap-request.txt"

mkcap cap1 ',"per_change":{"max_attempts":1}' "$TWO"
run "$w/cap1" "$w/opcap1.json"
"$F" company change add "$w/cap1" repo=diff kind=bug justification=defect "title=noisy output" "file=$w/cap-request.txt" > "$w/out" 2>&1
run "$w/cap1" "$w/opcap1.json"
check "caps: one attempt per change: the first model step of the change runs, the second is held (change-attempts-exhausted, change named, exit 12)" sh -c "[ \$(cat '$w/rc') = 12 ] && grep -qx 'refusal: change-attempts-exhausted' '$w/out' && grep -qx 'change: chg-0001' '$w/out' && grep -q 'accepted' '$w/cap1/company.journal' && grep -c 'company.step.accepted' '$w/cap1/company.journal' | grep -qx 2"
check "caps: the held step was not admitted" sh -c "! grep -q '\"task\":\"chg-0001.fix2\"' '$w/cap1/company.journal'"

mkcap cap2 ',"per_change":{"max_cost":0}' "$TWO"
run "$w/cap2" "$w/opcap2.json"
"$F" company change add "$w/cap2" repo=diff kind=bug justification=defect "title=noisy output" "file=$w/cap-request.txt" > "$w/out" 2>&1
run "$w/cap2" "$w/opcap2.json"
check "caps: a per-change cost cap of nothing holds the change's model steps (budget-exhausted, window: change, change named, exit 12)" sh -c "[ \$(cat '$w/rc') = 12 ] && grep -qx 'refusal: budget-exhausted' '$w/out' && grep -qx 'window: change' '$w/out' && grep -qx 'change: chg-0001' '$w/out'"
check "caps: and nothing of the change was admitted" sh -c "! grep -q 'chg-0001.fix' '$w/cap2/company.journal'"

mkcap cap3 ',"rolling":{"days":7,"max_cost":0}' "$TWO"
"$F" company run "$w/cap3" "$w/opcap3.json" now=2026-11-02 > "$w/out" 2> "$w/err"; echo $? > "$w/rc"
check "caps: a rolling cap of nothing, with the day given, holds every model step (budget-exhausted, window: rolling, exit 12)" sh -c "[ \$(cat '$w/rc') = 12 ] && grep -qx 'refusal: budget-exhausted' '$w/out' && grep -qx 'window: rolling' '$w/out' && ! grep -q 'company.step.admitted' '$w/cap3/company.journal'"
run "$w/cap3" "$w/opcap3.json"
check "caps: the day stays in the journal, so a run without now= is held too" sh -c "[ \$(cat '$w/rc') = 12 ] && grep -qx 'window: rolling' '$w/out'"

mkcap cap4 ',"rolling":{"days":7,"max_cost":0}' "$TWO"
run "$w/cap4" "$w/opcap4.json"
check "caps: a rolling cap with no day anywhere in the journal has no window: the run goes on (exit 0)" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'accepted: chg' '$w/out'"

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

# ---- publish of an accepted patch (docs/company.md section 21): applied in cancho to the checkout at the base commit, on a fresh branch, with its
# provenance, committed, never pushed
git -C "$w/ck1" remote add origin https://github.com/alpibrusl/cancho-diff.git
git -C "$w/ck1" config user.email forge@example.invalid; git -C "$w/ck1" config user.name forge
home=$(git -C "$w/ck1" symbolic-ref --short HEAD)
pubop() { # name, extra row fields
  printf '{"workers":"%s","tools":"%s","checker":"/opt/cancho/bin/cancho","agent":"stand-in-agent","repos":{"diff":{"kind":"library","slug":"alpibrusl/cancho-diff","checkout":"%s","compiler_rev":"%s","publish_allow":["src/**"],"max_patch_files":3,"max_patch_lines":9%s}}}' "$w/workers" "$w/tools" "$w/ck1" "$REV" "$2" > "$w/$1.json"
}
pubop op-pub ""
"$F" company publish "$w/co1" "$w/op-pub.json" chg forge/chg > "$w/out" 2> /dev/null; echo $? > "$w/rc"
check "publish: an accepted change step is published: exit 0, published and commit lines" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'published: forge/chg' '$w/out' && grep -q '^commit: ' '$w/out'"
check "publish: the branch holds the patched file (the patch applied in cancho) and a provenance of its own" sh -c "git -C '$w/ck1' show forge/chg:src/a.cho | tail -1 | grep -qx edited && git -C '$w/ck1' show forge/chg:docs/provenance/chg.md | grep -q 'base commit' && git -C '$w/ck1' show forge/chg:docs/provenance/chg.md | grep -q '$base'"
check "publish: exactly the patch's file and the provenance changed" sh -c "[ \"\$(git -C '$w/ck1' diff --name-only $home forge/chg | sort | tr '\\n' ' ')\" = 'docs/provenance/chg.md src/a.cho ' ]"
check "publish: the checkout is back on its branch, clean, and its file is the one it was" sh -c "[ \"\$(git -C '$w/ck1' symbolic-ref --short HEAD)\" = '$home' ] && [ -z \"\$(git -C '$w/ck1' status --porcelain --untracked-files=all)\" ] && ! tail -1 '$w/ck1/src/a.cho' | grep -qx edited"
check "publish: steps/chg/pr.md is written and nothing was pushed" sh -c "[ -s '$w/co1/steps/chg/pr.md' ] && [ -z \"\$(git -C '$w/ck1' for-each-ref refs/remotes)\" ]"
"$F" company publish "$w/co1" "$w/op-pub.json" chg forge/chg > "$w/out" 2> /dev/null; echo $? > "$w/rc"
check "publish: the same branch again is publish-branch-exists, exit 1" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'refusal: publish-branch-exists' '$w/out'"

# ---- the authority reviewer on the published commit (docs/reviewer.md section 2, docs/company.md section 25): `forge company authority`
printf '#!/bin/sh\nprintf "performs\\n    clock\\nnever touches\\n    the network\\n"\n' > "$w/stubc" && chmod +x "$w/stubc"
pubop op-auth1 ",\"compiler\":\"$w/stubc\",\"authority\":[{\"programs\":[\"src/*.cho\"],\"std\":true,\"ceiling\":\"docs/authority.txt\"}]"
pubop op-auth2 ",\"compiler\":\"$w/stubc\",\"authority\":[{\"programs\":[\"src/*.cho\"],\"ceiling\":\"docs/authority.txt\"},{\"programs\":[\"src/*.cho\"],\"ceiling\":\"README.md\"}]"
pubcommit=$(git -C "$w/ck1" rev-parse forge/chg)
"$F" company authority "$w/co1" "$w/op-auth1.json" chg "$pubcommit" > "$w/out" 2> /dev/null; echo $? > "$w/rc"
check "authority: a published commit within its ceiling is equal: exit 0, the verdict and the task in verification" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'authority: docs/authority.txt' '$w/out' && grep -qx 'verdict: equal' '$w/out' && grep -qx 'state: verification' '$w/out'"
check "authority: the evidence is beneath the step: ceiling.txt, head.txt and report.json in steps/chg/authority-0" sh -c "[ -s '$w/co1/steps/chg/authority-0/ceiling.txt' ] && [ -s '$w/co1/steps/chg/authority-0/head.txt' ] && grep -q '\"verdict\":\"equal\"' '$w/co1/steps/chg/authority-0/report.json'"
check "authority: the checkout is untouched (still on its branch, clean) and no tree is left behind" sh -c "[ \"\$(git -C '$w/ck1' symbolic-ref --short HEAD)\" = '$home' ] && [ -z \"\$(git -C '$w/ck1' status --porcelain --untracked-files=all)\" ] && [ ! -e '$w/co1/steps/chg/authority-0/tree' ]"
"$F" company authority "$w/co1" "$w/op-auth2.json" chg "$pubcommit" > "$w/out" 2> /dev/null; echo $? > "$w/rc"
check "authority: two entries, the second with no ceiling at the base: ceiling-missing, exit 5, the rule tag printed" sh -c "[ \$(cat '$w/rc') = 5 ] && grep -qx 'authority: README.md' '$w/out' && grep -qx 'rule: authority-ceiling-missing' '$w/out' && grep -qx 'verdict: equal' '$w/out'"
"$F" company authority "$w/co1" "$w/op-auth1.json" chg not-a-commit > "$w/out" 2> /dev/null; echo $? > "$w/rc"
check "authority: a commit that is not 40 hex is authority-commit-invalid, exit 1" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'refusal: authority-commit-invalid' '$w/out'"
"$F" company authority "$w/co1" "$w/op-pub.json" chg "$pubcommit" > "$w/out" 2> /dev/null; echo $? > "$w/rc"
check "authority: a repos row with no authority is authority-not-configured, exit 1" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'refusal: authority-not-configured' '$w/out'"
"$F" company authority "$w/co1" "$w/op-auth1.json" nosuch "$pubcommit" > "$w/out" 2> /dev/null; echo $? > "$w/rc"
check "authority: a step that is not an accepted repo.change step is publish-step-not-accepted, exit 1" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'refusal: publish-step-not-accepted' '$w/out'"
# ---- the authority reviewer as a step of the company (docs/company.md section 26): a reviewer `repo.authority` step that needs the repo.change step
printf '#!/bin/sh\nprintf "performs\\n    clock\\n    the network\\nnever touches\\n    the disk\\n"\n' > "$w/stubw" && chmod +x "$w/stubw"
pubop op-wide ",\"compiler\":\"$w/stubw\",\"authority\":[{\"programs\":[\"src/*.cho\"],\"ceiling\":\"docs/authority.txt\"}]"
mkco coa good ',{"id":"rev","role":"reviewer","task_type":"repo.authority","needs":["chg"],"input":"review"}'
sed 's/"roles":\["builder"\]/"roles":["builder","reviewer"]/' "$w/coa/company.json" > "$w/coa/company.json.new" && mv "$w/coa/company.json.new" "$w/coa/company.json"
mkdir -p "$w/coa/steps/rev/ev"
run "$w/coa" "$w/op-auth1.json"
check "step: the repo.change step is accepted, the reviewer step before any publish is authority-unpublished: exit 1, not admitted" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'accepted: chg' '$w/out' && grep -qx 'refusal: authority-unpublished' '$w/out' && [ \$(grep -c 'company.step.admitted' '$w/coa/company.journal') = 1 ]"
cp -R "$w/coa" "$w/cob"
"$F" company publish "$w/coa" "$w/op-pub.json" chg forge/rev-a > "$w/out" 2> /dev/null; echo $? > "$w/rc"
sta=$(sed -n 's/^commit: //p' "$w/out")
"$F" company publish "$w/cob" "$w/op-pub.json" chg forge/rev-b > "$w/out" 2> /dev/null; echo $? > "$w/rc"
check "step: publish records the commit it printed in the company journal (company.step.published, branch and commit)" sh -c "[ \$(cat '$w/rc') = 0 ] && tail -1 '$w/coa/company.journal' | grep -q '\"kind\":\"company.step.published\",\"task\":\"chg\",\"branch\":\"forge/rev-a\",\"commit\":\"$sta\"'"
check "step: the journal with a published record still replays: status is not refused" sh -c "'$F' company status '$w/coa' > '$w/status' 2>&1 && grep -q 'rev' '$w/status'"
run "$w/coa" "$w/op-auth1.json"
check "step: a published commit within its ceiling: the step is accepted and the company is done" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'authority: docs/authority.txt' '$w/out' && grep -qx 'verdict: equal' '$w/out' && grep -qx 'accepted: rev' '$w/out' && grep -qx 'done: steps accepted 2' '$w/out'"
check "step: Forge hashed authority.txt and recorded it; the evidence of the entry is beneath the step" sh -c "grep 'company.step.accepted' '$w/coa/company.journal' | grep -q '\"task\":\"rev\",\"artifact\":\"steps/rev/ev/authority.txt\"' && [ -s '$w/coa/steps/rev/ev/authority.txt' ] && grep -q '\"verdict\":\"equal\"' '$w/coa/steps/rev/ev/authority-0/report.json'"
run "$w/cob" "$w/op-wide.json"
check "step: a published commit wider than its ceiling holds the step: check-failed, exit 13, the verdict printed, not accepted" sh -c "[ \$(cat '$w/rc') = 13 ] && grep -qx 'verdict: wider' '$w/out' && grep -qx 'refusal: check-failed' '$w/out' && ! grep -q 'accepted\",\"task\":\"rev' '$w/cob/company.journal'"
run "$w/cob" "$w/op-wide.json"
check "step: the next run does not start it again by itself: held, exit 13, admitted once" sh -c "[ \$(cat '$w/rc') = 13 ] && [ \$(grep -c '\"task\":\"rev\"' '$w/cob/company.journal' | tr -d ' ') = 2 ]"
# ---- repo.publish as a step of the company (docs/auto-publish.md): Forge makes the local branch itself, where the operator granted a prefix
mkrepo ckap
git -C "$w/ckap" remote add origin https://github.com/alpibrusl/cancho-diff.git
git -C "$w/ckap" config user.email forge@example.invalid; git -C "$w/ckap" config user.name forge
aprow() { # name, extra top-level fields
  printf '{"workers":"%s","tools":"%s","checker":"/opt/cancho/bin/cancho","agent":"stand-in-agent"%s,"repos":{"diff":{"kind":"library","slug":"alpibrusl/cancho-diff","checkout":"%s","compiler_rev":"%s","publish_allow":["src/**"],"max_patch_files":3,"max_patch_lines":9,"compiler":"%s","authority":[{"programs":["src/*.cho"],"std":true,"ceiling":"docs/authority.txt"}]}}}' "$w/workers" "$w/tools" "$2" "${3:-$w/ckap}" "$REV" "$w/stubc" > "$w/$1.json"
}
aprow op-ap-no ""
aprow op-ap ",\"auto_publish\":{\"diff\":{\"branch_prefix\":\"forge/\"}}"
mkco coap good ',{"id":"pub","role":"system","task_type":"repo.publish","needs":["chg"],"input":"publish"},{"id":"rev","role":"reviewer","task_type":"repo.authority","needs":["chg","pub"],"input":"review"}'
sed 's/"roles":\["builder"\]/"roles":["builder","reviewer"]/' "$w/coap/company.json" > "$w/coap/company.json.new" && mv "$w/coap/company.json.new" "$w/coap/company.json"
mkdir -p "$w/coap/steps/pub/ev" "$w/coap/steps/rev/ev"
run "$w/coap" "$w/op-ap-no.json"
check "autopub: no auto_publish row for the repository: publish-auto-not-granted, exit 1, the step not admitted, no branch" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'accepted: chg' '$w/out' && grep -qx 'refusal: publish-auto-not-granted' '$w/out' && ! grep -q '\"task\":\"pub\"' '$w/coap/company.journal' && [ \"\$(git -C '$w/ckap' branch | wc -l | tr -d ' ')\" = 1 ]"
cp -R "$w/coap" "$w/coaq"
"$F" company publish "$w/coaq" "$w/op-ap.json" chg forge/person > "$w/out" 2> /dev/null; echo $? > "$w/rc"
personc=$(sed -n 's/^commit: //p' "$w/out")
run "$w/coaq" "$w/op-ap.json"
check "autopub: a publish a person already made is adopted: the step is accepted with that commit, no second branch" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'accepted: pub' '$w/out' && grep -qx 'commit $personc' '$w/coaq/steps/pub/ev/publish.txt' && ! git -C '$w/ckap' rev-parse --verify --quiet refs/heads/forge/co-chg > /dev/null && [ \$(grep -c 'company.step.published' '$w/coaq/company.journal' | tr -d ' ') = 1 ]"
run "$w/coap" "$w/op-ap.json"
check "autopub: granted, the flow runs to its end with no person command between: pub and rev accepted, done" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'accepted: pub' '$w/out' && grep -qx 'accepted: rev' '$w/out' && grep -qx 'done: steps accepted 3' '$w/out'"
check "autopub: the branch is the operator's prefix, the company and the step, and the journal records it" sh -c "git -C '$w/ckap' rev-parse --verify --quiet refs/heads/forge/co-chg > /dev/null && grep 'company.step.published' '$w/coap/company.journal' | grep -q '\"task\":\"chg\",\"branch\":\"forge/co-chg\"'"
check "autopub: publish.txt names the branch and the commit, and Forge hashed it" sh -c "grep -qx 'branch forge/co-chg' '$w/coap/steps/pub/ev/publish.txt' && grep -q 'commit ' '$w/coap/steps/pub/ev/publish.txt' && grep 'company.step.accepted' '$w/coap/company.journal' | grep -q '\"task\":\"pub\",\"artifact\":\"steps/pub/ev/publish.txt\"'"
check "autopub: the checkout is on its branch, clean, nothing was pushed (no remote refs)" sh -c "[ -z \"\$(git -C '$w/ckap' status --porcelain --untracked-files=all)\" ] && [ -z \"\$(git -C '$w/ckap' for-each-ref refs/remotes)\" ]"
run "$w/coap" "$w/op-ap.json"
check "autopub: a second run does nothing: pub admitted once and published once" sh -c "[ \$(grep -c '\"task\":\"pub\"' '$w/coap/company.journal' | tr -d ' ') = 2 ] && [ \$(grep -c 'company.step.published' '$w/coap/company.journal' | tr -d ' ') = 1 ]"
# ---- a crash between the commit and the journal record (docs/auto-publish.md section 4): the branch is adopted when it is what the publish would make
apsteps=',{"id":"pub","role":"system","task_type":"repo.publish","needs":["chg"],"input":"publish"},{"id":"rev","role":"reviewer","task_type":"repo.authority","needs":["chg","pub"],"input":"review"}'
mkcr() { # n: checkout ckar<n> and company coar<n>, the change accepted, the publish refused for want of a grant
  mkrepo ckar$1
  git -C "$w/ckar$1" remote add origin https://github.com/alpibrusl/cancho-diff.git
  git -C "$w/ckar$1" config user.email forge@example.invalid; git -C "$w/ckar$1" config user.name forge
  aprow op-ar$1 ",\"auto_publish\":{\"diff\":{\"branch_prefix\":\"forge/\"}}" "$w/ckar$1"
  aprow op-arno$1 "" "$w/ckar$1"
  mkco coar$1 good "$apsteps"
  sed 's/"roles":\["builder"\]/"roles":["builder","reviewer"]/' "$w/coar$1/company.json" > "$w/coar$1/company.json.new" && mv "$w/coar$1/company.json.new" "$w/coar$1/company.json"
  mkdir -p "$w/coar$1/steps/pub/ev" "$w/coar$1/steps/rev/ev"
  run "$w/coar$1" "$w/op-arno$1.json"
  home=$(git -C "$w/ckar$1" symbolic-ref --short HEAD)
}
lose_record() { sed '$d' "$w/$1/company.journal" > "$w/j.tmp" && mv "$w/j.tmp" "$w/$1/company.journal"; }
mkcr 1
"$F" company publish "$w/coar1" "$w/op-ar1.json" chg forge/co-chg > "$w/out" 2> /dev/null
crashc=$(sed -n 's/^commit: //p' "$w/out")
lose_record coar1
check "crash: the branch has the commit and the journal has lost its published record" sh -c "[ \"\$(git -C '$w/ckar1' rev-parse refs/heads/forge/co-chg)\" = '$crashc' ] && ! grep -q company.step.published '$w/coar1/company.journal'"
run "$w/coar1" "$w/op-ar1.json"
check "crash: a branch that is what the publish would make is adopted: pub and rev accepted, done" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'accepted: pub' '$w/out' && grep -qx 'accepted: rev' '$w/out' && grep -qx 'done: steps accepted 3' '$w/out'"
check "crash: the journal records the branch and the commit it already had, once; publish.txt names them" sh -c "[ \$(grep -c company.step.published '$w/coar1/company.journal' | tr -d ' ') = 1 ] && grep company.step.published '$w/coar1/company.journal' | grep -q '\"branch\":\"forge/co-chg\",\"commit\":\"$crashc\"' && grep -qx 'commit $crashc' '$w/coar1/steps/pub/ev/publish.txt'"
check "crash: no second commit and no second branch; the checkout is where it was and clean" sh -c "[ \"\$(git -C '$w/ckar1' rev-parse refs/heads/forge/co-chg)\" = '$crashc' ] && [ \"\$(git -C '$w/ckar1' branch | wc -l | tr -d ' ')\" = 2 ] && [ \"\$(git -C '$w/ckar1' symbolic-ref --short HEAD)\" = '$home' ] && [ -z \"\$(git -C '$w/ckar1' status --porcelain --untracked-files=all)\" ]"
mkcr 2
git_in "$w/ckar2" checkout -q -b forge/co-chg; printf 'other\n' >> "$w/ckar2/README.md"; git_in "$w/ckar2" commit -q -a -m other; git_in "$w/ckar2" checkout -q "$home"
strangec=$(git -C "$w/ckar2" rev-parse refs/heads/forge/co-chg)
run "$w/coar2" "$w/op-ar2.json"
check "crash: a branch of the same name that is not ours is not adopted: held, exit 14, publish-refused" sh -c "[ \$(cat '$w/rc') = 14 ] && grep -qx 'refusal: publish-branch-exists' '$w/out' && grep -q '\"kind\":\"company.step.check_unavailable\",\"task\":\"pub\",\"reason\":\"publish-refused\"' '$w/coar2/company.journal' && ! grep -q company.step.published '$w/coar2/company.journal'"
check "crash: and it is left alone: same tip, checkout where it was, clean" sh -c "[ \"\$(git -C '$w/ckar2' rev-parse refs/heads/forge/co-chg)\" = '$strangec' ] && [ \"\$(git -C '$w/ckar2' symbolic-ref --short HEAD)\" = '$home' ] && [ -z \"\$(git -C '$w/ckar2' status --porcelain --untracked-files=all)\" ]"
mkcr 3
"$F" company publish "$w/coar3" "$w/op-ar3.json" chg forge/co-chg > "$w/out" 2> /dev/null
lose_record coar3
git_in "$w/ckar3" checkout -q forge/co-chg; git_in "$w/ckar3" commit -q --amend -m "a message of someone else's"; git_in "$w/ckar3" checkout -q "$home"
strange3=$(git -C "$w/ckar3" rev-parse refs/heads/forge/co-chg)
run "$w/coar3" "$w/op-ar3.json"
check "crash: the right tree under another message is not adopted: held, exit 14, the branch untouched" sh -c "[ \$(cat '$w/rc') = 14 ] && [ \"\$(git -C '$w/ckar3' rev-parse refs/heads/forge/co-chg)\" = '$strange3' ] && ! grep -q company.step.published '$w/coar3/company.journal' && [ -z \"\$(git -C '$w/ckar3' status --porcelain --untracked-files=all)\" ]"
pubop op-noslug ""
sed 's/"slug":"alpibrusl\/cancho-diff",//' "$w/op-noslug.json" > "$w/op-noslug2.json"
"$F" company publish "$w/co1" "$w/op-noslug2.json" chg forge/other > "$w/out" 2> /dev/null; echo $? > "$w/rc"
check "publish: a repos row without a slug is publish-not-configured" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'refusal: publish-not-configured' '$w/out'"
printf 'moved\n' > "$w/ck1/README.md"; git_in "$w/ck1" add README.md; git_in "$w/ck1" commit -q -m moved
"$F" company publish "$w/co1" "$w/op-pub.json" chg forge/stale > "$w/out" 2> /dev/null; echo $? > "$w/rc"
check "publish: the checkout moved since the patch was made: patch-base-stale, exit 1, no branch" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'refusal: patch-base-stale' '$w/out' && ! git -C '$w/ck1' rev-parse --verify --quiet refs/heads/forge/stale > /dev/null"
git_in "$w/ck1" reset -q --hard "$base"
cp "$w/co1/steps/chg/ev/change.patch" "$w/kept.patch"
printf '\n' >> "$w/co1/steps/chg/ev/change.patch"
"$F" company publish "$w/co1" "$w/op-pub.json" chg forge/tampered > "$w/out" 2> /dev/null; echo $? > "$w/rc"
check "publish: a patch edited after acceptance is publish-artifact-changed, exit 1, no branch" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'refusal: publish-artifact-changed' '$w/out' && ! git -C '$w/ck1' rev-parse --verify --quiet refs/heads/forge/tampered > /dev/null"
cp "$w/kept.patch" "$w/co1/steps/chg/ev/change.patch"

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
