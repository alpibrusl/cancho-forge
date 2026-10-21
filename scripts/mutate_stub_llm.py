"""Test oracle for workers/stub_llm.cho (docs/stub-llm.md): one deliberate break per decision, applied to a copy of the
tree, which is then run the way the gate runs it (scripts/check_stub_llm.sh: the stub as a real child process, a journalled
flow per ending, outside oracles on the files, the journal and the process table). A break is KILLED when the build
succeeds and the script fails (an `ok` line missing or a `FAIL`); one that does not build is INVALID (this script's
mistake, not a kill). The runs are serial: the oracles look at the whole process table (`pgrep`). Python edits copies of
the source and runs the compiler; it decides nothing about the product.

Usage: CANCHO=path/to/cancho python3 scripts/mutate_stub_llm.py [--only NAME,NAME]"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANCHO = os.environ.get("CANCHO", "cancho")

W = "workers/stub_llm.cho"
# (name, old, new, what it breaks); `old` must occur exactly once in the worker.
M = [
    ("liar-does-not-lie", "claimed_sha(heap, buffer.bytes(shb), liar_mode == 1)", "claimed_sha(heap, buffer.bytes(shb), liar_mode == 3)", "`liar` claims the file's own hash"),
    ("liar-always-lies", "claimed_sha(heap, buffer.bytes(shb), liar_mode == 1)", "claimed_sha(heap, buffer.bytes(shb), true)", "every reply claims a hash that is not the file's"),
    ("liar-size-does-not-lie", "        if liar_mode == 2 {\n            size = size + 1;\n        }", "", "`liar_size` claims the file's own size"),
    ("liar-size-always", "        if liar_mode == 2 {\n            size = size + 1;\n        }", "        size = size + 1;", "every reply claims a size that is not the file's"),
    ("crash-does-not-crash", "code = int_of(src[len(src)]);", "code = 0;", "`crash_after_progress` ends normally"),
    ("crash-no-progress", 'put(heap, fs, exec_dir, "progress.txt", "step 1 of 3\\n");', "", "`crash_after_progress` leaves no progress"),
    ("crash-wrong-progress", '"step 1 of 3\\n"', '"step 2 of 3\\n"', "the progress it leaves is another text"),
    ("oversize-at-the-cap", "flood(io, n + 1);", "flood(io, n);", "`oversize` writes exactly the cap, which is not too much"),
    ("oversize-ceiling", "if n > 8388608 {", "if n > 4194304 {", "the ceiling of an oversize reply is 4 MiB"),
    ("truncated-whole", "whole[0..len(whole) / 2]", "whole[0..len(whole)]", "`truncated` writes the whole reply, without a newline"),
    ("truncated-by-a-byte", "whole[0..len(whole) / 2]", "whole[0..len(whole) - 1]", "`truncated` loses only the closing brace"),
    ("malformed-is-json", 'io.write_all(io, "Sure! Here is the JSON you asked for: {\\"state\\": \\"succ\\n");', 'io.write_all(io, "{}\\n");', "`malformed` writes JSON that is not a valid reply"),
    ("refuse-default-code", '"model-refused"', '"refused"', "the default refusal has another code"),
    ("slow-does-not-wait", "nap(heap, clock, ms);", "nap(heap, clock, 0);", "`slow` does not wait"),
    ("slow-delay-ignored", "ms = json.to_int(src, tape, node);", "ms = 0;", "the rule's delay is ignored"),
    ("script-missing-is-empty", "            errno = 2;\n        }", "            errno = 0;\n        }", "a script that is not there is read as an empty one"),
    ("script-read-error-ignored", "        if errno == 0 {\n            errno = e;\n        }", "", "a script that cannot be read is read as an empty one"),
    ("bad-request-without-prompt", "prompt_node < 0 || ", "", "a request without a prompt is run"),
    ("bad-request-prompt-kind", "|| !json.is_string(tp, prompt_node)", "", "a prompt that is not a string is run"),
    ("bad-request-exec-dir", "|| !journal_io.path_ok(fs, exec_dir)", "", "an execution directory that is not ok is used"),
    ("verb-not-checked", ' || !is(src, tp, json.get(src, tp, 0, "verb"), "execute")', "", "any verb is served"),
    ("contract-not-checked", '!is(src, tp, json.get(src, tp, 0, "contract"), "forge-worker/1") || ', "", "any contract is served"),
    ("request-id-not-needed", " || len(rid) == 0", "", "a request with no id is answered"),
    ("task-id-not-needed", " || len(tid) == 0", "", "a task with no id is answered"),
    ("propose-patch-name", '"proposal.patch", patch);', '"change.patch", patch);', "the patch is written under another name than the one answered"),
    ("propose-patch-claimed", '"patch", "proposal.patch", buffer.bytes(ps), len(patch)', '"patch", "proposal.patch", buffer.bytes(ps), len(patch) + 1', "the patch's size is not the file's"),
    ("propose-kind", '"patch", "proposal.patch"', '"log", "proposal.patch"', "the patch is described as a log"),
    ("propose-report-text", '"Proposal: "', '"Plan: "', "the report does not start with the proposal's summary"),
    ("propose-default-patch", "--- a/README.md", "--- README.md", "the default patch is not a unified diff of a file"),
    ("ok-text-default", '"stub reply\\n"', '"stub reply"', "the default reply has no newline"),
    ("ok-reply-name", 'put(heap, fs, exec_dir, "reply.md", contents)', 'put(heap, fs, exec_dir, "reply.txt", contents)', "the reply is written under another name than the one answered"),
    ("ok-evidence-kind", '"report", "reply.md"', '"log", "reply.md"', "the reply is described as a log"),
    ("ok-no-evidence", 'evidence_array(heap, "report", "reply.md", buffer.bytes(cb), size, "file", "", "", 0)', 'evidence_array(heap, "report", "", buffer.bytes(cb), size, "file", "", "", 0)', "the reply has no evidence"),
    ("failed-is-retryable", 'w = json.put_bool(heap, w, false);', 'w = json.put_bool(heap, w, true);', "a refusal of the stub says it is worth retrying"),
    ("state-always-succeeded", "if len(code) == 0 {\n        w = json.put_string(heap, w, \"succeeded\");", "if true {\n        w = json.put_string(heap, w, \"succeeded\");", "a refusal is answered as succeeded"),
    ("exit-status-ok", "code = 4;\n                } else if", "code = 0;\n                } else if", "a request it does not serve is answered with exit 0"),
]

# Breaks that cannot change an answer, with the reason; reported EQUIVALENT instead of SURVIVED. A break listed here that is
# KILLED is reported too: the reason no longer holds.
EQUIVALENT = {
    "oversize-ceiling": "the ceiling (8 MiB) is above every cap a case sets (4096), and above the default cap of the contract (1 MiB)",
    "truncated-by-a-byte": "a reply with its last byte missing is not a JSON object either: the observable ending is the same as for half",
    "bad-request-without-prompt": "`json.is_string` of the absent node -1 is false: the next check refuses it",
}


def one(m):
    name, old, new, what = m
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / "w"
        shutil.copytree(ROOT, work, ignore=shutil.ignore_patterns(".git", "build", "target"))
        path = work / W
        text = path.read_text()
        if text.count(old) != 1:
            return name, what, "INVALID (old text occurs %d times)" % text.count(old)
        path.write_text(text.replace(old, new))
        scratch = pathlib.Path(tmp) / "s"
        scratch.mkdir()
        env = dict(os.environ, CANCHO=CANCHO)
        try:
            run = subprocess.run(["sh", str(work / "scripts" / "check_stub_llm.sh"), str(scratch)], capture_output=True, text=True, timeout=300, env=env, cwd=work)
        except subprocess.TimeoutExpired:
            subprocess.run(["pkill", "-x", "stub_llm"])
            return name, what, "KILLED"
        subprocess.run(["pkill", "-x", "stub_llm"])
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
