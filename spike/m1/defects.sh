# The past defects of cancho-code replayed by M-1 (docs/self-repair.md section 11). BASE the commit the defect is present at, FIX the commit that fixed it.
BASE_A=18e735e0fb33e392a9a2af185c32006a4728af10   # cancho-code PR #99 (eb9fac5): the tests file bound an import twice
FIX_A=eb9fac5
BASE_B=0974743                                    # cancho-code PR #103 (a126d23): the plan check refused a correct plan
FIX_B=a126d23

# The narrowed trees (M-1 step 2, docs/spike/RESULTS.md): `cancho-build --repo` shows the model every .cho of src/ and tests/ up to 400,000 bytes, and cancho-code holds
# 1,110,491, so each replay is run on a copy cut to the files the fix touches, what they import (the import closure of src/) and what the repository's own test for the
# defect needs. An UPPER BOUND on what the tool can do on the real repository, since the model is shown only the relevant files.
NARROW_B="src/plan.cho tests/programs/plancheck.cho scripts/test-plan.sh tests/plans"
NARROW_A="src/acceptance.cho src/checker.cho src/driver.cho src/loop_check.cho src/parallel.cho src/plan.cho src/pool.cho src/project.cho src/signature.cho src/snapshot.cho src/splice.cho src/trail.cho tests/programs/project.cho scripts/test-project.sh tests/project"
