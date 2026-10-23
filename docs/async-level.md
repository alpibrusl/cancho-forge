# The `async` level: an adapter that answers `accepted` and is polled (issue #33)

> **Status: designed; the primitives are measured (spike S14), the code is not written.** Everything marked *measured* was
> run on compiler `972099e`, Linux x86-64, against the stand-in tool. Nothing here ran the real `cancho-build`. A claim that
> the building shows false is corrected here, in place, with the commit that corrected it.

The Cancho Code adapter ([`cancho-code-adapter.md`](cancho-code-adapter.md)) is `sync` today: one Forge process waits, up to
a day, on one build. [`worker-contract.md`](worker-contract.md) sections 1.2, 3.3 to 3.6 and 9 describe the `async` flow and
say it is designed and not built. This document decides what `accepted`, `status`, `result` and `cancel` mean for this worker,
for the journal and for recovery, and answers the two questions the issue asks: **how a later process stops a build an earlier
one started**, and **what stops a reused pid from being killed**.

## 1. The two facts the design stands on

1. **cancho cannot signal a process by number.** `child_kill_group` needs the `Child` handle of whoever started the process
   (cancho `docs/processes.md` 4.11, 4.12; the kill-by-pid builtin is an open row of section 9 of that document, on purpose:
   it would reach every process of the user). A worker is stateless per call (worker-contract 1.1), so the process that
   started a build is gone by the time `cancel` is called, **unless it stays**. `/bin/kill` through a narrowed `Exec` would
   work, and would put `exec("/bin/kill")` into the authority report of a worker whose report is reviewed.
2. **A lock the kernel drops when its holder dies answers "is it alive?"** without a pid. Issue #35 gave every run an `flock`
   on `forge-build.lock` in its execution directory; a process that can take the lock knows nobody holds it.

## 2. Decision: the process that starts the build stays, as a supervisor

`execute` does not run the build. It starts a second copy of the adapter, in a mode of its own, **detached** (its own session
and group, so that a kill of the adapter's or Forge's group does not reach it) and **released** (nobody owes it a wait), hands
it the request on its standard input, waits until it says it holds the directory, and answers `accepted`. The supervisor is
the process that today runs `run_locked`: it takes the lock, starts the build as a group leader, holds the `Child`, and ends
when the build does. A later `cancel` reaches it **through a file**, not a signal:

```
execute   --> checks the task (as today) --> starts SUPERVISOR (detached, released, request on stdin)
                                          --> waits for run.json with its own token, or for the supervisor to end
                                          --> answers accepted         (or the supervisor's refusal)
SUPERVISOR --> takes forge-build.lock (a held lock: exit, no write) --> removes the previous run's files
           --> writes run.json {request_id, task_id, token}          --> runs the build, as today, in slices of 100 ms
           --> every slice: cancel.req names this request?  yes: kills the build's group (child_kill_group)
           --> writes result.json (the final reply of `execute`, atomically) --> lets the lock go --> ends
status    --> reads run.json and result.json, and tries the lock: held = running, free and no result = lost
result    --> returns result.json byte for byte; if the supervisor is gone, settles it as lost (below)
cancel    --> writes cancel.req, waits for result.json, answers cancelled
```

**Why a supervisor and not the alternatives:**

| alternative | why not |
|---|---|
| `kill` through `exec("/bin/kill")` by a pid in a file | widens the reviewed authority; and a pid in a file is the pid-reuse problem itself |
| a signal to the supervisor (`Signals`) | the adapter releases `Signals` today; a signal capability is more authority than a file the supervisor already watches |
| no supervisor: the build is started by `execute` and released | nobody holds the `Child`: `status` and `cancel` cannot reach it; the deadline of four fifths of Forge's is not enforced; this is `exec_spawn_detached` with nothing after it (S7) |
| the supervisor is `cancho-build` itself | not ours to change (audit 2) |

**Measured (S14, `spike/s14_supervise.cho` driven by `spike/s14_supervise.sh`):**

| question | measured |
|---|---|
| does the supervisor outlive the process that started it? | yes: after the starter exited, 1 supervisor and 1 build were alive |
| how long does `execute` take to answer `accepted`? | 26 ms (process start, lock, `run`, the start of the build) |
| is a second start on the same directory refused by the supervisor, with no write? | yes, the supervisor exits 3 (`EWOULDBLOCK`) in 5 to 16 ms (5 runs); the starter reads that exit as the refusal |
| can a new process tell the build is running? | yes: a probe from a new process gets `EWOULDBLOCK` while the supervisor lives |
| does a cancel stop the whole build? | yes: `cancel` file written, the supervisor killed the group and wrote its result in 29 to 88 ms (5 runs); the `sleep 76` grandchild in the build's group was gone |
| does a SIGKILL of the supervisor free the lock? | yes: a probe afterwards got the lock at once |
| and the build it started? | **it survives, an orphan** (1 `sleep 76` alive): the same gap as G4 / S13, and nothing in this design stops it (section 7) |
| does a build that ends by itself end the supervisor? | yes: result `exited`, no supervisor left |
| can Forge wait without a sleep? | yes: `poller_wait` on a poller with nothing registered returned after 256 ms for 250 (process start included) |

## 3. The pid-reuse question

**Nothing in this design addresses a process by number.** The supervisor holds the `Child` of the build (a pid cannot be
reused while its `Child` exists, cancho 4.7) and is the only party that signals it. Everyone else talks to the supervisor
through the execution directory, and tells **which run** a file is about by a *request id*, not a pid:

* `run.json` holds `request_id`, `task_id` and a start `token` (the clock in milliseconds at `execute`; `execute` chose it
  and passes it to the supervisor, so a `run.json` left by an earlier run, even of the same request id, cannot be taken for
  this start);
* `cancel.req` holds the request id it is meant for; a supervisor acts on it only if it is its own; a stale file for an older
  run is ignored and removed by the next run;
* liveness is the lock, which the kernel drops with the process. A pid that was reused is not a lock holder.

Forge journals the request id and the execution directory (`execution.accepted`, section 5), not a pid. The issue's "pid and
start token written into the execution directory and journalled" is replaced by the request id and the token, for the reason
above: a number would have to be checked against a start time, and nothing here needs one.

## 4. The verbs

The contract's request for `status`, `result` and `cancel` names a `target` and nothing else (worker-contract 3.3 to 3.5,
`verbs.build_targeted`), and a stateless worker needs a place to look: Forge adds **`grants.execution_dir`** to the three
(the request is built from the journal's record, section 5). `execute` gains **`grants.workers_dir`**, the directory holding
`cancho_code`, so that the adapter can start its supervisor by name beneath it (`exec_spawn_detached_under`, the form
`cancho-build` is already started with). Both are paths the adapter checks as it checks `execution_dir`.

| verb | answers | when |
|---|---|---|
| `capabilities` | `level: async` | |
| `execute` | `accepted`, no evidence, no error | the task is valid, the tools directory opens, the supervisor started and wrote `run.json` with this token |
| | `failed` and a tag, no evidence, nothing written | `task-type-invalid`, `input-invalid`, `path-invalid`, `limits-invalid`, `operator-invalid`, `tool-unusable` (as today); `execution-locked` (the supervisor exited 3); `workdir-unwritable` (exit 5); `supervisor-unavailable` (the workers directory cannot be opened, the supervisor cannot be started, or it ended or stayed silent without saying) |
| `status` | `unknown` | no `run.json`, or its `request_id` is not the `target` |
| | `finished` | `result.json` exists for the target, or the lock is free (the supervisor is gone) |
| | `running`, `progress.step` = the build's `stage` | the lock is held; `stage` is read from `build.json` when it is a plain word of at most 32 bytes, else absent (advisory, never a verdict) |
| `result` | the final reply of `execute` | `result.json` exists for the target: **byte for byte, every time** |
| | `{"state":"not_ready"}` | the lock is held, or there is no run for the target |
| | `failed`, `build-supervisor-lost` | the lock is free and there is no `result.json`: written to `result.json` (under the lock, atomically) and then returned, so it is the same answer next time |
| `cancel` | `cancelled` | `cancel.req` written for a live run and `result.json` appeared saying `cancelled` |
| | `too_late` | `result.json` exists and does not say `cancelled` |
| | `not_running` | no run for the target, or its supervisor is gone |
| | (no answer, exit 4) | the supervisor did not write its result in 10 seconds: a wedged supervisor, a defect, and Forge classifies it `worker-error` |

`result.json` is the whole final reply (`state`, `summary`, `evidence`, `error`), written once, to a temporary name and
renamed; a reader sees all of it or none. The evidence it carries is the supervisor's, and Forge recomputes it against the
files as it does for `sync` (`forge.worker.execute`'s `recheck`, section 6).

**The table of endings (worker-contract 9.4) is unchanged**; it is now the table of `result`, and every row is a case of the
conformance program, polled instead of waited for.

**The deadline.** The supervisor's is `build_task.runner_deadline_ms(timeout_ms)`, four fifths of the request's `timeout_ms`,
from the start of the build, as the `sync` adapter's was; its group kill ends the build before Forge's own deadline, which is
the total of section 6.

**`cancel` semantics.** The supervisor kills the build's whole group with `KILL` (the same call `capture`'s deadline makes),
reaps it, writes `result.json` with `state: cancelled` (and `error` null, the evidence that exists), and ends. The directory
is **kept**, so that **the same work resumes**: a new request on the directory (a new task with `forge build`) takes the lock
the supervisor let go and the tool continues from `plan.json` and `state.txt` (the audit's claim; the stand-in does not
exercise it).

## 5. The journal

One new record, written by Forge, like `execution.started`: **`execution.accepted`**, `{"kind":"execution.accepted",
"task":..., "actor":"forge", "request":"<request id>", "dir":"<execution directory>"}`. It is written after the worker's
`accepted` is judged valid and before the first poll. Replay passes over it (the `execution.` namespace carries no state).
The ending is whatever the sync flow wrote: `execution.finished` (a `succeeded` result, with the claimed verdict), a
refusal record with the ending's rule tag, and the move; or `execution.cancelled` and the move to `cancelled`.

What it adds to the phases `forge recover` reads (`src/recover.cho`):

| phase | the journal says | before | now |
|---|---|---|---|
| 2 | `execution.started`, nothing after | `execution.lost`, then `execution-lost` / `retry-exhausted` | unchanged: the worker may have been started and not have answered |
| **5** | `execution.accepted`, nothing after | (could not happen) | **the worker took the job and may still be running**: it is not lost |

A task in phase 5 is never written `lost` by the journal alone. `forge recover <dir>` reports it as awaiting and writes
nothing for it. `forge recover <dir> <workers>` asks the worker (the same code `forge await` uses, section 6): `running`
leaves it running; `finished` reads the result and writes the ending the run would have written; `unknown`, or a result
that is `build-supervisor-lost`, is the run's ending and goes through the same rows as any other (`worker-crashed`-class
for a lost supervisor, `execution-lost` for an `unknown` the worker cannot account for).

## 6. Forge's side

* **`forge.worker.execute`** already judges an `accepted` reply when told the worker is `async` (`dispatch.classify`,
  `response.validate`); it maps to `Consequence::Poll`, `forge.flow` maps that to `running`. What is missing is the poll.
* **`forge.await_run`** (new, pure of the journal): given the worker, the request id, the execution directory and a
  deadline, loops `status` every second (a nap on a poller, measured above); on `running`, nap; on `finished`, `result`,
  classified as an `execute` reply and its evidence recomputed; on `unknown`, the ending `Unavailable`-class (the worker lost
  the run); when Forge's deadline passes, a `cancel`, a `result`, and the ending `Timeout` (`worker-timeout`). A `status` or
  `result` call that does not answer (the process ended unclean, over the cap, past its deadline) ends the wait with that
  ending's tag, as any call does: the run is not assumed to have ended, and `forge await` can resume the wait.
* **`forge build`** calls it after `execute` answers `accepted`, writes `execution.accepted` first, and from the ending on is
  unchanged. It **holds the workspace lock while it polls** (it is the single writer of the journal); a second Forge on the
  workspace is refused `workspace-locked`.
* **`forge await <dir> <workers> <task-id> [timeout-ms]`** (new): continues a task in phase 5: reads `request` and `dir` from
  its `execution.accepted`, takes the workspace lock, and runs the same wait and the same ending. This is what a restarted
  Forge runs after a crash in the middle of a build; `forge recover <dir> <workers>` runs it for each task in phase 5.
* **`forge cancel <dir> <workers> <task-id>`** (new): reads the journal **without the lock** (as `status` and `history` do),
  sends `cancel` to the worker for the recorded request, and prints the worker's answer. It writes **nothing**: the Forge that
  is polling (or the next `forge await`) sees the result say `cancelled` and writes `execution.cancelled` and the move to
  `cancelled`. This is what lets an operator cancel while `forge build` holds the lock.
* **The levels.** Forge learns a worker's level from `capabilities`, which it does not yet call at registration
  (worker-contract 3.6); `forge build` states it in code: the Cancho Code adapter is `async` and `forge.worker.call`'s check of
  verb against level (`verbs.verb_allowed`) is passed with `Level::Async`. A sync worker would still be refused `cancel`,
  `status` and `result` with `worker-verb-unsupported`. Registration is M4 and stays so.

## 7. What is not covered, and said so

* **An orphan build.** The supervisor killed with SIGKILL (the OOM killer, a power cut of the process, an operator) leaves the
  build running in its group with nobody holding its `Child` (S14: alive). The lock is free, `status` says `finished`,
  `result` says `build-supervisor-lost`, and **a new request on the directory would be accepted beside a build that still
  writes it**. This is gap G4 (children outlive a dead parent; `docs/processes.md` section 9 lists kill-by-pid and
  `PR_SET_PDEATHSIG` as the open rows) and not a new one: with the `sync` adapter the same SIGKILL left the same orphan. What
  changes is that the lost state is **named** (`build-supervisor-lost`) instead of being a silent hang of the Forge that
  waited. The operator stops the orphan; Forge cannot.
* **A probe takes the lock for an instant.** `status` and `result` find out that nobody holds the lock by taking it, so a
  supervisor that starts in that instant would see it held. The supervisor tries three times, 100 ms apart, before it
  answers `execution-locked`; the second start of a busy directory is still refused in about 300 ms (S14 measured the
  one-try refusal at 5 to 16 ms).
* **A build that deletes the lock or `result.json` of its own directory.** The build is the build's authority (adapter
  section 5), not a party to the exclusion; the same line as adapter 11.6. Argued, not measured.
* **Latency of the poll.** One second between `status` calls, each a process start. Not tuned.
* **The real `cancho-build`**, a real model, macOS, a network filesystem: none run. Whether the real tool shuts down cleanly
  and leaves a state it can resume from after a group `KILL` is the audit's claim (audit 4) and the stand-in does not test it.

## 8. New rules, and what reaches them

Each gets its row in `architecture.md` section 7 and a case in the conformance program in the build.

| tag | where | meaning |
|---|---|---|
| `supervisor-unavailable` | adapter (`execute`) | the workers directory cannot be opened, the supervisor cannot be started, or it ended or stayed silent for 10 seconds without a lock verdict; nothing was written |
| `build-supervisor-lost` | adapter (`result`) | the run's supervisor is gone and left no result; `failed`, not retryable |
| `task-not-awaiting` | `forge await`, `forge cancel` | the task is not `running` with an `execution.accepted` and no ending after it |
| (existing) `execution-locked` | adapter | now also reached through the supervisor's exit code |
| (existing) `worker-timeout`, `worker-crashed`, `worker-error`, `worker-protocol`, `evidence-ref-invalid`, `execution-lost`, `worker-verb-unsupported` | Forge | reached through the polled calls exactly as through `execute` |

## 9. What the build must show (the issue's "done when")

1. A conformance case for **every ending of the table**: `accepted` then `finished`, polled through `status` and `result`.
2. **Cancel of a running build**: the group is gone (no `sleep` of the stand-in left), the directory kept, the same request
   resumes it.
3. **`status` of a build whose worker was killed**: `finished`, and `result` is `build-supervisor-lost`.
4. **A Forge restart in the middle of a running build**: `forge build` killed with SIGKILL while the build runs;
   `forge recover <dir> <workers>` leaves the running task running and `forge await` settles it when the build ends; and the
   same after the build ended while Forge was down.
5. `cancho authority` of the adapter reviewed (the supervisor starts a process by name beneath a `Dir`: `exec_under` and
   `exec_detached`, both already in its report; `fs_write` for `run.json`, `result.json`, `cancel.req`, already held; the
   rename and remove rows to be read from the report, not assumed), and of the forge binary.
6. Every new refusal with its tag and a test that reaches it; a deliberate-break harness in the style of
   `scripts/mutate_cancho_code.py` kills every break.
