# Where the compiler's packages are (http-client, tls, x509): CANCHO_PACKAGES, else `packages` next to the compiler binary, as cancho-code's build-agent.sh finds them.
# Sets PKG; sourced by the scripts that build a program with the provider transport.
PKG="${CANCHO_PACKAGES:-}"
[ -d "$PKG" ] || PKG="$(dirname "$(command -v "$C")")/packages"
[ -d "$PKG" ] || PKG="$(dirname "$(dirname "$(command -v "$C")")")/packages"
[ -d "$PKG" ] || { echo "packages: no cancho packages found; set CANCHO_PACKAGES" >&2; exit 2; }
