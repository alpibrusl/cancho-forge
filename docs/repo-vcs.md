# The repository layer: one place that says how a repository is asked a question

> **Status: built for git and for `cancho vcs`: the questions (the texts that read a repository), the revisions of both kinds in every task,
> worker and reader of the journal (section 6), and the patch publish (section 7). A repository row that says `"vcs": "cancho"` is accepted.
> Not built: the review by declaration, and a file publish on `cancho vcs` (section 8).** Issue #116. A claim marked *(measured)* was measured
> on the date given; one marked *(read)* was read from the source.

## 1. What was there

Forge reaches a repository only by starting `git` through `/bin/sh`. The issue named nine files. Read again
*(read, 2026-11-23)*, the `git` commands themselves were written in **four**: `src/repo_task.cho` (the state of a
checkout, the copy of its tracked files), `src/gate_task.cho` (the head of a workspace), `src/authority_task.cho` (a
file at a commit, the tree of a commit) and `workers/repo_publish.cho` (six scripts that check a checkout, make a branch
and a commit, adopt or undo one). The other five (`company_publish`, `company_state`, `company_runner`,
`workers/repo_change`, `workers/authority_review`) call those and build no `git` text of their own. There was no layer
between: a second kind of version control would have meant a second copy of each text, in each file.

## 2. What is built

**`src/repo_vcs.cho`**: the five questions a task asks of a repository, each a function that takes the **kind** of
version control and answers the shell text.

| question | git | cancho |
|---|---|---|
| `state_script`: the head revision, its tree, `clean` or `dirty` | `git rev-parse`, `git status --porcelain` | `cancho vcs status`, `cancho vcs show` |
| `materialise_script`: a copy of the tracked files | `git ls-files -z`, then `tar` | the paths of the head's tree object, then the same `tar` |
| `head_script`: the head revision | `git rev-parse HEAD` | `cancho vcs status` |
| `file_script`: a file as it is at a revision | `git show REV:PATH` | the tree object of the change, then the blob |
| `export_script`: the tree of a revision beneath a directory | `git archive`, then `tar` | each line of the tree object: `cp`, `chmod`, or `ln -s` for a link |

The three task modules keep their functions and their signatures and call the layer with `repo_vcs.git()`. **The git
texts are byte for byte what they were**: the unit tests that pinned them before (`tests/repo_task_test.cho`,
`tests/gate_task_test.cho`, `tests/authority_task_test.cho`) pass unchanged, and `tests/repo_vcs_test.cho` pins them
once more at the layer.

**`src/repo_vcs_write.cho`**: the six scripts of the publish worker, moved unchanged out of
`workers/repo_publish.cho`, which now holds no `git` command. They were git's only; section 7 adds the `cancho` ones. The
worker's authority report (`docs/authority-repo-publish.txt`) is the same file.

**A revision** is 40 digits for git and 64 for `cancho vcs` (a change id): `repo_vcs.revision_ok(kind, text)`.

**The row.** A `repos` row of the operator file may say `"vcs": "git"`, which is also what a row that does not say
means. `"vcs": "cancho"` was **refused** until the publish was written (section 7); it is accepted now, when the operator
file's `checker` is a file named `cancho`. Any other value is `repos: vcs is not git or cancho`.

## 3. How the cancho texts read a repository

`cancho vcs` (release 0.1.0, the compiler this repository was pinned to when this was measured; the pin is release 0.1.1 since 2026-11-24) has `status` and `show`, and has no command that
prints a file at a change or lists a tree. Its store is plain files by design (`docs/vcs-cli.md` section 3 in
alpibrusl/cancho: "inspectable with the tools an agent has"): `objects/tree/AB/REST` is lines `MODE BLOB PATH`, and
`objects/blob/AB/REST` is the bytes of a file. So the cancho texts ask `cancho vcs` for the head and for the tree id of
a change, and read the tree and the blobs from the store with `sed`, `cut`, `awk`, `cp` and `cat`. **They depend on that
layout.** A `cancho vcs` that compresses or packs its objects (planned there: R4) breaks them, and the fix is a command
in `cancho vcs` (`cat`, `ls-tree`, `export`), not a cleverer shell text here. No `git` is started by any of them (the
unit test looks for the word).

## 4. Measured

`tests/conformance/repo_vcs.sh` *(2026-11-23, macOS arm64, cancho 0.1.0)* makes two repositories with the same files (a
regular file, an executable, a file in a directory, a name with a space, a link, two revisions), one kept by git and one
by `cancho vcs`, runs each text of the layer against each, and compares what the two answer: **36 checks, all hold**.
Among them: the two copies of the tracked files are the same tree (`diff -r`), with the modes and the link; an untracked
or a modified file makes both `dirty`; a file at the earlier revision is the same bytes; a missing file, a missing
revision and a directory that is no repository fail for both with the same status; the exported tree is the revision's
and not the working copy's; the checkout is never written.

## 5. What was not built when the row was refused

*Corrected 2026-11-24:* this section listed the pieces between the layer and a row that says `vcs: "cancho"`, and said "the row waits for the
publish". The publish, the gate's refusal as the publish's own and the workers' `PATH` are built (section 7), and the row is accepted. What is
still not built is section 8.

*Corrected 2026-11-23:* this section said that the tools a gate needs (`gate_task.required_tools`) would have to take
the kind. They do not: that list is what a repository's own gate script starts (Forge's gate starts `git` in its
tests), whatever keeps the workspace. The head check that runs before it starts `git` or `cancho` by the kind of the
revision, and a missing one is the shell's 127 there.

## 6. Revisions of both kinds *(built 2026-11-23)*

A revision of `cancho vcs` is a change id of 64 digits. Every place that said 40 now asks the layer:

| where | what it asks |
|---|---|
| `gate_task.revision_ok`, and so `gate_task.check` | `repo_vcs.revision_kind(text) >= 0`: 40 or 64 digits of `0-9a-f` |
| `gate_task.head_script(workspace, revision)`, `head_matches` | the text of the kind the revision is of; the digits and a newline |
| `authority_task.check` | the revision and the base are of one kind (a commit with a change is `revision-invalid`) |
| `authority_task.ceiling_script`, `export_script` | the text of the kind the revision is of |
| `repo_task.state_ok`, `state_head`, `state_tree`, `state_clean` | two lines of 40 or of 64 digits, never one of each |
| `repo_task.state_of(vcs, out)` | the state of a checkout kept by `vcs`: what the change worker asks |
| the `repo.change` request | `"vcs":"cancho"` in the input for such a row; **nothing** for git, so git's request is the bytes it was |
| `company_authority`, `company_repo_steps` (the row is at hand) | `repo_vcs.revision_ok(repo_row.vcs_kind(row), base)` |
| `company_state`, `company_publish`, `company_autopub` (the journal) | `repo_vcs.revision_sized`: as long as a revision of some kind, which is what `len == 40` asked |
| `company_runner` (the change report) | a base and a tree of one kind |

**The kind comes from the row where there is a row, and from the shape of the revision where there is none.** The
gate task and the authority task carry a revision and no row; 40 digits is a commit and 64 a change, and no text is
both. A `repos` row's `compiler_rev` and the pin files stay 40 digits (`repo_row.rev_ok`): the compiler is a git commit
whatever keeps the repository.

For git nothing changes: every unit test that pinned a text or a refusal passes with its assertions as they were (two
calls gained an argument: `gate_task.head_script`, `repo_task.state_script` and `materialise_script`).

*(measured, 2026-11-23, macOS arm64, cancho 0.1.0)* `scripts/check_authority_review.sh` now also runs the **real
authority worker** against repositories kept by `cancho vcs`, with a revision and a base of 64 digits and the compiler
on the `PATH` of the request's `env`: 11 more checks, all hold (44 in all). An equal and a wider report get their
verdicts; `ceiling.txt` is the base change's file and `head.txt` what the compiler printed in the head change's
exported tree; a change the store does not have is `revision-mismatch`; a change with a base of 40 digits is
`revision-invalid` with nothing written; the repository is left as it was and has no `.git`.

**Not measured:** the gate runner against a checkout kept by `cancho vcs` (its allow-list is four GitHub repositories with
their own gate commands). *Corrected 2026-11-24:* this said the change worker was not measured either, since `forge
company run` refused the row; it is measured now (section 7).

## 7. The publish on `cancho vcs` *(built 2026-11-24)*

`src/repo_vcs_write.cho` takes the kind, as `repo_vcs` does. Git's six texts are byte for byte what they were (`tests/repo_vcs_write_test.cho`
pins each against what the module printed before it took a kind). The `cancho` ones ask `cancho vcs` for everything and read no file of the store:

| step | git | cancho |
|---|---|---|
| the checks | toplevel, a commit, `origin` is the allow-listed repository, the head is the base, nothing modified, no such branch, no link on the way | `.cancho/vcs` here, a head, the head is the base, `status` says clean, `branch list` has no such branch, no link on the way |
| the branch | `git checkout -b` | `branch create`, `switch` |
| the commit | `git add`, `git commit -F -` (hooks off) | `record PATHS --intent-prompt MESSAGE --intent-session COMPANY --intent-issue STEP`; there is no staging |
| going back | `git checkout` | `switch` |
| adoption | parent, tree and message of the branch compared | `record --dry-run` with the time the branch's change carries answers the branch's change id |
| the undo | `git reset --hard`, untracked files removed, the branch deleted | `restore` of each file, `switch`, `branch delete --expect` |

**It is the patch publish only** (`repo.change`, then `forge company publish` or a `repo.publish` step): that is the publish that has a row. The
request to the worker gains four members for such a row and none for git, so git's request is the bytes it was: `"vcs":"cancho"`, `"compiler"`
(the operator's `checker`), `"session"` (the company's id) and `"issue"` (the step's id). The answer's `commit` is a change id of 64 digits; the
journal, `publish.txt` and `pr.md` carry it where they carried a commit.

**The intent.** The commit message Forge writes is the change's intent prompt; the company is the session and the step the issue. `cancho vcs
export-git` renders them as the commit message and the trailers `Cancho-Change`, `Cancho-Session` and `Cancho-Issue`.

**Adoption** (docs/auto-publish.md section 4) needs no comparison of parts: a change id is the hash of the tree, the parent, the intent, the author
and the time, so a dry run of the same record at the same time answers the same id exactly when the branch is what this publish would have made.

**The gate's refusal is the publish's.** `record` runs the gate of `cancho vcs` (the touched `.cho` files must check) and nothing here turns it
off. A tree it refuses is `publish-gate-failed`, with the compiler's rule in the `reason:`, and the publish is undone. Git has no such refusal: its
publish commits what the step's own check accepted.

**Where `cancho` is found.** The texts start `cancho` by name. For such a row the change worker and the publish worker put the directory of the
operator's `checker` first on the `PATH` of their shell, and the authority worker the directory of the row's `compiler` (when its request sets
no environment of its own, and Forge's sets none). So the row is accepted only when `checker` is an absolute plain path to a file named `cancho` (`operator-invalid` otherwise,
with the reason). This replaces the limitation section 5 recorded.

**No origin.** A repository kept by `cancho vcs` has no remote, so the check that holds a git checkout's `origin` to the allow-listed repository
has nothing to read: the row's `checkout` is all that says which repository it is. The `slug` is still required and still on the allow-list; it
names the repository in the provenance.

**It never exports and never pushes.** GitHub speaks git: `cancho vcs export-git <directory>` renders the branch as a git commit, and pushing
that is a person's act, as pushing a git branch is. `pr.md` says so for such a row.

*(measured, 2026-11-24, macOS arm64, cancho 0.1.0)* `tests/conformance/repo_publish_cancho.sh`, with the forge binary and the real change,
publish and authority workers against repositories made by `cancho vcs init`: **62 checks, all hold** (58 when this was written; a patch of two files was added). The change step records a base and a tree of
64 digits and leaves the checkout as it was. The publish leaves a branch at a change whose one parent is the base, with the intent, touching the
patch's file and the provenance and nothing else, and the checkout back on its branch, clean. An export made by the oracle is a git commit with
the file, the provenance and the three trailers. `publish-branch-exists`, `publish-checkout-dirty`, `patch-base-stale` and
`publish-gate-failed` each leave no branch and a clean checkout. A `repo.publish` step and a `repo.authority` step run with no command of a person
between (verdict `equal`, the ceiling read from the base change and the report made in the published change's tree). A publish whose journal
record was lost is adopted; a branch of the same name that is not ours is left alone and the step held. The worker refuses a request that names
another version control, a compiler that is not a file named `cancho`, a session that is not a plain name, a base of 40 digits, and a compiler that
is not there.

*Corrected 2026-11-24:* this paragraph said the gate of `cancho vcs` 0.1.0 refused a file that imports `std.io`, "not explained". Measured
further the same day: **it refuses any file that has an import**, of `std` or of a module of the same tree, with `unknown-name`
(`cancho vcs record --dry-run` on a library alone is accepted; on a file that imports that library, on one that imports `std.test`, and on one that
imports `std.bytes`, it is refused; `cancho check --std` and `cancho test --std` accept all of them). The cause is in alpibrusl/cancho and is not
found. What follows here: **a publish on `cancho vcs` whose patch touches a file with an import is refused `publish-gate-failed`**, and a test
file always imports `std.test`, so every change of kind `bug` or `feature` is. The fixtures of the script import nothing.

*Corrected 2026-11-24, later:* the cause was found and fixed in alpibrusl/cancho#824 (the gate of `cancho vcs record` did not follow the imports
of a file that declares no module), and release 0.1.1 (`d44389e2`) carries it. **This repository is pinned to 0.1.1 from this commit**, so the
refusal above is what 0.1.0 did and not what the pinned compiler does. *(measured with a model, 2026-11-24, macOS arm64, cancho 0.1.1,
`claude-haiku-5-5`)* The company of three steps described below, run again on the repository kept by `cancho vcs` with the released binary as
`checker` and `compiler`: `done: steps accepted 3`, the change (`src/words.cho` and `tests/words_test.cho`, which imports `std.test` and the
library) is published on `forge/words-e2e2-chg`, the authority verdict is `equal`, and no command of a person came between. One run. The
fixtures of `repo_publish_cancho.sh` still import nothing.

*(measured with a model, 2026-11-24, macOS arm64, cancho 0.1.0, `claude-haiku-5-5`)* One company of three steps (`repo.change` of kind `bug`,
`repo.publish`, `repo.authority`) on a repository of one library, one program and one test file, with the real `cancho-build` and `cancho-agent`
of alpibrusl/cancho-code and no stand-in. On a repository kept by `cancho vcs`: the change was accepted on the first attempt (a patch of two
files, 33 lines added, 1,027 tokens in and 983 out), and the publish was refused `publish-gate-failed (unknown-name)` for the reason above, with
the checkout left on its branch and clean. The same company on a git copy of the repository ran to its end with no command of a person between:
`done: steps accepted 3`, verdict `equal`, and the repository's own gate passes on the published branch (7 tests). The first try found a defect
of the publish worker that no script had reached: a patch of **two** files was refused `publish-dest-invalid` for both kinds, because the
destinations travel one to a line and the worker read the list only when it held no escape. It is fixed (the list is decoded, then every line is
held to a plain path), and `company_change.sh` and `repo_publish_cancho.sh` each publish a patch of two files now. One run of each kind: nothing
here says how often a model's change is accepted.

**Not measured:** a real repository (the largest one here is three `.cho` files); a publish on `cancho vcs` of a change with an import **by a script of the gate** (one run with a model did it, above; the fixtures of the script import nothing).

## 8. What is still not built

* **The review by declaration.** The review step is given a text diff. `cancho vcs diff` answers by declaration: not wired.
* **A file publish on `cancho vcs`.** `forge company publish` of a build step takes its repository and checkout from the operator's `publish`
  entry, which has no row and so no kind: it is git's. The worker refuses a request that asks for it (`publish-worker-failed`).
* **What `cancho vcs` itself lacks**: a merge (alpibrusl/cancho#520), a command that reads a file or a tree at a change (section 3), and a remote,
  so that the origin could be held to the allow-list. `replay` (#818) and attestations (#817) are built there and not released.
* **The gate runner** against a checkout kept by `cancho vcs`: its allow-list is four GitHub repositories with their own gate commands.
