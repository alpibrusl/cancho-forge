# Pilot stage 1: the free checker, its held-out audit and the first week

> **Status: design, nothing built, nothing measured.** Everything below is *(designed)* unless marked *(read)*. It is the design of stage S1 of [`pilot.md`](pilot.md), written
> before any code, as the repository's rules require. The product's brand is not written here: the company's name lives only in `pilot/brand.json`, and this document says "the
> checker" and "the company".
>
> **What was read** (2026-11-02): `pilot.md`; cancho `f4ead824` file names only (`packages/` holds `http-server`, `http-client`, `tls`, `x509`, `net-connect`, `net-sockets`; `examples/tls_nb/dns.cho`,
> `resolve_demo.cho`; `docs/ROADMAP.md` rows on UDP, `Net` and who resolves names). **Not read:** any of those sources' code. Whether cancho can do each thing in section 6 is therefore the
> first thing the spikes there find out.

## 1. What S1 is for

S1 is the smallest company that has a product on the internet, a deploy, a monitor of its own, content that brings visitors, and a change request that goes from a report to a fix. It
has no accounts, no state and no money. If it cannot run unattended for a month, S2 does not start.

## 2. The brief (what the checker answers and refuses)

*(To be approved by the board: gate `brief`.)* The checker takes **one URL** and answers, within a hard time limit, with: whether it is reachable and with what status, the redirect chain
(at most five hops), the time spent resolving, connecting, handshaking and waiting for the first byte, the addresses the name resolved to, and, for `https`, whether the chain verifies for that
name and how many days the certificate has left. It reads **at most 64 KiB** of the body and keeps none. It stores nothing about the request except counters.

It **refuses** a URL that is not `http` or `https`, has credentials in it, names a port outside a short list (80, 443, 8080, 8443), resolves to a private, loopback, link-local, multicast or
cloud-metadata address (checked after every redirect), or comes from a source over its rate limit. A refusal has a stable rule name and says what to change (`repair`), as the
`cancho-industrial` platform's answers do *(read)*.

## 3. The contract (what the build must implement)

*(A person's file: gate `contract`, file `contract.cho` in the company directory. This section is the draft the board edits.)*

| Operation | Answer |
|---|---|
| `GET /health` | `200` `{"ok":true}` |
| `GET /check?url=<url>` | `200` `{"url","final_url","status","redirects":[{"url","status"}],"addresses":["..."],"tls":{"verified":bool,"days_left":int}\|null,"timing_ms":{"dns","connect","tls","first_byte","total"},"verdict":"up"\|"degraded"\|"down","reason":"..."}` |
| refusals | `application/problem+json` with `rule` and `repair`: `url.invalid`, `url.scheme`, `url.credentials`, `url.port`, `target.private-address`, `target.too-many-redirects`, `rate.limited`, `check.timeout` |

`verdict` is a function of the measurements and nothing else: **down** if no response arrived, a connection failed or the chain did not verify; **degraded** if the status is 5xx, 4xx
other than 404 and 410 counted as the target's own answer, `days_left` is under 14, or `total` is over 5000 ms; **up** otherwise. All numbers are integers (milliseconds, days), as the
company's rule is that no floating point sits near a decision (`company.md` section 9).

## 4. The held-out audit: a test world the builder never sees

The audit is the product's oracle, and the most valuable thing the pilot builds first. It is **a cancho program that serves controllable fake targets** and **a driver that runs a candidate
checker against them and compares the answer with what the world was built to produce**. Both are written in cancho and run the candidate as a child process; the driver prints
`TOTAL a/b` as every check does (`company.md` section 8). The builder is never shown the world, its cases or its expected answers; a repro of a reported bug is added to it
(`company-lifecycle.md` section 4.3).

The world serves, on loopback ports: 200 with a body; 404; 410; 500; 503; a slow first byte (1, 3 and 6 s); a slow body; a body over 64 KiB; a 301 chain of 1, 5 and 6 hops; a redirect loop;
a redirect to a private address; a redirect to another scheme; a connection accepted and never answered; a connection refused; a reset after the headers; a chunked answer; a
`Content-Length` that lies; a header block over the limit; and, for TLS, a valid certificate, an expired one, a self-signed one, one for another name and one with 10 days left
(certificates made once and checked in as fixtures, so no tool runs at test time).

**About loopback:** the checker refuses loopback in production. The audit needs the checker to reach loopback, so the checker has one operator setting, `allow_private`, that is **off by default** and is
the only difference between the test configuration and the production one; the audit includes cases that run with it off and expect `target.private-address` for every private shape (decimal and
octal forms, `[::1]`, IPv4-mapped IPv6, a name that resolves to `127.0.0.1`, a redirect to `169.254.169.254`). The deploy preflight refuses a production configuration with it on.

Cases are grouped so a failure says what kind it is: **verdict** (the table above), **limits** (time, size, redirects), **refusals** (every rule), **protocol** (the hostile shapes), **tls**.
Target: about 60 cases before the first build, each with the exact expected JSON fields it checks.

## 5. The company in stage 1: who does what

| Function | S1 work | First scenario |
|---|---|---|
| Product | the brief, the contract, the audit (board approves the three) | gates `brief`, `contract`, `audit` |
| Dev | build the checker (`project.build`), then every change as `repo.change` | #1, #2 of `pilot.md` |
| QA | the held-out audit; the repository gate | every change |
| Reviewer | an authority distinct from the builder (lacking today: `pilot-results.md`) | every change |
| Design | the checker's page | scenario #8 |
| DevOps | deploy to staging, probes, rollback; the first deploy is the board's | #5 |
| Monitoring | the company's own monitor: the checker checking the checker | #3, #5 |
| Marketing | two posts a week for searches the checker answers, with a claim check | #8 |
| Support, Finance, Legal | not in S1 (no users, no money, a free tool); the abuse policy text is written | #6 |

The manifest is `pilot/company.json`: six steps (three gates, the build, the gate, the demo), valid under `forge company check`. It grows as functions appear; each growth is its own commit.

## 6. Spikes (done, 2026-11-02; results in `spike/RESULTS.md`)

| Spike | Question | Answer |
|---|---|---|
| P1 | Can a cancho program resolve a name over UDP and report the addresses and the time? | **Yes**: against a stub and once against a real resolver, with a deadline (`spike/p1_check.sh`, in the gate) |
| P2 | Can it connect, handshake, read the peer certificate's expiry and verify the chain for a name? | **Yes, with a gap**: verification, name and issuer failures each have their own tag; the engine does not publish `notAfter`, so expiry is measured by a shifted-clock probe (right to the day, 15 handshakes; one or two for the 14-day rule) until a one-line accessor is added to `packages/tls` |
| P3 | Can it fetch with a bounded body, count redirects and time each phase? | **Mostly**: cancho's client connects to an IP and verifies against the name; redirects, phase times, the 64 KiB cap and the specific TLS tags are the checker's to add |
| P4 | Can it serve HTTP and TLS cases with hostile behaviours? | **Yes for HTTP** (13 modes, 17 cases seen from outside by curl, in the gate); TLS cases wait for certificate fixtures |

Consequences recorded in this document: the checker holds an unnarrowed `Net` and judges addresses itself, after resolution, then connects to the literal address; the resolver address is a deployment setting;
`days_left` is the integer the probe gives; the world's TLS cases are `https_hello`'s valid chain plus the shifted clock until fixtures exist.

## 7. The first week

1. The board approves this document and edits the contract from what the spikes found (section 6).
2. The test world is built; its first cases are checked by a hand-written reference checker, so the oracle is shown to pass a correct one and fail a broken one (the repository's way: each gate failing once on a broken variant).
3. The brief, contract and audit are approved at the three gates; `build` runs with a real model under the budget of `pilot/company.json` ($10, tokens only).
4. Whatever the build leaves is judged by the audit; the demo is the board's.

## 8. Open questions

1. **Where does the checker run in S1?** One small server of the hosting provider chosen in `pilot.md` section 11, behind that provider's firewall, with the checker the only service on it. The first deploy is the board's, by hand, once.
2. **Is a resolver a deployment setting?** Recommended yes: a resolver address in the operator's configuration, with a second one for the monitor's cross-check.
3. **Rate limit shape.** A per-source token bucket in memory (stateless across restarts is acceptable at S1); the limit's numbers are decided with the first measurement of real traffic.
