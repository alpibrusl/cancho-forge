# Process-table questions for the checks of this repository (docs/self-hosting.md, D7). Source it: `. scripts/procs.sh`.
#
# `pgrep -x gate_runner` answered "is a runner still running?" and so also counted the runner that was running the gate
# itself, which made the gate fail under `forge gate` ("the gate is not re-entrant", measured 2026-10-21). The question each
# check means is "did *my* run leave something behind?". The processes that are not the asker's own are the ones that are
# not among its ancestors: the runner above us is expected, a runner beside us is a leak.
#
#   ancestors            the pids of this shell and of every process above it, one per line (read from /proc)
#   leftover pgrep-args  the pids `pgrep` finds that are not ancestors and not zombies, one per line; succeeds when there
#                        is one. A zombie (state Z) is a process that has ended and is waiting for its parent to collect it:
#                        it runs nothing, and a killed child can stay one for as long as the parent is slow to wait.
#
# `leftover -x gate_runner`, `leftover -f '^sleep 79$'`, `leftover -f 'git rev-parse HEAD'`. No `ps`: /proc/PID/stat.

ancestors() {
  _pid=$$
  _depth=0
  # at most 256 levels: a process table does not nest deeper, and a loop in it (or a misread field) must not hang a check
  while [ -n "$_pid" ] && [ "$_pid" -gt 0 ] 2> /dev/null && [ "$_depth" -lt 256 ]; do
    _depth=$((_depth + 1))
    echo "$_pid"
    # the fields after the command name, which is in parentheses and may hold spaces: state, then the parent's pid
    _pid=$(sed 's/^.*) //' "/proc/$_pid/stat" 2> /dev/null | cut -d' ' -f2)
  done
}

leftover() {
  pgrep "$@" | grep -vxF "$(ancestors)" | while read -r _p; do
    _state=$(sed 's/^.*) //' "/proc/$_p/stat" 2> /dev/null | cut -c1)
    if [ -n "$_state" ] && [ "$_state" != Z ]; then
      echo "$_p"
    fi
  done | grep .
}
