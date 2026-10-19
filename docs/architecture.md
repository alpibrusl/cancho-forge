# Architecture decision record: Forge is written in cancho

> **Status: accepted for Milestone 0, with the gaps in section 9.** Written
> before the runtime, in the manner of cancho's own `docs/`. Claims marked
> *(measured)* were run with the compiler pinned in `cancho.toml`
> (`cancho 0.0.0`, rev `2aa83b2`, linux-x86_64) and are recorded, with the
> commands and their output, in [`spike/RESULTS.md`](../spike/RESULTS.md) under
> the spike number cited. Claims marked *(designed)* have not been built or
> measured. A claim that turns out false is corrected here, in place.

---

## 1. Context

The design document (`cancho_forge_ideas_mvp_roadmap.md`) says Forge is "a
persistent runtime for an agent-operated software company", and that its
core principle is that **authority, budgets, evidence and approvals are
enforced by the runtime, not requested in prompts**. It leaves the
implementation language open ("adjust to the language/runtime choices") and
says Forge must not *require* its workers to be written in cancho.

This ADR decides what **Forge itself** is written in.

## 2. Decision

**Forge is written entirely in cancho.** No Python, no Rust, no shell in
the product. Other languages are allowed only as *test oracles* that look
at a result from outside the program (the way `spike/run.sh` uses `cat`,
`od` and `ps`); nothing Forge decides, stores or enforces is written in
them (`CLAUDE.md`).

Workers stay language-neutral. The worker contract
([`worker-contract.md`](worker-contract.md)) is JSON over a child
process's stdio, so Cancho Code (a cancho program) and a worker in any
other language implement the same interface.

### 2.1 Why

1. **The authority model is the product, and cancho has one.** Forge's
   job is to be an authority boundary. In cancho a program's reach is a
   set of capability values it was handed (`Fs`, `Exec`, `Net`, `Clock`,
   `Signals`, ...), each narrowable, and `cancho authority` prints what
   the program can reach. For Forge that report is an auditable statement
   of its own power: today (section 6) it says no network, no foreign
   code, files only under one directory, programs only under one
   directory. In Python or Rust the same statement would be a convention.
2. **Same toolchain as the main worker.** Cancho Code is a cancho
   program. Forge can read its `cancho authority` report (and, via
   `introspect`, its interface) with the tool that built it, and the
   worker adapter can be tested against a cancho mock worker built by the
   same compiler (spike S6).
3. **The runtime asks for exactly what cancho recently built.** Slices of
   cancho that Forge uses were each justified by the same two askers
   `docs/processes.md` names (a supervisor that runs tools as processes
   under narrowed authority), `docs/file-writes.md` (a durable log:
   append, sync, rename, lock) and `docs/signals.md` (stop cleanly).
   Forge is a third asker for the same primitives, which is how cancho
   decides what to keep (`CONTRIBUTING.md`: the bar is two askers).
4. **No ambient authority to forget.** A cancho program cannot open a
   file, start a process or read its environment without a capability in
   hand; a helper that was not passed `Exec` cannot spawn. The worker
   adapter, the journal and the policy module can therefore be reviewed
   by reading their signatures.

### 2.2 Costs, stated

* **Young platform.** One compiler, pinned by revision; the standard
  library was written for the programs that asked for it. Anything Forge
  needs that is not there is written in cancho first and moved into `std`
  only when a second program asks (`AGENTS.md`, section 7).
* **Ceremony.** `main` splits the `World` into ten capabilities and must
  release each; every function's effect row is exact. This costs lines,
  and is the same cost that makes the report true.
* **Compile-time narrowing.** `narrow` takes a *literal* (section 5.4,
  gap G1): Forge cannot narrow `Fs`/`Exec` to a path it reads from its
  configuration at run time.
* **A violated bound traps.** Spawning outside an `Exec` prefix is
  `SIGILL`, not an error value *(measured, S3)*. So the bound is the last
  line of defence and Forge's policy layer must refuse first (section
  5.2).
* **Platforms.** Linux and macOS; everything here was measured on Linux
  x86_64 only.
* **No database.** State is an append-only file plus projections
  (section 4). That is the plan, not a limitation, for the MVP's single
  workspace, and it is the thing to revisit if M7's pilot outgrows it.

### 2.3 Alternatives considered

| Option | Why not (now) |
|---|---|
| Host in Rust/Python, workers in cancho | Gives up the point of the exercise: Forge's own authority would be a convention, and the hosting language's `subprocess`/`open` have no `authority` report. Also two toolchains in the gate. |
| Host in cancho, state in SQLite via `Ffi` | `Ffi("libc")` is every authority at once (`docs/processes.md` section 1): the report would say `UNBOUNDED` and the point of choice 1 is lost. Revisit only with a narrowed foreign scope or a native store. |
| Event-sourced journal as the only state (chosen) | Section 4. |
| Mutable current-state files as the source of truth | Cannot answer "why is it in this state", and a crash mid-rewrite loses it. |

## 3. How each Forge subsystem maps onto cancho

"Spike" is the experiment that measured the primitive; "std/builtin" is
what is used. Nothing in the right-hand column is a Forge feature yet.

| Forge subsystem (design doc 6.x) | Built from | Evidence |
|---|---|---|
| Company state, task graph, event records (6.1, 6.2, 10) | An append-only JSONL journal; projections rebuilt by replay; `std.json` for records, `enum` + exhaustive `match` for the task state machine | S4, S5; `src/event.cho` and its tests |
| Durable storage, restart recovery | `open_append`, `file_write`, `file_sync`, directory sync, `file_truncate`, `fs_rename`, `file_lock` under one narrowed `Fs` (`docs/file-writes.md`) | S5 |
| Worker interface (6.3) | `std.process` over `exec_spawn`: `channels`, `capture` (stdin written while stdout is read, size bound, deadline, reap on every path), `capture_both` for stderr; `Argv` for the `\0` argument list | S1, S2, S6 |
| Bounded execution: timeout, output cap, cancellation (6.2, 6.6) | `Clock` + `Poller` deadline inside `capture`; `child_kill`; `Signals` narrowed to `INT,TERM` to stop Forge itself | S2, S6; signals designed (`docs/signals.md`), not spiked |
| Policy and authority (6.4) | Pure cancho functions over a policy document (parsed with `std.json`) called before every effect; the narrowed capabilities are the second, structural layer (section 5) | S3 (bounds); policy module designed |
| Budgets and resource limits (6.6) | Integers in the journal: reservation, usage and release events; the same replay that rebuilds state rebuilds the remaining budget | designed |
| Approval gates (6.2, 7) | `approval.requested` / `approval.granted` events; an operator CLI reads `Args`/`Io`, writes events. Approvals are journal facts, so they survive restarts | designed |
| Evidence and audit (6.5) | Artifacts as files under per-execution directories, referenced from events by path + `sha256` (`std.crypto.sha256` exists; Forge recomputes the hash itself) | hashing not spiked |
| Verification gate (M3) | The same `std.process` machinery runs repository checks as a Forge-owned child, separate from the worker's own claims | designed (S6 shows a worker's `succeeded` is only a claim) |
| Operator CLI (M1, M5) | `Args` + `Io`; one binary, subcommands | `src/main.cho` is a stub |
| Local web UI (M5, optional) | `std.http` + `std.route` server loop (`docs/http-server.md`), `Net` narrowed to loopback | not spiked |
| Operate loop (M6) | `Net` narrowed to named hosts (`Net("api:443")`) for read-only signals; no deploy capability exists until M6 grants one | designed |
| Scheduler (6.2) | A single loop over a `Poller` and `Clock`: wakes on child exit, deadline or signal | the poll loop exists inside `capture`; the scheduler is M1/M2 |

## 4. The journal is the source of truth

### 4.1 Shape

One directory, `<workspace>/.forge/`, narrowed `Fs`:

```
journal-000001.jsonl      sealed segment (never modified again)
journal-000002.jsonl      active segment (append only)
snapshot.json             projection at seq N (a cache, never authoritative)
executions/<id>/          one worker execution's artifacts (section 4.5)
lock                      held with flock for the life of the process
```

A **record** is one JSON object on one line, ended by `\n`:

```json
{"v":1,"seq":7,"kind":"task.dispatched","task":"t-1"}
```

`v` is the schema version; `seq` starts at 1 and has no gaps across
segments; `kind` is a dotted event name; unknown fields are ignored by
readers so a later version can add fields (*measured*, S4, and unit tests
in `tests/event_test.cho`). A fuller record also carries `ts`, `actor`
(worker or human identity, never the same namespace), `rule` (on refusals),
and the policy version that decided it.

### 4.2 Write protocol *(measured, S5)*

1. Build the whole record in memory and write it with **one**
   `file_write` on a handle opened `open_append`. A record is never split
   by Forge itself; the three records of the spike returned 46, 46 and 48
   bytes written.
2. `file_sync` before Forge does anything that cannot be taken back: before
   spawning a worker, before acknowledging an approval, before reporting
   success. *Intent before effect*: `execution.started` is durable before
   `exec_spawn` is called.
3. Group commit is allowed for a burst of records with no effect between
   them; one sync covers many writes (`docs/file-writes.md` section 1.1).
4. A new or rotated file is made durable by syncing its **directory**,
   which works through the same `file_sync` on a handle opened on the
   directory (S5: `sync dir: ok`).
5. A failed sync means the file's contents are unknown
   (`docs/file-writes.md` section 5.1): Forge stops, records nothing more,
   and exits with rule `journal-sync-failed`; it does not retry.
6. One writer: `file_lock` on `lock`. A second open file description in
   the same process is refused with errno 11 *(measured, S5)*, so a second
   Forge process on the same workspace is too.

On macOS `fsync` does not flush the drive's cache (`docs/file-writes.md`
section 6). Not measured here; M1 states the durability promise per
platform.

### 4.3 Recovery *(measured, S5)*

On start, read the active segment from the start and check each complete
line:

* Bytes after the last `\n` are a **torn tail**: a crash cut a record.
  Truncate to the last newline (`file_truncate`), sync, continue. S5
  recovered 3 records from a 165-byte file, cut it to 140 bytes, and a
  second recovery was a no-op.
* A **complete** line that is not valid JSON, has an unknown `v`, or whose
  `seq` is not exactly the next one is *corruption or a duplicate*, not a
  torn tail. Forge refuses (`journal-corrupt`), changes nothing, and tells
  the operator. S5 re-appended seqs 1-3 after 6 records: recovery reported
  3 bad lines and left all 420 bytes alone. The first version of the
  spike truncated them (it treated "not valid" as "torn"); that bug is why
  the two cases are separate here.
* Then rebuild projections by replaying from the last snapshot whose
  `last_seq` is not beyond the journal.

Reconciling work that was in flight is a *policy*, not a mechanism:
an `execution.started` with no `execution.finished` becomes
`execution.lost` and the task returns to `ready` under its retry budget.
Forge never silently re-dispatches (section 4.4).

### 4.4 Exactly-once, as far as it can be

A worker call has an external effect Forge cannot undo, so the journal
cannot make dispatch exactly-once; it makes it **observable and
bounded**:

* `request_id` (an idempotency key) is generated and journalled with the
  intent; the worker contract requires workers to treat a repeated
  `request_id` as the same request.
* After a crash, an unmatched intent is reconciled using the per-execution
  directory (a `result.json` the worker finished writing is accepted as
  the result) and, for a worker still running, the pid and start token
  recorded in the intent. Today a still-running worker survives its
  parent *(documented, `docs/processes.md` section 4.7; not measured
  here)*, and killing it by pid needs `/bin/kill` under an `Exec`
  (gap G4).

### 4.5 Artifacts

Patches, logs and reports live under `executions/<id>/` as files; events
carry `{"ref":"executions/<id>/patch.diff","sha256":"...","bytes":N}`.
Refs are relative, contain no `..`, and are resolved by Forge against the
one execution directory (`docs/worker-contract.md`, section 7). The
journal never contains file contents or secrets.

## 5. Authority model

Three layers, each independent. None relies on a prompt.

### 5.1 Layer 1: what the Forge process can reach

`main` splits the `World` and releases everything it does not need. Forge
at M1-M5 holds, and `cancho authority` will report, only:

| Capability | Narrowed to | Used for |
|---|---|---|
| `Fs` | the workspace directory (`.forge/` and the sample repository) | journal, artifacts, repository checks |
| `Exec` | the workers directory, plus the verifier directory | start workers and verifiers |
| `Clock` | (none) | deadlines, timestamps |
| `Signals` | `"INT,TERM"` | stop cleanly |
| `Io`, `Args`, `Heap` | | operator CLI |

`Net`, `Ffi`, `Tty` are released at once. The spike programs show what the
report looks like: the S6 dispatcher performs `child_signal`, `clock`,
`exec("/tmp/cancho-forge-spike/bin")`, `heap`, `io_write`, `pipe_read`,
`pipe_write`, `poll` and "never touches the filesystem, the network ...
foreign code" *(measured, S6)*. The report is checked in and diffed in
review once the runtime exists: **a change that widens it is a visible
diff** (M1 deliverable).

A function's parameters are its own authority statement. The journal
module takes `&Fs("<workspace>/.forge")` and nothing else, so it cannot
spawn; the worker adapter takes `&Exec(...)` and `&Clock`, so it cannot
write a file; the policy module takes neither.

### 5.2 Layer 2: the policy decision point

Section 6.4 of the design asks that "policy evaluation stays outside
worker-controlled code" and is checked at execution time. In Forge that
is a pure function (`[]` effect row, so it provably touches nothing) from
`(actor, action, resource, risk, budget state, approvals, policy version)`
to `Allow | Deny(rule) | NeedApproval(kind)`, called immediately before
every effect. It exists as a separate layer, and not just as "the type
system does it", for a measured reason:

> A spawn outside the `Exec` prefix, or containing `..`, is a **trap**
> (SIGILL, exit 132), not an error value *(measured, S3: modes b, d and e
> all exit 132)*.

If the narrowed capability were the only check, a mistaken dispatch would
kill the whole runtime mid-run instead of producing a refusal with a rule
tag in the journal. So Forge refuses first, with a tag, and treats the
capability bound as the backstop that makes a policy bug a crash rather
than a breach. Missing or unparseable policy is `Deny` (fail closed,
principle 9).

### 5.3 Layer 3: what a worker is given

A worker is started with `exec_spawn`, which hands it **only** what is
passed *(`docs/processes.md` sections 4.3, 4.4, 4.5; the empty
environment and the three streams are as designed; `LD_*`/`DYLD_*` entries
trap)*:

* an argument list Forge built with `Argv` (an argument containing `\0` is
  refused, not truncated);
* an empty environment (no `HOME`, no credentials in variables);
* stdin, stdout, stderr as Forge-owned pipes or `/dev/null`; no inherited
  descriptors (close-on-exec everywhere);
* a working directory (`exec_spawn_in` with a `Dir` capability) that is
  the execution directory.

Credentials a worker needs are passed per task, on stdin, in the request,
and are never journalled. Worker identity is a name Forge assigns and
journals; it is a different namespace from human operators.

### 5.4 What the model does not give us

Stated now so nobody discovers it later (each is expanded in
`spike/RESULTS.md`):

* **G1. Narrowing is compile-time.** The workers directory and the
  workspace are literals in the binary. Per-task, short-lived,
  run-time-chosen grants (design doc 6.4) are not expressible as
  capabilities. Forge enforces them in layer 2 (path checks against the
  task's declared scope) and uses the compile-time bound as an outer
  fence. Already an open row in `docs/processes.md` section 9 ("A bound
  chosen at deployment").
* **G2. The child's authority is the child's.** `Exec` bounds *which
  program* starts, not what it then does (`docs/processes.md` section 2).
  A worker that is a cancho program has a `cancho authority` report Forge
  can read and compare to what it granted; any other worker needs an OS
  sandbox (`lex-os`), which is outside M1-M5.
* **G3. Killing a worker does not kill its children.** Measured, S7: a
  killed worker's grandchild kept running. With `exec_spawn_detached`
  and `/bin/kill -KILL -- -<pid>` through the same `Exec`, the group
  dies. This costs `/bin/kill` in the `Exec` bound.

## 6. The task state machine

Runtime-owned. A worker never causes a transition by saying so; it
returns data and Forge decides.

```
proposed -> approved -> ready -> running -> verification -> accepted
   |           |          |        |  ^          |
   |           |          |        |  +-- retry -+--> rejected
   v           v          v        v
cancelled   cancelled  blocked   failed / lost -> ready (within retry budget) | blocked
```

* `running -> verification` is the only exit that carries a worker's
  `succeeded`; `verification -> accepted` requires Forge-observed evidence
  for every acceptance criterion (M3). A worker's `succeeded` alone never
  accepts *(measured as far as M0 can: S6 maps it to "verification, not
  accepted")*.
* Every transition is an event; an invalid transition is refused with
  `transition-invalid` and written as an event too.
* The transition table is an `enum` and a total `match`; the compiler
  refuses a state added without handling it (rule `match-not-exhaustive`,
  *measured*: a `match` missing `S::C` is refused with "this `match` does
  not cover `S::C`"). A `_` arm defeats that, so state matches in Forge do
  not use `_`; reviewers look for it.

## 7. Refusals and rule tags

Every refusal has a stable `rule`, as the compiler's do (`docs/agent-errors.md`
in cancho). It is a kebab-case name, appears in the journal event, the CLI
output and the final report, and has a test that reaches it. The first set:

| rule | meaning |
|---|---|
| `transition-invalid` | event would make a task move along an edge not in the table |
| `policy-denied` | policy decision `Deny`, with the policy version |
| `policy-missing` | no policy loaded or it did not parse (fail closed) |
| `approval-missing` | a protected action without a granted approval |
| `budget-exhausted` | a reservation would exceed a limit |
| `worker-protocol` | worker reply is not valid for the contract |
| `worker-contract-version` | no common contract version |
| `worker-timeout`, `worker-output-overflow`, `worker-crashed`, `worker-error`, `worker-unavailable` | observed ending of a worker process (section 5 of the worker contract) |
| `evidence-ref-invalid` | a path outside the execution directory, or a hash that does not match |
| `journal-corrupt` | a complete journal line that is not the next record |
| `journal-sync-failed` | `fsync` failed; contents unknown; Forge stops |
| `workspace-locked` | another Forge holds the lock |

The contract and the roadmap may add rules; none ships without its row
here and a test.

## 8. What this ADR does not decide

Policy language syntax, the cost accounting source, the shape of the
operator UI, and anything about Cancho Code's real interface (the contract
is written ahead of it and must be checked against it before M2 starts;
the roadmap says so). Those are M1-M5.

## 9. Open gaps this decision depends on

Collected from the spike; each says what cancho feature would remove it.
No cancho issue for any of them was found or filed in M0 (the one
reference is an existing open row in `docs/processes.md` section 9).

| # | Gap | Effect on Forge | Needed from cancho |
|---|---|---|---|
| G1 | `narrow` takes only literals | No run-time scoped grants; workers and workspace directories are fixed at build | A way to narrow to a value chosen at deployment (`docs/processes.md` section 9, "A bound chosen at deployment"; same question for `Fs`) |
| G2 | Out-of-bound spawn traps | Policy must pre-check; a policy bug is a crash | Either accepted as designed, or a checked variant that answers `Failed(EPERM)` |
| G3 | Kill reaches only the pid | A timed-out worker can leave a compiler or test runner running | A group-kill on a detached child (today: `/bin/kill` under `Exec`, measured to work) |
| G4 | No kill-by-pid capability; parent death does not kill children | Restart cannot cleanly stop an orphaned worker | `docs/processes.md` section 9: kill-by-pid with its own capability; `PR_SET_PDEATHSIG` on Linux only |
| G5 | `fsync` durability on macOS is weaker | Durability promise differs per platform | `F_FULLFSYNC` (`docs/file-writes.md` section 6) |
| G6 | Header of `docs/processes.md` says slices 3 and 4 are "designed, not built"; its own slice table and `std/process.cho` say built | Misleading; S1-S2, S6, S7 use `std.process.capture` successfully | Correct the header in the cancho repository |
