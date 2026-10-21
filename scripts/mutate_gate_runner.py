"""Test oracle for workers/gate_runner.cho (docs/self-hosting.md 3.1, spike S11): one deliberate break per decision,
applied to a copy of the tree, which is then run the way the gate runs it (scripts/check_gate_runner.sh: real git
checkouts, the runner as a real child process, outside oracles on the files and the process table). A break is KILLED
when the build succeeds and the script fails (an `ok` line missing, a `FAIL`, a trap, or a hang past the time limit); one
that does not build is INVALID (this script's mistake, not a kill). The runs are serial: the oracles look at the whole
process table (`pgrep`), so two at a time would see each other's children. Python edits copies of the source and runs
the compiler; it decides nothing about the product.

Usage: CANCHO=path/to/cancho python3 scripts/mutate_gate_runner.py [--only NAME,NAME]"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANCHO = os.environ.get("CANCHO", "cancho")

R = "workers/gate_runner.cho"
T = "src/gate_task.cho"
# (name, file, old, new, what it breaks); `old` must occur exactly once in the file.
M = [
    ("gate-not-detached", R, "run_sh(heap, exec, clock, buffer.bytes(sb), true, log_cap(), remaining)", "run_sh(heap, exec, clock, buffer.bytes(sb), false, log_cap(), remaining)", "the gate is started plain: a deadline kills the shell and leaks what it started (spike S11)"),
    ("head-not-detached", R, "run_sh(heap, exec, clock, buffer.bytes(sb), true, 4096, deadline_ms)", "run_sh(heap, exec, clock, buffer.bytes(sb), false, 4096, deadline_ms)", "the revision check is started plain"),
    ("deadline-is-forges", R, "var remaining = total - (clock_ms(clock) - start);", "var remaining = timeout_ms - (clock_ms(clock) - start);", "the runner's deadline is Forge's: Forge's kill fires first and leaks the gate"),
    ("log-cap", R, "return 8388608;", "return 16777216;", "the log cap is doubled"),
    ("mismatch-ignored", R, "if gate_task.head_matches(buffer.bytes(ob), revision) {\n                            found = 0;\n                        }", "found = 0;", "a checkout at another revision is run"),
    ("head-exit-ignored", R, "                found = 2;\n                if n == 0 {", "                found = 0;\n                if n == 0 {", "a workspace that cannot be entered is run"),
    ("env-empty", R, 'return "PATH=/usr/local/bin:/usr/bin:/bin\\0";', 'return "";', "the gate gets no PATH"),
    ("env-wide", R, 'return "PATH=/usr/local/bin:/usr/bin:/bin\\0";', 'return "PATH=/usr/local/bin:/usr/bin:/bin\\0HOME=/root\\0";', "the gate gets more than the fixed PATH"),
    ("pass-fail-swapped", R, 'if n == 0 {\n                    verdict = "pass";\n                } else {\n                    verdict = "fail";', 'if n != 0 {\n                    verdict = "pass";\n                } else {\n                    verdict = "fail";', "a failing gate is reported as passing"),
    ("exit-status-lost", R, "                exit_status = n;\n", "", "the exit status is not reported"),
    ("signal-as-pass", R, 'ending = "signaled";\n                code = "";\n                message = "";\n                verdict = "fail";', 'ending = "signaled";\n                code = "";\n                message = "";\n                verdict = "pass";', "a gate killed by a signal passes"),
    ("timeout-as-report", R, 'ending = "timeout";\n                code = "gate-timeout";', 'ending = "timeout";\n                code = "";', "a timeout is a report with no error"),
    ("overflow-as-report", R, 'code = "gate-output-overflow";', 'code = "";', "an overflow is a report with no error"),
    ("log-empty", R, "revision, buffer.bytes(lb), verdict,", 'revision, "", verdict,', "the gate's log is written empty"),
    ("log-sha", R, "let log_sha = snapshot.hex_digest(heap, log);", 'let log_sha = snapshot.hex_digest(heap, "x");', "the log's hash is not the file's"),
    ("log-size", R, "buffer.bytes(ls), len(log), buffer.bytes(rs)", "buffer.bytes(ls), len(log) + 1, buffer.bytes(rs)", "the log's size is not the file's"),
    ("report-ref", R, 'under(heap, exec_dir, "report.json")', 'under(heap, exec_dir, "report.txt")', "the report is written under another name than the one answered"),
    ("write-failure-ignored", R, "        if rc == 0 {\n            borrow log_sha as &ls in {", "        if true {\n            borrow log_sha as &ls in {", "a file that could not be written is reported as evidence"),
    ("answer-state", R, "if len(code) == 0 {\n        w = json.put_string(heap, w, \"succeeded\");", "if len(code) != 0 {\n        w = json.put_string(heap, w, \"succeeded\");", "a failed run answers succeeded"),
    ("refused-answered-ok", R, "gate_task.Checked::Refused(why) => {\n                            answer(heap, io, text_of(src, tp, rid), text_of(src, tp, tid), gate_task.rule_name(why),", "gate_task.Checked::Refused(why) => {\n                            answer(heap, io, text_of(src, tp, rid), text_of(src, tp, tid), \"\",", "a refusal is answered as a success"),
    ("check-skipped", R, "match gate_task.check(kind, repo, revision, workspace, exec_dir, timeout_ms) {", "match gate_task.Checked::Held {", "the task is not checked"),
    ("unknown-verb-served", R, 'is(src, tp, json.get(src, tp, 0, "verb"), "execute") ||', 'is(src, tp, json.get(src, tp, 0, "verb"), "execute") && false ||', "a verb that is not execute is served"),
    ("request-id-not-needed", R, "|| len(text_of(src, tp, rid)) == 0 ||", "||", "a request with no id is answered"),
    ("task-id-not-needed", R, "|| len(text_of(src, tp, tid)) == 0 {", "{", "a request with no task id is answered"),
    ("contract-not-checked", R, 'if !is(src, tp, json.get(src, tp, 0, "contract"), "forge-worker/1") ||', "if false ||", "another contract version is served"),
    ("deadline-total", T, "return timeout_ms / 5 * 4;", "return timeout_ms;", "the runner uses all of Forge's time"),
    ("gate-script-exit", T, '"; exit $?"', '""', "the shell runs the gate in its own place: a gate that kills its parent kills the runner"),
]


def one(m):
    name, rel, old, new, what = m
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / "w"
        shutil.copytree(ROOT, work, ignore=shutil.ignore_patterns(".git", "build", "target"))
        path = work / rel
        text = path.read_text()
        if text.count(old) != 1:
            return name, what, "INVALID (old text occurs %d times)" % text.count(old)
        path.write_text(text.replace(old, new))
        scratch = pathlib.Path(tmp) / "s"
        scratch.mkdir()
        env = dict(os.environ, CANCHO=CANCHO)
        try:
            run = subprocess.run(["sh", str(work / "scripts" / "check_gate_runner.sh"), str(scratch)], capture_output=True, text=True, timeout=300, env=env, cwd=work)
        except subprocess.TimeoutExpired:
            subprocess.run(["pkill", "-x", "gate_runner"])
            subprocess.run(["pkill", "-f", "^sleep 79$"])
            subprocess.run(["pkill", "-f", "[g]it rev-parse HEAD"])
            return name, what, "KILLED"
        out = run.stdout + run.stderr
        if "did not build" in out or "error:" in out and "FAIL" not in out:
            return name, what, "INVALID (does not build)"
        subprocess.run(["pkill", "-x", "gate_runner"])
        subprocess.run(["pkill", "-f", "^sleep 79$"])
        subprocess.run(["pkill", "-f", "[g]it rev-parse HEAD"])
        return name, what, "KILLED" if run.returncode != 0 or "FAIL " in out else "SURVIVED"


def main():
    only = None
    if "--only" in sys.argv:
        only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
    todo = [m for m in M if only is None or m[0] in only]
    results = []
    for m in todo:
        r = one(m)
        print(f"{r[2]:9} {r[0]:24} {r[1]}", flush=True)
        results.append(r)
    bad = [r for r in results if r[2] != "KILLED"]
    print(f"{len(results) - len(bad)} of {len(results)} breaks killed")
    sys.exit(1 if bad else 0)


main()
