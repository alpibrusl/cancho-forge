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
| ~~Audit of the real Cancho Code interface~~ | **Done after M0**: [`cancho-code-audit.md`](cancho-code-audit.md). Source read, both offline gates run, a stand-in build, a TERM and a resume. The worker contract was corrected in place (five points, listed at its top). **Not done**: a build with a real model. |
| Audit of `lex-loom` (what is implemented, experimental, proposed) | **Still owed**: no copy of it was available. The reuse matrix for Cancho Code and cancho is done (audit section 9); `lex-loom`'s row is not. |
| License and dependency review | **Done for Cancho Code and cancho** (both EUPL-1.2, same holder, nothing vendored; what may be reused and on what terms: audit section 9). **Still owed for `lex-loom`** and for any provider's terms for model output, which were not reviewed. |
| MVP acceptance-test plan | the nine success criteria exist (design doc section 7); mapping each to a test is M1's first task |
| One golden-path scenario fully specified | sketched in the design document; a sample repository and one objectively testable change must be chosen |
| Filing the cancho issues for G1-G5 | **Done after M0**: G1/G9 #534, G2 #535, G3 #533 (built), G6 #536 (fixed); G4 is a row of cancho's `docs/processes.md` section 9; G5 not filed |

**Exit criteria (revised, status):** the above audits written (Cancho Code
done, `lex-loom` open); the golden path
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
write, after write before sync, after sync, mid-record, mid-snapshot; **met for
a process kill, 25 points, architecture 4.8**);
invalid transitions are refused with `transition-invalid`; every transition
is a queryable event; duplicate and torn-record tests pass.

*Gaps in play:* G5 (macOS durability: state the promise per platform), **G9**
(found in M1: a library cannot be generic in the `Fs` prefix, so the file
layer holds `Fs("")` and guards paths itself).

**Status of M1 (what exists, honestly).** Built and in the gate:
`src/task.cho` (the state machine, 18 edges, the decision order, twelve rule
tags), `src/journal.cho` (replay, replay from an offset, torn-tail planning,
refuse-on-corrupt, `submit`, the write path that records refusals),
`src/journal_io.cho` (read, append with sync and the steps it is made of,
recover), `src/snapshot.cho` and `src/snapshot_io.cho` (a snapshot with the
journal's prefix hash, written tmp / sync / rename / sync-dir, recovered as
snapshot + tail, refused when invalid or when it disagrees), `src/lock.cho`
(the single-writer lock, `workspace-locked`), `src/report.cho` and
`src/main.cho` (the read-only operator CLI: `forge status <dir>`, `forge
history <dir> [task]`), `src/event.cho` extended (`transition`, `refusal`).
Measured: **82 tests** under `cancho test` (9 event, 22 task, 25 journal, 18
snapshot, 8 report), **65 file cases** in two conformance programs, **25 crash
points** (a child writer killed with `child_kill_group` after each step of
append, sync, snapshot and rename, then recovered, 420 checks, 0 failed), 13 CLI
cases and the checked-in authority report (`docs/authority.txt`) in the gate.
The exit test "state survives a kill at every instrumented crash point" is
therefore **met for a crash of the process**; it is *not* met for power loss,
which a process kill cannot simulate (a killed process leaves its page cache;
architecture section 4.8). **Not built:** the `schemas/`, objective /
execution / artifact / decision records, projections beyond task state,
segments and rotation, a snapshot cadence, the file-budget check as a `cancho
test`, and the rule `journal-sync-failed` (the file layer returns the errno;
the stop is M2). `forge` is read-only: it takes no lock and cuts nothing, and
its authority is `fs_read("")` with no write, process or network
(architecture section 4.9). Note the exit criterion names `transition-invalid`;
it now has company: `accept-unverified`, `actor-not-allowed`, `task-unknown`,
`task-duplicate`, `event-malformed`, `event-unknown`, `journal-corrupt`,
`path-invalid`, `snapshot-invalid`, `snapshot-mismatch`, `workspace-locked`
(architecture section 7).

## M2 -- Worker contract and Cancho Code adapter

**Status of M2 (what exists).** `src/response.cho` validates an `execute` response against the contract: a pure function, `worker-protocol` and the syntactic half of `evidence-ref-invalid` as rules with reasons, 19 tests and 32 mutants all killed (`scripts/mutate_response.py`). `src/evidence_io.cho` recomputes each evidence file's size and SHA-256 beneath a `Dir`, following no link (worker-contract section 4.1; spike S10, which found that the `Fs` capability follows a worker's symlink): 24 conformance cases, 16 of 16 mutants killed (`scripts/mutate_evidence.py`). `src/dispatch.cho` classifies how a run ended (section 5's rows 1 to 7) into a rule tag and a consequence, purely: 14 tests, 28 of 28 mutants killed (`scripts/mutate_dispatch.py`). `src/worker.cho` builds the `execute` request, starts the worker beneath a run-time `Dir` under a deadline and a cap, classifies the ending and recomputes the evidence; `tests/conformance/worker_contract.cho` runs 19 cases against the mock worker (`tests/contract/mock_worker.cho`, driven only by its request) as real child processes, 15 of 15 mutants killed (`scripts/mutate_contract.py`). **Gap G10 (cancho #562):** `exec_spawn_under` has no detached form, so a worker's subprocesses are not killed with it. **The gate runner** (`workers/gate_runner.cho`, `src/gate_task.cho`; issue #20; worker contract section 10): the first real worker, a cancho program that runs a repository's gate at a revision. Spike S11 measured that a deadline kill of a worker leaks what it started and that only the runner's own shorter deadline cleans (the runner's deadline is four fifths of Forge's); `gate_task` has 17 tests and 60 of 60 mutants killed (`scripts/mutate_gate_task.py`); 38 checks (22 conformance cases, 15 outside oracles, the authority report) run it against real git checkouts and real child processes (`scripts/check_gate_runner.sh`), and 26 of 27 end-to-end breaks are killed (`scripts/mutate_gate_runner.py`; the one survivor, the shell running the gate in its own place, cannot be observed with dash as `/bin/sh` and is killed by the unit test on the script text); its authority report is checked in (`docs/authority-gate-runner.txt`). Not run against a real repository's gate (self-hosting D7). **The stub LLM** (`workers/stub_llm.cho`, `src/stub_script.cho`; [`stub-llm.md`](stub-llm.md)): a deterministic, scripted `sync` worker that answers from a script file (a prompt picks a rule; ten behaviours: a reply, a proposal with a patch, a refusal, a reply that is not JSON, a reply cut off, evidence that lies about its hash or its size, a slow reply that honours the deadline, partial progress then a crash, a reply past the output cap), so that a flow can be run end to end with no model: 19 unit tests, 50 conformance checks (16 journalled and replayed flows, the stub's own error codes, 6 unserved requests, 14 outside oracles), 46 of 57 and 33 of 36 breaks killed and the rest listed as equivalent with their reason (`scripts/mutate_stub_script.py`, `scripts/mutate_stub_llm.py`); authority checked in (`docs/authority-stub-llm.txt`). It is the drop-in for the Cancho Code slot until #16 exists; it does not model a real model. **The first self-hosted task** (`forge gate`, `src/gate_run.cho`, `src/flow.cho`; issue #18): the worker half is now linked into `main` for this one verb, which widens `cancho authority` (`docs/authority.txt`: file writes, `exec_under`, `dir_read`, `clock`, `poll`, the pipes of the supervisor; architecture section 4.9): it records the task, runs the gate runner, and journals the ending and the verdict as a claim, never an acceptance; 13 unit tests, 29 checks on the built binary against real git checkouts (`scripts/check_gate_run.sh`) and 28 of 29 deliberate breaks killed, one equivalent (`scripts/mutate_gate_run.py`); the first run of a real repository's gate through it is in self-hosting section 8. **`error.retryable`** (issue #15): `forge.response.retryable` reads it, `forge.dispatch` makes a `failed` or `partial` reply a `Said` ending with a `worker-retryable` or `worker-said` consequence, `forge.retry` decides (three attempts for a task that reads, none for one that writes; rule tags `retry-exhausted`, `retry-write-refused`), and `forge gate` runs the attempt loop, journalling an `execution.retry` per retry. **`execution.lost` recovery** (issue #15; architecture section 4.4.1): `forge recover <dir>` settles the tasks a crash left `running` (`forge.recover`, pure; `forge.recover_io`), under the rule tags `execution-unstarted`, `execution-lost` and `retry-exhausted`, and starts no worker: 13 unit tests, 27 checks on the built binary (one a real SIGKILL of `forge gate`), 40 of 40 breaks killed (`scripts/mutate_recover.py`). **Not built:** the pid and start token in `execution.started` (so a lost execution's worker is not looked for), accepting a `result.json` written before the crash, a verb that dispatches an existing task; the Cancho Code binding, the same contract tests against the real worker, `capabilities`/`cancel`/`status`/`result`.

*Leans on:* `std.process`, `Exec`. *Justified by:* S1, S2, S3, S6.

Work: ~~audit Cancho Code first and correct `worker-contract.md`~~ (done,
`cancho-code-audit.md`; **the adapter's design changed**: Cancho Code is an
`async`, process-and-directory worker started detached with a group kill, not
a `sync` stdio worker; contract section 9); mock
worker rewritten to the contract (request-driven failure injection); a
contract-test suite run against mock and, then, the adapter; the adapter
(`src/worker.cho`) normalising the endings of contract section 5; execution
directories; evidence refs with recomputed hashes; workers started
detached with group kill (S7, `child_kill_group`) so a timeout does not leak a compiler.

*Exit:* the same contract tests pass against mock and real; a worker
failure cannot leave a task falsely complete; adapter failures are visible
and recoverable after a restart (intent without outcome becomes
`execution.lost`).

*Gaps in play:* ~~G3~~ (group kill: **built**, cancho #533, S7 passes with
no `/bin/kill` in the `Exec` bound), **G4** (orphan after Forge crash), **G1** (the
workers directory is a compile-time literal: ship Forge built for a
workspace, or hold `Exec("")` and rely on layer 2 -- decide in M2 and
record it).

**Status of the company layer (design `docs/superpowers/specs/2026-10-27-forge-company-layer-design.md`; [`company.md`](company.md)).** Built and in the gate, with stand-in workers: the manifest and its refusals, the step graph, the company journal and its replay, `forge company check | status | decide | run`, human gates and `retry:<id>`, a token-derived budget, acceptance only by a Forge-run check, needs delivery, a contract input, kill and resume, the analyst's `tool.run` worker. **Remains:** the StatusLite repository and its hidden audit; a company run with a real model (none has happened); the A/B of the contract arms and the semantic contract (arm C); the reviewer role (not distinct from qa); a writer run; forge#41's re-run comparison; holding a worker that ended without a claim; showing a held step and the cost in `status`.

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

## Self-hosting

The plan for Forge managing the cancho project itself (the compiler, the language documents, the packages), in stages from a read-only gate report to maintained pins, with the authority each stage needs and what Forge never does unattended: [`self-hosting.md`](self-hosting.md) (Stage 1 is built: the gate runner and `forge gate`, with the operator's environment of D7, run on two real repositories in agreement with CI; the later stages are a plan). It leans on M2 (a worker linked into `main`), M3 (Forge-observed checks) and M4 (policy and approvals); its first task needs a gate-runner worker that is not Cancho Code.

## Dependencies on cancho, in one place

| need | milestone | status in cancho |
|---|---|---|
| run-time-chosen bound for `Fs`/`Exec` (G1, G9) | M2 decide, M4 depend | open: cancho #534; `Dir` and `exec_spawn_under` merged (cancho #546) and **tried here (S9)**: a workers directory given at run time, report `exec_under`, no path named; not yet used by a worker adapter (M2) |
| asking before a bound violation (G2) | M4 | **built**: `exec_covers`/`fs_covers`, cancho #540 (closed #535); **adopted for the journal path** (`journal_io.path_ok`, S8, which found and fixed a defect in the copy it replaced); for a worker name, S9 only until M2 |
| group kill for a detached child (G3) | M2 | **built** (cancho #533, `child_kill_group`, edition 9; S7) |
| kill-by-pid capability, parent-death cleanup (G4) | M2 | open rows in `docs/processes.md` section 9 |
| `F_FULLFSYNC` on macOS (G5) | M1 | noted in `docs/file-writes.md` section 6 |
| header of `docs/processes.md` out of date (G6) | any | **fixed** (cancho #536, closed) |
