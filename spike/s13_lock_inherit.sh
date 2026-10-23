#!/bin/sh
# Spike S13 driver (issue #35): runs spike/s13_lock_inherit.cho and kills the holder from outside; asserts nothing, prints
# what it saw. Usage: CANCHO=path/to/cancho spike/s13_lock_inherit.sh
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
d=$(mktemp -d /tmp/forge-s13l.XXXXXX) || exit 1
trap 'pkill -f "[s]leep 77" 2> /dev/null; rm -rf "$d"' EXIT
mkdir "$d/bin" "$d/ev" || exit 1
printf '#!/bin/sh\nsleep 77\n' > "$d/bin/sleeper"; chmod +x "$d/bin/sleeper"
$C build spike/s13_lock_inherit.cho --std -o "$d/spike" || exit 1

"$d/spike" hold "$d/ev/lock" "$d/bin" > "$d/hold.out" &
holder=$!
sleep 1
"$d/spike" try "$d/ev/lock"; echo "1. second try while the holder lives: exit $?"
sleeper=$(pgrep -f '[s]leep 77' | head -1)
echo "   the build (pid $sleeper) is in group $(cut -d' ' -f5 "/proc/$sleeper/stat"), the holder is pid $holder"
echo "   descriptors of the build that name the lock file: $(ls -l /proc/$sleeper/fd 2> /dev/null | grep -c '/ev/lock')"
kill -9 "$holder"; wait "$holder" 2> /dev/null
sleep 0.5
echo "   holder killed with SIGKILL; the build lives: $(pgrep -f '[s]leep 77' | wc -l) process(es) named sleep 77"
"$d/spike" try "$d/ev/lock"; echo "2/3. try after the holder died, the build still running: exit $? (0 = lock was free)"
