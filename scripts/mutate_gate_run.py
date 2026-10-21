"""Test oracle for the first self-hosted task (`forge gate`, issue #18): one deliberate break per decision, applied to a
copy of the tree. A break of `src/flow.cho` is run against `cancho test` (the flow set); every other break is run the way
the gate runs it (scripts/check_gate_run.sh: the forge binary, a real runner process, real git checkouts, the journal read
back by `forge status` and `history`). A break is KILLED when the tests fail or the script fails (an `ok` line missing, a
`FAIL`, a hang past the time limit); one that does not build is INVALID (this script's mistake, not a kill). The
end-to-end runs are serial: the oracles look at the whole process table (`pgrep`). Python edits copies of the source and
runs the compiler; it decides nothing about the product.

Usage: CANCHO=path/to/cancho python3 scripts/mutate_gate_run.py [--only NAME,NAME]"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANCHO = os.environ.get("CANCHO", "cancho")

F = "src/flow.cho"
G = "src/gate_run.cho"
E = "src/event.cho"
M_ = "src/main.cho"
# (name, file, old, new, what it breaks); `old` must occur exactly once in the file.
M = [
    ("flow-verification-accepted", F, "dispatch.Consequence::Verification => {\n            return task.State::Verification;", "dispatch.Consequence::Verification => {\n            return task.State::Accepted;", "a worker's success accepts the task"),
    ("flow-retry-blocked", F, "dispatch.Consequence::RetryOrFail => {\n            return task.State::Ready;", "dispatch.Consequence::RetryOrFail => {\n            return task.State::Blocked;", "a lost execution is blocked, not ready"),
    ("flow-blocked-ready", F, "dispatch.Consequence::Blocked => {\n            return task.State::Blocked;", "dispatch.Consequence::Blocked => {\n            return task.State::Ready;", "a worker that could not be started leaves the task ready"),
    ("flow-failed-ready", F, "dispatch.Consequence::Failed => {\n            return task.State::Blocked;", "dispatch.Consequence::Failed => {\n            return task.State::Ready;", "a reply invalid for the contract is retried"),
    ("flow-workersaid-ready", F, "dispatch.Consequence::WorkerSaid => {\n            return task.State::Blocked;", "dispatch.Consequence::WorkerSaid => {\n            return task.State::Ready;", "a worker's own failure is retried"),
    ("flow-cancelled", F, "dispatch.Consequence::Cancelled => {\n            return task.State::Cancelled;", "dispatch.Consequence::Cancelled => {\n            return task.State::Blocked;", "a cancelled run is blocked"),
    ("flow-poll", F, "dispatch.Consequence::Poll => {\n            return task.State::Running;", "dispatch.Consequence::Poll => {\n            return task.State::Ready;", "an async worker's accepted job puts the task back to ready"),
    ("event-basis", E, 'w = json.put_string(heap, w, "claimed");', 'w = json.put_string(heap, w, "observed");', "a worker's claim is marked observed"),
    ("event-actor", E, 'w = json.put_string(heap, w, "worker");', 'w = json.put_string(heap, w, "forge");', "a worker's claim is written as Forge's"),
    ("verdict-pass", G, 'if json.string_equals(report, tp, v, "pass") {\n                    code = 1;', 'if json.string_equals(report, tp, v, "pass") {\n                    code = 2;', "a pass is recorded as a fail"),
    ("verdict-fail", G, 'if json.string_equals(report, tp, v, "fail") {\n                    code = 2;', 'if json.string_equals(report, tp, v, "fail") {\n                    code = 1;', "a fail is recorded as a pass"),
    ("started-not-written", G, 'seq = note_execution(heap, fs, journal_path, s4, "execution.started", tid, "");', "seq = s4;", "the intent is not written before the worker starts"),
    ("finished-always", G, "if succeeded(ending) {", "if true {", "a claim is written for a run that produced none"),
    ("finished-never", G, "if succeeded(ending) {", "if false {", "the runner's verdict is not recorded"),
    ("ending-refusal-not-written", G, "seq = note(heap, fs, journal_path, seq, tid, tag, false);", "seq = seq;", "the rule tag of a refused ending is not journalled"),
    ("check-refusal-not-written", G, "seq = note(heap, fs, journal_path, seq, tid, gate_task.rule_name(why), false);", "seq = seq;", "the rule tag of a refused task is not journalled"),
    ("move-always-verification", G, "flow.target_of(dispatch.consequence(ending))", "task.State::Verification", "every ending leaves the task in verification"),
    ("task-number", G, "let id = task_id(heap, revision, report.tasks + 1);", "let id = task_id(heap, revision, report.tasks + 0);", "the first task is numbered 0"),
    ("task-number-reported", G, "number: report.tasks + 1, records: records };", "number: report.tasks, records: records };", "the number reported is not the one used"),
    ("approved-by-forge", G, "tid, task.State::Approved, task.Actor::Human, false);", "tid, task.State::Approved, task.Actor::Forge, false);", "the approval is Forge's own"),
    ("proposed-by-forge", G, "tid, task.State::Proposed, task.Actor::Human, fresh);", "tid, task.State::Proposed, task.Actor::Forge, fresh);", "the proposal is Forge's own"),
    ("fresh-file-not-synced", G, "let fresh = report.records == 0;", "let fresh = false;", "(equivalent for the cases run: the directory sync is not observable)"),
    ("exit-claim", M_, 'io.write_all(io, "(a worker\'s claim: the task is in verification, not accepted)\\n");\n                    code = 0;', 'io.write_all(io, "(a worker\'s claim: the task is in verification, not accepted)\\n");\n                    code = 4;', "a recorded claim is exit 4"),
    ("exit-refused", M_, 'line(io, "refused: ", gate_task.rule_name(why));\n                code = 1;', 'line(io, "refused: ", gate_task.rule_name(why));\n                code = 0;', "a refused task is exit 0"),
    ("exit-locked", M_, 'io.error_all(io, ": the workspace cannot be written\\n");\n                        code = 3;', 'io.error_all(io, ": the workspace cannot be written\\n");\n                        code = 1;', "a locked workspace is exit 1"),
    ("workers-path-not-checked", M_, " || journal_io.path_ok(fs, workers) == false", "", "a workers directory with .. is used"),
    ("timeout-not-checked", M_, "        timeout = nat_of(arg(args, 8));\n        if timeout < 0 {\n            return usage(io);\n        }", "        timeout = nat_of(arg(args, 8));", "a timeout that is not a number is taken as -1"),
    ("timeout-default", M_, "var timeout = 900000;", "var timeout = 1000;", "the default timeout is under the least a run is given"),
    ("claim-line", M_, 'line(io, "claimed verdict: ", gate_run.verdict_name(claim));', 'line(io, "verdict: ", gate_run.verdict_name(claim));', "the output does not say the verdict is a claim"),
]

# Breaks that cannot change an answer, with the reason; reported EQUIVALENT instead of SURVIVED.
EQUIVALENT = {
    "fresh-file-not-synced": "whether the parent directory of a new journal was synced cannot be seen without a power loss (docs/file-writes.md)",
}


def unit(name):
    return name.startswith("flow-")


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
        env = dict(os.environ, CANCHO=CANCHO)
        if unit(name):
            r = subprocess.run([CANCHO, "test"], capture_output=True, text=True, cwd=work, env=env)
            out = r.stdout + r.stderr
            section = out.split("== test flow")[-1] if "== test flow" in out else out
            if "test result: ok" in section and "FAILED" not in section:
                return name, what, "SURVIVED"
            if "error:" in section and "test result" not in section:
                return name, what, "INVALID (does not build)"
            return name, what, "KILLED"
        scratch = pathlib.Path(tmp) / "s"
        scratch.mkdir()
        try:
            run = subprocess.run(["sh", str(work / "scripts" / "check_gate_run.sh"), str(scratch)], capture_output=True, text=True, timeout=300, env=env, cwd=work)
        except subprocess.TimeoutExpired:
            subprocess.run(["pkill", "-x", "gate_runner"])
            subprocess.run(["pkill", "-f", "^sleep 79$"])
            return name, what, "KILLED"
        subprocess.run(["pkill", "-x", "gate_runner"])
        subprocess.run(["pkill", "-f", "^sleep 79$"])
        out = run.stdout + run.stderr
        if "did not build" in out or "error:" in out and "FAIL" not in out:
            return name, what, "INVALID (does not build)"
        if run.returncode != 0 or "FAIL " in out:
            return name, what, "KILLED" if name not in EQUIVALENT else "KILLED (listed as equivalent: the reason no longer holds)"
        return name, what, "EQUIVALENT" if name in EQUIVALENT else "SURVIVED"


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
    bad = [r for r in results if r[2] not in ("KILLED", "EQUIVALENT")]
    equivalent = [r for r in results if r[2] == "EQUIVALENT"]
    print(f"{len(results) - len(bad) - len(equivalent)} of {len(results)} breaks killed, {len(equivalent)} equivalent (cannot change an answer)")
    sys.exit(1 if bad else 0)


main()
