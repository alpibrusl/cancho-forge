# The company over time: a portfolio that is built, changed, released, deployed and operated

> **Status: design, nothing built, nothing measured about any of it.** Every proposal below is *(designed)*. Statements about what exists
> were read from the sources named and are marked *(read)*; nothing was run for this document, no model was called and no money was
> spent. If this document and the code disagree, the code is right and this document is corrected in place.
>
> **What was read** (2026-10-31): cancho-forge `main` at `31ea7ac` (`docs/company.md` whole, `docs/library-steps.md`,
> `docs/threat-model.md`, `docs/roadmap.md`, `docs/intents.md`, `docs/architecture.md` section 4.1 and the journal rows of 9;
> `docs/worker-contract.md` headings, `docs/authority-repo-publish.txt`); cancho-forge branches **not yet on `main`**: `design-autonomy`
> (PR #54, `docs/autonomy.md`), `design-isolation` (PR #55, `docs/isolation.md`) and `design-self-repair` (PR #56,
> `docs/self-repair.md`), read from the branches, so the links to them below resolve only after those pull requests merge; cancho-code
> `main` at `59e52ca` (`docs/build.md`, `docs/project.md`, `docs/library.md`, headings and grep hits of `docs/reference.md`,
> `docs/multi-file.md`, `docs/journal.md`, `docs/mcp.md`); cancho-diff `main` at `d321813` (`docs/provenance.md`, the file list).
> **Not read:** `src/company_*.cho` (no source of this repository was read for this document, so every statement about code is taken
> from the documents above), `workers/*.cho`, the `fix` front door's source, cancho-code's `src/`, the audit programs of the
> cancho-diff company directory, anything of cancho-oci beyond what `isolation.md` quotes of it.

## 1. The requirement, and what stops it today

Three requirements, in the maintainer's words, 2026-10-31:

1. *A company creates and maintains the package, the same company*: a company owns a package for its whole life.
2. *A company should be able to maintain more than a repo.*
3. *A company should deploy and maintain the product online and evolve it according to the business use.*

And the constraint carried over from [`autonomy.md`](autonomy.md) section 1: the people who control the company judge **one demo per
release**, not every merge.

**What a company is today** *(read, `company.md` sections 1, 3, 7, 8, 14)*: one manifest with a fixed list of 1 to 256 steps; every
step id is unique and a step, once `accepted`, is never run again; the company ends when every step is accepted (`done: steps accepted
N`, exit 0). The builder builds a new project from a brief and "reads no existing repository" (`self-hosting.md` Stage 3, as quoted by
`self-repair.md` section 3 step 4). There is no clock anywhere in the company journal (`intents.md` section 5). Forge is not a daemon:
`forge company run` is one invocation that stops at the first thing that needs a person. The one thing that leaves the company is
`forge company publish`, which puts an accepted artifact on a local branch and never pushes (`company.md` section 15). There is no
deployment, no observation of a running product, and no way to say "the same company, a year later, has another piece of work".

**What the first real use showed.** The cancho-diff build ended with a person turning `project.cho` into a library by hand and writing its
tests and CI (`cancho-diff/docs/provenance.md`, *read*); [`library-steps.md`](library-steps.md) closed the library half. What is
left is that the package now exists, has users, will have defects, and nothing in the company can take the next piece of work on it.

**Scope.** This document designs the objects and rules that make a company long-lived (sections 2 and 3), the unit of work that replaces
"a list of steps that ends" (section 4), release and deploy (section 5), the operate-and-evolve loop (section 6), and the authority each
adds (section 7). It does not design merge policy ([`autonomy.md`](autonomy.md)), sandboxing ([`isolation.md`](isolation.md)), the repair
of Forge's and Cancho Code's own defects ([`self-repair.md`](self-repair.md)) or Intents ([`intents.md`](intents.md)); it uses them and
says where it needs something they only design.

**Non-goals.** Forge choosing what to build (section 6.4 draws the line), stateful deployments (databases, migrations: refused, section
5.6), a scheduler daemon, hosting a product for third parties, handling payment or contracts (`threat-model.md` section 4: "no
capability exists").

## 2. The portfolio

A company stops being "one manifest that finishes" and becomes a **portfolio**: a mission, a set of repositories it owns, a journal that
spans years and a budget that renews.

### 2.1 Repositories

The invariant of `company.md` section 3 holds: **the manifest declares requirements and grants nothing; it cannot name a repository, a
checkout, a compiler or a command.** So a repository is two rows, one in each file, that must agree.

The manifest gains an optional closed array `repos` *(designed)*:

```json
"repos": [
  { "id": "diff",     "kind": "library" },
  { "id": "diff-api", "kind": "service" }
]
```

| field | meaning |
|---|---|
| `id` | a name as a step id is (1 to 64 bytes of letters, digits, `-`, `_`, `.`; no dot name). Unique in the manifest |
| `kind` | one of `library`, `program`, `service` (below) |

The **operator file** (outside the company directory, `company.md` section 4) gains `repos`, which **extends the registry of
[`autonomy.md`](autonomy.md) section 3** instead of making a second list (`company.md` section 14 already notes that the publish list and
the gate runner's allow-list are two lists for one fact). Fields marked `+` are new to the autonomy registry *(designed)*:

```json
"repos": {
  "diff": {
    "slug": "alpibrusl/cancho-diff", "branch": "main", "checkout": "/abs/work/cancho-diff",
    "gate": "scripts/gate.sh", "policy": "default", "pins": [".cancho-rev"],
    "kind": "library",
    "compiler_rev": "f4ead824f33b291a0ad7620a34a0c1346a7abe4f",
    "publish_allow": ["src/**", "tests/**", "docs/**", "README.md"],
    "publish_deny":  [".github/**", "audit/**", "docs/provenance/**"],
    "max_patch_files": 20, "max_patch_lines": 800
  }
}
```

| field | meaning | refusal when wrong |
|---|---|---|
| `kind` + | must equal the manifest row's `kind` | `repo-kind-mismatch` |
| `compiler_rev` + | the cancho revision this repository is built, tested and audited with: 40 hex. One value per repository, never per change | `operator-invalid` (form); `repo-pin-mismatch` (below) |
| `publish_allow`, `publish_deny` + | path patterns a change may touch. `publish_deny` wins. Today the allow-list is a repository name plus a `files` map of destinations (`publish_plan.dest_ok`, `company.md` section 12); this makes it a set of paths for patches | `patch-path-denied` |
| `max_patch_files`, `max_patch_lines` + | bounds on one change, as `max_files` and `max_added_lines` of `autonomy.md` section 4 | `patch-too-large` |

`compiler_rev` and the repository's own pin files (`.cancho-rev`, `cancho.toml`: the registry's `pins`) are two statements of one fact.
Forge reads the pin from the checkout at each change's base commit and compares: a disagreement is `repo-pin-mismatch`, and nothing is
built. A **compiler bump** is therefore a change request (section 4.1) that moves both together; no other change may touch a pin file
(they are in `publish_deny` unless the change kind is `compiler-bump`). This closes the stale-pin failure `autonomy.md` section 5 reports
from the manual work (`pin-not-landed`) at the place the pin is written, for one repository.

**Kinds.** A kind fixes which checks, which release steps and which verbs exist for a repository. It is not a template for code.

| kind | what the repository produces | release | deploy | the change's check includes |
|---|---|---|---|---|
| `library` | a module other programs `import` (`src/NAME.cho`, `tests/NAME_test.cho`, `library-steps.md`) | a merged commit and a tag a person pushes | **none**: `deploy-kind-invalid` | the repository gate, the held-out audit, the authority ceiling |
| `program` | an executable built by the compiler | as `library`, plus an artifact digest recorded | none in this document | the above, plus that the built binary's own examples run |
| `service` | a program that runs somewhere and answers (stateless, section 5.6) | an image or binary digest, hashed by Forge | `staging` and `prod` through section 5 | the above, plus the health probes of section 5.4 against staging |

The kinds are a closed set. A fourth (a site, a mobile app) is a new row of this table and a new design, not a manifest value.

**One repository, one company.** A repository has at most one owning company. Within a company, work on a repository is serialized by a lock
file of the company directory named by repository id (`repos/<id>.lock`, `repo-locked`). That lock cannot exclude a second company or a
person working in the same checkout; the exclusion across companies is a convention the operator keeps, and a check for it is open
question 8.

Refusal tags *(designed)*: `repo-unknown` (a step or change names an id the manifest does not list), `repo-duplicate`,
`repo-kind-invalid`, `repo-kind-mismatch`, `repo-unconfigured` (the manifest lists a repository the operator file has no row for, found
when a step that needs it starts), `repo-pin-mismatch`, `repo-locked`, `repo-checkout-dirty`, `repo-checkout-changed` (section 4.2).

A manifest with no `repos` is valid and behaves exactly as today. That is a test of the first slice (section 8).

### 2.2 The journal across years

*Read:* `company.journal` is one file; every `status`, `decide` and `run` replays it whole (`company.md` section 7); records carry no
time; there is no snapshot of the **company** journal. (The **task** journal has segments in its design, `architecture.md` section 4.1,
and a snapshot with the journal's prefix hash that is built, `roadmap.md` M1; the same section 9 says segments and rotation are not
built.) For a company of one week this is right. For a company of years it makes the cost of every verb grow with its whole history, and
leaves no answer to "may old records leave the machine".

**Rule that does not move: the journal is append-only and replay is the only state** (`company.md` section 7). Nothing below edits,
deletes or reorders a record. What changes is how a long journal is *stored* and *read*.

**Segments.** The active journal stays `company.journal`. When it reaches a size the operator file sets (`journal_segment_bytes`,
default 64 MiB) or at the first record of a new calendar year, the next `run` or `decide` (it holds the lock) **seals** it:

1. appends the last record of the segment, `company.segment.sealed` (`first_seq`, `last_seq`, `sha256` of every byte before this record);
2. renames the file to `journal/NNNNNN.jnl` (atomic rename on one file system, then the directory synced, the order of
   `architecture.md` 4.2 item 4), which is never opened for writing again;
3. creates the new `company.journal` whose first record is `company.segment.opened` (`seq` the next number, `prev_sha256` the sealed
   segment's hash, including its sealing record), and whose `seq` goes on without a gap or a restart.

`seq` therefore stays one sequence for the life of the company; a reader that wants "everything" reads the segments in order and checks
the chain.

**Snapshots.** At the first record of a new segment Forge also writes `snapshot/NNNNNN.json`, a *cache* of replay at the sealing `seq`:
per step the accepted artifact path and digest, per gate the last decision, per change its state (section 4.1), spend totals per period,
the audit totals of section 4.3, the goals version. `status` and `run` read the newest snapshot whose hash matches its segment's chain
and replay only the active tail. **A snapshot is never authoritative**: `forge company verify <dir>` replays every segment from `seq` 1
and compares; a mismatch is `snapshot-mismatch`, the snapshot is ignored and the full replay is used. This is the rule `architecture.md`
4.1 already states for the task journal ("a cache, never authoritative"), applied to the company journal.

**What this does and does not give.** Sealed segments are never modified, so the append-only guarantee holds as before; the hash chain
adds *detection* of a modified or missing old segment (`journal-chain-broken`), which the task journal's threat model does not have
(`threat-model.md` T7: "tamper evidence is out of MVP scope"). It is detection by a trusted operator's own check, not defence: the
operator can rewrite the whole directory (`company.md` section 2). **Archiving** a sealed segment off the machine is allowed when its
hash is kept (`journal-segment-missing` if it is neither present nor on the operator's archive list `journal_archived`); a company that
needs the full history verifies it from the archive.

**Time.** A rolling cap and "by when" need dates; replay must stay a pure function of the file. The rule of `intents.md` section 5
applies: `now` is an argument (`now=YYYY-MM-DD`, the style `format=json` already uses) and is **written into every record** the
invocation appends as `at`. A `now` earlier than the last `at` in the journal is `clock-went-back`. Records written before this feature
have no `at` and count as outside every window (they still count in the lifetime cap). Whether Forge may read the clock itself instead
is open question 6.

**Personal data in an append-only file.** A change request's text (an issue body, an operator's note) can carry names and addresses, and
the journal never forgets. So **the journal holds hashes and sizes of intake text, never the text**: the body lives in
`changes/<id>/body.txt` and the record holds its `sha256` and byte length. The file can be deleted on a retention rule (section 4.4)
and the journal still replays; the hash then names something that is gone, which is stated, not hidden. This is a design rule because
it cannot be added afterwards.

Refusal tags *(designed)*: `journal-segment-missing`, `journal-chain-broken`, `snapshot-mismatch`, `clock-went-back`,
`journal-seal-failed` (an I/O error while sealing; the active file is untouched).

**Not decided:** the retention of sealed segments beyond "forever" (open question 10); whether the snapshot is worth it before replay time
is measured (section 9, M-3).

### 2.3 Budget: per change plus a rolling cap

*Read, `company.md` section 9:* all six keys are required; four token ceilings and `max_cost` (whole dollars) are **lifetime** totals;
they are checked only between model steps, so a running step can pass a ceiling by one step; the recorded spend lags a killed run; a
build that truncates `usage.jsonl` records no spend. For a company of years a lifetime ceiling is a stop sign that arrives once.

The manifest's `budget` gains two optional closed objects *(designed)*:

```json
"budget": {
  "input": 2000000, "output": 400000, "cache_write": 200000, "cache_read": 1000000, "max_cost": 2, "price_table": "prices.json",
  "rolling":    { "days": 30, "max_cost": 40 },
  "per_change": { "max_cost": 3, "max_attempts": 6 }
}
```

| key | meaning | refusal |
|---|---|---|
| `rolling.days`, `rolling.max_cost` | the cost recorded in the `days` days up to `now` (by `at`) may not pass `max_cost` (whole dollars, as today). Checked where the lifetime cap is: before a model step starts | `budget-exhausted` with `window: rolling` |
| `per_change.max_cost` | the cost of all steps of one change (section 4.1: their step ids start with the change id) may not pass it; checked before each model step of that change | `budget-exhausted` with `window: change` and `change: <id>` |
| `per_change.max_attempts` | the number of times the change's model steps are admitted (`company.step.admitted`) | `change-attempts-exhausted` |

The lifetime keys stay and stay required (a manifest without `rolling` or `per_change` is valid and behaves as today): they are the hard
stop a rolling cap cannot be argued out of. A change that hits its own cap goes to `held` with the reason; it never blocks other changes,
and the company's rolling cap can still stop all of them.

**Unchanged and still true:** the checks are between steps, so one step can overshoot; the budget is a ceiling on an honest build tool,
not on a hostile one (`company.md` section 9). **Not covered:** hosting, bandwidth and any recurring cost of a running service are
**not tokens and are not counted**. A deploy target's resources are fixed in the operator's adapter (section 5.3), so a change cannot
raise them, and a person changing them is the "human gate for spend" in the maintainer's third requirement (open question 7).

## 3. From "a list of steps" to "a company that keeps working"

The unit that replaces the manifest's fixed `steps` is the **change** (section 4). To keep the invariants of `company.md` (replay is the
only state; a step is accepted only by a Forge-run check; a worker's `done` is a claim) the design does **not** let changes write
themselves into `company.json`. Instead:

* The manifest keeps `steps` for what it has always held: a **bootstrap** (brief, lib, ship: how cancho-diff was made). Those steps
  become history when they are accepted. Creating a package is the first change a company makes, expressed as it is today.
* The manifest gains **`flows`** *(designed)*: named templates of steps, in the same closed shape as `steps`, whose ids carry a
  placeholder. A change instantiates one flow; its steps are **derived**, a pure function of manifest plus journal, as step states are
  today (`company.md` section 6). Derived step ids are `<change id>.<template step id>` (for example `chg-0007.fix`).

```json
"flows": {
  "bug": [
    { "id": "repro",  "role": "builder", "task_type": "repo.change", "needs": [],        "check": "audit_repro.sh" },
    { "id": "fix",    "role": "builder", "task_type": "repo.change", "needs": ["repro"], "check": "audit_repo.sh" },
    { "id": "gate",   "role": "qa",      "task_type": "repo.gate",   "needs": ["fix"],   "check": "audit_gate.sh" }
  ]
}
```

A flow is held to the manifest's step rules (a role from the six, the task type its role offers, `needs` among the flow's own ids, no
ring, a `check` where one is required), and to three more *(designed)*: its `needs` may name only its own steps (`flow-needs-foreign`),
at most 16 steps (`flow-too-long`), and a flow named by a change kind must exist (`flow-unknown`). Manifest-time refusals, tested like
the step ones.

**What a derived step needs that a listed one does not get today.** `company.md` section 14: *"The operator creates `steps/<id>/ev` by
hand for each worker step (no mkdir in the language)"*; a missing one is `step-dir-missing`. That cannot work for a step id that did not
exist when the operator prepared the company. Slice 2 therefore needs a **provisioner**: a worker (or a verb) that creates
`steps/<derived id>/ev` beneath the company directory, with authority to write beneath `steps/` and nowhere else. It is the only
mkdir-shaped capability added and is listed in section 7.1. *(Whether `/bin/mkdir` through an `Exec` narrowed to its directory, as
`repo_publish` narrows to `/bin/sh`, is acceptable is a design choice for that slice; not decided here.)*

## 4. Change requests

### 4.1 The record

A **change** is a journal-resident request for work on one repository of the portfolio. It is the new unit of work. Closed shape of the
record Forge appends when one is *proposed* (`company.change.proposed`) *(designed)*:

| field | meaning |
|---|---|
| `id` | `chg-NNNN`, assigned by Forge from the journal (the next number), never by the source |
| `repo` | a manifest repo id (`repo-unknown`) |
| `kind` | `bug`, `feature`, `compiler-bump`, `feedback` (below) |
| `source` | `{"type": "operator" \| "issue" \| "signal", "ref": "<plain string, at most 256 bytes>"}`: where it came from. A reference, never an instruction |
| `title` | plain text, at most 200 bytes, one line, no control bytes. Shown by `status` through the JSON writer (`company.md` section 5) |
| `body` | `{"sha256": "<hex>", "bytes": N}` of `changes/<id>/body.txt`, at most 16 KiB (the limit of `mission` and `input`), the text of the request (section 4.4) |
| `justification` | exactly one of `goal:<goal id>` (section 6.3), `defect`, `maintenance`, `operator` |
| `base` | the repository's `branch` tip (40 hex) when it was proposed; set by Forge from the checkout, not by the source |
| `at` | the `now` of the invocation |

Kinds, and what each is *for* (a kind selects a flow of section 3 and fixes who may ask for it):

| kind | what it asks | flow starts with | needs a person to admit | justification allowed |
|---|---|---|---|---|
| `bug` | the behaviour differs from the brief, the contract or the audit's oracle | a **repro** step (section 4.3) | no when `source` is `operator`; yes otherwise | `defect` |
| `feature` | new behaviour | a contract step: a person writes or approves the new signatures, because the contract is a person's file (`self-repair.md` section 1: "a person supplies briefs, contracts, audits and decisions") | yes, always | `goal:` or `operator` |
| `compiler-bump` | move `compiler_rev` and the pins to a revision | no model step: the `pin.bump` task of `autonomy.md` section 5 for this one repository; a red gate opens a `bug` change that names the bump | no when `source` is `operator`; the bump's target is chosen by a person | `maintenance` |
| `feedback` | a business observation that may or may not imply work ("the diff output is too noisy for logs") | a **triage** step by a person that turns it into a `bug` or `feature` or closes it; Forge does not interpret it | yes, always | `goal:` or `operator` |

**Change states** (derived from the journal, a closed set, in the style of `company.md` section 6):

| state | meaning |
|---|---|
| `proposed` | recorded; waiting for the admit decision |
| `admitted` | the gate `admit:<id>` is approved (or admission is automatic by the rules above); its flow's steps exist |
| `building` | a derived step is admitted and not accepted |
| `held` | a derived step is held by a failed or unavailable check, or by the change's own budget; `retry:<derived step id>` frees it, as today |
| `ready` | every step of the flow is accepted and a patch exists (section 4.2) |
| `released` | the change is in a release whose demo gate was approved (section 5.2) |
| `deployed` | the release is applied on `prod` and its health probes passed |
| `rejected`, `abandoned`, `superseded`, `reverted` | terminal. `abandoned` after `per_change.max_attempts`; `superseded` by a later change that names it; `reverted` by a change that reverts its patch |

Journal kinds *(designed)*, framed like every company record (`v`, `seq`, `kind`, `task` = the change id, `at`): `company.change.proposed`,
`company.change.admitted`, `company.change.rejected`, `company.change.abandoned`, `company.change.superseded`. The state is replay, not
a stored word. An older Forge replaying such a journal skips the kinds it does not know (`company.md` section 7) and so **silently ignores
the changes**: stated here, as `intents.md` section 7 states the same of intents.

Human decisions reuse `company.gate.decided` with new gate-name families beside `retry:<id>`: `admit:<change id>`, `demo:<release id>`
(section 5.2). As with `retry:` and `prune:`, **only a decision recorded after the thing it decides counts**, and `decide` on such a name
with nothing to decide is `gate-unknown`. This closes the pre-approved-gate gap (`company.md` section 14) for every gate this document
adds, and it matters more here because the company lives long enough for a stale approval to be found.

Refusal tags *(designed)*: `change-malformed`, `change-unknown-field`, `change-too-large`, `change-kind-invalid`,
`change-justification-missing`, `change-duplicate` (same `source.ref` and body hash as an open change), `change-rate-limited` (section
6.5), `change-base-unknown` (the checkout does not have the commit), `change-attempts-exhausted`.

### 4.2 Patch against current code

**What exists *(read)*.** This is the part of the design that depends most on something that does not exist, so it is stated exactly.

| Cancho Code feature | what it does | what it does not do |
|---|---|---|
| `build ... --retry <unit> [--hint ...]` (`build.md`, "Continuing a stuck unit") | re-opens one unit of the plan **a run left in the work directory** (`plan.json` valid and `state.txt` present; otherwise exit 2) and builds it again, with the hint shown to the model as `HINT:` lines | does not take a repository. The plan and the work directory are products of an earlier brief-to-build run |
| `build ... --patch <unit> <file>` | splices code a **person wrote** into `project.cho`, checks it as a model's reply is checked, **no model**, one attempt; puts `project.cho` back if it does not verify | the code is human-written; again needs the earlier run's plan |
| `fix <checker> <project.cho> <agent>` (`reference.md`, `project.md`) | "drives one issue against one file": loops an agent on that file with the compiler and an acceptance hook | one file; whether it can take a change request as the issue and edit an existing multi-unit file was **not read**; how well a model does it on a real repository file is **unmeasured** |
| `--library NAME` (`library.md`) | turns a finished `project.cho` into a module; refuses `library-has-module` when `project.cho` already declares one | cannot be run on a library that already exists |
| `project` / multi-file plans (`multi-file.md`) | `--retry` and `--patch` work per unit and per file within a plan | the files are the plan's, not a checkout's |

So today **nothing takes (a repository at a commit, a request) and returns a change to it**. `self-repair.md` section 3 step 4 names the
missing piece `repo.patch` and calls it "the largest missing piece". This document assumes the same piece and defines what Forge needs
of it, so that Forge's half can be built and tested with a stand-in, as every worker was.

**The task type `repo.change`** *(designed)*, role builder, a model step (the budget applies):

1. **Input, prepared by Forge, never by the worker.** Forge makes a **throw-away read-only copy of the repository at `base`** in the
   step's execution directory (`ev/base/`), by the mechanism the gate runner already uses for a qa step (a throw-away git checkout,
   `company.md` section 11; not read in code). The worker is given `ev/base/`, `ev/change.txt` (the request, section 4.4) and
   `ev/scope.txt` (the allowed paths from `publish_allow` minus `publish_deny`, written by Forge). The real `checkout` is **not** given
   to the worker.
2. **Output.** One file, `ev/change.patch`: a unified diff against `ev/base/` (what `diff -ru` or `git diff` writes). That is the
   step's **artifact**, replacing `project.cho` for this task type; hashed by Forge before and after the check under every rule of
   `company.md` section 8 (a regular file, at most 16 MiB, no link followed). A whole-tree output was considered and not chosen: a
   patch bounds what changed to what can be listed and checked.
3. **Bounds, enforced by Forge on the patch and not by the worker's word:** every path in the patch is in the allowed set
   (`patch-path-denied`); at most `max_patch_files` files and `max_patch_lines` added lines (`patch-too-large`); no rename, mode
   change or binary hunk (`patch-kind-invalid`); it applies cleanly to `ev/base/` (`patch-not-applicable`).
4. **The check** is a program of the company directory, as ever. It receives the patch and the step directory, applies the patch to a
   **second** fresh copy of `base`, runs the repository `gate` and the held-out audit on the result and prints `TOTAL a/b`.
   Acceptance is unchanged: `a == b`, `b > 0`, Forge ran the check, the last `TOTAL` line decides.
5. **The checkout is untouched.** Forge records the checkout's tree hash before the step and compares after: a changed checkout is
   `repo-checkout-changed`, the step is held. (The worker does not hold the checkout, so this is a tripwire for a bug of ours, not a
   defence against a worker.)

**When the base moved.** A change is built against `base`. By publication the branch may have moved. Forge does not rebase silently:

* at publish, the accepted patch is applied to a copy of the **current** tip; if it applies and the gate and audit still pass on that
  copy (Forge runs them, a new check record), it is published; otherwise the change returns to `building` for **one** re-derivation
  against the new base (`patch-base-stale`), counted against `per_change.max_attempts`; a second staleness is `held`.

**Publishing a change.** `forge company publish` today takes the files of an accepted builder step (`project.cho` and up to three
files, `library-steps.md`) and writes `docs/provenance.md` (reserved, `publish-dest-invalid`). For a change it would apply the accepted
patch, re-hashed against the journal, to a fresh branch `forge/<change id>`, and write a provenance **section for the change**; it still
never pushes (`publish-push-not-granted`). *Not read:* whether a second publish into a repository that already has `docs/provenance.md`
replaces it; the design needs one provenance file per change (`docs/provenance/<change id>.md`, in `publish_deny` for every other path)
and leaves the old file alone. This is a change to the publish worker, with a new authority report (section 7.1).

Refusal tags *(designed)*: `patch-path-denied`, `patch-too-large`, `patch-kind-invalid`, `patch-not-applicable`, `patch-base-stale`,
`repo-checkout-changed`.

**What this does not settle: whether a model can do it.** The whole design of section 4 assumes a Haiku-class builder can produce a
correct patch against a few-hundred-line file given a request and the file. The only evidence in these repositories is indirect: the
repairs of `self-repair.md` section 11 (cancho-code #99, #103) were small and human-written. Measurement M-1 (section 9) comes before
anything is built on it.

### 4.3 The held-out audit grows with every fixed defect

*Read:* a step's `check` is a program of the company directory that the builder never sees; Forge runs it; the cancho-diff audit
generates inputs from a fixed seed and judges against GNU `diff` as an independent oracle (`provenance.md`, "Not shown"); the audit's
result is never fed back to the builder (`company.md` section 8). Today the audit is written once, before the first build, by a person.

A bug that reached a user is evidence that the audit did not cover something. The rule *(designed)*:

> **A `bug` change is accepted only if it adds at least one case to the held-out audit that fails on `base` and passes on the fix, and
> the audit never shrinks.**

How, without the builder writing its own judge:

* The `bug` flow's **first step is a repro** (`repo.change` with a `check` that must see the repro **fail** on `base`). The repro is
  written by a step that is **not** the fix step (`self-repair.md` section 3 step 2: "the fixture author is a different step from the
  repairer"), and its expected answer must come from an **independent authority** named in the change: the contract, a worked example of
  the brief, a reference program or oracle (GNU `diff` for cancho-diff), or a person's one-line statement. A repro with none is shown
  to a person (gate `admit:<id>` carries the line) and waits.
* The repro's check is an ordinary check that prints `TOTAL n/n` when the repro is red on `base` and green on the oracle: acceptance
  of a "red on base" fixture needs **no new Forge semantics**, only a check program that says so.
* On acceptance of the **fix** step, Forge copies the accepted repro to `audit/regress/<change id>.case` **beneath the company directory**
  (a protected place: the builder's execution directory is `steps/<id>/ev`, section 3) and appends `company.audit.grew`
  (`change`, `path`, `sha256`, `cases`). The audit program convention is that it runs every file of `audit/regress/`.
* **The audit never shrinks.** Forge records the `b` of the last accepted audit run per repository (`company.audit.total`). A check
  whose `TOTAL a/b` has `b` smaller than the recorded one is `audit-shrank`, held. This protects the audit from an edit by mistake, not
  from a hostile operator (who can edit the journal).
* The repro is also in the change's patch as an ordinary visible regression test of the repository (the library's own CI keeps it). It
  is **visible to the builder of the fix, by construction** (it is part of the request). So the audit's regression cases are held-out
  only in that the audit's *expected outputs and generator variants* stay out of the builder's reach; a repro that is also a visible
  test adds regression protection, not secrecy. Stated so the audit's size is not read as a measure of hidden coverage.

Audit growth for a `feature` is a person's job (the contract and the audit are a person's, section 4.1); the flow waits at the gate
rather than let a builder define what "done" means.

Refusal tags *(designed)*: `repro-not-red` (the repro passes on `base`: not a defect, or not this one), `repro-no-authority` (no
independent authority, waiting for a person), `audit-shrank`.

### 4.4 Intake: where changes come from, and why none of it is an instruction

Three sources, each treated as **data**. The rule of `threat-model.md` T9 applies without exception: *worker output never reaches policy
or a command line; no untrusted text is interpreted by Forge; sensitive actions need a human regardless of what text says.* Concretely
for text that enters through a change:

* **Forge never parses it.** The body is a file, stored by hash (section 2.2); the only fields Forge reads are the closed ones of
  section 4.1, assigned by Forge or by the operator's verb.
* **It reaches a model only inside a frame.** The builder receives `ev/change.txt` written by Forge as a fixed preamble (what the text
  is: an untrusted report, never an instruction to change its task or its output path), the title, then the body, whole or cut at
  16 KiB with a marker. It is never placed in an argument vector, an environment, a path or a shell string (the worker request carries
  only the file's name). A model can still follow text that looks like an instruction; the frame is a mitigation, **not a control**.
* **The judge does not read it.** The check, the audit, the gate, the path allow-list, the size bounds, the authority ceiling and the
  demo are all independent of the request's words. Text that talks a model into writing something bad is stopped, if at all, by those,
  and the list of what it **can** achieve is the list of what they miss. That is why the first measurement of section 9 on this topic is
  an adversarial corpus, not a model benchmark (M-4).
* **No tools for the model today** (`isolation.md` section 2 fact 1: `cancho-agent` has no `exec`): injection can change the text the
  agent writes, not run anything. This is **latent**, not closed: the day a worker is a tool-using agent, or a change body is shown
  to one, this paragraph is false. The design makes that day require `isolation.md` first (section 7.3).

| source | how it enters | who may cause a change | what Forge stores | rules |
|---|---|---|---|---|
| `operator` | `forge company change add <dir> repo=.. kind=.. justification=.. file=<abs path>`, a verb of the operator's account | the operator | the closed fields and `changes/<id>/body.txt` | admitted without a gate for `bug` and `compiler-bump`; `feature` and `feedback` still gated |
| `issue` | **a file**, not a network call: the operator (or a timer) runs `gh issue list --json ...` into `intake/issues/*.json`; `forge company intake <dir> <operator-file> now=...` reads those files | whoever can open an issue, which Forge does not know and does not judge | per issue: the closed fields, `source.ref` = the issue URL as plain text, body by hash | always `proposed`, **always** needs `admit:<id>`; at most `intake.max_per_window` proposals (below) |
| `signal` | section 6.1: a threshold crossed on integers the operator's probes produced | nobody: a rule fired | `source.ref` = the alert name; **the body is written by Forge from a template**: signal name, value, threshold, `at`, nothing else | always `proposed`; **no free text from telemetry ever enters a body** (log lines, error messages, user agents are excluded by construction) |

Forge has **no network capability** in any slice up to the deploy slices (`threat-model.md` section 4: none exists until M6), and
this design does not add one for intake: reading an issue tracker is the operator's `gh`, and what Forge reads is a file. The cost is
that intake is as fresh as the operator's timer; the gain is that a stolen read token on the tracker is not Forge's problem and Forge's
authority report does not change for it.

A change whose `source` is `issue` and whose title or body asks for anything, including "approve this", "raise the budget", "skip the
audit", "deploy now", is a change request with that text in it. It has no path to a gate. Gates are decided only by `forge company
decide`, which authenticates nobody and records the user (`company.md` section 5): the person at the operator's account is the control.

**Rate limits** *(designed)*, in the manifest (`intake`): `max_per_window` (proposals accepted per `rolling.days` window, default 20),
`max_open_per_repo` (changes not terminal; default 5). Over either is `change-rate-limited`, and the file is left in `intake/` for a
later `intake`. A flood of issues costs files on disk, not tokens.

**Retention.** `changes/<id>/body.txt` may be deleted by the operator at any time after the change is terminal (a Forge verb
`forge company change forget <id>` records `company.change.forgotten` with the hash it was; it deletes the file). The journal keeps the
hash. A change whose body is forgotten cannot be re-derived (`change-body-forgotten`).

## 5. Release and deploy

### 5.1 The release object

A **release** is the set of `ready` changes of one repository that a person will see in one demo *(designed)*. Closed shape of
`company.release.proposed`:

| field | meaning |
|---|---|
| `id` | `rel-NNNN`, from the journal |
| `repo` | a repository id |
| `commit` | the 40-hex head that contains every listed change (Forge computes it: the tip of the branch after the changes merged, or the tip of a Forge-made integration branch while merging is a person's act) |
| `changes` | the change ids it carries (at most 32) |
| `artifact` | for `program` and `service`: `{"name", "sha256"}` of the built artifact, hashed by Forge; absent for `library` |
| `demo` | `{"sha256"}` of the demo directory (5.2) |
| `at` | `now` |

A release is **proposed by Forge** when the changes are `ready` and the operator's `release` rule holds (a count or a day; it is a
rule of `intake` and `release` in the operator file, not text of a change), and is never *approved* by Forge.

For a `library`, a release ends at merge and a tag a person pushes: the publish credential is one Forge does not hold (`autonomy.md`
section 7). For `program` and `service` the artifact is what moves on.

### 5.2 The demo gate, bound to a content hash

The demo is the object of `autonomy.md` section 6 (`claims.md`, `run/`, `audit.json`, `change.md`, `cost.json`, `hashes`, `replay.sh`)
with this additional content for a release over time *(designed)*:

| part | content | produced by |
|---|---|---|
| `trace.md` | per change: id, kind, justification, the goal it serves (6.3), the audit cases it added (4.3), its cost | Forge from the journal |
| `before_after.json` | the integer signals of the goal's metric (6.1) at the last observation before the release and the latest after the last release, side by side | Forge from `company.signal.observed` records; **an observation, not a causal claim** (6.3) |
| `staging.json` | what Forge deployed to staging (5.3), the probe results (5.4) and the rollback rehearsal result | Forge |
| `diff.md` | the combined patch of the release, the authority diff (empty is stated as empty) and the files outside `src/`, `tests/` and `docs/` that it touched | Forge |

The gate is `demo:<release id>` and `forge company decide <dir> demo:<release id> approved <reason...>` **binds the decision to the demo's
hash**: the decision record carries the hash of the demo directory as of the decision, and counts only if (a) it was recorded after the
release was proposed and (b) the hash equals the release record's `demo.sha256` *and* equals a re-hash of the directory at decision time.
Editing any file of the demo after the person looked (a changed `run/`) is `demo-hash-mismatch`. This is the change to `decide` that
`autonomy.md` section 6 asks for; **it does not exist**, and nothing in this section can be built before it.

**What the person approves.** The release's `commit` and `artifact.sha256`, and nothing else. An approval authorises a deploy of exactly
that artifact (5.3). A rejection records which release; nothing already merged is reverted by it (`autonomy.md` section 8).

### 5.3 Environments and the deploy verb

Environments are a closed set per `service` repository: `staging` and `prod`. There is no third one in this design (a preview
environment is a new row).

**Targets.** A target is an operator-file object *(designed)*, so the manifest still names no command:

```json
"targets": {
  "diff-api-staging": {
    "repo": "diff-api", "env": "staging",
    "adapter": "/abs/deploy/diff-api-staging",
    "adapter_args": ["--region", "eu"],
    "probes": "health_staging.sh",
    "soak_seconds": 600,
    "keep_releases": 3
  },
  "diff-api-prod": { "repo": "diff-api", "env": "prod", "adapter": "/abs/deploy/diff-api-prod", "probes": "health_prod.sh",
                     "soak_seconds": 1800, "keep_releases": 3 }
}
```

The rules that make the target the whole of a deploy's reach:

* **The adapter is the operator's program, outside the company directory**, the way the operator file is. It is the only thing that holds
  a credential to the place that runs the product. Forge never reads it (`deploy-secret-in-company-dir` is refused when the target
  names a path inside the company directory, judged by text like `operator-invalid`), never receives it in a request, never writes it to
  the journal or `pr.md`, and starts the adapter with an **empty environment except `PATH`** (the rule of `exec_spawn` that already
  protects every worker, `threat-model.md` T3). How the adapter reaches its credential (a file readable only by a separate unix user, a
  secret manager) is the operator's; `isolation.md` Layer 1 describes the second-unix-user glue and is the recommended form.
* **Named targets only.** A deploy request names a target key. No hostname, address, command or argument comes from a request,
  a change, a release or a model (`target-unknown`). The adapter's own arguments are the operator's `adapter_args`, fixed.
* **Four calls, one verb.** The adapter is invoked as `adapter plan|apply|status|rollback <release id> <artifact sha256> [<previous
  release id>]` and nothing else; each prints a closed answer (`plan` prints a summary Forge hashes; `apply` and `rollback` print `OK
  <artifact sha256>` or a refusal word; `status` prints the artifact sha256 currently live). The adapter is told which artifact by
  path under `releases/<release id>/` of the company directory (Forge hashes it again immediately before the call: `deploy-artifact-changed`).
* **Dry-run first, recorded.** `apply` is refused (`deploy-no-plan`) unless the journal holds `company.deploy.planned` for the same
  release and target, newer than the release proposal, with the plan's hash. For `prod`, `apply` is also refused unless the demo gate of
  that release is approved with a matching hash (`deploy-not-approved`). For `staging`, no human decision is needed: it is not
  production, and the demo is generated *from* it.
* **A rollback path before any apply.** `apply` is refused (`deploy-no-rollback`) unless the target has a previous release recorded as
  `verified` (5.4) whose artifact is still in `releases/` (the last `keep_releases`), or the repository has no previous release (the
  first deploy of a repository is by a person, once; open question 2).
* **Idempotent and recorded around the effect** (the rule `architecture.md` 4.2 states for workers: intent before effect):
  `company.deploy.started` is synced before the adapter runs; `company.deploy.applied` or `company.deploy.failed` after. A run killed in
  between leaves a `started` with no outcome; the next run asks the adapter `status` and records which artifact is live, then decides.
* **The adapter's word is a claim.** Whether the product is healthy is not its answer: 5.4.

Journal kinds *(designed)*: `company.release.proposed`, `company.deploy.planned`, `company.deploy.started`, `company.deploy.applied`,
`company.deploy.failed`, `company.deploy.verified`, `company.deploy.rolled_back`, `company.deploy.frozen`.

Deploys are run by `forge company deploy <company-dir> <operator-file> <release id> <target> [dry-run]`, a verb of its own, a writer
holding the company lock, like `publish`; it is **not** a scheduled step (`company.md` section 11 says why publish is not one: a role
and a scheduler change). `dry-run` runs `plan` only. Exits follow the family of `company.md` section 5, with the tags below.

Refusal tags *(designed)*: `target-unknown`, `target-invalid`, `deploy-kind-invalid` (a `library` or `program` repository),
`deploy-secret-in-company-dir`, `deploy-no-plan`, `deploy-not-approved`, `deploy-no-rollback`, `deploy-artifact-changed`,
`deploy-adapter-failed`, `deploy-frozen`, `deploy-isolation-unmet` (7.3), `deploy-rate-limited` (6.5).

### 5.4 Health checks that Forge runs itself

The principle of acceptance carries over: **a deploy is `verified` only when Forge ran the probes and they scored a full pass**; the
adapter's `OK` is a claim.

* Probes are a **check program of the company directory** named by the target (`probes`), run exactly as a step's check is: two
  arguments (the target's descriptor file and a scratch directory), `PATH` only, empty standard input, `check_timeout_ms` (up to 86 400
  000 ms in the operator file, so a soak of hours fits in one check), a 1 MiB output cap, inside its own process group under the check
  guard; the last `TOTAL a/b` line decides, `a == b` and `b > 0`. This needs **no network capability in Forge**: the probe program does
  the network call (`curl --max-time`, say), and its authority is the operator's script's (`isolation.md` section 2 table: "whatever
  the script does"). What this costs: Forge's report stays clean while the *check* has unbounded reach. The operator keeps probes
  small, to the named host, and is told so.
* A probe that is flaky is a probe that fails a good release: `soak_seconds` and the probe program's own retry are the operator's; the
  false-failure rate is measured before it gates anything (M-6).
* **Order:** `apply` on staging, probes (`TOTAL` pass → `company.deploy.verified` for staging), the demo built from staging, the human
  gate, `plan`, `apply` on prod, probes on prod, `verified`. **Staging verified is a precondition of the demo** (`demo-incomplete`
  otherwise).
* **A rollback rehearsal on staging** (apply the previous release, probe, apply the new one again) is part of the demo's `staging.json`;
  a rollback that was never exercised is not trusted at 3 a.m.
* **On a failed probe after a prod apply**, Forge runs `rollback` to the last `verified` release **without asking**, then probes
  again, then records `company.deploy.rolled_back`. This is the only deploy-class act that needs no decision, because it restores a
  state a person already approved. It happens **at most once per release**: a second failure (the rollback's probes fail too, or the
  release fails again after a re-deploy) records `company.deploy.frozen` and every further deploy of that repository is `deploy-frozen`
  until a person records `unfreeze:<repo id>`. A flapping rollback loop is the failure the freeze is for.
* **What probes cannot see:** wrong behaviour a health endpoint does not exercise. The audit, the demo's worked examples and the human
  are what stand against that; the probes are an availability check, and the document says so.

### 5.5 Failure of the deploy machinery itself

| what fails | consequence |
|---|---|
| Forge dies after `deploy.started`, before an outcome | next run asks `status`, records the live artifact; if it is the new one, probes run; if the old, the release is `held` with `deploy-adapter-failed` |
| the adapter hangs | the deadline kills its group (the check guard's mechanism, `company.md` section 8); `deploy.failed`; the previous release is *assumed* live **only after** `status` says so |
| `rollback` itself fails | `deploy.frozen`, the company stops deploying, a person is told by exit status (14-class) and by `status` |
| the artifact store loses a kept release | `deploy-no-rollback` for the next deploy; no apply |

### 5.6 What is refused outright

* **State.** A service whose release carries a **data migration**, a schema change or a change to persisted data is not deployed by
  Forge: the repository registry row has `stateless: true` for a `service` (the operator's statement), and a patch that touches a path
  in `migrations/**` or the registry's `state_paths` is `deploy-state-refused` at the release. A rollback cannot undo data; Forge does
  not claim to.
* **Anything that changes spend or topology:** more instances, bigger machines, new hosts, new DNS, new credentials. These are the
  adapter's configuration, the operator's, and a change cannot touch it (it is outside every `publish_allow`).
* **A deploy of a commit or an artifact that is not the approved one.**
* **Push.** `forge company deploy` is not `publish`; it does not push code. Getting the artifact's source to a remote repository stays a
  person's act or `autonomy.md`'s App.

## 6. Operate and evolve

### 6.1 Observations

A product that runs produces numbers. Forge records **integers**, the rule `intents.md` section 4 gives for metrics, because there is
no floating point near a decision (`company.md` section 9).

* The operator's `signals` (operator file) *(designed)*: `{"<name>": {"repo": "diff-api", "env": "prod", "program": "signal_calls.sh",
  "every_hours": 1}}`. The program is run like a check (two arguments, `PATH` only, deadline, output cap, under the check guard) and
  prints lines `SIGNAL <integer>` (the last one decides; no readable line is `signal-unavailable`, recorded, never a value).
  Forge appends `company.signal.observed` (`signal`, `value`, `at`, `release` = the release live at the time, from the journal).
* **Input is a file when it is about users.** A program may read a counter file the operator's collector wrote
  (`intents.md` section 4: "a number about users has to arrive as a file the operator puts in the step's execution directory"). Forge
  adds no network capability, no log reader and no metrics client.
* **The vocabulary is closed.** Which signals exist is the operator file's list; their meanings are the operator's. Examples:
  `health_failures`, `requests`, `errors_5xx`, `p95_ms` (an integer in the program's unit; Forge does not compute percentiles, nor does
  any cancho-tools tool, `company.md` section 14).
* A timer (cron, a systemd timer) runs `forge company observe <dir> <operator-file> now=...` and then `forge company run ...`. Forge has no
  daemon and the design adds none. Because every limit below is enforced from the journal, a timer that fires too often changes cost
  in files, not in behaviour.

### 6.2 From a number to a candidate change

The operator file's `alerts` *(designed)*: `{"<name>": {"signal": "errors_5xx", "above": 50, "for": 3, "kind": "bug", "repo": "diff-api"}}`
means: three consecutive observations above 50 → Forge appends **one** `company.change.proposed` with `source.type: signal`,
`source.ref` = the alert name, `justification: defect` (or `maintenance`), and a body **Forge writes from a template** that contains the
alert name, the signal name, the three values, the threshold and the release id. Nothing else. No second proposal for the same alert
while its change is open (`change-duplicate`).

A signal-origin change is **always `proposed`** and needs `admit:<id>`: Forge noticed a number, and a person decides it is worth money.
It has no repro (no independent authority is attached to a number), so its flow begins with a **triage** step by a person that either
writes the repro and the authority or closes it. This is deliberate: it keeps "the loop" from becoming a path in which a metric
spends the budget unattended.

### 6.3 Business goals: a versioned file the human owns

*Read:* a manifest has `mission`, "kept for the record; it drives nothing" (`company.md` section 3); Intents record why a set of steps
is worth keeping and when to stop (`intents.md`). Neither says what the **business** wants this quarter.

`goals.json` in the company directory *(designed)*, closed shape, edited only by a person:

```json
{ "v": 3,
  "goals": [
    { "id": "g-adoption", "statement": "More programs import the diff library than last quarter.",
      "metric": { "signal": "downloads_week", "repo": "diff" }, "target": { "above": 500 }, "until": "2027-03-31", "priority": 1 },
    { "id": "g-uptime", "statement": "The diff API is available.",
      "metric": { "signal": "health_failures", "repo": "diff-api" }, "target": { "below": 3 }, "until": "2027-12-31", "priority": 2 }
  ],
  "constraints": ["no new third-party dependency", "no stored user data"] }
```

* **Versioning.** Each `run`, `observe` and `release` hashes `goals.json`; when it differs from the last `company.goals.version` record,
  Forge appends one with `v`, `sha256` and `at`. `v` must be greater than the previous (`goals-version-not-increased`). The file is a
  person's: it is in no repository's `publish_allow`; a builder never sees it; a patch that names it is `patch-path-denied`.
* **A change is traced to a goal** by its `justification` (`goal:g-adoption`). A `feature` or `feedback` change without a goal is
  `change-justification-missing`; a goal whose `until` has passed is `goal-expired`. `bug`, `compiler-bump` and `maintenance` need none
  and say so (`defect`, `maintenance`): the trace is complete when every change has a justification, not when every change has a goal.
* **What Forge shows and does not claim.** `trace.md` of the demo (5.2) lists, per goal, the changes in the release and the metric's
  values before and after. **That is correlation, not credit.** Forge does not say a change moved a number; a person reading the
  demo may. `constraints` are text a person reads at the gate and a text the builder is shown in the frame of 4.4; no check of the
  company enforces them. (A constraint that matters is turned into a check by a person: a program that fails when a dependency is added.)
* **Goals vs Intents.** An Intent says "this step is worth keeping until X is not met" and ends in a prune proposal; a goal says "the
  business wants Y by Z" and ends in nothing automatic. They are not merged. A goal may *cite* an Intent id as free text in its
  statement; there is no mechanical link, and if one turns out to be wanted it is a field added to one of them.
* **Forge does not draft work from goals.** Section 6.4.

### 6.4 The line: Forge does not choose work

`company.md` section 1 says the layer "does not choose work, plan, or pivot"; `intents.md` section 2 argues that a person-written
criterion measured by a program is inside that line. This document keeps to it: every change is *caused* by a person (operator source),
by a person's admission of someone else's report (issue source), or by a rule a person wrote firing on a number (signal source, always
admitted by a person, body by template). **A model that reads `goals.json` and signals and proposes features is on the other side of the
line** (it is roadmap M7, "strategy loop", `roadmap.md`), and is not in any slice of this document. If the maintainer wants it, it is
a separate design that reuses the `proposed` state; open question 1.

### 6.5 The brakes

| brake | what it limits | where it lives | refusal |
|---|---|---|---|
| lifetime budget | total spend | manifest `budget` (exists) | `budget-exhausted` |
| rolling cap | spend per `days` | manifest `budget.rolling` | `budget-exhausted` (window rolling) |
| per-change cap and attempts | one change's spend | manifest `budget.per_change` | `budget-exhausted` (window change), `change-attempts-exhausted` |
| intake rate | proposals per window, open per repo | manifest `intake` | `change-rate-limited` |
| release rate | deploys of one repository per day | operator file `targets.<t>.max_per_day` (default 2) | `deploy-rate-limited` |
| freeze | all deploys of a repository after a failed rollback | journal `deploy.frozen`, lifted by `unfreeze:<repo>` | `deploy-frozen` |
| human: admit | whether a non-operator report becomes work | gate `admit:<id>` | `gate-open` |
| human: demo | anything that changes what prod does | gate `demo:<release id>`, hash-bound | `gate-open`, `demo-hash-mismatch` |
| human: spend | anything that changes what prod costs | not a Forge verb: the adapter's configuration (5.3, 5.6) | no deploy path to it |
| protected paths | the judge (policy, registry, goals, audits, CI) | `publish_deny` and `autonomy.md` section 4 | `patch-path-denied` |

**"Human gate for anything that changes prod behaviour or spend", read against the code.** *Behaviour*: the only path to a prod change
is a release, and a release needs an approved, hash-bound demo; the one deploy act without a decision (the rollback) restores an
already-approved artifact. *Spend*: no change can alter the adapter, targets or credentials, and tokens are bounded by 2.3. The hole is
tokens spent *by the loop on changes nobody asked for*: closed by `admit:` for everything except the operator's own `bug` and
`compiler-bump`, which are a person's act already.

## 7. Authority and threat model deltas

### 7.1 What each piece adds

| piece | new capability | unchanged | refused / still missing |
|---|---|---|---|
| `repos` rows, kinds | none: data in two files. `forge company check` gains refusals | the manifest grants nothing | a manifest naming a command or a path |
| segments and snapshots | rename of a file inside the company directory and a write of `snapshot/*`; `forge` already holds `Fs("")` (`isolation.md` section 2 table) | replay is the only state | deleting or editing a sealed segment |
| `repo.change` and the copy of `base` | a read of the repository checkout (the gate runner already makes throw-away checkouts) | acceptance = Forge-run check | the worker holding the real checkout |
| the patch publish | the publish worker applies a patch: a **new authority report** (`docs/authority-repo-publish.txt` is the template: `Exec("/bin/sh")`, files, clock, no network); the commit message says so (`CLAUDE.md`) | never pushes | a push, opening a PR |
| the provisioner | `fs_write` beneath `steps/` only | | any other path |
| `flows`, change records | none beyond the journal | | |
| `audit/regress/` write | Forge writes into the company directory from an accepted artifact | the audit is the operator's | the builder writing there |
| `deploy` verb | **start the operator's adapter** (`Exec` narrowed to the adapters directory by `exec_spawn_under`, as the workers directory is), write `releases/` and the journal. **No network, no secret** in Forge: the adapter holds them. A new worker program or a new row in `forge`'s report, *whichever the slice chooses, with its pinned report* | the empty environment; the deadline; the group kill | a hostname, address or command from data |
| probes and signals | none in Forge (they are check programs) | the check guard | reach of the *program* is not bounded by Forge |
| `observe` | a writer of `company.signal.observed` | | |

The principle of `threat-model.md` section 4 holds: **publish or deploy anything needs human approval per release, recorded as a
journal event**; a worker has no identity in that namespace. M6 of `roadmap.md` is "controlled operate loop: ... approval required for
deploy and remediation"; this design is that milestone's content, and it keeps its exit criterion ("nothing deploys without a recorded
approval") with one stated exception: the single automatic rollback to an already-approved artifact (5.4). If the maintainer reads that
exception as inside the exit criterion's words or outside them, open question 3 is the place.

### 7.2 Threats this design introduces

| id | threat | consequence | control in this design | status |
|---|---|---|---|---|
| L1 | prompt injection in an issue, a feedback note or a goal's text | the builder writes something the requester wanted | frame (4.4); the judge ignores the text; protected paths; patch bounds; human demo | latent while the agent has no tools; **not measured** (M-4) |
| L2 | injection through telemetry | same | no free text from telemetry reaches a body (6.2) | designed |
| L3 | an attacker floods the tracker | budget and attention | file intake, `max_per_window`, `max_open_per_repo`, `admit:` | designed |
| L4 | the builder weakens the audit that judges it | a bad change merges | the audit is outside the builder's directory; `audit-shrank`; `audit/` and the contract in `publish_deny` | designed; only as good as the operator's placement |
| L5 | a stale approval is reused | a deploy nobody saw | the approval counts only after the thing and only for its hash (5.2); `gate-unknown` on nothing to decide | designed (for the gates here; not for the existing `human_gates` of a manifest, `company.md` section 14) |
| L6 | the adapter's credential leaks into a log, journal, `pr.md` or a prompt | prod takeover | Forge never reads or passes it (5.3); empty environment; the adapter outside the company directory; `deploy-secret-in-company-dir`; **the builder runs where it cannot read it** (7.3) | designed; depends on isolation |
| L7 | the builder or a check reaches the adapter's program or the secret file | same | second unix user (`isolation.md` Layer 1) or a sandbox (Layer 2) | **not built** |
| L8 | a bad release reaches prod | users see wrong behaviour until a probe or a person notices | staging first, demo, probes, rollback, at-most-one auto rollback and freeze, `keep_releases` | designed; probes see availability only |
| L9 | the rollback itself breaks | prod stays down | rehearsal on staging; freeze; exit status and `status` | designed; unmeasured |
| L10 | data loss from a deployment | irreversible | stateless only; `state_paths`; migrations refused (5.6) | designed |
| L11 | two companies, or a company and a person, race on one repository | lost work, a wrong pin | `repo-locked` within a company; `repo-checkout-dirty`; one-owner is a convention | partial (open question 8) |
| L12 | the journal grows without bound | slow verbs, disk | segments, snapshots, caps in 4.1, `intake` limits | designed; replay time **unmeasured** (M-3) |
| L13 | personal data in an append-only journal | cannot be deleted | hashes only in the journal; bodies as deletable files (2.2, 4.4) | designed |
| L14 | a compromised compiler revision enters through a `compiler-bump` | every repository builds with it | the target is chosen by a person; the gate and `selfhost` of `autonomy.md` section 4; `T16` (the pin) remains partial | designed; no signature check exists |
| L15 | the demo is gamed by a builder that sees the audit | green and wrong | `autonomy.md` section 8 (oracle outside the builder, shown beside the builder's score) | designed |

### 7.3 Isolation is a precondition of any deploy verb

`threat-model.md` section 5: *"Until workers run in an OS sandbox, a worker is trusted not to be malicious, only to be possibly wrong."*
That sentence is acceptable while the worst thing a wrong worker can do is write bad code that the checks catch and a person judges.
It is not acceptable once the same user account, on the same machine, can reach a production credential. So:

* **No `forge company deploy` is implemented before** [`isolation.md`](isolation.md) Layer 0 (the hostile-worker suite and the preflight
  probe) exists, and Layer 1 (a separate unix user for the builder; the audit and the key and the adapter and its credential outside
  its reach) is in place. The prerequisite is enforced at run time: the operator file for a company that has any `targets` must carry
  `isolation_level` of at least `1`, and `deploy` refuses with `deploy-isolation-unmet` unless the preflight probe of that level
  passed for this operator file in this run (`isolation-probe-escaped`, `isolation-unavailable` and `isolation-level-unmet` are that
  document's tags, *designed*).
* `isolation.md` records which of its probes are measured on this machine and which are not; this design adds one probe to Layer 0
  *(designed)*, **H9: a worker started as the builder cannot execute the adapter, read its credential or write beneath `releases/`**.
* **Layer 2 (a sandbox for the builder) is required before the builder is shown text from a source the operator does not control and
  has tools.** While the builder is the text-only agent, Layer 1 is the floor; the day it has tools, Layer 2 is.

### 7.4 What a bad deploy can do, stated plainly

With every control above working: it can serve wrong behaviour of a stateless service to users for as long as it takes a probe, the
rollback or a person to act, and it can cost the compute of one extra rollout. It cannot spend more than the adapter's fixed
configuration allows, reach another service, change the credential, or keep itself deployed after a failed probe. With a control not
working (a probe that sees only availability; a demo that a person approves without looking; an adapter whose own configuration is
broader than documented): the first is the audit's and the human's job, the second is the human's, and the third is the operator's, and
Forge cannot tell them apart from a good deploy. This document does not claim otherwise.

## 8. The smallest first slice, and the order of the rest

### 8.1 Slice 1: `repos` and a `repo.change` step on an existing checkout, no deploy

The smallest unit that proves the thing the maintainer asked first: **the same company, a second piece of work, on a repository that
already exists.** Nothing else of this document is needed for it: no change records, no flows, no clock, no deploy.

* **Manifest.** `repos` (2.1) and a step's optional `repo` field naming an id (a closed key of the step shape), `task_type` `repo.change`
  offered by the builder role, `check` required as for any builder step.
* **Operator file.** `repos.<id>` with `slug`, `checkout`, `kind`, `compiler_rev`, `publish_allow`, `publish_deny`, `max_patch_files`,
  `max_patch_lines`. `branch` and `gate` are used from the autonomy registry shape; `forge registry check` of `autonomy.md` section 10 step
  1 is not required (the slice reads the rows it needs and rejects the rest of the shape as `operator-invalid`).
* **Runner.** For a `repo.change` step: materialise `ev/base/` from the checkout at its branch tip (`base` recorded in the admission
  record), write `change.txt` from the step's `input` and `scope.txt`, run the builder worker with the adapter's patch mode (**stand-in
  only in this slice**: a script that writes a patch; the real `cancho-build` has no such mode, 4.2), bound the patch, hash it, run the
  step's check (which applies it to a second copy and runs the repository gate), accept on a full score. Artifact name
  `change.patch`.
* **Publish.** Not in this slice. The accepted patch is in the step directory with its digest in the journal; applying it is a person's
  `git apply` until slice 2's publish.
* **Not in this slice:** change records, flows, `at`/`now`, segments, rolling budget, audit growth, intake, release, deploy, signals, goals.

**Tests named for the slice** (in the style of the existing ones: `cancho test` unit tests in `tests/*_test.cho`, and conformance cases in a
new `tests/conformance/company_change.sh` run by `scripts/gate.sh`; every refusal reached, per `CLAUDE.md`):

| test | reaches |
|---|---|
| `test_a_manifest_with_no_repos_is_valid_and_unchanged` (the whole current corpus passes untouched) | back-compat |
| `test_a_repos_row_with_a_kind_outside_the_three_is_repo_kind_invalid` | `repo-kind-invalid` |
| `test_two_repos_with_one_id_are_repo_duplicate` | `repo-duplicate` |
| `test_a_step_naming_a_repo_the_manifest_does_not_list_is_repo_unknown` | `repo-unknown` |
| `test_a_repo_change_step_without_a_repo_is_refused` / `..._with_a_repo_on_another_task_type_is_refused` | the manifest shape |
| `test_an_operator_repo_row_without_a_40_hex_compiler_rev_is_operator_invalid`, `..._with_a_dotdot_in_publish_allow_...`, `..._deny_wins_over_allow` | form of the operator row |
| `test_a_row_whose_kind_disagrees_with_the_manifest_is_repo_kind_mismatch` | `repo-kind-mismatch` |
| `test_a_pin_file_that_disagrees_with_compiler_rev_is_repo_pin_mismatch` (a git repository made in the gate with a `.cancho-rev`) | `repo-pin-mismatch` |
| conformance `good path`: stand-in writes a patch, Forge hashes it, the check applies it to a second copy, runs the repository's gate, `TOTAL n/n`; accepted with `change.patch` and its digest | acceptance for a patch |
| conformance `a patch outside publish_allow` / `inside publish_deny` | `patch-path-denied` |
| conformance `a patch with a rename`, `a binary hunk` | `patch-kind-invalid` |
| conformance `a patch over max_patch_lines` | `patch-too-large` |
| conformance `a patch made against another base` | `patch-not-applicable` |
| conformance `the builder edits ev/base only`: the checkout's tree hash is the same after | the checkout is untouched |
| conformance `a checkout with an untracked file` | `repo-checkout-dirty` |
| conformance `a checkout changed under the step` (a stand-in that writes into the real checkout path it was never given: it cannot, so the test plants a change *between* materialise and accept) | `repo-checkout-changed` |
| conformance `a patch edited after acceptance` (the digest differs at the next step that needs it) | `artifact-invalid` (existing) |
| conformance `a lying worker` (claims `done`, patch does not pass the gate) | `check-failed`, held, `retry:` frees it |
| conformance `kill and resume` mid-step | no redo of an accepted step (existing guarantee, now for this task type) |
| authority: `scripts/gate.sh` authority comparison unchanged for `forge`; any new worker has its own pinned report | CLAUDE.md |

The slice is **done** when those are green with the stand-in. It says nothing about whether a model can write such a patch (M-1) and
must be reported that way, as `company.md` reports every number.

### 8.2 The order of the rest

Each ends with a gate that reaches its tags and, where it spends money, a measured run recorded in `spike/RESULTS.md` (the rule of
`autonomy.md` section 10).

| # | slice | needs first | measure with a real model **before** building |
|---|---|---|---|
| 1 | `repos` + `repo.change` with a stand-in (8.1) | nothing | **M-1** |
| 2 | provisioner, **change records** (`company.change.*`), `admit:`, `flows` (derived steps), operator-source intake, `change add`; publish a patch on `forge/<change id>` with per-change provenance | 1 | M-2 |
| 3 | `bug` flow with the repro step; `audit/regress/`; `audit-shrank` | 2 | M-5 |
| 4 | time (`now`, `at`), `rolling` and `per_change` budget, `change-rate-limited` | 2 | none (no model): a unit-test slice |
| 5 | segments, seal, snapshot, `verify` | 4 | **M-3** (replay cost; no model) |
| 6 | `compiler-bump` as a change (needs `pin.bump`, `autonomy.md` section 10 step 4) | 2, autonomy 4 | M-7 |
| 7 | `issue` intake from files; retention; `goals.json`, justification, trace | 4 | **M-4** |
| 8 | release object, demo builder, `decide` hash binding (the same piece as step 5 of `autonomy.md` section 10; build once) | autonomy 5 | the demo on a past change |
| 9 | **isolation Layer 0 and 1** (`isolation.md` steps 0 and 1) | 8 | its own probes |
| 10 | targets, `deploy dry-run`, `apply` to **staging only** against a stand-in adapter; probes as checks; rehearsal; freeze | 8, 9 | **M-6** |
| 11 | prod deploy with the demo gate; auto rollback | 10 | rehearsal measured on a real staging |
| 12 | signals, `observe`, alerts → candidate changes | 4, 10 | M-8 |

Slices 1 to 7 touch no network and deploy nothing; 8 builds the object both documents need; **9 is a hard precondition of 10**.

## 9. What to measure before building each, and how

None of these has been run. Each is a measurement with a stated question, an input, a reading and what would change the design. They are
ordered by when the answer is needed. Cost figures are not given; they are the first output of the run.

| id | question | run | reading | changes the design if |
|---|---|---|---|---|
| **M-1** | can a Haiku-class builder produce a correct patch against an existing file from a request? | replay as change requests the defects the project already has with known fixes: cancho-code #99 and #103 (`self-repair.md` section 11) and the `test_script_7` plan in cancho-diff; each against the real file at the base commit, `fix` or a patch-mode `cancho-build` if one exists, N attempts each, with the real checker | patches that pass the repository gate and the fixture / attempts; tokens; dollars; of those that pass, how many a human reviewer judges correct (not merely passing) | the pass rate is low: slice 2 onward waits for `repo.patch` in Cancho Code; or `--hint` from a person is part of the flow |
| **M-2** | what is a change's real cost distribution? | the same changes through slice 2's flow with the real model | cost per change, attempts, how many hit `per_change` | `per_change.max_cost` default; whether `max_attempts` of 6 is right |
| **M-3** | when does replay of the company journal become slow? | synthetic journals of 10^4, 10^5, 10^6 records (written by a test program), time of `status` and `run` replay | seconds and memory against count | segmenting is not needed before N records; the size for sealing |
| **M-4** | do the frame and the judge hold against adversarial change bodies? | a corpus of bodies that ask for protected-path edits, scope widening, an exfiltration string, "approve", a payload for the shell; each run as a change with the real model | patches that touch denied paths (should be refused by `patch-path-denied`), patches that pass the gate while doing something the corpus asked, and any text that reaches a path, argv or shell | how much weight the frame carries; whether `issue` intake stays gated by `admit:` for good |
| **M-5** | do repro steps produce red-on-base cases from reports? | bug reports of past defects, repro step with a real model | repro red on base / attempts; wrong-red (red for the wrong reason, checked by a human) | whether the repro may be model-written or must be a person's |
| **M-6** | what is the probe false-failure rate and the rollback time on a staging target? | a stand-in then a real staging host: 100 deploys of an unchanged artifact, and 20 with an injected fault | false failures, time to detect, time to roll back | `soak_seconds`, the probe contract, the freeze threshold |
| **M-7** | does a compiler bump through the change flow match the manual one? | the pin bump of `autonomy.md` section 5 replayed on the real repositories in dry-run | rows landed / expected, `pin-not-landed` count | policy for `compiler-bump` |
| **M-8** | do alerts fire at useful rates? | signals from a real running service over weeks | alerts per week, changes admitted / proposed | `every_hours`, `for`, thresholds |

Baseline note, as in `self-repair.md` section 8: the manual work of the first weeks (the cancho-diff run, the pin bumps) was not timed,
so there is **no baseline** for "faster" or "cheaper than by hand"; record the next ones before building.

## 10. Open questions that only the maintainer can decide

Most important first, each with a recommendation. None blocks slice 1.

1. **May Forge propose work nobody asked for?** (A model reading `goals.json` and signals and drafting features.) This is the line
   `company.md` section 1 and `intents.md` section 2 draw, and it decides whether "evolve it according to the business use" means
   *people* evolve the product with Forge doing the work, or Forge evolves it. **Recommendation:** no, for everything in this document.
   Signals produce templated candidates a person admits; goals trace and are shown; a drafted-feature loop is its own design (roadmap
   M7) after a year of changes and a measured admit/reject record exists to calibrate it against.
2. **What is the first deploy target, who owns its credentials and who does the first deploy?** Everything in section 5 is abstract
   until one adapter exists. **Recommendation:** one staging host the maintainer owns, a stateless service, an adapter script that
   pulls an image or binary by digest, a credential held by a second unix user; the first deploy of a repository is done by a person,
   once, and recorded as a release (it is also what makes `deploy-no-rollback` satisfiable); prod waits until M-6 has run.
3. **Is the automatic rollback to the last verified release inside "nothing deploys without a recorded approval"?** The release it
   restores was approved earlier. **Recommendation:** yes, at most once per release, then freeze; a rollback loop is worse than a
   person waking up. If the answer is no, a rollback needs `rollback:<release>` approved, and the 3 a.m. case is a person's phone.
4. **Who merges, until `autonomy.md` merge-by-policy exists?** `self-hosting.md` section 5 says a person; the maintainer's rule is that
   humans see a demo, not merges. **Recommendation:** in slices 1 to 7 a person merges, with the diff and the change's evidence on one
   page (the provenance); from slice 8 the merge is covered by the policy and the demo, and this document adds nothing to
   `autonomy.md`'s decision.
5. **Who may cause work?** Operator only, or also trusted authors of issues, or anyone (gated)? **Recommendation:** operator, and issues
   through the operator-run file intake with `admit:` on every one, rate-limited; revisit after M-4. Never auto-admit by author name
   (a login is an identifier an attacker can choose in a fork or a bot).
6. **May Forge read a clock?** A rolling cap, `until`, release rate and the soak need time; `intents.md` chose "no clock; `now` is an
   argument". **Recommendation:** keep it: a systemd timer passes `now=`, `at` is recorded, `clock-went-back` guards. The cost is a
   wrapper script; the gain is that replay and every test stay deterministic and Forge's authority report gains no `clock` row for it.
7. **What counts as spend?** Tokens only (this document), or also hosting? **Recommendation:** tokens only in Forge; hosting is the
   adapter's fixed configuration and a change to it is a person's, so "spend" has one gate by construction. Revisit if a service's cost
   is variable (autoscaling), because then a deploy can change spend without touching the adapter.
8. **One company per repository, enforced how?** **Recommendation:** one company per product (a mission with its repositories), the
   repository registry shared with `autonomy.md` as one file, and a `repo-owned` refusal when a registry row names an `owner` company
   id other than this manifest's. This needs the `owner` field in the registry.
9. **Where does `goals.json` live and who may change it?** **Recommendation:** the company directory (so the operator, who is the
   author, owns it), hash-recorded on use, never writable by any worker; a goal's `target` is a measurement, its `statement` is text a
   builder is shown.
10. **Retention.** How long do sealed segments, `releases/<id>/` artifacts and change bodies live? **Recommendation:** journal segments
    forever (small, and the point of the guarantee), kept release artifacts `keep_releases` (3), bodies of terminal changes deleted after
    90 days by `change forget`, with the hash kept. This is also the answer to personal data in issues; the maintainer should confirm
    it against the obligations of wherever the product is used.
11. **Which kinds does the product need in its first year?** The table of 2.1 has `library`, `program`, `service`. **Recommendation:**
    exactly those; a site, an app, a data pipeline are new kinds, and each is a new design.
12. **Is publishing a library (the registry credential, the tag) ever Forge's?** `autonomy.md` section 7 says a credential Forge does
    not hold. **Recommendation:** keep it a person's, one decision per release, with the demo's commit ids. The gain from delegating is
    small and the credential is the thing an injected change would most want.

## 11. What this document does not do

It does not make a company run for years: nothing here is built. It does not claim a model can patch an existing repository (M-1 is the
first thing to find out and may say no). It does not make deployment safe: it moves the question to an adapter, a set of probes and a
human, and names what each can and cannot see. It does not choose a hosting provider, a monitoring system or an identity for the
person who approves. It does not remove the person from the loop: it moves them from merges to demos, which is exactly the claim to
measure, and which `autonomy.md` section 9 and `self-repair.md` section 8 also say has no baseline yet.
