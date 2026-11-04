#!/bin/sh
# The model reviewer's worker, offline (docs/review-step.md section 5, RV2): workers/repo_review.cho is built here with the vendored provider transport and
# fed one request per case on standard input; the oracle for what it answered and wrote is outside the program (grep on the reply and the execution
# directory). Every case ends before a connection is made: the capabilities, each refusal of the task, the inputs it needs, a key it cannot read, a host that does not
# resolve. The call itself (TLS, the provider's answer) is not measured here: it needs the provider, and is measured once by RV4 on a real change. The key never
# appears in what the worker printed or wrote. Prints `ok ...` / `FAIL ...` lines; exit 1 if a FAIL or the build failed.
# Usage: CANCHO=path/to/cancho [CANCHO_PACKAGES=dir] scripts/check_repo_review.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
. scripts/packages.sh
scratch=$1
fail=0
rr="$scratch/rr"; mkdir "$rr" || exit 1
ok() { echo "ok   repo review: $1"; }
bad() { echo "FAIL repo review: $1"; fail=1; }
libs=$(ls src/*.cho | grep -v '/main\.cho$')
all="workers/repo_review.cho $libs spike/lib/dns.cho vendor/cancho-code/*.cho $PKG/http-client/*.cho $PKG/tls/*.cho $PKG/x509/*.cho"

# the worker's own authority report is its review artefact
$C authority $all --std | sed -n '/^performs/,/^provably/p' | sed '$d' > "$rr/authority.txt"
if cmp -s "$rr/authority.txt" docs/authority-repo-review.txt; then ok "the worker's authority is the checked-in report"; else bad "the worker's authority differs from docs/authority-repo-review.txt"; diff docs/authority-repo-review.txt "$rr/authority.txt"; fi
$C check $all --std || fail=1
if ! $C build $all --std -o "$rr/worker"; then echo "FAIL repo review: the worker did not build"; exit 1; fi

KEY=TOPSECRET-KEY-MARKER-0123456789
printf '%s\n' "$KEY" > "$rr/key"
mkdir "$rr/ev_ok"; printf 'make the parser stricter\n' > "$rr/ev_ok/brief.txt"; printf -- '--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n' > "$rr/ev_ok/change.patch"
# request <name> [kind] [exec dir] [model] [host] [max_tokens] [max_diff_bytes] [key file]
request() {
  printf '{"contract":"forge-worker/1","verb":"execute","request_id":"r-%s","task":{"id":"t-%s","type":"%s","input":{}},"grants":{"execution_dir":"%s","review":{"key_file":"%s","host":"%s","model":"%s","max_tokens":%s,"max_diff_bytes":%s}},"limits":{"timeout_ms":60000}}' \
    "$1" "$1" "${2:-repo.review}" "${3:-$rr/ev_$1}" "${8:-$rr/key}" "${5:-nonexistent.invalid}" "${4:-claude-sonnet-5-5}" "${6:-2048}" "${7:-65536}"
}
run() { request "$@" | "$rr/worker" > "$rr/reply_$1"; echo $? > "$rr/rc_$1"; }
has() { grep -q -- "$2" "$rr/$1"; }
check() { if has "$3" "$4"; then ok "$1: $2"; else bad "$1: $2"; fi; }
code() { check "$1" "answers failed with $2" "reply_$1" "\"state\":\"failed\".*\"code\":\"$2\""; }
fixture() { mkdir "$rr/ev_$1"; cp "$rr/ev_ok/brief.txt" "$rr/ev_ok/change.patch" "$rr/ev_$1/"; }

printf '{"contract":"forge-worker/1","verb":"capabilities","request_id":"r-caps"}' | "$rr/worker" > "$rr/reply_caps"
check caps "names itself, the sync level and the task type" reply_caps '"repo-review".*"sync".*"repo.review"'

# the refusals of the task, before anything is read
fixture kind; run kind repo.authority; code kind task-type-invalid
run relative repo.review relative/dir; code relative path-invalid
fixture keyrel; run keyrel repo.review "" "" "" "" "" relative-key; code keyrel path-invalid
fixture model; run model repo.review "" "bad model"; code model scope-invalid
fixture host; run host repo.review "" "" "a/b"; code host scope-invalid
fixture tokens; run tokens repo.review "" "" "" 0; code tokens limits-invalid
fixture diffmax; run diffmax repo.review "" "" "" "" 262145; code diffmax limits-invalid

# the inputs it needs
mkdir "$rr/ev_nobrief"; cp "$rr/ev_ok/change.patch" "$rr/ev_nobrief/"; run nobrief; code nobrief input-unreadable
mkdir "$rr/ev_nopatch"; cp "$rr/ev_ok/brief.txt" "$rr/ev_nopatch/"; run nopatch; code nopatch input-unreadable
fixture bigpatch; run bigpatch repo.review "" "" "" "" 10; code bigpatch input-unreadable
mkdir "$rr/ev_emptypatch"; cp "$rr/ev_ok/brief.txt" "$rr/ev_emptypatch/"; : > "$rr/ev_emptypatch/change.patch"; run emptypatch; code emptypatch input-unreadable

# a key that cannot be read, and a host that cannot be resolved: unavailable, nothing written, and the key is nowhere
fixture nokey; run nokey repo.review "" "" "" "" "" "$rr/absent"; code nokey review-unavailable
check nokey "says the key file could not be read" reply_nokey "the key file could not be read"
fixture unresolved; run unresolved; code unresolved review-unavailable
for n in kind relative keyrel model host tokens diffmax nobrief nopatch bigpatch emptypatch nokey unresolved; do
  [ "$(cat "$rr/rc_$n")" = 0 ] && ok "$n: exit 0" || bad "$n: exit status $(cat "$rr/rc_$n")"
  [ "$(wc -l < "$rr/reply_$n" | tr -d ' ')" = 1 ] && ok "$n: one line on standard output" || bad "$n: not one line on standard output"
done
for n in unresolved nokey bigpatch; do
  if [ ! -e "$rr/ev_$n/reply.txt" ] && [ ! -e "$rr/ev_$n/usage.jsonl" ] && [ ! -e "$rr/ev_$n/report.json" ]; then ok "$n: nothing written beside the inputs"; else bad "$n: files were written"; fi
done
if grep -rq -- "$KEY" "$rr"/reply_* "$rr"/ev_*; then bad "the key appears in an answer or an execution directory"; else ok "the key appears in no answer and no execution directory"; fi
# garbage and a wrong contract are protocol errors, not answers
printf 'not json' | "$rr/worker" > "$rr/reply_garbage"; echo $? > "$rr/rc_garbage"
[ "$(cat "$rr/rc_garbage")" = 4 ] && ok "garbage on standard input: exit 4" || bad "garbage on standard input: exit $(cat "$rr/rc_garbage")"
exit "$fail"
