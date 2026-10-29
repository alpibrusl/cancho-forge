# Intents: why a step is worth keeping, and when to stop

> **Status: design, nothing built, nothing measured.** Every claim about what Forge will do is *(designed)*. Every claim about
> what Forge does now is taken from [`company.md`](company.md) on `main` at `e7c7009` and was **not** checked against the code
> (`src/company_*.cho` was not read for this document). Tracked by #45; the epic is #44. If this document and the code disagree,
> the code is right and this document is corrected in place.

## 1. The gap

The company layer verifies that a step was **built right**: Forge runs the step's check against an artifact it hashed itself, and a
worker's claim is never acceptance ([`company.md`](company.md) section 8). It says nothing about whether the step was **worth
building**, and nothing about when to stop keeping it. A person answers that today, in their head, outside the journal.

An *Intent* is the smallest record that moves that answer into the journal without moving the judgment: a person writes down, before
anything is measured, what a set of steps is for, what number would show it is not earning its place, and by when someone must look
again. Forge measures the number with a program the operator wrote and **proposes**; a person decides.

This is the split of the Alpibru manifesto ("Trust Without Comprehension", https://alpibru.com/manifesto) applied to product
work: verification wherever it can replace comprehension, human judgment only for what verification cannot answer. The Intent is
where the judgment is recorded. Forge does not make it.

## 2. Does it fit the non-goals?

The company-layer design lists "strategy or pivot loops" and an "LLM CEO" as non-goals
([`superpowers/specs/2026-10-27-forge-company-layer-design.md`](superpowers/specs/2026-10-27-forge-company-layer-design.md)
section 2), and `company.md` section 1 says the layer "does not choose work, plan, or pivot".

An Intent is at the edge of that line, not clearly inside it. **Proposed reading, for the owner to accept or refuse:** it is inside
only while all four of these hold, and each is a test, not a promise:

1. Every criterion (hypothesis, metric program, kill threshold, expiry) is written by a person and is **fixed before the first
   measurement** (section 5).
2. `forge company review` writes records and **no step**: no new work enters the manifest or the scheduler's reach from a review.
3. Nothing happens on a proposal until a person approves its gate, and an approval recorded **before** the proposal does not count
   (the rule `retry:<id>` already has, `company.md` section 8).
4. The design's non-goal gets one sentence in place saying exactly this, with the commit that adds it.

**The alternative** is to treat Intents as the first slice of roadmap M7 ("strategy loop and measured pilot") and leave the
company-layer non-goal as written. That costs a second home for the same verbs. This document recommends the first reading and
does not edit the non-goal; that is the owner's decision.

## 3. The record *(designed)*

An Intent is an element of a new `intents` array in `company.json`. Like the rest of the manifest it is a closed shape, declares
requirements, and grants nothing.

```json
"intents": [
  { "id": "uptime-lib",
    "hypothesis": "A status page needs counts and a ratio; percentiles are not worth a dependency.",
    "steps": ["lib"],
    "measure": { "check": "measure_uptime.sh", "of": "uptime" },
    "kill": { "below": 9500 },
    "expires": "2027-01-31" }
]
```

| field | meaning |
|---|---|
| `id` | a name, as a step id is (1 to 64 bytes of letters, digits, `-`, `_`, `.`; no dot name). Unique among intents |
| `hypothesis` | text, at most 16 KiB, no NUL, as `mission` is. Nothing is driven by it; it is what a person reads at review |
| `steps` | the steps this Intent justifies. Each must exist |
| `measure.check` | a program of the company directory, as a step's `check` is |
| `measure.of` | the step whose **accepted** artifact the program reads. Re-verified against the SHA-256 of its `company.step.accepted` record before every run, as a need is (`company.md` section 8) |
| `kill` | exactly one of `{"below": N}` or `{"above": N}`, an integer. The kill threshold is *met* when the measured value is below (or above) it |
| `expires` | a date, `YYYY-MM-DD`, validated as a shape |

**Integers only.** The measured value is an integer in the author's own unit (basis points, milliseconds), because Forge has no
floating point anywhere near a decision (`company.md` section 9). A ratio is scaled by the program.

## 4. Measuring *(designed)*

The measure program is run exactly as a step's check is, so nothing new is trusted: started with two arguments (the artifact's
absolute path, the step's execution directory), `PATH` only as its environment, empty standard input, a deadline
(`check_timeout_ms`), a 1 MiB cap on standard output, inside its own process group under the check guard. The artifact is hashed
before and after, and a change is `artifact-invalid`.

It prints a line `METRIC <integer>`; **the last such line decides** and the program must not let the artifact write to its standard
output, for the reason `company.md` section 8 gives for `TOTAL`. No readable line, a signal, the deadline or the output cap is
`metric-unavailable`, never a value.

What this measures is **the artifact Forge hashed**, not the product in use. A number about users has to arrive as a file the
operator puts in the step's execution directory, as an analyst's input does (`company.md` section 13); Forge has no network
capability, and this document does not add one. Where such a number comes from is #47's question, not this one's.

## 5. Time and the kill criterion *(designed)*

**No clock.** `company.journal` records carry no time and replay must stay a pure function of the file. So "now" is an argument:
`forge company review <company-dir> <operator-file> now=YYYY-MM-DD`, in the `NAME=value` style `format=json` already uses. The
date is written into every record the review appends (`at`), so a replay sees the date the operator gave and never a clock.
`expired` is `now > expires`, a comparison of two validated date strings.

**Fixed before it is measured.** The manifest is editable after the fact, and an edit to a kill threshold after the number is
known would make the record worthless. So the first `review` that meets an Intent appends `company.intent.declared` with the
SHA-256 of the Intent's canonical text, and every later review refuses an Intent whose text no longer hashes to it
(`intent-changed`). A person who wants a different criterion adds a **new** Intent with a new id; the old one stays in the journal.

This is detection, not defence. The operator is the manifest's author and can edit `company.journal` too (`company.md` section 2);
the check catches an honest mistake and leaves a visible record of a deliberate change. It does not change the trust model.

## 6. Proposals and decisions *(designed)*

`forge company review` takes the company lock, replays the journal (cutting a torn tail, as `run` does), and for each Intent that
has no conclusion yet:

1. declares it if it is new (section 5);
2. measures it if its `of` step is accepted, and appends `company.intent.measured`;
3. appends **one** `company.intent.proposed` if the kill threshold is crossed (`reason: kill-met`) or the date has passed
   (`reason: expired`), and not again until the proposal is decided.

It writes no step and starts no worker. A proposal opens the gate **`prune:<intent id>`**, decided with the verb that exists:

```
forge company decide <dir> prune:<intent id> approved|rejected <reason...>
```

`approved` retires the Intent; `rejected` keeps it. Either **concludes** it: a person has looked at the evidence and decided, and
the Intent takes no further proposals. Keeping something past its expiry is a new Intent. As with `retry:<id>`, only a decision
recorded **after** the proposal counts, and `decide` on a `prune:` gate with no proposal is `gate-unknown`, so a prune cannot be
approved in advance (the pre-approved-gate gap in `company.md` section 14 is not reopened here).

Forge does not remove anything on `approved`. A retirement is a record, and what a person does about it (delete the code, drop a
step from the manifest) happens outside. Whether a later slice may turn it into a builder step is #48's question.

## 7. Journal kinds and replay *(designed)*

Framed like every Forge journal (`v`, `seq`, `kind`, `task`). `task` is the Intent id.

| kind | fields |
|---|---|
| `company.intent.declared` | `sha256` of the canonical Intent |
| `company.intent.measured` | `value`, `at`, `artifact_sha256` |
| `company.intent.metric_unavailable` | `at`, `reason` |
| `company.intent.proposed` | `reason` (`kill-met` or `expired`), `at` |

Decisions reuse `company.gate.decided` with `gate: "prune:<id>"`. Replay gives, for each Intent: declared hash, last value, whether a
proposal is open, and whether it is concluded. A build that does not know these kinds passes over them (`company.md` section 7:
"a kind this build does not know is passed over"), so an older Forge replays a newer journal without error, **and silently ignores
its Intents**; that is stated, not a bug.

`forge company status` gains an `intents:` block, one `<id> <state>` line each (`open`, `measured`, `proposed`, `kept`,
`retired`), and `format=json` gains an `intents` key. Adding a key is compatible with a reader that ignores keys it does not know;
a reader that rejects them breaks, and `company.md` section 5 says "every key is always present", so this document asks for that
sentence to be amended when #46 lands. `status` stays read-only and never runs a measure program.

## 8. Refusals *(designed; none exists in code)*

A rule ships with a row in `company.md` section 12 and `architecture.md` section 7 and a test that reaches it.

| tag | when |
|---|---|
| `intent-malformed` | a field of the wrong shape, an unknown key, a key twice, a kill with both bounds or neither, a date that is not `YYYY-MM-DD` |
| `intent-duplicate` | two Intents with one id |
| `intent-step-unknown` | `steps` or `measure.of` names no step |
| `intent-changed` | the Intent's text no longer hashes to its `company.intent.declared` record |
| `metric-unavailable` | no readable `METRIC` line, a signal, the deadline or the cap (recorded; nothing proposed) |

Exit codes for `review` belong to the family of `company.md` section 5 (0/1/2/3 and 10 to 16) and are settled in #48.

## 9. Authority

An Intent adds no capability. The measure program is a program of the company directory that Forge runs with Forge's authority,
exactly like a `check`; **what it widens is the number of such programs the trusted operator can name**, and that is the whole of
the change. `forge company review` is a writer and a runner, so its authority report resembles `run`'s; the commit that adds it says
so, as `CLAUDE.md` requires.

## 10. What stays a person's

- Whether the hypothesis is the right one, and whether the metric measures it. A program that always prints a passing number is
  indistinguishable from a good one; Forge verifies *that the number was produced under the rules*, not that it means anything.
- Whether to keep something that has crossed its kill line.
- Everything about users: no Intent can see one without an input file a person provides.

This is the manifesto's wager stated at the scale of one repository, not a result. No Intent has been written or run.

## 11. Not decided here

- Whether `measure` may be an analyst or qa step instead of a bare program (#47).
- Where a number about users comes from (#47).
- What a retirement may trigger beyond a record (#48).
- Exit codes and the text of the `review` output (#48).
- Whether a renewal needs more than a new Intent (this document says no; a longer history may say otherwise).
