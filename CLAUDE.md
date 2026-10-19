# CLAUDE.md -- cancho-forge

This repository is written in **cancho**, and only in cancho. Before
writing any program here read
[`AGENTS.md`](https://github.com/alpibrusl/cancho/blob/main/AGENTS.md)
(how to write cancho; `cancho agent-guidelines` prints it from the
compiler, so a checkout is not required) and, before anything that changes
how a program is built or checked,
[`CONTRIBUTING.md`](https://github.com/alpibrusl/cancho/blob/main/CONTRIBUTING.md).
The rules that matter most here:

- **The gate**, all passing, before anything is called done
  (`scripts/gate.sh` runs the four):
  1. `cancho fmt --check src tests spike`
  2. `cancho check <file> --std` on every program (`src/*.cho` as one
     program, each `spike/*.cho` on its own)
  3. `cancho test` (the `[[test]]` sets in `cancho.toml`)
  4. no `.cho` file over 2,000 lines
- **Design before code**, in `docs/`, with claims measured. A claim that
  turns out false is corrected in place, in the document that made it,
  with the commit that corrected it. Spikes live in `spike/` and their
  results, including what failed, in `spike/RESULTS.md`.
- **No source file over 2,000 lines.** Split by concern; never raise a
  ceiling.
- **Every refusal has a rule tag.** Anything Forge declines to do -- a
  denied action, an invalid transition, a malformed worker reply, an
  exhausted budget -- is reported with a stable, documented `rule` name,
  the way the compiler reports its own (`docs/architecture.md`, section
  "Refusals"). A new refusal is not done until its tag is documented and a
  test reaches it.
- **Python (or any other language) is for test oracles only, never
  product logic.** A script may check a result from outside the program
  (the way `spike/run.sh` uses `cat`, `od` and `ps`); nothing Forge
  decides, stores or enforces is written in anything but cancho.
- **Narrow the body, never widen the row.** Effect rows are exact, and
  `cancho authority` is the review artefact: a change that widens a
  program's authority says so in its commit message.
- **No input may reach a panic.** Parse errors, short reads, a worker that
  lies, a journal torn mid-record: each is a value handled on a named
  path, never a trap. (A trap is how cancho enforces a capability bound;
  Forge checks first so the bound is never what stops it. See
  `spike/RESULTS.md`, S3.)
- **Compiler pin.** `cancho.toml` names the compiler revision. Do not
  bump it without re-running `spike/run.sh` and the gate.
