# Threat model (Milestone 0)

> **Status: short and provisional.** It names what is protected, who or what
> may misbehave, which actions are sensitive, and where a human must
> decide. It does not claim production-grade security; the design document
> asks that no such claim be made before an appropriate review. *Measured*
> marks what a spike showed (`spike/RESULTS.md`); everything else is a
> design intention.

## 1. What is protected

| asset | why it matters |
|---|---|
| The journal | the record of who decided and did what; if it is wrong, every report is |
| The workspace and sample repository | what workers change; what a release candidate is made from |
| Credentials a worker is given for a task | repository tokens, model-provider keys |
| Budget (money, tokens, time) | the thing a runaway worker spends |
| Approvals | the human gate on consequential actions |
| The operator's machine | Forge and its workers run there |

## 2. Trust boundaries

```
 human operator ---(CLI: approvals, objectives)---> FORGE (trusted, small)
                                                      |  \
                          journal, policy ------------+   \--- spawn, stdin/stdout JSON
                          (files under .forge/)                |
                                                         WORKER child (untrusted output,
                                                          semi-trusted behaviour)
                                                               |
                                              repository content, issue text, web pages,
                                              tool output  (untrusted input to the worker)
```

Forge trusts: the operator, its own binary and the compiler that built it,
the policy it loaded. Forge does **not** trust: worker output, worker
claims of success, evidence a worker supplies, repository content, stderr.

## 3. Threats and the control for each

| # | Threat | Control | Status |
|---|---|---|---|
| T1 | Worker reports success it did not achieve (self-certification) | Runtime-owned state machine; `succeeded` goes to `verification`, never `accepted`; independent checks (M3) | state mapping **measured** (S6); verification M3 |
| T2 | Worker runs a program it was not meant to | `Exec` narrowed to the workers directory; policy pre-check | bound **measured** (S3: a spawn outside the prefix and a path with a `..` component both trap, exit 132) |
| T3 | Worker inherits a secret from Forge | `exec_spawn` passes an empty environment and no descriptors; `LD_*`/`DYLD_*` entries trap (`docs/processes.md` 4.3, 4.5) | designed in cancho; Forge passes `""` (S1, S2, S6) |
| T4 | Worker hangs or floods output | deadline and byte cap in `capture`; kill and reap | **measured** (S2: 301 ms for a 300 ms deadline; 1000-byte cap) |
| T5 | Worker leaves processes running after a kill (orphaned compiler, test runner) | Detached start + group kill (`child_kill_group`, which `capture` also does) | **measured**: leaks for a plain `exec_spawn`; gone with `exec_spawn_detached`, by `capture` or by `child_kill_group` by hand, with `Exec` narrowed to the worker and no `/bin/kill` (S7, corrected after cancho #533). Not reached: a descendant that calls `setsid`; the orphan after a Forge crash (G4) |
| T6 | Forge crashes mid-run and loses or doubles work | Append-only journal, sync before effect, torn-tail truncation, intent-before-effect events, idempotency key | torn tail **measured** by killing a writer at 25 crash points (architecture 4.8; sync order is not observable by a process kill); reconciliation designed |
| T7 | Journal tampered or corrupted | A complete line that is not the next record refuses recovery and changes nothing (`journal-corrupt`) | **measured** (S5) for corruption; *tamper evidence* (hash chain) is out of MVP scope |
| T8 | Two Forge processes write one workspace | `file_lock` on `.forge/lock` | **measured**: S5 (errno 11), and now across processes: refused with `workspace-locked` at 24 crash points, free after each kill (architecture 4.7) |
| T9 | Prompt injection through repository content, issue text or tool output | Worker output never reaches policy or a command line; no untrusted text is interpreted by Forge; sensitive actions need a human regardless of what text says | designed; injection scenarios are an M4 test requirement |
| T10 | Malformed or hostile JSON from a worker crashes Forge | `std.json` returns a negative result for malformed input; bounded tape | **measured** (S4: 6 malformed inputs, none trapped) |
| T11 | Evidence points outside the execution directory (`../../etc/passwd`) or lies about content | `ref` rules and hash recomputation (worker contract section 4) | designed |
| T12 | Budget overrun by retries or parallelism | Reservations journalled before dispatch; limits checked at execution time, not only creation | designed (M4) |
| T13 | A policy bug turns into a breach | Narrowed capabilities as a second, structural layer: the failure mode is a trap, not a breach | bound **measured** (S3); but see T14 |
| T14 | A policy bug, or an out-of-bound request, crashes Forge | Policy refuses first with a rule tag; the capability trap is the backstop | **measured**: the trap is `SIGILL` (S3), so the backstop kills the runtime |
| T15 | A secret is written to the journal or a report | Credentials are passed on stdin per task and never journalled; redaction rules for worker text (M4) | designed |
| T16 | Supply chain: the compiler or standard library is compromised | Compiler revision pinned in `cancho.toml`; no third-party packages are vendored | partial; no signature check |

## 4. Sensitive actions and the human gate

Forge fails closed for these (principle 9). Until M4 every one is simply
**not implemented**, which is the safest state; each needs a named
approval kind and an entry in the policy before it can exist.

| action | needs | first possible in |
|---|---|---|
| Dispatch a task to a worker | policy `Allow` for (worker, task type, scope, risk); budget reservation | M2 / M4 |
| Accept a task result | Forge-observed evidence for every acceptance criterion | M3 |
| Create a release candidate | all contributing tasks `accepted` | M5 |
| Publish or deploy anything | human approval **per release**, recorded as a journal event | M6 |
| Spend above a threshold | human approval | M4 |
| Change policy, budget, mission or a role's authority | human approval; a worker or the strategy loop may only *propose* | M4 / M7 |
| Widen Forge's own authority (a new capability in `main`) | a code change, visible as a diff in the checked-in `cancho authority` report | always |
| Contact the network, send external communications, handle payment or contracts | no capability exists; out of scope for the MVP | not before M6, read-only |

Approvals are journal events by a human identity. A worker has no
identity in that namespace, so it cannot approve, and a worker cannot
modify the policy it is evaluated under: the policy is read by Forge, not
passed to the worker.

## 5. What is out of scope and why it matters

* **Hostile code execution.** `Exec` bounds which program starts, not what
  it does; the child's authority is its own (`docs/processes.md` section 2,
  `docs/filesystem.md` section 2.1: containment against a hostile program
  is a sandbox's job). Until workers run in an OS sandbox, a worker is
  trusted *not to be malicious*, only to be *possibly wrong*. State this
  to the operator.
* **Side channels, denial of service by the operator's own machine,
  physical access.**
* **Tamper-evident storage and signing.** Deferred per the design document.
* **Hardware durability.** On macOS `file_sync` does not flush the drive's
  cache (`docs/file-writes.md` section 6); only Linux was measured.

## 6. Residual risks to carry into M1

1. T14: the trap-on-violation backstop kills Forge. Needs a checked
   alternative from cancho or discipline in the policy layer (G2).
2. T5 and G3: group kill requires starting workers detached
   (`exec_spawn_detached`); it no longer needs `Exec` access to
   `/bin/kill` (corrected after cancho #533).
3. Compile-time-only narrowing (G1) means workspace and worker directories
   are fixed in the binary; per-task scope is policy, not capability.
4. Orphaned workers after a Forge crash (G4) are only detectable by pid.
