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
/// Helper for a builtin implemented (table-driven) on both backends — no
/// divergence. See `migrated_builtin` for the actual compile fns.
fn registry_both(name : String, result : ResultShape) -> BuiltinDecl {
  BuiltinDecl::{
    name,
    sig_summary: "",
    result,
    has_linear: true,
    has_gc: true,
    divergence_reason: None,
  }
}

///|
/// Registry table — the typed source of truth for which builtins the
/// registry owns and their parity. Phase B-1 migrates builtins from the
/// `wasm_codegen_builtin_*.mbt` and `wasm_gc_codegen.mbt::Call` dispatch
/// into this table one namespace at a time.
///
/// Migrated (table-driven on both backends — legacy `match name` arms
/// removed, dispatch goes through `migrated_builtin` below):
/// - `Char::to_int` / `Char::from_int` — identity (62-bit tagged int).
/// - numeric conversions: `Int::to_float` / `Int::to_double` /
///   `Float::to_int` / `Double::to_int` / `Float::to_double` /
///   `Double::to_float`.
/// - int math utilities: `Int::abs` / `max` / `min` / `clamp` / `signum` /
///   `is_even` / `is_odd` (linear keeps the `!is_user_fn` guard).
/// - `Bytes::` namespace: `from_array` / `from_string` / `to_string` /
///   `length` / `get` / `new` / `push` / `set` / `append` / `blit` / `fill` /
///   `slice` / `concat` / `to_array`.
/// - `String::` namespace: `length` / `char_code_at` / `substring` / `concat` /
///   `join` / `equals` / `index_of` / `last_index_of` / `contains` /
///   `starts_with` / `ends_with` / `trim` / `trim_start` / `trim_end` /
///   `to_lower` / `to_upper` / `count` / `replace` / `split` / `from_char_code` /
///   `from_char_codes` (the linear arms guarded by `!is_user_fn` keep that
///   guard via `mig_guarded`).
///
/// Divergences (parity contract only, all `PreludeFallback`):
/// - `String::compare` has a single-pass SIMD arm in the linear backend
///   (ADR-0054); wasm-gc reaches the same result via the prelude. (Likewise
///   `String::replace_all` / `String::unicode_length` stay legacy: the former
///   has only a linear dedicated arm, the latter only a wasm-gc one, so neither
///   is a `registry_both` builtin.)
/// - Native float math (`Float`/`Double` ceil/floor/fract/round/sqrt/trunc)
///   and `Array::fold` have dedicated wasm-gc arms; the linear backend
///   routes them through the prelude / fallback path.
pub fn builtins() -> Array[BuiltinDecl] {
  [
    // --- migrated: table-driven on both backends ---
    registry_both("Char::to_int", Int),
    registry_both("Char::from_int", Int),
    registry_both("Int::to_float", Float),
    registry_both("Int::to_double", Double),
    registry_both("Float::to_int", Int),
    registry_both("Double::to_int", Int),
    registry_both("Float::to_double", Double),
    registry_both("Double::to_float", Float),
    registry_both("Int::abs", Int),
    registry_both("Int::max", Int),
    registry_both("Int::min", Int),
    registry_both("Int::clamp", Int),
    registry_both("Int::signum", Int),
    registry_both("Int::is_even", Int),
    registry_both("Int::is_odd", Int),
    registry_both("Bytes::from_array", Ref),
    registry_both("Bytes::from_string", Ref),
    registry_both("Bytes::to_string", Ref),
    registry_both("Bytes::length", Int),
    registry_both("Bytes::get", Int),
    registry_both("Bytes::new", Ref),
    registry_both("Bytes::push", Unit),
    registry_both("Bytes::set", Unit),
    registry_both("Bytes::append", Unit),
    registry_both("Bytes::blit", Unit),
    registry_both("Bytes::fill", Unit),
    registry_both("Bytes::slice", Ref),
    registry_both("Bytes::concat", Ref),
    registry_both("Bytes::to_array", Ref),
    // String:: namespace. Boolean-returning ops (equals / contains /
    // starts_with / ends_with) yield a tagged bool, shape Int.
    registry_both("String::length", Int),
    registry_both("String::char_code_at", Int),
    registry_both("String::substring", Ref),
    registry_both("String::concat", Ref),
    registry_both("String::join", Ref),
    registry_both("String::equals", Int),
    registry_both("String::index_of", Int),
    registry_both("String::last_index_of", Int),
    registry_both("String::contains", Int),
    registry_both("String::starts_with", Int),
    registry_both("String::ends_with", Int),
    registry_both("String::trim", Ref),
    registry_both("String::trim_start", Ref),
    registry_both("String::trim_end", Ref),
    registry_both("String::to_lower", Ref),
    registry_both("String::to_upper", Ref),
    registry_both("String::count", Int),
    registry_both("String::replace", Ref),
    registry_both("String::split", Ref),
    registry_both("String::from_char_code", Ref),
    registry_both("String::from_char_codes", Ref),
    // --- divergences (parity contract only) ---
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
/// Look up a builtin's metadata by name. Used by the parity gate. Returns
/// `None` when the registry hasn't taken ownership of the name yet.
pub fn find_builtin(name : String) -> BuiltinDecl? {
  for decl in builtins() {
    if decl.name == name {
      return Some(decl)
    }
  }
  None
}

///|
/// The per-backend codegen for a builtin the registry has migrated off the
/// legacy `match name` arms (Phase B-1). Kept separate from the public
/// `BuiltinDecl` because the compile fns reference package-private context
/// types (`CodegenCtx` / `GcCodegenCtx` ...) that a `pub(all)` struct may
/// not expose. `compile_gc` receives the positional arg expressions
/// pre-extracted by the wasm-gc `Call` dispatch.
priv struct MigratedBuiltin {
  compile_linear : (CodegenCtx, ByteBuf, Array[@core.CallArg]) -> Unit raise WasmGenError
  compile_gc : (GcCodegenCtx, GcFuncCtx, GcByteBuf, Array[@core.Expr]) -> Unit raise WasmGenError
  /// When true, the *linear* dispatch only uses this entry when the name
  /// does not resolve to a user/prelude function (`!is_user_fn`), mirroring
  /// the legacy `"Int::abs" if !is_user_fn =>` guards. The wasm-gc dispatch
  /// ignores this (it has no equivalent guard — preserved behavior).
  linear_skip_if_user_fn : Bool
}

///|
/// Constructor for a migrated builtin that always intercepts on both
/// backends (no user-fn shadowing guard).
fn mig(
  compile_linear : (CodegenCtx, ByteBuf, Array[@core.CallArg]) -> Unit raise WasmGenError,
  compile_gc : (GcCodegenCtx, GcFuncCtx, GcByteBuf, Array[@core.Expr]) -> Unit raise WasmGenError,
) -> MigratedBuiltin {
  MigratedBuiltin::{ compile_linear, compile_gc, linear_skip_if_user_fn: false }
}

///|
/// Constructor for a migrated builtin whose linear dispatch is guarded by
/// `!is_user_fn` (the int-math utilities).
fn mig_guarded(
  compile_linear : (CodegenCtx, ByteBuf, Array[@core.CallArg]) -> Unit raise WasmGenError,
  compile_gc : (GcCodegenCtx, GcFuncCtx, GcByteBuf, Array[@core.Expr]) -> Unit raise WasmGenError,
) -> MigratedBuiltin {
  MigratedBuiltin::{ compile_linear, compile_gc, linear_skip_if_user_fn: true }
}

///|
/// Single dispatch table feeding both backends. When this returns `Some`,
/// the linear and wasm-gc dispatch call the matching compile fn instead of
/// a legacy `match name` arm. Adding a migrated builtin is one arm here
/// (plus its metadata entry in `builtins()` for the parity gate).
fn migrated_builtin(name : String) -> MigratedBuiltin? {
  match name {
    // Char::to_int / Char::from_int are identity: a Char is a 62-bit
    // tagged int (ADR-0006), so the conversion just compiles its argument.
    "Char::to_int" | "Char::from_int" =>
      Some(mig(compile_char_identity_linear, compile_char_identity_gc))
    // Numeric widening / truncation conversions. Linear boxes f32/f64 and
    // tags ints; wasm-gc uses raw f32/f64/i64 — hence per-backend fns.
    "Int::to_float" =>
      Some(mig(compile_int_to_float_linear, compile_int_to_float_gc))
    "Int::to_double" =>
      Some(mig(compile_int_to_double_linear, compile_int_to_double_gc))
    "Float::to_int" =>
      Some(mig(compile_float_to_int_linear, compile_float_to_int_gc))
    "Double::to_int" =>
      Some(mig(compile_double_to_int_linear, compile_double_to_int_gc))
    "Float::to_double" =>
      Some(mig(compile_float_to_double_linear, compile_float_to_double_gc))
    "Double::to_float" =>
      Some(mig(compile_double_to_float_linear, compile_double_to_float_gc))
    // Integer math utilities. Operate on tagged i64 (linear) / raw i64
    // (wasm-gc); linear keeps the `!is_user_fn` shadowing guard.
    "Int::abs" => Some(mig_guarded(compile_int_abs_linear, compile_int_abs_gc))
    "Int::max" => Some(mig_guarded(compile_int_max_linear, compile_int_max_gc))
    "Int::min" => Some(mig_guarded(compile_int_min_linear, compile_int_min_gc))
    "Int::clamp" =>
      Some(mig_guarded(compile_int_clamp_linear, compile_int_clamp_gc))
    "Int::signum" =>
      Some(mig_guarded(compile_int_signum_linear, compile_int_signum_gc))
    "Int::is_even" =>
      Some(mig_guarded(compile_int_is_even_linear, compile_int_is_even_gc))
    "Int::is_odd" =>
      Some(mig_guarded(compile_int_is_odd_linear, compile_int_is_odd_gc))
    // Bytes:: namespace. Linear bodies are inline byte-buffer codegen; the
    // wasm-gc arms delegate to dedicated `compile_bytes_*_gc` fns. No
    // `!is_user_fn` guard (matches the legacy arms), so `mig`.
    "Bytes::from_array" =>
      Some(
        mig(compile_bytes_from_array_linear, compile_bytes_from_array_gc_arm),
      )
    "Bytes::from_string" =>
      Some(
        mig(compile_bytes_from_string_linear, compile_bytes_from_string_gc_arm),
      )
    "Bytes::to_string" =>
      Some(mig(compile_bytes_to_string_linear, compile_bytes_to_string_gc_arm))
    "Bytes::length" =>
      Some(mig(compile_bytes_length_linear, compile_bytes_length_gc_arm))
    "Bytes::get" =>
      Some(mig(compile_bytes_get_linear, compile_bytes_get_gc_arm))
    "Bytes::new" =>
      Some(mig(compile_bytes_new_linear, compile_bytes_new_gc_arm))
    "Bytes::push" =>
      Some(mig(compile_bytes_push_linear, compile_bytes_push_gc_arm))
    "Bytes::set" =>
      Some(mig(compile_bytes_set_linear, compile_bytes_set_gc_arm))
    "Bytes::append" =>
      Some(mig(compile_bytes_append_linear, compile_bytes_append_gc_arm))
    "Bytes::blit" =>
      Some(mig(compile_bytes_blit_linear, compile_bytes_blit_gc_arm))
    "Bytes::fill" =>
      Some(mig(compile_bytes_fill_linear, compile_bytes_fill_gc_arm))
    "Bytes::slice" =>
      Some(mig(compile_bytes_slice_linear, compile_bytes_slice_gc_arm))
    "Bytes::concat" =>
      Some(mig(compile_bytes_concat_linear, compile_bytes_concat_gc_arm))
    "Bytes::to_array" =>
      Some(mig(compile_bytes_to_array_linear, compile_bytes_to_array_gc_arm))
    // String:: namespace. Linear bodies inline byte-buffer codegen; wasm-gc
    // arms delegate to dedicated `compile_string_*` fns. The arms whose legacy
    // linear dispatch was `if !is_user_fn =>` keep that guard via `mig_guarded`.
    "String::length" =>
      Some(mig(compile_string_length_linear, compile_string_length_gc_arm))
    "String::char_code_at" =>
      Some(
        mig(
          compile_string_char_code_at_linear, compile_string_char_code_at_gc_arm,
        ),
      )
    "String::substring" =>
      Some(
        mig(compile_string_substring_linear, compile_string_substring_gc_arm),
      )
    "String::concat" =>
      Some(mig(compile_string_concat_linear, compile_string_concat_gc_arm))
    "String::join" =>
      Some(mig(compile_string_join_linear, compile_string_join_gc_arm))
    "String::equals" =>
      Some(mig(compile_string_equals_linear, compile_string_equals_gc_arm))
    "String::index_of" =>
      Some(mig(compile_string_index_of_linear, compile_string_index_of_gc_arm))
    "String::contains" =>
      Some(
        mig_guarded(
          compile_string_contains_linear, compile_string_contains_gc_arm,
        ),
      )
    "String::starts_with" =>
      Some(
        mig_guarded(
          compile_string_starts_with_linear, compile_string_starts_with_gc_arm,
        ),
      )
    "String::ends_with" =>
      Some(
        mig_guarded(
          compile_string_ends_with_linear, compile_string_ends_with_gc_arm,
        ),
      )
    "String::last_index_of" =>
      Some(
        mig_guarded(
          compile_string_last_index_of_linear, compile_string_last_index_of_gc_arm,
        ),
      )
    "String::count" =>
      Some(
        mig_guarded(compile_string_count_linear, compile_string_count_gc_arm),
      )
    "String::trim" =>
      Some(mig_guarded(compile_string_trim_linear, compile_string_trim_gc_arm))
    "String::trim_start" =>
      Some(
        mig_guarded(
          compile_string_trim_start_linear, compile_string_trim_start_gc_arm,
        ),
      )
    "String::trim_end" =>
      Some(
        mig_guarded(
          compile_string_trim_end_linear, compile_string_trim_end_gc_arm,
        ),
      )
    "String::to_upper" =>
      Some(
        mig_guarded(
          compile_string_to_upper_linear, compile_string_to_upper_gc_arm,
        ),
      )
    "String::to_lower" =>
      Some(
        mig_guarded(
          compile_string_to_lower_linear, compile_string_to_lower_gc_arm,
        ),
      )
    "String::replace" =>
      Some(
        mig_guarded(
          compile_string_replace_linear, compile_string_replace_gc_arm,
        ),
      )
    "String::split" =>
      Some(
        mig_guarded(compile_string_split_linear, compile_string_split_gc_arm),
      )
    "String::from_char_code" =>
      Some(
        mig(
          compile_string_from_char_code_linear, compile_string_from_char_code_gc_arm,
        ),
      )
    "String::from_char_codes" =>
      Some(
        mig(
          compile_string_from_char_codes_linear, compile_string_from_char_codes_gc_arm,
        ),
      )
    _ => None
  }
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
