#!/bin/sh
# The repository layer (src/repo_vcs.cho, docs/repo-vcs.md): each shell text of the layer is run against two real repositories that hold the same
# files, one kept by git and one by `cancho vcs`, and what the two kinds answer is compared. A regular file, an executable, a file in a
# directory, a name with a space and a link are in the tree. The git texts are the ones every task ran before the layer (the unit tests pin them
# byte for byte); this script is what says the cancho texts answer the same questions the same way.
#
# Usage: CANCHO=<compiler> sh tests/conformance/repo_vcs.sh <scratch dir>
# Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL or a build failed.
C=${CANCHO:-cancho}
w=$1
[ -n "$w" ] || { echo "usage: repo_vcs.sh <scratch dir>"; exit 2; }
fail=0
ok() { echo "ok   repo vcs: $1"; }
bad() { echo "FAIL repo vcs: $1"; fail=1; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', wanted '$3'"; fi; }

mkdir -p "$w" || exit 1
w=$(cd "$w" && pwd -P)
if ! $C build tests/conformance/repo_vcs.cho src/repo_vcs.cho --std -o "$w/print"; then echo "FAIL repo vcs: the printer did not build"; exit 1; fi
# The texts start `cancho` by name, as they start `git`: the compiler under test is the one on the PATH here.
bin=$(cd "$(dirname "$(command -v "$C")")" && pwd -P)
PATH="$bin:$PATH"; export PATH

fill() { # the same files in the directory $1
  mkdir -p "$1/sub/deep" && printf 'one\ntwo\n' > "$1/a.txt" && printf '#!/bin/sh\necho hi\n' > "$1/sub/run.sh" && chmod 755 "$1/sub/run.sh" \
    && printf 'deep\n' > "$1/sub/deep/with space.txt" && printf 'the ceiling\n' > "$1/sub/ceiling.txt" && ln -s a.txt "$1/link"
}
g=$w/g; c=$w/c
rm -rf "$g" "$c"; mkdir "$g" "$c"; fill "$g"; fill "$c"
( cd "$g" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q -m one ) || { echo "FAIL repo vcs: no git repository"; exit 1; }
( cd "$c" && cancho vcs init --output json > /dev/null && cancho vcs record --all --time 1 --output json > /dev/null ) || { echo "FAIL repo vcs: no cancho repository"; exit 1; }
# A second change in each, so that a revision that is not the head can be asked for.
grev1=$(cd "$g" && git rev-parse HEAD)
crev1=$(sed -n '1p' "$c/.cancho/vcs/refs/heads/main")
printf 'the ceiling, raised\n' > "$g/sub/ceiling.txt"; printf 'the ceiling, raised\n' > "$c/sub/ceiling.txt"
( cd "$g" && git add -A && git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q -m two )
( cd "$c" && cancho vcs record --all --time 2 --output json > /dev/null )
grev2=$(cd "$g" && git rev-parse HEAD)
crev2=$(sed -n '1p' "$c/.cancho/vcs/refs/heads/main")

run() { # KIND OP ARGS...: the text printed and run by /bin/sh; its output in $w/out, its status in $st
  "$w/print" "$@" > "$w/text.sh" || { bad "no text for $*"; return; }
  /bin/sh -c "$(cat "$w/text.sh")" > "$w/out" 2>&1; st=$?
}

# ---- state: the head, its tree, clean or dirty --------------------------------------------------------------------------------------------
run git state "$g"; gs=$st; ghead=$(sed -n 1p "$w/out"); gclean=$(sed -n 3p "$w/out"); glines=$(wc -l < "$w/out" | tr -d ' ')
run cancho state "$c"; cs=$st; chead=$(sed -n 1p "$w/out"); ctree=$(sed -n 2p "$w/out"); cclean=$(sed -n 3p "$w/out"); clines=$(wc -l < "$w/out" | tr -d ' ')
is "state: both end 0" "$gs $cs" "0 0"
is "state: both print three lines" "$glines $clines" "3 3"
is "state: git's head is its commit" "$ghead" "$grev2"
is "state: cancho's head is its change" "$chead" "$crev2"
is "state: a change id is 64 digits and so is its tree" "${#chead} ${#ctree}" "64 64"
is "state: both are clean" "$gclean $cclean" "clean clean"
echo stray > "$g/stray.txt"; echo stray > "$c/stray.txt"
run git state "$g"; gclean=$(sed -n 3p "$w/out"); run cancho state "$c"; cclean=$(sed -n 3p "$w/out")
is "state: an untracked file makes both dirty" "$gclean $cclean" "dirty dirty"
rm "$g/stray.txt" "$c/stray.txt"
printf 'one\ntwo\nthree\n' > "$g/a.txt"; printf 'one\ntwo\nthree\n' > "$c/a.txt"
run git state "$g"; gclean=$(sed -n 3p "$w/out"); run cancho state "$c"; cclean=$(sed -n 3p "$w/out")
is "state: a modified file makes both dirty" "$gclean $cclean" "dirty dirty"
printf 'one\ntwo\n' > "$g/a.txt"; printf 'one\ntwo\n' > "$c/a.txt"
run git state "$w/nowhere"; gs=$st; run cancho state "$w/nowhere"; cs=$st
is "state: a checkout that is not there is 2 for both" "$gs $cs" "2 2"
mkdir -p "$w/empty"; run git state "$w/empty"; gs=$st; run cancho state "$w/empty"; cs=$st
is "state: a directory that is no repository is 3 for both" "$gs $cs" "3 3"

# ---- tracked: a copy of the tracked files, nothing of the store, nothing untracked ----------------------------------------------------------
echo stray > "$g/stray.txt"; echo stray > "$c/stray.txt"
mkdir -p "$w/evg" "$w/evc"
run git tracked "$g" "$w/evg" base; gs=$st; run cancho tracked "$c" "$w/evc" base; cs=$st
is "tracked: both end 0" "$gs $cs" "0 0"
if diff -r "$w/evg/base" "$w/evc/base" > "$w/diff.txt" 2>&1; then ok "tracked: the two copies hold the same files"; else bad "tracked: the copies differ: $(head -3 "$w/diff.txt" | tr '\n' ' ')"; fi
[ ! -e "$w/evc/base/stray.txt" ] && [ ! -e "$w/evc/base/.cancho" ] && ok "tracked: no untracked file and no store in the cancho copy" || bad "tracked: the cancho copy holds a stray file or the store"
[ -x "$w/evc/base/sub/run.sh" ] && [ -L "$w/evc/base/link" ] && [ -f "$w/evc/base/sub/deep/with space.txt" ] && ok "tracked: the executable, the link and the name with a space are there" || bad "tracked: a mode, the link or the spaced name is lost"
[ ! -e "$w/evc/tracked.lst" ] && [ ! -e "$w/evc/tracked.tar" ] && ok "tracked: the list and the tar are removed" || bad "tracked: the list or the tar is left"
rm "$g/stray.txt" "$c/stray.txt"

# ---- head -----------------------------------------------------------------------------------------------------------------------------------
run git head "$g"; gh=$(cat "$w/out"); run cancho head "$c"; ch=$(cat "$w/out"); cs=$st
is "head: git prints its commit" "$gh" "$grev2"
is "head: cancho prints its change" "$ch" "$crev2"
run cancho head "$w/empty"; [ "$st" != 0 ] && [ ! -s "$w/out" ] && ok "head: no repository is a failure and prints nothing" || bad "head: no repository ended $st and printed '$(cat "$w/out")'"

# ---- file: a file as it is at a revision ----------------------------------------------------------------------------------------------------
run git file "$g" "$grev1" sub/ceiling.txt; gs=$st; cp "$w/out" "$w/fg"; run cancho file "$c" "$crev1" sub/ceiling.txt; cs=$st; cp "$w/out" "$w/fc"
is "file: both end 0" "$gs $cs" "0 0"
cmp -s "$w/fg" "$w/fc" && is "file: the file at the earlier revision" "$(cat "$w/fc")" "the ceiling" || bad "file: the two kinds print different bytes"
run cancho file "$c" "$crev2" sub/ceiling.txt; is "file: the file at the head" "$(cat "$w/out")" "the ceiling, raised"
run cancho file "$c" "$crev2" "sub/deep/with space.txt"; is "file: a name with a space" "$(cat "$w/out")" "deep"
run git file "$g" "$grev2" sub/none.txt; gs=$st; run cancho file "$c" "$crev2" sub/none.txt; cs=$st
[ "$gs" != 0 ] && [ "$cs" != 0 ] && [ ! -s "$w/out" ] && ok "file: a file the revision does not have is a failure for both, with nothing printed" || bad "file: a missing file ended $gs and $cs"
run cancho file "$c" "$(printf '%064d' 0)" sub/ceiling.txt; [ "$st" != 0 ] && [ ! -s "$w/out" ] && ok "file: a revision the store does not have is a failure" || bad "file: an unknown revision ended $st"
run cancho file "$c" "$crev2" sub; [ "$st" != 0 ] && ok "file: a directory is not a file" || bad "file: a directory ended 0"

# ---- export: the tree of a revision beneath a directory ---------------------------------------------------------------------------------------
mkdir -p "$w/xg" "$w/xc"
run git export "$g" "$grev1" "$w/xg"; gs=$st; run cancho export "$c" "$crev1" "$w/xc"; cs=$st
is "export: both end 0" "$gs $cs" "0 0"
if diff -r "$w/xg/tree" "$w/xc/tree" > "$w/diff.txt" 2>&1; then ok "export: the two trees hold the same files"; else bad "export: the trees differ: $(head -3 "$w/diff.txt" | tr '\n' ' ')"; fi
is "export: it is the earlier revision's tree" "$(cat "$w/xc/tree/sub/ceiling.txt")" "the ceiling"
[ -x "$w/xc/tree/sub/run.sh" ] && [ ! -x "$w/xc/tree/a.txt" ] && [ -L "$w/xc/tree/link" ] && is "export: the modes and the link" "$(readlink "$w/xc/tree/link")" "a.txt" || bad "export: a mode or the link is lost"
[ ! -e "$w/xc/tree/.cancho" ] && ok "export: no store in the tree" || bad "export: the store is in the tree"
printf 'changed in the working copy\n' > "$c/a.txt"
run cancho export "$c" "$crev2" "$w/xc"; is "export: the tree is the revision's, not the working copy's" "$(cat "$w/xc/tree/a.txt" | tr '\n' ' ')" "one two "
is "export: a second export replaces the first" "$(cat "$w/xc/tree/sub/ceiling.txt")" "the ceiling, raised"
printf 'one\ntwo\n' > "$c/a.txt"
run cancho export "$c" "$(printf '%064d' 0)" "$w/xc"; [ "$st" != 0 ] && ok "export: a revision the store does not have is a failure" || bad "export: an unknown revision ended 0"
cmp -s "$c/a.txt" "$g/a.txt" && [ "$(sed -n '1p' "$c/.cancho/vcs/refs/heads/main")" = "$crev2" ] && ok "the checkout was read, never written" || bad "the checkout changed"

# ---- the command line of the printer --------------------------------------------------------------------------------------------------------
"$w/print" svn state "$c" > /dev/null 2>&1; is "an unknown kind is refused" "$?" "2"
"$w/print" cancho commit "$c" > /dev/null 2>&1; is "an unknown question is refused" "$?" "2"
exit $fail
