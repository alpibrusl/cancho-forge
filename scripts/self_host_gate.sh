#!/bin/sh
# Run the gate of one repository at one revision through Forge, the way the first self-hosted task does (docs/self-hosting.md
# section 3.1 and D7), and print what Forge recorded. An operator's tool, outside the gate: it builds `forge` and
# `gate_runner` from this tree, makes a checkout of <source> at <revision>, an empty execution directory and a workspace, and
# runs `forge gate` with the environment given as NAME=value arguments (the operator's, D7). Nothing in <source> is changed.
#
# Usage: CANCHO=path/to/cancho scripts/self_host_gate.sh <repo key> <source repository> <revision> <scratch directory, new> \
#          [timeout-ms] [NAME=value ...]
#   e.g. scripts/self_host_gate.sh alpibrusl/cancho-forge /path/to/cancho-forge <40 hex> /tmp/run1 900000 \
#          PATH=/path/to/cancho/target/release CANCHO_CACHE=/tmp/run1/cache HOME=/tmp/run1/home
# Exit status: that of `forge gate` (docs/self-hosting.md section 3.1), or 2 for usage.
set -u
C="${CANCHO:-cancho}"
if [ $# -lt 4 ]; then
  echo "usage: self_host_gate.sh <repo key> <source repository> <revision> <scratch directory, new> [timeout-ms] [NAME=value ...]" >&2
  exit 2
fi
repo=$1; source=$2; revision=$3; scratch=$4; shift 4
cd "$(dirname "$0")/.." || exit 1
mkdir "$scratch" || exit 2
mkdir "$scratch/workers" "$scratch/ws" "$scratch/ev" "$scratch/cache" "$scratch/home" || exit 2
libs=$(ls src/*.cho | grep -v '/main\.cho$')
$C build src/*.cho --std -o "$scratch/forge" || exit 1
$C build workers/gate_runner.cho $libs --std -o "$scratch/workers/gate_runner" || exit 1
git clone -q --no-checkout "$source" "$scratch/checkout" || exit 1
git -C "$scratch/checkout" checkout -q "$revision" || exit 1
echo "== forge gate $repo @ $revision"
start=$(date +%s)
"$scratch/forge" gate "$scratch/ws" "$scratch/workers" "$repo" "$revision" "$scratch/checkout" "$scratch/ev" "$@"
status=$?
end=$(date +%s)
echo "== exit status $status, $((end - start)) s wall clock"
echo "== report.json"; cat "$scratch/ev/report.json" 2> /dev/null; echo
echo "== gate.log (last 15 lines)"; tail -15 "$scratch/ev/gate.log" 2> /dev/null
echo "== history"; "$scratch/forge" history "$scratch/ws"
exit "$status"
