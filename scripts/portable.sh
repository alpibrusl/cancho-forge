# Stand-ins for the two GNU tools the conformance scripts use, defined only where the system lacks them (macOS): `timeout` and `setsid`.
# Sourced by the scripts that need them; on Linux this file defines nothing.
if ! command -v timeout > /dev/null 2>&1; then
  timeout() { # [-k grace] seconds command...: 124 when the seconds ran out, else the command's status
    if [ "$1" = -k ]; then shift 2; fi
    _secs=$1; shift
    _flag=$(mktemp "${TMPDIR:-/tmp}/timeout.XXXXXX") || return 125
    rm -f "$_flag"
    "$@" &
    _pid=$!
    ( sleep "$_secs"; : > "$_flag"; kill -TERM "$_pid" 2> /dev/null; sleep 2; kill -KILL "$_pid" 2> /dev/null ) > /dev/null 2>&1 &
    _guard=$!
    wait "$_pid"; _rc=$?
    kill "$_guard" 2> /dev/null; pkill -P "$_guard" 2> /dev/null; wait "$_guard" 2> /dev/null
    if [ -e "$_flag" ]; then rm -f "$_flag"; return 124; fi
    return "$_rc"
  }
fi
if ! command -v setsid > /dev/null 2>&1; then
  setsid() { # command...: the command in a session of its own (perl's POSIX::setsid, then exec: the process id is the command's)
    perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or exit 127' -- "$@"
  }
fi
