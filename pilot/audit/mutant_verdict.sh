#!/bin/sh
# Sourced by self_check_mutants.sh. `mutant_verdict <audit's standard output> <k>`: what a mutant's run of the audit through k cases means. Prints one word:
#   caught   the audit's last line is `TOTAL a/k` with a < k (some case noticed the fault)
#   hole     `TOTAL k/k` (no case noticed it)
#   crashed  anything else: no TOTAL line, a TOTAL of another size, an empty file. An audit that died is NOT a catch (rule `mutant-audit-crashed`, docs/pilot-audit.md section 5.2).
mutant_verdict() {
  _last=$(tail -1 "$1" 2>/dev/null)
  case "$_last" in
    "TOTAL "[0-9]*/[0-9]*)
      _t=${_last#TOTAL }; _a=${_t%/*}; _b=${_t#*/}
      case "$_a$_b" in *[!0-9]*) echo crashed; return ;; esac
      if [ "$_b" != "$2" ]; then echo crashed
      elif [ "$_a" -lt "$2" ]; then echo caught
      else echo hole; fi ;;
    *) echo crashed ;;
  esac
}
