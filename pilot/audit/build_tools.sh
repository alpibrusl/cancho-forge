#!/bin/sh
# Builds the audit's tools into <bin dir>: world, resolver, driver and tlsworld (docs/pilot-audit.md). The operator runs it once; audit_checker.sh needs no compiler.
# Usage: CANCHO=path/to/cancho [CANCHO_PACKAGES=dir] pilot/audit/build_tools.sh <bin dir>
set -u
C="${CANCHO:-cancho}"
cd "$(dirname "$0")/../.." || exit 1
. scripts/packages.sh
b=$1
mkdir -p "$b" || exit 1
V=pilot/audit/vendor
$C build pilot/audit/world.cho --std -o "$b/world" || exit 1
$C build pilot/audit/resolver.cho --std -o "$b/resolver" || exit 1
$C build pilot/audit/driver.cho pilot/audit/expect.cho --std -o "$b/driver" || exit 1
$C build --std $V/hello.cho $V/loop.cho $V/app.cho $V/front.cho $V/identity.cho $PKG/http-server/server.cho \
  $PKG/tls/tls.cho $PKG/tls/record.cho $PKG/tls/message.cho $PKG/tls/slot.cho $PKG/tls/cident.cho $PKG/tls/client12.cho $PKG/tls/client.cho $PKG/tls/hello.cho \
  $PKG/tls/identity.cho $PKG/tls/clientauth.cho $PKG/tls/ticket.cho $PKG/tls/server.cho $PKG/tls/saved.cho \
  $PKG/x509/verify.cho $PKG/x509/names.cho $PKG/x509/x509.cho $PKG/x509/key.cho -o "$b/tlsworld" || exit 1
