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
* **2026-11-05**: the board approved the `audit` gate (T6) after reading the case table. **First real model call** of the review worker (`claude-haiku-5-5`, one real diff): succeeded, 2,012 tokens in and 1,819 out, about 0.11 cent at the price in `pilot/prices.json` ($0.10 and $0.50 per million tokens; an earlier version of this line said 1.5 cents from an assumed price, corrected), the reply a valid verdict with three concerns of which one was a real minor point (`review-step.md` section 5.2). A first attempt at 1,024 output tokens was cut: the model uses far more output tokens than its reply holds.
* **2026-11-05**: RV4 on the pilot's own changes (`review-step.md` section 5.3, `spike/RESULTS.md` R-3): the five whole commits of the audit (36 to 56 KB) were **cut at the worker's maximum of 8,192 output tokens**, as was a 18 KB diff; diffs of 4 to 11 KB were answered. The review found four small true defects in work already approved (a wrong exit-code comment in `mutate.cho`, a test comparing lengths only, a mutant counted as caught when the audit crashes, a relative scratch directory), none changing a result; not fixed yet. Found and fixed on the way: a cut call left no usage record (the spend of eleven cuts is estimated, not recorded), and the prompt now tells the model not to put a double quote in a claim. About 8 cents in all, 6 of them estimated. For the pilot's builder diffs, `max_diff_bytes` near 12 KB until a model or a ceiling that fits larger ones is measured.
