# Task 6 report: budget

Files: src/company_budget.cho (462 lines, module forge.company_budget, pure, no effect row), tests/company_budget_test.cho (24 tests), cancho.toml ([[test]] company_budget). Authority unchanged.

## RED / GREEN
RED: tests written against a module stub: `unknown-name` on `company_budget.Prices`. GREEN: after implementing, `24 passed; 0 failed` (two compile-level fixes on the way: struct fields are not assignable through a value, `json.parse` needs `borrow mut`). Every expected integer is computed by hand in the test.

## Facts read from the real sources
- eval/prices.json: USD per million tokens as decimals; {provider: {model: {in, cache_write, cache_read, out, optional prompt_limit, over_limit_prices{same four}}}}; `_source`/`_note` keys at root and inside entries; ollama `_any`. The test embeds the file's own values (notes shortened).
- usage.jsonl (src/cancho_agent.cho `log_call`; scripts/test-agent-native.sh pins in=11 out=22 cache_write=33 cache_read=44 thinking=7): one object per call with provider, model, task, sample, in, out, thinking, cache_write, cache_read, stop, outcome, status, reply_chars, program_chars, ms. The test's literal is that exact line shape.
- eval/metrics.py tiering: prompt = in + cache_write + cache_read > prompt_limit -> whole call at over_limit_prices. Reproduced.

## Rulings (all in the module header and tested)
- Prices: micro-dollars per million tokens, ints, parsed from the number's own text (no floats): digits, optional `.` + 1..6 digits, at most $1000. Sign, exponent, 7+ places, string, null, missing class -> that model's price None. `over_limit_prices` present but incomplete -> None; present without `prompt_limit` -> no tier (has_over false); `prompt_limit` not a positive int -> None.
- Cost: sum(tokens*price)/1e6 in integers, rounded UP once over the whole sum (3 tokens of each class at haiku base = 2.205 -> 3, per-class rounding would say 5). Overflow-safe split (whole part / remainder part); saturates at 1e15.
- `max_cost` unit: WHOLE US DOLLARS (spec writes "$10"); `dollars_to_micro` converts (saturating, negative -> 0).
- Limits: ceilings may be reached, not passed (`spent > limit`); 0 allows nothing, does NOT mean unlimited (manifest requires all numbers, so no "unset"). Cost likewise `cost > max`.
- Tiering: log has per-call prompt tokens, so `parse_usage_tiered(text, limit)` / `parse_usage_for(text, prices)` bucket over-limit calls in `over_*` and set `tiered`. A Usage without that information (`parse_usage`, `usage_of`) is priced WHOLLY at the over tier when the prices have one (conservative, tested: haiku 1,000,000 input via usage_of = 500000, tiered = exact).
- Malformed line = not an object / not parseable / any of the four fields absent, non-int, fractional, negative, > 1e15 / longer than 2048 bytes (line parsed in a 64 KiB arena; longer is skipped, never a trap). Skipped and counted in `malformed`. Blank/whitespace/CRLF lines are not lines. Totals saturate at 1e15.
- `parse_prices(model)` searches every provider (first that names the model); it never uses `_any` (a model nobody priced is None, not free). `parse_prices_for(provider, model)` also falls back to that provider's `_any` (ollama, all-zero prices).
- `price-table-missing` is not used here (command layer, later).

## Public signatures
```
pub struct Usage { input, output, cache_write, cache_read, calls, malformed: int, tiered: bool, over_input, over_output, over_cache_write, over_cache_read: int }
pub struct Prices { input, output, cache_write, cache_read, prompt_limit: int, has_over: bool, over_input, over_output, over_cache_write, over_cache_read: int }   // micro-dollars per million tokens
pub struct Limits { input: int, output: int, cache_write: int, cache_read: int }
pub fn line_limit() -> [] int                      // 2048
pub fn usage_of(input: int, output: int, cache_write: int, cache_read: int) -> [] Usage
pub fn parse_usage[&t](text: &t [byte]) -> [] Usage
pub fn parse_usage_tiered[&t](text: &t [byte], prompt_limit: int) -> [] Usage
pub fn parse_usage_for[&t](text: &t [byte], p: Prices) -> [] Usage
pub fn parse_prices[&h, &t](heap: &!h Heap, text: &t [byte], model: &static [byte]) -> [heap] option.Option[Prices]
pub fn parse_prices_for[&h, &t](heap: &!h Heap, text: &t [byte], provider: &static [byte], model: &static [byte]) -> [heap] option.Option[Prices]
pub fn cost_micro(u: Usage, p: Prices) -> [] int
pub fn dollars_to_micro(dollars: int) -> [] int
pub fn exhausted(spent: Usage, limits: Limits, cost_micro: int, max_cost_micro: int) -> [] bool
```
Deviation from the brief: Prices has extra fields for the over tier (the brief's four come first); `model` is `&static [byte]` as specified, so Task 8 passing a manifest-derived name must supply a static or use a different route (see concerns).

## Gate
fmt, check, all `cancho test` sets (company_budget 24), conformance etc. as in earlier tasks. Only failures: the 3 known `FAIL procs` lines (scripts/check_procs.sh). No other failure. Largest file 462 lines.

## Concerns
- `model`/`provider` params are `&static [byte]` (as the brief wrote for parse_prices); Task 8 reads them from the manifest at run time, which is not static. If that does not typecheck there, relax to `[&m] &m [byte]` (a mechanical change; I did not because the brief fixed the signature and `json.get` takes any `&k`). Flag for Task 8.
- The journal's `spend.recorded` carries only totals, so the budget the company replays has no per-call tier: for a model with an over tier (haiku) cost is priced at the higher tier, up to 5x the true cost. Safe (never under-counts) but may stop a haiku company early; Task 8 can instead price per step from `parse_usage_for` at record time if it stores cost, or accept the conservatism.
- Tape arena: lines over 2048 bytes are malformed; a real log line is ~250 bytes plus the task text (cancho-agent's `task_head` is short).

## Fix round 1: no input reaches a panic (review finding, Medium + Low)
Problem: `usage_of` did not clamp and `cost_micro` assumed 0 <= tokens <= 1e15, so `usage_of(9000000000000000000, 0, 0, 0)` at $1000/M overflowed (SIGILL); negatives gave negative cost. Journal-replayed totals reach `usage_of`, and `Usage`/`Prices` are public structs.
Tests first (RED: 3 of 27 failed, `trapped: killed by signal 4`), then GREEN `27 passed; 0 failed`:
- `test_usage_of_clamps_huge_and_negative_totals_and_the_cost_never_traps` (i64 max, 9e18, negatives, at several price levels; cost saturates at 1e15 or is 0).
- `test_a_usage_built_directly_with_huge_or_negative_fields_is_clamped_by_cost_micro` (direct Usage with huge/negative fields and over buckets, an over bucket larger than its total, negative and huge prices).
- `test_a_limit_at_or_above_one_quadrillion_is_reachable_by_a_saturated_total`.
Changes in src/company_budget.cho: `clamp` (to [0,1e15]) in `usage_of`; `whole_part`/`rest_part` clamp tokens and clamp prices to [0,1e9]; `cost_micro` caps each over bucket at its total (`over_of`, `base_of`) so the base part is never negative; `exhausted` goes through `over_ceiling`, which clamps both sides to [0,1e15] and treats a saturated spent (exactly 1e15) against a limit or cost ceiling of 1e15 or more as exhausted (documented in the module header). Negative inputs are 0.
Commands: `cancho test tests/company_budget_test.cho src/company_budget.cho --std` -> `test result: ok. 27 passed; 0 failed`; full `CANCHO=... scripts/gate.sh`: `gate: FAIL` with exactly the 3 known `FAIL procs` lines (check_procs.sh) and no other failure.
