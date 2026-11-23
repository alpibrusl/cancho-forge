Install cancho-forge and check it on this machine. Work in a new empty directory, keep every path free of spaces, and never use sudo. Run steps 2 to 5 in one shell session. Report honestly; do not retry a failing command in a loop and do not edit the repository to make a command pass.

1. Check that `git`, `curl`, a C compiler (`cc`), `clang` (15 or newer) and `sh` exist. If one is missing, stop and tell me which; do not install system packages on your own.

2. Get the two repositories side by side, both cloned into the new empty directory (call it the parent):
   git clone https://github.com/alpibrusl/cancho-forge.git
   git clone https://github.com/alpibrusl/cancho.git
   git -C cancho checkout "$(cat cancho-forge/.cancho-rev)"

3. Install the released compiler of that commit (a prebuilt binary, checked against its published sha256) and point at it:
   sh cancho/scripts/install.sh "$(cat cancho-forge/.cancho-rev)" "$PWD/cancho-inst"
   export CANCHO="$PWD/cancho-inst/bin/cancho"

4. Prove the install works. This needs no network, no key and no model. Start from the parent directory:
   cd cancho-forge
   sh scripts/gate.sh        # must end with: gate: PASS
   The gate runs `cancho fmt --check`, `cancho check`, `cancho test`, two file conformance programs, a kill-at-every-crash-point program, the `forge` CLI cases, the authority report and a 2,000-line file budget.

5. Run the Milestone 0 spikes. They start real child processes and write under /tmp/cancho-forge-spike (about 15 seconds):
   sh spike/run.sh
   Read the output. Find these in it and show me the lines:
   - the five ways a worker can end (`normal`, `reports fail`, `garbage`, `exit 3`, `hang`) and how each was classified;
   - the journal lines: the torn tail being cut (`file_bytes=165` then `140`), and `REFUSED: complete line(s) that are not the next event; file left untouched`;
   - `lock by second writer (must fail): FAILED errno 11`.

6. Tell me, briefly:
   - whether the gate printed `gate: PASS`, and how many tests it ran;
   - the lines asked for in step 5;
   - anything that failed, with the exact error.
Nothing here runs a company yet: this is Milestone 0 and the first part of Milestone 1. Docs: README.md, spike/RESULTS.md (what was measured), docs/cancho-code-audit.md (the real interface of cancho-code), docs/architecture.md.
