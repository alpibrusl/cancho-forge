# The repository layer: one place that says how a repository is asked a question

> **Status: built for the questions (the texts that read a repository), for git and for `cancho vcs`, and for the
> revisions of both kinds in every task, worker and reader of the journal (section 6). Not built: the publish on
> `cancho vcs`, so a repository row that names it is still refused.** Issue #116. A claim marked *(measured)* was measured on the date given; one
> marked *(read)* was read from the source.

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
`workers/repo_publish.cho`, which now holds no `git` command. They are git's only (`repo_vcs.publish_built`). The
worker's authority report (`docs/authority-repo-publish.txt`) is the same file.

**A revision** is 40 digits for git and 64 for `cancho vcs` (a change id): `repo_vcs.revision_ok(kind, text)`.

**The row.** A `repos` row of the operator file may say `"vcs": "git"`, which is also what a row that does not say
means. `"vcs": "cancho"` is **refused** (`operator-invalid`, `reason: repos: vcs is cancho, which the tasks are not
wired to yet (docs/repo-vcs.md): only git`): a row that named it and was run against `git` would be worse than a
refusal. Any other value is `repos: vcs is not git or cancho`.

## 3. How the cancho texts read a repository

`cancho vcs` (release 0.1.0, the compiler this repository is pinned to) has `status` and `show`, and has no command that
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

## 5. What is not built, and why the row is refused

The issue's second step ends when the conformance scripts pass unchanged against a row that says `vcs: "cancho"`. That
is not reached, and these are the pieces between:

* **The publish.** A branch, a commit with the provenance and its trailers, adoption and undo are git's six scripts.
  For `cancho vcs` they are `record` with the intent (the company, the job and the run as `--intent-session` and
  `--intent-issue`), and, while there is no cancho remote, `export-git` to the GitHub origin. Not written.
* **The gate's refusal as the task's refusal.** `cancho vcs record` refuses a tree that does not check (`gate-failed`,
  with the rule tag). Reported as the publish's own refusal: not written.
* **The review by declaration.** The review step is given a text diff. `cancho vcs diff` answers by declaration: not
  wired.
* **The change worker's `PATH`.** `workers/repo_change.cho` gives its shell a fixed `PATH` (`/usr/local/bin:/usr/bin:/bin`),
  and the cancho texts start `cancho` by name: on a host where the compiler is elsewhere, the state of a checkout kept
  by `cancho vcs` cannot be read. The authority worker takes the operator's `env`, which is how section 6 ran it.
* **What `cancho vcs` itself lacks**: a merge (alpibrusl/cancho#520), and a command that reads a file or a tree at a
  change (section 3). `replay` (#818) and attestations (#817) are built there and not released.

So the first change (#117) is the issue's first step in full, and of its second step the module and its measurement;
section 6 is the revisions. The row waits for the publish.

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

**Not measured:** the gate runner and the change worker against a checkout kept by `cancho vcs`. The gate runner's
allow-list is four GitHub repositories with their own gate commands; the change worker is reached through `forge
company run`, which refuses the row. Their texts are the ones section 4 measured, and their revision checks are unit
tests only.
