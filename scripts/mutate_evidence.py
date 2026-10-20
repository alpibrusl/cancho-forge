"""Test oracle for src/evidence_io.cho and journal_io.drain (docs/worker-contract.md, 4.1): one deliberate break per
decision, built in a copy together with the conformance program, run against a scratch directory made the way the gate
makes it. A break is KILLED when the build succeeds and the program fails; one that does not build is INVALID (the
script's mistake, not a kill). Python edits copies of the source and runs the compiler; it decides nothing about
the product.

Usage: CANCHO=path/to/cancho python3 scripts/mutate_evidence.py [--only NAME,NAME]"""
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
    ("missing-is-unreadable", "src/evidence_io.cho", "if e == 2 {\n                verdict = refused(response.r_evidence_missing());", "if e == 99 {\n                verdict = refused(response.r_evidence_missing());", "a file that is not there is reported as unreadable"),
    ("open-failure-held", "src/evidence_io.cho", "                verdict = refused(response.r_evidence_unreadable());\n            }\n        }\n        Opened::Ok", "            }\n        }\n        Opened::Ok", "a link or a directory that fails to open is accepted"),
    ("read-error-held", "src/evidence_io.cho", "} else if errno != 0 {", "} else if errno == 12345 {", "a read that fails is accepted"),
    ("too-large-code", "src/evidence_io.cho", "if errno == 0 - 3 {", "if errno == 0 - 4 {", "a file past the cap is not told apart"),
    ("cap-bigger", "src/evidence_io.cho", "return 67108864;", "return 67108866;", "the cap admits a file one byte past it"),
    ("cap-smaller", "src/evidence_io.cho", "return 67108864;", "return 67108863;", "a file of exactly the cap is refused"),
    ("drain-room", "src/journal_io.cho", "if n > room {", "if n >= room {", "a read that ends exactly at the limit is called too big"),
    ("size-skip", "src/evidence_io.cho", "if buffer.size(db) != json.to_int(src, tape, size) {", "if false {", "a size that is not the claimed one is accepted"),
    ("sha-skip", "src/evidence_io.cho", "if !json.string_equals(src, tape, sha, buffer.bytes(gb)) {", "if false {", "a hash that is not the claimed one is accepted"),
    ("dir-guard", "src/evidence_io.cho", "if !journal_io.path_ok(fs, execution_dir) {", "if false {", "an execution directory with .. in it is opened"),
    ("only-first", "src/evidence_io.cho", "    var i = 0;\n    while i < n {\n        let entry = json.at(tape, evidence, i);", "    var i = 0;\n    while i < 1 && i < n {\n        let entry = json.at(tape, evidence, i);", "only the first entry is checked"),
    ("count-limit", "src/evidence_io.cho", "if n > response.max_evidence() {", "if n > response.max_evidence() + 1000 {", "a response with too much evidence is read through"),
    ("ref-recheck", "src/evidence_io.cho", "|| !response.ref_ok(json.string_view(src, tape, path))", "", "a .. in a ref reaches the directory walk"),
    ("sha-recheck", "src/evidence_io.cho", "if !json.is_string(tape, sha) || !response.sha256_ok(json.string_view(src, tape, sha)) {", "if !json.is_string(tape, sha) {", "a hash of the wrong shape is compared instead of refused"),
    ("bytes-recheck", "src/evidence_io.cho", " || json.to_int(src, tape, size) < 0 {", " {", "a negative size is compared instead of refused"),
    ("held-on-no-json", "src/evidence_io.cho", "var verdict = Checked::Refused(response.Rule::WorkerProtocol, response.r_not_json());", "var verdict = Checked::Held;", "a body that does not parse is accepted"),
]


def one(m):
    name, rel, old, new, what = m
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / "w"
        shutil.copytree(ROOT / "src", work / "src")
        shutil.copytree(ROOT / "tests" / "conformance", work / "tests" / "conformance")
        path = work / rel
        text = path.read_text()
        if text.count(old) != 1:
            return name, what, "INVALID (old text occurs %d times)" % text.count(old)
        path.write_text(text.replace(old, new))
        libs = sorted(str(p) for p in (work / "src").glob("*.cho") if p.name != "main.cho")
        exe = pathlib.Path(tmp) / "ef"
        build = subprocess.run([CANCHO, "build", str(work / "tests/conformance/evidence_files.cho"), str(work / "tests/conformance/support.cho"), *libs, "--std", "-o", str(exe)], capture_output=True, text=True)
        if build.returncode != 0:
            return name, what, "INVALID (does not build)"
        scratch = pathlib.Path(tmp) / "ev"
        outside = pathlib.Path(tmp) / "outside"
        (scratch / "sub").mkdir(parents=True)
        outside.mkdir()
        (outside / "s.txt").write_text("secret\n")
        (scratch / "link").symlink_to(outside / "s.txt")
        (scratch / "dirlink").symlink_to(outside)
        for f, n in (("big.bin", 67108865), ("cap.bin", 67108864)):
            with open(scratch / f, "wb") as fh:
                fh.truncate(n)
        run = subprocess.run([str(exe), str(scratch)], capture_output=True, text=True)
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
