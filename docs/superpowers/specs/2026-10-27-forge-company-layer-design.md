# Forge company layer, and StatusLite as its first company

**Status:** design for approval, 2026-10-27. Nothing here is built. Facts about the repositories were read from their READMEs, `CLAUDE.md`, `docs/roadmap.md` and `docs/worker-contract.md` (Forge) and from lex-loom's README, `docs/design/agentic-company.md` (head), `examples/linksnap.company.toml` and the `create-company` skill. lex-loom's code was not read. Measured facts come from this session's runs and are marked as such. Choices I made, not the owner, are marked **(my call)**.

## 1. Intent and why

Alfonso wants a Forge "company" that builds something that could be a small real product, with roles that are not all coders, using Claude Haiku 5.5, and wants the Forge and Cancho Code integration to improve along the way. The semantic contract (`alpibrusl/cancho-contract`, proposal revision 3) is to be adopted only if it gives a measured advantage.

lex-loom is an earlier attempt at the same idea (autonomous companies with role packs, a manifest, human gates, budgets). Its own write-up says its companies shipped with no real users because every decision was one model reading another model's verdict. Forge starts from an audited core (journal, task state machine, independent verification) and has no company layer. This design brings loom's *shape* (a manifest, role packs, human gates, budgets) into Forge on Forge's terms: a worker's success is never acceptance, authority is never declared by a document, and every refusal has a rule tag.

The product, **StatusLite**, is a small self-hosted uptime and status page tool. It is the first company the layer runs. It is a test of the layer first and a product second.

## 2. Goals, non-goals, anti-goals

**Goals**
1. A company manifest Forge validates before anything runs, with named refusals.
2. A runner that turns the manifest's steps into Forge tasks in dependency order, dispatches each to the worker its role maps to, and records everything in the existing journal.
3. Human gates that block a step until a recorded decision.
4. A budget that stops the company, derived from recorded token usage.
5. At least three roles that are not "builder" working end to end: QA (independent audit), analyst (data tool), reviewer (authority check). A writer is a stretch goal.
6. StatusLite built by that company with Haiku, scored by an audit the builder never sees.
7. A measured A/B of the Cancho Code `--contract` signatures against the brief alone on StatusLite's units, reported with every run and failure. The semantic contract format is adopted only if a second A/B (see section 8) shows an advantage over signatures.

**Non-goals (not in this project)**
- A scheduler daemon, an LLM "CEO", strategy or pivot loops, revenue, deployment, monetization, or running several companies at once.
- Replacing Forge's journal or state machine.
- The full semantic contract validator (`cancho-contract` is separate work).

**Anti-goals (failure even if it "works")**
- A step accepted because its worker said `done`.
- An LLM writing the audit that grades its own output.
- A manifest field that grants a capability.
- A result reported as a company success when a human did the work by hand and the journal does not show it.

## 3. Constraints

- Forge is written in cancho only; no other language in product logic. Python is allowed for test oracles only (`CLAUDE.md`).
- No source file over 2,000 lines. `src/main.cho` is already 941 and `verbs.cho` 742; new code goes in new files.
- Every refusal has a documented rule tag and a test that reaches it. No input may reach a panic.
- The gate (`scripts/gate.sh`) must pass. A change that widens a program's authority says so in its commit message and updates the checked-in `cancho authority` report.
- The compiler pin in `cancho.toml` and `.cancho-rev` is not bumped without re-running the spikes and the gate.
- Today Forge has two worker adapters (`workers/cancho_code.cho`, `workers/gate_runner.cho`) plus a stub. The README says objectives, artifacts, policy, budgets and verification are not built.
- Haiku through the Anthropic key at `~/.config/cancho-code/anthropic.key`. Measured this session: ten Forge-adapter runs cost about $0.29 in total.

## 4. The design

### 4.1 The manifest

A JSON file, `company.json` **(my call: JSON, because Forge already parses JSON and has no TOML parser)**, parsed against a closed shape. Fields:

- `id`, `mission` (the product brief in words, kept for the record; it does not drive anything by itself).
- `model`: provider and model name for model-driven steps.
- `budget`: a ceiling in tokens by kind (input, output, cache write, cache read) and a derived-cost ceiling using a price table file the operator names. Cost is derived, never worker-reported.
- `human_gates`: a list of named gates.
- `roles`: the role packs in use (section 4.2).
- `steps`: an ordered list of `{id, role, task_type, needs[], input, check, gate?}`.

The manifest declares requirements only. It cannot widen a worker's authority; what a worker can reach stays what its binary is granted (`cancho authority`). A mismatch between what a step needs and what its worker adapter offers is refused at validation.

### 4.2 Role packs

A role is a name mapped to a worker adapter, a task type and a default check. A pack is a named set of roles.

| Role | Worker | Task type | Independent check |
|---|---|---|---|
| builder | `workers/cancho_code.cho` (exists) | `project.build` | a Forge-run audit program supplied with the step, never shown to the builder |
| qa | `workers/gate_runner.cho` (exists) | `repo.gate` | the gate itself is deterministic |
| analyst | new `workers/tool_run.cho` | `tool.run` | Forge re-runs the same query and compares output hashes (forge#41) |
| reviewer | the gate runner with an authority-report step | `repo.gate` | compare `cancho authority` output to the checked-in ceiling |
| writer (stretch) | the builder adapter on a docs brief | `project.build` | length, required sections and links, checked by a Forge-run program; a person reads it before the gate opens |
| product | a person | none | the `product-brief` human gate |

Only the first two adapters exist today. `tool_run` is new in this design and is the second milestone's work.

### 4.3 The runner

`forge company check <dir>` validates the manifest and prints rule-tagged refusals. `forge company run <dir>` admits each step as a Forge task, in dependency order, dispatches it, records the outcome, and stops at a human gate. `forge company decide <dir> <gate> approved|rejected <reason>` records a decision. `forge company status <dir>` shows steps, states, spend and open gates, read-only.

Rules the runner follows:
- A step starts only when everything it needs is `accepted` (not merely `done`).
- A step becomes `accepted` only after its check, run by Forge, passes against the artifact Forge hashed itself.
- A step with a gate does not start until the gate has an `approved` decision in the journal.
- If the budget ceiling is crossed, no new step starts and the company ends in a named state, `budget-exhausted`.
- Resuming after a crash replays the journal and continues; steps already accepted are not rerun.

### 4.4 Refusals (names to be documented with their tests)

`manifest-malformed`, `manifest-unknown-field`, `step-id-duplicate`, `step-needs-unknown`, `step-cycle`, `role-unknown`, `task-type-unsupported`, `check-missing`, `gate-unknown`, `budget-missing`, `price-table-missing`, `budget-exhausted`, `gate-open`, `check-failed`, `check-unavailable`. These are proposals; the final list is settled in the plan.

### 4.5 StatusLite (the first company)

**What it is.** A small program that reads probe results and produces (a) uptime percentages and latency percentiles per service over a window and (b) a static status page. It is written in cancho, built by Cancho Code.

**Scope for the first company run (my call, because network capability for the Cancho builds is unmeasured):**
1. Library units: a check-result record and its line format, window selection, uptime percentage with explicit rounding, percentile (nearest-rank), status classification, HTML status page rendering.
2. A command-line program that reads a file of check results and writes the page and a JSON summary.
3. The prober (HTTP checks) is a later stretch step; the first run uses recorded or synthetic check logs.

**Definitions the product owner must fix before building** (these are where brief-only builds were observed to go wrong): what counts as down; how a window boundary is treated; rounding of uptime; percentile method; what the page shows for a service with no data. These live in the brief and, for the A/B, as required signatures.

**Where it lives (my call):** a new repository, `alpibrusl/statuslite`, private. The company's manifest and its run artifacts live there; Forge lives in `cancho-forge`.

### 4.6 The contract question

- **Arm A:** brief only. **Arm B:** brief plus required signatures (the existing `--contract`). Both on StatusLite's library units, Haiku, several runs each, scored by the hidden audit.
- **Arm C (only if B shows a gap left to close):** the semantic contract from `alpibrusl/cancho-contract` proposal revision 3, hand-authored for the pilot units, passed as the proposal describes. Not built until arms A and B are measured.
- The contract is adopted for Forge only if arm C beats arm B on the hidden audit or on a recorded secondary measure (for example, a requirement that is traceable to a check), at an authoring cost that is recorded.

## 5. How this improves the Forge and Code integration

Work that falls out of the layer and that I expect to need, each listed so it can be accepted or dropped:
- `provider_error` is currently also reported for a build that failed because of its environment (cancho-code#92, now fixed), and for a model that ran out of tokens (seen with the qwen models this session). The adapter should map a cut-off to its own outcome. Not yet filed as an issue.
- The adapter's `--jobs` default and its empty environment, now consistent after cancho-code#93.
- The adapter takes a `contract` input so a step can pass signatures. Today it takes only the brief.
- The adapter records usage per step so the budget has something to read. Usage already lands in `usage.jsonl`; Forge does not read it yet.

## 6. Order of work

This is three projects; they are done in this order, each with its own gate and measurement.
1. **Company layer v0:** manifest, validation, step graph, status (no workers). Gate passes. Offline.
2. **Company layer v1:** run steps through the builder and gate adapters, human gates, budget, resume. Stub worker first, then Haiku. Add `tool_run` for the analyst role.
3. **StatusLite:** repository, brief and definitions, hidden audit, then the company run, then the A/B.

## 7. Success, and how it is checked

- The manifest for StatusLite validates; a deliberately broken one is refused with the right tag for each refusal in 4.4.
- A stub-worker run reaches the end with every step in the journal, including a blocked gate that unblocks only after `decide`.
- A real run with Haiku: the number of units accepted, the hidden-audit score of the final program, wall time, tokens and derived cost, all from stored files.
- A kill in the middle of a run followed by `run` again completes without rerunning accepted steps, and leaves no stray process.
- A worker's `done` with a failing check never produces `accepted` (a test with a lying stub worker).
- The A/B table with every run and failure, not only the successes. Samples are small; the report says so.

## 8. What is left to the builder

File layout inside the 2,000-line budget; the exact JSON shape; the final refusal list; the price-table format; how `tool_run` finds its tool (follow the `exec_covers` pattern the other adapters use).

## 9. Open items for the owner

1. Create `alpibrusl/statuslite` as a private repository? (my call: yes)
2. A spending ceiling for the whole experiment, in dollars. (my call: $10 total, with the first full Haiku run capped at $2)
3. The StatusLite definitions in section 4.5 (what counts as down and so on). I will propose values for review.

## 10. Calls made after the builder check

A fresh reader asked ten questions. Most are settled here as my calls; the two that are the owner's are in section 11.

**Data flow (questions 1, 2).** The step graph is static and hand-written in `company.json`; no fan-out. A builder step is one `cancho-build` over one brief (a library or the CLI), so StatusLite has about five to six builder steps. `check` names an audit program in the company directory plus a pass rule; **pass means the audit's score equals its total** (all cases), and a score below that is `check-failed`. `needs` passes the accepted artifact's path and its sha256, both recorded in the journal; a downstream step receives them as inputs. "Units accepted" in section 7 means accepted steps.

**Budget (question 3).** Reading `usage.jsonl` is required in part 2, not optional: the budget cannot work without it. Budgets are checked between steps; a running step is not killed when the ceiling is crossed and may overshoot, which the report states. The budget covers model-driven steps only (deterministic steps cost no tokens). `budget-exhausted` is tested offline with a stub worker that writes a `usage.jsonl`.

**Gates (question 4).** One operator on one machine: `decide` does not authenticate and the journal records who ran it as the operating-system user name plus the reason. This is not an access control and the document does not claim it is. `rejected` leaves the gated step and its dependents `blocked` and ends the run as `gate-rejected`; a later `approved` for the same gate is allowed and recorded, so a decision is changed by a new entry, never an edit.

**Retry (question 5).** No retry at the Forge level in v1. A failed check ends the step as `check-failed` and the company waits for a person. The builder keeps its own internal retries (its plan examples and compiler checks), which is how Cancho Code works today. **The audit result is never fed back to the builder**, so the A/B is not contaminated.

**Reviewer vs QA (question 6).** The reviewer is distinct only if the gate runner can run `cancho authority` and compare to a ceiling file in the company directory. I have not checked that it can. If it cannot, the reviewer role is dropped from this project and goal 5 becomes "QA and analyst, plus the product gate", which I would state as not met rather than rename QA.

**Analyst (question 7).** In StatusLite the analyst recomputes the headline numbers independently of the product, from the same check-log file, with `cancho-tools` programs (`tally` and `jsonq`, which exist and are tested) and compares them to the product's JSON summary. This covers counts and uptime percentage. I do not know whether those tools can produce percentiles; if not, percentiles stay covered by the hidden audit only and the report says so. `tool.run` needs deterministic output, which these tools promise (same bytes every time, per the `cancho-tools` README). forge#41 is the proposal for this adapter.

**Key and environment (question 8).** Measured this session: the builder adapter reads the API key from a file path in the agent command (`--key-file`), so an empty environment does not block it. Ten Forge-adapter runs with Haiku worked this way.

**Budget measured against what (question 9).** The $10 covers everything in the experiment: the company run and the A/B. Runs per arm: three, on three library briefs, for two arms (brief, brief plus signatures), about 18 builds. From the measured ten runs costing about $0.29, that is expected to be well under $10, but the StatusLite briefs are unmeasured.

**Scope of section 5 (question 10).** In scope: the adapter's `contract` input and per-step usage reading. Optional: mapping a cut-off model to its own outcome instead of `provider_error`. Changes in `cancho-code` are made as separate pull requests and merged only on the owner's go.

## 11. Open items that are the owner's

1. The total spending ceiling ($10 proposed, with the first full run at $2) and the sample size (three runs per arm proposed).
2. Whether the changes to `cancho-code` that this needs (the `contract` input and any usage fields) may be opened as pull requests there.
