# Stale-artifact fixtures

`pre_tilde_playground.wasm` is the exact `playground/public/tree-sitter-vibe.wasm`
that was committed before #2422 rebuilt it — the artifact that actually shipped
stale after #2403 added prefix `~` to `grammar.js` and could regenerate only the
C parser.

It is the red-test input for `scripts/check_treesitter_wasm_corpus.sh`. Parsing
`~5` with it gives:

```
(source_file (ERROR) (expression_statement (primary_expression (integer))))
```

where `test/corpus/expressions.txt` records:

```
(source_file (expression_statement (unary_expression operand: (primary_expression (integer)))))
```

It is committed rather than read out of git history because the self-test must
not depend on how the repository was cloned. It first read `HEAD~1`, which works
locally and fails on CI's shallow checkout — a gate failing for a reason
unrelated to the property it checks (#2252), which is what that self-test
exists to prevent in others.

**Never regenerate this file.** Its value is that it is stale; a rebuilt copy
would parse `~` correctly and the red test would silently stop proving
anything.
