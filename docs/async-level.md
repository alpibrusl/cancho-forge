# The `async` level: an adapter that answers `accepted` and is polled (issue #33)

> **Status: built, against the stand-in tool only** (the design was merged first, #38; this is the build, #33). Everything
> marked *measured* was run on compiler `972099e`, Linux x86-64, against the stand-in tool. Nothing here ran the real
> `cancho-build`, a real model or macOS. Section 10 says what the building measured and what it corrected; a claim that the
> building showed false is corrected where it was made.

The Cancho Code adapter ([`cancho-code-adapter.md`](cancho-code-adapter.md)) was `sync` (one Forge process waits, up to
a day, on one build) and is `async` since this issue. [`worker-contract.md`](worker-contract.md) sections 1.2, 3.3 to 3.6 and 9 describe the `async` flow and
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
it the request on its standard input (after a first line `supervise <token>`, which is how the same program knows it is the
supervisor without reading its command line: see section 10), waits until it says it holds the directory, and answers
`accepted`. The supervisor is
the process that today runs `run_locked`: it takes the lock, starts the build as a group leader, holds the `Child`, and ends
when the build does. A later `cancel` reaches it **through a file**, not a signal:

```
execute   --> checks the task (as before) --> starts SUPERVISOR (detached, released; stdin: `supervise <token>` and the request)
                                          --> waits for run.json with its own token, or for the supervisor to end
                                          --> answers accepted         (or the supervisor's refusal)
SUPERVISOR --> takes forge-build.lock (a held lock: exit, no write) --> removes the previous run's files
           --> writes run.json {request_id, task_id, token}          --> runs the build, as today, in slices of 100 ms
           --> every slice: cancel.req names this request?  yes: kills the build's group (child_kill_group)
           --> writes result.json (the final reply of `execute`, atomically) --> lets the lock go --> ends
status    --> reads run.json and result.json, and tries the lock: held = running, free and no result = lost
result    --> returns result.json (the call's own request id in it); if the supervisor is gone, settles it as lost (below)
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
| `result` | the final reply of `execute` | `result.json` exists for the target: **the same bytes every time, with the request id of the call that asks** (a reply is valid for the request it answers: section 10) |
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
  the run); when Forge's deadline passes, a `cancel` and the ending `Timeout` (`worker-timeout`; as for any worker a deadline leaves the task `ready`, the policy of `forge.flow`, not `blocked`: section 10). A `status` or
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

## 10. Measured, and what the building changed

Compiler `972099e`, Linux x86-64, one run each, against the **stand-in** tool (`scripts/standin_cancho_build.sh`, modes `slow` and
`holdgrand`, the second with a grandchild `sleep 78` that only a kill of the build's group reaches).

**What was run.**

* **Every ending of the table of `result`, polled.** The cases of `tests/conformance/cancho_code.cho` assert what they
  asserted when the adapter was `sync` (state, `error.code`, `retryable`, number of evidence entries, time), but the program now
  drives each through `execute` -> `status` until `finished` -> `result` (`ran_async`), and `forge.worker.execute` +
  `forge.await_run.finish` for Forge's own path. `scripts/check_cancho_code.sh`: **103 checks, all `ok`** (it was 84).
* **Cancel of a running build**: answered `cancelled` in under 3 s; the build and its grandchild are gone, so is the
  supervisor; `status` is `finished` and `result` is `cancelled` with no error and the evidence there is, the same twice; the
  directory is kept (brief, report, log, lock file) and has no product; a second cancel is `cancelled`; **the same request on the
  same directory is accepted and ends `done`** (the old `cancel.req` did not stop it: the supervisor removes it at the start).
* **`status` and `result` of a build whose supervisor was killed with SIGKILL**: the build and its grandchild are still running
  (the orphan, gap G4); `status` is `finished`, `cancel` is `not_running`, `result` is `failed` / `build-supervisor-lost` /
  not retryable with the evidence there is, **kept** (a file removed from the directory afterwards does not change it), and a
  cancel after that is `too_late`. The next request on the directory takes the lock at once and ends `done`.
* **The races of the lock and the file protocol**: a second adapter on a busy directory is answered `execution-locked` in under
  three seconds and writes nothing (every file's size, mtime to the nanosecond and checksum is what it was); a cancel request
  naming another request does not stop the build; `status`, `result` and `cancel` about a directory with no run answer
  `unknown`, `not_ready`, `not_running` and write not a byte (not even the lock file); a relative directory or no target is not
  answered (exit 4); a workers directory that is missing, or has no `cancho_code`, is `supervisor-unavailable`, and none at all
  is `path-invalid`, with nothing written.
* **Forge, end to end** (`scripts/check_build_run.sh`: **70 checks**, it was 52). `forge build` waits for an accepted build and
  writes its ending as it always did (the journal has one more record, `execution.accepted`). `forge cancel` is answered while
  `forge build` holds the workspace lock and writes nothing; the polling `forge build` then ends `cancelled` (`execution.cancelled`,
  `task.cancelled`, exit 4, no claim) and the directory resumes under a new task. **A Forge killed with SIGKILL in the middle of a
  build**: the build outlives it; `forge recover <dir>` reports the task awaiting and writes nothing; `forge recover <dir>
  <workers>` asks the worker, finds the build running, and writes nothing; after the build ended while Forge was down, the same
  command reads the result and moves the task to `verification` with the claim; recovering again finds nothing. `forge await`
  waits for a build that was still running when Forge came back and settles it. A budget the build outruns makes Forge cancel it
  (`worker-timeout`, the group gone, the directory kept). A worker that does not know the run it accepted is `execution-lost`
  (`blocked`). A cancel with no Forge polling is written by the next `forge await`.
* **Unit tests** (`cancho test`: **262** in all): `run_files` 6, `verbs` +2 (the replies a worker writes are the ones Forge
  judges valid), `dispatch` +2, `recover` +6 (an accepted task is awaiting, not lost, however many times the worker was started;
  an `accepted_of` that reads the request and directory), `build_task` +1.
* **Authority**: `docs/authority-cancho-code.txt` and `docs/authority.txt` are byte for byte what they were (the gate compares
  both). `child_kill_group` needed no new label; the rename and the remove are `fs_write("")`.
* **Deliberate breaks**:
  * `scripts/mutate_cancho_code.py`: **86 breaks, 85 killed, 1 equivalent**, 31 of them new for this level (the state words of
    `accepted` and `cancelled`; an accepted answer before the supervisor holds the directory; a start token that is not compared;
    the supervisor's exit codes misread; a workers directory not checked; a stale cancel request, result or header kept; each
    answer of `status`, `result` and `cancel` for a run that is live, finished, lost, unknown or cancelled; a result that is not
    re-bound to the caller's request id or is made again at every call; a cancel not written, for another request, never looked for,
    looked for every hundred seconds, or killing the pid and not the group; a cancelled build reported as a signal; the unit
    tests of `run_files` and `verbs`). The one equivalent: removing a stale `run.json` before `open_write` truncates it (a write
    that fails after the removal cannot be arranged as root). One break the first run did not kill (a stale `result.json` kept)
    needed a better test: the new run was too quick to be told from the old result, so the check now holds the build and asks
    `status` and `result` of it before it ends.
  * `scripts/mutate_build_run.py`: **51 breaks, all killed**, 25 of them new (the accepted run not polled or not written down,
    the request or the directory of the record, `execution.cancelled` missing in `forge build` and in `forge await`, the refusal
    tag or the claim missing in `forge await`, a deadline ignored, not cancelled or reported as a loss, a status that is not
    `unknown`-is-lost, the result asked under the wrong id, `recover` taking an accepted run for a lost one or not asking, the exit
    status of a running run and of a cancel, a budget under a second). Two were not killed at first: a `forge await` budget under a
    second (the check now tries 999 ms) and one that was INVALID (replaced).
  * `dispatch` 41 of 41 (five new: the lost run's tag and consequence, and the three states `accepted` is not), `verbs` 72 of 72
    (the request in a directory), `recover` 40 of 40, `contract` 15 of 15, `gate_run` 58 (57 killed, 1 equivalent as before),
    `stub_llm` 33 of 36 with 3 equivalent as before. **Thirteen breaks of the older harnesses were INVALID** (the three of `mutate_contract.py` already were
    on `main`, since `recheck` was extracted; ten became so with this change, by a field added to `Counts`, a command added to
    `main.cho` that repeats a line, or a second request builder in `verbs.cho`); their texts are repaired and they are killed.

**What the building corrected in the design (each is fixed above in place):**

1. **The supervisor is told it is one on standard input, not in its arguments.** The first build read `supervise <token>` from
   the command line and the adapter's report gained `args` (it had listed "the command line" under *never touches*). A review
   artefact that widens for a convenience is the wrong trade: the first line of the input is now `supervise <token>`, and the
   report is unchanged.
2. **A `result` must carry the request id of the call that asks.** The design said `result.json` is returned "byte for byte";
   Forge's validator (rightly) refuses a reply whose `request_id` is not the call's, and the stored reply carries the `execute`'s.
   `forge.run_files.rebind` replaces the id in the stored bytes (the file is in a fixed layout the adapter wrote, and an id that is
   not plain text is refused), so the answer is the same bytes with the id of the caller.
3. **Forge's own deadline leaves the task `ready`, not `blocked`.** The design said the ending is `worker-timeout`, which is true;
   the consequence of that ending in `forge.flow` (`retry-or-fail`) is `ready` for every worker, a deadline having no verdict, and
   `forge.retry` refuses the retry of a task that writes only for `worker-retryable` endings. The build check says so.
4. **The request id Forge gives the worker is `r-<task>`** (`r-build-1`), not `<task>-a<n>` as the examples of section 5 had it;
   `execution.accepted` records whatever it was.
5. **The ending of a lost run is `Ending::Lost`** (a new variant of `forge.dispatch`: tag `execution-lost`, consequence
   `blocked`), not an `Unavailable`; and `status` creates no file for a run it does not know (the lock file is only opened for a
   run that has a `run.json`).
6. **`forge build` takes at least as long as one poll** when the first `status` finds the build running: it asks, naps a second,
   and asks again. Not tuned.

**Not measured, and not claimed:**

* **The real `cancho-build`**, a real model and a key. In particular whether the tool, killed with `KILL` at its group's
  level, leaves `plan.json` and `state.txt` in a state from which it resumes (the audit's claim, audit 4; the stand-in resumes
  because it is a shell script). `progress.step` is the stand-in's `stage` word; the real tool's stages are the audit's.
* **macOS** (`EWOULDBLOCK` is 35 there; `child_kill_group` and the poller are measured on Linux only), a network filesystem.
* **An orphan build** after a SIGKILL of the supervisor: gap G4. The check shows it alive and shows that `result` names the loss;
  nothing stops it, and a new request on the directory would be accepted beside it.
* **The three tries of the supervisor's lock** against a `status` probe that holds the lock at that instant (the break that
  makes it one try is equivalent: no test can arrange the instant). **A supervisor silent for ten seconds** (its kill and
  `supervisor-unavailable`) and **a supervisor that does not write its result in ten seconds after a cancel** (the adapter's only
  unanswered call, exit 4, `worker-error`): the code is there, no test reaches either.
* **Latency and cost of polling** (one process start per `status`), many builds at once, a journal with many awaiting tasks.
* **`forge recover <dir> <workers>` for a task whose directory was moved or deleted**: `status` answers `unknown` and the task is
  `execution-lost` (the `lo` case removes `run.json`); a workers directory that cannot be opened is exit 3.
