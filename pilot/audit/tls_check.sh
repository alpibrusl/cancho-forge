#!/bin/sh
# T1 of docs/pilot-audit.md: the audit's TLS fixtures, served by cancho's own TLS server (the vendored `https_hello`, pilot/audit/vendor/) and seen from OUTSIDE by
# `openssl s_client` and `curl`. A valid chain verifies and answers; a certificate for another name and a self-signed one are served and fail verification; the
# server is TLS 1.3 only and speaks no plain HTTP on its port. Expiry needs no fixture of its own (the checker's --now, section 3.1). Prints `ok ...` / `FAIL ...`.
# Usage: CANCHO=path/to/cancho [CANCHO_PACKAGES=dir] pilot/audit/tls_check.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../.." || exit 1
. scripts/packages.sh
w=$1
fail=0
ok() { echo "ok   audit tls: $1"; }
bad() { echo "FAIL audit tls: $1"; fail=1; }
command -v openssl > /dev/null || { echo "FAIL audit tls: no openssl, the oracle"; exit 1; }
V=pilot/audit/vendor
if ! $C build --std $V/hello.cho $V/loop.cho $V/app.cho $V/front.cho $V/identity.cho $PKG/http-server/server.cho \
  $PKG/tls/tls.cho $PKG/tls/record.cho $PKG/tls/message.cho $PKG/tls/slot.cho $PKG/tls/cident.cho $PKG/tls/client12.cho $PKG/tls/client.cho $PKG/tls/hello.cho \
  $PKG/tls/identity.cho $PKG/tls/clientauth.cho $PKG/tls/ticket.cho $PKG/tls/server.cho $PKG/tls/saved.cho \
  $PKG/x509/verify.cho $PKG/x509/names.cho $PKG/x509/x509.cho $PKG/x509/key.cho -o "$w/tlsworld"; then echo "FAIL audit tls: the TLS world did not build"; exit 1; fi
base=$((30000 + $$ % 20000))
n=0
# serve <identity> : starts the server on a fresh port in $port, its pid in $pid
serve() {
  n=$((n + 1)); port=$((base + n))
  "$w/tlsworld" --port "$port" --dir "pilot/audit/tls/id_$1" > "$w/srv.$n.out" 2>&1 &
  pid=$!
  i=0; while [ $i -lt 50 ] && ! grep -q '^listening' "$w/srv.$n.out"; do sleep 0.1; i=$((i + 1)); done
}
stop() { kill "$pid" 2> /dev/null; wait "$pid" 2> /dev/null; }
probe() { # extra s_client options; the request is a GET / with the Host ok.test
  printf 'GET / HTTP/1.1\r\nHost: ok.test\r\nConnection: close\r\n\r\n' | openssl s_client -connect "127.0.0.1:$port" -servername ok.test -CAfile pilot/audit/tls/ca.pem -verify_hostname ok.test -verify_return_error -quiet "$@" > "$w/probe.out" 2>&1; echo $? > "$w/probe.rc"
}
serve valid; probe
if [ "$(cat "$w/probe.rc")" = 0 ] && grep -q '200 OK' "$w/probe.out"; then ok "a valid chain for ok.test verifies and answers 200"; else bad "valid chain ($(head -c 300 "$w/probe.out"))"; fi
probe -tls1_2
if [ "$(cat "$w/probe.rc")" != 0 ] && ! grep -q '200 OK' "$w/probe.out"; then ok "a TLS 1.2-only client is refused (the server is TLS 1.3 only)"; else bad "tls1.2 was answered"; fi
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$port/" 2> /dev/null)
if [ "$code" = 000 ]; then ok "plain HTTP on the TLS port is not answered"; else bad "plain HTTP got $code"; fi
stop
serve wrongname; probe
if [ "$(cat "$w/probe.rc")" != 0 ] && grep -q 'hostname mismatch' "$w/probe.out"; then ok "a certificate for another name is served and fails with a hostname mismatch"; else bad "wrongname ($(head -c 300 "$w/probe.out"))"; fi
stop
serve selfsigned; probe
if [ "$(cat "$w/probe.rc")" != 0 ] && grep -qi 'self-signed\|self signed\|unable to get local issuer\|unable to verify' "$w/probe.out"; then ok "a self-signed certificate is served and fails verification"; else bad "selfsigned ($(head -c 300 "$w/probe.out"))"; fi
stop
exit "$fail"
