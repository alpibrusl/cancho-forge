#!/bin/sh
# The tool runner (workers/tool_run.cho; task 11, docs/worker-contract.md section 12) against real child processes and stand-in
# tools. The program under test is the worker binary, given one request on its standard input as Forge gives it; this script is the
# oracle only (cmp, grep, sha256sum, /proc on what the worker wrote and left behind). The stand-in tools are shell scripts written
# here into a tools directory; each answers `introspect` (or does not) and does one thing: count the lines of its input, hang with
# a grandchild, write too much, exit 3, show its environment and its arguments. Prints `ok ...` / `FAIL ...` lines; exit 1 if any
# FAIL.
# With FORGE_CANCHO_TOOLS=<a directory holding built cancho-tools `tally` and `jsonq`>, the real tools are also run under the
# worker against a fixture check log and their own `introspect` (docs/company.md, "Analyst (tool.run)"); without it that part says
# it was skipped.
# Usage: tests/conformance/tool_run.sh <the built worker> <scratch directory, empty, a path with no component that starts with a dash>
set -u
cd "$(dirname "$0")/../.." || exit 1
bin=$1
t=$2
fail=0
ok() { echo "ok   tool run: $1"; }
bad() { echo "FAIL tool run: $1"; fail=1; }
check() { # name, command...
  name=$1; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
tools="$t/tools"; mkdir "$tools" "$t/outside" || exit 1
echo secret > "$t/outside/s.txt"

# The stand-ins. Their `introspect` prints an object with an `authority` object (the cancho-tools convention), whose exact text is
# the oracle for the SHA-256 the worker records.
auth='{"bounded":true,"effects":["heap","io_write"],"never_touches":["the network"]}'
intro="{\"tool\":\"standin\",\"authority\":$auth,\"guarantees\":{\"deterministic\":true}}"
printf '%s' "$auth" > "$t/auth.txt"
standin() { # name, body (after the introspect answer; $last is the input path)
  printf '#!/bin/sh\nif [ "$1" = introspect ]; then printf %%s %s; exit 0; fi\nfor a; do last=$a; done\n%s\n' "'$intro'" "$2" > "$tools/$1" && chmod +x "$tools/$1" || exit 1
}
standin count 'wc -l < "$last" | tr -d " "'
standin hang 'sleep 89 & echo "$$ $!" > "$(dirname "$last")/pids"; wait'
standin noisy 'head -c 2000000 /dev/zero | tr "\\0" x'
standin exit3 'echo partial; exit 3'
standin show 'echo "path=$PATH"; echo "home=${HOME-unset}"; echo "stdin=$(cat | wc -c | tr -d " ")"; for a; do echo "arg=$a"; done'
printf '#!/bin/sh\nif [ "$1" = introspect ]; then echo "no such command" >&2; exit 2; fi\necho 7\n' > "$tools/nointro" && chmod +x "$tools/nointro" || exit 1
printf '#!/bin/sh\necho never\n' > "$tools/notexec" && chmod 644 "$tools/notexec" || exit 1

granted='["count","hang","noisy","exit3","show","nointro","notexec","absent","tally","jsonq"]'
# request <tag> <tool> <argv json> <input> <timeout> [<type>]: the request for an execution directory $t/ev_<tag>
request() {
  printf '{"contract":"forge-worker/1","verb":"execute","request_id":"r-%s","attempt":1,"task":{"id":"t-%s","type":"%s","input":{"tool":"%s","argv":%s,"input":"%s"}},"limits":{"timeout_ms":%s,"max_output_bytes":1048576},"grants":{"execution_dir":"%s","tools_dir":"%s","granted_tools":%s}}' \
    "$1" "$1" "${6:-tool.run}" "$2" "$3" "$4" "$5" "$t/ev_$1" "$tools" "$granted"
}
go() { # tag tool argv input timeout [type]: run the worker; its stdout in $t/<tag>.out, its status in $t/<tag>.rc
  [ -d "$t/ev_$1" ] || mkdir "$t/ev_$1" || exit 1
  request "$@" > "$t/$1.req"
  "$bin" < "$t/$1.req" > "$t/$1.out"; echo $? > "$t/$1.rc"
}
st() { cat "$t/$1.rc"; }
has() { grep -q "$2" "$t/$1.out"; } # tag, fixed text in the reply
log() { printf 'svc1 up 12\nsvc1 down 0\nsvc2 up 30\nsvc1 up 15\n' > "$t/ev_$1/checks.log"; }
alive() { # pid: running and not a zombie
  s=$(sed 's/^.*) //' "/proc/$1/stat" 2> /dev/null | cut -c1)
  [ -n "$s" ] && [ "$s" != Z ]
}

# ---- capabilities, and the verbs a sync worker is not sent
printf '{"contract":"forge-worker/1","verb":"capabilities","request_id":"r-cap"}' | "$bin" > "$t/cap.out"; echo $? > "$t/cap.rc"
check "capabilities: answered, level sync, task type tool.run" sh -c "[ \$(cat '$t/cap.rc') = 0 ] && grep -q '\"level\":\"sync\"' '$t/cap.out' && grep -q '\"type\":\"tool.run\"' '$t/cap.out'"
printf '{"contract":"forge-worker/1","verb":"cancel","request_id":"r-c","target":"r-1"}' | "$bin" > "$t/cancelverb.out"; echo $? > "$t/cancelverb.rc"
check "a cancel verb is not answered (exit 4, nothing on stdout): a sync worker is cancelled by a signal" sh -c "[ \$(cat '$t/cancelverb.rc') = 4 ] && [ ! -s '$t/cancelverb.out' ]"
printf 'not json' | "$bin" > "$t/junk.out"; echo $? > "$t/junk.rc"
check "a request that is not JSON is not answered (exit 4)" sh -c "[ \$(cat '$t/junk.rc') = 4 ] && [ ! -s '$t/junk.out' ]"

# ---- a run that works: the tool's output is the artifact, the report says how it ended, the manifest is hashed
mkdir "$t/ev_count" && log count
go count count '[]' checks.log 20000
check "count: succeeded, exit 0, the three evidence files named" sh -c "[ '$(st count)' = 0 ] && grep -q '\"state\":\"succeeded\"' '$t/count.out' && grep -q '\"ref\":\"tool.out\"' '$t/count.out' && grep -q '\"ref\":\"report.json\"' '$t/count.out' && grep -q '\"ref\":\"introspect.json\"' '$t/count.out'"
check "count: tool.out is what the tool printed (4 lines counted)" sh -c "[ \"\$(cat '$t/ev_count/tool.out')\" = 4 ]"
check "count: the report records exit 0, ending exited, not truncated" sh -c "grep -q '\"ending\":\"exited\",\"exit_status\":0' '$t/ev_count/report.json' && grep -q '\"stdout_truncated\":false' '$t/ev_count/report.json'"
check "count: the report records the SHA-256 of the tool's own authority manifest (forge#41)" grep -q "\"authority_manifest\":{\"source\":\"introspect\",\"sha256\":\"$(sha256sum "$t/auth.txt" | cut -c1-64)\"}" "$t/ev_count/report.json"
check "count: the evidence digests are the files' (sha256sum)" sh -c "has() { grep -q \"\$2\" '$t/count.out'; }; has x \"\$(sha256sum '$t/ev_count/tool.out' | cut -c1-64)\" && has x \"\$(sha256sum '$t/ev_count/report.json' | cut -c1-64)\""
check "count: the input is passed by absolute path, last" grep -q "\"input\":\"$t/ev_count/checks.log\"" "$t/ev_count/report.json"
cp "$t/ev_count/tool.out" "$t/count.out1"; cp "$t/ev_count/report.json" "$t/count.rep1"; cp "$t/count.out" "$t/count.reply1"
go count count '[]' checks.log 20000
check "deterministic: the same request writes the same bytes twice (tool.out, report.json, the reply)" sh -c "cmp -s '$t/count.out1' '$t/ev_count/tool.out' && cmp -s '$t/count.rep1' '$t/ev_count/report.json' && cmp -s '$t/count.reply1' '$t/count.out'"

# ---- the environment, the arguments, the input
mkdir "$t/ev_show" && log show
go show show '["--field","3","a b","$(rm -rf /)","café"]' checks.log 20000
printf 'path=/usr/local/bin:/usr/bin:/bin\nhome=unset\nstdin=0\narg=--field\narg=3\narg=a b\narg=$(rm -rf /)\narg=café\narg=%s\n' "$t/ev_show/checks.log" > "$t/want_show"
check "show: PATH alone, no HOME, an empty stdin, the argv as given (no shell), then the input" cmp -s "$t/ev_show/tool.out" "$t/want_show"
check "show: the report repeats the argv" grep -q '"argv":\["--field","3","a b","$(rm -rf /)","café"\]' "$t/ev_show/report.json"

# ---- refusals: nothing runs, nothing is written
for tag in unlisted unlisted2 nonarray badelem nlarg emptyarg escape abs sibling type limits absentin linkin dirin notexec absent; do mkdir "$t/ev_$tag" || exit 1; done
for tag in unlisted unlisted2 nonarray badelem nlarg emptyarg escape abs sibling type limits notexec absent; do log "$tag"; done
go unlisted seek '[]' checks.log 20000
go unlisted2 '../count' '[]' checks.log 20000
check "a tool the operator did not grant is tool-not-granted; nothing ran" sh -c "has() { grep -q \"\$2\" \"$t/\$1.out\"; }; has unlisted '\"code\":\"tool-not-granted\"' && has unlisted2 '\"code\":\"tool-not-granted\"' && has unlisted '\"state\":\"failed\"' && [ \$(ls -A '$t/ev_unlisted') = checks.log ]"
go nonarray count '"--field 3"' checks.log 20000
go badelem count '["--top",10]' checks.log 20000
go nlarg count '["a\\nb"]' checks.log 20000
go emptyarg count '[""]' checks.log 20000
check "an argv that is shell text, has a number, an escape (a newline) or an empty string is argv-malformed" sh -c "for x in nonarray badelem nlarg emptyarg; do grep -q '\"code\":\"argv-malformed\"' \"$t/\$x.out\" || exit 1; [ \$(ls -A \"$t/ev_\$x\") = checks.log ] || exit 1; done"
go escape count '[]' ../outside/s.txt 20000
go abs count '[]' "$t/outside/s.txt" 20000
go sibling count '[]' "$t/ev_count/checks.log" 20000
check "an input that escapes the execution directory (.., an absolute path elsewhere, a sibling) is path-invalid" sh -c "for x in escape abs sibling; do grep -q '\"code\":\"path-invalid\"' \"$t/\$x.out\" || exit 1; [ \$(ls -A \"$t/ev_\$x\") = checks.log ] || exit 1; done"
go type count '[]' checks.log 20000 repo.gate
go limits count '[]' checks.log 1999
check "a task type other than tool.run is task-type-invalid; a deadline under 2 s is limits-invalid" sh -c "grep -q '\"code\":\"task-type-invalid\"' '$t/type.out' && grep -q '\"code\":\"limits-invalid\"' '$t/limits.out'"
ln -s "$t/outside/s.txt" "$t/ev_linkin/checks.log" || exit 1
mkdir "$t/ev_dirin/checks.log" || exit 1
go absentin count '[]' checks.log 20000
go linkin count '[]' checks.log 20000
go dirin count '[]' checks.log 20000
check "an input that is absent, a link (to a file outside) or a directory is input-unusable; nothing written" sh -c "for x in absentin linkin dirin; do grep -q '\"code\":\"input-unusable\"' \"$t/\$x.out\" || exit 1; done; [ -z \"\$(ls -A '$t/ev_absentin')\" ] && [ \$(ls -A '$t/ev_linkin') = checks.log ]"
go notexec notexec '[]' checks.log 20000
go absent absent '[]' checks.log 20000
check "a granted tool that cannot be started (not executable, not there) is tool-unusable; nothing written" sh -c "grep -q '\"code\":\"tool-unusable\"' '$t/notexec.out' && grep -q '\"code\":\"tool-unusable\"' '$t/absent.out' && [ \$(ls -A '$t/ev_notexec') = checks.log ] && [ \$(ls -A '$t/ev_absent') = checks.log ]"
check "every refusal is a valid failed reply with no evidence" sh -c "for x in unlisted nonarray escape type absentin notexec; do grep -q '\"state\":\"failed\".*\"evidence\":\[\]' \"$t/\$x.out\" || exit 1; done"

check "dirin: nothing was written beside the directory named as input" sh -c "[ \$(ls -A '$t/ev_dirin') = checks.log ]"
mkdir "$t/ev_midlink" && ln -s "$t/outside" "$t/ev_midlink/sub" || exit 1
go midlink count '[]' sub/s.txt 20000
check "an input reached through a link to a directory outside (sub/s.txt, sub a link) is input-unusable; nothing written" sh -c "grep -q '\"code\":\"input-unusable\"' '$t/midlink.out' && [ \$(ls -A '$t/ev_midlink') = sub ]"
mkdir "$t/ev_ownin" && log ownin
go ownin count '[]' tool.out 20000
check "an input that names one of the runner's own files (tool.out) is path-invalid; nothing written" sh -c "grep -q '\"code\":\"path-invalid\"' '$t/ownin.out' && [ \$(ls -A '$t/ev_ownin') = checks.log ]"

# ---- the evidence is never written through a link, and a name that cannot be replaced is evidence-unwritable
mkdir "$t/ev_evdir" "$t/ev_evdir/tool.out" && log evdir
go evdir count '[]' checks.log 20000
check "a directory at tool.out: failed evidence-unwritable, no evidence named, the directory left" sh -c "grep -q '\"state\":\"failed\"' '$t/evdir.out' && grep -q '\"code\":\"evidence-unwritable\"' '$t/evdir.out' && grep -q '\"evidence\":\[\]' '$t/evdir.out' && [ -d '$t/ev_evdir/tool.out' ]"
mkdir "$t/ev_links" && log links
for f in tool.out report.json introspect.json tool.tmp; do echo keep > "$t/outside/$f.target"; ln -s "$t/outside/$f.target" "$t/ev_links/$f" || exit 1; done
go links count '[]' checks.log 20000
check "links planted at tool.out, report.json, introspect.json and tool.tmp are replaced, never written through: succeeded, regular files, the outside files untouched" sh -c "grep -q '\"state\":\"succeeded\"' '$t/links.out' && for f in tool.out report.json introspect.json; do [ -f '$t/ev_links/'\$f ] && [ ! -L '$t/ev_links/'\$f ] || exit 1; done && [ ! -e '$t/ev_links/tool.tmp' ] && for f in tool.out report.json introspect.json tool.tmp; do [ \"\$(cat '$t/outside/'\$f.target)\" = keep ] || exit 1; done && [ \"\$(cat '$t/ev_links/tool.out')\" = 4 ]"

# ---- exit status, no manifest, the output cap, the deadline, the cancel
mkdir "$t/ev_exit3" && log exit3
go exit3 exit3 '[]' checks.log 20000
check "exit3: succeeded (the tool's status is the check's to judge), exit status 3 recorded, its output kept" sh -c "has() { grep -q \"\$2\" \"$t/\$1.out\"; }; has exit3 '\"state\":\"succeeded\"' && grep -q '\"ending\":\"exited\",\"exit_status\":3' '$t/ev_exit3/report.json' && [ \"\$(cat '$t/ev_exit3/tool.out')\" = partial ]"
mkdir "$t/ev_nointro" && log nointro
go nointro nointro '[]' checks.log 20000
check "nointro: no manifest is invented: source unavailable, sha256 null, and why" sh -c "grep -q '\"authority_manifest\":{\"source\":\"unavailable\",\"sha256\":null,\"note\":\"the tool' '$t/ev_nointro/report.json' && [ \"\$(cat '$t/ev_nointro/tool.out')\" = 7 ] && ! grep -q introspect.json '$t/nointro.out'"
mkdir "$t/ev_noisy" && log noisy
go noisy noisy '[]' checks.log 20000
check "noisy: failed tool-output-overflow, tool.out cut at exactly 1 MiB, the report marks it truncated" sh -c "grep -q '\"code\":\"tool-output-overflow\"' '$t/noisy.out' && [ \$(wc -c < '$t/ev_noisy/tool.out') -eq 1048576 ] && grep -q '\"ending\":\"output-overflow\"' '$t/ev_noisy/report.json' && grep -q '\"stdout_bytes\":1048576,\"stdout_cap\":1048576,\"stdout_truncated\":true' '$t/ev_noisy/report.json'"
mkdir "$t/ev_hang" && log hang
start=$(date +%s%N)
go hang hang '[]' checks.log 3000
took=$(( ($(date +%s%N) - start) / 1000000 ))
check "hang: failed tool-timeout inside Forge's deadline (the runner's is 4/5 of 3 s), the report says timeout" sh -c "grep -q '\"code\":\"tool-timeout\"' '$t/hang.out' && grep -q '\"ending\":\"timeout\"' '$t/ev_hang/report.json' && [ $took -lt 3000 ]"
check "hang: the tool and its grandchild are gone: its whole group was killed (the two recorded pids, exactly)" sh -c "read p g < '$t/ev_hang/pids' && [ -n \"\$p\" ] && [ -n \"\$g\" ] && for x in \$p \$g; do s=\$(sed 's/^.*) //' /proc/\$x/stat 2> /dev/null | cut -c1); [ -z \"\$s\" ] || [ \"\$s\" = Z ] || exit 1; done"
mkdir "$t/ev_cancel" && log cancel
request cancel hang '[]' checks.log 60000 > "$t/cancel.req"
"$bin" < "$t/cancel.req" > "$t/cancel.out" &
wpid=$!
n=0; while [ ! -s "$t/ev_cancel/pids" ] && [ $n -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
read cp cg < "$t/ev_cancel/pids"
check "cancel: the tool and its grandchild run before the signal" sh -c "s1=\$(sed 's/^.*) //' /proc/$cp/stat | cut -c1); s2=\$(sed 's/^.*) //' /proc/$cg/stat | cut -c1); [ \"\$s1\" != Z ] && [ \"\$s2\" != Z ]"
kill -TERM "$wpid"
wait "$wpid"; echo $? > "$t/cancel.rc"
check "cancel: a TERM to the worker ends the run cancelled (error tool-cancelled), the worker exits 0 and answers" sh -c "[ \$(cat '$t/cancel.rc') = 0 ] && grep -q '\"state\":\"cancelled\"' '$t/cancel.out' && grep -q '\"code\":\"tool-cancelled\"' '$t/cancel.out' && grep -q '\"ending\":\"cancelled\"' '$t/ev_cancel/report.json'"
check "cancel: the tool's whole group is gone (both recorded pids)" sh -c "for x in $cp $cg; do s=\$(sed 's/^.*) //' /proc/\$x/stat 2> /dev/null | cut -c1); [ -z \"\$s\" ] || [ \"\$s\" = Z ] || exit 1; done"

# ---- nothing left: every live process whose command line names an execution directory of this script (a tool is given its input
# by path) or whose working directory is the tools directory (a tool and what it starts run there)
sleep 0.2
left=$(for p in $(grep -lF "$t/ev_" /proc/[0-9]*/cmdline 2> /dev/null | cut -d/ -f3) $(find /proc/[0-9]*/cwd -maxdepth 0 -lname "$tools" 2> /dev/null | cut -d/ -f3); do
  alive "$p" && echo "$p"
done)
check "no process the runs started is left" [ -z "$left" ]

# ---- the real cancho-tools, when built (task 11 step 3)
if [ -n "${FORGE_CANCHO_TOOLS-}" ] && [ -x "$FORGE_CANCHO_TOOLS/tally" ] && [ -x "$FORGE_CANCHO_TOOLS/jsonq" ]; then
  cp "$FORGE_CANCHO_TOOLS/tally" "$FORGE_CANCHO_TOOLS/jsonq" "$tools/" || exit 1
  mkdir "$t/ev_tally" "$t/ev_jsonq" && log tally || exit 1
  printf '{"services":{"svc1":{"checks":3,"up":2}},"checks":4}' > "$t/ev_jsonq/summary.json"
  go tally tally '["--field","2","--delim"," "]' checks.log 20000
  go jsonq jsonq '["-p","/checks"]' summary.json 20000
  # the oracle for the manifest: the bytes of the `authority` object of the tool's own `introspect`, brace-matched outside the program
  span() { python3 -I -c 'import sys
t=open(sys.argv[1],encoding="utf-8").read(); k=t.index("\"authority\":")+len("\"authority\":"); d=0
for j in range(k,len(t)):
    d+= t[j]=="{"; d-= t[j]=="}"
    if d==0: break
sys.stdout.write(t[k:j+1])' "$1"; }
  "$tools/tally" introspect > "$t/tally.intro"; "$tools/jsonq" introspect > "$t/jsonq.intro"
  tally_auth=$(span "$t/tally.intro" | sha256sum | cut -c1-64); jsonq_auth=$(span "$t/jsonq.intro" | sha256sum | cut -c1-64)
  check "cancho-tools tally: succeeded, counts the status field (3 up, 1 down), the manifest hash is introspect's authority" sh -c "grep -q '\"state\":\"succeeded\"' '$t/tally.out' && grep -q '\"total\":4,\"distinct\":2' '$t/ev_tally/tool.out' && grep -q '{\"key\":\"up\",\"count\":3},{\"key\":\"down\",\"count\":1}' '$t/ev_tally/tool.out' && grep -q '\"sha256\":\"$tally_auth\"' '$t/ev_tally/report.json'"
  check "cancho-tools jsonq: succeeded, reads /checks = 4, the manifest hash is introspect's authority" sh -c "grep -q '\"state\":\"succeeded\"' '$t/jsonq.out' && grep -q '\"value\":4' '$t/ev_jsonq/tool.out' && grep -q '\"sha256\":\"$jsonq_auth\"' '$t/ev_jsonq/report.json'"
  cp "$t/ev_tally/tool.out" "$t/tally.1"
  go tally tally '["--field","2","--delim"," "]' checks.log 20000
  check "cancho-tools tally: the same bytes twice" cmp -s "$t/tally.1" "$t/ev_tally/tool.out"
else
  echo "skip tool run: the real cancho-tools (set FORGE_CANCHO_TOOLS to a directory holding built tally and jsonq)"
fi
exit "$fail"
