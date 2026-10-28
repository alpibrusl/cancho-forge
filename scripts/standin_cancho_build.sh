#!/bin/sh
# The stand-in for Cancho Code's build tool `cancho-build <checker> <brief> <workdir> <agent> --provider P --model M ...`, shared by
# scripts/check_cancho_code.sh (the adapter alone) and scripts/check_build_run.sh (`forge build` end to end). The first line of
# the brief says what to do: finish, get stuck, fail the gate or the plan, hit a provider error, refuse its arguments, lie about
# its verdict, write junk, hang with a grandchild, write too much, be killed. It is a test oracle's fixture, not product logic:
# nothing Forge decides is written in it. It is copied to `cancho-build` in a tools directory and run as that.
brief=$2
work=$3
read -r mode < "$brief"
log() { printf 'ran\n' > "$work/run.log"; }
report() { # stage units_verified verdict
  printf '{"brief":"b","stage":"%s","plan_valid":true,"units_total":2,"units_verified":%s,"verdict":"%s"}\n' "$1" "$2" "$3" > "$work/build.json"
}
case "$mode" in
  done)      log; report done 2 done; printf 'product\n' > "$work/project.cho"; printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;
  stuck)     log; report done 1 stuck; printf 'product\n' > "$work/project.cho"; printf '[BUILD_VERDICT]\tstuck\n'; exit 1 ;;
  stuck0)    log; report done 0 stuck; printf '[BUILD_VERDICT]\tstuck\n'; exit 1 ;;
  gate)      log; report done 2 gate_failed; printf 'product\n' > "$work/project.cho"; printf '[BUILD_VERDICT]\tgate_failed\n'; exit 1 ;;
  plan)      log; report plan 0 plan_failed; printf '[BUILD_VERDICT]\tplan_failed\n'; exit 3 ;;
  provider)  log; report build 1 provider_error; printf 'product\n' > "$work/project.cho"; printf '[BUILD_VERDICT]\tprovider_error\n'; exit 4 ;;
  usage)     echo 'usage: cancho-build ...' >&2; exit 2 ;;
  disagree)  log; report done 2 done; printf '[BUILD_VERDICT]\tdone\n'; exit 1 ;;
  disagree0) log; report done 1 stuck; printf '[BUILD_VERDICT]\tstuck\n'; exit 0 ;;
  badjson)   log; printf 'this is not json\n' > "$work/build.json"; exit 0 ;;
  nojson)    log; exit 0 ;;
  link)      log; printf '{"verdict":"done","units_verified":9}\n' > "$work/../outside_secret.json"; ln -s "$work/../outside_secret.json" "$work/build.json"; exit 0 ;;
  hang)      log; report build 0 ""; sleep 79 & wait ;;
  noisy)     log; report build 0 ""; head -c 1100000 /dev/zero | tr '\0' x ;;
  sig)       log; kill -9 $$ ;;
  spend)     # the company layer's budget (tests/conformance/company_run.sh): a build that ends done and, as the real agent does,
             # leaves one usage.jsonl line per call: two calls, 600 + 500 input tokens, 10 + 20 output
             log; report done 2 done; printf 'product\n' > "$work/project.cho"
             printf '{"provider":"stand","model":"m1","task":"t","sample":0,"in":600,"out":10,"thinking":0,"cache_write":0,"cache_read":0,"stop":"end_turn","outcome":"ok","status":200,"reply_chars":1,"program_chars":1,"ms":1}\n' >> "$work/usage.jsonl"
             printf '{"provider":"stand","model":"m1","task":"t","sample":0,"in":500,"out":20,"thinking":0,"cache_write":0,"cache_read":0,"stop":"end_turn","outcome":"ok","status":200,"reply_chars":1,"program_chars":1,"ms":1}\n' >> "$work/usage.jsonl"
             printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;
  linkart)   log; report done 2 done; printf 'secret\n' > "$work/../../../outside_artifact.txt"; ln -s "$work/../../../outside_artifact.txt" "$work/project.cho"; printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;  # company_run.sh
  needs)     # task 8c (company_run.sh): a build that needs another step. Its product is what Forge gave it in its execution
             # directory, needs.json and then each copy, so the oracle can see that it arrived.
             log; report done 2 done; { cat "$work/needs.json"; for f in "$work"/needs-*; do cat "$f"; done; } > "$work/project.cho" 2> /dev/null
             printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;
  contract|contractmut)
             # task 10 (company_run.sh): a build that is given a contract. It records its argument vector (args.txt) and its product
             # is the contract file as it read it from the path after `--contract` (or `nocontract` when it was not given one).
             # `contractmut` then appends to that file: a build that changes its contract.
             log; report done 2 done; for a in "$@"; do printf 'A:%s\n' "$a"; done > "$work/args.txt"
             c=; prev=; for a in "$@"; do if [ "$prev" = --contract ]; then c=$a; fi; prev=$a; done
             if [ -n "$c" ]; then cat "$c" > "$work/project.cho"; else printf 'nocontract\n' > "$work/project.cho"; fi
             if [ "$mode" = contractmut ] && [ -n "$c" ]; then printf 'tampered\n' >> "$c"; fi
             printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;
  usagelink) log; report done 2 done; printf 'product\n' > "$work/project.cho"; ln -s /dev/zero "$work/usage.jsonl"; printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;  # company_run.sh
  usagefifo) log; report done 2 done; printf 'product\n' > "$work/project.cho"; mkfifo "$work/usage.jsonl"; printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;  # company_run.sh
  usagebig)  log; report done 2 done; printf 'product\n' > "$work/project.cho"; truncate -s 17000000 "$work/usage.jsonl"; printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;  # company_run.sh
  usagedir)  log; report done 2 done; printf 'product\n' > "$work/project.cho"; mkdir "$work/usage.jsonl"; printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;  # company_run.sh
  bare)      log; report done 2 done; printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;  # done, and no project.cho (company_run.sh)
  args)      log; report done 2 done; printf 'product\n' > "$work/project.cho"; for a in "$@"; do printf 'A:%s\n' "$a"; done > "$work/args.txt"; printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;
  args2)     log; report done 2 done; printf 'product\n' > "$work/project.cho"; for a in "$@"; do printf 'A:%s\n' "$a"; done > "$work/args.txt"; printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;
  env)       log; report done 2 done; printf 'product\n' > "$work/project.cho"; env > "$work/env.txt"; printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;
  slow)      # issue #35: a build that is still running when a second adapter starts on its directory. It records the brief it read
             # and its pid, then waits for a file `release` in the work directory, then ends `done`; the product names the brief's
             # second line, so the files say which build wrote them last.
             log; report build 0 ""; tag=$(sed -n 2p "$brief"); cp "$brief" "$work/seen_brief.txt"; printf '%s\n' "$$" >> "$work/pids.txt"
             while [ ! -e "$work/release" ]; do sleep 0.1; done
             report done 2 done; printf 'product of %s\n' "$tag" > "$work/project.cho"; printf '[BUILD_VERDICT]\tdone %s\n' "$tag"; exit 0 ;;
  holdgrand) # issue #33: like `slow`, and it starts a grandchild (`sleep 78`) that a kill of the build's group must reach
             log; report build 0 ""; tag=$(sed -n 2p "$brief"); cp "$brief" "$work/seen_brief.txt"; printf '%s\n' "$$" >> "$work/pids.txt"
             sleep 78 &
             while [ ! -e "$work/release" ]; do sleep 0.1; done
             kill $! 2> /dev/null
             report done 2 done; printf 'product of %s\n' "$tag" > "$work/project.cho"; printf '[BUILD_VERDICT]\tdone %s\n' "$tag"; exit 0 ;;
  straggle)  # defect 2 of statuslite run arm-a-1 (docs/company.md section 14): the real tool's driver starts its agent as
             # `/bin/sh -c '<agent> <file> 2><file>.agent.err'` (a plain spawn: in the build's group), dash forks for the redirect,
             # and at the agent's deadline the driver kills the shell's pid alone; the agent runs on in the build's group after the
             # build ends. Here: such a shell, its child `sleep 76` (or the seconds on the brief's second line, as `sleep N`), the
             # shell killed, the build ending done with the child still running.
             log; report done 2 done; printf 'product\n' > "$work/project.cho"
             n=$(sed -n 2p "$brief"); [ -n "$n" ] || n=76
             /bin/sh -c "sleep $n 2>/dev/null" > /dev/null 2>&1 &
             sh_pid=$!; sleep 0.3; kill -9 "$sh_pid" 2> /dev/null; printf '%s\n' "$sh_pid" > "$work/pids.txt"
             printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;
  killable)  # task 9 (tests/conformance/company_kill.sh): a build that is killed in the middle. Unless `fast` is in the work
             # directory it spends one call (a usage.jsonl line), starts a grandchild (`sleep 97`), writes both pids to pids.txt,
             # says it is building (the file `building`) and waits for a `release` that never comes. Then (or at once, with
             # `fast`) it spends a second call and ends `done`.
             log; report build 0 ""
             if [ ! -e "$work/fast" ]; then
               printf '{"provider":"stand","model":"m1","task":"t","sample":0,"in":600,"out":10,"thinking":0,"cache_write":0,"cache_read":0,"stop":"end_turn","outcome":"ok","status":200,"reply_chars":1,"program_chars":1,"ms":1}\n' >> "$work/usage.jsonl"
               sleep 97 &
               printf '%s %s\n' "$$" "$!" >> "$work/pids.txt"
               : > "$work/building"
               while [ ! -e "$work/release" ]; do sleep 0.1; done
               kill $! 2> /dev/null
             fi
             printf '{"provider":"stand","model":"m1","task":"t","sample":0,"in":500,"out":20,"thinking":0,"cache_write":0,"cache_read":0,"stop":"end_turn","outcome":"ok","status":200,"reply_chars":1,"program_chars":1,"ms":1}\n' >> "$work/usage.jsonl"
             report done 2 done; printf 'product\n' > "$work/project.cho"; printf '[BUILD_VERDICT]\tdone\n'; exit 0 ;;
  *)         log; report done 1 wat; exit 1 ;;
esac
