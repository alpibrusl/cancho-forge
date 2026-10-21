"""Test oracle for src/verbs.cho and the process half `worker.call` (docs/worker-contract.md, 3.6 and 8): one deliberate
break per decision. A `unit` break is built in a copy and run with `cancho test` on the sources of the `verbs` test set;
an `e2e` break is built in a copy together with the mock worker, the stub LLM, the gate runner and the conformance program
`tests/conformance/verbs.cho`, and run the way the gate runs it (a workers directory). A break is KILLED when it builds and
the tests fail (or trap, or hang past the time limit); one that does not build is INVALID (this script's mistake, not a
kill). Python edits copies of the source and runs the compiler; it decides nothing about the product.

Two breaks are left out because they are equivalent: `limits_ok` and `judge_result_not_ready` test `json.is_object` first, but
`json.get` of a node that is not an object is already "missing", so the later checks refuse the same inputs.

Usage: CANCHO=path/to/cancho python3 scripts/mutate_verbs.py [--only NAME,NAME] [--jobs N]"""
import concurrent.futures
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANCHO = os.environ.get("CANCHO", "cancho")

V = "src/verbs.cho"
W = "src/worker.cho"
# (layer, name, file, old, new, what it breaks); `old` must occur exactly once in the file.
M = [
    ("unit", "contract-unchecked", V, 'if !is_text(src, tape, json.get(src, tape, 0, "contract"), "forge-worker/1") {\n        return r_contract();\n    }', "", "a reply of another contract is taken"),
    ("unit", "request-id-unchecked", V, 'if !is_text(src, tape, json.get(src, tape, 0, "request_id"), request_id) {\n        return r_request_id();\n    }', "", "a reply to another request is taken"),
    ("unit", "not-object-unchecked", V, "if !json.is_object(tape, 0) {\n        return r_not_object();\n    }", "", "a reply that is not an object is read as one"),
    ("unit", "worker-version-unchecked", V, 'name_ok(src, tape, json.get(src, tape, worker, "version"), max_name_bytes())', "true", "a worker with no version is taken"),
    ("unit", "worker-name-unchecked", V, '!name_ok(src, tape, json.get(src, tape, worker, "name"), max_name_bytes()) ||', "", "a worker with no name is taken"),
    ("unit", "name-may-be-empty", V, "json.string_length(src, tape, node) >= 1 && json.string_length(src, tape, node) <= most", "json.string_length(src, tape, node) >= 0 && json.string_length(src, tape, node) <= most", "an empty name is taken"),
    ("unit", "name-too-long", V, "pub fn max_name_bytes() -> [] int {\n    return 128;", "pub fn max_name_bytes() -> [] int {\n    return 129;", "a name of 129 bytes is taken"),
    ("unit", "name-may-escape", V, "json.is_string(tape, node) && json.string_plain(tape, node) && json.string_length", "json.is_string(tape, node) && json.string_length", "a name with an escape is taken"),
    ("unit", "supports-may-be-empty", V, "json.count(tape, supports) < 1 ||", "json.count(tape, supports) < 0 ||", "an empty supports list is taken"),
    ("unit", "supports-too-many", V, "pub fn max_supports() -> [] int {\n    return 16;", "pub fn max_supports() -> [] int {\n    return 17;", "17 supported versions are taken"),
    ("unit", "supports-entry-unchecked", V, "if !json.is_string(tape, v) {\n            return protocol(r_supports());\n        }", "", "a supported version that is not text is taken"),
    ("unit", "version-ignored", V, "if !common {\n        return Judged::Refused(Rule::ContractVersion, r_supports());\n    }", "", "no common version is taken"),
    ("unit", "version-substring", V, 'if json.string_equals(src, tape, v, "forge-worker/1") {\n            common = true;', 'if json.string_length(src, tape, v) > 0 {\n            common = true;', "any version is common"),
    ("unit", "version-checked-first", V, "    var common = false;\n    var i = 0;", "    var common = true;\n    var i = 0;", "a version mismatch is never found"),
    ("unit", "level-async-is-sync", V, 'if is_text(src, tape, l, "async") {\n        level = Level::Async;', 'if is_text(src, tape, l, "async") {\n        level = Level::Sync;', "an async worker is read as sync"),
    ("unit", "level-unknown-taken", V, '} else if !is_text(src, tape, l, "sync") {\n        return protocol(r_level());\n    }', "}", "an unknown level is taken as sync"),
    ("unit", "task-types-unchecked", V, "if !json.is_array(tape, types) || json.count(tape, types) > max_task_types() {\n        return protocol(r_task_types());\n    }", "", "task types that are not a list are read"),
    ("unit", "task-types-too-many", V, "pub fn max_task_types() -> [] int {\n    return 64;", "pub fn max_task_types() -> [] int {\n    return 65;", "65 task types are taken"),
    ("unit", "task-type-unchecked", V, '!name_ok(src, tape, json.get(src, tape, entry, "type"), max_name_bytes())', "false", "a task type with no name is taken"),
    ("unit", "limits-unchecked", V, "if !limits_ok(src, tape, json.get(src, tape, entry, \"limits_max\")) {\n            return protocol(r_limits_max());\n        }", "", "a task type with no limits is taken"),
    ("unit", "timeout-may-be-zero", V, "json.to_int(src, tape, timeout) < 1", "json.to_int(src, tape, timeout) < 0", "a timeout limit of zero is taken"),
    ("unit", "output-may-be-zero", V, "json.to_int(src, tape, most) >= 1", "json.to_int(src, tape, most) >= 0", "an output limit of zero is taken"),
    ("unit", "limit-fits-unchecked", V, "!json.is_int(tape, timeout) || !json.fits_int(src, tape, timeout) ||", "!json.is_int(tape, timeout) ||", "a timeout limit past 64 bits is read as an integer"),
    ("unit", "cancel-target-unchecked", V, "    if !target_ok(src, tape, target) {\n        return protocol(r_target());\n    }\n    let s = json.get(src, tape, 0, \"state\");\n    if is_text(src, tape, s, \"cancelled\")", "    let s = json.get(src, tape, 0, \"state\");\n    if is_text(src, tape, s, \"cancelled\")", "a cancel reply about another target is taken"),
    ("unit", "status-target-unchecked", V, "    if !target_ok(src, tape, target) {\n        return protocol(r_target());\n    }\n    let progress", "    let progress", "a status reply about another target is taken"),
    ("unit", "cancel-states-swapped", V, 'if is_text(src, tape, s, "not_running") {\n        return Judged::Cancel(CancelState::NotRunning);', 'if is_text(src, tape, s, "not_running") {\n        return Judged::Cancel(CancelState::TooLate);', "not running is read as too late"),
    ("unit", "cancel-too-late-lost", V, 'if is_text(src, tape, s, "too_late") {\n        return Judged::Cancel(CancelState::TooLate);', 'if is_text(src, tape, s, "too_late") {\n        return Judged::Cancel(CancelState::Cancelled);', "too late is read as cancelled"),
    ("unit", "status-states-swapped", V, 'if is_text(src, tape, s, "queued") {\n        return Judged::Status(StatusState::Queued);', 'if is_text(src, tape, s, "queued") {\n        return Judged::Status(StatusState::Running);', "queued is read as running"),
    ("unit", "status-finished-lost", V, 'if is_text(src, tape, s, "finished") {\n        return Judged::Status(StatusState::Finished);', 'if is_text(src, tape, s, "finished") {\n        return Judged::Status(StatusState::Unknown);', "finished is read as unknown"),
    ("unit", "progress-unchecked", V, "if progress >= 0 && !progress_ok(src, tape, progress) {\n        return protocol(r_progress());\n    }", "", "a progress that is not valid is taken"),
    ("unit", "progress-not-object", V, "fn progress_ok[&s, &t](src: &s [byte], tape: &t [int], node: int) -> [] bool {\n    if !json.is_object(tape, node) {\n        return false;\n    }", "fn progress_ok[&s, &t](src: &s [byte], tape: &t [int], node: int) -> [] bool {", "a progress that is not an object is read"),
    ("unit", "fraction-above-one", V, "f <= 1.0", "f <= 2.0", "a fraction past 1 is taken"),
    ("unit", "fraction-below-zero", V, "f >= 0.0", "f >= -1.0", "a negative fraction is taken"),
    ("unit", "fraction-not-number", V, "if !json.is_number(tape, fraction) {\n            return false;\n        }", "", "a fraction that is not a number is read as one"),
    ("unit", "step-too-long", V, "pub fn max_step_bytes() -> [] int {\n    return 256;", "pub fn max_step_bytes() -> [] int {\n    return 257;", "a step of 257 bytes is taken"),
    ("unit", "step-not-text", V, "json.is_string(tape, step) && json.string_length(src, tape, step) <= max_step_bytes()", "json.string_length(src, tape, step) <= max_step_bytes()", "a step that is not text is taken"),
    ("unit", "updated-unchecked", V, "if updated >= 0 && !name_ok(src, tape, updated, max_name_bytes()) {\n        return protocol(r_updated());\n    }", "", "a time that is not text is taken"),
    ("unit", "not-ready-any-contract", V, 'return is_text(src, tape, json.get(src, tape, 0, "contract"), "forge-worker/1") && is_text(src, tape, json.get(src, tape, 0, "request_id"), request_id);', 'return is_text(src, tape, json.get(src, tape, 0, "request_id"), request_id);', "a not-ready reply of another contract is taken"),
    ("unit", "not-ready-any-request", V, 'return is_text(src, tape, json.get(src, tape, 0, "contract"), "forge-worker/1") && is_text(src, tape, json.get(src, tape, 0, "request_id"), request_id);', 'return is_text(src, tape, json.get(src, tape, 0, "contract"), "forge-worker/1");', "a not-ready reply to another request is taken"),
    ("unit", "result-may-be-accepted", V, "response.validate(heap, body, request_id, task_id, false)", "response.validate(heap, body, request_id, task_id, true)", "accepted is taken as a result"),
    ("unit", "result-evidence-rule-lost", V, "return Judged::Refused(Rule::EvidenceRefInvalid, reason);", "return Judged::Refused(Rule::Protocol, reason);", "an evidence refusal loses its rule"),
    ("unit", "result-task-id", V, "response.validate(heap, body, request_id, task_id, false)", "response.validate(heap, body, request_id, \"\", false)", "a result for another task is taken"),
    ("unit", "sync-has-cancel", V, "            Level::Sync => {\n                return false;\n            }", "            Level::Sync => {\n                return true;\n            }", "a sync worker is sent a cancel"),
    ("unit", "async-lacks-status", V, 'if bytes.equal(verb, "cancel") || bytes.equal(verb, "status") || bytes.equal(verb, "result") {\n        match level {', 'if bytes.equal(verb, "cancel") || bytes.equal(verb, "result") {\n        match level {', "an async worker is not sent a status"),
    ("unit", "execute-not-allowed", V, 'if bytes.equal(verb, "capabilities") || bytes.equal(verb, "execute") {\n        return true;', 'if bytes.equal(verb, "capabilities") {\n        return true;', "execute is not a verb of any level"),
    ("unit", "unknown-verb-allowed", V, "        }\n    }\n    return false;\n}\n\n// The refusal for a verb", "        }\n    }\n    return true;\n}\n\n// The refusal for a verb", "an unknown verb is allowed"),
    ("unit", "unknown-verb-judged", V, 'if !(bytes.equal(verb, "capabilities") || bytes.equal(verb, "cancel") || bytes.equal(verb, "status") || bytes.equal(verb, "result")) {\n        return refuse_verb();\n    }', "", "an unknown verb is judged"),
    ("unit", "targeted-any-verb", V, 'if !(bytes.equal(verb, "cancel") || bytes.equal(verb, "status") || bytes.equal(verb, "result")) {\n        return buffer.empty(heap, 1);\n    }', "", "any verb is built into a targeted request"),
    ("unit", "targeted-no-target", V, '    w = json.put_key(heap, w, "target");\n    w = json.put_string(heap, w, target);\n', "", "a targeted request names no target"),
    ("unit", "capabilities-verb", V, 'w = json.put_string(heap, w, "capabilities");\n    w = json.put_key(heap, w, "request_id");\n    w = json.put_string(heap, w, request_id);\n    w = json.end_object(heap, w);\n    return json.finish(w);\n}\n\n// `cancel`', 'w = json.put_string(heap, w, "status");\n    w = json.put_key(heap, w, "request_id");\n    w = json.put_string(heap, w, request_id);\n    w = json.end_object(heap, w);\n    return json.finish(w);\n}\n\n// `cancel`', "a capabilities request names another verb"),
    ("unit", "reply-level", V, 'w = json.put_key(heap, w, "level");\n    w = json.put_string(heap, w, level);', 'w = json.put_key(heap, w, "level");\n    w = json.put_string(heap, w, "sync");', "a worker always says it is sync"),
    ("unit", "reply-version", V, 'w = json.put_string(heap, w, "forge-worker/1");\n    w = json.end_array(heap, w);', 'w = json.put_string(heap, w, "forge-worker/2");\n    w = json.end_array(heap, w);', "a worker says it speaks another version"),
    ("unit", "reply-limits", V, 'w = json.put_int(heap, w, timeout_max);', 'w = json.put_int(heap, w, 0);', "a worker says its timeout limit is zero"),
    ("unit", "lists-always", V, "if json.is_object(tp, entry) && is_text(body, tp, json.get(body, tp, entry, \"type\"), task_type) {", "if json.is_object(tp, entry) {", "any task type is listed"),
    ("unit", "lists-last-only", V, "                    i = i + 1;\n                }\n            }\n        }\n    }\n    unbox_slice(heap, tape);\n    return found;", "                    i = i + 100;\n                }\n            }\n        }\n    }\n    unbox_slice(heap, tape);\n    return found;", "only the first task type is looked at"),
    ("unit", "settle-nonzero-judged", V, "            if n == 0 {\n                return Settled::Reply(judge(heap, verb, out, request_id, target, task_id));\n            }\n            return Settled::Ended(dispatch.Ending::Error(n));", "            return Settled::Reply(judge(heap, verb, out, request_id, target, task_id));", "a non-zero exit is judged by what was written"),
    ("unit", "settle-timeout-overflow", V, "process.Ran::TimedOut => {\n            return Settled::Ended(dispatch.Ending::Timeout);", "process.Ran::TimedOut => {\n            return Settled::Ended(dispatch.Ending::Overflow);", "a deadline is read as an overflow"),
    ("unit", "settle-crash-error", V, "return Settled::Ended(dispatch.Ending::Crashed(s));", "return Settled::Ended(dispatch.Ending::Error(s));", "a signal is read as an exit status"),
    ("e2e", "call-level-unchecked", W, "if len(request) == 0 || !verbs.verb_allowed(level, verb) {", "if len(request) == 0 {", "a verb the level has not is sent"),
    ("e2e", "call-empty-request", W, "if len(request) == 0 || !verbs.verb_allowed(level, verb) {", "if !verbs.verb_allowed(level, verb) {", "an empty request is sent"),
    ("e2e", "call-wrong-target", W, "settled = verbs.settle(heap, ran, verb, buffer.bytes(ob), request_id, target, task_id);", "settled = verbs.settle(heap, ran, verb, buffer.bytes(ob), request_id, request_id, task_id);", "the target is taken to be the request id"),
    ("e2e", "call-wrong-verb", W, "settled = verbs.settle(heap, ran, verb, buffer.bytes(ob), request_id, target, task_id);", 'settled = verbs.settle(heap, ran, "capabilities", buffer.bytes(ob), request_id, target, task_id);', "every reply is judged as a capabilities reply"),
    ("e2e", "call-bounds", W, "let (out, ran) = run(heap, exec, workers, clock, name, request, most, timeout_ms);\n    var settled", "let (out, ran) = run(heap, exec, workers, clock, name, request, most, timeout_ms * 1000);\n    var settled", "the deadline of a verb is stretched"),
    ("e2e", "call-most", W, "let (out, ran) = run(heap, exec, workers, clock, name, request, most, timeout_ms);\n    var settled", "let (out, ran) = run(heap, exec, workers, clock, name, request, most * 1000, timeout_ms);\n    var settled", "the output cap of a verb is stretched"),
    ("e2e", "runner-capabilities-type", "workers/gate_runner.cho", '"sync", "repo.gate", gate_task.max_timeout_ms(), 1048576)', '"sync", "repo.change", gate_task.max_timeout_ms(), 1048576)', "the gate runner lists another task type"),
    ("e2e", "runner-capabilities-level", "workers/gate_runner.cho", '"gate-runner", "0.1.0", "sync"', '"gate-runner", "0.1.0", "async"', "the gate runner says it is async"),
    ("e2e", "stub-capabilities-type", "workers/stub_llm.cho", '"sync", "repo.change", 600000, 1048576)', '"sync", "repo.gate", 600000, 1048576)', "the stub lists another task type"),
    ("e2e", "stub-capabilities-level", "workers/stub_llm.cho", '"stub-llm", "0.1.0", "sync"', '"stub-llm", "0.1.0", "async"', "the stub says it is async"),
    ("e2e", "mock-caps-async", "tests/contract/mock_worker.cho", 'if bytes.equal(rid, "r-async") {\n        level = "async";', 'if bytes.equal(rid, "r-async") {\n        level = "sync";', "the mock never says it is async"),
]


def libs_of(work):
    return sorted(str(p) for p in (work / "src").glob("*.cho") if p.name != "main.cho")


def one(m):
    layer, name, rel, old, new, what = m
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / "w"
        for d in ("src", "tests", "workers"):
            shutil.copytree(ROOT / d, work / d)
        shutil.copy(ROOT / "cancho.toml", work / "cancho.toml")
        path = work / rel
        text = path.read_text()
        if text.count(old) != 1:
            return name, what, "INVALID (old text occurs %d times)" % text.count(old)
        path.write_text(text.replace(old, new))
        if layer == "unit":
            try:
                run = subprocess.run([CANCHO, "test", "tests/verbs_test.cho", "src/verbs.cho", "src/dispatch.cho", "src/response.cho", "--std"], cwd=work, capture_output=True, text=True, timeout=300)
            except subprocess.TimeoutExpired:
                return name, what, "KILLED"
            out = run.stdout + run.stderr
            if "running" not in out and "test result" not in out:
                return name, what, "INVALID (does not build)"
            return name, what, "KILLED" if run.returncode != 0 else "SURVIVED"
        libs = libs_of(work)
        support = str(work / "tests/conformance/support.cho")
        workers = pathlib.Path(tmp) / "workers"
        workers.mkdir()
        for out_name, src in (("mock_worker", "tests/contract/mock_worker.cho"), ("stub_llm", "workers/stub_llm.cho"), ("gate_runner", "workers/gate_runner.cho")):
            extra = [support] if out_name == "mock_worker" else []
            b = subprocess.run([CANCHO, "build", str(work / src), *extra, *libs, "--std", "-o", str(workers / out_name)], capture_output=True, text=True)
            if b.returncode != 0:
                return name, what, "INVALID (does not build)"
        exe = pathlib.Path(tmp) / "verbs"
        b = subprocess.run([CANCHO, "build", str(work / "tests/conformance/verbs.cho"), support, *libs, "--std", "-o", str(exe)], capture_output=True, text=True)
        if b.returncode != 0:
            return name, what, "INVALID (does not build)"
        try:
            proc = subprocess.Popen([str(exe), str(workers)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
            try:
                stdout, _ = proc.communicate(timeout=180)
            finally:
                # a break that stretches a deadline leaves its workers running: the whole group goes
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        except subprocess.TimeoutExpired:
            return name, what, "KILLED"
        failed = proc.returncode != 0 or "FAIL " in stdout
        return name, what, "KILLED" if failed else "SURVIVED"


def main():
    only = None
    jobs = 4
    if "--only" in sys.argv:
        only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
    if "--jobs" in sys.argv:
        jobs = int(sys.argv[sys.argv.index("--jobs") + 1])
    todo = [m for m in M if only is None or m[1] in only]
    with concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        results = list(pool.map(one, todo))
    bad = [r for r in results if r[2] != "KILLED"]
    for name, what, verdict in results:
        print(f"{verdict:9} {name:28} {what}")
    print(f"{len(results) - len(bad)} of {len(results)} breaks killed")
    sys.exit(1 if bad else 0)


main()
