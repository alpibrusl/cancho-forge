# The past defects of cancho-code replayed by M-1 (docs/self-repair.md section 11). BASE the commit the defect is present at, FIX the commit that fixed it.
BASE_A=18e735e0fb33e392a9a2af185c32006a4728af10   # cancho-code PR #99 (eb9fac5): the tests file bound an import twice
FIX_A=eb9fac5
BASE_B=0974743                                    # cancho-code PR #103 (a126d23): the plan check refused a correct plan
FIX_B=a126d23
