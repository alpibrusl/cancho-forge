#!/bin/sh
# The authority reviewer's worker against real git checkouts and real child processes (docs/reviewer.md section 2, worker-contract section 12).
# workers/authority_review.cho is built here and fed one `execute` request per case on standard input; the oracle for what it answered and
# wrote is outside the program (grep and cmp on the reply and the evidence files). The compiler is a stand-in shell script that prints the
# authority report the checkout carries (`stub_out.txt`) and exits with the status in `stub_code`; the real compiler is checked by the
# gate's own authority comparisons. Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
# Usage: CANCHO=path/to/cancho scripts/check_authority_review.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
ar="$scratch/ar"; mkdir "$ar" || exit 1
ok() { echo "ok   authority review: $1"; }
bad() { echo "FAIL authority review: $1"; fail=1; }
git_in() { dir=$1; shift; git -C "$dir" -c user.email=forge@example.invalid -c user.name=forge -c commit.gpgsign=false "$@"; }

# the worker's own authority report is its review artefact
$C authority workers/authority_review.cho $libs --std | sed -n '/^performs/,/^provably/p' | sed '$d' > "$ar/authority.txt"
if cmp -s "$ar/authority.txt" docs/authority-authority-review.txt; then ok "the worker's authority is the checked-in report"; else bad "the worker's authority differs from docs/authority-authority-review.txt"; diff docs/authority-authority-review.txt "$ar/authority.txt"; fi
$C check workers/authority_review.cho $libs --std || fail=1
if ! $C build workers/authority_review.cho $libs --std -o "$ar/worker"; then echo "FAIL authority review: the worker did not build"; exit 1; fi

# the stand-in compiler: `<it> authority <programs> --std` prints stub_out.txt of the working directory and exits with stub_code
cat > "$ar/stubc" <<'STUB'
#!/bin/sh
cat stub_out.txt
exit "$(cat stub_code 2> /dev/null || echo 0)"
STUB
chmod +x "$ar/stubc"
ceiling_text='performs\n    clock\n    exec("/bin/sh")\n    fs_read("")\n    heap\nnever touches\n    the network\n    foreign code\n'
# fixture <name> <head stub_out printf text> [<stub_code>] [<head also rewrites the ceiling to the same text: yes>]
fixture() {
  d="$ar/$1"; mkdir -p "$d/docs" && git init -q "$d" || exit 1
  printf "$ceiling_text" > "$d/docs/authority.txt"; printf "$ceiling_text" > "$d/stub_out.txt"
  git_in "$d" add -A && git_in "$d" commit -q -m base || exit 1
  printf "$2" > "$d/stub_out.txt"
  [ -n "${3-}" ] && printf '%s' "$3" > "$d/stub_code"
  [ "${4-}" = yes ] && printf "$2" > "$d/docs/authority.txt"
  git_in "$d" add -A && git_in "$d" commit -q --allow-empty -m head || exit 1
  mkdir "$ar/ev_$1"
}
request() { # name, [revision override], [ceiling override], [base override]
  d="$ar/$1"; head=$(git -C "$d" rev-parse HEAD); base=${4:-$(git -C "$d" rev-parse HEAD~1)}
  printf '{"contract":"forge-worker/1","verb":"execute","request_id":"r-%s","task":{"id":"t-%s","type":"repo.authority","input":{"repo":"alpibrusl/cancho-forge","revision":"%s","base":"%s","ceiling":"%s","programs":["src/*.cho"],"std":true}},"grants":{"workspace":"%s","execution_dir":"%s","compiler":"%s"},"limits":{"timeout_ms":60000}}' \
    "$1" "$1" "${2:-$head}" "$base" "${3:-docs/authority.txt}" "$d" "$ar/ev_$1" "$ar/stubc"
}
run() { request "$@" | "$ar/worker" > "$ar/reply_$1"; }
has() { grep -q "$2" "$ar/$1"; }
check() { # name, description, file, pattern
  if has "$3" "$4"; then ok "$1: $2"; else bad "$1: $2"; fi
}
same="$ceiling_text"
fixture equal "$same"
fixture wider 'performs\n    clock\n    exec("/bin/sh")\n    fs_read("")\n    heap\n    net\nnever touches\n    the network\n    foreign code\n'
fixture narrower 'performs\n    clock\n    fs_read("")\n    heap\nnever touches\n    the network\n    foreign code\n'
fixture edited 'performs\n    clock\n    exec("/bin/sh")\n    fs_read("")\n    heap\n    net\nnever touches\n    the network\n    foreign code\n' "" yes
fixture failing "$same" 1
fixture noceiling "$same"
fixture mismatch "$same"
fixture behind 'performs\n    clock\n    exec("/bin/sh")\n    fs_read("")\n    heap\n    net\nnever touches\n    the network\n    foreign code\n'
fixture refused "$same"
behind_head=$(git -C "$ar/behind" rev-parse HEAD); behind_base=$(git -C "$ar/behind" rev-parse HEAD~1)
git -C "$ar/behind" -c advice.detachedHead=false checkout -q HEAD~1
for n in equal wider narrower edited; do run $n; done
request behind "$behind_head" "" "$behind_base" | "$ar/worker" > "$ar/reply_behind"
check equal "succeeded, verdict equal, no rule" reply_equal '"state":"succeeded"'
check equal "the report says equal" ev_equal/report.json '"verdict":"equal","rule":""'
check wider "succeeded: a widening is a report, not a worker error" reply_wider '"state":"succeeded"'
check wider "the report says wider with its rule tag" ev_wider/report.json '"verdict":"wider","rule":"authority-widened"'
check narrower "the report says narrower and no rule" ev_narrower/report.json '"verdict":"narrower","rule":""'
check edited "a patch that also edits the ceiling does not move it: still wider" ev_edited/report.json '"verdict":"wider"'
printf "$ceiling_text" > "$ar/want_ceiling"
if cmp -s "$ar/want_ceiling" "$ar/ev_edited/ceiling.txt"; then ok "edited: ceiling.txt is the base commit's file, not the edited one"; else bad "edited: ceiling.txt is not the base commit's file"; fi
if cmp -s "$ar/edited/stub_out.txt" "$ar/ev_edited/head.txt"; then ok "edited: head.txt is what the compiler printed"; else bad "edited: head.txt differs from the compiler's output"; fi
if [ "$(grep -o '"evidence":\[[^]]*\]' "$ar/reply_wider" | grep -o '"id"' | wc -l)" -eq 3 ]; then ok "wider: three evidence entries"; else bad "wider: not three evidence entries"; fi
# the head commit is exported, not the working tree: the checkout is at the BASE (detached), the head commit is only in its history
check behind "a checkout left on the base still reports the head commit's authority" ev_behind/report.json '"verdict":"wider"'
if [ "$(git -C "$ar/behind" rev-parse HEAD)" = "$behind_base" ] && [ -z "$(git -C "$ar/behind" status --porcelain)" ]; then ok "behind: the repository's working tree is untouched"; else bad "behind: the repository was changed"; fi
if [ ! -e "$ar/ev_wider/tree" ] && [ ! -e "$ar/ev_wider/tree.tar" ]; then ok "wider: the exported tree and its tar are removed"; else bad "wider: the exported tree is left behind"; fi
# a compiler that exits non-zero: failed, with its words kept
run failing
check failing "failed with authority-compiler-failed" reply_failing '"code":"authority-compiler-failed"'
check failing "the report is incomplete and keeps the compiler's words" ev_failing/report.json '"verdict":"incomplete"'
# a ceiling path the base commit does not have: a verdict, ceiling-missing
request noceiling "" docs/nothere.txt | "$ar/worker" > "$ar/reply_noceiling"
check noceiling "ceiling-missing, as a report" ev_noceiling/report.json '"verdict":"ceiling-missing","rule":"authority-ceiling-missing"'
# a checkout at another revision, and refusals: nothing written
request mismatch 0123456789abcdef0123456789abcdef01234567 | "$ar/worker" > "$ar/reply_mismatch"
check mismatch "revision-mismatch" reply_mismatch '"code":"revision-mismatch"'
request refused "" ../escape | "$ar/worker" > "$ar/reply_refused"
check refused "a ceiling path that leaves the repository is path-invalid" reply_refused '"code":"path-invalid"'
for n in mismatch refused; do
  if [ -z "$(ls -A "$ar/ev_$n")" ]; then ok "$n: nothing written"; else bad "$n: files were written"; fi
done
# the capabilities verb
printf '{"contract":"forge-worker/1","verb":"capabilities","request_id":"c-1"}' | "$ar/worker" > "$ar/reply_caps"
check caps "task type repo.authority, level sync" reply_caps 'repo.authority'

# ---- Forge's call (src/authority_call.cho): the journal, the recomputed verdict and the printed lines -------------------------------------------
$C check tests/conformance/authority_call.cho $libs --std || fail=1
if ! $C build tests/conformance/authority_call.cho $libs --std -o "$ar/call"; then echo "FAIL authority review: the call driver did not build"; exit 1; fi
mkdir "$ar/workers" && cp "$ar/worker" "$ar/workers/authority_review" || exit 1
printf '{"workers":"/w","repos":{"forge":{"kind":"library","checkout":"/abs/forge","compiler_rev":"f4ead824f33b291a0ad7620a34a0c1346a7abe4f","publish_allow":["src/**"],"max_patch_files":20,"max_patch_lines":800,"compiler":"%s","authority":[{"programs":["src/*.cho"],"std":true,"ceiling":"docs/authority.txt"}]}}}' "$ar/stubc" > "$ar/operator.json"
call() { # fixture name: run the call in a fresh workspace and execution directory; output in call_<name>.out, status in call_<name>.rc
  d="$ar/$1"; mkdir "$ar/ws_$1" "$ar/cev_$1" || exit 1
  "$ar/call" "$ar/ws_$1" "$ar/workers" "$ar/operator.json" forge alpibrusl/cancho-forge "$(git -C "$d" rev-parse HEAD)" "$(git -C "$d" rev-parse HEAD~1)" "$d" "$ar/cev_$1" > "$ar/call_$1.out" 2> "$ar/call_$1.err"; echo $? > "$ar/call_$1.rc"
}
for n in equal narrower wider edited failing; do call $n; done
cc() { # name, expected status, description
  if [ "$(cat "$ar/call_$1.rc")" = "$2" ]; then ok "call $1: $3 (status $2)"; else bad "call $1: $3 (status $(cat "$ar/call_$1.rc"), wanted $2)"; fi
}
cc equal 0 "equal verdict"
cc narrower 0 "narrower verdict"
cc wider 5 "wider verdict is a refusing verdict"
cc edited 5 "a patch that edits its own ceiling is still wider"
cc failing 4 "a compiler that fails is a run without a verdict"
grep -q '^verdict: equal$' "$ar/call_equal.out" && ok "call equal: prints the recomputed verdict" || bad "call equal: no verdict line"
grep -q '^state: verification$' "$ar/call_equal.out" && ok "call equal: the task is in verification" || bad "call equal: not in verification: $(cat "$ar/call_equal.out")"
grep -q '^rule: authority-widened$' "$ar/call_wider.out" && ok "call wider: prints the rule tag" || bad "call wider: no rule line"
grep -q 'authority-widened' "$ar/ws_wider/journal.jsonl" && ok "call wider: the journal has the rule tag" || bad "call wider: the tag is not in the journal"
grep -q 'authority-widened' "$ar/ws_equal/journal.jsonl" && bad "call equal: a rule tag in the journal" || ok "call equal: no rule tag in the journal"
grep -q '^worker-error: authority-compiler-failed$' "$ar/call_failing.out" && ok "call failing: the worker's own code is shown" || bad "call failing: no worker-error line"
exit $fail
