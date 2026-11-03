#!/usr/bin/env python3
"""R-1 seeds (docs/reviewer.md section 9): 20 changes of known fate against one pinned commit of this repository.

A seed is (id, file, old text, new text, brief, fate). `correct` seeds must leave `cancho check` and the repository's own unit tests passing and do what the
brief says; `faulty` seeds must be caught by the repository's own tests (that is what "a planted fault the audit catches" means here). This script builds
each patch with git, then APPLIES it to a copy of the pinned tree and runs the audit; a seed whose measured fate is not its declared fate is reported and the
run fails: the ground truth of R-1 is measured, not declared. Test ORACLE and a data file, not product logic.

Usage: seeds.py <out dir, empty> <path to cancho> [--no-audit]
"""
import os, subprocess, sys, shutil, tempfile

BASE = "04edac8"
FORGE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RR, CG = "src/repo_row.cho", "src/company_graph.cho"

SEEDS = [
 # ---- correct
 ("c01", RR, "    return letter || digit || c == 45 || c == 95 || c == 46;", "    return c == 45 || c == 95 || c == 46 || letter || digit;",
  "In `name_char`, test the three punctuation bytes before the letters and digits. The set of accepted bytes must not change.", "correct"),
 ("c02", RR, "        if !name_char(c) && c != 47 {\n            return false;\n        }\n        if i == 0 && (c == 45 || c == 46) {",
  "        if name_char(c) == false && c != 47 {\n            return false;\n        }\n        if i == 0 && (c == 45 || c == 46) {",
  "In `branch_ok`, spell the first test as `name_char(c) == false`, as the rest of this file does. No behaviour change.", "correct"),
 ("c03", RR, "    if len(slug) < 3 || len(slug) > 128 {\n        return false;\n    }\n    var slashes = 0;",
  "    let size = len(slug);\n    if size < 3 || size > 128 {\n        return false;\n    }\n    var slashes = 0;",
  "In `slug_ok`, read the length of the slug once into a local. No behaviour change.", "correct"),
 ("c04", CG, "        if bytes.equal(company_manifest.step_id(m, company_manifest.step_at(m, i)), id) {\n            return i;",
  "        let s = company_manifest.step_at(m, i);\n        if bytes.equal(company_manifest.step_id(m, s), id) {\n            return i;",
  "In `index_of`, bind the step to a local before comparing its id. No behaviour change.", "correct"),
 ("c05", CG, "        if is_accepted(accepted, i) == false && needs_met(m, accepted, i) {\n            return option.Option::Some(i);",
  "        if needs_met(m, accepted, i) && is_accepted(accepted, i) == false {\n            return option.Option::Some(i);",
  "In `ready`, test the needs before the step's own acceptance. Both are pure; the answer must not change.", "correct"),
 ("c06", CG, "    var met = true;\n    var j = 0;\n    while j < k {\n        let at = index_of(m, company_manifest.step_need(m, s, j));\n        if at < 0 || is_accepted(accepted, at) == false {\n            met = false;\n        }\n        j = j + 1;\n    }\n    return met;",
  "    var j = 0;\n    while j < k {\n        let at = index_of(m, company_manifest.step_need(m, s, j));\n        if at < 0 || is_accepted(accepted, at) == false {\n            return false;\n        }\n        j = j + 1;\n    }\n    return true;",
  "In `needs_met`, return false at the first need that is not met instead of remembering it and finishing the loop. Same answers.", "correct"),
 ("c07", RR, "// A branch name of the row: 1 to 64 bytes", "// A branch name of a registry row: 1 to 64 bytes",
  "Fix the comment of `branch_ok`: it names a row of the registry, not of a company. Comment only.", "correct"),
 ("c08", CG, "    if i < 0 || i >= len(accepted) {\n        return false;\n    }\n    return accepted[i];",
  "    return i >= 0 && i < len(accepted) && accepted[i];",
  "Write `is_accepted` as one boolean expression. Same answers for every `i`, including out of range.", "correct"),
 ("c09", RR, "// The slug of the row (`owner/name`)", "// How many components a branch name has: the slashes in it, plus one. A helper for a later check; nothing calls it yet.\npub fn branch_depth[&b](name: &b [byte]) -> [] int {\n    var depth = 1;\n    var i = 0;\n    while i < len(name) {\n        if int_of(name[i]) == 47 {\n            depth = depth + 1;\n        }\n        i = i + 1;\n    }\n    return depth;\n}\n\n// The slug of the row (`owner/name`)",
  "Add `branch_depth`, a public helper that returns the number of `/`-separated components of a branch name (`a/b/c` is 3, `a` is 1). Nothing else changes.", "correct"),
 ("c10", CG, "// The number of the first step that is not accepted", "// How many steps are not accepted yet. A step past the end of `accepted` counts as not accepted.\npub fn waiting_count[&a, &m](m: &m company_manifest.Manifest, accepted: &a [bool]) -> [] int {\n    let n = company_manifest.step_count(m);\n    var waiting = 0;\n    var i = 0;\n    while i < n {\n        if is_accepted(accepted, i) == false {\n            waiting = waiting + 1;\n        }\n        i = i + 1;\n    }\n    return waiting;\n}\n\n// The number of the first step that is not accepted",
  "Add `waiting_count`, a public function that returns how many steps of the manifest are not accepted. Nothing else changes.", "correct"),
 # ---- faulty
 ("f01", RR, "            if stars > 1 && !bytes.equal(comp, \"**\") {", "            if stars > 2 && !bytes.equal(comp, \"**\") {",
  "In `pattern_ok`, a component may carry two stars (`*.*` matches a name with an extension); three or more are still refused.", "faulty"),
 ("f02", RR, "    var i = 0;\n    while i < len(path) {\n        if int_of(path[i]) == 42 {\n            return false;\n        }\n        i = i + 1;\n    }\n    if any_match(src, tp, deny, path) {", "    if any_match(src, tp, deny, path) {",
  "In `path_allowed`, remove the loop that refuses a path with a star: `pattern_ok` already checks the shape of the path.", "faulty"),
 ("f03", RR, "    return letter || digit || c == 45 || c == 95 || c == 46;", "    return letter || digit || c == 45 || c == 95;",
  "Tidy `name_char`: the name characters are letters, digits, `-` and `_`.", "faulty"),
 ("f04", RR, "    return v >= 1 && v <= hi;", "    return v >= 0 && v <= hi;",
  "In `count_ok`, a count of zero is a valid bound; accept it.", "faulty"),
 ("f05", CG, "        if at < 0 || is_accepted(accepted, at) == false {\n            met = false;", "        if at < 0 || is_accepted(accepted, at) {\n            met = false;",
  "In `needs_met`, drop the comparison with false and use the value directly.", "faulty"),
 ("f06", CG, "        if is_accepted(accepted, i) == false && needs_met(m, accepted, i) {\n            return option.Option::Some(i);",
  "        if is_accepted(accepted, i) == false || needs_met(m, accepted, i) {\n            return option.Option::Some(i);",
  "In `ready`, a step is ready when it is not accepted or its needs are met; say so in the condition.", "faulty"),
 ("f07", CG, "    return 0 - 1;\n}\n\n// Is step `i` accepted?", "    return 0;\n}\n\n// Is step `i` accepted?",
  "`index_of` returns 0 for an id it does not find, so that callers never have to test for a negative.", "faulty"),
 ("f08", CG, "    if i < 0 || i >= len(accepted) {\n        return false;\n    }\n    return accepted[i];", "    if i < 0 || i > len(accepted) {\n        return false;\n    }\n    return accepted[i];",
  "In `is_accepted`, the last valid index is `len(accepted)`; state the bound that way.", "faulty"),
 ("f09", RR, "    return bytes.equal(name, \".cancho-rev\") || bytes.equal(name, \"cancho.toml\");", "    return bytes.equal(name, \".cancho-rev\");",
  "In `pin_name_ok`, `.cancho-rev` is the only pin file a row may name; drop `cancho.toml`.", "faulty"),
 ("f10", RR, "    if any_match(src, tp, deny, path) {\n        return false;\n    }\n    return any_match(src, tp, allow, path);", "    return any_match(src, tp, allow, path);",
  "Drop the deny check from `path_allowed`: the caller applies `publish_deny` itself before it asks.", "faulty"),
]

def run(cmd, cwd, inp=None):
    return subprocess.run(cmd, cwd=cwd, input=inp, capture_output=True, text=True)

def audit(tree, cancho):
    libs = [f for f in sorted(os.listdir(os.path.join(tree, "src"))) if f.endswith(".cho") and f != "main.cho"]
    libs = [os.path.join("src", f) for f in libs]
    r = run([cancho, "check", "src/main.cho"] + libs + ["--std"], tree)
    if r.returncode != 0:
        return "fail", "cancho check: " + (r.stderr or r.stdout).strip().splitlines()[0][:160]
    for t in ("tests/repo_row_test.cho", "tests/company_graph_test.cho"):
        r = run([cancho, "test", t] + libs + ["--std"], tree)
        if r.returncode != 0:
            return "fail", t + ": " + [l for l in (r.stdout + r.stderr).splitlines() if "FAIL" in l or "error" in l.lower() or "panic" in l.lower()][:1].__str__()[:160]
    return "pass", ""

def main():
    out, cancho = sys.argv[1], sys.argv[2]
    do_audit = "--no-audit" not in sys.argv
    base = tempfile.mkdtemp(prefix="r1base-", dir=os.environ.get("TMPDIR", "/tmp"))
    arc = subprocess.Popen(["git", "-C", FORGE, "archive", BASE, "src", "tests"], stdout=subprocess.PIPE)
    subprocess.run(["tar", "-x", "-C", base], stdin=arc.stdout, check=True)
    run(["git", "init", "-q"], base); run(["git", "add", "-A"], base)
    run(["git", "-c", "user.email=r1@example.invalid", "-c", "user.name=r1", "commit", "-q", "-m", "base"], base)
    bad = 0
    for sid, f, old, new, brief, fate in SEEDS:
        p = os.path.join(base, f)
        src = open(p).read()
        if src.count(old) != 1:
            print("FAIL %s: the old text occurs %d times in %s" % (sid, src.count(old), f)); bad += 1; continue
        open(p, "w").write(src.replace(old, new))
        patch = run(["git", "diff", "--no-color"], base).stdout
        d = os.path.join(out, sid)
        os.makedirs(d)
        open(os.path.join(d, "change.patch"), "w").write(patch)
        open(os.path.join(d, "brief.txt"), "w").write(brief + "\n")
        open(os.path.join(d, "fate"), "w").write(fate + "\n")
        measured, why = ("n/a", "")
        if do_audit:
            measured, why = audit(base, cancho)
        run(["git", "checkout", "-q", "--", f], base)
        want = "pass" if fate == "correct" else "fail"
        if do_audit and measured != want:
            print("FAIL %s: declared %s but the audit says %s %s" % (sid, fate, measured, why)); bad += 1
        else:
            print("ok   %s: %-7s audit %-4s %s" % (sid, fate, measured, why))
    shutil.rmtree(base)
    sys.exit(1 if bad else 0)

main()
