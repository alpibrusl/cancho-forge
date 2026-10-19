# Architecture decision record: Forge is written in cancho

> **Status: accepted for Milestone 0, with the gaps in section 9.** Written
> before the runtime, in the manner of cancho's own `docs/`. Claims marked
> *(measured)* were run with the compiler pinned in `cancho.toml`
> (`cancho 0.0.0`, rev `2aa83b2`, linux-x86_64) and are recorded, with the
> commands and their output, in [`spike/RESULTS.md`](../spike/RESULTS.md) under
> the spike number cited. Claims marked *(designed)* have not been built or
> measured. A claim that turns out false is corrected here, in place.
>
> **Corrected after M0** (by the Cancho Code audit,
> [`cancho-code-audit.md`](cancho-code-audit.md), and by building M1's core):
> section 5.3 (credentials are not passed on stdin), section 6 (the real edge
> table; `retry` goes through `ready`), section 7 (the rules M1 implements and
> tests), section 8, and section 9 (G9: a library cannot be generic in the
> `Fs` prefix). Each is marked where it changed.
>
> **Corrected after the pin bump** to rev `8411e9a` (cancho #533, #536): the
> spikes below were measured at `2aa83b2`; all were re-run at `8411e9a`, and
> only S7 changed (group kill is built; G3, section 5.4 and section 9).

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
| Bounded execution: timeout, output cap, cancellation (6.2, 6.6) | `Clock` + `Poller` deadline inside `capture`; `child_kill`; `child_kill_group` for a worker started `exec_spawn_detached` (which `capture` calls itself on its kill paths); `Signals` narrowed to `INT,TERM` to stop Forge itself | S2, S6, S7; signals designed (`docs/signals.md`), not spiked |
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
{"v":1,"seq":7,"kind":"task.running","task":"t-1","actor":"forge"}
```

`v` is the schema version; `seq` starts at 1 and has no gaps across
segments; `kind` is a dotted event name; unknown fields are ignored by
readers so a later version can add fields (*measured*, S4, and unit tests
in `tests/event_test.cho`). **As built in M1** (`src/event.cho`): a task event
carries `actor` (`forge`, `worker` or `human`: never the same namespace) and,
for a fact Forge itself checked, `basis: "observed"`; a refusal is a record of
kind `refusal` with `task` and `rule`. A fuller record will also carry `ts`
and the policy version that decided it *(designed)*.

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

**As built in M1** *(measured: `tests/journal_test.cho`, 25 cases, and
`tests/conformance/journal_files.cho`, 24 cases against real files)*: the pure
core is `src/journal.cho` (`replay` over a byte slice into the state of every
task, `recovery_cut`, `submit`), the file layer `src/journal_io.cho`
(`read_all`, `append`, `recover`). Details that the paragraph above leaves to
the reader:

* A complete line the *state machine* refuses (say a `task.running` for a task
  still `proposed`) is not "corrupt bytes". It is reported under the
  machine's own tag (`transition-invalid`, `accept-unverified`, ...) with the
  1-based line number, and, like corruption, nothing is cut.
* A record whose `seq` is not exactly the next one, a `v` this build does not
  know, a line that is not a JSON object, an empty line: `journal-corrupt`.
* A tail that is a whole, valid record without its newline is still a torn
  tail: the newline is part of the record, and the tail is cut.
* The first failure ends the replay; the table it leaves behind must not be
  used, and the report says so (`rule` is non-zero).
* Recovery never takes its decision from the file layer: `journal.recovery_cut`
  is a pure function of the report, and is -1 whenever the replay was refused.

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
  (gap G4, still open: `child_kill_group` needs the `Child`, which died
  with the crashed Forge).

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

**(Corrected.)** The draft said credentials "are passed per task, on stdin, in
the request". The Cancho Code audit showed that is not how its real
interface works: the API key is a **file path** named inside the agent command
line (`--key-file`), read by the agent, never an environment variable or an
argument value, and the build tool has no stdin protocol at all
([`cancho-code-audit.md`](cancho-code-audit.md) 2.2). So the rule is: a
credential is a file Forge grants by path, in a command line Forge builds from
configuration and never from a task; the key's *contents* are never journalled,
and its path is filtered from anything shown. A worker that does read a
request on stdin may still be given a per-task credential there. Worker identity is a name Forge assigns and
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
* **G3. ~~Killing a worker does not kill its children.~~ Built (cancho
  #533, merged; corrected in place after the pin bump to `8411e9a`).**
  Measured, S7: a plain `exec_spawn` worker's grandchild still survives a
  kill (the control). A worker started with `exec_spawn_detached` leads
  its own process group, and `child_kill_group(&Child, signal)` (edition
  9, cancho `docs/processes.md` 4.12) signals that group; `std.process.capture`
  does it itself, before the pid's kill, on its deadline, output-bound
  and watch-failure paths. No `/bin/kill`: the dispatcher's `Exec` is
  narrowed to the worker alone and the authority report has no
  `exec("/bin")` (S7 prints it). Residual, from cancho's document: a
  descendant that calls `setsid`/`setpgid` leaves the group; a worker that
  exits by itself and leaves a subprocess behind is not killed by
  `capture` (the dispatcher calls `child_kill_group` before `child_wait`
  to cover it); after a Forge *crash* there is no `Child` to hold (G4).

## 6. The task state machine

Runtime-owned. A worker never causes a transition by saying so; it
returns data and Forge decides. **As built in M1** in `src/task.cho`
*(measured: `tests/task_test.cho`, 22 cases, an independent oracle of the
whole 9 x 9 table)*:

```
proposed -> approved -> ready -> running -> verification -> accepted
```

That is the happy path. Off it: any non-terminal state can be `cancelled`; a
proposal can be `rejected`; `ready` and `running` can be `blocked`, which
returns only to `ready`; `running` goes back to `ready` when an execution is
lost or fails within the retry budget; `verification` can be `rejected` or go
back to `ready` for a repair.

The table, one row per state (these 18 edges are all of them):

| from | to |
|---|---|
| `proposed` | `approved`, `rejected`, `cancelled` |
| `approved` | `ready`, `cancelled` |
| `ready` | `running`, `blocked`, `cancelled` |
| `running` | `verification`, `ready`, `blocked`, `cancelled` |
| `blocked` | `ready`, `cancelled` |
| `verification` | `accepted`, `rejected`, `ready`, `cancelled` |
| `accepted`, `rejected`, `cancelled` | (terminal: nothing) |

**Corrected from the M0 diagram.** M0 drew `verification -> running` as
"retry". There is no such edge: a repair or a retry goes back through
`ready`, so the budget and the policy are consulted again before the next
dispatch, and no task is ever `running` without having been `ready` first.
M0's `failed` and `lost` are not states: a failed or lost execution is an
event, and the task returns to `ready` (within its retry budget) or to
`blocked`. `proposed -> rejected` is new: declining a proposal needs no
approval first.

* `running -> verification` is the only exit that carries a worker's
  `succeeded`; `verification -> accepted` requires a Forge-observed check
  (M3 supplies the evidence; M1 enforces the *form*). A worker's `succeeded`
  alone never accepts *(measured as far as M0 can: S6 maps it to
  "verification, not accepted"; measured in M1 as a property over every
  state, every actor and both bases: exactly one of 60 combinations reaches
  `accepted`, Forge + `basis: observed` from `verification`)*.
* **The decision order is part of the contract** (`task.decide`):
  1. a `task.proposed` event creates a task (`task-duplicate` if it exists,
     `actor-not-allowed` if a worker wrote it); any other event needs a task
     that exists (`task-unknown`);
  2. a move to `accepted` needs `actor` forge *and* `basis` observed, else
     `accept-unverified`, whoever wrote it (a worker's claim, a human's word
     and an unobserved Forge event alike); this is checked **before** the edge,
     so a worker claiming `accepted` from `running` is `accept-unverified`, the
     more informative refusal;
  3. a worker never moves a task: `actor-not-allowed`;
  4. the edge must be in the table: `transition-invalid`.
* Every transition is an event; a refused move is written as a `refusal`
  event with its rule tag (`journal.submit`), changes no state when
  replayed, and so "why is it in this state" has an answer.
* The transition table is an `enum` and a total `match`; the compiler
  refuses a state added without handling it (rule `match-not-exhaustive`,
  *measured*: a `match` missing `S::C` is refused with "this `match` does
  not cover `S::C`"). A `_` arm defeats that, so state matches in Forge do
  not use `_`; reviewers look for it. (`to` in `can_move` is compared by code
  because the language has no `==` on enums; `from` is matched exhaustively.)
* A task id is 1 to 64 bytes of letters, digits, `.`, `_`, `-`, starting
  with a letter or digit: it is the projection's key and a path component
  (`executions/<id>/`), so it can be neither `.` nor `..`.

## 7. Refusals and rule tags

Every refusal has a stable `rule`, as the compiler's do (`docs/agent-errors.md`
in cancho). It is a kebab-case name, appears in the journal event, the CLI
output and the final report, and has a test that reaches it. **A rule ships
with its row here and a test; the "Reached by" column says which, and a rule
with no test yet is marked *designed* and does not exist in code.**

Implemented in M1 (`task.Rule`, `src/task.cho`; each reached by a named test
in `tests/task_test.cho` and/or `tests/journal_test.cho`, and the file-level
ones by `tests/conformance/journal_files.cho`):

| rule | meaning | Reached by |
|---|---|---|
| `transition-invalid` | event would make a task move along an edge not in the table (including any move out of `accepted`, `rejected`, `cancelled`) | `test_transition_invalid_is_reached`, `test_an_illegal_transition_in_the_journal_is_reported_by_its_own_tag`, `test_submit_a_refused_move_is_recorded_not_applied` |
| `accept-unverified` | a move to `accepted` not written by Forge with `basis: observed`: a worker's claim, a human's word, or an unobserved Forge event | `test_accept_unverified_is_reached`, `test_accepted_is_reached_in_exactly_one_way`, `test_a_worker_claim_of_acceptance_in_the_journal_is_refused`, conformance `claim:` and `refusal:` |
| `actor-not-allowed` | a worker wrote an event that would move a task, or propose one | `test_actor_not_allowed_is_reached`, `test_a_worker_never_moves_a_task`, `test_a_worker_actor_cannot_move_a_task_in_the_journal` |
| `task-unknown` | an event for a task id Forge has never seen proposed | `test_task_unknown_is_reached`, `test_events_for_a_task_never_proposed_or_proposed_twice_are_refused` |
| `task-duplicate` | a `task.proposed` for an id that exists | `test_task_duplicate_is_reached` (all nine states), same journal test |
| `event-malformed` | a task event with no or non-string `task` / `actor`, an `actor` that is not forge / worker / human, a `basis` that is not a string, or a task id outside the closed set | `test_malformed_task_events_are_refused`, `test_submit_with_a_bad_id_is_recorded_against_no_task` |
| `event-unknown` | a kind that is neither a `task.*` kind nor in a namespace M1 records (`refusal`, `execution.`, `approval.`, `budget.`, `policy.`, `company.`) | `test_unknown_kinds_are_refused` |
| `journal-corrupt` | a complete journal line that is not the next record: not JSON, not an object, unknown `v`, `seq` not exactly next (gap, duplicate, not starting at 1), wrong types | `test_garbage_in_the_middle_...`, `test_a_duplicated_run_of_seqs_...`, `test_a_gap_in_seq_is_corrupt`, `test_lines_that_are_not_records_are_corrupt`, conformance `duplicate:` and `garbage + torn:` |
| `path-invalid` | a journal path that is not absolute, has a `..` component, a NUL, or is longer than 512 bytes: refused before the file capability (which traps on `..`) is reached | conformance `path:`, `recover: a .. path`, `append: a .. path` |

Designed, not implemented (no test reaches them yet; they are not claims):

| rule | meaning |
|---|---|
| `policy-denied` | policy decision `Deny`, with the policy version |
| `policy-missing` | no policy loaded or it did not parse (fail closed) |
| `approval-missing` | a protected action without a granted approval |
| `budget-exhausted` | a reservation would exceed a limit |
| `worker-protocol` | worker reply is not valid for the contract |
| `worker-contract-version` | no common contract version |
| `worker-timeout`, `worker-output-overflow`, `worker-crashed`, `worker-error`, `worker-unavailable` | observed ending of a worker process (section 5 of the worker contract; the Cancho Code binding adds how an exit code is read, section 9.4) |
| `evidence-ref-invalid` | a path outside the execution directory, or a hash that does not match |
| `journal-sync-failed` | `fsync` failed; contents unknown; Forge stops (the file layer returns the errno today; the stop is M2) |
| `workspace-locked` | another Forge holds the lock |

The contract and the roadmap may add rules; none ships without its row
here and a test.

## 8. What this ADR does not decide

Policy language syntax, the cost accounting source, and the shape of the
operator UI. Those are M1-M5. (M0 also deferred Cancho Code's real interface;
that audit is done, [`cancho-code-audit.md`](cancho-code-audit.md), and the
worker contract was corrected by it.)

## 9. Open gaps this decision depends on

Collected from the spike; each says what cancho feature would remove it.
No cancho issue for any of them was found or filed in M0 (the one
reference is an existing open row in `docs/processes.md` section 9).
**Corrected after M0, in place:** the gaps were searched for and filed
upstream; the status of each is in its row below.

| # | Gap | Effect on Forge | Needed from cancho |
|---|---|---|---|
| G1 | **Open: [cancho #534](https://github.com/alpibrusl/cancho/issues/534).** `narrow` takes only literals | No run-time scoped grants; workers and workspace directories are fixed at build | A way to narrow to a value chosen at deployment (`docs/processes.md` section 9, "A bound chosen at deployment"; same question for `Fs`) |
| G2 | **Open: [cancho #535](https://github.com/alpibrusl/cancho/issues/535).** Out-of-bound spawn traps | Policy must pre-check; a policy bug is a crash | Either accepted as designed, or a checked variant that answers `Failed(EPERM)` |
| G3 | **Built: [cancho #533](https://github.com/alpibrusl/cancho/issues/533), merged** (`child_kill_group`, rev `8411e9a`; S7 re-run, no `/bin/kill`). Was: kill reaches only the pid | Nothing now; workers that start subprocesses are started detached | None. Residual: a descendant that leaves the group; the orphan after a Forge crash (G4) |
| G4 | **Open, no issue; `docs/processes.md` section 9** (narrowed by #533 for a live supervisor only). No kill-by-pid capability; parent death does not kill children | Restart cannot cleanly stop an orphaned worker | `docs/processes.md` section 9: kill-by-pid with its own capability; `PR_SET_PDEATHSIG` on Linux only |
| G5 | `fsync` durability on macOS is weaker | Durability promise differs per platform | `F_FULLFSYNC` (`docs/file-writes.md` section 6) |
| G6 | **Fixed: [cancho #536](https://github.com/alpibrusl/cancho/issues/536) (closed; in `8411e9a`).** Header of `docs/processes.md` says slices 3 and 4 are "designed, not built"; its own slice table and `std/process.cho` say built | Misleading; S1-S2, S6, S7 use `std.process.capture` successfully | Correct the header in the cancho repository |
| G9 | **Open: [cancho #534](https://github.com/alpibrusl/cancho/issues/534)** (with G1). A library function over `Fs` cannot be generic in the prefix: `Fs("/x")` is not accepted where a function declares `Fs("")` *(measured, M1; see `spike/RESULTS.md`, "M1 findings")* | `src/journal_io.cho` is written against `Fs("")` and guards the path itself (`path-invalid`); a binary that links it reports `fs_read("")`, `fs_write("")`. The production `forge` binary links it in M2, and that widening is a visible diff in `cancho authority` and says so in its commit | The same run-time-chosen-bound question as G1, for `Fs`; or a way to declare a function generic in a capability's prefix |
