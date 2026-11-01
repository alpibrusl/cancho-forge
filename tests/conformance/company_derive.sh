#!/bin/sh
# Derived steps end to end (docs/company.md section 19; docs/company-lifecycle.md section 3): the steps of a flow appear in `status` for an ADMITTED
# change and not before, with the ids `<change id>.<template id>`, their needs prefixed the same way, their repository the change's, and the gates and
# the `retry:` gate of a derived step known to `decide`. The program under test is the forge binary; this script is the oracle only (grep). It needs no
# worker: the flow's steps are run by a person or wait. A derived `repo.change` step RUN by the change worker is tests/conformance/company_change.sh's
# derived case (Linux).
# Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or the build failed.
# Usage: CANCHO=path/to/cancho tests/conformance/company_derive.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../.." || exit 1
scratch=$1
fail=0
w="$scratch/cd"
mkdir "$w" || exit 1
if ! $C build src/*.cho --std -o "$w/forge"; then
  echo "FAIL company derive: forge did not build"
  exit 1
fi
F="$w/forge"
ok() { echo "ok   company derive: $1"; }
bad() { echo "FAIL company derive: $1"; fail=1; }
check() { name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
co="$w/co"
mkdir -p "$co/changes" || exit 1
cat > "$co/company.json" <<'EOT'
{"id":"co","mission":"m","model":{"provider":"stand","name":"m1"},
 "budget":{"input":1,"output":1,"cache_write":1,"cache_read":1,"max_cost":1,"price_table":"prices.json"},
 "human_gates":["triage-ok"],"roles":["builder","product"],
 "repos":[{"id":"diff","kind":"library"},{"id":"api","kind":"service"}],
 "flows":{
  "bug":[{"id":"triage","role":"product","task_type":"none","needs":[],"input":"look","gate":"triage-ok"},
         {"id":"fix","role":"builder","task_type":"repo.change","needs":["triage"],"input":"ignored for a repo.change","check":"c.sh"}],
  "feature":[{"id":"design","role":"product","task_type":"none","needs":[],"input":"design it"}],
  "compiler-bump":[{"id":"bump","role":"product","task_type":"none","needs":[],"input":"bump it"}],
  "feedback":[{"id":"read","role":"product","task_type":"none","needs":[],"input":"read it"}]},
 "steps":[{"id":"boot","role":"product","task_type":"none","needs":[],"input":"start"}]}
EOT
printf 'the output is too noisy\n' > "$w/req.txt"
steps() { "$F" company status "$co" format=json | grep -o '"id":"[^"]*"' | tr '\n' ' '; }
st() { "$F" company status "$co" format=json; }

check "no change: only the manifest's own step" sh -c "'$F' company status '$co' format=json | grep -q '\"id\":\"boot\"'"
check "no change: no derived step" sh -c "! '$F' company status '$co' format=json | grep -q 'chg-'"

"$F" company change add "$co" repo=diff kind=bug justification=defect "title=noisy" "file=$w/req.txt" > "$w/out" 2>&1
check "a bug is admitted by the act" grep -q "change chg-0001: admitted" "$w/out"
check "its flow's two steps appear in status" sh -c "'$F' company status '$co' format=json | grep -q '\"id\":\"chg-0001.triage\"' && '$F' company status '$co' format=json | grep -q '\"id\":\"chg-0001.fix\"'"
check "the manifest's own step is still there" sh -c "'$F' company status '$co' format=json | grep -q '\"id\":\"boot\"'"
check "the derived step keeps its gate" sh -c "'$F' company status '$co' format=json | grep -q '\"gate\":\"triage-ok\"'"
check "the derived fix waits for its triage" sh -c "'$F' company status '$co' format=json | grep -o '{[^{}]*\"id\":\"chg-0001.fix\"[^{}]*}' | grep -q '\"state\":\"waiting\"'"

"$F" company change add "$co" repo=api kind=feature justification=operator "title=new output" "file=$w/req.txt" > "$w/out" 2>&1
check "a feature stays proposed" grep -q "change chg-0002: proposed" "$w/out"
check "a proposed change derives nothing" sh -c "! '$F' company status '$co' format=json | grep -q 'chg-0002'"
"$F" company decide "$co" admit:chg-0002 approved "worth it" > "$w/out" 2>&1
check "admitting it derives its flow" sh -c "'$F' company status '$co' format=json | grep -q '\"id\":\"chg-0002.design\"'"
"$F" company change add "$co" repo=diff kind=feedback justification=operator "title=a note" "file=$w/req.txt" > "$w/out" 2>&1
"$F" company decide "$co" admit:chg-0003 rejected "no" > "$w/out" 2>&1
check "a rejected change derives nothing" sh -c "! '$F' company status '$co' format=json | grep -q 'chg-0003'"

# decide knows the gates and retry gates of derived steps and no others
"$F" company decide "$co" triage-ok approved "ok" > "$w/out" 2>&1; echo $? > "$w/rc"
check "the human gate of a derived step is decided" sh -c "[ \"\$(cat '$w/rc')\" = 0 ]"
"$F" company decide "$co" retry:chg-0001.fix approved "again" > "$w/out" 2>&1; echo $? > "$w/rc"
check "retry: of a derived step is a gate" sh -c "[ \"\$(cat '$w/rc')\" = 0 ] && grep -q 'gate retry:chg-0001.fix: approved' '$w/out'"
"$F" company decide "$co" retry:chg-0009.fix approved "again" > "$w/out" 2>&1; echo $? > "$w/rc"
check "retry: of a change that does not exist is gate-unknown" sh -c "[ \"\$(cat '$w/rc')\" = 1 ] && grep -q 'refusal: gate-unknown' '$w/out'"
"$F" company decide "$co" retry:chg-0002.nothing approved "again" > "$w/out" 2>&1; echo $? > "$w/rc"
check "retry: of a step the flow does not have is gate-unknown" sh -c "[ \"\$(cat '$w/rc')\" = 1 ] && grep -q 'refusal: gate-unknown' '$w/out'"

# a missing request file refuses the verbs that need the steps
mv "$co/changes/chg-0001.txt" "$w/kept.txt"
"$F" company status "$co" format=json > "$w/out" 2>&1; echo $? > "$w/rc"
check "an admitted change without its request file: change-body-missing, exit 1" sh -c "[ \"\$(cat '$w/rc')\" = 1 ] && grep -q 'refusal: change-body-missing' '$w/out'"
mv "$w/kept.txt" "$co/changes/chg-0001.txt"
check "put back, status works again" sh -c "'$F' company status '$co' format=json | grep -q 'chg-0001.fix'"

if [ "$fail" -eq 0 ]; then echo "ok   company derive: done"; fi
exit "$fail"
