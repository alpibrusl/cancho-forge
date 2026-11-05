# The pilot's held-out audit: the test world, the driver and the reference checker

**Status: design, nothing built.** Written before the code (`CONTRIBUTING.md`). It details section 4 and the second step of section 7 of [`pilot-s1.md`](pilot-s1.md), which the board approved on 2026-11-04. Every claim marked
*(designed)* is a proposal; one marked *(read)* was read from the source or document named; each *measure* is a case that must exist before this document says it is true.

**What was read** (2026-11-04): `pilot-s1.md` sections 2 to 7; `spike/p4_world.cho` (13 modes, header) and `spike/p4_check.sh` (17 cases, seen from outside by `curl`); `spike/RESULTS.md` P1 to P4; `company.md` section 8 (a check is started with the
artifact's path and the step's execution directory, `PATH=/usr/local/bin:/usr/bin:/bin`, an empty standard input, a deadline and a 1 MiB output cap; the last `TOTAL a/b` decides; the artifact must never write to the check's standard output).
**Spike result (2026-11-04, compiler `f4ead824`, macOS arm64):** see section 3.1. **Not read:** what a `project.build` leaves
as its artifact (this document assumes the checker as one executable file; section 2 says what changes if not).

## 1. What the audit is for

The audit is the oracle that decides whether the build is accepted (`audit_checker.sh`, the `check` of the `build` step). It must be **right before the builder is run**, so this document builds, in order: a world that misbehaves on purpose, a driver
that compares a candidate's answers with what the world was built to produce, **a reference checker written by hand that passes every case**, and **broken variants of it that each fail at least one case**. Only a world that passes a correct checker and fails a
broken one is shown to be an oracle; that is the repository's way (`CONTRIBUTING.md`: each gate failing once on a broken variant). The builder never sees any of it, and the audit's result is never fed back to it (`company.md` section 8).

## 2. The candidate's interface: what the contract must add *(designed)*

`pilot/contract.cho` pins the pure functions. The audit also has to *start* the checker, so the process interface is part of the contract and the board edits it with the file:

```
checker serve --port <n> --resolver <a.b.c.d> [--roots <pem>] [--allow-loopback] [--now <unix seconds>]
```

* It serves `GET /health` and `GET /check?url=<url>` of `pilot-s1.md` section 3 on `127.0.0.1:<port>` and runs until it is killed; it prints its listening line to its own standard error, never to the check's.
* `--now` fixes the checker's clock for certificate expiry (section 3.1); off by default.
* `--resolver` is the UDP resolver it asks (port 53 unless `<a.b.c.d:p>`); the audit runs a stub resolver (the P1 stub) that answers the names of the cases, so no case depends on the internet.
* `--roots` is the PEM bundle the TLS cases trust (the world's test CA); without it the system's are used. `--allow-loopback` is the setting that lets the checker reach 127.0.0.0/8 and nothing else private (section 4.1); it is **off by default**, and the audit runs the refusal group with it off.
* The artifact is the one executable file. If the build leaves a directory or a source tree instead, `audit_checker.sh` builds it itself with the compiler of the operator's `checker` setting; this is decided with the first `project.build`, not guessed here.

## 3. The world *(designed)*

The world is a cancho program, `pilot/audit/world.cho`, promoted from `spike/p4_world.cho`: a raw TCP server, one mode a process, on loopback, so that cases a library refuses to produce are possible (a connection that never answers, a reset after the headers, a
`Content-Length` that lies, a header block over the limit). It keeps the 13 modes of P4 and adds:

* **a TLS server** (section 3.1): cancho's own, behind the fixtures `valid` (the test CA, name `ok.test`), `selfsigned` and `wrongname` (valid for `other.test`); it answers `GET /` with 200 and nothing else. `expired`, `soon` (10 days left) and `late` (14 days left, the boundary of the rule) are the valid leaf seen under the checker's `--now`. The certificates are made once and checked in under `pilot/audit/tls/`, with the command that made them in a comment of the fixture's README, so no tool runs at test time and a reviewer can remake them.
* **`redirect-to <url>`**: any target, including a private one (`http://169.254.169.254/`), another scheme (`ftp://`), and a hostile `Location` (empty, relative, 8 KiB).
* **a stub resolver** (`pilot/audit/resolver.cho`, from `spike/p1_resolve.cho`'s stub): answers a case's names from a table, including a name that resolves to `127.0.0.1`, to `10.0.0.5`, to `169.254.169.254`, to two addresses (one public-looking
  and one private), and a name that does not exist (NXDOMAIN) or never answers.

Each case starts what it needs and kills it afterwards (a world process serves a fixed number of connections and exits, as P4's does), on ports derived from the driver's process, so two audits can run at once.

*Measure (T1):* `pilot/audit/world_check.sh`, a successor of `spike/p4_check.sh` with the new modes seen from outside by `curl` and `openssl s_client`, all in the gate.

### 3.1 The T1 spike: what cancho's TLS server does and does not do *(measured)*

I built cancho's `examples/https_hello` (`scripts/https_hello_test.py`'s recipe) and served three throw-away identities made with `openssl` (ECDSA P-256, a test CA, `ok.test`) from a directory holding `chain.pem`, `key.pem` and `names`, and probed each with `openssl s_client -verify_return_error -verify_hostname ok.test`:

| Identity | Server | Probe |
|---|---|---|
| valid for `ok.test` | **serves** (`listening`) | chain verifies |
| certificate for `other.test` | **serves** | `verify error:num=62:hostname mismatch` |
| expired (2020 to 2021) | **refuses to load it**: `identity : refused, tls-server-cert-expired`; nothing listens | connection refused |

So the world can serve a valid chain and a wrong-name chain from cancho's server unchanged. Two consequences, corrected in this document (the first revision of this section proposed a forked server loop; the better answer needs none):

1. **No expired fixture is served.** The server checks `notAfter` against its own clock when it loads an identity, so an expired certificate cannot be served. It does not need to be: every leaf is valid from 2026-01-01 to 2035-01-01, and *expired* is the checker's view when it is run with `--now` past `notAfter`.
2. **A static fixture cannot keep a "10 days left" or "14 days left" certificate true**, because the checker's `days_left` depends on the real date. So the contract gets an operator setting, **`--now <unix seconds>`**, off by default like `--allow-loopback`, that fixes the checker's clock (the deploy preflight refuses a production configuration with either). With it, `t02` (expired), `t05` (10 days) and `t06` (14 days) all use the same valid leaf: the audit sets `--now` to `notAfter` plus a day, minus 10 days and minus 14 days, deterministic on any day of the year. Without it the cases would rot. The board edits this into `pilot/contract.cho` with the process interface of section 2.

**Built in T1** (`pilot/audit/tls_check.sh`, in the gate): the server is cancho's `examples/https_hello`, **vendored verbatim** from the pinned compiler revision into `pilot/audit/vendor/` (the compiler's `examples/` are not available to the gate, only its `packages/`), built with the compiler's `http-server`, `tls` and `x509`; the fixtures are `pilot/audit/tls/` (made once by `make.sh`, checked in, throw-away keys). Seen from outside: a valid chain for `ok.test` verifies and answers 200; a TLS 1.2-only client is refused; plain HTTP on the TLS port is not answered; a certificate for `other.test` is served and fails with a hostname mismatch; a self-signed leaf is served and fails verification. 5 of 5.

**Also built in T1:** the P4 world is promoted to `pilot/audit/world.cho` (with `redirect301 <url>` and `location empty|relative|long`; `redirect <url>` already took any target, a private one included) and `pilot/audit/resolver.cho` is the stub resolver: `resolver <port> <queries> <name=a.b.c.d[,a.b.c.d]|NX|SILENT>...`, up to four A records, NXDOMAIN for a name not in the table, silence on request. `pilot/audit/world_check.sh` (the 17 P4 cases, 4 new redirect cases, 7 resolver cases, seen from outside by `curl` and by the P1 client) is in the gate: 28 of 28. **T1 is done.**

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

### 4.1 As built in T2 *(measured)*

* `pilot/audit/expect.cho` (pure; `tests/audit_expect_test.cho`, 6 tests): the checks of a case, `status=N`, `status>=N`, `status<=N`, `path=V`, `path~S`, `path>=N`, `path<=N`, `path#N`, `path?`, `path-`; the answer of a spec that has no known shape is a number, never a trap.
* `pilot/audit/driver.cho`: one request to a candidate on loopback, one answer read under a deadline, one comparison; prints `ok` or `fail <why>`; exit 0 pass, 1 fail, 2 usage, 3 no answer to check.
* `pilot/audit/cases.txt`: the case format (header of the file) and a **starter set of 21 cases** (`p00 p06 v01 v02 v03 v04 v05 v07 v10 l09 r01` to `r11`). The groups and the format are final; **the rest of the 60 are written with the reference checker (T3)**, because a case nothing has been able to pass cannot be told from a case that is wrong. This corrects the table above, which read as if the whole table came in T2.
* `pilot/audit/audit_checker.sh <artifact> <execution dir>`: per case, the world processes, the stub resolver and a fresh candidate (`<artifact> serve --port <n> --resolver 127.0.0.1:<n> <flags>`), the driver; one `pass <id>` / `fail <id> (<why>)` line per case on **standard error**, and `TOTAL a/b` **last on standard output**; the candidate's output goes to a file in the execution directory.
* **The setting is `--allow-loopback`, not `--allow-private`.** It lets the checker reach 127.0.0.0/8 and **nothing else private**. With it the audit can run a case whose first hop is the world on loopback and whose redirect goes to `169.254.169.254` (`r11`), which `--allow-private` would have made untestable (section 8, question 2, answered). The refusal cases `r07` to `r10` run without it. The board edits the name into the contract.
* **Self-check** (`pilot/audit/self_check_standins.sh`, in the gate): a stand-in that answers one canned "up" JSON to everything passes **exactly** `p00 v02 v03` of the 21 (`TOTAL 3/21`) and fails the other 18; a candidate that never listens scores `TOTAL 0/21` with all 21 reported failed, none skipped; a candidate that prints `TOTAL 99/99` itself leaves the audit's last standard-output line `TOTAL 0/21`. About 43 seconds on this machine, three audits and the builds; the dead candidate's waits dominate.
* **Not yet measured:** a stand-in right for each single case (this one is right for three); the per-case wall time with a real candidate (T3); the TLS cases (they need the contract's `--roots` and `--now`); the rate-limit case (it needs 31 requests to one candidate, which the one-request-per-case format does not express yet: a `requests <n>` key, added with it).

## 5. The reference checker and the broken variants *(designed)*

`pilot/audit/reference/` is a checker written by hand against `pilot-s1.md` sections 2 and 3, by the same rules as the contract, whose only job is to pass the audit. It is **not** what the build is shown, and it is not what the company ships: it exists so that the
audit has a witness. It uses the P1 resolver and the P2/P3 client work; its expiry is measured by the shifted-clock probe of P2 until the accessor exists, and that is a flaw the audit must not hide: case `t05`/`t06` fail with a probe that is off by one day.

`pilot/audit/broken/` holds the **mutants**: the reference with one deliberate fault each, **one per behaviour the audit claims to check** (at least 40: a 404 as `degraded`; a private check before the redirect but not after; the octal form allowed; the cap at 64 KiB + 1; five redirects allowed as six;
`days_left` off by one; the boundary at 15; `degraded` for a slow answer at 4999 ms; a refusal without `repair`; a crash on a 10 KiB target; and so on). Each mutant is a one-line edit of the reference (built, section 5.2: not a diff, so that no line number can drift), so that the mutants
are small, reviewable text and not 40 copies of a program.

*Measure (T3, T4):* `pilot/audit/self_check.sh` builds the reference and passes if **the reference scores N/N and every mutant scores below N/N**, naming the cases that caught each; a mutant nothing catches is printed as a hole in the audit and fails the check.

### 5.1 T3 as built so far: the pure core *(measured)*

T3 is cut in three: **R1** the pure core (done), **R2** the fetcher (resolve over UDP with the stub, connect to the literal address, redirects, the 64 KiB cap, phase times, the TLS probe), **R3** the server (`checker serve ...`, `/health`, `/check`, the rate limiter, the JSON answer). Only when R3 is in can `self_check.sh` run the reference against `cases.txt`.

`pilot/audit/reference/checker.cho` (`module checker`, no network, no clock, total) holds the functions `pilot/contract.cho` pins and what they stand on: `verdict_of`, `verdict_name`, `private_v4`, `url_rule`, `repair_of`, and `url_host`, `url_port`, `url_is_https`, `url_target`, `ipv4_loose` (decimal, octal and hex forms, one to four parts, as `inet_aton`), `ipv6_class` and `literal_private` (every way to write loopback is loopback). 10 unit tests, `tests/checker_test.cho`, in the gate, with the boundary on both sides of every private range.

**R2a, the fetcher over plain HTTP (built).** `pilot/audit/reference/fetch.cho` (`module fetch`) and its command line `fetch_cli.cho`: `fetch.run` takes a URL and answers a refusal rule or the contract's JSON (`url`, `final_url`, `status`, `redirects`, `addresses`, `tls`, `timing_ms`, `verdict`, `reason`). It judges the URL, resolves the host itself over UDP (`spike/lib/dns.cho`) or reads an address literal in any spelling, judges **every** address, connects to the address (never the name) with a connect limit, sends `GET`, reads the head and at most 64 KiB of body, follows up to five redirects judging each hop again, and stops at the hard limit of 8 s (`check.timeout`). A body longer than the cap is cut and the reason says so; a head over 64 KiB, a reset, an empty reply, half a status line and a `Content-Length` that lies are `down`. `pilot/audit/reference/fetch_check.sh` (in the gate) runs it against the world and the stub resolver through the command line: 30 of 30 (statuses, every failure shape, the cap, a chunked answer, a first byte at 6 s, one redirect followed, a loop, a redirect to the metadata address and to another scheme, the port list and `--allow-loopback`, eight spellings of a private address, a name that resolves to loopback, a name with one private record among its answers, NXDOMAIN, a public-looking address with nothing behind it, a hang). Not in R2a: the TLS probe (`tls.verified`, `days_left`, the `tls` phase time) and the answer's `tls` object, which is `null`.

**R2b, the TLS probe (built).** `pilot/audit/reference/probe.cho` (`module probe`) drives cancho's TLS 1.3 client engine over one address: handshake for the **name** against the roots it is given, at the clock it is given (`now_ms`, the checker's `--now`), then the request over the established connection. `fetch.run` uses it for an `https` URL, takes `tls.verified` from the handshake and the `tls` phase time from its duration, and **finds `days_left` by handshaking at later clocks** (the largest whole number of days `d` for which the chain still verifies at `now + d days`, a bisection of at most 17 handshakes), because the engine does not publish the leaf's `notAfter` (spike P2); that is the flaw to remove with the accessor, and the audit's `days_left` cases are what will notice a probe that is off by a day. `fetch_check.sh` gained 11 cases against the vendored TLS server on the audit's fixtures (41 of 41 in all): a valid chain with 1826 days left at five years before `notAfter`; 14 days left is `up` (the boundary), 13 days and 23 hours is 13 whole days and `degraded`; 10 days and 1 day are `degraded`; an expired chain, a certificate for another name, a self-signed one and a chain no trusted root vouches for are `down` with `tls.verified` false and the engine's refusal tag as the reason; the `tls` phase is measured. Found on the way: **the engine's refusals are small negative numbers** (-28 for a name mismatch, for instance), not positive codes, and a peer that closes after its alert can make the write of ours fail before the loop looks at the engine's state, so the loop looks first; and the 64 KiB a region holds in all is exceeded by three 16 KiB buffers and a pending buffer (the trap said so), so the exchange uses 8 KiB buffers.

**R3, the server, and the first score (built).** `pilot/audit/reference/server.cho` is `checker serve --port --resolver [--roots] [--allow-loopback] [--now]`: `GET /health`, `GET /check?url=`, `HEAD /health`, 405 for other methods, 404 for other paths, 414 above an 8 KiB target, 431 above a 16 KiB head; a refusal is `application/problem+json` with `rule` and `repair` (url.* 400, target.private-address 403, target.too-many-redirects 422, rate.limited 429, check.timeout 504). `request.cho` (the request line, the query, a parameter and how often it appears, percent-decoding once) and `ratelimit.cho` (30 checks a minute a source, in memory) are pure, total and unit-tested (`tests/request_test.cho`, 7 tests). `cases.txt` now holds **71 cases at R3**: verdict 12, limits 11, refusals 32, protocol 9, tls 7 (T4 added six, 77 in all: refusals 37, tls 8; section 5.2). `pilot/audit/self_check.sh` (in the gate) builds the reference and runs it through all of them: **TOTAL 71/71**.

What running the reference found, all fixed in the audit and not in the reference: the first run scored 13 of 21 of the starter set, because (1) a world was not yet listening when the candidate's request reached it, so `audit_checker.sh` now waits for every world's `listening` line, and (2) `r07` asked for `http://127.0.0.1:<arbitrary port>/` with the loopback setting off, which a correct checker may refuse as `url.port` or as `target.private-address`: an ambiguous case, now `http://127.0.0.1:8080/`. The 71-case run then scored 70: `t07` (a TLS URL on a port that speaks plain HTTP) used a world that waited for a request the TLS client never sends, so a correct checker could only time out; the world has an `eager` mode that speaks first, as a plain HTTP server does. And the stand-in check had predicted the canned-up candidate would pass 3 cases; it passes the 8 whose spec is a 200 and `up` and nothing else (`p00 p03 p05 v02 v03 l01 l06 l07`), each checked by reading its spec. The gate runs 12 of the 71 for the three stand-ins (the 8 plus 4 it fails: the full run takes ten minutes, dead candidate's waits dominating) and `FULL=1` runs all; the full run was measured once, after this change: 8 of 71, 0 of 71, and the noisy candidate's `TOTAL 99/99` still not on the audit's standard output.

Not yet: the audit's wall time and the gate's, and the board's reading of the table (T6).

### 5.2 T4, the mutants *(measured)*

`pilot/audit/broken/mutants.txt` holds **49 mutants**, each a block of `what` (the fault), `file`, `from` (text of the reference that occurs **exactly once**), `to` and `catch` (the cases that must notice it). `pilot/audit/mutate.cho` (unit-tested, `tests/mutate_test.cho`) applies the edit and refuses a `from` that is missing, repeated (overlaps count) or empty, so a mistake in a mutant cannot pass as a fault nothing found. `pilot/audit/self_check_mutants.sh` builds each (3 s), runs only its `catch` cases (so 49 mutants take about 6 minutes, not 49 audits) and prints `caught mNN by <cases>` or `HOLE mNN`. The gate runs a sample of six (one per kind of fault: the expiry boundary, a private range, the URL length, the redirect count, the redirect limit, the probe); the whole set runs on demand.

The first pass caught 45 of 49. **Every miss was the audit's, not the reference's**: the audit had not claimed what the mutant broke.
- *The boundary of 13 days.* A mutant with the degraded line at 13 days passed because the cases had 10 and 14 and nothing between: case `t08` (13 days and 23 hours, whole days 13, `degraded`) is new.
- *Five redirects allowed as six.* `l09` used a world that serves eight connections, so a checker that followed six redirects also ended in the refusal; the world now serves exactly six (the request and five followed), and a sixth followed hop finds nothing.
- *Statuses of the refusals.* The refusal cases accepted any 4xx, so a private address answered 400 for 403 and too many redirects 400 for 422 passed; the cases now say `status=403` and `status=422`.
- *`repair` and `reason` that say nothing.* The check `repair?` meant "there and not null", which an empty string satisfies; the spec language has `path+` (a string of at least one byte) and every refusal and every `down` uses it.
- *Ranges and ports nothing tried.* Multicast (`r33`), 100.64/10 (`r34`), and the ports 8443 and 8080 being **accepted** (`r35`, `r36`: a name that does not resolve is `down`, not `url.port`), and a URL of 2,100 bytes against the 2,048 limit (`r37`), are new.
- *One equivalent mutant* (a 5xx test the 4xx test already covers) was dropped, not counted.

Not claimed, and so not tested: the 60-second window of the rate limit, the exact byte of the body cap, the 8-second hard limit to the millisecond, a public address being accepted (the audit cannot reach one). A candidate that gets these wrong passes; the board should know this when it reads the table (T6).
**`--allow-loopback` and the port list, refined.** The port list is no longer lifted for a loopback *literal* only: the fetcher defers it until the host's addresses are known and lifts it when the setting is on **and every address is in 127.0.0.0/8**. A name that the stub resolver maps to 127.0.0.1 (the TLS cases need `ok.test` to be a name, for the certificate) therefore works on the world's arbitrary port, and a name mapped to a public address on a port outside the list is still `url.port`.

Found on the way: the stub resolver had no way to say it was ready, so a check that started it and queried at once raced it. It now prints `listening <port>` after binding and the scripts wait for that line (a measured race, not a guess: two cases failed on it).

Decisions this forced, for the board to confirm in the contract:

* **Documentation ranges (192.0.2/24, 198.51.100/24, 203.0.113/24) are public** to `private_v4`: the audit's "public-looking" address is 203.0.113.7. 0/8, 10/8, 100.64/10, 127/8, 169.254/16, 172.16/12, 192.0.0/24, 192.168/16, 224/4 and 240/4 are refused.
* **`--allow-loopback` lifts the port list for loopback too.** `url_rule` is the contract's pure port list (80, 443, 8080, 8443); the world listens on arbitrary ports, so with the setting on the server accepts any port for a loopback literal and for nothing else. Without this every verdict case would be `url.port`. Found by the first test of `url_rule` on `http://127.0.0.1:41001/`.
* **A public IPv6 literal is `url.invalid`'s sibling, not checked**: the reference connects over IPv4 only; a private one is `target.private-address`, a well-formed public one is answered `url.invalid` with the repair "use an IPv4 address or a name" (decided in R2).

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
| **T2** *(built, starter set)* | the case format, the driver, `audit_checker.sh`; the stand-in candidates | `pilot/audit/self_check_standins.sh` (section 4.1) |
| **T3** | the reference checker | `self_check.sh`: the reference scores N/N |
| **T4** | the mutants | every mutant scores below N/N; no hole |
| **T5** | the gate integration, the audit's duration, the results recorded here and in `pilot-results.md` | the gate runs `self_check.sh` |
| **T6** | the board reads the case table and approves the `audit` gate | the board's decision, recorded by `forge company decide` |

T3 is the largest (a checker with DNS, TLS, redirects and a rate limiter); T1 and T2 are the cheapest and are done first, because they show whether the world can be made at all.

## 8. Open questions

1. **Is the reference the product?** Recommended no: the company builds the checker from the brief and the contract with a model, and the reference exists only as the audit's witness. If the reference is good enough to ship, that is a decision for later and it would make the experiment pointless.
2. **The loopback setting.** Answered in section 4.1: `--allow-loopback`, which allows 127.0.0.0/8 and nothing else private. The refusal group runs with it off; `r11` (a redirect from loopback to the metadata address) runs with it on.
3. **Time limit.** `check_timeout_ms` for the build's check is the operator's; the audit's slowest cases are seconds long. Measured at T2.
