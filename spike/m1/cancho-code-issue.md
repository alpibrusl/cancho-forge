# Proposed issue for alpibrusl/cancho-code (not filed: the session was not permitted to write to that repository)

**Title:** repo.patch: let the caller say which files the model is shown (bundle-too-large on a real repository)

`cancho-build --repo` shows the model every `.cho` file of `src/` and `tests/` and refuses (`bundle-too-large`, exit 2) when they hold more than 400,000 bytes.
**cancho-code itself holds 1,110,491** (`src/` 948,566, `tests/` 161,925), so the tool cannot be pointed at this repository, and so cannot be pointed at any company
repository of that size. Measured 2026-11-02 while preparing M-1 of cancho-forge's `docs/company-lifecycle.md` (cancho-forge#74, `spike/RESULTS.md`).

## Asks
1. **A way to name the files the model sees**, for example `--show FILE` (a list of paths, or globs) next to `--constraints`; the rest of the checkout is still copied and
   still gated, and a change may only write inside what it was shown plus new files. Without it a company repository over 400 KB cannot be a `repo.change` target.
2. **Let the repository's own test count.** For kind `bug` the gate requires an added or changed `fn test_*` under `tests/` that fails on the base (`no-test-added`,
   `test-passes-on-base`). The tests that closed #99 and #103 are shell fixtures (`scripts/test-project.sh`, `scripts/test-plan.sh`), so a faithful fix of those defects cannot
   satisfy the gate the way this repository tests. Something like `--judge SCRIPT` (run on the tree, exit 0 passes) as an alternative to the `_test.cho` rule would let the
   operator's gate decide.

Neither is urgent for the tool as it is used on small repositories; both decide whether `repo.change` can work on the repositories a company will actually own.
