# Import-kind Phase 1 integration matrix

These fixtures are staged inputs for the explicit import-kind integration
gate. They are intentionally not wired into the active fixture runner until
the parser retains item kinds in the AST.

`expected.tsv` records the Phase 1 contract. During bootstrap Phase A, `type`
is the broad data-type spelling accepted for aliases, structs, and enums;
the dedicated `struct`, `enum`, `effect`, and `trait` spellings are exact.
Narrowing `type` to aliases is deferred until the committed seed supports the
precise data-type import syntax. The matrix also covers legacy bare imports,
aliases, re-exports, and a qualified member imported alongside its owning
struct namespace.
