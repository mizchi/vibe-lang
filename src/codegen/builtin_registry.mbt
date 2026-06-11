///|
/// Phase B (Issue #415) skeleton: a single registry table that describes
/// every builtin with its parity between the linear and wasm-gc backends.
///
/// Phase B-1 migrates builtins off the two parallel `match name`
/// dispatchers in `wasm_codegen_builtin_*.mbt` and `wasm_gc_codegen.mbt`
/// and onto the shared `migrated_builtin` table below, one namespace at a
/// time (Char → numeric conversions → ... → Array/Bytes/Map/String).
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
/// Phase B-2 (#415): a single `RegistryEntry` declares each builtin ONCE —
/// its parity metadata (name / result shape / has_linear / has_gc /
/// divergence_reason) AND its per-backend codegen (`compile_linear` /
/// `compile_gc`, optional). Both the public `builtins()` metadata (used by
/// the parity gate) and the `migrated_builtin` dispatch table are derived
/// from `registry_entries()`, so adding or changing a builtin is a single
/// edit. The compile fns reference package-private context types, so this
/// entry type is `priv` (the public `BuiltinDecl` stays metadata-only).
priv struct RegistryEntry {
  name : String
  result : ResultShape
  has_linear : Bool
  has_gc : Bool
  divergence_reason : DivergenceReason?
  /// Linear codegen. `None` when the linear backend has no dedicated arm
  /// (a wasm-gc-only divergence such as the native float math ops).
  compile_linear : ((CodegenCtx, ByteBuf, Array[@core.CallArg]) -> Unit raise WasmGenError)?
  /// wasm-gc codegen. `None` when wasm-gc reaches the same behavior through
  /// the prelude (a linear-only builtin such as the `Set::` namespace, or a
  /// metadata-only divergence such as `String::compare`).
  compile_gc : ((GcCodegenCtx, GcFuncCtx, GcByteBuf, Array[@core.Expr]) -> Unit raise WasmGenError)?
  /// When true, the linear dispatch only uses this entry when the name does
  /// not resolve to a user/prelude function (`!is_user_fn`) — the legacy
  /// `"Int::abs" if !is_user_fn =>` guards.
  linear_skip_if_user_fn : Bool
}

///|
/// Both backends have a dedicated codegen arm (no divergence, no guard).
fn entry_both(
  name : String,
  result : ResultShape,
  compile_linear : (CodegenCtx, ByteBuf, Array[@core.CallArg]) -> Unit raise WasmGenError,
  compile_gc : (GcCodegenCtx, GcFuncCtx, GcByteBuf, Array[@core.Expr]) -> Unit raise WasmGenError,
) -> RegistryEntry {
  RegistryEntry::{
    name,
    result,
    has_linear: true,
    has_gc: true,
    divergence_reason: None,
    compile_linear: Some(compile_linear),
    compile_gc: Some(compile_gc),
    linear_skip_if_user_fn: false,
  }
}

///|
/// Both backends, but the linear dispatch keeps the `!is_user_fn` guard.
fn entry_both_guarded(
  name : String,
  result : ResultShape,
  compile_linear : (CodegenCtx, ByteBuf, Array[@core.CallArg]) -> Unit raise WasmGenError,
  compile_gc : (GcCodegenCtx, GcFuncCtx, GcByteBuf, Array[@core.Expr]) -> Unit raise WasmGenError,
) -> RegistryEntry {
  RegistryEntry::{
    name,
    result,
    has_linear: true,
    has_gc: true,
    divergence_reason: None,
    compile_linear: Some(compile_linear),
    compile_gc: Some(compile_gc),
    linear_skip_if_user_fn: true,
  }
}

///|
/// Linear has a dedicated arm; wasm-gc reaches the same behavior through the
/// prelude (no gc arm → gc dispatch falls through). e.g. the `Set::` namespace.
fn entry_linear_only(
  name : String,
  result : ResultShape,
  compile_linear : (CodegenCtx, ByteBuf, Array[@core.CallArg]) -> Unit raise WasmGenError,
) -> RegistryEntry {
  RegistryEntry::{
    name,
    result,
    has_linear: true,
    has_gc: false,
    divergence_reason: Some(PreludeFallback),
    compile_linear: Some(compile_linear),
    compile_gc: None,
    linear_skip_if_user_fn: false,
  }
}

///|
/// A divergence recorded only for the parity contract — no registry codegen
/// on either side (the implementing backend still uses its legacy arm).
/// `has_linear`/`has_gc` describe which backend has the dedicated arm.
fn entry_divergence(
  name : String,
  result : ResultShape,
  has_linear : Bool,
) -> RegistryEntry {
  RegistryEntry::{
    name,
    result,
    has_linear,
    has_gc: !has_linear,
    divergence_reason: Some(PreludeFallback),
    compile_linear: None,
    compile_gc: None,
    linear_skip_if_user_fn: false,
  }
}

///|
/// The single source of truth: every builtin the registry owns, declared
/// once. `builtins()` and `migrated_builtin` are both derived from this.
///
/// Migrated (table-driven dispatch on the listed backend(s)):
/// - Char identity, numeric conversions, int math, `Int::parse`, the full
///   `Bytes::` / `String::` / `Array::` / `Map::` (conservative subsets) /
///   `StringBuilder::` / `ArrayBuilder::` / `MapBuilder::` namespaces, and the
///   linear-only `Set::` namespace (wasm-gc via prelude).
///
/// Divergences (parity contract only — implemented via the legacy arm /
/// prelude, not the registry):
/// - `String::compare` (linear-only SIMD, ADR-0054; wasm-gc via prelude),
///   `Double::to_i64_bits_{lo,hi}` (linear-only split f64 raw bits; wasm-gc
///   has no boxed-double half extraction path),
///   `Array::fold` and the native `Float`/`Double` math (wasm-gc arms; linear
///   via prelude).
fn registry_entries() -> Array[RegistryEntry] {
  [
    // --- Char identity ---
    entry_both(
      "Char::to_int",
      Int,
      compile_char_identity_linear,
      compile_char_identity_gc,
    ),
    entry_both(
      "Char::from_int",
      Int,
      compile_char_identity_linear,
      compile_char_identity_gc,
    ),
    // --- numeric conversions (linear boxes f32/f64 & tags ints; gc raw) ---
    entry_both(
      "Int::to_float",
      Float,
      compile_int_to_float_linear,
      compile_int_to_float_gc,
    ),
    entry_both(
      "Int::to_double",
      Double,
      compile_int_to_double_linear,
      compile_int_to_double_gc,
    ),
    entry_both(
      "Float::to_int",
      Int,
      compile_float_to_int_linear,
      compile_float_to_int_gc,
    ),
    entry_both(
      "Double::to_int",
      Int,
      compile_double_to_int_linear,
      compile_double_to_int_gc,
    ),
    entry_both(
      "Float::to_double",
      Double,
      compile_float_to_double_linear,
      compile_float_to_double_gc,
    ),
    entry_both(
      "Double::to_float",
      Float,
      compile_double_to_float_linear,
      compile_double_to_float_gc,
    ),
    // --- int math utilities (linear keeps the !is_user_fn guard) ---
    entry_both_guarded(
      "Int::abs",
      Int,
      compile_int_abs_linear,
      compile_int_abs_gc,
    ),
    entry_both_guarded(
      "Int::max",
      Int,
      compile_int_max_linear,
      compile_int_max_gc,
    ),
    entry_both_guarded(
      "Int::min",
      Int,
      compile_int_min_linear,
      compile_int_min_gc,
    ),
    entry_both_guarded(
      "Int::clamp",
      Int,
      compile_int_clamp_linear,
      compile_int_clamp_gc,
    ),
    entry_both_guarded(
      "Int::signum",
      Int,
      compile_int_signum_linear,
      compile_int_signum_gc,
    ),
    entry_both_guarded(
      "Int::is_even",
      Int,
      compile_int_is_even_linear,
      compile_int_is_even_gc,
    ),
    entry_both_guarded(
      "Int::is_odd",
      Int,
      compile_int_is_odd_linear,
      compile_int_is_odd_gc,
    ),
    entry_both(
      "Int::parse",
      Ref,
      compile_int_parse_linear,
      compile_int_parse_gc_arm,
    ),
    // --- Bytes:: ---
    entry_both(
      "Bytes::from_array",
      Ref,
      compile_bytes_from_array_linear,
      compile_bytes_from_array_gc_arm,
    ),
    entry_both(
      "Bytes::from_string",
      Ref,
      compile_bytes_from_string_linear,
      compile_bytes_from_string_gc_arm,
    ),
    entry_both(
      "Bytes::to_string",
      Ref,
      compile_bytes_to_string_linear,
      compile_bytes_to_string_gc_arm,
    ),
    entry_both(
      "Bytes::length",
      Int,
      compile_bytes_length_linear,
      compile_bytes_length_gc_arm,
    ),
    entry_both(
      "Bytes::get",
      Int,
      compile_bytes_get_linear,
      compile_bytes_get_gc_arm,
    ),
    entry_both(
      "Bytes::new",
      Ref,
      compile_bytes_new_linear,
      compile_bytes_new_gc_arm,
    ),
    entry_both(
      "Bytes::push",
      Unit,
      compile_bytes_push_linear,
      compile_bytes_push_gc_arm,
    ),
    entry_both(
      "Bytes::set",
      Unit,
      compile_bytes_set_linear,
      compile_bytes_set_gc_arm,
    ),
    entry_both(
      "Bytes::append",
      Unit,
      compile_bytes_append_linear,
      compile_bytes_append_gc_arm,
    ),
    entry_both(
      "Bytes::blit",
      Unit,
      compile_bytes_blit_linear,
      compile_bytes_blit_gc_arm,
    ),
    entry_both(
      "Bytes::fill",
      Unit,
      compile_bytes_fill_linear,
      compile_bytes_fill_gc_arm,
    ),
    entry_both(
      "Bytes::slice",
      Ref,
      compile_bytes_slice_linear,
      compile_bytes_slice_gc_arm,
    ),
    entry_both(
      "Bytes::concat",
      Ref,
      compile_bytes_concat_linear,
      compile_bytes_concat_gc_arm,
    ),
    entry_both(
      "Bytes::to_array",
      Ref,
      compile_bytes_to_array_linear,
      compile_bytes_to_array_gc_arm,
    ),
    // --- String:: (boolean-returning ops yield a tagged bool → Int) ---
    entry_both(
      "String::length",
      Int,
      compile_string_length_linear,
      compile_string_length_gc_arm,
    ),
    entry_both(
      "String::char_code_at",
      Int,
      compile_string_char_code_at_linear,
      compile_string_char_code_at_gc_arm,
    ),
    entry_both(
      "String::substring",
      Ref,
      compile_string_substring_linear,
      compile_string_substring_gc_arm,
    ),
    entry_both(
      "String::concat",
      Ref,
      compile_string_concat_linear,
      compile_string_concat_gc_arm,
    ),
    entry_both(
      "String::join",
      Ref,
      compile_string_join_linear,
      compile_string_join_gc_arm,
    ),
    entry_both(
      "String::equals",
      Int,
      compile_string_equals_linear,
      compile_string_equals_gc_arm,
    ),
    entry_both(
      "String::index_of",
      Int,
      compile_string_index_of_linear,
      compile_string_index_of_gc_arm,
    ),
    entry_both_guarded(
      "String::last_index_of",
      Int,
      compile_string_last_index_of_linear,
      compile_string_last_index_of_gc_arm,
    ),
    entry_both_guarded(
      "String::contains",
      Int,
      compile_string_contains_linear,
      compile_string_contains_gc_arm,
    ),
    entry_both_guarded(
      "String::starts_with",
      Int,
      compile_string_starts_with_linear,
      compile_string_starts_with_gc_arm,
    ),
    entry_both_guarded(
      "String::ends_with",
      Int,
      compile_string_ends_with_linear,
      compile_string_ends_with_gc_arm,
    ),
    entry_both_guarded(
      "String::trim",
      Ref,
      compile_string_trim_linear,
      compile_string_trim_gc_arm,
    ),
    entry_both_guarded(
      "String::trim_start",
      Ref,
      compile_string_trim_start_linear,
      compile_string_trim_start_gc_arm,
    ),
    entry_both_guarded(
      "String::trim_end",
      Ref,
      compile_string_trim_end_linear,
      compile_string_trim_end_gc_arm,
    ),
    entry_both_guarded(
      "String::to_lower",
      Ref,
      compile_string_to_lower_linear,
      compile_string_to_lower_gc_arm,
    ),
    entry_both_guarded(
      "String::to_upper",
      Ref,
      compile_string_to_upper_linear,
      compile_string_to_upper_gc_arm,
    ),
    entry_both_guarded(
      "String::count",
      Int,
      compile_string_count_linear,
      compile_string_count_gc_arm,
    ),
    entry_both_guarded(
      "String::replace",
      Ref,
      compile_string_replace_linear,
      compile_string_replace_gc_arm,
    ),
    entry_both_guarded(
      "String::split",
      Ref,
      compile_string_split_linear,
      compile_string_split_gc_arm,
    ),
    entry_both(
      "String::from_char_code",
      Ref,
      compile_string_from_char_code_linear,
      compile_string_from_char_code_gc_arm,
    ),
    entry_both(
      "String::from_char_codes",
      Ref,
      compile_string_from_char_codes_linear,
      compile_string_from_char_codes_gc_arm,
    ),
    // --- Map:: (conservative subset) ---
    entry_both(
      "Map::iter_length",
      Int,
      compile_map_iter_length_linear,
      compile_map_iter_length_gc_arm,
    ),
    entry_both("Map::get", Ref, compile_map_get_linear, compile_map_get_gc_arm),
    entry_both("Map::set", Ref, compile_map_set_linear, compile_map_set_gc_arm),
    entry_both(
      "Map::delete",
      Ref,
      compile_map_delete_linear,
      compile_map_delete_gc_arm,
    ),
    entry_both(
      "Map::keys",
      Ref,
      compile_map_keys_linear,
      compile_map_keys_gc_arm,
    ),
    entry_both(
      "Map::values",
      Ref,
      compile_map_values_linear,
      compile_map_values_gc_arm,
    ),
    entry_both(
      "Map::has_key",
      Int,
      compile_map_has_key_linear,
      compile_map_has_gc_arm,
    ),
    entry_both("Map::has", Int, compile_map_has_linear, compile_map_has_gc_arm),
    entry_both(
      "Map::iter_get",
      Ref,
      compile_map_iter_get_linear,
      compile_map_iter_get_gc_arm,
    ),
    // --- Array:: (conservative subset) ---
    entry_both(
      "Array::length",
      Int,
      compile_array_length_linear,
      compile_array_length_gc_arm,
    ),
    entry_both(
      "Array::get",
      Ref,
      compile_array_get_linear,
      compile_array_get_gc_arm,
    ),
    entry_both(
      "Array::set",
      Unit,
      compile_array_set_linear,
      compile_array_set_gc_arm,
    ),
    entry_both(
      "Array::truncate",
      Unit,
      compile_array_truncate_linear,
      compile_array_truncate_gc_arm,
    ),
    entry_both(
      "Array::with_capacity",
      Ref,
      compile_array_with_capacity_linear,
      compile_array_with_capacity_gc_arm,
    ),
    entry_both(
      "Array::push",
      Unit,
      compile_array_push_linear,
      compile_array_push_gc_arm,
    ),
    // --- StringBuilder:: ---
    entry_both(
      "StringBuilder::new",
      Ref,
      compile_string_builder_new_linear,
      compile_string_builder_new_gc_arm,
    ),
    entry_both(
      "StringBuilder::push",
      Unit,
      compile_string_builder_push_linear,
      compile_string_builder_push_gc_arm,
    ),
    entry_both(
      "StringBuilder::freeze",
      Ref,
      compile_string_builder_freeze_linear,
      compile_string_builder_freeze_gc_arm,
    ),
    // --- ArrayBuilder:: / MapBuilder:: ---
    entry_both(
      "ArrayBuilder::new",
      Ref,
      compile_array_builder_new_linear,
      compile_array_builder_new_gc_arm,
    ),
    entry_both(
      "ArrayBuilder::push",
      Unit,
      compile_array_builder_push_linear,
      compile_array_builder_push_gc_arm,
    ),
    entry_both(
      "ArrayBuilder::freeze",
      Ref,
      compile_array_builder_freeze_linear,
      compile_array_builder_freeze_gc_arm,
    ),
    entry_both(
      "MapBuilder::new",
      Ref,
      compile_map_builder_new_linear,
      compile_map_builder_new_gc_arm,
    ),
    entry_both(
      "MapBuilder::set",
      Unit,
      compile_map_builder_set_linear,
      compile_map_builder_set_gc_arm,
    ),
    entry_both(
      "MapBuilder::freeze",
      Ref,
      compile_map_builder_freeze_linear,
      compile_map_builder_freeze_gc_arm,
    ),
    // --- Set:: (linear-only; wasm-gc via prelude) ---
    entry_linear_only("Set::new", Ref, compile_set_new_linear),
    entry_linear_only("Set::size", Int, compile_set_size_linear),
    entry_linear_only("Set::contains", Int, compile_set_contains_linear),
    entry_linear_only("Set::add", Ref, compile_set_add_linear),
    entry_linear_only("Set::remove", Ref, compile_set_remove_linear),
    entry_linear_only("Set::to_array", Ref, compile_set_to_array_linear),
    entry_linear_only("Set::from_array", Ref, compile_set_from_array_linear),
    // --- divergences (parity contract only; legacy arm / prelude) ---
    entry_divergence("String::compare", Int, true),
    entry_divergence("Double::to_i64_bits_lo", Int, true),
    entry_divergence("Double::to_i64_bits_hi", Int, true),
    entry_divergence("Array::fold", Ref, false),
    entry_divergence("Double::ceil", Double, false),
    entry_divergence("Double::floor", Double, false),
    entry_divergence("Double::fract", Double, false),
    entry_divergence("Double::round", Double, false),
    entry_divergence("Double::sqrt", Double, false),
    entry_divergence("Double::trunc", Double, false),
    entry_divergence("Float::ceil", Float, false),
    entry_divergence("Float::floor", Float, false),
    entry_divergence("Float::fract", Float, false),
    entry_divergence("Float::round", Float, false),
    entry_divergence("Float::sqrt", Float, false),
    entry_divergence("Float::trunc", Float, false),
  ]
}

///|
/// Public, metadata-only view of the registry. Used by the parity gate
/// (`src/tests/codegen_parity_test.mbt`). Derived from `registry_entries()`.
pub fn builtins() -> Array[BuiltinDecl] {
  let out : Array[BuiltinDecl] = []
  for e in registry_entries() {
    out.push(BuiltinDecl::{
      name: e.name,
      sig_summary: "",
      result: e.result,
      has_linear: e.has_linear,
      has_gc: e.has_gc,
      divergence_reason: e.divergence_reason,
    })
  }
  out
}

///|
/// Look up a builtin's metadata by name. Used by the parity gate. Returns
/// `None` when the registry doesn't own the name.
pub fn find_builtin(name : String) -> BuiltinDecl? {
  for decl in builtins() {
    if decl.name == name {
      return Some(decl)
    }
  }
  None
}

///|
/// The per-backend codegen the dispatch sites consume. `compile_gc == None`
/// means linear-only (wasm-gc falls through to the prelude path).
priv struct MigratedBuiltin {
  compile_linear : (CodegenCtx, ByteBuf, Array[@core.CallArg]) -> Unit raise WasmGenError
  compile_gc : ((GcCodegenCtx, GcFuncCtx, GcByteBuf, Array[@core.Expr]) -> Unit raise WasmGenError)?
  linear_skip_if_user_fn : Bool
}

///|
/// Built-once dispatch table (lazy). `migrated_builtin` is on the codegen
/// hot path, so the map is materialized from `registry_entries()` on first
/// use and cached, rather than rebuilt per lookup. A top-level `let`
/// computing the map directly would form a definition cycle
/// (table -> compile fns -> compile_expr -> migrated_builtin -> table), so
/// the cache holds `None` until first use.
let migrated_table_cache : Ref[Map[String, MigratedBuiltin]?] = Ref::{
  val: None,
}

///|
/// Look up the per-backend codegen for a builtin the registry dispatches.
/// Returns `None` for names with no `compile_linear` (pure divergences) or
/// names the registry does not own.
fn migrated_builtin(name : String) -> MigratedBuiltin? {
  let table = match migrated_table_cache.val {
    Some(t) => t
    None => {
      let t : Map[String, MigratedBuiltin] = Map::new()
      for e in registry_entries() {
        match e.compile_linear {
          Some(cl) =>
            t.set(e.name, MigratedBuiltin::{
              compile_linear: cl,
              compile_gc: e.compile_gc,
              linear_skip_if_user_fn: e.linear_skip_if_user_fn,
            })
          None => ()
        }
      }
      migrated_table_cache.val = Some(t)
      t
    }
  }
  table.get(name)
}

///|
/// Linear identity codegen for `Char::to_int` / `Char::from_int`.
fn compile_char_identity_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "Char::*", 1)
  compile_expr(ctx, buf, pos_args[0])
}

///|
/// wasm-gc identity codegen for `Char::to_int` / `Char::from_int`.
fn compile_char_identity_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Char identity arity")
  }
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
}

// --- numeric conversions (Phase B-1) ---
// Linear bodies migrated verbatim from wasm_codegen_builtin_numeric.mbt;
// wasm-gc bodies from wasm_gc_codegen.mbt. Shapes differ because linear
// boxes floats / tags ints while wasm-gc uses raw f32/f64/i64.

///|
fn compile_int_to_float_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "Int::to_float", 1)
  emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
    compile_expr_i32(ctx, buf, pos_args[0])
    emit_untag_int_i32(buf)
    emit_f32_convert_i32_s(buf)
  })
}

///|
fn compile_int_to_float_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Int::to_float arity")
  }
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_f32_convert_i64_s_gc(buf)
}

///|
fn compile_int_to_double_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "Int::to_double", 1)
  emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
    compile_expr_i32(ctx, buf, pos_args[0])
    emit_i64_const_raw(buf, 2L)
    emit_i64_shr_s(buf)
    emit_f64_convert_i64_s(buf)
  })
}

///|
fn compile_int_to_double_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Int::to_double arity")
  }
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_f64_convert_i64_s_gc(buf)
}

///|
fn compile_float_to_int_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "Float::to_int", 1)
  emit_unbox_f32_expr(ctx, buf, pos_args[0])
  emit_i32_trunc_f32_s(buf)
  emit_i64_extend_i32_s(buf)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
}

///|
fn compile_float_to_int_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Float::to_int arity")
  }
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_i64_trunc_f32_s_gc(buf)
}

///|
fn compile_double_to_int_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "Double::to_int", 1)
  emit_unbox_f64_expr(ctx, buf, pos_args[0])
  emit_i64_trunc_f64_s(buf)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
}

///|
fn compile_double_to_int_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Double::to_int arity")
  }
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_i64_trunc_f64_s_gc(buf)
}

///|
fn compile_float_to_double_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(
    args, "Float::to_double", 1,
  )
  emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
    emit_unbox_f32_expr(ctx, buf, pos_args[0])
    emit_f64_promote_f32(buf)
  })
}

///|
fn compile_float_to_double_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Float::to_double arity")
  }
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_f64_promote_f32_gc(buf)
}

///|
fn compile_double_to_float_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(
    args, "Double::to_float", 1,
  )
  emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
    emit_unbox_f64_expr(ctx, buf, pos_args[0])
    emit_f32_demote_f64(buf)
  })
}

///|
fn compile_double_to_float_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Double::to_float arity")
  }
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_f32_demote_f64_gc(buf)
}

// --- integer math utilities (Phase B-1) ---
// Linear operates on tagged i64 directly; wasm-gc on raw i64. Bodies
// migrated verbatim from wasm_codegen_builtin_numeric.mbt /
// wasm_gc_codegen.mbt.

///|
fn compile_int_abs_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "Int::abs", 1)
  let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_local_tee(buf, tmp)
  emit_i64_const_raw(buf, 0L)
  emit_i64_lt_s(buf)
  emit_if(buf)
  emit_i64_const_raw(buf, 0L)
  emit_local_get(buf, tmp)
  emit_i64_sub(buf)
  emit_local_set(buf, tmp)
  emit_end(buf)
  emit_local_get(buf, tmp)
}

///|
fn compile_int_abs_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Int::abs arity")
  }
  let x = alloc_local_gc(fctx, GcValKind::I64)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_local_tee_gc(buf, x)
  emit_i64_const_gc(buf, 0L)
  emit_i64_lt_s_gc(buf)
  emit_if_gc(buf, Some(GcValKind::I64))
  emit_i64_const_gc(buf, 0L)
  emit_local_get_gc(buf, x)
  emit_i64_sub_gc(buf)
  emit_else_gc(buf)
  emit_local_get_gc(buf, x)
  emit_end_gc(buf)
}

///|
fn compile_int_max_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "Int::max", 2)
  let a_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
  let b_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_local_set(buf, a_local)
  compile_expr_i32(ctx, buf, pos_args[1])
  emit_local_set(buf, b_local)
  emit_local_get(buf, a_local)
  emit_local_get(buf, b_local)
  emit_local_get(buf, a_local)
  emit_local_get(buf, b_local)
  emit_i64_gt_s(buf)
  emit_select(buf)
}

///|
fn compile_int_max_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("Int::max arity")
  }
  let a = alloc_local_gc(fctx, GcValKind::I64)
  let b = alloc_local_gc(fctx, GcValKind::I64)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_local_set_gc(buf, a)
  compile_expr_gc(ctx, fctx, buf, pos_args[1])
  emit_local_set_gc(buf, b)
  emit_local_get_gc(buf, a)
  emit_local_get_gc(buf, b)
  emit_i64_gt_s_gc(buf)
  emit_if_gc(buf, Some(GcValKind::I64))
  emit_local_get_gc(buf, a)
  emit_else_gc(buf)
  emit_local_get_gc(buf, b)
  emit_end_gc(buf)
}

///|
fn compile_int_min_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "Int::min", 2)
  let a_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
  let b_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_local_set(buf, a_local)
  compile_expr_i32(ctx, buf, pos_args[1])
  emit_local_set(buf, b_local)
  emit_local_get(buf, a_local)
  emit_local_get(buf, b_local)
  emit_local_get(buf, a_local)
  emit_local_get(buf, b_local)
  emit_i64_lt_s(buf)
  emit_select(buf)
}

///|
fn compile_int_min_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("Int::min arity")
  }
  let a = alloc_local_gc(fctx, GcValKind::I64)
  let b = alloc_local_gc(fctx, GcValKind::I64)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_local_set_gc(buf, a)
  compile_expr_gc(ctx, fctx, buf, pos_args[1])
  emit_local_set_gc(buf, b)
  emit_local_get_gc(buf, a)
  emit_local_get_gc(buf, b)
  emit_i64_lt_s_gc(buf)
  emit_if_gc(buf, Some(GcValKind::I64))
  emit_local_get_gc(buf, a)
  emit_else_gc(buf)
  emit_local_get_gc(buf, b)
  emit_end_gc(buf)
}

///|
fn compile_int_clamp_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "Int::clamp", 3)
  let x_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
  let lo_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
  let hi_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_local_set(buf, x_local)
  compile_expr_i32(ctx, buf, pos_args[1])
  emit_local_set(buf, lo_local)
  compile_expr_i32(ctx, buf, pos_args[2])
  emit_local_set(buf, hi_local)
  emit_local_get(buf, x_local)
  emit_local_get(buf, hi_local)
  emit_local_get(buf, x_local)
  emit_local_get(buf, hi_local)
  emit_i64_lt_s(buf)
  emit_select(buf)
  emit_local_set(buf, x_local)
  emit_local_get(buf, lo_local)
  emit_local_get(buf, x_local)
  emit_local_get(buf, lo_local)
  emit_local_get(buf, x_local)
  emit_i64_gt_s(buf)
  emit_select(buf)
}

///|
fn compile_int_clamp_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 3 {
    raise WasmGenError::Unsupported("Int::clamp arity")
  }
  let x = alloc_local_gc(fctx, GcValKind::I64)
  let lo = alloc_local_gc(fctx, GcValKind::I64)
  let hi = alloc_local_gc(fctx, GcValKind::I64)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_local_set_gc(buf, x)
  compile_expr_gc(ctx, fctx, buf, pos_args[1])
  emit_local_set_gc(buf, lo)
  compile_expr_gc(ctx, fctx, buf, pos_args[2])
  emit_local_set_gc(buf, hi)
  emit_local_get_gc(buf, x)
  emit_local_get_gc(buf, hi)
  emit_i64_gt_s_gc(buf)
  emit_if_gc(buf, Some(GcValKind::I64))
  emit_local_get_gc(buf, hi)
  emit_else_gc(buf)
  emit_local_get_gc(buf, x)
  emit_end_gc(buf)
  emit_local_set_gc(buf, x)
  emit_local_get_gc(buf, lo)
  emit_local_get_gc(buf, x)
  emit_i64_gt_s_gc(buf)
  emit_if_gc(buf, Some(GcValKind::I64))
  emit_local_get_gc(buf, lo)
  emit_else_gc(buf)
  emit_local_get_gc(buf, x)
  emit_end_gc(buf)
}

///|
fn compile_int_signum_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "Int::signum", 1)
  let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_local_set(buf, tmp)
  emit_local_get(buf, tmp)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shr_s(buf)
  emit_local_set(buf, tmp)
  emit_local_get(buf, tmp)
  emit_i64_const_raw(buf, 0L)
  emit_i64_lt_s(buf)
  emit_if(buf)
  emit_i64_const_raw(buf, tag_int_value64(-1L))
  emit_local_set(buf, tmp)
  emit_else(buf)
  emit_local_get(buf, tmp)
  emit_i64_const_raw(buf, 0L)
  emit_i64_gt_s(buf)
  emit_if(buf)
  emit_i64_const_raw(buf, tag_int_value64(1L))
  emit_local_set(buf, tmp)
  emit_else(buf)
  emit_i64_const_raw(buf, tag_int_value64(0L))
  emit_local_set(buf, tmp)
  emit_end(buf)
  emit_end(buf)
  emit_local_get(buf, tmp)
}

///|
fn compile_int_signum_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Int::signum arity")
  }
  let x = alloc_local_gc(fctx, GcValKind::I64)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_local_set_gc(buf, x)
  emit_local_get_gc(buf, x)
  emit_i64_const_gc(buf, 0L)
  emit_i64_gt_s_gc(buf)
  emit_if_gc(buf, Some(GcValKind::I64))
  emit_i64_const_gc(buf, 1L)
  emit_else_gc(buf)
  emit_local_get_gc(buf, x)
  emit_i64_const_gc(buf, 0L)
  emit_i64_lt_s_gc(buf)
  emit_if_gc(buf, Some(GcValKind::I64))
  emit_i64_const_gc(buf, -1L)
  emit_else_gc(buf)
  emit_i64_const_gc(buf, 0L)
  emit_end_gc(buf)
  emit_end_gc(buf)
}

///|
fn compile_int_is_even_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "Int::is_even", 1)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_i64_const_raw(buf, 2L)
  emit_i64_shr_s(buf)
  emit_i64_const_raw(buf, 1L)
  emit_i64_and(buf)
  emit_i64_eqz(buf)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
  emit_i64_const_raw(buf, tag_bool.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_int_is_even_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Int::is_even arity")
  }
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_i64_const_gc(buf, 1L)
  emit_i64_and_gc(buf)
  emit_i64_const_gc(buf, 0L)
  emit_i64_eq_gc(buf)
}

///|
fn compile_int_is_odd_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "Int::is_odd", 1)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_i64_const_raw(buf, 2L)
  emit_i64_shr_s(buf)
  emit_i64_const_raw(buf, 1L)
  emit_i64_and(buf)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
  emit_i64_const_raw(buf, tag_bool.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_int_is_odd_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Int::is_odd arity")
  }
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_i64_const_gc(buf, 1L)
  emit_i64_and_gc(buf)
  emit_i64_const_gc(buf, 1L)
  emit_i64_eq_gc(buf)
}
