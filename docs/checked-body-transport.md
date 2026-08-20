# Checked body transport

Issue #1958 owns the shadow-only authority boundary for future incremental
owner reuse. No artifact described here is a production cache or reuse input.

The implementation is split into two layers:

- `CheckedImplementationBodyArtifact` retains exact ingested source, binding
  provenance, exported-interface bytes, and the successful empty-diagnostic
  identity.
- `NormalizedCheckedLeafArtifact` is the first versioned normalized typed-IR
  pilot. Its contract is strict and intentionally much smaller than the AST.
  Unsupported nodes return `None`; they are never reconstructed from source or
  approximated by name.

## V1 coverage

| Layer | Constructor or field | V1 status |
|---|---|---|
| Statement | one unannotated top-level `SLet` | supported |
| Expression | `EInt`, `EBool`, `EString`, `EUnit` | supported |
| Function | top-level `EFn`, including generic schemes and trait-bound rows; parameter names, checked return and effect row | supported pilot |
| Function body | scalar leaves, identifiers/calls, immutable/recursive/mutable lets and assignment, sequence/branch/match/handle/loops, tuple/array/record/map construction, unary/binary/dot, return/break/continue | supported pilot |
| Pattern | wild, bind, int/string/bool, constructor, tuple, struct, or-pattern | supported pilot |
| Surface type field | all current `TypeExpr` constructors, including function effects | structured pilot for explicit record arguments |
| Checked type | every current constructor, including `CtRecord`, `CtVar`, `CtForAll` bounds, and explicit `CtUnknown` | structured pilot |
| Expression | every other `Expr` constructor | fail closed |
| Statement | every other `Stmt` constructor | fail closed |
| Checked type | final environment type of a scalar `SLet` binding | canonical text retained |
| Type environment | every current `TypeEnv` constructor, exact order/duplicates/cache rows/origins, complete `TypeDef`, trait method, bound, and generic provenance fields | structured shadow transport |
| Substitution | complete lossless `Subst` | not yet supported |
| Type definitions | complete checked declaration closure | existing narrow artifact only; not yet joined |
| Occurrences | complete typed occurrence table | existing path artifact only; not yet joined |
| Docs and locations | exact source plus parser binder rows | retained by the body aggregate |
| Diagnostics | successful canonical empty typing set | retained; diagnosed builds publish nothing |

## Single-function join pilot

The shadow-only `NormalizedCheckedFunctionJoinArtifact` retains one successful
function's exact source and binder rows together with its normalized body,
structured final value binding, structured final substitution, and the
append-aligned `(offset, role, lane, Type)` occurrence rows. Construction uses
the complete expression-path observation and requires every row to belong to
the single retained statement. Missing, duplicate-offset, malformed, stale,
and cross-authority data fail closed during decoding or explicit authority
matching. `SubstCached` remains ineligible because its map representation is
an implementation cache rather than canonical substitution authority.

This pilot is not complete `TypeEnv` transport: it retains only the selected
function binding. It does not change the unsupported statuses in the table or
authorize production reuse.

The separate `NormalizedValueTypeEnvArtifact` covers every current environment
node. Unlike the production persistent-env codec, it retains module-export
origin provenance, exact flat/cached row order (including duplicates), mutable
cell escape facts, complete type-definition closures, and trait method/generic
metadata. Cached name/value length mismatches fail closed. A seeded checker
final environment is part of the round-trip fixtures. The environment remains
a separate shadow artifact; joining it into the function artifact is deferred
to a schema-version change rather than silently widening its existing v1.

## Remaining work

Before production owner reuse can be considered, a later schema version must
cover every reachable `Stmt`, `Expr`, `Pat`, and `TypeExpr` field; structured
`Type`, `TypeEnv`, `Subst`, `TypeDef`, and typed-occurrence transport; import and
mode assumptions; and cold/shadow reconstruction parity across the hostile
corpus. New constructors must make decoding or production eligibility fail
closed until their codecs and round-trip fixtures land. #1959 is the earliest
place allowed to connect a completed transport to planning or reuse.
