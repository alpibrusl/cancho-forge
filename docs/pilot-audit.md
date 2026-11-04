# The pilot's held-out audit: the test world, the driver and the reference checker

**Status: design, nothing built.** Written before the code (`CONTRIBUTING.md`). It details section 4 and the second step of section 7 of [`pilot-s1.md`](pilot-s1.md), which the board approved on 2026-11-04. Every claim marked
*(designed)* is a proposal; one marked *(read)* was read from the source or document named; each *measure* is a case that must exist before this document says it is true.

**What was read** (2026-11-04): `pilot-s1.md` sections 2 to 7; `spike/p4_world.cho` (13 modes, header) and `spike/p4_check.sh` (17 cases, seen from outside by `curl`); `spike/RESULTS.md` P1 to P4; `company.md` section 8 (a check is started with the
artifact's path and the step's execution directory, `PATH=/usr/local/bin:/usr/bin:/bin`, an empty standard input, a deadline and a 1 MiB output cap; the last `TOTAL a/b` decides; the artifact must never write to the check's standard output).
**Not read:** whether a cancho program can *serve* TLS with a given certificate and key (P2 drove the client side and used cancho's `https_hello` and its test chain as the server; the server side is the first spike of T1), and what a `project.build` leaves
as its artifact (this document assumes the checker as one executable file; section 2 says what changes if not).

## 1. What the audit is for

The audit is the oracle that decides whether the build is accepted (`audit_checker.sh`, the `check` of the `build` step). It must be **right before the builder is run**, so this document builds, in order: a world that misbehaves on purpose, a driver
that compares a candidate's answers with what the world was built to produce, **a reference checker written by hand that passes every case**, and **broken variants of it that each fail at least one case**. Only a world that passes a correct checker and fails a
broken one is shown to be an oracle; that is the repository's way (`CONTRIBUTING.md`: each gate failing once on a broken variant). The builder never sees any of it, and the audit's result is never fed back to it (`company.md` section 8).

## 2. The candidate's interface: what the contract must add *(designed)*

`pilot/contract.cho` pins the pure functions. The audit also has to *start* the checker, so the process interface is part of the contract and the board edits it with the file:

```
checker serve --port <n> --resolver <a.b.c.d> [--roots <pem>] [--allow-private]
```

* It serves `GET /health` and `GET /check?url=<url>` of `pilot-s1.md` section 3 on `127.0.0.1:<port>` and runs until it is killed; it prints its listening line to its own standard error, never to the check's.
* `--resolver` is the UDP resolver it asks (port 53 unless `<a.b.c.d:p>`); the audit runs a stub resolver (the P1 stub) that answers the names of the cases, so no case depends on the internet.
* `--roots` is the PEM bundle the TLS cases trust (the world's test CA); without it the system's are used. `--allow-private` is the single setting that lets the checker reach loopback; it is **off by default**, and the audit runs the refusal group with it off.
* The artifact is the one executable file. If the build leaves a directory or a source tree instead, `audit_checker.sh` builds it itself with the compiler of the operator's `checker` setting; this is decided with the first `project.build`, not guessed here.

## 3. The world *(designed)*

The world is a cancho program, `pilot/audit/world.cho`, promoted from `spike/p4_world.cho`: a raw TCP server, one mode a process, on loopback, so that cases a library refuses to produce are possible (a connection that never answers, a reset after the headers, a
`Content-Length` that lies, a header block over the limit). It keeps the 13 modes of P4 and adds:

* **`tls <fixture> <mode>`**: the same modes behind a TLS handshake, with the certificate and key of a checked-in fixture: `valid` (the test CA, name `ok.test`), `expired`, `selfsigned`, `wrongname` (valid for `other.test`), `soon` (10 days left),
  `late` (14 days left, the boundary of the rule). The certificates are made once and checked in under `pilot/audit/tls/`, with the command that made them in a comment of the fixture's README, so no tool runs at test time and a reviewer can remake them.
* **`redirect-to <url>`**: any target, including a private one (`http://169.254.169.254/`), another scheme (`ftp://`), and a hostile `Location` (empty, relative, 8 KiB).
* **a stub resolver** (`pilot/audit/resolver.cho`, from `spike/p1_resolve.cho`'s stub): answers a case's names from a table, including a name that resolves to `127.0.0.1`, to `10.0.0.5`, to `169.254.169.254`, to two addresses (one public-looking
  and one private), and a name that does not exist (NXDOMAIN) or never answers.

Each case starts what it needs and kills it afterwards (a world process serves a fixed number of connections and exits, as P4's does), on ports derived from the driver's process, so two audits can run at once.

*Measure (T1):* `pilot/audit/world_check.sh`, a successor of `spike/p4_check.sh` with the new modes seen from outside by `curl` and `openssl s_client`, all in the gate.

## 4. The cases and the driver *(designed)*

A case is one row of `pilot/audit/cases.txt` (a plain text table, one row a case, parsed by the driver with a closed shape): `id | group | world setup | request | expected`. `expected` is a list of `field=value` or `field~substring` checks on the JSON of the
answer and on its HTTP status; a case fails on any check, and a case that cannot start (the candidate did not listen, the world did not) is a failure of that case, never a skip. About **60 cases** in the groups of `pilot-s1.md` section 4:

| Group | Cases (id: what the world does and what must come back) |
|---|---|
| **verdict** (12) | `v01` 200 → `up`; `v02` 404 → `up` (the target's own answer); `v03` 410 → `up`; `v04` 500 → `degraded`; `v05` 503 → `degraded`; `v06` 403 → `degraded`; `v07` 301→200 → `up`, `final_url` is the last hop; `v08` first byte at 1 s → `up`; `v09` total over 5000 ms but under the limit → `degraded`; `v10` connection refused → `down`; `v11` reset after half a status line → `down`; `v12` an empty reply → `down` |
| **limits** (12) | `l01` first byte at 3 s still answers; `l02` first byte past the hard limit → `check.timeout`; `l03` a body of 64 KiB is read, 64 KiB + 1 is cut and the answer says so (`reason`); `l04` a 300 000-byte body does not make the answer slow or large; `l05` a chunked answer is read; `l06` a trickled body ends at the cap or the time limit, not later; `l07` 1 redirect; `l08` 5 redirects; `l09` 6 redirects → `target.too-many-redirects`; `l10` a redirect loop → the same rule; `l11` a `Content-Length` that lies → `down` with a reason, never a hang; `l12` a header block of 100 KiB → `down`, never a crash |
| **refusals** (20) | one case per `rule` of the contract and per shape: `url.invalid` (empty, no scheme separator, a space, 4 KiB long); `url.scheme` (`ftp://`, `file:///etc/passwd`, `javascript:`); `url.credentials` (`http://u:p@host/`); `url.port` (22, 25, 0, 65536, 8081); `target.private-address` for `127.0.0.1`, `localhost` (resolver answers 127.0.0.1), `[::1]`, `0.0.0.0`, `10.0.0.5`, `172.16.0.1`, `192.168.1.1`, `169.254.169.254`, the decimal `2130706433`, the octal `0177.0.0.1`, the hex `0x7f.1`, `::ffff:127.0.0.1`, a name with two A records one of them private, and **a redirect from a public-looking target to `169.254.169.254`**; `rate.limited` (the 31st request in a minute from one source, then a different source is not limited). Every refusal carries `rule` and a non-empty `repair`, and the status is the one the contract names |
| **protocol** (8) | `p01` the request line of the candidate's own server given a path without a query (`/check`) → a problem answer, not a crash; `p02` a query with the `url` twice; `p03` a percent-encoded URL decodes once; `p04` a 10 KiB request target; `p05` `HEAD /health`; `p06` an unknown path → 404 problem; `p07` `POST /check` → 405; `p08` the server still answers `/health` after all of the above (it did not die) |
| **tls** (8) | `t01` valid chain, right name → `tls.verified=true`, `days_left` large; `t02` expired → `down`, `verified=false`; `t03` self-signed → `down`; `t04` a certificate for another name → `down`; `t05` 10 days left → `degraded`, `days_left=10`; `t06` 14 days left → `up` (the boundary); `t07` a TLS port that speaks plain HTTP → `down`; `t08` an `https` redirect to an `http` target and back |

*Measure (T2):* the driver is run against a **stand-in candidate** (a canned-answer HTTP server) that is right for one case and wrong for the rest: it passes exactly that case, so the comparison logic is shown to say pass when it should and fail when it should.

## 5. The reference checker and the broken variants *(designed)*

`pilot/audit/reference/` is a checker written by hand against `pilot-s1.md` sections 2 and 3, by the same rules as the contract, whose only job is to pass the audit. It is **not** what the build is shown, and it is not what the company ships: it exists so that the
audit has a witness. It uses the P1 resolver and the P2/P3 client work; its expiry is measured by the shifted-clock probe of P2 until the accessor exists, and that is a flaw the audit must not hide: case `t05`/`t06` fail with a probe that is off by one day.

`pilot/audit/broken/` holds the **mutants**: the reference with one deliberate fault each, **one per behaviour the audit claims to check** (at least 40: a 404 as `degraded`; a private check before the redirect but not after; the octal form allowed; the cap at 64 KiB + 1; five redirects allowed as six;
`days_left` off by one; the boundary at 15; `degraded` for a slow answer at 4999 ms; a refusal without `repair`; a crash on a 10 KiB target; and so on). Each mutant is a patch to the reference, applied at audit time by a cancho patch step (`src/patch_apply.cho` exists) so that the mutants
are small, reviewable text and not 40 copies of a program.

*Measure (T3, T4):* `pilot/audit/self_check.sh` builds the reference and passes if **the reference scores N/N and every mutant scores below N/N**, naming the cases that caught each; a mutant nothing catches is printed as a hole in the audit and fails the check.

## 6. Where it runs, what it costs, what can go wrong *(designed)*

* `audit_checker.sh <artifact> <execution dir>` builds nothing it does not have to: it starts the stub resolver, then one world process per case, then the artifact, runs the driver, and prints the cases that failed on **standard error** and the single line `TOTAL a/b` **last on standard output**. The artifact's
  output goes to a file in the execution directory, never to standard output (`company.md` section 8, the rule for audit authors). The whole audit has a deadline the check guard enforces (`check_timeout_ms`; the cases run in parallel groups to fit it).
* **No model is used by the audit.** It costs nothing in tokens; it costs machine time (the slow cases are real seconds), measured at T2 and recorded here.
* **What can go wrong.** Flaky cases (timing at the edge of a limit): every timing case has a margin of at least a second on both sides and runs once, and a flaky case is a defect in the audit to fix, not to retry. A world that is wrong in the same way as the reference (one author): the cases are checked
  against the *contract's text*, not against the reference, and the board reads the case table at the `audit` gate; a second author of the reference is the better protection and is named as the next step if the pilot continues. Overfitting: the builder never sees the world, but
  the contract's pure functions are visible and the cases that exercise them exactly (the boundary at 14 days) are part of the contract's text on purpose.

## 7. Slices and what measures them

| Slice | Content | Measured by |
|---|---|---|
| **T1** | the world promoted to `pilot/audit/`, the TLS fixtures, the new modes, the stub resolver; a spike answers whether cancho can serve TLS with a given certificate | `world_check.sh` in the gate (the P4 cases plus the new ones, seen from outside) |
| **T2** | the case table, the driver, `audit_checker.sh`; the stand-in candidates | the stand-in right for one case passes exactly that case; a candidate that cannot start fails every case |
| **T3** | the reference checker | `self_check.sh`: the reference scores N/N |
| **T4** | the mutants | every mutant scores below N/N; no hole |
| **T5** | the gate integration, the audit's duration, the results recorded here and in `pilot-results.md` | the gate runs `self_check.sh` |
| **T6** | the board reads the case table and approves the `audit` gate | the board's decision, recorded by `forge company decide` |

T3 is the largest (a checker with DNS, TLS, redirects and a rate limiter); T1 and T2 are the cheapest and are done first, because they show whether the world can be made at all.

## 8. Open questions

1. **Is the reference the product?** Recommended no: the company builds the checker from the brief and the contract with a model, and the reference exists only as the audit's witness. If the reference is good enough to ship, that is a decision for later and it would make the experiment pointless.
2. **The `--allow-private` setting.** The audit needs loopback; the contract names the setting. Recommended: the refusal group runs with it off against **public-looking addresses served through the stub resolver** (the world listens on `127.0.0.1`, so a name mapped to `203.0.113.7` cannot be connected to); decided with T3, when it is clear which cases can run
   with the setting off at all. The ones that cannot are listed here, not dropped.
3. **Time limit.** `check_timeout_ms` for the build's check is the operator's; the audit's slowest cases are seconds long. Measured at T2.
