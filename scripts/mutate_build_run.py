"""Test oracle for `forge build` (src/build_run.cho, the `build` command of src/main.cho, and the request and options of
src/build_task.cho; issue #34, docs/cancho-code-adapter.md section 10): one deliberate break per decision, applied to a copy of
the tree, which is then run the way the gate runs it (scripts/check_build_run.sh: the forge binary, the adapter as a real child
process, a stand-in build tool, outside oracles on the journal, the files and the process table). A break is KILLED when the
build succeeds and the script fails (an `ok` line missing, a `FAIL`, a trap, or a hang past the time limit); one that does not
build is INVALID (this script's mistake, not a kill). After a clean run the unit tests of the pure half (`cancho test
tests/build_task_test.cho ...`) are the second oracle: a break they fail is KILLED too. The runs are serial: the oracles look at
the whole process table (`pgrep`), so two at a time would see each other's children. Python edits copies of the source and runs
the compiler; it decides nothing about the product.

An EQUIVALENT break is one that no observable behaviour can tell from the original; each is listed in EQUIVALENT with the reason,
and is expected to survive. Anything else that survives is a missing test.

Usage: CANCHO=path/to/cancho python3 scripts/mutate_build_run.py [--only NAME,NAME] [--dry]
  --dry  only check that each `old` text occurs exactly once; build and run nothing."""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANCHO = os.environ.get("CANCHO", "cancho")

B = "src/build_run.cho"
T = "src/build_task.cho"
M = "src/main.cho"
A = "src/await_run.cho"
K = "src/await_task.cho"
E = "src/event.cho"
X = "src/recover.cho"
D = "src/dispatch.cho"
W = "src/worker.cho"
# (name, file, old, new, what it breaks); `old` must occur exactly once in the file.
MUT = [
    # ---- the orchestration (src/build_run.cho)
    ("check-skipped", B, "var checked = build_task.check(build_task.task_type(), brief, execution_dir, tools_dir, timeout_ms);", "var checked = build_task.Checked::Held;", "the task is not checked"),
    ("operator-skipped", B, "checked = build_task.operator_checked(checker, guide, provider, model, agent, attempts_ceiling, agent_seconds, rounds, plan_seconds, jobs);", "checked = build_task.Checked::Held;", "the operator's configuration is not checked"),
    ("intent-not-written", B, 'seq = gate_run.note_execution(heap, fs, journal_path, s4, "execution.started", tid, "");', "seq = s4;", "the intent is not written before the worker starts"),
    ("retry-as-read-only", B, "let decision = retry.decide(consequence, attempts, false);", "let decision = retry.decide(consequence, attempts, true);", "a build is treated as read-only: a provider error is retried"),
    ("retry-tag-not-journalled", B, "if len(again) > 0 {", "if len(again) > 99 {", "a refused retry leaves no refusal record"),
    ("finish-for-any-ending", B, "    if gate_run.succeeded(e) {\n        return gate_run.note_execution(", "    if true {\n        return gate_run.note_execution(", "an execution.finished is written for a build that did not succeed"),
    ("claim-empty", B, "build_task.verdict_name(claimed_verdict(heap, fs, execution_dir))", '""', "the claim is written with no verdict"),
    ("worker-name", B, '"cancho_code", buffer.bytes(qb)', '"gate_runner", buffer.bytes(qb)', "the build is sent to another worker"),
    ("brief-dropped", B, "buffer.bytes(rb), attempts, tid, brief, timeout_ms,", 'buffer.bytes(rb), attempts, tid, "", timeout_ms,', "the request carries no brief"),
    ("tools-as-workdir", B, "timeout_ms, 1048576, execution_dir, tools_dir, workers_dir, checker,", "timeout_ms, 1048576, tools_dir, tools_dir, workers_dir, checker,", "the build's work directory is the tools directory"),
    ("ceilings-swapped", B, "agent, attempts_ceiling, agent_seconds, rounds, plan_seconds, jobs);\n                        borrow req as &qb in {", "agent, attempts_ceiling, rounds, agent_seconds, plan_seconds, jobs);\n                        borrow req as &qb in {", "two of the ceilings are swapped on their way to the tool"),
    ("read-brief-limit", B, "journal_io.drain(heap, x, data, build_task.max_brief_bytes())", "journal_io.drain(heap, x, data, build_task.max_brief_bytes() + 1)", "a brief file one byte over the limit is read whole"),
    ("claimed-from-wrong-file", B, '"/build.json"', '"/run.log"', "the claim is read from another file"),
    # ---- the async level (issue #33): what Forge does with `accepted` (src/build_run.cho, src/await_run.cho, src/await_task.cho)
    ("accepted-not-polled", B, "if dispatch.accepted(ending) {", "if false {", "an accepted job is not waited for: the task stays running"),
    ("accepted-not-journalled", B, "seq = gate_run.note_accepted(heap, fs, journal_path, seq, tid, buffer.bytes(rb), execution_dir);", "seq = seq;", "the run a later Forge must ask about is not written down"),
    ("accepted-record-request", E, "    w = json.put_key(heap, w, \"request\");\n    w = json.put_string(heap, w, request);", "    w = json.put_key(heap, w, \"request\");\n    w = json.put_string(heap, w, task);", "the record names the task where it names the request"),
    ("accepted-record-dir", E, "    w = json.put_key(heap, w, \"dir\");\n    w = json.put_string(heap, w, dir);", "    w = json.put_key(heap, w, \"dir\");\n    w = json.put_string(heap, w, task);", "the record names the task where it names the directory"),
    ("cancelled-not-written", B, '            if bytes.equal(dispatch.consequence_name(consequence), "cancelled") {', '            if false {', "a cancelled run leaves no execution.cancelled (forge build)"),
    ("cancelled-not-written-by-await", K, "    if bytes_equal_cancelled(consequence) {", "    if false {", "a cancelled run leaves no execution.cancelled (forge await)"),
    ("tag-not-written-by-await", K, "    if len(tag) > 0 {\n        s = gate_run.note(", "    if len(tag) > 99 {\n        s = gate_run.note(", "forge await leaves no refusal record for the ending"),
    ("claim-not-written-by-await", K, "    s = build_run.finish_attempt(heap, fs, journal_path, s, tid, ending, execution_dir);", "    s = s;", "forge await leaves no claim"),
    ("await-any-task", K, "    if phase == 5 {\n        borrow request", "    if phase >= 0 {\n        borrow request", "forge await goes on with a task that has no accepted run"),
    ("deadline-ignored", A, "if clock_ms(clock) >= deadline {", "if false {", "Forge waits for ever for a build that outruns its deadline"),
    ("deadline-no-cancel", A, "                    cancel(heap, exec, workers, clock, name, request_id, task_id, execution_dir);\n", "", "a build that outruns Forge's deadline is not asked to stop"),
    ("deadline-not-timeout", A, "                    ending = dispatch.Ending::Timeout;\n                    waiting = false;\n                } else {", "                    ending = dispatch.Ending::Lost;\n                    waiting = false;\n                } else {", "Forge's deadline is reported as a lost run"),
    ("unknown-not-lost", A, "out = Probe::Ended(dispatch.Ending::Lost);", "out = Probe::Running;", "a worker that does not know its run is waited for for ever"),
    ("result-to-wrong-request", A, "                ending = result_of(heap, exec, workers, fs, clock, name, request_id, task_id, execution_dir);", "                ending = result_of(heap, exec, workers, fs, clock, name, task_id, task_id, execution_dir);", "the result is asked for under the task id and not the request id"),
    ("status-to-wrong-request", A, 'let q = verbs.build_targeted_in(heap, "status", buffer.bytes(ib), request_id, execution_dir);', 'let q = verbs.build_targeted_in(heap, "status", buffer.bytes(ib), task_id, execution_dir);', "status asks about the task id and not the request"),
    ("lost-as-retry", D, "        Ending::Lost => {\n            return Consequence::Blocked;", "        Ending::Lost => {\n            return Consequence::RetryOrFail;", "a lost run is sent back to ready"),
    ("lost-tag", D, '        Ending::Lost => {\n            return "execution-lost";', '        Ending::Lost => {\n            return "worker-error";', "a lost run is tagged as a worker error"),
    ("workers-dir-not-sent", T, "    w = json.put_key(heap, w, \"workers_dir\");\n    w = json.put_string(heap, w, workers_dir);\n", "", "the request does not tell the adapter where to find its supervisor"),
    # ---- the commands (src/main.cho) and recovery (src/recover.cho)
    ("recover-awaiting-lost", X, "                    ph = map.put(heap, ph, id, 5);", "                    ph = map.put(heap, ph, id, 2);", "an accepted run is taken for a lost one"),
    ("recover-awaiting-ignored", M, "                                if len(workers) > 0 {\n                                    code = ask_awaiting(", "                                if false {\n                                    code = ask_awaiting(", "forge recover with the workers directory does not ask the worker"),
    ("recover-running-is-failure", M, '            line(io, "awaiting: ", "the worker says the run is going on; nothing was written");\n            code = 0;', '            line(io, "awaiting: ", "the worker says the run is going on; nothing was written");', "a run that is still going makes forge recover fail"),
    ("cancel-exit", M, "                        verbs.CancelState::Cancelled => {\n                            return 0;", "                        verbs.CancelState::Cancelled => {\n                            return 4;", "a cancel that worked is reported as one that did not"),
    ("cancel-any-task", M, "                    if phase != 5 {\n                        io.error_all(io, \"forge: \");", "                    if phase < 0 {\n                        io.error_all(io, \"forge: \");", "forge cancel asks the worker about a task that has no accepted run"),
    ("await-timeout-floor", M, "        if timeout < 1000 {\n            return usage(io);", "        if timeout < 0 {\n            return usage(io);", "forge await takes a budget under a second"),
    # ---- the request and the pure half (src/build_task.cho)
    ("id-prefix", T, 'buffer.append(heap, buffer.empty(heap, 16), "build-")', 'buffer.append(heap, buffer.empty(heap, 16), "bld-")', "the task id has another prefix"),
    ("guide-dropped-in-request", T, '    if len(guide) > 0 {\n        w = json.put_key(heap, w, "guide");', '    if false {\n        w = json.put_key(heap, w, "guide");', "the operator's guide never reaches the adapter"),
    ("brief-not-escaped", T, "w = json.put_string(heap, w, brief);", "w = json.put_fragment(heap, w, brief);", "the brief is spliced into the request unescaped"),
    ("option-list-open", T, 'return bytes.equal(name, "guide") ||', 'return bytes.equal(name, "bogus") || bytes.equal(name, "guide") ||', "an option that is not on the list is taken"),
    ("verdict-name", T, 'return "gate_failed";', 'return "gate-failed";', "a claim is not the tool's own word"),
    # ---- the command (src/main.cho)
    ("brief-errno-ignored", M, "                if errno != 0 {\n                    io.error_all(io, \"forge: \");\n                    io.error_all(io, build_task.rule_name(build_task.Refusal::BriefUnreadable));", "                if errno < 0 - 100 {\n                    io.error_all(io, \"forge: \");\n                    io.error_all(io, build_task.rule_name(build_task.Refusal::BriefUnreadable));", "an unreadable brief file is run anyway"),
    ("brief-path-unchecked", M, " || journal_io.path_ok(fs, brief_file) == false {", " {", "a brief file path that is not absolute is taken"),
    ("default-timeout", M, "    var timeout = 3600000;\n    var first_option = 11;", "    var timeout = 100;\n    var first_option = 11;", "the default timeout is not what a build may be given"),
    ("duplicate-option", M, "        if bit_set(seen, bit) {", "        if false {", "an option twice is taken"),
    ("unknown-option", M, "        if !build_task.option_known(name) {", "        if false {", "an option that is not on the list is ignored"),
    ("option-assigned-wrong", M, "                attempts = n;\n                bit = 2;", "                rounds = n;\n                bit = 2;", "attempts= sets the rounds"),
    ("refused-code", M, '                line(io, "refused: ", build_task.rule_name(why));\n                code = 1;', '                line(io, "refused: ", build_task.rule_name(why));\n                code = 4;', "a refused task exits like an ending without a claim"),
    ("claim-exit", M, "                if claim > 0 {\n                    line(io, \"claimed verdict: \", build_task.verdict_name(claim));", "                if claim > 5 {\n                    line(io, \"claimed verdict: \", build_task.verdict_name(claim));", "a claim is never reported"),
    ("retry-line-not-shown", M, "retry.rule_tag(retry.decide(dispatch.consequence(ending), done.attempts, false))", "retry.rule_tag(retry.decide(dispatch.consequence(ending), done.attempts, true))", "the refused retry is not shown to the operator"),
]
M = MUT

# Breaks that no behaviour can tell from the original, and why. They are expected to SURVIVE.
EQUIVALENT = {}

def one(m):
    name, rel, old, new, what = m
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / "w"
        shutil.copytree(ROOT, work, ignore=shutil.ignore_patterns(".git", "build", "target"))
        path = work / rel
        text = path.read_text()
        if text.count(old) != 1:
            return name, what, "INVALID (old text occurs %d times)" % text.count(old)
        if "--dry" in sys.argv:
            return name, what, "OK"
        path.write_text(text.replace(old, new))
        scratch = pathlib.Path(tempfile.mkdtemp(prefix="forge-cc-mut."))
        env = dict(os.environ, CANCHO=CANCHO, FORGE_FAILFAST="1")
        try:
            run = subprocess.run(["sh", str(work / "scripts" / "check_build_run.sh"), str(scratch)], capture_output=True, text=True, timeout=400, env=env, cwd=work)
        except subprocess.TimeoutExpired:
            subprocess.run(["pkill", "-x", "cancho_code"])
            subprocess.run(["pkill", "-f", "^sleep 79$"])
            subprocess.run(["pkill", "-f", "^sleep 78$"])
            subprocess.run(["pkill", "-f", "[c]ancho-build"])
            shutil.rmtree(scratch, ignore_errors=True)
            return name, what, "KILLED"
        shutil.rmtree(scratch, ignore_errors=True)
        out = run.stdout + run.stderr
        if run.returncode == 0 and "FAIL " not in out:
            # the pure half has its own oracle: the unit tests of src/build_task.cho (a rule the conformance cannot reach because
            # the process half refuses first, such as the size of a brief, is held there)
            units = subprocess.run([CANCHO, "test"], capture_output=True, text=True, timeout=600, cwd=work)
            if units.returncode != 0:
                return name, what, "KILLED"
        if "did not build" in out or re.search(r"^\S+:\d+:\d+: error", out, re.M) and "FAIL" not in out:
            return name, what, "INVALID (does not build)"
        subprocess.run(["pkill", "-x", "cancho_code"])
        subprocess.run(["pkill", "-f", "^sleep 79$"])
        subprocess.run(["pkill", "-f", "^sleep 78$"])
        subprocess.run(["pkill", "-f", "[c]ancho-build"])
        return name, what, "KILLED" if run.returncode != 0 or "FAIL " in out else "SURVIVED"


def main():
    only = None
    if "--only" in sys.argv:
        only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
    todo = [m for m in M if only is None or m[0] in only]
    results = []
    for m in todo:
        r = one(m)
        print(f"{r[2]:9} {r[0]:28} {r[1]}", flush=True)
        results.append(r)
    if "--dry" in sys.argv:
        bad = [r for r in results if r[2] != "OK"]
        print(f"{len(results) - len(bad)} of {len(results)} breaks apply")
        sys.exit(1 if bad else 0)
    bad = [r for r in results if r[2] != "KILLED" and r[0] not in EQUIVALENT]
    print(f"{len(results) - len(bad)} of {len(results)} breaks killed")
    sys.exit(1 if bad else 0)


main()
