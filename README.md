# Cancho Forge

A persistent runtime for an agent-operated software company: durable
state, explicit authority, budgets, approval gates, evidence and an audit
journal around specialised workers such as Cancho Code. The idea and the
milestone roadmap are the design document this repository grew from; the
parts that survived contact with the compiler are in `docs/`.

**Written entirely in [cancho](https://github.com/alpibrusl/cancho).** No
Python, no Rust, no shell in the product. Authority is enforced by the
language's capabilities, and `cancho authority` prints what each program
can reach.

## Status: Milestone 0 (architecture and interface audit)

Nothing here runs a company yet. What exists:

| | |
|---|---|
| `docs/architecture.md` | The decision to build Forge in cancho, how each subsystem maps onto std and capabilities, the journal design, the authority model |
| `docs/worker-contract.md` | The versioned worker contract (v1): `capabilities`, `execute`, `cancel`, `status`, `result`, JSON over stdio or files |
| `docs/threat-model.md` | Assets, adversaries, sensitive actions, approval boundaries |
| `docs/roadmap.md` | Milestones M1-M7, adapted to what M0 measured |
| `spike/` | Real cancho programs that measure whether the platform can carry Forge, and `spike/RESULTS.md`: what worked, what did not, exact commands and outputs |
| `src/event.cho`, `tests/event_test.cho` | The one piece of product code so far: the journal record, with tests |

Read `spike/RESULTS.md` first: it lists the gaps in cancho that block or
shape later milestones.

## Build, test, run the spikes

You need the cancho compiler (see `cancho.toml` for the revision these
sources were written for), `clang` and `cc`, on Linux or macOS. Only Linux
x86_64 has been measured so far.

```sh
export CANCHO=/path/to/cancho            # or have `cancho` on PATH
scripts/gate.sh                          # fmt --check, check, test, file budget
$CANCHO build && ./build/forge           # prints one sample journal record
spike/run.sh                             # re-runs every spike, prints the evidence
```

## Layout

```
cancho.toml     package, binary, test sets, compiler pin
src/            product code (cancho)
tests/          cancho tests (`fn test_*`, run by `cancho test`)
docs/           design, written before code, with measured claims
spike/          M0 measurements; RESULTS.md is the record
scripts/gate.sh the gate
```

## Licence

EUPL-1.2, as cancho. See `LICENSE` and `NOTICE`.
