#!/bin/sh
# Spike S13 (issue #35): what happens when two Cancho Code adapters are started on one execution directory, the second while
# the first build still runs. Measures; asserts nothing. The adapter is the product (workers/cancho_code.cho); this script
# only starts it twice and looks at the files and the process table from outside, as a test oracle does.
# Usage: spike/s13_two_builds.sh <adapter binary> <scratch directory, empty, no component starting with - or .>
# The stand-in build tool is scripts/standin_cancho_build.sh (its `slow` mode waits for a file `release`).
set -u
adapter=$1
d=$2
cd "$(dirname "$0")/.." || exit 1
mkdir "$d/tools" "$d/ev" || exit 1
cp scripts/standin_cancho_build.sh "$d/tools/cancho-build" && chmod +x "$d/tools/cancho-build" || exit 1

request() { # brief-json-string, out file
  printf '{"contract":"forge-worker/1","verb":"execute","request_id":"r-1","attempt":1,"task":{"id":"t-1","type":"project.build","input":{"brief":%s}},"limits":{"timeout_ms":60000,"max_output_bytes":1048576},"grants":{"execution_dir":"%s/ev","tools_dir":"%s/tools","build":{"checker":"/opt/cancho/bin/cancho","agent":"stand-in-agent","provider":"stand","model":"m1"}}}' "$1" "$d" "$d" > "$2"
}
request '"slow\nfirst"' "$d/req_a"
request '"slow\nsecond"' "$d/req_b"

"$adapter" < "$d/req_a" > "$d/ans_a" 2> "$d/err_a" &
pa=$!
i=0; while [ ! -e "$d/ev/pids.txt" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
echo "first build started: $(wc -l < "$d/ev/pids.txt") build process(es) so far"
( cd "$d/ev" && cksum brief.txt seen_brief.txt build.json run.log pids.txt 2>&1 | sed 's/^/  before B: /' )

"$adapter" < "$d/req_b" > "$d/ans_b" 2> "$d/err_b" &
pb=$!
sleep 1.5
( cd "$d/ev" && cksum brief.txt seen_brief.txt build.json run.log pids.txt 2>&1 | sed 's/^/  after B started: /' )
echo "builds running now: $(pgrep -f '[c]ancho-build' | wc -l); adapters running: $(pgrep -x cancho_code | wc -l)"
echo "brief.txt now says: $(sed -n 2p "$d/ev/brief.txt")  (A's brief is 'first')"
echo "pids.txt (one line per build that read a brief): $(wc -l < "$d/ev/pids.txt")"

touch "$d/ev/release"
wait "$pa"; ra=$?
wait "$pb"; rb=$?
echo "adapter A exit $ra, B exit $rb"
echo "A answered: $(cat "$d/ans_a" | sed 's/"evidence":\[.*\],"error"/"evidence":[...],"error"/' | cut -c1-300)"
echo "B answered: $(cat "$d/ans_b" | sed 's/"evidence":\[.*\],"error"/"evidence":[...],"error"/' | cut -c1-300)"
echo "final project.cho: $(cat "$d/ev/project.cho" 2>/dev/null)"
echo "final build.out: $(cat "$d/ev/build.out")"
echo "files: $(ls "$d/ev" | tr '\n' ' ')"

# ---- the same, through `forge build` with a workspace each (the lock of Forge is a file of the workspace, not of the
# execution directory): only when a forge binary is given as the third argument.
if [ $# -ge 3 ]; then
  forge=$3
  echo "== two forge build commands, two workspaces, one execution directory"
  mkdir "$d/w1" "$d/w2" "$d/ev2" "$d/workers" || exit 1
  cp "$adapter" "$d/workers/cancho_code"
  printf 'slow\nfirst' > "$d/b1"; printf 'slow\nsecond' > "$d/b2"
  "$forge" build "$d/w1" "$d/workers" "$d/tools" "$d/b1" "$d/ev2" /opt/cancho/bin/cancho stand m1 a 60000 > "$d/f1.out" 2>&1 &
  p1=$!
  i=0; while [ ! -e "$d/ev2/pids.txt" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  "$forge" build "$d/w2" "$d/workers" "$d/tools" "$d/b2" "$d/ev2" /opt/cancho/bin/cancho stand m1 a 60000 > "$d/f2.out" 2>&1 &
  p2=$!
  sleep 1.5
  echo "builds running with two workspaces: $(pgrep -f '[c]ancho-build' | wc -l); brief.txt says: $(sed -n 2p "$d/ev2/brief.txt")"
  touch "$d/ev2/release"
  wait "$p1"; r1=$?; wait "$p2"; r2=$?
  echo "forge build exit codes: $r1 and $r2; states: $(grep -h '^state:' "$d/f1.out" "$d/f2.out" | tr '\n' ' ')"
fi
