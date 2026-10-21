"""Test oracle for src/stub_script.cho (docs/stub-llm.md, sections 3 and 4): one deliberate break per decision, built in
a copy, run against `cancho test` (the stub_script set). A break is KILLED when the tests fail. Python edits copies of the
source and runs the compiler; it decides nothing about the product.

Usage: CANCHO=path/to/cancho python3 scripts/mutate_stub_script.py [--only NAME,NAME]"""
import concurrent.futures
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANCHO = os.environ.get("CANCHO", "cancho")

# (name, old, new, what it breaks); `old` must occur exactly once in src/stub_script.cho.
M = [
    ("name-ok", 'if bytes.equal(name, "ok") {', 'if bytes.equal(name, "okay") {', "`ok` is not a behaviour"),
    ("name-refuse", 'if bytes.equal(name, "refuse") {', 'if bytes.equal(name, "refuse ") {', "`refuse` is not a behaviour"),
    ("name-malformed", 'if bytes.equal(name, "malformed") {', 'if bytes.equal(name, "garbled") {', "`malformed` is not a behaviour"),
    ("name-liar", 'if bytes.equal(name, "liar") {', 'if bytes.equal(name, "lie") {', "`liar` is not a behaviour"),
    ("name-liar-size", 'if bytes.equal(name, "liar_size") {', 'if bytes.equal(name, "liar-size") {', "`liar_size` is not a behaviour"),
    ("name-truncated", 'if bytes.equal(name, "truncated") {', 'if bytes.equal(name, "cut") {', "`truncated` is not a behaviour"),
    ("name-slow", 'if bytes.equal(name, "slow") {', 'if bytes.equal(name, "sleep") {', "`slow` is not a behaviour"),
    ("name-crash", 'if bytes.equal(name, "crash_after_progress") {', 'if bytes.equal(name, "crash") {', "`crash_after_progress` is not a behaviour"),
    ("name-oversize", 'if bytes.equal(name, "oversize") {', 'if bytes.equal(name, "big") {', "`oversize` is not a behaviour"),
    ("name-propose", 'if bytes.equal(name, "propose") {', 'if bytes.equal(name, "proposal") {', "`propose` is not a behaviour"),
    ("do-name-ok", 'Do::Ok => {\n            return "ok";', 'Do::Ok => {\n            return "okay";', "a behaviour's name does not find it again"),
    ("do-name-propose", 'Do::Propose => {\n            return "propose";', 'Do::Propose => {\n            return "proposal";', "propose's name does not find it again"),
    ("do-maps-wrong", 'return option.Option::Some(Do::Refuse);', 'return option.Option::Some(Do::Ok);', "refuse is read as ok"),
    ("max-rules", "pub fn max_rules() -> [] int {\n    return 64;", "pub fn max_rules() -> [] int {\n    return 65;", "65 rules are allowed"),
    ("max-match", "pub fn max_match_bytes() -> [] int {\n    return 256;", "pub fn max_match_bytes() -> [] int {\n    return 257;", "a match of 257 bytes is allowed"),
    ("max-delay", "return 600000;", "return 600001;", "a delay of 600001 ms is allowed"),
    ("rules-empty", "if n < 1 || n > max_rules() {", "if n > max_rules() {", "a script with no rules is valid"),
    ("rules-count-edge", "if n < 1 || n > max_rules() {", "if n < 1 || n >= max_rules() {", "64 rules are refused"),
    ("rules-not-array", "if rules < 0 || !json.is_array(tape, rules) {", "if rules < 0 {", "rules need not be an array"),
    ("script-not-object", "pub fn valid[&s, &t](src: &s [byte], tape: &t [int]) -> [] bool {\n    if !json.is_object(tape, 0) {\n        return false;\n    }", "pub fn valid[&s, &t](src: &s [byte], tape: &t [int]) -> [] bool {", "a script need not be an object"),
    ("rule-not-object", "    if !json.is_object(tape, rule) {\n        return false;\n    }", "", "a rule need not be an object"),
    ("do-not-string", "if action < 0 || !json.is_string(tape, action) {", "if action < 0 {", "`do` need not be a string"),
    ("do-missing", "if action < 0 || !json.is_string(tape, action) {", "if !json.is_string(tape, action) {", "a rule may lack `do` (-1 is read as a node)"),
    ("do-unknown", "option.Option::None => {\n            return false;\n        }\n        option.Option::Some(d) => {\n        }", "option.Option::None => {\n        }\n        option.Option::Some(d) => {\n        }", "an unknown behaviour is valid"),
    ("match-empty", 'json.get(src, tape, rule, "match"), max_match_bytes(), true)', 'json.get(src, tape, rule, "match"), max_match_bytes(), false)', "an empty match is valid"),
    ("type-empty", 'json.get(src, tape, rule, "type"), max_match_bytes(), true)', 'json.get(src, tape, rule, "type"), max_match_bytes(), false)', "an empty type is valid"),
    ("text-length", 'json.get(src, tape, rule, "text"), max_text_bytes(), false)', 'json.get(src, tape, rule, "text"), max_text_bytes() * 2, false)', "a text over the limit is valid"),
    ("patch-length", 'json.get(src, tape, rule, "patch"), max_text_bytes(), false)', 'json.get(src, tape, rule, "patch"), max_text_bytes() * 2, false)', "a patch over the limit is valid"),
    ("summary-length", 'json.get(src, tape, rule, "summary"), max_match_bytes(), false)', 'json.get(src, tape, rule, "summary"), max_match_bytes() * 2, false)', "a summary over the limit is valid"),
    ("string-not-checked", "    if !json.is_string(tape, node) {\n        return false;\n    }\n    let n = json.string_length", "    let n = json.string_length", "an optional field may be any kind"),
    ("string-length-edge", "if n < 0 || n > most {", "if n < 0 || n > most + 1 {", "a string one byte too long is valid"),
    ("string-length-low", "if n < 0 || n > most {", "if n > most {", "(unreachable: a string has a length)"),
    ("code-escape", "!json.string_plain(tape, code) || ", "", "an error code may hold escapes"),
    ("code-not-string", "if !json.is_string(tape, code) || ", "if ", "an error code may be any kind"),
    ("code-kebab", "|| !code_ok(json.string_view(src, tape, code))", "", "any error code is valid"),
    ("delay-not-int", "if !json.is_int(tape, delay) || !json.fits_int(src, tape, delay) {", "if !json.fits_int(src, tape, delay) {", "a delay need not be an integer"),
    ("delay-fits", "if !json.is_int(tape, delay) || !json.fits_int(src, tape, delay) {", "if !json.is_int(tape, delay) {", "a delay beyond 64 bits is valid"),
    ("delay-negative", "if ms < 0 || ms > max_delay_ms() {", "if ms > max_delay_ms() {", "a negative delay is valid"),
    ("delay-edge", "if ms < 0 || ms > max_delay_ms() {", "if ms < 0 || ms >= max_delay_ms() {", "the longest delay is refused"),
    ("code-length-low", "if len(code) < 1 || len(code) > 64 {", "if len(code) > 64 {", "an empty error code is valid"),
    ("code-length-high", "if len(code) < 1 || len(code) > 64 {", "if len(code) < 1 || len(code) > 65 {", "an error code of 65 bytes is valid"),
    ("code-hyphen-first", "if int_of(code[0]) == 45 || int_of(code[len(code) - 1]) == 45 {", "if int_of(code[len(code) - 1]) == 45 {", "a code may start with a hyphen"),
    ("code-hyphen-last", "if int_of(code[0]) == 45 || int_of(code[len(code) - 1]) == 45 {", "if int_of(code[0]) == 45 {", "a code may end with a hyphen"),
    ("code-upper", "let lower = c >= 97 && c <= 122;", "let lower = c >= 65 && c <= 122;", "upper case and punctuation are allowed in a code"),
    ("code-digit", "let digit = c >= 48 && c <= 57;\n        if !lower", "let digit = c >= 48 && c <= 56;\n        if !lower", "9 is not a code character"),
    ("code-hyphen", "if !lower && !digit && c != 45 {", "if !lower && !digit {", "a hyphen is not a code character"),
    ("code-underscore", "if !lower && !digit && c != 45 {", "if !lower && !digit && c != 45 && c != 95 {", "an underscore is a code character"),
    ("pick-index-zero", "let m = json.get(src, tape, rule, \"match\");\n        if m >= 0 && bytes.find(prompt, json.string_view(src, tape, m)) < 0 {", "let m = json.get(src, tape, rule, \"match\");\n        if m >= 0 && bytes.find(prompt, json.string_view(src, tape, m)) <= 0 {", "a match at the start of the prompt is no match"),
    ("pick-match-ignored", "if m >= 0 && bytes.find(prompt, json.string_view(src, tape, m)) < 0 {\n            takes = false;\n        }", "", "a match is not looked at"),
    ("pick-type-inverted", "if ty >= 0 && !bytes.equal(task_type, json.string_view(src, tape, ty)) {", "if ty >= 0 && bytes.equal(task_type, json.string_view(src, tape, ty)) {", "a rule takes every type but its own"),
    ("pick-type-ignored", "if ty >= 0 && !bytes.equal(task_type, json.string_view(src, tape, ty)) {\n            takes = false;\n        }", "", "a type is not looked at"),
    ("pick-last-skipped", "    var i = 0;\n    while i < n {\n        let rule = json.at(tape, rules, i);\n        var takes = true;", "    var i = 0;\n    while i < n - 1 {\n        let rule = json.at(tape, rules, i);\n        var takes = true;", "the last rule is never tried"),
    ("pick-first-skipped", "    var i = 0;\n    while i < n {\n        let rule = json.at(tape, rules, i);\n        var takes = true;", "    var i = 1;\n    while i < n {\n        let rule = json.at(tape, rules, i);\n        var takes = true;", "the first rule is never tried"),
    ("pick-none", "    return 0 - 1;\n}\n", "    return 0;\n}\n", "no rule taking the prompt picks the root"),
    ("code-no-rule", 'return "stub-no-rule";', 'return "no-rule";', "the stub's own code has another name"),
    ("code-script-missing", 'return "stub-script-missing";', 'return "stub-script-invalid";', "two of the stub's codes are the same"),
    ("code-bad-request", 'return "stub-bad-request";', 'return "bad-request-";', "the stub's own code is not kebab case"),
]

# Breaks that cannot change an answer, with the reason. Each is a check that another check already makes redundant: the
# code stays (it says what is meant, and the other check is an accident of how `json` answers), and the break is
# reported EQUIVALENT instead of KILLED. A break listed here that is KILLED is reported too: the reason no longer holds.
EQUIVALENT = {
    "script-not-object": "`json.get` of a node that is not an object is -1, so `rules < 0` already refuses it",
    "rule-not-object": "`json.get` of a rule that is not an object is -1, so the `do` check already refuses it",
    "do-not-string": "`string_view` of a node that is not a string is empty, which is no behaviour",
    "do-missing": "`json.is_string` of the absent node -1 is false",
    "rules-not-array": "`json.at` of a node that is not an array is -1, which `rule_ok` refuses",
    "string-not-checked": "`json.string_length` of a node that is not a string is -1, which is refused",
    "string-length-low": "a string always has a length of 0 or more",
    "code-escape": "an escape in a code is a backslash in its raw bytes, which `code_ok` refuses",
    "code-not-string": "`json.string_plain` of a node that is not a string is false",
    "delay-not-int": "`json.fits_int` of a node that is not an integer is false",
    "delay-fits": "`json.to_int` of an integer past 64 bits saturates, which is past the longest delay",
}


def one(m):
    name, old, new, what = m
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / "w"
        shutil.copytree(ROOT, work, ignore=shutil.ignore_patterns(".git", "build", "target"))
        path = work / "src" / "stub_script.cho"
        text = path.read_text()
        if text.count(old) != 1:
            return name, what, f"BAD BREAK: the old text occurs {text.count(old)} times"
        path.write_text(text.replace(old, new))
        r = subprocess.run([CANCHO, "test"], capture_output=True, text=True, cwd=work)
        out = r.stdout + r.stderr
        section = out.split("== test stub_script")[-1] if "== test stub_script" in out else out
        if "test result: ok" in section and "FAILED" not in section:
            return name, what, "EQUIVALENT" if name in EQUIVALENT else "SURVIVED"
        if "error:" in section and "test result" not in section:
            return name, what, "INVALID (does not build)"
        return name, what, "KILLED" if name not in EQUIVALENT else "KILLED (listed as equivalent: the reason no longer holds)"


def main():
    only = None
    if "--only" in sys.argv:
        only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
    todo = [m for m in M if only is None or m[0] in only]
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        results = list(pool.map(one, todo))
    bad = [r for r in results if r[2] not in ("KILLED", "EQUIVALENT")]
    for name, what, verdict in results:
        print(f"{verdict:9} {name:22} {what}")
    equivalent = [r for r in results if r[2] == "EQUIVALENT"]
    print(f"{len(results) - len(bad) - len(equivalent)} of {len(results)} breaks killed, {len(equivalent)} equivalent (cannot change an answer)")
    sys.exit(1 if bad else 0)


main()
