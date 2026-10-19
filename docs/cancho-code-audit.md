# Cancho Code interface audit

> **Status: done for Milestone 0 (the interface audit item of the roadmap).**
> What this document does: records what the real Cancho Code interface *is*,
> as read from its source and documents and as **run** here, and lines it up
> against [`worker-contract.md`](worker-contract.md) (`forge-worker/1`). The
> corrections that follow from it have been made in the contract, in place.
> What it does not do: it does not run a real build (that needs a model key
> and spends money), and it does not audit `lex-loom` (no copy of it was
> available; see section 9).

## 0. What was audited, and how

| | |
|---|---|
| Subject | `alpibrusl/cancho-code`, read-only checkout `/home/user/alpibrusl/cancho-code`, commit `7da1bf6181375ed314d72e24c0444b4081af8c37` (2026-10-16, "Merge pull request #90 from alpibrusl/multi-file"). Its `.cancho-rev` is `2e72479d42535fb8becd58e9ad29310ca1c91831`. |
| Compiler used here | the Forge pin at the time, `2aa83b23dd3d9ea0f4551098597bc7b51dc2aecd` (since bumped to `8411e9a`; `/home/user/cancho/target/release/cancho`). **This is not the revision Cancho Code names**, and the named one (`2e72479`) is not in the local cancho checkout (`git cat-file` answers "could not get object info"), so what changed between the two could not be inspected. Both offline gates below passed anyway. |
| Read | `README.md`, `docs/build.md`, `docs/journal.md`, `docs/project.md`, `docs/reference.md`, `docs/mcp.md`, `docs/dashboard.md`, `docs/design.md` (header), `src/build.cho`, `src/project.cho` (parts), `src/trail.cho`, `src/acceptance.cho`, `src/driver.cho`, `src/checker.cho`, `src/cancho_agent.cho` (header, usage log), `src/mcp.cho` (scripts), `tests/programs/build.cho` (`main`), `scripts/test-build.sh`, `scripts/test-mcp.sh`, `docs/authority-build.json`, `eval/prices.json`, `LICENSE`, `NOTICE` |
| Not read in full | `src/project.cho` (2,725 lines), `src/cases.cho`, `src/lessons.cho`, `src/board.cho`, the parallel pool; only the parts cited |
| Method | Claims are tagged **(source)** when read from a file, with `file:line`, and **(run)** when produced by running something here. Where a document and the source differ, the source is cited. |
| Not covered | a real model (no key was used or needed); `--provider ollama`; macOS; `--jobs` above 1 under a real agent; the board tool; anything over a network |

## 1. The short version

Cancho Code is **not** a "JSON request on stdin, JSON response on stdout"
program. It is a **command-line build tool whose request is its arguments and
a brief file, whose response is a directory of files plus an exit code, and
which runs for minutes**. There are two front doors:

1. `cancho-build` (`src/build.cho`, built by `scripts/build-cancho-build.sh`):
   a process started with an argument vector, run directory in, verdict line
   and exit code out. Resumable by running the same command again.
2. `cancho-mcp` (`src/mcp.cho`): an MCP server over stdio that starts
   `cancho-build` detached and exposes start / status / unit story / retry /
   patch / result / stop as tools. This one *is* JSON, and *is* `async` in the
   contract's sense, but it is JSON-RPC 2.0 with a session, not
   `forge-worker/1`.

Neither matches section 1 of the draft contract. The five largest
disagreements, each measured or cited below:

| # | The draft contract said | The real interface |
|---|---|---|
| 1 | one JSON object on stdin, one on stdout | arguments only; stdout is tab-separated `[TAG]<TAB>...` lines; the result is a directory |
| 2 | exit 0 = "I produced a response", non-zero = `worker-error` | **the exit code is the verdict**: 0 `done`, 1 `stuck` / `gate_failed`, 3 `plan_failed`, 4 `provider_error`, 2 usage. 1, 3 and 4 are well-formed outcomes, not crashes |
| 3 | a first adapter at the `sync` level; `cancel` = TERM then KILL, "reaped either way" | a build takes minutes (a plan, then a model call per unit): it is `async` by nature. TERM ends it with exit 143 and **no verdict**; **its agent child kept running (run)** |
| 4 | `repo.change`: edit an existing repository at `grants.workspace` | it **builds a new project from a brief** into a work directory. Editing an existing file is `fix`, one file at a time, a different tool |
| 5 | `cost` is `worker-reported`, `limits.budget` is enforced by the worker | no money is recorded or limited: only tokens (`usage.jsonl`) and attempt / round ceilings. Dollars exist only when a separate board tool multiplies tokens by a dated price file |

## 2. The process interface

### 2.1 Arguments *(source)*

```
cancho-build <checker> <brief.txt> <workdir> <agent-command> --provider <p> --model <m> [options]
```

`docs/build.md:6`, `tests/programs/build.cho:5`. All of it is `argv`:
there is **no stdin protocol**. The `main` reads `Args`, `Io` (to write),
`Fs`, `Exec`, `Clock`, `Heap`; it releases `Net`, `Ffi` and `Signals`
(`tests/programs/build.cho` main, `tests/programs/build.cho:149-152`,
`:362-367`). It never reads standard input.

| argument | rule | cite |
|---|---|---|
| `checker` | absolute path of the cancho compiler; relative is exit 2 (a relative one "died with SIGILL") | `tests/programs/build.cho:202`, `docs/project.md:20` |
| `brief.txt` | must be readable; no `..` | `tests/programs/build.cho:207`, `:314-319` |
| `workdir` | must exist; no `..` | `docs/build.md:9`, `tests/programs/build.cho:207`, `src/build.cho:383` |
| `agent-command` | **a shell command line**, run through `/bin/sh -c`; the tool adds `--provider`, `--model`, `--usage-log` | `docs/build.md:9`, `src/build.cho:239-280`, `src/acceptance.cho:124` |
| `--provider`, `--model` | required, **no default for either** | `tests/programs/build.cho:216-219` |
| `--guide` | how to write a plan; required unless the workdir holds a valid `plan.json` | `docs/build.md:14`, `src/build.cho:405-407` |
| `--attempts N` (4), `--agent-seconds N` (30), `--rounds N` (3), `--plan-seconds N` (900), `--jobs N` (4, 1-64) | ceilings; **there is no whole-run deadline and no money limit** | `tests/programs/build.cho:165-173`, `docs/build.md:17-19`, `docs/project.md:122` |
| `--review on --review-guide`, `--contract <file>`, `--memory <dir>`, `--remember`, `--retry <unit> [--hint]`, `--patch <unit> <file>` | optional | `docs/build.md:11-21`, `:81-104` |

Every path, provider and model "may hold only letters, digits and
`. _ / + : = @ % , -`" because they are spliced into a shell command line
(`docs/build.md:23`, `tests/programs/build.cho:80-92`). **Any workspace or
execution path Forge hands it must obey that charset**; no spaces, no quotes.
An unknown option is exit 2 with nothing run (`tests/programs/build.cho:221-229`).

### 2.2 Environment and credentials *(source, run)*

* The agent is started with the environment **`PATH=/usr/local/bin:/usr/bin:/bin`
  and nothing else** (`src/acceptance.cho:124`, `src/driver.cho:238`;
  `docs/project.md:118`). The build tool itself used no environment of its
  own: **(run)** `env -i cancho-build ... ` against the stand-in agent ended
  `[BUILD_VERDICT] done`, exit 0.
* The API key is **a file path named inside the agent command**
  (`--key-file ...`), never the environment, never an argument value
  (`README.md:60`, `docs/build.md:9`). So Forge cannot pass a credential "on
  stdin, per task" as architecture section 5.3 says; it can only *grant a
  file* (and the build tool's `Exec("")` means the file is reachable by
  whatever the agent command runs, section 6).
* The provider and model are the operator's, per run; a task cannot choose
  them without Forge composing the command.

### 2.3 Processes it starts *(source)*

`/bin/sh -c "<agent-command> ..."` for the plan agent and each unit's agent
(`src/acceptance.cho:111-124`, `src/driver.cho:238`); `/bin/sh` for the
checker (`src/checker.cho:88-96`), and with `--jobs` above 1 **itself again**
as `<self> --unit-worker ...` (`src/project.cho:1501-1538`, `:1755`). Its
authority report, which I regenerated with the pinned compiler, says
`exec("")`, `fs_read("")`, `fs_write("")`, no network, no signals
(**run**, `cancho authority`; pinned in `docs/authority-build.json`). `exec("")`
is **every program**: the `Exec` bound Forge puts on *starting* `cancho-build`
does not bound what `cancho-build` then starts (architecture G2, now with a
concrete case).

## 3. Outputs

### 3.1 Standard output, standard error, exit code *(source, run)*

Standard output carries lines of the form `[TAG]<TAB>field<TAB>field`
(`src/project.cho:98-117`, `src/build.cho:336-343`). One happy run, with the
stand-in agent of the build gate (**run**, exit 0, nothing on standard
error):

```
[BUILD_STAGE]	plan
[PLAN]	valid
[BUILD_STAGE]	build
[PLAN]	valid
[UNIT]	a	building
[ACCEPTANCE]	pass
[ISSUE_VERDICT]	verified	attempts 1
[UNIT]	a	verified
 ... (b, c) ...
[PROJECT_VERDICT]	done
[BUILD_VERDICT]	done
```

`[UNIT]<TAB><id><TAB>building|verified|kept|regressed|failed|skipped|unavailable`
(`docs/build.md:71`); `[ACCEPTANCE]` and `[ISSUE_VERDICT]` are printed to the
console and not to `run.log` (`docs/build.md:71`).
Standard error carries only usage errors (`tests/programs/build.cho:189`,
`:203-305`); the agent's own standard error goes to `agent-<id>.log`
(`docs/build.md:64`).

| exit | `[BUILD_VERDICT]` | meaning | cite |
|---|---|---|---|
| 0 | `done` | every unit verified and the final gate held | `docs/build.md:44`, `src/build.cho:315-326` |
| 1 | `stuck` | a unit failed (refusals, examples, or the agent reached the model and gave up) or depended on one that did | same |
| 1 | `gate_failed` | every unit verified, the whole did not check | same |
| 3 | `plan_failed` | no valid plan (rounds used up, `plan.json.questions.json` needs a decision, or the plan check refused it). **Nothing is built.** | same |
| 4 | `provider_error` | the agent could not be reached / crashed / timed out, in the plan or a unit; what verified is kept | same |
| 2 | (none) | usage error, nothing run | `tests/programs/build.cho:10`, **(run)** no arguments: usage text, exit 2; relative checker: `build: the checker path must be absolute`, exit 2 |
| 143 | (none) | terminated by SIGTERM: **no verdict line**, `build.json` stays at its last stage | **(run)** section 5 |

`code_of` is a function of the verdict word (`src/build.cho:315-326`): a word
other than the first three maps to 1. The order of writes in `finish` is
`build.json` (stage `done`, `verdict`), then the `run_end` journal event, then
the verdict line (`src/build.cho:329-343`).

**Do not take the verdict from standard output.** The stream carries text a
model influenced (`[PLAN_ERROR]` lines, unit ids from a model-written plan),
and a line of that shape in it would be read as a verdict by anyone grepping.
The adapter must take the verdict from `build.json` (`verdict`, written by the
tool) **and** the exit code, and require them to agree through
`code_of`'s table; disagreement is `worker-protocol`.

### 3.2 The run directory *(source, run)*

`<workdir>/` "is the whole record of a run; other tools read exactly these
files" (`docs/build.md:56`). Listing from a real stand-in run (**run**) agrees
with `docs/build.md:58-69`: `plan.json`, `plan.log`, `state.txt`
(`verified <id>` per line), `trail-<id>.jsonl`, `agent-<id>.log`,
`project.cho` (the product), `main.cho`, `tests-<id>.cho`, `legend-<id>.txt`,
`run.log`, `build.json`, `journal/`, plus sidecars (`project.cho.task`,
`.before`, `.feedback`, `.acceptance`, `.agent.err`, `.agent.log`, `.snap0.cho`,
`.call/`), and `usage.jsonl` when the real agent ran. `build.json` after the
run, verbatim:

```json
{"brief":"/home/user/alpibrusl/cancho-code/tests/buildcmd/brief.txt","stage":"done","plan_valid":true,"units_total":3,"units_verified":3,"verdict":"done","started_unix":1792398884,"seconds":1,"provider":"stand","model":"m1","review":"none"}
```

`stage` is `plan`, `build` or `done`; `verdict` is empty until the end;
`started_unix` and `seconds` are "of this invocation", "a stamp, not a timer"
(`docs/build.md:79`). **There is no "updated" timestamp**: liveness cannot be
read from `build.json`; the MCP server decides "alive" from a recorded pid and
`ps -p <pid> -o args=` (`docs/mcp.md:79`, `src/mcp.cho:183-185`).

### 3.3 The journal *(source, run)*

`<workdir>/journal/events.jsonl` + `blobs/`. Event kinds and fields:
`docs/journal.md:139-150`; the real first lines of a run (**run**):

```
{"t_ms":1792398884706,"kind":"run_start","brief":"...","provider":"stand","model":"m1","options":{"review":false,"rounds":3,"attempts":4,"agent_seconds":60,"plan_seconds":900}}
{"t_ms":1792398884720,"kind":"plan_final","valid":true,"units":3,"plan":"plan-1792398884720.json"}
{"t_ms":1792398884727,"kind":"unit_start","unit":"a","function":"double","deps":[]}
{"t_ms":1792398885039,"kind":"attempt","unit":"a","n":0,"outcome":"verified","decision":"verified",...}
```

How it differs from Forge's journal (`architecture.md` section 4), and why it
is **not** a basis for it:

| | Cancho Code journal | Forge journal |
|---|---|---|
| Write | read the whole file, append in memory, write `events.jsonl.tmp`, `rename` over (`src/trail.cho:135-170`; `docs/journal.md:129`) | one `file_write` on an append handle, then `file_sync` |
| Cost | rewrites the whole file per event | constant per event |
| Limit | stops at 2 MiB and **the run goes on unrecorded** (`src/trail.cho:138`, `docs/journal.md:129`) | refuses or rotates; never silently drops |
| Identity | `t_ms` + `kind`; no `v`, no `seq`, no task id | `v`, `seq` (gap-free), `kind`, `task` |
| Durability | no `fsync` of the file or directory in the path read | `file_sync` before any irreversible effect |
| Torn reads | a reader sees the old or the new file (rename), never half a line | torn tail is cut on recovery |
| Multi-writer | `--jobs` units' attempt events "are put into the file, in `t_ms` order, when the unit ends" (`docs/journal.md:130`) | one writer, locked |
| Secrets | "the key and the request headers never reach it; the gate greps" (`docs/journal.md:125`) | by rule, M4 redaction |

Forge therefore **reads** this journal as untrusted evidence, by reference
and hash; it never extends it. Its events are not Forge's events.

### 3.4 What it records of cost and usage *(source)*

The agent writes one JSON line per API call to `<workdir>/usage.jsonl`
(`--usage-log`, added by the build to both agent commands:
`src/build.cho:261`, `:276`; writer `src/cancho_agent.cho:171-207`):
`provider, model, task, sample, in, out, thinking, cache_write, cache_read,
stop, outcome, status, reply_chars, program_chars, ms`. Calls that were
rate-limited or unreachable are lines too (`outcome` `rate_limited`,
`unreachable`, `api_error`: `src/cancho_agent.cho:899-921`). **Tokens only.**
Dollars are produced by `cancho-board`, from tokens and `eval/prices.json`
("fetched 2026-10-14. Prices change: re-check before quoting a cost"), as
`cost_usd` per unit (`docs/dashboard.md:26,41-43`) and in the MCP `status`
tool (`docs/mcp.md:61`). I could not run a cost computation on real usage
(no real build). So Forge's `cost` for this worker has `source:
"derived-from-tokens"`, not `worker-reported`, and Forge keeps its own dated
price table.

## 4. Lifecycle: start, resume, cancel *(source, run)*

* **Start**: run the command. The tool is a foreground process for the whole
  build. Forge must start it detached (spike S7) and record pid and start
  token before waiting.
* **Resume**: "A killed run is resumed by running the same command: a valid
  `plan.json` is not asked for again, and `state.txt` keeps the units that
  verified (they are re-checked, as in `project`)" (`docs/build.md:52`).
  Gate case `resume` (SIGKILL while building the third unit) passes
  (**run**, section 8). **(run)** after SIGTERM: the second invocation printed
  `[BUILD_STAGE] plan reused`, `[BUILD_STAGE] build`, exit 0, and the journal
  then held two `run_start` events (a resumed run appends,
  `docs/journal.md:136`). So *the run directory is the identity of the work*;
  a process is only an attempt at it.
* **Continue a stuck unit**: `--retry <unit> [--hint]`, `--patch <unit>
  <file>` (`docs/build.md:81-104`). Not a worker concept in the contract;
  it is what `partial` outcomes need (section 7).
* **Cancel**: there is **no cooperative cancel**. `main` releases `Signals`
  unclaimed (`tests/programs/build.cho:152`), so the default action of
  SIGTERM applies. **(run)**, with an agent command that execs `sleep 77`:
  `kill -TERM <pid>` gave exit 143, no verdict on standard output,
  `build.json` still `"stage":"build","verdict":""`, and **`sleep 77` was
  still alive afterwards** (its parent `/bin/sh -c ...` had the same process
  group as the build; both survived). The MCP server's `cancho_stop` walks the
  process tree with `ps | awk` and sends TERM to all of it
  (`src/mcp.cho:193-195`, `docs/mcp.md:59`); it needs `ps`, `awk`, `kill`
  and `/bin/sh`, and sends no KILL.
* **Two runs, one directory**: I found no lock in the build or project
  sources (`grep -n 'file_lock\|flock\|\.lock' src/*.cho` finds nothing,
  **run**). Only the MCP server prevents it (a pid file and `mcp.already-running`,
  `src/mcp.cho:789`). A direct adapter must hold the exclusion itself.

## 5. The MCP front door *(source, run)*

`cancho-mcp` (`docs/mcp.md`, 1,803-line `src/mcp.cho`) is JSON-RPC 2.0,
revision 2025-11-25, one message per line on stdin/stdout
(`docs/mcp.md:67`). Tools (`docs/mcp.md:53-59`): `cancho_build_start`
(`name` + `brief_path` | `brief_text` ≤ 16 KiB; detached; "a run that exists
and is not alive resumes"), `cancho_status`, `cancho_unit_story`,
`cancho_retry`, `cancho_patch`, `cancho_result`, `cancho_stop`. Errors are
`{"ok":false,"error":{"rule":...,"message":...}}` with rules `mcp.bad-name`,
`mcp.bad-path`, `mcp.too-many-runs`, `mcp.already-running`, `mcp.not-running`,
`mcp.no-such-run`, `mcp.no-such-unit`, ... (`src/mcp.cho`, the rule strings).
`cancho_status` returns `alive`, `state` (`running|finished|not_running`),
`stage`, `verdict`, `units_verified/total`, `units_stuck`, `units_building`,
`cost_usd`, `log_tail` (`docs/mcp.md:54`).

Of the three drawbacks for Forge, the first is decisive: (a) it is a
**session** (initialize handshake, then calls), and Forge's `std.process`
machinery measured in M0 is a one-shot write-then-read (`capture`); an
interleaved request/response conversation over a pipe was **not spiked**;
(b) all its process control is four constant `sh` scripts plus `ps`, so
Forge's `Exec` bound would need `/bin/sh`, `ps`, `awk`, `kill`, which is the
opposite of narrow; (c) the operator's choices (root, provider, model, key
file, `--max-runs`) are fixed at server start, so per-task limits cannot
travel. Its good parts are things to copy in spirit: names validated against
a closed charset before anything is touched, a pid-plus-command-line liveness
check against pid reuse, a cap on runs alive, bounded and marked-truncated
text out, the key path filtered from every result.

**Recommendation recorded for M2:** the adapter drives `cancho-build`
directly (Forge starts it detached, owns the lock, kills the group, reads the
directory). `cancho-mcp` is the second choice, worth a spike of its own before
anyone relies on it.

## 6. Authority, honestly

* `cancho-build` reaches `exec("")`, `fs_read("")`, `fs_write("")`, `clock`,
  `args`, `io_write`, pipes, `poll`, `child_signal`, `heap`; **no network, no
  signals, no foreign code** (**run**, `cancho authority`; matches
  `docs/authority-build.json`). The model's reach is the agent's: the agent
  has `net_out("")` (`docs/authority-agent.json`) and the key file.
* The agent command is "the operator's text and is run by `build` through a
  shell; it is trusted" (`docs/mcp.md:82`). In Forge terms: **Forge must build
  that command line itself, from configuration, never from a task.**
* Under `fix`/`project` the model edits files in the work directory; nothing
  bounds where the checker or the acceptance command (which run `cancho test`
  and a linker through `/bin/sh`) can write beyond what the OS gives that user.
  This is G2 in full. An OS-level sandbox is outside M1-M5.

## 7. Mapping onto `forge-worker/1`

| `forge-worker/1` | Cancho Code | Fit |
|---|---|---|
| process per call, stdin JSON, stdout JSON | argv + files + tab lines + exit code | **no**: an adapter must translate in both directions |
| `capabilities` | nothing. No `--version`, no capability query. | **none**: a static table in Forge keyed by the pinned revision; `cancho authority` of the binary is the review artefact |
| `execute` (`sync`) | runs for minutes; resumable | **`async` only**: Forge starts detached, returns `accepted` |
| `request_id` idempotency | the run directory (same command resumes); a repeated start on a live directory is **not** guarded by the tool | **partial**: Forge derives the directory from `request_id` and holds the lock |
| `task.type` `repo.change` | `project.build` (brief to new project); `fix` for one file | **no**: the type list changes |
| `task.input.goal` | the brief file text (`brief.txt`) | **yes**, written by Forge into the execution directory |
| `task.input.repo` | none: no existing repository is read | **no** |
| `task.acceptance` (informational) | the plan's per-unit examples, authored by the model; `--contract <file>` pins exact public signatures | **partly**: criteria can only be written into the brief or the contract file; they are not machine-checked against Forge's list |
| `limits.timeout_ms` | `--plan-seconds`, `--agent-seconds`, `--attempts`, `--rounds` are per call and per unit; no total | **no**: Forge's own deadline is the only whole-run bound |
| `limits.max_output_bytes` | standard output is small, but the *files* are unbounded | Forge bounds the stream; file sizes are checked when referenced |
| `limits.budget` (money) | none | **no**: Forge reserves budget itself from `--attempts`/`--rounds` worst-case token estimates (M4), and reads `usage.jsonl` |
| `grants.workspace` | none (always a fresh work directory) | **no** |
| `grants.execution_dir` | the `<workdir>` argument | **yes**, with the charset rule of 2.1 |
| response `state: succeeded` | `[BUILD_VERDICT] done`, exit 0, `build.json.verdict == "done"` | **yes, as a claim** (the verifier is the compiler and the unit's own examples, which is real evidence but is Cancho Code's, not Forge's) |
| `state: failed` | `stuck`, `gate_failed`, `plan_failed`, `provider_error` | **yes**, with the verdict word as `error.code`; `provider_error` is the retryable one ("wait and rerun", `docs/project.md:84`) |
| `state: partial` | `stuck` / `gate_failed` with `units_verified > 0`: `project.cho` holds the verified units | **yes**: this is exactly the case |
| `state: cancelled` | none | **none**: killed means `not_running`; Forge's `execution.cancelled` is Forge's fact |
| `summary` | none; `run.log` tail | text from the run is untrusted |
| `evidence[]` (`ref`, `sha256`, `bytes`) | files in the run directory; **no hash anywhere** (`grep -i sha256 src/*.cho` finds nothing) | **yes**, synthesised by the adapter and hashed by Forge: `project.cho` (kind `file`), `trail-<id>.jsonl`, `journal/events.jsonl` (`log`), `journal/blobs/<unit>-aN-acceptance.txt` (`test_output`), `run.log` (`log`) |
| `cost` | `usage.jsonl` tokens | **derived**, `source: "derived-from-tokens"` |
| `error.retryable` | by verdict | `provider_error` true; `stuck` false unless `--retry`; others false |
| `status` | `build.json` (`stage`, `units_*`, `verdict`) | **yes**, no timestamp |
| `result` | files plus `build.json.verdict == done` | **yes** |
| `cancel` | none; group kill by Forge | see section 4 |
| section 5 row 5 "non-zero exit is `worker-error`" | exit 1, 3, 4 are outcomes | **wrong for this worker** |

## 8. What was run

| What | Result |
|---|---|
| `CANCHO=... sh scripts/test-build.sh` in the checkout | `build gate: ok`, 35.9 s wall. Covers the happy path, plan reuse, invalid plan, unreachable agent, SIGKILL then resume, stuck, `--retry`, `--patch`, usage errors, `build.json` fields (`scripts/test-build.sh:1-33`). Uses a stand-in agent: no model, no key. |
| `CANCHO=... sh scripts/test-mcp.sh` | `test-mcp: every case held`, 31 s wall. |
| `cancho authority` on the `build` program set | `exec("")`, `fs_read("")`, `fs_write("")`, no network / signals / foreign code. |
| A stand-in happy run, directly | exit 0, listing and `build.json` above. |
| `env -i` run | exit 0, `[BUILD_VERDICT] done`. |
| SIGTERM during a unit | exit 143, no verdict, `build.json` stage `build`, agent child survived. |
| Same command again | `plan reused`, exit 0, two `run_start` events. |
| No arguments / relative checker | exit 2 with the text in section 3.1. |

Both gates ran with the Forge-pinned compiler, not Cancho Code's own. Both
tests use a **stand-in agent** (`tests/buildcmd/agent.sh`), so nothing here
says anything about a model's behaviour, latency, token use or cost; a
real-model claim needs a real build and is not made.

## 9. Reuse and licence matrix

*(This is the roadmap's owed "component reuse/migration matrix" and licence
review, **for Cancho Code and cancho only**. It is a reading of the licence
text, not legal advice. `lex-loom` was not reviewed: no copy was available.)*

Facts, **(source)**: Cancho Code's `LICENSE` is the EUPL v1.2 text
(`LICENSE:19-285`), its `NOTICE` says "licensed under the European Union
Public Licence v. 1.2 (EUPL-1.2)", copyright "(c) 2026 Alpibru S.L.", and the
README's last line is "EUPL-1.2" (`README.md:71`). cancho's `LICENSE` and
`NOTICE` say the same, "Version 1.2 only" in cancho's header. Forge's own
`LICENSE`/`NOTICE` are EUPL-1.2 with the same holder. One gap found: the
`NOTICE` in Cancho Code points to a `THIRD_PARTY.md` for third-party material
**and the checkout has none**; I did not find any third-party code to list
(`vendor/fetch_io.cho` says it is the I/O of cancho's `packages/http-client`,
that is cancho's own).

What EUPL-1.2 requires (`LICENSE:103-141`): keep all copyright and licence
notices; mark modified files with the fact and date of modification; any
distribution *or communication* of copies is under the EUPL (or a compatible
licence from the appendix: GPL v2/v3, AGPL v3, LGPL, MPL v2, EPL v1.0, OSL,
CeCILL, EUPL 1.1/1.2, LiLiQ-R); provide the source or say where it is. No
trademark licence.

| Component | Reuse in Forge | Condition / reason |
|---|---|---|
| `cancho-build` / `cancho-mcp` **as programs Forge runs** | **Yes**, the plan | Running the tool is not copying it. A Forge distribution that *ships* the binary carries the EUPL text, its notices, and a source pointer. Pin by commit; record the commit in `THIRD_PARTY.md` when it is shipped. |
| `docs/build.md`, `journal.md`, run-directory layout, `usage.jsonl` shape | **Read as an interface**; do not copy prose | Reading files in a documented layout needs no licence beyond the right to run the program. If Forge quotes text, keep the notice. The layout is **not versioned** (`build.json` has no `schema` key, the board's `board.json` does: `docs/dashboard.md:52`): Forge must validate every field, tolerate absences, and fail closed. |
| `src/plan.cho` (plan check), `src/splice.cho`, `src/acceptance.cho`, `src/checker.cho` | **Possible, not planned** | Same holder, same licence, so copying is allowed with notices intact and a modification mark. Reasons against: written for `edition 7` and for the revision `2e72479`, Forge pins `2aa83b2` at `edition 9`; they take `Exec("")`, the opposite of Forge's narrow bound; `acceptance.run` is `/bin/sh -c`. Forge writes its own against `std.process`. |
| `src/trail.cho` journal writer | **No** | Different design (section 3.3). |
| `src/mcp.cho` patterns (name validation, pid liveness, caps, truncation, key filter) | **Ideas yes, code no** | Re-derive in Forge with tests; the shell scripts are the opposite of the authority model. |
| `eval/prices.json` | **No; keep Forge's own** | A dated snapshot of a provider's published prices; Forge records its own table with its own date and source. |
| Prompts and guides (`docs/plan-guide.md`, `docs/review-guide.md`, `guidelines.md` from `cancho agent-guidelines`) | **Reference them as inputs to the worker**, not as Forge text | They are the worker's operator configuration. |
| The Anthropic / Ollama APIs, the model output | **Out of scope here** | Provider terms and any limits on using output are not code licences and were not reviewed. Forge never embeds a key. |
| System tools used by the worker | `cancho` (EUPL-1.2), `cc`/`clang` (linker), `/bin/sh`; `ps`, `awk`, `kill` for the MCP server; `python3` only for the MCP gate's test client (`scripts/test-mcp.sh`), not the product | None vendored. Forge has no dependency on any of them except the compiler. |

**Consequence for Forge's own licence:** none. Forge is EUPL-1.2 by the same
holder and executes Cancho Code as a separate program; no relicensing question
arises. If Forge ever copies Cancho Code source, `THIRD_PARTY.md` gets a row
(file, upstream commit, licence) in the same commit, and `NOTICE` is left
intact.

**Not done:** `lex-loom` audit and reuse matrix row, `lex-code`, and a
dependency review of anything else the design document names. They stay owed
in the roadmap.

## 10. What changed in this repository because of this audit

* `docs/worker-contract.md`: corrected in place (see the table at its top and the
  paragraphs marked **(corrected)**): the transport is now two bindings (the stdio JSON form
  stays for workers that implement it; **the Cancho Code binding is a
  process-and-directory binding**); exit-code semantics are per binding; the
  Cancho Code adapter is `async`; `cost.source` gains `derived-from-tokens`;
  task types are `project.build`, `file.fix`; `repo.change` is not claimed for
  Cancho Code; credentials are file grants; section 5 is rewritten for the
  binding; section 8's last row is closed.
* `docs/architecture.md`: section 5.3's "credentials on stdin" corrected;
  the rule table gains the M1 rules; the state-machine section gains the real
  edge table.
* `docs/roadmap.md`: the audit row is closed, the licence row is split
  (Cancho Code and cancho done, `lex-loom` open).
