#!/bin/sh
# The stub LLM worker against the contract and a whole flow per way it can answer (docs/stub-llm.md). workers/stub_llm.cho
# is built into a workers directory; tests/conformance/stub_llm.cho starts it beneath that directory as a real child
# process once per case (a script, a prompt, an expected ending), writes the journal of the flow Forge would write and
# replays it. The oracle for what the stub wrote and for the journal is outside the programs: cmp, grep and pgrep on the
# files and the process table, and the `forge` binary reading the journal back. Prints `ok ...` / `FAIL ...` lines;
# exit 1 if any FAIL or a build failed.
# Used by scripts/gate.sh and by scripts/mutate_stub_llm.py (which runs it on a copy of the tree with one break).
# Usage: CANCHO=path/to/cancho scripts/check_stub_llm.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
sl="$scratch/sl"; mkdir "$sl" "$sl/workers" || exit 1
for e in ok propose refuse malformed truncated liar liar_size slow_in_time slow_past_deadline crash oversize no_rule no_script type_picks_the_rule type_skips_the_rule a_script_with_a_bad_rule \
  code_no_rule code_script_missing code_script_invalid code_script_not_json code_bad_request code_bad_request_prompt_not_a_string code_bad_request_exec_dir code_script_unreadable code_default_refusal code_scripted_refusal propose_default ok_has_one_evidence propose_has_two_evidence; do
  mkdir "$sl/ev_$e" || exit 1
done
# A script that cannot be read (it is a directory): the stub answers stub-script-missing, not a guess.
mkdir "$sl/ev_code_script_unreadable/stub_script.json" || exit 1
# The stub's authority report is its review artefact (docs/authority-stub-llm.txt); a change that widens it changes that
# file in the same commit and says so in the message.
$C authority workers/stub_llm.cho $libs --std | sed -n '/^performs/,/^provably/p' | sed '$d' > "$sl/authority.txt"
if cmp -s "$sl/authority.txt" docs/authority-stub-llm.txt; then
  echo "ok   stub llm authority: the report is the checked-in one"
else
  echo "FAIL stub llm authority: differs from docs/authority-stub-llm.txt"; diff docs/authority-stub-llm.txt "$sl/authority.txt"; fail=1
fi
$C check workers/stub_llm.cho $libs --std || fail=1
$C check tests/conformance/stub_llm.cho tests/conformance/support.cho $libs --std || fail=1
if $C build workers/stub_llm.cho $libs --std -o "$sl/workers/stub_llm" \
  && $C build tests/conformance/stub_llm.cho tests/conformance/support.cho $libs --std -o "$sl/stub_llm_conf" \
  && $C build src/*.cho --std -o "$sl/forge"; then
  "$sl/stub_llm_conf" "$sl/workers" "$sl" > "$sl/out" || fail=1
  cat "$sl/out"
  if grep -q '^FAIL ' "$sl/out"; then fail=1; fi
  oracle() { # name, command...
    name=$1; shift
    if "$@"; then echo "ok   stub llm oracle: $name"; else echo "FAIL stub llm oracle: $name"; fail=1; fi
  }
  printf 'hello from the stub\n' > "$sl/want_reply"
  oracle "ok: reply.md is the scripted text" cmp -s "$sl/ev_ok/reply.md" "$sl/want_reply"
  printf -- '--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\n+new\n' > "$sl/want_patch"
  oracle "propose: proposal.patch is the scripted patch, byte for byte" cmp -s "$sl/ev_propose/proposal.patch" "$sl/want_patch"
  oracle "propose: report.md names the summary" grep -q '^Proposal: add a line$' "$sl/ev_propose/report.md"
  oracle "propose: nothing else was written in the execution directory" sh -c "[ \"\$(ls '$sl/ev_propose' | sort | tr '\\n' ' ')\" = 'proposal.patch report.md stub_script.json ' ]"
  printf 'stub reply\n' > "$sl/want_default"
  oracle "liar: the file is the default text; only the claim lied" cmp -s "$sl/ev_liar/reply.md" "$sl/want_default"
  printf 'step 1 of 3\n' > "$sl/want_progress"
  printf -- '--- a/README.md\n+++ b/README.md\n@@ -1 +1,2 @@\n # project\n+A line added by the stub.\n' > "$sl/want_default_patch"
  oracle "propose without a patch: proposal.patch is the default patch, byte for byte" cmp -s "$sl/ev_propose_default/proposal.patch" "$sl/want_default_patch"
  oracle "crash: the progress it made before dying is left, and no reply file" sh -c "cmp -s '$sl/ev_crash/progress.txt' '$sl/want_progress' && [ ! -e '$sl/ev_crash/reply.md' ]"
  oracle "malformed: nothing but the script was written" sh -c "[ \"\$(ls '$sl/ev_malformed')\" = 'stub_script.json' ]"
  oracle "no script: nothing was written" sh -c "[ -z \"\$(ls -A '$sl/ev_no_script')\" ]"
  oracle "no stub outlived the run (a slow one was killed at its deadline)" sh -c "! pgrep -x stub_llm > /dev/null"
  # The journal is read back by the forge binary, which shares no code with the test that wrote it but the library.
  oracle "journal of a refusal: forge status reads it, one task, blocked" sh -c "mkdir '$sl/ws_m' && cp '$sl/malformed.journal.jsonl' '$sl/ws_m/journal.jsonl' && '$sl/forge' status '$sl/ws_m' > '$sl/status_m' && grep -q '^records: 6\$' '$sl/status_m' && grep -q '^  blocked: 1\$' '$sl/status_m'"
  oracle "journal of a refusal: forge history shows the rule tag, once" sh -c "'$sl/forge' history '$sl/ws_m' > '$sl/history_m' && [ \$(grep -c 'kind=refusal' '$sl/history_m') -eq 1 ]"
  oracle "journal of a proposal: forge status says verification, never accepted" sh -c "mkdir '$sl/ws_p' && cp '$sl/propose.journal.jsonl' '$sl/ws_p/journal.jsonl' && '$sl/forge' status '$sl/ws_p' > '$sl/status_p' && grep -q '^  verification: 1\$' '$sl/status_p' && ! grep -q accepted '$sl/status_p'"
  oracle "a timeout is a retry: forge status says the task is ready again" sh -c "mkdir '$sl/ws_t' && cp '$sl/slow_past_deadline.journal.jsonl' '$sl/ws_t/journal.jsonl' && '$sl/forge' status '$sl/ws_t' > '$sl/status_t' && grep -q '^  ready: 1\$' '$sl/status_t'"
else
  echo "stub llm: did not build"
  fail=1
fi
exit "$fail"
