"""Test oracle for workers/cancho_code.cho and src/build_task.cho (docs/cancho-code-adapter.md): one deliberate break per
decision, applied to a copy of the tree, which is then run the way the gate runs it (scripts/check_cancho_code.sh: the
adapter as a real child process, a stand-in build tool, outside oracles on the files and the process table). A break is
KILLED when the build succeeds and the script fails (an `ok` line missing, a `FAIL`, a trap, or a hang past the time
limit); one that does not build is INVALID (this script's mistake, not a kill). After a clean run the unit tests of the pure half (`cancho test tests/build_task_test.cho ...`) are the second oracle: a break they fail is KILLED too. The runs are serial: the oracles look at
the whole process table (`pgrep`), so two at a time would see each other's children. Python edits copies of the source
and runs the compiler; it decides nothing about the product.

An EQUIVALENT break is one that no observable behaviour can tell from the original; each is listed in EQUIVALENT with the
reason, and is expected to survive. Anything else that survives is a missing test.

Usage: CANCHO=path/to/cancho python3 scripts/mutate_cancho_code.py [--only NAME,NAME] [--dry]
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

W = "workers/cancho_code.cho"
T = "src/build_task.cho"
S = "src/supervise.cho"
R = "src/run_files.cho"
V = "src/verbs.cho"
# (name, file, old, new, what it breaks); `old` must occur exactly once in the file.
M = [
    # ---- the process half: how the build is started, bounded and read
    ("tool-name", T, 'return "cancho-build";', 'return "cancho-buil";', "the tool is looked up under another name"),
    ("env-not-empty", W, 'exec_spawn_detached_under(exec, tools, build_task.tool_name(), args, "",', 'exec_spawn_detached_under(exec, tools, build_task.tool_name(), args, "PATH=/x\\0",', "the build is given an environment"),
    ("deadline-is-forges", W, 'supervise.wait(heap, clock, fs, child, to_child, from_child, build_task.out_cap(), deadline, cancel_path, request_id)', 'supervise.wait(heap, clock, fs, child, to_child, from_child, build_task.out_cap(), timeout_ms, cancel_path, request_id)', "the build may use all of Forge's time: Forge's kill fires first and leaks"),
    ("deadline-total", T, "return timeout_ms / 5 * 4;", "return timeout_ms;", "the adapter uses all of Forge's time"),
    ("out-cap", T, "return 1048576;\n}\n\n// The most of a file", "return 2097152;\n}\n\n// The most of a file", "the build's standard output may be twice the cap"),
    ("brief-not-written", W, "rc = write_file(fs, buffer.bytes(bp), brief);", 'rc = write_file(fs, buffer.bytes(bp), "");', "the brief file is empty"),
    ("workdir-failure-ignored", W, '    if rc != 0 {\n        return refuse(heap, request_id, task_id, build_task.rule_name(build_task.Refusal::WorkdirUnwritable), "the brief could not be written', '    if false {\n        return refuse(heap, request_id, task_id, build_task.rule_name(build_task.Refusal::WorkdirUnwritable), "the brief could not be written', "a brief that could not be written is run anyway"),
    ("unavailable-ignored", W, "    if spawned == false {", "    if false {", "a build that could not be started is reported as an ending"),
    ("out-empty", W, "rc = write_file(fs, buffer.bytes(op), buffer.bytes(ob));", 'rc = write_file(fs, buffer.bytes(op), "");', "the tool's standard output is written empty"),
    ("verified-lost", W, "                            verified = n;", "                            verified = 0;", "the number of verified units is never read"),
    ("verdict-forced", W, "verdict = build_task.verdict_id(json.string_view(src, tp, v));", "verdict = 1;", "every build.json says done"),
    # ---- the evidence
    ("evidence-sha", W, "let sha = snapshot.hex_digest(heap, buffer.bytes(db));", 'let sha = snapshot.hex_digest(heap, "x");', "an evidence file's hash is not the file's"),
    ("evidence-size", W, "buffer.bytes(sb), buffer.size(db));", "buffer.bytes(sb), buffer.size(db) + 1);", "an evidence file's size is not the file's"),
    ("evidence-count", T, "pub fn evidence_count() -> [] int {\n    return 4;", "pub fn evidence_count() -> [] int {\n    return 3;", "the last evidence file is never offered"),
    ("evidence-name", T, 'return "build.json";', 'return "build.jsn";', "the report is offered under a name that is not its file"),
    # ---- the answer
    ("answer-partial-as-succeeded", W, '    } else if state == 1 {\n        w = json.put_string(heap, w, "partial");', '    } else if state == 1 {\n        w = json.put_string(heap, w, "succeeded");', "a partial build answers succeeded"),
    ("retryable-dropped", W, "w = json.put_bool(heap, w, retryable);", "w = json.put_bool(heap, w, false);", "a provider error is never retryable"),
    ("timeout-code", W, 'code = "build-timeout";', 'code = "build-crashed";', "a deadline is reported as a crash"),
    ("crash-code", W, 'code = "build-crashed";', 'code = "build-timeout";', "a signal is reported as a deadline"),
    ("overflow-code", W, 'code = "build-output-overflow";', 'code = "build-timeout";', "an overflow is reported as a deadline"),
    ("capabilities-level", W, '"cancho-code-adapter", "0.2.0", "async"', '"cancho-code-adapter", "0.2.0", "sync"', "the adapter declares a level it does not have"),
    ("capabilities-type", W, '"async", "project.build"', '"async", "repo.gate"', "the adapter declares another task type"),
    # ---- what is refused
    ("check-skipped", W, 'var refusal = build_task.check(kind, buffer.bytes(bb), exec_dir, tools_dir, timeout_ms);', 'var refusal = build_task.Checked::Held;', "the task is not checked"),
    ("operator-skipped", W, 'refusal = build_task.operator_checked(checker, guide, provider, model, agent, attempts, agent_seconds, rounds, plan_seconds, jobs);', 'refusal = build_task.Checked::Held;', "the operator's configuration is not checked"),
    ("type-unchecked", T, "if !bytes.equal(task_type_text, task_type()) {", "if false {", "another task type is run"),
    ("brief-size-unchecked", T, "if len(brief) < 1 || len(brief) > max_brief_bytes() {", "if len(brief) < 1 {", "a brief of any size is taken"),
    ("brief-nul-unchecked", T, "if int_of(brief[i]) == 0 {", "if false {", "a brief with a NUL is taken"),
    ("min-timeout", T, "return 10000;\n}\n\npub fn max_timeout_ms", "return 9000;\n}\n\npub fn max_timeout_ms", "a build may be given under ten seconds"),
    ("word-semicolon", T, "|| c == 44 || c == 45;", "|| c == 44 || c == 45 || c == 59;", "a provider may hold a semicolon, which the tool splices into a shell line"),
    ("jobs-range", T, "return n >= 1 && n <= 64;", "return n >= 1 && n <= 65;", "jobs may be one over the tool's range"),
    ("ceiling-not-integer", W, "    return 0 - 1;\n}\n\n// Is the build tool", "    return fallback;\n}\n\n// Is the build tool", "a ceiling that is not an integer falls back to the default"),
    ("path-unchecked", T, "if !gate_task.path_ok(execution_dir) || !gate_task.path_ok(tools_dir) {", "if false {", "a path with a shell metacharacter is taken"),
    # ---- how the tool's ending is read (worker-contract 9.4)
    ("exit-ignored", T, "if exit_code == 0 && verdict == 1 {", "if verdict == 1 {", "a failing exit code with the verdict done is a success"),
    ("verdict-ignored", T, "if exit_code == 0 && verdict == 1 {", "if exit_code == 0 {", "an exit 0 with any verdict (or none) is a success"),
    ("stuck-partial-always", T, "if units_verified > 0 {", "if units_verified >= 0 {", "a stuck build with nothing verified is partial"),
    ("gate-failed-failed", T, "        Ended::StuckPartial => {\n            return 1;\n        }\n        Ended::GateFailed => {\n            return 1;", "        Ended::StuckPartial => {\n            return 1;\n        }\n        Ended::GateFailed => {\n            return 2;", "a failed final gate is failed, not partial"),
    ("provider-not-retryable", T, "        Ended::ProviderError => {\n            return true;", "        Ended::ProviderError => {\n            return false;", "a provider error is not retryable"),
    ("stuck-retryable", T, "        Ended::Stuck => {\n            return false;\n        }\n        Ended::StuckPartial => {\n            return false;", "        Ended::Stuck => {\n            return true;\n        }\n        Ended::StuckPartial => {\n            return false;", "a stuck build is retried blindly"),
    ("plan-code", T, 'return "plan-failed";', 'return "plan_failed";', "an ending's code is the tool's word, not kebab-case"),
    ("usage-as-protocol", T, "    if exit_code == 2 {\n        return Ended::Usage;", "    if exit_code == 2 {\n        return Ended::Disagree;", "a refused argument vector is reported as a protocol error"),
    # ---- the argument vector
    ("arg-provider", T, 'put_option(heap, b2, "--provider", provider)', 'put_option(heap, b2, "--provide", provider)', "the provider option is misspelt"),
    ("arg-guide-dropped", T, "    if len(guide) > 0 {\n        b2 = put_option", "    if false {\n        b2 = put_option", "the operator's guide never reaches the tool"),
    ("default-attempts", W, "fn default_attempts() -> [] int {\n    return 4;", "fn default_attempts() -> [] int {\n    return 5;", "the default is not the tool's"),
    ("arg-agent-split", T, "b2 = put_arg(heap, b2, agent);", "b2 = put_arg(heap, put_arg(heap, b2, agent), agent);", "the agent command is given twice"),
    # ---- the lock of the execution directory (issue #35; docs/cancho-code-adapter.md section 11)
    ("lock-let-go-early", W, '                    code = work_locked(heap, fs, clock, exec, tools, request_id, task_id, brief, exec_dir, args, timeout_ms, token);\n                    lock.let_go(file);', '                    lock.let_go(file);\n                    code = work_locked(heap, fs, clock, exec, tools, request_id, task_id, brief, exec_dir, args, timeout_ms, token);', "the lock is let go before the build runs, so a second adapter is not refused"),
    ("lock-refusal-unrecognised", W, 'if rule == task.rule_code(task.Rule::WorkspaceLocked) {\n                        tries = tries + 1;', 'if false {\n                        tries = tries + 1;', "a held lock is reported as a path that is not lockable"),
    ("lock-refusal-tag", W, "build_task.rule_name(build_task.Refusal::ExecutionLocked), \"another build", "build_task.rule_name(build_task.Refusal::WorkdirUnwritable), \"another build", "a held lock is reported as an unwritable directory"),
    ("lock-tag-name", T, 'return "execution-locked";', 'return "execution-lock";', "the refusal's tag is not the documented one"),
    ("lock-refusal-retryable", W, 'reply = refuse(heap, request_id, task_id, build_task.rule_name(build_task.Refusal::ExecutionLocked), "another build holds this execution directory; nothing was written");', 'reply = answer(heap, request_id, task_id, 2, build_task.rule_name(build_task.Refusal::ExecutionLocked), "another build holds this execution directory; nothing was written", true, "[]");', "a held lock is retryable"),
    ("lock-failure-runs", W, '                lock.Lock::Failed(e2) => {\n                    code = 5;\n                    finished = true;', '                lock.Lock::Failed(e2) => {\n                    code = work_locked(heap, fs, clock, exec, tools, request_id, task_id, brief, exec_dir, args, timeout_ms, token);\n                    finished = true;', "a lock file that cannot be opened is run without a lock"),
    ("lock-name", T, 'return "forge-build.lock";', 'return "build.out";', "the lock is the build's output file, which the build and the adapter write"),
    # ---- the async level (issue #33; docs/async-level.md)
    ("accepted-named-succeeded", W, 'w = json.put_string(heap, w, "accepted");', 'w = json.put_string(heap, w, "succeeded");', "execute answers succeeded for a build that has only begun"),
    ("cancelled-named-failed", W, 'w = json.put_string(heap, w, "cancelled");', 'w = json.put_string(heap, w, "failed");', "a cancelled run is reported failed"),
    ("accepted-before-the-lock", W, "how = await_start(heap, fs, cw, buffer.bytes(rp), request_id, token, 10000);", "how = 1;", "execute answers accepted without waiting to know the supervisor holds the directory"),
    ("start-token-ignored", W, "if errno == 0 && run_files.run_is(heap, buffer.bytes(db), request_id, token) {", "if errno == 0 && run_files.run_is(heap, buffer.bytes(db), request_id, 0 - 1) {", "a run.json left by an earlier run of the same request is taken for this start"),
    ("locked-exit-misread", W, "} else if code == 3 {", "} else if code == 33 {", "the supervisor's refusal (exit 3) is reported as an unavailable supervisor"),
    ("unwritable-exit-misread", W, "} else if code == 5 {", "} else if code == 55 {", "the supervisor's unwritable directory (exit 5) is reported as an unavailable supervisor"),
    ("workers-dir-unchecked", W, "if !build_task.workers_dir_ok(workers_dir) {", "if false {", "execute starts a supervisor beneath a directory it did not check"),
    ("stale-cancel-kept", W, "    remove_in(heap, fs, exec_dir, run_files.cancel_name());\n", "", "a cancel request of an earlier run stops the run that resumes it"),
    ("stale-result-kept", W, "    remove_in(heap, fs, exec_dir, run_files.result_name());\n", "", "the result of an earlier run is taken for the result of the new one"),
    ("stale-run-kept", W, "    remove_in(heap, fs, exec_dir, run_files.run_name());\n", "", "a run.json of an earlier run stays beside a failed write of the new one"),
    ("status-unknown-as-finished", W, '        return verbs.status_reply(heap, request_id, target, "unknown", "");\n    }\n    let (stored, state) = result_of(heap, fs, exec_dir, target);\n    buffer.drop(heap, stored);', '        return verbs.status_reply(heap, request_id, target, "finished", "");\n    }\n    let (stored, state) = result_of(heap, fs, exec_dir, target);\n    buffer.drop(heap, stored);', "a run that is not there is reported finished"),
    ("status-lost-as-running", W, '            lock.Lock::Held(file) => {\n                lock.let_go(file);\n                buffer.drop(heap, reply);\n                reply = verbs.status_reply(heap, request_id, target, "finished", "");', '            lock.Lock::Held(file) => {\n                lock.let_go(file);\n                buffer.drop(heap, reply);\n                reply = verbs.status_reply(heap, request_id, target, "running", "");', "a run whose supervisor is gone is reported running for ever"),
    ("status-running-as-finished", W, '                    borrow stage as &sb in {\n                        reply = verbs.status_reply(heap, request_id, target, "running", buffer.bytes(sb));', '                    borrow stage as &sb in {\n                        reply = verbs.status_reply(heap, request_id, target, "finished", buffer.bytes(sb));', "a live run is reported finished"),
    ("result-not-rebound", W, "reply = run_files.rebind(heap, buffer.bytes(sb), request_id);", "reply = buffer.append(heap, buffer.empty(heap, 64), buffer.bytes(sb));", "a result answers with the request id of the execute, not of the call"),
    ("result-lost-not-kept", W, "                            store_result(heap, fs, exec_dir, buffer.bytes(lb));\n", "", "a lost run's result is made again at every call instead of being kept"),
    ("result-when-live", W, "                reply = verbs.not_ready_reply(heap, request_id);\n            }\n            lock.Lock::Failed(e2) => {\n                buffer.drop(heap, reply);\n                reply = verbs.not_ready_reply(heap, request_id);", "                reply = verbs.status_reply(heap, request_id, target, \"running\", \"\");\n            }\n            lock.Lock::Failed(e2) => {\n                buffer.drop(heap, reply);\n                reply = verbs.not_ready_reply(heap, request_id);", "a live run's result is a status instead of not_ready"),
    ("lost-code", W, 'build-supervisor-lost', 'build-crashed', "a lost supervisor is reported as a crash of the build"),
    ("cancel-not-written", W, "rc = write_file(fs, buffer.bytes(cp), target);", "rc = 0;", "a cancel is answered without being asked of the supervisor"),
    ("cancel-lost-is-alive", W, "            lock.Lock::Held(file) => {\n                lock.let_go(file);\n            }\n            lock.Lock::Refused(rule) => {\n                alive = rule", "            lock.Lock::Held(file) => {\n                alive = true;\n                lock.let_go(file);\n            }\n            lock.Lock::Refused(rule) => {\n                alive = rule", "a cancel of a run whose supervisor is gone waits for a supervisor that is not there"),
    ("cancel-after-end", W, '    if state == 4 {\n        return option.Option::Some(verbs.cancel_reply(heap, request_id, target, "cancelled"));\n    }\n    if state > 0 {', '    if state == 4 {\n        return option.Option::Some(verbs.cancel_reply(heap, request_id, target, "too_late"));\n    }\n    if state > 0 {', "a cancelled run is too late to cancel again"),
    ("control-path-unchecked", W, "|| !gate_task.path_ok(exec_dir) {\n                        code = 4;", "{\n                        code = 4;", "a relative directory is looked in"),
    ("control-target-needed", W, "len(text_of(src, tp, rid)) == 0 || len(target) == 0 ||", "len(text_of(src, tp, rid)) == 0 ||", "a call about no run is answered"),
    ("cancel-any-text", S, "asked = bytes.equal(buffer.bytes(db), request_id);", "asked = len(buffer.bytes(db)) > 0;", "a cancel request for another run stops this one"),
    ("cancel-check-removed", S, "if state == running() && asks_for_cancel(heap, fs, cancel_path, request_id) {", "if state == running() && asks_for_cancel(heap, fs, cancel_path, request_id) && false {", "the supervisor never looks for a cancel request"),
    ("cancel-slice-long", S, "pub fn slice_ms() -> [] int {\n    return 100;", "pub fn slice_ms() -> [] int {\n    return 100000;", "a cancel request is looked for only every hundred seconds"),
    ("cancel-leaves-group", S, "            child_kill_group(ch, 256);\n", "", "a cancel kills the build's pid and not its group"),
    ("cancel-not-reported", S, "return (out, ran, state == cancelled());", "return (out, ran, false);", "a cancelled build is reported as a signal"),
    ("token-ignored-by-run-is", R, "held = json.to_int(data, tp, tk) == token;", "held = true;", "the start token is not compared"),
    ("rebind-cuts-the-tail", R, "stored[len(prefix()) + len(id)..len(stored)]", "stored[len(prefix()) + len(id)..len(stored) - 1]", "a rebound result loses its last byte"),
    ("result-state-cancelled-lost", R, 'json.string_equals(data, tp, s, "cancelled")', 'json.string_equals(data, tp, s, "canceled")', "a cancelled result is not known as one"),
    ("status-step-unbounded", V, "if len(step) > 0 {\n        w = json.put_key(heap, w, \"progress\");", "if len(step) > 99 {\n        w = json.put_key(heap, w, \"progress\");", "a status never carries its step"),
    # ---- what is not a task
    ("unknown-verb-served", W, '|| !is(src, tp, verb, "execute") ||', '|| false ||', "a verb that is not execute is served"),
    ("request-id-not-needed", W, "|| len(text_of(src, tp, rid)) == 0 ||", "||", "a request with no id is answered"),
    ("task-id-not-needed", W, "|| len(text_of(src, tp, tid)) == 0 {", "{", "a request with no task id is answered"),
    ("contract-not-checked", W, 'let contract_ok = is(src, tp, json.get(src, tp, 0, "contract"), "forge-worker/1");', 'let contract_ok = true;', "another contract version is served"),
]

# Breaks that no behaviour can tell from the original, and why. They are expected to SURVIVE.
EQUIVALENT = {
    "tool-unusable-never": "(not in M)",
    "stale-run-kept": "the supervisor writes run.json with open_write, which truncates and replaces whatever is there, right after removing it; the removal can be told from its absence only by a write that fails after it, and a write that fails ends the supervisor with exit 5 whatever the file held (run as root, a permission cannot be made to refuse it)",
}


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
            run = subprocess.run(["sh", str(work / "scripts" / "check_cancho_code.sh"), str(scratch)], capture_output=True, text=True, timeout=400, env=env, cwd=work)
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
