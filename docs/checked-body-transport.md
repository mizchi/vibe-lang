# Checked body transport

Issue #2505 owns the boundary between module checking and code generation.
`checker/artifacts/program` transports the complete current `CheckedProgram`.
Decoding reconstructs values directly from bytes: it neither parses source nor
reruns inference, and no current syntax or semantic constructor is omitted.

`runtime.check_module_with_program_transport(job)` returns the ordinary
`ModuleOutcome` together with bytes from that same successful checker invocation,
using the job's actual dependency environments. Diagnosed modules return no
bytes; parse failures propagate unchanged. Ordinary `check_module` does not
construct this transport.

These bytes are **transport, not evidence that a module is reusable**. A decoder
cannot establish that bytes came from a successful producer. Persistent storage,
current-input validation and production cache consumption are not connected to
this format yet.

## Complete program payload

| Field | Retained data |
|---|---|
| `checked_stmts` | Complete post-desugar `Array[Stmt]`: every expression, pattern, surface type, import kind, declaration field and byte offset |
| `final_env` | Every `TypeEnv` node, value type and binding origin; exact chain order, duplicates, cached indexes, mutable-cell escape facts, trait methods and generic provenance |
| `type_defs` | Every complete `TypeDef`, in original order |
| `final_subst` | Every `Subst` node, including both `SubstCached` maps, bounds and effect-variable bindings |
| `typed_occurrences` | Append-ordered `(offset, Type)` rows, including duplicate offsets |

`typed_occurrences` is what the production checker records, not a fully
elaborated typed IR. Additional lowering channels, including typed-equality
keys, must join the enclosing module artifact before it can replace all
codegen inputs.

Syntax trees use the existing [AST Binary ABI](ast_binary_abi.md), including
exact IEEE-754 float bits. There is no second syntax codec.

## Wire format: `vCHK` version 1

Four bytes `vCHK`, unsigned canonical LEB128 version `1`, two unsigned checksum
values, then the five fields in table order. The AST field includes its `vAST`
header. Arrays encode a count followed by elements; tuples and structs retain
field order. Primitive encodings and checked readers come from the AST codec.

Checksums cover every payload byte using the codegen body cache's arithmetic:
seeds `17` and `29`, multipliers `131` and `137`, moduli `2147483647` and
`2147483629`. They detect corruption, not producer authenticity or freshness.

Semantic tags are one byte. Existing tags and field order are fixed; changing
payload shape requires a new version.

| Tree | Tags in order, starting at 1 |
|---|---|
| `Type` | `CtInt`, `CtDouble`, `CtBool`, `CtString`, `CtChar`, `CtUnit`, `CtTuple`, `CtArray`, `CtOption`, `CtFn`, `CtEnum`, `CtStruct`, `CtBytes`, `CtNamed`, `CtConstructor`, `CtApplied`, `CtVar`, `CtForAll`, `CtUnknown`, `CtRecord` |
| `TypeDef` | `TDEnum`, `TDStruct`, `TDAlias`, `TDEffect`, `TDEffectSet` |
| `BindingOrigin` | `BindingOriginUnavailable`, `BindingOriginModuleExport`, `BindingOriginReExportSurface` |
| `TypeEnv` | `EnvEmpty`, `EnvBind`, `EnvTraitDef`, `EnvTraitImpl`, `EnvTraitImplGen`, `EnvTypeDefs`, `EnvMutCell`, `EnvFlat`, `EnvCached` |
| `Subst` | `SubstEmpty`, `SubstBind`, `SubstBound`, `SubstCached`, `SubstEffBind` |

`EnvValueBinding` encodes its type then origin. Substitution maps encode entries
in `Map::keys` order. Duplicate map keys are malformed; duplicate environment
rows and occurrence offsets remain intact. `EnvCached` name/value counts must
agree. Unsupported versions, unknown tags, invalid primitives, truncation,
checksum mismatch, inconsistent indexes and trailing bytes return `None`.
Writers match every constructor explicitly; extending an enum requires updating
its codec and conformance tests.

## Source and identity boundaries

Source text is outside `CheckedProgram`. The existing
`CheckedImplementationBodyArtifact` retains exact ingested source, including
comments, docs and whitespace, plus parser-authoritative binder rows. Its narrow
normalized leaf/function observation formats remain separate APIs; their
coverage limits do not constrain `vCHK`.

For reusable modules, exact source remains an input identity: comments and
whitespace invalidate the stored body and locations. Exported-interface identity
must describe typed public declarations independently of private bodies. Source
or full program bytes must never stand in for public identity. Docs and positions
must refresh even when the typed public interface is unchanged.

The remaining #2505 integration must bind program, source/binder data, public
interface, dependency assumptions, mode and lowering tables in one validated
module artifact. Fresh and transported builds must agree on output **and
diagnostics** across the full corpus before production reuse is enabled.
Missing, stale, cross-mode or corrupt artifacts must fall back to checking.
The per-module prelude (#2510) then consumes the artifact's tables.

## Verification

`checker/artifacts/program/program_test.vibe` covers every semantic constructor,
a seeded checker result, restored lookup/provenance/substitution behavior,
independent wire fixtures, malformed input and fresh-versus-restored Wasm.
The existing AST binary tests cover every embedded syntax constructor.

`runtime/module_program_transport_test.vibe` checks against a dependency
environment and proves type, import, effect and parse failures retain ordinary
checker diagnostics and produce no successful transport.
