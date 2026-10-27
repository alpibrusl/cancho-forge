# Forge Company Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `forge company check|run|decide|status` runs a manifest of steps through Forge's existing workers, with human gates, a token-derived budget and acceptance only by a Forge-run check.

**Architecture:** Pure modules (`company_manifest`, `company_graph`, `company_state`, `company_budget`, `company_check`) hold every decision and are unit-tested offline; one IO module (`company_cmd`) wires them to the CLI. Step tasks go through the existing `build`/`gate` machinery and the task journal. Company-level facts (step admitted, check result, gate decision, spend) go in a separate `company.journal` in the company directory, using `event.record` framing and the existing torn-tail recovery.

**Tech Stack:** cancho (compiler pinned in `cancho.toml` / `.cancho-rev`), `cancho test` sets in `cancho.toml`, JSON via `std.json`. No other language in product logic.

**Spec:** `docs/superpowers/specs/2026-10-27-forge-company-layer-design.md` (sections 10 and 11 are the decisions made after the builder check). Also not covered: the reviewer role (spec section 10 makes it conditional on the gate runner being able to run `cancho authority` and compare to a ceiling; unchecked, so no task yet), and the writer role (stretch). Not covered here, planned separately: the StatusLite repository, brief and audit, and the contract A/B.

## Global Constraints

- cancho only in product logic; Python only as a test oracle (`CLAUDE.md`).
- No `.cho` file over 2,000 lines; `src/main.cho` is 941, so new logic goes in new files.
- Every refusal has a rule tag documented in `docs/company.md` and a test that reaches it. No input may reach a panic.
- `scripts/gate.sh` passes before any task is called done. Compiler pin is not bumped.
- A change that widens a program's authority says so in its commit message and updates `docs/authority.txt`.
- A worker's `done` never produces `accepted`; only a Forge-run check does (spec 4.3).
- Manifest is JSON, closed shape, unknown field refused (spec 4.1). The manifest never grants authority.
- Refusal tags (spec 4.4): `manifest-malformed`, `manifest-unknown-field`, `step-id-duplicate`, `step-needs-unknown`, `step-cycle`, `role-unknown`, `task-type-unsupported`, `check-missing`, `gate-unknown`, `budget-missing`, `price-table-missing`, `budget-exhausted`, `gate-open`, `gate-rejected`, `check-failed`, `check-unavailable`.
- Step passes only if audit score equals its total (spec 10). `decide` records OS user and reason, authenticates nothing (spec 10).

## Review Focus

- Empty `steps` list, or a step that `needs` itself: refused (`step-cycle`), never a loop.
- A manifest of 1 MB or a step id with control characters: refused as `manifest-malformed`, no trap.
- Journal torn in the middle of a `gate.decided` record: recovery drops it and the gate reads as open.
- Audit program that prints no score, a negative score or a score above total: `check-unavailable`, not `accepted`.
- `decide` run twice with `approved` then `rejected`: the last entry wins and both are in the journal.

---

### Task 1: Manifest parsing and validation

**Files:**
- Create: `src/company_manifest.cho`, `tests/company_manifest_test.cho`, `tests/fixtures/company/{good,dup-step,cycle,unknown-field}.json`
- Modify: `cancho.toml` (add `[[test]] name = "company_manifest"`)

**Interfaces:**
- Produces: `pub enum Refusal` (one variant per manifest-level tag in Global Constraints), `pub fn rule_name(r: Refusal) -> [] &static [byte]`, `pub struct Step { id, role, task_type, needs, input, check, gate }` and `pub struct Manifest`, `pub fn parse[&h, &t](heap: &!h Heap, text: &t [byte]) -> [heap] ManifestResult` where `ManifestResult` is `Held(Manifest)` or `Refused(Refusal)`.
- Fields per spec 4.1: `id`, `mission`, `model{provider,name}`, `budget{input,output,cache_write,cache_read,max_cost,price_table}`, `human_gates[]`, `roles[]`, `steps[]`.

- [ ] **Step 1: Write failing tests** in `tests/company_manifest_test.cho`: `good.json` parses; `dup-step.json` gives `"step-id-duplicate"`; `cycle.json` (a needs b, b needs a) gives `"step-cycle"`; `unknown-field.json` gives `"manifest-unknown-field"`; a step with role `"cook"` gives `"role-unknown"`; a builder step without `check` gives `"check-missing"`; text `"{"` gives `"manifest-malformed"`; empty steps gives `"manifest-malformed"`.
- [ ] **Step 2: Run** `cancho test` for the `company_manifest` set. Expected: FAIL, module not found.
- [ ] **Step 3: Implement** `parse` and `rule_name` in `src/company_manifest.cho`, role names fixed to `builder, qa, analyst, reviewer, writer, product`, task types to those in spec 4.2. Cycle detection may reuse Task 2's function once it exists; until then a bounded depth walk.
- [ ] **Step 4: Run** the set again. Expected: PASS.
- [ ] **Step 5: Commit** `git add src/company_manifest.cho tests cancho.toml && git commit -m "company: manifest parse and validate"`.

### Task 2: Step graph

**Files:**
- Create: `src/company_graph.cho`, `tests/company_graph_test.cho`
- Modify: `cancho.toml`, `src/company_manifest.cho` (call `has_cycle` instead of the bounded walk)

**Interfaces:**
- Consumes: `Manifest`, `Step` from Task 1.
- Produces: `pub fn has_cycle(m: &Manifest) -> [] bool`, `pub fn ready[&a](m: &Manifest, accepted: &a [bool]) -> [] option.Option[int]` returning the index of the first step whose every `needs` is accepted and which is not itself accepted, `pub fn index_of[&i](m: &Manifest, id: &i [byte]) -> [] int` (-1 if absent).

- [ ] **Step 1: Failing tests:** chain a→b→c yields ready order 0,1,2 as each is marked accepted; diamond yields the second branch only after the first joins; self-need and 2-cycle give `has_cycle` true; nothing ready when all accepted gives `None`.
- [ ] **Step 2: Run** the set. Expected: FAIL.
- [ ] **Step 3: Implement** the three functions in `src/company_graph.cho`; deterministic (lowest index first).
- [ ] **Step 4: Run** the set and `company_manifest`. Expected: PASS.
- [ ] **Step 5: Commit** `company: step graph`.

### Task 3: Company journal and replay

**Files:**
- Create: `src/company_state.cho`, `tests/company_state_test.cho`
- Modify: `cancho.toml`

**Interfaces:**
- Consumes: `event.record`, `event.seq_of` (`src/event.cho`); journal append and torn-tail recovery from `src/journal_io.cho` and `src/recover.cho` (read their signatures first and reuse them for the `company.journal` file; do not copy them).
- Produces: event kinds `company.step.admitted` (step id, task id), `company.step.accepted` (artifact path, sha256), `company.step.check_failed` (score, total), `company.gate.decided` (gate, verdict `approved|rejected`, user, reason), `company.spend.recorded` (step id, input, output, cache_write, cache_read); `pub struct CompanyState { accepted: [bool], gates: ..., spend: ... }`; `pub fn replay[&h, &t](heap: &!h Heap, journal_text: &t [byte], m: &Manifest) -> [heap] CompanyState`; `pub fn gate_state[&g](s: &CompanyState, gate: &g [byte]) -> [] int` (0 open, 1 approved, 2 rejected; last entry wins).

- [ ] **Step 1: Failing tests:** replay of a hand-built journal yields the right accepted flags; a journal cut mid-record in the last `company.gate.decided` leaves that gate open; `approved` then `rejected` for one gate gives 2; unknown `kind` is ignored; `seq` gap is a refusal consistent with the task journal's.
- [ ] **Step 2: Run** the set. Expected: FAIL.
- [ ] **Step 3: Implement** `company_state.cho`. Recovery behaviour must match the task journal (cut only a torn last line; refuse a complete wrong line).
- [ ] **Step 4: Run** the set. Expected: PASS.
- [ ] **Step 5: Commit** `company: journal events and replay`.

### Task 4: `forge company check` and `status`

**Files:**
- Create: `src/company_cmd.cho`, `tests/company_cmd_test.cho` (pure formatting functions only)
- Modify: `src/main.cho` (one dispatch line next to `"gate"`/`"build"` at ~line 894), `cancho.toml`

**Interfaces:**
- Consumes: Tasks 1 to 3.
- Produces: `pub fn check_cmd(...) -> [<exact row>] int` and `pub fn status_cmd(...) -> [<exact row>] int` in `company_cmd.cho` (read-only effect rows only: `fs_read`, `io_write`); `pub fn status_text[&h](heap: &!h Heap, m: &Manifest, s: &CompanyState) -> [heap] buffer.Buffer` (pure, tested). Exit codes: 0 valid, 1 refused (rule tag printed as `refusal: <tag>`), 2 usage.

- [ ] **Step 1: Failing tests** for `status_text`: one line per step `id state`, then `spend` and `open gates`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** `status_text`, `check_cmd`, `status_cmd`; add the dispatch in `main.cho`. Read-only: `status` must not take the writer lock.
- [ ] **Step 4: Run** the set; then run `forge company check tests/fixtures/company/good.json` by hand. Expected: exit 0.
- [ ] **Step 5: Commit** `company: check and status verbs` (message states the authority is read-only).

### Task 5: Gates and `decide`

**Files:**
- Modify: `src/company_cmd.cho`, `src/company_state.cho`, `tests/company_state_test.cho`

**Interfaces:**
- Consumes: Task 3 events.
- Produces: `pub fn decide_cmd(...) -> [<row incl. fs_write>] int`; takes lock, appends `company.gate.decided`; refuses an unknown gate with `gate-unknown`; user name from the process environment value the OS user provides (record `"unknown"` if absent, never fail). `pub fn step_blocked_by_gate(m: &Manifest, s: &CompanyState, step: int) -> [] int` returning 0 free, 1 `gate-open`, 2 `gate-rejected`.

- [ ] **Step 1: Failing tests:** step with open gate gives 1; after `approved` gives 0; after `rejected` gives 2; dependents of a rejected-gated step are not ready (graph `ready` plus this function).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** the two functions and `decide_cmd`; usage `forge company decide <dir> <gate> approved|rejected <reason>`.
- [ ] **Step 4: Run** the set, then do an approve then reject then approve sequence by hand on a temp dir and read the journal. Expected: three entries, last wins.
- [ ] **Step 5: Commit** `company: human gates and decide`.

### Task 6: Budget

**Files:**
- Create: `src/company_budget.cho`, `tests/company_budget_test.cho`
- Modify: `cancho.toml`

**Interfaces:**
- Produces: `pub struct Prices { input, output, cache_write, cache_read }` (micro-dollars per million tokens, integers), `pub fn parse_prices[&h, &t](heap: &!h Heap, text: &t [byte], model: &static [byte]) -> [heap] option.Option[Prices]` reading the repo's `eval/prices.json` shape from cancho-code (read that file first and pin the field names in the test), `pub fn parse_usage[&t](text: &t [byte]) -> [] Usage` summing the `in`, `out`, `cache_write`, `cache_read` fields of `usage.jsonl` lines (malformed lines skipped and counted), `pub fn cost_micro(u: Usage, p: Prices) -> [] int`, `pub fn exhausted(spent: Usage, limits: Limits, cost_micro: int, max_cost_micro: int) -> [] bool`.

- [ ] **Step 1: Failing tests:** known usage and price give a cost computed by hand in the test (assert the exact integer); one token over a limit gives `exhausted` true; malformed usage line is skipped, not a trap; missing price for the model gives `None`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** with integer arithmetic only.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `company: token-derived budget`.

### Task 7: Check runner

**Files:**
- Create: `src/company_check.cho`, `tests/company_check_test.cho`
- Modify: `cancho.toml`

**Interfaces:**
- Produces: `pub fn parse_score[&t](text: &t [byte]) -> [] ScoreResult` reading the last line of the form `TOTAL a/b` (the format `eval/audit_*.py` prints), `ScoreResult` is `Score(int, int)` or `Unavailable`; `pub fn verdict(r: ScoreResult) -> [] int` (0 pass when `a == b` and `b > 0`, 1 `check-failed`, 2 `check-unavailable`). The IO wrapper that runs the audit program belongs in Task 8.

- [ ] **Step 1: Failing tests:** `"TOTAL 221/221"` passes; `"TOTAL 117/221"` is 1; empty text, `"TOTAL -1/5"`, `"TOTAL 6/5"`, `"TOTAL 0/0"` are 2.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** `parse_score` and `verdict`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `company: audit score parsing`.

### Task 8: `forge company run`

**Files:**
- Modify: `src/main.cho` (extract the body of `build` into a function taking a spec struct instead of `Args`, behaviour unchanged; existing tests must still pass), `src/company_cmd.cho`
- Test: `tests/company_run_test.cho` (pure scheduling step function), plus a stub-worker script test in `tests/conformance/`

**Interfaces:**
- Consumes: Tasks 1 to 7; `src/stub_script.cho` for the stub worker.
- Produces: `pub fn next_action(m: &Manifest, s: &CompanyState, limits: ..., spent_cost_micro: int) -> [] Action` with `Action` = `Start(int)`, `WaitGate(int)`, `Blocked(int)`, `Stop(<tag>)`, `Done`; `pub fn run_cmd(...)` loops: replay, `next_action`, run the step (builder through the extracted build function, qa through the gate function), run the step's `check` program with a narrowed `Exec`, append events, repeat.

- [ ] **Step 1: Failing tests** for `next_action`: step with open gate gives `WaitGate`; budget exhausted gives `Stop("budget-exhausted")` before any new step starts; all accepted gives `Done`; rejected gate gives `Blocked`.
- [ ] **Step 2: Failing conformance test** with a stub worker that always reports `done` and a check program that prints `TOTAL 1/2`: the run ends `check-failed` and the step is not `accepted` (the lying-worker test, spec 7).
- [ ] **Step 3: Run** both. Expected: FAIL.
- [ ] **Step 4: Implement** `next_action`, the refactor and `run_cmd`. Resume: running twice must not rerun an accepted step (assert by counting `company.step.admitted` per step id).
- [ ] **Step 5: Run** `scripts/gate.sh`. Expected: `gate: PASS`, including the existing build/gate tests after the refactor.
- [ ] **Step 6: Commit** `company: run steps, check and resume` (message states the added `fs_write` and `exec` rows).

### Task 9: Kill and resume

**Files:**
- Create: `tests/conformance/company_kill.sh` is a test oracle only; the program under test is `forge`.
- Modify: `scripts/gate.sh` to include it.

**Interfaces:** consumes `run_cmd`.

- [ ] **Step 1: Write the oracle:** start `forge company run` against the stub manifest with a slow stub, `kill` the process group mid-step, run again, assert every step is `accepted` exactly once and `ps` shows no stray stub process.
- [ ] **Step 2: Run** the oracle. Expected: FAIL or hang until Task 8 is correct; fix `run_cmd` only, not the oracle.
- [ ] **Step 3: Run** `scripts/gate.sh`. Expected: PASS.
- [ ] **Step 4: Commit** `company: kill and resume conformance`.

### Task 10: Builder step takes a contract

**Files:**
- Modify: `src/build_task.cho`, `workers/cancho_code.cho`, `tests/build_task_test.cho`

**Interfaces:**
- Produces: an optional `contract` path in a `project.build` task input, passed to `cancho-build` as `--contract <path>`, refused as `contract-path-invalid` when it is not under the execution directory (follow the existing `path_ok` rule in `gate_task.cho`).

- [ ] **Step 1: Failing tests:** argument vector contains `--contract <path>` when given and not otherwise; `../x` is refused with the tag.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** in `build_task.cho` and wire it in the worker.
- [ ] **Step 4: Run** `cancho test` and `scripts/gate.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `adapter: pass a contract file to cancho-build`.

### Task 11: Analyst worker `tool_run`

**Files:**
- Create: `workers/tool_run.cho`, `src/tool_task.cho`, `tests/tool_task_test.cho`, `docs/authority-tool-run.txt`
- Modify: `cancho.toml`, `scripts/gate.sh` (authority check for the new worker)

**Interfaces:**
- Produces: task type `tool.run`; input is a tool name from an operator-granted list, its argv as a JSON array (never shell text) and an input path under the execution directory; evidence is bounded stdout, exit code and the tool's own authority manifest hash (forge#41). Follow `build_task.cho` for the check/refusal pattern and `exec_covers` for tool lookup.

- [ ] **Step 1: Failing tests:** an unlisted tool is refused `tool-not-granted`; argv with a non-string element is refused `argv-malformed`; a path escaping the execution directory is refused; stdout over the cap is truncated and marked.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** `tool_task.cho` (pure checks) and the worker. Confirm with the tool's own `introspect` that `cancho-tools` `tally` and `jsonq` run under this adapter against a fixture and record the result in `docs/company.md`; if percentiles are unavailable, say so there.
- [ ] **Step 4: Run** `scripts/gate.sh`. Expected: PASS with the new authority report checked in.
- [ ] **Step 5: Commit** `workers: tool.run for deterministic data tools` (message states the worker's exact authority).

### Task 12: Documentation

**Files:**
- Create: `docs/company.md`
- Modify: `docs/architecture.md` (Refusals table), `README.md` (one status line, no claim that Forge "runs a company" beyond what Task 8 measured), `docs/roadmap.md`

- [ ] **Step 1: Write `docs/company.md`:** manifest shape with an annotated example, role table, every refusal tag with one sentence and the test that reaches it, the company-journal note (a separate file; this corrects spec 4.3's "existing journal" in the spec with this commit), and what is not measured.
- [ ] **Step 2: Correct the spec in place** (`docs/superpowers/specs/...`, section 4.3) to say step tasks use the task journal and company facts the company journal.
- [ ] **Step 3: Run** `scripts/gate.sh`. Expected: PASS.
- [ ] **Step 4: Commit** `docs: company layer`.
