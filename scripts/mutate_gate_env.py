"""Test oracle for src/gate_env.cho (docs/self-hosting.md, D7): one deliberate break per decision, built in a copy, run
against `cancho test` (the gate_env set). A break is KILLED when the tests fail. Python edits copies of the source and runs
the compiler; it decides nothing about the product.

Usage: CANCHO=path/to/cancho python3 scripts/mutate_gate_env.py [--only NAME,NAME]"""
import concurrent.futures
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANCHO = os.environ.get("CANCHO", "cancho")

# (name, old, new, what it breaks[, why it is equivalent]); `old` must occur exactly once in src/gate_env.cho. A fifth item
# says why no test can tell the break from the original; a break that survives without one is a gap in the tests.
M = [
    ("max-entries", "pub fn max_entries() -> [] int {\n    return 5;", "pub fn max_entries() -> [] int {\n    return 9;", "nine entries are allowed"),
    ("max-entries-low", "pub fn max_entries() -> [] int {\n    return 5;", "pub fn max_entries() -> [] int {\n    return 7;", "eight entries are refused"),
    ("max-value", "pub fn max_value() -> [] int {\n    return 512;", "pub fn max_value() -> [] int {\n    return 513;", "a directory of 513 bytes is allowed"),
    ("max-path-value", "pub fn max_path_value() -> [] int {\n    return 1024;", "pub fn max_path_value() -> [] int {\n    return 1025;", "a PATH of 1025 bytes is allowed"),
    ("fixed-path", 'return "/usr/local/bin:/usr/bin:/bin";', 'return "/usr/bin:/bin";', "the fixed PATH loses a directory"),
    ("name-path", 'bytes.equal(name, "PATH") || bytes.equal(name, "HOME")', 'bytes.equal(name, "HOME")', "PATH is not a name"),
    ("name-home", 'bytes.equal(name, "HOME") || bytes.equal(name, "CANCHO_CACHE")', 'bytes.equal(name, "CANCHO_CACHE")', "HOME is not a name"),
    ("name-cache", 'bytes.equal(name, "CANCHO_CACHE") || bytes.equal(name, "CARGO_HOME")', 'bytes.equal(name, "CARGO_HOME")', "CANCHO_CACHE is not a name"),
    ("name-cargo", 'bytes.equal(name, "CARGO_HOME") || bytes.equal(name, "RUSTUP_HOME")', 'bytes.equal(name, "RUSTUP_HOME")', "CARGO_HOME is not a name"),
    ("name-rustup", '|| bytes.equal(name, "RUSTUP_HOME");', ";", "RUSTUP_HOME is not a name"),
    ("name-any", "pub fn name_ok[&n](name: &n [byte]) -> [] bool {\n    return", "pub fn name_ok[&n](name: &n [byte]) -> [] bool {\n    return len(name) > 0 ||", "any name is allowed"),
    ("dir-min", "if len(path) < 2 || len(path) > max_value()", "if len(path) < 1 || len(path) > max_value()", "the root alone is a directory", "`/` alone is refused by the trailing-slash rule and `x` by the rooted rule, so the length guard is redundant (it keeps the later `path[0]` from reading an empty text)"),
    ("dir-max-edge", "len(path) > max_value() ||", "len(path) >= max_value() ||", "512 bytes is too long"),
    ("dir-rooted", "|| int_of(path[0]) != 47 {\n        return false;\n    }\n    if int_of(path[len(path) - 1]) == 47", "{\n        return false;\n    }\n    if int_of(path[len(path) - 1]) == 47", "a relative path is a directory"),
    ("dir-trailing-slash", "if int_of(path[len(path) - 1]) == 47 {\n        return false;\n    }", "", "a trailing slash is allowed"),
    ("dir-any-char", "if !letter && !digit && !punct {\n            return false;\n        }", "", "any byte is a path character"),
    ("dir-upper", "let letter = c >= 65 && c <= 90 || c >= 97 && c <= 122;", "let letter = c >= 97 && c <= 122;", "an upper case letter is refused"),
    ("dir-lower", "let letter = c >= 65 && c <= 90 || c >= 97 && c <= 122;", "let letter = c >= 65 && c <= 90;", "a lower case letter is refused"),
    ("dir-dash", "let punct = c == 46 || c == 47 || c == 45 || c == 95;", "let punct = c == 46 || c == 47 || c == 95;", "a dash is refused"),
    ("dir-underscore", "let punct = c == 46 || c == 47 || c == 45 || c == 95;", "let punct = c == 46 || c == 47 || c == 45;", "an underscore is refused"),
    ("dir-dot", "let punct = c == 46 || c == 47 || c == 45 || c == 95;", "let punct = c == 47 || c == 45 || c == 95;", "a dot is refused: ~/.cargo cannot be named"),
    ("dir-colon", "let punct = c == 46 || c == 47 || c == 45 || c == 95;", "let punct = c == 46 || c == 47 || c == 45 || c == 95 || c == 58;", "a colon is allowed in a directory"),
    ("dir-empty-component", "if i > 0 && component == 0 {\n                return false;\n            }", "", "// is allowed"),
    ("dir-dots-component", "if component > 0 && dots == component {\n                return false;\n            }\n            component = 0;", "component = 0;", ". and .. components in the middle are allowed"),
    ("dir-dots-last", "    if component > 0 && dots == component {\n        return false;\n    }\n    return true;", "    return true;", "a last component of dots is allowed"),
    ("dir-dot-count", "if c == 46 {\n                dots = dots + 1;", "if c == 46 && false {\n                dots = dots + 1;", "a component of dots is not noticed"),
    ("list-min", "if len(value) < 2 || len(value) > max_path_value()", "if len(value) < 1 || len(value) > max_path_value()", "a one-byte PATH is allowed", "a one-byte PATH is `/` or a letter, and `dir_ok` refuses both"),
    ("list-max-edge", "len(value) > max_path_value() {", "len(value) >= max_path_value() {", "1024 bytes is too long for a PATH"),
    ("list-segment", "if !dir_ok(value[start..i]) {", "if false {", "a PATH segment is not checked"),
    ("list-split", "int_of(value[i]) == 58", "int_of(value[i]) == 59", "a PATH is split at a semicolon"),
    ("list-last", "while i <= len(value) {", "while i < len(value) {", "the last segment of a PATH is not checked"),
    ("equals-at", "if int_of(entry[i]) == 61 {\n            return i;", "if int_of(entry[i]) == 62 {\n            return i;", "the name ends at the wrong byte"),
    ("entry-empty-name", "if at < 1 {\n        return false;\n    }\n    let name", "if at < 0 {\n        return false;\n    }\n    let name", "an entry with no name is allowed", "an entry with no name has an empty name, which `name_ok` refuses"),
    ("entry-name-unchecked", "if !name_ok(name) {\n        return false;\n    }", "", "an entry may name any variable"),
    ("entry-path-as-dir", "if bytes.equal(name, \"PATH\") {\n        return path_list_ok(value);\n    }", "", "a PATH is one directory: a list is refused"),
    ("entry-dir-as-list", "    return dir_ok(value);\n}", "    return path_list_ok(value);\n}", "HOME may be a list of directories"),
    ("entry-value-unchecked", "    return dir_ok(value);\n}", "    return true;\n}", "a value of HOME is not checked"),
    ("same-name-length", "x < 1 || y < 1 || x != y", "x < 1 || y < 1", "HOME and HOMES are the same variable", "`bytes.equal` of two names of different lengths is false, and only names of the list get this far"),
    ("same-name-compare", "bytes.equal(a[0..x], b[0..y])", "true", "every name is the same as every other"),
    ("check-not-array", "if !json.is_array(tape, node) {\n        return Fault::NotAnArray;", "if false {\n        return Fault::NotAnArray;", "a string is an environment"),
    ("check-count", "if n > max_entries() {\n        return Fault::TooMany;", "if n > 100 {\n        return Fault::TooMany;", "any number of entries is allowed"),
    ("check-string", "if item < 0 || !json.is_string(tape, item) || !json.string_plain(tape, item) {", "if item < 0 {", "an entry may be a number or escaped", "a number's text is not `NAME=value`: `entry_ok` refuses it, so the guard is redundant"),
    ("check-plain", "|| !json.string_plain(tape, item) {", "{", "an entry with an escape is allowed", "an escape leaves a backslash in the raw text, which no name or directory allows: `entry_ok` refuses it"),
    ("check-entry", "if !entry_ok(json.string_view(src, tape, item)) {\n            return Fault::BadEntry;", "if false {\n            return Fault::BadEntry;", "an entry is not checked"),
    ("check-twice", "return Fault::Twice;", "return Fault::BadEntry;", "a name twice is a bad entry"),
    ("check-twice-off", "if same_name(json.string_view(src, tape, item), json.string_view(src, tape, json.at(tape, node, k))) {", "if false {", "a name twice is allowed"),
    ("check-twice-range", "while k < i {", "while k < i - 1 {", "a name twice at the last position is allowed"),
    ("check-absent", "if node < 0 {\n        return Fault::Held;\n    }\n    if !json.is_array", "if node < 0 {\n        return Fault::NotAnArray;\n    }\n    if !json.is_array", "no environment at all is refused"),
    ("held-too-many", "Fault::TooMany => {\n            return false;", "Fault::TooMany => {\n            return true;", "too many entries are held"),
    ("held-twice", "Fault::Twice => {\n            return false;", "Fault::Twice => {\n            return true;", "a name twice is held"),
    ("held-bad", "Fault::BadEntry => {\n            return false;", "Fault::BadEntry => {\n            return true;", "a bad entry is held"),
    ("held-not-array", "Fault::NotAnArray => {\n            return false;", "Fault::NotAnArray => {\n            return true;", "a non-array is held"),
    ("text-parse", "if json.parse(text, tp) > 0 {\n            fault = check_node(text, tp, 0);", "if true {\n            fault = check_node(text, tp, 0);", "text that does not parse is checked as if it did"),
    ("text-default", "var fault = Fault::NotAnArray;", "var fault = Fault::Held;", "text that does not parse is held"),
    ("block-order", "    let operator = value_of(src, tape, node, \"PATH\");\n    if len(operator) > 0 {\n        b = buffer.append(heap, b, operator);\n        b = buffer.push(heap, b, byte_of(58));\n    }\n    b = buffer.append(heap, b, fixed_path());", "    let operator = value_of(src, tape, node, \"PATH\");\n    b = buffer.append(heap, b, fixed_path());\n    if len(operator) > 0 {\n        b = buffer.push(heap, b, byte_of(58));\n        b = buffer.append(heap, b, operator);\n    }", "the operator's PATH is behind the fixed one"),
    ("block-no-colon", "b = buffer.append(heap, b, operator);\n        b = buffer.push(heap, b, byte_of(58));", "b = buffer.append(heap, b, operator);", "the operator's PATH runs into the fixed one"),
    ("block-no-fixed", "    b = buffer.append(heap, b, fixed_path());\n    b = buffer.push(heap, b, byte_of(0));", "    b = buffer.push(heap, b, byte_of(0));", "the fixed PATH is removed when there is an operator one"),
    ("block-path-dup", "if at > 0 && !bytes.equal(entry[0..at], \"PATH\") {", "if at > 0 {", "PATH is put in twice"),
    ("block-others-dropped", "if at > 0 && !bytes.equal(entry[0..at], \"PATH\") {", "if false {", "the other variables are dropped"),
    ("block-nul", "b = buffer.append(heap, b, entry);\n            b = buffer.push(heap, b, byte_of(0));", "b = buffer.append(heap, b, entry);\n            b = buffer.push(heap, b, byte_of(10));", "the entries end in a newline"),
    ("block-absent", "    if node < 0 {\n        return b;\n    }\n    let count", "    let count", "no environment at all reads a node that is not there", "`json.count` of node -1 is 0, so the loop does not run"),
    ("value-of-first", "if at > 0 && bytes.equal(entry[0..at], name) {\n            return entry[at + 1..len(entry)];", "if at > 0 {\n            return entry[at + 1..len(entry)];", "the first entry is taken for any name"),
]


def one(m):
    name, old, new, what, *rest = m
    equivalent = rest[0] if rest else None
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / "w"
        shutil.copytree(ROOT, work, ignore=shutil.ignore_patterns(".git", "build", "target"))
        path = work / "src" / "gate_env.cho"
        text = path.read_text()
        if text.count(old) != 1:
            return name, what, f"BAD BREAK: the old text occurs {text.count(old)} times", equivalent
        path.write_text(text.replace(old, new))
        r = subprocess.run([CANCHO, "test"], capture_output=True, text=True, cwd=work)
        out = r.stdout + r.stderr
        section = out.split("== test gate_env")[-1].split("== test ")[0] if "== test gate_env" in out else out
        if "test result: ok" in section and "FAILED" not in section:
            return name, what, "SURVIVED", equivalent
        if "error:" in section and "test result" not in section:
            return name, what, "INVALID (does not build)", equivalent
        return name, what, "KILLED", equivalent


def main():
    only = None
    if "--only" in sys.argv:
        only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
    todo = [m for m in M if only is None or m[0] in only]
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        results = list(pool.map(one, todo))
    bad = 0
    for name, what, verdict, equivalent in results:
        note = ""
        if verdict == "SURVIVED" and equivalent:
            verdict = "EQUIVALENT"
            note = f"  ({equivalent})"
        elif verdict != "KILLED":
            bad += 1
        print(f"{verdict:10} {name:24} {what}{note}")
    killed = sum(1 for r in results if r[2] == "KILLED")
    print(f"{killed} of {len(results)} breaks killed")
    sys.exit(1 if bad else 0)


main()
