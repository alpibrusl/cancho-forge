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
R = "workers/gate_runner.cho"
ind = " " * 40
T = "src/retry.cho"
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
    ("env-unchecked", G, "checked = gate_task.env_checked(gate_env.check_text(heap, env));", "checked = gate_task.Checked::Held;", "Forge runs a bad environment and leaves the refusal to the runner"),
    ("env-not-passed", G, "buffer.bytes(nb), timeout_ms, 1048576, checkout, execution_dir, env)", 'buffer.bytes(nb), timeout_ms, 1048576, checkout, execution_dir, "")', "the operator's environment is not put in the request"),
    ("env-checked-only-when-empty", G, "if len(env) > 0 {\n            match checked {", "if len(env) == 0 {\n            match checked {", "the environment is checked only when there is none"),
    ("tools-not-checked", R, "gate_task.required_tools(repo), gate_task.gate_command(repo))", 'gate_task.required_tools(""), gate_task.gate_command(repo))', "the runner starts the gate without checking for the tools it needs"),
    ("verdict-pass", G, 'if json.string_equals(report, tp, v, "pass") {\n                    code = 1;', 'if json.string_equals(report, tp, v, "pass") {\n                    code = 2;', "a pass is recorded as a fail"),
    ("verdict-fail", G, 'if json.string_equals(report, tp, v, "fail") {\n                    code = 2;', 'if json.string_equals(report, tp, v, "fail") {\n                    code = 1;', "a fail is recorded as a pass"),
    ("started-not-written", G, 'seq = note_execution(heap, fs, journal_path, s4, "execution.started", tid, "");', "seq = s4;", "the intent is not written before the worker starts"),
    ("finished-always", G, "fn finish_attempt[&h, &f, &p, &i, &d](heap: &!h Heap, fs: &f Fs(\"\"), path: &p [byte], seq: int, id: &i [byte], e: dispatch.Ending, execution_dir: &d [byte]) -> [heap, fs_read(\"\"), fs_write(\"\"), file_read, file_write] int {\n    if succeeded(e) {", "fn finish_attempt[&h, &f, &p, &i, &d](heap: &!h Heap, fs: &f Fs(\"\"), path: &p [byte], seq: int, id: &i [byte], e: dispatch.Ending, execution_dir: &d [byte]) -> [heap, fs_read(\"\"), fs_write(\"\"), file_read, file_write] int {\n    if true {", "a claim is written for a run that produced none"),
    ("finished-never", G, "fn finish_attempt[&h, &f, &p, &i, &d](heap: &!h Heap, fs: &f Fs(\"\"), path: &p [byte], seq: int, id: &i [byte], e: dispatch.Ending, execution_dir: &d [byte]) -> [heap, fs_read(\"\"), fs_write(\"\"), file_read, file_write] int {\n    if succeeded(e) {", "fn finish_attempt[&h, &f, &p, &i, &d](heap: &!h Heap, fs: &f Fs(\"\"), path: &p [byte], seq: int, id: &i [byte], e: dispatch.Ending, execution_dir: &d [byte]) -> [heap, fs_read(\"\"), fs_write(\"\"), file_read, file_write] int {\n    if false {", "the runner's verdict is not recorded"),
    ("claim-never-reported", G, "fn claimed_of[&h, &f, &d](heap: &!h Heap, fs: &f Fs(\"\"), e: dispatch.Ending, execution_dir: &d [byte]) -> [heap, fs_read(\"\"), file_read] int {\n    if succeeded(e) {", "fn claimed_of[&h, &f, &d](heap: &!h Heap, fs: &f Fs(\"\"), e: dispatch.Ending, execution_dir: &d [byte]) -> [heap, fs_read(\"\"), file_read] int {\n    if false {", "the output never names the claimed verdict"),
    ("ending-refusal-not-written", G, "seq = note(heap, fs, journal_path, seq, tid, tag, false);", "seq = seq;", "the rule tag of a refused ending is not journalled"),
    ("check-refusal-not-written", G, "seq = note(heap, fs, journal_path, seq, tid, gate_task.rule_name(why), false);", "seq = seq;", "the rule tag of a refused task is not journalled"),
    ("move-always-verification", G, "retry.target_after(consequence, decision), task.Actor::Forge, false);\n                                            tasks = t5;\n                                            seq = s5;\n                                            outcome = Outcome::Ended(ending, claimed_of(", "task.State::Verification, task.Actor::Forge, false);\n                                            tasks = t5;\n                                            seq = s5;\n                                            outcome = Outcome::Ended(ending, claimed_of(", "every ending leaves the task in verification"),
    ("task-number", G, "let id = task_id(heap, revision, report.tasks + 1);", "let id = task_id(heap, revision, report.tasks + 0);", "the first task is numbered 0"),
    ("task-number-reported", G, "number: report.tasks + 1, records: records, attempts: attempts };", "number: report.tasks, records: records, attempts: attempts };", "the number reported is not the one used"),
    ("approved-by-forge", G, "tid, task.State::Approved, task.Actor::Human, false);", "tid, task.State::Approved, task.Actor::Forge, false);", "the approval is Forge's own"),
    ("proposed-by-forge", G, "tid, task.State::Proposed, task.Actor::Human, fresh);", "tid, task.State::Proposed, task.Actor::Forge, fresh);", "the proposal is Forge's own"),
    ("fresh-file-not-synced", G, "let fresh = report.records == 0;", "let fresh = false;", "(equivalent for the cases run: the directory sync is not observable)"),
    ("exit-claim", M_, 'line(io, "claimed verdict: ", gate_run.verdict_name(claim));\n                    io.write_all(io, "(a worker\'s claim: the task is in verification, not accepted)\\n");\n                    code = 0;', 'line(io, "claimed verdict: ", gate_run.verdict_name(claim));\n                    io.write_all(io, "(a worker\'s claim: the task is in verification, not accepted)\\n");\n                    code = 4;', "a recorded claim is exit 4"),
    ("exit-refused", M_, 'line(io, "refused: ", gate_task.rule_name(why));\n                code = 1;', 'line(io, "refused: ", gate_task.rule_name(why));\n                code = 0;', "a refused task is exit 0"),
    ("exit-locked", M_, 'code = 2;\n            } else {\n                match lock.acquire(fs, buffer.bytes(lb)) {\n                    lock.Lock::Refused(rule) => {\n                        io.error_all(io, "forge: ");\n                        io.error_all(io, task.rule_code_name(rule));\n                        io.error_all(io, ": the workspace cannot be written\\n");\n                        code = 3;', 'code = 2;\n            } else {\n                match lock.acquire(fs, buffer.bytes(lb)) {\n                    lock.Lock::Refused(rule) => {\n                        io.error_all(io, "forge: ");\n                        io.error_all(io, task.rule_code_name(rule));\n                        io.error_all(io, ": the workspace cannot be written\\n");\n                        code = 1;', "a locked workspace is exit 1"),
    ("workers-path-not-checked", M_, ' || journal_io.path_ok(fs, workers) == false {\n                io.error_all(io, "forge: path-invalid: <dir> and <workers> must be absolute, with no .. component\\n");\n                code = 2;\n            } else {', ' {\n                io.error_all(io, "forge: path-invalid: <dir> and <workers> must be absolute, with no .. component\\n");\n                code = 2;\n            } else {', "a workers directory with .. is used"),
    ("timeout-not-checked", M_, "        timeout = nat_of(arg(args, 8));\n        if timeout < 0 {\n            return usage(io);\n        }", "        timeout = nat_of(arg(args, 8));", "a timeout that is not a number is taken as -1"),
    ("timeout-default", M_, "var timeout = 900000;", "var timeout = 1000;", "the default timeout is under the least a run is given"),
    ("claim-line", M_, 'line(io, "claimed verdict: ", gate_run.verdict_name(claim));', 'line(io, "verdict: ", gate_run.verdict_name(claim));', "the output does not say the verdict is a claim"),
    ("retry-max-two", T, "    return 3;", "    return 2;", "only two attempts are made"),
    ("retry-max-four", T, "    return 3;", "    return 4;", "four attempts are made"),
    ("retry-boundary", T, "    if attempt >= max_attempts() {", "    if attempt > max_attempts() {", "one attempt too many"),
    ("retry-write-allowed", T, "    if !read_only {\n        return Decision::WriteRefused;", "    if read_only {\n        return Decision::WriteRefused;", "a task that writes is retried"),
    ("retry-timeout-retried", T, "        dispatch.Consequence::RetryOrFail => {\n            return false;", "        dispatch.Consequence::RetryOrFail => {\n            return true;", "a deadline is retried"),
    ("retry-verification-retried", T, "        dispatch.Consequence::Verification => {\n            return false;", "        dispatch.Consequence::Verification => {\n            return true;", "a claim is retried"),
    ("retry-workersaid-retried", T, "        dispatch.Consequence::WorkerSaid => {\n            return false;", "        dispatch.Consequence::WorkerSaid => {\n            return true;", "a failure that cannot be helped is retried"),
    ("retry-never", T, "        dispatch.Consequence::WorkerRetryable => {\n            return true;", "        dispatch.Consequence::WorkerRetryable => {\n            return false;", "a retryable failure is not retried"),
    ("retry-tag-exhausted", T, 'return "retry-exhausted";', 'return "retry-write-refused";', "an exhausted budget is tagged as a refused write"),
    ("retry-tag-write", T, 'return "retry-write-refused";', 'return "retry-exhausted";', "a refused write is tagged as an exhausted budget"),
    ("retry-after-exhausted-ready", T, "        Decision::Exhausted => {\n            return task.State::Blocked;", "        Decision::Exhausted => {\n            return task.State::Ready;", "a task out of attempts is left ready"),
    ("retry-after-write-ready", T, "        Decision::WriteRefused => {\n            return task.State::Blocked;", "        Decision::WriteRefused => {\n            return task.State::Ready;", "a refused write is left ready"),
    ("retry-after-again-running", T, "        Decision::Again => {\n            return task.State::Ready;", "        Decision::Again => {\n            return task.State::Blocked;", "a task about to be retried is blocked"),
    ("flow-retryable-blocked", F, "dispatch.Consequence::WorkerRetryable => {\n            return task.State::Ready;", "dispatch.Consequence::WorkerRetryable => {\n            return task.State::Blocked;", "a retryable failure is blocked"),
    ("loop-retry-not-written", G, "seq = note_retry(heap, fs, journal_path, seq, tid, attempts);", "seq = seq;", "the journal does not say why the task ran twice"),
    ("loop-no-ready", G, "let (t5, s5) = move_to(heap, fs, journal_path, tasks, seq, tid, task.State::Ready, task.Actor::Forge, false);", "let (t5, s5) = (tasks, seq);", "the task is not moved back to ready"),
    ("loop-started-not-written", G, 'seq = note_execution(heap, fs, journal_path, s6, "execution.started", tid, "");', "seq = s6;", "the second attempt has no intent in the journal"),
    ("loop-same-request-id", G, "    if attempt > 1 {", "    if attempt > 100 {", "every attempt has the request id of the first"),
    ("loop-attempt-not-sent", G, "buffer.bytes(rb), attempts, tid,", "buffer.bytes(rb), 1, tid,", "the worker is always told it is the first attempt"),
    ("loop-write-task", G, "retry.decide(consequence, attempts, true)", "retry.decide(consequence, attempts, false)", "the gate is treated as a task that writes"),
    ("loop-attempts-not-counted", G, "attempts = attempts + 1;", "attempts = 1;", "the attempts are not counted"),
    ("loop-exhausted-tag-not-written", G, ind+"retry.Decision::Exhausted => {\n"+ind+"    seq = note(heap, fs, journal_path, seq, tid, retry.rule_tag(decision), false);", ind+"retry.Decision::Exhausted => {\n"+ind+"    seq = seq;", "the refusal of an exhausted budget is not journalled"),
    ("show-attempts", M_, "if done.attempts > 1 {", "if done.attempts > 5 {", "the output does not say how many attempts were made"),
    ("show-retry-tag", M_, "done.attempts, true));\n                if len(again) > 0 {", "done.attempts, true));\n                if false {", "the output does not name the retry refusal"),]

# Breaks that cannot change an answer, with the reason; reported EQUIVALENT instead of SURVIVED.
EQUIVALENT = {
    "fresh-file-not-synced": "whether the parent directory of a new journal was synced cannot be seen without a power loss (docs/file-writes.md)",
}


def unit(name):
    return name.startswith(("flow-", "retry-"))


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
            head = "== test retry" if name.startswith("retry-") else "== test flow"
            section = out.split(head)[-1] if head in out else out
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
