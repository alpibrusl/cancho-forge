#!/bin/sh
# R2 of docs/pilot-audit.md section 5.1: the reference fetcher against the audit's world and stub resolver, through its command line (fetch_cli.cho). Prints `ok ...` / `FAIL ...`.
# Usage: CANCHO=path/to/cancho pilot/audit/reference/fetch_check.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../../.." || exit 1
. scripts/packages.sh
w=$1
fail=0
ok() { echo "ok   reference fetch: $1"; }
bad() { echo "FAIL reference fetch: $1"; fail=1; }
R=pilot/audit/reference
$C build pilot/audit/world.cho --std -o "$w/world" && $C build pilot/audit/resolver.cho --std -o "$w/resolver" && $C build $R/fetch_cli.cho $R/fetch.cho $R/probe.cho $R/checker.cho spike/lib/dns.cho $PKG/tls/*.cho $PKG/x509/*.cho --std -o "$w/fetch" || { echo "FAIL reference fetch: did not build"; exit 1; }
base=$((30000 + $$ % 20000)); n=0
stop() { kill $pids 2> /dev/null; wait 2> /dev/null; pids=""; }
# case <allow 0|1> <resolver table or ""> <url with @w1 @w2> -- <world 1 args> [-- <world 2 args>]  ->  $out, $rc
run_() {
  allow=$1; table=$2; url=$3; shift 3
  n=$((n + 1)); p1=$((base + n * 4 + 1)); p2=$((p1 + 1)); pr=$((p1 + 2)); pids=""
  url=$(printf '%s' "$url" | sed -e "s/@w1/$p1/g" -e "s/@w2/$p2/g")
  [ "${1-}" = "--" ] && shift
  if [ $# -gt 0 ]; then
    set -- "$@"; first=""; second=""; cur=first
    for a in "$@"; do if [ "$a" = "--" ]; then cur=second; else eval "$cur=\"\$$cur \$(printf '%s' \"\$a\" | sed -e \"s/@w1/$p1/g\" -e \"s/@w2/$p2/g\")\""; fi; done
    # shellcheck disable=SC2086
    [ -n "$first" ] && { "$w/world" $p1 ${first}  > /dev/null 2>&1 & pids="$pids $!"; }
    # shellcheck disable=SC2086
    [ -n "$second" ] && { "$w/world" $p2 ${second} > /dev/null 2>&1 & pids="$pids $!"; }
  fi
  if [ -n "$table" ]; then "$w/resolver" "$pr" 4 $table > "$w/resolver.$n.out" 2>&1 & pids="$pids $!"; fi
  i=0; while [ $i -lt 50 ]; do
    if [ -z "$table" ] || grep -q '^listening' "$w/resolver.$n.out" 2> /dev/null; then break; fi
    sleep 0.1; i=$((i + 1))
  done
  sleep 0.3
  out=$("$w/fetch" 127.0.0.1 "$pr" "$allow" "$url" 2> /dev/null); rc=$?
  stop
}
has() { printf '%s' "$out" | grep -q -- "$1"; }
chk() { # description, pattern
  if has "$2"; then ok "$1"; else bad "$1 ($out)"; fi
}
run_ 1 "" "http://127.0.0.1:@w1/" 2 ok
chk "a 200 is up, final_url is the target, no redirects" '"status":200.*"redirects":\[\].*"verdict":"up"'
run_ 1 "" "http://127.0.0.1:@w1/" 2 status 404
chk "a 404 is up (the target's own answer)" '"status":404.*"verdict":"up"'
run_ 1 "" "http://127.0.0.1:@w1/" 2 status 500
chk "a 500 is degraded" '"status":500.*"verdict":"degraded"'
run_ 1 "" "http://127.0.0.1:@w1/"
chk "a refused connection is down, with its reason" '"verdict":"down".*connection was refused'
run_ 1 "" "http://127.0.0.1:@w1/" 2 reset
chk "half a status line is down" '"verdict":"down"'
run_ 1 "" "http://127.0.0.1:@w1/" 2 close
chk "an empty reply is down" '"verdict":"down"'
run_ 1 "" "http://127.0.0.1:@w1/" 2 lie
chk "a Content-Length that lies is down" '"verdict":"down".*before its Content-Length'
run_ 1 "" "http://127.0.0.1:@w1/" 2 bighead
chk "a header block of 100 KiB is down, not a crash" '"verdict":"down"'
run_ 1 "" "http://127.0.0.1:@w1/" 2 big 300000
chk "a 300000-byte body is read to the cap and the answer says it was cut" 'body cut at 64 KiB'
run_ 1 "" "http://127.0.0.1:@w1/" 2 chunked
chk "a chunked answer is answered" '"status":200.*"verdict":"up"'
run_ 1 "" "http://127.0.0.1:@w1/" 2 slow 6000
chk "a first byte at 6 s is answered and degraded (total over 5000 ms)" '"status":200.*"verdict":"degraded"'
run_ 1 "" "http://127.0.0.1:@w1/" 2 redirect301 "http://127.0.0.1:@w2/" -- 2 ok
chk "a 301 to a 200 is followed once: one hop recorded, final_url is the last" '"status":200,"redirects":\[{"url":"http://127.0.0.1:[0-9]*/","status":301}\].*"verdict":"up"'
run_ 1 "" "http://127.0.0.1:@w1/" 8 redirect "http://127.0.0.1:@w1/"
if [ "$rc" = 1 ] && has 'refused target.too-many-redirects'; then ok "a redirect loop ends at the limit: target.too-many-redirects"; else bad "loop ($out)"; fi
run_ 1 "" "http://127.0.0.1:@w1/" 2 redirect301 "http://169.254.169.254/"
if [ "$rc" = 1 ] && has 'refused target.private-address'; then ok "a redirect from loopback to the metadata address is refused"; else bad "metadata redirect ($out)"; fi
run_ 1 "" "http://127.0.0.1:@w1/" 2 redirect301 "ftp://x.test/"
if [ "$rc" = 1 ] && has 'refused url.scheme'; then ok "a redirect to another scheme is refused"; else bad "scheme redirect ($out)"; fi
run_ 0 "" "http://127.0.0.1:@w1/" 2 ok
if [ "$rc" = 1 ] && has 'refused url.port'; then ok "without --allow-loopback an unlisted port is refused first"; else bad "no loopback ($out)"; fi
run_ 0 "" "http://127.0.0.1:8080/"
if [ "$rc" = 1 ] && has 'refused target.private-address'; then ok "without --allow-loopback loopback is private"; else bad "loopback ($out)"; fi
for u in "http://169.254.169.254/" "http://2130706433:8080/" "http://0177.0.0.1:8080/" "http://0x7f.1:8080/" "http://[::1]:8080/" "http://[::ffff:127.0.0.1]:8080/" "http://10.0.0.5/" "http://0.0.0.0:8080/"; do
  run_ 0 "" "$u"
  if [ "$rc" = 1 ] && has 'refused target.private-address'; then ok "$u is refused as private"; else bad "$u ($out)"; fi
done
run_ 0 "lo.test=127.0.0.1" "http://lo.test:8080/"
if [ "$rc" = 1 ] && has 'refused target.private-address'; then ok "a name that resolves to loopback is refused as private"; else bad "lo.test ($out)"; fi
run_ 0 "mixed.test=203.0.113.7,10.0.0.5" "http://mixed.test/"
if [ "$rc" = 1 ] && has 'refused target.private-address'; then ok "a name with one private address among its records is refused"; else bad "mixed ($out)"; fi
run_ 0 "gone.test=NX" "http://gone.test/"
chk "a name that does not exist is down" '"verdict":"down".*did not resolve'
run_ 0 "pub.test=203.0.113.7" "http://pub.test/"
chk "a public-looking address with nothing listening is down, not refused" '"verdict":"down"'
run_ 1 "" "http://127.0.0.1:@w1/" 2 hang 20000
if [ "$rc" = 1 ] && has 'refused check.timeout'; then ok "an answer that never comes is check.timeout at the hard limit"; else bad "hang ($out)"; fi

# ---- TLS: the vendored cancho TLS server on the audit's fixtures, the checker's roots and its clock (--now) ----
V=pilot/audit/vendor
if $C build --std $V/hello.cho $V/loop.cho $V/app.cho $V/front.cho $V/identity.cho $PKG/http-server/server.cho \
  $PKG/tls/tls.cho $PKG/tls/record.cho $PKG/tls/message.cho $PKG/tls/slot.cho $PKG/tls/cident.cho $PKG/tls/client12.cho $PKG/tls/client.cho $PKG/tls/hello.cho \
  $PKG/tls/identity.cho $PKG/tls/clientauth.cho $PKG/tls/ticket.cho $PKG/tls/server.cho $PKG/tls/saved.cho \
  $PKG/x509/verify.cho $PKG/x509/names.cho $PKG/x509/x509.cho $PKG/x509/key.cho -o "$w/tlsworld"; then
  NOT_AFTER=2051222400   # 2035-01-01T00:00:00Z, the fixtures' notAfter
  DAY=86400
  # tlsrun <identity> <roots: ca|none> <now unix s> -> $out
  tlsrun() {
    n=$((n + 1)); p1=$((base + n * 4 + 1)); pr=$((p1 + 2))
    "$w/tlsworld" --port "$p1" --dir "pilot/audit/tls/id_$1" > "$w/tls.$n.out" 2>&1 &
    t1=$!
    "$w/resolver" "$pr" 4 ok.test=127.0.0.1 > "$w/resolver.$n.out" 2>&1 &
    t2=$!
    i=0; while [ $i -lt 50 ] && ! { grep -q '^listening' "$w/tls.$n.out" && grep -q '^listening' "$w/resolver.$n.out"; }; do sleep 0.1; i=$((i + 1)); done
    if [ "$2" = ca ]; then roots="pilot/audit/tls/ca.pem"; else roots="/dev/null"; fi
    out=$("$w/fetch" 127.0.0.1 "$pr" 1 "https://ok.test:$p1/" "$roots" "$3" 2> /dev/null); rc=$?
    kill $t1 $t2 2> /dev/null; wait 2> /dev/null
  }
  tlsrun valid ca $((NOT_AFTER - 1826 * DAY))
  chk "a valid chain for ok.test verifies, with whole days left (1826 at five years before notAfter)" '"tls":{"verified":true,"days_left":1826}.*"verdict":"up"'
  tlsrun valid ca $((NOT_AFTER - 14 * DAY))
  chk "14 days left is up (the boundary)" '"days_left":14}.*"verdict":"up"'
  tlsrun valid ca $((NOT_AFTER - 14 * DAY + 1))
  chk "13 days and 23 hours left is 13 whole days and degraded" '"days_left":13}.*"verdict":"degraded"'
  tlsrun valid ca $((NOT_AFTER - 10 * DAY))
  chk "10 days left is degraded" '"days_left":10}.*"verdict":"degraded"'
  tlsrun valid ca $((NOT_AFTER - DAY))
  chk "1 day left is degraded with days_left 1" '"days_left":1}.*"verdict":"degraded"'
  tlsrun valid ca $((NOT_AFTER + DAY))
  chk "an expired chain is down, not verified" '"tls":{"verified":false,"days_left":0}.*"verdict":"down"'
  tlsrun wrongname ca $((NOT_AFTER - 1826 * DAY))
  chk "a certificate for another name is down, not verified" '"tls":{"verified":false.*"verdict":"down"'
  tlsrun selfsigned ca $((NOT_AFTER - 1826 * DAY))
  chk "a self-signed certificate is down, not verified" '"tls":{"verified":false.*"verdict":"down"'
  tlsrun valid none $((NOT_AFTER - 1826 * DAY))
  chk "a chain that no trusted root vouches for is down" '"tls":{"verified":false.*"verdict":"down"'
  chk "and the reason names what the engine refused" 'x509'
  tlsrun valid ca $((NOT_AFTER - 1826 * DAY))
  chk "the tls phase is measured" '"timing_ms":{"dns":[0-9]*,"connect":[0-9]*,"tls":[0-9]*,'
else
  bad "the TLS world did not build"
fi
exit "$fail"
