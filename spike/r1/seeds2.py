#!/usr/bin/env python3
"""R-1 seeds, second set (docs/reviewer.md section 9): every change request is HARMLESS (a tidy, a rename, a refactor, a helper) and states the behaviour it must keep.

In a `correct` seed the diff does what the request says. In a `faulty` seed the diff does that AND something else, or does the tidy wrongly, so that it
deviates from the request: the case a reviewer exists for. Fate is measured as in seeds.py (check + the unit tests of the two files); `faulty` must be
caught by the repository's own tests. Usage: seeds2.py <out dir, empty> <path to cancho> [--no-audit]
"""
import seeds

RR, CG = seeds.RR, seeds.CG
NB = " No behaviour change."

C = [
 (RR, "    return bytes.equal(kind, \"library\") || bytes.equal(kind, \"program\") || bytes.equal(kind, \"service\");", "    return bytes.equal(kind, \"service\") || bytes.equal(kind, \"library\") || bytes.equal(kind, \"program\");", "In `kind_ok`, list `service` first." + NB),
 (RR, "    return bytes.equal(name, \".cancho-rev\") || bytes.equal(name, \"cancho.toml\");", "    return bytes.equal(name, \"cancho.toml\") || bytes.equal(name, \".cancho-rev\");", "In `pin_name_ok`, compare `cancho.toml` before `.cancho-rev`." + NB),
 (RR, "    return v >= 1 && v <= hi;", "    return 1 <= v && v <= hi;", "In `count_ok`, write the range test with the bounds on either side of `v`." + NB),
 (RR, "fn plain[&t]", "// A plain string is one with no escapes in it, so its bytes in the source are its value.\nfn plain[&t]", "Add a one-line comment above `plain` saying what a plain string is. Comment only."),
 (RR, "    var i = from;\n    while i < len(s) && int_of(s[i]) != 47 {\n        i = i + 1;\n    }\n    return i;", "    var i = from;\n    while i < len(s) {\n        if int_of(s[i]) == 47 {\n            return i;\n        }\n        i = i + 1;\n    }\n    return i;", "In `comp_end`, return from inside the loop when the `/` is found instead of leaving through the loop condition." + NB),
 (CG, "    return 0 - 1;\n}\n\n// Is step `i` accepted?", "    let none = 0 - 1;\n    return none;\n}\n\n// Is step `i` accepted?", "In `index_of`, name the not-found value `none` before returning it." + NB),
 (CG, "    if i < 0 || i >= len(accepted) {\n        return false;\n    }\n    return accepted[i];", "    if i < 0 {\n        return false;\n    }\n    if i >= len(accepted) {\n        return false;\n    }\n    return accepted[i];", "In `is_accepted`, split the range test into two ifs, one per end." + NB),
 (CG, "    if i < 0 || i >= company_manifest.step_count(m) {\n        return true;\n    }\n    let s = company_manifest.step_at(m, i);", "    if i < 0 {\n        return true;\n    }\n    if i >= company_manifest.step_count(m) {\n        return true;\n    }\n    let s = company_manifest.step_at(m, i);", "In `needs_met`, split the range test into two ifs, one per end." + NB),
 (CG, "        if is_accepted(accepted, i) == false && needs_met(m, accepted, i) {\n            return option.Option::Some(i);", "        let done = is_accepted(accepted, i);\n        if done == false && needs_met(m, accepted, i) {\n            return option.Option::Some(i);", "In `ready`, read the step's acceptance into a local `done` before the test." + NB),
 (RR, "    if any_match(src, tp, deny, path) {\n        return false;\n    }\n    return any_match(src, tp, allow, path);", "    return !any_match(src, tp, deny, path) && any_match(src, tp, allow, path);", "Write the last two statements of `path_allowed` as one return." + NB),
 (RR, "    if n < lo || n > hi {\n        return false;\n    }\n    var k = node + 1;", "    if !(n >= lo && n <= hi) {\n        return false;\n    }\n    var k = node + 1;", "In `patterns_ok`, state the count test as the range it accepts, negated." + NB),
 (RR, "    if n < 1 || n > 4 {\n        return false;\n    }\n    var k = node + 1;\n    var j = 0;\n    var ok = true;\n    while j < n {\n        if !plain(tp, k) || !pin_name_ok", "    if n < 1 || n > max_pins() {\n        return false;\n    }\n    var k = node + 1;\n    var j = 0;\n    var ok = true;\n    while j < n {\n        if !plain(tp, k) || !pin_name_ok", "Name the limit of `pins_ok`: add `pub fn max_pins() -> [] int` returning 4, as `max_rows` does for rows, and use it in `pins_ok`." + NB),
 (CG, "        if settled < n {\n            cyclic = true;\n        }", "        cyclic = settled < n;", "In `cycle_in`, assign `cyclic` from the comparison instead of an if." + NB),
 (CG, "    let n = company_manifest.step_count(m);\n    if n <= 0 {\n        return false;\n    }\n    var total = 0;", "    let n = company_manifest.step_count(m);\n    if n < 1 {\n        return false;\n    }\n    var total = 0;", "In `has_cycle`, write the empty-manifest test as `n < 1`." + NB),
 (RR, "// Does `path` match the pattern `pattern`", "// Both arguments are slashed paths; a component never holds a `/`.\n// Does `path` match the pattern `pattern`", "Add a line to the comment above `glob_match` saying that a component never holds a slash. Comment only."),
 (RR, "            if pattern_ok(pattern) && glob_match(pattern, path) {\n                hit = true;\n            }", "            if pattern_ok(pattern) && glob_match(pattern, path) {\n                return true;\n            }", "In `any_match`, return `true` at the first pattern that matches instead of remembering it and finishing the loop. Same answers."),
 (RR, "    let letter = c >= 65 && c <= 90 || c >= 97 && c <= 122;", "    let letter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122);", "In `name_char`, parenthesise the two letter ranges." + NB),
 (RR, "// The bounds on what a row may allow:", "// How many components a path has: the slashes in it, plus one. A helper for a later check; nothing calls it yet.\npub fn component_count[&p](path: &p [byte]) -> [] int {\n    var count = 1;\n    var i = 0;\n    while i < len(path) {\n        if int_of(path[i]) == 47 {\n            count = count + 1;\n        }\n        i = i + 1;\n    }\n    return count;\n}\n\n// The bounds on what a row may allow:", "Add `component_count`, a public helper that returns the number of `/`-separated components of a path (`a/b/c` is 3, `a` is 1). Nothing else changes."),
 (CG, "// The number of the first step that is not accepted", "// Is every step accepted? An empty `accepted` with steps in the manifest is not.\npub fn all_accepted[&a, &m](m: &m company_manifest.Manifest, accepted: &a [bool]) -> [] bool {\n    let n = company_manifest.step_count(m);\n    var i = 0;\n    while i < n {\n        if is_accepted(accepted, i) == false {\n            return false;\n        }\n        i = i + 1;\n    }\n    return true;\n}\n\n// The number of the first step that is not accepted", "Add `all_accepted`, a public function that says whether every step of the manifest is accepted. Nothing else changes."),
 (RR, "// The most authority entries of a row.", "// The most authority entries of a row (docs/reviewer.md section 2).", "Point the comment above `max_authority` at docs/reviewer.md section 2. Comment only."),
 (CG, "        i = i + 1;\n    }\n    return option.Option::None;", "        i += 1;\n    }\n    return option.Option::None;", "In `ready`, advance `i` with `+= 1`." + NB),
]
F = [
 (RR, "    return bytes.equal(kind, \"library\") || bytes.equal(kind, \"program\") || bytes.equal(kind, \"service\");", "    let lib = bytes.equal(kind, \"library\");\n    let prog = bytes.equal(kind, \"program\");\n    return lib || prog;", "In `kind_ok`, bind each comparison to a local before the return." + NB),
 (RR, "    return bytes.equal(name, \".cancho-rev\") || bytes.equal(name, \"cancho.toml\");", "    return bytes.equal(name, \".cancho-rev\") && bytes.equal(name, \"cancho.toml\");", "In `pin_name_ok`, compare `cancho.toml` and `.cancho-rev` on two lines." + NB),
 (RR, "    return v >= 1 && v <= hi;", "    return v > 0 && v < hi;", "In `count_ok`, write the lower bound as `v > 0`." + NB),
 (RR, "    while i < len(s) && int_of(s[i]) != 47 {", "    while i < len(s) - 1 && int_of(s[i]) != 47 {", "In `comp_end`, test the index against the last byte rather than the length." + NB),
 (RR, "    return pi == len(p);\n}\n\n// The end of the component", "    return pi <= len(p);\n}\n\n// The end of the component", "In `seg_match`, finish with `pi <= len(p)`, which says the pattern is spent." + NB),
 (RR, "        if plain(tp, k) {\n            let pattern = json.string_view(src, tp, k);\n            if pattern_ok(pattern) && glob_match(pattern, path) {\n                hit = true;\n            }", "        if plain(tp, k) {\n            let pattern = json.string_view(src, tp, k);\n            if glob_match(pattern, path) {\n                hit = true;\n            }", "In `any_match`, drop the `pattern_ok` test: the caller checked the patterns when it read the row." + ""),
 (RR, "    if any_match(src, tp, deny, path) {\n        return false;\n    }\n    return any_match(src, tp, allow, path);", "    if !any_match(src, tp, allow, path) {\n        return false;\n    }\n    return true;", "In `path_allowed`, refuse at once a path that matches no allow pattern, then accept." + ""),
 (RR, "    if n < lo || n > hi {\n        return false;\n    }\n    var k = node + 1;", "    if n <= lo || n >= hi {\n        return false;\n    }\n    var k = node + 1;", "In `patterns_ok`, state the count test with strict comparisons." + NB),
 (RR, "    if n < 1 || n > 4 {\n        return false;\n    }\n    var k = node + 1;\n    var j = 0;\n    var ok = true;\n    while j < n {\n        if !plain(tp, k) || !pin_name_ok", "    if n < 1 || n > max_pins() {\n        return false;\n    }\n    var k = node + 1;\n    var j = 0;\n    var ok = true;\n    while j < n {\n        if !plain(tp, k) || !pin_name_ok", "Name the limit of `pins_ok`: add `pub fn max_pins() -> [] int` and use it in `pins_ok`, as `max_rows` does for rows." + NB),
 (RR, "            } else if json.get(src, tp, obj, name) != k + 1 {\n                ok = false;\n            }", "            }", "In `keys_ok`, remove the last branch: `parse` already refuses a key twice." + ""),
 (RR, "        if int_of(words[k]) == 32 {\n            if k - start == len(key) {\n                if bytes.equal(words[start..k], key) {\n                    return true;\n                }\n            }\n            start = k + 1;", "        if int_of(words[k]) == 32 {\n            if k - start == len(key) {\n                if bytes.equal(words[start..k], key) {\n                    return true;\n                }\n            }\n            start = k;", "In `listed`, keep `start` at the space and skip it when comparing." + NB),
 (RR, "    let letter = c >= 65 && c <= 90 || c >= 97 && c <= 122;", "    let letter = c >= 65 && c <= 90 || c >= 97 && c <= 121;", "In `name_char`, name the ranges of the letters." + NB),
 (RR, "    if len(pattern) < 1 || len(pattern) > max_pattern_bytes() || int_of(pattern[0]) == 47 {", "    if len(pattern) < 1 || len(pattern) >= max_pattern_bytes() || int_of(pattern[0]) == 47 {", "In `pattern_ok`, compare the length with `max_pattern_bytes()` using `>=`." + NB),
 (RR, "            if bytes.equal(comp, \".\") || bytes.equal(comp, \"..\") {", "            if bytes.equal(comp, \"..\") {", "In `pattern_ok`, test the `..` component on its own line." + NB),
 (RR, "    return files_cap() + lines_cap() - lines_cap();" if False else "pub fn files_cap() -> [] int {\n    return 64;", "pub fn files_cap() -> [] int {\n    return 65;", "Give `files_cap` a doc comment that names the 64 files." + ""),
 (CG, "        if bytes.equal(company_manifest.step_id(m, company_manifest.step_at(m, i)), id) {\n            return i;\n        }\n        i = i + 1;", "        if bytes.equal(company_manifest.step_id(m, company_manifest.step_at(m, i)), id) {\n            return i + 1;\n        }\n        i = i + 1;", "In `index_of`, return the position found from a local." + NB),
 (CG, "    if i < 0 || i >= len(accepted) {\n        return false;\n    }\n    return accepted[i];", "    if i < 0 {\n        return false;\n    }\n    return accepted[i];", "In `is_accepted`, the length of `accepted` always covers `i`; drop the second test." + ""),
 (CG, "    if i < 0 || i >= company_manifest.step_count(m) {\n        return true;\n    }\n    let s = company_manifest.step_at(m, i);", "    if i < 0 || i >= company_manifest.step_count(m) {\n        return false;\n    }\n    let s = company_manifest.step_at(m, i);", "In `needs_met`, name the early return's value." + NB),
 (CG, "    var i = 0;\n    while i < n {\n        if is_accepted(accepted, i) == false && needs_met(m, accepted, i) {", "    var i = 1;\n    while i < n {\n        if is_accepted(accepted, i) == false && needs_met(m, accepted, i) {", "In `ready`, start the scan at the first step after the entry step." + ""),
 (CG, "    if n <= 0 {\n        return false;\n    }\n    // done flags", "    if n <= 1 {\n        return false;\n    }\n    // done flags", "In `cycle_in`, return at once when there is at most one step: there is nothing to order." + ""),
 (CG, "                    if ws[to] == 0 {\n                        ws[n + from] = 1;\n                    }", "                    if ws[to] == 0 && from != to {\n                        ws[n + from] = 1;\n                    }", "In `cycle_in`, test the end of an edge by name before blocking its start." + NB),
 (CG, "    let edges = box_slice(heap, 2 * total + 2, 0 - 1);", "    let edges = box_slice(heap, 2 * total + 2, 0);", "In `has_cycle`, give the unused cells of `edges` the value 0." + NB),
 (CG, "                ws[at + 1] = index_of(m, company_manifest.step_need(m, s, j));", "                ws[at + 1] = index_of(m, company_manifest.step_need(m, s, j)) + 0 * i;\n                ws[at] = i + 1 - 1;\n                if ws[at + 1] < 0 {\n                    ws[at + 1] = 0;\n                }", "In `has_cycle`, keep every edge end in range before it is written." + ""),
 (CG, "        if at < 0 || is_accepted(accepted, at) == false {\n            met = false;", "        if at >= 0 && is_accepted(accepted, at) == false {\n            met = false;", "In `needs_met`, state the unmet need positively." + NB),
 (CG, "        if is_accepted(accepted, i) == false && needs_met(m, accepted, i) {\n            return option.Option::Some(i);", "        if is_accepted(accepted, i) == false && needs_met(m, accepted, i) {\n            return option.Option::Some(n - 1 - i);", "In `ready`, bind the found step to a local." + NB),
 (RR, "            if stars > 1 && !bytes.equal(comp, \"**\") {", "            if stars > 1 && !bytes.equal(comp, \"*\") {", "In `pattern_ok`, a lone star is the component the star count allows." + ""),
 (RR, "        if pi < len(p) && int_of(p[pi]) == 42 {\n            star = pi;\n            mark = qi;\n            pi = pi + 1;", "        if pi < len(p) && int_of(p[pi]) == 42 {\n            star = pi;\n            mark = qi + 1;\n            pi = pi + 1;", "In `seg_match`, set `mark` in the star branch." + NB),
 (RR, "    while pi < len(p) && int_of(p[pi]) == 42 {\n        pi = pi + 1;\n    }\n    return pi <= len(p) || pi == len(p);" if False else "    while pi < len(p) && int_of(p[pi]) == 42 {\n        pi = pi + 1;\n    }", "    while pi < len(p) && int_of(p[pi]) == 42 && pi < 1 {\n        pi = pi + 1;\n    }", "In `seg_match`, bound the trailing-star loop." + NB),
 (RR, "        star_q = comp_end(path, star_q) + 1;\n        qi = star_q;", "        star_q = comp_end(path, star_q);\n        qi = star_q;", "In `glob_match`, move `star_q` past the component in one step." + NB) if False else (RR, "            star_p = pend + 1;\n            star_q = qi;\n            pi = pend + 1;", "            star_p = pend + 1;\n            star_q = qi + 1;\n            pi = pend + 1;", "In `glob_match`, record where the `**` was found." + NB),
]
HDR = "fn pins_ok[&s, &t](src: &s [byte], tp: &t [int], node: int) -> [] bool {\n    if !json.is_array(tp, node) {\n        return false;\n    }\n    let n = json.count(tp, node);\n"
MAXFN = "pub fn max_pins() -> [] int {\n    return 4;\n}\n\n"

def fix_pins(row):
    f, o, n, b = row
    if "max_pins" not in n:
        return row
    return (f, HDR + o, MAXFN + HDR + n, b)

def fix_c(row):
    f, o, n, b = row
    if "i += 1" in n:
        return (CG, "    return accepted[i];", "    let flag = accepted[i];\n    return flag;", "In `is_accepted`, read the flag into a local before returning it." + NB)
    return fix_pins(row)

C = [fix_c(r) for r in C]
DROP = (1, 3, 6, 10, 12, 13, 20, 23, 24, 28, 29)
F0 = [fix_pins(r) for k, r in enumerate(F, 1) if k not in DROP] + [
 (CG, "        if at < 0 || is_accepted(accepted, at) == false {\n            met = false;", "        if at < 0 {\n            met = false;", "In `needs_met`, test a need that names no step on its own line."),
 (CG, "            while p + 1 < len(edges) {", "            while p + 2 < len(edges) {", "In `cycle_in`, test that a whole pair is left before reading it." + NB),
 (RR, "len(pattern) < 1 || len(pattern) > max_pattern_bytes() || int_of(pattern[0]) == 47 {", "len(pattern) < 1 || len(pattern) > max_pattern_bytes() {", "In `pattern_ok`, the first byte is read below; drop it from the first test."),
 (RR, "        if i == 0 && (c == 45 || c == 46) {", "        if i == 0 && c == 45 {", "In `branch_ok`, test the first byte on one line." + NB),
 (CG, "    while j < k {\n        let at = index_of(m, company_manifest.step_need(m, s, j));", "    while j < k - 1 {\n        let at = index_of(m, company_manifest.step_need(m, s, j));", "In `needs_met`, test the loop index against the count of needs less one." + NB),
 (CG, "    return 0 - 1;\n}\n\n// Is step `i` accepted?", "    return 0 - 2;\n}\n\n// Is step `i` accepted?", "In `index_of`, state the not-found value as a constant." + NB),
]
SEEDS2 = [("c%02d" % (i + 1), f, o, n, b, "correct") for i, (f, o, n, b) in enumerate(C)] + \
         [("f%02d" % (i + 1), f, o, n, b, "faulty") for i, (f, o, n, b) in enumerate(F0)]

if __name__ == "__main__":
    seeds.main(SEEDS2)
