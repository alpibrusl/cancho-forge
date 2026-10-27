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
   Forge process on the same workspace is too. **Built in M1**
   (`src/lock.cho`, section 4.7).

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
* Then rebuild projections by replaying from the snapshot, if it agrees
  with the journal (section 4.6), and from the start if it does not.

**As built in M1** *(measured: `tests/journal_test.cho`, 25 cases, and
`tests/conformance/journal_files.cho`, 24 cases against real files)*: the pure
core is `src/journal.cho` (`replay` and `replay_from` over a byte slice into
the state of every task, `recovery_cut`, `submit`), the file layer
`src/journal_io.cho` (`read_all`, `append` and the steps it is made of,
`recover`). Details that the paragraph above leaves to
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
Forge never silently re-dispatches (section 4.4). The policy is built as
`forge recover` (section 4.4.1); replaying a journal does not apply it, because
looking must change nothing (section 4.9).

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

#### 4.4.1 Recovery: `forge recover` *(issue #15; `src/recover.cho`, `src/recover_io.cho`)*

A crash can stop Forge between the records of a run. The journal then says a task is `running` and the run it was in has
no ending. `forge recover <dir>` takes the lock of the workspace, replays the journal (a torn tail is cut, as every writer
does), and settles each `running` task from the records alone. Where a task stopped is read from the last record about it
since it became `running` (`task.running`; any other `task.*` record ends the reading):

| where it stopped | what Forge writes (every record is actor `forge`) | the task is |
|---|---|---|
| `task.running`, no `execution.started` after it: the intent was never written, so no worker was started | refusal `execution-unstarted` | `ready` |
| `execution.started` and nothing after it: the worker may have run, and what it did is not known | `execution.lost`; then, if the worker was started fewer than `retry.max_attempts()` (3) times for this task, refusal `execution-lost` | `ready` |
| the same, and the worker was started 3 times | `execution.lost`, refusal `retry-exhausted` | `blocked` |
| `execution.finished` and no move after it: the worker's claim is recorded, the move was not (a finished record is written only for a `succeeded` reply, `forge gate` above) | nothing but the move | `verification` |
| `execution.accepted` and nothing after it: an `async` worker took the job (issue #33; [`async-level.md`](async-level.md)) | **nothing**: it is not lost, and starting it again would start a second build in a directory the first may still write. `forge recover <dir>` reports it `awaiting`; `forge recover <dir> <workers>` asks the worker once (`status`): running leaves it `running` and writes nothing, finished reads `result` and writes the ending a `forge build` would have written, `unknown` is refusal `execution-lost` | `running`, or what the ending says |
| `execution.cancelled` and no move after it: the worker stopped the run because it was asked to | nothing but the move | `cancelled` |
| `execution.lost` and no move after it: a recovery that was itself cut short | as the rows above, without a second `execution.lost` | `ready` or `blocked` |

The starts are counted from every `execution.started` of the task in the journal, so a task whose retries (section 4.9)
were interrupted spends the same budget a task that was not interrupted would have. Four properties, each tested:

* **Forge starts no worker.** `ready` is where the budget and the policy are consulted again (section 6). `forge gate`
  records a new task on every call, so a recovered task waits for an operator; there is no verb yet that dispatches an
  existing task (not done, below).
* **It is idempotent.** After a recovery no task is `running` without an ending, so a second `forge recover` finds nothing,
  writes nothing, and the journal is byte for byte what it was. A recovery cut short (a crash after `execution.lost`) is
  finished by the next one, which does not write the loss twice; the one thing it may repeat (not tested) is the refusal record that
  followed the loss, which is history, not state.
* **It never writes into a journal the replay refuses.** A complete bad line is `journal-corrupt` (exit 1), nothing is cut and
  nothing is appended, as for every writer (section 4.3).
* **It is one record at a time, each synced** (`journal_io.append`), like `forge gate`, so a crash in the middle leaves a
  journal that replays to the last record written.

What is *not* done, and said plainly: the pid and the start token of the worker are not in `execution.started`, so for a
worker that did not answer `accepted` Forge cannot ask whether it is still running (gap G4 above); for an `async` worker it
can (`execution.accepted` records the request and the directory, and no pid is ever used: `async-level.md` section 3). `execution.lost` therefore means "no ending was recorded", not "the
worker did nothing"; the tag `execution-lost` says Forge did not guess. Authority: `docs/authority.txt` is unchanged (the
verb uses only the journal's file capabilities that `forge gate` already needed).

#### 4.4.2 Kill and resume of `forge company run` *(task 9; `src/company_runner.cho`, `workers/check_guard.cho`; measured by `tests/conformance/company_kill.sh`)*

Which process runs in which group (Linux; the build and check rows measured with `ps -eo pid,pgid,sid,args` during a run, each detached process its own session and group leader and its children in its group; the `cancho_code` calls and the qa rows read from the spawn calls, `forge.worker` and `workers/gate_runner.cho`):

| process | started by | group / session |
|---|---|---|
| `forge company run` | the operator | the operator's (the oracle starts it with `setsid`, so it leads one) |
| `cancho_code` calls (`execute`, `status`, `result`, `cancel`) | Forge, `exec_spawn_under` | Forge's: they end with a kill of Forge's group |
| the adapter's supervisor (`cancho_code`, mode `supervise`) | the `execute` call, `exec_spawn_detached_under` | its own session: it is meant to outlive Forge (`forge await`, [`async-level.md`](async-level.md)) |
| the build tool (`cancho-build`) and what it starts | the supervisor, detached | its own session; the supervisor kills it on deadline, output cap and `cancel` |
| `check_guard` | Forge, `exec_spawn_detached_under` beneath the operator's workers directory | its own session |
| the step's check and what it starts | the guard, detached beneath the company directory | its own session; the guard kills it |
| `gate_runner` (qa steps) | Forge, `exec_spawn_under` | Forge's |
| `tool_run` (analyst steps, task 11) | Forge, `exec_spawn_under` | Forge's: a TERM or INT to Forge's group reaches it, and it kills the tool's group before it exits (`supervise.watch_stop`) |
| the tool (`analyst_tools/<tool>`) and what it starts | the tool runner, detached | its own session; the runner kills it at its deadline, past the 1 MiB cap and on a claimed signal. A SIGKILL of the runner leaves it running until it ends by itself (as a gate, G4) |
| the gate (`scripts/gate_cancho.sh` of the checkout) | the gate runner, detached | its own session |

So a kill of Forge's group reaches Forge and its transient adapter calls, never the supervisor, the build, the guard or the check.
What each kill leaves and what removes it (the first four are oracle cases, each asserted by a scan of `/proc` for every process
whose command line or working directory names the scratch directory, and by the pids the stubs recorded):

| the kill | left right after it | reaped by |
|---|---|---|
| SIGKILL of the group mid-build (K) | the supervisor and the build (asserted: they run) | the **next run**: before it admits the step again, `reap_stale` asks every task of the step's workspace whose worker may run (`recover.in_flight`: phase 2 or 5) to stop through the adapter's `cancel` (the supervisor kills the build's group and keeps a `cancelled` result), settles a phase-5 task as `forge recover <dir> <workers>` does (`await_task.run`) and recovers the rest (`recover_io.run`); `reaped: <task>` is printed. Asserted: nothing is left after that run |
| SIGTERM of the group mid-build (T) | **nothing**: Forge claims `TERM` and `INT` while a build runs (`signals("INT,TERM")`), cancels the build through the adapter (`await_run.finish_or_stop`), records the spend, prints `stopped: signal` and exits 16 | itself, before it exits (asserted before any next run) |
| SIGKILL of the group mid-check (C) | nothing, within about 100 ms: the guard tries `<dir>/check.lock` every slice (`supervise.watch`); Forge holds it while it waits, so a lock the guard can take means Forge is gone, and the guard kills the check's group | the guard |
| SIGTERM of the group mid-check (CT) | as C: the signal is not claimed outside a build, so Forge ends the default way (143) and the guard reaps the check | the guard |
| a kill between the build's end and the check (spend recorded or not) | nothing runs; the spend may be unrecorded (`budget-exhausted` row, section 7) | the next run records the delta of `usage.jsonl` against the journal, once (asserted in every case: the input of the spend records sums to that of `usage.jsonl`) |
| SIGTERM of the group while `execute` itself runs (E: the adapter has started its supervisor and build, and not yet answered `accepted`) | **nothing**: the signal also ends the `execute` call, Forge (which claimed it) sees it after the call (`await_run.stop_asked` in `build_run.run`) and asks the run to stop by its request id (`await_run.cancel_unaccepted`: `cancel`, again every 200 ms while the adapter answers `not_running`, ten times at most), then journals the call's ending, records the spend and exits 16 (`stopped: signal`). Without this the task would be journalled as ended (phase 0), so no later run would know to reap it (fix round 1) | itself, before it exits. Tested with a fixture adapter that holds back its `accepted` answer (`E:` checks) |
| SIGKILL between `execution.started` and `execution.accepted` of a build | possibly the supervisor and the build; the task stays in phase 2 (Forge wrote nothing more) | the next run, as K (`in_flight` includes phase 2; the request id is `request_id_of(task, 1)`, a build's only attempt). **Not tested**: a SIGKILL cannot be placed in that window from outside |
| a kill of the group mid-qa step | the gate (its runner dies with Forge's group, and the gate is detached) until it ends by itself; nothing bounds it once its runner is gone | **nothing** (gap G4). The next run's gate runs in the same checkout beside it. Not tested; tasks after 9 |
| SIGKILL of the guard itself (not of Forge) | the check, until it ends by itself | nothing (G4); Forge reports the check unavailable |

Every case: the lock of the company directory is free (it is a flock), `forge company status` exits 0 (a torn tail is appended
in each case), the next run is not refused `workspace-locked`, and running on to the end accepts every step exactly once: the killed
step is admitted twice, the others once, and no `company.step.accepted` is duplicated (the journal, not memory, is the state).

Forge's own deadline for the guard (the check's plus `company_step.guard_margin_ms`, 15 s) is a backstop: when it fires, `capture`
kills the guard's group, which does NOT hold the check (the check leads a group of its own), so the check would then run on to its
own end. It is unlikely: the guard's deadline is the check's and fires 15 s earlier, and the guard kills the check's group then
(the 10 s hanging check of tests/conformance/company_run.sh). It would take a guard stuck for 15 s past that.

The limits of the language this rests on: cancho has no kill by pid and no parent-death signal (`docs/processes.md` 4.7, gap
G4), so a process that outlives Forge can be stopped only by something that holds its `Child` (the supervisor, the guard) or
through a protocol (`cancel`). SIGKILL cannot be caught by any program. A race left open: if a next run takes `check.lock` before
an old guard has looked (it looks every 100 ms, and the next run rebuilds the step first), that guard runs its check to its own
deadline; and a next run waits at most 5 s for the lock before the check is unavailable.

### 4.5 Artifacts

Patches, logs and reports live under `executions/<id>/` as files; events
carry `{"ref":"executions/<id>/patch.diff","sha256":"...","bytes":N}`.
Refs are relative, contain no `..`, and are resolved by Forge against the
one execution directory (`docs/worker-contract.md`, section 7). The
journal never contains file contents or secrets.

### 4.6 Snapshots *(built in M1; measured: S5, `tests/snapshot_test.cho`, `tests/conformance/snapshot_files.cho`, `tests/conformance/crash_points.cho`)*

A snapshot is a **cache**: the projection of the journal at record N, so that
start-up replays only the tail. It is never authoritative, and it is never
trusted on its own word. One line, one newline, in `snapshot.json`:

```json
{"v":1,"last_seq":3,"journal_bytes":204,"journal_sha256":"6c09...","tasks":{"t-1":"approved","t-2":"proposed"}}
```

`last_seq` is how many records it covers, `journal_bytes` the length of that
prefix of the journal (a record boundary), `journal_sha256` the SHA-256 of
exactly those bytes, `tasks` the projection (task id to state name). The hash
is what ties a snapshot to *this* journal: a snapshot made for another
history, or for a journal that has since been cut or rewritten, does not match
(`snapshot.cho`, 18 unit tests).

**Write protocol** *(`snapshot_io.save`; the steps are public so the crash
test runs the same ones)*, as spike S5 measured it:
1. open `snapshot.json.tmp` for writing (create or truncate),
2. one write of the whole line,
3. `file_sync` that handle,
4. `fs_rename` the tmp over `snapshot.json`,
5. sync the directory.

A kill before 4 leaves `snapshot.json` as it was (absent, or the previous
snapshot) and a `.tmp` that no recovery reads and the next save truncates; a
kill after 4 leaves the new one. `save` checks both paths before opening
anything (a test found that the first version opened the tmp before noticing a
bad final path; corrected) and refuses an empty snapshot (-3), which is what
`snapshot.encode` answers to arguments that describe no prefix of the journal.

**Recovery** *(`snapshot.recover_with`, `snapshot_io.recover`)*:
* no snapshot, or an empty file: a full replay; not a refusal.
* a snapshot that checks out: its projection, then only the journal *after*
  `journal_bytes` is replayed (`journal.replay_from`). **The property**, tested
  for a snapshot after every prefix 0..10 of a ten-record journal, with and
  without a torn tail, in both modes, and again at 25 crash points on real
  files: *snapshot + tail equals the full replay*, the projection and the whole
  report (`records`, `valid_bytes`, `torn_bytes`, `tasks`, `rule`, `line`).
* a snapshot that is refused: not used, left on disk untouched for the
  operator, the journal untouched, and the projection is a **full replay**.
  The journal decides; a bad cache costs time, never correctness.

Two refusals, new tags (section 7):
* `snapshot-invalid`: not one JSON line this build reads (no newline, torn,
  not an object, wrong or missing field, unknown `v`, a state no state has, a
  task id outside the closed set, a duplicate task id, trailing text).
* `snapshot-mismatch`: well formed but it disagrees with the journal: it
  covers more than the journal holds, `journal_bytes` is not a record
  boundary, the prefix holds a different number of records than `last_seq`, the
  prefix hashes differently, a snapshot of zero records that lists tasks, or,
  **in strict mode**, replaying the prefix does not give its `tasks`.

**What the cheap mode cannot see, stated as a test**
(`test_cheap_mode_does_not_catch_that_and_the_docs_say_so`): a snapshot written
from a wrong table under the right hash passes the cheap checks, and only
`strict` (which replays the covered prefix too, so it saves no replay time)
refuses it. Forge uses `strict` until a measurement shows replay is too slow;
**no such measurement exists**, the journals are tiny. Until then the snapshot
buys the protocol and the invariants, not speed. Not built: segments and
rotation (one `journal.jsonl`), a snapshot cadence, deleting old snapshots.

### 4.7 The single-writer lock *(built in M1)*

`src/lock.cho`: `acquire(fs, path)` opens `<workspace>/lock` (created if
missing, never written) and takes `file_lock` (`flock(LOCK_EX|LOCK_NB)`) on
that handle; the handle is held for the life of the process. Answers
`Held(file)`, `Refused(rule)` or `Failed(errno)`:
* another holder, `EWOULDBLOCK` (11 on Linux, 35 on macOS): `workspace-locked`;
* a path with two dots in a row anywhere (`..`, `a..b`), relative or with a NUL: `path-invalid`, nothing opened (the rule for the dots is the compiler's, asked with `fs_covers`; spike S8);
* anything else (a missing directory: ENOENT): `Failed(errno)`, which is an I/O
  error and not a refusal by Forge.

The lock is a **separate file** from the journal, so reading or recovering the
journal never touches it, and the kernel drops it when the holder dies, however
it dies: no stale lock, no human. That last claim is *measured*, not read: the
crash test kills the holder at 24 points (every one after it took the lock) and
the parent takes the lock at once each time. While the holder lives, at the same
24 points, a second writer in another process is refused with `workspace-locked`.
Advisory only: a process that does not call `flock` is not stopped (honest
mistakes, not hostility). Not measured: macOS (the 35 is documented, not run).

### 4.8 Crash points *(built in M1; measured: `tests/conformance/crash_points.cho`)*

This replaces the earlier simulation (append half a record and call recovery),
which tested the recovery function and never a crash. The test is
`crash_writer.cho` (a child) and `crash_points.cho` (the parent).

The child is a Forge writer that does its writes **one protocol step at a time**
and, after each, prints where it is, flushes (stdout is a stdio buffer: without
`flush_out` the lines appear only at exit, which strace showed) and stops until
killed. The steps are the product's own (`journal_io.open_appender`,
`write_all`, `sync_file`, `sync_parent`; `snapshot_io.open_tmp`, `publish`),
which `append` and `save` are made of, so the sequence that is killed is the
sequence Forge runs. The parent starts it under `exec_spawn_detached` (the child
leads a group), waits for the line for crash point k, takes the lock to check it
is refused, kills with `child_kill_group(KILL)`, `child_wait`s (it must report
the KILL signal), and then plays the restart: lock, recovery, snapshot, one more
record, one more snapshot, checking the **files**, never the child's claims.

The **25 crash points** (k = 0..24):

| k | after |
|---|---|
| 0, 1 | start (nothing done), lock taken |
| 2-5 | record 1 (a new file): half written, written, synced, directory synced |
| 6-8, 9-11 | records 2 and 3: half, written, synced |
| 12-16 | snapshot at 3: tmp half written, tmp written, tmp synced, renamed, directory synced |
| 17-19 | record 4: half, written, synced |
| 20-24 | snapshot at 4 (replacing the first): the same five |

and k = 25 is the writer finishing by itself (exit 0), verified too. After each
kill, 15 to 18 named checks (15 before the first snapshot is published, 18 after): the lock is free; journal recovery succeeds with no
refusal, finds exactly the whole records the child had written, cuts a torn
tail iff the child was inside a record, leaves the file exactly its valid bytes,
and a second recovery cuts nothing; the projection has the states those records
imply (a table written by hand in the test); the snapshot is present iff one was
published, whole, used, and `snapshot + tail` equals the full replay in both
modes; the journal continues (the next record appends and replays) and a new
snapshot over the leftover tmp is saved, renamed and used. **Measured: 25 crash
points exercised, 420 checks, 0 failed, 0.9 s.**

What this does **not** test, plainly:
* **Power loss.** A killed process leaves its page cache, so bytes written and
  not synced are still in the file. Whether `fsync` reached the platter is not
  observable here (`docs/file-writes.md` section 6). The kill proves ordering
  and atomicity against a crash of the *process*: a record is whole or a torn
  tail, a snapshot is whole or absent or the previous one, a lock does not
  outlive its holder. Consequently a `file_sync` that did nothing is a mutant
  the kill test could not kill, and none is claimed killed (the attempt to build
  it was refused anyway: row exactness says a `sync_file` that no longer
  performs `file_write` does not compile).
* **A torn record by the kernel.** The product writes a record with one
  `write`, which a process kill cannot split. The child therefore *splits it in
  two* (the half-write points) to put a kill inside a record, as a short write
  would. That fault injection is the child's, not the product's.
* **Mutants killed** (each built, run to a red test, reverted): recovery never
  cutting a torn tail (21 FAIL lines); `publish` renaming to the wrong name (63);
  a failed `file_lock` ignored (24, the lock-refused check at every point);
  snapshot `last_seq` off by one (74); tail replay from offset 0 (33);
  `open_tmp` appending instead of truncating (13). And in the unit tests, the
  snapshot checks one by one (hash, boundary, record count, duplicate ids, id
  closure, strict compare, replay offset, replay record base).
* The child binary is built into the literal `/tmp/forge-crash-bin`, because
  `narrow` takes only literals (cancho #534); two gates run at once on one
  machine would collide there.

### 4.9 The operator CLI *(built in M1; `forge gate` added with issue #18)*

`forge status <dir>` and `forge history <dir> [task-id]` (`src/main.cho`,
`src/report.cho`), read-only. `<dir>` is an absolute path holding
`journal.jsonl` and, if there is one, `snapshot.json`. Looking changes nothing:
no torn tail is cut, no snapshot written, the lock not taken (a writer may be
running, and a record it is in the middle of writing shows as `torn tail
bytes`). Recovery for `status` is strict (section 4.6). Output, from the
finished crash-writer session in the gate:

```
records: 4
bytes: 272
torn tail bytes: 0
tasks: 2
  approved: 2
snapshot: used, covers 4 records
```

`history` prints `#<seq> kind=... task=... actor=... basis=... rule=...`, the
fields each record has, for every valid record (refusals included), or for one
task. Exit status: 0 clean; 1 the journal is refused (the output ends with
`journal: refused (<rule>) at line N`, after the valid records); 2 usage or a
directory that is not absolute or has `..`; 3 no `journal.jsonl` there, or an
I/O error. Measured by 8 unit tests of the text (`tests/report_test.cho`) and 13
cases run on the built binary by the gate (exact text, every exit code, and that
the journal is byte-identical after looking at a corrupt one).

**`forge await`, `forge cancel`, and the polling of `forge build`** *(issue #33; [`async-level.md`](async-level.md) sections 5 and 6)*:
when the Cancho Code adapter answers `accepted`, `forge build` writes `execution.accepted` (actor forge, with the `request` it
gave the worker and the execution `dir`), polls `status` once a second, reads `result` when the worker says `finished`, and
writes the ending exactly as for a `sync` reply (the refusal tag, the retry decision, `execution.finished` with the claim, the
move); a run still going at Forge's deadline is asked to stop (`cancel`) and ends `worker-timeout`. `forge await <dir>
<workers> <task-id> [timeout-ms]` does the same for a task whose Forge went away; `forge cancel <dir> <workers> <task-id>`
reads the journal **without the lock** and asks the worker to stop the run, writing nothing: the Forge that is polling (or the
next `forge await`) writes `execution.cancelled` and the move to `cancelled`. Exit status of `await`: 0 a claim was recorded,
4 the run ended without one, 1 the task or the journal was refused (`task-not-awaiting`), 2 usage, 3 lock or I/O; of `cancel`:
0 the worker stopped the run, 4 it did not (`not_running`, `too_late`, or the call failed), 1, 2, 3 as above.

**`forge gate`** *(issue #18; [`self-hosting.md`](self-hosting.md) section 3.1)* is the one verb that acts:
`forge gate <dir> <workers> <repo> <revision> <checkout> <execution-dir> [timeout-ms]` takes the lock of the workspace
(section 4.7), records a task and runs the gate runner on a working copy of one repository of the allow-list at one
revision, and journals what happened. The records of one run are `task.proposed`, `task.approved` (actor human: the
operator who ran the command), `task.ready`, `task.running`, `execution.started` (the intent, durable before the worker
is started: section 4.4), a `refusal` record when the ending is a refusal (its rule tag), `execution.finished` with the
runner's verdict as a **claim** (`"actor":"worker","basis":"claimed","verdict":"pass"`; the replay passes over the
`execution.` namespace and nothing accepts on it), and the move `forge.retry.target_after` gives (`verification` for a
worker's `succeeded`, `ready` for a lost or failed execution, `blocked` for what needs an operator; never `accepted`). **Retries** (issue #15): a worker that answers `failed` or `partial` with `error.retryable: true` is started again, `running -> ready -> running`, at most `retry.max_attempts()` (3) times in all; each retry is an `execution.retry` record (actor forge, the attempt that failed) written before the move, and each attempt has its own `execution.started` and its own request id (`r-<task>` for the first, `r-<task>-<n>` after). Only that case is retried: a deadline, a signal or a non-zero exit leaves the task `ready` for an operator, and a gate that fails is a claim in `verification`, not a retry. After the third failure the task is `blocked` with a `retry-exhausted` refusal; a task that writes is never retried by default (`retry-write-refused`; no task type writes today, so the branch is reached by unit tests only). The output names `attempts: n` when there was more than one. A
task that `forge.gate_task` refuses (`scope-invalid`, `revision-invalid`, `task-type-invalid`, `path-invalid`,
`limits-invalid`, `env-invalid`) is written down with its tag and stays `approved`. Exit status: 0 a claim was recorded; 1 the task or the
journal was refused; 2 usage or a path that is not ok; 3 the workspace is locked (`workspace-locked`), a directory
cannot be opened, or an I/O error; 4 the run ended without a claim. Measured by 13 unit tests (`tests/flow_test.cho`,
`tests/gate_run_test.cho`, `tests/event_test.cho`) and 56 checks run on the built binary against real git checkouts and a
real runner process (`scripts/check_gate_run.sh`, in the gate). The recovery that turns an `execution.started` with no
`execution.finished` into `execution.lost` is `forge recover` (below, section 4.4.1).

**`forge recover <dir>`** *(issue #15)* settles the tasks a crash left `running`: it takes the lock of the workspace
(section 4.7), replays the journal (a torn tail is cut), writes what happened to each task and moves it out of `running`
(section 4.4.1 has the table), prints one line for each task (`<id>: execution-lost, ...: running -> ready`) and
`recovered: <n>`. It starts no worker. Exit status: 0 done (`recovered: 0` when nothing was running); 1 the journal is
refused (the rule tag is printed, nothing is written); 2 usage, or a directory that is not absolute or has `..`; 3 the
workspace is locked (`workspace-locked`), there is no `journal.jsonl`, or an I/O error. Measured by 13 unit tests of the
plan (`tests/recover_test.cho`) and 27 checks on the built binary (`scripts/check_recover.sh`, in the gate), one of them a
real crash: `forge gate` killed with SIGKILL after it wrote `execution.started`, then recovered. 40 of 40 deliberate
breaks of the plan, the file layer and the verb are killed (`scripts/mutate_recover.py`; the first run left two alive, a
finished and a lost record of a task that was not running, and a test was added for each).

**Authority**, checked into `docs/authority.txt` and compared by the gate. It was `args`, `err_write`, `file_read`,
`fs_read("")`, `heap`, `io_write` for `status` and `history`; **`forge gate` widened it** (issue #18), by `fs_write("")`
and `file_write` (the journal, the lock), `exec_under` (the gate runner is a name beneath the workers directory, so the
report names no path), `dir_read` (that directory), `clock` and `poll` (the deadline), and `pipe_read`, `pipe_write` and
`child_signal` (the supervisor of `std.process.capture`):

```
performs
    args
    child_signal
    clock
    dir_read
    err_write
    exec_under
    file_read
    file_write
    fs_read("")
    fs_write("")
    heap
    io_write
    pipe_read
    pipe_write
    poll
never touches
    the network
    signals
    foreign code
```

It can **read and write** any file the process may (the file layer holds `Fs("")`, gap G9, cancho #534), and **start a
program beneath one directory it is given**; `path_ok` and `gate_task.check` refuse a path that is not absolute or has
`..` before a capability sees it. "Other programs" left the *never touches* list: that is the widening a reviewer should
read. It still has no network, no `signals` capability and no foreign code. The crash tests, which write, are separate
programs that are not shipped.

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
than a breach. *(Added after spike S8: the policy layer must not keep its own
copy of the bound's rule. Forge's copy refused a `..` component and accepted
`/a/..b`, which the capability traps on, so the layer meant to prevent the crash
was the way into it. It now asks the compiler, `fs_covers` / `exec_covers`, so
the two cannot drift.)* Missing or unparseable policy is `Deny` (fail closed,
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
| `event-malformed` | a task event with no or non-string `task` / `actor`, an `actor` that is not forge / worker / human, a `basis` that is not a string, or a task id outside the closed set | `test_malformed_task_events_are_refused`, `test_submit_with_a_bad_id_is_recorded_against_no_task`; for `company.journal` (a `company.*` kind this build knows with wrong fields: a verdict that is not `approved` or `rejected`, a non-string artifact, a negative or over-large token count, a `cost_micro` that is not a count): `test_a_known_kind_with_the_wrong_fields_is_event_malformed`, `test_spend_saturates_instead_of_overflowing`, `test_a_cost_that_is_not_a_count_is_event_malformed` |
| `event-unknown` | a kind that is neither a `task.*` kind nor in a namespace M1 records (`refusal`, `execution.`, `approval.`, `budget.`, `policy.`, `company.`) | `test_unknown_kinds_are_refused` |
| `journal-corrupt` | a complete journal line that is not the next record: not JSON, not an object, unknown `v`, `seq` not exactly next (gap, duplicate, not starting at 1), wrong types | `test_garbage_in_the_middle_...`, `test_a_duplicated_run_of_seqs_...`, `test_a_gap_in_seq_is_corrupt`, `test_lines_that_are_not_records_are_corrupt`, conformance `duplicate:` and `garbage + torn:`; for `company.journal` (`forge.company_state`, the same framing and rule): `test_a_seq_gap_is_journal_corrupt_and_replay_stops_there`, `test_a_duplicate_seq_and_a_journal_not_starting_at_1_are_corrupt`, `test_a_complete_line_that_is_not_a_record_is_corrupt_and_nothing_is_cut_even_with_a_torn_tail` |
| `snapshot-invalid` | a snapshot file that is not one JSON line this build reads (section 4.6); the journal is used instead | `test_unreadable_snapshots_are_snapshot_invalid`, `test_a_snapshot_without_its_newline_or_empty_of_content_is_snapshot_invalid`, conformance `refused: a half snapshot`, `refused: garbage` |
| `snapshot-mismatch` | a well-formed snapshot that disagrees with the journal (beyond it, off a boundary, wrong count, wrong hash, a lying projection under strict); the journal is used instead | `test_a_snapshot_with_the_wrong_hash_is_a_mismatch`, `..._of_another_history_...`, `..._beyond_the_journal_...`, `..._off_a_record_boundary_...`, `..._of_no_records_with_tasks_...`, `test_strict_mode_catches_...`, conformance `refused: a snapshot beyond the journal` |
| `workspace-locked` | another Forge holds the workspace lock (section 4.7) | conformance `lock: a second writer is refused`, and `crash_points` at 24 points across processes |
| `worker-protocol` | a worker's reply that is not valid for the contract: not JSON, not an object, a wrong `contract`, `request_id` or `task_id`, an unknown `state` or evidence `kind`, a missing or mistyped field, more than 256 evidence entries, a duplicate or escaped evidence id, a `failed` or `partial` response with no `error`, a `succeeded` one with an error. The reason is a code (`response.reason_name`) | `tests/response_test.cho`: one test per group of reasons, and the sweep of every prefix and single-byte change |
| `worker-protocol` (the other four verbs) | a reply to `capabilities`, `cancel`, `status` or `result` that is not valid for its verb (worker-contract section 3.6): a `worker`, `supports`, `level`, `task_types` or `limits_max` that is malformed, a `target` that is not the one asked about, a `state` outside the verb's closed set, a `progress` or `updated` that is not what section 3.4 says. The reasons are codes 30 to 41 (`verbs.reason_name`) beside those of `response.reason_name` | `tests/verbs_test.cho`; `tests/conformance/verbs.cho` (real child processes) |
| `worker-contract-version` | a well-formed `capabilities` reply whose `supports` does not list `forge-worker/1`; decided after every other check, so a malformed reply is never a version mismatch | `test_no_common_contract_version_is_its_own_rule_and_only_for_a_well_formed_reply`; conformance `capabilities: no common version is worker-contract-version` |
| `worker-verb-unsupported` | Forge would send a verb that the worker's declared level has not (`cancel`, `status` or `result` to a `sync` worker) or that the contract has not; **nothing is started** (Forge's own refusal, made by `forge.worker.call` before the spawn) | `test_which_verbs_a_level_has_and_what_an_unknown_verb_is`; conformance `a sync worker is sent no cancel, and nothing is started` (the worker named is not there, so a start would have been `worker-unavailable`) |
| `evidence-ref-invalid` | an evidence `ref` that is empty, absolute, longer than 512 bytes, escaped, holds a NUL or two dots in a row; a `sha256` that is not 64 lower-case hex digits; a negative `bytes`. (A hash or size that does not match the file is `forge.evidence_io`, below.) | `test_a_reference_that_leaves_the_execution_directory_is_evidence_ref_invalid`, `..._at_most_512_bytes`, `..._a_hash_is_64_lower_case_hex_digits`, `..._a_size_is_a_non_negative_integer` |
| `path-invalid` | a journal path that is not absolute, has two dots in a row anywhere (`..` as a component or inside a name), a NUL, or is longer than 512 bytes: refused before the file capability (which traps on the byte pair) is reached. *Corrected after spike S8: this row said "a `..` component", which is what Forge's hand-written check tested and the capability does not: `/a/..b` passed the check and trapped.* | conformance `path:` (two cases), `recover: a .. path`, `append: a .. path`, `recover/append/exists: a name with .. inside`; `forge company check` / `status`: a manifest path or company directory that is not ok, printed as `refusal: path-invalid`, exit 2 | `scripts/check_company.sh` (`a relative path is path-invalid`, `a relative directory is path-invalid`) |
| `scope-invalid` | a `repo.gate` task names a repository that is not in the allow-list (`forge.gate_task`, `docs/self-hosting.md` section 6). The gate runner answers `failed` with this as `error.code`; Forge's own task validation will call the same function (#17) | `test_a_repository_that_is_not_listed_is_scope_invalid`, `test_every_repository_of_the_allow_list_...`; conformance `gate_runner`: `a repository not on the list` |
| `revision-invalid` | a revision that is not exactly 40 lower-case hexadecimal digits | `test_a_revision_is_exactly_forty_lower_case_hex_digits`, `test_a_revision_that_is_not_one_is_revision_invalid`; conformance `a revision that is not 40 hex digits` |
| `task-type-invalid` | a task whose `type` is not `repo.gate`, sent to the gate runner | `test_a_task_of_another_type_is_task_type_invalid`; conformance `another task type` |
| `limits-invalid` | a `repo.gate` task whose `timeout_ms` is under 2 seconds or over one day | `test_a_timeout_outside_two_seconds_to_a_day_is_limits_invalid`; conformance `a timeout under two seconds` |
| `env-invalid` | the operator's environment of a `repo.gate` run (`grants.env`, built from the trailing `NAME=value` arguments of `forge gate`, `docs/self-hosting.md` D7) is not allowed: not an array of strings, more than 5 entries, a name that is not `PATH`, `HOME`, `CANCHO_CACHE`, `CARGO_HOME` or `RUSTUP_HOME`, a name twice, a value that is not an absolute directory (`PATH`: directories joined by `:`) of letters, digits and `._/-` with no `..` and no `.` component, or too long (512 bytes; `PATH` 1024). Checked last, after type, scope, revision, paths and limits; by Forge before anything runs (the task stays `approved`) and again by the runner | `tests/gate_env_test.cho` (8 tests: the five names, directories, a PATH list, an entry, the length limits at the edge, the array in its fixed order, the block); `test_a_bad_environment_is_env_invalid_and_comes_after_every_other_fault`; conformance `gate_runner`: nine cases from `a name that is not on the list (LD_PRELOAD)` to `a task with two faults`; `check_gate_run.sh`: `env-invalid` (four), `revision-invalid before env-invalid` |
| `path-invalid` (the runner's half) | a `grants.workspace` or `grants.execution_dir` that is not absolute, 2 to 512 bytes of letters, digits and `._/-`, with no two dots in a row and no component starting with a dot or a dash: refused before anything is put in a shell command | `test_a_path_goes_into_a_shell_command_only_if_the_shell_leaves_it_alone` (25 paths), `test_a_path_has_a_length_bound`; conformance `a shell metacharacter in a path` |
| `input-invalid` | a `project.build` task whose `input.brief` is missing, not a string, empty, over 16 KiB, or holds a NUL (`forge.build_task`, `docs/cancho-code-adapter.md`). The Cancho Code adapter answers `failed` with this as `error.code`; nothing is written | `test_a_brief_is_one_to_sixteen_kib_and_holds_no_nul`; conformance `an empty brief`, `a brief that is a number`, `a brief that is null`, `a brief with a NUL`, `a brief of 16 KiB and one byte` |
| `operator-invalid` | the operator's build configuration of a `project.build` run (`grants.build`) is missing or not allowed: a checker or guide that is not a path, a provider or model with a character the tool splices into a shell line, an agent command that is not one printable-ASCII argument, a ceiling that is not an integer in the tool's range | `test_the_operators_configuration_is_checked_after_the_task` and the three tests after it; conformance `no grants.build`, `a provider with a shell metacharacter`, `a relative checker`, `jobs above the tool's range`, `a ceiling that is not an integer` |
| `tool-unusable` | the Cancho Code adapter cannot open the operator's tools directory (`grants.tools_dir`), or `cancho-build` is not a name the `Exec` bound covers; nothing is started | conformance `a tools directory that is not there` (the second half, a name the bound would not take, cannot be reached: the name is fixed) |
| `workdir-unwritable` | the Cancho Code adapter cannot write `brief.txt` or `build.out` in the execution directory, or cannot open it to list the evidence | conformance `an execution directory that cannot be written` |
| `brief-unreadable` | `forge build` could not read the brief file the operator named (not there, a directory, unreadable) or it is over 16 KiB: exit 1, nothing is journalled (no task exists yet) | conformance `forge build`: `a brief file that is not there`, `a brief file of 16 KiB and one byte`, `a brief 'file' that is a directory` (`scripts/check_build_run.sh`); `test_an_unreadable_brief_file_has_its_own_rule_tag` |
| `task-type-invalid`, `path-invalid`, `limits-invalid` (the adapter's half) | the same three refusals for `project.build`: a type that is not `project.build`, an `execution_dir` or `tools_dir` that is not a path the adapter will use, a `timeout_ms` under 10 seconds or over one day | `test_the_task_type_is_project_build_and_nothing_else_is_held`, `test_a_path_is_refused_before_anything_is_put_in_an_argument_vector`, `test_a_timeout_outside_ten_seconds_to_a_day_is_limits_invalid`; conformance `another task type`, `a shell metacharacter in a path`, `a timeout under ten seconds` |
| `contract-path-invalid` | a `project.build` task whose `input.contract` is present and is not a file beneath the execution directory (task 10; the spec's contract arm B, `cancho-build --contract`): empty, not a plain string, an absolute path outside the execution directory or equal to it, a relative path with a `..`, a component that starts with a dot or a dash, an empty component, a trailing slash, a byte outside letters, digits and `._/-`, or more than 512 bytes once resolved (`build_task.contract_ok`, the `gate_task.path_ok` rule applied to the resolved path). Checked after the limits and before the operator's configuration, in the adapter (`failed`, nothing written) and in `forge.build_run` (journalled `contract-path-invalid`, the task `failed`). A task without `input.contract` is started without `--contract`: the argument vector is byte for byte the one it always was. Authority unchanged (a path is checked, never opened, by the adapter; the build tool reads it) | `test_a_contract_that_is_not_beneath_the_execution_directory_is_contract_path_invalid` (19 paths, incl. `../x`, `/etc/passwd`, empty), `test_a_contract_beneath_the_execution_directory_is_held`, `test_a_contract_path_has_a_length_bound`, `test_a_relative_contract_is_resolved_against_the_execution_directory`, `test_a_contract_adds_its_option_only_when_there_is_one`, `test_the_request_carries_a_contract_only_when_there_is_one` (`tests/build_task_test.cho`); `tests/conformance/cancho_code.cho` (the real adapter): `a contract beneath the execution directory reaches the argument vector`, `... given as an absolute path ...`, `a contract with a .. component`, `an empty contract`, `a contract that is a number`, `a contract that is null`, `a contract at an absolute path outside the execution directory` (each refused case ran nothing and wrote nothing), with the oracles `contract: ctr/ctr2: the vector holds --contract ...` and `a task without one has no --contract`; `tests/conformance/company_run.sh`: `contract: the build tool got --contract ...`, `contract: a step that names none is started without the option` |
| `tool-not-granted` | a `tool.run` task (task 11; worker-contract section 12) names a tool that the operator's granted list (`grants.granted_tools`, from the operator file, never the manifest or the task) does not name, or a name that is not a plain tool name (a path, `..`, empty); an empty list grants nothing. `tool_task.check`, in the tool runner (`failed`, nothing run, nothing written) and, before the step is admitted, in `forge company run` (see the run's half below) | `test_an_unlisted_tool_is_tool_not_granted` (`tests/tool_task_test.cho`); `tests/conformance/tool_run.sh` (the real worker): `a tool the operator did not grant is tool-not-granted; nothing ran` |
| `argv-malformed` | a `tool.run` task whose `argv` is not a JSON array of 0 to 64 plain strings of 1 to 4096 bytes, 64 KiB in all, with no byte below 32 and no 127 (shell text, a number, `null`, a nested array, an escape such as `\n` or `\u0000`, an empty string) | `test_an_argv_that_is_not_an_array_of_plain_strings_is_argv_malformed`, `test_an_argv_string_with_an_escape_or_a_control_byte_is_argv_malformed`, `test_an_argv_is_at_most_64_arguments_...`; `tests/conformance/tool_run.sh`: `an argv that is shell text, has a number, an escape (a newline) or an empty string is argv-malformed` |
| `path-invalid`, `limits-invalid`, `task-type-invalid`, `operator-invalid` (`tool.run`'s half) | a `tool.run` task whose execution or tools directory is not `gate_task.path_ok`, whose `input` is not a file beneath the execution directory (`..`, an absolute path elsewhere, a sibling directory, the directory itself, a hidden component: `build_task.contract_ok`'s rule), whose `timeout_ms` is outside 2 s to a day, whose type is not `tool.run`, or whose `grants.granted_tools` is not an array of at most 32 tool names | `test_an_input_that_escapes_the_execution_directory_is_path_invalid`, `test_the_paths_and_the_limits_are_checked_before_the_tool`, `test_the_task_type_is_tool_run_and_nothing_else`, `test_a_granted_list_that_is_not_a_list_of_tool_names_is_operator_invalid`; `tests/conformance/tool_run.sh`: `an input that escapes the execution directory ...`, `a task type other than tool.run ...; a deadline under 2 s ...` |
| `input-unusable` | the tool runner opened a `tool.run` task's input beneath the execution directory following no link and it is absent, a link (to a file outside, say), reached through a link to a directory, a directory or unreadable; nothing is started or written. (An input that names one of the runner's own files, `tool.out`, `report.json`, `introspect.json`, `tool.tmp`, is `path-invalid` before that: `tool_task.own_file`) | `tests/conformance/tool_run.sh`: `an input that is absent, a link (to a file outside) or a directory is input-unusable; nothing written`, `dirin: nothing was written ...`, `an input reached through a link to a directory outside ...`, `an input that names one of the runner's own files (tool.out) is path-invalid`; `test_an_input_that_names_one_of_the_runners_own_files_is_path_invalid` |
| `evidence-unwritable` (`tool.run`) | the tool runner ran the tool but could not put an evidence file beneath the execution directory: each is written as `tool.tmp` created O_EXCL and O_NOFOLLOW beneath the directory's handle and renamed over its name, so a link planted at `tool.out`, `report.json`, `introspect.json` or `tool.tmp` is replaced and never written through, and a name that cannot be replaced (a directory) is this refusal: `failed`, no evidence named, the temporary removed | `tests/conformance/tool_run.sh`: `a directory at tool.out: failed evidence-unwritable ...`, `links planted at tool.out, report.json, introspect.json and tool.tmp are replaced, never written through ...` |
| `tool-unusable` (`tool.run`) | the tool runner cannot open `grants.tools_dir`, or the granted tool cannot be started beneath it (not there, not executable) | `tests/conformance/tool_run.sh`: `a granted tool that cannot be started (not executable, not there) is tool-unusable; nothing written` |
| `tool-timeout`, `tool-output-overflow`, `tool-cancelled` (worker endings, `error.code`) | the tool did not end inside the runner's deadline (four fifths of Forge's), wrote more than 1 MiB on standard output (`tool.out` is cut at exactly 1 MiB and the report says `stdout_truncated: true`), or a `TERM`/`INT` reached the runner (state `cancelled`); in each case the tool's whole process group is killed and the evidence written. Recorded by Forge as the worker's error code; the run ends without a claim | `tests/conformance/tool_run.sh`: `noisy: ...`, `hang: failed tool-timeout ...`, `hang: the tool and its grandchild are gone ...`, `cancel: ...` (the two recorded pids checked exactly) |
| `execution-locked` | the Cancho Code adapter found the execution directory locked by another adapter (`flock` on `forge-build.lock` beneath it, `docs/cancho-code-adapter.md` section 11): a build is running there. `failed`, not retryable, no evidence; **nothing is written** to the directory. A lock the kernel drops when its holder dies is never stale | conformance (`scripts/check_cancho_code.sh`): `lock: it is failed, execution-locked, not retryable, with no evidence`, `lock: the refused start wrote nothing`, `lock: the first build ended as it would have alone`, `lost:` and `deadline:` (the lock is free after a SIGKILL of the supervisor and after a deadline); the supervisor's exit code is what the starter reads, so the refusal reaches `execute` through it; `forge build` through the adapter in `scripts/check_build_run.sh` (`two workspaces, one execution directory`); `test_every_refusal_has_its_own_rule_tag` |
| `supervisor-unavailable` | the Cancho Code adapter could not start the supervisor of a build (`docs/async-level.md` section 4): the workers directory cannot be opened, the supervisor cannot be started, or it ended or stayed silent for ten seconds without taking the execution directory. `failed`, not retryable, no evidence, nothing written | conformance (`scripts/check_cancho_code.sh`): `workers: a directory that is not there, or one without cancho_code, is supervisor-unavailable`; `test_every_refusal_has_its_own_rule_tag` |
| `build-supervisor-lost` | the adapter's answer to `result` for a run whose supervisor is gone and left no result (killed with SIGKILL): `failed`, not retryable, with the evidence that exists; the build it started may still be running (gap G4). Kept in `result.json` under the lock, so the answer is the same every time | conformance: `lost: status is finished; result is failed, build-supervisor-lost, ...` |
| `task-not-awaiting` | `forge await` or `forge cancel` about a task that is not `running` with an `execution.accepted` and no ending after it (it does not exist, it ended, it was never accepted): exit 1, nothing written | `scripts/check_build_run.sh`: `async: forge cancel about a task that has ended is refused task-not-awaiting`, `await: a task that does not exist is refused task-not-awaiting`; `tests/recover_test.cho` (`accepted_of`) |
| the adapter's outcome codes | `stuck`, `gate-failed`, `plan-failed`, `provider-error` (the tool's own endings, worker-contract 9.4: outcomes, not worker errors), and `build-usage`, `build-protocol`, `build-crashed`, `build-timeout`, `build-output-overflow`, `build-unavailable` (the adapter could not get a verdict). They are `error.code` values the worker defines, as the gate runner's are (worker-contract 10.3), listed with their states and retryability in `docs/cancho-code-adapter.md` section 4 | `test_each_pair_of_exit_code_and_verdict_of_the_tools_table_is_its_ending` and the five after it; one conformance case for each |
| `manifest-malformed` | a company manifest (`forge.company_manifest`, company-layer design 4.1) that is not JSON, is over 1 MiB, is not an object, has a missing or mistyped field, an empty `steps`, more than 256 steps, a name (step id, gate, role) that is not 1 to 64 letters, digits, `-`, `_`, `.`, a key twice or written with an escape, or a text with `\u0000` | `tests/company_manifest_test.cho`: `test_text_that_is_not_a_manifest_is_malformed`, `..._an_empty_steps_list_...`, `..._a_field_of_the_wrong_type_...`, `..._a_control_character_in_a_step_id_...`, `..._over_one_mebibyte_...`, `..._very_deep_nesting_...`, `..._the_same_key_twice_...`, `test_a_step_id_that_is_a_dot_name_is_malformed` (a step id is a directory name of the run: `.`, `..`, one starting with a dot or with two dots in a row is refused); for `forge company check` / `status` (`forge.company_cmd`): a manifest file that is not there, is unreadable or is over 1 MiB, exit 1 | `scripts/check_company.sh` (`check: a file that is not there...`, `check: an empty file`, `status: no company.json...`) |
| `manifest-unknown-field` | a key in the manifest root, `model`, `budget` or a step that the closed shape does not have | `test_a_field_the_shape_does_not_have_is_refused` |
| `step-id-duplicate` | two steps with the same `id` | `test_a_step_id_used_twice_is_refused` |
| `step-needs-unknown` | a `needs` entry that names no step | `test_a_need_that_is_no_step_is_refused` |
| `step-cycle` | a step that needs itself, or steps that need each other in a ring (the module's own check, 256 steps at most) | `test_a_step_that_needs_itself_is_a_cycle`, `..._two_steps_that_need_each_other_...`, `..._a_longer_cycle_behind_a_clean_step_...`, `..._the_most_steps_in_a_chain_...` |
| `role-unknown` | a role outside `builder, qa, analyst, reviewer, writer, product`, in `roles` or a step, or a step whose role `roles` does not list | `test_a_role_that_is_not_one_of_the_six_is_refused`, `..._a_role_pack_that_names_...`, `..._a_step_whose_role_is_not_in_the_roles_in_use_...` |
| `task-type-unsupported` | a `task_type` that is not `project.build`, `repo.gate`, `tool.run` or `none`, or is not the one the step's role offers | `test_a_task_type_the_role_does_not_offer_is_refused` |
| `check-missing` | a builder or writer step with no `check`, or an empty one | `test_a_builder_step_without_a_check_is_refused` |
| `contract-role-invalid` | a step that is neither a builder nor a writer names a `contract` (task 10): only a build is given a contract file. The `contract` of a builder or writer is optional and is a plain file name of the company directory (the `check` charset: 1 to 128 bytes of letters, digits, `-`, `_`, `.`, not starting with `.`); a `contract` that is empty, not a string, written with an escape or not such a name is `manifest-malformed`, and the key twice or a key beside it that the shape does not have stays `manifest-malformed` / `manifest-unknown-field` | `test_a_contract_on_a_role_that_builds_nothing_is_contract_role_invalid`, `test_a_builder_or_writer_step_may_name_a_contract`, `test_a_contract_is_a_plain_file_name_or_the_manifest_is_malformed`, `test_a_step_key_outside_the_shape_is_still_unknown_beside_a_contract`, `test_the_contract_of_a_step_reads_back_and_a_step_without_one_has_none`, `test_the_refusal_tags_are_the_documented_ones`; `tests/conformance/company_run.sh`: `manifest: a contract on a qa step is contract-role-invalid`, `manifest: a contract that is a path` |
| `gate-unknown` | a step's `gate` that is not in `human_gates`; and `forge company decide` about a gate the manifest does not list and that is not `retry:<step id>` of one of its steps (exit 1, nothing written) | `test_a_gate_that_is_not_a_human_gate_is_refused`; `scripts/check_company.sh` (`decide: a gate the manifest does not list is gate-unknown`, `a refused decision wrote no journal`); `tests/company_manifest_test.cho` (`has_gate`); `tests/company_state_test.cho` (`test_a_retry_gate_names_a_step_of_the_manifest`); `tests/conformance/company_run.sh` (`decide: a retry of a step the manifest does not have is gate-unknown`) |
| `budget-missing` | no `budget` object, or one of `input`, `output`, `cache_write`, `cache_read`, `max_cost` absent | `test_a_missing_budget_or_price_table_is_refused` |
| `price-table-missing` | `budget.price_table` absent or empty | `test_a_missing_budget_or_price_table_is_refused`, `test_a_price_table_that_is_not_a_plain_file_name_is_malformed` |
| `check-failed` | the audit's last `TOTAL a/b` line has `a < b` (`forge.company_check.verdict` answers 1; `rule_of(1)`). A worker's `done` never makes a step `accepted`; only a verdict of 0 (`a == b`, `b > 0`) does. `forge company run` prints it with `step:` and `score: a/b`, appends `company.step.check_failed` and exits 13. No Forge-level retry: the record HOLDS the step (`company_state.held_by_check`, `company_run.Action::Held`): every later run prints `refusal: check-failed`, `step:`, `held: ...` and the `retry:` line, exits 13 and starts no build and spends nothing, until a person records `forge company decide <dir> retry:<id> approved <reason>` after the failure (any step id makes the gate `retry:<id>`; a rejection, or an approval recorded before the failure, keeps it held); then the next run admits it once, and a new failure holds it again. A score below the total is check-failed whatever the check's exit (`company_step.check_verdict`) | `tests/company_check_test.cho`: `test_a_score_below_the_total_is_check_failed`, `test_the_last_total_line_decides_and_other_lines_are_ignored`, `test_the_rule_tags`; `tests/company_step_test.cho`: `test_a_score_below_the_total_is_check_failed_whatever_the_exit`; `tests/company_state_test.cho`: `test_a_failed_check_holds_the_step`, `test_only_an_approved_retry_recorded_after_the_failure_frees_the_step`; `tests/company_run_test.cho`: `test_a_step_whose_check_failed_is_held_not_started_again`, `test_an_approved_retry_lets_the_held_step_start_again`; `tests/conformance/company_run.sh`: `lying worker: ...` (the build claims `done`, the audit scores 1/2: exit 13, no `company.step.accepted`; a second run does NOT build again (admitted once, one build in the step's workspace); a rejected retry keeps it held; after `decide retry:lib approved` it is admitted exactly once more; `lying worker that spends`: the held run spends nothing) |
| `check-unavailable` | the audit printed no readable score: empty text, no `TOTAL` line, the last one with a sign, a missing or extra part, text after it, a number over 15 digits, `a > b` or `0/0` (`verdict` answers 2, `rule_of(2)`); never a pass | `test_no_score_a_negative_one_an_over_one_and_zero_of_zero_are_unavailable`, `test_parts_that_are_not_plain_digits_are_unavailable`, `test_text_after_the_score_on_its_line_is_unavailable_but_trailing_blanks_are_not`, `test_numbers_of_more_than_fifteen_digits_are_unavailable_never_a_trap`, `test_a_huge_text_is_read_promptly`, `test_the_rule_tags`. In `forge company run` (exit 14) also: the check ended by a signal, its deadline or its output cap (1 MiB), could not be started, or passed with a non-zero exit; or its guard (`check_guard`, section 4.4.2) is not in the operator's workers directory (then `reason: the operator's workers directory has no check_guard` is printed; `company_runner.run_check`, `company_step.guard_missing`), refused its arguments, or did not end (`company_step.check_ran`: only the guard's codes 0 and 1 are a check's exit). Tests for the guard half: `test_the_guard_says_how_the_check_ended_and_forge_reads_it_back`, `test_a_missing_guard_is_told_apart_from_every_other_ending`, and `tests/conformance/company_run.sh` `no check_guard in the workers directory`. Also when `<dir>/check.lock` stays held for five seconds (a guard of an earlier run that has not seen it gone): `reason: another check guard still holds check.lock` (`company_step.guard_busy`), recorded, so the step is held with a reason rather than rebuilt by the next run. Recorded as `company.step.check_unavailable` (reason `check-unavailable`), which holds the step as check-failed does (released by `retry:<id>`). The guard kills the check's whole process group on EVERY ending, its own exit included (`supervise.watch` with `reap_group`; the adapter's `supervise.wait` is unchanged), so nothing a check started in the background outlives it | `tests/company_step_test.cho`: `test_a_busy_check_lock_is_its_own_ending_not_a_bare_failure`, `test_a_pass_with_a_failing_exit_is_unavailable_not_a_pass`, `test_a_check_that_did_not_end_by_itself_is_unavailable_even_with_a_full_score`, `test_no_score_is_unavailable`; `tests/conformance/company_run.sh`: `audit without a score` (and its held second run), `a check that does not end` (10 s deadline, its process group gone), `a check that writes more than 1 MiB`, `a busy check lock`, `a passing check that leaves a sleep behind`, `a failing check that leaves a sleep behind` |
| `usage-invalid` | `forge company run`: a builder or writer step's `steps/<id>/ev/usage.jsonl` is not a regular file of at most 16 MiB beneath the execution directory: a symbolic link (to `/dev/zero`, say: it is never read, so no memory is exhausted), a FIFO (never opened: the run cannot block while it holds the company's lock), a directory, larger, or unreadable. Read with `company_files.read_artifact`, as an artifact. `refusal: usage-invalid`, `step:`, `reason: the build's usage.jsonl is <reason>`; recorded as `company.step.check_unavailable` (reason `usage-invalid`), which holds the step; exit 14; no check is run, nothing accepted. A file that is not there is no usage (a build that called no model). The token counts are the build tool's own log, trusted as it is (docs/company.md sections 2 and 9) | `tests/company_step_test.cho`: `test_a_held_code_names_the_refusal_it_was_recorded_with_and_its_exit`; `tests/company_state_test.cho`: `test_the_reason_of_an_unavailable_check_is_kept_as_its_held_code`; `tests/conformance/company_run.sh`: `usagelink`, `usagefifo`, `usagebig`, `usagedir` (each under a 4 GiB memory bound and a 60 s deadline), `usage-invalid: a later run names the RECORDED refusal` |
| `artifact-invalid` | `forge company run`: the artifact Forge hashes (`steps/<id>/ev/project.cho`, `report.json`, or `company.json`) is not a regular file beneath its directory: not there, a symbolic link (even to a file Forge could read), a directory, a FIFO (never opened: `dir_stat` first, so the run cannot block on it while it holds the lock), a device, over 16 MiB, unreadable, or changed while the check ran (hashed before and after). It is opened with `dir_open_read` beneath the directory (O_NOFOLLOW), the way `forge.evidence_io` opens evidence. `refusal: artifact-invalid`, `step:`, `artifact:`, `reason:`; recorded as `company.step.check_unavailable` (reason `artifact-invalid`), which holds the step; exit 14, never accepted; every later run names `artifact-invalid` again (the held code keeps the recorded reason, `company_step.held_tag`) | `tests/company_step_test.cho`: `test_every_way_an_artifact_is_refused_has_its_reason`; `tests/conformance/company_run.sh`: `no artifact`, `a symlink artifact`, `a directory where the artifact should be`, `a FIFO in the artifact's place`, `a check that changes the artifact it judges`, `artifact-invalid: a later run names the recorded refusal too` |
| `artifact-invalid` (`needs-missing`, `needs-changed`) | `forge company run`, when a step starts (task 8c, spec section 10: `needs` passes the accepted artifact's path and sha256): every step it `needs` that has a checked artifact (builder, writer, qa, reviewer; NOT a product step run by a person, whose "artifact" is the whole manifest, parsed and trusted on every run: an edit to company.json after it was accepted blocks nothing, and nothing of it is given) is read again exactly as at acceptance (`read_artifact`: beneath its directory, a regular file of at most 16 MiB, no link followed), must be that step's own artifact (`company_step.artifact_rel`), and must have the SHA-256 its `company.step.accepted` record holds (`company_state.artifact_of`). Not there is `reason: needs-missing`; any other difference (other bytes, a link or directory in its place, too large, unreadable, a recorded path that is not the step's artifact) is `reason: needs-changed`. `refusal: artifact-invalid`, `step:`, `need:`, `artifact:`, `reason:`; exit 14; ALL needs are checked before anything is written, so on a refusal the step is NOT admitted and nothing is written or removed anywhere, the execution directory included (no hold: the step is not at fault, and putting the accepted bytes back lets the next run start it). A builder or writer step that passes is given the very bytes checked, in its execution directory: `needs-<need id>-<artifact name>` each and `needs.json` (`company_step.needs_text`: `[{"step","artifact","path","sha256"}]`), each written to `needs.tmp` (O_EXCL, O_NOFOLLOW, mode 0644 less the umask: never group- or world-writable) and renamed over the name, so a link left there is replaced, never written through. Before writing, the names Forge owns there (`needs.json`, `needs-*`) left by an earlier start are removed, so a builder is given exactly its current needs (none for a builder with no needs). A qa, reviewer or product step is verified, not given copies | `tests/company_state_test.cho`: `test_an_accepted_step_exposes_the_artifact_and_digest_it_was_accepted_with`, `test_an_escaped_artifact_path_is_held_decoded`, `test_the_last_accepted_record_of_a_step_is_its_artifact`, `test_a_malformed_accepted_record_records_no_artifact`; `tests/company_step_test.cho`: `test_the_artifact_of_a_step_and_its_delivered_name_follow_its_runner`, `test_needs_text_lists_every_need_with_the_path_and_digest_the_journal_recorded`, `test_needs_text_lists_only_what_is_accepted`, `test_needs_text_escapes_what_it_copies_from_the_journal`; `tests/conformance/company_run.sh`: `needs: ...` (delivered byte for byte, needs.json with the recorded sha256, read by the worker, nothing for a step without needs), `needs changed`, `needs missing`, `needs as a link`, `needs restored`, `a product step whose need changed`, `a qa step whose need changed`, `a product need: company.json edited after it was accepted does not block`, `two needs, the second changed` (the execution directory unchanged), `stale needs`, `needs files are not group- or world-writable`, `resume with needs` (delivered again, a planted link replaced and its target untouched) |
| `artifact-invalid` (`contract-missing`, `contract-unreadable`, `contract-changed`) | `forge company run`, a builder or writer step that names a `contract` (task 10). DELIVERY: before the step is admitted (after its needs are verified and delivered) Forge reads the contract file of the company directory with `read_artifact` (a regular file of at most 16 MiB, no link followed) and writes its OWN copy as `contract.txt` in the step's execution directory (`company_files.deliver_contract`: `needs.tmp`, O_EXCL, O_NOFOLLOW, renamed over the name, so a link left there is replaced, never written through). The build is then run with the contract `contract.txt` (resolved by the adapter against the execution directory: `--contract <execution dir>/contract.txt`). Why a copy and not the company directory's path: the path stays under the execution directory, so `contract-path-invalid` means something and the adapter never sees a path the manifest author chose; the build tool reads bytes Forge read and wrote itself; and the adapter is never given the path of the file the company directory keeps (a claim about the adapter's arguments, not the build process: nothing confines what the build process opens, see the trust model, docs/company.md section 2). Not there is `reason: contract-missing`, anything else (a link, a directory, over 256 KiB (`company_step.contract_cap`: all the build tool's plan agent reads of it), over 16 MiB, unreadable) `reason: contract-unreadable`: `refusal: artifact-invalid`, `step:`, `contract:`, `reason:`; exit 14; the step is NOT admitted and nothing is recorded (no hold: the next run reads the file again). VERIFICATION: the build can write in its execution directory, so when it ends (spend recorded, claim seen, before the check) Forge reads `contract.txt` again and compares it with the company directory's file; a difference or a file gone is `refusal: artifact-invalid`, `step:`, `artifact: steps/<id>/ev/contract.txt`, `reason: contract-changed`, recorded as `company.step.check_unavailable` (the step is HELD like any unavailable check: the build is at fault), exit 14, the check not run and nothing accepted. A step that names no contract is started exactly as before (no `--contract`); a `contract.txt` an earlier manifest left in its execution directory is removed (`company_files.clear_contract`), so a build never meets a contract it was not given. Authority unchanged: the same `dir_read`, `dir_write`, `file_read`, `file_write` rows as the needs delivery | `tests/company_step_test.cho`: `test_every_way_an_artifact_is_refused_has_its_reason` (`artifact_reason(6)`, `contract_reason`, `contract_cap`); `tests/conformance/company_run.sh`: `contract: ...` (argument vector with `--contract` and the copy's path, the copy byte for byte, a step with none unchanged and its whole vector), `contract missing` (refused, not admitted, nothing written; then built once the file is there), `contract over 256 KiB` (and exactly 256 KiB given), `no contract named: a stale contract.txt is removed`, `contract as a link`, `contract: a link planted at contract.txt is replaced`, `contract changed by the build` (held, not accepted, the company directory's file untouched) |
| `budget-exhausted` | `forge company run`: the budget is spent (`company_budget.exhausted` over the tokens the journal recorded and the recorded cost, `company_state.spent_cost_micro`) and a model step (builder, writer) is held back by it, behind an open gate or not (`company_run.next_action` answers `Stop`); no new step starts, exit 12. A gated step that uses no model waits on its gate instead (`gate-open`). A running step is not killed when the ceiling is crossed and may overshoot. Two more ways the recorded spend lags what was spent, both measured by reading the code, not by a test: (1) a run killed after a build ended and before its spend record was appended has spent tokens the journal does not hold yet; the next run's budget check does not see them, so it may admit one more model step, and the delta recorded after that step includes them (the step's `usage.jsonl` keeps growing, and the delta is against what the journal recorded for the step). (2) The delta is `usage.jsonl` now less what was recorded, never negative: if the tool rewrites the file shorter, the calls in it are lost up to the old total | `tests/company_run_test.cho`: `test_an_exhausted_token_budget_stops_before_any_new_model_step`, `test_an_exhausted_cost_budget_stops_before_any_new_model_step`, `test_a_gated_model_step_under_a_spent_budget_is_stop_not_wait`, `test_stop_when_only_a_model_step_held_by_the_budget_is_left`; `tests/conformance/company_run.sh`: `budget: ...` (a build spends 1100 tokens over a ceiling of 1000; the next model step is never admitted) |
| `gate-open` | `forge company run`: nothing can start and a step waits on a human gate with no decision that would let it run (`next_action` answers `WaitGate`): `refusal: gate-open`, `gate: <name>`, `step: <id>`, exit 10. `forge company decide`, then run again. `company_state.step_blocked_by_gate` answers 1 | `tests/company_run_test.cho`: `test_a_step_with_an_open_gate_waits`, `test_a_gated_step_that_uses_no_model_waits_even_when_the_budget_is_spent`, `test_a_gated_product_step_waits_although_a_model_step_is_held_by_the_budget`; `tests/company_state_test.cho` (`test_a_step_behind_an_open_gate_is_blocked_gate_open...`); `tests/conformance/company_run.sh`: `good path: the first run stops at the open gate` |
| `gate-rejected` | `forge company run`: nothing else can start and a step's gate was last decided `rejected` (`next_action` answers `Blocked`): `refusal: gate-rejected`, `gate:`, `step:`, exit 11. Its dependents are never admitted; an independent step runs first. A later `approved` lets it run | `tests/company_run_test.cho`: `test_a_rejected_gate_blocks_and_nothing_behind_it_starts`, `test_an_independent_branch_continues_past_a_blocked_one_and_blocked_comes_last`; `tests/conformance/company_run.sh`: `rejected gate: ...` |
| `step-cycle` (the run's half) | `forge company run`: `next_action` answers `Blocked` for a step that is behind no rejected gate (`company_run.settle`'s last fallback: a need that can never be met). `parse` refuses every manifest that could reach it, so no command reaches it; printed with `step:`, exit 11, if one ever did | `tests/company_run_test.cho`: `test_settle_falls_back_to_blocking_the_first_step_left` |
| `step-failed` | `forge company run`: the step's worker ended without a claim or was refused (`forge build` / `forge gate`'s run answered a status other than 0: stuck, gate_failed, plan_failed, a deadline, a refused task); `refusal: step-failed`, `step:`, `exit: N`, exit 15. No check is run and no `accepted` is written; a build's tokens are still recorded | `tests/conformance/company_run.sh`: `stuck worker: ...` |
| `stopped` (not a refusal: a stop) | `forge company run`: a claimed `TERM` or `INT` arrived while a build ran (section 4.4.2), `execute` included (then the run is cancelled by its request id, `await_run.cancel_unaccepted`), or right after it, before the claim was closed: the build was cancelled through the adapter (its group killed), its task in the step's workspace is `cancelled`, the spend is recorded, `stopped: signal` and `step:` are printed, exit 16. The step stays admitted and not accepted; the next run admits it again. A signal at any other moment ends Forge the default way | `tests/company_step_test.cho`: `test_the_guard_says_how_the_check_ended_and_forge_reads_it_back` (exit 16); `tests/conformance/company_kill.sh`: `T: forge stopped on the signal and said so`, `T: once forge is gone nothing the company started is left`, `T: what the build spent before the signal is recorded`, `E: forge stopped on the signal`, `E: once forge is gone nothing is left` |
| `step-failed` (stale) | `forge company run`: a build an earlier run started in the step's execution directory is still running after the adapter was asked to stop it (`reap_stale`): `refusal: step-failed`, `step:`, `reason: a build an earlier run started is still running ...`, exit 15, the step not admitted. The usual path asks and settles (`reaped: <task>`) and goes on | the reaping itself: `tests/conformance/company_kill.sh` (`K: the next run asked the killed build to stop`, `K: after the next run nothing ... is left`); `tests/recover_test.cho`: `test_in_flight_names_the_tasks_whose_worker_may_still_be_running`. The refusal arm needs an adapter that ignores `cancel`: **not reached by a test** |
| `step-dir-missing` | `forge company run`: a worker step's `<company-dir>/steps/<id>/ev` is not a directory (Forge cannot make one: the language has no `mkdir`); nothing is written, exit 1 | `tests/conformance/company_run.sh`: `a step directory that is not there` |
| `operator-invalid` (the run's half) | `forge company run`: the operator file is inside the company directory by its path (`company_step.inside`: hygiene, not a boundary: the company directory, its checks and `company.journal` are trusted, the operator's, and the operator is the manifest's author, docs/company.md section 2; `reason:` printed), not there, not JSON, or outside its closed shape (`company_step.operator_ok`: a key not in it, a relative path, a timeout outside 10 s to a day, an escaped string), or lacks what a step needs (a build's `tools`, `checker`, `agent`; a qa step's `gates.<id>`); exit 1, nothing written | `tests/company_step_test.cho`: `test_an_operator_file_outside_the_shape_is_refused`, `test_a_good_operator_file_is_taken_and_read_back`, `test_an_operator_file_inside_the_company_directory_is_seen_by_its_text`; `tests/conformance/company_run.sh`: `an operator file outside its shape`, `an operator file that is not there`, `an operator file inside the company directory` |
| `price-table-missing` (the run's half) | `forge company run`: the price table the manifest names is not in the company directory, cannot be read, does not parse, or does not price the manifest's model (`company_budget.parse_prices_for`); exit 1, nothing written | `tests/conformance/company_run.sh`: `no price table`, `a price table without the model` |
| `task-type-unsupported`, `check-missing` (the run's half) | `forge company run` reaching a step no adapter runs (no role maps to `company_step.Runner::Unsupported` since task 11, when the analyst's `tool.run` got the tool runner: the arm is kept, and not reached by a test), a worker step with no `check` (a qa step may parse without one; its gate's verdict is a claim), or a product step with neither a gate nor a check: exit 1, the step is not admitted | `tests/conformance/company_run.sh`: `a qa step with no check`, `a product step with neither a gate nor a check` |
| `tool-not-granted`, `argv-malformed`, `path-invalid`, `operator-invalid` (the run's half, analyst steps) | `forge company run`, an analyst step (task 11): what it runs is the operator file's, never the manifest's (`analyst_tools`, `granted_tools`, `analysts.<id>` = tool, argv array, input beneath `steps/<id>/ev`). Before the step is admitted Forge runs `tool_task.check` on them (the very check the tool runner runs again): a tool the granted list does not name is `tool-not-granted`, an argv that is not an array of plain strings `argv-malformed`, an input that escapes the step's execution directory `path-invalid`, no `analyst_tools` or no entry for the step `operator-invalid`; `refusal: <tag>`, `step: <id>`, exit 1, nothing admitted, nothing run, no workspace journal. A refusal the worker makes after that (`input-unusable`, `tool-unusable`, `evidence-unwritable`), the deadline, the cap or a cancel is the run ending without a claim: `step-failed`, exit 15; the runner's own `error.code` (one it has, `tool_task.known_code`) is printed `worker-error: <code>` and recorded as a `refusal` of the tool task in the step's workspace journal (`tool_call`, fix round 1) | `tests/company_step_test.cho`: `test_an_operator_file_names_each_analyst_steps_tool_argv_and_input`, `test_an_analyst_entry_outside_its_shape_is_refused`; `tests/conformance/company_run.sh`: `analyst: a tool the operator did not grant is tool-not-granted ...`, `analyst: an argv with a number ...`, `analyst: an input that escapes ...`, `analyst: no entry for the step ...`, `analyst: an input that is not there is refused by the worker after admission: the operator is told its code ...`, `analyst: the operator's tool_timeout_ms is honoured ...`; `test_a_worker_error_code_is_known_only_when_it_is_one_of_the_runners` |
| `journal-corrupt`, `event-malformed`, `workspace-locked`, `path-invalid` (the run's half) | `forge company run` refuses a journal the replay refuses as `status` does (`refusal:` and `line:`, exit 1, nothing written), a company directory another writer holds (`<dir>/lock`, the lock `decide` takes), a path that is not absolute (exit 2) | `tests/conformance/company_run.sh`: `a corrupt journal`, `a company directory locked by another writer`, `bad usage` |

The rows from `manifest-malformed` down to here are the company layer's (design: `docs/superpowers/specs/2026-10-27-forge-company-layer-design.md`).
[`docs/company.md`](company.md) section 12 lists the same tags, each with the exit code of the verb that prints it and one test that reaches
it, and says what each verb prints around the tag; it does not repeat the prose of these rows. `scripts/gate.sh` checks that every tag the
company code can print appears in both documents, so a new company tag cannot ship without a row in each. Two things the company layer
prints are not refusals and have no row of their own: `stopped: signal` (exit 16, the `stopped` row) and `worker-error: <code>`, the tool
runner's own error code (the `input-unusable`, `tool-unusable`, `evidence-unwritable` and `tool-timeout` rows).

Designed, not implemented (no test reaches them yet; they are not claims):

| rule | meaning |
|---|---|
| `policy-denied` | policy decision `Deny`, with the policy version |
| `policy-missing` | no policy loaded or it did not parse (fail closed) |
| `approval-missing` | a protected action without a granted approval |
| `budget-exhausted` (the reservation form) | a reservation would exceed a limit (the task layer's; the company layer's `budget-exhausted` above is implemented) |
| `worker-timeout`, `worker-output-overflow`, `worker-crashed`, `worker-error`, `worker-unavailable` | observed ending of a worker process (section 5 of the worker contract; the Cancho Code binding adds how an exit code is read, section 9.4) |
| `execution-lost`, `execution-unstarted` | `forge.recover`: Forge found a task `running` with no ending and settled it (section 4.4.1). `execution-lost`: the intent (`execution.started`) was written and nothing after it (or, for an `async` worker, its `status` answered `unknown` for a run it had accepted: `forge.await_run`, `dispatch.Ending::Lost`, consequence `blocked`), so the worker may have run; Forge writes `execution.lost`, does not re-dispatch, and the task is `ready`. `execution-unstarted`: the task was `running` and the intent was never written, so no worker was started; the task is `ready`. When the budget of starts is used up the tag is `retry-exhausted` (below) and the task is `blocked`. Reached by `tests/recover_test.cho` and `scripts/check_recover.sh` |
| `retry-exhausted`, `retry-write-refused` | `forge.retry`: a worker said its failure is retryable (`error.retryable: true`) and no other attempt is made: the three allowed are used (`retry-exhausted`), or the task writes (`retry-write-refused`). The task is `blocked`. `retry-exhausted` is also what `forge recover` writes when a worker was started the whole budget and the last run has no ending. Reached by `tests/retry_test.cho`, `scripts/check_gate_run.sh` and, for the recovery, `scripts/check_recover.sh` |
| `evidence-ref-invalid` (the file half) | `forge.evidence_io` opens each `ref` beneath the execution directory following no link and recomputes size and SHA-256: reasons `evidence-missing`, `evidence-unreadable` (a link, a directory), `evidence-too-large` (past 64 MiB), `evidence-bytes-mismatch`, `evidence-sha-mismatch` (`docs/worker-contract.md` 4.1; `tests/conformance/evidence_files.cho`, 24 cases; spike S10) |
| `journal-sync-failed` | `fsync` failed; contents unknown; Forge stops (the file layer returns the errno today; the stop is M2) |

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
| G1 | **Open: [cancho #534](https://github.com/alpibrusl/cancho/issues/534); partly answered 2026-10-19 by cancho #546 (merged).** `narrow` still takes only literals; a run-time bound is a `Dir` (`Fs`) and `exec_spawn_under(&Exec(""), &Dir, ...)` (`Exec`, row `exec_under`, which names no path) | Workers and workspace directories fixed at build, unless Forge adopts the new calls (tried in S9 for workers: the directory is `argv[1]`, the report says `exec_under` and not the directory; not yet in a worker adapter) | A bound carried as a value (a single file, a prefix the type can show) is not built: `docs/processes.md` section 9 |
| G2 | **Answered 2026-10-19: [cancho #535](https://github.com/alpibrusl/cancho/issues/535) closed by cancho #540.** Out-of-bound spawn still traps by design, but `exec_covers` and `fs_covers` (edition 9, no row) ask first by the rule the operation traps on | Forge's policy uses the predicate instead of its own copy of the rule: **adopted for the journal path (S8)**, which exposed a defect in the copy; for worker names, S9 (the guard is `len > 0`, not rooted, `exec_covers`) | None |
| G3 | **Built: [cancho #533](https://github.com/alpibrusl/cancho/issues/533), merged** (`child_kill_group`, rev `8411e9a`; S7 re-run, no `/bin/kill`). Was: kill reaches only the pid | Nothing now; workers that start subprocesses are started detached | None. Residual: a descendant that leaves the group; the orphan after a Forge crash (G4) |
| G4 | **Open, no issue; `docs/processes.md` section 9** (narrowed by #533 for a live supervisor only; worked around for `forge company run`'s builds and checks by task 9, section 4.4.2: the next run cancels a stale build through the adapter, and a guard kills a check whose Forge is gone. Not for a qa step's gate). No kill-by-pid capability; parent death does not kill children | Restart cannot cleanly stop an orphaned worker | `docs/processes.md` section 9: kill-by-pid with its own capability; `PR_SET_PDEATHSIG` on Linux only |
| G5 | `fsync` durability on macOS is weaker | Durability promise differs per platform | `F_FULLFSYNC` (`docs/file-writes.md` section 6) |
| G6 | **Fixed: [cancho #536](https://github.com/alpibrusl/cancho/issues/536) (closed; in `8411e9a`).** Header of `docs/processes.md` says slices 3 and 4 are "designed, not built"; its own slice table and `std/process.cho` say built | Misleading; S1-S2, S6, S7 use `std.process.capture` successfully | Correct the header in the cancho repository |
| G10 | **Built: [cancho #562](https://github.com/alpibrusl/cancho/issues/562), `exec_spawn_detached_under` (cancho #588, compiler rev `972099e`); spike S12 measured it: the grandchild is gone after the deadline, the report names `exec_under` and `exec_detached` and no path.** The text below is the gap as it stood before, kept for the record. `exec_spawn_under` (the worker is a name beneath a run-time `Dir`, #546) does not start the worker as a process-group leader, and `exec_spawn_detached` has no `Dir` form, so `capture`'s deadline kills the worker and leaks what it started *(S7 measured the plain start; **S11 measured the under form: the leak is real**, and a worker that starts what it runs detached and enforces a deadline of its own, shorter than Forge's, is the only clean path today; Forge's kill is a backstop that leaks)* | `src/worker.cho` uses `exec_spawn_under`. The mock worker starts nothing, so its contract tests are unaffected; **the Cancho Code adapter (a worker that runs a compiler) does not ship until #562** | `exec_spawn_detached_under` |
| G9 | **Open: [cancho #534](https://github.com/alpibrusl/cancho/issues/534)** (with G1; cancho #546 documents `Dir` as the answer for a directory bound, not tried against the journal). A library function over `Fs` cannot be generic in the prefix: `Fs("/x")` is not accepted where a function declares `Fs("")` *(measured, M1; see `spike/RESULTS.md`, "M1 findings")* | `src/journal_io.cho` is written against `Fs("")` and guards the path itself (`path-invalid`); a binary that links it reports `fs_read("")`, `fs_write("")`. The production `forge` binary links it in M2, and that widening is a visible diff in `cancho authority` and says so in its commit. `path_ok` now asks `fs_covers`, so the `..`/length rule is the compiler's and not a copy (S8) | The same run-time-chosen-bound question as G1, for `Fs`; or a way to declare a function generic in a capability's prefix |
