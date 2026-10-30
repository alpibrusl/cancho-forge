# Isolation: what Forge runs, what confines it, and what the cancho ecosystem can add

> **Status: design, nothing built.** Every proposal below is *(designed)*. Statements about what exists were read from the sources named
> and are marked *(read)*; the few things run on this machine for this document are marked **measured** and listed in section 9. Anything
> else is *(unmeasured)*. If this document and the code disagree, the code is right and this document is corrected in place.
>
> **What was read** (commits are `origin/main` at the time of writing, except where noted):
> cancho `2bd251f7` (`docs/processes.md` whole, `docs/foreign-authority.md`, `docs/reach.md` §5, `docs/unsafe-and-global-state.md`,
> `docs/under-a-grant.md` headings); cancho-tools `154e69a` (`tools/run/run.cho`, `tools.toml`, `docs/next-tools.md` §0 and §3);
> cancho-oci `fb59bdb` (README, `docs/design.md`, the list of `src/` modules; **not** the sources of the modules); cancho-forge `2cf52ff`
> (`docs/threat-model.md`, `docs/worker-contract.md` headings and the sections on the execution directory, `docs/company.md` §§2-4, 8, 14,
> `workers/check_guard.cho`, `docs/authority-*.txt`); cancho-code `0974743` (`scripts/cancho-agent.sh`, `src/driver.cho` where it starts the
> agent, `docs/authority-{agent,build,provider}.json`). **Not read:** `src/company_*.cho` beyond what the headers above say, `cancho-oci`'s
> module sources, the Rust sources of the compiler's process builtins.

## 1. The question

`docs/threat-model.md` §5 says it in one sentence: *"Until workers run in an OS sandbox, a worker is trusted not to be malicious, only to
be possibly wrong."* This document is about the second half of that sentence: what it would take for Forge to run a company's processes
(the builder, the checks, the held-out audit, the gate runner, the analyst's tools) so that the first half can be weakened, using the
cancho ecosystem where it can and naming the outside tool where it cannot.

Non-goals: confinement against a kernel exploit, side channels, a hostile operator, or a hostile *compiler* (the compiler is pinned and
trusted, `threat-model.md` T16).

## 2. What runs today, and who can do what

*(Read.)* A company run starts these processes, all as the operator's unix user, all on one machine:

| process | started by | what it is | its own authority (read from the reports) |
|---|---|---|---|
| `forge` | the operator | the supervisor | `Exec("")` beneath a workers directory, `Fs("")`, no network, no foreign code |
| `cancho_code` worker | `forge`, `exec_spawn_under`, empty environment | the adapter around `cancho-build` | `exec_under`, `exec_detached`, `fs_*`, no network |
| `cancho-build`, then the driver | the adapter | plan, build, check loop | `exec("")`, `fs_read("")`, `fs_write("")`; the driver starts the agent with `/bin/sh` and the command text the operator gave, environment `PATH=/usr/local/bin:/usr/bin:/bin` (`src/driver.cho`, `run_core`) |
| `cancho-agent` | the driver | one text request to the model, writes the project file | `fs_read("")`, `fs_write("")`, `net_out("")`; `bounded: false`, `unbounded_by: ["net_out(\"\")"]` (`docs/authority-agent.json`); **no `exec`** |
| `cancho check` / `cancho test` | the driver | the compiler, on the model's text | the compiler's own |
| the step's check (`audit_lib.sh`) | `check_guard`, via `forge` | runs the held-out audit (`python3`, GNU `diff`, `patch`, the compiler) | whatever the script does; environment `PATH` only |

Two facts shape everything else, and the second was **measured** for this document:

1. **The model has no tools today.** `cancho-agent` has no `exec` row: it sends text and writes text. The model cannot read the audit
   directory or run a command. Every threat in §3 that needs the *model* to act is therefore *latent*: it becomes live the day a worker is a
   tool-using agent (the worker contract allows any program; `worker-contract.md` §1), or a stronger plan agent is added.
2. **Generated code runs only as tests, and a test cannot hold a capability.** `cancho test` refuses a test whose parameters are not a unique
   `Heap` or `Io` reference (`docs/testing.md` §3, as quoted by the compiler). **Measured:** a test declared `(world: World)` that calls
   `split` and an `extern fn system` is refused at once ("looks like a test but has a parameter that is not a unique `Heap` or `Io`
   reference") and a shell command written there never runs. `Io` is the console. So the model's code, while it is only being tested, can
   neither open a file, nor dial, nor start a program. (`main` of a generated project is not run by the check; the audit strips it.)

## 3. Threats

Ranked by exposure *today* (§2) and by what happens if the worker becomes tool-using (latent).

| id | threat | today | latent (tool-using worker) |
|---|---|---|---|
| T-a | the builder reads the held-out audit or the oracle (they sit inside the company directory, `diff-company/company/audit/`) | the model cannot; our own programs do not | **live**: nothing stops a process with the operator's uid |
| T-b | the builder writes outside its execution directory (the journal, the manifest, other steps) | our programs do not; Forge only *tells* the worker the boundary (`worker-contract.md`: "a worker is *told* the boundary ... narrower capability, or sandboxed") | live |
| T-c | network beyond the model host | `cancho-agent` holds `net_out("")`, **unbounded**; the host is chosen at run time and the report says so | live, and larger |
| T-d | the API key reaches code the model wrote | the key is a file (`--key-file`) read by the agent only; generated code runs only as tests (§2.2) | live: a file readable by the operator's uid is readable by anything that runs as it |
| T-e | the builder's own tests run with capabilities | **closed by the language** (§2.2, measured) | stays closed for tests; not for any other generated code that is *run* |
| T-f | resource exhaustion: memory, CPU, processes, disk | a deadline and an output cap exist (`capture`, measured S2); no memory, process or disk limit | live |
| T-g | a worker lies (claims `done`, a forged `ref`, evidence outside the directory) | **closed in kind**: acceptance is Forge running the check on an artifact it hashed (`company.md` §8); `ref`s are resolved beneath a `Dir` (T11) | closed |
| T-h | supply chain of the binaries (compiler, `cancho-build`, `python3`, `diff`, `patch`, `/bin/sh`) | the compiler is pinned by revision (T16); the rest is whatever the machine has; nothing is signed or hashed at run time | same |

## 4. What each ecosystem piece gives, and what it does not

**`Exec` (compiler, `docs/processes.md`).** *(Read.)* Bounds **which program starts**, by path prefix (`Exec("/dir")`; a path outside or
with `..` is a **trap**, `SIGILL`, measured in forge S3), and **what the parent hands over**: the environment is exactly what is passed
(§4.3; `LD_*`/`DYLD_*` trap), no descriptor crosses unless given (§4.5), signals start at their defaults (§4.6), the working directory
can be a `Dir` (§4.10), a worker can be a name beneath a run-time `Dir` that leads a process group of its own (`exec_spawn_detached_under`,
§4.15). It does **not** bound what the child then does: *"The child's own authority is the child's"* and *"containment against a hostile
program is a sandbox's job (`lex-os`)"* (§2). No resource limits, no user change, no namespaces exist as builtins (**measured by `grep`**
over `docs/` and `std/`: the only `setrlimit`/`prctl`-with-seccomp uses are Rust test code, `docs/unsafe-and-global-state.md`).

**Process groups (§4.12, #533).** A supervisor can kill a worker's whole group; a descendant that calls `setsid`/`setpgid` leaves it, and
§9 of `processes.md` says a cgroup would reach it and does not exist.

**cancho-tools `run`.** *(Read; `tools/run/run.cho`, `docs/next-tools.md` §3.1.)* Starts one program from the deployer's programs directory
with exact arguments, `PATH=<dir>` as the only environment, a deadline and a per-stream output cap. Its own summary says: *"it does not
sandbox it"*, and `reversibility: irreversible-consequential`. It is `exec_spawn_in` plus `capture_both`; **it adds nothing Forge's
adapter does not already do**, so it is not the missing piece. Also relevant: `tools.toml` forbids `ffi` to every tool with **no exception
row** (`only clock can be excused`), so a launcher that needs foreign calls cannot live in cancho-tools (§7).

**Authority reports.** A report states what a *program* reaches; for `exec` it says *a program may be started*, not what that program does
(`processes.md` §2: "the closure is a question"). They are the right artefact for reviewing a launcher (§7) and the wrong one for judging a
worker.

**`check_guard`.** *(Read; `workers/check_guard.cho`.)* About **lifecycle**: it runs a check in a session and process group of its own and
kills the group at the deadline, past the output cap, or when Forge is gone (it tries the live-lock every 100 ms). It confines nothing
the check can touch.

**cancho-oci.** *(Read: README, `docs/design.md`.)* Builds a reproducible `FROM scratch` image from **static** executables (a dynamic one is
refused, 46 refusal cases), at most 64 entries per layer, push/pull/sign/SBOM. The design lists as out of scope, with a reason: *"a container
runtime, a Dockerfile interpreter and any `RUN` step"*, and building on a base image is "stage 2". An image is an **identity** (a digest), not
a **boundary**.

**The language and foreign calls.** *(Read; `docs/foreign-authority.md`, `docs/reach.md` §5.)* A cancho program can call libc through
`extern fn` under `Ffi("libc")`; the report is then `bounded: false` with `unbounded_by` **listing every foreign symbol reachable**
(`libc:prctl`, ...). `Ffi("libc")` "is every authority at once", and the report cannot say what a symbol does (`syscall`, `dlsym`,
`execve` "do the rest"). A foreign function with no capability is refused (test `a_foreign_function_without_a_capability_is_refused`).
So the language **can in principle reach** `setrlimit`, `prctl` and `syscall`; whether it can build their arguments is §7.

## 5. The layers

Each layer says: what it closes, what it leaves open, how it is verified, its refusal tags, its effect on authority reports.

### Layer 0: one verification that applies to every layer, the hostile-worker suite *(designed)*

A directory of tiny **hostile workers**, each a program that tries one forbidden thing and writes what happened to its evidence file, run
under the configured level, plus a **preflight probe**: before the first paid step, Forge runs the probe (the same programs) under the
level the operator asked for and refuses to start if any attempt **succeeds**.

| probe | tries | passes (is refused) when |
|---|---|---|
| H1 | open and read `<company>/audit/cases.json` | the open fails |
| H2 | create a file one directory above its execution directory; and a file under `/tmp` | both fail (or `/tmp` is private) |
| H3 | connect to `1.1.1.1:443` and to `127.0.0.1:<forge port>` | both fail |
| H4 | read the key file named in the operator file | the read fails |
| H5 | allocate until 4 GiB; fork 4096 children; write 10 GiB to disk | each ends with a limit, not with the machine slowing |
| H6 | read its environment | it is exactly `PATH` |
| H7 | `setsid` and keep running after the deadline | nothing of it survives the step |
| H8 | write the journal or `company.json` | the write fails |

Rule tags *(designed)*: `isolation-probe-escaped` (with the probe id), `isolation-unavailable` (the level needs something this machine
lacks), `isolation-level-unmet` (the operator file asks for a level the launcher cannot give). They are checked **by Forge before spending**,
not by a reviewer after.

### Layer 1: what can be done today, with cancho and file permissions only *(designed)*

1. **Put the audit and oracle where the builder's user cannot read them.** Today they are in `company/audit/`, in the operator's
   directory. Move them to a directory mode `0700` owned by the operator, and run the *worker* process as a second unix user with no access
   to it. Cancho cannot change user, so the worker program is started through the operating system (`sudo -n -u forge-build <worker>` or a
   systemd unit): **one line of non-cancho glue**, named as such. Forge itself keeps the operator's user, runs the check (it is Forge that
   runs `audit_lib.sh`), and never gives the builder the path.
2. **The key** moves to a file mode `0400` owned by the *builder* user, outside the company directory. (Closes T-d for any process not running
   as that user, i.e. the other workers and the checks.)
3. **Narrow what the supervisor starts.** `cancho-build`'s driver holds `exec("")` and spawns `/bin/sh` with an operator-given command. A
   narrower driver, built on `exec_spawn_under` (`processes.md` §4.14, built), would report `exec_under` and no path. This is a change in
   cancho-code, not in the compiler. *(Unmeasured whether the agent's `/bin/sh -c <text>` can be replaced by a direct program start; the
   operator's command is a string with arguments.)*
4. **Make `net_out` visible**: `cancho-agent` stays `unbounded_by net_out("")` (the host is run-time data). Document it in the operator file
   and let L2 cut the rest.
5. **Limits**: `prlimit` and `ulimit` exist on this machine (**measured**), but cancho has no builtin; with only cancho means T-f stays the
   deadline and the output cap.

*Closes:* T-a and T-d against any process not running as the builder user; T-b partly (file modes); nothing for T-c, T-f.
*Leaves open:* the builder user's own reach (it can read what it owns, write its home, use the network, fill the disk); a second unix user is
operator setup on every machine.
*Verified by:* Layer 0 H1, H2 (outside the directory), H4, H6, H8.
*Reports:* Forge's report does not change; the adapter's loses `exec("")` if item 3 is done.

### Layer 2: a launcher that confines the worker before it runs *(designed)*

Cancho has no pre-`exec` hook (the child is a plain `fork`+`exec` inside the builtin, `processes.md` §3), so confinement must be applied
**by the launched program to itself, then it `exec`s the worker**: Forge starts `sandbox <policy> -- <worker> <args>`; the launcher sets the
restrictions on its own process (they are inherited across `exec` and cannot be undone) and replaces itself with the worker.

Two ways to build it. They differ in what they cost and what they say in the report.

**2a. A cancho launcher over libc** *(the ecosystem-native path)*. A small program, in a repository of its own (not cancho-tools; §4), that
calls `prctl(PR_SET_NO_NEW_PRIVS)`, `setrlimit`, `unshare(CLONE_NEWNET | CLONE_NEWUSER)`, the three Landlock syscalls, and `execve`.
**Kernel support on this machine is measured**: `landlock_create_ruleset(NULL, 0, VERSION)` returned ABI **8** (kernel 7.0.0-42), and
`unshare -Urn true` works unprivileged. What this would close: T-a, T-b, T-c (empty network namespace, or Landlock's TCP rules), T-f (rlimits),
T-d (the key is a path outside the allowed set). Its authority report would be `bounded: false` with `unbounded_by` listing exactly the
symbols it declares (`libc:prctl`, `libc:setrlimit`, `libc:unshare`, `libc:syscall`, `libc:execve`) and **`exec`**: a reviewer reads one
short file and a pinned report (`docs/authority-sandbox.txt`, compared by the gate like the others), which is the same review artefact Forge
already uses.
**Honest limits:** (i) `syscall` is "does anything" (`foreign-authority.md` §3): the report cannot prove the launcher *only* confines;
the file's size and a differential test must. (ii) **Unmeasured and probably the blocking gap:** Landlock and seccomp take **pointers to
structures** (`struct landlock_ruleset_attr`, `landlock_path_beneath_attr`, `struct sock_fprog`). `reach.md` says the boundary is "the
absence of a raw-pointer constructor". An `extern fn` taking `&[byte]` may be able to pass a buffer laid out by hand (getenv does with a
text), which would suffice; **whether it does is the first spike of this layer**. (iii) `execve` replaces the process, so the launcher must
not need cleanup; the `Child` Forge holds is the same pid. (iv) Linux only; Landlock needs a kernel from 5.13 (the ABI above is the machine's).
**If (ii) fails the compiler change needed** is issue-sized: an `extern fn` argument that is a pointer to a caller-built byte buffer with a
stated layout, *or* (better, and larger) a small capability family `Confine` with builtins for rlimit, no-new-privs and Landlock rules whose
labels are **bounded** (`confine_fs("<dir>")`), so a launcher would not need `Ffi` at all and its report would be exact.

**2b. An external sandbox through `Exec`** *(works today, is glue)*. `bwrap` and `unshare` exist here (`/usr/bin/bwrap`, `runc`, `podman`;
**measured**). **Measured with `bwrap`:** a worker started as `bwrap --unshare-net --unshare-pid --ro-bind /usr /usr --tmpfs /tmp --bind
<exec dir> /work ... sh -c ...` could not see the audit directory (`ls` and `cat` failed), wrote only under `/work` (`/usr` was read-only),
had only `lo` in `/proc/net/dev`, and a connect to `1.1.1.1:443` answered "Network is unreachable". Forge starts `bwrap` as the worker
(`Exec` narrowed to its directory). Costs: an external binary in the trust base (T-h), a policy written in `bwrap` flags, and
`apparmor_restrict_unprivileged_userns` is `1` on this machine yet user namespaces worked (**measured**); other machines may differ
(`isolation-unavailable`).

*Recommendation:* ship **2b first** (it exists and is measured) behind the same operator-file key as 2a, so the level, the probe suite and
the tags do not change when 2a replaces it.

*Closes:* T-a, T-b, T-c, T-f (with `prlimit`/cgroup flags in 2b), T-d. *Leaves open:* the model host stays reachable if the worker needs
it (allow one host: Landlock TCP rules, or a proxy; §8); kernel bugs; a worker allowed to write its execution directory can fill the disk
(quota is outside both).
*Verified by:* Layer 0 H1-H8 under the level. *Tags:* `sandbox-policy-malformed`, `sandbox-refused` (the launcher refuses a policy it cannot
apply), `isolation-unavailable`. *Reports:* a new pinned report for the launcher; Forge's `Exec` narrows to one directory.

### Layer 3: workers as OCI images, by digest *(designed)*

Goal: **identity**, not confinement. The operator file names a worker by a digest; Forge refuses to start anything else
(`worker-digest-mismatch`); a runtime (`runc` or `podman`, both present here, **measured**) gives the boundary of layer 2 for free.
*cancho-oci can package only what is static and self-contained:* the cancho-native workers (`check_guard`, `gate_runner`, `tool_run`, and
`cancho_code` if it stays static) are candidates. **The builder is not**: `cancho-build` starts `/bin/sh`, the compiler, `python3`, `diff` and
`patch`, and "building on a base image" is stage 2 of cancho-oci, not built. *(Unmeasured: whether the cancho binaries are fully static; the
cancho-oci README says a cancho program is "a static executable".)* So this layer helps the cancho workers first, the builder after
cancho-oci grows base images.
*Closes:* T-h for the packaged binaries. *Leaves open:* everything not packaged. *Verified by:* a start of a worker whose digest differs
is refused (`worker-digest-mismatch`) before any process starts. *Reports:* none change; the image's SBOM carries each program's report.

### Layer 4: workers on other machines *(designed; `docs/autonomy.md` has the coordinator design)*

A remote worker host runs layer 2 locally and returns a hashed artifact; Forge runs the check on its own side. It **moves the key**: the
model call can be made by a small broker on the coordinator, so the key never reaches the builder host (closes T-d in kind, not by file
mode). It adds a trust problem of its own (the host, the transport) that this document does not design. *Verified by:* H1-H8 run on the
remote host by a probe sent with the first step.

## 6. Order and what each step buys

| step | cost | buys | needs |
|---|---|---|---|
| 0. hostile suite and preflight probe | small, no new authority | an **honest answer** to "is this boundary real" for every later layer | nothing |
| 1. layer 1 (user, modes, key) | operator setup, one line of glue | T-a, T-d against other processes | a second unix user |
| 2. layer 2b (`bwrap` through `Exec`) | a worker wrapper + policy | T-a, b, c, d, f | `bwrap` installed; user namespaces allowed |
| 3. spike: can a cancho program build Landlock/seccomp arguments | a day | decides 2a vs a compiler change | the compiler pin |
| 4. layer 2a, or the `Confine` capability | a repository, or a compiler feature | the same, ecosystem-native and reviewable | 3 |
| 5. layer 3 for the cancho workers | packaging | worker identity | cancho-oci present state |
| 6. layer 4 | `docs/autonomy.md` | key never on the builder host | 2 |

## 7. Where the language is short, and what would close it

| need | can the language do it today | what would change |
|---|---|---|
| apply an rlimit to a process | not as a builtin; **reachable** through `extern fn setrlimit` under `Ffi("libc")` | a `Confine`-style capability with a bounded label, if `Ffi` is to be avoided |
| change user / group | no builtin; reachable via libc (`setuid`) | same |
| namespaces, seccomp, Landlock | no builtin; reachable via `syscall`/`unshare`, **arguments are the open question** (pointers to structs, §5 L2a ii) | an `extern fn` argument that passes a caller-built byte buffer, or the `Confine` family |
| run code between `fork` and `exec` | no (the builtin does both); the launcher pattern avoids the need | not needed if the launcher self-restricts |
| a bounded label for "this launcher only confines" | no: `syscall` is every syscall; the report lists the symbol | the `Confine` family |
| a launcher inside cancho-tools | **no, by policy**: `tools.toml` forbids `ffi` with no exception | a policy change in that repository, or a repository of its own (recommended) |
| a cgroup / a descendant that left the group | no (`processes.md` §9 names it) | outside the language: the sandbox's PID namespace (2b: `--unshare-pid`) covers it |

## 8. Questions for the maintainer

1. **Where does the launcher live?** A new repository (recommended: `cancho-sandbox`), or an exception for `ffi` in cancho-tools. The policy
   as written has no exception for `ffi`.
2. **Accept `bwrap` as the first implementation?** It is an external binary in the trust base for the first months.
3. **Is the `Confine` capability (bounded labels for rlimit, no-new-privs, Landlock) wanted in the compiler**, instead of a launcher over
   `Ffi("libc")`? It is the larger change and the better report; the spike in §6 decides whether it is needed.
4. **Second unix user**: acceptable operator setup? Without it the audit is only hidden by convention.
5. **The model host.** The builder needs one host (`api.anthropic.com`). A network namespace removes it; a Landlock TCP rule allows a port,
   not a host; a broker on the coordinator removes the need. Which first?
6. **Latent vs live.** Everything in §3 is latent while the only worker is a text agent. Is the first goal to make a tool-using worker safe
   to add (this document), or to harden the current one (then only T-c, T-f, T-h matter)?
7. **Should `cancho-agent` narrow `net_out`** to a configured host list (`unbounded_by` would then be empty)? `net-bounds.md` in the
   compiler repository is the place that decides; not read here.

## 9. What was measured for this document

On this machine (Linux 7.0.0-42-generic, unprivileged user, 2026-10-30), as test oracles only, nothing installed or changed:

| check | result |
|---|---|
| `which unshare bwrap runc podman` | all four present |
| `unshare -Urn true`; `unshare -Urm sh -c 'mount -t tmpfs none /mnt'` | both succeed unprivileged |
| `/proc/sys/user/max_user_namespaces`; `apparmor_restrict_unprivileged_userns` | 115205; `1` (and user namespaces still worked) |
| Landlock ABI (`landlock_create_ruleset(NULL, 0, VERSION)` via `ctypes`) | 8 |
| `bwrap --unshare-net --unshare-pid --ro-bind /usr /usr --tmpfs /tmp --bind ... /work`: read the audit directory; write under `/work`; write `/usr`; `/proc/net/dev`; TCP connect to `1.1.1.1:443` | the audit path was invisible; the write under `/work` succeeded; `/usr` was read-only; only `lo` existed; "Network is unreachable" |
| a cancho test taking `(world: World)` that calls `split` and an `extern fn system` | refused by `cancho test` before running |
| `prlimit`, `setpriv`, `capsh` exist | yes |
| attempts to build a launcher skeleton that calls `prctl` through `Ffi("libc")` under the pinned compiler | **did not get past argument forms** (the `Split` destructuring changed across editions); no conclusion about the language is drawn from it |

Not measured: any of the layers built; a Landlock call from cancho; overhead of `bwrap` on a build; whether the cancho binaries are static.
