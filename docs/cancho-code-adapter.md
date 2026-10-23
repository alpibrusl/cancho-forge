# The Cancho Code adapter: task type `project.build`

> **Status: built (issue #16), `sync` at first and `async` since issue #33 ([`async-level.md`](async-level.md)).** `workers/cancho_code.cho` (the process half) and `src/build_task.cho`
> (the pure half) are checked in with a conformance program, a stand-in build tool, outside oracles and a deliberate-break
> harness. It has **never started the real `cancho-build`**: no model, no key and no real Cancho Code binary were used. What
> was measured is the adapter against a stand-in that ends the way [`cancho-code-audit.md`](cancho-code-audit.md) says the
> real tool ends. Where the two differ, this document is wrong and is corrected in place.
> Written before the code and corrected by it: section 9 says what the building changed.
> `forge build` (section 10, issue #34) starts it from Forge, still against the stand-in tool.

The audit ([`cancho-code-audit.md`](cancho-code-audit.md)) found that Cancho Code is a command-line build tool whose request
is its arguments and a brief file, whose response is a directory of files plus an exit code, and which runs for minutes.
[`worker-contract.md`](worker-contract.md) section 9 is the binding that says how the messages of the contract are carried
for such a tool. This document is the adapter that implements it, and the decisions it had to make that section 9 left open.

It could not be written until the worker could be started **beneath a directory chosen at run time and as a process-group
leader** (gap G10, cancho #562, built by cancho #588 as `exec_spawn_detached_under`; spike S12). The adapter is the first
worker to use it.

## 1. Scope: why `sync`

> **The `async` level is built ([`async-level.md`](async-level.md), issue #33).** What follows is the reason for the first
> slice, kept because the deadline and the resume it describes are unchanged; the decision that replaces the waiting, and its
> measurements (spike S14, the conformance), are in that document.

Section 9 says the Cancho Code adapter is `async`: `execute` answers `accepted`, `status` and `result` are polled, `cancel` kills
the group. The `async` flow is **designed and not built end to end** (worker-contract 3.6: the mock only answers the verdicts;
Forge does not act on `status`). An adapter that answers `accepted` would have nothing on the other side to poll it. So the
first slice is `sync` (worker-contract 1.2): `execute` runs the build to completion inside its deadline and answers the final
result on stdout; `cancel`, `status` and `result` are not sent to it (`worker-verb-unsupported`, nothing is started).

What makes this honest rather than a shortcut:

* **The directory is the identity of the work** (audit 4). A build that did not finish inside the deadline is not lost: the
  adapter kills its group, keeps the directory, and answers `build-timeout`; **the same request resumes it** (the tool resumes
  from `plan.json` and `state.txt`). So a `sync` adapter with a long deadline loses nothing the `async` one would keep. (The
  resume is the tool's claim, audit 4, measured there with a stand-in; the adapter's conformance does not run a resumed build.)
* **The deadline is the adapter's own**, four fifths of Forge's (`build_task.runner_deadline_ms`), for the reason S7 and S11
  measured: Forge's kill reaches the adapter's pid and a detached build outlives it. With `exec_spawn_detached_under` and
  `capture`'s deadline the adapter ends the build's whole group before Forge's deadline fires (S12).
* The cost of `sync` is a Forge process that waits (up to a day) on one build. That is Forge's scheduling problem, not a
  correctness one, and it is what the `async` split is for when it is built.

## 2. The task, and who says what

```json
"task":   {"id": "t-1", "type": "project.build", "input": {"brief": "<1 to 16384 bytes of text>"}},
"limits": {"timeout_ms": 600000, "max_output_bytes": 1048576},
"grants": {
  "execution_dir": "/abs/executions/e-1",
  "tools_dir":     "/abs/tools",
  "build": {"checker": "/abs/cancho", "agent": "<agent command>", "provider": "p", "model": "m",
            "guide": "/abs/plan-guide.md", "attempts": 4, "agent_seconds": 30, "rounds": 3, "plan_seconds": 900, "jobs": 4}
}
```

Three things come from three places and none from another's (worker-contract 9.1: arguments come from configuration, never
from a task):

| | comes from | rule |
|---|---|---|
| the **brief** | the task (`task.input.brief`): untrusted text a model will read | 1 to 16 KiB, no NUL; written to `brief.txt` in the execution directory, **never to an argument** |
| **where and with what** the build runs: the tools directory, the checker, the agent command, the provider, the model, the guide, the five ceilings | the operator, through Forge (`grants.tools_dir`, `grants.build`) | paths as `gate_task.path_ok`; provider and model only what the tool allows in a shell line; the agent command one printable-ASCII argument; ceilings in ranges. Defaults are the tool's own |
| the **execution directory** | Forge (`grants.execution_dir`) | `gate_task.path_ok` |

The tool is **a fixed name**, `cancho-build`, found beneath `tools_dir` (`exec_spawn_detached_under`, under `Exec("")` with the
name checked first by `exec_covers`): a task cannot name what runs. `limits.timeout_ms` is 10 000 to 86 400 000.

## 3. What it does

1. Validate (`build_task.check`, then `build_task.operator_checked`). The first fault, in the order type, brief, paths, limits,
   operator, is the one named. A refusal runs nothing and writes nothing.
2. Open `tools_dir` as a `Dir`; ask `exec_covers` about `cancho-build`.
3. Write `brief.txt` in the execution directory.
4. Start `cancho-build <checker> <execution_dir>/brief.txt <execution_dir> <agent> --provider P --model M [--guide G]
   --attempts N --agent-seconds N --rounds N --plan-seconds N --jobs N` **detached beneath the tools directory, with an empty
   environment** (the audit ran it under `env -i`), and capture its standard output up to 1 MiB under the deadline.
5. Write that output as `build.out`.
6. Read `build.json`, opened beneath the execution directory following no link, and turn the tool's exit code and verdict into
   an ending (section 4).
7. Offer as evidence each of `build.json`, `build.out`, `run.log`, `project.cho` that exists as an ordinary file. Answer.

## 4. The reply

The verdict is **a claim**. The tool's exit code and the verdict word in `build.json` must **agree** (the tool's `code_of`
is a function of the verdict), and the verdict is **never** taken from standard output, which carries text a model influenced.

| the build ended | `state` | `error.code` | retryable | evidence |
|---|---|---|---|---|
| exit 0, `done` | `succeeded` (a claim; Forge moves the task to `verification`) | none | | the four files |
| exit 1, `stuck`, at least one unit verified | `partial` | `stuck` | no | the files that exist |
| exit 1, `stuck`, nothing verified | `failed` | `stuck` | no | |
| exit 1, `gate_failed` | `partial` | `gate-failed` | no | |
| exit 3, `plan_failed` | `failed` | `plan-failed` | no | nothing was built |
| exit 4, `provider_error` | `failed` | `provider-error` | **yes** (what verified is kept; a new request resumes it) | |
| exit 2 | `failed` | `build-usage` | no | a defect of the adapter or of the operator's configuration |
| any other pair of exit code and verdict; `build.json` missing, not an object, or a link; an unknown verdict word | `failed` | `build-protocol` | no | |
| ended by a signal | `failed` | `build-crashed` | no | |
| not finished inside the adapter's deadline (its group is killed) | `failed` | `build-timeout` | no (the same request resumes it) | what exists |
| more than 1 MiB of standard output (its group is killed) | `failed` | `build-output-overflow` | no | what exists |
| the tool could not be started | `failed` | `build-unavailable` | no | none |
| asked to stop by `cancel` (its group is killed) | `cancelled` | none | | what exists |
| the supervisor is gone and left no result (`result`, issue #33) | `failed` | `build-supervisor-lost` | no | what exists |

`stuck`, `gate_failed` and `plan_failed` are **outcomes**, not worker errors; they are never retried blindly. Only a provider
error is `retryable: true`.

Refused before anything runs (`failed`, no evidence): `task-type-invalid`, `input-invalid`, `path-invalid`, `limits-invalid`,
`operator-invalid`; `tool-unusable` (the tools directory cannot be opened); `workdir-unwritable` (the brief or the
output cannot be written, the directory cannot be opened to list the evidence, or its lock file cannot be opened); and
`execution-locked` (another adapter holds the directory: section 11, not retryable, nothing written); and, since issue #33, `supervisor-unavailable` (the supervisor of the build cannot be started or does not take the directory) and `path-invalid` for a `workers_dir` that is not a path. With the `async` level every ending of this table is the answer to `result`; `execute` answers `accepted` once the build is running, or one of the refusals of this paragraph. A request that is not an `execute` or a
`capabilities` of this contract, or names no request id or no task id, is **not answered** (exit 4, which Forge classifies
`worker-error`). Every code has a row in [`architecture.md`](architecture.md) section 7 and a case in the conformance program.

## 5. Authority

`cancho authority workers/cancho_code.cho` (checked in as [`authority-cancho-code.txt`](authority-cancho-code.txt), compared
by the gate): `exec_under` and `exec_detached` (**no `exec("...")` and no path named**: the program is a name beneath a `Dir`
the operator gave), `fs_read("")` and `fs_write("")` (the brief, the output, and the evidence directory), a clock, pipes and
a poll for the capture, the heap, stdio; no network, no signals, no foreign code. Compared with the gate runner's
([`authority-gate-runner.txt`](authority-gate-runner.txt)): `exec("/bin/sh")` is gone and `exec_under` replaces it; `fs_read("")`
and `dir_read`/`file_read` are new, because the adapter reads `build.json` and hashes the evidence. What the build does once
started is the build's authority, not the adapter's: **`cancho-build` itself holds `exec("")`** (audit 6, architecture G2), and
the `Exec` bound Forge puts on starting the adapter does not bound it.

The `async` level (issue #33) **did not widen it either**: the supervisor is the adapter itself started by name beneath a `Dir`
(`exec_under` and `exec_detached`, already in the report), the files it keeps are written under `fs_write("")`, and the
rename and the remove of `result.json` are covered by the same label. The one thing that could have added `args` (the
supervisor needs its start token) is passed on standard input as a first line instead (`supervise <token>`), so that the
adapter still reads no command line. `docs/authority-cancho-code.txt` is byte for byte what it was; the gate compares it.

The lock of section 11 (issue #35) **did not widen this report**: it is `file_lock` on a file the adapter opens with `open_append`, under
the `fs_write("")` and `file_write` it already held for `brief.txt`. The gate compares the report with the checked-in file
and it is unchanged.

## 6. How it is checked

* **Unit tests**, `tests/build_task_test.cho` (`cancho test`, 24): every refusal and its tag and the fixed order, the ranges,
  the argument vector byte for byte, and every pair of exit code and verdict of the tool's table, with the pairs outside it.
* **Conformance**, `tests/conformance/cancho_code.cho`, run by `scripts/check_cancho_code.sh`: the adapter built into a workers
  directory and started as a real child process, against a stand-in `cancho-build` (a shell script, a test fixture that does one
  thing for each first line of the brief) in a tools directory. One case for each way a build can end, each refusal, and each
  thing the adapter must not do with a request that is not a task; plus **Forge's own path** (`forge.worker.execute`
  recomputes the evidence of a good run against the files, and the task goes to `verification`).
* **Oracles outside the programs** (`cmp`, `grep`, `pgrep`): the brief file is the brief byte for byte, including quotes,
  newlines and shell metacharacters; the argument vector is the operator's, one argument each, the agent command as **one**
  argument, and nothing of the brief in it; the environment is empty; a build that hangs leaves no `sleep` and no `cancho-build`
  behind (its group was killed, which is what G10 was about); a `build.json` that is a link is not followed or offered; a
  noisy build's output is exactly the 1 MiB cap; refusals wrote nothing.
* **Deliberate breaks**, `scripts/mutate_cancho_code.py`: one break per decision, each applied to a copy of the tree and run
  through the whole check. The result is in section 7.

## 7. Measured

Compiler `972099e`, Linux x86-64, one run each.

* `scripts/check_cancho_code.sh`: **69 checks, all `ok`** (the conformance cases and the oracles), including the case of a build
  that hangs: the adapter's own deadline fires first, its group is killed and nothing the stand-in started is left running.
* `cancho test`: 24 unit tests for `build_task`.
* `scripts/mutate_cancho_code.py`: **48 deliberate breaks, 48 killed, none equivalent.** One for each decision: the tool's name,
  the environment, the deadline (the adapter's and the arithmetic), the output cap, the brief file, a failed write, a build that
  could not start, the output file, the verdict and the verified count read from `build.json`, each evidence field, each
  `error.code` and the retryable flag, every refusal and each of its bounds, every pair of exit code and verdict, each
  argument of the vector and the defaults, and what is not a task. A break is killed by the check script, or, for the pure half,
  by the unit tests that the harness runs after a clean check.

The first run of the harness found **five breaks that were not killed**, and each said something true about the code:

| break | why it survived | what changed |
|---|---|---|
| a brief that cannot be written is run anyway | the later write of `build.out` failed the same way, so the answer was the same | a case with a `brief.txt` that is a directory: the brief fails and the output could be written; the tool must not run |
| a verb other than `execute` is served | the only case of another verb also named no task id, which a different guard refuses | a complete task under another verb |
| the number of verified units is not used by an exit 2 | the adapter had a branch for exit 2 that duplicated `build_task.ended`'s | the duplicate is removed: one rule, one place |
| exit 2 is reported as a protocol error | the same duplicate hid it | killed by the conformance once the duplicate was gone |
| a brief of any size is taken | the worker's decoder refuses an oversize brief first, so the rule in the pure half was unreachable from the process | a unit test at exactly 16 384 bytes and one more, and the harness runs the unit tests as a second oracle |

The harness itself had a defect found at the same time: it called a break INVALID when the output held the text `error:` and no
`FAIL`, which matched its own check label `provider_error:`; it now looks for the compiler's `file:line:col: error` form.

## 8. Not done

* ~~**The `async` level** (an adapter that answers `accepted` and is polled) and with it `status`, `result` and `cancel` for this
  worker.~~ Built (issue #33): [`async-level.md`](async-level.md).
* **A real `cancho-build`.** Nothing here ran the real tool, a model or a key; the stand-in ends the way the audit measured the
  real one ends. Latency, token use, cost and the share of runs that end `done` are still unmeasured (worker-contract 9.5).
* **Forge's side** is built since issue #34 (section 10): `forge build` builds the `project.build` request from the operator's
  configuration and starts this adapter. The adapter still checks its request again, because a request may not come from Forge.
* ~~**Two builds in one directory.** The adapter holds none either: exclusion is Forge's lock on the execution directory.~~
  **Corrected (issue #35, section 11): that assumption was false** (Forge's lock is the workspace's, and two workspaces can point at
  one directory; measured) and is replaced by the adapter's own lock. The tool itself still has none (audit 4).
* **Cost.** The tool records tokens in `usage.jsonl`; the adapter does not offer that file or derive a cost (worker-contract 9.2,
  milestone M4).
* **`--retry`, `--patch`, `--review`, `--contract`, `--memory`**: not passed. A `stuck` outcome continues only through a new
  request that does not exist yet.
* **A descendant that leaves the build's group** (`setsid`) is not reached by the group kill (cancho `docs/processes.md`
  section 9; S12). **macOS.**

## 9. What building it changed, and what it found

* **Error codes are kebab-case.** Worker-contract 9.4 wrote the tool's verdict words (`gate_failed`, `plan_failed`,
  `provider_error`) as `error.code`; the contract says the code is kebab-case. The codes are `gate-failed`, `plan-failed`,
  `provider-error`; 9.4 is corrected in place.
* **Exit 2 is answered, not silent.** Section 9.4 said exit 2 is `worker-error` and a Forge bug. The adapter composes the
  argument vector, so it answers `build-usage` with the evidence there is; a request that is not a task is what stays
  unanswered (exit 4).
* **A compiler defect, filed upstream as [cancho #597](https://github.com/alpibrusl/cancho/issues/597):** `exec_covers(exec, name) == false` fails code generation ("cannot determine the scalar
  kind of `PathCovers`"), while the same call returned from a function or used as a condition compiles. The adapter asks it in
  a function (`tool_ok`).
* **A check's own scratch path can be refused.** The first run of the check failed 40 cases because the scratch directory had a
  path component starting with `-`, which `gate_task.path_ok` refuses by design. `scripts/gate.sh` uses `mktemp` under `/tmp`;
  a person running the check by hand must too.
* **`pgrep -f 'cancho-build'` matched the oracle's own `sh -c`.** The oracles use the bracket form (`[c]ancho-build`), as the
  other checks do.

## 10. `forge build`: Forge starts the adapter (issue #34)

> **Status: built, checked against the stand-in tool only.** Written before the code; section 10.7 says what the building
> changed.

`forge build` does for the adapter what `forge gate` does for the gate runner: it takes the lock of a workspace, records a
task, starts the worker as a real child process under a deadline and an output cap, recomputes the evidence against the files,
and journals what happened. It builds the `project.build` request from the **operator's configuration**, which is the part
that did not exist (`forge.build_task.request`; before it, nothing built a request with `grants.tools_dir` and `grants.build`).

### 10.1 The command

```
forge build <dir> <workers> <tools> <brief-file> <execution-dir> <checker> <provider> <model> <agent> [timeout-ms] [NAME=value ...]
```

`<dir>` is the workspace (the journal and the lock), `<workers>` the directory holding the adapter `cancho_code`, `<tools>` the
directory holding `cancho-build`, `<brief-file>` the brief (at most 16 KiB), `<execution-dir>` an existing directory for the
build. `<checker>` (an absolute path of the compiler), `<provider>`, `<model>` and `<agent>` (one argument: the shell command
line the tool runs) are positional because a build cannot start without them; the optional trailing `guide=PATH`,
`attempts=N`, `agent_seconds=N`, `rounds=N`, `plan_seconds=N`, `jobs=N` are the tool's ceilings, a **closed list** (a name twice,
or not on it, or a value that is not a number, is bad usage). `timeout-ms` defaults to one hour. The same shape as `forge gate`:
positional paths, an optional timeout, trailing `NAME=value`.

### 10.2 Where the configuration lives

**Decision: on the command line, like `forge gate`'s environment (self-hosting D7), not in a file.** A configuration file would
need a format, a parser and a place to look for it, and each of those is more authority and more refusals; the command line
needs none, and the closed list makes a typo a refusal instead of a silent default. The alternative, a file in the workspace,
stays open for when the number of options makes the command line unwieldy.

Three consequences, stated rather than hidden:

* **The configuration is never journalled.** The journal holds the task, its states, the intent, the refusal tags and the
  claimed verdict; the checker, the agent command, the provider and the model are in no record (checked: the journal of a
  successful build contains none of them).
* **A secret stays out of the journal and the request logs, not out of `ps`.** The tool takes its API key as **a file path
  named inside the agent command** (audit 2.2), so what is on the command line is a path, never a key. But the agent command
  line is visible to anyone who can read the process table while the build runs, as every argument is. If that is not
  acceptable, the answer is a configuration file with restricted permissions, which is the open alternative above.
* **The brief is not on the command line**, only its path; it reaches the adapter in the request (JSON-escaped) and the tool in
  a file.

### 10.3 What it does, and what it shares with `forge gate`

Read the brief (before anything is journalled: a file that cannot be read, or is over 16 KiB, is `brief-unreadable`, exit 1,
no journal); take the lock; then `forge.build_run.run`:

```
task.proposed, task.approved   (human: the operator who ran the command)
the task is checked            (type, brief, paths, limits, then the operator's configuration; a refusal is a `refusal`
                                record and the task stays `approved`: nothing is started, nothing written in <execution-dir>)
task.ready, task.running       (forge)
execution.started             (forge: the intent, before the adapter is started)
the adapter is started         (forge.worker.execute; the evidence is recomputed, a symlink is not followed)
a refusal record               (when the ending is a refusal, or the retry is refused)
execution.finished             (worker, basis "claimed": the verdict of build.json, written only for a succeeded run)
task.verification | task.blocked
```

**Shared**: the functions that write those records (`move_to`, `note`, `note_execution`, `note_retry`, `request_id_of`,
`succeeded` of `forge.gate_run`, now `pub`), the lock, the journal replay, `forge.worker.execute`, `forge.dispatch`,
`forge.flow` and `forge.retry`. **Not shared**: the loop around them, because each thing it decides differs (the checks, the
id `build-N`, the request, the claim read from `build.json`, the retry policy). Sharing the loop would take a parameter for each
of those; this duplicates about eighty lines instead, and leaves `forge gate` byte for byte as it was (its own checks and
mutation harness untouched). If a third task type arrives, the loop is the thing to factor.

### 10.4 A build is not retried by itself

`forge.retry` retries only a worker's `retryable: true` failure, up to three attempts, and **never a task that writes**
(`retry-write-refused`). `forge build` says the task writes. So the adapter's one retryable ending, `provider-error`, ends the
task `blocked` with `retry-write-refused`, and the operator decides; to **resume**, run `forge build` again on the same
`<execution-dir>` (a new task, `build-N+1`, over the same work: the tool resumes from `plan.json` and `state.txt`, the audit's
claim, which the stand-in does not exercise).

The reason is money, not safety: a build writes only inside its own directory and resumes, so a retry would be safe, but every
attempt spends a model's tokens, and the decision to spend more is not Forge's. A policy that retries a build is a per-task-type
flag in `forge.retry` and a budget; neither exists (milestone M4).

### 10.5 Exit status and refusals

| exit | when |
|---|---|
| 0 | a claim was recorded (`done`): the task is in `verification`, never accepted |
| 1 | refused: the task (`task-type-invalid`, `input-invalid`, `path-invalid`, `limits-invalid`, `operator-invalid`: it stays `approved`, the tag is printed), the brief file (`brief-unreadable`: no journal), or the journal |
| 2 | bad usage, or a path that is not absolute or has a `..` |
| 3 | the workspace is locked, the workers directory cannot be opened, or an I/O error |
| 4 | the run ended without a claim: the ending and the state (`blocked`) are printed |

`brief-unreadable` is new (`docs/architecture.md` section 7); the others are the adapter's, now also reached through Forge.

### 10.6 Authority of the forge binary

**Unchanged**, measured: `cancho authority src/*.cho --std` prints the report that `docs/authority.txt` already holds, byte for
byte, with `forge build` linked in. The command needs the same rows `forge gate` has: `exec_under` and `dir_read` (the adapter
is a name beneath the workers directory), `fs_read("")` and `file_read` (the brief file, `build.json`), `fs_write("")` and
`file_write` (the journal), a clock and a poller (the deadline). It starts no process by a path and holds no `exec("...")`; the
tool is started by the *adapter*, whose authority is `docs/authority-cancho-code.txt` and is unchanged. (It was expected to widen
and does not; the commit message says so.)

### 10.7 Measured, and what the building changed

Compiler `972099e`, Linux x86-64, one run each, against the **stand-in** `cancho-build` (`scripts/standin_cancho_build.sh`, shared
with the adapter's own check). `scripts/check_build_run.sh`: **48 checks, all `ok`**: a build that ends `done` (seven records,
the claim written by the worker, the brief byte for byte with quotes, a backslash and a tab, no configuration in the journal,
the lock let go); the operator's options reaching the tool one argument each; every ending that is not a claim (`stuck`,
`provider-error` with the retry refused and started once, `gate_failed`, `plan_failed`, an exit 2, a tool that lies, a hang whose
group is killed with nothing left running, a noisy tool, a missing tool); every refusal and that it started nothing; the brief file
cases (missing, 16 KiB and one byte, exactly 16 KiB, a directory); bad usage; and no process left behind. `cancho test`: 30
unit tests for `build_task`. `scripts/mutate_build_run.py`: **27 deliberate breaks, 27 killed, none equivalent**, one per decision (the checks and their order, the intent before the worker, the retry policy and its journal record, the claim and where it is read, the worker's name, the brief, the work directory, the ceilings' order, the brief file's limit and path check, the id, the guide, the escaping of the brief, the closed option list and its duplicates, the default timeout, each exit status and what is printed). All 27 were killed on the first run, so this harness found no hole in the checks, unlike the adapter's (section 7); the two checks added while it was written (a brief path that is not absolute, the default timeout) were added because a break could not be written for them without one.

What the building changed: the brief file limit was off by one on the first run (the read took a file of 16 KiB and one byte to
the later `input-invalid` refusal instead of `brief-unreadable`; the check that found it is the one for that file); an
unguarded `seen / bit` in the option parser was replaced by `bit_set`, which does not divide when `bit` is 0, though the closed
list makes that unreachable (no input may reach a trap, even an unreachable one).

### 10.8 Not done

* **A real `cancho-build`** (issue #32): everything here is the stand-in.
* **The worker's error code of a build that did not succeed is not journalled.** A `stuck` or `gate-failed` build ends the task
  `blocked`, and the journal says so, with no `execution.finished`; the code is in the adapter's reply, which Forge does not
  keep, and the verdict is in `build.json`, which is untrusted evidence Forge reads only for a succeeded run (a link in its
  place is refused only then). Recording the claim of a failed build needs the evidence recomputed for that ending too.
* **A refusal tag from `forge.dispatch`** (a reply that is not valid for the contract) is journalled by the same code as the
  gate's, but the stand-in adapter never produces one: this check does not reach that line. The gate's checks cover the same
  shape.
* ~~**The `async` level** (#33).~~ Built: [`async-level.md`](async-level.md). (The lock for two builds in one directory, #35, is built: section 11.)
* **The tag of a refused second build is not in `forge build`'s output.** The second `forge build` on a busy directory ends
  `blocked` with `ending: worker-said`, exit 4, and journals no `execution.finished`; the code `execution-locked` is in the
  adapter's reply, which Forge does not keep (the item above about a failed build's code). The first build is undisturbed.
* **Cost**, **a configuration file**, **`--retry`/`--patch`** (section 8).

## 11. Two builds in one directory (issue #35)

> **Status: built, checked against the stand-in tool only.** Written before the code (sections 11.1 to 11.6 are the design as
> committed first; 11.7 says what the building measured and changed). The spike measurements are `spike/RESULTS.md`, S13.

### 11.1 The race, measured (before any lock)

Nothing stops a second adapter, or a second `forge build`, on a directory a build is using. `spike/s13_two_builds.sh` starts
two adapters on one execution directory against the stand-in tool, the second while the first build still runs:

* **both ran**: two builds live at once, and no error;
* the second **overwrote `brief.txt` under the first** (a 10-byte brief became an 11-byte one), and the two builds had read
  different briefs;
* the files at the end were **whoever wrote last**: `project.cho` and `build.out` named the first build in one run of four
  and the second in three;
* **both answered `succeeded`**, each with evidence recomputed from the same files: a claim whose files may be another
  request's, which Forge would move to `verification` without being able to tell;
* **Forge's lock does not cover it**: `forge build` locks the *workspace* `<dir>`, and `<execution-dir>` is another argument.
  Two workspaces and one execution directory gave two exit 0 and two tasks in `verification`. (Two commands on one workspace
  are refused `workspace-locked`; that is `forge.lock`'s case and is not the question.)

So the assumption in section 8, that exclusion is Forge's lock on the execution directory, was **false as written**: there is no
lock on the execution directory, only on the workspace. And a retried request, a person running the worker by hand, or a
second Forge never goes through the lock at all.

### 11.2 Where the exclusion belongs: (b), the adapter, and Forge's lock stays

The options of the issue, with the cost of each:

| | what it excludes | cost |
|---|---|---|
| (a) Forge's lock only | two `forge build` on one workspace | **does not exclude the measured case** (two workspaces), a worker run by hand, or a second Forge |
| (b) the adapter takes its own lock on the execution directory | every start of the adapter on that directory, whoever started it | a recovery rule, a file in the directory, and a refusal tag in the worker; **no new authority** (below) |
| (c) both | (b) plus a refusal at Forge before anything is started | Forge's lock already exists; a new Forge-side check would read the execution directory, which Forge does not otherwise do before the worker runs |

**Decision: (b).** The worker is the only party that sees every start, and the adapter is the one that writes the directory. The
cost the issue names, "a write capability and a recovery rule in the worker, whose authority is reviewed", is smaller than it
looks: the adapter **already holds** `fs_write("")` and `file_write` (it writes `brief.txt` and `build.out`), and the lock is
`file_lock` on a file it opens with `open_append`, the same call `forge.lock` makes. So the authority report
(`docs/authority-cancho-code.txt`) is expected not to change, and the gate compares it. The recovery rule is the one
`forge.lock` already answers (below), not a pid file. Forge's workspace lock stays as it is: it protects the journal, which
is a different thing.

### 11.3 The primitive

An exclusive, non-blocking `flock` on a file of its own, `forge-build.lock`, in the execution directory, held on an open
file for the life of the adapter's build, and let go after the answer is written. Not "a lock file created exclusively and
removed": that primitive is a *name*, and a name outlives a crash.

* **Why `flock` and not exclusive create.** With exclusive create, the file existing means "locked", so a SIGKILL of the
  adapter leaves a lock nobody removes, and the fix is a pid and a start token read back and compared (what a pid file needs),
  which is a race of its own (pid reuse) and more code to be wrong. `flock` is released by the kernel when the descriptor
  closes, however the process ends. Measured (S13): a second `file_lock` is refused with `EWOULDBLOCK` while the holder lives,
  and is granted at once after the holder is killed with SIGKILL. The lock file is created if missing (`open_append`) and
  never written.
* **Create-race.** Two adapters that both find the file missing both create it (`O_CREAT` without `O_EXCL` returns the same
  file to both), and only one gets the lock: the exclusion is on the file, not on its creation.
* **Where.** Inside the execution directory, so that it travels with the directory (copied, removed or resumed with it), and
  so that a second adapter finds it from the one path it was given. The refused start **writes nothing**: the file exists
  already (the holder made it), opening it for append writes no byte, and the check is that every file in the directory,
  `forge-build.lock` included, is byte for byte what it was and the mtime of none changed. A lock file beside the directory
  (`<dir>.lock`) would keep the evidence directory clean, but it needs a writable parent the operator did not name, so it is
  not chosen.
* **The lock is taken after the task is checked and before the first write** (`brief.txt`): a refused start has done
  nothing to the directory in use. A directory that cannot be opened or created for the lock is `workdir-unwritable`, as
  before.
* **The build does not hold it.** `exec_spawn_detached_under` starts the build with no descriptor of the adapter's open
  (S13: the build has none naming the lock file). So the lock is the *adapter's*, and lasts as long as the adapter does.

### 11.4 Stale locks, a deadline, a resume

* **A crash of the adapter** (SIGKILL, the OOM killer, a power cut of the machine) frees the lock with the process. Nothing
  is removed by anyone, and the next start takes it: the stale-lock case is settled, not stuck. **The residual, measured and
  not hidden (S13): the build the killed adapter started is an orphan, in a group of its own, and may still be writing.** The
  lock cannot follow it (it has no descriptor), so a second adapter started at that moment is *not* refused and would race
  the orphan. This is gap G4 (children outlive a dead parent), not new; what closes it is the operator, who stops the orphan
  (its group is not killed by anything) before resuming, and `forge recover` does not do it today. The check shows the
  orphan alive, the second adapter taking the lock, and says so in its label.
* **`build-timeout`.** The adapter's own deadline kills the build's group and *then* answers and exits, so the lock is let go
  at the end of that request and "the same request after a deadline kill resumes" (section 10.4) takes it. The check runs the
  hang case and then a second request on the same directory.
* **A resumed build** is a new request on the same directory after the first ended, which is a sequence, not a conflict. A
  resume while the first is still running **is** the conflict and is refused: that is the point.

### 11.5 What a refused second start answers

`failed`, `error.code` **`execution-locked`**, `retryable: false`, no evidence (`[]`), and exit 0 (it is a valid answer; a
request the worker cannot answer is exit 4). Not retryable *by Forge*: a retry of a task that writes is refused anyway
(`retry-write-refused`, section 10.4), and the operator, who can see the other build, decides. The tag is a worker `error.code`
like the others of section 4, with a row in `architecture.md` section 7 and a conformance case. No file in the directory is
written, and the first build is undisturbed: its files are byte-identical to a run without the second (the check compares
them, with `cmp`, to a run of the same brief in another directory).

### 11.6 What is not claimed

* **A build that removes or replaces its own lock file** (it runs in that directory, as the agent's code) can make a later
  adapter lock a different file and run beside it. The build is the build's authority (section 5), not a party to the
  exclusion; the lock stops two *adapters*, not a build that works against it. Argued, not measured.
* **Network filesystems, macOS** (`EWOULDBLOCK` is 35 there; `forge.lock` already carries both numbers). Linux ext4/tmpfs only.
* **The real `cancho-build`** may care about an extra file in its work directory; the stand-in does not.

### 11.7 Measured, and what the building changed

Compiler `972099e`, Linux x86-64, one run each, against the **stand-in** tool (`scripts/standin_cancho_build.sh`, mode `slow`).

* **The race is a test.** `scripts/check_cancho_code.sh` runs the scenario of 11.1 with two real adapters: the first build running,
  the second adapter started on the same directory. Run on the adapter **as it was**, with the check in place, it failed 7 of its
  new checks and the updated `notool` one (the second ran, `brief.txt` changed, the two answered `succeeded`, the files differed from a
  run alone, the lock file did not exist); on the
  adapter with the lock all pass. The second answers `failed` / `execution-locked` / `retryable: false` / no evidence at once, every
  file of the directory (size, mtime to the nanosecond, checksum, the lock file included) is what it was before it started, and
  the first build's files and its answer are byte for byte those of the same brief run alone in another directory.
* **Stale lock, settled.** The first adapter killed with SIGKILL with its build running: the build is still alive (an orphan),
  holds no descriptor naming the lock file, and the next adapter takes the lock at once and finishes `succeeded`. **The orphan
  and the second build overlap while the orphan lives**: that is the residual of 11.4, shown by the check, not removed by it.
* **A deadline kill and a resume**: after the `build-timeout` case, the same directory takes the same request and the build
  finishes `done`. A lock file that is a directory is `workdir-unwritable` and the tool never runs.
* **Through Forge**: two `forge build` on two workspaces and one execution directory (`scripts/check_build_run.sh`): the second
  ends `blocked`, exit 4, and started no build; the first ends in `verification` with its own claim and its own `brief.txt`.
  Two on one workspace are refused at the workspace (`workspace-locked`, exit 3), as before.
* **Unit tests**: `build_task` has the new tag and the lock name (31 tests, one new; the tag is also asserted in the existing tag test).
* **Counts**: `check_cancho_code.sh` 84 checks, all `ok` (69 before); `check_build_run.sh` 52 (48 before).
* **Deliberate breaks**, `scripts/mutate_cancho_code.py`: 7 new (the lock let go before the build, the held lock not recognised,
  the refusal under another tag or tag name, retryable, a lock file that cannot be opened run anyway, the lock file named as the
  build's output), all killed.
* **Authority**: the adapter's report and the forge binary's are unchanged (the gate compares both).

What the building changed: the first oracle for the `notool` case listed only `brief.txt`, and now lists the lock file too (the
adapter takes the lock before the tool is looked up by the spawn). The decision of 11.2 did not change.
