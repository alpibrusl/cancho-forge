# The company layer

**Status, stated first.** The company layer is built and tested with stand-in workers. **No company has been run with a real
model**: every number in this document comes from the gate's conformance programs, in which the builder is the real Cancho Code
adapter over a *stand-in* build tool (`scripts/standin_cancho_build.sh`), the qa step runs the real gate runner on a throw-away git
checkout, and the analyst runs a stand-in tool (the real `tally` and `jsonq` were run once during development; the gate skips that run unless `FORGE_CANCHO_TOOLS` is set and does not re-run it otherwise). The layer has not built StatusLite, has not
spent a dollar, and says nothing about what a model-driven company costs or achieves. See "What is not measured" at the end.

## 1. What it is

The company layer reads a **manifest** (`company.json`: a closed JSON shape naming a mission, a model, a budget, human gates and an
ordered list of **steps** with roles and dependencies) and runs its steps through Forge's own workers, one at a time, in dependency
order: a builder step through the Cancho Code adapter (`forge build`'s run), a qa step through the gate runner (`forge gate`'s run), an
analyst step through the tool runner, a product step by a person's recorded decision. It does what Forge already did for one task, for
a list of tasks:

* a step becomes `accepted` only when **Forge runs the step's check program itself** against an artifact Forge hashed itself, and the
  check scores a full pass; a worker's `done` is a claim and never acceptance;
* a **human gate** blocks a step until `forge company decide` records a decision;
* a **budget** derived from the tokens a model step used (read from its `usage.jsonl`, priced from a price table) stops new model steps;
* everything the company decided is in an append-only **company journal**, and a run killed at any point and run again completes
  without redoing an accepted step.

What it is not: it is not a scheduler, an LLM "CEO" or a deployment system; it does not choose work, plan, or pivot; it runs the
steps a person wrote, one at a time, and stops at the first thing that needs a person. "Runs a company" in this document means only
that, and only as far as the sections below say it was measured.

Design: [`docs/superpowers/specs/2026-10-27-forge-company-layer-design.md`](superpowers/specs/2026-10-27-forge-company-layer-design.md)
(corrected in place where the implementation settled or contradicted it). Refusal tags: section 12 here and
[`architecture.md`](architecture.md) section 7. Kill and resume: [`architecture.md`](architecture.md) section 4.4.2.

## 2. Files and directories

```
<company-dir>/                absolute path; the operator's, owned by the person running the company
  company.json                the manifest (this exact name for `status`, `decide`, `run`)
  company.journal             the company journal (section 7); created by the first `decide` or `run`
  lock                        the writer lock (a flock): held by `decide` while it writes and by `run` for the whole run
  check.lock                  held by `run` while a check runs (the check guard watches it, section 10)
  prices.json                 the price table the manifest names (`budget.price_table`), a plain file name in this directory
  audit_lib.sh, signatures.txt ...   check programs and contract files the manifest names, plain file names in this directory
  steps/<id>/                 one Forge workspace per worker step: journal.jsonl (the task journal), lock, brief.txt
  steps/<id>/ev/              the step's execution directory. THE OPERATOR CREATES IT for every worker step
                              (builder, writer, qa, reviewer, analyst) before the first run: the language has no mkdir,
                              so a missing one is `step-dir-missing`. Forge puts the artifact, needs-*, needs.json and
                              contract.txt there; the worker writes its evidence there.
<operator-file>               OUTSIDE <company-dir> (section 4)
```

**The trust model (one statement; [`architecture.md`](architecture.md) section 7 says the same).** The company directory, its check
programs, its price table, its contract files and `company.journal` are **trusted: they are the operator's**. The person who runs the
company is the manifest's author; nothing below contains an author who is not trusted. The operator file lives outside the company
directory as **hygiene** (what grants programs and checkouts is kept apart from what a manifest edit touches), not as a boundary against
a hostile author. Acceptance holds only against:

* a **builder that writes nothing outside its execution directory** (`steps/<id>/ev`). The adapter's arguments name only that directory,
  but nothing confines the build *process*: Cancho Code's own tests run with no `Fs`, so a model-written program does not reach the file
  system when it is tested, and that is the whole of the containment;
* an **audit that does not run the artifact with ambient authority** (the check runs with Forge's user, `PATH` only, under the check
  guard; if it executes the artifact, the artifact runs with all of that).

**Not contained:** a manifest author who is not the operator. Such an author can name any program of the company directory as a
check (and so run it with Forge's authority), edit `company.journal` (accept a step by hand, approve a gate, erase spend), put an
already-approved gate on a product step (accepted on that decision alone), or point a contract at any file of the directory. That is why
the operator is the author. Both limits are listed in section 14.

Every path on the command line is absolute with no `..` (the rule of every Forge verb; a relative path is `path-invalid`, exit 2).
`forge company check` takes the manifest file itself, so it can check a manifest before it is in a company directory.

## 3. The manifest

A JSON file of at most 1 MiB, parsed against a **closed** shape: a key the shape does not have is `manifest-unknown-field`, a key
written twice or with an escape is `manifest-malformed`. It *declares requirements only*; no field grants a capability (design
4.1). In particular **the manifest cannot name a tool, a worker, a repository, a checkout, a compiler or an agent command**: those are
the operator's (section 4). It CAN name programs of the company directory as checks, and Forge runs them: so editing `company.json`
does widen what Forge runs, within the company directory, which is why the company directory and its author are trusted (section 2).

```json
{
  "id": "demo",
  "mission": "A small status page library (kept for the record; it drives nothing).",
  "model": { "provider": "anthropic", "name": "claude-haiku-4-5" },
  "budget": {
    "input": 2000000, "output": 400000, "cache_write": 200000, "cache_read": 1000000,
    "max_cost": 2,
    "price_table": "prices.json"
  },
  "human_gates": ["product-brief", "ship"],
  "roles": ["builder", "qa", "analyst", "product"],
  "steps": [
    { "id": "brief", "role": "product", "task_type": "none", "needs": [],
      "input": "Approve the product brief.", "gate": "product-brief" },
    { "id": "lib", "role": "builder", "task_type": "project.build", "needs": ["brief"],
      "input": "Write the uptime library described in brief.txt.",
      "check": "audit_lib.sh", "contract": "signatures.txt" },
    { "id": "gate", "role": "qa", "task_type": "repo.gate", "needs": ["lib"],
      "input": "Run the repository gate.", "check": "audit_gate.sh" },
    { "id": "uptime", "role": "analyst", "task_type": "tool.run", "needs": ["lib"],
      "input": "Recount the checks.", "check": "same_number.sh" },
    { "id": "ship", "role": "product", "task_type": "none", "needs": ["gate", "uptime"],
      "input": "Approve the release.", "gate": "ship" }
  ]
}
```

(`forge company check` answers `valid: demo, 5 steps` for exactly this text; JSON has no comments, so the notes are below.)

* `id`, `mission`: names the company and keeps the brief in words. `mission` and every step `input` are text of at most 16 KiB with
  no NUL. Nothing is driven by `mission`.
* `model`: `provider` and `name`. A builder step is built with this provider and model, and the price table is looked up with them.
* `budget`: **all six keys are required** (`budget-missing` / `price-table-missing`). `input`, `output`, `cache_write`, `cache_read` are
  token ceilings (non-negative integers; a ceiling may be reached and not passed; a ceiling of 0 does not mean unlimited, but it does **not** stop the first model step either: the budget is checked only between model steps, so with every ceiling 0 and nothing spent the first builder or writer step still starts, and everything after it is refused).
  `max_cost` is **whole US dollars**. `price_table` is a plain file name (1 to 128 bytes of letters, digits, `-`, `_`, `.`, not starting
  with `.`) of a file in the company directory. See section 9.
* `human_gates`: the names a step's `gate` may use. (Besides these, every step id makes a *retry gate* `retry:<id>`, section 5.)
* `roles`: the roles in use. A step whose role is not listed is `role-unknown`.
* `steps`: 1 to 256 steps. `id` is a name (1 to 64 bytes of letters, digits, `-`, `_`, `.`); `role` one of the six; `task_type` the one
  its role offers (section 4; any other is `task-type-unsupported`); `needs` the ids of steps that must be `accepted` first (a need that
  is no step is `step-needs-unknown`, a ring or a self-need is `step-cycle`); `input` the step's brief (what a build is asked to build; the
  text is decoded and written to `steps/<id>/brief.txt`); `check` the name of a program in the company directory (**required for a builder
  or writer step**, `check-missing`; `forge company run` also requires one for qa, reviewer and analyst steps, and for a product step
  that has no gate); `contract` (optional, **builder or writer only**, `contract-role-invalid` otherwise) the name of a file in the
  company directory holding required signatures (section 8); `gate` (optional) a name from `human_gates` (`gate-unknown`).

The order in which faults are looked for, so that a manifest with two faults is always refused for the same one, is the header of
`src/company_manifest.cho`.

## 4. The operator file

`forge company run <company-dir> <operator-file>`. The operator file is **the second argument of `run`** and nothing else reads it
(`check`, `status` and `decide` never need it). It is a closed JSON object, at most 64 KiB, in which every path is absolute and every
string is plain (no escape) and at most 4096 bytes. It is the operator's, not the manifest's: the manifest says *what* is wanted, this
file says *which programs and which repositories may be used for it*, the way the arguments of `forge build` and `forge gate` do. It
**must live outside the company directory** (a path inside it, judged by its text, is `operator-invalid` with a `reason:` line): the
company directory and the operator file are both the operator's (section 2), and keeping the grants out of the directory a manifest
edit touches is hygiene, not a boundary. (A symbolic link from outside pointing inside is not seen.)

| key | meaning | needed by |
|---|---|---|
| `workers` | directory holding the worker programs `cancho_code`, `gate_runner`, `check_guard` and `tool_run` (built from `workers/*.cho`) | every run (`check_guard` by every check) |
| `tools`, `checker`, `agent` | `forge build`'s `<tools>`, `<checker>`, `<agent>`: the directory of `cancho-build`, the compiler it calls, the agent command | every builder or writer step |
| `guide` | `forge build`'s `guide=PATH`: the plan guide a builder or writer step's `cancho-build` is started with (`--guide <path>`, carried in the worker request). Absolute, and held at parse time to the rule `forge build` holds its guide to (`gate_task.path_ok`: `A-Za-z0-9._/-` only, no `..`, at most 512 bytes); Forge does not open it. Without it the tool is started with no `--guide`, which the real `cancho-build` refuses unless the step's workdir already holds a valid `plan.json` | optional; in practice every builder or writer step |
| `gates` | `{"<step id>": {"repo", "revision", "checkout"}}`: what a qa or reviewer step reports the gate of; `repo` must be on the gate runner's allow-list, `revision` a 40-hex commit, `checkout` an absolute path | each qa or reviewer step |
| `analyst_tools`, `granted_tools`, `analysts`, `tool_timeout_ms` | the analyst's tools, section 13 | each analyst step |
| `build_timeout_ms`, `gate_timeout_ms`, `check_timeout_ms` | deadlines in ms, 10000 to 86400000; defaults 3600000, 900000, 600000 | optional |
| `attempts`, `agent_seconds`, `rounds`, `plan_seconds`, `jobs` | `forge build`'s trailing `attempts=N` ... `jobs=N`: the build tool's ceilings for every builder or writer step (`--attempts`, `--agent-seconds`, ... in its argument vector, carried in the worker request). Whole numbers (`json.fits_int`: not `30.0`, not `"30"`) held at parse time to the ranges `build_task.operator_checked` holds them to: attempts 1 to 20, agent_seconds 1 to 3600, rounds 1 to 10, plan_seconds 1 to 7200, jobs 1 to 64; defaults 4, 30, 3, 900, 4 (`step_run.build_spec`). Out of range or of the wrong type is `operator-invalid` with `reason: <key> is not a whole number from <low> to <high>` (the first wrong one, in this order). `agent_seconds` is the deadline of ONE agent call: a model whose calls take longer than it (statuslite run arm-a-1: Haiku 5.5 calls of 64 to 121 s against the fixed 30) cannot finish a unit | optional; one value for every build step of the run |

A key outside this shape, a relative path, a wrong type or a timeout outside its range is `operator-invalid`, and so is a missing key a
step needs (checked when the step starts, before anything is admitted). These are checks of form only; every value is checked again by
what uses it, so the file grants nothing the workers' own checks do not allow.

## 5. The verbs

All paths absolute. Everything is printed on standard output (the usage text goes to standard error). `status` and `check` write
nothing and take no lock.

### `forge company check <manifest.json>`

Validates the manifest. Prints `valid: <id>, <n> steps` (exit 0) or `refusal: <tag>` (exit 1: any manifest refusal, including a file that is
not there, unreadable or over 1 MiB, which is `manifest-malformed`). Exit 2: usage, or `refusal: path-invalid`.

### `forge company status <company-dir>`

Reads `company.json` and `company.journal` (no journal is a company where nothing happened yet). Prints one `<id> <state>` line per step
(states: section 6), then
`spend: input N output N cache_write N cache_read N`, then `open gates: a b` (the distinct gates, in step order, of steps that are not
accepted and whose gate has no decision; `none` when there are none; a step that is still `waiting` on a need counts), and
`torn tail bytes: N` only when the journal ends in an incomplete line (status does not cut it). Exit 0; 1 for a manifest refusal, or
when the replay refuses (`journal-corrupt` / `event-malformed` with `line: N`, after the state that replayed before the bad line);
2 usage or `path-invalid`; 3 `error: cannot read company.journal`. It shows tokens, not cost, and **does not show a held step**: a
step whose check failed is `ready` here (see "Not done").

### `forge company decide <company-dir> <gate> approved|rejected <reason...>`

Records a human decision (`company.gate.decided`): the gate, the verdict, the reason (the remaining arguments joined by spaces, 1 to 1024
bytes) and the operating-system user (`USER` read from `/proc/self/environ`; `unknown` when there is none, **Linux only**). It
authenticates nobody: it is one operator on one machine, and the record is a record, not an access control. It takes the writer lock,
refuses a corrupt journal, cuts a torn tail, appends and syncs, and prints `gate <gate>: <verdict>`. The last decision on a gate wins, so a
rejected gate can be approved later (a new entry, never an edit). Two kinds of gate name are accepted:

* a name in the manifest's `human_gates`;
* **`retry:<step id>`** for a step of the manifest: the decision that lets the run start a step *held* by a failed or unavailable check
  (section 8). Only an `approved` recorded **after** the hold frees it.

Anything else is `refusal: gate-unknown`. Exit 0 recorded; 1 refused (`gate-unknown`, a manifest refusal, `journal-corrupt` with `line: N`,
`workspace-locked` while a run holds the lock); 2 usage (fewer than one reason word, a verdict that is neither word, a reason over
1024 bytes) or `path-invalid`; 3 an I/O error (`error: cannot take the lock ...`, `cannot read`, `cannot cut`, `cannot write`). Nothing is
written on any refusal.

### `forge company run <company-dir> <operator-file>`

Takes the company lock for the whole run, then, round after round: replays `company.journal` (a torn tail is cut; a corrupt journal is
refused as `status` refuses it), asks the scheduler what to do next (`company_run.next_action`, pure), and does that one thing. Nothing
is carried from one round to the next but what the journal says. Printed lines: `refusal: <tag>` with the lines that go with it
(`step: <id>`, `gate: <name>`, `score: a/b`, `reason: ...`, `artifact:`, `need:`, `contract:`, `exit: N`, `held: ...`, `retry: forge company
decide <dir> retry:<id> approved <reason>`, `line: N`), `accepted: <id>` for each step accepted in this run,
`reaped: <task>` for a stale build it stopped, `worker-error: <code>` for a tool runner's refusal, `stopped: signal`, and finally
`done: steps accepted N`. A worker step also prints what `forge build` or `forge gate` prints.

| exit | meaning | printed |
|---|---|---|
| 0 | every step is accepted | `done: steps accepted N` |
| 1 | refused before or between steps: the manifest, the journal, the operator file, the price table, a missing step directory, a step no worker can run, a tool the operator did not grant, a lock another writer holds | `refusal: <tag>` |
| 2 | usage, or a path that is not absolute | `refusal: path-invalid` (usage prints nothing on stdout) |
| 3 | I/O error: the lock, the journal, a file Forge cannot write, or the run did not settle | `error: ...` |
| 10 | waiting for a human gate | `refusal: gate-open`, `gate: <name>`, `step: <id>` |
| 11 | blocked: a gate was rejected and nothing else can start (the defensive `step-cycle` shares the code) | `refusal: gate-rejected`, `gate:`, `step:` |
| 12 | the budget is spent and a model step is held back by it | `refusal: budget-exhausted` |
| 13 | a check ran and did not pass, or a step is held by an earlier failed check | `refusal: check-failed`, `step:`, `score: a/b` (on the run that scored it) or `held:` + `retry:` (on later runs) |
| 14 | the check could not be read as a score, did not end, wrote too much, its artifact is unusable, or a need or the contract is not what was accepted or given | `refusal: check-unavailable`, `refusal: artifact-invalid` or `refusal: usage-invalid`, `step:`, `reason:` |
| 15 | a step's worker ended without a claim, or a stale build would not stop; the run went on with every step that does not need it first (section 8, item 6) | when it happens: `refusal: step-failed`, `step:`, `exit: N` or `reason:`, `going on: ...`; at the end: `refusal: step-failed`, one `step: <id>` per such step, `failed: ...` |
| 16 | a TERM or INT arrived while a build ran: the build was cancelled and its spend recorded | `stopped: signal`, `step:` |

The usual shape of a company, then, is: run (exit 10 at a gate), `decide`, run again, and so on until exit 0; and on 13 or 14, a person
reads the step's evidence and either fixes the cause or records `retry:<id> approved`.

## 6. Step states

`forge company status` shows a closed set, derived from the manifest and the journal (not from any worker's word):

| state | meaning |
|---|---|
| `accepted` | the journal holds `company.step.accepted` for it |
| `rejected` | its gate's last decision is `rejected` |
| `gated` | its needs are accepted and its gate has no decision yet |
| `ready` | its needs are accepted and it has no gate, or its gate is approved |
| `waiting` | a step it needs is not accepted (this wins over its gate) |

A step *held* by its check (section 8) is not a state of its own in `status`: it is shown as `ready`. The run, not `status`, reports the
hold.

## 7. The company journal

The company's facts are in **`<company-dir>/company.journal`, a file of their own**, not in the task journal. Each worker step is a
Forge task in its own workspace, `steps/<id>/journal.jsonl`, with the task state machine and the worker's evidence exactly as `forge
build` and `forge gate` leave them; the company journal records what the *company* decided about the steps. (The design's section 4.3 first
said "the existing journal"; this is the correction. A step's task is left in `verification` in its workspace forever: only the company
journal says it was accepted.)

One JSON object per line, framed like every Forge journal (`v`, `seq` from 1 and exactly next, `kind`, `task`):

| kind | `task` is | other fields |
|---|---|---|
| `company.step.admitted` | the step id | `forge_task` (the step's workspace, `steps/<id>`) |
| `company.step.accepted` | the step id | `artifact` (path relative to the company directory), `sha256` (computed by Forge) |
| `company.step.check_failed` | the step id | `score`, `total` |
| `company.step.check_unavailable` | the step id | `reason` (the printed tag: `check-unavailable`, `artifact-invalid` or `usage-invalid`; a later run names it again) |
| `company.gate.decided` | the gate name | `gate`, `verdict` (`approved` / `rejected`), `user`, `reason` |
| `company.spend.recorded` | the step id | `input`, `output`, `cache_write`, `cache_read`, `cost_micro` |

Replay is the only state: which steps are accepted, the last decision per gate, how many times each step was admitted, the tokens and
cost spent, which steps are held, and the artifact path and digest each accepted step was accepted with. A kind this build does not know
is passed over (its `seq` must still be next); a known kind with wrong fields is `event-malformed`.

**Torn tail.** Bytes after the last newline are a record being written when the process died; replay does not read them. `decide` and
`run` cut them before appending; `status` reports `torn tail bytes: N` and cuts nothing. A *complete* line that is not the next record is
`journal-corrupt`: nothing is cut or written, and `status` shows the steps that replayed before it.

## 8. How a step runs, and what accepts it

For a step `Start(i)` the run does, in order (the long form is the header of `src/company_runner.cho`):

1. **Refusals that write nothing**: no `check` where one is required (`check-missing`), no `steps/<id>/ev` (`step-dir-missing`), an operator
   file without what the step needs (`operator-invalid`).
2. **Needs** (below) are re-verified and delivered; a **contract** (below) is delivered; a stale build of an earlier, killed run is reaped.
3. `company.step.admitted`. A step admitted and never accepted (a run killed in the middle, a check that failed) is admitted again by the
   next run that is allowed to start it.
4. The worker runs: a builder or writer step builds `input` in `steps/<id>/ev` (the artifact is `project.cho`); a qa or reviewer step
   reports the gate named by the operator's `gates.<id>` (`report.json`); an analyst step runs its tool (`tool.out`); a product step has
   no worker (its artifact is `company.json`).
5. A build's `usage.jsonl` is priced and `company.spend.recorded` appended, **whatever the build's ending**: tokens spent on a build that
   got stuck are spent.
6. A worker that ended without a claim: `step-failed` (`exit: N`), no check, nothing accepted, and **the run goes on**. Within this one
   invocation the step is not admitted again (the run keeps the list in memory, never in the journal: `company_run.next_action` is given
   it and answers `Failed` instead of `Start` for it); every other step that is ready still runs, and the steps that need the failed one
   wait. When nothing else can start the run ends exit 15, `refusal: step-failed` and a `step:` line for each step that ended without a
   claim in it. It is not a hold: the next invocation starts with an empty list and admits it again, in step order (the lowest step
   first, so a step listed first is retried first), so a transient provider error heals by re-running. A stale build that would not stop
   (item 2) is treated the same way. (Until 50d81e9 such a step stopped the run at once, so in the A/B runs B1 and A2 the independent
   steps behind nothing were never built.) A `Failed` ending outranks a hold by a check, an open gate and a spent budget: the run reports
   what happened in it.
7. **The check.** Forge hashes the artifact itself, runs the step's `check` program, and hashes it again.

**Acceptance.** A step is `accepted` only when Forge ran the check and the check printed a score line `TOTAL a/b` (the last such line
decides) with **`a == b` and `b > 0`**. Then, and only then, `company.step.accepted` is written with the artifact's path and the SHA-256
Forge computed. A worker's `done`, a gate's `passed`, a tool's exit 0: none of these is acceptance. Details:

* The artifact must be a regular file beneath its directory, at most 16 MiB, opened with no link followed (a symbolic link, a directory,
  a FIFO or a device is `artifact-invalid`); it is hashed before and after the check, and a change is `artifact-invalid`
  (`reason: changed while the check ran`).
* The check program is a name in the company directory. It is started with two arguments, the artifact's absolute path and the step's
  execution directory, with `PATH=/usr/local/bin:/usr/bin:/bin` as its whole environment, an empty standard input, a deadline
  (`check_timeout_ms`) and a 1 MiB cap on standard output, inside its own process group under the check guard (section 10). It is not
  shown a worker's claim.
* A score below the total is `check-failed` whatever the program's exit status. A full score with a non-zero exit, no score line, an
  unreadable one (a sign, text after it, a number of more than 15 digits, `a > b`, `0/0`), a signal, the deadline or the output cap are
  `check-unavailable`: never a pass.
* The audit's result is **never fed back** to the builder, so a re-run does not learn from it.
* **For audit authors:** the LAST `TOTAL` line on the check's standard output decides. An audit that runs the artifact must not let the
  artifact write to the audit's standard output (redirect the artifact's output to a file or `/dev/null`, and print the `TOTAL` line
  yourself, last): otherwise the program under test can print its own `TOTAL n/n` and pass. The check guard kills the check's whole
  process group when the check ends, so nothing the audit (or the artifact) leaves in the background survives it.

**Held after a failure; retry through `decide`.** A `check_failed` or `check_unavailable` record **holds** its step. There is no
Forge-level retry: every later run prints the refusal again (`held: ...` and the `retry:` line), exits 13 or 14, and starts nothing for
that step, spends nothing, until a person records `forge company decide <dir> retry:<id> approved <reason>` *after* the failure. A
rejection, an approval recorded before the failure, or a retry of another step does not free it. Then the next run admits the step once,
and a new failure holds it again. (Independent steps still run first.) `artifact-invalid` is held the same way, except for a *need* or a
*contract* that is not what it should be before the step is admitted (below), which holds nothing.

**Needs delivery.** `needs` is not only an order. Before a step starts, every need that has a checked artifact (builder, writer, qa,
reviewer, analyst; **not a product need**, whose artifact is the whole manifest, which this run parsed and trusts) is read again, exactly
as at acceptance, and must be that step's own artifact with the SHA-256 its `accepted` record holds; otherwise `artifact-invalid` with
`reason: needs-missing` or `needs-changed`, exit 14, **nothing written, nothing admitted, nothing held** (the step is not at fault; put the
accepted bytes back and the next run starts it). All needs are verified before the first write. A builder or writer step is then **given
the very bytes verified**, in its execution directory, as flat files: `needs-<need id>-<artifact name>` for each need (for example
`needs-lib-project.cho`) and `needs.json`, `[{"step","artifact","path","sha256"}]` (`path` the copy's name). Files are written as
`needs.tmp` (exclusive create, no link followed, mode 0644 less the umask) and renamed over their name; names Forge owns there
(`needs.json`, `needs-*`) from an earlier start are removed first. qa, reviewer and analyst steps are verified but given nothing.
**Forge does not tell the builder the files are there**: the step's `input` must say so (for example "the library is in
`needs-lib-project.cho`").

**Contract input.** A builder or writer step may name a `contract`: a file of the company directory with the exact public signatures
the build must use. Before the step is admitted Forge reads it (a regular file; at most **256 KiB**, which is all the build tool's plan
agent reads of it; a missing file is `reason: contract-missing`, a link, directory, oversize or unreadable one `contract-unreadable`;
exit 14, nothing admitted, nothing recorded) and writes **its own copy** as `contract.txt` in the execution directory; the build tool is
started with `--contract <execution dir>/contract.txt`. A step with no contract is started with no `--contract` at all (its whole
argument vector is the pre-contract one, asserted), and a `contract.txt` left by an earlier manifest is removed. The build can write in
that directory, so the contract is **protected by detection, not prevention**: when the build ends Forge reads `contract.txt` again and
compares it with the company directory's file, and a difference or a missing file is `artifact-invalid`, `reason: contract-changed`, the
step held, nothing accepted. Mapped to the design's arms (section 4.6): **arm A** is a step with no `contract`; **arm B** is a step
with a `contract` file of required signatures (the existing `--contract` of Cancho Code); **arm C**, the semantic contract of
`cancho-contract`, is **not built**: Forge treats the file as opaque bytes (copied and size-capped, never parsed), and no A/B has been
run.

## 9. Budget

Forge **derives the cost**; the **token counts are the build tool's own log** (`usage.jsonl`, written by Cancho Code's agent in the
step's execution directory), trusted as the build tool is trusted (section 2). A build that truncates or deletes that file gets zero
spend recorded: the budget is a ceiling on an honest build tool, not a control on a hostile one.

* After every build (whatever its ending) Forge reads `steps/<id>/ev/usage.jsonl` the way it reads an artifact (beneath the execution
  directory, no link followed, a regular file of at most 16 MiB, a FIFO never opened): a link (to `/dev/zero`, say), a FIFO, a directory,
  a larger or unreadable file is `usage-invalid` (`reason:` printed), recorded as an unavailable check (the step held, exit 14), no
  check run, nothing accepted; a file that is not there is no usage. It is the log Cancho Code's agent writes (one JSON object
  per model call with `in`, `out`, `cache_write`, `cache_read`), prices it call by call, subtracts what the journal already holds for the
  step, and appends the difference as `company.spend.recorded` with its `cost_micro`. A line that is not an object of at most 2048
  bytes with four integer token fields from 0 to 10^15 is skipped and counted, never a trap.
* **Price table**: `budget.price_table`, a file in the company directory in the shape of cancho-code's `eval/prices.json`
  (`{provider: {model: {"in", "cache_write", "cache_read", "out", optional "prompt_limit" and "over_limit_prices"}}}`, prices as USD per
  million tokens written as decimals with at most six places, at most 1000; keys beginning with `_` are notes; a provider's `_any`
  prices a model of a provider that has no entry). Prices are read from the number's own text into **micro-dollars**; there is no
  floating point. A table that is missing, unreadable, unparsable, or does not price the manifest's provider and model is
  `price-table-missing` (exit 1, nothing written). A call whose prompt (`in + cache_write + cache_read`) is over a model's
  `prompt_limit` is priced at the over tier.
* **Cost** is `sum(tokens * price) / 1,000,000` over the four classes, in integers, **rounded up once** over the whole sum, saturating at
  10^15 micro-dollars. `max_cost` is in **whole dollars** and is converted to micro-dollars for the comparison. The recorded
  `cost_micro` is **authoritative**: a replay never re-prices a total (a total has lost its per-call tiers; re-pricing Haiku's would put
  every call at its higher tier, up to five times over). A spend record without `cost_micro` is unpriced and is priced conservatively
  at the highest tier.
* **When it is checked**: only **between model steps**. The scheduler (`company_run.next_action`) will not start a builder or writer
  step when any token class is over its ceiling (`spent > limit`) or the cost is over `max_cost`; the run then ends `budget-exhausted`,
  exit 12 (a gated model step behind a spent budget counts as held by it). **Steps that use no model (qa, analyst, reviewer, product)
  are never stopped by it.** A running step is **not** killed when the ceiling is crossed, so spending can pass a ceiling by one step. **A zero-budget company still runs its first model step**: `spent > limit` is false at 0 spent, there is no pre-check, and no test covers it.
* **Two ways the recorded spend lags what was spent** (read from the code, not covered by a test): (1) a run killed after a build ended
  and before its `spend.recorded` was appended has spent tokens the journal does not hold; the next run's budget check does not see them
  and may admit one more model step, and the delta recorded after that step includes them (the **kill-before-spend window**). (2) The
  delta is `usage.jsonl` now less what was recorded and is never negative: if a tool **rewrites `usage.jsonl` shorter**, the calls in it
  are lost up to the old total. For an honest tool that is a lag; for a **hostile build it is a budget bypass** (truncate or delete the
  file and spend is not recorded at all).

## 10. Kill and resume

The journal, not memory, is the state, so any run can be killed and run again. Measured by `tests/conformance/company_kill.sh` (a real
`forge company run` killed as a process group with SIGKILL and SIGTERM mid-build and mid-check, then run again; stand-in build tool):
after each kill the lock is free (it is a flock), `status` exits 0 (a torn tail is tolerated), the next run is not refused
`workspace-locked`, runs on to the end with **every step accepted exactly once** (the killed step admitted twice, the others once), the
spend recorded across the kill equals the `usage.jsonl` total, and a further run admits nothing. What a kill leaves, and what removes
it (the full table is [`architecture.md`](architecture.md) section 4.4.2):

| the kill | left running | removed by |
|---|---|---|
| SIGKILL mid-build | the adapter's supervisor and the build (they are meant to outlive Forge) **until the next `run`** | the next run, before it admits the step again (`reaped: <task>`). If no next run comes they run to the adapter's own deadline. `forge recover` does **not** reap them |
| SIGTERM / INT mid-build | nothing: Forge claims the signal while a build runs, cancels the build through its worker, records the spend, prints `stopped: signal`, exits 16 | itself |
| SIGKILL or SIGTERM mid-check | nothing, within about 100 ms | the check guard (`workers/check_guard.cho`) watches `<dir>/check.lock`, which Forge holds while it waits, and kills the check's group when it can take it |
| SIGTERM while `execute` itself runs | nothing | Forge cancels the run by its request id before exiting 16 |
| SIGKILL mid-qa step | **the gate, until it ends by itself**; nothing bounds it once its runner is gone | nothing (gap G4); the next run's gate runs beside it. Not tested |
| SIGKILL mid-analyst step | **the tool, until it ends by itself**; TERM / INT are handled | nothing. Not tested |
| SIGKILL of the check guard itself | the check, until it ends | nothing |
| SIGKILL between `execution.started` and `execution.accepted` | possibly the supervisor and the build | the next run, as for mid-build. **Not tested** (cannot be placed from outside) |

The operator's workers directory must hold `check_guard`; without it every check is `check-unavailable` with `reason: the operator's
workers directory has no check_guard`. A race left open: if a next run takes `check.lock` before an old guard has looked (it looks every
100 ms), that guard runs its check to its own deadline.

## 11. Roles

| role | task type | what runs it | artifact | status |
|---|---|---|---|---|
| builder | `project.build` | the Cancho Code adapter, `forge build`'s run; a model step (budget applies) | `project.cho` | **implemented and measured** with a stand-in build tool: lying worker, good path, budget, rejected gate, kill and resume, needs, contract |
| qa | `repo.gate` | the gate runner, `forge gate`'s run, over the operator's `gates.<id>` (repo on the allow-list, revision, checkout) | `report.json` | **implemented and measured** on a throw-away git checkout |
| analyst | `tool.run` | the tool runner `workers/tool_run.cho`; no model | `tool.out` | **implemented and measured** with a stand-in tool (the real `tally` and `jsonq` ran once in development; the gate skips that unless `FORGE_CANCHO_TOOLS` is set); its re-run comparison (forge#41) is not built (below) |
| product | none | a person: the step's `gate` (accepted on the approved decision alone when it has no `check`; with a `check` that runs on `company.json`); a product step with neither is `check-missing` | `company.json` | **implemented and measured** |
| reviewer | `repo.gate` | **the same path as qa**: the gate runner over `gates.<id>`. Nothing compares `cancho authority` to a checked-in ceiling, which was the reviewer's whole point in the design (4.2, 10) | `report.json` | **accepted by the manifest and mapped to the gate runner, but not run by any test and not distinct from qa.** The design's goal 5 asked for a reviewer; it is not met |
| writer | `project.build` | the builder path (a model step) | `project.cho` | **accepted by the manifest (a `check` is required) and mapped to the builder path, but no writer step has been run by any test.** The design's checks (length, required sections and links) are whatever the step's own `check` program does; Forge adds none, and "a person reads it before the gate opens" is only a `gate` the manifest author puts on the step |

The role pack the design called "a role is a name mapped to a worker, a task type and a default check" is the table above; there is no
default check, and each step names its own.

## 12. Refusal tags

Every refusal has a stable `rule` tag, printed as `refusal: <tag>`, and a test that reaches it (one arm, the `step-failed` stale-build refusal, is not reached by a test; see the row). The table is the company layer's,
with the exit code of the verb that prints it and one test or oracle case that reaches it. The full prose of each, and every test, is
[`architecture.md`](architecture.md) section 7 (the same tags; `scripts/gate.sh` checks that every tag the company code can print is in
both documents). `unit` is `cancho test` (`tests/*_test.cho`); `run.sh` is `tests/conformance/company_run.sh`; `kill.sh` is
`tests/conformance/company_kill.sh`; `tool_run.sh` is `tests/conformance/tool_run.sh`; `check_company.sh` is `scripts/check_company.sh`.

| tag | printed when | exit | reached by |
|---|---|---|---|
| `manifest-malformed` | the manifest is not JSON, is over 1 MiB, is the wrong shape, has a name that is not a name, a step id that is a dot name (`.`, `..`, a leading dot, two dots in a row: it names a directory), a key twice or escaped; also a manifest file that is not there or unreadable | 1 | unit `test_text_that_is_not_a_manifest_is_malformed`; `check_company.sh` `check: a file that is not there...` |
| `manifest-unknown-field` | a key the closed shape does not have | 1 | unit `test_a_field_the_shape_does_not_have_is_refused` |
| `step-id-duplicate` | two steps with one id | 1 | unit `test_a_step_id_used_twice_is_refused` |
| `step-needs-unknown` | a `needs` entry that is no step | 1 | unit `test_a_need_that_is_no_step_is_refused` |
| `step-cycle` | a step that needs itself or steps in a ring; the run's defensive half (a need that can never be met) prints it with exit 11 | 1 (11) | unit `test_a_step_that_needs_itself_is_a_cycle`; `test_settle_falls_back_to_blocking_the_first_step_left` |
| `role-unknown` | a role outside the six, or one `roles` does not list | 1 | unit `test_a_role_that_is_not_one_of_the_six_is_refused` |
| `task-type-unsupported` | a `task_type` that is not the one the role offers; in the run, a step no adapter runs (unreachable since task 11) | 1 | unit `test_a_task_type_the_role_does_not_offer_is_refused` |
| `check-missing` | a builder or writer step without `check` (manifest); in the run also a qa, reviewer or analyst step without one, or a product step with neither gate nor check | 1 | unit `test_a_builder_step_without_a_check_is_refused`; run.sh `a qa step with no check` |
| `contract-role-invalid` | a step that is neither builder nor writer names a `contract` | 1 | unit `test_a_contract_on_a_role_that_builds_nothing_is_contract_role_invalid`; run.sh `manifest: a contract on a qa step ...` |
| `gate-unknown` | a step's `gate` not in `human_gates`; `decide` about a gate that is neither listed nor `retry:<step id>` | 1 | unit `test_a_gate_that_is_not_a_human_gate_is_refused`; `check_company.sh` `decide: a gate the manifest does not list is gate-unknown` |
| `budget-missing` | no `budget`, or one of its five numbers absent | 1 | unit `test_a_missing_budget_or_price_table_is_refused` |
| `price-table-missing` | `budget.price_table` absent (manifest); in the run, a table that is not there, unreadable, or does not price the manifest's model | 1 | unit `test_a_missing_budget_or_price_table_is_refused`; run.sh `no price table`, `a price table without the model` |
| `path-invalid` | a path on the command line that is not absolute or has `..`; in `tool.run`, an input outside the execution directory | 2 (1 for an analyst input) | `check_company.sh` `check: a relative path is path-invalid`; run.sh `analyst: an input that escapes ...` |
| `journal-corrupt` | a complete line of `company.journal` that is not the next record | 1 | unit `test_a_seq_gap_is_journal_corrupt_and_replay_stops_there`; run.sh `a corrupt journal` |
| `event-malformed` | a known `company.*` kind with wrong fields (a verdict that is neither word, a count that is not a count, a `cost_micro` that is not a count) | 1 | unit `test_a_known_kind_with_the_wrong_fields_is_event_malformed` |
| `workspace-locked` | another writer holds `<dir>/lock` (a run, or a `decide` in the middle of writing) | 1 | `check_company.sh` `decide: while another writer holds the lock ...`; run.sh `a company directory locked by another writer` |
| `operator-invalid` | the operator file is not there, not JSON, outside its shape (a build ceiling out of range or not a whole number: with `reason:`), inside the company directory, or lacks what a step needs; an analyst with no `analyst_tools` or no entry | 1 | unit `test_an_operator_file_outside_the_shape_is_refused`, `test_an_operator_file_may_name_a_guide_held_to_the_build_path_rule`, `test_an_operator_file_may_set_the_build_ceilings_held_to_forge_builds_ranges`; run.sh `an operator file inside the company directory`, `guide: a relative guide path is operator-invalid`, `limits: an agent_seconds past forge build's range is operator-invalid with its reason ...`, `limits: a jobs that is a string is operator-invalid with its reason ...` |
| `step-dir-missing` | a worker step's `steps/<id>/ev` is not a directory | 1 | run.sh `a step directory that is not there` |
| `tool-not-granted` | an analyst step's tool is not in `granted_tools` | 1 | unit `test_an_unlisted_tool_is_tool_not_granted`; run.sh `analyst: a tool the operator did not grant ...` |
| `argv-malformed` | an analyst's `argv` is not an array of plain strings | 1 | unit `test_an_argv_that_is_not_an_array_of_plain_strings_is_argv_malformed`; run.sh `analyst: an argv with a number ...` |
| `limits-invalid`, `task-type-invalid` | the tool runner (`tool.run`) refuses a deadline outside 2 s to a day, or a task type that is not `tool.run`; the company run cannot send either (it builds the request), so they are reached through the worker directly | worker `failed` | unit `test_the_task_type_is_tool_run_and_nothing_else`; tool_run.sh `a task type other than tool.run ...; a deadline under 2 s ...` |
| `gate-open` | a step waits on a human gate with no decision | 10 | unit `test_a_step_with_an_open_gate_waits`; run.sh `good path: the first run stops at the open gate` |
| `gate-rejected` | nothing else can start and a gate was last decided `rejected` | 11 | unit `test_a_rejected_gate_blocks_and_nothing_behind_it_starts`; run.sh `rejected gate: ...` |
| `budget-exhausted` | a model step is held back by a spent budget | 12 | unit `test_an_exhausted_token_budget_stops_before_any_new_model_step`; run.sh `budget: ...` |
| `check-failed` | the check scored below its total, or the step is held by an earlier failure | 13 | unit `test_a_score_below_the_total_is_check_failed`; run.sh `lying worker: ...` (second run held, `retry:` frees it) |
| `check-unavailable` | no readable score, a check that did not end by itself, wrote too much, a missing `check_guard`, or an earlier such hold | 14 | unit `test_a_pass_with_a_failing_exit_is_unavailable_not_a_pass`; run.sh `audit without a score`, `a check that does not end`, `no check_guard in the workers directory` |
| `usage-invalid` | a build's `usage.jsonl` is a link, a FIFO, a directory, over 16 MiB or unreadable (never followed, never opened when not a regular file); recorded, the step held | 14 | unit `test_a_held_code_names_the_refusal_it_was_recorded_with_and_its_exit`; run.sh `usagelink`, `usagefifo`, `usagebig`, `usagedir` |
| `artifact-invalid` | the artifact is not a regular file beneath its directory or changed under the check; a need is missing or changed (`needs-missing`, `needs-changed`); the contract is missing, unreadable or changed by the build (`contract-missing`, `contract-unreadable`, `contract-changed`) | 14 | unit `test_every_way_an_artifact_is_refused_has_its_reason`; run.sh `a symlink artifact`, `needs changed`, `contract changed by the build` |
| `step-failed` | the step's worker ended without a claim (stuck, a refusal, a deadline), or a stale build would not stop; printed when it happens and again when nothing else can start (the run goes on with the steps that do not need it first) | 15 | unit `test_a_step_that_ended_without_a_claim_is_not_started_again_in_the_same_invocation`, `test_when_nothing_else_can_start_the_answer_is_the_failed_step_and_its_dependent_waits`; run.sh `stuck worker: ...`, `no claim: ...`; the stale arm needs an adapter that ignores `cancel` and is **not reached by a test** |

Not refusals, so without a tag of their own: `stopped: signal` (exit 16; `kill.sh` `T:` and `E:` cases) and `worker-error: <code>`, the
tool runner's own code (`input-unusable`, `tool-unusable`, `evidence-unwritable`, `tool-timeout`, `tool-output-overflow`,
`tool-cancelled`; section 13; `tool_run.sh`).

## 13. Analyst (tool.run)

An analyst step recomputes a number of the product independently, with a deterministic data tool, and its `check` compares the
two (spec section 4.2 and section 10, the analyst paragraph; forge#41). It runs through the tool runner,
`workers/tool_run.cho` (worker-contract section 12), and uses no model: no spend is read or recorded for it, and it is not held by
a spent budget (it is a non-model step, `company_run`).

**Who names what.** The manifest names an analyst step (`role: analyst`, `task_type: tool.run`, a `check`) and nothing it runs.
The operator file names the rest, for each analyst step by its id:

```json
"analyst_tools": "/opt/cancho-tools/build",
"granted_tools": ["tally", "jsonq"],
"analysts": { "uptime": { "tool": "tally", "argv": ["--field", "2", "--delim", " "], "input": "checks.log" } },
"tool_timeout_ms": 60000
```

`argv` is a JSON array of strings, never shell text (no shell runs the tool); `input` is a file beneath `steps/<id>/ev`, which the
operator puts there (Forge cannot make a directory or decide where the data comes from), and is given to the tool as its last
argument, by absolute path. Before the step is admitted Forge checks these with `tool_task.check`, the same check the runner repeats:
a tool not in `granted_tools` is `tool-not-granted`, a malformed `argv` is `argv-malformed`, an input outside the execution
directory is `path-invalid`, no entry or no `analyst_tools` is `operator-invalid` (each exit 1, nothing admitted).

**What is accepted.** The runner keeps the tool's standard output as `steps/<id>/ev/tool.out` (at most 1 MiB; more is
`tool-output-overflow`, the output cut and marked in `report.json`, and the step fails), and that file is the step's artifact:
hashed beneath its directory as every artifact is, given to the check as its first argument (the execution directory, with
`report.json` and `introspect.json`, as its second), and accepted only on the check's pass. `report.json` records the tool's exit
status and the SHA-256 of the tool's own authority manifest, read from its `introspect` answer; a tool that does not publish one
gets `"source": "unavailable", "sha256": null` and a note, never an invented hash.

**Measured with the real cancho-tools** (2026-10-27). cancho-tools at 154e69a was built with Forge's pinned compiler (972099e;
cancho-tools pins 93613fc, a later revision, for which no compiler binary was at hand; `tally` and `jsonq` build with 972099e
unchanged) into a scratch directory outside this repository; nothing was committed. Run under the tool runner by
`tests/conformance/tool_run.sh` (set `FORGE_CANCHO_TOOLS` to the directory holding the two binaries) against a fixture check log of
four lines `service status latency`:

* `tally --field 2 --delim " " <checks.log>`: `succeeded`, exit 0, `{"total":4,"distinct":2,...,"top":[{"key":"up","count":3},
  {"key":"down","count":1}],...}`; the same bytes twice.
* `jsonq -p /checks <summary.json>`: `succeeded`, `{"pointer":"/checks","kind":"integer","value":4}`.
* The authority manifest hash: the bytes of the `authority` object of each tool's own `introspect` (tally
  `fdf71a63...27ea`, jsonq `588da92e...c8e3`). Those bytes are exactly the tool's `manifests/<tool>.authority.json`, minified (checked
  outside the program), and its `effects` are the ones `cancho authority` at 972099e derives from the same sources (`args`,
  `dir_read`, `err_write`, `file_read`, `fs_read`, `heap`, `io_read`, `io_write`). Note that `introspect` prints the manifest the
  binary embeds (generated by cancho-tools' `scripts/manifest.py` at its own pin, and it says `"compiler":"93613fc..."` whatever
  compiler built it): the hash names that manifest, not a report re-derived at run time.

**What the tools can and cannot compute** (from cancho-tools' README, `tools.toml` and each tool's `introspect`):

* Counts: yes. `tally` counts and ranks distinct lines or one field (`--field N --delim D`), integers only. So "checks", "up" and
  "down" over a whole log are one call each; the check program does the division for an uptime percentage (no tool divides).
* Per service: only if the service and the status are one field of the log (`tally` keys on one field or the whole line; a line
  that also holds a latency is distinct per latency). With the StatusLite line format `service status latency`, a per-service
  uptime needs either a log written with `service:status` as one field or a check that filters first; `seek` can find the lines of
  one service but does not count by field.
* Values from the product's JSON summary: yes, `jsonq` reads one value by RFC 6901 pointer.
* **Percentiles: not available.** None of the eleven tools (`seek`, `list`, `peek`, `jsonq`, `tally`, `hash`, `write`, `replace`,
  `move`, `archive`, `run`) sorts numerically or computes a quantile, a sum or a mean; nothing in cancho-tools' README, docs or
  `tools.toml` mentions percentiles. (cancho-table, a separate repository, aggregates count, sum, min, max, distinct and mean by its
  own account in cancho-tools' `docs/next-tools.md` section 5; no percentile is listed there, and it was not run here.) So in
  StatusLite the latency percentiles stay covered by the hidden audit only, as spec section 10 anticipated, and the report must say so.

**Not done.** forge#41's "Forge re-runs the same query and compares output hashes" is not built: determinism is asserted by the
conformance (the same bytes twice, stand-in and real `tally`), and the step's check judges the output once. A SIGKILL of the
runner or of Forge's group leaves the tool running until it ends by itself (a TERM or INT does not: the runner kills the tool's
group first). The manifest hash is the tool's own self-report, unverified (see worker-contract 12.2).

**When the runner refuses after admission** (the input is not there or not a regular file beneath the directory, the tool cannot be
started, the evidence cannot be written) or stops the tool (its deadline, the 1 MiB cap, a signal), the run prints
`worker-error: <code>` (`input-unusable`, `tool-unusable`, `evidence-unwritable`, `tool-timeout`, `tool-output-overflow`,
`tool-cancelled`) before `refusal: step-failed` (exit 15), and the step's workspace journal records it as a refusal of the tool
task. The operator's `tool_timeout_ms` is the deadline the run is given (the runner's own is four fifths of it).

## 14. What is not measured, and what is not done

Everything above is true of the code as built and of the gate's conformance programs. This is the list of what that does **not** show,
drawn from the review ledger of the build (`.superpowers/sdd/2026-10-27-forge-company-layer/progress.md`) and the task reports.

**Trust limits** (section 2)

* Acceptance assumes a builder that writes nothing outside its execution directory: the build *process* is not confined by Forge (only
  the adapter's arguments are); Cancho Code's own tests running with no `Fs` is the only containment, and it is Cancho Code's.
* A manifest author who is not the operator is not contained: checks are programs of the company directory Forge runs, `company.journal`
  is a file of it, an approved gate can be reused on a product step. The budget's token counts are the build tool's log (section 9).

**Not measured at all**

* **No company has been run with a real model.** No Haiku run, no dollar spent, no wall time, no token count from a real
  `cancho-build`. The builder in every oracle is the real adapter over a stand-in build tool whose `usage.jsonl` lines were written to the
  shape cancho-code's source and tests pin; the price table in the oracle is a toy. Cost figures, the budget's first real overshoot and
  a real model's behaviour under the contract are all unknown.
  *Corrected (2026-10-28):* one company has since been run with a real model (StatusLite, arm A, run 1, Haiku 5.5; its record is
  `statuslite/runs/arm-a-1/` in the StatusLite repository): it stopped on two Forge defects, the fixed `--agent-seconds 30` (now the
  operator file's `agent_seconds`, section 4) and the timed-out agents that outlived their build (below, "Kill and process gaps"). The
  oracles of this repository still use the stand-in only.
* **StatusLite does not exist.** Its repository was not created, and the gate runner's allow-list (`alpibrusl/cancho-forge`, `cancho-hdl`,
  `cancho`, `cancho-ui`) does not name it, so no qa step can report its gate yet.
* **The A/B** (arm A brief only, arm B signatures, arm C semantic contract) has not been run; arm C is not built. The contract path
  is tested for what Forge does (delivery, argument vector, tamper detection), not for whether signatures help a model.
* **Linux x86_64 only.** The user lookup for `decide` reads `/proc/self/environ` (Linux; elsewhere the user is recorded as `unknown`);
  nothing was run on macOS.
* **A process kill is not a power loss.** The journal's sync is the same as for the task journal ([`architecture.md`](architecture.md) 4.8).

**Not built**

* **The reviewer role** is not distinct from qa (section 11): no authority-versus-ceiling comparison exists, so the design's goal 5 (a
  reviewer that is not a coder or a gate-runner) is **not met**; the company layer has qa, analyst and the product gate.
* **The writer role** has never been run by a test; none of the design's writer checks (length, sections, links) exists.
* **forge#41's re-run comparison** ("Forge re-runs the same query and compares output hashes") is not built: the analyst's tool is run
  once and its output judged once. Determinism is asserted by the conformance (the same bytes twice) only. The tool's authority-manifest
  hash in `report.json` is the tool's own self-report, unverified.
* **Percentiles are unavailable in cancho-tools**: none of its eleven tools sorts numerically or computes a quantile, a sum or a mean
  (section 13). A StatusLite latency percentile can only be covered by the hidden audit. Per-service counts need `service` and `status`
  in one field of the log.
* **Pre-approved gates.** `decide` records a decision on any gate of the manifest at any time, including before the gated step is
  reachable: the gate is then already approved when the step is, and nobody looks at that step's inputs. (A `retry:<id>` approved *before*
  a failure is recorded but does not count, by design.)
* **`status` shows a held step as `ready`** and shows no cost, only tokens; the hold, the failed score and the cost are in the run's output
  and in the journal.
* **A worker that ends without a claim (exit 15) is not held**: the run goes on with every step that does not need it and is not
  admitted again in that invocation, but the next run admits it again and builds it again, spending again (first, if it is the lowest
  step left). Only a failed or unavailable check holds. A step that fails the same way every time is paid for once per invocation. Also, if a run is killed after a `retry:<id>` approval and before the step records anything new, the
  approval still stands, and the next run rebuilds it: one extra paid try.
* **Relative paths are refused** everywhere (`path-invalid`), by the rule of every Forge verb. A worker step is also refused
  `path-invalid` when a component of a path it is given starts with `-` (the session scratchpad of some agents, for example); `check`
  and `status` accept such a path. Use a plain absolute path such as one under `/tmp/...`.
* **The operator creates `steps/<id>/ev`** by hand for each worker step (no mkdir in the language), and the step's `input` must name the
  `needs-*` files for the builder to find them (Forge appends nothing to the brief).
* **A step id of `.` or `..`** passes the manifest's name rule (a manifest rule is still to be added).
* **A role changed after acceptance** (a builder step edited into a product step) skips the re-verification of its artifact for the steps
  that need it; an edit to `company.json` after a product step was accepted is not noticed (product needs are trusted).
* **A check's environment is `PATH` only**: a check that needs `HOME` or a locale fails or cannot judge.
* **A directory planted at `needs-<id>-<name>`** in an execution directory makes the delivery fail as an I/O error (exit 3), not a tag.
  A file `needs-*` of the worker's own in `ev` is deleted at the next start (those names are Forge's).
* **`forge build` has no `--contract` option**: a contract can only be given by a manifest step (or a direct task).

* **A zero-budget company still runs its first model step**: no pre-check exists and no test covers it (section 9).
* **Smaller gaps from the review ledger**: an environment over 64 KiB makes `decide` record the user as `unknown`; `decide` creates the
  lock file before it checks the manifest and the gate. The score parser's blank skipping ignores `\r`, and its last-`TOTAL`-line rule is
  strict: a later prose line starting with `TOTAL` makes the score unavailable. The qa and reviewer need cases are only partly tested; the
  cycle check's glue (`has_cycle`) is untested on cyclic input; there is no oversize-manifest oracle case; the early oracle skipped output
  checks on an empty expectation (fixed in task 5). (Fixed: a held step now names the refusal it was recorded with, `artifact-invalid` or `usage-invalid`, on every later run.)
  The `event-malformed` tests for the fields of `check_failed`, `admitted` and `gate.decided` records are missing.

**Kill and process gaps** (details in section 10 and [`architecture.md`](architecture.md) 4.4.2)

* A SIGKILL mid-build leaves the supervisor and the build running until the next `run`; mid-qa leaves the gate and mid-analyst the tool until
  they end by themselves (gap G4: cancho has no kill by pid or parent-death signal); a SIGKILL of the check guard leaves the check.
  The qa and analyst cases and the kill between `execution.started` and `execution.accepted` are **not tested**.
* **A build's timed-out agents (statuslite run arm-a-1, defect 2).** Measured there: three `cancho-agent` processes still calling the
  provider 5+ minutes after their build had ended, killed by hand; their late `usage.jsonl` lines were charged to the next build or to
  none, so `max_cost` did not see that spend. The cause, read from cancho-code's source and reproduced with the stand-in (`straggle`):
  the tool's driver (`src/driver.cho`) starts the agent with a plain `exec_spawn` of `/bin/sh -c '<agent> <file> 2><file>.agent.err'`,
  so the shell is in the build's process group and session (`cancho-build` leads both: the adapter starts it with
  `exec_spawn_detached_under`); dash forks for the redirect, so the agent is the shell's child, not the shell; at the agent's deadline
  `process.capture` signals the group the shell leads (none: `ESRCH`) and kills the shell's pid alone. The agent, reparented, runs on
  in the build's group (measured with the stand-in: the left `sleep 76` had `pgid` = `sid` = the build's pid, its parent the
  session's subreaper, the build itself gone). *Fixed here:* the adapter's `supervise.wait` now kills the build's whole group on
  every ending, the build's own exit included (`reap_group`, as the check guard), before it reads `usage.jsonl` and answers, so
  nothing the build left in its group outlives the build, and what it spent until then is in the file Forge reads.
  Tests: `scripts/check_cancho_code.sh` `straggle: what the build left running in its group (sleep 76) was killed when it ended`;
  `tests/conformance/company_run.sh` `a build that leaves a process in its group: accepted, and once the run ends nothing it left is
  running`. **Not fixed (cancho-code's):** while the build still runs, a timed-out agent keeps running and calling the provider beside
  the driver's next attempt, until the build ends; its usage lines land in the build's `usage.jsonl` and are counted, but late. A
  descendant that leaves the group (`setsid`) is still not reached. The fix is the driver's: start the agent as a group leader (or
  `exec` it from the shell) so that the group kill at the agent's deadline reaches it.
* The `step-failed` arm for a stale build that will not stop needs an adapter that ignores `cancel` and **is not reached by a test**; the
  worst case of cancelling a hung adapter is derived from the code (at most ten asks, each call bounded by a 30 s timeout), not measured.
* The window between the step's `execution.started` and its `accepted` record, and a signal that arrives between the last look and the
  close of the claim, are not placed by any test.
* **FIFOs**: a FIFO swapped into place *between* Forge's `dir_stat` and its open still blocks the open; a FIFO named as an analyst's
  input blocks the tool runner until Forge's deadline; the Cancho Code adapter blocks on a FIFO left as `project.cho` until its own
  deadline (an adapter issue, not fixed).
* **Other build-written files in `ev`** (`build.json` read by `build_run`, a gate's `report.json` in `gate_run`, `run.json` and
  `result.json` in the adapter) are still read with a plain open: a link or FIFO planted there by a hostile build that left a
  background process behind can exhaust memory (1 TiB cap) or block Forge while it holds the lock. Only `usage.jsonl`, artifacts and the
  tool `report.json` are read beneath `ev`, without links and capped. Not fixed; routing these through `company_files.read_artifact`
  is the follow-up.
* A tool's `report.json` that is a link, a FIFO or oversize is read as "no claim"; no test plants one.
* A `usage-invalid` run records no spend: tokens spent in it are not counted, an honest tool that leaves a directory or an oversize
  file included (the step is held, so nothing is silently rebuilt).
* The budget's two lags (kill-before-spend, shrinking `usage.jsonl`, section 9) are read from the code, not tested.

**Gate**

`scripts/gate.sh` ends `FAIL` on the machine of this build only because of 3 lines of `scripts/check_procs.sh` (`coreutils: unknown
program 'forgeprobe...'`), identical on the untouched baseline and unrelated to the company layer. *Corrected:* this said the cause was a
`pgrep` name longer than 15 characters. The measured cause is that on this machine `/usr/bin/sleep` and `timeout` are hard links to
the uutils multicall binary, which dispatches on `argv[0]`: the helper's copy named `forgeprobe$$` prints `coreutils: unknown program`
and never runs as a probe. Everything else passes.
