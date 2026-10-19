# cancho-forge

**An agent-run software company you can audit.**

Agent workflows have capable workers and no durable operating system around
them: plans disappear into chats, a worker is often the only judge of its own
work, and limits live in prompts. cancho-forge is the missing company-level
runtime. State, budgets, approvals and evidence are kept by the runtime, and a
worker such as [cancho-code](https://github.com/alpibrusl/cancho-code) only
proposes and executes.

```
[WORKER]          mock         running
  normal          worker_claims_succeeded   -> verification (not accepted)
  hang (500 ms)   worker_timeout            child killed and reaped
[AUTHORITY]       dispatcher   exec("/tmp/cancho-forge-spike/bin")   no filesystem, no network
```

- **A worker cannot accept its own work.** A reported success only moves a task
  to verification. Acceptance needs checks Forge ran itself.
- **Authority is a capability, not a request.** Each worker is given an `Exec`
  narrowed to its own programs; `cancho authority` prints what the dispatcher
  and the worker can reach.
- **One append-only journal.** Recovery cuts only a torn last line, and refuses,
  changing nothing, when a complete line is wrong.
- **Loops and workers stop.** Deadlines and output bounds end a hung or
  runaway worker, named, and the child is reaped.
- **Written entirely in [cancho](https://github.com/alpibrusl/cancho).** No
  Python, no Rust and no shell in the product.
- **Measured, at Milestone 0** (Linux x86_64, a mock worker): a 300 ms deadline
  ended in 301 ms; a runaway output was stopped at exactly 1,000 bytes; a torn
  journal tail was cut from 165 to 140 bytes and a second recovery changed
  nothing; five ways of a worker ending were each classified. Nothing here runs
  a company yet. Not measured: macOS, a real cancho-code, several workers at
  once, power loss. Conditions and caveats:
  [`spike/RESULTS.md`](spike/RESULTS.md).

**[Project page](https://alpibrusl.github.io/cancho-forge)** ·
[Architecture](docs/architecture.md) ·
[Worker contract](docs/worker-contract.md) ·
[Roadmap](docs/roadmap.md)

## Try it

You need the [cancho](https://github.com/alpibrusl/cancho) compiler, at the
revision named in `cancho.toml`, and `clang`.

```sh
git clone https://github.com/alpibrusl/cancho-forge.git && cd cancho-forge
export CANCHO=<path-to-the-cancho-binary>
scripts/gate.sh        # fmt --check, check, test, file budget  ->  gate: PASS
spike/run.sh           # re-runs every spike and prints the evidence
```

Read [`spike/RESULTS.md`](spike/RESULTS.md) first: it lists what cancho cannot
do yet that shapes the later milestones (grants fixed at build time, a kill
that reaches one pid, orphaned workers after a crash).

## More

[Threat model](docs/threat-model.md) · [Architecture](docs/architecture.md) ·
[Worker contract](docs/worker-contract.md) · [Roadmap](docs/roadmap.md) ·
[Working rules](CLAUDE.md)

EUPL-1.2.
