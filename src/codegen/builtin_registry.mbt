///|
/// Phase B (Issue #415) skeleton: a single registry table that describes
/// every builtin with its parity between the linear and wasm-gc backends.
///
/// This file is intentionally empty of dispatch logic — Phase B-0 only
/// introduces the shape. Phase B-1 will migrate namespaces (Array → Bytes
/// → Map → String → Int/Char/Float) one PR at a time, replacing the
/// match arms in `wasm_codegen_builtin_*.mbt` and `wasm_gc_codegen.mbt`
/// with `find_builtin(name)` lookups.
///
/// Background: the dual-codegen problem (wasm-linear + wasm-gc
/// maintained in parallel) is the biggest structural complexity in
/// `src/codegen/`. As of Phase B-1 this table owns the **parity
/// contract**: every core-namespace divergence between the two backends
/// is recorded here as a typed entry, and the registry-driven gate
/// `src/tests/codegen_parity_test.mbt` fails `pkf run test` /
/// release-check on any divergence the source scan finds but the table
/// does not declare. This replaced the regex+plain-text allowlist
/// (`scripts/codegen_parity_allowlist.txt`, now removed). Phase B-2 will
/// extend each entry with `compile_linear` / `compile_gc` fns so the two
/// big match statements collapse into a table lookup.

///|
/// Why a builtin is implemented for only one of the two backends. Used as
/// the typed source of truth for the codegen parity gate
/// (`src/tests/codegen_parity_test.mbt`): a core-namespace divergence is
/// only accepted when a `BuiltinDecl` records it here with a reason.
pub(all) enum DivergenceReason {
  /// The missing backend reaches the same behavior through the prelude /
  /// fallback path rather than a dedicated codegen arm. The name only
  /// shows up in one backend's source scan, but user code still works on
  /// both (e.g. `String::compare` has a single-pass linear arm while
  /// wasm-gc falls back to the prelude implementation; the native float
  /// math ops are the mirror case).
  PreludeFallback
  /// WASI P1 host import — wasm-gc target plans to use a P2 component
  /// (see ADR-0036 / docs/spec/codegen-dual-backend.md Phase D).
  WasiP1HostImport
  /// Linear-specific primitive (FixedArray, raw memory helpers) that
  /// has no analogue in wasm-gc.
  LinearOnlyPrimitive
  /// Not yet implemented for the missing backend — Phase A.2 follow-up
  /// tracked in issue #414.
  NotYetImplemented
}

///|
/// Result kind of a builtin. Two-axis: representation (Int64, Float, Ref,
/// Unit) and per-backend kind details are still expressed in
/// `wasm_codegen_emit.mbt::ValueKind` / `wasm_gc_codegen::GcValKind`.
/// Registry only carries the abstract shape so checker and both backends
/// can agree on the signature.
pub(all) enum ResultShape {
  /// Tagged i64 (Int / Char / Bool / Unit on linear; raw i64 on wasm-gc).
  Int
  /// f32 / f64 — boxed on linear, raw on wasm-gc.
  Float
  Double
  /// String / Bytes / Array / Map — reference value.
  Ref
  /// Side-effect builtin (e.g. `Array::push` returns Unit-shaped i32 on
  /// wasm-gc but the linear backend uses a tagged unit).
  Unit
}

///|
/// A single builtin entry. Once Phase B-1 migration lands, both backends
/// will be table-driven and new builtins join by appending one entry to
/// `builtins()` below, instead of touching two large `match name`
/// statements.
pub(all) struct BuiltinDecl {
  /// Fully qualified name (e.g. "Array::push").
  name : String
  /// Source-of-truth signature, shared with the checker (currently a
  /// human-readable summary; Phase B-2 will tighten this to a
  /// `@core.Type`).
  sig_summary : String
  /// Result shape — used by Phase B-1 to derive ValueKind / GcValKind
  /// per backend.
  result : ResultShape
  /// True when the builtin is implemented for the linear backend.
  has_linear : Bool
  /// True when the builtin is implemented for the wasm-gc backend.
  has_gc : Bool
  /// Required when `has_linear != has_gc` (a parity divergence) — why the
  /// builtin only has a dedicated codegen arm in one backend.
  divergence_reason : DivergenceReason?
}

///|
/// Helper for a core-namespace builtin that only has a dedicated codegen
/// arm in one backend, with the other backend reaching the same behavior
/// through the prelude / fallback path. These are the entries the parity
/// gate (`src/tests/codegen_parity_test.mbt`) treats as accepted
/// divergences.
fn prelude_fallback(
  name : String,
  result : ResultShape,
  has_linear : Bool,
) -> BuiltinDecl {
  BuiltinDecl::{
    name,
    sig_summary: "",
    result,
    has_linear,
    has_gc: !has_linear,
    divergence_reason: Some(PreludeFallback),
  }
}

///|
/// Registry table. Phase B-1 will progressively migrate *all* builtins
/// from the existing `wasm_codegen_builtin_*.mbt` and
/// `wasm_gc_codegen.mbt::Call` dispatch into this table. For now the table
/// owns the **parity contract**: every core-namespace divergence between
/// the linear and wasm-gc backends is recorded here as a typed entry, and
/// `src/tests/codegen_parity_test.mbt` fails if the source scan finds a
/// core divergence that is not declared (replacing the old
/// `scripts/codegen_parity_allowlist.txt`).
///
/// Current divergences (all `PreludeFallback`):
/// - `String::compare` has a single-pass SIMD arm in the linear backend
///   (ADR-0054); wasm-gc reaches the same result via the prelude.
/// - Native float math (`Float`/`Double` ceil/floor/fract/round/sqrt/trunc)
///   and `Array::fold` have dedicated wasm-gc arms; the linear backend
///   routes them through the prelude / fallback path.
pub fn builtins() -> Array[BuiltinDecl] {
  [
    // linear-only (wasm-gc uses the prelude)
    prelude_fallback("String::compare", Int, true),
    // wasm-gc-only (linear uses the prelude / fallback path)
    prelude_fallback("Array::fold", Ref, false),
    prelude_fallback("Double::ceil", Double, false),
    prelude_fallback("Double::floor", Double, false),
    prelude_fallback("Double::fract", Double, false),
    prelude_fallback("Double::round", Double, false),
    prelude_fallback("Double::sqrt", Double, false),
    prelude_fallback("Double::trunc", Double, false),
    prelude_fallback("Float::ceil", Float, false),
    prelude_fallback("Float::floor", Float, false),
    prelude_fallback("Float::fract", Float, false),
    prelude_fallback("Float::round", Float, false),
    prelude_fallback("Float::sqrt", Float, false),
    prelude_fallback("Float::trunc", Float, false),
  ]
}

///|
/// Look up a builtin by name. Returns `None` when the registry hasn't
/// taken ownership of the name yet (Phase B-1 in progress).
pub fn find_builtin(name : String) -> BuiltinDecl? {
  for decl in builtins() {
    if decl.name == name {
      return Some(decl)
    }
  }
  None
}
