# Self-hosting: Forge managing the cancho project

> **Status: a plan, not a build.** Nothing here is implemented. It says
> which tasks Forge takes first, how its responsibility for the cancho
> project (the compiler `alpibrusl/cancho`, the language documents, and the
> packages and repositories around it) grows in stages, what authority each
> stage needs, and what Forge never does unattended. *Measured* marks a
> result that exists in this repository (`spike/RESULTS.md`, the gate, the
> checked-in `docs/authority.txt`); *unmeasured* marks a number or a
> behaviour nobody has run; everything else is a design decision, and the
> open ones are collected in section 7. Tracked by
> [alpibrusl/cancho-forge#12](https://github.com/alpibrusl/cancho-forge/issues/12)
> (this document is #13).

## 1. Why this first, and what "takes responsibility" means

Forge is written in cancho, so the first long-running consumer of the
compiler is Forge itself; the first work worth giving Forge is the work of
keeping that compiler, its documents and its packages in a state a human can
trust. That is also the only project whose gate we already run by hand
every day (`cargo fmt --check`, `cargo clippy -D warnings`, `cargo test
--workspace` for the compiler; `scripts/gate.sh` for Forge).

"Takes responsibility" is used in one narrow sense: **for a defined class of
task, Forge decides when it is done, records why, and a human only handles
the exceptions.** It never means Forge may widen its own authority, merge
its own work or bypass the gate. Every stage below widens what Forge may do
in a way that is visible in a diff (section 4) and ends with a go/no-go that
a human signs.

## 2. Principles the plan does not bend

These are Forge's existing rules (`CLAUDE.md`, architecture sections 5 to 7,
the threat model), restated as they bind this plan:

1. **A worker's "done" is a claim.** A task is `accepted` in exactly one
   way: Forge, with `basis: observed` (architecture section 6; measured: one
   of 60 actor/state/basis combinations reaches `accepted`). A gate result
   that a worker reports is recorded as **claimed** evidence, whatever it
   says.
2. **Narrow the body, never widen the row.** A stage that needs a new
   capability says so in its commit, and `docs/authority.txt` changes in
   the same commit; the gate fails otherwise (measured: the authority check
   in `scripts/gate.sh`).
3. **Every refusal has a rule tag and a test.** A new refusal here is
   *designed* until a test reaches it (section 6).
4. **Policy refuses first; the capability bound is the backstop**, because a
   violation of the bound traps (measured, S3).
5. **A worker is trusted not to be malicious, only to be possibly wrong**
   (threat model section 5): `Exec` bounds which program starts, not what it
   does. Until workers run in an OS sandbox, Forge only runs code from
   places the operator already trusts (section 5).

## 3. The tasks, in the order they are given

### 3.1 First: report a repository's gate at a revision (read-only)

Issue [#18](https://github.com/alpibrusl/cancho-forge/issues/18).

> Given a repository from the allow-list and a 40-hex revision, run the
> repository's own gate in an execution directory and record what happened.

* **Input:** `{repo, revision}` in the task. `repo` is a key into a policy
  table Forge loads (`alpibrusl/cancho`, `cancho-ui`, `cancho-hdl`,
  `cancho-forge`); anything else is `scope-invalid`, a revision that is not
  40 lower-case hex digits is `revision-invalid` (section 6).
* **Output:** a journal record per transition, and evidence files in
  `executions/<id>/`: the gate's combined log, the worker's result, the
  gate's exit status; each with its size and SHA-256 recomputed by Forge
  (measured for the mechanism: `src/evidence_io.cho`, 24 conformance cases).
* **What it does not do:** change a file of the repository, push, open or
  comment on a pull request, or decide that the repository is fine. The
  verdict (`pass` or `fail`) is **claimed** until Stage 2.
* **Why it is the right first task:** it is reversible (the execution
  directory is deleted), it needs no write authority outside Forge's own
  workspace, it exercises every part of the worker contract that exists
  (dispatch, the endings of worker-contract section 5, evidence recompute),
  and it has an oracle that is not Forge: the repository's CI ran the same
  gate on the same revision.

Success criterion, to be measured and not assumed: for N revisions of the
four repositories, Forge's claimed verdict equals CI's. *N and the time per
run are unmeasured.* One data point exists: see section 8.

### 3.2 Later tasks, one stage at a time

| stage | task | writes to the project? |
|---|---|---|
| 1 | gate report at a revision (above) | no |
| 2 | **observed** gate and drift checks (below) | no |
| 3 | prepare a change as a patch, in an execution directory | no (a human applies it) |
| 4 | push a branch and open a *draft* pull request | a branch and a draft PR, per approval |
| 5 | compiler pin bump as a task | a branch and a draft PR, per approval |

The stages are in section 4; this table is the order, and the order is the
point: **read, then observe, then propose, then submit, then maintain.**

## 4. Stages and the authority each needs

`cancho authority` is the review artefact (architecture section 5.1). Today
the `forge` binary's report is, measured and checked in
(`docs/authority.txt`): `args`, `err_write`, `file_read`, `fs_read("")`,
`heap`, `io_write`, and "never touches the network, signals, other programs,
foreign code". The rows below are what each stage is **expected** to add;
the report, not this table, is what a reviewer reads, and a row that turns
out different is corrected here in place.

### Stage 0: where it is now

The journal, the task state machine and the read-only CLI (`forge status`,
`forge history`) exist and are in the gate. The worker half exists as
libraries tested against a mock worker (`src/response.cho`, `evidence_io.cho`,
`dispatch.cho`, `worker.cho`) but is **not linked into `main`**
([#17](https://github.com/alpibrusl/cancho-forge/issues/17)). Forge cannot
start anything.

### Stage 1: observe, claimed (read-only)

Needs: the `main` wiring (#17), a **gate-runner worker** (section 7, D2), and
the contract methods the runner actually uses.

| row added | why | note |
|---|---|---|
| `fs_write("")` | the journal and the execution directories | already true of the libraries; G9 (cancho #534) is why it is `""` and not the workspace, and `path_ok` guards the path (`fs_covers`, S8) |
| `exec_under` | start a worker beneath a directory chosen at run time (S9: the report names no path) | the workers directory is `argv`, not a literal |
| `clock` | deadlines and timestamps | |
| `signals("INT,TERM")` | stop cleanly | architecture 5.1 |

Not added: `net`, `ffi`, `tty`. The commit that links `worker.cho` widens
the report and says so; `docs/authority.txt` is updated in it.

Workers run with an empty environment and only the arguments Forge built
(architecture section 5.3). What a repository's gate does once started is
the worker's authority, not Forge's (G2).

### Stage 2: observe, Forge-owned (read-only)

Roadmap M3. Forge runs the checks **itself**, as children with an `Exec`
bound separate from the worker's, so that a verdict can be `observed`
(`verification -> accepted` needs it). The tasks:

* the gate of a repository at a revision, run by Forge, compared with the
  claimed result of Stage 1 and with CI;
* **drift checks** that need no model: `.cancho-rev` equals the `cancho`
  field of `cancho.toml` in cancho-forge, and the compiler pin of hdl and
  forge is the revision the compiler repository publishes; no source file
  over 2,000 lines in any of the four repositories; every rule tag a
  document names is reached by a test (the rule `CONTRIBUTING.md` already
  asks for, checked by a program instead of by a reviewer).

Needs: M3 (acceptance criteria as data, `Exec` for Forge's own checks).
Adds an `exec` row for the checks' programs; the report shows them.

### Stage 3: propose (a patch, not a change)

Roadmap M4 plus the Cancho Code adapter
([#16](https://github.com/alpibrusl/cancho-forge/issues/16), blocked on
[cancho#562](https://github.com/alpibrusl/cancho/issues/562)). A worker
prepares a change in a *copy* in an execution directory and Forge records it
as `patch` evidence. **Nothing leaves the execution directory**; a human
reads the patch and applies it. Needs the policy decision point
(`Allow | Deny | NeedApproval`), approvals as journal events and budgets.

The Cancho Code worker builds a *new project from a brief* (`project.build`)
and, later, fixes one broken file (`file.fix`); it reads no existing
repository (audit section 2.1; contract section 9). It therefore fits Stage 3
for a narrow class (a one-file fix, a generated example, a new small
package), and **not** Stage 1: the epic's first draft listed it as a
dependency of the first task, which was wrong, and is corrected here in place
(section 7, D2).

### Stage 4: submit

Forge pushes a branch and opens a **draft** pull request for an approved
patch. This is the first stage with an outward effect, and the first that
needs a new kind of authority: either `net` narrowed to a named host (roadmap
M6 says the diff of the report gaining `net(...)` is the review) or an `exec`
of a narrowed git/forge client run as a worker. Which of the two is open
(D4). Per-PR approval, recorded as a journal event by a human identity; a
worker has none, so it cannot approve.

### Stage 5: maintain packages

A compiler pin bump is a task of Stage 4's kind with a fixed procedure: bump
`cancho.toml` and `.cancho-rev` together, run `spike/run.sh` **and** the gate
(`CLAUDE.md`: "do not bump it without re-running `spike/run.sh` and the
gate"), attach both outputs as evidence, open a draft PR. Release tracking
and read-only health signals are M6. The strategy loop (M7) only proposes.

Each stage ends with a go/no-go that a human signs, using the previous
stage's measured agreement with CI (Stages 1 to 2) or acceptance by a human
reviewer (Stages 3 to 5). Expansion is justified by measured performance, not
by how well the demonstration went (roadmap M7).

## 5. What Forge never does unattended

These hold at every stage. Each is "not implemented" now, which is the safest
state (threat model section 4), and each needs a named approval kind and a
policy entry *before* it can exist; a stage can add an approved path, never
remove a prohibition.

| never, without a recorded human approval | enforced by |
|---|---|
| merge a pull request (any repository, any branch) | no capability: Stage 4 can open a *draft*; merging is outside every stage |
| push to a default branch (`main`) or force-push anything | policy `Deny`, and the push path takes a branch name that policy proves is not the default; designed, not built |
| bump the compiler pin (`cancho.toml`, `.cancho-rev`) without `spike/run.sh` **and** the gate passing, both attached as evidence | the pin-bump task's acceptance criteria (Stage 5); until then, no task type exists for it |
| widen its own authority: add a capability to `main`, change `docs/authority.txt`, the policy or a budget | a code change, reviewed as a diff; a worker or the strategy loop may only *propose* (threat model section 4) |
| run code from a source the operator has not allowed | `scope-invalid` against the allow-list; **no pull request from a fork, no unreviewed branch of a stranger**, until workers run in an OS sandbox (G2) |
| accept its own work | `accept-unverified`: a task is accepted only by Forge with `basis: observed`, and for Stages 3 to 5 the acceptance of a *change* also needs a human approval |
| spend past a budget, or retry a write | `budget-exhausted` (designed, M4); a write is never retried by the adapter |
| close, edit or comment on an issue or a review | no capability in any stage; Forge reports to the journal and the operator |

Running a repository's gate is running its code. In Stage 1 that code is the
project's own, at a revision on a branch of a repository the operator owns:
"possibly wrong, not malicious". The day a revision can come from someone
else, that stops being true, and the task type needs an OS sandbox first
(outside M1 to M5).

## 6. Evidence and refusals

**Evidence.** A task's execution is journalled as events (`execution.*`), with
the intent written and synced *before* the worker starts (architecture 4.4),
so a crash between intent and outcome becomes `execution.lost` on recovery
(architecture 4.3; measured at 25 crash points for a process kill, **not**
for power loss). Evidence is a list of references, never content:
`{kind, ref, sha256, bytes}`, each recomputed by Forge beneath the
execution directory, following no link (worker contract 4.1; measured by
spike S10 and 24 conformance cases). For a gate report the refs are the gate
log (`log`), the exit status and the runner's result (`report`), and for a
test run its output (`test_output`); all `claimed` in Stage 1. `observed`
evidence starts in Stage 2, when Forge produces it with its own child.
Redaction and a credential's path never reach the journal (architecture
section 5.3; redaction rules are M4).

**Rule tags.** This plan reuses every existing tag and adds two. The
*designed* rows are added to architecture section 7 in the same change as
this document; none exists in code, and none ships without a test that
reaches it.

| rule | meaning | stage | status |
|---|---|---|---|
| `scope-invalid` | a task names a repository or a path that is not in the policy allow-list | 1 | **designed** |
| `revision-invalid` | a revision that is not exactly 40 lower-case hexadecimal digits | 1 | **designed** |
| `policy-denied`, `policy-missing`, `approval-missing`, `budget-exhausted` | the architecture's designed policy tags | 3 | designed |
| `worker-unavailable`, `worker-timeout`, `worker-output-overflow`, `worker-crashed`, `worker-error`, `worker-protocol`, `evidence-ref-invalid` | how a run ended or a reply was malformed (worker contract section 5) | 1 | implemented, tested |
| `accept-unverified`, `transition-invalid`, `actor-not-allowed` | the state machine | all | implemented, tested |

A failing gate is **not** a refusal: it is the project telling the truth, an
outcome recorded as claimed evidence. A task whose gate fails still ends
`verification`, and a human or Stage 2 decides what the failure means.

## 7. Dependencies and decisions still open

| item | issue | needed for | state |
|---|---|---|---|
| This plan | #13 | all | this document |
| `main` wiring of `worker.cho` | [#17](https://github.com/alpibrusl/cancho-forge/issues/17) | Stage 1 | open; widens `cancho authority` |
| First self-hosted task | [#18](https://github.com/alpibrusl/cancho-forge/issues/18) | Stage 1 | open |
| `capabilities`/`cancel`/`status`/`result` | [#14](https://github.com/alpibrusl/cancho-forge/issues/14) | `status` and `cancel` of a long run; **not** a blocker of a sync runner | open |
| `error.retryable` | [#15](https://github.com/alpibrusl/cancho-forge/issues/15) | policy retries; a gate that fails is not retried | open |
| Cancho Code adapter | [#16](https://github.com/alpibrusl/cancho-forge/issues/16), blocked on [cancho#562](https://github.com/alpibrusl/cancho/issues/562) | Stage 3 | blocked |
| M3 (observed checks) | roadmap | Stage 2 | not started |
| M4 (policy, approvals, budgets) | roadmap | Stages 3 to 5 | not started |

Decisions this plan does not take, each to be recorded in the document that
settles it:

* **D1. How a checkout gets into the execution directory.** Forge has no
  `git` and should not grow `net` for Stage 1. Candidates: the operator (or a
  CI job) places a read-only mirror under the workers' reach, and the runner
  copies a revision out of it; or the runner does the clone (then it, not
  Forge, holds the network, which is G2 again). Open.
* **D2. The first real worker is a gate runner, not Cancho Code.** A small
  worker, preferably a cancho program itself (no foreign code), that runs a
  repository's gate script in the execution directory under its own `Exec`
  bound and writes the evidence files. It is a new issue, and #18 depends on
  it; the Cancho Code adapter (#16) is for Stage 3. Its sync/async level: a
  gate run is minutes (section 8), which a `sync` worker can do inside a
  deadline of the same order, so #14 is not a prerequisite.
* **D3. G10 applies to the gate runner, not only to Cancho Code. Measured 2026-10-21 (spike S11, `spike/RESULTS.md`).**
  A gate starts compilers; if Forge's deadline kills the runner, what the runner started is leaked, because
  `exec_spawn_under` has no detached form ([cancho#562](https://github.com/alpibrusl/cancho/issues/562)). S11 measured the
  under form: **the leak is real** (a runner killed by Forge's deadline leaves its gate running, whether the runner
  started the gate plain or detached). The mitigation proposed here before it was measured, "the runner starts the gate
  with `exec_spawn_detached` and kills its group on its own, shorter, deadline, so the outer kill is only the backstop",
  **half holds**: with the runner's own deadline shorter than Forge's, nothing is left; but the outer kill is **not** a
  backstop, because a detached gate leaves the runner's group and session, so when Forge's deadline is the one that
  fires the gate leaks. The design rule that follows: the runner's deadline is strictly less than Forge's, with a margin
  for the group kill and the evidence; Forge's deadline is the last resort and leaks. Corrected in place from the
  earlier text of this item, in the commit that carries spike S11. Not measured: a real gate (descendants that
  `setsid`), a runner that dies mid-gate, a Forge crash (G4).
* **D4. Stage 4's push path:** `net` narrowed to a host, or a narrowed
  `exec` of a client run as a worker. Decide with M6's authority review.
* **D5. Where the allow-list and policy live,** and how a change to them is
  approved. Missing or unparseable policy is `Deny` (architecture 5.2).
* **D6. Concurrency.** One workspace, one writer (`workspace-locked`;
  measured). Stage 1 runs one task at a time; several workers at once are
  **not covered** by any measurement here (`spike/RESULTS.md`, "Not
  covered").

## 8. What has been measured, and what has not

Measured in this repository:

* the journal, the state machine, torn-tail recovery and the lock (M1: 82
  tests, 65 file cases, 25 crash points, 420 checks);
* the worker contract against a mock worker as real child processes (19
  cases, 15 of 15 mutants killed), evidence recompute (24 cases, 16 of 16),
  the classification of endings (14 tests, 28 of 28), response validation
  (19 tests, 32 of 32);
* the authority report of today's binary (`docs/authority.txt`).

Not measured, and not claimed:

* a gate run of any of the four repositories through Forge: its time, its
  agreement with CI (the leak of section 7, D3, is measured for a stand-in gate, spike S11);
* anything with a real worker, a real network, power loss, macOS, several
  workers at once, or a journal larger than the tests'.

One data point, **measured 2026-10-21**: Forge's own `scripts/gate.sh`, run once with compiler rev `7e4088b` on the cloud container of `spike/RESULTS.md` (Linux, x86_64), passed (`gate: PASS`) in 1 m 33 s wall clock (51.7 s user). That is one run of one repository, not a distribution; the compiler repository's `cargo test --workspace` and the other repositories' gates were not timed here.

## 9. What would make us stop

The plan is wrong, and is corrected here in place with the commit that
corrected it, if any of these turns out true: Stage 1's claimed verdict
disagrees with CI on a revision and the cause is Forge's; a worker leaks a
process Forge cannot find (D3, G4); the authority report grows by a row this
document did not predict; a stage's task needs a prohibition of section 5 to
be lifted. The last one is not a bug to patch around: it is a decision for
the operator, in writing.
