# Worker contract, version 1

> **Status: draft, `forge-worker/1`, corrected once by the Cancho Code audit
> ([`cancho-code-audit.md`](cancho-code-audit.md)).** The `execute` path over
> stdio is measured with a cancho mock worker (spike S6); the Cancho Code
> binding (section 9) is measured against its real command line with a
> stand-in agent, not a real model; everything else is designed. This
> contract was written *ahead of* Cancho Code's real interface and the audit
> showed it wrong in five places, listed next and fixed where they occur,
> each marked **(corrected)**. Nothing here binds Cancho Code to internals.
> See [`architecture.md`](architecture.md) for why the transport is a child
> process and how Forge limits what the child gets.

### What the audit changed, and why

| # | Was | Now | Evidence |
|---|---|---|---|
| 1 | The only transport is one JSON object on stdin and one on stdout. | That is the **stdio binding** (mock worker, third-party workers). Cancho Code has no stdin protocol: its request is `argv` plus a brief file, its answer a run directory, tab-separated lines and an exit code. That is the **process-and-directory binding** (section 9). The JSON messages of section 3 stay the contract's *model*; an adapter translates. | audit 2.1, 3.1 |
| 2 | Exit 0 means "a protocol response", non-zero is `worker-error`. | Per binding. In the Cancho Code binding the exit code **is** the verdict (0 `done`, 1 `stuck`/`gate_failed`, 3 `plan_failed`, 4 `provider_error`); only 2 (usage, which Forge treats as its own bug) and signals are errors. | audit 3.1 |
| 3 | The first Cancho Code adapter is `sync`; cancel is TERM then KILL and the process is reaped. | It is `async` (minutes, resumable). There is no cooperative cancel; TERM leaves **no verdict and an orphaned agent**, so Forge starts it detached and kills the group. | audit 4 (run) |
| 4 | Task type `repo.change` with `grants.workspace`. | Cancho Code builds a **new project from a brief**: `project.build`. `repo.change` is not claimed for it. | audit 2.1, 7 |
| 5 | `cost.source` is `worker-reported`; `limits.budget` is enforced by the worker; credentials travel on stdin. | Cancho Code records tokens only; money is `derived-from-tokens` with Forge's own dated price table; there is no money limit, only attempt and round ceilings; the key is a **file path** in the agent command. | audit 3.4, 2.2 |

---

## 1. Shape

A worker is an **executable** Forge starts as a child process, once per
call, under an `Exec` capability narrowed to the workers directory. There
are two bindings of the same model: this section and sections 2-4 describe
the **stdio binding**; section 9 is the **process-and-directory binding**
that Cancho Code needs **(corrected)**. In the stdio binding a call is:

```
<worker-path> <verb>        stdin: one JSON request      stdout: one JSON response
```

* **Verbs:** `capabilities`, `execute`, `cancel`, `status`, `result`.
* **stdin:** exactly one JSON object, then end of file.
* **stdout:** exactly one JSON object followed by `\n`, then exit. Anything
  else on stdout is a protocol error. stdout is bounded
  (`limits.max_output_bytes`, default 1 MiB): more is `worker-output-overflow`.
* **stderr:** diagnostics for humans. Captured (bounded, 64 KiB by
  default), journalled as an artifact, **never parsed** and never shown to
  another agent as an instruction.
* **Exit status:** `0` means "I produced a protocol response", which may
  say the task failed. Non-zero is `worker-error`, whatever was on stdout.
* **Environment:** empty. **Working directory:** the execution directory.
  **Arguments:** the verb only; everything else is in the JSON.

Forge-side machinery (all measured in S1, S2, S6): `process.channels`,
`exec_spawn`, `process.capture` / `capture_both`, which write the request
while reading the output (no pipe deadlock), keep at most the bound, enforce
the deadline with a kill and reap the child on every path.

### 1.1 Why not a long-lived worker process or sockets

One process per call is stateless on both sides: there is no session to
lose when either side restarts, and the journal (not the connection) is the
memory. A long-running worker keeps its own state in its execution
directory, so a *later* call (`status`, `result`) works after Forge
restarted. A sockets or HTTP transport could implement the same JSON
messages and is not ruled out; it is not needed for M2 and would need `Net`.

### 1.2 Conformance levels

| level | verbs | meaning |
|---|---|---|
| `sync` | `capabilities`, `execute` | `execute` runs to completion inside the deadline and answers a final result on stdout. `cancel` is Forge killing the process. |
| `async` | all five | `execute` may answer `state:"accepted"` quickly and keep working in the background, writing `status.json` and `result.json` in the execution directory; `status`, `result` and `cancel` read and act on that. |

The mock worker is `sync`. **(corrected)** The Cancho Code adapter is
`async`, not `sync`: a build is a plan stage and then a model call per unit,
minutes in all, and the work is resumable from its directory (audit section
4). `capabilities.level` declares the level. For the stdio binding async is
designed, not spiked; for the Cancho Code binding the start / status / result
/ cancel semantics are in section 9 and were measured with a stand-in agent.

## 2. Envelope

Every request and response carries:

| field | type | meaning |
|---|---|---|
| `contract` | string | `"forge-worker/1"`. Major version only; a breaking change makes `/2`. |
| `request_id` | string | Forge-generated idempotency key, journalled before the call. A repeated `request_id` for `execute` means the same request: the worker must not start the work twice. **(corrected)** A process-and-directory worker has no field to carry it: Forge makes the execution directory name a function of `request_id` and holds the exclusion itself, because Cancho Code does not (audit section 4). |
| `verb` | string | in requests: the verb. |

Rules: unknown fields are ignored (so a minor addition is not a break).
A missing required field, a wrong type, an unknown `state` or `kind`
value, or a `request_id` that does not match the request is a **protocol
error**, never a guess (fail closed). All integers are 64-bit signed.
JSON is UTF-8; no comments.

## 3. Verbs

### 3.1 `capabilities`

Request: `{"contract":"forge-worker/1","verb":"capabilities","request_id":"r-0"}`

```json
{
  "contract": "forge-worker/1",
  "request_id": "r-0",
  "worker": {"name": "mock", "version": "0.1.0"},
  "supports": ["forge-worker/1"],
  "level": "sync",
  "task_types": [
    {"type": "repo.change", "limits_max": {"timeout_ms": 600000, "max_output_bytes": 1048576}}
  ]
}
```

**(corrected)** `repo.change` above is the mock worker's. Cancho Code's
types are `project.build` (a brief becomes a verified new project) and,
later, `file.fix` (one broken file, its `fix` tool); it reads no existing
repository. Cancho Code has no `capabilities` call at all (no `--version`):
Forge keeps a static table per pinned revision (`.cancho-rev` of the
worker), and `cancho authority` of the binary is the review artefact.

Forge picks the highest `supports` entry it also supports; none is
`worker-contract-version`. A task whose `type` is not listed is refused by
Forge before dispatch (`policy-denied`), not sent. Called at worker
registration and cached per worker version; a worker may not widen its
`limits_max` after Forge has granted a task.

### 3.2 `execute`

```json
{
  "contract": "forge-worker/1",
  "verb": "execute",
  "request_id": "r-17",
  "attempt": 1,
  "task": {
    "id": "t-1",
    "type": "repo.change",
    "input": {"repo": "workspace/sample", "goal": "add a --version flag"},
    "acceptance": ["tests pass", "no new dependencies"]
  },
  "limits": {"timeout_ms": 600000, "max_output_bytes": 1048576, "budget": {"unit": "usd_cents", "max": 200}},
  "grants": {"workspace": "workspace/sample", "execution_dir": "executions/e-17"}
}
```

* `task.input` is opaque to Forge beyond the task type's schema; `acceptance`
  is informational for the worker. **The worker's view of acceptance is not
  the gate**: Forge verifies independently (M3).
* `limits` are Forge's decision, taken from policy and the budget. The
  worker enforces what it can; Forge enforces `timeout_ms` and
  `max_output_bytes` itself regardless. **(corrected)** "What it can" is
  less than assumed for Cancho Code: it has per-call and per-unit ceilings
  (`--plan-seconds`, `--agent-seconds`, `--attempts`, `--rounds`), **no
  whole-run deadline and no money limit** (audit 2.1). For that worker Forge's
  deadline is the only total, and `limits.budget` is Forge's own reservation,
  not a flag the worker honours.
* `grants.workspace` and `grants.execution_dir` are the only directories the
  worker is told about; paths are relative to Forge's root and the worker's
  working directory is `execution_dir`. A worker is *told* the boundary; it
  is not *held* to it unless it is itself a cancho program under a
  narrower capability, or sandboxed (architecture section 5.4, G2).

Response:

```json
{
  "contract": "forge-worker/1",
  "request_id": "r-17",
  "state": "succeeded",
  "task_id": "t-1",
  "summary": "Added --version; 14 tests pass.",
  "evidence": [
    {"id": "ev-1", "kind": "patch",       "ref": "patch.diff",       "sha256": "9f2c...e1", "bytes": 2210},
    {"id": "ev-2", "kind": "test_output", "ref": "logs/test.txt",    "sha256": "41aa...07", "bytes": 5120},
    {"id": "ev-3", "kind": "report",      "ref": "report.md",        "sha256": "c0d3...55", "bytes": 913}
  ],
  "cost": {"unit": "usd_cents", "amount": 37, "source": "worker-reported"},
  "error": null
}
```

`cost.source` is `worker-reported` (the worker said so; untrusted),
`derived-from-tokens` **(corrected, new)** (Forge or its adapter computed it
from token counts the worker recorded, with Forge's own dated price table), or
`forge-measured`. Cancho Code is always `derived-from-tokens`: it records
tokens only (`usage.jsonl`), never money (audit 3.4).

`state`:

| state | meaning |
|---|---|
| `succeeded` | the worker believes it finished. **A claim.** Forge moves the task to `verification`, never to `accepted`. |
| `failed` | the worker could not do it; `error` is non-null |
| `partial` | something usable was produced, but the task is not done; `error` says what is missing |
| `cancelled` | the worker stopped because it was asked to |
| `accepted` (`async` only, from `execute`) | the worker took the job; poll `status` / `result` |

Any other value is `worker-protocol`. *(Added by the validator, section 8: a response has at most 256 evidence entries; a `succeeded` response carries no `error`; `failed` and `partial` carry one; `cost.amount` is an integer, 0 or more.)* `error` is `{"code": "<worker-defined,
kebab-case>", "message": "<text>", "retryable": true|false}`; the code is
recorded, never interpreted as an instruction. `summary` and `message` are
**untrusted text**: stored, shown to a human, never executed or used as
input to a policy decision.

### 3.3 `cancel`

`{"contract":..., "verb":"cancel","request_id":"r-18","target":"r-17"}` ->
`{"contract":..., "request_id":"r-18","state":"cancelled"|"not_running"|"too_late"}`.

* `sync` worker: there is no `cancel` call. Forge sends `TERM`, waits the
  grace period (default 5 s, policy), then `KILL`; the process is reaped
  either way (measured: `child_kill` with `std.signals.sigterm()` ends
  `sleep` in 1 ms and the exit reports `signaled`, S2). The task event is
  `execution.cancelled`, whatever the worker managed to say.
  **(corrected)** "reaped either way" is true of the pid Forge started and of
  nothing it started. Measured against Cancho Code's `build` (audit 4): TERM
  gives exit 143 and no verdict, and the agent process it had started kept
  running. So a worker that starts subprocesses is always started detached and
  killed by group (S7), and the cancel is never the end of the *work*: the
  directory survives and the same command resumes it.
* Cancellation reaches only the worker's own process **unless Forge started
  it detached and kills its group** (S7). Workers that start subprocesses
  must be started that way; architecture G3 (built: `child_kill_group`,
  no `/bin/kill` in the `Exec` bound; corrected after cancho #533).
* `async` worker: `cancel` is idempotent; `too_late` means the result
  already exists, and Forge then reads it with `result`.

### 3.4 `status`

`{"verb":"status","request_id":"r-19","target":"r-17"}` ->
`{"request_id":"r-19","target":"r-17","state":"running","progress":{"step":"running tests","fraction":0.6},"updated":"2026-10-19T10:00:00Z"}`.
`state` is one of `queued`, `running`, `finished`, `unknown`. `progress` is
informational. `status` is advisory; only `result` is evidence of an
ending.

### 3.5 `result`

`{"verb":"result","request_id":"r-20","target":"r-17"}` -> the same body as the
`execute` response in section 3.2, or `{"state":"not_ready"}`. Calling it
twice returns the same answer (idempotent); a worker may not change a result
once reported.

## 4. Evidence references

Evidence is **by reference**. The journal does not hold file contents.

| field | rule |
|---|---|
| `id` | unique within the response, 1 to 128 bytes, written without JSON escapes |
| `kind` | `patch`, `log`, `report`, `test_output`, `file`, `other` |
| `ref` | a **relative** path inside `execution_dir`: not empty, no leading `/`, no NUL, at most 512 bytes, and no two dots in a row anywhere. Anything else is `evidence-ref-invalid`. *(Corrected: this said "no `..` component". The file capability traps on the byte pair wherever it falls, so `a..b` is refused too, as journal paths are, spike S8. A JSON escape in a `ref` is refused as well: refs are written plain.)* |
| `sha256` | exactly 64 digits of `0-9a-f`: the hash of the file as the worker wrote it. A hash of another shape is `evidence-ref-invalid` |
| `bytes` | length: an integer, 0 or more (negative is `evidence-ref-invalid`, not an integer is `worker-protocol`) |

Forge **recomputes** the hash and size itself when it receives the response,
before the artifact is referenced by any event. A mismatch is
`evidence-ref-invalid`. Evidence that a worker supplies is recorded as
`claimed`; it can support, but never replace, evidence Forge observes by
running its own checks (M3). A changed file after the first recording
invalidates every verification that cited it.

### 4.1 Recomputing the hash and the size *(built: `src/evidence_io.cho`)*

`forge.response` judges the shape of a response and opens nothing. `evidence_io.verify(heap, fs, body, execution_dir)` is
the other half: it opens the execution directory **once** as a `Dir` and opens each `ref` beneath it one component at a
time, following no link (`std.dirs.open_file`), reads the file up to a cap of 64 MiB, and compares the size, then the
SHA-256, with the claim. Every mismatch is `evidence-ref-invalid`, with a reason:

| reason | when |
|---|---|
| `evidence-missing` | the file is not there (`ENOENT`) |
| `evidence-unreadable` | it will not open or read: a symlink (to a file, or in the path), a directory, no permission |
| `evidence-too-large` | more than 64 MiB (`evidence_io.max_file_bytes`); a file of exactly the cap is read |
| `evidence-bytes-mismatch` | the size is not the claimed `bytes` (checked first: a hash of another length cannot match) |
| `evidence-sha-mismatch` | the SHA-256 is not the claimed `sha256` |

An execution directory Forge cannot open (not absolute, `..` in it, not there) is **not** a verdict on the worker: the
answer is `NoDirectory(errno)`, `-2` for a path that is not ok, and the caller treats it as an adapter fault.

**Why a `Dir` and not `Fs`.** Measured in spike S10: a worker is untrusted and can leave a symlink in its own
directory; `open_read` through `Fs` follows it (`link` to a file outside, and a path through a symlinked directory, both
opened and read), so Forge would have hashed, and in M3 might have attached as evidence, a file the worker has no
business naming. `ref_ok` and `fs_covers` look at the bytes of a path and cannot see this. `std.dirs.open_file` refuses
both (`ELOOP`, `ENOTDIR`), and `..` and an absolute path never reach it. The loop holds `dir_read`, not the `Fs`.

## 5. Error states Forge observes

Independent of what the worker says, Forge classifies how the process
ended. Rows 1-7 were produced by the S6 spike with a mock worker and a real
child process; the rule tags are the refusals of architecture section 7.

| # | Observation | rule tag | Task consequence | Spike S6 line |
|---|---|---|---|---|
| 1 | spawn failed (`Spawned::Failed(errno)`) | `worker-unavailable` | `blocked`; operator action | (S3 shows the bound; a missing file answers an errno, designed) |
| 2 | deadline passed; child killed and reaped | `worker-timeout` | retry under budget, else `failed` | `hang (500ms): worker_timeout ... [501 ms]` |
| 3 | stdout past `max_output_bytes`; child killed | `worker-output-overflow` | `failed`, not retried automatically | S2: `bound 1000 vs yes: too much, kept 1000 bytes` |
| 4 | ended by a signal | `worker-crashed` | retry under budget | `child_kill`: `signaled 8` (S2) |
| 5 | non-zero exit status **(corrected: stdio binding only; the Cancho Code binding reads the exit code as a verdict, section 9.4)** | `worker-error` | retry under budget | `exit 3: worker_error exit 3` |
| 6 | exit 0 but stdout is not a JSON object, or fails section 2 | `worker-protocol` | `failed`; never retried blindly | `garbage: protocol_error` |
| 7 | well-formed response with `state: failed` | (worker's own `error.code`) | per `retryable`, under budget | `reports fail: worker_reports_failed` |
| 8 | well-formed, `state: succeeded` (Cancho Code binding: `done`, exit 0, and `build.json.verdict == "done"`) | (none) | `verification` | `normal: worker_claims_succeeded -> verification (not accepted)` |
| 9 | `evidence` ref or hash invalid | `evidence-ref-invalid` | `failed` | not spiked |
| 10 | `request_id` mismatch | `worker-protocol` | `failed` | not spiked |

**A task is never `accepted` by any row above.** Rows 1-7 never reach
`verification`; row 8 reaches it only as an unverified claim.

## 6. Versioning

* `forge-worker/1` is the contract. Adding an optional field, a `kind`, a
  verb a worker may ignore, or a `task_type` is not a break.
* A new required field, a changed meaning or a removed value is
  `forge-worker/2`. Forge may support several majors; a worker lists the
  ones it speaks; `capabilities` negotiates (section 3.1).
* The contract tests (section 8) are versioned with it; the same suite runs
  against the mock worker and, from M2, the Cancho Code adapter.

## 7. Security rules for a response

A worker's output is untrusted data, as are repository contents and tool
output it relays (`threat-model.md`):

1. Parse into a bounded tape (`std.json.tape_len` is always enough); a parse
   error is a value, never a trap (measured, S4: truncated, empty,
   trailing-garbage, bare-word and unquoted-key inputs all answer a negative
   result).
2. Check every field against section 2 before any is used.
3. Resolve every `ref` against the execution directory only, with the
   section 4 rules, before opening it.
4. Never feed `summary`, `error.message` or stderr back into a prompt, a
   policy decision or a command line.
5. Never copy credentials from a response into the journal; the response is
   journalled by reference after redaction rules (M4).

## 8. How it is checked

| what | how | status |
|---|---|---|
| `execute` over stdio, the five endings of section 5 rows 2, 5, 6, 7, 8 | spike S6: Forge-side dispatcher + `mock_worker.cho` | **measured** |
| bounds: deadline, output cap, exit status, kill | S2 | **measured** |
| the `Exec` bound a worker is started under | S3 | **measured** |
| a worker's subprocesses are killed with it | S7 | **measured: not for a plain start; yes for a detached start, killed by `capture` or by `child_kill_group`, with no `/bin/kill`** (corrected after cancho #533) |
| `capabilities`, `cancel`, `status`, `result`, `async` level | | designed |
| contract tests run against mock and the real adapter | `tests/contract/` (M2) | not started |
| the response of `execute` against section 2, 3.2 and 4 (the shape, the closed sets, the ref and hash syntax, the bounds), as a pure function | `src/response.cho`; `tests/response_test.cho` (19 tests, among them every prefix and every single-byte change of a valid response), and `scripts/mutate_response.py` (32 deliberate breaks, all killed) | **built** (rows 6, 9 and 10 of section 5 are reached by it) |
| how a run ended (section 5) to a rule tag and a consequence, as a pure function of what `capture` observed and the bytes it captured | `src/dispatch.cho` (`classify`, `rule_tag`, `consequence`); `tests/dispatch_test.cho` (14 tests: every row, and that the ending wins over what the worker wrote), `scripts/mutate_dispatch.py` (28 deliberate breaks, all killed) | **built**. Not built: the half that spawns beneath the workers directory under a deadline and feeds `classify`; reading `error.retryable` for the `worker-said` consequence |
| the process half: build the `execute` request, start the worker beneath a run-time `Dir` under a deadline and an output cap, classify, recompute the evidence, one function | `src/worker.cho` (`build_execute`, `run`, `execute`); `tests/contract/mock_worker.cho` (driven only by its request: `task.input.inject`); `tests/conformance/worker_contract.cho` (19 cases, real child processes, one per way a run can end); `scripts/mutate_contract.py` (15 deliberate breaks, all killed); the gate checks no mock outlives the run | **built, against the mock**. The same table is what the Cancho Code adapter must pass. Not built: `capabilities`, `cancel`, `status`, `result` and the `async` level; `error.retryable`. **Gap G10** (architecture section 9): a worker started this way is not a process-group leader |
| evidence hash and size recomputed against the file, a symlink not followed | `src/evidence_io.cho`; `tests/conformance/evidence_files.cho` (24 cases against real files, the links made by the gate), `scripts/mutate_evidence.py` (16 deliberate breaks, all killed); spike S10 | **built** (section 4.1). Not yet called by a worker adapter: `src/main.cho` does not link it, so `cancho authority` for `forge` is unchanged; the call widens it by `dir_read` and says so |
| the real Cancho Code interface | [`cancho-code-audit.md`](cancho-code-audit.md): source read, both offline gates run (`scripts/test-build.sh`, `scripts/test-mcp.sh`), a stand-in run, a TERM, a resume, an `env -i` run | **done in M0; corrected sections marked above. Not done: a run with a real model** |
| the Cancho Code binding of section 9 as an adapter | `src/worker.cho` (M2) | designed from the audit; not built |

The S6 mock worker (`spike/mock_worker.cho`) selected its behaviour from an argument. The M2 mock
(`tests/contract/mock_worker.cho`) reads it from the request instead (`task.input.inject`), so the adapter under test is called
exactly as production calls it, and refuses a request that is not an `execute` of this contract.

**Where the spike and this document differ.** The S6 mock predates the
envelope: it answers `{"v":1,"state":...,"task_id":...,"evidence":[...]}`
(no `contract`, no `request_id`, an evidence `ref` of the form
`file:artifacts/...` and no hash), and the S6 dispatcher checks only that
stdout is a JSON object with a known `state`. So section 5 rows 9 and 10,
and the `request_id` and hash rules, are not exercised. M2 brings the mock
and the dispatcher up to this text, not the other way round.

---

## 9. The process-and-directory binding (Cancho Code) *(corrected: new)*

This section is derived from [`cancho-code-audit.md`](cancho-code-audit.md)
and cites it; every number and line there was read or run. It is a *binding*:
it says how the messages of section 3 are carried when the worker is a
command-line tool with a work directory, not how the tool must change.

### 9.1 Mapping

| Message | Carried as |
|---|---|
| `execute` request | Forge creates `executions/<id>/` (name derived from `request_id`; characters `A-Za-z0-9._-` only, no `..`; the worker's path rules are narrower than Forge's, audit 2.1), writes the brief into `brief.txt` there, and starts, **detached, in its own process group**, `cancho-build <checker> <abs>/brief.txt <abs>/executions/<id> "<agent-command>" --provider P --model M --guide G [--attempts N] [--rounds N] [--agent-seconds N] [--plan-seconds N] [--jobs N]`. The argument vector, including the agent command (which names the key file), is built by Forge from configuration, **never from a task**. |
| `execute` response | `{"state":"accepted"}` at once; the pid and its start token are journalled (`execution.started`) before the call returns. |
| `status` | read `executions/<id>/build.json`: `stage` `plan`/`build`/`done`, `units_verified`/`units_total`, `verdict`. Liveness is Forge's own (pid and start token), not `build.json`'s: it has no update timestamp. |
| `result` | when the process has ended: the exit code **and** `build.json.verdict` (they must agree under the table in 9.4, else `worker-protocol`), plus the evidence of 9.3. |
| `cancel` | kill the process group (TERM, grace, KILL); the task event is `execution.cancelled`; the directory is kept. A later `execute` with the same `request_id` resumes the same work. |
| `request_id` | the directory name; Forge takes a lock on it. Two builds in one directory are unguarded by the tool. |

### 9.2 Limits

`timeout_ms` is Forge's own deadline on the whole process (there is none
inside). `--attempts`, `--rounds`, `--agent-seconds`, `--plan-seconds` are
chosen from policy and bound the worst case; `--jobs` is operator
configuration (concurrent units). Money: Forge reserves a worst-case
estimate from the ceilings and records actual usage from `usage.jsonl`
(M4); the tool itself will spend whatever its ceilings allow.

### 9.3 Evidence

The adapter lists files that exist under `executions/<id>/` and Forge hashes
them (the tool records no hash). A `ref` must satisfy section 4 and the
tool's own file layout:

| kind | ref |
|---|---|
| `file` | `project.cho` (and the plan's other files, listed in `plan.json` `files`) |
| `log` | `run.log`, `journal/events.jsonl`, `trail-<id>.jsonl`, `agent-<id>.log` |
| `test_output` | `journal/blobs/<id>-a<N>-acceptance.txt`, `journal/blobs/<id>-a<N>-checker.json` |
| `report` | `build.json` |

The tool's `diff` blobs are a diff between a model's attempts, not a patch of
a repository; they are `log`, never `patch`. All of it is `claimed`.
`journal/events.jsonl` may stop growing at 2 MiB with the run continuing
(audit 3.3), so its absence of an event is not evidence of absence.

### 9.4 Endings

| Observation | Contract outcome |
|---|---|
| exit 0 and `verdict == "done"` | `state: succeeded` (a claim; the compiler and the unit's own examples are its evidence, Forge's are M3's) |
| exit 1 and `verdict` `stuck` | `partial` if `units_verified > 0`, else `failed`; `error.code` `stuck`; the units are in `plan.json`, `state.txt`; **retryable only through `--retry`/`--patch`, which is a new request** |
| exit 1 and `verdict` `gate_failed` | `partial`, `error.code` `gate_failed` |
| exit 3, `plan_failed` | `failed`, `error.code` `plan_failed`, nothing built |
| exit 4, `provider_error` | `failed`, `error.code` `provider_error`, `retryable: true` (kept units are kept) |
| exit 2 | `worker-error` and a Forge bug: the arguments were wrong |
| killed by Forge | `execution.cancelled` / `worker-timeout`; the verdict is absent |
| signal, trap, or exit 143 not from Forge | `worker-crashed` |
| verdict and exit code disagree, `build.json` missing or not an object, unknown verdict word | `worker-protocol` |
| process gone with no verdict and Forge did not kill it | `execution.lost` after recovery (architecture 4.3) |

`stuck`, `gate_failed` and `plan_failed` are **outcomes**, not worker errors:
they are the tool working, and they are never retried blindly.

### 9.5 Still open

A run with a real model: its latency, token use, cost and the share of runs
that end `done` have **not** been measured by Forge; the numbers in Cancho
Code's own README are its claims. The MCP front door is an alternative
binding (audit 5) and has not been spiked from a cancho client.
