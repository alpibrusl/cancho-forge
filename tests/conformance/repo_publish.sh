#!/bin/sh
# `forge company publish` end to end (docs/company.md section 15; docs/autonomy.md section 5). The programs under test are the forge
# binary and the worker `workers/repo_publish.cho`; this script is the oracle only. It makes a company whose builder step is the
# stand-in build tool in its `spend` mode (a product and usage records), runs it to acceptance, makes a throw-away git repository whose
# `origin` is the allow-listed `alpibrusl/cancho-diff` on github.com (a name only: nothing here has a network), and publishes.
#
# The good path: the artifact on a new branch, byte for byte; the provenance (tokens, cost, the person's decision) beside it; the commit
# message with the operator's trailer; the working tree back on the branch it was on, clean; `steps/<id>/pr.md` written; nothing pushed
# (no remote-tracking ref); the company journal unchanged. And one case per refusal tag of the publish: each leaves the checkout exactly
# as it found it (clean, on its branch, no new branch) and writes no pr.md. The hostile cases: a branch or a path with shell
# metacharacters is refused before any shell sees it; a trailer full of shell syntax is data; a commit hook of the checkout does not
# run; a link in the way is refused; a commit that fails after the branch was made is undone (an ignored path).
# Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
# Usage: CANCHO=path/to/cancho tests/conformance/repo_publish.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../.." || exit 1
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
w="$scratch/rp"
mkdir "$w" "$w/workers" "$w/tools" "$w/emptyworkers" || exit 1
cp scripts/standin_cancho_build.sh "$w/tools/cancho-build" && chmod +x "$w/tools/cancho-build" || exit 1
if ! { $C build src/*.cho --std -o "$w/forge" && $C build workers/cancho_code.cho $libs --std -o "$w/workers/cancho_code" && $C build workers/check_guard.cho $libs --std -o "$w/workers/check_guard" && $C build workers/repo_publish.cho $libs --std -o "$w/workers/repo_publish"; }; then
  echo "FAIL repo publish: a program did not build"
  exit 1
fi
F="$w/forge"
ok() { echo "ok   repo publish: $1"; }
bad() { echo "FAIL repo publish: $1"; fail=1; }
check() { # name, command...
  name=$1; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

# ---- the company: lib (builder, stand-in `spend`: a product and two usage records of 600 + 500 input tokens) -> ship (a person's gate)
co="$w/co"
mkdir -p "$co/steps/lib/ev" || exit 1
printf '{"id":"co","mission":"m","model":{"provider":"stand","name":"m1"},"budget":{"input":100000,"output":100000,"cache_write":100000,"cache_read":100000,"max_cost":10,"price_table":"prices.json"},"human_gates":["ship"],"roles":["builder","product"],"steps":[{"id":"lib","role":"builder","task_type":"project.build","needs":[],"input":"spend","check":"audit_pass.sh"},{"id":"ship","role":"product","task_type":"none","needs":["lib"],"input":"ship it","gate":"ship"}]}' > "$co/company.json"
printf '{"_note":"test","stand":{"m1":{"in":1.0,"cache_write":1.0,"cache_read":1.0,"out":1.0}}}' > "$co/prices.json"
printf '#!/bin/sh\necho "audit of $1"\necho "TOTAL 2/2"\n' > "$co/audit_pass.sh"
chmod +x "$co/audit_pass.sh"

git_in() { d=$1; shift; git -C "$d" -c user.email=forge@example.invalid -c user.name=forge -c commit.gpgsign=false "$@"; }
# A checkout: a repository with one commit, `origin` the allow-listed repository by name, an identity of its own (the worker has no
# environment, so no global one).
mkrepo() { # name, origin url
  d="$w/$1"
  mkdir "$d" && git init -q "$d" && printf 'readme\n' > "$d/README.md" && git_in "$d" add -A && git_in "$d" commit -q -m first || exit 1
  git -C "$d" remote add origin "$2" && git -C "$d" config user.email forge@example.invalid && git -C "$d" config user.name forge || exit 1
  git -C "$d" config commit.gpgsign false
}
ORIGIN=https://github.com/alpibrusl/cancho-diff.git
operator() { # file, checkout, repo, files json, workers dir, trailer
  printf '{"workers":"%s","tools":"%s","checker":"/opt/cancho/bin/cancho","agent":"stand-in-agent","check_timeout_ms":20000,"build_timeout_ms":20000,"publish":{"lib":{"repo":"%s","checkout":"%s","files":%s}},"commit_trailer":"%s"}' "$5" "$w/tools" "$3" "$2" "$4" "$6" > "$1"
}
FILES='{"project.cho":"src/diff.cho"}'
TRAILER='Co-Authored-By: Forge Test <forge@example.invalid>'

mkrepo ck1 "$ORIGIN"
operator "$w/op1.json" "$w/ck1" alpibrusl/cancho-diff "$FILES" "$w/workers" "$TRAILER"
"$F" company run "$co" "$w/op1.json" > "$w/run1.out" 2> "$w/run1.err"
check "setup: the first run stops at the open gate (exit 10) with lib accepted" sh -c "[ \$(sed -n 's/^//p' /dev/null; echo 0) = 0 ] && grep -qx 'gate: ship' '$w/run1.out' && grep -q 'company.step.accepted' '$co/company.journal'"
"$F" company decide "$co" ship approved "looks right" > /dev/null
sha=$(sha256sum "$co/steps/lib/ev/project.cho" | cut -c1-64)
before=$(cksum < "$co/company.journal")
orig=$(git -C "$w/ck1" rev-parse --abbrev-ref HEAD)

# ---- the good path
"$F" company publish "$co" "$w/op1.json" lib forge/lib > "$w/pub1.out" 2> "$w/pub1.err"; echo $? > "$w/pub1.rc"
check "good: exit 0 and the branch and a 40-hex commit are printed" sh -c "[ \$(cat '$w/pub1.rc') = 0 ] && grep -qx 'published: forge/lib' '$w/pub1.out' && grep -Eq '^commit: [0-9a-f]{40}\$' '$w/pub1.out'"
commit=$(sed -n 's/^commit: //p' "$w/pub1.out")
check "good: the branch holds that commit" sh -c "[ \"\$(git -C '$w/ck1' rev-parse forge/lib)\" = '$commit' ]"
check "good: the artifact is on the branch, byte for byte" sh -c "git -C '$w/ck1' show forge/lib:src/diff.cho | cmp -s - '$co/steps/lib/ev/project.cho'"
git -C "$w/ck1" show forge/lib:docs/provenance.md > "$w/prov.md"
check "good: the provenance names the artifact digest, the tokens, the cost and the person's decision" sh -c "grep -q '$sha' '$w/prov.md' && grep -q 'input 1100, output 30' '$w/prov.md' && grep -q 'Cost recorded by Forge | \\\$0.001130' '$w/prov.md' && grep -q 'ship.: approved by .*: looks right' '$w/prov.md' && grep -q 'does not record' '$w/prov.md'"
check "good: the commit message has the subject and the operator's trailer line, and the commit holds exactly the two files" sh -c "git -C '$w/ck1' log -1 --format=%B forge/lib | head -1 | grep -qx 'Add src/diff.cho, built by Forge' && git -C '$w/ck1' log -1 --format=%B forge/lib | grep -qx '$TRAILER' && [ \"\$(git -C '$w/ck1' show --name-only --format= forge/lib | sort | tr '\\n' ' ')\" = 'docs/provenance.md src/diff.cho ' ]"
check "good: the checkout is back on its own branch, clean, with neither file in its tree" sh -c "[ \"\$(git -C '$w/ck1' rev-parse --abbrev-ref HEAD)\" = '$orig' ] && [ -z \"\$(git -C '$w/ck1' status --porcelain --untracked-files=all)\" ] && [ ! -e '$w/ck1/src/diff.cho' ]"
check "good: steps/lib/pr.md has the title, the branch and the commit, and says nothing was pushed" sh -c "head -1 '$co/steps/lib/pr.md' | grep -qx 'Add src/diff.cho (step lib of the company co)' && grep -q 'forge/lib' '$co/steps/lib/pr.md' && grep -q '$commit' '$co/steps/lib/pr.md' && grep -q 'was not pushed' '$co/steps/lib/pr.md' && grep -q 'was not pushed' '$w/pub1.out'"
check "good: nothing was pushed (no remote-tracking ref) and the company journal is byte for byte what it was" sh -c "[ -z \"\$(git -C '$w/ck1' branch -r)\" ] && [ \"\$(cksum < '$co/company.journal')\" = '$before' ]"

# ---- the same inputs give the same provenance, in another checkout
mkrepo ck2 "$ORIGIN"
operator "$w/op2.json" "$w/ck2" alpibrusl/cancho-diff "$FILES" "$w/workers" "$TRAILER"
"$F" company publish "$co" "$w/op2.json" lib forge/other > "$w/pub2.out" 2> /dev/null
git -C "$w/ck2" show forge/other:docs/provenance.md > "$w/prov2.md"
check "deterministic: a second publish writes the same provenance bytes" cmp -s "$w/prov.md" "$w/prov2.md"

# ---- one case per refusal. `refused NAME TAG CHECKOUT ARGS...`: exit 1, the tag, the checkout untouched, no pr.md
refused() { # name, tag, checkout, operator file, step, branch [extra word]
  name=$1; tag=$2; ck=$3; op=$4; step=$5; branch=$6; shift 6
  rm -f "$co/steps/$step/pr.md" 2> /dev/null
  heads=$(git -C "$ck" branch --list 2> /dev/null | wc -l)
  "$F" company publish "$co" "$op" "$step" "$branch" "$@" > "$w/r.out" 2> "$w/r.err"; rc=$?
  newheads=$(git -C "$ck" branch --list 2> /dev/null | wc -l)
  check "$name: exit 1 and 'refusal: $tag'" sh -c "[ '$rc' = 1 ] && grep -qx 'refusal: $tag' '$w/r.out'"
  check "$name: the checkout is as it was (the same branches, clean) and no pr.md" sh -c "[ '$heads' = '$newheads' ] && { [ -n '${DIRTY:-}' ] || [ -z \"\$(git -C '$ck' status --porcelain --untracked-files=all 2> /dev/null)\" ]; } && [ ! -e '$co/steps/$step/pr.md' ]"
}
mkrepo ck3 "$ORIGIN"
operator "$w/op3.json" "$w/ck3" alpibrusl/cancho-diff "$FILES" "$w/workers" "$TRAILER"
refused "push is not granted" publish-push-not-granted "$w/ck3" "$w/op3.json" lib forge/p push
refused "a branch that is an option" publish-branch-invalid "$w/ck3" "$w/op3.json" lib -x
refused "a branch with .." publish-branch-invalid "$w/ck3" "$w/op3.json" lib a..b
refused "a branch ending .lock" publish-branch-invalid "$w/ck3" "$w/op3.json" lib forge/x.lock
refused "a branch with shell syntax" publish-branch-invalid "$w/ck3" "$w/op3.json" lib 'x;touch pwned'
check "shell syntax in a branch: nothing was run" sh -c "[ ! -e '$w/ck3/pwned' ] && [ ! -e pwned ]"
refused "a step that is no step" publish-step-not-accepted "$w/ck3" "$w/op3.json" nope forge/q
refused "a step that is not a builder (a person's gate)" publish-step-not-accepted "$w/ck3" "$w/op3.json" ship forge/q
printf '{"workers":"%s","tools":"%s","checker":"/opt/cancho/bin/cancho","agent":"stand-in-agent"}' "$w/workers" "$w/tools" > "$w/op-none.json"
refused "no publish entry for the step" publish-not-configured "$w/ck3" "$w/op-none.json" lib forge/q
operator "$w/op-files.json" "$w/ck3" alpibrusl/cancho-diff '{"project.cho":"src/diff.cho","notes.txt":"docs/notes.txt"}' "$w/workers" ""
refused "a file the step did not accept" publish-file-unaccepted "$w/ck3" "$w/op-files.json" lib forge/q
operator "$w/op-files2.json" "$w/ck3" alpibrusl/cancho-diff '{"other.cho":"src/diff.cho"}' "$w/workers" ""
refused "files that omit the artifact" publish-file-unaccepted "$w/ck3" "$w/op-files2.json" lib forge/q
for d in ../x.cho /abs.cho .git/hooks/x a//b .hidden/x -x.cho docs/provenance.md 'a b.cho' 'x;y.cho'; do
  operator "$w/op-dest.json" "$w/ck3" alpibrusl/cancho-diff "{\"project.cho\":\"$d\"}" "$w/workers" ""
  refused "a destination '$d'" publish-dest-invalid "$w/ck3" "$w/op-dest.json" lib forge/q
done
operator "$w/op-repo.json" "$w/ck3" alpibrusl/not-listed "$FILES" "$w/workers" ""
refused "a repository that is not on the allow-list" publish-repo-not-allowed "$w/ck3" "$w/op-repo.json" lib forge/q
mkrepo ck-other https://github.com/someone/else.git
operator "$w/op-other.json" "$w/ck-other" alpibrusl/cancho-diff "$FILES" "$w/workers" ""
refused "a checkout whose origin is another repository" publish-repo-not-allowed "$w/ck-other" "$w/op-other.json" lib forge/q
mkrepo ck-host https://evil.example/alpibrusl/cancho-diff.git
operator "$w/op-host.json" "$w/ck-host" alpibrusl/cancho-diff "$FILES" "$w/workers" ""
refused "a checkout whose origin is the right name on another host" publish-repo-not-allowed "$w/ck-host" "$w/op-host.json" lib forge/q
mkdir "$w/plain"
operator "$w/op-plain.json" "$w/plain" alpibrusl/cancho-diff "$FILES" "$w/workers" ""
refused "a checkout that is not a repository" publish-checkout-invalid "$w/plain" "$w/op-plain.json" lib forge/q
operator "$w/op-dots.json" "$w/ck3/../ck3" alpibrusl/cancho-diff "$FILES" "$w/workers" ""
refused "a checkout path with .." publish-checkout-invalid "$w/ck3" "$w/op-dots.json" lib forge/q
mkdir "$w/ck3/sub"; : > "$w/ck3/sub/.keep"; git_in "$w/ck3" add -A; git_in "$w/ck3" commit -q -m sub
operator "$w/op-sub.json" "$w/ck3/sub" alpibrusl/cancho-diff "$FILES" "$w/workers" ""
refused "a checkout that is a directory inside a repository, not its toplevel" publish-checkout-invalid "$w/ck3" "$w/op-sub.json" lib forge/q
printf 'edit\n' >> "$w/ck3/README.md"
DIRTY=1 refused "a checkout with a modified file" publish-checkout-dirty "$w/ck3" "$w/op3.json" lib forge/q
git -C "$w/ck3" checkout -q -- README.md
printf 'x\n' > "$w/ck3/untracked.txt"
DIRTY=1 refused "a checkout with an untracked file" publish-checkout-dirty "$w/ck3" "$w/op3.json" lib forge/q
rm -f "$w/ck3/untracked.txt"
refused "a branch that exists" publish-branch-exists "$w/ck1" "$w/op1.json" lib forge/lib
rm -rf "$w/ck3/src"; mkdir "$w/elsewhere"; ln -s "$w/elsewhere" "$w/ck3/src"; git_in "$w/ck3" add -A; git_in "$w/ck3" commit -q -m link
refused "a link on the way to the destination" publish-dest-invalid "$w/ck3" "$w/op3.json" lib forge/q
check "a link on the way: nothing was written through it" sh -c "[ -z \"\$(ls -A '$w/elsewhere')\" ]"
mkrepo ck-noid "$ORIGIN"
git -C "$w/ck-noid" config --unset user.email; git -C "$w/ck-noid" config --unset user.name; git -C "$w/ck-noid" config user.useConfigOnly true
operator "$w/op-noid.json" "$w/ck-noid" alpibrusl/cancho-diff "$FILES" "$w/workers" ""
refused "a commit git refuses (no identity), undone" publish-commit-failed "$w/ck-noid" "$w/op-noid.json" lib forge/q
check "a commit git refuses: the branch is gone and the files are not left behind" sh -c "[ -z \"\$(git -C '$w/ck-noid' branch --list 'forge/*')\" ] && [ ! -e '$w/ck-noid/src/diff.cho' ] && [ ! -e '$w/ck-noid/docs/provenance.md' ]"
mkrepo ck-ign "$ORIGIN"
printf 'src/\n' > "$w/ck-ign/.gitignore"; git_in "$w/ck-ign" add -A; git_in "$w/ck-ign" commit -q -m ignore
operator "$w/op-ign.json" "$w/ck-ign" alpibrusl/cancho-diff "$FILES" "$w/workers" ""
refused "an ignored destination: staging fails after the branch was made, undone" publish-commit-failed "$w/ck-ign" "$w/op-ign.json" lib forge/q
check "an ignored destination: back on the first branch, no branch left, the ignored file removed" sh -c "[ \"\$(git -C '$w/ck-ign' rev-parse --abbrev-ref HEAD)\" = '$orig' ] && [ -z \"\$(git -C '$w/ck-ign' branch --list 'forge/*')\" ] && [ ! -e '$w/ck-ign/src/diff.cho' ]"
operator "$w/op-nowork.json" "$w/ck3" alpibrusl/cancho-diff "$FILES" "$w/emptyworkers" ""
mkrepo ck-nowork "$ORIGIN"
operator "$w/op-nowork.json" "$w/ck-nowork" alpibrusl/cancho-diff "$FILES" "$w/emptyworkers" ""
refused "a workers directory with no repo_publish" publish-worker-failed "$w/ck-nowork" "$w/op-nowork.json" lib forge/q

# ---- the artifact changed since it was accepted: another company directory (a copy), its artifact edited
cp -r "$co" "$w/co-edited" && printf 'x' >> "$w/co-edited/steps/lib/ev/project.cho"
mkrepo ck4 "$ORIGIN"
operator "$w/op4.json" "$w/ck4" alpibrusl/cancho-diff "$FILES" "$w/workers" ""
"$F" company publish "$w/co-edited" "$w/op4.json" lib forge/q > "$w/r.out" 2> /dev/null; rc=$?
check "an artifact edited after acceptance: publish-artifact-changed, nothing touched" sh -c "[ '$rc' = 1 ] && grep -qx 'refusal: publish-artifact-changed' '$w/r.out' && [ -z \"\$(git -C '$w/ck4' branch --list 'forge/*')\" ] && [ ! -e '$w/co-edited/steps/lib/pr.md' ]"
# a link where the artifact was
cp -r "$co" "$w/co-link" && rm "$w/co-link/steps/lib/ev/project.cho" && ln -s "$w/co/steps/lib/ev/project.cho" "$w/co-link/steps/lib/ev/project.cho"
"$F" company publish "$w/co-link" "$w/op4.json" lib forge/q > "$w/r.out" 2> /dev/null; rc=$?
check "an artifact that became a link: publish-artifact-changed" sh -c "[ '$rc' = 1 ] && grep -qx 'refusal: publish-artifact-changed' '$w/r.out'"
# the journal
cp -r "$co" "$w/co-nojournal" && rm "$w/co-nojournal/company.journal"
"$F" company publish "$w/co-nojournal" "$w/op4.json" lib forge/q > "$w/r.out" 2> /dev/null; rc=$?
check "no journal: publish-journal-unreadable" sh -c "[ '$rc' = 1 ] && grep -qx 'refusal: publish-journal-unreadable' '$w/r.out'"
cp -r "$co" "$w/co-corrupt" && printf 'garbage\n' >> "$w/co-corrupt/company.journal"
"$F" company publish "$w/co-corrupt" "$w/op4.json" lib forge/q > "$w/r.out" 2> /dev/null; rc=$?
check "a corrupt journal: journal-corrupt, nothing published" sh -c "[ '$rc' = 1 ] && grep -qx 'refusal: journal-corrupt' '$w/r.out' && [ -z \"\$(git -C '$w/ck4' branch --list 'forge/*')\" ]"
# usage and paths
"$F" company publish "$co" "$w/op4.json" lib > /dev/null 2>&1; rc=$?
check "too few arguments: usage, exit 2" sh -c "[ '$rc' = 2 ]"
"$F" company publish company "$w/op4.json" lib forge/q > "$w/r.out" 2> /dev/null; rc=$?
check "a relative company directory: path-invalid, exit 2" sh -c "[ '$rc' = 2 ] && grep -qx 'refusal: path-invalid' '$w/r.out'"
cp "$w/op4.json" "$co/op-inside.json"
"$F" company publish "$co" "$co/op-inside.json" lib forge/q > "$w/r.out" 2> /dev/null; rc=$?
check "an operator file inside the company directory: operator-invalid" sh -c "[ '$rc' = 1 ] && grep -qx 'refusal: operator-invalid' '$w/r.out'"
rm -f "$co/op-inside.json"
printf '{"workers":"%s","publish":{"lib":{"repo":"alpibrusl/cancho-diff","checkout":"relative","files":{"project.cho":"a.cho"}}}}' "$w/workers" > "$w/op-rel.json"
"$F" company publish "$co" "$w/op-rel.json" lib forge/q > "$w/r.out" 2> /dev/null; rc=$?
check "a publish entry of the wrong shape: operator-invalid" sh -c "[ '$rc' = 1 ] && grep -qx 'refusal: operator-invalid' '$w/r.out'"
printf '{"workers":"%s","commit_trailer":"a\\nb"}' "$w/workers" > "$w/op-nl.json"
"$F" company publish "$co" "$w/op-nl.json" lib forge/q > "$w/r.out" 2> /dev/null; rc=$?
check "a trailer with an escape (a line break): operator-invalid" sh -c "[ '$rc' = 1 ] && grep -qx 'refusal: operator-invalid' '$w/r.out'"

# ---- a trailer full of shell syntax is data, and the checkout's own commit hook does not run
mkrepo ck5 "$ORIGIN"
printf '#!/bin/sh\ntouch "%s/hook-ran"\nexit 0\n' "$w" > "$w/ck5/.git/hooks/pre-commit"; chmod +x "$w/ck5/.git/hooks/pre-commit"
printf '#!/bin/sh\ntouch "%s/hook-ran"\nexit 0\n' "$w" > "$w/ck5/.git/hooks/commit-msg"; chmod +x "$w/ck5/.git/hooks/commit-msg"
printf '#!/bin/sh\ntouch "%s/hook-ran"\nexit 0\n' "$w" > "$w/ck5/.git/hooks/post-commit"; chmod +x "$w/ck5/.git/hooks/post-commit"
HOSTILE='T: $(touch '"$w"'/trailer-ran); `touch '"$w"'/trailer-ran2`; x'
operator "$w/op5.json" "$w/ck5" alpibrusl/cancho-diff "$FILES" "$w/workers" "$HOSTILE"
"$F" company publish "$co" "$w/op5.json" lib forge/hostile > "$w/pub5.out" 2> /dev/null; rc=$?
check "hostile trailer and hooks: published (exit 0)" sh -c "[ '$rc' = 0 ]"
check "hostile trailer: it is in the message as text and no command ran" sh -c "git -C '$w/ck5' log -1 --format=%B forge/hostile | grep -qF 'touch $w/trailer-ran' && [ ! -e '$w/trailer-ran' ] && [ ! -e '$w/trailer-ran2' ]"
check "the checkout's commit hooks did not run" sh -c "[ ! -e '$w/hook-ran' ]"

# ---- a detached checkout goes back to where it was
mkrepo ck6 "$ORIGIN"
git -C "$w/ck6" checkout -q --detach
head6=$(git -C "$w/ck6" rev-parse HEAD)
operator "$w/op6.json" "$w/ck6" alpibrusl/cancho-diff "$FILES" "$w/workers" ""
"$F" company publish "$co" "$w/op6.json" lib forge/detached > /dev/null 2>&1; rc=$?
check "a detached checkout: published, and HEAD is back on the commit it was at" sh -c "[ '$rc' = 0 ] && [ \"\$(git -C '$w/ck6' rev-parse HEAD)\" = '$head6' ] && git -C '$w/ck6' rev-parse --verify --quiet forge/detached > /dev/null"

if [ "$fail" -eq 0 ]; then echo "repo publish: all held"; fi
exit "$fail"
