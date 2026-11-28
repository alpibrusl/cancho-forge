#!/bin/sh
# `forge company intake` end to end (docs/company.md section 30; docs/company-lifecycle.md section 4.4): a file of issues, as
# `gh issue list --json number,title,body,url,labels,state` writes it, filed as change requests. The program under test is the forge binary;
# this script is the oracle only (sha256sum, cat, grep, wc). It reaches every skip and refusal of the verb: intake-issue-malformed (not an
# object, a pull request's URL, no title), intake-issue-closed, repo-unknown (no row of the slug, two rows of it, a row the manifest does
# not list), intake-kind-unmapped (no label of the table, both kinds), flow-unknown, change-malformed (a title with a tab), change-duplicate
# (in one file and on a second intake), change-rate-limited (with the `left:` count), intake-file-malformed (missing, not JSON, not an
# array, over 1000 issues, over 8 MiB), operator-invalid, clock-invalid, path-invalid and usage; and the good paths: a bug and a
# feature filed and both proposed (an issue's bug is not admitted by the act), the source and URL in the journal and the text not, the
# request file's content and its cut at 16 KiB, a second intake that writes nothing, the issues file left as it was, and an admit decision.
# Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or the build failed.
# Usage: CANCHO=path/to/cancho tests/conformance/company_intake.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../.." || exit 1
scratch=$1
fail=0
w="$scratch/cin"
mkdir "$w" || exit 1
if ! $C build src/*.cho --std -o "$w/forge"; then
  echo "FAIL company intake: forge did not build"
  exit 1
fi
F="$w/forge"
ok() { echo "ok   company intake: $1"; }
bad() { echo "FAIL company intake: $1"; fail=1; }
check() { # name, command...
  name=$1; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
run() { # company dir, operator file, issues file, [now=...] -> output in $w/out, status in $w/rc
  "$F" company intake "$@" > "$w/out" 2>&1; echo $? > "$w/rc"
}
expect() { # name, status, text
  if [ "$(cat "$w/rc")" = "$2" ] && { [ -z "$3" ] || grep -qF -- "$3" "$w/out"; }; then ok "$1"; else bad "$1 (status $(cat "$w/rc"): $(cat "$w/out"))"; fi
}
has() { # name, text: the last output holds it
  if grep -qF -- "$2" "$w/out"; then ok "$1"; else bad "$1 (output: $(cat "$w/out"))"; fi
}
step='{"id":"fix","role":"builder","task_type":"repo.change","needs":[],"input":"x","check":"c.sh"}'
head='"model":{"provider":"stand","name":"m1"},"budget":{"input":1,"output":1,"cache_write":1,"cache_read":1,"max_cost":1,"price_table":"prices.json"},"human_gates":["go"],"roles":["builder"]'
co="$w/co"
mkdir -p "$co/changes" || exit 1
printf '{"id":"co","mission":"m",%s,"repos":[{"id":"diff","kind":"library"},{"id":"api","kind":"service"},{"id":"t1","kind":"library"},{"id":"t2","kind":"library"}],"flows":{"bug":[%s],"feature":[%s]},"steps":[{"id":"s","role":"builder","task_type":"repo.change","needs":[],"input":"x","check":"c.sh","repo":"diff","change_kind":"bug"}]}' "$head" "$step" "$step" > "$co/company.json"
row() { # slug
  printf '{"kind":"library","slug":"%s","checkout":"/nowhere/ck","compiler_rev":"0123456789abcdef0123456789abcdef01234567","publish_allow":["src/**"],"max_patch_files":3,"max_patch_lines":9}' "$1"
}
printf '{"workers":"/nowhere/workers","repos":{"diff":%s,"api":%s,"t1":%s,"t2":%s,"gone":%s}}' "$(row a/diff)" "$(row a/api)" "$(row a/twin)" "$(row a/twin)" "$(row a/gone)" > "$w/op.json"

U=https://github.com
L_BUG='[{"id":"LA_1","name":"bug","description":"Something is not working","color":"d73a4a"}]'
L_ENH='[{"id":"LA_2","name":"enhancement","description":"","color":"a2eeef"}]'
long=$(head -c 20000 /dev/zero | tr '\0' 'x')
cat > "$w/issues.json" <<EOF
[{"number":1,"title":"diff: a hunk header miscounts","body":"Steps:\r\n1. run \`diff\` on été\n\"quoted\" <b>","url":"$U/a/diff/issues/1","labels":$L_BUG,"state":"OPEN"},
 {"number":2,"title":"api: a JSON output","body":"","url":"$U/a/api/issues/2","labels":$L_ENH,"state":"OPEN"},
 {"number":3,"title":"closed one","body":"b","url":"$U/a/diff/issues/3","labels":$L_BUG,"state":"CLOSED"},
 {"number":4,"title":"no label","body":"b","url":"$U/a/diff/issues/4","labels":[],"state":"OPEN"},
 {"number":5,"title":"both","body":"b","url":"$U/a/diff/issues/5","labels":[{"name":"bug"},{"name":"feature"}],"state":"OPEN"},
 {"number":6,"title":"no row","body":"b","url":"$U/a/nope/issues/6","labels":$L_BUG,"state":"OPEN"},
 {"number":7,"title":"two rows","body":"b","url":"$U/a/twin/issues/7","labels":$L_BUG,"state":"OPEN"},
 {"number":8,"title":"a row the manifest does not list","body":"b","url":"$U/a/gone/issues/8","labels":$L_BUG,"state":"OPEN"},
 {"number":9,"title":"a pull request","body":"b","url":"$U/a/diff/pull/9","labels":$L_BUG,"state":"OPEN"},
 "not an object",
 {"number":10,"body":"no title","url":"$U/a/diff/issues/10","labels":$L_BUG},
 {"number":11,"title":"a\ttab","body":"b","url":"$U/a/diff/issues/11","labels":$L_BUG,"state":"OPEN"},
 {"number":1,"title":"diff: a hunk header miscounts","body":"again","url":"$U/a/diff/issues/1","labels":$L_BUG,"state":"OPEN"},
 {"number":12,"title":"a long report","body":"$long","url":"$U/a/diff/issues/12","labels":$L_BUG}]
EOF
before=$(sha256sum "$w/issues.json" | cut -d' ' -f1)

# refusals first: nothing is written by any of them
"$F" company intake "$co" "$w/op.json" > "$w/out" 2>&1; echo $? > "$w/rc"
expect "missing arguments are usage, exit 2" 2 ""
run "$co" "$w/op.json" "$w/issues.json" "day=2026-11-28";       expect "an argument that is not now= is usage, exit 2" 2 ""
run "$co" "$w/op.json" "$w/issues.json" "now=2026-13-01";       expect "a bad day is clock-invalid" 1 "refusal: clock-invalid"
run "$co" "$w/op.json" "relative.json";                         expect "a relative issues file is path-invalid, exit 2" 2 "refusal: path-invalid"
printf '{' > "$w/op-bad.json"
run "$co" "$w/op-bad.json" "$w/issues.json";                    expect "an operator file that is not JSON is operator-invalid" 1 "refusal: operator-invalid"
run "$co" "$w/op.json" "$w/missing.json";                       expect "an issues file that is not there is intake-file-malformed" 1 "refusal: intake-file-malformed"
printf '[{' > "$w/i-bad.json"
run "$co" "$w/op.json" "$w/i-bad.json";                         expect "an issues file that is not JSON is intake-file-malformed" 1 "refusal: intake-file-malformed"
printf '{"url":"x"}' > "$w/i-obj.json"
run "$co" "$w/op.json" "$w/i-obj.json";                         expect "an issues file that is not an array is intake-file-malformed" 1 "refusal: intake-file-malformed"
{ printf '['; i=0; while [ $i -lt 1000 ]; do printf '1,'; i=$((i + 1)); done; printf '1]'; } > "$w/i-many.json"
run "$co" "$w/op.json" "$w/i-many.json";                        expect "an issues file of 1001 issues is intake-file-malformed" 1 "refusal: intake-file-malformed"
{ printf '['; head -c 8388608 /dev/zero | tr '\0' ' '; printf ']'; } > "$w/i-big.json"
run "$co" "$w/op.json" "$w/i-big.json";                         expect "an issues file over 8 MiB is intake-file-malformed" 1 "refusal: intake-file-malformed"
check "no refusal wrote a journal or a request file" sh -c "[ ! -e '$co/company.journal' ] && [ -z \"\$(ls '$co/changes')\" ]"

# the good path, with every skip in one file
run "$co" "$w/op.json" "$w/issues.json" "now=2026-11-28";        expect "an intake of the file exits 0" 0 "intake: 3 filed, 11 skipped"
has "an open bug is filed and stays proposed: chg-0001" "issue $U/a/diff/issues/1 filed as change chg-0001: proposed"
has "an enhancement is filed as a feature: chg-0002 proposed" "issue $U/a/api/issues/2 filed as change chg-0002: proposed"
has "a closed issue is intake-issue-closed" "issue $U/a/diff/issues/3 skipped: intake-issue-closed"
has "an issue with no label of the table is intake-kind-unmapped" "issue $U/a/diff/issues/4 skipped: intake-kind-unmapped"
has "an issue labelled with both kinds is intake-kind-unmapped" "issue $U/a/diff/issues/5 skipped: intake-kind-unmapped"
has "an issue of a slug no row has is repo-unknown" "issue $U/a/nope/issues/6 skipped: repo-unknown"
has "an issue of a slug two rows have is repo-unknown" "issue $U/a/twin/issues/7 skipped: repo-unknown"
has "an issue of a row the manifest does not list is repo-unknown" "issue $U/a/gone/issues/8 skipped: repo-unknown"
has "a pull request's URL is intake-issue-malformed" "issue $U/a/diff/pull/9 skipped: intake-issue-malformed"
has "an element that is not an object is intake-issue-malformed" "issue (no url) skipped: intake-issue-malformed"
has "an issue with no title is intake-issue-malformed" "issue $U/a/diff/issues/10 skipped: intake-issue-malformed"
has "a title with a tab is change-malformed" "issue $U/a/diff/issues/11 skipped: change-malformed"
has "the same URL twice in one file is change-duplicate" "issue $U/a/diff/issues/1 skipped: change-duplicate"
has "a long report is filed: chg-0003" "issue $U/a/diff/issues/12 filed as change chg-0003: proposed"
check "no change is admitted by the act" sh -c "! grep -q 'company.change.admitted' '$co/company.journal'"
check "the journal holds the source and the URL" grep -q "\"source_type\":\"issue\",\"source_ref\":\"$U/a/diff/issues/1\"" "$co/company.journal"
check "a feature from an issue has the justification issue" sh -c "grep 'chg-0002' '$co/company.journal' | grep -q '\"ckind\":\"feature\".*\"justification\":\"issue\"'"
check "the journal holds no text of a body" sh -c "! grep -q 'hunk header miscounts.*Steps\|run .diff' '$co/company.journal'"
printf '%s\ndiff: a hunk header miscounts\n\nSteps:\r\n1. run `diff` on \303\251t\303\251\n"quoted" <b>' "$U/a/diff/issues/1" > "$w/want1.txt"
check "the request is the URL, the title and the decoded body" cmp -s "$w/want1.txt" "$co/changes/chg-0001.txt"
sum=$(sha256sum "$co/changes/chg-0001.txt" | cut -d' ' -f1)
check "the journal holds the request's sha256" grep -q "\"body_sha256\":\"$sum\"" "$co/company.journal"
printf '%s\napi: a JSON output\n\n' "$U/a/api/issues/2" > "$w/want2.txt"
check "an empty body gives the URL and the title" cmp -s "$w/want2.txt" "$co/changes/chg-0002.txt"
n3=$(wc -c < "$co/changes/chg-0003.txt" | tr -d ' ')
check "a long body is cut to at most 16 KiB ($n3 bytes)" sh -c "[ $n3 -le 16384 ] && [ $n3 -gt 16000 ]"
check "the cut is marked" grep -q 'cut here at 16 KiB by forge company intake' "$co/changes/chg-0003.txt"
check "the day is recorded" grep -q '"company.clock.set"' "$co/company.journal"
lines1=$(wc -l < "$co/company.journal" | tr -d ' ')

# a second intake of the same file files nothing
run "$co" "$w/op.json" "$w/issues.json" "now=2026-11-28";        expect "a second intake exits 0 and files nothing" 0 "intake: 0 filed, 14 skipped"
has "an issue filed before is change-duplicate" "issue $U/a/api/issues/2 skipped: change-duplicate"
check "the second intake wrote no record" [ "$(wc -l < "$co/company.journal" | tr -d ' ')" = "$lines1" ]
check "the issues file is left as it was" [ "$(sha256sum "$w/issues.json" | cut -d' ' -f1)" = "$before" ]
"$F" company status "$co" format=json > "$w/status" 2>&1
check "status counts 3 proposed, 0 admitted" grep -q '"changes":{"proposed":3,"admitted":0,"rejected":0}' "$w/status"
"$F" company decide "$co" admit:chg-0001 approved "a real defect" > "$w/out" 2>&1; echo $? > "$w/rc"
expect "an issue's change is admitted by a decision" 0 "gate admit:chg-0001: approved"
run "$co" "$w/op.json" "$w/issues.json" "now=2026-11-27";        expect "a day before the journal's is clock-went-back" 1 "refusal: clock-went-back"

# flow-unknown and the rate limit, on a company with one flow and room for one open change per repository
c2="$w/c2"
mkdir -p "$c2/changes" || exit 1
printf '{"id":"c2","mission":"m",%s,"repos":[{"id":"diff","kind":"library"}],"flows":{"bug":[%s]},"intake":{"max_open_per_repo":1},"steps":[{"id":"s","role":"builder","task_type":"repo.change","needs":[],"input":"x","check":"c.sh","repo":"diff","change_kind":"bug"}]}' "$head" "$step" > "$c2/company.json"
cat > "$w/i2.json" <<EOF
[{"title":"one","body":"b","url":"$U/a/diff/issues/1","labels":$L_BUG},
 {"title":"a feature","body":"b","url":"$U/a/diff/issues/2","labels":$L_ENH},
 {"title":"two","body":"b","url":"$U/a/diff/issues/3","labels":$L_BUG},
 {"title":"three","body":"b","url":"$U/a/diff/issues/4","labels":$L_BUG}]
EOF
run "$c2" "$w/op.json" "$w/i2.json";                            expect "the open limit stops intake: change-rate-limited, exit 1" 1 "refusal: change-rate-limited"
has "the limit says which" "limit: changes open for the repository (intake.max_open_per_repo)"
has "a feature with no flow is flow-unknown" "issue $U/a/diff/issues/2 skipped: flow-unknown"
has "what was filed before the limit stays" "issue $U/a/diff/issues/1 filed as change chg-0001: proposed"
has "the rest are counted as left" "left: 2 issues of the file, for a later intake"
check "nothing after the limit was filed" sh -c "! grep -q 'issues/3\|issues/4' '$c2/company.journal'"

# `change add ... url=`: the operator files an issue by hand; intake then knows it, and a second hand filing of it is refused
c3="$w/c3"
mkdir -p "$c3/changes" || exit 1
cp "$co/company.json" "$c3/company.json"
printf 'by hand' > "$w/hand.txt"
"$F" company change add "$c3" repo=diff kind=bug justification=defect "title=by hand" "file=$w/hand.txt" "url=$U/a/diff/pull/1" > "$w/out" 2>&1; echo $? > "$w/rc"
expect "change add with a url= that is not an issue URL is change-malformed" 1 "refusal: change-malformed"
check "the refused url= wrote nothing" sh -c "[ ! -e '$c3/company.journal' ]"
"$F" company change add "$c3" repo=diff kind=bug justification=defect "title=by hand" "file=$w/hand.txt" "url=$U/a/diff/issues/1" "url=$U/a/diff/issues/2" > "$w/out" 2>&1; echo $? > "$w/rc"
expect "url= twice is usage, exit 2" 2 ""
"$F" company change add "$c3" repo=diff kind=bug justification=defect "title=by hand" "file=$w/hand.txt" "url=$U/a/diff/issues/1" now=2026-11-28 > "$w/out" 2>&1; echo $? > "$w/rc"
expect "change add with url= files the operator's bug and admits it" 0 "change chg-0001: admitted"
check "the journal holds the URL as issue, the source still operator" sh -c "grep 'chg-0001' '$c3/company.journal' | grep -q '\"source_type\":\"operator\".*\"issue\":\"$U/a/diff/issues/1\"'"
"$F" company change add "$c3" repo=diff kind=bug justification=defect "title=again" "file=$w/hand.txt" "url=$U/a/diff/issues/1" > "$w/out" 2>&1; echo $? > "$w/rc"
expect "a second change add of the same url= is change-duplicate" 1 "refusal: change-duplicate"
run "$c3" "$w/op.json" "$w/issues.json" "now=2026-11-28"
has "intake skips the issue filed by hand with url=" "issue $U/a/diff/issues/1 skipped: change-duplicate"
has "intake files the others" "issue $U/a/api/issues/2 filed as change chg-0002: proposed"

exit "$fail"
