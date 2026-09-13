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

`checker/artifacts/module` joins that program with its original located parser
input and all per-module lowering rows. The FS coordinator persists and consumes
this artifact through `runtime/checked_module_cache` when
`VIBE_CHECKED_MODULE_CACHE` is `on`. The mode is opt-in; an empty setting or `off`
uses the existing path. `verify` always checks afresh, compares any stored module
with the new complete artifact, and sends the fresh result to codegen.

A successful reuse supplies the parser AST to merge and the typed rows to the
lowering/prelude consumers. It does not rerun inference or parse that body for
codegen. The original parser AST is retained separately because codegen owns
its desugars: replacing it with `CheckedProgram.checked_stmts` would apply some
transformations twice. Existing header discovery and whole-program link work
remain in their current phases.

These bytes establish transport integrity and exact input agreement. They do
not authenticate a producer against a party able to forge complete cache files.

## Complete program payload

| Field | Retained data |
|---|---|
| `checked_stmts` | Complete post-desugar `Array[Stmt]`: every expression, pattern, surface type, import kind, declaration field and byte offset |
| `final_env` | Every `TypeEnv` node, value type and binding origin; exact chain order, duplicates, cached indexes, mutable-cell escape facts, trait methods and generic provenance |
| `type_defs` | Every complete `TypeDef`, in original order |
| `final_subst` | Every `Subst` node, including both `SubstCached` maps, bounds and effect-variable bindings |
| `typed_occurrences` | Append-ordered `(offset, Type)` rows, including duplicate offsets |

`typed_occurrences` is what the production checker records, not a fully
elaborated typed IR. The enclosing module artifact also retains the packed lowering-offset table
and typed-equality offset/key rows that codegen reads independently of it.

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

## Module format and cache policy

`vMOD` version 1 starts with four magic bytes, a canonical unsigned version
varint, then two little-endian unsigned 32-bit checksum fields. Its payload is
an exact binary input identity, the complete located parser AST, the five
`vCHK` program fields, packed lowering offsets, equality offsets and equality
type keys. The program fields use the same codec directly, without a nested
envelope or buffer copy. Counts frame variable-length fields. The two checksums
use the arithmetic above and cover every payload byte; equality row counts must
agree, and trailing data is refused. The existing atomic `VART1` artifact store
is the outer envelope.

The encoder writes directly into one buffer and fills the fixed checksum slots
afterward. Verification compares that one encoding with stored bytes: exact
agreement with the fresh result validates them without another decode or write.
A difference is decoded to distinguish a corrupt entry (repair) from a valid
artifact that disagrees with the checker (verification failure). The AST reader
joins byte strings in bounded chunks, avoiding one allocation per byte of a
compiler bundle literal.

The input identity contains the compiler/cache version, typing semantics,
`#cfg` flags, resolution context, normalized owner path, exact source and every
resolved dependency environment in its actual order. Environments use the
complete binary codec, including cached binding indexes and provenance. The
older persistent TypeEnv text rebuilds those indexes and therefore cannot serve
as this exact identity. A compact fingerprint only chooses the lookup slot;
acceptance compares every input byte, even after a valid file is copied into a
foreign slot.

The identity excludes dependency implementation fingerprints. A private body
edit can reuse consumers whose public dependency environments stayed equal;
a public type edit invalidates the consumers whose inputs changed. The ordinary
conservative fingerprint and public TypeEnv publication remain available to
existing consumers. Comment, whitespace and doc edits change the owner's exact
source identity and refresh its AST and offsets.

Every module accepted by the enabled FS walk passes through this validation.
Old TypeEnv/sidecar-only shortcuts cannot skip it. Missing, corrupt or foreign
artifacts run the ordinary check and republish only after success. Diagnosed
modules produce no artifact. The codegen AST memo is reset per compilation,
checks exact source and context, and hands out a fresh top-level array so merge
cannot mutate another consumer's input.

Default activation and the remaining phase separation stay subject to corpus
parity and compiler-sized cost measurements. The #2510 work still owns caching
the prelude's derived tables and limiting its execution to edited modules; this
artifact already supplies its AST and checker-owned lowering inputs.

When this cache is enabled, `VIBE_INCREMENTAL_TELEMETRY_OUT` uses schema 5 and
reports `modules_reused_checked_module_artifact` separately from conservative
fingerprint and TDRE9 hits. The three reuse reasons sum to `modules_reused`.
With the cache off, schema 4 is emitted instead — the same counters without
that field. (They were 3 and 2 before #2766 added the two lane-parse counters
to both.) The edit-cycle KPI reader accepts both schemas and validates their
exact fields and sums.

**Do not enable this cache together with `VIBE_EXPERIMENTAL_AST_CACHE=1`.**
They are two AST caches for the same lane and the per-file one is redundant
here: `parse_program_with_path` serves the merge from the checked-module
artifact before the shared parse memo is consulted, so the per-file prefetch's
trees are consumed by nothing. Measured on the full CLI closure, warm, with
this cache on: `non_walk_parse_operations` is 0 either way, and turning the
per-file cache on costs **+360.7 MiB (+11.3%)**. The planner therefore skips
the per-file prefetch entirely whenever this cache is on or verifying.
The existing check-only KPI benchmark pins this cache off to preserve its
documented TDRE9 measurement; the parity gate measures checked-module reuse.

## Verification

`checker/artifacts/program/program_test.vibe` covers every semantic constructor,
a seeded checker result, restored lookup/provenance/substitution behavior,
independent wire fixtures, malformed input and fresh-versus-restored Wasm.
The existing AST binary tests cover every embedded syntax constructor.

`runtime/module_program_transport_test.vibe` checks against a dependency
environment and proves type, import, effect and parse failures retain ordinary
checker diagnostics and produce no successful transport.

`runtime/checked_module_cache/cache_test.vibe` proves actual codegen consumption,
nonzero reuse after a meaning-changing private body edit, invalidation on a
public type edit, diagnostic parity and exact input dimensions. Each execution
uses a fresh directory so a previous test cannot supply its edited variants.

`pkf run test-checked-module-cache-parity` compares Wasm bytes and complete
diagnostics for every `fixtures/typecheck/expected.tsv` row with both entry
choices, across off/verify/on modes. It requires real module publication and
canonical repair after deletion, truncation, same-length corruption, a foreign
source artifact and a cross-typing-mode artifact, in both on and verify modes.
It requires telemetry to prove that reuse skipped real checker calls, and an
invalid mode must refuse while clearing stale success telemetry.
`--units` additionally checks
every active file discovered by the unit runner. Pass `VIBE_STAGE2_WASM` to select
the freshly built compiler; the gate records its SHA-256 and retains evidence.
Both selections also repeat a compiler-import fixture after publication to
exercise warm verification with large bundle literals. The default selection
runs in the operation gate's early lane.
