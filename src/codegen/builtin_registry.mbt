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
/// `src/codegen/`. The `scripts/check_codegen_parity.sh` informational
/// gate currently shows ~17 core-namespace divergences after #414
/// landed Phase A.2. With registry entries, parity becomes a static
/// property (`compile_gc` either Some or None with a reason), and
/// `check_codegen_parity` can become a hard gate driven by the table
/// instead of regex over source files.

///|
/// Why a builtin is implemented only for the linear backend. Mostly
/// host-import bindings that wasm-gc can't service yet.
pub(all) enum LinearOnlyReason {
  /// WASI P1 host import — wasm-gc target plans to use a P2 component
  /// (see ADR-0036 / docs/spec/codegen-dual-backend.md Phase D).
  WasiP1HostImport
  /// Linear-specific primitive (FixedArray, raw memory helpers) that
  /// has no analogue in wasm-gc.
  LinearOnlyPrimitive
  /// Not yet implemented for wasm-gc — Phase A.2 follow-up tracked in
  /// issue #414.
  NotYetGc
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
  /// Required when `has_gc` is false — why.
  linear_only_reason : LinearOnlyReason?
}

///|
/// Skeleton table. Phase B-1 will progressively migrate entries from
/// the existing `wasm_codegen_builtin_*.mbt` and
/// `wasm_gc_codegen.mbt::Call` dispatch into this table.
///
/// The current implementation is empty: registry consumers must fall
/// back to the legacy match-arm dispatch until each namespace is moved
/// over. Keeping the table empty means there is no risk of double-
/// dispatch during the migration.
pub fn builtins() -> Array[BuiltinDecl] {
  []
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
