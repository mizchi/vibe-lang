# Checked direct expression return observation

`@vibe/compiler/checker` exposes an opt-in
`CheckedDirectExpressionReturnObservation` for compiler-internal consumers.

`Some` means that every retained post-desugar expression coordinate in the
bounded `core::expr_children` structural preorder received exactly one direct,
Primary checker-returned type. It is complete-or-none: skipped children,
synthetic rewrites, auxiliary rechecks, duplicate or missing frames, malformed
structure, and bounded traversal exhaustion return `None`.

The observation does not re-check expressions or infer skipped types. Its type
accessor and deterministic snapshot canonicalize raw returns only after a
successful checker run using that run's final substitution. It is not typed IR,
a source-offset/binding table, artifact, codec, cache/reuse input, import
contract, interface, or trace.

## Strict artifact v1

`CheckedDirectExpressionReturnArtifact` is an opaque, opt-in transport built
only from that observation. Its retained preorder rows are exactly
`(statement_path, expression_path, canonical_type_text)`. The builder
independently reconciles every row with the observation's retained checked
program and shared expression-structure authority before copying paths and
freezing final-substitution type text; any missing, duplicate, unmapped, or
misaligned row returns `None`.

The canonical marker is `vibe-checked-direct-expression-return-artifact:v1\n`.
The decoder is strict and accepts canonical length-delimited rows (including
zero rows) only. Decoded payloads attest neither a successful checker run nor
canonical-type or full typed-IR semantics; the artifact is not a cache/reuse,
import, interface, or trace contract.

## Expression-kind direct-return artifact v1

`CheckedExpressionKindDirectReturnArtifact` is a separate opaque, opt-in,
complete-or-none join built **only** from one
`CheckedDirectExpressionReturnObservation`. Its rows are exactly
`(statement_path, expression_path, closed_expr_constructor_kind,
canonical_direct_return_type_text)` in the shared retained post-desugar
preorder. The builder walks that observation's embedded
`checked_program.checked_stmts` with the shared structural authority, then
requires count and coordinate equality for every direct-return row before it
copies the authority kind and canonicalizes raw types with that same run's
`final_subst`. Missing, duplicate, unmapped, or misaligned rows fail closed;
it never combines independently decoded artifacts or checker runs.

The exact marker is
`vibe-checked-expression-kind-direct-return-artifact:v1\n`. The strict,
length-delimited codec accepts only canonical counts, lengths, paths, and one
of the 33 closed `Expr` constructor tags; type text itself remains arbitrary
opaque exact text. Zero rows are canonical. Decoded bytes attest neither
checker success nor canonical type semantics, universal expression typing,
full typed IR, provenance, binding/resolution, source identity, diagnostics,
cache/reuse/import/interface/trace.
