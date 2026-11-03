# Publishing inside the flow: `repo.publish` as a step

**Status: slices A1, A2 and A3 built (docs/company.md section 27).** Written before the code (`CONTRIBUTING.md`); every claim marked *measure* is checked by a case named below before this document says it is true. Where the code differs from this text, section 27 of `company.md` lists it, and the text below is corrected in place.

## 1. The gap

Section 26 of [`company.md`](company.md) left one hole: `forge company publish` is a person's verb, so a flow
`fix → publish → ceiling` stops at `authority-unpublished` until someone runs it. A company cannot reach `done` without a person
running a command whose whole effect is a **local branch and commit in a checkout**. That command has no outward effect: it never pushes
(`publish-push-not-granted`), and its result is undone by deleting the branch.

The act that matters is the one after it: **push and open the pull request**. That stays a person's act. This document moves only the
local publish inside the flow, and keeps the line where it is.

## 2. The step

A task type **`repo.publish`** (code 6, `autonomy.md` section 5 named it) with no role to offer it: it is run by Forge, not by an agent,
so `step_rules_code` accepts it only with `"role": "system"` (a new fixed role, never in a manifest's `roles`; any other role is
`task-type-unsupported`). Shape:

```json
{"id": "publish", "role": "system", "task_type": "repo.publish", "needs": ["fix"]}
```

* `needs` is exactly one `repo.change` step (a builder or library step still needs the verb), else `publish-step-invalid`,
  exit 1, nothing written.
* It is *ready* when the step it needs is accepted **and every other step that needs it for review (`qa`) is accepted**: the flow
  author orders it with `needs` on the review step too, as for any step. Forge adds no hidden ordering.
* The reviewer's `repo.authority` step then `needs` the change step **and** the publish step. Its precondition (`authority-unpublished`) is satisfied by the
  journal record the publish step writes, so what it reads does not change.

## 3. The grant

The company manifest says *what happens*; the **operator file says what is allowed**, as for every effect. New field, form-checked as the
others (`operator-invalid` with a `reason:`):

```json
"auto_publish": {"<repos id>": {"branch_prefix": "forge/"}}
```

* No entry for the step's repository: the step is **refused** `publish-auto-not-granted`, exit 1, not admitted. The company file cannot
  grant itself publication.
* The branch is **not chosen by the company**: `<branch_prefix><company id>-<id of the repo.change step>`, checked by the same branch rules as the verb
  (`publish-branch-invalid`). It is therefore the same on every run, which is what makes the step idempotent (section 4).
* `branch_prefix` is 1 to 40 bytes of `A-Za-z0-9._-/` ending in `/`. Nothing else is configurable: no push, no remote, no force, no
  file list beyond what the person's verb already takes from the `publish` / `repos` rows.

The step runs the **same code** as the verb (`company_publish`, the same worker, the same checks and the same journal record). It is
not a second implementation, so every `publish-*` tag of section 12 applies unchanged.

## 4. Failure and rerun

The existing exit contract holds: 0 accepted, 1 refused, 13 held, 14 unavailable, 4 I/O.

* **Rerun after success.** The step is accepted; `run` does not start it again. A publish a person already made (the journal holds the record) is
  taken as the step's own: accepted with that commit, no second branch.
* **Crash between the commit and the journal record** (the verb exits 4, the commit exists). A rerun finds the branch and no record. The step
  **adopts** the branch only when the worker, which holds the checkout, finds it is what the publish would make *now*: the branch's tip is
  one commit above the change's base commit, its tree is the tree of the base with the patch and the provenance file applied (the provenance
  file names the company, the step, the patch digest and the decisions recorded, so a tree that matches names them), and its message is the
  message the publish would write. Then the step appends the record and accepts, with the commit the branch already has: no second commit.
  Anything else is `publish-branch-exists`, which the step holds as `check-unavailable` (`publish-refused`, exit 14), the branch untouched.
  The worker answers an adopt request by looking at the checkout only through a staged index that it resets afterwards: nothing is committed
  and no ref moves. *Measure:* `company_change.sh` cases `crash: a branch that is what the publish would make is adopted`, `... of the
  same name that is not ours is not adopted`, `... the right tree under another message is not adopted`.
* **A publish refused after admission** (a dirty or moved checkout, `publish-checkout-dirty` and the like) is **held**: `check-unavailable`, exit 14,
  not retried; the operator cleans the checkout and `decide retry:<id>`.
* **The publish step is never retried by `run` itself.** One attempt per run, as for a check.

## 5. What this does not grant

* No push, no pull request, no merge, no remote of any kind. The step's authority is the verb's: files in one checkout and `git`
  through `/bin/sh` (`docs/authority-repo-publish.txt`). *Measure:* the authority comparison for `company_runner` must not widen
  (`docs/authority.txt`); the gate fails it if it does.
* Not a bypass of QA or of the ceiling: publishing *before* review is the point of section 26 (the commit is what the ceiling
  judges), so a published branch is **unreviewed work in a local branch**, never an accepted one. Acceptance of the company still needs
  the `repo.authority` step (and, later, `repo.review`).
* No second checkout and no worktree: two steps publishing to one checkout run one after the other under the company lock.

## 6. Why a step, not a flag on `run`

A flag would publish after any accepted change with nothing in the manifest saying so. A step is in the flow, visible in `status`, has an
id the reviewer `needs`, can be left out of a company that must not publish, and fails and holds as a step. The grant being in the
operator file keeps the second key in a different hand from the first (company author vs. operator).

## 7. Slices

| Slice | Content | Measured by |
|---|---|---|
| **A1** | `repo.publish` task type, `system` role, `Runner::Publish`, the operator `auto_publish` field and its form check, refusals `publish-step-invalid`, `publish-auto-not-granted`; the runner calls the verb's code | unit (manifest rules, operator form); `company_change.sh` `autopub:` cases: not granted → refused and not admitted; granted → branch `forge/<company>-<step>`, journal record, step accepted |
| **A2** | a whole flow `fix → qa → publish → ceiling` to `done` with **no person command between**, then the branch is the only thing in the checkout that changed | `company_change.sh` `autopub: flow to done`; checkout `git status` clean, `git branch` shows exactly the one new branch, remote refs unchanged |
| **A3** | adoption after a crash (section 4) | the `crash:` cases of `company_change.sh` (adopted; another branch of the name; the right tree under another message); `test_a_patch_request_asks_to_adopt_only_when_it_says_so` |

## 8. Open questions

1. Should the branch name allow a person-chosen suffix? Proposed: no. A name Forge derives is idempotent and cannot collide with a
   person's branches by construction (the prefix is the operator's).
2. One `auto_publish` per repository, or per `(repository, flow)`? Proposed: per repository; a finer grant can be added when a second flow
   needs it.
3. Should a held `repo.authority` verdict *delete* the unreviewed branch? Proposed: no. Deleting is an act on the checkout nobody asked
   for; the hold names the branch and a person decides.
