#!/bin/sh
# `forge company publish` of a LIBRARY step end to end (docs/library-steps.md; docs/company.md section 15). A company whose builder step
# names a `library` is run to acceptance with the stand-in build tool in its `library` mode (project.cho, src/diff.cho and
# tests/diff_test.cho, as `cancho-build --library diff` leaves them), then published: both library files on the new branch in one
# commit, byte for byte, with the provenance listing each with its digest. And the refusals: a file changed since Forge hashed it, a
# file the step did not leave, the same destination twice, a step with no library naming a library path; and the worker itself, given a
# request it should never get from Forge (a bad `more`), with the branch undone.
# Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
# Usage: CANCHO=path/to/cancho tests/conformance/repo_publish_library.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../.." || exit 1
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
w="$scratch/rl"
mkdir "$w" "$w/workers" "$w/tools" || exit 1
cp scripts/standin_cancho_build.sh "$w/tools/cancho-build" && chmod +x "$w/tools/cancho-build" || exit 1
if ! { $C build src/*.cho --std -o "$w/forge" && $C build workers/cancho_code.cho $libs --std -o "$w/workers/cancho_code" && $C build workers/check_guard.cho $libs --std -o "$w/workers/check_guard" && $C build workers/repo_publish.cho $libs --std -o "$w/workers/repo_publish"; }; then
  echo "FAIL repo publish library: a program did not build"
  exit 1
fi
F="$w/forge"
ok() { echo "ok   repo publish library: $1"; }
bad() { echo "FAIL repo publish library: $1"; fail=1; }
check() { # name, command...
  name=$1; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
git_in() { d=$1; shift; git -C "$d" -c user.email=forge@example.invalid -c user.name=forge -c commit.gpgsign=false "$@"; }
mkrepo() { # name, origin url
  d="$w/$1"
  mkdir "$d" && git init -q "$d" && printf 'readme\n' > "$d/README.md" && git_in "$d" add -A && git_in "$d" commit -q -m first || exit 1
  git -C "$d" remote add origin "$2" && git -C "$d" config user.email forge@example.invalid && git -C "$d" config user.name forge || exit 1
  git -C "$d" config commit.gpgsign false
}
ORIGIN=https://github.com/alpibrusl/cancho-diff.git
operator() { # file, checkout, files json
  printf '{"workers":"%s","tools":"%s","checker":"/opt/cancho/bin/cancho","agent":"stand-in-agent","check_timeout_ms":20000,"build_timeout_ms":20000,"publish":{"lib":{"repo":"alpibrusl/cancho-diff","checkout":"%s","files":%s}},"commit_trailer":"Co-Authored-By: Forge Test <forge@example.invalid>"}' "$w/workers" "$w/tools" "$2" "$3" > "$1"
}

# ---- the company: lib (builder with a contract and the library `diff`) -> ship (a person's gate)
co="$w/co"
mkdir -p "$co/steps/lib/ev" || exit 1
printf '{"id":"co","mission":"m","model":{"provider":"stand","name":"m1"},"budget":{"input":100000,"output":100000,"cache_write":100000,"cache_read":100000,"max_cost":10,"price_table":"prices.json"},"human_gates":["ship"],"roles":["builder","product"],"steps":[{"id":"lib","role":"builder","task_type":"project.build","needs":[],"input":"library","check":"audit_pass.sh","contract":"api.txt","library":"diff"},{"id":"ship","role":"product","task_type":"none","needs":["lib"],"input":"ship it","gate":"ship"}]}' > "$co/company.json"
printf '{"_note":"test","stand":{"m1":{"in":1.0,"cache_write":1.0,"cache_read":1.0,"out":1.0}}}' > "$co/prices.json"
printf '#!/bin/sh\necho "audit of $1"\necho "TOTAL 2/2"\n' > "$co/audit_pass.sh"
chmod +x "$co/audit_pass.sh"
printf 'pub fn add(a: int, b: int) -> [] int\n' > "$co/api.txt"

BOTH='{"src/diff.cho":"src/diff.cho","tests/diff_test.cho":"tests/diff_test.cho"}'
mkrepo ck1 "$ORIGIN"
operator "$w/op1.json" "$w/ck1" "$BOTH"
"$F" company run "$co" "$w/op1.json" > "$w/run1.out" 2> "$w/run1.err"
check "setup: the run stops at the open gate with lib accepted and its library recorded" sh -c "grep -qx 'gate: ship' '$w/run1.out' && grep -q 'company.step.accepted' '$co/company.journal' && grep -q 'company.step.library' '$co/company.journal'"
"$F" company decide "$co" ship approved "looks right" > /dev/null
shasrc=$(sha256sum "$co/steps/lib/ev/src/diff.cho" | cut -c1-64)
shatests=$(sha256sum "$co/steps/lib/ev/tests/diff_test.cho" | cut -c1-64)
before=$(cksum < "$co/company.journal")

# ---- the good path
"$F" company publish "$co" "$w/op1.json" lib forge/lib > "$w/pub1.out" 2> "$w/pub1.err"; echo $? > "$w/pub1.rc"
check "good: exit 0, the branch and a 40-hex commit printed" sh -c "[ \$(cat '$w/pub1.rc') = 0 ] && grep -qx 'published: forge/lib' '$w/pub1.out' && grep -Eq '^commit: [0-9a-f]{40}\$' '$w/pub1.out'"
check "good: both library files are on the branch, byte for byte" sh -c "git -C '$w/ck1' show forge/lib:src/diff.cho | cmp -s - '$co/steps/lib/ev/src/diff.cho' && git -C '$w/ck1' show forge/lib:tests/diff_test.cho | cmp -s - '$co/steps/lib/ev/tests/diff_test.cho'"
check "good: the commit holds exactly the two files and the provenance" sh -c "[ \"\$(git -C '$w/ck1' show --name-only --format= forge/lib | sort | tr '\n' ' ')\" = 'docs/provenance.md src/diff.cho tests/diff_test.cho ' ]"
git -C "$w/ck1" show forge/lib:docs/provenance.md > "$w/prov.md"
check "good: the provenance lists each file with the digest Forge hashed" sh -c "grep -q '## Files' '$w/prov.md' && grep -q 'src/diff.cho.*$shasrc' '$w/prov.md' && grep -q 'tests/diff_test.cho.*$shatests' '$w/prov.md'"
check "good: project.cho is not on the branch, the company journal is unchanged, nothing was pushed" sh -c "! git -C '$w/ck1' show forge/lib:project.cho > /dev/null 2>&1 && [ \"\$(cksum < '$co/company.journal')\" = '$before' ] && [ -z \"\$(git -C '$w/ck1' branch -r)\" ]"
check "good: the checkout is back on its branch and clean" sh -c "[ -z \"\$(git -C '$w/ck1' status --porcelain --untracked-files=all)\" ] && [ \"\$(git -C '$w/ck1' rev-parse --abbrev-ref HEAD)\" != forge/lib ]"

# ---- the artifact together with the library files (three entries)
mkrepo ck2 "$ORIGIN"
operator "$w/op2.json" "$w/ck2" '{"project.cho":"build/project.cho","src/diff.cho":"src/diff.cho","tests/diff_test.cho":"tests/diff_test.cho"}'
"$F" company publish "$co" "$w/op2.json" lib forge/three > "$w/pub2.out" 2> /dev/null; rc=$?
check "three entries: published, and project.cho is among the files" sh -c "[ '$rc' = 0 ] && git -C '$w/ck2' show forge/three:build/project.cho | cmp -s - '$co/steps/lib/ev/project.cho'"

# ---- one entry that is a library file (the main file of the worker is not project.cho)
mkrepo ck3 "$ORIGIN"
operator "$w/op3.json" "$w/ck3" '{"tests/diff_test.cho":"t/diff_test.cho"}'
"$F" company publish "$co" "$w/op3.json" lib forge/one > "$w/pub3.out" 2> /dev/null; rc=$?
check "one library file alone: published" sh -c "[ '$rc' = 0 ] && git -C '$w/ck3' show forge/one:t/diff_test.cho | cmp -s - '$co/steps/lib/ev/tests/diff_test.cho'"

# ---- refusals
refused() { # name, tag, checkout, operator file, branch
  name=$1; tag=$2; ck=$3; op=$4; branch=$5
  heads=$(git -C "$ck" branch --list | wc -l)
  "$F" company publish "$co" "$op" lib "$branch" > "$w/r.out" 2> "$w/r.err"; rc=$?
  newheads=$(git -C "$ck" branch --list | wc -l)
  check "$name: exit 1 and 'refusal: $tag'" sh -c "[ '$rc' = 1 ] && grep -qx 'refusal: $tag' '$w/r.out'"
  check "$name: the checkout is as it was (the same branches, clean)" sh -c "[ '$heads' = '$newheads' ] && [ -z \"\$(git -C '$ck' status --porcelain --untracked-files=all)\" ]"
}
mkrepo ck4 "$ORIGIN"
operator "$w/op4.json" "$w/ck4" "$BOTH"
operator "$w/op-lib.json" "$w/ck4" '{"library.txt":"x.txt"}'
refused "a file Forge never hashed (library.txt)" publish-file-unaccepted "$w/ck4" "$w/op-lib.json" forge/q
operator "$w/op-twice.json" "$w/ck4" '{"src/diff.cho":"same.cho","tests/diff_test.cho":"same.cho"}'
refused "the same destination twice" publish-dest-invalid "$w/ck4" "$w/op-twice.json" forge/q
operator "$w/op-bad.json" "$w/ck4" '{"src/diff.cho":"src/diff.cho","tests/diff_test.cho":"../t.cho"}'
refused "an extra destination that climbs out" publish-dest-invalid "$w/ck4" "$w/op-bad.json" forge/q
operator "$w/op-other.json" "$w/ck4" '{"src/other.cho":"src/diff.cho"}'
refused "a library path of another module" publish-file-unaccepted "$w/ck4" "$w/op-other.json" forge/q

# a file changed after Forge hashed it
printf 'tampered\n' >> "$co/steps/lib/ev/tests/diff_test.cho"
refused "the tests file changed after acceptance" publish-artifact-changed "$w/ck4" "$w/op4.json" forge/q
check "the tests file changed: nothing is on a branch of the checkout" sh -c "[ -z \"\$(git -C '$w/ck4' branch --list 'forge/*')\" ]"
printf 'tampered\n' >> "$co/steps/lib/ev/src/diff.cho"
operator "$w/op-src.json" "$w/ck4" '{"src/diff.cho":"src/diff.cho"}'
refused "the source file changed after acceptance" publish-artifact-changed "$w/ck4" "$w/op-src.json" forge/q
rm -f "$co/steps/lib/ev/src/diff.cho"
refused "the source file gone" publish-artifact-changed "$w/ck4" "$w/op-src.json" forge/q

# ---- the worker, given a request Forge would never send: a bad `more` is refused and the branch is undone
req() { # more json
  printf '{"checkout":"%s","repo":"alpibrusl/cancho-diff","branch":"forge/w","src_dir":"%s","src_name":"project.cho","dest":"a.cho","sha256":"%s","provenance_dest":"docs/provenance.md","provenance":"p","message":"m"%s}' "$w/ck5" "$co/steps/lib/ev" "$(sha256sum "$co/steps/lib/ev/project.cho" | cut -c1-64)" "$1"
}
mkrepo ck5 "$ORIGIN"
worker() { # label, tag, request
  printf '%s' "$3" | "$w/workers/repo_publish" > "$w/wk.out" 2> /dev/null
  check "worker: $1 -> $2" sh -c "grep -q '\"rule\":\"$2\"' '$w/wk.out' && [ -z \"\$(git -C '$w/ck5' branch --list 'forge/*')\" ] && [ -z \"\$(git -C '$w/ck5' status --porcelain --untracked-files=all)\" ]"
}
M='"more":[{"src_dir":"%s","src_name":"%s","dest":"%s","sha256":"%s"}]'
good=$(sha256sum "$co/steps/lib/ev/project.cho" | cut -c1-64)
worker "an extra that climbs out" publish-dest-invalid "$(req ",$(printf "$M" "$co/steps/lib/ev" project.cho '../x.cho' "$good")")"
worker "an extra with the main destination" publish-dest-invalid "$(req ",$(printf "$M" "$co/steps/lib/ev" project.cho 'a.cho' "$good")")"
worker "an extra with the provenance destination" publish-dest-invalid "$(req ",$(printf "$M" "$co/steps/lib/ev" project.cho 'docs/provenance.md' "$good")")"
worker "an extra with a source name holding a slash" publish-dest-invalid "$(req ",$(printf "$M" "$co/steps/lib/ev" 'x/y.cho' 'b.cho' "$good")")"
worker "an extra with a relative directory" publish-dest-invalid "$(req ",$(printf "$M" "rel" project.cho 'b.cho' "$good")")"
worker "an extra with a digest that is not hex" publish-dest-invalid "$(req ",$(printf "$M" "$co/steps/lib/ev" project.cho 'b.cho' 'zz')")"
worker "more that is not an array" publish-dest-invalid "$(req ',"more":5')"
worker "more with four entries" publish-dest-invalid "$(req ',"more":[{},{},{},{}]')"
worker "an extra with the wrong digest (the branch is made, then undone)" publish-artifact-changed "$(req ",$(printf "$M" "$co/steps/lib/ev" project.cho 'b.cho' "$(printf '%064d' 0)")")"
worker "an extra that is not there (the branch is made, then undone)" publish-artifact-changed "$(req ",$(printf "$M" "$co/steps/lib/ev" nothere.cho 'b.cho' "$good")")"
check "worker: a good extra is published (the control)" sh -c "printf '%s' '$(req ",$(printf "$M" "$co/steps/lib/ev" project.cho 'b.cho' "$good")")' | '$w/workers/repo_publish' | grep -q '\"ok\":true' && git -C '$w/ck5' show forge/w:b.cho | cmp -s - '$co/steps/lib/ev/project.cho'"

if [ "$fail" -eq 0 ]; then echo "repo publish library: all held"; fi
exit "$fail"
