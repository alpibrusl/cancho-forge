#!/bin/sh
# T4 of docs/pilot-audit.md section 5.2: the MUTANTS. Each block of broken/mutants.txt is the reference checker with one deliberate fault (a one-line replacement in one of its
# files, applied by pilot/audit/mutate.cho, which refuses a `from` that does not occur exactly once). The mutant is built and run through the cases it names after `catch`; it must
# score below the number of cases it was run through, or the audit has a HOLE: a fault of the kind it names that no case notices. Prints `caught mNN by v04` or `HOLE mNN ...`.
# Usage: CANCHO=... [CANCHO_PACKAGES=dir] [MUTANTS="m01 m02"] pilot/audit/self_check_mutants.sh <scratch directory, empty>
set -u
C="${CANCHO:-cancho}"
# the scratch directory is resolved BEFORE the cd: a relative one means relative to where the caller stands, not to the repository
case "$1" in /*) w=$1 ;; *) w=$(pwd)/$1 ;; esac
cd "$(dirname "$0")/../.." || exit 1
. scripts/packages.sh
. pilot/audit/mutant_verdict.sh
R=pilot/audit/reference
fail=0
mkdir -p "$w/bin" "$w/ev" "$w/m"
sh pilot/audit/build_tools.sh "$w/bin" || { echo "FAIL audit mutants: the audit's tools did not build"; exit 1; }
$C build pilot/audit/mutate.cho --std -o "$w/bin/mutate" || { echo "FAIL audit mutants: mutate did not build"; exit 1; }
field() { # field <id> <key>: the rest of the line after `<key> ` in the block of mutant <id>
  awk -v id="$1" -v key="$2" 'BEGIN{ins=0} $1=="mutant"{ins=($2==id)} ins && $1==key{ sub("^" key " ?", ""); print; exit }' pilot/audit/broken/mutants.txt
}
ids=${MUTANTS:-$(awk '$1=="mutant"{print $2}' pilot/audit/broken/mutants.txt)}
n=0; caught=0
for id in $ids; do
  n=$((n + 1))
  file=$(field "$id" file); from=$(field "$id" from); to=$(field "$id" to); catch=$(field "$id" catch)
  d="$w/m/$id"; rm -rf "$d"; mkdir -p "$d"
  cp $R/*.cho "$d/"
  if ! "$w/bin/mutate" "$R/$file" "$from" "$to" > "$d/$file.new" 2> "$d/mutate.err"; then
    echo "FAIL audit mutants: $id does not apply to $file (its \`from\` must occur exactly once)"; fail=1; continue
  fi
  mv "$d/$file.new" "$d/$file"
  # shellcheck disable=SC2086
  if ! $C build $d/server.cho $d/fetch.cho $d/probe.cho $d/checker.cho $d/request.cho $d/ratelimit.cho spike/lib/dns.cho $PKG/tls/*.cho $PKG/x509/*.cho --std -o "$d/candidate" > "$d/build.out" 2>&1; then
    echo "FAIL audit mutants: $id does not build"; fail=1; continue
  fi
  k=$(echo $catch | wc -w | tr -d ' ')
  ONLY="$catch" AUDIT_BIN="$w/bin" sh pilot/audit/audit_checker.sh "$d/candidate" "$w/ev" > "$d/out" 2> "$d/err"
  by=$(grep '^fail' "$d/err" | awk '{print $2}' | tr '\n' ' ')
  case "$(mutant_verdict "$d/out" "$k")" in
    hole) echo "HOLE $id: $(field "$id" what) -- cases $catch all passed"; fail=1 ;;
    caught) caught=$((caught + 1)); echo "caught $id by $by" ;;
    *) echo "FAIL audit mutants: $id: the audit did not finish (no \`TOTAL a/$k\` line; see $d/err), so nothing is claimed caught"; fail=1 ;;
  esac
done
if [ "$fail" = 0 ]; then echo "ok   audit mutants: $caught of $n caught"; else echo "FAIL audit mutants: $caught of $n caught"; fi
exit "$fail"
