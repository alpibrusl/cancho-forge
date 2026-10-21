"""Test oracle for src/gate_task.cho (docs/self-hosting.md, 3.1): one deliberate break per decision, built in a copy,
run against `cancho test` (the gate_task set). A break is KILLED when the tests fail. Python edits copies of the source
and runs the compiler; it decides nothing about the product.

Usage: CANCHO=path/to/cancho python3 scripts/mutate_gate_task.py [--only NAME,NAME]"""
import concurrent.futures
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANCHO = os.environ.get("CANCHO", "cancho")

# (name, old, new, what it breaks); `old` must occur exactly once in src/gate_task.cho.
M = [
    ("tag-task-type", 'return "task-type-invalid";', 'return "scope-invalid";', "a wrong task type is tagged as a scope fault"),
    ("tag-scope", 'return "scope-invalid";', 'return "task-type-invalid";', "an unlisted repository is tagged as a task-type fault"),
    ("tag-revision", 'return "revision-invalid";', 'return "scope-invalid";', "a bad revision is tagged as a scope fault"),
    ("tag-path", 'return "path-invalid";', 'return "revision-invalid";', "a bad path is tagged as a revision fault"),
    ("tag-env", 'return "env-invalid";', 'return "limits-invalid";', "a bad environment is tagged as a limits fault"),
    ("env-checked-always-held", "if gate_env.is_held(f) {\n        return Checked::Held;", "if true {\n        return Checked::Held;", "a bad environment is held"),
    ("env-checked-never-held", "if gate_env.is_held(f) {\n        return Checked::Held;", "if false {\n        return Checked::Held;", "a good environment is refused"),
    ("environment-126-only", "exit_status == 126 || exit_status == 127", "exit_status == 126", "a command not found (127) is the project's failure"),
    ("environment-127-only", "exit_status == 126 || exit_status == 127", "exit_status == 127", "a command not executable (126) is the project's failure"),
    ("environment-range", "exit_status == 126 || exit_status == 127", "exit_status >= 126", "every exit from 126 up is the environment's"),
    ("environment-from-125", "exit_status == 126 || exit_status == 127", "exit_status >= 125 && exit_status <= 127", "an exit of 125 is the environment's"),
    ("tools-forge", 'return "cancho git";', 'return "git";', "the gate of this repository is run without checking for cancho"),
    ("tools-forge-git", 'return "cancho git";', 'return "cancho";', "git is not checked for"),
    ("tools-hdl", 'return "git";\n    }\n    if bytes.equal(key, "alpibrusl/cancho") ||', 'return "cargo";\n    }\n    if bytes.equal(key, "alpibrusl/cancho") ||', "the gate of hdl is run needing cargo"),
    ("tools-cargo", 'return "cargo";', 'return "";', "the Rust gates are run without checking for cargo"),
    ("tools-unknown", 'return "";\n}\n\npub fn repo_known', 'return "git";\n}\n\npub fn repo_known', "a key that is not listed needs git"),
    ("preflight-loop", '"for t in "', '"for u in "', "the preflight loops over another variable than it tests"),
    ("preflight-exit", 'exit 127; }; done; ', 'exit 1; }; done; ', "a missing tool ends the gate with 1, a failure"),
    ("preflight-or", '2>&1 || { echo', '2>&1 && { echo', "the preflight fails for a tool that is there"),
    ("preflight-skipped", 'if len(tools) > 0 {\n        b = buffer.append(heap, b, "for t in ");', 'if len(tools) > 1000 {\n        b = buffer.append(heap, b, "for t in ");', "the preflight is never written"),
    ("tag-limits", 'return "limits-invalid";', 'return "path-invalid";', "a bad timeout is tagged as a path fault"),
    ("task-type-name", 'return "repo.gate";', 'return "repo.change";', "the task type is another"),
    ("min-timeout", "return 2000;", "return 1000;", "a timeout of 1999 ms is allowed"),
    ("max-timeout", "return 86400000;", "return 86400001;", "a timeout past a day is allowed"),
    ("timeout-low-edge", "timeout_ms < min_timeout_ms()", "timeout_ms <= min_timeout_ms()", "the shortest timeout is refused"),
    ("timeout-high-edge", "timeout_ms > max_timeout_ms()", "timeout_ms >= max_timeout_ms()", "the longest timeout is refused"),
    ("timeout-one-side", "if timeout_ms < min_timeout_ms() || timeout_ms > max_timeout_ms()", "if timeout_ms < min_timeout_ms()", "a timeout past a day is allowed"),
    ("check-skips-type", "if !bytes.equal(task_type_text, task_type()) {", "if false {", "the task type is not checked"),
    ("check-skips-scope", "if !repo_known(repo) {", "if false {", "the repository is not checked"),
    ("check-skips-revision", "if !revision_ok(revision) {", "if false {", "the revision is not checked"),
    ("check-skips-workspace", "if !path_ok(workspace) || !path_ok(execution_dir) {", "if !path_ok(execution_dir) {", "the workspace path is not checked"),
    ("check-skips-exec-dir", "if !path_ok(workspace) || !path_ok(execution_dir) {", "if !path_ok(workspace) {", "the execution directory path is not checked"),
    ("repo-forge", 'bytes.equal(key, "alpibrusl/cancho-forge") || bytes.equal(key, "alpibrusl/cancho-hdl") || bytes.equal(key, "alpibrusl/cancho") || bytes.equal(key, "alpibrusl/cancho-ui");', 'bytes.equal(key, "alpibrusl/cancho-hdl") || bytes.equal(key, "alpibrusl/cancho") || bytes.equal(key, "alpibrusl/cancho-ui");', "cancho-forge is not on the list"),
    ("repo-hdl", 'bytes.equal(key, "alpibrusl/cancho-hdl") || bytes.equal(key, "alpibrusl/cancho") || bytes.equal(key, "alpibrusl/cancho-ui");', 'bytes.equal(key, "alpibrusl/cancho") || bytes.equal(key, "alpibrusl/cancho-ui");', "cancho-hdl is not on the list"),
    ("repo-ui", ' || bytes.equal(key, "alpibrusl/cancho-ui");', ";", "cancho-ui is not on the list"),
    ("repo-compiler", 'bytes.equal(key, "alpibrusl/cancho") || bytes.equal(key, "alpibrusl/cancho-ui");', 'bytes.equal(key, "alpibrusl/cancho-ui");', "cancho is not on the list"),
    ("repo-anything", "pub fn repo_known[&k](key: &k [byte]) -> [] bool {\n    return", "pub fn repo_known[&k](key: &k [byte]) -> [] bool {\n    return len(key) > 0 ||", "any repository is on the list"),
    ("command-forge", 'return "scripts/gate.sh";', 'return "scripts/gate_cancho.sh";', "forge runs hdl's gate"),
    ("command-hdl", 'return "scripts/gate_cancho.sh";', 'return "scripts/gate.sh";', "hdl runs forge's gate"),
    ("command-cargo", '"cargo fmt --all --check && cargo clippy --all-targets -- -D warnings && cargo test --workspace"', '"cargo test --workspace"', "the compiler's gate is only its tests"),
    ("command-ui-row", '|| bytes.equal(key, "alpibrusl/cancho-ui") {\n        return "cargo', '{\n        return "cargo', "cancho-ui has no gate"),
    ("revision-length", "if len(revision) != 40 {", "if len(revision) != 41 {", "a revision of 41 digits is wanted"),
    ("revision-length-loose", "if len(revision) != 40 {", "if len(revision) < 40 {", "a longer revision is allowed"),
    ("revision-digit-low", "let digit = c >= 48 && c <= 57;\n        let lower", "let digit = c >= 47 && c <= 57;\n        let lower", "a slash is a digit"),
    ("revision-digit-high", "let digit = c >= 48 && c <= 57;\n        let lower", "let digit = c >= 48 && c <= 58;\n        let lower", "a colon is a digit"),
    ("revision-lower-low", "let lower = c >= 97 && c <= 102;", "let lower = c >= 96 && c <= 102;", "a backquote is a hex digit"),
    ("revision-lower-high", "let lower = c >= 97 && c <= 102;", "let lower = c >= 97 && c <= 103;", "g is a hex digit"),
    ("revision-upper", "let lower = c >= 97 && c <= 102;", "let lower = (c >= 97 && c <= 102) || (c >= 65 && c <= 70);", "upper case hex is allowed"),
    ("path-min", "if len(path) < 2 || len(path) > 512 || int_of(path[0]) != 47 {", "if len(path) < 1 || len(path) > 512 || int_of(path[0]) != 47 {", "the root alone is a path"),
    ("path-max", "if len(path) < 2 || len(path) > 512 || int_of(path[0]) != 47 {", "if len(path) < 2 || len(path) > 513 || int_of(path[0]) != 47 {", "a path of 513 bytes is allowed"),
    ("path-rooted", "|| int_of(path[0]) != 47 {", "{", "a relative path is allowed"),
    ("path-dash", "let punct = c == 46 || c == 47 || c == 45 || c == 95;", "let punct = c == 46 || c == 47 || c == 95;", "a dash is not a path character"),
    ("path-underscore", "let punct = c == 46 || c == 47 || c == 45 || c == 95;", "let punct = c == 46 || c == 47 || c == 45;", "an underscore is not a path character"),
    ("path-dot", "let punct = c == 46 || c == 47 || c == 45 || c == 95;", "let punct = c == 47 || c == 45 || c == 95;", "a dot is not a path character"),
    ("path-any", "if !letter && !digit && !punct {\n            return false;\n        }", "", "any byte is a path character"),
    ("path-upper", "let letter = c >= 65 && c <= 90 || c >= 97 && c <= 122;", "let letter = c >= 97 && c <= 122;", "an upper case letter is not a path character"),
    ("path-lower", "let letter = c >= 65 && c <= 90 || c >= 97 && c <= 122;", "let letter = c >= 65 && c <= 90;", "a lower case letter is not a path character"),
    ("path-dotdot", "if c == 46 && i > 0 && int_of(path[i - 1]) == 46 {\n            return false;\n        }", "", "two dots in a row are allowed"),
    ("path-hidden", "if i > 0 && int_of(path[i - 1]) == 47 && (c == 46 || c == 45) {\n            return false;\n        }", "", "a component starting with a dot or a dash is allowed"),
    ("path-hidden-dash", "(c == 46 || c == 45) {\n            return false;", "c == 46 {\n            return false;", "a component starting with a dash is allowed"),
    ("deadline-fraction", "return timeout_ms / 5 * 4;", "return timeout_ms / 4 * 3;", "the runner's deadline is three quarters"),
    ("deadline-equal", "return timeout_ms / 5 * 4;", "return timeout_ms;", "the runner's deadline is Forge's"),
    ("deadline-margin", "return timeout_ms / 5 * 4;", "return timeout_ms / 10 * 9;", "the runner's deadline is nine tenths"),
    ("head-tenth", "let tenth = runner_ms / 10;", "let tenth = runner_ms / 5;", "the revision check gets a fifth"),
    ("head-cap", "if tenth > 10000 {\n        return 10000;", "if tenth > 20000 {\n        return 20000;", "the revision check may take 20 seconds"),
    ("head-script-cd", 'buffer.append(heap, buffer.empty(heap, 64), "cd ")', 'buffer.append(heap, buffer.empty(heap, 64), "pushd ")', "the revision check does not enter the workspace"),
    ("head-script-git", '" && git rev-parse HEAD"', '" && git rev-parse HEAD~1"', "the revision check asks for the parent"),
    ("gate-script-streams", '"exec 2>&1; cd "', '"cd "', "stderr is not joined to the log"),
    ("gate-script-and", '" && "', '"; "', "the gate runs even if the workspace cannot be entered"),
    ("gate-script-exit", '"; exit $?"', '""', "the shell runs the gate in its own place"),
    ("gate-script-cd", '"exec 2>&1; cd "', '"exec 2>&1; pushd "', "the gate does not enter the workspace"),
    ("match-len", "if len(printed) != 41 || int_of(printed[40]) != 10 {", "if len(printed) != 40 || int_of(printed[40]) != 10 {", "git's output without a newline is a match"),
    ("match-newline", "if len(printed) != 41 || int_of(printed[40]) != 10 {", "if len(printed) != 41 {", "any 41st byte is a newline"),
    ("match-loop", "while i < 40 {", "while i < 39 {", "the last digit is not compared"),
    ("match-first", "var i = 0;\n    while i < 40 {", "var i = 1;\n    while i < 40 {", "the first digit is not compared"),
    ("match-loose", "if printed[i] != revision[i] {\n            return false;\n        }", "", "any 41 bytes match"),
]


def one(m):
    name, old, new, what = m
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / "w"
        shutil.copytree(ROOT, work, ignore=shutil.ignore_patterns(".git", "build", "target"))
        path = work / "src" / "gate_task.cho"
        text = path.read_text()
        if text.count(old) != 1:
            return name, what, f"BAD BREAK: the old text occurs {text.count(old)} times"
        path.write_text(text.replace(old, new))
        r = subprocess.run([CANCHO, "test"], capture_output=True, text=True, cwd=work)
        out = r.stdout + r.stderr
        section = out.split("== test gate_task")[-1] if "== test gate_task" in out else out
        # the break must still build: an error that is not a test failure is this script's mistake
        if "test result: ok" in section and "FAILED" not in section:
            return name, what, "SURVIVED"
        if "error:" in section and "test result" not in section:
            return name, what, "INVALID (does not build)"
        return name, what, "KILLED"


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
