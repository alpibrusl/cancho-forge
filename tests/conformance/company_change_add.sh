#!/bin/sh
# `forge company change add` and the `admit:<id>` gate end to end (docs/company.md section 17; docs/company-lifecycle.md sections 4.1 and 4.4). The
# program under test is the forge binary; this script is the oracle only (sha256sum, cat, grep). It reaches every tag of the verb: repo-unknown,
# change-kind-invalid, change-justification-missing, change-malformed (a title of two lines, a request that cannot be read, an empty one),
# change-too-large, flow-unknown (a manifest with flows and none named after the kind), and gate-unknown for an `admit:` gate with no proposed change behind it; and the good paths: a bug admitted by the act, a
# feature that waits, an admit decision that admits it, a rejected one that rejects it, a decision recorded before the proposal that counts for
# nothing, the request file and its hash, the journal holding the hash and never the text, and `status format=json` counting the changes.
# Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or the build failed.
# Usage: CANCHO=path/to/cancho tests/conformance/company_change_add.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../.." || exit 1
scratch=$1
fail=0
w="$scratch/cca"
mkdir "$w" || exit 1
if ! $C build src/*.cho --std -o "$w/forge"; then
  echo "FAIL company change add: forge did not build"
  exit 1
fi
F="$w/forge"
ok() { echo "ok   company change add: $1"; }
bad() { echo "FAIL company change add: $1"; fail=1; }
check() { # name, command...
  name=$1; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
co="$w/co"
mkdir -p "$co/changes" || exit 1
printf '{"id":"co","mission":"m","model":{"provider":"stand","name":"m1"},"budget":{"input":1,"output":1,"cache_write":1,"cache_read":1,"max_cost":1,"price_table":"prices.json"},"human_gates":["go"],"roles":["builder"],"repos":[{"id":"diff","kind":"library"}],"steps":[{"id":"s","role":"builder","task_type":"repo.change","needs":[],"input":"x","check":"c.sh","repo":"diff","change_kind":"bug"}]}' > "$co/company.json"
printf 'the output of diff is too noisy for logs\n' > "$w/req1.txt"
printf 'second request\n' > "$w/req2.txt"
: > "$w/empty.txt"
head -c 16385 /dev/zero | tr '\0' 'a' > "$w/big.txt"
head -c 16384 /dev/zero | tr '\0' 'a' > "$w/max.txt"

add() { # repo kind justification title file -> output in $w/out, status in $w/rc
  "$F" company change add "$co" "repo=$1" "kind=$2" "justification=$3" "title=$4" "file=$5" > "$w/out" 2>&1; echo $? > "$w/rc"
}
expect() { # name, status, text
  if [ "$(cat "$w/rc")" = "$2" ] && { [ -z "$3" ] || grep -qF -- "$3" "$w/out"; }; then ok "$1"; else bad "$1 (status $(cat "$w/rc"): $(cat "$w/out"))"; fi
}
lines() { wc -l < "$co/company.journal" | tr -d ' '; }

# refusals first: nothing is written by any of them
add nope bug defect "t" "$w/req1.txt";            expect "an unlisted repository is repo-unknown, exit 1" 1 "refusal: repo-unknown"
add diff chore defect "t" "$w/req1.txt";          expect "a kind outside the four is change-kind-invalid" 1 "refusal: change-kind-invalid"
add diff bug operator "t" "$w/req1.txt";          expect "a bug with the justification operator is change-justification-missing" 1 "refusal: change-justification-missing"
add diff feature defect "t" "$w/req1.txt";        expect "a feature with the justification defect is change-justification-missing" 1 "refusal: change-justification-missing"
add diff bug defect "two
lines" "$w/req1.txt";                              expect "a title of two lines is change-malformed" 1 "refusal: change-malformed"
add diff bug defect "t" "$w/missing.txt";         expect "a request file that is not there is change-malformed" 1 "refusal: change-malformed"
add diff bug defect "t" "$w/empty.txt";           expect "an empty request is change-malformed" 1 "refusal: change-malformed"
add diff bug defect "t" "$w/big.txt";             expect "a request over 16 KiB is change-too-large" 1 "refusal: change-too-large"
check "no refusal wrote a journal or a request file" sh -c "[ ! -e '$co/company.journal' ] && [ -z \"\$(ls '$co/changes')\" ]"
"$F" company change add "$co" repo=diff kind=bug > "$w/out" 2>&1; echo $? > "$w/rc"
expect "missing arguments are usage, exit 2" 2 ""
add diff bug defect "t" "relative.txt";            expect "a relative path is path-invalid, exit 2" 2 "refusal: path-invalid"

# good paths
add diff bug defect "noisy output" "$w/req1.txt"; expect "a bug is admitted by the act: chg-0001 admitted, exit 0" 0 "change chg-0001: admitted"
check "the request is copied to changes/chg-0001.txt" cmp -s "$w/req1.txt" "$co/changes/chg-0001.txt"
sum=$(sha256sum "$w/req1.txt" | cut -d' ' -f1)
check "the journal holds the request's sha256 and not its text" sh -c "grep -q '\"body_sha256\":\"$sum\"' '$co/company.journal' && ! grep -q 'too noisy' '$co/company.journal'"
check "a bug writes two records (proposed, admitted)" [ "$(lines)" = 2 ]
add diff feature goal:g-adoption "more output formats" "$w/req2.txt"; expect "a feature stays proposed: chg-0002 proposed" 0 "change chg-0002: proposed"
add diff feedback operator "a note" "$w/max.txt"; expect "a request of exactly 16 KiB is accepted: chg-0003 proposed" 0 "change chg-0003: proposed"
add diff compiler-bump maintenance "bump" "$w/req1.txt"; expect "a compiler-bump is admitted by the act: chg-0004" 0 "change chg-0004: admitted"
"$F" company status "$co" format=json > "$w/status" 2>&1
check "status counts 2 proposed, 2 admitted, 0 rejected" grep -q '"changes":{"proposed":2,"admitted":2,"rejected":0}' "$w/status"

# the admit gate
"$F" company decide "$co" admit:chg-0001 approved "no" > "$w/out" 2>&1; echo $? > "$w/rc"
expect "admit: on an admitted change is gate-unknown (a stale approval has nothing to decide)" 1 "refusal: gate-unknown"
"$F" company decide "$co" admit:chg-0099 approved "no" > "$w/out" 2>&1; echo $? > "$w/rc"
expect "admit: on a change that does not exist is gate-unknown" 1 "refusal: gate-unknown"
"$F" company decide "$co" admit:chg-0002 approved "worth doing" > "$w/out" 2>&1; echo $? > "$w/rc"
expect "admit: on a proposed change is recorded" 0 "gate admit:chg-0002: approved"
"$F" company decide "$co" admit:chg-0003 rejected "not now" > "$w/out" 2>&1; echo $? > "$w/rc"
expect "a rejection is recorded" 0 "gate admit:chg-0003: rejected"
"$F" company status "$co" format=json > "$w/status" 2>&1
check "status counts 0 proposed, 3 admitted, 1 rejected" grep -q '"changes":{"proposed":0,"admitted":3,"rejected":1}' "$w/status"
"$F" company decide "$co" admit:chg-0003 approved "again" > "$w/out" 2>&1; echo $? > "$w/rc"
expect "a decided change has no admit: gate left" 1 "refusal: gate-unknown"

# the changes directory is the operator's
rm -r "$co/changes"
add diff bug defect "t" "$w/req1.txt";            expect "no changes/ directory: the request cannot be written, exit 3, no record" 3 "error: cannot write changes/"
check "that wrote no record (eight so far: four proposals, two admissions, two decisions)" [ "$(lines)" = 8 ]

# a manifest that declares flows must have the flow named after the kind
co2="$w/co2"
mkdir -p "$co2/changes" || exit 1
printf '{"id":"co","mission":"m","model":{"provider":"stand","name":"m1"},"budget":{"input":1,"output":1,"cache_write":1,"cache_read":1,"max_cost":1,"price_table":"prices.json"},"human_gates":["go"],"roles":["builder"],"repos":[{"id":"diff","kind":"library"}],"flows":{"bug":[{"id":"fix","role":"builder","task_type":"repo.change","needs":[],"input":"x","check":"c.sh"}]},"steps":[{"id":"s","role":"builder","task_type":"repo.change","needs":[],"input":"x","check":"c.sh","repo":"diff","change_kind":"bug"}]}' > "$co2/company.json"
"$F" company change add "$co2" repo=diff kind=feature justification=operator "title=t" "file=$w/req1.txt" > "$w/out" 2>&1; echo $? > "$w/rc"
expect "a manifest with flows and none named feature: flow-unknown" 1 "refusal: flow-unknown"
check "that wrote nothing" sh -c "[ ! -e '$co2/company.journal' ] && [ -z \"\$(ls '$co2/changes')\" ]"
"$F" company change add "$co2" repo=diff kind=bug justification=defect "title=t" "file=$w/req1.txt" > "$w/out" 2>&1; echo $? > "$w/rc"
expect "the kind that has its flow is taken: chg-0001 admitted" 0 "change chg-0001: admitted"

# the day (docs/company.md section 22): `now=YYYY-MM-DD` puts a company.clock.set record before the verb's own, only when the day is later
co3="$w/co3"
mkdir -p "$co3/changes" || exit 1
cp "$co/company.json" "$co3/company.json"
cl() { grep -c 'company.clock.set' "$co3/company.journal" 2> /dev/null | tr -d ' '; }
"$F" company change add "$co3" repo=diff kind=bug justification=defect "title=t" "file=$w/req1.txt" now=2026-13-01 > "$w/out" 2>&1; echo $? > "$w/rc"
expect "now= that is not a date is clock-invalid, exit 1" 1 "refusal: clock-invalid"
check "that wrote nothing" sh -c "[ ! -e '$co3/company.journal' ] && [ -z \"\$(ls '$co3/changes')\" ]"
"$F" company change add "$co3" repo=diff kind=bug justification=defect "title=t" "file=$w/req1.txt" now=2026-11-02 > "$w/out" 2>&1; echo $? > "$w/rc"
expect "a change with now= is taken" 0 "change chg-0001: admitted"
check "the journal holds the day first, then the change" sh -c "[ \"\$(sed -n 1p '$co3/company.journal' | grep -c company.clock.set)\" = 1 ] && sed -n 1p '$co3/company.journal' | grep -q '\"at\":\"2026-11-02\"' && sed -n 2p '$co3/company.journal' | grep -q company.change.proposed"
check "status shows the day" sh -c "'$F' company status '$co3' format=json | grep -q '\"clock\":\"2026-11-02\"'"
"$F" company change add "$co3" repo=diff kind=feature justification=operator "title=t2" "file=$w/req2.txt" now=2026-11-02 > "$w/out" 2>&1; echo $? > "$w/rc"
expect "the same day again" 0 "change chg-0002: proposed"
check "writes no second day record" sh -c "[ \"$(cl)\" = 1 ]"
"$F" company change add "$co3" repo=diff kind=bug justification=defect "title=t3" "file=$w/req1.txt" now=2026-11-01 > "$w/out" 2>&1; echo $? > "$w/rc"
expect "an earlier day is clock-went-back, exit 1" 1 "refusal: clock-went-back"
check "that wrote nothing: still 2 changes and their files" sh -c "[ \"\$(ls '$co3/changes' | wc -l | tr -d ' ')\" = 2 ] && [ \"\$(wc -l < '$co3/company.journal' | tr -d ' ')\" = 4 ]"
"$F" company decide "$co3" admit:chg-0002 approved now=2026-11-03 "worth it" > "$w/out" 2>&1; echo $? > "$w/rc"
expect "decide with now= right after the verdict" 0 "gate admit:chg-0002: approved"
check "the day record comes first and the reason does not hold the now= word" sh -c "tail -2 '$co3/company.journal' | head -1 | grep -q '\"at\":\"2026-11-03\"' && tail -1 '$co3/company.journal' | grep -q '\"reason\":\"worth it\"'"
"$F" company decide "$co3" retry:nothing approved now=2026-11-02 "back in time" > "$w/out" 2>&1; echo $? > "$w/rc"
expect "decide with an earlier day is clock-went-back (the gate is also unknown, but the day is judged first or the gate: either way exit 1)" 1 "refusal: "
"$F" company decide "$co3" admit:chg-0001 approved now=2026-02-30 "why" > "$w/out" 2>&1; echo $? > "$w/rc"
expect "decide with now= that is not a date is clock-invalid" 1 "refusal: clock-invalid"
"$F" company decide "$co3" admit:chg-0001 approved now=2026-11-04 > "$w/out" 2>&1; echo $? > "$w/rc"
expect "decide with now= and no reason is usage, exit 2" 2 ""
"$F" company run "$co3" "$w/none.json" now=2026-99-99 > "$w/out" 2>&1; echo $? > "$w/rc"
expect "run with now= that is not a date is clock-invalid" 1 "refusal: clock-invalid"
"$F" company run "$co3" "$w/none.json" later=2026-11-04 > "$w/out" 2>&1; echo $? > "$w/rc"
expect "run with a sixth word that is not now= is usage, exit 2" 2 ""

if [ "$fail" -eq 0 ]; then echo "ok   company change add: done"; fi
exit "$fail"
