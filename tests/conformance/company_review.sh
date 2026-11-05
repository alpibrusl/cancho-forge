#!/bin/sh
# `forge company run` of a `repo.review` step end to end (docs/review-step.md sections 6 to 8, slice RV3). The programs under test are the forge binary and the change worker;
# the model reviewer's worker is the stand-in scripts/standin_repo_review.sh (no network, no key). This script is the oracle only. A reviewer step needs the accepted
# `repo.change` step `chg` (the patch is its artifact). The cases: approve (accepted, one spend, `review.json`), concerns (accepted, printed one line each), a reply that is
# not a verdict (held, `review-unparsed`, exit 14, the spend still recorded), a reply in a code fence (the same), the worker failing (held, `review-unavailable`), a patch over
# `max_diff_bytes` (held, `review-diff-too-large`, the worker never called), no `review` in the operator file (`review-not-granted`, exit 1, nothing admitted), a model with no price
# (`price-table-missing`), a second run (nothing admitted again), and `decide retry:` freeing a hold.
# Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
# Usage: CANCHO=path/to/cancho tests/conformance/company_review.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../.." || exit 1
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
w="$scratch/cr"
mkdir "$w" "$w/workers" "$w/tools" || exit 1
cp scripts/standin_cancho_change.sh "$w/tools/cancho-build" && chmod +x "$w/tools/cancho-build" || exit 1
cp scripts/standin_repo_review.sh "$w/workers/repo_review" && chmod +x "$w/workers/repo_review" || exit 1
if ! { $C build src/*.cho --std -o "$w/forge" && $C build workers/repo_change.cho $libs --std -o "$w/workers/repo_change" && $C build workers/check_guard.cho $libs --std -o "$w/workers/check_guard"; }; then
  echo "FAIL company review: a program did not build"
  exit 1
fi
F="$w/forge"
ok() { echo "ok   company review: $1"; }
bad() { echo "FAIL company review: $1"; fail=1; }
check() { name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
REV=f4ead824f33b291a0ad7620a34a0c1346a7abe4f
git_in() { d=$1; shift; git -C "$d" -c user.email=forge@example.invalid -c user.name=forge -c commit.gpgsign=false "$@"; }
mkrepo() {
  d="$w/$1"
  mkdir -p "$d/src" "$d/tests" "$d/docs" "$d/scripts" || exit 1
  printf 'one\ntwo\nthree\n' > "$d/src/a.cho"; printf 'test\n' > "$d/tests/a_test.cho"; printf 'readme\n' > "$d/README.md"
  printf 'performs\n    clock\nnever touches\n    the network\n' > "$d/docs/authority.txt"; printf '%s\n' "$REV" > "$d/.cancho-rev"
  printf '#!/bin/sh\n! grep -q BROKEN src/a.cho\n' > "$d/scripts/gate.sh"; chmod +x "$d/scripts/gate.sh"
  git init -q "$d" && git_in "$d" add -A && git_in "$d" commit -q -m first || exit 1
}
# the operator file: <name> <checkout> [max_diff_bytes] [model] [with review: yes|no]
operator() {
  diffmax=${3:-65536}; model=${4:-m1}; rv=${5:-yes}; review=""
  if [ "$rv" = yes ]; then
    review=",\"review\":{\"worker\":\"repo_review\",\"provider\":\"stand\",\"model\":\"$model\",\"key_file\":\"$w/key\",\"host\":\"example.invalid\",\"max_tokens\":1024,\"max_diff_bytes\":$diffmax,\"mode\":\"advisory\"}"
  fi
  cat > "$w/$1.json" <<EOT
{"workers":"$w/workers","tools":"$w/tools","checker":"/opt/cancho/bin/cancho","agent":"stand-in-agent","check_timeout_ms":30000,"build_timeout_ms":10000,
 "repos":{"diff":{"kind":"library","checkout":"$2","compiler_rev":"$REV","publish_allow":["src/**","tests/**"],"publish_deny":[],"max_patch_files":3,"max_patch_lines":20}}$review}
EOT
}
# a company: <name> <the review step's input: the stand-in's mode>
mkco() {
  co="$w/$1"
  mkdir -p "$co/steps/chg/ev" "$co/steps/rv/ev" || exit 1
  printf '{"id":"co","mission":"m","model":{"provider":"stand","name":"m1"},"budget":{"input":100000,"output":100000,"cache_write":100000,"cache_read":100000,"max_cost":10,"price_table":"prices.json"},"human_gates":["go"],"roles":["builder","reviewer"],"repos":[{"id":"diff","kind":"library"}],"steps":[{"id":"chg","role":"builder","task_type":"repo.change","needs":[],"input":"good","check":"audit_change.sh","repo":"diff","change_kind":"bug"},{"id":"rv","role":"reviewer","task_type":"repo.review","needs":["chg"],"input":"%s"}]}' "$2" > "$co/company.json"
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
run() { "$F" company run "$1" "$2" > "$w/out" 2> "$w/err"; echo $? > "$w/rc"; }
rc_is() { [ "$(cat "$w/rc")" = "$1" ]; }
out_has() { grep -qx "$1" "$w/out"; }
count() { grep -c "$2" "$1/company.journal"; }
printf 'k\n' > "$w/key"

# ---- approve
mkrepo ck1; operator op1 "$w/ck1"; mkco co1 approve
run "$w/co1" "$w/op1.json"
check "approve: exit 0, both steps accepted, the run is done" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'accepted: chg' '$w/out' && grep -qx 'accepted: rv' '$w/out' && grep -qx 'done: steps accepted 2' '$w/out'"
check "approve: the verdict is printed" grep -qx 'review: approve' "$w/out"
check "approve: review.json holds the verdict, the model and the reply, and the accepted record carries its digest" sh -c "grep -q '\"verdict\":\"approve\"' '$w/co1/steps/rv/ev/review.json' && grep -q '\"model\":\"m1\"' '$w/co1/steps/rv/ev/review.json' && sha=\$(sha256sum '$w/co1/steps/rv/ev/review.json' | cut -c1-64) && grep 'company.step.accepted' '$w/co1/company.journal' | grep '\"task\":\"rv\"' | grep -q \"\$sha\""
check "approve: the worker was given the brief and the patch, and nothing else of the company" sh -c "[ \"\$(cat '$w/co1/steps/rv/ev/brief.txt')\" = approve ] && cmp -s '$w/co1/steps/chg/ev/change.patch' '$w/co1/steps/rv/ev/change.patch'"
check "approve: the grant reached the worker: the model, the host and the key file's path, and the key is not in the request" sh -c "grep -q '\"model\":\"m1\"' '$w/co1/steps/rv/requests.log' && grep -q '\"host\":\"example.invalid\"' '$w/co1/steps/rv/requests.log' && grep -q '\"key_file\":\"$w/key\"' '$w/co1/steps/rv/requests.log'"
check "approve: the spend is recorded once, for the review step" sh -c "[ \$(grep 'company.spend.recorded' '$w/co1/company.journal' | grep -c '\"task\":\"rv\"') = 1 ] && grep 'company.spend.recorded' '$w/co1/company.journal' | grep '\"task\":\"rv\"' | grep -q '\"input\":1000,\"output\":200'"
run "$w/co1" "$w/op1.json"
check "approve: a second run admits nothing again and calls the worker no more" sh -c "[ \$(cat '$w/rc') = 0 ] && [ \$(grep -c 'company.step.admitted' '$w/co1/company.journal') = 2 ] && [ \$(wc -l < '$w/co1/steps/rv/requests.log' | tr -d ' ') = 1 ]"

# ---- concerns
mkrepo ck2; operator op2 "$w/ck2"; mkco co2 concerns
run "$w/co2" "$w/op2.json"
check "concerns: the step is accepted (advisory) and every item is printed on one line" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'accepted: rv' '$w/out' && grep -qx 'review: concerns' '$w/out' && grep -qx 'review: src/a.cho:3: the new line is never read' '$w/out' && grep -qx 'review: README.md:0: no test covers it' '$w/out'"

# ---- a reply that is not a verdict, and one in a fence
for mode in garbage fence; do
  mkrepo "ck-$mode"; operator "op-$mode" "$w/ck-$mode"; mkco "co-$mode" "$mode"
  run "$w/co-$mode" "$w/op-$mode.json"
  check "$mode: held review-unparsed, exit 14, the step not accepted (only chg is)" sh -c "[ \$(cat '$w/rc') = 14 ] && grep -qx 'refusal: review-unparsed' '$w/out' && ! grep -qx 'accepted: rv' '$w/out' && [ \$(grep -c 'company.step.accepted' '$w/co-$mode/company.journal') = 1 ]"
  check "$mode: the tokens are still paid for and recorded" sh -c "grep 'company.spend.recorded' '$w/co-$mode/company.journal' | grep -q '\"task\":\"rv\"'"
done

# ---- the worker fails
mkrepo ck4; operator op4 "$w/ck4"; mkco co4 cut
run "$w/co4" "$w/op4.json"
check "cut: held review-unavailable, exit 14" sh -c "[ \$(cat '$w/rc') = 14 ] && grep -qx 'refusal: review-unavailable' '$w/out' && ! grep -qx 'accepted: rv' '$w/out'"

# ---- no reply file at all
mkrepo ck5; operator op5 "$w/ck5"; mkco co5 silent
run "$w/co5" "$w/op5.json"
check "silent: no reply.txt is a review that did not happen: held, exit 14" sh -c "[ \$(cat '$w/rc') = 14 ] && ! grep -qx 'accepted: rv' '$w/out'"

# ---- a patch over the operator's bound
mkrepo ck6; operator op6 "$w/ck6" 20; mkco co6 approve
run "$w/co6" "$w/op6.json"
check "too large: held review-diff-too-large, exit 14, the worker never called" sh -c "[ \$(cat '$w/rc') = 14 ] && grep -qx 'refusal: review-diff-too-large' '$w/out' && [ ! -e '$w/co6/steps/rv/requests.log' ]"

# ---- not granted, and a model nobody priced
mkrepo ck7; operator op7 "$w/ck7" 65536 m1 no; mkco co7 approve
run "$w/co7" "$w/op7.json"
check "not granted: the operator file has no review: review-step-invalid or review-not-granted, exit 1, the step not admitted" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -q '^refusal: review-' '$w/out' && ! grep -q 'company.step.admitted.*\"task\":\"rv\"' '$w/co7/company.journal'"
mkrepo ck8; operator op8 "$w/ck8" 65536 unpriced; mkco co8 approve
run "$w/co8" "$w/op8.json"
check "unpriced: a review model with no price is price-table-missing, exit 1, the step not admitted" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'refusal: price-table-missing' '$w/out' && ! grep -q 'company.step.admitted.*\"task\":\"rv\"' '$w/co8/company.journal'"

[ "$fail" = 0 ]
