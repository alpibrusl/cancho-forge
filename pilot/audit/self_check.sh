#!/bin/sh
# T3 of docs/pilot-audit.md: the REFERENCE checker (pilot/audit/reference/) is built and run through the audit. It must score N/N: an audit that fails a correct checker is
# wrong, whatever it says of a builder's. Prints `ok ...` / `FAIL ...`; the cases it fails are named.
# Usage: CANCHO=path/to/cancho [CANCHO_PACKAGES=dir] pilot/audit/self_check.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../.." || exit 1
. scripts/packages.sh
w=$1
fail=0
ok() { echo "ok   audit self-check: $1"; }
bad() { echo "FAIL audit self-check: $1"; fail=1; }
R=pilot/audit/reference
mkdir -p "$w/bin" "$w/ev"
sh pilot/audit/build_tools.sh "$w/bin" || { echo "FAIL audit self-check: the audit's tools did not build"; exit 1; }
$C build $R/server.cho $R/fetch.cho $R/probe.cho $R/checker.cho $R/request.cho $R/ratelimit.cho spike/lib/dns.cho $PKG/tls/*.cho $PKG/x509/*.cho --std -o "$w/reference" || { echo "FAIL audit self-check: the reference checker did not build"; exit 1; }
n=$(grep -c '^case ' pilot/audit/cases.txt)
AUDIT_BIN="$w/bin" sh pilot/audit/audit_checker.sh "$w/reference" "$w/ev" > "$w/ref.out" 2> "$w/ref.err"
cat "$w/ref.err" | grep '^fail' | sed 's/^/     /'
if [ "$(tail -1 "$w/ref.out")" = "TOTAL $n/$n" ]; then ok "the reference checker scores TOTAL $n/$n"; else bad "the reference scored $(tail -1 "$w/ref.out")"; fi
exit "$fail"
