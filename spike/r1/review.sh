#!/bin/sh
# R-1 (docs/reviewer.md section 9): does a model reviewer, given a change request and the diff and nothing else, tell a correct change from a faulty one?
# For each seed made by seeds.py, asks the model once (spike/r1/ask.cho) and compares its verdict with the seed's measured fate. A test ORACLE and a
# measurement, not product logic. The reviewer sees `brief.txt` and `change.patch` and nothing else: no fate, no audit, no test, no other file.
#
# Usage: review.sh <ask binary> <key file> <ceiling dollars> <model> <seeds dir> <results.tsv> <scratch dir, empty>
#   <key file>  a file holding the API key. This script never reads it and never prints it: the path goes to `ask`, which reads it.
# Environment: PRICE_IN, PRICE_OUT (dollars per million tokens, default 3 and 15: a deliberately high list price, so the total is an upper bound on the
# bill; the real price of the model is not read from anywhere), ASK_HOST (default api.anthropic.com), ROOTS (a PEM bundle, default the system's).
# The ceiling is checked before each call; the money spent so far is priced from the tokens the API reported, so one call's worth can pass it.
set -u
ask=${1:?ask binary}; key=${2:?key file}; ceiling=${3:?ceiling}; model=${4:?model}; seeds=${5:?seeds dir}; out=${6:?results}; w=${7:?scratch}
host=${ASK_HOST:-api.anthropic.com}; pin=${PRICE_IN:-3}; pout=${PRICE_OUT:-15}
[ -x "$ask" ] && [ -f "$key" ] && [ -d "$seeds" ] || { echo "review: usage" >&2; exit 2; }
ip=$(dscacheutil -q host -a name "$host" 2> /dev/null | awk '/^ip_address:/ {print $2; exit}')
[ -n "$ip" ] || ip=$(getent ahostsv4 "$host" 2> /dev/null | awk '{print $1; exit}')
[ -n "$ip" ] || { echo "review: cannot resolve $host" >&2; exit 1; }
roots=${ROOTS:-}
if [ -z "$roots" ]; then for f in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt; do [ -f "$f" ] && { roots=$f; break; }; done; fi
[ -n "$roots" ] || { echo "review: no CA bundle" >&2; exit 1; }
mkdir -p "$w" || exit 2
printf 'seed\tfate\tverdict\titems\tin_tokens\tout_tokens\tcost_usd\tmodel\n' > "$out"
total=0; stopped=0
for d in "$seeds"/*/; do
  id=$(basename "$d")
  if awk "BEGIN{exit !($total >= $ceiling)}"; then stopped=1; break; fi
  {
    printf 'You review a change to a cancho repository. You are given the change request and the diff, and nothing else. Decide whether the diff does what the request says without breaking what the code did before or must do. Read the diff line by line.\n\n'
    printf 'Answer with one JSON object and nothing else: {"verdict":"approve"|"concerns","items":[{"file":"<path>","line":<number>,"claim":"<one sentence a person can check>"}]}. Use "approve" only if you found nothing to object to (then items is []). Use "concerns" if you found a defect or a doubt, with at most 20 items.\n\n'
    printf '=== CHANGE REQUEST ===\n'; cat "$d/brief.txt"
    printf '\n=== DIFF ===\n'; cat "$d/change.patch"
  } > "$w/$id.prompt"
  rm -f "$w/$id.reply" "$w/$id.usage"
  "$ask" --model "$model" --key-file "$key" --host "$host" --ip "$ip" --roots "$roots" --prompt "$w/$id.prompt" --out "$w/$id.reply" --usage "$w/$id.usage" --max-tokens 2048 > "$w/$id.log" 2>&1
  rc=$?
  verdict=none; items=0; tin=0; tout=0; cost=0
  if [ "$rc" = 0 ]; then
    verdict=$(tr -d '\n' < "$w/$id.reply" | sed -n 's/.*"verdict"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -1); [ -n "$verdict" ] || verdict=unparsed
    items=$(grep -o '"claim"' "$w/$id.reply" | wc -l | tr -d ' ')
    set -- $(tail -1 "$w/$id.usage" | tr '=' ' ')
    tin=${2:-0}; tout=${4:-0}
    cost=$(awk "BEGIN{printf \"%.5f\", ($tin * $pin + $tout * $pout) / 1000000}")
    total=$(awk "BEGIN{printf \"%.5f\", $total + $cost}")
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(cat "$d/fate")" "$verdict" "$items" "$tin" "$tout" "$cost" "$model" >> "$out"
  echo "review: $id fate=$(cat "$d/fate") verdict=$verdict items=$items spent=\$$total"
done
[ "$stopped" = 0 ] || echo "review: STOPPED at the ceiling (\$$total of \$$ceiling)"
# the reading: agreement and the false-approval rate (docs/reviewer.md section 5)
awk -F'\t' 'NR>1 { n++; if ($2=="correct") { c++; if ($3=="approve") ca++ } else { f++; if ($3=="approve") fa++ } if (($2=="correct" && $3=="approve") || ($2=="faulty" && $3=="concerns")) agree++ }
  END { printf "seeds %d  agreement %d/%d  false approvals %d/%d (faulty approved)  false concerns %d/%d (correct flagged)\n", n, agree, n, fa+0, f, c-ca, c }' "$out"
echo "spent \$$total (priced at \$$pin / \$$pout per million tokens in/out; the ceiling was \$$ceiling)"
