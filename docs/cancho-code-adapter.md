# The Cancho Code adapter: task type `project.build`

> **Status: built, as a `sync` slice (issue #16).** `workers/cancho_code.cho` (the process half) and `src/build_task.cho`
> (the pure half) are checked in with a conformance program, a stand-in build tool, outside oracles and a deliberate-break
> harness. It has **never started the real `cancho-build`**: no model, no key and no real Cancho Code binary were used. What
> was measured is the adapter against a stand-in that ends the way [`cancho-code-audit.md`](cancho-code-audit.md) says the
> real tool ends. Where the two differ, this document is wrong and is corrected in place.
> Written before the code and corrected by it: section 9 says what the building changed.

The audit ([`cancho-code-audit.md`](cancho-code-audit.md)) found that Cancho Code is a command-line build tool whose request
is its arguments and a brief file, whose response is a directory of files plus an exit code, and which runs for minutes.
[`worker-contract.md`](worker-contract.md) section 9 is the binding that says how the messages of the contract are carried
for such a tool. This document is the adapter that implements it, and the decisions it had to make that section 9 left open.

It could not be written until the worker could be started **beneath a directory chosen at run time and as a process-group
leader** (gap G10, cancho #562, built by cancho #588 as `exec_spawn_detached_under`; spike S12). The adapter is the first
worker to use it.

## 1. Scope: why `sync`

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

`stuck`, `gate_failed` and `plan_failed` are **outcomes**, not worker errors; they are never retried blindly. Only a provider
error is `retryable: true`.

Refused before anything runs (`failed`, no evidence): `task-type-invalid`, `input-invalid`, `path-invalid`, `limits-invalid`,
`operator-invalid`; and `tool-unusable` (the tools directory cannot be opened) and `workdir-unwritable` (the brief or the
output cannot be written, or the directory cannot be opened to list the evidence). A request that is not an `execute` or a
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

* **The `async` level** (an adapter that answers `accepted` and is polled) and with it `status`, `result` and `cancel` for this
  worker. Section 1 says why the `sync` slice is what can be tested today.
* **A real `cancho-build`.** Nothing here ran the real tool, a model or a key; the stand-in ends the way the audit measured the
  real one ends. Latency, token use, cost and the share of runs that end `done` are still unmeasured (worker-contract 9.5).
* **Forge's side.** `forge.worker.build_execute*` builds the `repo.gate` and `repo.change` requests; nothing builds a
  `project.build` request (`grants.tools_dir`, `grants.build`) from the operator's configuration, and no `forge` command starts
  this adapter. The adapter checks its request again because a request may not come from Forge.
* **Two builds in one directory.** The tool has no lock (audit 4). The adapter holds none either: exclusion is Forge's lock on
  the execution directory (`forge.lock`), as for the gate runner.
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
