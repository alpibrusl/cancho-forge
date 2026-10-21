"""Test oracle for `forge recover` (issue #15, `execution.lost`): one deliberate break per decision of src/recover.cho,
src/recover_io.cho and the verb in src/main.cho, applied to a copy of the tree. A break of src/recover.cho is run against
`cancho test` (the recover set); every other break is run the way the gate runs it (scripts/check_recover.sh: the forge
binary, real journals, `forge status` read back). A break is KILLED when the tests fail or the script fails (an `ok` line
missing, a `FAIL`, a hang past the time limit); one that does not build is INVALID (this script's mistake, not a kill).
The end-to-end runs are serial: the oracles look at the whole process table. Python edits copies of the source and runs the
compiler; it decides nothing about the product.

Usage: CANCHO=path/to/cancho python3 scripts/mutate_recover.py [--only NAME,NAME]"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANCHO = os.environ.get("CANCHO", "cancho")

P = "src/recover.cho"
IO = "src/recover_io.cho"
M_ = "src/main.cho"
# (name, file, old, new, what it breaks); `old` must occur exactly once in the file.
M = [
    ("running-not-phase-1", P, 'if bytes.equal(kind, "task.running") {\n                    ph = map.put(heap, ph, id, 1);', 'if bytes.equal(kind, "task.running") {\n                    ph = map.put(heap, ph, id, 0);', "a running task with no intent is not seen"),
    ("move-does-not-end-phase", P, "} else if bytes.starts_with(kind, \"task.\") {\n                    ph = map.put(heap, ph, id, 0);", "} else if bytes.starts_with(kind, \"task.\") {\n                    ph = map.put(heap, ph, id, current);", "a task that moved on is still settled"),
    ("started-while-not-running", P, 'current > 0 && bytes.equal(kind, "execution.started")', 'bytes.equal(kind, "execution.started")', "an intent of a task that is not running makes it running"),
    ("finished-while-not-running", P, 'current > 0 && bytes.equal(kind, "execution.finished")', 'bytes.equal(kind, "execution.finished")', "a finished record of a task that is not running makes it running"),
    ("lost-while-not-running", P, 'current > 0 && bytes.equal(kind, "execution.lost")', 'bytes.equal(kind, "execution.lost")', "a lost record of a task that is not running makes it running"),
    ("started-phase", P, 'ph = map.put(heap, ph, id, 2);', 'ph = map.put(heap, ph, id, 1);', "a started execution is taken for one never started"),
    ("finished-phase", P, 'ph = map.put(heap, ph, id, 3);', 'ph = map.put(heap, ph, id, 2);', "a finished execution is taken for a lost one"),
    ("lost-phase", P, 'ph = map.put(heap, ph, id, 4);', 'ph = map.put(heap, ph, id, 2);', "a recovery cut short writes execution.lost again"),
    ("starts-not-counted", P, "st = map.put(heap, st, id, seen + 1);", "st = map.put(heap, st, id, seen);", "the attempts are never counted"),
    ("starts-counted-twice", P, "st = map.put(heap, st, id, seen + 1);", "st = map.put(heap, st, id, seen + 2);", "each start counts twice"),
    ("unstarted-tag", P, 'event.refusal(heap, s, id, "execution-unstarted")', 'event.refusal(heap, s, id, "execution-lost")', "a run never started is tagged as lost"),
    ("unstarted-blocked", P, "o = add(heap, o, event.transition(heap, s + 1, task.kind_of_state(task.State::Ready), id, \"forge\", \"\"));\n        t = say(heap, t, id, \"execution-unstarted", "o = add(heap, o, event.transition(heap, s + 1, task.kind_of_state(task.State::Blocked), id, \"forge\", \"\"));\n        t = say(heap, t, id, \"execution-unstarted", "a run never started is blocked"),
    ("unstarted-not-counted", P, "Counts { unstarted: c.unstarted + 1,", "Counts { unstarted: c.unstarted,", "the unstarted are not counted"),
    ("finished-accepted", P, "task.kind_of_state(task.State::Verification), id, \"forge\", \"\")", "task.kind_of_state(task.State::Accepted), id, \"forge\", \"\")", "a recorded claim accepts the task"),
    ("finished-ready", P, "task.kind_of_state(task.State::Verification), id, \"forge\", \"\")", "task.kind_of_state(task.State::Ready), id, \"forge\", \"\")", "a recorded claim is thrown away"),
    ("finished-not-counted", P, "finished: c.finished + 1,", "finished: c.finished,", "the settled claims are not counted"),
    ("lost-record-missing", P, "if p == 2 {\n        o = add(heap, o, event.execution", "if p == 9 {\n        o = add(heap, o, event.execution", "the loss is not written"),
    ("lost-record-seq", P, '"execution.lost", id, ""));\n        s = s + 1;', '"execution.lost", id, ""));\n        s = s + 0;', "the records after the loss reuse its seq"),
    ("budget-boundary", P, "if started >= retry.max_attempts() {", "if started > retry.max_attempts() {", "one start too many"),
    ("budget-ignored", P, "if started >= retry.max_attempts() {", "if started >= 99 {", "a task never runs out of starts"),
    ("budget-always", P, "if started >= retry.max_attempts() {", "if started >= 1 {", "the first lost run exhausts the budget"),
    ("exhausted-ready", P, "task.kind_of_state(task.State::Blocked), id, \"forge\", \"\")", "task.kind_of_state(task.State::Ready), id, \"forge\", \"\")", "an exhausted task is left ready"),
    ("exhausted-tag", P, 'event.refusal(heap, s, id, "retry-exhausted")', 'event.refusal(heap, s, id, "execution-lost")', "an exhausted task is tagged as lost"),
    ("exhausted-not-counted", P, "exhausted: c.exhausted + 1 });", "exhausted: c.exhausted });", "the exhausted are not counted"),
    ("lost-tag", P, 'event.refusal(heap, s, id, "execution-lost")', 'event.refusal(heap, s, id, "retry-exhausted")', "a lost run is tagged as exhausted"),
    ("lost-blocked", P, "o = add(heap, o, event.transition(heap, s + 1, task.kind_of_state(task.State::Ready), id, \"forge\", \"\"));\n    t = say(heap, t, id, \"execution-lost", "o = add(heap, o, event.transition(heap, s + 1, task.kind_of_state(task.State::Blocked), id, \"forge\", \"\"));\n    t = say(heap, t, id, \"execution-lost", "a lost run is blocked"),
    ("lost-not-counted", P, "lost: c.lost + 1, finished: c.finished, exhausted: c.exhausted });\n}", "lost: c.lost, finished: c.finished, exhausted: c.exhausted });\n}", "the lost are not counted"),
    ("seq-after-pair", P, 'running -> ready");\n    return (o, t, s + 2, Counts { unstarted: c.unstarted, lost: c.lost + 1', 'running -> ready");\n    return (o, t, s + 1, Counts { unstarted: c.unstarted, lost: c.lost + 1', "the next task's records reuse a seq"),
    ("by-worker", P, 'event.transition(heap, s + 1, task.kind_of_state(task.State::Ready), id, "forge", ""));\n    t = say(heap, t, id, "execution-lost', 'event.transition(heap, s + 1, task.kind_of_state(task.State::Ready), id, "worker", ""));\n    t = say(heap, t, id, "execution-lost', "the move is written as a worker's"),
    ("first-seq", P, "var seq = records + 1;", "var seq = records;", "the first new record reuses the last seq"),
    ("phase-0-settled", P, "map.value_at(pb, e) > 0 {", "map.value_at(pb, e) >= 0 {", "a task that is not running is settled"),
    ("recover-io-refused-written", IO, "if report.rule != 0 {", "if false {", "a journal that is refused is written to"),
    ("recover-io-seq", IO, "recover.plan(heap, buffer.bytes(db), report.records)", "recover.plan(heap, buffer.bytes(db), report.records + 1)", "the new records skip a seq"),
    ("recover-io-short", IO, "while k < len(all) && failure == 0 {", "while k < len(all) - 1 && failure == 0 {", "the last record of the plan is not written"),
    ("main-refused-exit", M_, 'io.error_all(io, "forge: the journal is refused: ");\n                            io.error_all(io, task.rule_code_name(rule));\n                            io.error_all(io, "\\n");\n                            code = 1;\n                        } else if errno != 0 {', 'io.error_all(io, "forge: the journal is refused: ");\n                            io.error_all(io, task.rule_code_name(rule));\n                            io.error_all(io, "\\n");\n                            code = 0;\n                        } else if errno != 0 {', "a refused journal is exit 0"),
    ("main-usage-count", M_, "if arg_count(args) != 3 {\n        return usage(io);\n    }\n    let jpath = concat(heap, arg(args, 2), \"/journal.jsonl\");\n    let lpath", "if arg_count(args) < 3 {\n        return usage(io);\n    }\n    let jpath = concat(heap, arg(args, 2), \"/journal.jsonl\");\n    let lpath", "an extra argument is taken"),
    ("main-path-not-checked", M_, "if journal_io.path_ok(fs, buffer.bytes(jb)) == false {\n                io.error_all(io, \"forge: path-invalid: <dir> must be absolute, with no .. component\\n\");\n                code = 2;\n            } else if journal_io.exists(fs, buffer.bytes(jb)) == false {\n                io.error_all(io, \"forge: no journal.jsonl in that directory\\n\");\n                code = 3;\n            } else {\n                match lock.acquire(fs, buffer.bytes(lb)) {\n                    lock.Lock::Refused(rule) => {\n                        io.error_all(io, \"forge: \");\n                        io.error_all(io, task.rule_code_name(rule));\n                        io.error_all(io, \": the workspace cannot be written\\n\");\n                        code = 3;\n                    }\n                    lock.Lock::Failed(errno) => {\n                        io.error_all(io, \"forge: the lock of the workspace could not be taken\\n\");\n                        code = 3;\n                    }\n                    lock.Lock::Held(held) => {\n                        let recover_io", "if false {\n                io.error_all(io, \"forge: path-invalid: <dir> must be absolute, with no .. component\\n\");\n                code = 2;\n            } else if journal_io.exists(fs, buffer.bytes(jb)) == false {\n                io.error_all(io, \"forge: no journal.jsonl in that directory\\n\");\n                code = 3;\n            } else {\n                match lock.acquire(fs, buffer.bytes(lb)) {\n                    lock.Lock::Refused(rule) => {\n                        io.error_all(io, \"forge: \");\n                        io.error_all(io, task.rule_code_name(rule));\n                        io.error_all(io, \": the workspace cannot be written\\n\");\n                        code = 3;\n                    }\n                    lock.Lock::Failed(errno) => {\n                        io.error_all(io, \"forge: the lock of the workspace could not be taken\\n\");\n                        code = 3;\n                    }\n                    lock.Lock::Held(held) => {\n                        let recover_io", "a relative directory is used"),
    ("main-count-finished", M_, "counts.unstarted + counts.lost + counts.finished)", "counts.unstarted + counts.lost)", "the settled claims are not in the count"),
    ("main-count-unstarted", M_, "counts.unstarted + counts.lost + counts.finished)", "counts.lost + counts.finished)", "the unstarted are not in the count"),
    ("main-text-not-shown", M_, "borrow text as &tb in {\n                                buffer.write(io, tb);\n                            }", "borrow text as &tb in {\n                            }", "the tasks settled are not named"),
]

# Breaks that cannot change an answer, with the reason; reported EQUIVALENT instead of SURVIVED.
EQUIVALENT = {}


def unit(name):
    return name in UNIT


UNIT = {m[0] for m in M if m[1] == P}


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
            head = "== test recover"
            section = out.split(head)[-1] if head in out else out
            if "test result: ok" in section and "FAILED" not in section and "error:" not in section:
                return name, what, "SURVIVED"
            if "error:" in section and "test result" not in section:
                return name, what, "INVALID (does not build)"
            return name, what, "KILLED"
        scratch = pathlib.Path(tmp) / "s"
        scratch.mkdir()
        try:
            run = subprocess.run(["sh", str(work / "scripts" / "check_recover.sh"), str(scratch)], capture_output=True, text=True, timeout=300, env=env, cwd=work)
        except subprocess.TimeoutExpired:
            subprocess.run(["pkill", "-f", "^sleep 83$"])
            return name, what, "KILLED"
        subprocess.run(["pkill", "-f", "^sleep 83$"])
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
