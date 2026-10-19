# Third-party material

None is vendored. The standard library (`std.*`) is part of the cancho
compiler this repository is built with, under the compiler's own licence
(EUPL-1.2). The compiler revision these sources were written for is pinned
in `cancho.toml`.

Cancho Code (`alpibrusl/cancho-code`, EUPL-1.2) is not vendored: Forge runs it
as a separate program and reads the files it leaves. If source is ever copied
from it, a row naming the file, the upstream commit and the licence is added
here in the same commit. The reuse and licence matrix is in
`docs/cancho-code-audit.md`, section 9.
