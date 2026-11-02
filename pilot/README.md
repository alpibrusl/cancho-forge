# pilot/

Fixtures of the pilot company (docs/pilot.md, docs/pilot-s1.md). **Not a company directory**: a company directory holds a journal and the evidence of its steps, which are the
operator's and live outside every repository (docs/company.md section 2). To start the pilot, make a directory for it, copy `company.json` and `prices.json` into it, and put beside them
the files the manifest names and this repository does not hold yet: `contract.cho` (a person's file), `audit_checker.sh` and the test world it runs (the held-out audit).

| file | what |
|---|---|
| `brand.json` | the **only** place the brand is written. Changing the name is a change to this file and to the text the site build takes from it |
| `company.json` | the manifest of stage 1; `forge company check pilot/company.json` validates it |
| `prices.json` | a copy of cancho-code's `eval/prices.json` (fetched 2026-10-14 there); re-check before quoting a cost |
