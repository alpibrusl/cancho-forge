#!/bin/sh
# The pilot's held-out audit (docs/pilot-audit.md sections 4 and 6; the `check` of the manifest's `build` step).
#   audit_checker.sh <artifact> <execution dir>
# Runs the candidate checker (the artifact, an executable) once per case of cases.txt, against the test world, and prints on STANDARD ERROR one line per case (`pass <id>` or
# `fail <id> <why>`) and on STANDARD OUTPUT, last, `TOTAL a/b`. The candidate's own output goes to a file in the execution directory and never to standard output, so it cannot
# print a score (docs/company.md section 8). Needs the built tools of the audit in $AUDIT_BIN (default: ./bin beside this script): world, resolver, driver and tlsworld.
# Environment: CASES (default cases.txt beside this script), ONLY (a space-separated list of case ids to run), WAIT_MS (how long to wait for the candidate to listen, default 3000).
set -u
here=$(cd "$(dirname "$0")" && pwd)
artifact=${1:?artifact}; exec_dir=${2:?execution dir}
bin=${AUDIT_BIN:-$here/bin}; cases=${CASES:-$here/cases.txt}; wait_ms=${WAIT_MS:-3000}
[ -x "$artifact" ] || { echo "audit: the artifact is not an executable file" >&2; echo "TOTAL 0/1"; exit 0; }
for t in world resolver driver; do [ -x "$bin/$t" ] || { echo "audit: $bin/$t is missing" >&2; exit 2; }; done
mkdir -p "$exec_dir/audit" || exit 2
base=$((20000 + $$ % 20000)); idx=0; total=0; passed=0
pids=""
stop_all() { for p in $pids; do kill "$p" 2> /dev/null; done; wait 2> /dev/null; pids=""; }
trap 'stop_all' EXIT INT TERM
sub() { # replace @w1..@w4, @r, @ca in $1
  printf '%s' "$1" | sed -e "s/@w1/$p1/g" -e "s/@w2/$p2/g" -e "s/@w3/$p3/g" -e "s/@w4/$p4/g" -e "s/@r/$pr/g" -e "s#@ca#$here/tls/ca.pem#g"
}
run_case() {
  [ -n "$id" ] || return 0
  if [ -n "${ONLY:-}" ]; then case " $ONLY " in *" $id "*) ;; *) return 0 ;; esac; fi
  idx=$((idx + 1)); total=$((total + 1))
  pc=$((base + idx * 10)); p1=$((pc + 1)); p2=$((pc + 2)); p3=$((pc + 3)); p4=$((pc + 4)); pr=$((pc + 8))
  log="$exec_dir/audit/$id"
  : > "$log.worlds"
  printf '%s' "$worlds" | while IFS='|' read -r name count mode arg; do
    [ -n "$name" ] || continue
    port=$(sub "@$name"); arg=$(sub "$arg")
    if [ -n "$arg" ]; then "$bin/world" "$port" "$count" "$mode" "$arg" >> "$log.worlds" 2>&1 & else "$bin/world" "$port" "$count" "$mode" >> "$log.worlds" 2>&1 & fi
    echo $! >> "$log.pids"
  done
  if [ -n "$resolver" ]; then
    # shellcheck disable=SC2086
    "$bin/resolver" "$pr" $resolver > "$log.resolver" 2>&1 &
    echo $! >> "$log.pids"
    i=0; while [ $i -lt 50 ] && ! grep -q '^listening' "$log.resolver" 2> /dev/null; do sleep 0.1; i=$((i + 1)); done
  fi
  [ -f "$log.pids" ] && pids=$(cat "$log.pids")
  fl=$(sub "$flags")
  # shellcheck disable=SC2086
  "$artifact" serve --port "$pc" --resolver "127.0.0.1:$pr" $fl > "$log.candidate" 2>&1 &
  cand=$!; pids="$pids $cand"
  # wait for the candidate to listen: /health answered, or the wait is over (then the case fails with 'no answer')
  waited=0
  while [ "$waited" -lt "$wait_ms" ]; do
    "$bin/driver" "$pc" /health 400 'status>=100' > /dev/null 2>&1 && break
    sleep 0.2
    waited=$((waited + 200))
  done
  target=$(sub "$request"); spec=$(sub "$expect")
  out=$("$bin/driver" "$pc" "$target" "$timeout" "$spec" "$method" 2> /dev/null); rc=$?
  if [ "$rc" = 0 ]; then passed=$((passed + 1)); echo "pass $id" >&2; else echo "fail $id ($out)" >&2; fi
  stop_all
  rm -f "$log.pids"
}
id=""; flags=""; worlds=""; resolver=""; request=""; expect=""; method=GET; timeout=8000
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '#'*) ;;
    '') run_case; id=""; flags=""; worlds=""; resolver=""; request=""; expect=""; method=GET; timeout=8000 ;;
    "case "*) id=${line#case } ;;
    "flags "*) flags=${line#flags } ;;
    "world "*) set -- ${line#world }; n=$1; c=$2; m=$3; shift 3; worlds="$worlds$n|$c|$m|$*
" ;;
    "resolver "*) resolver=${line#resolver } ;;
    "request "*) request=${line#request } ;;
    "method "*) method=${line#method } ;;
    "timeout "*) timeout=${line#timeout } ;;
    "expect "*) expect=${line#expect } ;;
  esac
done < "$cases"
run_case
echo "TOTAL $passed/$total"
