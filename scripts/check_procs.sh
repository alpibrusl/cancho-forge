#!/bin/sh
# The helper of scripts/procs.sh against real processes: a leak is found, an ancestor is not, and an ancestor does not hide a
# leak beside it. A probe is a copy of `sleep` or `sh` under a name that nothing else on the machine has, so that
# `pgrep -x` can name it. Prints `ok ...` / `FAIL ...` lines; exit 1 if any FAIL. Used by scripts/gate.sh and by
# scripts/mutate_procs.py (which runs it on a copy of the tree with one break).
# Usage: scripts/check_procs.sh <scratch directory, empty>
set -u
cd "$(dirname "$0")/.." || exit 1
root=$(pwd)
scratch=$1
fail=0
ok() { echo "ok   procs: $1"; }
bad() { echo "FAIL procs: $1"; fail=1; }
mkdir "$scratch/a" "$scratch/b" "$scratch/c" || exit 1
sleep_bin=$(command -v sleep)
timeout_bin=$(command -v timeout)
name=forgeprobe$$
# `b/NAME` is a sleeper (what leaks); `a/NAME` is `timeout`, which starts its command as a child and waits for it, as the
# gate runner does: the asker runs below it. (A copy of `sh` would not do: the helper's own subshells would carry the name.)
cp "$sleep_bin" "$scratch/b/$name" && cp "$timeout_bin" "$scratch/a/$name" && cp "$(command -v xargs)" "$scratch/c/$name" || exit 1

# 1. a leak: a probe running beside the asker is found, and is gone once it is killed
"$scratch/b/$name" 60 & leaked=$!
sleep 0.3
if sh -c ". '$root/scripts/procs.sh'; leftover -x $name" > "$scratch/found" && [ "$(cat "$scratch/found")" = "$leaked" ]; then
  ok "a probe beside the asker is a leftover, and the pid is the probe's"
else
  bad "a probe beside the asker was not found as the only leftover (got: $(cat "$scratch/found" 2> /dev/null))"
fi
kill "$leaked" 2> /dev/null; wait "$leaked" 2> /dev/null
if sh -c ". '$root/scripts/procs.sh'; leftover -x $name" > /dev/null; then
  bad "a killed probe is still a leftover"
else
  ok "nothing is left once the probe is killed"
fi

# 2. an ancestor: the asker runs inside a process of that name (the runner that is running the gate): not a leftover
if "$scratch/a/$name" 30 sh -c ". '$root/scripts/procs.sh'; leftover -x $name" > "$scratch/found"; then
  bad "the asker's own process was reported as a leftover (got: $(cat "$scratch/found"))"
else
  ok "the process the asker runs in is not a leftover"
fi

# 3. a grandparent: the asker is two levels below a process of that name
if "$scratch/a/$name" 30 sh -c "sh -c \". '$root/scripts/procs.sh'; leftover -x $name\"" > "$scratch/found"; then
  bad "an ancestor two levels up was reported as a leftover (got: $(cat "$scratch/found"))"
else
  ok "an ancestor two levels up is not a leftover"
fi

# 4. both: inside such a process, a probe of the same name started beside the asker is still found, and only it
"$scratch/a/$name" 30 sh -c "$scratch/b/$name 60 & leaked=\$!; sleep 0.3; . '$root/scripts/procs.sh'; leftover -x $name > '$scratch/found4'; echo \$leaked > '$scratch/leaked4'; kill \$leaked"
if [ -s "$scratch/found4" ] && [ "$(cat "$scratch/found4")" = "$(cat "$scratch/leaked4")" ]; then
  ok "an ancestor does not hide a leak beside it: only the leak is reported"
else
  bad "inside an ancestor of the same name, the leak was not the only leftover (found: $(cat "$scratch/found4" 2> /dev/null), leak: $(cat "$scratch/leaked4" 2> /dev/null))"
fi

# 5. an ancestor that leads no process group of its own (`timeout` above does): it is found by its pid, not by its group
if echo x | "$scratch/c/$name" sh -c ". '$root/scripts/procs.sh'; leftover -x $name" > "$scratch/found5"; then
  bad "an ancestor that is not a group leader was reported as a leftover (got: $(cat "$scratch/found5"))"
else
  ok "an ancestor that leads no group of its own is not a leftover"
fi

# 6. a zombie is not a leftover: a probe that ended, under a parent that never waits for it, is still in the process table
sh -c "$scratch/b/$name 0 & exec sleep 4" & parent=$!
sleep 1
if pgrep -x "$name" > /dev/null && ! sh -c ". '$root/scripts/procs.sh'; leftover -x $name" > "$scratch/found6"; then
  ok "a probe that has ended and waits to be collected (a zombie) is not a leftover"
else
  bad "a zombie was reported as a leftover, or the zombie was not made (found: $(cat "$scratch/found6" 2> /dev/null))"
fi
kill "$parent" 2> /dev/null; wait "$parent" 2> /dev/null

# 7. the matching by command line works the same way
"$scratch/b/$name" 61 & leaked=$!
sleep 0.3
if sh -c ". '$root/scripts/procs.sh'; leftover -f '$name 61'" > /dev/null; then
  ok "a leftover is found by its command line too"
else
  bad "a leftover was not found by its command line"
fi
kill "$leaked" 2> /dev/null; wait "$leaked" 2> /dev/null
exit "$fail"
