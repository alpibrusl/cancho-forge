#!/bin/sh
# Spike P4 (docs/pilot-s1.md section 6): the audit's test world serves every misbehaviour it promises, seen from OUTSIDE by an independent client (curl). The world is spike/p4_world.cho.
# Usage: CANCHO=path/to/cancho spike/p4_check.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/.." || exit 1
w=$1
fail=0
ok() { echo "ok   p4: $1"; }
bad() { echo "FAIL p4: $1"; fail=1; }
command -v curl > /dev/null || { echo "FAIL p4: no curl, the oracle"; exit 1; }
if ! $C build spike/p4_world.cho --std -o "$w/world"; then echo "FAIL p4: did not build"; exit 1; fi
base=$((30000 + $$ % 20000))
n=0
# case <name> <connections> <curl options...> -- <world mode> [arg]   : runs the world, curl once; leaves status in $rc and the body in $w/body, the code in $code
case_() {
  name=$1; conns=$2; shift 2
  opts=""
  while [ "$1" != "--" ]; do opts="$opts $1"; shift; done
  shift
  n=$((n + 1)); port=$((base + n))
  "$w/world" "$port" "$conns" "$@" > "$w/world.$n.out" 2>&1 &
  sleep 0.5
  code=$(curl -s -o "$w/body" -w '%{http_code} %{size_download}' --connect-timeout 2 $opts "http://127.0.0.1:$port/" 2> /dev/null); rc=$?
  if [ "$conns" -gt 1 ]; then :; fi
  kill $! 2> /dev/null; wait 2> /dev/null
}
case_ "ok" 1 --max-time 3 -- ok
[ "$rc" = 0 ] && [ "$code" = "200 2" ] && [ "$(cat "$w/body")" = ok ] && ok "a plain 200 with a two-byte body" || bad "ok ($rc $code)"
case_ "404" 1 --max-time 3 -- status 404
[ "$rc" = 0 ] && [ "${code%% *}" = 404 ] && ok "a 404 is served as a 404" || bad "404 ($rc $code)"
case_ "500" 1 --max-time 3 -- status 500
[ "$rc" = 0 ] && [ "${code%% *}" = 500 ] && ok "a 500 is served as a 500" || bad "500 ($rc $code)"
case_ "slow1500 patient" 1 --max-time 4 -- slow 1500
[ "$rc" = 0 ] && [ "${code%% *}" = 200 ] && ok "a first byte after 1.5 s arrives for a client that waits" || bad "slow patient ($rc $code)"
case_ "slow1500 impatient" 1 --max-time 1 -- slow 1500
[ "$rc" = 28 ] && ok "and is a timeout for a client that gives up at 1 s (curl exit 28)" || bad "slow impatient ($rc)"
case_ "hang" 1 --max-time 1 -- hang 4000
[ "$rc" = 28 ] && ok "a connection that is accepted and never answered is a timeout (curl exit 28)" || bad "hang ($rc)"
case_ "close" 1 --max-time 3 -- close
[ "$rc" = 52 ] && ok "a request read and then a close with no answer is an empty reply (curl exit 52)" || bad "close ($rc)"
case_ "abort" 1 --max-time 3 -- abort
[ "$rc" != 0 ] && [ "$rc" != 28 ] && ok "a connection closed with the request unread is reset, a failure and not a timeout (curl exit $rc)" || bad "abort ($rc)"
case_ "reset" 1 --max-time 3 -- reset
[ "$rc" != 0 ] && [ "$rc" != 28 ] && ok "half a status line then a close is a failure, not a timeout (curl exit $rc)" || bad "reset ($rc)"
case_ "lie" 1 --max-time 3 -- lie
[ "$rc" = 18 ] && [ "${code#* }" = 10 ] && ok "a Content-Length of 100 over ten bytes is a partial transfer after 10 bytes (curl exit 18)" || bad "lie ($rc $code)"
case_ "chunked" 1 --max-time 3 -- chunked
[ "$rc" = 0 ] && [ "$(cat "$w/body")" = hello ] && ok "a chunked answer decodes to hello" || bad "chunked ($rc)"
case_ "big" 1 --max-time 5 -- big 300000
[ "$rc" = 0 ] && [ "$code" = "200 300000" ] && ok "a 300000-byte body is served whole" || bad "big ($rc $code)"
case_ "bighead" 1 --max-time 3 -- bighead
[ "$rc" != 0 ] && ok "a 100 KiB header block is refused by a client with a header limit (curl exit $rc)" || bad "bighead ($rc)"
case_ "trickle" 1 --max-time 5 -- trickle 50
[ "$rc" = 0 ] && [ "${code%% *}" = 200 ] && ok "an answer one byte at a time, 50 ms apart, still completes" || bad "trickle ($rc $code)"
n=$((n + 1)); port=$((base + n))
"$w/world" "$port" 7 redirect "http://127.0.0.1:$port/" > "$w/world.loop.out" 2>&1 &
sleep 0.5
curl -s -o /dev/null -L --max-redirs 5 --max-time 5 "http://127.0.0.1:$port/" 2> /dev/null; rc=$?
kill $! 2> /dev/null; wait 2> /dev/null
[ "$rc" = 47 ] && ok "a redirect to itself is a loop that stops at the limit (curl exit 47)" || bad "loop ($rc)"
n=$((n + 1)); a=$((base + n)); n=$((n + 1)); b=$((base + n))
"$w/world" "$b" 1 ok > "$w/world.chain.b.out" 2>&1 &
"$w/world" "$a" 1 redirect "http://127.0.0.1:$b/" > "$w/world.chain.a.out" 2>&1 &
sleep 0.5
code=$(curl -s -o /dev/null -L --max-redirs 5 --max-time 5 -w '%{http_code} %{num_redirects}' "http://127.0.0.1:$a/" 2> /dev/null); rc=$?
wait 2> /dev/null
[ "$rc" = 0 ] && [ "$code" = "200 1" ] && ok "a redirect to another port is followed once to a 200" || bad "chain ($rc $code)"
"$w/world" "$((base + 99))" 1 ok > "$w/world.refused.out" 2>&1 &
sleep 0.5
curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$((base + 98))/" 2> /dev/null; rc=$?
kill $! 2> /dev/null; wait 2> /dev/null
[ "$rc" = 7 ] && ok "a port nothing listens on is a refused connection (curl exit 7)" || bad "refused ($rc)"
exit "$fail"
