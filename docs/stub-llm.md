# The stub LLM worker

> **Status: built and measured (this document was written before the code; section 8 holds what was measured).**
> A deterministic, scripted worker that speaks the worker contract
> ([`worker-contract.md`](worker-contract.md)) the way a model-backed worker would, so that every flow of Forge that
> ends in a worker can be run end to end with no model, no network and no key. It is the drop-in for the slot of the
> Cancho Code adapter ([#16](https://github.com/alpibrusl/cancho-forge/issues/16), blocked on
> [cancho#562](https://github.com/alpibrusl/cancho/issues/562)) until that exists, and afterwards the way to test a flow
> against a worker that fails on purpose. Tracked by [#12](https://github.com/alpibrusl/cancho-forge/issues/12).

## 1. Why

Forge's contract tests ran against `tests/contract/mock_worker.cho`, which is driven by an `inject` word in the request
and answers a fixed three-byte file. That is enough to reach every row of worker-contract section 5, and not enough to
test a *flow*: a task that is proposed, approved, dispatched, answered, judged and journalled, with the reply a real
model-backed worker would give (a prompt in, a text or a patch out) and the ways it goes wrong. Three things were
missing:

1. a worker whose answer depends on the **prompt** of the task, as a model's does, chosen by a script a test can read;
2. the failures of a **model-backed** worker, not only a crashing process: a refusal, a reply that is not JSON, a reply
   cut off, evidence that lies, a reply that comes after the deadline, partial work before a crash;
3. a **proposal**: the reply a Stage 3 flow records (a patch as evidence, a claim and nothing more,
   [`self-hosting.md`](self-hosting.md) section 4).

## 2. What it is

`workers/stub_llm.cho`: a `sync` worker of the stdio binding. One `execute` request on stdin, one response on stdout,
exit 0, one process per call. It is a cancho program started beneath the workers directory like any other worker
(`forge.worker`, `exec_spawn_under`); nothing in Forge knows it is a stub.

What it answers is chosen by a **script**, `stub_script.json` in `grants.execution_dir`, the way the brief of the
process-and-directory binding (worker-contract section 9) is a file in the execution directory: written by the test (or
the operator) before the dispatch. The pure half, whether a script is well formed and which rule a prompt picks, is
`src/stub_script.cho`, in `cancho test`.

## 3. The script

```json
{"rules": [
  {"match": "add a flag", "type": "repo.change", "do": "propose",
   "summary": "add a --version flag", "patch": "--- a/main\n+++ b/main\n@@ -1 +1 @@\n-old\n+new\n"},
  {"match": "unsafe", "do": "refuse", "code": "policy-refusal", "summary": "declined"},
  {"do": "ok", "text": "the reply for everything else\n"}
]}
```

* **The first rule that takes the prompt is the one.** A rule takes a prompt when its `match` is a substring of
  `task.input.prompt` (compared as written between the quotes of the request: escapes are not decoded, so a `match`
  is compared with the prompt's JSON text) and its `type`, when it has one, is `task.type`. A rule with no `match`
  takes every prompt: last, it is the default; first, it hides the rest.
* **No rule takes the prompt** is the stub's own refusal `stub-no-rule`, never a guess.
* **A script is checked as a whole** before any rule is used: one bad rule is `stub-script-invalid` for every prompt,
  so a typo in a rule that is not reached today is found today.
* **Limits** (`forge.stub_script`): 1 to 64 rules; `match` and `type` 1 to 256 bytes; `text` and `patch` at most 65536
  decoded bytes; `summary` at most 256; `delay_ms` 0 to 600000 and an integer; `code` 1 to 64 bytes of `a-z`, `0-9` and
  `-`, not starting or ending with `-`, with no escapes; `do` one of the ten below.

## 4. What it does

| `do` | the stub writes | Forge sees | rule tag / consequence |
|---|---|---|---|
| `ok` | `reply.md` = `text` (default `stub reply\n`) | `succeeded`, one `report` entry | none / `verification` |
| `propose` | `proposal.patch` = `patch` (default: a one-line unified diff of `README.md`), `report.md` = `Proposal: <summary>` | `succeeded`, a `patch` and a `report` entry | none / `verification` |
| `refuse` | nothing | `failed`, `error.code` = the rule's `code` (default `model-refused`), `retryable: false`, no evidence | none / `worker-said` |
| `malformed` | text that is not JSON | exit 0, not an object | `worker-protocol` (not JSON) / `failed` |
| `truncated` | the first half of a valid reply, no newline | a reply that stops | `worker-protocol` (not JSON) / `failed` |
| `liar` | `reply.md`, but the reply claims another hash | `succeeded` | `evidence-ref-invalid` (sha mismatch) / `failed` |
| `liar_size` | `reply.md`, but the reply claims another size | `succeeded` | `evidence-ref-invalid` (bytes mismatch) / `failed` |
| `slow` | waits `delay_ms`, then as `ok` | a reply, or none if Forge's deadline passed first | none / `verification`, or `worker-timeout` / `retry-or-fail` |
| `crash_after_progress` | `progress.txt` (`step 1 of 3`), then traps | ended by a signal | `worker-crashed` / `retry-or-fail` |
| `oversize` | `limits.max_output_bytes + 1` bytes (at most 8 MiB + 1) | stdout past the cap | `worker-output-overflow` / `failed` |

The rule tags are Forge's (worker-contract section 5; architecture section 7): the stub adds **none**. What it adds
are the `error.code`s a worker may choose, which Forge records and never interprets:

| `error.code` | when |
|---|---|
| `stub-no-rule` | no rule takes the prompt |
| `stub-script-missing` | there is no `stub_script.json` in the execution directory |
| `stub-script-invalid` | the script is not JSON, or not well formed (section 3) |
| `stub-bad-request` | the request has no `task.input.prompt` string, or `grants.execution_dir` is not a path the stub will use |
| `evidence-unwritable` | a file of the reply could not be written in the execution directory |
| the rule's `code`, or `model-refused` | `refuse` |

A request that is not an `execute` of `forge-worker/1`, or that has no request id or no task id, is **not answered**:
the stub exits 4 having written nothing, as the gate runner does (Forge sees `worker-error`). It does not guess a reply
Forge could not match to a call.

**The delay is a wait, not a spin.** `slow` waits on an empty poller (`poller_wait`) until `delay_ms` has passed on the
clock; it uses no CPU, and Forge's deadline (`process.capture`) kills it like any worker. It starts no process, so the
kill reaches everything it has (gap G10 does not apply to a worker with no children, spike S11).

## 5. The flow it is tested with

`tests/conformance/stub_llm.cho` starts the stub as a real child process, once per case, through `forge.worker.execute`
(the path production will use), then writes the journal Forge would write for that ending and replays it. The flow:

1. `task.proposed` and `task.approved` (human), `task.ready` and `task.running` (forge), by `forge.journal.submit`;
2. the dispatch, the classification (`forge.dispatch`) and the evidence recomputed against the files
   (`forge.evidence_io`);
3. for an ending that is a refusal, a `refusal` record with its rule tag (`forge.event.refusal`), then the move the
   consequence says:

| consequence | the task goes to | why |
|---|---|---|
| `verification` | `verification` | the worker's `succeeded` is a claim; **never `accepted`** |
| `retry-or-fail` | `ready` | a lost or failed execution returns to `ready` within the retry budget (architecture section 6); **the budget is not built**, so the flow takes the first retry |
| `blocked`, `failed`, `worker-said` | `blocked` | operator action; `failed` has no state of its own (architecture section 6), and `worker-said` waits on `error.retryable`, which is not read yet |
| `cancelled`, `poll` | `cancelled`, stays `running` | not reached by the stub |

**This mapping is Forge's own** (`forge.flow.target_of`, `src/flow.cho`, 6 unit tests; `forge gate` uses it too,
[`self-hosting.md`](self-hosting.md) section 3.1). It was a table in this test's first version, when no supervisor
existed; the first self-hosted task made it Forge's, and the test now calls the same function. The flow driver in the test
is still test code (it writes the four moves that dispatch a task by hand). What the test checks is Forge's own
machinery: the replay is clean (no `journal-corrupt`, no torn bytes), the task is in the state above, the record count is
exactly right, and the refusal line holds the rule tag.

## 6. What it does not model

* **A real model.** The stub's reply is a function of a script. It does not misunderstand, drift, argue, hallucinate a
  path, or answer differently the second time. A flow that passes against it has not been tested against a model's
  nondeterminism.
* **The Cancho Code binding.** Cancho Code is `async`, process-and-directory, minutes long (worker-contract section 9);
  the stub is `sync` over stdio. It is a stand-in for the *position* of a model-backed worker in the flow, not for the
  binding. The `async` verbs (`status`, `result`, `cancel`) are not implemented by it.
* **Cost.** No tokens, no money, no `cost` field.
* **Children.** A worker that starts subprocesses and leaks them (spike S11) is the gate runner's problem, not the
  stub's; the stub starts none.
* **Prompt injection.** The prompt is data to match, never executed or fed back; the stub cannot be injected because it
  does nothing with the prompt but compare it.

## 7. Authority

`cancho authority workers/stub_llm.cho` is checked in as [`authority-stub-llm.txt`](authority-stub-llm.txt) and compared
by the gate (`scripts/check_stub_llm.sh`): `fs_read("")`, `fs_write("")`, `file_read`, `file_write` (the script and the
evidence; every path has passed `journal_io.path_ok`), `heap`, `io_read`, `io_write`, `clock` and `poll` (the delay). It
never touches the network, the command line, signals, other programs or foreign code. No `exec`: it starts nothing.
`src/stub_script.cho` is pure (empty effect rows). The `forge` binary's own report (`docs/authority.txt`) is unchanged:
nothing in `main` links the stub.

## 8. Measured

* **`cancho test`:** 19 unit tests of `forge.stub_script` (the pick, the type filter, the default, no rule, the closed set
  of behaviours, every optional field, every bound at its edge and one past it).
* **Conformance** (`scripts/check_stub_llm.sh`, real child processes, in `scripts/gate.sh`): 50 checks. 16 flows (one
  per ending and per pick of a rule), each with a replayed journal; 13 raw replies, for the stub's own codes, the number
  and `kind` of the evidence entries, `retryable: false` on a refusal; 6 requests the stub does not serve (exit 4, nothing
  written); 14 oracles outside the programs (`cmp`, `grep`, `pgrep`, and the `forge` binary reading the journals back
  with `status` and `history`: a refusal journal reads as blocked with one `refusal` record, a proposal as
  `verification` and never `accepted`, a timeout as `ready`); and the authority report against the checked-in one.
  The whole gate, with these 50 checks in it, passes in 84 s (one run, compiler `7e4088b`, the container of `spike/RESULTS.md`).
* **Deliberate breaks** (section 9).

## 9. Mutation results

* **`scripts/mutate_stub_script.py`** (the pure module, against `cancho test`): 57 breaks, **46 killed, 11 equivalent**, 0
  survived. An *equivalent* break is a check that another check already makes redundant (`json.get` of a node that is
  not an object answers -1, so "the script is an object" and "a rule is an object" refuse nothing the next line does not;
  `json.to_int` saturates, so "the delay fits 64 bits" refuses nothing the bound does not). Each is listed in the script
  with its reason; the checks stay because they say what is meant and the others are accidents of how `json` answers.
  The first run had 14 survivors: three were real gaps (the length of a text, a patch and a summary was not tested;
  neither was a delay that wraps around 64 bits) and got tests; the rest are the 11 above. One of the "killed" results
  of the second run was the new test trapping on its own script, found by running it against the unbroken module first.
* **`scripts/mutate_stub_llm.py`** (the worker, against the conformance script, serial): 36 breaks, **33 killed, 3
  equivalent**, 0 survived. The first run had 8 survivors: five were gaps in the oracles (the `kind` of the evidence, the
  default patch, `retryable`, a script that cannot be read) and got checks; three are equivalent and listed with their
  reason (the 8 MiB ceiling of `oversize` is above every cap a case sets; a reply missing its last byte is not JSON
  either, as one missing half is not; a request with no prompt is refused by the next check). A run of the harness
  while a half-written file was in the tree built the copies badly and every result was `INVALID`: the harness copies
  the whole tree, so it is run on a tree that builds.

## 10. Not done

`capabilities` (the stub would answer it, Forge does not call it yet, worker-contract section 3.1), the `async`
verbs, `error.retryable` (a rule cannot choose it; it is always `false`), a script that reacts to the attempt number
(a flaky worker that fails twice and then succeeds, for the retry budget of M4), and the Cancho Code binding.
