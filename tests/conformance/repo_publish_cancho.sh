#!/bin/sh
# A repository kept by `cancho vcs` through a company, end to end (docs/repo-vcs.md section 7). The programs under test are the forge binary and the
# real workers `repo_change`, `repo_publish` and `authority_review`; this script is the oracle only. The repository is a throw-away one made here by
# `cancho vcs init` and `record`; no `git` keeps anything (git is used once, by this oracle, to read what `cancho vcs export-git` rendered). The build
# tool is a stand-in written below (no model, no network, no key): `good` appends a comment to `src/a.cho`, `bad` a line that does not check.
#
# The change step on such a checkout (a base and a tree of 64 digits, the checkout untouched); `forge company publish` (a branch at a change whose
# parent is the base, the intent recorded, the checkout back where it was, nothing exported or pushed); one case per refusal the publish has on this
# kind (publish-branch-exists, publish-checkout-dirty, patch-base-stale, publish-gate-failed); `repo.publish` and `repo.authority` as steps
# with no command of a person between; a publish whose journal record was lost, adopted, and a branch of the same name that is not ours, left alone;
# the worker's own refusals; a row whose checker is not the compiler.
# Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
# Usage: CANCHO=path/to/cancho tests/conformance/repo_publish_cancho.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../.." || exit 1
scratch=$1
fail=0
libs=$(ls src/*.cho | grep -v '/main\.cho$')
w="$scratch/pc"
mkdir "$w" "$w/workers" "$w/tools" || exit 1
w=$(cd "$w" && pwd -P)
if ! { $C build src/*.cho --std -o "$w/forge" && $C build workers/repo_change.cho $libs --std -o "$w/workers/repo_change" && $C build workers/check_guard.cho $libs --std -o "$w/workers/check_guard" && $C build workers/repo_publish.cho $libs --std -o "$w/workers/repo_publish" && $C build workers/authority_review.cho $libs --std -o "$w/workers/authority_review"; }; then
  echo "FAIL publish cancho: a program did not build"
  exit 1
fi
F="$w/forge"
ok() { echo "ok   publish cancho: $1"; }
bad() { echo "FAIL publish cancho: $1"; fail=1; }
check() { # name, command...
  name=$1; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
# The compiler, by its absolute path: the operator's checker and the row's compiler. The tasks start `cancho` from its directory.
cc="$(cd "$(dirname "$(command -v "$C")")" && pwd -P)/cancho"
[ -x "$cc" ] || { echo "FAIL publish cancho: the compiler is not a file named cancho ($cc)"; exit 1; }
REV=f4ead824f33b291a0ad7620a34a0c1346a7abe4f
cv() { d=$1; shift; (cd "$d" && "$cc" vcs "$@" --output json); }
field() { sed -n "s/^  \"$1\": \"\\(.*\\)\",\\{0,1\\}\$/\\1/p"; }
head_of() { cv "$1" status | field head; }
on_branch() { cv "$1" status | field branch; }
clean() { cv "$1" status | grep -q '^  "clean": true'; }
branch_at() { cv "$1" branch list | awk -v n="\"name\": \"$2\"" '/"change": "/ { c = $2; gsub(/[^0-9a-f]/, "", c) } index($0, n) { print c }'; }
branches() { cv "$1" branch list | grep -c '"name": '; }

cat > "$w/tools/cancho-build" <<'EOT'
#!/bin/sh
repo= change= work=
prev=
for a in "$@"; do
  case "$prev" in
    --repo) repo=$a ;;
    --change) change=$a ;;
    --work) work=$a ;;
  esac
  prev=$a
done
[ -n "$repo" ] && [ -n "$change" ] && [ -n "$work" ] || exit 2
read -r mode arg < "$change"
mkdir -p "$work" || exit 2
rm -rf "$work/base" "$work/tree"; cp -r "$repo" "$work/base"; cp -r "$repo" "$work/tree"
case "$mode" in
  good) printf '// edited\n' >> "$work/tree/src/a.cho" ;;
  bad)  printf 'fn broken( -> {\n' >> "$work/tree/src/a.cho" ;;
  *)    exit 2 ;;
esac
(cd "$work" && diff -ruN base tree > change.patch)
printf '[CHANGE_PATCH]\t%s/change.patch\n[CHANGE_VERDICT]\tdone\n' "$work"
exit 0
EOT
chmod +x "$w/tools/cancho-build"

mkrepo() { # name: a program that checks (it imports nothing: docs/repo-vcs.md section 7 on the gate and `std`), the report of its authority as the ceiling, one change on `main`
  d="$w/$1"
  mkdir -p "$d/src" "$d/docs" "$d/scripts" || exit 1
  cat > "$d/src/a.cho" <<'EOT'
edition 9;

fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock, signals, exec, tty } = split(world);
    release(ffi);
    release(fs);
    release(heap);
    release(args);
    release(net);
    release(clock);
    release(signals);
    release(exec);
    release(tty);
    var console = io;
    var c = 0;
    borrow mut console as &!i in {
        c = getchar(i);
    }
    release(console);
    return 0;
}
EOT
  printf 'readme\n' > "$d/README.md"; printf '%s\n' "$REV" > "$d/.cancho-rev"
  printf '#!/bin/sh\nexit 0\n' > "$d/scripts/gate.sh"; chmod +x "$d/scripts/gate.sh"
  (cd "$d" && "$cc" authority src/a.cho --std | awk '/^performs/ { p = 1 } /^provably/ { p = 0 } p' > docs/authority.txt)
  [ -s "$d/docs/authority.txt" ] || { echo "FAIL publish cancho: no authority report for the fixture"; exit 1; }
  cv "$d" init > /dev/null && cv "$d" record --all --time 1 > /dev/null || { echo "FAIL publish cancho: no cancho vcs repository"; exit 1; }
}
operator() { # name, checkout, [extra top-level fields], [checker]
  printf '{"workers":"%s","tools":"%s","checker":"%s","agent":"stand-in-agent","check_timeout_ms":30000,"build_timeout_ms":10000%s,"repos":{"diff":{"kind":"library","vcs":"cancho","slug":"alpibrusl/cancho-diff","checkout":"%s","compiler_rev":"%s","publish_allow":["src/**"],"max_patch_files":3,"max_patch_lines":9,"compiler":"%s","authority":[{"programs":["src/*.cho"],"std":true,"ceiling":"docs/authority.txt"}]}}}' \
    "$w/workers" "$w/tools" "${4:-$cc}" "${3:-}" "$2" "$REV" "$cc" > "$w/$1.json"
}
GRANT=',"auto_publish":{"diff":{"branch_prefix":"forge/"}}'
mkco() { # name, input of the step chg: a change, its publish and its authority review
  co="$w/$1"
  mkdir -p "$co/steps/chg/ev" "$co/steps/pub/ev" "$co/steps/rev/ev" || exit 1
  printf '{"id":"co","mission":"m","model":{"provider":"stand","name":"m1"},"budget":{"input":100000,"output":100000,"cache_write":100000,"cache_read":100000,"max_cost":10,"price_table":"prices.json"},"human_gates":["go"],"roles":["builder","reviewer"],"repos":[{"id":"diff","kind":"library"}],"steps":[{"id":"chg","role":"builder","task_type":"repo.change","needs":[],"input":"%s","check":"audit_change.sh","repo":"diff","change_kind":"bug"},{"id":"pub","role":"system","task_type":"repo.publish","needs":["chg"],"input":"publish"},{"id":"rev","role":"reviewer","task_type":"repo.authority","needs":["chg","pub"],"input":"review"}]}' "$2" > "$co/company.json"
  printf '{"_note":"test","stand":{"m1":{"in":1.0,"cache_write":1.0,"cache_read":1.0,"out":1.0}}}' > "$co/prices.json"
  cat > "$co/audit_change.sh" <<'EOT'
#!/bin/sh
t=$(mktemp -d) || { echo "TOTAL 0/2"; exit 1; }
cp -r "$2/fresh/." "$t/"
a=0; b=0
if (cd "$t" && patch -p1 -s -i "$1") > /dev/null 2>&1; then a=1; fi
if [ $a = 1 ] && (cd "$t" && sh scripts/gate.sh) > /dev/null 2>&1; then b=1; fi
rm -rf "$t"
echo "TOTAL $((a + b))/2"
EOT
  chmod +x "$co/audit_change.sh"
}
run() { "$F" company run "$1" "$2" > "$w/out" 2> "$w/err"; echo $? > "$w/rc"; }
publish() { "$F" company publish "$1" "$2" chg "$3" > "$w/out" 2> "$w/err"; echo $? > "$w/rc"; }
rc() { cat "$w/rc"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', wanted '$3'"; fi; }

# ---- the row -----------------------------------------------------------------------------------------------------------------------------------
mkrepo ck1; mkco co1 good
operator op-notcancho "$w/ck1" "" /opt/tools/checker
run "$w/co1" "$w/op-notcancho.json"
check "row: a checker that is not a file named cancho is operator-invalid, with the reason, and nothing is admitted" sh -c "[ \$(cat '$w/rc') != 0 ] && grep -qx 'refusal: operator-invalid' '$w/out' && grep -q \"reason: repos: vcs is cancho, and the operator file's checker is not\" '$w/out' && [ ! -s '$w/co1/company.journal' ]"

# ---- the change step on a checkout kept by cancho vcs ------------------------------------------------------------------------------------------
operator op1 "$w/ck1"
base=$(head_of "$w/ck1"); home=$(on_branch "$w/ck1")
tree=$(cv "$w/ck1" show "$base" | field tree)
run "$w/co1" "$w/op1.json"
check "change: the step is accepted; the publish step has no grant, so the run stops there (publish-auto-not-granted, exit 1)" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'accepted: chg' '$w/out' && grep -qx 'refusal: publish-auto-not-granted' '$w/out'"
is "change: a revision of the checkout is a change id of 64 digits" "${#base} ${#tree}" "64 64"
check "change: the journal names the base change and its tree" sh -c "grep 'company.step.change' '$w/co1/company.journal' | grep -q '\"repo\":\"diff\",\"base\":\"$base\",\"tree\":\"$tree\"'"
check "change: the patch adds the stand-in's line" grep -q '^+// edited' "$w/co1/steps/chg/ev/change.patch"
check "change: the fresh copy is the tracked files, with nothing of the store" sh -c "cmp -s '$w/ck1/src/a.cho' '$w/co1/steps/chg/ev/fresh/src/a.cho' && [ ! -e '$w/co1/steps/chg/ev/fresh/.cancho' ]"
is "change: the checkout is the change it was, on its branch" "$(head_of "$w/ck1") $(on_branch "$w/ck1") $(branches "$w/ck1")" "$base $home 1"
check "change: and clean, with no .git" sh -c "[ ! -e '$w/ck1/.git' ]" && check "change: clean" clean "$w/ck1"

# ---- forge company publish ------------------------------------------------------------------------------------------------------------------------
publish "$w/co1" "$w/op1.json" forge/person
change=$(sed -n 's/^commit: //p' "$w/out")
check "publish: exit 0, the branch and a change id of 64 digits" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'published: forge/person' '$w/out' && [ ${#change} = 64 ]"
is "publish: the branch is at that change" "$(branch_at "$w/ck1" forge/person)" "$change"
cv "$w/ck1" show "$change" > "$w/show.json"
check "publish: its one parent is the base the patch was made against" sh -c "[ \"\$(sed -n '/^  \"parents\": \\[\$/,/^  \\]/p' '$w/show.json' | grep -c '\"[0-9a-f]\\{64\\}\"')\" = 1 ] && sed -n '/^  \"parents\": \\[\$/,/^  \\]/p' '$w/show.json' | grep -q '\"$base\"'"
check "publish: the intent is recorded: the message as the prompt, the company as the session, the step as the issue" sh -c "grep -q '\"session\": \"co\"' '$w/show.json' && grep -q '\"issue\": \"chg\"' '$w/show.json' && grep -q '\"prompt\": \"Apply the change of step chg, built by Forge' '$w/show.json'"
check "publish: the change touches the patch's file and the provenance, and nothing else" sh -c "[ \"\$(grep -c '\"path\": ' '$w/show.json')\" = 2 ] && grep -q '\"path\": \"src/a.cho\"' '$w/show.json' && grep -q '\"path\": \"docs/provenance/chg.md\"' '$w/show.json'"
check "publish: the gate of cancho vcs ran on it" grep -q 'gate:cancho-check:ok' "$w/show.json"
is "publish: the checkout is back on its branch at the base" "$(head_of "$w/ck1") $(on_branch "$w/ck1")" "$base $home"
check "publish: and clean, its file the one it was, no provenance in the working copy" sh -c "! grep -q edited '$w/ck1/src/a.cho' && [ ! -e '$w/ck1/docs/provenance' ]" && check "publish: clean" clean "$w/ck1"
check "publish: the journal records the branch and the change; pr.md says how the branch reaches GitHub" sh -c "grep company.step.published '$w/co1/company.journal' | grep -q '\"branch\":\"forge/person\",\"commit\":\"$change\"' && grep -q 'cancho vcs export-git' '$w/co1/steps/chg/pr.md'"
check "publish: nothing was exported or pushed: no .git in the checkout" sh -c "[ ! -e '$w/ck1/.git' ]"
# What a person does next, done here by the oracle: the export renders the branch as a git commit with the file, the provenance and the trailers.
if cv "$w/ck1" export-git "$w/x1" > /dev/null 2>&1; then
  check "export: the branch is a git commit that holds the patched file and the provenance" sh -c "git -C '$w/x1' show forge/person:src/a.cho | tail -1 | grep -qx '// edited' && git -C '$w/x1' show forge/person:docs/provenance/chg.md | grep -q '$base'"
  check "export: its message is the intent, with the change, the session and the issue as trailers" sh -c "git -C '$w/x1' log -1 --format=%B forge/person | grep -qx 'Cancho-Change: $change' && git -C '$w/x1' log -1 --format=%B forge/person | grep -qx 'Cancho-Session: co' && git -C '$w/x1' log -1 --format=%B forge/person | grep -qx 'Cancho-Issue: chg' && git -C '$w/x1' log -1 --format=%s forge/person | grep -q '^Apply the change of step chg'"
else
  bad "export: cancho vcs export-git failed"
fi
check "export: the checkout is still clean" clean "$w/ck1"

# ---- the refusals of the publish on this kind -------------------------------------------------------------------------------------------------------
publish "$w/co1" "$w/op1.json" forge/person
check "refusal: the same branch again is publish-branch-exists, exit 1" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'refusal: publish-branch-exists' '$w/out'"
is "refusal: and the branch is where it was" "$(branch_at "$w/ck1" forge/person)" "$change"
echo stray > "$w/ck1/stray.txt"
publish "$w/co1" "$w/op1.json" forge/second
check "refusal: an untracked file is publish-checkout-dirty, exit 1, no branch made" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'refusal: publish-checkout-dirty' '$w/out'"
is "refusal: no branch was made and the stray file is left" "$(branch_at "$w/ck1" forge/second) $(cat "$w/ck1/stray.txt")" " stray"
rm "$w/ck1/stray.txt"
echo more >> "$w/ck1/README.md"; cv "$w/ck1" record README.md --time 3 > /dev/null
publish "$w/co1" "$w/op1.json" forge/second
check "refusal: a checkout that moved on from the base is patch-base-stale, exit 1" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'refusal: patch-base-stale' '$w/out'"
is "refusal: no branch was made" "$(branch_at "$w/ck1" forge/second)$(branches "$w/ck1")" "2"

# ---- a tree the gate of cancho vcs refuses: the publish's own refusal ----------------------------------------------------------------------------------
mkrepo ckg; mkco cog bad; operator opg "$w/ckg"
gbase=$(head_of "$w/ckg")
run "$w/cog" "$w/opg.json"
check "gate: the step's own check accepts the change (the repository's gate does not look at it)" grep -qx 'accepted: chg' "$w/out"
publish "$w/cog" "$w/opg.json" forge/broken
check "gate: the publish is refused publish-gate-failed, exit 1, with the compiler's rule in the reason" sh -c "[ \$(cat '$w/rc') = 1 ] && grep -qx 'refusal: publish-gate-failed' '$w/out' && grep -q '^reason: the gate of cancho vcs refused the change: a file of it does not check ([a-z-]*)\$' '$w/out'"
is "gate: undone: no branch, the checkout on its branch at the base" "$(branches "$w/ckg") $(head_of "$w/ckg") $(on_branch "$w/ckg")" "1 $gbase main"
check "gate: the file is the one it was, no provenance, nothing published in the journal" sh -c "! grep -q broken '$w/ckg/src/a.cho' && [ ! -e '$w/ckg/docs/provenance' ] && ! grep -q company.step.published '$w/cog/company.journal'" && check "gate: clean" clean "$w/ckg"

# ---- repo.publish and repo.authority as steps: no command of a person between ------------------------------------------------------------------------
mkrepo cka; mkco coa good; operator opa "$w/cka" "$GRANT"
abase=$(head_of "$w/cka")
run "$w/coa" "$w/opa.json"
check "steps: the change, its publish and the authority review are accepted in one run" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'accepted: chg' '$w/out' && grep -qx 'accepted: pub' '$w/out' && grep -qx 'accepted: rev' '$w/out' && grep -qx 'done: steps accepted 3' '$w/out'"
achange=$(branch_at "$w/cka" forge/co-chg)
check "steps: publish.txt names the branch and its change, 64 digits" sh -c "grep -qx 'branch forge/co-chg' '$w/coa/steps/pub/ev/publish.txt' && grep -qx 'commit $achange' '$w/coa/steps/pub/ev/publish.txt' && [ ${#achange} = 64 ]"
check "steps: the authority worker read the change and its base from the store: verdict equal, the head report from the change's tree" sh -c "grep -qx 'verdict: equal' '$w/out' && grep -q '\"verdict\":\"equal\"' '$w/coa/steps/rev/ev/authority-0/report.json' && cmp -s '$w/cka/docs/authority.txt' '$w/coa/steps/rev/ev/authority-0/ceiling.txt'"
is "steps: the checkout is on its branch at the base" "$(head_of "$w/cka") $(on_branch "$w/cka") $(branches "$w/cka")" "$abase main 2"
check "steps: clean" clean "$w/cka"
run "$w/coa" "$w/opa.json"
check "steps: a second run publishes nothing again" sh -c "[ \$(grep -c company.step.published '$w/coa/company.journal' | tr -d ' ') = 1 ]"
is "steps: the branch is where it was" "$(branch_at "$w/cka" forge/co-chg)" "$achange"

# ---- a publish whose journal record was lost (docs/auto-publish.md section 4) ----------------------------------------------------------------------
mkcr() { # n: a checkout and a company with the change accepted and nothing published
  mkrepo ckr$1; mkco cor$1 good; operator opr$1 "$w/ckr$1" "$GRANT"; operator oprno$1 "$w/ckr$1"
  run "$w/cor$1" "$w/oprno$1.json"
}
mkcr 1
publish "$w/cor1" "$w/opr1.json" forge/co-chg
crash=$(sed -n 's/^commit: //p' "$w/out")
sed '$d' "$w/cor1/company.journal" > "$w/j.tmp" && mv "$w/j.tmp" "$w/cor1/company.journal"
check "crash: the branch has the change and the journal has lost its record" sh -c "[ ${#crash} = 64 ] && ! grep -q company.step.published '$w/cor1/company.journal'"
run "$w/cor1" "$w/opr1.json"
check "crash: a branch that is what the publish would make is adopted: pub and rev accepted, done" sh -c "[ \$(cat '$w/rc') = 0 ] && grep -qx 'accepted: pub' '$w/out' && grep -qx 'accepted: rev' '$w/out' && grep -qx 'done: steps accepted 3' '$w/out'"
check "crash: the journal records the change the branch already had, once" sh -c "[ \$(grep -c company.step.published '$w/cor1/company.journal' | tr -d ' ') = 1 ] && grep company.step.published '$w/cor1/company.journal' | grep -q '\"branch\":\"forge/co-chg\",\"commit\":\"$crash\"' && grep -qx 'commit $crash' '$w/cor1/steps/pub/ev/publish.txt'"
is "crash: no second change and no second branch; the checkout on its branch" "$(branch_at "$w/ckr1" forge/co-chg) $(branches "$w/ckr1") $(on_branch "$w/ckr1")" "$crash 2 main"
check "crash: clean, the file the one it was" sh -c "! grep -q edited '$w/ckr1/src/a.cho' && [ ! -e '$w/ckr1/docs/provenance' ]" && check "crash: clean" clean "$w/ckr1"
mkcr 2
rbase=$(head_of "$w/ckr2")
cv "$w/ckr2" branch create forge/co-chg > /dev/null
run "$w/cor2" "$w/opr2.json"
check "crash: a branch of the same name that is not ours is not adopted: held, exit 14, publish-branch-exists" sh -c "[ \$(cat '$w/rc') = 14 ] && grep -qx 'refusal: publish-branch-exists' '$w/out' && ! grep -q company.step.published '$w/cor2/company.journal'"
is "crash: and it is left alone, the checkout where it was" "$(branch_at "$w/ckr2" forge/co-chg) $(head_of "$w/ckr2") $(on_branch "$w/ckr2")" "$rbase $rbase main"
check "crash: clean, the file the one it was" sh -c "! grep -q edited '$w/ckr2/src/a.cho' && [ ! -e '$w/ckr2/docs/provenance' ]" && check "crash: clean" clean "$w/ckr2"

# ---- the worker checks its own request ---------------------------------------------------------------------------------------------------------------
req() { # vcs, compiler, base, session
  printf '{"checkout":"%s","repo":"alpibrusl/cancho-diff","branch":"forge/direct","src_dir":"%s","src_name":"change.patch","dest":"src/a.cho","sha256":"%s","patch_base":"%s","provenance_dest":"docs/provenance/chg.md","provenance":"p","message":"m","vcs":"%s","compiler":"%s","session":"%s","issue":"chg"}' \
    "$w/ckr2" "$w/cor2/steps/chg/ev" "$(sha256sum "$w/cor2/steps/chg/ev/change.patch" | cut -c1-64)" "$3" "$1" "$2" "$4"
}
req svn "$cc" "$rbase" co | "$w/workers/repo_publish" > "$w/reply"
check "worker: a version control that is not git or cancho is publish-worker-failed" grep -q '"ok":false,"rule":"publish-worker-failed"' "$w/reply"
req cancho /opt/tools/checker "$rbase" co | "$w/workers/repo_publish" > "$w/reply"
check "worker: a compiler that is not a file named cancho is publish-worker-failed" grep -q '"ok":false,"rule":"publish-worker-failed"' "$w/reply"
req cancho "$cc" "$rbase" 'co;id' | "$w/workers/repo_publish" > "$w/reply"
check "worker: a session that is not a plain name is publish-worker-failed" grep -q '"ok":false,"rule":"publish-worker-failed"' "$w/reply"
req cancho "$cc" 0123456789abcdef0123456789abcdef01234567 co | "$w/workers/repo_publish" > "$w/reply"
check "worker: a base of 40 digits for cancho vcs is publish-dest-invalid" grep -q '"ok":false,"rule":"publish-dest-invalid"' "$w/reply"
req cancho "$w/nowhere/cancho" "$rbase" co | "$w/workers/repo_publish" > "$w/reply"
check "worker: a compiler that is not there is publish-checkout-invalid" grep -q '"ok":false,"rule":"publish-checkout-invalid"' "$w/reply"
is "worker: none of them made a branch or touched the checkout" "$(branch_at "$w/ckr2" forge/direct)$(head_of "$w/ckr2") $(on_branch "$w/ckr2")" "$rbase main"
req cancho "$cc" "$rbase" co | "$w/workers/repo_publish" > "$w/reply"
direct=$(branch_at "$w/ckr2" forge/direct)
check "worker: and the request as Forge writes it is answered with the change the branch is at" sh -c "[ ${#direct} = 64 ] && grep -qx '{\"ok\":true,\"commit\":\"$direct\"}' '$w/reply'"
exit $fail
