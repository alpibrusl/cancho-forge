# Library steps: `cancho-build --library` through Forge, and publishing both files

**Status: built and tested with a stand-in build tool** (`tests/conformance/company_run.sh`, `scripts/check_cancho_code.sh`,
`tests/conformance/repo_publish_library.sh`, unit tests; all run by `scripts/gate.sh`). **Not run with the real `cancho-build --library` or a
real model**, and not run against a real repository. If this document and the code disagree, the code is right and this document is
corrected in place.

## Why

The first cancho-diff build ([`autonomy.md`](autonomy.md) section 5) ended with a person turning `project.cho` into a module by hand
(`module diff;`, `pub` on three functions, `cancho fmt`) and writing its tests. cancho-code now does that itself: `cancho-build --library NAME
--contract C` writes `src/NAME.cho` and `tests/NAME_test.cho` after a `done` build (cancho-code `docs/library.md`). What Forge lacked was a way
to ask for it, and a way to publish two files. Nothing here changes what the audit judges or what Forge decides; it only carries the request
in and the two files out, hashed by Forge itself.

## A step that asks for a library

```json
{ "id": "lib", "role": "builder", "task_type": "project.build", "needs": ["brief"], "input": "...",
  "check": "audit_lib.sh", "contract": "contract.txt", "library": "diff" }
```

`library` is a module name (`company_manifest.library_name_ok`, the rule of cancho-build's `library-name`: lowercase letters, digits and `_`,
not starting with a digit, 1 to 64 bytes, not `std` or `test`) and needs a `contract` (the contract names the public functions) and a
builder or writer role. Refusals at `forge company check`: `library-role-invalid`, `library-name-invalid`, `library-needs-contract`.

## What Forge does with it

1. **Before the build.** Next to `contract.txt` Forge writes `library.txt` (the module name, nothing else) in the step's execution
   directory, replacing anything there, a link included. A step with no `library` has a stale `library.txt` removed.
2. **The adapter** (`workers/cancho_code.cho`) reads `library.txt` and checks it again (`build_task.library_checked`): a name that is not a
   module name, a `library.txt` that is not a plain small file, or one with no `contract` is `library-invalid`, refused before anything is
   started. Otherwise `--library NAME` is the last option of `cancho-build`'s argument vector. The module name never comes from the task
   or the manifest at that point: it is a file Forge wrote. (Why a file and not a field of the request: the request is built by five
   functions that already carry fourteen values; `contract.txt` is the precedent for a Forge-written file in the execution directory.)
3. **After the build, before the check.** Forge hashes `src/NAME.cho` and `tests/NAME_test.cho` beneath the execution directory by the rules
   of every artifact (regular file, no link followed, at most 16 MiB) and appends one `company.step.library` record to the company journal
   (`library`, `src_sha256`, `tests_sha256`). A file that is not there (a build that said `done` and left nothing) is `artifact-invalid`
   with the file named, the step held like any unavailable check, nothing recorded.
4. **The check** is unchanged and still judges `project.cho` (the held-out audit of cancho-diff reads `project.cho`). The library files are the
   build tool's transformation of it, verified by the tool's generated tests; no check of the company judges them. That is a gap, said in
   `company.md` section 14.

Replay ignores nothing it should read: a `company.step.library` record with a missing field is `event-malformed`; one that is fine changes
no step state. An older Forge replaying a journal with such a record skips it.

## Publishing the two files

```json
"publish": { "lib": { "repo": "alpibrusl/cancho-diff", "checkout": "/abs/checkout",
  "files": { "src/diff.cho": "src/diff.cho", "tests/diff_test.cho": "tests/diff_test.cho" } } }
```

`files` may name `project.cho` and, for a step with a library, `src/<library>.cho` and `tests/<library>_test.cho`, each at most once, each
to a destination `publish_plan.dest_ok` accepts and that no other entry (or `docs/provenance.md`) uses. `forge company publish` hashes each
named file again against the journal (`company.step.accepted` for `project.cho`, the last `company.step.library` before the last acceptance
for the others), sends the first as the worker's main file and the rest as `more` (at most three in all), and the worker, which trusts no
caller, checks every destination and hashes every file again before it writes: all files and the provenance are staged together and committed
once. A mismatch undoes the branch (`publish-artifact-changed`).

The provenance gets a `## Files` section listing each destination with its digest when there is more than one file.

## Tags

| tag | where |
|---|---|
| `library-role-invalid`, `library-name-invalid`, `library-needs-contract` | the manifest (`forge company check`) |
| `library-invalid` | the adapter, a `library.txt` it will not use |
| `artifact-invalid` (the library file named in `artifact:`) | the runner, a library file that is missing, not a regular file or over 16 MiB |
| `publish-file-unaccepted`, `publish-dest-invalid`, `publish-artifact-changed` | publish, as before, now also for the library files |

## What it does not do

* It does not make the audit judge the library files (above).
* It does not publish CI, README or anything else a build did not write and Forge did not hash.
* It does not journal the publish (as before).
* It does not run `cancho-build --library`; the stand-in honours the flag as the real tool is documented to. The first real run will show
  whether the real tool's output paths match (`src/NAME.cho`, `tests/NAME_test.cho` in the work directory, per its `docs/library.md`).
