"""Test oracle for src/response.cho (docs/worker-contract.md, 8): one deliberate break per decision, built in a
copy, run against `cancho test response`. A break is KILLED when the tests fail. Python edits copies of the source
and runs the compiler; it decides nothing about the product.

Usage: CANCHO=path/to/cancho python3 scripts/mutate_response.py [--only NAME,NAME]"""
import concurrent.futures
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANCHO = os.environ.get("CANCHO", "cancho")

# (name, old, new, what it breaks); `old` must occur exactly once in src/response.cho.
# Two decisions have no break because none can be observed: the `string_plain` test of the hash (a raw view of an
# escaped string has a backslash, which is not a hex digit, so `sha256_ok` refuses it first, and the guard was
# removed for that reason) and `parse(...) > 0` against `>= 0` (a document that parses has at least one node).
M = [
    ("contract-name", "\"forge-worker/1\"", "\"forge-worker/2\"", "another contract is the one spoken"),
    ("request-id-skip", "        return protocol(r_request_id());\n", "        return Verdict::Valid(State::Succeeded);\n", "a request id mismatch is accepted"),
    ("task-id-skip", "        return protocol(r_task_id());\n", "        return Verdict::Valid(State::Succeeded);\n", "a task id mismatch is accepted"),
    ("async-accepted", "if is_async && is_text(src, tape, node, \"accepted\")", "if is_text(src, tape, node, \"accepted\")", "a sync worker may answer accepted"),
    ("state-partial", "if is_text(src, tape, node, \"partial\") {", "if false {", "partial is not a state"),
    ("state-cancelled", "if is_text(src, tape, node, \"cancelled\") {", "if false {", "cancelled is not a state"),
    ("summary", "if summary >= 0 && !json.is_string(tape, summary) {", "if false {", "a summary may be anything"),
    ("evidence-count", "if n > max_evidence() {", "if n > max_evidence() + 1 {", "257 entries are accepted"),
    ("evidence-limit", "return 256;", "return 255;", "255 is the most"),
    ("id-length", "json.string_length(src, tape, id) > max_id_bytes()", "json.string_length(src, tape, id) > max_id_bytes() + 1", "an id of 129 bytes is accepted"),
    ("id-empty", "json.string_length(src, tape, id) < 1 ||", "false ||", "an empty id is accepted"),
    ("id-plain", "if !json.string_plain(tape, id) ||", "if false ||", "an id with an escape is accepted"),
    ("id-duplicate", "if json.string_equals(src, tape, id, json.string_view(src, tape, other)) {", "if false {", "a duplicate id is accepted"),
    ("kind-closed", "|| is_text(src, tape, node, \"other\")", "|| true", "any kind is accepted"),
    ("kind-patch", "is_text(src, tape, node, \"patch\") ||", "false ||", "patch is not a kind"),
    ("ref-absolute", "|| int_of(path[0]) == '/'", "", "an absolute path is accepted"),
    ("ref-nul", "        if c == 0 {\n            return false;\n        }\n", "", "a NUL is accepted"),
    ("ref-dots", "if c == '.' && i + 1 < n && int_of(path[i + 1]) == '.' {", "if false {", "two dots are accepted"),
    ("ref-length", "n > max_ref_bytes()", "n > max_ref_bytes() + 1", "513 bytes are accepted"),
    ("ref-empty", "if n == 0 ||", "if false ||", "an empty path is accepted"),
    ("ref-plain", "if !json.string_plain(tape, path) ||", "if false ||", "an escaped path is accepted"),
    ("sha-length", "if len(text) != 64 {", "if len(text) < 64 {", "a longer hash is accepted"),
    ("sha-upper", "c >= 'a' && c <= 'f'", "c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'", "upper-case hex is accepted"),
    ("bytes-negative", "if json.to_int(src, tape, size) < 0 {\n        return refuse", "if false {\n        return refuse", "a negative size is accepted"),
    ("bytes-fits", "if !json.is_int(tape, size) || !json.fits_int(src, tape, size) {", "if !json.is_int(tape, size) {", "a size past 64 bits is not noticed"),
    ("cost-negative", "|| json.to_int(src, tape, amount) < 0 {", "{", "a negative cost is accepted"),
    ("cost-source", "|| is_text(src, tape, source, \"forge-measured\")", "|| true", "any cost source is accepted"),
    ("error-shape", "return json.is_string(tape, code) && json.is_string(tape, message) && json.is_bool(tape, retry);", "return true;", "any error object is accepted"),
    ("failed-needs-error", "        State::Failed => {\n            if !has_error {", "        State::Failed => {\n            if false {", "a failure without a reason is accepted"),
    ("success-no-error", "        State::Succeeded => {\n            if has_error {", "        State::Succeeded => {\n            if false {", "a success with an error is accepted"),
    ("partial-needs-error", "        State::Partial => {\n            if !has_error {", "        State::Partial => {\n            if false {", "a partial without a reason is accepted"),
    ("object-root", "if !json.is_object(tape, 0) {", "if false {", "a non-object root is not noticed"),
]


def sh(cmd, cwd):
    return subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)


def one(m):
    name, old, new, what = m
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / "w"
        shutil.copytree(ROOT, work, ignore=shutil.ignore_patterns(".git", "build", "target"))
        path = work / "src" / "response.cho"
        text = path.read_text()
        if text.count(old) != 1:
            return name, what, f"BAD BREAK: the old text occurs {text.count(old)} times"
        path.write_text(text.replace(old, new))
        # run only the response set
        manifest = work / "cancho.toml"
        r = sh([CANCHO, "test"], work)
        out = r.stdout + r.stderr
        section = out.split("== test response")[-1] if "== test response" in out else out
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
