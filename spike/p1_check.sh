#!/bin/sh
# Spike P1 (docs/pilot-s1.md section 6) as a check: a cancho program resolves a name over UDP itself, with a deadline. The oracle is outside the program: it starts the program's
# own stub resolver on loopback and reads what the program prints. Hermetic: no real resolver is asked.
# Usage: CANCHO=path/to/cancho spike/p1_check.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
w=$1
fail=0
ok() { echo "ok   p1: $1"; }
bad() { echo "FAIL p1: $1"; fail=1; }
if ! $C build spike/p1_resolve.cho spike/lib/dns.cho --std -o "$w/p1"; then echo "FAIL p1: did not build"; exit 1; fi
port=$((20000 + $$ % 20000))
"$w/p1" stub "$port" 2 > "$w/stub.out" 2>&1 &
sleep 1
"$w/p1" resolve 127.0.0.1 "$port" example.test 1000 > "$w/r1.out" 2>&1
"$w/p1" resolve 127.0.0.1 "$port" Mixed.Case.Test. 1000 > "$w/r2.out" 2>&1
wait
grep -qx "address 192.0.2.7" "$w/r1.out" && grep -qx "ttl 60" "$w/r1.out" && ok "a name resolves to the address and the TTL the stub gave" || bad "a name resolves"
grep -qx "address 192.0.2.7" "$w/r2.out" && ok "a name with capitals and a final dot resolves too" || bad "capitals and a final dot"
[ "$(sed -n 's/^ms //p' "$w/r1.out")" -lt 500 ] && ok "and does so fast (the poller wakes on the datagram, not on the deadline)" || bad "fast"
grep -qx "served 2" "$w/stub.out" && ok "the stub saw exactly the two queries" || bad "stub served"
"$w/p1" silent "$((port + 1))" 1 > "$w/silent.out" 2>&1 &
sleep 1
"$w/p1" resolve 127.0.0.1 "$((port + 1))" example.test 600 > "$w/r3.out" 2>&1
wait
grep -qx "code -4" "$w/r3.out" && ok "a resolver that never answers is the deadline (code -4)" || bad "deadline code"
ms=$(sed -n 's/^ms //p' "$w/r3.out")
[ "$ms" -ge 590 ] && [ "$ms" -le 900 ] && ok "and it came at the deadline (600 ms asked, $ms ms taken)" || bad "deadline time ($ms ms)"
"$w/p1" resolve 127.0.0.1 "$((port + 2))" example.test 600 > "$w/r4.out" 2>&1
grep -qx "code -6" "$w/r4.out" && ok "nothing listening is a failure at once, not the deadline (code -6)" || bad "refused code"
[ "$(sed -n 's/^ms //p' "$w/r4.out")" -lt 300 ] && ok "and at once" || bad "refused time"
"$w/p1" resolve 127.0.0.1 "$port" "" 600 > "$w/r5.out" 2>&1
grep -qx "code -1" "$w/r5.out" && ok "an empty name is refused before anything is sent (code -1)" || bad "empty name"
exit "$fail"
