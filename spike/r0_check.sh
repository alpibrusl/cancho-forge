#!/bin/sh
# Spike R-0 (docs/reviewer.md section 6): does `authority_review.compare` tell equal, narrower and wider apart on this repository's real authority reports?
# Usage: CANCHO=path/to/cancho spike/r0_check.sh <scratch directory, empty>
# The heads are what the compiler reports now for each checked-in ceiling; the mutations are made with sed and sort, outside cancho, so the oracle is not the code under test.
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
root=$(pwd)
w=$1
fail=0
ok() { echo "ok   r0: $1"; }
bad() { echo "FAIL r0: $1"; fail=1; }
libs=$(ls src/*.cho | grep -v '/main\.cho$')
if ! $C build spike/r0_compare.cho $libs --std -o "$w/r0"; then echo "FAIL r0: did not build"; exit 1; fi
report() { $C authority "$@" --std | sed -n '/^performs/,/^provably/p' | sed '$d'; }
want() { # want <name> <expected code> <ceiling> <head>
  got=$("$w/r0" "$3" "$4")
  if [ "$got" = "$2" ]; then ok "$1 -> $2"; else bad "$1: wanted $2, got $got"; fi
}
report src/*.cho > "$w/main.txt"
report workers/repo_publish.cho $libs > "$w/publish.txt"
report workers/check_guard.cho $libs > "$w/guard.txt"
for pair in "authority:main" "authority-repo-publish:publish" "authority-check-guard:guard"; do
  ceil="$root/docs/${pair%%:*}.txt"; head="$w/${pair##*:}.txt"
  want "$ceil against the compiler's report now" 0 "$ceil" "$head"
  # a label added: one more line under performs
  sed '/^performs/a\
    net' "$head" > "$w/added.txt"
  want "$ceil with a label added" 2 "$ceil" "$w/added.txt"
  # a label removed: the first label under performs
  sed '2d' "$head" > "$w/removed.txt"
  want "$ceil with its first label removed" 1 "$ceil" "$w/removed.txt"
  # a guarantee lost: the last line of the report (under never touches)
  sed '$d' "$head" > "$w/lost.txt"
  want "$ceil with a guarantee lost" 2 "$ceil" "$w/lost.txt"
  # 20 reorderings of the lines under each section: the verdict must stay equal
  n=0; bad_n=0
  while [ $n -lt 20 ]; do
    # each section keeps its header on top; its body lines are put in random order
    awk -v s=$n 'BEGIN{srand(s)} function flush(  i,k,t,m){ m=cnt; for(i=m;i>1;i--){k=int(rand()*i)+1;t=body[i];body[i]=body[k];body[k]=t} for(i=1;i<=m;i++)print body[i]; cnt=0 } /^[a-z]/{flush(); print; next} {body[++cnt]=$0} END{flush()}' "$head" > "$w/shuf.txt"
    got=$("$w/r0" "$ceil" "$w/shuf.txt")
    [ "$got" = 0 ] || bad_n=$((bad_n + 1))
    n=$((n + 1))
  done
  if [ $bad_n -eq 0 ]; then ok "$ceil: 20 reorderings, no false wider"; else bad "$ceil: $bad_n of 20 reorderings were not equal"; fi
done
# a missing ceiling and an unreadable head
: > "$w/empty.txt"
want "an empty ceiling" 3 "$w/empty.txt" "$w/main.txt"
want "an empty head" 4 "$root/docs/authority.txt" "$w/empty.txt"
exit $fail
