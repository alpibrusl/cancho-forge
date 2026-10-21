"""Test oracle for src/dispatch.cho (docs/worker-contract.md, 8): one deliberate break per decision, built in a
copy, run against `cancho test dispatch`. A break is KILLED when the tests fail. Python edits copies of the source
and runs the compiler; it decides nothing about the product.

Usage: CANCHO=path/to/cancho python3 scripts/mutate_dispatch.py [--only NAME,NAME]"""
import concurrent.futures
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANCHO = os.environ.get("CANCHO", "cancho")

# (name, old, new, what it breaks); `old` must occur exactly once in src/dispatch.cho.
# The arms of `consequence` and `rule_tag` for `Reply(Valid(Failed | Partial))` have no break: `classify` makes a `Said`
# of those two states, so the arms cannot be reached from a run.
# Two decisions have no break because none can be observed: the `string_plain` test of the hash (a raw view of an
# escaped string has a backslash, which is not a hex digit, so `sha256_ok` refuses it first, and the guard was
# removed for that reason) and `parse(...) > 0` against `>= 0` (a document that parses has at least one node).
M = [
    ("timeout-consequence", "        Ending::Timeout => {\n            return Consequence::RetryOrFail;", "        Ending::Timeout => {\n            return Consequence::Failed;", "a timeout is not retried"),
    ("overflow-consequence", "        Ending::Overflow => {\n            return Consequence::Failed;", "        Ending::Overflow => {\n            return Consequence::RetryOrFail;", "an output overflow is retried"),
    ("unavailable-consequence", "        Ending::Unavailable(errno) => {\n            return Consequence::Blocked;", "        Ending::Unavailable(errno) => {\n            return Consequence::RetryOrFail;", "a worker that cannot start is retried instead of blocking"),
    ("crash-consequence", "        Ending::Crashed(signal) => {\n            return Consequence::RetryOrFail;", "        Ending::Crashed(signal) => {\n            return Consequence::Failed;", "a crash is not retried"),
    ("error-consequence", "        Ending::Error(code) => {\n            return Consequence::RetryOrFail;", "        Ending::Error(code) => {\n            return Consequence::Failed;", "a non-zero exit is not retried"),
    ("refused-consequence", "                response.Verdict::Refused(rule, reason) => {\n                    return Consequence::Failed;", "                response.Verdict::Refused(rule, reason) => {\n                    return Consequence::RetryOrFail;", "a protocol error is retried blindly"),
    ("succeeded-consequence", "                        response.State::Succeeded => {\n                            return Consequence::Verification;", "                        response.State::Succeeded => {\n                            return Consequence::Poll;", "a worker's success is not sent to verification"),
    ("cancelled-consequence", "                        response.State::Cancelled => {\n                            return Consequence::Cancelled;", "                        response.State::Cancelled => {\n                            return Consequence::Verification;", "a cancelled run goes to verification"),
    ("accepted-consequence", "                        response.State::Accepted => {\n                            return Consequence::Poll;", "                        response.State::Accepted => {\n                            return Consequence::Cancelled;", "an accepted job is not polled"),
    ("said-retryable-ignored", "            if retry {\n                return Consequence::WorkerRetryable;", "            if !retry {\n                return Consequence::WorkerRetryable;", "the worker's retryable flag is read backwards"),
    ("said-always-retryable", "            return Consequence::WorkerSaid;\n        }\n        Ending::Reply(verdict) => {\n            match verdict {\n                // Not valid", "            return Consequence::WorkerRetryable;\n        }\n        Ending::Reply(verdict) => {\n            match verdict {\n                // Not valid", "every failure the worker reports is retried"),
    ("said-never-retryable", "            if retry {\n                return Consequence::WorkerRetryable;\n            }\n", "", "no failure the worker reports is retried"),
    ("said-failed-lost", "                        response.State::Failed => {\n                            return Ending::Said(state, response.retryable(heap, out));", "                        response.State::Failed => {\n                            return Ending::Reply(verdict);", "a failed reply is no longer a Said ending"),
    ("said-partial-lost", "                        response.State::Partial => {\n                            return Ending::Said(state, response.retryable(heap, out));", "                        response.State::Partial => {\n                            return Ending::Reply(verdict);", "a partial reply is no longer a Said ending"),
    ("said-failed-flag-false", "                        response.State::Failed => {\n                            return Ending::Said(state, response.retryable(heap, out));", "                        response.State::Failed => {\n                            return Ending::Said(state, false);", "a failed reply's retryable flag is dropped"),
    ("said-partial-flag-true", "                        response.State::Partial => {\n                            return Ending::Said(state, response.retryable(heap, out));", "                        response.State::Partial => {\n                            return Ending::Said(state, true);", "a partial reply is always retryable"),
    ("said-tag", "        Ending::Said(state, retry) => {\n            return \"\";", "        Ending::Said(state, retry) => {\n            return \"worker-error\";", "a reply that is valid carries a refusal tag"),
    ("retryable-name", "            return \"worker-retryable\";", "            return \"worker-said\";", "the consequence is named wrongly in the journal and the output"),
    ("refused-not-said", "                response.Verdict::Refused(rule, reason) => {\n                    return Ending::Reply(verdict);", "                response.Verdict::Refused(rule, reason) => {\n                    return Ending::Said(response.State::Failed, true);", "a refused reply is retried"),
    ("exit-test", "            if n != 0 {\n                return Ending::Error(n);", "            if n > 0 {\n                return Ending::Error(n);", "a negative exit status is read as success"),
    ("exit-test-skip", "            if n != 0 {\n                return Ending::Error(n);\n            }\n", "", "a non-zero exit is read as a reply"),
    ("validate-skip", "let verdict = response.validate(heap, out, request_id, task_id, is_async);", "let verdict = response.Verdict::Valid(response.State::Succeeded);", "a reply is not validated"),
    ("tag-timeout", "return \"worker-timeout\";", "return \"worker-crashed\";", "a timeout is tagged as a crash"),
    ("tag-unavailable", "return \"worker-unavailable\";", "return \"worker-error\";", "an unavailable worker is tagged as an error"),
    ("tag-overflow", "return \"worker-output-overflow\";", "return \"worker-timeout\";", "an overflow is tagged as a timeout"),
    ("tag-error", "return \"worker-error\";", "return \"worker-crashed\";", "an error exit is tagged as a crash"),
    ("tag-crashed", "return \"worker-crashed\";", "return \"worker-error\";", "a crash is tagged as an error"),
    ("valid-tag", "                response.Verdict::Valid(state) => {\n                    return \"\";", "                response.Verdict::Valid(state) => {\n                    return \"worker-protocol\";", "a valid reply carries a refusal tag"),
    ("refused-tag", "return response.rule_name(rule);", "return \"worker-protocol\";", "an invalid evidence ref is tagged as a protocol error"),
    ("setup-tag", "        Ending::Setup(errno) => {\n            return \"path-invalid\";", "        Ending::Setup(errno) => {\n            return \"worker-error\";", "an unusable execution directory is tagged as a worker error"),
    ("setup-consequence", "        Ending::Setup(errno) => {\n            return Consequence::Blocked;", "        Ending::Setup(errno) => {\n            return Consequence::RetryOrFail;", "an unusable execution directory is retried"),
    ("timeout-arm", "        process.Ran::TimedOut => {\n            return Ending::Timeout;", "        process.Ran::TimedOut => {\n            return Ending::Overflow;", "a deadline is read as an overflow"),
    ("overflow-arm", "        process.Ran::TooMuch => {\n            return Ending::Overflow;", "        process.Ran::TooMuch => {\n            return Ending::Timeout;", "an overflow is read as a deadline"),
    ("signal-value", "return Ending::Crashed(s);", "return Ending::Crashed(0);", "the signal number is lost"),
    ("errno-value", "return Ending::Unavailable(e);", "return Ending::Unavailable(0);", "the errno is lost"),
    ("exit-value", "return Ending::Error(n);", "return Ending::Error(1);", "the exit status is lost"),
]


def sh(cmd, cwd):
    return subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)


def one(m):
    name, old, new, what = m
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / "w"
        shutil.copytree(ROOT, work, ignore=shutil.ignore_patterns(".git", "build", "target"))
        path = work / "src" / "dispatch.cho"
        text = path.read_text()
        if text.count(old) != 1:
            return name, what, f"BAD BREAK: the old text occurs {text.count(old)} times"
        path.write_text(text.replace(old, new))
        # the dispatch set's section of the output
        manifest = work / "cancho.toml"
        r = sh([CANCHO, "test"], work)
        out = r.stdout + r.stderr
        section = out.split("== test dispatch")[-1] if "== test dispatch" in out else out
        failed = "FAILED" in section or "error" in section.lower() and "test result: ok" not in section
        return name, what, "KILLED" if failed else "SURVIVED"


def main():
    only = None
    if "--only" in sys.argv:
        only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
    todo = [m for m in M if only is None or m[0] in only]
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        results = list(pool.map(one, todo))
    survived = [r for r in results if r[2] != "KILLED"]
    for name, what, verdict in results:
        print(f"{verdict:9} {name:20} {what}")
    print(f"{len(results) - len(survived)} of {len(results)} breaks killed")
    sys.exit(1 if survived else 0)


main()
