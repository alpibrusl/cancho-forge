#!/bin/sh
# Spike R-2 (docs/reviewer.md section 6, step 2): the authority worker with the REAL compiler against real commits. A throw-away clone of this repository gets
# four commits made here, each a real edit of a real program, and the worker (workers/authority_review.cho) is asked, with the compiler in $CANCHO, about each:
#   benign   a comment added to src/main.cho                                   base = the clone's HEAD, head = the commit            -> equal
#   widen    src/main.cho opens a UDP socket (a label the ceiling lacks)       base = HEAD, head = the commit                        -> wider
#   cheat    the same, and docs/authority.txt edited to allow it, one patch    base = HEAD, head = the commit                        -> wider (the base's ceiling is read)
#   narrow   the ceiling at the base lists a label the program does not use    base = a commit that adds it, head = a commit after   -> narrower
# The oracle is the reply and report.json, read with grep; the compiler is not mocked. The clone's programs are compiled by the compiler only for their authority report.
# Usage: CANCHO=/abs/path/to/cancho spike/r2_check.sh <scratch directory, empty, a path with no component that starts with a dash>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
root=$(pwd)
w=$1
fail=0
ok() { echo "ok   r2: $1"; }
bad() { echo "FAIL r2: $1"; fail=1; }
libs=$(ls src/*.cho | grep -v '/main\.cho$')
case "$C" in /*) ;; *) C=$(command -v "$C") ;; esac
$C build workers/authority_review.cho $libs --std -o "$w/worker" || { echo "FAIL r2: the worker did not build"; exit 1; }
git clone -q "$root" "$w/repo" || { echo "FAIL r2: clone"; exit 1; }
git_in() { git -C "$w/repo" -c user.email=forge@example.invalid -c user.name=forge -c commit.gpgsign=false "$@"; }
branch=$(git -C "$w/repo" symbolic-ref --short HEAD)
head0=$(git -C "$w/repo" rev-parse HEAD)
cat > "$w/socket.txt" <<'BLOCK'
    borrow net as &nb in {
        match udp_bind(nb, 0, 0) {
            UdpOpened::Failed(e) => {
            }
            UdpOpened::Ok(opened) => {
                udp_close(opened);
            }
        }
    }
    release(net);
BLOCK
widen() { awk -v bf="$w/socket.txt" '{ if ($0 == "    release(net);") { while ((getline l < bf) > 0) print l } else print }' "$w/repo/src/main.cho" > "$w/main.new" && cp "$w/main.new" "$w/repo/src/main.cho"; }
commit() { git_in add -A && git_in commit -q -m "$1" && git -C "$w/repo" rev-parse HEAD; }
# benign
printf '\n// a comment, and nothing else\n' >> "$w/repo/src/main.cho"; benign=$(commit benign)
git_in checkout -q -b widen "$head0"; widen; wide=$(commit widen)
git_in checkout -q -b cheat "$head0"; widen
# the cheat edits the ceiling to allow whatever the compiler reports: the report's own text, with its unbounded marks
(cd "$w/repo" && $C authority src/*.cho --std | sed -n '/^performs/,/^provably/p' | sed '$d' > docs/authority.txt); cheat=$(commit cheat)
git_in checkout -q "$branch"
# narrow: the ceiling gains a label the program does not use (one commit), then an empty commit
awk '{print} $0=="performs"{print "    tty"}' "$w/repo/docs/authority.txt" > "$w/auth.new" && cp "$w/auth.new" "$w/repo/docs/authority.txt"; ceil=$(commit ceiling); after=$(git_in commit -q --allow-empty -m after && git -C "$w/repo" rev-parse HEAD)
request() { # name head base
  mkdir "$w/ev_$1" || exit 1
  printf '{"contract":"forge-worker/1","verb":"execute","request_id":"r-%s","task":{"id":"t-%s","type":"repo.authority","input":{"repo":"alpibrusl/cancho-forge","revision":"%s","base":"%s","ceiling":"docs/authority.txt","programs":["src/*.cho"],"std":true}},"grants":{"workspace":"%s","execution_dir":"%s","compiler":"%s"},"limits":{"timeout_ms":300000}}' "$1" "$1" "$2" "$3" "$w/repo" "$w/ev_$1" "$C"
}
verdict() { # name head base want
  request "$1" "$2" "$3" | "$w/worker" > "$w/reply_$1"
  if grep -q '"state":"succeeded"' "$w/reply_$1" && grep -q "\"verdict\":\"$4\"" "$w/ev_$1/report.json"; then ok "$1 -> $4"; else bad "$1: wanted $4: $(cat "$w/reply_$1" | cut -c1-300) $(cat "$w/ev_$1/report.json" 2> /dev/null)"; fi
}
verdict benign "$benign" "$head0" equal
verdict widen "$wide" "$head0" wider
verdict cheat "$cheat" "$head0" wider
verdict narrow "$after" "$ceil" narrower
grep -q 'net_in' "$w/ev_widen/head.txt" && ok "widen: head.txt is the compiler's real report and names net_in" || bad "widen: head.txt does not name net_in"
[ ! -e "$w/ev_widen/tree" ] && ok "widen: the exported tree is gone" || bad "widen: the exported tree is left"
[ "$(git -C "$w/repo" rev-parse HEAD)" = "$after" ] && [ -z "$(git -C "$w/repo" status --porcelain)" ] && ok "the repository's HEAD and tree were not moved by four reviews" || bad "the repository was changed"
exit $fail
