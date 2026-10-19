# Milestone 0 spike: results

Everything below was **run**, with real cancho programs and the compiler
named here. Nothing in this file is from reading documentation unless it
says so.

| | |
|---|---|
| Compiler | `cancho 0.0.0 (rev 8411e9ade1805eedec64b8a217610efb0cd0cd4c, host x86_64-unknown-linux-gnu)`, `/home/user/cancho-bin/cancho`. The M0 spikes were first run on rev `2aa83b2`; the pin was bumped after M1's first commits (cancho #533 and #536) and every spike re-run: nothing the bump changed altered a result except S7, rewritten below |
| Machine | Linux 6.18, x86_64, a cloud sandbox container (so: no init reaping orphans -- see S7) |
| Backend | the compiler's default (LLVM via `clang`/`cc`); not cross-checked on Cranelift |
| Not covered | macOS; a real Cancho Code; concurrency of several workers; large journals; anything over a network |
| Reproduce | `CANCHO=/path/to/cancho spike/run.sh` (regenerates the transcript in the appendix) and `CANCHO=... scripts/gate.sh` |
| Files | `spike/s1_capture.cho` ... `s7_grandchild.cho`, `spike/mock_worker.cho`, `spike/run.sh` |

Every `.cho` file in the repository passes `cancho fmt --check` and
`cancho check <file> --std` (the gate prints `gate: PASS`); `cancho test`
runs the 6 tests of `tests/event_test.cho` and they pass. (Corrected after
M1: `cancho test` now runs 82 tests in five sets; the gate also runs two file
conformance programs (62 cases), a kill-at-every-crash-point program (25 crash
points, 420 checks), 13 CLI cases and the authority-report check; see "M1
findings".)

## Summary

| Capability asked | Result | Spike |
|---|---|---|
| Spawn a child | **PASS** | S1 |
| Capture its stdout | **PASS** | S1, S2, S6 |
| Write its stdin while reading its stdout | **PASS** (via `capture`; exercised with a JSON request in S6; the 1 MiB no-deadlock claim of `docs/processes.md` 7.1 was not re-run) | S6 |
| Enforce a timeout | **PASS**: 300 ms deadline ended in 301 ms; 500 ms in 501 ms; child killed and reaped | S2, S6 |
| Enforce an output bound | **PASS**: exactly 1000 bytes kept, child killed | S2 |
| Report exit status / signal | **PASS** | S2, S6 |
| Kill a child explicitly | **PASS**, with a trap for the unwary (section S2) | S2 |
| Kill what the child started (a grandchild) | **PASS by default for a detached worker** (`exec_spawn_detached`: `capture` kills the group at the deadline, or `child_kill_group` by hand), with `Exec` narrowed to `/bin/sh` and no `/bin/kill`; a plain `exec_spawn` worker still leaks its grandchild (the control). *Corrected after #533: M0 recorded FAIL here, PASS only with `/bin/kill` in an `Exec("/bin")` bound.* | S7 |
| Pass a narrowed `Exec` | **PASS**: allowed spawns run; outside spawn and `..` path **trap** (SIGILL, exit 132) -- a refusal-as-value does not exist | S3 |
| `cancho authority` reports it | **PASS**: `exec("/bin/echo")`, `exec("/usr/bin")`; Forge's S6 dispatcher reports no filesystem, no network, no foreign code | S3, S6 |
| Append + sync a journal | **PASS** | S5 |
| Make a new file durable (directory sync) | **PASS** (mechanism works; effect on a real power loss not measurable here) | S5 |
| Torn-tail recovery | **PASS**: 165 -> 140 bytes, idempotent | S5 |
| Refuse to "repair" a duplicate / corrupt complete line | **PASS** after fixing a bug the spike itself had (see S5) | S5 |
| Atomic replace by rename, crash before rename leaves old file | **PASS** | S5 |
| Single-writer lock | **PASS**: second lock fails, errno 11 | S5 |
| `std.json` write a task event | **PASS** | S4 |
| `std.json` parse it back, nested fields, arrays, escapes, unknown fields | **PASS** (20 checks) | S4 |
| `std.json` refuse malformed input without trapping | **PASS** (6 inputs) | S4 |
| Full worker round trip with a mock worker | **PASS** (5 scenarios) | S6 |

Things that did **not** go as hoped, and what they block, are in
"Gaps" at the end.

---

## S1 -- spawn, capture stdout, under a narrowed `Exec`

`s1_capture.cho` narrows `Exec` to `"/bin"`, makes the two channels with
`process.channels()`, `exec_spawn`s `/bin/echo`, and calls
`process.capture` with a 5000 ms deadline and 4096-byte bound.

```
$ cancho run spike/s1_capture.cho --std
ran: code 0
stdout: hello from child
```

Worked first time. The ceremony is real: the file is 88 lines for one
`echo`, of which `main` is 25 (ten capabilities split, six released, four borrowed). The
call shape follows `tests/programs/process_capture.cho` in the cancho
repository.

## S2 -- deadline, output bound, exit status, explicit kill

`s2_timeout_kill.cho` runs five cases and prints how each ended and how long
it took.

```
$ cancho run spike/s2_timeout_kill.cho --std
deadline 300ms vs sleep 30: timed out, kept 0 bytes, 301 ms
bound 1000 vs yes: too much, kept 1000 bytes, 2 ms
nonzero exit: code 3, kept 0 bytes, 2 ms
stderr not captured: code 0, kept 4 bytes, 2 ms
explicit kill: child_kill rc=0, signaled 8, 1 ms
```

* A `sleep 30` was ended by the deadline after 301 ms (305 ms in an
  earlier run), reaped, and reported as `TimedOut` -- not as a signal.
* `yes` is stopped at exactly the bound (1000 bytes) and reported `TooMuch`.
* Exit code 3 and the signal are separate outcomes (`Code(3)`, `Signaled`).
* `capture` reads stdout only: the `echo err 1>&2` case kept 4 bytes
  (`out\n`). Stderr needs `capture_both` (`std/process.cho`), which this
  spike did not exercise.
* **A trap found on the way.** The first version of this spike called
  `child_kill(ch, 15)`. It answered `22` (`EINVAL`) and the following
  `child_wait` then **blocked for the child's full 30 s** (`30002 ms`),
  because the kill had not happened. `child_kill` takes `std.signals`' bit
  values (`sg.sigterm()`, which is 8, and `256` for KILL), not POSIX
  numbers (`docs/processes.md` 4.7). The committed program uses
  `sg.sigterm()`; the 22/30 s output is from the superseded first run and
  is not reproducible from the committed file. For Forge: never call
  `child_wait` after a `child_kill` whose result you did not check, and
  prefer `capture` (which kills on its own deadline).

## S3 -- a narrowed `Exec` is a bound, and breaking it traps

`s3_narrow.cho` narrows `Exec` to two unrelated things at once with the
tuple form of `narrow`: one program (`/bin/echo`) and one directory
(`/usr/bin`). `argv[1]` picks the spawn to attempt.

```
$ cancho authority spike/s3_narrow.cho --std
performs
    args
    exec("/bin/echo")
    exec("/usr/bin")
    io_write
never touches
    the filesystem
    the network
    the heap
    signals
    foreign code
...
mode a  /bin/echo        via Exec("/bin/echo")  -> exited code 0
mode b  /bin/cat         via Exec("/bin/echo")  -> Illegal instruction, exit=132
mode c  /usr/bin/true    via Exec("/usr/bin")   -> exited code 0
mode d  /usr/bin/../../bin/cat via Exec("/usr/bin") -> Illegal instruction, exit=132
mode e  /bin/cat         via Exec("/usr/bin")   -> Illegal instruction, exit=132
```

(Verbatim output is in the appendix.) A narrowed `Exec` does bound which
programs start, down to a single file, and the report states it. **But a
violation is a trap -- SIGILL, the whole process dies -- not an error value
Forge can turn into a journalled refusal.** That is by design in cancho
(`docs/processes.md` 4.1) and it shapes Forge's authority model: policy
must refuse first; the capability is the backstop (ADR section 5.2).

Also seen here: the bound is a **compile-time literal**. A program cannot be
told the workers directory at run time without holding `Exec("")` and
checking paths itself (gap G1). The same holds for `Fs` in S5.

## S4 -- `std.json`: a task event

`s4_json_event.cho` writes a `task.dispatched` event with a nested task,
nested limits object, a criteria array and a note needing escapes
(`café "quoted"\n`), parses it, and runs 20 checks.

```
$ cancho run spike/s4_json_event.cho --std
event: {"v":1,"seq":7,"kind":"task.dispatched","task":{"id":"t-1","worker":"mock","limits":{"timeout_ms":5000,"budget_cents":120},"criteria":["tests pass","no new deps"]},"note":"café \"quoted\"\n"}
parses: ok
...                                   (19 more lines, all "ok")
serialised event has no raw newline: ok
```

All 20 pass (appendix has every line). In particular: field lookup through
three levels; array indexing; the escaped note decodes to 15 bytes
(3 + the 2-byte `é` + 10); a missing key is node `-1` and reads as `0`;
unknown nested fields are skipped; truncated, empty, trailing-garbage,
bare-word, unquoted-key and single-quoted inputs each answer a negative
result (no trap); a 20-digit integer is reported by `fits_int` as not
fitting; and the writer's output contains no raw newline, so one record
per line is a sound framing. Not tested: duplicate keys, deep nesting, very
large documents, floats (Forge's records do not need them).

Note the idiom cost: parsing is a tape you size and free, and every reader
needs a `Heap`. The 6 unit tests in `tests/event_test.cho` (via
`cancho test`, using `src/event.cho`) cover the same ground for the actual
product record.

## S5 -- journal: append, sync, torn tail, recovery, snapshot, lock

`s5_journal.cho` runs against `/tmp/cancho-forge-spike`, a compile-time
`Fs` prefix; `run.sh` creates it. Records are JSON lines
(`{"seq":N,"kind":K,"task":"t-1"}`). Each step is a separate process
invocation, so "crash" means the process ended, not that the kernel lost
its page cache. This does **not** test power loss.

```
append      wrote bytes: 46, 46, 48 / file_sync: ok 0 / sync dir: ok 0
tear        torn write: ok 25   (half a record, no newline, no sync)
recover     recovered records=3 valid_bytes=140 file_bytes=165 corrupt_complete_lines=0
            truncate torn tail: ok 0 / file_sync: ok 0         -> file is now 140 bytes
recover     recovered records=3 valid_bytes=140 file_bytes=140 ...   (second run: nothing to do)
append2     (seq 4-6) then recover: records=6 valid_bytes=280 file_bytes=280
append      (seq 1-3 AGAIN) then recover:
            recovered records=6 valid_bytes=280 file_bytes=420 corrupt_complete_lines=3
            REFUSED: complete line(s) that are not the next event; file left untouched
            bytes before/after: 420/420
snapshot-torn  snapshot.json still: {"last_seq":0}   (crash before rename; snapshot.json.tmp left behind)
snapshot       write tmp, sync tmp, rename: ok 0, sync dir: ok 0
               snapshot.json now: {"last_seq":3,"tasks":{"t-1":"running"}}   (tmp gone)
lock           lock by first writer: ok 0
               lock by second writer (must fail): FAILED errno 11
```

What this shows:

* One `file_write` per record on an `open_append` handle writes the whole
  record (46/46/48 bytes); `file_sync` and a **directory** sync (`open_read`
  on the directory, then `file_sync`) both succeed. The effect of those
  syncs on durability across a real power loss is not measurable here.
* A torn tail is recognised (bytes after the last newline), cut with
  `file_truncate`, and synced; recovery is idempotent.
* **A bug the spike had and fixed, which is now a design rule.** The first
  recovery treated "anything that is not a valid next record" as a torn
  tail and truncated to the last good byte. When the spike appended
  seq 1-3 a second time, that truncated three complete lines (they were
  valid JSON with the wrong `seq`). Recovery must cut **only** bytes after
  the last newline and must **refuse, changing nothing**, on a complete bad
  line. This is ADR section 4.3. Found by running the driver, not by
  reading.
* The temp-file / sync / rename / sync-directory sequence works; a crash
  before the rename leaves the old snapshot byte-for-byte intact and a
  stray `.tmp` the next start must remove (not yet implemented).
* `file_lock` works as a lock between two open file descriptions of one
  process, which is how it conflicts between two processes (flock
  semantics); a second Forge process on the same workspace is refused.
  Not tested across two real processes, nor after `kill -9` of the holder
  (documented to release the lock).
* Not measured: the sync cost (the cancho document measured 193 us per
  `fdatasync` on its machine), behaviour on a full disk, `EXDEV` on rename,
  large journals, a journal across segments.

## S6 -- a worker round trip, end to end

`mock_worker.cho` is a cancho program: reads one JSON request from stdin,
writes one JSON response to stdout, with a failure mode picked by its
argument. `s6_dispatch.cho` is the Forge side: `Exec` narrowed to one
directory, JSON request via `std.json`, `process.capture` with the request as
input, then a classifier that maps every ending to one named outcome.

```
$ cancho build spike/mock_worker.cho --std -o /tmp/cancho-forge-spike/bin/mock_worker
$ cancho run spike/s6_dispatch.cho --std
normal      : worker_claims_succeeded -> verification (not accepted) [2 ms]
reports fail: worker_reports_failed [3 ms]
garbage     : protocol_error: stdout is not a JSON object [2 ms]
exit 3      : worker_error exit 3 [1 ms]
hang (500ms): worker_timeout (child killed and reaped) [501 ms]
```

`cancho authority` on the two programs:

* the **mock worker** performs `args`, `heap`, `io_read`, `io_write`; it
  "never touches the filesystem, the network, signals, other programs,
  foreign code";
* the **dispatcher** performs `child_signal`, `clock`,
  `exec("/tmp/cancho-forge-spike/bin")`, `heap`, `io_write`, `pipe_read`,
  `pipe_write`, `poll`; it "never touches the filesystem, the network, the
  command line, signals, foreign code".

So the claim that matters for Forge's authority model holds *in the
report*: the supervisor cannot read or write a file, and the worker cannot
spawn. The contract's response envelope is not fully implemented by the
mock (see `docs/worker-contract.md` section 8).

## S7 -- what a kill reaches

A worker that starts subprocesses (compilers, test runners) is the normal
case for an engineering worker. `s7_grandchild.cho` starts
`/bin/sh -c 'sleep 77 & wait'`, times it out at 300 ms, and lets an outside
`ps` (matched on the arguments `sleep 77`) look at the grandchild.

**M0 result, rev `2aa83b2` (kept, because the gap table cites it):** a plain
`capture` kill reached the worker's pid only (the `sleep` stayed `S`), and the
only way to reach the group was `exec_spawn_detached` plus
`/bin/kill -KILL -- -<pid>` through an `Exec("/bin")` bound, which put
`exec("/bin")` in the authority report. That was gap G3, filed upstream as
cancho #533.

**After #533, rev `8411e9a`.** `child_kill_group(&Child, signal)` (edition 9,
cancho `docs/processes.md` 4.12) signals the group a detached child leads, and
`std.process.capture` sends the group KILL before the pid's on every path on
which it kills (deadline, output bound, failed watch). The spike was rewritten:
`Exec` is narrowed to `/bin/sh` alone, `/bin/kill` is gone, and three modes run
(`p` plain `exec_spawn`, the control; `g` `exec_spawn_detached` and let
`capture` kill; `k` `exec_spawn_detached`, no `capture`, the program calls
`child_kill_group` and `child_wait` itself). Verbatim, from `spike/run.sh`:

```
=== S7 what a kill reaches (grandchild 'sleep 77'); no /bin/kill, no exec("/bin")
performs
    args
    child_signal
    clock
    exec("/bin/sh")
    exec_detached
    heap
    io_write
    pipe_read
    pipe_write
    poll
never touches
--- mode p
worker timed out; killed and reaped
'sleep 77' processes (pid pgid state; S = alive, Z = killed, not yet reaped by init):
  17483 12215 S sleep 77
--- mode g
worker timed out; killed and reaped
'sleep 77' processes (pid pgid state; S = alive, Z = killed, not yet reaped by init):
--- mode k
worker ended by signal 256
child_kill_group rc=0
'sleep 77' processes (pid pgid state; S = alive, Z = killed, not yet reaped by init):
```

**PASS by default.** The authority report names `exec("/bin/sh")` and
`exec_detached`; it has no `exec("/bin")` and no `/bin/kill`. Mode `p` is the
control: the grandchild is alive (`S`) and sits in the parent's process group
(pgid 12215), so the other two modes cannot have passed for any reason. In
mode `g` and `k` the grandchild is gone (not even a zombie: on this run the
container reaped it; the M0 run showed `Z`, "dead, not yet reaped"). `child_kill_group`
answers `0`; `child_wait` then reports `Signaled(256)`, the KILL bit.

What the measurement does not show, and the cancho document says:

* Only a descendant that stayed in the group is reached; one that calls
  `setsid`/`setpgid` is not (cancho `docs/processes.md` section 9). Not
  measured here (our grandchild is `sleep`).
* A worker that exits by itself and leaves a subprocess behind is not killed
  by `capture` (the exit ends the capture). The dispatcher must call
  `child_kill_group` itself before `child_wait` if it wants that; not
  measured here.
* `Exec("/bin/sh")` bounds what *Forge* may start, not what the worker then
  starts: the grandchild `sleep` is outside the bound, as in M0 (gap G2).
* After a Forge crash there is no `Child` to hold (gap G4, still open).
* Mode `k` waits 300 ms by spinning on the clock for the worker to have started
  its `sleep`; it is a spike, a real dispatcher polls (S2).

---

## M1 findings -- what building the core measured

Not spikes: these were found writing `src/task.cho`, `src/journal.cho`,
`src/journal_io.cho` and their tests, with the same compiler (rev `2aa83b2`).

**A library cannot be generic in the `Fs` prefix (G9).** A scratch program
(not kept in `spike/`, because the gate requires every `spike/*.cho` to check
clean and this one is refused by design):

```cancho
fn size_of[&f, &p](fs: &f Fs(""), path: &p [byte]) -> [fs_read("")] int { ... }
...
let data = narrow(fs, "/tmp/cancho-forge-conf");
borrow data as &d in { n = size_of(d, "/tmp/cancho-forge-conf/x"); }
```

```
$ cancho check fs2.cho --std
fs2.cho:16:21: error: expected `""`, found `"/tmp/cancho-forge-conf"`
```

So a function that declares `Fs("")` takes only the whole filesystem, and one
that declares `Fs("/x")` fixes `/x` in the library. `src/journal_io.cho` takes
`Fs("")` and refuses a bad path itself (`path-invalid`); see architecture
section 9, G9.

**`cancho test` hands a test only a `Heap` and an `Io`** (`docs/testing.md`
section 3, confirmed by the runner: "releases `ffi`/`fs`/`args`"). So file
behaviour is in `tests/conformance/journal_files.cho`, a program the gate
builds and runs on a scratch directory; the pure logic is tested through
`cancho test`.

**Counts, at the commit that added them.** `cancho test`: 9 (event, three added
for `transition`, `refusal` and an escaped hostile id) + 22 (task) + 25
(journal) = 56 tests, all pass. Conformance: 24 cases against real
files, all pass. Seven hand-made mutations of the source (an extra edge, the
acceptance check removed, the worker check removed, recovery cutting despite
a refusal, the `seq` check removed, duplicates allowed, the torn-tail finder
starting from zero) each turned at least one suite red; a conformance mutation
(a cut to the full length instead of to the last whole record) failed 3 cases.
That is evidence the tests can fail, not proof they cover everything.

**Edge cases that do not trap, measured by tests.** A `seq` of
99999999999999999999999 (`json.to_int` saturates; it is simply not the next
seq), 3,000 nested `[` on one line, a line of NUL bytes, a run of bare
newlines, a seq of `1.0` or `"1"`, and a line with trailing text each answer
`journal-corrupt` as a value. (S4 listed deep nesting as untested; it now is,
at that one depth.)

**Row exactness caught a mutation for free.** Removing the only call that
used `file_write` from `recover` was refused at build time ("declared but not
performed"), so a mutation of that kind has to keep the row honest.

**Names.** `join` is a builtin and cannot be redefined (`under` is used
instead).

### M1, second part: snapshots, the lock, kills, the CLI

Counts at the commit that added them: `cancho test` 82 (9 event, 22 task, 25
journal, 18 snapshot, 8 report); conformance 62 cases (24 journal, 38 snapshot
and lock); 25 crash points, 420 checks, 0 failed, 0.9 s; 13 CLI cases. What
building them found:

* **Stdout is a stdio buffer, and a child's markers do not reach its parent
  until it exits.** The first kill-at-a-point harness hung for the 15 s
  deadline at every point and printed nothing; `strace -f` showed the child
  writing all its lines in one `write(1, ..., 1133)` at exit. `flush_out`
  (edition 5, cancho `docs/checked-output.md`, a builtin) after each marker
  fixed it. Anything that uses a child's stdout as a progress channel needs it.
* **A test found a real bug in `snapshot_io.save`**: with a good tmp path and a
  `..` final path it opened and wrote the tmp, then refused at the rename,
  leaving a stray file. Both paths are now checked first; the case that found
  it (`save: a .. path on either side is refused (-2) before anything is
  opened`) stays.
* **`sync` on a second handle is not the same promise.** The first plan was to
  split `append` into write, sync and dir-sync steps that each open the file
  (so the crash test could pause between them). Dropped: on Linux a writeback
  error is reported to descriptors opened before it, so an `fsync` on a handle
  opened after the write may miss it. The steps take the one open handle
  instead (`write_all`, `sync_file`).
* **Row exactness again.** A mutant that makes `sync_file` a no-op does not
  build ("declared but not performed"), and a process kill could not see it
  anyway (the page cache survives). The mutants that did run, and what killed
  them, are in `docs/architecture.md` section 4.8.
* **`narrow` takes a literal (G1, cancho #534), and it showed up in the test
  harness**: the parent can only start a child from a literal directory, so
  the gate builds `crash_writer` into `/tmp/forge-crash-bin`.
* **Process kill is not power loss.** Stated in the architecture and in the
  README: the 25 points prove ordering and atomicity against a crash of the
  process; nothing here shows an `fsync` reached the platter.
* **The `forge` binary's authority widened**, from `heap`/`io_write` to
  `fs_read("")` and `file_read` (no write, no exec, no network); checked in as
  `docs/authority.txt` and compared by the gate.

## Gaps

What did not work or is not built, and what each blocks. "Needed from
cancho" is a proposed feature. **Corrected after M0**: the tracker was
searched and the gaps filed or found. G1 and G9 are [cancho #534](https://github.com/alpibrusl/cancho/issues/534)
(still open; **corrected 2026-10-19**: cancho #546 answers part of it, below), G2 was [#535](https://github.com/alpibrusl/cancho/issues/535) (**closed: `exec_covers`/`fs_covers`, cancho #540**), G3 was
[#533](https://github.com/alpibrusl/cancho/issues/533) and is **built and merged**
(`child_kill_group`, S7), G4 stays open and is a row of `docs/processes.md`
section 9 (no issue), G6 was [#536](https://github.com/alpibrusl/cancho/issues/536)
and is **fixed** (closed; the header on cancho main says slices 0 to 6 are built,
checked by reading `docs/processes.md` at rev `8411e9a`).

| # | Gap | Blocks | Needed from cancho |
|---|---|---|---|
| G1 | **Open: cancho #534, partly answered 2026-10-19 (cancho #546, merged).** `narrow` still accepts only literals. A run-time bound is now a `Dir` (for `Fs`, edition 6) and, for `Exec`, `exec_spawn_under(&Exec(""), &Dir, name, ...)` (edition 9; its row is `exec_under`, which names no path). Forge has **not** used either yet | Per-task, run-time scoped grants (design doc 6.4); a workers/workspace directory from configuration | A way to narrow to a deployment-time value. Existing open row: `docs/processes.md` section 9, "A bound chosen at deployment" (it says `Fs` has the same question) |
| G2 | ~~Open: cancho #535. A bound violation is a trap (SIGILL), not a value~~ **Answered 2026-10-19: cancho #540 (merged, closed #535)**: `exec_covers(&Exec, path)` and `fs_covers(&Fs, path)` (edition 9, no row) say whether a path is inside the bound by the rule the operations trap on, so Forge can ask first and journal a refusal instead of duplicating the rule. The violation still traps by design | Nothing now; **not yet adopted in Forge's policy layer** (M4) | None. Forge's own pre-check can be replaced by the predicate once the pin carries it (it does as of this pin) |
| G3 | ~~`capture`/`child_kill` reach the pid only; grandchildren survive (S7)~~ **Built: cancho #533 (merged), `child_kill_group`; S7 re-run, PASS with no `/bin/kill`** | Nothing now; M2 starts workers with `exec_spawn_detached` | None. Residual, from cancho's own document: a descendant that leaves the group is not reached; the orphan after a Forge crash is G4 |
| G4 | **Open, no issue: a row of `docs/processes.md` section 9** (cancho #533 narrowed it: a supervisor that is alive can stop a worker's group with the `Child` it holds; after a supervisor *crash* nothing changes). No kill-by-pid capability; children outlive a dead parent (documented, not measured) | Safely stopping an orphaned worker after a Forge crash (M2) | `docs/processes.md` section 9 rows: kill-by-pid with its own capability; `PR_SET_PDEATHSIG` (Linux only) |
| G5 | `fsync` on macOS does not flush the drive cache (documented); only Linux was run | The durability promise on macOS (M1) | `F_FULLFSYNC` (`docs/file-writes.md` section 6) |
| G6 | **Fixed: cancho #536 (closed, in rev `8411e9a`).** `docs/processes.md`'s status header says "slices 3 and 4 designed, not built", but its own slice table, `std/process.cho` and S1/S2/S6/S7 show `std.process` working | Nothing, but it misled the brief for this spike | Correct the header in the cancho repository (a document-only fix, per `CONTRIBUTING.md`) |
| G7 | `cancho check` refuses a library with no `main`; `cancho test` is the only check for library-only files | Gate shape (we check `src/*.cho` as one program and rely on `cancho test` for tests) | None required; noted |
| G8 | No `cancho` command walks a directory tree from a program without `std.dirs`/`Fs`; the 2,000-line rule is enforced by a shell loop in `scripts/gate.sh`, not in cancho | "Pure cancho" gate (M1 plans a cancho test using `std.dirs`) | None required |
| G9 | **Open: cancho #534** (same issue as G1). A function over `Fs` cannot be generic in the prefix (M1 findings above). cancho #546 documents `Dir` as the answer when the bound is a directory; **not tried against Forge's journal** | The journal's file layer cannot be narrowed to the workspace; it holds `Fs("")` and guards paths itself | Same as G1, for `Fs`; or a prefix-generic capability parameter |

Not spiked, and therefore not claimed: SHA-256 evidence hashing; stderr
capture (`capture_both`); `exec_spawn_in` (working directory); `Signals`
for a clean stop; the `async` worker level and the `cancel` / `status` /
`result` verbs; `std.http`; macOS; several concurrent workers; the real
Cancho Code and `lex-loom`.

---

## Appendix: full transcript of `spike/run.sh`

Run with `CANCHO=/home/user/cancho-bin/cancho spike/run.sh` (rev
`8411e9a`, exit 0), re-recorded after the pin bump and the S7 rewrite. The
S7 section lists only `sleep 77` processes (`ps` matched on its arguments;
an earlier listing by command name also showed unrelated `sleep`s of other
programs on the machine): `S` (alive) after mode `p`, nothing after modes
`g` and `k`.

```

=== gate: fmt, check
fmt: ok
check s1_capture: ok
check s2_timeout_kill: ok
check s3_narrow: ok
check s4_json_event: ok
check s5_journal: ok
check s6_dispatch: ok
check s7_grandchild: ok
check mock_worker: ok

=== S1 spawn + capture stdout under Exec("/bin")
ran: code 0
stdout: hello from child

=== S2 deadline, output bound, exit status, explicit kill
deadline 300ms vs sleep 30: timed out, kept 0 bytes, 302 ms
bound 1000 vs yes: too much, kept 1000 bytes, 2 ms
nonzero exit: code 3, kept 0 bytes, 2 ms
stderr not captured: code 0, kept 4 bytes, 2 ms
explicit kill: child_kill rc=0, signaled 8, 0 ms

=== S3 narrowed Exec: allowed spawns run, outside spawns trap
performs
    args
    exec("/bin/echo")
    exec("/usr/bin")
    io_write
never touches
    the filesystem
    the network
    the heap
    signals
    foreign code
evaluated at compile time
    1 operators
--- mode a: /bin/echo: exited code 0
exit=0
--- mode b: Illegal instruction
exit=132
--- mode c: /usr/bin/true: exited code 0
exit=0
--- mode d: Illegal instruction
exit=132
--- mode e: Illegal instruction
exit=132

=== S4 std.json: write, parse, refuse a task event
event: {"v":1,"seq":7,"kind":"task.dispatched","task":{"id":"t-1","worker":"mock","limits":{"timeout_ms":5000,"budget_cents":120},"criteria":["tests pass","no new deps"]},"note":"café \"quoted\"\n"}
parses: ok
seq == 7: ok
task is object: ok
task.id == t-1: ok
task.limits.timeout_ms == 5000: ok
criteria has 2: ok
criteria[1] == no new deps: ok
missing key is node -1: ok
missing key reads as 0: ok
note has an escape: ok
note decodes to 15 bytes: ok
unknown field tolerated: ok
truncated is negative: ok
empty is negative: ok
trailing garbage is negative: ok
bare word is negative: ok
unquoted key is negative: ok
single quotes negative: ok
oversized int does not fit: ok
serialised event has no raw newline: ok

=== S5 journal: append+sync, torn tail, recovery, snapshot rename, lock
wrote bytes: 46, 46, 48
file_sync: ok 0
sync dir: ok 0
journal after append:
{"seq":1,"kind":"task.proposed","task":"t-1"}
{"seq":2,"kind":"task.approved","task":"t-1"}
{"seq":3,"kind":"task.dispatched","task":"t-1"}
torn write: ok 25
tail after torn write (od -c):
0000000   ,   "   t   a   s   k   "   :   "   t   -   1   "   }  \n   {
0000020   "   s   e   q   "   :   4   ,   "   k   i   n   d   "   :   "
0000040   t   a   s   k   .   r   u   n
recovered records=3 valid_bytes=140 file_bytes=165 corrupt_complete_lines=0
truncate torn tail: ok 0
file_sync: ok 0
bytes now: 140
recovered records=3 valid_bytes=140 file_bytes=140 corrupt_complete_lines=0
wrote bytes: 46, 46, 48
file_sync: ok 0
sync dir: ok 0
recovered records=6 valid_bytes=280 file_bytes=280 corrupt_complete_lines=0
--- duplicate seq must be refused, file untouched
wrote bytes: 46, 46, 48
file_sync: ok 0
sync dir: ok 0
recovered records=6 valid_bytes=280 file_bytes=420 corrupt_complete_lines=3
REFUSED: complete line(s) that are not the next event; file left untouched
bytes before/after: 420/420
write tmp: ok 41
sync tmp: ok 0
crash before rename: snapshot.json untouched
snapshot.json still: {"last_seq":0}
bin
journal.jsonl
s3
s5
snapshot.json
snapshot.json.tmp
write tmp: ok 41
sync tmp: ok 0
rename: ok 0
sync dir: ok 0
snapshot.json now:   {"last_seq":3,"tasks":{"t-1":"running"}}
bin
journal.jsonl
s3
s5
snapshot.json
lock by first writer: ok 0
lock by second writer (must fail): FAILED errno 11

=== S6 worker round trip (mock worker over stdio)
normal      : worker_claims_succeeded -> verification (not accepted) [2 ms]
reports fail: worker_reports_failed [2 ms]
garbage     : protocol_error: stdout is not a JSON object [1 ms]
exit 3      : worker_error exit 3 [1 ms]
hang (500ms): worker_timeout (child killed and reaped) [502 ms]
performs
    args
    heap
    io_read
    io_write
never touches
performs
    child_signal
    clock
    exec("/tmp/cancho-forge-spike/bin")
    heap
    io_write
    pipe_read
    pipe_write
    poll
never touches

=== S7 what a kill reaches (grandchild 'sleep 77'); no /bin/kill, no exec("/bin")
performs
    args
    child_signal
    clock
    exec("/bin/sh")
    exec_detached
    heap
    io_write
    pipe_read
    pipe_write
    poll
never touches
--- mode p
worker timed out; killed and reaped
'sleep 77' processes (pid pgid state; S = alive, Z = killed, not yet reaped by init):
  24327 19878 S sleep 77
--- mode g
worker timed out; killed and reaped
'sleep 77' processes (pid pgid state; S = alive, Z = killed, not yet reaped by init):
--- mode k
worker ended by signal 256
child_kill_group rc=0
'sleep 77' processes (pid pgid state; S = alive, Z = killed, not yet reaped by init):
```
