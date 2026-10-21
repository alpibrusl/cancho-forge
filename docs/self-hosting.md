# Self-hosting: Forge managing the cancho project

> **Status: a plan; Stage 1's first task is built (`forge gate`, sections 3.1, 7 and 8), nothing else is.** It says
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

**Built** (`forge gate`, issue #18): `forge gate <dir> <workers> <repo> <revision> <checkout> <execution-dir> [timeout-ms] [NAME=value ...]`
(`src/main.cho`, `src/gate_run.cho`) takes the lock of the workspace, records the task (`task.proposed`, `task.approved`
by the human who ran the command), checks it (`forge.gate_task`: a refusal is a `refusal` record with its rule tag and the
task stays `approved`), moves it to `ready` and `running`, writes `execution.started` (the intent, before the worker
starts), starts the gate runner as a child process (`forge.worker.execute`: a deadline, an output cap, the evidence
recomputed against the files, a symlink not followed), writes the rule tag if the ending is a refusal, writes
`execution.finished` with the runner's verdict as a claim (`"actor":"worker","basis":"claimed"`), and moves the task by
`forge.flow.target_of`: **`verification`**, never `accepted`. Exit status: 0 a claim was recorded (a failing gate is
still 0: the project telling the truth; an environment failure is not a fail, D7), 1 the task or the journal was refused, 2 usage or a
path that is not ok, 3 the workspace is locked or a directory cannot be opened, 4 the run ended without a claim (the
ending and the state are printed: a gate that ends 126 or 127 is such a run, `incomplete`, D7). The trailing `NAME=value`
arguments are the operator's environment for the gate (D7); `scripts/self_host_gate.sh` runs one repository at one
revision with it, the way section 8 reports. What Forge cannot do itself (cancho has no `mkdir`, and decision D1 stays open): the
execution directory (empty), the checkout (at the revision) and the workers directory are made by the operator
beforehand. Measured in section 8.

Success criterion, to be measured and not assumed: for N revisions of the
four repositories, Forge's claimed verdict equals CI's. *N and the time per
run are unmeasured.* Data points exist: see section 8.

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

Until the Cancho Code adapter exists, the flows of this stage (a proposal recorded as `patch` evidence, a claim that is
never acceptance) are tested end to end against the stub LLM ([`stub-llm.md`](stub-llm.md)): a scripted worker whose
`propose` behaviour returns a patch, and whose failures (a refusal, a reply that lies, a reply too late, a crash) are
the ones a model-backed worker will have.

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
| `scope-invalid` | a task names a repository that is not in the allow-list | 1 | **implemented in `forge.gate_task`, tested** (Forge's own call arrives with #17) |
| `revision-invalid` | a revision that is not exactly 40 lower-case hexadecimal digits | 1 | **implemented, tested** |
| `task-type-invalid`, `limits-invalid` | a task of another type; a `timeout_ms` outside 2 s to one day (added when the runner was built) | 1 | **implemented, tested** |
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
| `main` wiring of `worker.cho` | [#17](https://github.com/alpibrusl/cancho-forge/issues/17) | Stage 1 | **done for one verb**: `forge gate` links it; `docs/authority.txt` widened (architecture section 4.9). Not a general wiring: no other verb starts a worker |
| Gate-runner worker | [#20](https://github.com/alpibrusl/cancho-forge/issues/20) | Stage 1 | **built**, wired into `forge gate`; run on two real repositories, see section 8 and D7 |
| First self-hosted task | [#18](https://github.com/alpibrusl/cancho-forge/issues/18) | Stage 1 | **built** (`forge gate`, section 3.1); run on `cancho-forge` and `cancho-ui` with the operator's environment it **agrees with CI** (one revision each, section 8); without it, `incomplete` (D7) |
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
* **D2. The first real worker is a gate runner, not Cancho Code. Built** (`workers/gate_runner.cho`, issue #20, worker
  contract section 10): a cancho program (no foreign code), `sync`, that checks the checkout is at the revision, runs
  the repository's gate under its own `Exec("/bin/sh")` bound and writes `gate.log` and `report.json`. #18 depends on
  it; the Cancho Code adapter (#16) is for Stage 3. A gate run is minutes (section 8), which a `sync` worker does
  inside a deadline of the same order, so #14 is not a prerequisite. Tested against real git checkouts and real child
  processes (38 checks: 22 conformance cases, 15 outside oracles, the authority report), 60 of 60 unit breaks and 26 of 27
  end-to-end breaks killed (the survivor is unobservable with dash as `/bin/sh`: worker contract 10.5); **not** run against any of the four real
  repositories' gates (D7).
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
* **D7. The gate's environment. Decided 2026-10-21, built in the change that carries this text; measured in section 8.**
  Before it, the runner started the gate with a fixed `PATH=/usr/local/bin:/usr/bin:/bin` and nothing else, and the first
  real runs (below, kept as the evidence) showed three problems. The decision for each:
  1. **The environment is the operator's, never the task's.** `forge gate` takes it as trailing arguments,
     `NAME=value`, after the optional timeout; Forge puts it in `grants.env` of the `execute` request (a JSON array of
     strings; absent means none), never in `task.input`, which is all a task controls (worker contract 9.1: arguments
     come from configuration). The names are a closed list, **`PATH`, `HOME`, `CANCHO_CACHE`, `CARGO_HOME`,
     `RUSTUP_HOME`**, at most 5 entries (one for each name), no name twice; the values are absolute paths (`PATH`: absolute directories
     joined by `:`), letters, digits and `._/-`, no `..`, at most 512 bytes (`PATH`: 1024). Anything else (`LD_PRELOAD`,
     `BASH_ENV`, a relative path, a value with a space or a quote) is the refusal **`env-invalid`**: Forge refuses it
     before anything runs (the task stays `approved`, the tag is journalled), and the runner checks again, because a
     request may not come from Forge. An operator `PATH` is put **in front of** the fixed one, which stays: the system
     directories are never removed. The runner's authority does not change (the environment was already an argument of the
     spawn); the checks are pure (`src/gate_env.cho`). **Not decided here: who may write the operator's command line.**
     It is whoever runs `forge`, as before.
  2. **An environment failure is not the project's failure.** Exit 126 and 127 of the gate (the shell could not run or
     find a command) end the run as **`incomplete`**, ending `environment`, worker error `gate-environment`, with the log
     and the report written: no verdict is claimed, the task is not moved to `verification`, and nothing says `fail`. The
     cost is that a gate that exits 127 for its own reasons is also `incomplete`; that errs on the side of not claiming.
  2b. **A missing tool is found before the gate runs.** Found by measuring (section 8): `scripts/gate.sh` of this
     repository, run without `cancho` on the `PATH`, counted its failed steps and exited 1, so rule 2 did not see it and the
     run was claimed `fail`. `gate_task.required_tools` names the tools each row's gate certainly needs, and the runner's
     shell checks them with `command -v` first, in the environment the gate is given, and ends with 127 naming the missing
     one. It is a table row to extend, not a proof that nothing else is missing.
  3. **The oracles of the gates ask about their own children.** `pgrep -x gate_runner` (and `mock_worker`, `stub_llm`, the
     `sleep 79` and `git rev-parse HEAD` of the fixtures) saw the runner that was running the gate. They now go through
     `scripts/procs.sh`, which drops the **ancestors** of the asking process (read from `/proc`, no `ps`): the runner that
     runs the gate is an ancestor and is not a leak; a runner that is not an ancestor still is. The leak case is kept as a
     test of the helper (`scripts/check_procs.sh`), and broken on purpose (`scripts/mutate_procs.py`).

  **First real runs, 2026-10-21 (before this decision), each measured, kept as the evidence for it:**
  1. `cancho` is not on the fixed `PATH`: the gate of this repository fails in 338 ms with `cancho: not found`, claimed
     `fail`. Put on it by a symlink, it fails again: **`cancho test` and `cancho build` need `CANCHO_CACHE` or `HOME`**
     ("no cache directory"), which the runner does not pass. What worked was a wrapper script the operator installed as
     `cancho` that sets `CANCHO_CACHE` and execs the compiler. A Rust gate (`cancho-ui`, `cancho`) fails in 6 ms with exit
     127, `cargo: not found` (it lives in `~/.cargo/bin`; rustup also wants `HOME`).
  2. An environment failure was claimed `fail`: any non-zero exit was.
  3. The gate of this repository was not re-entrant: with the environment provided it ran completely under the runner
     (85.8 s) and failed one check, `no runner outlived the run`, because the runner running the gate *is* a `gate_runner`.
  **So: the claimed verdict for `alpibrusl/cancho-forge` at `592421a` was `fail`, and CI's was green. They disagreed (one
  revision, one repository), the cause was known, and it was not a defect of the project.** What the same runs say after
  this change is in section 8.
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

Also measured: the first self-hosted task (`forge gate`): 13 unit tests (`tests/flow_test.cho`, `tests/gate_run_test.cho`, `tests/event_test.cho`) and 29 checks on the built binary against real git checkouts and a real runner process (`scripts/check_gate_run.sh`): a pass and a fail are both claims in `verification` and never `accepted`; a checkout at another revision, a gate that never ends (nothing it started left running), a runner that is not there, a locked workspace and five refusals each end in the state and the journal records the document says. 28 of 29 deliberate breaks of `flow`, `gate_run`, `event` and `main` are killed and one is equivalent (`scripts/mutate_gate_run.py`; the first run had three survivors, all gaps in the oracles: the id of the task in the journal, and who proposed and approved it).

**Measured 2026-10-21, after D7 (the change that carries this text), `scripts/self_host_gate.sh`, one run each, on the cloud container of `spike/RESULTS.md` (Linux, x86_64), compiler `7e4088b`:**

| repository @ revision | environment given | what Forge recorded | wall clock | CI on that revision |
|---|---|---|---|---|
| cancho-forge @ `d35285f` (this change) | `PATH` (the compiler's directory), `CANCHO_CACHE`, `HOME` | claimed **pass**, task in `verification`, exit 0 | 140 s (an earlier run at `6890651`: 135 s; the gate run directly on the same machine: 84 to 110 s) | green (the `gate` run on the head `d35285f` of the pull request of this change, 110 s) |
| cancho-ui @ `5e77f0b` | `PATH` (`~/.cargo/bin`), `HOME`, `CARGO_HOME`, `RUSTUP_HOME` | claimed **pass**, `verification`, exit 0 | 99 s (an earlier run: 84 s) | green (the `gate` run of that commit on `main`, 70 s) |
| cancho-forge @ `d35285f` | none | **incomplete**, `environment`, exit 127: `the gate needs cancho, which is not on PATH`; the task is `blocked`, exit 4, no claim | 0.01 s | n/a |
| cancho-ui @ `5e77f0b` | none | **incomplete**, `environment`, exit 127: `the gate needs cargo ...`; `blocked`, exit 4 | 0.02 s | n/a |

So for these two revisions Forge's claim equals CI's, once the operator provides the environment, and an environment that is
not provided is no longer claimed as the project's failure. **That is two data points, not N**: the other two repositories
(`cancho`, `cancho-hdl`) were not run, no revision with a failing CI was run (so "Forge says fail when CI says fail" is
unmeasured for a real gate), and the times are one run each.

**What measuring found, and the change it caused.** The first run without `cancho` on the `PATH` (before the preflight below)
was still claimed `fail`: `scripts/gate.sh` runs every step, counts the failed ones and exits 1, so the shell's 127 never
reached the runner (`cancho: not found` twenty times in the log, exit status 1, 3 s). The exit-status rule of D7 sees only a
gate that dies of the 126 or 127 itself. The fix is a **preflight**: `gate_task.required_tools` names, for each row of the
allow-list, the tools its gate certainly needs (cancho-forge: `cancho git`; cancho-hdl: `git`; cancho and cancho-ui:
`cargo`), and the shell text the runner starts checks each with `command -v` in the environment the gate is given and ends
with 127, naming the tool. Limits: the list is the minimum, not a proof; a gate that needs another tool and wraps its commands
is still `fail` when that tool is missing (the list is a table row to extend, with a test).

Not measured, and not claimed:

* a gate run of `cancho` or `cancho-hdl` through Forge; a gate that really fails, in agreement with CI; the time per run beyond one run (the leak of section 7, D3, is measured for a stand-in gate, spike S11);
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
