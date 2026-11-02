#!/bin/sh
# M-1 (docs/company-lifecycle.md section 9): can a Haiku-class builder produce a correct patch against an existing file from a request? Replays two past
# defects of cancho-code (defects.sh) with the real `cancho-build --repo` and a real model, N independent runs each, and judges every changed tree with the
# defect's own hidden fixture (judge.sh). Stops before a run when the money spent reaches the ceiling. A test ORACLE and a measurement; not product logic.
#
# Usage: CANCHO=compiler CODE=cancho-code-checkout replay.sh <key-file> <ceiling dollars> <runs per defect> <results.tsv> <scratch dir, empty, short path>
#   <key-file>  a file holding the API key (the agent reads it; this script never does and never prints it); its path is made of letters, digits and ._/-
# Environment: MODEL (default claude-haiku-5-5), ATTEMPTS (3, the attempts inside one run).
# Cost: usage.jsonl of every run is priced at the model's list price: input 0.10 and output 0.50 dollars per million tokens up to 100K prompt tokens, 0.50 and
# 2.50 above; cache reads at a tenth of the input price and cache writes at 1.25 times it (assumed, not read from the bill). A call over 100K is priced at the
# higher tier, so the total is an upper bound on a Haiku 5.5 bill, and the ceiling is checked before each run, so one run's worth can pass it.
set -u
CODE="${CODE:?set CODE}"; C="${CANCHO:?set CANCHO}"
key=${1:?key file}; ceiling=${2:?ceiling}; runs=${3:?runs}; out=${4:?results}; w=${5:?scratch}
model=${MODEL:-claude-haiku-5-5}; attempts=${ATTEMPTS:-3}
here=$(cd "$(dirname "$0")" && pwd)
. "$here/defects.sh"
[ -f "$key" ] || { echo "replay: no key file" >&2; exit 2; }
[ -x "$CODE/build/cancho-build" ] && [ -x "$CODE/build/cancho-agent" ] || { echo "replay: build cancho-build and cancho-agent first (scripts/build-cancho-build.sh, scripts/build-agent.sh)" >&2; exit 2; }
mkdir -p "$w" || exit 2
printf 'defect\trun\texit\tattempts\tin_tokens\tout_tokens\tcost_usd\tjudge\tpatch_lines\tmodel\n' > "$out"
total=0
cost_of() { # usage.jsonl -> dollars (awk): see the header
  [ -f "$1" ] || { echo 0; return; }
  awk -F'[:,{}]' '{
    n=split($0,f,","); iin=0; oo=0; cw=0; cr=0
    for(i=1;i<=n;i++){ if(f[i]~/"in":/){sub(/.*"in":/,"",f[i]); iin=f[i]+0} if(f[i]~/"out":/){sub(/.*"out":/,"",f[i]); oo=f[i]+0} if(f[i]~/"cache_write":/){sub(/.*"cache_write":/,"",f[i]); cw=f[i]+0} if(f[i]~/"cache_read":/){sub(/.*"cache_read":/,"",f[i]); cr=f[i]+0} }
    pi=0.10; po=0.50; if(iin+cw+cr>100000){pi=0.50; po=2.50}
    t+=(iin*pi + oo*po + cw*pi*1.25 + cr*pi*0.1)/1000000 } END { printf "%.4f", t+0 }' "$1"
}
tokens_of() { # usage.jsonl field -> sum
  [ -f "$1" ] || { echo 0; return; }
  grep -o "\"$2\":[0-9]*" "$1" | awk -F: '{s+=$2} END {print s+0}'
}
stopped=0
for d in A B; do
  r=1
  while [ "$r" -le "$runs" ]; do
    if awk "BEGIN{exit !($total >= $ceiling)}"; then stopped=1; break 2; fi
    base=$(eval echo \$BASE_$d)
    b="$w/base-$d-$r"; wk="$w/work-$d-$r"
    mkdir -p "$b" && git -C "$CODE" archive "$base" | tar -x -C "$b" || exit 2
    "$CODE/build/cancho-build" --repo "$b" --change "$here/$d.txt" --kind bug --checker "$C" --work "$wk" \
      --agent "$CODE/scripts/cancho-agent.sh --key-file $key" --provider anthropic --model "$model" --attempts "$attempts" > "$wk.log" 2>&1
    rc=$?
    cost=$(cost_of "$wk/usage.jsonl"); tin=$(tokens_of "$wk/usage.jsonl" in); tout=$(tokens_of "$wk/usage.jsonl" out)
    total=$(awk "BEGIN{printf \"%.4f\", $total + $cost}")
    verdict=na; plines=0
    if [ "$rc" = 0 ] && [ -d "$wk/tree" ]; then
      plines=$(wc -l < "$wk/change.patch" 2> /dev/null | tr -d ' ')
      if CODE="$CODE" CANCHO="$C" sh "$here/judge.sh" "$d" "$wk/tree" > "$wk.judge" 2>&1; then verdict=pass; else verdict=fail; fi
    fi
    used=$(grep -c '"outcome"' "$wk/usage.jsonl" 2> /dev/null || echo 0)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "$r" "$rc" "$used" "$tin" "$tout" "$cost" "$verdict" "$plines" "$model" >> "$out"
    r=$((r + 1))
  done
done
[ "$stopped" = 1 ] && printf 'ceiling\t-\t-\t-\t-\t-\t%s\t-\t-\t%s\n' "$total" "$model" >> "$out"
printf 'total\t-\t-\t-\t-\t-\t%s\t-\t-\t%s\n' "$total" "$model" >> "$out"
cat "$out"
