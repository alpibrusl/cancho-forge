# The pilot company: one concrete business to measure progress toward an autonomous company

> **Status: design, nothing built, nothing measured about the company.** Every proposal below is *(designed)*. Statements about what exists were read from the
> sources named and are marked *(read)*; numbers about the market, prices and demand are **assumptions** and are marked *(assumed)*; nothing was run for this
> document, no model was called and no money was spent. If this document and the code disagree, the code is right and this document is corrected in place.
>
> **What was read** (2026-11-02): cancho-forge `main` at `1ccf372` (`docs/company-lifecycle.md`, `docs/company.md` sections 14 to 24, `docs/autonomy.md`,
> `docs/roadmap.md` M6 and M7, `docs/threat-model.md` section 4, `docs/isolation.md` headings, `spike/RESULTS.md`); alpibrusl/cancho-industrial `main` (the root
> README and `platform/README.md`, through the GitHub API; **no source of it was run**). **Not read:** the other cancho packages named in section 7
> (`cancho-web`, `cancho-schema`, `cancho-ui`, `cancho-mqtt`, `cancho-gateway`), anything about hosting providers or payment providers beyond general knowledge.

## 1. Why a pilot, and what it must answer

Forge has been built in the order of its design documents: the company layer, work on an existing repository, change requests, flows, a publish of a patch, the day and
the budgets. Each piece is tested against stand-ins and none has been used for something a person would pay for. The first real use (cancho-diff) ended with a person
turning the build into a library by hand, and a library with no buyer cannot test the stages that make a company a company: finding users, taking money, running a
service, answering customers, deciding what to do next.

So the pilot is **one small company that sells something, with every function of a company present**, and a scoreboard that says, per function and per week, how
much of it ran without a person. The question it answers is not "does the product make money" (that is upside) but **"how much of a real company's weekly work does
Forge do correctly, at what cost, and what stops it doing more"**. Its output is a table (section 5) and a list of what the next piece of Forge must be.

## 2. The company

**Working name: `upcheck`.** It sells availability monitoring to small software teams, in four stages, each of which adds state and functions. The stages are the
growth path: a company that cannot run stage 1 unattended is not ready for stage 2.

| Stage | Product | New things it forces | Exit criterion (measured, section 6) |
|---|---|---|---|
| **S1** | A free, stateless checker on the web and as an API: give a URL, get status, latency, TLS certificate expiry and DNS answers, from our servers | a site, a deploy, abuse controls, content that brings visitors, an own-status monitor | the checker runs a month with its own monitor green, and a change request goes from report to a deployed fix with a person only at the demo |
| **S2** | A paid API tier: keys, rate limits, a subscription through a hosted payments provider | billing, refunds, support, terms and privacy, price experiments | the first real payment in test mode is reconciled by the finance function; then one in live mode, approved by a person |
| **S3** | Scheduled monitoring and alerts for a customer's URLs | state (monitors, results, incidents), on-call logic, verified ownership of a monitored domain, data export and erasure | an incident the company causes itself is detected by its own monitor, communicated and closed without a person |
| **S4** | Hosted status pages and subscriber notices | design themes, a customer feedback loop, usage-driven roadmap | the roadmap of a quarter is proposed by the company from its own numbers and admitted by a person |

*Why this product (designed, reasoned, not proven):* a monitoring product exercises every function; the company monitors itself with its own product (dogfooding is
the monitoring function's work); correctness has a strong independent judge (probe and alert logic against fake servers the builder never sees: slow, down, a bad
certificate, flapping, a redirect loop); acquisition is by content that can be written, published and measured; money has a clean path through a hosted checkout;
and S1 needs no state of its own. **What it is not:** evidence of a market. The market for such tools is crowded and the demand for free checkers is *(assumed)*;
measurement M-P1 (section 10) tests it before anything is built for S2.

## 3. The functions: the organisation of the company

A function is a set of recurring work with an owner, inputs, outputs and a judge. In Forge's terms a function is **flows and Intents, executed by the existing
roles** (builder, qa, analyst, reviewer, writer, product: what authority a worker has) rather than six new roles. Which function runs which flow is the company
manifest's business. *(Open question 1 asks whether that is enough.)*

| Function | What it does for `upcheck` | Forge mechanism it would use | What it needs that Forge lacks | What stays a person's |
|---|---|---|---|---|
| **CEO / strategy** | weekly review: read the numbers, propose the quarter's goals, split the budget between functions, decide pricing experiments | an Intent per goal (`intents.md`), `goals.json` (lifecycle 6.3), a weekly flow of analyst and product steps | the strategy loop (roadmap M7), goals and signals (lifecycle slices 7 and 12) | admitting goals and budget; the board is a person |
| **Product** | turn feedback and numbers into briefs, contracts and audit cases; own the backlog | product role steps, `change add`, `admit:` | issue intake (slice 7); audit growth (slice 3) | the brief for anything new; the contract and the audit are a person's file today |
| **Design** | brand, the site and the checker's page, themes, accessibility | a builder step with a design brief; the check is automated (accessibility, rendering, size budgets) plus a person at the demo | a check for design that is not a person's eye; a repository kind for a site | taste: approval at the demo |
| **Dev** | build and change the checker, the API, the platform | builder and `repo.change`, derived steps, the publish of a patch | measured model quality (M-1); the demo gate and merge by policy (autonomy steps 3 to 6) | merge, until the policy is argued |
| **QA / security review** | held-out audit of probes and alerts; review of every change by an authority that is not the builder; abuse review | qa and reviewer steps; `audit/regress/` | reviewer distinct from qa (autonomy step 2); audit growth (slice 3); an adversarial corpus (M-4) | the threat model's changes |
| **DevOps / SRE** | deploy, roll back, keep the service up, rotate secrets, patch the host | deploy to staging then prod, probes, rollback (lifecycle section 5) | isolation Layers 0 and 1, then the deploy slices (9 to 11), then signals (12) | the adapter's credential; spend; the first deploy |
| **Monitoring / on-call** | run the company's own monitor, open incidents, page, write the post-incident note | signals and alerts becoming candidate changes (lifecycle section 6); its own product from S3 | signals and `observe` (slice 12) | admitting an incident's repair; paging a person for anything beyond a retry |
| **Marketing / content** | publish tutorials and comparison pages for the searches the free tool answers; changelog; social posts; measure traffic and signups | writer steps with a check against facts (no claim the product cannot meet), publish to the site repository; analyst steps over exported analytics | a content check; a way to read analytics as a file; a repository kind for a site | the claim policy; anything paid (ads) |
| **Sales (self-serve)** | the pricing page, trial flow, answers to pre-sales questions | writer plus product steps; the payment provider's hosted pages | none beyond billing | custom deals |
| **Support** | answer customer reports, classify, reproduce, turn into changes, close the loop | intake (issues, email as files), product and writer steps, `change add` | issue intake (slice 7); a way to send a reply (a network act: section 8) | refunds above the cap; anything legal |
| **Finance** | reconcile payments, track revenue and costs (tokens, hosting, provider fees), margin, runway; forecast; report | analyst steps over the provider's exports; the budget caps (lifecycle 2.3) | a profit-and-loss view as a journal-derived file; payments (section 8) | tax, filings, the bank, the accountant |
| **Legal / compliance** | terms, privacy, data-processing text, abuse policy, erasure requests | writer steps from a lawyer's templates; `forget` and erasure on request | erasure that reaches the platform's data (section 7) | the content of every legal text, and acceptance of it |

## 4. What the company may do on its own, and what needs a person

A rule per class of act, in the style of `autonomy.md` section 7. **Nothing here widens Forge's authority report until the slice that builds it says so in its
commit.**

| Act | Autonomous | Needs a recorded human decision |
|---|---|---|
| change code, tests, docs, content in an owned repository | yes, through checks | merge (until the policy exists), anything outside `publish_allow` |
| deploy to staging | yes | |
| deploy to production | | the demo of the release, hash-bound (lifecycle 5.2) |
| roll back to the last verified release | yes, once per release | after that, the freeze |
| spend tokens | within the caps (lifecycle 2.3, section 6 below) | raising a cap |
| spend money outside tokens (hosting, domains, tools, ads) | | every act, until a capped allowance exists (open question 4) |
| take a payment | the provider does; Forge only reads the result | switching live mode on |
| refund | up to a cap per day, if the allowance exists | above the cap |
| change a price | | always |
| send a message to a customer | templated replies for classes the person approved | anything else |
| publish content | within the claim policy | a claim outside it |
| accept a legal text, a provider's terms, a data request with legal effect | | always |

## 5. The scoreboard: where each function is today

One line per function, one status: **missing** (nothing), **stand-in** (built and tested against stand-ins only), **real** (run with a real model or a real
service at least once), **measured** (run N times with numbers recorded in `spike/RESULTS.md` or `docs/pilot-results.md`). This table is updated in the commit that changes
a status, and a status never moves up without the evidence being named.

| Function | Status (2026-11-02) | Evidence and what is missing |
|---|---|---|
| Dev | **stand-in** | `repo.change`, flows, derived steps, patch publish: `company.md` sections 16 to 21. M-1 prepared, not run (`spike/RESULTS.md`): the tool refuses a 1.1 MB repository |
| QA | **real** | the gate runner on real repositories (self-hosting Stage 1); no held-out audit growth |
| Reviewer | **missing** | same task type as qa; no authority comparison (autonomy step 2) |
| Product | **stand-in** | `change add`, `admit:`; no intake from users, no audit growth |
| Design | **missing** | no site repository kind, no design check |
| DevOps | **missing** | design only: lifecycle section 5, `isolation.md` |
| Monitoring | **missing** | design only: lifecycle section 6 |
| Marketing | **missing** | the writer role has no behaviour of its own; no analytics input |
| Sales | **missing** | |
| Support | **missing** | no intake |
| Finance | **missing** | budget caps exist for tokens only (`company.md` sections 22 to 24) |
| Legal | **missing** | |
| CEO | **missing** | roadmap M7 |

## 6. Measures

All integers, all derived from the company journal or from files the operator puts in a step's directory (`intents.md` section 4), none from a clock Forge reads.

| Measure | Definition |
|---|---|
| **Autonomy ratio** | of the steps of a scenario (section 9), the number accepted with no person decision between the trigger and the demo, over all steps; per function and overall |
| **Correctness** | of the changes accepted, the number that passes a held-out judge the builder never saw, over all accepted (M-1's judge, section 10) |
| **Cost per change** | recorded token cost of a change's steps (`company.md` section 23), plus hosting attributable to it |
| **Lead time** | days between `company.change.proposed` and the release that carries it (needs part A's days) |
| **Incident minutes** | minutes the company's own checker was down or wrong, from its own monitor |
| **Acquisition** | visits to the free tool, signups, paid conversions per week (integers read from exported analytics) |
| **Revenue, cost, margin** | revenue from the provider's export; cost = tokens + hosting + provider fees; margin in cents |
| **Support latency** | days from a customer report to its reply and to its fix |

A function's status moves to **measured** only after its scenarios (section 9) have run at least five times with these recorded.

## 7. The platform base: what `cancho-industrial` already gives, and what it does not

*(read, from the READMEs.)* `cancho-industrial/platform` is one program written in cancho on `cancho-web` and `cancho-schema`: **tenants, devices and readings over
HTTP**, with a stored-at time on every reading, device keys shown once, **EdDSA scoped tokens with a no-escalation rule**, an audit trail, personal-data export and
erasure, a live stream of readings, an ingest from the broker, an operator console in `cancho-ui`, a catalogue of refusal rules with stable names and repairs
(`GET /introspect`), and a mutant suite and an authority report kept in the gate. It persists to a state directory as snapshots, and it is bounded per table.

| `upcheck` needs (S3 and S4) | `platform` has |
|---|---|
| customers | tenants |
| a monitor, and a probe | devices |
| a check result with its time | a reading, with the time the platform stored it |
| API keys with scopes, rate-limited | device keys, scoped tokens, the no-escalation rule |
| erasure and export on request | `erase`, export |
| a customer-visible live view | the stream and the console |
| an audit trail for support and finance | the ledger |
| stable error names for customers and for the support function | the rule catalogue |

**Not there, and needed:** the probes themselves; scheduling; alert rules and notifications; billing and a link between a tenant and a subscription; rate limiting per
key; status-page rendering; durable storage beyond a snapshot (its own README calls it a proof of concept); anything deployed. The licence is EUPL-1.2 (copyleft),
which constrains how its code may be reused in a product (open question 6).

**Proposal:** S1 does not need it (stateless). From S3 the platform is the backend `upcheck` starts from, as a repository the company owns (a fork or a vendored copy, open
question 6), and its first changes are the company's first `repo.change` work on a real stateful codebase, judged by its own mutant suite, which is a held-out oracle of the
kind Forge wants. This also gives the pilot its first test of the "stateful service" kind that the lifecycle design refuses today (`stateless: true`, section 5.6 there):
the pilot is where that refusal gets argued.

## 8. Money, customers and abuse: what changes in the threat model

`threat-model.md` section 4 says payments, contracts and hosting for third parties have "no capability". A company that sells needs a narrow, capped, recorded version of each,
and this is the document that argues it. **None of it is built, and nothing below is a licence to build without the slice that adds it saying so in its commit.**

1. **Payments** (designed). A hosted checkout provider holds the card data; Forge never sees it and never holds a payment secret. A merchant-of-record provider also takes sales
   tax off the company. Forge's side is two things: **reading** the provider's exports as files (finance and analytics), and **a webhook receiver** inside the product that verifies
   a signature and records "tenant T is paid until D" (stateful: from S2). **Test mode first**; live mode is a person's decision. Refunds and price changes are acts of section 4.
2. **Network acts.** Replying to a customer, publishing a post, calling a provider are acts that leave the machine. The design's rule holds: a separately granted, human-gated
   capability per class (`net(...)` narrowed to named hosts, lifecycle section 7.1), reported in the authority diff.
3. **Abuse.** A service that probes URLs a stranger names can be turned on a third party or on our own network. Controls designed before S1 is deployed: refuse private,
   loopback and link-local targets and the cloud metadata address, after resolving and again after every redirect; a hard rate limit per source; at most N redirects; a response
   size cap; a fixed user agent that names the company and an abuse contact; a denylist the operator edits; and for **scheduled** monitoring (S3) proof of ownership of the domain
   before the first probe. The checker's egress runs in the isolation of `isolation.md` (Layer 1 at least, and the deploy slices depend on it anyway).
4. **Personal data.** A check result can carry a URL with a token in it. The platform's erasure and export are the base; the journal keeps hashes and never request text
   (`company-lifecycle.md` section 2.2 says the same of change requests).
5. **Terms and privacy** are a person's texts, written from a lawyer's templates, accepted by a person; the company only publishes them.

## 9. The scenarios: a week in the life, seeded

The scoreboard is filled by running scripted weeks. A scenario is a trigger (a file in `intake/` or a call), the functions it should engage, the artefacts it should leave
and a judge. The seeded set, each run at least five times before a function is called measured:

| # | Trigger | Functions | Judge |
|---|---|---|---|
| 1 | a bug report: the checker says a valid certificate has expired | support, product, dev, qa, reviewer, devops | a repro red on the base, a fix green, the review distinct from the builder, staging verified, one demo |
| 2 | the checker answers wrongly for a redirect loop | qa, dev | the held-out loop case fails before and passes after |
| 3 | a traffic spike doubles hosting cost | monitoring, finance, devops, ceo | an alert, a cost line in the weekly review, a proposal (rate limit or cap) a person admits |
| 4 | a customer asks for a refund | support, finance | within the cap: done and reconciled; above it: held for a person |
| 5 | a deploy fails its probes | devops, monitoring | one automatic rollback, an incident note, a bug change with the failing probe as its repro |
| 6 | an abuse report: our checker was used against a third party | security, support, dev, legal | the offending target class blocked, the report answered with the policy text |
| 7 | a competitor ships a feature | ceo, product, marketing | a proposal with the numbers, not an immediate build; admitted or rejected by a person |
| 8 | the week's content: two posts for searches the free tool answers | marketing, design, qa | each post passes the claim check; the site builds; traffic is read the next week |
| 9 | a price change proposal | ceo, finance, marketing | held for a person, with the projected effect from the numbers |
| 10 | an erasure request | legal, devops, dev | the tenant's data gone, the proof written, the journal untouched |
| 11 | a dependency (compiler pin) bump | dev, qa | the pin task of `autonomy.md` section 5 |
| 12 | the quarterly review | ceo, finance, product | goals proposed from the numbers; a person admits |

## 10. The order of work the pilot forces, and what to measure first

The pilot reorders the roadmap by what a scenario needs. The first column is the smallest set that makes S1 a real company.

| Order | Piece | Needed by scenario | Notes |
|---|---|---|---|
| 1 | **M-1** (can a Haiku-class builder write a patch against existing code?), narrowed replay | 1, 2 | harness in `spike/m1/`; needs a key file and a ceiling; asks the tool for a path scope |
| 2 | **M-P1**: is there demand for the free tool? | | a person's measurement with a landing page and a counter, before S2 is designed in detail |
| 3 | slice 3: repro step, `audit/regress/` | 1, 2 | the audit is the product's oracle |
| 4 | reviewer distinct from qa (autonomy step 2) | 1 | |
| 5 | the site repository kind, the writer's claim check, analytics as a file | 8 | |
| 6 | isolation Layers 0 and 1 | 5, 6 | hard precondition of any deploy (lifecycle 7.3) |
| 7 | deploy to staging, probes, rollback; the demo gate and hash binding | 1, 5 | lifecycle slices 8 to 11 |
| 8 | signals and alerts, issue intake, goals | 3, 6, 12 | lifecycle slices 7 and 12 |
| 9 | payments (section 8), the stateful kind, the platform fork | 4, 9, S2 and S3 | argued in its own design before it is built |

## 11. Open questions for the maintainer

1. **Functions as flows and roles, or as roles?** Recommendation: flows over the six roles, owner by manifest. Revisit when two functions need different authority for the same task type.
2. **Name, domain and legal entity.** The pilot needs a name that can be registered, a domain, and an entity that can hold a payment account. None is chosen.
3. **Who is the board,** and what do they approve weekly? Recommendation: one person, one demo a week, the decisions of section 4.
4. **A capped allowance for spend outside tokens** (hosting, domains, tools): a monthly figure the company may spend without asking, recorded as `allowance` in the operator file? Recommendation: none until S1 is deployed.
5. **When may live payments start,** and who flips it? Recommendation: after S2's test-mode reconciliation passes five weeks running.
6. **The platform:** fork or vendor `cancho-industrial/platform` (EUPL-1.2 is copyleft), or write the stateful part fresh? Recommendation: fork it as an owned repository and keep its licence; revisit if a customer cannot accept copyleft.
7. **Hosting provider** for staging and prod, and who holds the first credential.
8. **Do we keep the product this way if M-P1 says no demand?** Recommendation: yes for S1 (the pilot's value is the company, not the revenue); no for S2 and beyond until demand is measured.

## 12. What this document does not do

It does not show that anyone would pay for `upcheck`, choose a price, pick a payment or hosting provider, or settle the legal form. It does not widen any authority: every capability it
names is built, if at all, by a slice that reports it. It does not say Forge can run any function today: section 5 says which can, and the answer is mostly no. It exists so that the
next piece of Forge is chosen by a scenario that fails, and so that "how far are we from an autonomous company" has a table for an answer.
