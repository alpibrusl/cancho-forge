# Roadmap

> Milestone-based, not date-based, as in the design document. Each ends in
> a demonstrable artifact and a go/no-go. **Adapted by Milestone 0**: every
> milestone below names the cancho capability it leans on, the spike result
> that justifies it, and the gap (architecture section 9) it must route
> around or have fixed. Numeric targets are not set until a baseline is
> measured (design doc section 7).

## M0 -- Architecture and interface audit  *(this milestone)*

**Done in this commit:** the ADR (`architecture.md`), the worker contract
v1 draft, the threat model, this roadmap, and `spike/` with
`spike/RESULTS.md`: seven programs run with the pinned compiler measuring
spawn, capture, deadline, kill, narrowed `Exec`, JSON, journal, recovery,
atomic rename and locking. The gate (`scripts/gate.sh`) passes.

**Not done, and required before M2 can start:**

| item | why it is not done |
|---|---|
| Audit of the real Cancho Code interface (task, planning, checker, journal, execution) | no access to it in M0; the worker contract is written ahead of it and must be corrected in place |
| Audit of `lex-loom` (what is implemented, experimental, proposed) and the component reuse/migration matrix | same; the design document's section 14 asks for it |
| License and dependency review of those two | same. Forge has no third-party dependencies (`THIRD_PARTY.md`) and is EUPL-1.2 like cancho; reuse of Loom or Cancho Code code is unchecked |
| MVP acceptance-test plan | the nine success criteria exist (design doc section 7); mapping each to a test is M1's first task |
| One golden-path scenario fully specified | sketched in the design document; a sample repository and one objectively testable change must be chosen |
| Filing the cancho issues for G1-G5 | none were found or filed in M0 |

**Exit criteria (revised):** the above audits written; the golden path
specified end to end; no critical dependency on an undocumented internal
API; licence compatibility understood.

## M1 -- Durable company state and task model

*Leans on:* `docs/file-writes.md` primitives, `std.json`, `enum`/`match`.
*Justified by:* S4, S5 (append+sync, torn-tail recovery, atomic snapshot,
lock all worked; one recovery bug found and fixed in the spike).

Work: the journal module (`src/journal.cho`: segments, write protocol,
recovery, lock, per section 4 of the ADR) on top of `src/event.cho`;
objective / task / execution / artifact / decision records and a versioned
schema (`schemas/*.json` as documentation, validated by cancho code, not
by a foreign tool); the task state machine as a total `match`; projections
and a snapshot with `last_seq`; CLI: create objective, list tasks, show
history. The checked-in `cancho authority` report for the `forge` binary.
The file-budget check moves from `scripts/gate.sh` into a `cancho test`
that walks the tree (`std.dirs`), so the gate is cancho-only.

*Exit:* state survives a kill at every instrumented crash point (before
write, after write before sync, after sync, mid-record, mid-snapshot);
invalid transitions are refused with `transition-invalid`; every transition
is a queryable event; duplicate and torn-record tests pass.

*Gaps in play:* G5 (macOS durability: state the promise per platform).

## M2 -- Worker contract and Cancho Code adapter

*Leans on:* `std.process`, `Exec`. *Justified by:* S1, S2, S3, S6.

Work: audit Cancho Code first and correct `worker-contract.md`; mock
worker rewritten to the contract (request-driven failure injection); a
contract-test suite run against mock and, then, the adapter; the adapter
(`src/worker.cho`) normalising the endings of contract section 5; execution
directories; evidence refs with recomputed hashes; workers started
detached with group kill (S7) so a timeout does not leak a compiler.

*Exit:* the same contract tests pass against mock and real; a worker
failure cannot leave a task falsely complete; adapter failures are visible
and recoverable after a restart (intent without outcome becomes
`execution.lost`).

*Gaps in play:* **G3** (group kill; works today at the price of `/bin/kill`
in the `Exec` bound), **G4** (orphan after Forge crash), **G1** (the
workers directory is a compile-time literal: ship Forge built for a
workspace, or hold `Exec("")` and rely on layer 2 -- decide in M2 and
record it).

## M3 -- Verification and evidence gate

*Leans on:* the same `std.process` machinery run as a Forge-owned child;
`std.crypto.sha256`. *Justified by:* S6 (a worker's `succeeded` is only
mapped to `verification`).

Work: machine-readable acceptance criteria; repository checks as Forge's own
children with their own `Exec` bound (separate from the worker's);
worker-reported versus Forge-observed evidence kept distinct; pass / fail
/ inconclusive / not-run; stale-verification invalidation on artifact hash
change; bounded repair loop.

*Exit:* failed checks block acceptance; changed artifacts invalidate
verification; repair loops stop at limits; the report separates observed
evidence from assertions.

## M4 -- Policies, budgets and human approvals

*Leans on:* a pure policy module; the journal. *Justified by:* S3, which
shows the capability bound is a trap and so cannot be the only check.

Work: action categories and the policy decision point (`Allow | Deny(rule)
| NeedApproval`), evaluated at execution time; budget reservations as
events; approval requests and decisions as events; safe defaults on policy
failure; prompt-injection and malicious-repository tests; redaction rules.

*Exit:* unauthorised actions refused before execution with a rule tag; a
worker cannot grant itself authority; limits hold across restarts and
retries.

*Gaps in play:* **G1**, **G2** -- a decision here whether Forge asks cancho
for run-time narrowing and a non-trapping bound violation, or accepts
"policy refuses; trap is a crash" as the design.

## M5 -- Operator experience and repeatable demo

Work: status views, approve / reject flows, Markdown and JSON run report
(from the journal alone), dry-run, sample repository, one-command setup
(`scripts/gate.sh` plus `cancho build`), operator and troubleshooting
guides, evaluation report. Optional local web UI on `std.http` with `Net`
narrowed to loopback. *Exit:* a new operator runs the demo from the
documentation; the report shows requested, executed, verified, blocked and
approved; success and failure cases both shown.

## M6 -- Controlled operate loop

Work: release-candidate tracking; read-only health signals through `Net`
narrowed to named hosts; incidents and follow-up tasks from alerts;
approval required for deploy and remediation; post-incident review that
proposes, not applies. Forge's authority report gains `net(...)` for the
first time, and that diff is the review. *Exit:* operational events create
traceable tasks; nothing deploys without a recorded approval.

## M7 -- Strategy loop and measured pilot

Work: a small set of measured product and delivery metrics; planned versus
actual effort, cost, quality, incidents; evidence-linked proposals;
human approval for objective, budget or policy changes; a time-boxed pilot
on one non-critical repository. *Exit:* recommendations link to observed
data and state uncertainty; expansion justified by measured performance,
not demo quality. Revisit the "no database" decision (ADR section 2.2) with
the pilot's journal size and replay time.

## Dependencies on cancho, in one place

| need | milestone | status in cancho |
|---|---|---|
| run-time-chosen `narrow` for `Fs`/`Exec` (G1) | M2 decide, M4 depend | open row in `docs/processes.md` section 9 |
| non-trapping bound violation (G2) | M4 | not requested anywhere found; by design a trap |
| group kill for a detached child (G3) | M2 | workable today through `/bin/kill` |
| kill-by-pid capability, parent-death cleanup (G4) | M2 | open rows in `docs/processes.md` section 9 |
| `F_FULLFSYNC` on macOS (G5) | M1 | noted in `docs/file-writes.md` section 6 |
| header of `docs/processes.md` out of date (G6) | any | correction in cancho repository |
