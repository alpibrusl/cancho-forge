"""Test oracle for src/worker.cho (docs/worker-contract.md, 8): one deliberate break per decision, built in a copy
together with the mock worker and the contract-test program, run the way the gate runs it (a workers directory holding
the mock, an execution directory holding a symlink). A break is KILLED when the build succeeds and the program fails (or
traps, or hangs past the time limit); one that does not build is INVALID (this script's mistake, not a kill). Python edits
copies of the source and runs the compiler; it decides nothing about the product.

Usage: CANCHO=path/to/cancho python3 scripts/mutate_contract.py [--only NAME,NAME]"""
import concurrent.futures
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANCHO = os.environ.get("CANCHO", "cancho")

# (name, file, old, new, what it breaks); `old` must occur exactly once in the file.
M = [
    ("name-rooted", "src/worker.cho", "len(name) > 0 && int_of(name[0]) != 47 && exec_covers(exec, name)", "len(name) > 0 && exec_covers(exec, name)", "a rooted worker name reaches the capability (which traps)"),
    ("name-empty", "src/worker.cho", "len(name) > 0 && int_of(name[0]) != 47 && exec_covers(exec, name)", "int_of(name[0]) != 47 && exec_covers(exec, name)", "an empty worker name reaches the capability"),
    ("name-covers", "src/worker.cho", "len(name) > 0 && int_of(name[0]) != 47 && exec_covers(exec, name)", "len(name) > 0 && int_of(name[0]) != 47", "a name with two dots reaches the capability (which traps)"),
    ("name-refusal-errno", "src/worker.cho", "process.Ran::Failed(0 - 2));\n    }\n    match process.channels()", "process.Ran::Failed(2));\n    }\n    match process.channels()", "a refused name looks like a missing file"),
    ("spawn-errno-lost", "src/worker.cho", "                    process.close(to_child, from_child);\n                    return (buffer.empty(heap, 1), process.Ran::Failed(e));", "                    process.close(to_child, from_child);\n                    return (buffer.empty(heap, 1), process.Ran::Failed(1));", "the errno of a failed spawn is lost"),
    ("timeout-ignored", "src/worker.cho", "request, most, timeout_ms);\n                }", "request, most, timeout_ms * 100);\n                }", "the deadline is stretched"),
    ("cap-ignored", "src/worker.cho", "request, most, timeout_ms);\n                }", "request, most * 1000, timeout_ms);\n                }", "the output cap is stretched"),
    ("evidence-unchecked", "src/worker.cho", "evidence_io.Checked::Refused(rule, reason) => {\n                                ending = dispatch.Ending::Reply(response.Verdict::Refused(rule, reason));", "evidence_io.Checked::Refused(rule, reason) => {\n                                ending = ending;", "a hash that does not match is accepted"),
    ("setup-ignored", "src/worker.cho", "ending = dispatch.Ending::Setup(errno);", "ending = ending;", "an execution directory that is not there is accepted"),
    ("evidence-wrong-dir", "src/worker.cho", "evidence_io.verify(heap, fs, buffer.bytes(ob), execution_dir)", "evidence_io.verify(heap, fs, buffer.bytes(ob), \"/tmp\")", "the evidence is looked for in another directory"),
    ("grants-dir", "src/worker.cho", "w2 = json.put_string(heap, w2, execution_dir);", "w2 = json.put_string(heap, w2, workspace);", "the worker is told the workspace as its execution directory"),
    ("request-id", "src/worker.cho", "w2 = json.put_string(heap, w2, request_id);", "w2 = json.put_string(heap, w2, task_id);", "the request id sent is the task id"),
    ("task-id", "src/worker.cho", "w2 = json.put_key(heap, w2, \"id\");\n    w2 = json.put_string(heap, w2, task_id);", "w2 = json.put_key(heap, w2, \"id\");\n    w2 = json.put_string(heap, w2, request_id);", "the task id sent is the request id"),
    ("input-dropped", "src/worker.cho", "w2 = json.put_fragment(heap, w2, input);", "w2 = json.put_null(heap, w2);", "the task input is not sent"),
    ("verb", "src/worker.cho", "w2 = json.put_string(heap, w2, \"execute\");", "w2 = json.put_string(heap, w2, \"status\");", "another verb is sent"),
]


def one(m):
    name, rel, old, new, what = m
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / "w"
        shutil.copytree(ROOT / "src", work / "src")
        shutil.copytree(ROOT / "tests" / "conformance", work / "tests" / "conformance")
        shutil.copytree(ROOT / "tests" / "contract", work / "tests" / "contract")
        path = work / rel
        text = path.read_text()
        if text.count(old) != 1:
            return name, what, "INVALID (old text occurs %d times)" % text.count(old)
        path.write_text(text.replace(old, new))
        libs = sorted(str(p) for p in (work / "src").glob("*.cho") if p.name != "main.cho")
        support = str(work / "tests/conformance/support.cho")
        workers = pathlib.Path(tmp) / "workers"
        workers.mkdir()
        mock = subprocess.run([CANCHO, "build", str(work / "tests/contract/mock_worker.cho"), support, *libs, "--std", "-o", str(workers / "mock_worker")], capture_output=True, text=True)
        exe = pathlib.Path(tmp) / "wc"
        build = subprocess.run([CANCHO, "build", str(work / "tests/conformance/worker_contract.cho"), support, *libs, "--std", "-o", str(exe)], capture_output=True, text=True)
        if mock.returncode != 0 or build.returncode != 0:
            return name, what, "INVALID (does not build)"
        ev = pathlib.Path(tmp) / "ev"
        outside = pathlib.Path(tmp) / "outside"
        ev.mkdir()
        outside.mkdir()
        (outside / "s.txt").write_text("secret\n")
        (ev / "link").symlink_to(outside / "s.txt")
        try:
            run = subprocess.run([str(exe), str(workers), str(ev)], capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            return name, what, "KILLED"
        failed = run.returncode != 0 or "FAIL " in run.stdout
        return name, what, "KILLED" if failed else "SURVIVED"


def main():
    only = None
    if "--only" in sys.argv:
        only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
    todo = [m for m in M if only is None or m[0] in only]
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        results = list(pool.map(one, todo))
    bad = [r for r in results if r[2] != "KILLED"]
    for name, what, verdict in results:
        print(f"{verdict:9} {name:22} {what}")
    print(f"{len(results) - len(bad)} of {len(results)} breaks killed")
    sys.exit(1 if bad else 0)


main()
