# Proposal: a plan whose own test is the dead end is not reused (cancho-code)

Status: **proposal for the cancho-code owner**. Nothing in cancho-code is changed; a PR is made only on the owner's go.
Measured 2026-10-28 against cancho-code 9d5a86a (the `cancho-build` binary of the StatusLite A/B, `/tmp/slab-bin/cc/build/cancho-build`)
and cancho-forge dd9b5ac, offline: stand-in agent `tests/buildcmd/agent.sh` of cancho-code, no model, no key.

## 1. The problem

StatusLite A/B runs B1 and A2 (`statuslite/runs/AB-TABLE.txt`, `runs/arm-b-1/REPORT.txt`): the planner wrote a `plan.json` whose
acceptance test `test_pn_large` (B1) / `test_percentile_large` (A2) asserts `percentile_nearest(v, 1)` over 3000 values is the
smallest; by the plan's own description (rank = ceil(p*n/100)) it is the 30th. Every build of that step fails that test, and every
re-run of the step reuses the same plan, so the step can never pass and each re-run pays again.

## 2. Where the reuse happens: cancho-build, not Forge

* **cancho-code `src/build.cho:392-404`**: "A plan.json from an earlier run that the check accepts is kept." The work directory's
  `plan.json` is read and `judge`d (`judge(..., false)`, the structural plan check plus the brief's names); `units >= 0` prints
  `[BUILD_STAGE] plan reused` and the plan agent is not asked. "Valid" means only that: it parses, passes the plan check and declares
  every name the brief requires (docs/build.md "brief names"). Nothing about how the plan fared before is considered. The error
  `no valid plan.json in the work directory, and no --guide to ask for one` (`:405-407`) is the `units < 0` branch with no guide.
  The behaviour is documented and tested in cancho-code: docs/build.md:14 and :52 ("a valid `plan.json` is not asked for again"),
  `scripts/test-build.sh` "reuse: a valid plan in the work directory is kept".
* **Forge only supplies the same directory.** `src/company_runner.cho:747` builds a builder step in `steps/<id>/ev`, every admission;
  `workers/cancho_code.cho:521-524` removes only the adapter's run files (`run`, `result`, `result.tmp`, `cancel`), Forge removes only
  its own names (`needs*`, `contract.txt`). No Forge source mentions `plan.json` except a message string (`src/build_task.cho:554`).
  This is intended: docs/cancho-code-adapter.md:36 and :293 ("the directory is the identity of the work"; a new request "resumes from
  `plan.json` and `state.txt`"). B1's step journal shows both builds `execution.accepted ... "dir":"/tmp/slab-b1/steps/percentile/ev"`.

## 3. What signals "the plan itself is wrong", and who has it

| record | written by | what it says about the B1 failure |
|---|---|---|
| `build.json` | cancho-build | `"verdict":"stuck","units_total":1,"units_verified":0` only: no unit, no test, no reason |
| `result.json` / Forge output | adapter / Forge | `error.code: stuck`, `retryable: false`; Forge prints `refusal: step-failed`, `exit: 4` |
| `run.log` | cancho-build | `[BUILD_STAGE] plan reused`, `[UNIT] nearest failed`, `[BUILD_VERDICT] stuck` |
| `trail-<unit>.jsonl` | cancho-build | per build, overwritten: `sig "acceptance:test test_pn_large ... FAILED"`, decisions `retry` then `signature` |
| `journal/events.jsonl` | cancho-build | **every** run, appended: `attempt` with `outcome:"acceptance_failed"` (compiled, its own test failed; docs/journal.md:42), `decision:"signature"` (the same failure twice, docs/journal.md:43), the signature naming the test; `plan_final` with the plan blob; `run_end` verdict |

So the precise signal (an attempt whose code **compiled** failed **a test of the plan**, the **same** way twice, the loop stopped on
`signature`, the run ended `stuck`) exists only in cancho-build's own journal. Forge sees `stuck`, which it correctly does not
retry blindly, but `stuck` alone is not "wrong plan": B2's cli build 1 was stuck on `no_program` x5 and passed on a re-run with the
same plan; A1's cli passed on a re-run after acceptance failures. A Forge that deleted `plan.json` on `stuck` would discard good plans
(and A3 cli's 27 verified units of 28) and would be removing another tool's file on a coarse signal; a Forge that parsed
cancho-build's journal would put the build tool's policy in the orchestrator, and every other caller (`cancho-code` MCP server,
a person) would keep the dead end. `provider_error` (exit 4) and `plan_failed` (exit 3) never reach the rule below at all.

**Decision: the fix belongs in cancho-code (`cancho-build`).** No Forge change.

## 4. Measured (offline, stand-in)

Scratch harness: the real cancho-build binary, `tests/buildcmd/agent.sh`, `plan.sh` copying B1's real `plan.json`, a unit recipe
writing a **correct** nearest-rank `percentile_nearest`.

1. Build 1, fresh dir: `[BUILD_STAGE] plan` ... `[ACCEPTANCE] fail` x2, `[ISSUE_VERDICT] failed signature`, `stuck`; agent calls
   `PLAN nearest nearest`; trail = B1's exactly (`acceptance:test test_pn_large ... FAILED`, `retry`, `signature`).
2. Build 2, same dir: `[BUILD_STAGE] plan reused`, no `PLAN` call, the same two failures, `stuck`. This is B1's run 3 / A2's.
3. Same dir, `plan.json` removed (what the proposal does), planner now answering the plan with only that one assertion corrected to 30:
   `[BUILD_STAGE] plan`, `PLAN nearest`, `[ACCEPTANCE] pass`, `verified attempts 1`, `done`, exit 0. The same correct code that failed
   twice passes: the test was the defect, and re-planning in place heals it (the journal of the earlier runs stays, appended).

## 5. The smallest change

In `src/build.cho`, between `:400` (the old plan judged) and `:403` (the `units >= 0` reuse branch):

```
// A plan whose own test was the dead end of the last run is asked for again (once per work directory).
if units >= 0 && len(retry) == 0 && len(patch) == 0 && len(guide) > 0 {
    let (u, t) = trail.dead_plan_test(heap, fs, jq, old_plan_bytes);   // empty when the rule does not hold
    if len(u) > 0 { tell "[BUILD_STAGE]\tplan\treplaced\t<u>\t<t>\n"; trail.plan_replaced(...); units = 0 - 1; }
}
```

`units = -1` sends the run down the existing `asked` path (`:408-438`), which already empties `plan.json` first (`:413`), asks the plan
agent and judges the fresh plan; `state.txt` is kept and its units are re-checked as on any resume. `dead_plan_test` reads
`journal/events.jsonl` (cap it, as `slurp` does) and holds **all** of, for the last `run_start`..`run_end`:

1. `run_end.verdict == "stuck"`;
2. some unit's **last** `attempt` has `outcome:"acceptance_failed"` and `decision:"signature"`;
3. its signature is `acceptance:test <name> ... FAILED` and `<name>` is a test of that unit in the plan being reused (a plan test, not
   a test file that did not compile, `acceptance:<path>:<line>`, and not a sweep of another unit);
4. that run's `plan_final` blob is byte-equal to the `plan.json` being reused (a plan the person edited since is theirs: reuse it);
5. no `plan_replaced` event already in the journal (at most one re-plan per work directory, so a planner that writes the same wrong
   test again costs one plan call, not one per re-run).

Not touched: `--retry` / `--patch` (a person continuing a unit keeps the plan, `:363-379`); no `--guide` keeps today's reuse (the rule
needs a planner; do not turn a resume into exit 2); `provider_error`, `plan_failed`, `refused` (compile) stops, `ceiling` stops,
`agent_failed`/`no_program` never trigger. Docs to change with it: `src/build.cho:347` head comment, docs/build.md:14, :52 and the
`run.log` line list (:71: `plan<TAB>replaced<TAB><unit><TAB><test>`), docs/journal.md (`plan_replaced` event).

Optional, a second PR: tell the plan agent which test was the dead end (a `--plan-hint`-style line: "test X of unit U failed twice
against code that compiled; check it against the brief"). Without it a re-plan may repeat the mistake (section 7).

## 6. Test sketch (scripts/test-build.sh, stand-in agent)

* **dead plan replaced**: `plan.sh` writes a plan whose unit `a` has a test the good recipe cannot pass; run 1 -> `stuck`, agent log
  `PLAN a a`; switch `plan.sh` to the good plan; run 2 -> run.log has `plan<TAB>replaced<TAB>a<TAB><test>`, agent order begins
  `PLAN`, verdict `done`, journal has one `plan_replaced`.
* **once only**: keep the bad `plan.sh`; run 2 replaces (stuck again), run 3 -> `plan<TAB>reused`, no `PLAN`.
* **not replaced** (each: run 2 says `plan reused`, no `PLAN` call): the last run ended `provider_error` (plan agent away mid-units);
  the stop was `refused` (a compile signature twice); the stop was `ceiling` with mixed signatures; the failing signature is a test file
  that did not compile; the person edited `plan.json` between runs; run 2 is `--retry a` or `--patch a f`; run 2 has no `--guide`.
* **verified work kept**: a three-unit plan where `a`, `b` verify and `c`'s test is the dead end; after the re-plan `state.txt`'s
  units that the new plan still has are re-checked, not rebuilt.

## 7. Risks, and what could not be determined without a real model run

* **Whether a re-plan writes a correct test.** Not measurable offline. The brief's ambiguity ("p 1 gives the smallest when there are
  at most 100 values") produced the same wrong test in 2 of the 5 new percentile plans (B1, A2; the plans of A3, B2, B3 built and were accepted, so had no dead-end test; not otherwise checked). An unhinted
  re-plan may well repeat it; the optional hint is the lever, its effect unknown.
* **False positives.** "the same plan test failed twice on compiled code" is also what an implementer that cannot do the unit looks
  like. Then the rule costs one plan call (B1's plan call: 7,197 in / 4,989 out tokens, Haiku 5.5) and, on a multi-unit plan whose unit
  ids change, verified units rebuilt. How often this happens with a real model is unknown.
* **Forge cost amplification is a separate Forge question, not fixed here.** Since dd9b5ac a `step-failed` step is re-admitted by every
  `forge company run` (docs/company.md section 8 item 6), including `stuck`, which the adapter calls an outcome "never retried
  blindly" (docs/cancho-code-adapter.md:106, a claim about `forge.retry`, which stays true). With this proposal the dead end is paid
  once more at most (the re-plan); holding a `stuck` step for `retry:<id>` like a failed check would be a Forge policy change for the
  owner to decide.
