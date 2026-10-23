#!/bin/sh
# Re-runs every Milestone 0 spike and prints what it measured. The cancho
# programs are the product; this script only builds them, creates the data
# directory their `Fs`/`Exec` literals name, and looks at the outside world
# (cat, od, ps) the way a test oracle does. Usage: CANCHO=path/to/cancho ./run.sh
set -u
C="${CANCHO:-cancho}"
D=/tmp/cancho-forge-spike
cd "$(dirname "$0")" || exit 1
rm -rf "$D" && mkdir -p "$D/bin"

say() { printf '\n=== %s\n' "$*"; }

say "gate: fmt, check"
$C fmt --check .. && echo "fmt: ok"
for f in s1_capture s2_timeout_kill s3_narrow s4_json_event s5_journal s6_dispatch s7_grandchild s8_covers s9_under s10_symlink s11_runner s11_forge s12_detached_under s13_lock_inherit s14_supervise mock_worker; do
  $C check $f.cho --std && echo "check $f: ok"
done

say "S1 spawn + capture stdout under Exec(\"/bin\")"
$C run s1_capture.cho --std

say "S2 deadline, output bound, exit status, explicit kill"
$C run s2_timeout_kill.cho --std

say "S3 narrowed Exec: allowed spawns run, outside spawns trap"
$C build s3_narrow.cho --std -o "$D/s3" && $C authority s3_narrow.cho --std
for m in a b c d e; do
  printf -- '--- mode %s: ' "$m"; "$D/s3" $m; echo "exit=$?"
done 2>&1

say "S4 std.json: write, parse, refuse a task event"
$C run s4_json_event.cho --std

say "S5 journal: append+sync, torn tail, recovery, snapshot rename, lock"
$C build s5_journal.cho --std -o "$D/s5" || exit 1
"$D/s5" append;  echo "journal after append:"; cat "$D/journal.jsonl"
"$D/s5" tear;    echo "tail after torn write (od -c):"; tail -c 40 "$D/journal.jsonl" | od -c | head -3
"$D/s5" recover; echo "bytes now: $(wc -c < "$D/journal.jsonl")"
"$D/s5" recover
"$D/s5" append2; "$D/s5" recover
echo "--- duplicate seq must be refused, file untouched"
"$D/s5" append;  before=$(wc -c < "$D/journal.jsonl"); "$D/s5" recover; echo "bytes before/after: $before/$(wc -c < "$D/journal.jsonl")"
echo '{"last_seq":0}' > "$D/snapshot.json"
"$D/s5" snapshot-torn; echo "snapshot.json still: $(cat "$D/snapshot.json")"; ls "$D"
"$D/s5" snapshot;      echo "snapshot.json now:   $(cat "$D/snapshot.json")"; ls "$D"
"$D/s5" lock

say "S6 worker round trip (mock worker over stdio)"
$C build mock_worker.cho --std -o "$D/bin/mock_worker" && $C run s6_dispatch.cho --std
$C authority mock_worker.cho --std | sed -n 1,6p
$C authority s6_dispatch.cho --std | sed -n 1,10p

say "S7 what a kill reaches (grandchild 'sleep 77'); no /bin/kill, no exec(\"/bin\")"
$C build s7_grandchild.cho --std -o "$D/s7" || exit 1
$C authority s7_grandchild.cho --std | sed -n '/^performs/,/^never/p'
for m in p g k; do
  printf -- '--- mode %s\n' "$m"; "$D/s7" $m; sleep 0.3
  echo "'sleep 77' processes (pid pgid state; S = alive, Z = killed, not yet reaped by init):"
  ps -eo pid,pgid,stat,args | awk '$4 == "sleep" && $5 == "77" { print "  " $1, $2, $3, $4, $5 }'
  pkill -f '^sleep 77$' 2>/dev/null || true
done

say "S8 Forge's old path rule against fs_covers (the capability traps on what the old rule let through)"
$C build s8_covers.cho --std -o "$D/s8" || exit 1
for p in /tmp/x/journal.jsonl /tmp/a..b/j /tmp/a/../b; do
  printf -- '--- %s\n' "$p"; "$D/s8" v "$p"; "$D/s8" e "$p"; echo "exit=$?"
done 2>&1

say "S9 a worker started beneath a directory given at run time, guard first"
$C build s9_under.cho --std -o "$D/s9" || exit 1
$C authority s9_under.cho --std | sed -n '/^performs/,/^never/p'
for n in mock_worker ./mock_worker nope /bin/echo ../x a..b ""; do
  printf -- '--- [%s]: ' "$n"; "$D/s9" "$D/bin" "$n"
done 2>&1

say "S10 a worker's symlink: the Fs capability follows it, a Dir does not"
$C build s10_symlink.cho --std -o "$D/s10" || exit 1
mkdir -p "$D/s10dir/exec" "$D/s10dir/outside" && echo secret > "$D/s10dir/outside/s.txt"
echo ok > "$D/s10dir/exec/plain"
ln -s "$D/s10dir/outside/s.txt" "$D/s10dir/exec/link"
ln -s "$D/s10dir/outside" "$D/s10dir/exec/dirlink"
for r in plain link dirlink/s.txt missing ../outside/s.txt; do
  printf -- '--- Dir: %s\n' "$r"; "$D/s10" d "$D/s10dir/exec" "$r"
done 2>&1
for r in plain link dirlink/s.txt missing; do
  printf -- '--- Fs: %s\n' "$r"; "$D/s10" f "$D/s10dir/exec/$r"
done 2>&1

say "S11 a deadline kill of a gate runner: does what the gate started survive? (the grandchild is 'sleep 78')"
$C build s11_runner.cho --std -o "$D/bin/runner" || exit 1
$C build s11_forge.cho --std -o "$D/s11" || exit 1
for how in u d; do
  for m in p d l; do
    printf -- '--- Forge starts the runner: %s; the runner starts the gate: %s\n' \
      "$([ $how = u ] && echo 'exec_spawn_under (not a group leader)' || echo 'exec_spawn_detached (a group leader)')" \
      "$(case $m in p) echo 'plain, no deadline of its own';; d) echo 'detached, its own deadline 200 ms < 1000 ms';; l) echo 'detached, no deadline of its own';; esac)"
    if [ $how = u ]; then "$D/s11" u "$D/bin" runner $m none; else "$D/s11" d "$D/bin" runner $m "$D/bin/runner"; fi
    sleep 0.4
    echo "'sleep 78' processes (pid pgid sid state; none = nothing leaked):"
    ps -eo pid,pgid,sid,stat,args | awk '$5 == "sleep" && $6 == "78" { print "  " $1, $2, $3, $4 }'
    pkill -f '^sleep 78$' 2>/dev/null || true
    pkill -x runner 2>/dev/null || true
  done
done

say "S12 a worker found beneath a run-time Dir that leads a group of its own (G10, cancho #562 / #588): the grandchild is 'sleep 79'"
$C build s12_detached_under.cho --std -o "$D/s12" || exit 1
$C authority s12_detached_under.cho --std | sed -n '/^performs/,/^never/p'
printf '#!/bin/sh\nsleep 79 &\nwait\n' > "$D/bin/grandkid" && chmod +x "$D/bin/grandkid"
for m in u d; do
  printf -- '--- %s\n' "$([ $m = u ] && echo 'exec_spawn_under (not a group leader): the control' || echo 'exec_spawn_detached_under (a group leader)')"
  "$D/s12" $m "$D/bin"; sleep 0.4
  echo "'sleep 79' processes (pid pgid sid state; none = nothing leaked):"
  ps -eo pid,pgid,sid,stat,args | awk '$5 == "sleep" && $6 == "79" { print "  " $1, $2, $3, $4 }'
  pkill -f '^sleep 79$' 2>/dev/null || true
done

say "S13 two builds in one execution directory (issue #35): the race, and what a lock does to a build it started"
$C build ../workers/cancho_code.cho $(ls ../src/*.cho | grep -v '/main\.cho$') --std -o "$D/cancho_code" || exit 1
$C build ../src/*.cho --std -o "$D/forge" || exit 1
s13=$(mktemp -d /tmp/forge-s13.XXXXXX) || exit 1
sh s13_two_builds.sh "$D/cancho_code" "$s13" "$D/forge"
rm -rf "$s13"
CANCHO="$C" sh s13_lock_inherit.sh

say "S14 a supervisor that stays: start, probe, cancel, SIGKILL, and a nap (issue #33)"
CANCHO="$C" sh s14_supervise.sh
