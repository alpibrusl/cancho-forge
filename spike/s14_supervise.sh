#!/bin/sh
# Spike S14 driver (issue #33): measures from outside what spike/s14_supervise.cho does; asserts nothing.
# Usage: CANCHO=path/to/cancho spike/s14_supervise.sh
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
d=$(mktemp -d /tmp/forge-s14.XXXXXX) || exit 1
trap 'pkill -f "^sleep 76\$" 2> /dev/null; pkill -x s14 2> /dev/null; rm -rf "$d"' EXIT
mkdir "$d/self" "$d/tools" "$d/quick" "$d/ev" || exit 1
$C build spike/s14_supervise.cho --std -o "$d/self/s14" || exit 1
printf '#!/bin/sh\nsleep 76 &\nwait\n' > "$d/tools/sleeper"; chmod +x "$d/tools/sleeper"
printf '#!/bin/sh\nsleep 0.5\n' > "$d/quick/sleeper"; chmod +x "$d/quick/sleeper"
ms() { date +%s%N | cut -c1-13; }
. scripts/procs.sh
live() { leftover -x s14 | wc -l; }
builds() { pgrep -f "^sleep 76\$" | wc -l; }

t=$(ms); "$d/self/s14" start "$d/ev" "$d/tools" "$d/self"; echo "1. start answered after $(( $(ms) - t )) ms"
echo "   the starter has exited; supervisors alive: $(live); builds alive: $(builds); run file: $(cat "$d/ev/run")"
"$d/self/s14" probe "$d/ev"; echo "   (probe from a new process)"
t=$(ms); "$d/self/s14" start "$d/ev" "$d/tools" "$d/self"; echo "2. a second start on the same directory: answered after $(( $(ms) - t )) ms; supervisors alive: $(live); builds alive: $(builds)"
"$d/self/s14" cancel "$d/ev"; t=$(ms)
n=0; while [ ! -e "$d/ev/result" ] && [ $n -lt 100 ]; do sleep 0.01; n=$((n + 1)); done
echo "3. cancel: result '$(cat "$d/ev/result" 2> /dev/null)' after $(( $(ms) - t )) ms; builds alive: $(builds) (the sleep 76 grandchild was in the group)"
sleep 0.3; echo "   supervisors alive: $(live)"; "$d/self/s14" probe "$d/ev"
rm -f "$d/ev/run" "$d/ev/result" "$d/ev/cancel"
"$d/self/s14" start "$d/ev" "$d/tools" "$d/self" > /dev/null
sup=$(leftover -x s14 | head -1)
kill -9 "$sup"; sleep 0.3
echo "4. the supervisor killed with SIGKILL: supervisors alive: $(live); builds alive (orphan): $(builds)"
"$d/self/s14" probe "$d/ev"; echo "   (the lock went with the supervisor; the orphan is not stopped by anything)"
pkill -f "^sleep 76\$"; rm -f "$d/ev/run" "$d/ev/result" "$d/ev/cancel"
"$d/self/s14" start "$d/ev" "$d/quick" "$d/self" > /dev/null; sleep 1
echo "5. a build that ends by itself: result '$(cat "$d/ev/result" 2> /dev/null)'; supervisors alive: $(live)"
t=$(ms); "$d/self/s14" nap; echo "6. a nap of 250 ms on an empty poller took $(( $(ms) - t )) ms (process start included)"
