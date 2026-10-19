---
name: cancho-forge
description: Work on cancho-forge, a persistent runtime for an agent-operated software company written entirely in cancho: its task state machine, append-only journal, worker contract and spikes. Use when the user wants to run, check or extend cancho-forge, or to understand what it enforces (a worker cannot accept its own work).
---

# cancho-forge

cancho-forge keeps company state, budgets, approvals and evidence in the runtime, so a worker (such as cancho-code) proposes and executes but cannot mark its own work accepted or widen its authority. It is written in cancho only: nothing Forge decides, stores or enforces is written in another language.

## Rules (always)

- Never use `sudo`. Do not install system packages without asking.
- Paths that go into a shell command may hold only letters, digits and `. _ / + : = @ % , -`.
- Do not retry a failing command in a loop, and do not edit the repository to make a command pass. Report what failed, with the exact error.
- Python or shell is for test oracles and the gate only, never product logic. Every refusal has a stable rule tag, documented in `docs/architecture.md`, and a test that reaches it. No input may reach a trap.
- The compiler is pinned: `.cancho-rev` and `cancho.toml` must name the same revision. Do not bump it without re-running the gate and `spike/run.sh`.
- Do not claim more than was measured. Only Linux x86_64 has been run, and no real cancho-code run with a model.

## 1. Install (once)

Follow `docs/agent-prompt.md` in the cancho-forge repository: clone `cancho-forge` and `cancho` side by side, check out the compiler at the commit in `cancho-forge/.cancho-rev`, build it, export `CANCHO`, and run `sh scripts/gate.sh` (it must end `gate: PASS`).

## 2. Change something

Design before code, in `docs/`, with claims measured; a claim that turns out false is corrected in place. Then change `src/` and add tests under `tests/` (`cancho test`); file behaviour is covered by `tests/conformance/journal_files.cho`, which the gate builds and runs. Run the gate before calling anything done.

## 3. What it enforces

- A task moves only along the 18 legal edges of `src/task.cho`; only a Forge-observed event can move it to `accepted`.
- The journal (`src/journal.cho`) replays into task state, cuts only a torn last line, and refuses, changing nothing, on a corrupt complete line.
- `cancho authority` on a program is the review artefact: a change that widens a program's authority says so in its commit message.

## More

`README.md`, `spike/RESULTS.md`, `docs/worker-contract.md`, `docs/cancho-code-audit.md`, `docs/roadmap.md`, `docs/threat-model.md`.
