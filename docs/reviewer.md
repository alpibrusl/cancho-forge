# The reviewer: authority ceiling and an independent review, distinct from qa

> **Status: design, nothing built, nothing measured.** Every proposal below is *(designed)*. Statements about what exists were read from the sources named and are marked
> *(read)*. It is autonomy build step 2 (`autonomy.md` section 10) and the reviewer row of the pilot scoreboard (`pilot-results.md`).
>
> **What was read** (2026-11-02): cancho-forge `main` at `abcc439`: `autonomy.md` sections 4 and 8 to 10, `company.md` sections 8, 11 and 14 to 24, `pilot.md` section 3, `scripts/gate.sh` (its authority
> comparisons). **Not read:** the sources of `workers/gate_runner.cho` and `src/gate_task.cho` beyond their file headers.

## 1. What is missing, exactly

`company.md` section 11 *(read)*: the reviewer role is `repo.gate`, **the same path as qa**. A reviewer step today runs the same gate runner over `gates.<id>`; nothing in it differs. The design asked
for two things only a reviewer provides, both items of a merge policy (`autonomy.md` section 4):

| item | what it says | what makes it the reviewer's and not qa's |
|---|---|---|
| `authority-ceiling` | the changed repository's programs reach no more than the checked-in ceiling says | the ceiling is read from the **base** commit, the candidate's authority is computed from the **head**, and the comparison is Forge's, not the repository's own script |
| `review` | a verdict from a reviewer that did not build the change and did not see the builder's context | a separate model step with its own context, given the diff and the brief only |

A repository's own gate may already compare authority (this repository's does: `scripts/gate.sh`). That check is the repository's word about itself and the change can edit it. The reviewer's is the
operator's word about the repository, kept where the change cannot reach.

## 2. The authority ceiling *(designed)*

**The check.** For each program the registry row lists, Forge asks the compiler for the program's authority at two commits and compares:

```
base ceiling   = the ceiling file as it is at the BASE commit            (docs/authority.txt, docs/authority-<worker>.txt ...)
head authority = `cancho authority <program files> --std`, run on the HEAD tree, its `performs ... provably` block
```

The result is one of `equal`, `narrower` (a label gone: allowed, and the ceiling file should shrink), `wider` (a label added or a bound removed: **refused**), or `ceiling-missing`. A change that edits the
ceiling file in the same patch does not change the result: the base file is the one compared; the edit makes the patch touch a protected path (`publish_deny`), and a patch that touches one is not mergeable
by policy (`autonomy.md` section 4), only by the board, with the authority diff shown at the demo (lifecycle section 5.2). That is exactly the rule of `CLAUDE.md`: a widening says so, and a person decides.

**Where the list comes from** *(built)*. The operator's registry row (`repos.<id>`, `company.md` section 16) gains two keys that go together: `authority`, 1 to 4 entries `{"programs": [1 to 8 relative patterns, `*` allowed], "ceiling": "<relative path>", "std"?: true}`, one per program set, and `compiler`, the absolute path of the compiler binary that matches the row's `compiler_rev`. A row with one and not the other is `operator-invalid`, as is a pattern, ceiling or path of the wrong shape (`repo_row.rows_reason`). The manifest names none of it (`company.md` section 3). `repo_row.authority_count` and `authority_entry` read the entries; `authority_task.request` turns an entry into the `execute` request of a `repo.authority` task (built, with a round-trip test that the worker's own checks accept it); `authority_call.run` / `run_step` (`src/authority_call.cho`) journal the task (`authority-N`: proposed, approved, checked, ready, running, `execution.started`), start the worker, **recompute the verdict from `ceiling.txt` and `head.txt`** (the report's own claim is not read), note the rule tag when the verdict is a refusal, and leave the task in `verification` whatever the verdict (a `wider` is a result for the step to judge, not a failed run); a read-only check, so it may retry. Exit status 0 equal or narrower, 1 refused, 3 journal or lock, 4 no verdict, 5 a refusing verdict. Conformance: `scripts/check_authority_review.sh`, 11 checks of the call. **Where it is called:** `forge company authority <dir> <operator> <step> <commit>` (`src/company_authority.cho`, `docs/company.md` section 25), after `forge company publish`; exit 5 is the hold. It is not a step of a flow (the commit is not in the company journal), which would need `publish` to record it.

**The comparison is a pure function** *(built, R-0)* `authority_review.compare(ceiling_text, head_text) -> verdict code` over two reports, each a `performs` list of labels with their bounds and a `never touches` list of guarantees. It is parsed, not diffed: a reordering is `equal`. Codes: `equal` 0, `narrower` 1, `wider` 2, `ceiling-missing` 3, `unreadable` 4. A head label the ceiling lacks is wider, unless it is the same label with a bound where the ceiling's is the empty one (`fs_read("")`, unbounded), which is narrower; a different non-empty bound is wider. A `never touches` line the head lacks is wider (an assurance lost); one the head adds is narrower. Wider wins.

**The worker** `workers/authority_review.cho` *(designed)*: one JSON request on standard input, one line out, as every worker (`worker-contract.md`). It materialises the two trees by the gate runner's
mechanism (a throw-away checkout; it never writes the operator's), runs the compiler the operator names (`checker` of the operator file, an absolute path), reads the ceiling from the base tree, and answers
the verdict and the two blocks as evidence (`report.json`). **External programs it starts: the compiler (it is the authority oracle) and `git` for the checkouts (as the gate runner does); nothing else.** Its
own authority report is checked in (`docs/authority-authority-review.txt`), as every worker's is.

**Tags** *(designed)*: `authority-widened`, `authority-ceiling-missing`, `authority-unreadable` (the compiler's report cannot be parsed), `authority-compiler-failed` (the compiler exited non-zero, which includes a listed program with no file at the head: *corrected on building the worker, the separate `authority-program-missing` was dropped*). Each reached by a test.

## 3. The review verdict *(designed)*

A separate model step, never the builder's session. Its input is **the diff and the brief, and nothing else**: not the builder's reply, its attempts, its journal, or the audit. Its output is a closed JSON
object, `{"verdict":"approve"|"concerns","items":[{"file","line","claim"}]}`, at most 20 items, each a claim a person can check; it is **evidence, never a decision**:
- it is one item of several in the policy, never the only one (`autonomy.md` section 8);
- it cannot be the reason a change is accepted by itself, and a `concerns` verdict holds the change for a person with the items shown;
- its text is data, framed as a change request's is (`company-lifecycle.md` section 4.4).

**Whether it is worth anything is measured, not assumed** (R-1 below). Until it has been measured it is recorded and shown and **counts for nothing** in the policy.

## 4. How it fits the company

- **Built (docs/company.md section 26):** the ceiling is a reviewer step of task type `repo.authority`, run over the commit `publish` recorded. What follows is the original design, kept for the model review (`repo.review`, not built).
- The manifest gets no new task type: a reviewer step is `repo.gate` as now, and the **operator's `gates.<id>` entry names a different worker** (`authority_review`) instead of the gate runner. That keeps the manifest's closed
  shape and puts the choice where authority lives. The review verdict is a separate step of role `reviewer` and task type `repo.change`-like `repo.review` *(designed, one new task type, open question 2)*.
- Both appear in a change's flow (`company-lifecycle.md` section 3): `fix` (builder) -> `gate` (qa) -> `ceiling` (reviewer) -> `review` (reviewer, model) -> `demo`.
- The evidence is the step's artifact; the policy evaluator of `autonomy.md` step 3 reads it. Until that exists, the demo shows it.

## 5. What to measure first

| id | question | run | reading |
|---|---|---|---|
| **R-0** | does the comparison tell equal, narrower and wider apart on real programs? | the compiler's report for this repository's programs at a commit, a patch that adds a label, one that removes one, one that reorders | each verdict as designed; no false `wider` on 20 reorderings |
| **R-1** | does a model reviewer agree with an independent judge on seeded changes? | 20 seeded changes of known fate (10 correct, 10 with a planted fault the audit catches), reviewed with the diff and the brief only | agreement and false-approval rate; if a false approval is over 10%, `review` stays advisory for good |

R-0 needs no model. R-1 spends money and waits for the M-1 budget decision.

## 6. Order

1. R-0 and the pure `compare`, in cancho, with unit tests for every verdict (no worker yet). **Done** (`src/authority_review.cho`, `tests/authority_review_test.cho`, `spike/r0_check.sh`; result in `spike/RESULTS.md`). The tags are not yet in the gate's docs-tag list: they enter it with the worker that emits them.
2. The worker, with a stand-in compiler script, then the real compiler, in the gate. **Built with the stand-in and run with the real compiler (`spike/RESULTS.md`, R-2); it reads the head from a commit (`git archive`), not from a working tree, so it can review a published branch commit without touching the checkout** (`workers/authority_review.cho`, `docs/worker-contract.md` section 13); the real compiler on real commits: R-2, 7 of 7.
3. The registry field, in the operator file's checks. **Done** (`src/repo_row.cho`, `tests/repo_row_test.cho`); the step that builds the task from it is next.
4. The review step (needs M-1's tool decisions), recorded and shown only.

## 7. Open questions

1. **Narrower is allowed, but should it fail until the ceiling shrinks?** Recommendation: allowed with a note; a ceiling that only ever widens by decision and shrinks by habit is fine.
2. **A new task type `repo.review`, or the review as a `repo.change` step with a different worker?** Recommendation: a new type; the output is a verdict, not a patch.
3. **Which compiler?** The repository's pinned one (`compiler_rev` of the registry row), so that the report is the one its own gate reads.

## 8. What this document does not do

It does not build a worker, choose a model, or claim a reviewer catches anything. It makes "the reviewer is qa under another name" a precise, testable gap with an order of work.
