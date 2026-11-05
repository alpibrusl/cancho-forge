# Pilot results: the scoreboard and the log

> The scoreboard of [`pilot.md`](pilot.md) section 5, kept current, and a log of what each run found. A status moves up only with the evidence named in the same commit. Dates are the days the evidence was produced.

## Scoreboard

| Function | Status | Since | Evidence |
|---|---|---|---|
| Dev | stand-in | 2026-11-02 | `company.md` sections 16 to 21; M-1 prepared, not run (`spike/RESULTS.md`) |
| QA | real | 2026-11-02 | the gate runner on real repositories (`self-hosting.md` Stage 1); the held-out audit is built and checked (reference 77/77, 49 mutants caught: `pilot-audit.md`), not yet run on a candidate |
| Reviewer | missing | | no authority comparison (`autonomy.md` step 2) |
| Product | stand-in | 2026-11-02 | `change add`, `admit:`; the pilot manifest is valid (`pilot/company.json`) |
| Design | missing | | |
| DevOps | missing | | |
| Monitoring | missing | | |
| Marketing | missing | | |
| Sales | missing | | |
| Support | missing | | |
| Finance | missing | | |
| Legal | missing | | |
| CEO | missing | | |

## Log

* **2026-11-02**: the pilot is designed (`pilot.md`, `pilot-s1.md`). Nothing has run. The name is provisional (`pilot/brand.json`); the domain is not bought.
* **2026-11-02**: spikes P1 to P4 (`spike/RESULTS.md`): resolution, TLS verification with a gap (no `notAfter`), a client that connects to a checked address, a hostile test world (17 cases, in the gate). No function changes status: the spikes are capabilities, not functions.
* **2026-11-05**: the held-out audit's test world is built (`pilot-audit.md` sections 3 to 5.2): 77 cases, a reference checker as witness that scores **77/77**, and **49 one-fault mutants, all caught** (the first pass caught 45; the four misses were the audit's own holes and are closed). Cost: the reference through all 77 cases, build included, takes **236 s** on a Mac; the 49 mutants about 6 minutes; the Linux CI gate of the PR that added the reference ran **18m48s** (it was 9 to 10 minutes before the audit), the growth being the audit's stanzas. Not claimed and so not tested: the rate limit's 60 s window, the exact byte of the body cap, the 8 s limit to the millisecond, a public address being accepted. No model has built anything yet.
