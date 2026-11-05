# The model review as a step: `repo.review`

**Status: slices RV1, RV2 and RV3 built (the verdict parser, the operator `review` form check, the task type and `review_step.preflight`; the worker, offline-measured, section 5; the Forge runner `Runner::Review`, section 9). RV4 is measured once (section 5.2) and open until the review has run on the pilot's own changes.** Written before the code (`CONTRIBUTING.md`). Every claim marked *(designed)* is a proposal; one marked *(read)* was read from the source or document
named; each *measure* is a case that must exist before this document says it is true. It is step 4 of the order in [`reviewer.md`](reviewer.md) section 6, and it builds only what
that document's section 3 and section 9 allow: **a review that is recorded and shown and counts for nothing.**

**What was read** (2026-11-04, `main` at `2b748c4`): `reviewer.md` (all), `company.md` sections 9, 25 to 27, `worker-contract.md` section 13 (headings), `docs/authority.txt` (Forge `never touches the
network`), `src/company_manifest.cho` (`type_code`: `repo.authority` 5, `repo.publish` 6), `spike/r1/ask.cho` and `review.sh` (the measured call), `wc -l src/company_runner.cho` (1987 of
2000). **Not read:** where the change worker leaves the brief it was given (this document needs one file and says which), the body of `company_budget.cho`, and the Cancho Code provider
transport's TLS roots handling beyond what `ask.cho` does.

## 1. What it is, and what it is not

A reviewer-role step of a new task type **`repo.review`** (code 7) that, once a `repo.change` step is accepted, asks a model one question about it and **records the answer**. The
model sees **the brief and the diff and nothing else**: not the builder's reply, its attempts, its journal, its spend, the audit or the other steps. That is what makes it
independent, and it is enforced by what Forge puts in front of the worker, not by what the model is told.

It is **evidence, never a decision** (`reviewer.md` section 3). In this slice:

* the step is **accepted whatever the verdict**, once the verdict was obtained and was well formed;
* a `concerns` verdict is journaled and **printed with its items**, so a person sees it at the demo and in `status`, and it holds nothing;
* no policy reads it, and nothing is ever accepted or refused because of it.

This is not a limitation to remove quietly: R-1 (`reviewer.md` section 9) has two runs and a 95% upper bound near 15% on a false approval; the rule is a bound of 10%. The step that makes
the verdict *count* is a later change that cites a larger measurement from another author's seeds, and it is a different mode (section 9), not an edit of this one.

## 2. The step *(designed)*

```json
{"id": "review", "role": "reviewer", "task_type": "repo.review", "needs": ["fix"]}
```

* Role `reviewer` only (any other role: `task-type-unsupported`). It names no `repo` and takes no `check` (`repo-task-invalid`).
* It `needs` **exactly one** `repo.change` step, else `review-step-invalid` (exit 1, nothing written, not admitted). It may be listed after `qa`, `ceiling` or `pub` by naming them in `needs` as well;
  Forge adds no hidden ordering (as for `repo.publish`, `auto-publish.md` section 2). The review does **not** need the publish: the patch is what is reviewed, not the commit.
* *Ready* when the step it reviews is accepted. The runner is `Runner::Review`; its artifact is `review.json`.
* It is a **model step** for the budget (`company.md` section 9): the scheduler will not start it when the budget is exhausted, and its spend is recorded (section 6).

## 3. The grant: the operator's `review` *(designed)*

The manifest says what happens; the operator file says what is allowed (as `auto_publish`, `authority`, `checker`). A company file cannot grant itself a model call.

```json
"review": {"worker": "repo_review", "provider": "anthropic", "model": "claude-sonnet-5-5", "key_file": "/abs/path/key",
           "host": "api.anthropic.com", "max_tokens": 2048, "max_diff_bytes": 65536, "mode": "advisory"}
```

* Form-checked with the file (`operator-invalid` with a `reason:`): `worker` a file name of the workers directory; `provider` and `model` plain tokens that **the budget's price table prices**;
  `key_file` an absolute path; `host` a host name (letters, digits, `.`, `-`); `max_tokens` 1 to 8192; `max_diff_bytes` 1 to 262144; `mode` exactly `advisory` (the only value; the field exists so that the
  mode that counts is a visible, separate decision). No other key.
* No `review` in the operator file: a `repo.review` step is refused `review-not-granted` (exit 1, not admitted).
* **The key is a path, never a value.** Forge never opens `key_file`; it passes the path to the worker, which reads it inside its own authority and never prints, logs or journals it
  (the rule already applied to `ask.cho`: *measure* the worker's output and the journal for the key text in the conformance case).
* The address is resolved by the worker (it performs the lookup); nothing else about the network is configurable. (An operator-given `ip` was considered and left out of RV1: the form allows exactly the eight keys above. It is added with a measured need, not before.)
* The default model is a decision for the operator, not for this document. The measured one (R-1) is `claude-sonnet-5-5`: 4 of 63 false approvals (1 of 60 once the one seed whose request asked for the fault is set aside)
  and 5 of 63 false concerns. Haiku had 0 of 42 false approvals and 11 of 42 false concerns.

## 4. What the worker is given *(designed)*

Forge writes, in the step's execution directory and nowhere else the worker can read:

* `brief.txt`: the brief of the **reviewed change step**, exactly the file Forge wrote for the builder before it ran (the change request's title and body and the step's `input`): nothing the builder produced.
* `change.patch`: the reviewed step's `change.patch`, as Forge read and bounded it (`patch_check`). A patch over `max_diff_bytes` is not sent: `review-diff-too-large`, a step **held** (exit 14,
  `check-unavailable`, reason `review-diff-too-large`); the operator raises the bound or `decide retry:<id>`.

Both are copies Forge made, regular files, no link followed. The prompt is a **constant of the worker** (the one measured in `spike/r1/review.sh`: the instruction, the brief, the diff), its
SHA-256 is written into `review.json`, so a change of the words is a visible change of the instrument. Changing it re-opens R-1.

## 5. The worker `workers/repo_review.cho` *(designed)*

A `sync` worker of the stdio binding (`worker-contract.md` sections 1 to 4), one process per call, as `authority_review` is. Request: the verb `execute`, the grants (execution directory; the operator's `review` fields).
It reads `brief.txt` and `change.patch`, builds the request body (`anthropic.request_body`), makes **one** call through Cancho Code's provider transport (`provider.exchange`, the code `spike/r1/ask.cho` already
runs) with no retry, no tools, no thinking, and writes into the execution directory:

* `reply.txt`: the model's text, verbatim;
* `usage.jsonl`: one line `{"in":N,"out":N,"cache_write":N,"cache_read":N}` (the format `company.md` section 9 already reads);
* `report.json`: model, prompt SHA-256, byte counts, the HTTP status, nothing secret.

**It answers no verdict.** Forge parses `reply.txt` itself (section 6); the worker's claim is not read, as `ceiling.txt`/`head.txt` are recomputed for `repo.authority`.

**Authority.** The worker's authority is its own ceiling, checked in as `docs/authority-repo-review.txt` and compared by the gate, as every worker's is: `fs_read` and `file_write` of the execution directory, `fs_read` of one file
(the key), and a network connection (`net_connect`) for the provider's host. It starts **no external program**. Forge's own `docs/authority.txt` keeps `never touches the network`: **the gate fails if this slice widens it.** That is
the reason the call is a worker and not a function of Forge.

### 5.1 As built in RV2

*(read from the code, 2026-11-04.)* `workers/repo_review.cho` is edition 9 and links the provider transport **vendored verbatim** from cancho-code `6fcac18` into `vendor/cancho-code/` (`provider`, `anthropic`, `reply`, `fetch_io`; the TLS client and HTTP client are the compiler's `packages/`, found by `scripts/packages.sh`: `CANCHO_PACKAGES`, else `packages` next to the compiler, as cancho-code's `build-agent.sh` does). Editions mix in one build; `cancho check` accepts the whole. The gate builds the worker and compares its authority report with `docs/authority-repo-review.txt`: `clock`, `conn_read`, `conn_write`, `file_write`, `fs_read("")`, `fs_write("")`, `heap`, `io_read`, `io_write`, `net_out("")` **unbounded** (a host a name resolves to cannot be bounded by a report, so the host is a grant and the report says so), `poll`, `udp_recv`, `udp_send`; it does not touch the command line, signals, other programs or foreign code. **Forge's own `docs/authority.txt` is unchanged**: the worker is a separate program.

Differences from the text above, corrected here: the grants are `execution_dir` and `review` (`key_file`, `host`, `model`, `max_tokens`, `max_diff_bytes`) in the request's `grants`, and the task's `input` is empty; the task check is the pure `forge.review_prompt.check` with the codes `task-type-invalid`, `path-invalid`, `scope-invalid` and `limits-invalid`; a missing, empty or over-bound `brief.txt` or `change.patch` is `input-unreadable`; every way the model was not reached or its answer cannot be kept (key unreadable, no CA bundle, resolver unreadable, host unresolved, TLS or transport failure, a status other than 200, a reply cut at `max_tokens`, no text) is `review-unavailable` with the reason in the message. The address is resolved by a UDP query (`spike/lib/dns.cho`) to the first IPv4 `nameserver` of `/etc/resolv.conf` (`forge.review_net`), and the connection goes to that address; the CA bundle is the first of `/etc/ssl/cert.pem`, `/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt`.

**What RV2 measures and what it does not.** `scripts/check_repo_review.sh` runs the real worker offline: capabilities, each refusal of the task, each missing input, a key file it cannot read, a host that does not resolve, no file written beside the inputs, the key text in no answer and no directory, garbage on standard input is exit 4. The prompt, the usage line, the report and the status mapping are pure and unit-tested (`tests/review_prompt_test.cho`, `tests/review_net_test.cho`). **Not measured in RV2: the TLS call itself and the provider's answer** (the positive path of the resolver, the certificate check, a 200, a 429, a cut reply, the key reaching only the provider's host). That needs the provider; it is measured once, on a real change, by RV4, and the earlier text of this table row that promised a stand-in TLS server is withdrawn: a stand-in would need a test-only port and trust knob in a worker that holds a key. The contract cases with a stand-in *worker* (an approve, a `concerns`, a held review) are RV3's, on Forge's side.

### 5.2 The first real call *(measured, 2026-11-05)*

`workers/repo_review.cho` (RV2, built from this repository's `main`) was run once against the provider with `claude-haiku-5-5`, `max_tokens` 4096, on a real change: the diff of the `path+` check added to the audit's spec language (3,741 bytes of patch, 150 of brief). The key file was passed by path; it was not read by anything but the worker.

* **It works end to end**: resolve, TLS with the chain checked, the call, a 200, `reply.txt`, `usage.jsonl`, `report.json`, state `succeeded`. The positive path RV2 could not measure offline is now measured once.
* **Usage: 2,012 tokens in, 1,819 out**, no cache. At the Haiku price I assume ($1 and $5 per million tokens in and out; **not read from a price list in this run**) that is about one cent and a half. A first attempt with `max_tokens` 1024 was cut (`the reply was cut at max_tokens`, the worker's `review-unavailable`, correctly refused) and cost a little under that again. **1,819 tokens out for a 733-byte reply (about 200 tokens of text) leaves roughly 1,600 tokens that are not in the reply**: the model spends output tokens that are not in the reply (thinking-like overhead) although the worker asks for none; a ceiling of 1024 is too low for this model and 4096 is the working number. The budget line for a review must count the larger number.
* **The answer parses by reading**: one JSON object, `"verdict":"concerns"`, three items with `file`, `line`, `claim`, every string plain printable ASCII within the bounds. (Run through `forge.review_verdict` in RV3, not here.)
* **What the review was worth, read by a person**: of three concerns, one is a real if minor observation (a field path containing `+` would now be cut at the `+`; true, and no field name in the audit has one), one asks to confirm that two std functions exist (they do, the file builds and its tests pass: noise), and one asks for a test of the first (reasonable). Advisory, as designed; it found nothing that was wrong and nothing that was missed by the tests. One sample says nothing about its hit rate: R-3 stays open until the review runs on the pilot's own changes.
* **Found**: a key file under a hidden directory (`~/.config/...`) is refused `path-invalid` by the path rule (`gate_task.path_ok` refuses a component that starts with a dot). That is the right rule for the grant, and the operator's key file must live under a path without one.

## 6. What Forge does with the answer *(designed)*

1. **Spend.** The step's `usage.jsonl` is read as any model step's is, priced from the budget's price table for `provider`/`model`, and appended as `company.spend.recorded` (`company.md` section 9). A missing or
   unpriced model is `price-table-missing` before the step is admitted.
2. **Parse, by Forge, in cancho.** A pure module `review_verdict` reads `reply.txt`: it accepts one JSON object, `{"verdict":"approve"|"concerns","items":[{"file":string,"line":int,"claim":string}]}`, and
   nothing else (text around the object, a code fence, a second object, a missing key, an extra key: **unparsed**). `approve` with items, or `concerns` with none, is **unparsed**. At most 20 items; `file` 1 to 200
   bytes, `line` 0 to 10^7, `claim` 1 to 400 bytes; all printable ASCII (32 to 126) and written **plain**, with no JSON escape: a claim that quotes code with a `"` is unparsed and the step is held rather than the escape being decoded (*built*, `tests/review_verdict_test.cho`; if this holds too many good reviews, R-3 will show it as `review-unparsed` and decoding can be designed then). The text is **data**: it is never put in a command, a path, a journal key or another model's prompt.
3. **Record.** A well formed answer: Forge writes `steps/<id>/ev/review.json` (the validated object, the prompt hash, the model), hashes it, appends `company.step.reviewed` (`task` = the step, `verdict`,
   `items` count, `model`) and accepts the step (`company.step.accepted`). `concerns` prints, under the step, one line per item: `review: <file>:<line>: <claim>`.
4. **Failures are holds, not acceptances.** The model was not reached, the provider answered an error or a refusal, the reply was cut at `max_tokens`, or the reply is unparsed: the step is **held**,
   `check-unavailable`, exit 14, with the reason `review-unavailable` or `review-unparsed` in the record, never retried by `run` itself (one attempt per run, as a check); `decide retry:<id>` frees it. A
   company that needs the step is not done until a person has either a review or left the step out of the flow.

Tags *(designed)*: `review-step-invalid`, `review-not-granted`, `review-diff-too-large`, `review-unavailable`, `review-unparsed`. Each reached by a test named in the table of section 8.

## 7. Where the code goes *(designed)*

* `src/review_verdict.cho` (*built, RV1*; pure: parse and bound a reply; unit tests for every refusal above, a reply that is a fence, an extra key, a count of 21, a claim of 401 bytes, no trap on any byte string).
* `src/review_call.cho` (writes the two inputs, starts the worker, reads `reply.txt`, `usage.jsonl`, `report.json`, answers a status), by the shape of `authority_call`.
* `src/company_manifest.cho` (*built, RV1*): `TaskType::RepoReview`, `type_code` 7, role `reviewer` only (`task-type-unsupported` otherwise), `repo`, `change_kind`, `check` or `gate` on it are `repo-task-invalid`. 1913 of 2000 lines; the rules that need the graph or the operator file are in `review_step.cho`.
* `src/operator_review.cho` (*built, RV1*): the form check of `review`, with the `reason:` of `operator-invalid`; `company_step.operator_reason` joins it to the build ceilings' and the rows' reasons, so `company_runner.cho` got shorter, not longer. `src/review_step.cho` (*built, RV1*): the two tags and `preflight` (needs exactly one `repo.change` step; the operator file has a `review`).
* **`src/company_runner.cho` is at 1987 of 2000 lines (`crates/cancho/tests/files.rs` ceiling): the first commit of the runner slice moves the `repo.authority` and `repo.publish` step runners
  into a module of their own and adds nothing**, so the ceiling is not raised.
* `workers/repo_review.cho`, `docs/authority-repo-review.txt`, a section 14 of `worker-contract.md`, and a section 28 of `company.md` that says what was built.

## 8. Slices and what measures them

| Slice | Content | Measured by |
|---|---|---|
| **RV1** | `review_verdict` (pure), the `review` operator form check, `TaskType::RepoReview` and the manifest rules (`review-step-invalid`), no runner | unit: every refusal of section 6.2 and 2; `repo_row`/operator form cases; the types round-trip |
| **RV2** *(built)* | the worker, its authority report, the offline cases | `scripts/check_repo_review.sh` (section 5.1): the real worker, offline; the gate compares `docs/authority-repo-review.txt`. The provider call is RV4's |
| **RV3** | split `company_runner.cho` (no behaviour change), then `Runner::Review`, the call, the journal record, the printed items, the spend, `review-not-granted`, `review-diff-too-large` | `company_change.sh` `review:` cases with a stand-in `repo_review` worker: approve accepted; concerns accepted and printed; unparsed held 14; a diff over the bound held 14; not granted refused 1; `status` shows the verdict; the spend recorded once |
| **RV4** *(first call measured, section 5.2)* | one real run against the provider on the pilot's own change, priced and kept in `spike/RESULTS.md` as R-3 | the real worker, the real model, the cost, the result read by a person; a number, not a claim |

## 9. What this does not do, and what comes after

* It does not make the review count. A **`hold` mode** (a `concerns` verdict holds the change for a person with the items) is the second item of the policy of `autonomy.md` section 4; it is a separate
  value of `mode`, designed after a seed set from **another author** drawn from the changes the builders really propose (`reviewer.md` section 9, last paragraph), and not before.
* It does not run a second reviewer, a self-consistency vote or a model of a different family; those are measurements first.
* It does not read the builder's transcript, ever. A future version that does is a different instrument and would re-open R-1.
* It does not call any other service. One host, one request, no retry, a body bounded by `max_diff_bytes`.
* It does not send the operator's other files, the repository's other files or the company journal. The only repository content that leaves the machine is the diff the operator already allowed the
  builder to produce (`publish_allow`/`publish_deny` bound it before the review sees it) and the brief it was given. **That is still the diff leaving the machine to a third party**; it is a grant the operator
  makes in `review`, and without it there is no call.

## 10. Open questions

1. **Does a held review (`check-unavailable`) block the company from being done?** Proposed: yes, as any step; the operator leaves the step out of the flow when they do not want the dependence.
2. **Which model by default?** None: the operator names it, and the price table must price it. The measured candidate is Sonnet 5.5.
3. **A per-company cap on review spend apart from the build budget?** Proposed: no; the company's `max_cost` covers it. A review costs about $0.003 on a diff of this repository's size (R-1: $0.22 for 42 calls, priced high).
4. **Should the verdict be shown in `pr.md`?** Proposed: yes, as a clearly marked advisory block, after the authority line; a person who reads the PR sees it. Not built until RV3 has run.

## 9. RV3 as built *(measured)*

`Runner::Review` (`company_step.cho`), the step `company_review_step.review_step` and the call `review_call.run_step`, by the shape of the change step and of `repo_call`. `company_runner.cho` was split first (no behaviour change: 1,984 to 1,567 lines; the shared helpers are `company_run_io.cho`, the `repo.authority` and `repo.publish` runners `company_repo_steps.cho`). `tests/conformance/company_review.sh` runs it end to end, in the gate, against a stand-in worker (`scripts/standin_repo_review.sh`, no network): approve, concerns (accepted and every item printed), a reply that is not a verdict and one in a code fence (held `review-unparsed`, the tokens still recorded), a failed worker and a missing reply (held `review-unavailable`), a patch over the bound (held `review-diff-too-large`, the worker never called), no `review` grant, an unpriced model, and a second run that admits and calls nothing again.

What differs from the design of section 6, corrected here: **no `company.step.reviewed` record in the first cut of RV3** (the verdict was only in `review.json`). It was added as the next small slice: the record (`task` = the step, `verdict`, `items`, `model`) is appended after `review.json` is hashed and immediately before `company.step.accepted`; replay checks its shape (`approve` has no item, `concerns` has some, otherwise `event-malformed`) and keeps the last per step; `status` shows `review=approve` or `review=concerns:N` on the step's line, and `format=json` a `review` object only for a reviewed step. A held ending writes no record. `tests/company_state_test.cho` (`test_a_reviewed_record_replays_as_the_steps_verdict`, `test_a_reviewed_record_that_contradicts_itself_is_event_malformed`), `tests/company_cmd_test.cho` (`test_status_shows_the_verdict_of_a_reviewed_step_and_only_that`) and `tests/conformance/company_review.sh`. The price is read before admission as section 6 point 1 says (`price-table-missing`), for the operator's review provider and model, not the manifest's.

