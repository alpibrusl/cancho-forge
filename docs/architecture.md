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

### 4.9 The operator CLI *(built in M1)*

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

**Authority**, checked into `docs/authority.txt` and compared by the gate:

```
performs
    args
    err_write
    file_read
    fs_read("")
    heap
    io_write
never touches
    the network
    signals
    other programs
    foreign code
```

This is the first widening of the `forge` binary beyond `heap` and `io_write`
(M0's `main` released everything): it can **read** any file, because a library
cannot be generic in the `Fs` prefix (G9, cancho #534) and the file layer holds
`Fs("")`. It performs no `fs_write` and no `exec`; the crash tests, which write,
are separate programs that are not shipped.

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
| `event-malformed` | a task event with no or non-string `task` / `actor`, an `actor` that is not forge / worker / human, a `basis` that is not a string, or a task id outside the closed set | `test_malformed_task_events_are_refused`, `test_submit_with_a_bad_id_is_recorded_against_no_task` |
| `event-unknown` | a kind that is neither a `task.*` kind nor in a namespace M1 records (`refusal`, `execution.`, `approval.`, `budget.`, `policy.`, `company.`) | `test_unknown_kinds_are_refused` |
| `journal-corrupt` | a complete journal line that is not the next record: not JSON, not an object, unknown `v`, `seq` not exactly next (gap, duplicate, not starting at 1), wrong types | `test_garbage_in_the_middle_...`, `test_a_duplicated_run_of_seqs_...`, `test_a_gap_in_seq_is_corrupt`, `test_lines_that_are_not_records_are_corrupt`, conformance `duplicate:` and `garbage + torn:` |
| `snapshot-invalid` | a snapshot file that is not one JSON line this build reads (section 4.6); the journal is used instead | `test_unreadable_snapshots_are_snapshot_invalid`, `test_a_snapshot_without_its_newline_or_empty_of_content_is_snapshot_invalid`, conformance `refused: a half snapshot`, `refused: garbage` |
| `snapshot-mismatch` | a well-formed snapshot that disagrees with the journal (beyond it, off a boundary, wrong count, wrong hash, a lying projection under strict); the journal is used instead | `test_a_snapshot_with_the_wrong_hash_is_a_mismatch`, `..._of_another_history_...`, `..._beyond_the_journal_...`, `..._off_a_record_boundary_...`, `..._of_no_records_with_tasks_...`, `test_strict_mode_catches_...`, conformance `refused: a snapshot beyond the journal` |
| `workspace-locked` | another Forge holds the workspace lock (section 4.7) | conformance `lock: a second writer is refused`, and `crash_points` at 24 points across processes |
| `worker-protocol` | a worker's reply that is not valid for the contract: not JSON, not an object, a wrong `contract`, `request_id` or `task_id`, an unknown `state` or evidence `kind`, a missing or mistyped field, more than 256 evidence entries, a duplicate or escaped evidence id, a `failed` or `partial` response with no `error`, a `succeeded` one with an error. The reason is a code (`response.reason_name`) | `tests/response_test.cho`: one test per group of reasons, and the sweep of every prefix and single-byte change |
| `evidence-ref-invalid` | an evidence `ref` that is empty, absolute, longer than 512 bytes, escaped, holds a NUL or two dots in a row; a `sha256` that is not 64 lower-case hex digits; a negative `bytes`. (A hash or size that does not match the file is `forge.evidence_io`, below.) | `test_a_reference_that_leaves_the_execution_directory_is_evidence_ref_invalid`, `..._at_most_512_bytes`, `..._a_hash_is_64_lower_case_hex_digits`, `..._a_size_is_a_non_negative_integer` |
| `path-invalid` | a journal path that is not absolute, has two dots in a row anywhere (`..` as a component or inside a name), a NUL, or is longer than 512 bytes: refused before the file capability (which traps on the byte pair) is reached. *Corrected after spike S8: this row said "a `..` component", which is what Forge's hand-written check tested and the capability does not: `/a/..b` passed the check and trapped.* | conformance `path:` (two cases), `recover: a .. path`, `append: a .. path`, `recover/append/exists: a name with .. inside` |
| `scope-invalid` | a `repo.gate` task names a repository that is not in the allow-list (`forge.gate_task`, `docs/self-hosting.md` section 6). The gate runner answers `failed` with this as `error.code`; Forge's own task validation will call the same function (#17) | `test_a_repository_that_is_not_listed_is_scope_invalid`, `test_every_repository_of_the_allow_list_...`; conformance `gate_runner`: `a repository not on the list` |
| `revision-invalid` | a revision that is not exactly 40 lower-case hexadecimal digits | `test_a_revision_is_exactly_forty_lower_case_hex_digits`, `test_a_revision_that_is_not_one_is_revision_invalid`; conformance `a revision that is not 40 hex digits` |
| `task-type-invalid` | a task whose `type` is not `repo.gate`, sent to the gate runner | `test_a_task_of_another_type_is_task_type_invalid`; conformance `another task type` |
| `limits-invalid` | a `repo.gate` task whose `timeout_ms` is under 2 seconds or over one day | `test_a_timeout_outside_two_seconds_to_a_day_is_limits_invalid`; conformance `a timeout under two seconds` |
| `path-invalid` (the runner's half) | a `grants.workspace` or `grants.execution_dir` that is not absolute, 2 to 512 bytes of letters, digits and `._/-`, with no two dots in a row and no component starting with a dot or a dash: refused before anything is put in a shell command | `test_a_path_goes_into_a_shell_command_only_if_the_shell_leaves_it_alone` (25 paths), `test_a_path_has_a_length_bound`; conformance `a shell metacharacter in a path` |

Designed, not implemented (no test reaches them yet; they are not claims):

| rule | meaning |
|---|---|
| `policy-denied` | policy decision `Deny`, with the policy version |
| `policy-missing` | no policy loaded or it did not parse (fail closed) |
| `approval-missing` | a protected action without a granted approval |
| `budget-exhausted` | a reservation would exceed a limit |
| `worker-contract-version` | no common contract version |
| `worker-timeout`, `worker-output-overflow`, `worker-crashed`, `worker-error`, `worker-unavailable` | observed ending of a worker process (section 5 of the worker contract; the Cancho Code binding adds how an exit code is read, section 9.4) |
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
| G4 | **Open, no issue; `docs/processes.md` section 9** (narrowed by #533 for a live supervisor only). No kill-by-pid capability; parent death does not kill children | Restart cannot cleanly stop an orphaned worker | `docs/processes.md` section 9: kill-by-pid with its own capability; `PR_SET_PDEATHSIG` on Linux only |
| G5 | `fsync` durability on macOS is weaker | Durability promise differs per platform | `F_FULLFSYNC` (`docs/file-writes.md` section 6) |
| G6 | **Fixed: [cancho #536](https://github.com/alpibrusl/cancho/issues/536) (closed; in `8411e9a`).** Header of `docs/processes.md` says slices 3 and 4 are "designed, not built"; its own slice table and `std/process.cho` say built | Misleading; S1-S2, S6, S7 use `std.process.capture` successfully | Correct the header in the cancho repository |
| G10 | **Open: [cancho #562](https://github.com/alpibrusl/cancho/issues/562).** `exec_spawn_under` (the worker is a name beneath a run-time `Dir`, #546) does not start the worker as a process-group leader, and `exec_spawn_detached` has no `Dir` form, so `capture`'s deadline kills the worker and leaks what it started *(S7 measured the plain start; **S11 measured the under form: the leak is real**, and a worker that starts what it runs detached and enforces a deadline of its own, shorter than Forge's, is the only clean path today; Forge's kill is a backstop that leaks)* | `src/worker.cho` uses `exec_spawn_under`. The mock worker starts nothing, so its contract tests are unaffected; **the Cancho Code adapter (a worker that runs a compiler) does not ship until #562** | `exec_spawn_detached_under` |
| G9 | **Open: [cancho #534](https://github.com/alpibrusl/cancho/issues/534)** (with G1; cancho #546 documents `Dir` as the answer for a directory bound, not tried against the journal). A library function over `Fs` cannot be generic in the prefix: `Fs("/x")` is not accepted where a function declares `Fs("")` *(measured, M1; see `spike/RESULTS.md`, "M1 findings")* | `src/journal_io.cho` is written against `Fs("")` and guards the path itself (`path-invalid`); a binary that links it reports `fs_read("")`, `fs_write("")`. The production `forge` binary links it in M2, and that widening is a visible diff in `cancho authority` and says so in its commit. `path_ok` now asks `fs_covers`, so the `..`/length rule is the compiler's and not a copy (S8) | The same run-time-chosen-bound question as G1, for `Fs`; or a way to declare a function generic in a capability's prefix |
