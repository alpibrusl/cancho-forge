# Self-repair: how Cancho Code and Forge fix their own defects

> **Status: design, nothing built, nothing measured about the loop.** Tags: **[m]** measured (a file or a run on disk, named), **[r]** read in
> code or a document (named, not run), **[d]** designed. If this document and the code disagree, the code is right and this is corrected
> in place.
>
> **What was read** (2026-10-30): cancho-forge `main` at `2cf52ff` (`docs/self-hosting.md` sections 1, 2, Stage 3 to 5 and 5,
> `docs/company.md` sections 3, 8, 9, 14); cancho-forge branch `design-autonomy` at `cb92de2` (PR #54, `docs/autonomy.md`) and
> `design-isolation` at `b1ecc2b` (PR #55, `docs/isolation.md`, headings and its findings); cancho-code `main` at `0974743`
> (`docs/build.md`, `docs/journal.md`, `docs/memory.md`, `src/lessons.cho` and `src/memory.cho` headers,
> `eval/results/2026-10-29-83-diagnosis.md` and `83-rerun.md`); the cancho-diff company directory
> (`diff-company/run1.out`, `PLAN-EDIT-1.md`, `plan.json.orig-run1`, `steps/lib/ev/journal/events.jsonl` and its blobs). **Not read:**
> `src/company_*.cho`, the body of `src/project.cho`/`src/plan.cho` beyond what the PRs touched, `docs/profile.md`, `docs/multi-file.md`,
> the `fix` front door's documentation (only its authority-check header was read). Claims about those are marked **[d]** or omitted.

## 1. The requirement and its scope

The rule given by the maintainer, 2026-10-30: **a product is changed only by Cancho Code and Forge; a person supplies briefs, contracts,
audits and decisions, and approves a demo.** Cancho Code and Forge are products too. So when one of them has a defect that blocks a
build, the repair must be made by the same machinery, with a person looking at one demo, not at diffs.

This document designs that loop. It does not design strategy (what to build next: `intents.md`), merge policy
(`autonomy.md`) or sandboxing (`isolation.md`); it uses them.

**The rule was broken on the first real company run, and how is the first evidence.** On the cancho-diff build (2026-10-30) a person
edited a plan by hand, then edited the built file to make it a library, then wrote its tests and CI by hand (recorded in
`cancho-diff` PR 1, `docs/provenance.md`). This document lists, for each, what in the system should have done it (section 11, incident D).

## 2. What "a defect" is: the taxonomy, and what tells the classes apart

The loop must fire **only** on tool defects. Firing on anything else makes the tool "repair" a model's mistake, a vague brief or an
audit, and each of those has a different owner. The classes below come from the project's own records, not from a guess: the
classification of the #83 stuck runs used P, S, C, M, G and "?" **[m]** (`83-diagnosis.md`), and the "?" rows are the lesson: **a class
that cannot be told apart from what is on disk cannot be acted on automatically.**

| class | what it is | owner | mechanical evidence (what is on disk) | fires the loop? |
|---|---|---|---|---|
| **B** brief | the brief is ambiguous or contradicts its contract | the person (product role) | the same brief builds to full marks with `--contract` and to 0 without it **[m]**: ini 0/76 to 76/76, editdistance 0/54 to 54/54 (`83-rerun.md`) | no |
| **P** plan/case | a case the model wrote into the plan fails for every correct program | the planner | one unit; the same `acceptance:test <name> FAILED` signature on at least 2 attempts; `decision: signature`; `<name>` is a test of that unit in `plan.json` **[r]** (`build.md`, "A plan whose own test is the dead end", conditions 1 to 3) | no: `build` already replans once **[r]** |
| **M** model | the model's code is wrong | the unit agent | signatures differ between attempts, or a later attempt verifies **[m]** (cancho-diff `script`, attempt 1: `not-a-slice`) | no: `memory`/`lessons` **[r]** |
| **G** tool | a program of the tool produced a wrong refusal or a wrong file | the tool's repository | **a model-free reproduction exists** (below) | **yes** |
| **E** environment | the run was set up wrongly | the operator | zero tokens, zero model calls, `plan_failed` within seconds; the agent log shows the program did not start **[m, partly]** (section 11, incident C) | no (maybe a preflight, section 3 step 9) |
| **J** judge | the audit or the checker is wrong | the audit's owner | the audit fails its own reference, or a mutant passes, or it disagrees with the independent oracle (GNU `diff`) **[m]**: `diff-company/audit/` is validated this way; `eval/audit_editdistance.py` scored a correct list-shaped `closest` 0/9 until PR 102 | no |

**The discriminator for G is one test: can the wrong behaviour be reproduced without a model?** A model failure cannot (it needs the
model's reply); a tool defect can, because the tool's wrong answer is a function of files on disk: a plan, a brief, a unit's code, a
tests file. The journal keeps exactly those: `plan_final` (the plan bytes), every attempt's `prompt`, `reply`, `code` and `checker`
blobs, and the `acceptance` text **[m]** (`ev/journal/blobs/script-a0-*` exist). So triage (step 1) has material to build a reproduction
from, and a G candidate without one is reclassified `?` and goes to a person.

Two further signals make a G candidate stronger, and none alone suffices:

* **invariance under the model**: the same signature on every attempt although the diffs the model wrote differ **[r]** (`attempt` events
  carry a `diff` blob and a `signature`);
* **an independent authority disagrees with the tool**: the contract file's exact signatures, a worked example of the brief, a reference
  program, GNU `diff`/`patch`. For incident B the contract disagreed with the plan check **[m]**.

`?` is a valid class. The #83 diagnosis ended with it for five runs because the journals of those runs were not on disk **[m]**; the
loop's first duty is therefore preservation (step 0).

## 3. The loop

Each step names its mechanism: **existing** (read in code or docs), **new** (designed), and who or what performs it. A step that a model
performs never judges its own output.

0. **Preserve** *(existing, with one gap)*. The journal is append-only and survives a retry **[m]**: in cancho-diff the second run
   appended to `journal/events.jsonl` and the failed attempts, their prompts and replies remained. The per-unit files do not:
   `trail-script.jsonl` was overwritten by the second run (it now holds one `verified` line) **[m]**. *New:* a stuck or failed build
   copies `journal/` and the trail files into a write-once `evidence/<run-id>/` before any retry is admitted (Forge, in the step runner,
   next to the spend record that is already written "whatever the build's ending" **[r]**, `company.md` section 8, item 5).
1. **Triage** *(new, a program, no model)*. A cancho tool `triage`, modelled on `src/lessons.cho` **[r]**: it reads the journals it is
   named, never a prompt or a reply as instructions, and writes defect **candidates** with the discriminators of section 2
   (`defects.jsonl`). `lessons.jsonl` is an input: a refusal class with many occurrences in several runs and **a next-attempt success
   rate of zero** (the miner records both **[r]**, `memory.md`) is a candidate no model has ever fixed.
2. **Reproduce** *(new; a step by someone other than the repairer)*. A *fixture author* turns a candidate into a **model-free fixture
   that is red on the tool at the revision that failed**: a case for the tool's own gate, in the style the repository already uses. Cancho
   Code's gates run the whole chain against a stand-in agent with no model **[r]** (`build.md`, "Gate and authority"), so a fixture is a
   plan or a project file plus the command and the expected answer. The fixture author is a different step from the repairer, and the
   expected answer must come from an **independent authority** (a contract, a brief example, an oracle) named in the defect record.
   If none exists, the fixture is shown to a person as one line ("with this input the tool should answer X") and the loop waits.
3. **Brief the repair** *(new; template in section 5)*. The repair brief has a check that cannot be met by weakening the judge: the
   fixture goes green, **and** the whole gate of the repository stays green, **and** the authority reports are unchanged.
4. **Repair** *(partly new)*. A company step on the tool's own repository, run with the **pinned previous version** of the tool
   (section 6). The builder as it exists builds *new projects from a brief* and "reads no existing repository" **[r]**
   (`self-hosting.md` Stage 3); a one-file fix is the `fix` front door **[r]** (its authority is pinned in `check-authority.sh`; I did not
   read its documentation). A repair that touches several files, or a 1769-line `src/plan.cho` plus its fixtures, needs a step type that
   reads a checkout and writes a patch bounded to named paths. *New:* `repo.patch`. This is the largest missing piece (section 12).
5. **Check** *(existing)*. Forge runs the repository's gate itself on a throw-away checkout of the repair's head (`repo.gate`, the
   gate runner **[r]**) and the fixture; a worker's `done` is a claim **[r]**. *New:* the diff is compared against the **protected
   paths** of section 6; a touch is a refusal `repair-touches-judge`.
6. **Pull request** *(new, from `autonomy.md`)*. The diff goes in as a pull request. Until merge-by-policy exists **[d]**, a person merges
   (`self-hosting.md` section 5: no merge without a recorded human approval **[r]**); after it, only if the policy's evidence list
   holds, and a repair that widens an authority report or touches a protected path is never mergeable by policy.
7. **Demo** *(new)*. The single human gate (section 4).
8. **Pin and resume** *(new, from `autonomy.md` section 5)*. `pin.bump` moves dependents to the repaired revision; the company that hit
   the defect is resumed on the new tool. The resumed step reads the same journal, which is append-only **[r]**.
9. **Remember** *(section 7)*. The fixture is now part of the gate for good. If the defect was class E and recurred, a preflight is
   proposed as an ordinary change (an operator-file check in Forge that runs the agent with `--version` before admitting a build).

Steps 1 to 3 touch no network and spend nothing; steps 4 and 5 are the only paid ones.

## 4. The demo: what the person looks at

One directory, replayable, hash-bound (the same object as `autonomy.md` section 6, with this content):

| part | content |
|---|---|
| `defect.json` | the record of section 5: what failed, the class, the evidence paths and their hashes |
| `red.txt` / `green.txt` | the fixture run against the failing revision and against the repaired one, same command, output beside output |
| `replay/` | **the original failing run replayed with its recorded model replies** (the journal keeps each reply **[m]**): before the repair the tool refuses at the recorded step; after, it does not. No model is called, so it costs nothing and cannot differ between viewings **[d]** |
| `gate.txt` | the repository's whole gate on the repaired head, and the authority reports with `diff` empty (or shown) |
| `change.md` | files touched, lines added and removed, protected paths touched (must be none), the repair's cost and attempts |
| `hashes`, `replay.sh` | as in `autonomy.md` |

The person approves a **hash** of this directory (`forge company decide ... demo`, bound to the hash **[d]**), so an approval cannot
precede the demo. What the demo does not show: that the repair is the right fix rather than a fix that passes the fixture. The gate and the
replay narrow that; they do not close it (section 9).

## 5. Schemas

A defect record (`defects/<id>.json`, closed shape, written by triage and completed by the fixture step) **[d]**:

```json
{
  "id": "D-2026-10-29-tests-import",
  "class": "G",
  "tool": { "repo": "alpibrusl/cancho-code", "rev": "<40 hex>", "command": "cancho-build ... (the argv, no secrets)" },
  "symptom": {
    "unit": "get", "outcome": "acceptance_failed",
    "signature": "acceptance:tests-get.cho:3:1",
    "message": "`option` is already bound to another import here",
    "evidence": [ { "path": "journal/events.jsonl", "sha256": "<hex>" }, { "path": "journal/blobs/get-a0-acceptance.txt", "sha256": "<hex>" } ]
  },
  "discriminators": {
    "zero_model_calls": false,
    "signature_invariant_across_diffs": true,
    "location_in_generated_file": true,
    "independent_authority": { "kind": "compiler", "says": "the tests file compiles when the unit's own tests import nothing the project file imports" },
    "model_free_repro": true
  },
  "fixture": { "path": "tests/project/plan-rawtests-import.json", "written_by": "step:fixture", "red_at": "<rev>", "expected": "build verified" },
  "repair": { "attempts": 0, "max_attempts": 3, "budget_usd": 2, "step": null, "pr": null },
  "status": "captured | fixture-red | repairing | demo | merged | reverted | abandoned"
}
```

A repair brief (the text of the step's `input`; the placeholders are filled by Forge from the record, not by a model) **[d]**:

```
Repair one defect in <repo> at <pinned rev>. Defect record: <path>. Read it first.
The failing behaviour is reproduced by <fixture path>, run with <command>. It is read-only: you may not edit it, the gate scripts,
anything under <protected paths>, the authority files (docs/authority*.json) or .cancho-rev.
Done means, all three, checked by Forge and not by you:
  1. <command> passes;
  2. the whole gate (<gate command>) passes;
  3. `check-authority` reports no change.
Touch only: <allowed paths>. If you cannot meet 1 to 3 without touching a forbidden path, say so and stop: that is a finding, not a failure.
Budget: <n> attempts, <usd> dollars. Do not widen any effect row. Do not fix anything else you notice; write it down instead.
```

## 6. Guardrails

* **The repairer runs on a pinned previous version of the tool, never on itself.** The repair step uses the last tool revision that passed
  a demo (`known-good`, recorded in the registry of `autonomy.md` **[d]**). A tool that repairs itself with its own un-repaired code can
  only get as far as the defect lets it.
* **A repair may not touch the judge.** Protected for a repair: the repository's gate scripts, the fixture it must make green, the
  audits and oracles, the policy and registry, `docs/authority*.json`, `.cancho-rev`/`cancho.toml` pins, `.github/`. **Exception that
  needs a person:** a repair whose point is a pin or an authority diff (a defect in how the pin is read); then the diff is the demo's
  first page. Refusal tag: `repair-touches-judge` **[d]**.
* **A repair that widens an authority report needs a person**, whatever the policy says. The reports are the review artefact
  (`CLAUDE.md`, "narrow the body, never widen the row" **[r]**). Tag: `repair-widens-authority`.
* **The fixture is written by another step than the repair**, and its expected answer comes from an independent authority, not from the
  repairer. A repairer that cannot be made to pass fixes the fixture is the failure this rule is for.
* **Bounded:** at most `N` repair attempts per defect (proposal: 3) and a dollar cap per repair; the existing budget refusal applies
  **[r]** (`company.md` section 9). After `N`, the defect is `abandoned` and goes to a person with the evidence.
* **One defect per repair.** The brief says to write other findings down; they become new candidates, not part of this diff.
* **No hand edits of a run in progress.** The operator-bypass of section 1: the system must not require, and the operator must not use,
  edits to `plan.json`, the built file or the checker between runs. A needed edit is a defect record.
* **Isolation applies:** the repair runs under the layers of `isolation.md` as they exist; a repair worker never holds a token that
  can merge or release.

## 7. Regression memory

* **Every repaired defect leaves a permanent fixture in the repository's gate.** This is already how a defect was closed once: PR #99
  added the gate case `rawtests import` and `tests/project/plan-rawtests-import.json` **[r]** (`83-diagnosis.md`, class G row), and PR
  #103 added a case to `scripts/test-plan.sh` **[m]** (`brief-heap shown in the call`). The loop makes that the *rule*, and the defect
  record keeps the link from fixture to incident.
* **Cancho Code's memory is for model mistakes and is the wrong home for tool defects.** `lessons.jsonl` groups the compiler's refusals
  that a *model* received by class and feeds the next prompt with fixes that worked **[r]**. A tool defect has no fix that a model can apply,
  so a lesson for it would teach the model to work around a bug. The two stay apart; the only connection is that a lesson class that no
  attempt ever fixed is a triage input (step 1).
* **A register of defects** (`docs/defects.md` generated from the records) lists id, class, tool revision, fixture, the commit that
  closed it, and whether it recurred. Written by the loop; a person reads it, nobody edits it.

## 8. Metrics (all unmeasured; there is no loop yet)

| question | measure | why it matters |
|---|---|---|
| does it work | defects `merged` / defects `captured` | the headline |
| is it fast | hours from `captured` to `merged`, and person-minutes inside that | the claim is "a person only sees a demo" |
| is it honest | repairs reverted within 30 days; repaired defects that recurred in the same class | false repairs |
| does triage fire correctly | candidates confirmed by a person / candidates; G found by hand but missed by triage | a loop that repairs the wrong thing is worse than none |
| what does it cost | dollars and attempts per merged repair | against the maintainer's hours |
| is the judge safe | `repair-touches-judge` refusals per 100 repairs (should be near zero because the brief forbids it; a rise means the repairer is trying) | |
| baseline | the 2026-10-29/30 incidents by hand: the times were not recorded, so there is no baseline yet; record the next ones before building | do not claim improvement without it |

## 9. Risks

* **A repair that makes the judge easier.** Closed by protected paths and by the fixture being someone else's; open where the fixture
  itself encodes a wrong expectation. Mitigation: independent authority named in the record; a person reads the one-line expected
  answer when there is none.
* **A repair that fixes one case and breaks another.** The whole gate and the authority reports are in the check, and the replay of the
  original run; the gate's coverage is the limit. A tool with thin tests repairs thinly. This is the strongest reason to keep the rule
  "the fixture stays after".
* **Sycophantic acceptance.** The reviewer of a repair, if there is one, sees the diff and the defect record only, not the repairer's
  context, and is one evidence item, never the only one **[d]** (`autonomy.md` section 4).
* **A misclassified model failure repaired as a tool defect** teaches the tool to hide a model weakness. Triage requires the model-free
  reproduction; without one the candidate is `?`.
* **Churn.** A tool changing under a company mid-run. Resume is on the append-only journal, a step is re-verified when its tool changes,
  and a repaired revision enters only through `pin.bump` **[d]**.
* **Authority creep through repairs.** Each repair can narrow or keep a report, never widen it without a person; the sum of many
  small repairs is checked by the same pinned reports.
* **Two directions at once.** `self-hosting.md` section 5 says Forge never merges unattended **[r]**; `autonomy.md` proposes merge by
  policy **[d]**. The repair loop is safe under the first (a person merges, seeing the demo) and faster under the second. It does not
  depend on the second being accepted.

## 10. What self-repair does not do

It does not choose what to build or what to fix first (a person or an Intent does), does not repair a brief, an audit or an operator
setting, does not change policy or the registry, does not release, and does not repair a defect it cannot reproduce without a model.
It does not make the tools correct; it makes a found defect cost one demo.

## 11. Four real incidents, walked through as if the loop existed

### A. The tests file that bound an import twice (class G; cancho-code PR #99)

* **What happened [m, from `83-diagnosis.md`]:** sortedmap, unit `get`: both attempts `acceptance_failed` with the same signature
  `tests-get.cho:3:1`; the message "`option` is already bound to another import here". The model then added `import std.option as opt`
  and was refused again. The tool had written the unit's tests file with an import the project file already had.
* **Capture:** triage sees the same signature on two attempts although the diffs differ, and the location is a file the tool generates
  (`tests-<id>.cho`). Model-free reproduction: a plan whose unit's `tests` import what the project imports, built against the stand-in
  agent. Class G.
* **Fixture (another step):** `tests/project/plan-rawtests-import.json` plus the case `rawtests import` in `scripts/test-project.sh`;
  expected answer from the compiler: the tests file compiles. Red at `eb9fac5^`.
* **Repair brief:** the template above; allowed paths `src/plan.cho`; forbidden: the fixture, `scripts/test-*.sh`.
* **Green:** the fix was `plan.add_unit_test` **[r]**; fixture green, `test-project`, `test-build`, `check-authority` unchanged.
* **Demo:** `red.txt` shows the build `stuck` on the recorded plan, `green.txt` shows it verified, `replay/` shows that the recorded
  `get` unit now passes through the driver with the recorded replies. *Not shown:* that sortedmap-1 and -2 (stuck with unknown cause)
  were the same defect: their journals were not on disk **[m]**. Step 0 is what would have kept them.

### B. The plan check that refused a correct plan (class G; cancho-code PR #103)

* **What happened [m]:** the first cancho-diff plan's signatures equalled the contract file's exactly, and `plancheck` answered
  `[PLAN_ERROR] brief-heap` because the rule never read whether the brief's call showed a heap. It was found by measuring `plancheck` on
  a one-unit plan, not by the loop.
* **Capture:** triage's second signal: **the tool refuses what an independent authority accepts** (contract == plan signature). Zero
  model calls, deterministic.
* **Fixture:** `tests/plans/brief-heap-shown.txt` with the case `brief-heap shown in the call` (expected: refused only for `from_roman`).
  Red at `0974743`.
* **Green:** one condition `bytes.find(call, "heap") < 0` in `brief_heaps` **[r]** (`src/plan.cho`); plan, build, briefs and authority
  gates unchanged.
* **Lesson for the loop:** the defect was introduced by an earlier change that had a fixture (PR #100) but no case where its rule must
  *not* fire. A repair's fixture set must include a negative case for any rule it adds: the repair brief says "also add a case where the
  rule must not fire". Tag candidate: `repair-no-negative-case` **[d]**.

### C. Four builds dying in zero seconds (class E; 2026-10-29)

* **What happened [m, partly]:** the first #83 re-run: all four builds `plan_failed` in 0 s with $0 spent, because the agent's empty
  environment dropped `CANCHO_AGENT_BIN`. **Evidence limit:** the journals of that attempt were overwritten by the re-run in the same
  directories; what survives is the session record and `runs-83/results.txt` after the fix. This is the case step 0 exists for.
* **Capture:** zero tokens, zero `plan_call` events, `plan_failed` within seconds: class E, not G. The loop does **not** repair the
  environment. It proposes one tool change once the class recurs: a Forge preflight that runs the configured agent once and refuses to
  admit a build when it does not start (`operator-agent-unstartable`), with its own fixture (an operator file naming a missing agent).
* **What the person sees:** not a demo; an E candidate with a one-line cause, and, if the preflight is proposed and built, a demo of
  it.

### D. The wrong case in the plan (class P; cancho-diff, 2026-10-30): the loop does not fire, and the hand edit was the bypass

* **What happened [m]:** unit `script` of cancho-diff: attempts 0, 2, 3 `acceptance_failed` on `test_script_7`, attempt 1 `refused`
  (`not-a-slice`), `decision: signature` on attempt 3, `unit_end stuck`, `run_end stuck`. The plan expected `" -+"`; the merged script is
  `" -+ "` (diff `plan.json.orig-run1` against `plan.json`).
* **What the system already had [r]:** `build.md` conditions 1 to 3 hold exactly for this run (stuck; the last attempts the same
  acceptance failure with `decision: signature`; the test is a test of that unit in the plan). With condition 4 (the plan is the one
  that run built, unedited) and `--guide` given, a second invocation **replaces the plan once** (`plan_replaced`). Forge re-admits a step
  whose worker ended without a claim on the next invocation **without any gate** (`company.md` section 8, item 6 **[r]**): the
  `retry:lib` approval given that day was not needed.
* **What was done:** the operator edited the string by hand and approved `retry:lib`. Condition 4 then made the plan "theirs" and
  suppressed the replan (no `plan_replaced` in `events.jsonl` **[m]**). **Whether the replan would have produced a plan that passes is
  unmeasured.** The defect is not in the tool; the lapse is in the operator, and it motivates the rule "no hand edits" and the
  observation that **the repair path for class P already exists and should have been run**.
* **Loop behaviour:** triage classifies P (not G): no model-free reproduction, a plan-owned test; it records the incident and does not
  open a repair. If the replan also failed, the next owner is the person on the brief (class B or P escalated), not the tool.

## 12. Open questions for the maintainer

1. **The repair step type.** Today's builder does not edit an existing repository **[r]**. Is `repo.patch` (a worker that reads a
   checkout and returns a patch bounded to named paths) the next Code feature, or is the `fix` front door extended to several files? The
   loop cannot run on files like `src/plan.cho` until one exists. Unknown: how well a model repairs a 1769-line file; measure on past
   defects (#99, #103) as a replay before building the rest.
2. **Who writes the fixture** (step 2): a model step with an independent authority, or always the person? The first is faster and the
   weak point; the second is slow and safe. A proposal: model step, with the person approving only fixtures without an authority.
3. **Is a replay with recorded replies acceptable as demo evidence** when the failing run's journal is partial? Proposal: no replay, say
   so in the demo, and fall back to the fixture alone.
4. **`N` and the dollar cap** per defect. Proposal 3 attempts, 2 dollars; both unmeasured.
5. **The known-good tool** per repository: defined as "the last revision that passed a demo". For a defect that exists in every revision
   (incident A), the repairer runs on the defective one; is that acceptable when the defect cannot block the repair run itself?
6. **Merge of tool repositories.** Does merge-by-policy (`autonomy.md`) apply to cancho-code and cancho-forge, which `self-hosting.md`
   section 5 holds to "never merge unattended"? This document works under either answer.
7. **Where triage lives**: a cancho-code tool beside `lessons` (reads journals), or a Forge analyst step. The first reuses the journal
   readers; the second fits the company journal. Proposal: cancho-code, called by a Forge analyst step.
8. **The bootstrap path (section 13) and its audit:** who may take it, and how often is too often.

## 13. The bootstrap problem, plainly

If the defect blocks the repair loop itself (Forge cannot admit a builder; the planner refuses every plan; the gate runner cannot run;
triage or the merge path is the broken part), the loop cannot repair it and **a person has to make the change by hand.** The design does
not hide this; it limits it:

* the person's change still needs the red fixture first and the green gate after, so it enters the same register
  (`status: repaired-by-hand`, counted separately in the metrics of section 8);
* the previous known-good tool can usually still run the repair of a defect in the *current* one, which is why the repairer is pinned;
* a defect present in the known-good revision too, and blocking the repair step, is the case with no automatic exit;
* every hand repair is a candidate for a new class-E or preflight item so the same hole is closed for the machine next time.
