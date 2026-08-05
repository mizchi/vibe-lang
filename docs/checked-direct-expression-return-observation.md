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
