#!/bin/sh
# The stand-in for Cancho Code's `cancho-build --repo DIR --change FILE --kind K --checker C --work W --agent A --provider P --model M`
# (cancho-code docs/repo-patch.md), used by tests/conformance/repo_change.sh and tests/conformance/company_change.sh. The first line of the
# change file says what to do. Like the real tool it works on a copy of --repo inside the work directory (base/ and tree/), writes
# `change.patch` as `diff -ruN base tree`, prints `[CHANGE_VERDICT]` and exits 0 (done), 1 (stuck), 2 (usage) or 4 (provider error).
# It is a test oracle's fixture, not product logic: nothing Forge decides is written in it. It is copied to `cancho-build` in a tools directory.
repo= change= work= kind=
prev=
for a in "$@"; do
  case "$prev" in
    --repo) repo=$a ;;
    --change) change=$a ;;
    --work) work=$a ;;
    --kind) kind=$a ;;
  esac
  prev=$a
done
[ -n "$repo" ] && [ -n "$change" ] && [ -n "$work" ] || { echo 'usage: cancho-build --repo DIR --change FILE --work W ...' >&2; exit 2; }
read -r mode arg < "$change"
mkdir -p "$work" || exit 2
for a in "$@"; do printf 'A:%s\n' "$a"; done > "$work/args.txt"
# a changed copy: base/ (pristine) and tree/ (edited by $1 below), then the patch
prepare() { rm -rf "$work/base" "$work/tree"; cp -r "$repo" "$work/base"; cp -r "$repo" "$work/tree"; }
finish() { (cd "$work" && diff -ruN base tree > change.patch); printf '[CHANGE_PATCH]\t%s/change.patch\n[CHANGE_VERDICT]\tdone\n' "$work"; exit 0; }
usage() { printf '{"provider":"stand","model":"m1","task":"t","sample":0,"in":%s,"out":10,"thinking":0,"cache_write":0,"cache_read":0,"stop":"end_turn","outcome":"ok","status":200,"reply_chars":1,"program_chars":1,"ms":1}\n' "$1" >> "$work/usage.jsonl"; }
case "$mode" in
  good|The)  # `The`: the first word of every request Forge frames for a derived step (docs/company.md section 19): it edits like `good`
             prepare; printf 'edited\n' >> "$work/tree/src/a.cho"; finish ;;
  spend)     prepare; usage 600; usage 500; printf 'edited\n' >> "$work/tree/src/a.cho"; finish ;;
  outside)   prepare; printf 'more\n' >> "$work/tree/docs/x.md"; finish ;;
  denied)    prepare; printf 'more\n' >> "$work/tree/src/secret/k.cho"; finish ;;
  big)       prepare; i=0; while [ $i -lt 30 ]; do printf 'line %s\n' $i >> "$work/tree/src/a.cho"; i=$((i + 1)); done; finish ;;
  lie)       prepare; printf 'BROKEN\n' >> "$work/tree/src/a.cho"; finish ;;
  rename)    prepare; printf 'diff --git a/src/a.cho b/src/b.cho\nsimilarity index 100%%\nrename from src/a.cho\nrename to src/b.cho\n' > "$work/change.patch"; printf '[CHANGE_VERDICT]\tdone\n'; exit 0 ;;
  binary)    prepare; printf 'Binary files base/src/a.cho and tree/src/a.cho differ\n' > "$work/change.patch"; printf '[CHANGE_VERDICT]\tdone\n'; exit 0 ;;
  stale)     prepare; printf -- '--- base/src/a.cho\n+++ tree/src/a.cho\n@@ -1,3 +1,3 @@\n some other base\n-that is not\n+this repo\n an a.cho\n' > "$work/change.patch"; printf '[CHANGE_VERDICT]\tdone\n'; exit 0 ;;
  nopatch)   prepare; printf '[CHANGE_VERDICT]\tdone\n'; exit 0 ;;
  linkpatch) prepare; ln -s /etc/hostname "$work/change.patch"; printf '[CHANGE_VERDICT]\tdone\n'; exit 0 ;;
  stuck)     prepare; printf '[CHANGE_VERDICT]\tstuck\n'; exit 1 ;;
  provider)  prepare; printf '[CHANGE_VERDICT]\tprovider_error\n'; exit 4 ;;
  usage)     echo 'usage: cancho-build --repo ...' >&2; exit 2 ;;
  hang)      prepare; sleep 79 & printf '%s\n' "$!" > "$work/pids.txt"; wait ;;
  editbase)  # a tool that writes the copy it was given, not only its tree: the checkout and the fresh copy must not change
             prepare; printf 'scribble\n' >> "$repo/src/a.cho"; printf 'edited\n' >> "$work/tree/src/a.cho"; finish ;;
  plant)     # a tool that reaches the real checkout (its path is the change file's second word) and plants a file there
             prepare; printf 'planted\n' > "$arg/planted.txt"; printf 'edited\n' >> "$work/tree/src/a.cho"; finish ;;
  slow)      # waits for a file `release` in the work directory (the kill-and-resume case)
             prepare; : > "$work/building"; while [ ! -e "$work/release" ] && [ ! -e "$arg" ]; do sleep 0.1; done; printf 'edited\n' >> "$work/tree/src/a.cho"; finish ;;
  *)         echo "unknown mode" >&2; exit 2 ;;
esac
