# Worker contract, version 1

> **Status: draft, `forge-worker/1`. The `execute` path over stdio is
> measured with a cancho mock worker (spike S6); everything else is
> designed.** This contract is written *ahead of* Cancho Code's real
> interface. Milestone 2 starts by auditing Cancho Code and correcting this
> document in place wherever the two disagree; nothing here binds Cancho
> Code to internals. See [`architecture.md`](architecture.md) for why the
> transport is a child process and how Forge limits what the child gets.

---

## 1. Shape

A worker is an **executable** Forge starts as a child process, once per
call, under an `Exec` capability narrowed to the workers directory. A call
is:

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

The mock worker and the first Cancho Code adapter are `sync`.
`capabilities.async` declares the level. Async is designed, not spiked
(see section 8).

## 2. Envelope

Every request and response carries:

| field | type | meaning |
|---|---|---|
| `contract` | string | `"forge-worker/1"`. Major version only; a breaking change makes `/2`. |
| `request_id` | string | Forge-generated idempotency key, journalled before the call. A repeated `request_id` for `execute` means the same request: the worker must not start the work twice. |
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
  `max_output_bytes` itself regardless.
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

`state`:

| state | meaning |
|---|---|
| `succeeded` | the worker believes it finished. **A claim.** Forge moves the task to `verification`, never to `accepted`. |
| `failed` | the worker could not do it; `error` is non-null |
| `partial` | something usable was produced, but the task is not done; `error` says what is missing |
| `cancelled` | the worker stopped because it was asked to |
| `accepted` (`async` only, from `execute`) | the worker took the job; poll `status` / `result` |

Any other value is `worker-protocol`. `error` is `{"code": "<worker-defined,
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
* Cancellation reaches only the worker's own process **unless Forge started
  it detached and kills its group** (S7). Workers that start subprocesses
  must be started that way; architecture G3.
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
| `id` | unique within the response |
| `kind` | `patch`, `log`, `report`, `test_output`, `file`, `other` |
| `ref` | a **relative** path inside `execution_dir`: no leading `/`, no `..` component, no NUL, at most 512 bytes. Anything else is `evidence-ref-invalid` |
| `sha256` | lowercase hex of the file as the worker wrote it |
| `bytes` | length |

Forge **recomputes** the hash and size itself when it receives the response,
before the artifact is referenced by any event. A mismatch is
`evidence-ref-invalid`. Evidence that a worker supplies is recorded as
`claimed`; it can support, but never replace, evidence Forge observes by
running its own checks (M3). A changed file after the first recording
invalidates every verification that cited it.

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
| 5 | non-zero exit status | `worker-error` | retry under budget | `exit 3: worker_error exit 3` |
| 6 | exit 0 but stdout is not a JSON object, or fails section 2 | `worker-protocol` | `failed`; never retried blindly | `garbage: protocol_error` |
| 7 | well-formed response with `state: failed` | (worker's own `error.code`) | per `retryable`, under budget | `reports fail: worker_reports_failed` |
| 8 | well-formed, `state: succeeded` | (none) | `verification` | `normal: worker_claims_succeeded -> verification (not accepted)` |
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
| a worker's subprocesses are killed with it | S7 | **measured: not by default; with a detached start and a group kill, yes** |
| `capabilities`, `cancel`, `status`, `result`, `async` level | | designed |
| contract tests run against mock and the real adapter | `tests/contract/` (M2) | not started |
| evidence hash recomputation | `std.crypto.sha256` exists | not spiked |
| the real Cancho Code interface | audit at the start of M2 | **not done: this document may be wrong about it** |

The mock worker (`spike/mock_worker.cho`) implements `execute` only, and
selects its behaviour from an argument for failure injection. The M2
version will read the injected behaviour from the request instead, so the
adapter under test is called exactly as production calls it.

**Where the spike and this document differ.** The S6 mock predates the
envelope: it answers `{"v":1,"state":...,"task_id":...,"evidence":[...]}`
(no `contract`, no `request_id`, an evidence `ref` of the form
`file:artifacts/...` and no hash), and the S6 dispatcher checks only that
stdout is a JSON object with a known `state`. So section 5 rows 9 and 10,
and the `request_id` and hash rules, are not exercised. M2 brings the mock
and the dispatcher up to this text, not the other way round.
