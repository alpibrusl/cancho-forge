#!/bin/sh
# The stand-in for the model reviewer's worker `workers/repo_review.cho` (docs/review-step.md section 7), used by tests/conformance/company_review.sh: it speaks the worker contract
# (one `execute` request on standard input, one response on standard output) and makes no network call. The first word of the step's brief (`brief.txt` in the execution
# directory) says what the "model" answers: approve, concerns, garbage (text that is not a verdict), cut (the worker fails `review-unavailable`), or silent (no `reply.txt`).
# It is a test oracle's fixture, not product logic: Forge parses the reply itself. It appends the request it was given to `requests.log` beside the execution directory.
req=$(cat)
dir=$(printf '%s' "$req" | sed -n 's/.*"execution_dir":"\([^"]*\)".*/\1/p')
rid=$(printf '%s' "$req" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
tid=$(printf '%s' "$req" | sed -n 's/.*"task":{"id":"\([^"]*\)".*/\1/p')
printf '%s\n' "$req" >> "$dir/../requests.log"
read -r mode _ < "$dir/brief.txt"
fail() { printf '{"contract":"forge-worker/1","request_id":"%s","state":"failed","task_id":"%s","summary":"the review failed","evidence":[],"error":{"code":"%s","message":"the review failed","retryable":false}}\n' "$rid" "$tid" "$1"; exit 0; }
printf '{"in":1000,"out":200,"cache_write":0,"cache_read":0}\n' > "$dir/usage.jsonl"
case "$mode" in
  approve) printf '{"verdict":"approve","items":[]}' > "$dir/reply.txt" ;;
  concerns) printf '{"verdict":"concerns","items":[{"file":"src/a.cho","line":3,"claim":"the new line is never read"},{"file":"README.md","line":0,"claim":"no test covers it"}]}' > "$dir/reply.txt" ;;
  garbage) printf 'I think this is fine.' > "$dir/reply.txt" ;;
  fence) printf '```json\n{"verdict":"approve","items":[]}\n```' > "$dir/reply.txt" ;;
  cut) fail review-unavailable ;;
  silent) rm -f "$dir/reply.txt" ;;
esac
ev=""; n=0
for f in reply.txt usage.jsonl; do
  [ -f "$dir/$f" ] || continue
  sha=$( { sha256sum "$dir/$f" 2> /dev/null || shasum -a 256 "$dir/$f"; } | cut -c1-64); bytes=$(wc -c < "$dir/$f" | tr -d ' '); n=$((n + 1))
  [ -n "$ev" ] && ev="$ev,"
  ev="$ev{\"id\":\"ev-$n\",\"kind\":\"file\",\"ref\":\"$f\",\"sha256\":\"$sha\",\"bytes\":$bytes}"
done
printf '{"contract":"forge-worker/1","request_id":"%s","state":"succeeded","task_id":"%s","summary":"model review","evidence":[%s],"error":null}\n' "$rid" "$tid" "$ev"
