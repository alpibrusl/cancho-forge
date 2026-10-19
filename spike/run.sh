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
for f in s1_capture s2_timeout_kill s3_narrow s4_json_event s5_journal s6_dispatch s7_grandchild mock_worker; do
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

say "S7 what a kill reaches (grandchild 'sleep 77')"
$C build s7_grandchild.cho --std -o "$D/s7" || exit 1
for m in p g; do
  printf -- '--- mode %s\n' "$m"; "$D/s7" $m; sleep 0.3
  echo "sleep processes (pid pgid state; S = alive, Z = killed, not yet reaped by init):"
  ps -eo pid,pgid,stat,comm | awk '$4 == "sleep" { print "  " $0 }'
  pkill -x sleep 2>/dev/null
done
