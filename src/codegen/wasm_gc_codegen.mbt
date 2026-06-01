///|
priv struct GcByteBuf {
  mut data : FixedArray[Byte]
  mut len : Int
}

///|
fn GcByteBuf::new() -> GcByteBuf {
  { data: FixedArray::make(4096, b'\x00'), len: 0 }
}

///|
fn GcByteBuf::grow_to(self : GcByteBuf, needed : Int) -> Unit {
  let new_cap = if self.data.length() * 2 > needed {
    self.data.length() * 2
  } else {
    needed
  }
  let new_data = FixedArray::make(new_cap, b'\x00')
  FixedArray::unsafe_blit(new_data, 0, self.data, 0, self.len)
  self.data = new_data
}

///|
fn GcByteBuf::ensure(self : GcByteBuf, additional : Int) -> Unit {
  let needed = self.len + additional
  if needed > self.data.length() {
    self.grow_to(needed)
  }
}

///|
fn GcByteBuf::push(self : GcByteBuf, b : Int) -> Unit {
  if self.len == self.data.length() {
    self.grow_to(self.data.length() * 2)
  }
  self.data.unsafe_set(self.len, b.to_byte())
  self.len += 1
}

///|
fn GcByteBuf::extend(self : GcByteBuf, bytes : Array[Byte]) -> Unit {
  self.ensure(bytes.length())
  for i in 0..<bytes.length() {
    self.data.unsafe_set(self.len + i, bytes[i])
  }
  self.len += bytes.length()
}

///|
fn GcByteBuf::extend_buf(self : GcByteBuf, other : GcByteBuf) -> Unit {
  self.ensure(other.len)
  FixedArray::unsafe_blit(self.data, self.len, other.data, 0, other.len)
  self.len += other.len
}

///|
fn GcByteBuf::len(self : GcByteBuf) -> Int {
  self.len
}

///|
fn GcByteBuf::to_array(self : GcByteBuf) -> Array[Byte] {
  Array::makei(self.len, fn(i) { self.data[i] })
}

///|
fn GcByteBuf::to_bytes(self : GcByteBuf) -> Bytes {
  Bytes::from_array(self.to_array())
}

///|
/// Write a signed LEB128 value (s33) — required for GC heap type indices.
/// The GC spec encodes heap type references as signed s33 values where
/// non-negative values represent type indices.
fn write_s33_leb_gc(buf : GcByteBuf, n : Int) -> Unit {
  let mut value = n
  let mut more = true
  while more {
    let byte = value & 0x7f
    value = value >> 7
    if (value == 0 && (byte & 0x40) == 0) || (value == -1 && (byte & 0x40) != 0) {
      more = false
      buf.push(byte)
    } else {
      buf.push(byte | 0x80)
    }
  }
}

///|
fn write_u32_leb_gc(buf : GcByteBuf, n : Int) -> Unit {
  let u = n.reinterpret_as_uint()
  let v0 = (u & 0x7fU).reinterpret_as_int()
  let r0 = u >> 7
  if r0 == 0U {
    buf.push(v0)
    return
  }
  buf.push(v0 | 0x80)
  let v1 = (r0 & 0x7fU).reinterpret_as_int()
  let r1 = r0 >> 7
  if r1 == 0U {
    buf.push(v1)
    return
  }
  buf.push(v1 | 0x80)
  let v2 = (r1 & 0x7fU).reinterpret_as_int()
  let r2 = r1 >> 7
  if r2 == 0U {
    buf.push(v2)
    return
  }
  buf.push(v2 | 0x80)
  let v3 = (r2 & 0x7fU).reinterpret_as_int()
  let r3 = r2 >> 7
  if r3 == 0U {
    buf.push(v3)
    return
  }
  buf.push(v3 | 0x80)
  buf.push((r3 & 0x7fU).reinterpret_as_int())
}

///|
fn write_i32_leb_gc(buf : GcByteBuf, n : Int) -> Unit {
  write_i32_leb_gc_inner(buf, n, 0)
}

///|
fn write_i32_leb_gc_inner(buf : GcByteBuf, value : Int, depth : Int) -> Unit {
  let byte = value & 0x7f
  let rest = value >> 7
  let sign_bit_set = (byte & 0x40) != 0
  let done = (rest == 0 && !sign_bit_set) || (rest == -1 && sign_bit_set)
  if done {
    buf.push(byte)
  } else if depth < 4 {
    buf.push(byte | 0x80)
    write_i32_leb_gc_inner(buf, rest, depth + 1)
  } else {
    buf.push(byte)
  }
}

///|
priv enum GcValKind {
  I32
  I64
  F32
  F64
  AnyRef
  EqRef
  I31Ref
  StructRef
  ArrayRef
  FuncRef
  ExternRef
  Ref(Int)
} derive(Eq)

///|
priv enum GcTypeDef {
  Array(elem~ : GcValKind)
  Struct(fields~ : Array[GcValKind])
  Func(params~ : Array[GcValKind], result~ : GcValKind)
  TagFunc(params~ : Array[GcValKind])
}

///|
priv struct GcFuncDef {
  name : String
  params : Array[@core.FuncParam]
  ret : @core.Type?
  body : @core.Module
}

///|
priv struct GcFuncSig {
  params : Array[GcValKind]
  result : GcValKind
}

///|
priv struct GcLocalInfo {
  idx : Int
  kind : GcValKind
}

///|
priv struct GcFuncCtx {
  locals : Map[String, GcLocalInfo]
  map_value_kinds : Map[String, GcValKind]
  array_builder_elem_hints : Map[String, GcValKind]
  local_kinds : Array[GcValKind]
  param_count : Int
  closure_call_types : Map[String, Int]
  current_rec_binding : String?
  /// Name of the immediately-enclosing top-level function (or let-rec
  /// binding) — used only to label lifted closures in the wasm `name`
  /// section. Distinct from `current_rec_binding` so we don't conflate
  /// "is rec-callable" with "is the enclosing label".
  mut enclosing_function_name : String?
  direct_rec_call_name : String?
  direct_rec_call_func_idx : Int
  direct_rec_call_type_idx : Int
}

///|
priv struct GcWasmFunc {
  sig : GcFuncSig
  locals : Array[GcValKind]
  body : Array[Byte]
  type_idx : Int
}

///|
priv struct GcCodegenCtx {
  types : Array[GcTypeDef]
  struct_type_index : Map[String, Int]
  array_type_index : Map[String, Int]
  func_indices : Map[String, Int]
  func_param_counts : Map[String, Int]
  func_returns : Map[String, GcValKind]
  func_param_kinds : Map[String, Array[GcValKind]]
  string_type : Int
  array_i32_type : Int
  bytes_type : Int
  int64array_type : Int
  closure_fn_type_cache : Map[String, Int]
  closure_struct_type_cache : Map[String, Int]
  closure_lifted_funcs : Array[GcWasmFunc]
  /// Parallel labels for `closure_lifted_funcs` used by the wasm `name`
  /// custom section. Format: `<parent>::lambda@<offset>` when the
  /// lambda is bound to a let, `lambda@<offset>` for free lambdas, or
  /// `as_closure::<name>` for the wrapper synthesised when a top-level
  /// function is passed as a value. Surfaces in profiler / devtools.
  closure_lifted_labels : Array[String]
  closure_call_type_for_func : Map[String, Int]
  mut num_regular_funcs : Int
  enum_ctor_tags : Map[String, Int]
  enum_ctor_arities : Map[String, Int]
  enum_ctor_type_indices : Map[String, Int]
  enum_ctor_field_kinds : Map[String, Array[GcValKind]]
  enum_names : Map[String, Bool]
  /// Named struct types: name → gc struct type index
  named_struct_types : Map[String, Int]
  /// Named struct field order: name → sorted field names
  named_struct_fields : Map[String, Array[String]]
  /// Anonymous record types: type_idx → sorted field names. Populated
  /// by `infer_record_kind_gc` so later `__index(record, "field")`
  /// dispatches in `try_compile_struct_field_get_gc` can look up the
  /// field index even when the record was created via a record literal
  /// (no `struct Foo { ... }` declaration).
  record_field_names_by_type_idx : Map[Int, Array[String]]
  error_tag_index : Int
  error_tag_type_index : Int
  /// Compile-time known constants from top-level let bindings.
  /// Maps name → (global_index, val_kind)
  global_consts : Map[String, (Int, GcValKind)]
  // Top-level String constants. wasm globals don't take arbitrary
  // initializer expressions for struct/array refs without const ops, so
  // we keep the value as a MoonBit String and emit `emit_string_literal`
  // at every use site. Cheaper than a lazy-init global for the small
  // string constants that show up in practice (sha1 `hex_table`, etc.).
  string_consts : Map[String, String]
  mut needs_exceptions : Bool
  /// Issue #417 / Phase A: coverage instrumentation. When enabled,
  /// build_module_gc emits a `memory` section + two i32 globals
  /// (`__vibe_cov_base`, `__vibe_cov_count`) and every Line / Branch
  /// site emits an `i32.load + i32.add + i32.store` into linear
  /// memory at `coverage_base + id * 4`. The same JS reader
  /// (`scripts/coverage_wasm_source.mjs`) works against both
  /// backends — only the memory wiring differs.
  mut coverage_enabled : Bool
  coverage_points : Array[WasmCoveragePoint]
  /// Original source text, used only to upgrade lambda labels in the
  /// wasm `name` section from `lambda@<offset>` to
  /// `lambda@<line>:<col>`. Empty string disables the upgrade (labels
  /// stay at byte offsets) — kept optional so synthetic ASTs built by
  /// wbtests don't have to thread a string through.
  mut source : String
}

///|
/// Find a common supertype for two GcValKinds.
fn gc_common_kind(a : GcValKind, b : GcValKind) -> GcValKind {
  if a == b {
    return a
  }
  // Both refs → eqref
  match (a, b) {
    (GcValKind::Ref(_), GcValKind::Ref(_)) => GcValKind::EqRef
    (GcValKind::Ref(_), GcValKind::EqRef) => GcValKind::EqRef
    (GcValKind::EqRef, GcValKind::Ref(_)) => GcValKind::EqRef
    (GcValKind::I32, GcValKind::I64) => GcValKind::I64
    (GcValKind::I64, GcValKind::I32) => GcValKind::I64
    // Unit (I32) vs ref → eqref
    (GcValKind::I32, GcValKind::Ref(_)) => GcValKind::EqRef
    (GcValKind::Ref(_), GcValKind::I32) => GcValKind::EqRef
    (GcValKind::I32, GcValKind::EqRef) => GcValKind::EqRef
    (GcValKind::EqRef, GcValKind::I32) => GcValKind::EqRef
    // i64 / f32 / f64 vs EqRef — all box into eqref via the matching
    // `{i64}` / `{f32}` / `{f64}` wrapper struct that
    // `emit_box_top_for_ref_kind_gc` already understands. Previously
    // these fell through to AnyRef, which made the surrounding `if`
    // block declare a wider result type than its arms could supply and
    // broke wasm validation on prelude generics like
    // `num_abs[T: Signed + Ord + Sub](x: T) -> T`.
    (GcValKind::I64, GcValKind::EqRef) => GcValKind::EqRef
    (GcValKind::EqRef, GcValKind::I64) => GcValKind::EqRef
    (GcValKind::F32, GcValKind::EqRef) => GcValKind::EqRef
    (GcValKind::EqRef, GcValKind::F32) => GcValKind::EqRef
    (GcValKind::F64, GcValKind::EqRef) => GcValKind::EqRef
    (GcValKind::EqRef, GcValKind::F64) => GcValKind::EqRef
    _ => GcValKind::AnyRef
  }
}

///|
/// True for kinds that map directly to wasm numeric primitives.
fn gc_is_arith_kind(kind : GcValKind) -> Bool {
  match kind {
    GcValKind::I32 | GcValKind::I64 | GcValKind::F32 | GcValKind::F64 => true
    _ => false
  }
}

///|
/// Used to gate the prelude `add` / `sub` / `mul` / `div` / `eq` / `lt`
/// short-circuits — inline the wasm primitive only when *both* operands
/// resolve to numeric kinds. Otherwise fall through to the regular
/// call dispatch so a user-defined function (e.g.
/// `vibe/collection/set.vibe::add: (StringSet, String) -> StringSet`)
/// keeps working.
fn gc_call_args_arith(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  args : Array[@core.Expr],
) -> Bool raise WasmGenError {
  if args.length() != 2 {
    return false
  }
  let lk = infer_expr_kind_gc(ctx, fctx, args[0])
  let rk = infer_expr_kind_gc(ctx, fctx, args[1])
  gc_is_arith_kind(lk) && gc_is_arith_kind(rk)
}

///|
/// Map a unified value kind to the arithmetic primitive kind.
/// EqRef / Ref / AnyRef operands are treated as boxed I64.
fn gc_arith_kind(kind : GcValKind) -> GcValKind {
  match kind {
    GcValKind::I64 | GcValKind::I32 | GcValKind::F32 | GcValKind::F64 => kind
    _ => GcValKind::I64
  }
}

///|
fn emit_box_top_for_ref_kind_gc(
  ctx : GcCodegenCtx,
  buf : GcByteBuf,
  actual_kind : GcValKind,
  expected_kind : GcValKind,
) -> Unit {
  match expected_kind {
    GcValKind::AnyRef | GcValKind::EqRef =>
      match actual_kind {
        GcValKind::Ref(_)
        | GcValKind::AnyRef
        | GcValKind::EqRef
        | GcValKind::I31Ref
        | GcValKind::StructRef
        | GcValKind::ArrayRef
        | GcValKind::FuncRef
        | GcValKind::ExternRef => ()
        GcValKind::I64 => {
          let box_type = ensure_struct_type(ctx.types, ctx.struct_type_index, [
            GcValKind::I64,
          ])
          emit_struct_new_gc(buf, box_type)
        }
        GcValKind::I32 => {
          let box_type = ensure_struct_type(ctx.types, ctx.struct_type_index, [
            GcValKind::I32,
          ])
          emit_struct_new_gc(buf, box_type)
        }
        GcValKind::F32 => {
          let box_type = ensure_struct_type(ctx.types, ctx.struct_type_index, [
            GcValKind::F32,
          ])
          emit_struct_new_gc(buf, box_type)
        }
        GcValKind::F64 => {
          let box_type = ensure_struct_type(ctx.types, ctx.struct_type_index, [
            GcValKind::F64,
          ])
          emit_struct_new_gc(buf, box_type)
        }
      }
    _ => ()
  }
}

///|
fn emit_coerce_top_gc(
  ctx : GcCodegenCtx,
  buf : GcByteBuf,
  actual_kind : GcValKind,
  expected_kind : GcValKind,
) -> Unit {
  if actual_kind == expected_kind {
    return
  }
  match expected_kind {
    GcValKind::AnyRef | GcValKind::EqRef =>
      emit_box_top_for_ref_kind_gc(ctx, buf, actual_kind, expected_kind)
    GcValKind::Ref(type_idx) =>
      match actual_kind {
        GcValKind::Ref(actual_idx) =>
          if actual_idx != type_idx {
            emit_ref_cast_gc(buf, type_idx)
          }
        GcValKind::AnyRef
        | GcValKind::EqRef
        | GcValKind::StructRef
        | GcValKind::ArrayRef
        | GcValKind::FuncRef
        | GcValKind::ExternRef
        | GcValKind::I31Ref => emit_ref_cast_gc(buf, type_idx)
        _ => ()
      }
    GcValKind::I64 =>
      match actual_kind {
        GcValKind::I32 => emit_i64_extend_i32_s_gc(buf)
        GcValKind::AnyRef | GcValKind::EqRef | GcValKind::Ref(_) => {
          let box_type = ensure_struct_type(ctx.types, ctx.struct_type_index, [
            GcValKind::I64,
          ])
          emit_ref_cast_gc(buf, box_type)
          emit_struct_get_gc(buf, box_type, 0)
        }
        _ => ()
      }
    GcValKind::I32 =>
      match actual_kind {
        GcValKind::I64 => emit_i32_wrap_i64_gc(buf)
        GcValKind::AnyRef | GcValKind::EqRef | GcValKind::Ref(_) => {
          let box_type = ensure_struct_type(ctx.types, ctx.struct_type_index, [
            GcValKind::I32,
          ])
          emit_ref_cast_gc(buf, box_type)
          emit_struct_get_gc(buf, box_type, 0)
        }
        _ => ()
      }
    GcValKind::F32 =>
      match actual_kind {
        GcValKind::AnyRef | GcValKind::EqRef | GcValKind::Ref(_) => {
          let box_type = ensure_struct_type(ctx.types, ctx.struct_type_index, [
            GcValKind::F32,
          ])
          emit_ref_cast_gc(buf, box_type)
          emit_struct_get_gc(buf, box_type, 0)
        }
        _ => ()
      }
    GcValKind::F64 =>
      match actual_kind {
        GcValKind::AnyRef | GcValKind::EqRef | GcValKind::Ref(_) => {
          let box_type = ensure_struct_type(ctx.types, ctx.struct_type_index, [
            GcValKind::F64,
          ])
          emit_ref_cast_gc(buf, box_type)
          emit_struct_get_gc(buf, box_type, 0)
        }
        _ => ()
      }
    _ => ()
  }
}

///|
fn gc_val_kind_key(kind : GcValKind) -> String {
  match kind {
    GcValKind::I32 => "i32"
    GcValKind::I64 => "i64"
    GcValKind::F32 => "f32"
    GcValKind::F64 => "f64"
    GcValKind::AnyRef => "anyref"
    GcValKind::EqRef => "eqref"
    GcValKind::I31Ref => "i31ref"
    GcValKind::StructRef => "structref"
    GcValKind::ArrayRef => "arrayref"
    GcValKind::FuncRef => "funcref"
    GcValKind::ExternRef => "externref"
    GcValKind::Ref(idx) => "ref:" + idx.to_string()
  }
}

///|
fn struct_key(fields : Array[GcValKind]) -> String {
  let sb = StringBuilder::new()
  sb.write_string("struct:")
  let mut first = true
  for k in fields {
    if first {
      first = false
    } else {
      sb.write_char(',')
    }
    sb.write_string(gc_val_kind_key(k))
  }
  sb.to_string()
}

///|
fn array_key(elem : GcValKind) -> String {
  "array:" + gc_val_kind_key(elem)
}

///|
fn ensure_array_type(
  types : Array[GcTypeDef],
  index : Map[String, Int],
  elem : GcValKind,
) -> Int {
  let key = array_key(elem)
  match index.get(key) {
    Some(idx) => idx
    None => {
      let idx = types.length()
      types.push(GcTypeDef::Array(elem~))
      index[key] = idx
      idx
    }
  }
}

///|
fn ensure_struct_type(
  types : Array[GcTypeDef],
  index : Map[String, Int],
  fields : Array[GcValKind],
) -> Int {
  let key = struct_key(fields)
  match index.get(key) {
    Some(idx) => idx
    None => {
      let idx = types.length()
      types.push(GcTypeDef::Struct(fields~))
      index[key] = idx
      idx
    }
  }
}

///|
fn GcCodegenCtx::new() -> GcCodegenCtx {
  let types : Array[GcTypeDef] = []
  let struct_type_index : Map[String, Int] = {}
  let array_type_index : Map[String, Int] = {}
  let array_i32_type = ensure_array_type(
    types,
    array_type_index,
    GcValKind::I32,
  )
  let string_fields : Array[GcValKind] = [
    GcValKind::I32,
    GcValKind::Ref(array_i32_type),
  ]
  let string_type = ensure_struct_type(types, struct_type_index, string_fields)
  // Bytes struct: (len: i32, cap: i32, data: ref array<i32>)
  let bytes_fields : Array[GcValKind] = [
    GcValKind::I32,
    GcValKind::I32,
    GcValKind::Ref(array_i32_type),
  ]
  let bytes_type = ensure_struct_type(types, struct_type_index, bytes_fields)
  // Int64Array struct: (len: i32, data: ref array<i64>) — i64 cells store
  // Int values without the 30-bit truncation of the linear Array[Int] (#429).
  let array_i64_type = ensure_array_type(
    types,
    array_type_index,
    GcValKind::I64,
  )
  let int64array_fields : Array[GcValKind] = [
    GcValKind::I32,
    GcValKind::Ref(array_i64_type),
  ]
  let int64array_type = ensure_struct_type(
    types, struct_type_index, int64array_fields,
  )
  // Error tag type: (eqref) -> [] — a tag carrying one eqref payload
  let error_tag_type_index = types.length()
  types.push(GcTypeDef::TagFunc(params=[GcValKind::EqRef]))
  let error_tag_index = 0 // The first (and only) tag
  {
    types,
    struct_type_index,
    array_type_index,
    func_indices: {},
    func_param_counts: {},
    func_returns: {},
    func_param_kinds: {},
    string_type,
    array_i32_type,
    bytes_type,
    int64array_type,
    closure_fn_type_cache: {},
    closure_struct_type_cache: {},
    closure_lifted_funcs: [],
    closure_lifted_labels: [],
    closure_call_type_for_func: {},
    num_regular_funcs: 0,
    enum_ctor_tags: {},
    enum_ctor_arities: {},
    enum_ctor_type_indices: {},
    enum_ctor_field_kinds: {},
    enum_names: {},
    named_struct_types: {},
    named_struct_fields: {},
    record_field_names_by_type_idx: {},
    error_tag_index,
    error_tag_type_index,
    global_consts: {},
    string_consts: {},
    needs_exceptions: false,
    coverage_enabled: false,
    coverage_points: [],
    source: "",
  }
}

///|
fn write_valtype_gc(buf : GcByteBuf, kind : GcValKind) -> Unit {
  match kind {
    GcValKind::I32 => buf.push(0x7f)
    GcValKind::I64 => buf.push(0x7e)
    GcValKind::F32 => buf.push(0x7d)
    GcValKind::F64 => buf.push(0x7c)
    GcValKind::AnyRef => buf.push(0x6e)
    GcValKind::EqRef => buf.push(0x6d)
    GcValKind::I31Ref => buf.push(0x6c)
    GcValKind::StructRef => buf.push(0x6b)
    GcValKind::ArrayRef => buf.push(0x6a)
    GcValKind::FuncRef => buf.push(0x70)
    GcValKind::ExternRef => buf.push(0x6f)
    GcValKind::Ref(idx) => {
      buf.push(0x63) // ref null
      write_s33_leb_gc(buf, idx) // heap type index as s33
    }
  }
}

///|
fn write_block_type_gc(buf : GcByteBuf, result : GcValKind?) -> Unit {
  match result {
    Some(kind) => write_valtype_gc(buf, kind)
    None => buf.push(0x40)
  }
}

///|
fn emit_i32_const_gc(buf : GcByteBuf, n : Int) -> Unit {
  buf.push(0x41)
  write_i32_leb_gc(buf, n)
}

///|
fn emit_drop_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x1a)
}

///|
fn emit_unreachable_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x00)
}

///|
fn emit_local_get_gc(buf : GcByteBuf, idx : Int) -> Unit {
  buf.push(0x20)
  write_u32_leb_gc(buf, idx)
}

///|
fn emit_local_set_gc(buf : GcByteBuf, idx : Int) -> Unit {
  buf.push(0x21)
  write_u32_leb_gc(buf, idx)
}

///|
fn emit_local_tee_gc(buf : GcByteBuf, idx : Int) -> Unit {
  buf.push(0x22)
  write_u32_leb_gc(buf, idx)
}

///|
fn emit_call_gc(buf : GcByteBuf, idx : Int) -> Unit {
  buf.push(0x10)
  write_u32_leb_gc(buf, idx)
}

///|
fn emit_global_get_gc(buf : GcByteBuf, idx : Int) -> Unit {
  buf.push(0x23)
  write_u32_leb_gc(buf, idx)
}

///|
fn emit_global_set_gc(buf : GcByteBuf, idx : Int) -> Unit {
  buf.push(0x24)
  write_u32_leb_gc(buf, idx)
}

///|
fn emit_i32_add_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x6a)
}

///|
/// i32.load align=2 offset=0 (the 4-byte aligned counter at the i32 addr
/// already on the value stack).
fn emit_i32_load_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x28)
  buf.push(0x02) // align = 2 → 4-byte
  buf.push(0x00) // offset = 0
}

///|
/// i32.store align=2 offset=0.
fn emit_i32_store_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x36)
  buf.push(0x02)
  buf.push(0x00)
}

///|
/// Issue #417: register a coverage point and emit the increment ops
/// when coverage is enabled. Mirrors `emit_coverage` in the linear
/// backend but writes to linear memory through wasm-gc opcodes.
///
///     i32.const addr      ; address for store
///     i32.const addr      ; address for load
///     i32.load 2 0        ; current counter
///     i32.const 1
///     i32.add
///     i32.store 2 0       ; bump counter
fn emit_coverage_gc(
  ctx : GcCodegenCtx,
  buf : GcByteBuf,
  kind : WasmCoveragePointKind,
  span : @core.Span,
) -> Unit {
  if !ctx.coverage_enabled {
    return
  }
  let id = ctx.coverage_points.length()
  ctx.coverage_points.push({ id, kind, span })
  let addr = id * 4
  emit_i32_const_gc(buf, addr)
  emit_i32_const_gc(buf, addr)
  emit_i32_load_gc(buf)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_i32_store_gc(buf)
}

///|
fn emit_i32_sub_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x6b)
}

///|
fn emit_i32_mul_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x6c)
}

///|
fn emit_i32_div_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x6d)
}

///|
fn emit_i32_eqz_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x45)
}

///|
fn emit_i32_rem_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x6f)
}

///|
fn emit_f32_const_gc(buf : GcByteBuf, n : Float) -> Unit {
  buf.push(0x43)
  let bytes = Float::to_le_bytes(n)
  buf.extend(bytes.to_array())
}

///|
fn emit_f64_const_gc(buf : GcByteBuf, n : Double) -> Unit {
  buf.push(0x44)
  let bits = Double::reinterpret_as_uint64(n)
  let bytes = UInt64::to_le_bytes(bits)
  buf.extend(bytes.to_array())
}

///|
fn emit_f32_add_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x92)
}

///|
fn emit_f32_sub_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x93)
}

///|
fn emit_f32_mul_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x94)
}

///|
fn emit_f32_div_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x95)
}

///|
fn emit_f32_eq_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x5b)
}

///|
fn emit_f32_lt_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x5d)
}

///|
fn emit_f32_neg_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x8c)
}

///|
fn emit_f64_add_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xa0)
}

///|
fn emit_f64_sub_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xa1)
}

///|
fn emit_f64_mul_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xa2)
}

///|
fn emit_f64_div_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xa3)
}

///|
fn emit_f64_eq_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x61)
}

///|
fn emit_f64_lt_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x63)
}

///|
fn emit_f64_neg_gc(buf : GcByteBuf) -> Unit {
  // f64.neg is 0x9a — 0x99 is f64.abs (the prior typo made `-x`
  // come out as `abs(x)`, e.g. `Double::abs(-3.5)` collapsed to
  // `Double::abs(3.5)` and the assertion still tripped because the
  // codegen also routed `eq` through i64.eq on f64 operands).
  buf.push(0x9a)
}

///|
fn write_i64_leb_gc(buf : GcByteBuf, n : Int64) -> Unit {
  let mut value = n
  while true {
    let mut byte = (value & 0x7fL).to_int()
    value = value >> 7
    let sign_bit_set = (byte & 0x40) != 0
    let done = (value == 0L && !sign_bit_set) || (value == -1L && sign_bit_set)
    if !done {
      byte = byte | 0x80
    }
    buf.push(byte)
    if done {
      break
    }
  }
}

///|
fn emit_i64_const_gc(buf : GcByteBuf, n : Int64) -> Unit {
  buf.push(0x42)
  write_i64_leb_gc(buf, n)
}

///|
fn emit_i64_add_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x7c)
}

///|
fn emit_i64_sub_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x7d)
}

///|
fn emit_i64_mul_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x7e)
}

///|
fn emit_i64_div_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x7f)
}

///|
fn emit_i64_rem_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x81)
}

///|
fn emit_i64_and_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x83)
}

///|
fn emit_i64_or_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x84)
}

///|
fn emit_i64_xor_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x85)
}

///|
fn emit_i64_shl_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x86)
}

///|
fn emit_i64_shr_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x87)
}

///|
fn emit_f64_convert_i64_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xb9)
}

///|
fn emit_i64_trunc_f64_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xb0)
}

///|
fn emit_f32_convert_i64_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xb4)
}

///|
fn emit_i64_trunc_f32_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xae)
}

///|
fn emit_f64_promote_f32_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xbb)
}

///|
fn emit_f32_demote_f64_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xb6)
}

///|
fn emit_f64_reinterpret_i64_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xbf)
}

///|
fn emit_i64_eq_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x51)
}

///|
fn emit_i64_extend_i32_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xac)
}

///|
fn emit_i32_wrap_i64_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xa7)
}

///|
fn emit_i64_lt_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x53)
}

///|
fn emit_i64_ne_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x52)
}

///|
fn emit_i64_gt_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x55)
}

///|
fn emit_i64_le_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x57)
}

///|
fn emit_i64_ge_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x59)
}

///|
fn emit_i32_eq_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x46)
}

///|
fn emit_i32_and_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x71)
}

///|
fn emit_i32_or_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x72)
}

///|
fn emit_i32_shl_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x74)
}

///|
fn emit_i32_shr_u_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x76)
}

///|
fn emit_i32_ne_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x47)
}

///|
fn emit_i32_lt_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x48)
}

///|
fn emit_i32_gt_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x4a)
}

///|
fn emit_i32_le_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x4c)
}

///|
fn emit_i32_ge_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x4e)
}

///|
fn emit_ref_eq_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xd3)
}

///|
fn emit_block_gc(buf : GcByteBuf, result : GcValKind?) -> Unit {
  buf.push(0x02)
  write_block_type_gc(buf, result)
}

///|
fn emit_loop_gc(buf : GcByteBuf, result : GcValKind?) -> Unit {
  buf.push(0x03)
  write_block_type_gc(buf, result)
}

///|
fn emit_if_gc(buf : GcByteBuf, result : GcValKind?) -> Unit {
  buf.push(0x04)
  write_block_type_gc(buf, result)
}

///|
fn emit_else_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x05)
}

///|
fn emit_end_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x0b)
}

///|
fn emit_br_gc(buf : GcByteBuf, depth : Int) -> Unit {
  buf.push(0x0c)
  write_u32_leb_gc(buf, depth)
}

///|
/// wasm `return` (0x0F): unwind to the current function boundary.
fn emit_return_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x0f)
}

///|
fn emit_br_if_gc(buf : GcByteBuf, depth : Int) -> Unit {
  buf.push(0x0d)
  write_u32_leb_gc(buf, depth)
}

///|
fn emit_struct_new_gc(buf : GcByteBuf, type_idx : Int) -> Unit {
  buf.push(0xfb)
  buf.push(0x00)
  write_u32_leb_gc(buf, type_idx)
}

///|
fn emit_struct_get_gc(buf : GcByteBuf, type_idx : Int, field_idx : Int) -> Unit {
  buf.push(0xfb)
  buf.push(0x02)
  write_u32_leb_gc(buf, type_idx)
  write_u32_leb_gc(buf, field_idx)
}

///|
fn emit_struct_set_gc(buf : GcByteBuf, type_idx : Int, field_idx : Int) -> Unit {
  buf.push(0xfb)
  buf.push(0x05)
  write_u32_leb_gc(buf, type_idx)
  write_u32_leb_gc(buf, field_idx)
}

///|
fn emit_array_new_default_gc(buf : GcByteBuf, type_idx : Int) -> Unit {
  buf.push(0xfb)
  buf.push(0x07)
  write_u32_leb_gc(buf, type_idx)
}

///|
/// `array.new $t` — pops (initial_value: $t, length: i32),
/// pushes (ref $t) of the given length filled with the value.
fn emit_array_new_gc(buf : GcByteBuf, type_idx : Int) -> Unit {
  buf.push(0xfb)
  buf.push(0x06)
  write_u32_leb_gc(buf, type_idx)
}

///|
/// `array.copy $dst $src` — pops (dst_ref, dst_off: i32, src_ref,
/// src_off: i32, len: i32). Same type used for src and dst.
fn emit_array_copy_gc(buf : GcByteBuf, type_idx : Int) -> Unit {
  buf.push(0xfb)
  buf.push(0x11)
  write_u32_leb_gc(buf, type_idx)
  write_u32_leb_gc(buf, type_idx)
}

///|
fn emit_array_new_fixed_gc(
  buf : GcByteBuf,
  type_idx : Int,
  count : Int,
) -> Unit {
  buf.push(0xfb)
  buf.push(0x08)
  write_u32_leb_gc(buf, type_idx)
  write_u32_leb_gc(buf, count)
}

///|
fn emit_array_get_gc(buf : GcByteBuf, type_idx : Int) -> Unit {
  buf.push(0xfb)
  buf.push(0x0b)
  write_u32_leb_gc(buf, type_idx)
}

///|
fn emit_array_set_gc(buf : GcByteBuf, type_idx : Int) -> Unit {
  buf.push(0xfb)
  buf.push(0x0e)
  write_u32_leb_gc(buf, type_idx)
}

///|
fn emit_array_len_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xfb)
  buf.push(0x0f)
}

///|
fn emit_ref_func_gc(buf : GcByteBuf, func_idx : Int) -> Unit {
  buf.push(0xd2)
  write_u32_leb_gc(buf, func_idx)
}

///|
fn emit_call_ref_gc(buf : GcByteBuf, type_idx : Int) -> Unit {
  buf.push(0x14)
  write_u32_leb_gc(buf, type_idx)
}

///|
fn emit_ref_cast_gc(buf : GcByteBuf, type_idx : Int) -> Unit {
  buf.push(0xfb)
  buf.push(0x17)
  write_u32_leb_gc(buf, type_idx)
}

///|
fn emit_ref_test_gc(buf : GcByteBuf, type_idx : Int) -> Unit {
  buf.push(0xfb)
  buf.push(0x15)
  write_u32_leb_gc(buf, type_idx)
}

///|
fn emit_ref_null_any_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xd0)
  buf.push(0x6e)
}

///|
fn scan_enum_defs_gc(
  ctx : GcCodegenCtx,
  ast : @core.Module,
) -> Unit raise WasmGenError {
  let mut next_tag = 0
  for stmt in ast.stmts {
    let (enum_name, ctors) = match stmt {
      @core.Stmt::EnumDef(name~, ctors~, ..) => (name, ctors)
      @core.Stmt::ExportEnumDef(name~, ctors~, ..) => (name, ctors)
      @core.Stmt::InternalExportEnumDef(name~, ctors~, ..) => (name, ctors)
      _ => continue
    }
    ctx.enum_names[enum_name] = true
    for ctor in ctors {
      if !ctx.enum_ctor_tags.contains(ctor.name) {
        ctx.enum_ctor_tags[ctor.name] = next_tag
        next_tag += 1
      }
      let tag = ctx.enum_ctor_tags[ctor.name]
      ctx.enum_ctor_arities[ctor.name] = ctor.args.length()
      // Build per-variant struct type: [i32 tag, payload_0, ..., payload_n]
      let field_kinds : Array[GcValKind] = [GcValKind::I32]
      let payload_kinds : Array[GcValKind] = []
      for arg in ctor.args {
        let kind = gc_val_kind_from_type(ctx, arg)
        field_kinds.push(kind)
        payload_kinds.push(kind)
      }
      let type_idx = ensure_struct_type(
        ctx.types,
        ctx.struct_type_index,
        field_kinds,
      )
      ctx.enum_ctor_type_indices[ctor.name] = type_idx
      ctx.enum_ctor_field_kinds[ctor.name] = payload_kinds
      // Register qualified form: EnumName::CtorName
      let qualified = enum_name + "::" + ctor.name
      if !ctx.enum_ctor_tags.contains(qualified) {
        ctx.enum_ctor_tags[qualified] = tag
        ctx.enum_ctor_arities[qualified] = ctor.args.length()
        ctx.enum_ctor_type_indices[qualified] = type_idx
        ctx.enum_ctor_field_kinds[qualified] = payload_kinds
      }
    }
  }
  // Register builtin Option enum (Some/None) if not already defined
  if !ctx.enum_ctor_tags.contains("Some") {
    let some_tag = next_tag
    next_tag += 1
    ctx.enum_ctor_tags["Some"] = some_tag
    ctx.enum_ctor_arities["Some"] = 1
    // Use EqRef payload so both I64 and ref types can be stored
    // (I64 values will need wrapping — handled by compile_expr_gc)
    let some_fields : Array[GcValKind] = [GcValKind::I32, GcValKind::EqRef]
    let some_type = ensure_struct_type(
      ctx.types,
      ctx.struct_type_index,
      some_fields,
    )
    ctx.enum_ctor_type_indices["Some"] = some_type
    ctx.enum_ctor_field_kinds["Some"] = [GcValKind::EqRef]
  }
  if !ctx.enum_ctor_tags.contains("None") {
    let none_tag = next_tag
    let _ = next_tag + 1
    ctx.enum_ctor_tags["None"] = none_tag
    ctx.enum_ctor_arities["None"] = 0
    let none_fields : Array[GcValKind] = [GcValKind::I32]
    let none_type = ensure_struct_type(
      ctx.types,
      ctx.struct_type_index,
      none_fields,
    )
    ctx.enum_ctor_type_indices["None"] = none_type
    ctx.enum_ctor_field_kinds["None"] = []
  }
  ctx.enum_names["Option"] = true
}

///|
/// Register named struct types from StructDef statements.
/// Maps struct name → gc struct type index, and tracks field order.
fn register_struct_types_gc(
  ctx : GcCodegenCtx,
  ast : @core.Module,
) -> Unit raise WasmGenError {
  for stmt in ast.stmts {
    let (struct_name, fields) = match stmt {
      @core.Stmt::StructDef(name~, fields~, ..) => (name, fields)
      @core.Stmt::ExportStructDef(name~, fields~, ..) => (name, fields)
      @core.Stmt::InternalExportStructDef(name~, fields~, ..) => (name, fields)
      _ => continue
    }
    // Sort fields alphabetically (same order as record types)
    let sorted_names : Array[String] = []
    for f in fields {
      sorted_names.push(f.name)
    }
    // Insertion sort by name
    for i in 1..<sorted_names.length() {
      let mut j = i
      while j > 0 && addr_string_lt(sorted_names[j], sorted_names[j - 1]) {
        let tmp = sorted_names[j - 1]
        sorted_names[j - 1] = sorted_names[j]
        sorted_names[j] = tmp
        j -= 1
      }
    }
    // Build field type map
    let field_types : Map[String, @core.Type] = {}
    for f in fields {
      field_types[f.name] = f.ty
    }
    // Create gc struct type with sorted field kinds
    let gc_field_kinds : Array[GcValKind] = []
    for name in sorted_names {
      match field_types.get(name) {
        Some(ty) => gc_field_kinds.push(gc_val_kind_from_type(ctx, ty))
        None => ()
      }
    }
    let type_idx = ensure_struct_type(
      ctx.types,
      ctx.struct_type_index,
      gc_field_kinds,
    )
    ctx.named_struct_types[struct_name] = type_idx
    ctx.named_struct_fields[struct_name] = sorted_names
  }
}

///|
/// Try to compile a struct field assignment: `record.field = value` →
/// `struct.set`. Returns true on success. Used by `Stmt::IndexAssign` when
/// the index is a string literal naming a struct field. The struct itself
/// must already be registered via `register_struct_types_gc`. The caller
/// is responsible for the "field must be declared `mut`" policy — by the
/// time we land here the typechecker has already approved the write.
fn try_compile_struct_field_set_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  field_name : String,
  record_expr : @core.Expr,
  value_expr : @core.Expr,
) -> Bool raise WasmGenError {
  let record_kind = infer_expr_kind_gc(ctx, fctx, record_expr)
  match record_kind {
    GcValKind::Ref(type_idx) => {
      for struct_name, struct_type_idx in ctx.named_struct_types {
        if struct_type_idx == type_idx {
          match ctx.named_struct_fields.get(struct_name) {
            Some(field_names) =>
              for i in 0..<field_names.length() {
                if field_names[i] == field_name {
                  compile_expr_gc(ctx, fctx, buf, record_expr)
                  compile_expr_gc(ctx, fctx, buf, value_expr)
                  emit_struct_set_gc(buf, type_idx, i)
                  return true
                }
              }
            None => ()
          }
        }
      }
      false
    }
    _ => false
  }
}

///|
/// Try to compile a struct field access: field_name(record_expr) → struct.get.
/// Returns true if the access was successfully compiled, false otherwise.
fn try_compile_struct_field_get_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  field_name : String,
  record_expr : @core.Expr,
) -> Bool raise WasmGenError {
  let record_kind = infer_expr_kind_gc(ctx, fctx, record_expr)
  match record_kind {
    GcValKind::Ref(type_idx) => {
      // Check if this struct type belongs to a named struct with this field
      for struct_name, struct_type_idx in ctx.named_struct_types {
        if struct_type_idx == type_idx {
          match ctx.named_struct_fields.get(struct_name) {
            Some(field_names) =>
              for i in 0..<field_names.length() {
                if field_names[i] == field_name {
                  compile_expr_gc(ctx, fctx, buf, record_expr)
                  emit_struct_get_gc(buf, type_idx, i)
                  return true
                }
              }
            None => ()
          }
        }
      }
      // Anonymous record literal: look up the sorted field-name order
      // populated by `infer_record_kind_gc`. Lets `r.field` resolve
      // when `r` came from `record { ... }` rather than a named struct.
      match ctx.record_field_names_by_type_idx.get(type_idx) {
        Some(field_names) =>
          for i in 0..<field_names.length() {
            if field_names[i] == field_name {
              compile_expr_gc(ctx, fctx, buf, record_expr)
              emit_struct_get_gc(buf, type_idx, i)
              return true
            }
          }
        None => ()
      }
      false
    }
    _ => false
  }
}

///|
/// Try to infer the GcValKind for a struct field access.
/// Returns Some(kind) if field_name is a valid field of the record expression's struct type.
fn try_infer_struct_field_kind_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  field_name : String,
  record_expr : @core.Expr,
) -> GcValKind? raise WasmGenError {
  let record_kind = infer_expr_kind_gc(ctx, fctx, record_expr)
  match record_kind {
    GcValKind::Ref(type_idx) => {
      for struct_name, struct_type_idx in ctx.named_struct_types {
        if struct_type_idx == type_idx {
          match ctx.named_struct_fields.get(struct_name) {
            Some(field_names) =>
              for i in 0..<field_names.length() {
                if field_names[i] == field_name {
                  match ctx.types[type_idx] {
                    GcTypeDef::Struct(fields~) =>
                      if i < fields.length() {
                        return Some(fields[i])
                      }
                    _ => ()
                  }
                }
              }
            None => ()
          }
        }
      }
      None
    }
    _ => None
  }
}

///|
fn collect_free_vars_expr_gc(
  expr : @core.Expr,
  bound : Map[String, Bool],
  free : Map[String, Bool],
) -> Unit {
  match expr {
    @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::Char(..)
    | @core.Expr::String(..) => ()
    @core.Expr::Ident(name~, ..) =>
      if !bound.contains(name) {
        free[name] = true
      }
    @core.Expr::Call(args~, ..) =>
      for arg in args {
        collect_free_vars_expr_gc(arg.expr, bound, free)
      }
    @core.Expr::Fn(params~, body~, ..) => {
      let inner_bound : Map[String, Bool] = {}
      for k, v in bound {
        inner_bound[k] = v
      }
      for param in params {
        inner_bound[param.name] = true
      }
      collect_free_vars_module_gc(body, inner_bound, free)
    }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      collect_free_vars_expr_gc(cond, bound, free)
      collect_free_vars_module_gc(then_body, bound, free)
      collect_free_vars_module_gc(else_body, bound, free)
    }
    @core.Expr::Block(body~, ..) =>
      collect_free_vars_module_gc(body, bound, free)
    @core.Expr::Array(items~, ..) =>
      for item in items {
        collect_free_vars_expr_gc(item, bound, free)
      }
    @core.Expr::While(cond~, body~, ..) => {
      collect_free_vars_expr_gc(cond, bound, free)
      collect_free_vars_module_gc(body, bound, free)
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, ..) => {
      collect_free_vars_expr_gc(iterable, bound, free)
      let inner_bound : Map[String, Bool] = {}
      for k, v in bound {
        inner_bound[k] = v
      }
      inner_bound[value_name] = true
      match index_name {
        Some(n) => inner_bound[n] = true
        None => ()
      }
      collect_free_vars_module_gc(body, inner_bound, free)
    }
    @core.Expr::Tuple(items~, ..) =>
      for item in items {
        collect_free_vars_expr_gc(item, bound, free)
      }
    @core.Expr::Record(fields~, ..) =>
      for field in fields {
        collect_free_vars_expr_gc(field.expr, bound, free)
      }
    @core.Expr::StructLit(fields~, ..) =>
      for field in fields {
        collect_free_vars_expr_gc(field.expr, bound, free)
      }
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      collect_free_vars_expr_gc(scrutinee, bound, free)
      for arm in arms {
        let inner_bound : Map[String, Bool] = {}
        for k, v in bound {
          inner_bound[k] = v
        }
        collect_free_vars_pat_gc(arm.pat, inner_bound)
        collect_free_vars_expr_gc(arm.expr, inner_bound, free)
      }
    }
    @core.Expr::Handle(body~, arms~, ..) => {
      collect_free_vars_module_gc(body, bound, free)
      for arm in arms {
        let inner_bound : Map[String, Bool] = {}
        for k, v in bound {
          inner_bound[k] = v
        }
        collect_free_vars_pat_gc(arm.pat, inner_bound)
        collect_free_vars_expr_gc(arm.expr, inner_bound, free)
      }
    }
    @core.Expr::Perform(args~, ..) =>
      for arg in args {
        collect_free_vars_expr_gc(arg.expr, bound, free)
      }
    _ => ()
  }
}

///|
fn collect_free_vars_pat_gc(pat : @core.Pat, bound : Map[String, Bool]) -> Unit {
  match pat {
    @core.Pat::Bind(name~, ..) => bound[name] = true
    @core.Pat::Tuple(items~, ..) =>
      for item in items {
        collect_free_vars_pat_gc(item, bound)
      }
    @core.Pat::Ctor(args~, ..) =>
      for arg in args {
        collect_free_vars_pat_gc(arg, bound)
      }
    @core.Pat::Record(fields~, ..) | @core.Pat::Struct(fields~, ..) =>
      for field in fields {
        collect_free_vars_pat_gc(field.pat, bound)
      }
    _ => ()
  }
}

///|
/// Collect all function call target names from a module (for closure capture).
fn collect_call_names_module_gc(
  body : @core.Module,
  names : Map[String, Bool],
) -> Unit {
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(expr~, ..)
      | @core.Stmt::ExportLet(expr~, ..)
      | @core.Stmt::InternalExportLet(expr~, ..)
      | @core.Stmt::LetMut(expr~, ..) => collect_call_names_expr_gc(expr, names)
      @core.Stmt::Assign(expr~, ..) => collect_call_names_expr_gc(expr, names)
      @core.Stmt::Expr(expr~, ..) => collect_call_names_expr_gc(expr, names)
      _ => ()
    }
  }
}

///|
fn collect_call_names_expr_gc(
  expr : @core.Expr,
  names : Map[String, Bool],
) -> Unit {
  match expr {
    @core.Expr::Call(name~, args~, ..) => {
      names[name] = true
      for arg in args {
        collect_call_names_expr_gc(arg.expr, names)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      collect_call_names_expr_gc(cond, names)
      collect_call_names_module_gc(then_body, names)
      collect_call_names_module_gc(else_body, names)
    }
    @core.Expr::Block(body~, ..) => collect_call_names_module_gc(body, names)
    @core.Expr::Fn(body~, ..) => collect_call_names_module_gc(body, names)
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      collect_call_names_expr_gc(scrutinee, names)
      for arm in arms {
        collect_call_names_expr_gc(arm.expr, names)
      }
    }
    @core.Expr::Handle(body~, arms~, ..) => {
      collect_call_names_module_gc(body, names)
      for arm in arms {
        collect_call_names_expr_gc(arm.expr, names)
      }
    }
    @core.Expr::While(cond~, body~, ..) => {
      collect_call_names_expr_gc(cond, names)
      collect_call_names_module_gc(body, names)
    }
    @core.Expr::ForIn(iterable~, body~, ..) => {
      collect_call_names_expr_gc(iterable, names)
      collect_call_names_module_gc(body, names)
    }
    @core.Expr::Array(items~, ..) =>
      for item in items {
        collect_call_names_expr_gc(item, names)
      }
    @core.Expr::Tuple(items~, ..) =>
      for item in items {
        collect_call_names_expr_gc(item, names)
      }
    @core.Expr::Record(fields~, ..) =>
      for field in fields {
        collect_call_names_expr_gc(field.expr, names)
      }
    @core.Expr::StructLit(fields~, ..) =>
      for field in fields {
        collect_call_names_expr_gc(field.expr, names)
      }
    _ => ()
  }
}

///|
fn collect_free_vars_module_gc(
  body : @core.Module,
  bound : Map[String, Bool],
  free : Map[String, Bool],
) -> Unit {
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, ..) => {
        // For let rec, bind name BEFORE scanning expr (self-reference)
        if rec {
          bound[name] = true
        }
        collect_free_vars_expr_gc(expr, bound, free)
        bound[name] = true
      }
      @core.Stmt::ExportLet(rec~, name~, expr~, ..) => {
        if rec {
          bound[name] = true
        }
        collect_free_vars_expr_gc(expr, bound, free)
        bound[name] = true
      }
      @core.Stmt::InternalExportLet(rec~, name~, expr~, ..) => {
        if rec {
          bound[name] = true
        }
        collect_free_vars_expr_gc(expr, bound, free)
        bound[name] = true
      }
      @core.Stmt::LetMut(name~, expr~, ..) => {
        collect_free_vars_expr_gc(expr, bound, free)
        bound[name] = true
      }
      @core.Stmt::LetPat(pat~, expr~, ..) => {
        collect_free_vars_expr_gc(expr, bound, free)
        collect_free_vars_pat_gc(pat, bound)
      }
      @core.Stmt::LetPatElse(pat~, expr~, ..) => {
        collect_free_vars_expr_gc(expr, bound, free)
        collect_free_vars_pat_gc(pat, bound)
      }
      @core.Stmt::Assign(expr~, ..) =>
        collect_free_vars_expr_gc(expr, bound, free)
      @core.Stmt::Expr(expr~, ..) =>
        collect_free_vars_expr_gc(expr, bound, free)
      _ => ()
    }
  }
}

///|
fn has_free_vars_gc(
  body : @core.Module,
  params : Array[@core.FuncParam],
  top_level_funcs : Map[String, Bool],
  enum_ctor_names? : Map[String, Bool] = {},
) -> Bool {
  let bound : Map[String, Bool] = {}
  for param in params {
    bound[param.name] = true
  }
  let free : Map[String, Bool] = {}
  collect_free_vars_module_gc(body, bound, free)
  for name, _ in free {
    if !top_level_funcs.contains(name) &&
      !enum_ctor_names.contains(name) &&
      !is_gc_builtin_name(name) {
      return true
    }
  }
  false
}

///|
/// Check if a name is a known builtin that doesn't need to be captured.
fn is_gc_builtin_name(name : String) -> Bool {
  // Option constructors (registered as builtin enum)
  name == "Some" ||
  name == "None" ||
  // Boolean values
  name == "true" ||
  name == "false" ||
  // Intrinsic functions used in codegen
  name.has_prefix("__") ||
  // Builtin type operations
  name.has_prefix("Int::") ||
  name.has_prefix("Bool::") ||
  name.has_prefix("Double::") ||
  name.has_prefix("String::") ||
  name.has_prefix("Array::") ||
  name.has_prefix("ArrayBuilder::") ||
  name.has_prefix("MapBuilder::") ||
  name.has_prefix("Map::") ||
  name.has_prefix("Set::") ||
  name.has_prefix("Bytes::") ||
  name.has_prefix("StringBuilder::") ||
  // Effect operations (desugared from perform)
  name.has_prefix("Fs::") ||
  name.has_prefix("Env::") ||
  name.has_prefix("Http::") ||
  name.has_prefix("Socket::") ||
  name.has_prefix("Io::") ||
  // Common builtins
  name == "add" ||
  name == "sub" ||
  name == "mul" ||
  name == "div" ||
  name == "eq" ||
  name == "lt" ||
  // Floating-point math shortcuts — intercepted in compile_expr_gc to
  // emit the matching wasm primitive directly rather than calling the
  // bundled vibe implementation (which depends on Double globals the
  // wasm-gc backend doesn't register).
  name == "floor" ||
  name == "ceil" ||
  name == "trunc" ||
  name == "round" ||
  name == "fract" ||
  name == "not" ||
  name == "__not" ||
  name == "__or" ||
  name == "neg" ||
  name == "println" ||
  name == "print" ||
  name == "abort" ||
  name == "throw" ||
  name == "record_set" ||
  name == "__assert" ||
  name == "__assert_eq" ||
  name == "String::replace_all"
}

///|
fn closure_sig_key_gc(
  param_kinds : Array[GcValKind],
  result_kind : GcValKind,
) -> String {
  let sb = StringBuilder::new()
  sb.write_string("closure:")
  for k in param_kinds {
    sb.write_string(gc_val_kind_key(k))
    sb.write_char(',')
  }
  sb.write_string("->")
  sb.write_string(gc_val_kind_key(result_kind))
  sb.to_string()
}

///|
fn ensure_closure_types_gc(
  ctx : GcCodegenCtx,
  param_kinds : Array[GcValKind],
  result_kind : GcValKind,
) -> (Int, Int) {
  let key = closure_sig_key_gc(param_kinds, result_kind)
  match ctx.closure_fn_type_cache.get(key) {
    Some(fn_idx) =>
      match ctx.closure_struct_type_cache.get(key) {
        Some(st_idx) => (fn_idx, st_idx)
        None => (fn_idx, fn_idx)
      }
    None => {
      let fn_params : Array[GcValKind] = [GcValKind::AnyRef]
      for k in param_kinds {
        fn_params.push(k)
      }
      let fn_type_idx = ctx.types.length()
      ctx.types.push(GcTypeDef::Func(params=fn_params, result=result_kind))
      ctx.closure_fn_type_cache[key] = fn_type_idx
      let struct_fields : Array[GcValKind] = [
        GcValKind::Ref(fn_type_idx),
        GcValKind::AnyRef,
      ]
      let struct_type_idx = ctx.types.length()
      ctx.types.push(GcTypeDef::Struct(fields=struct_fields))
      ctx.closure_struct_type_cache[key] = struct_type_idx
      (fn_type_idx, struct_type_idx)
    }
  }
}

///|
fn track_closure_binding_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  name : String,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  match expr {
    @core.Expr::Fn(params~, ret~, body~, ..) => {
      let param_kinds : Array[GcValKind] = []
      for param in params {
        param_kinds.push(gc_val_kind_from_type(ctx, param.ty))
      }
      let result_kind = match ret {
        Some(ty) => gc_val_kind_from_type(ctx, ty)
        None => {
          let saved = clone_locals_gc(fctx.locals)
          for param in params {
            let k = gc_val_kind_from_type(ctx, param.ty)
            fctx.locals[param.name] = { idx: 0, kind: k }
          }
          let kind = infer_block_kind_gc(ctx, fctx, body)
          restore_locals_gc(fctx, saved)
          kind
        }
      }
      let (fn_type_idx, _) = ensure_closure_types_gc(
        ctx, param_kinds, result_kind,
      )
      fctx.closure_call_types[name] = fn_type_idx
    }
    @core.Expr::Call(name=callee, ..) =>
      match ctx.closure_call_type_for_func.get(callee) {
        Some(fn_type_idx) => fctx.closure_call_types[name] = fn_type_idx
        None => ()
      }
    @core.Expr::Ident(name=alias_target, ..) =>
      // Function alias: let f = g where g is a known function
      match ctx.closure_call_type_for_func.get(alias_target) {
        Some(fn_type_idx) => fctx.closure_call_types[name] = fn_type_idx
        None =>
          match fctx.closure_call_types.get(alias_target) {
            Some(fn_type_idx) => fctx.closure_call_types[name] = fn_type_idx
            None => ()
          }
      }
    _ => ()
  }
}

///|
fn closure_call_sig_from_kind_gc(
  ctx : GcCodegenCtx,
  kind : GcValKind,
  opname : String,
) -> (Int, Int, Array[GcValKind], GcValKind) raise WasmGenError {
  match kind {
    GcValKind::Ref(struct_type_idx) =>
      match ctx.types[struct_type_idx] {
        GcTypeDef::Struct(fields~) =>
          if fields.length() == 2 {
            match fields[0] {
              GcValKind::Ref(fn_type_idx) =>
                match ctx.types[fn_type_idx] {
                  GcTypeDef::Func(params~, result~) =>
                    (struct_type_idx, fn_type_idx, params, result)
                  _ =>
                    raise WasmGenError::Unsupported(opname + " closure fn type")
                }
              _ =>
                raise WasmGenError::Unsupported(opname + " closure callee type")
            }
          } else {
            raise WasmGenError::Unsupported(opname + " closure struct arity")
          }
        _ => raise WasmGenError::Unsupported(opname + " closure kind")
      }
    _ => raise WasmGenError::Unsupported(opname + " expects closure")
  }
}

///|
fn gc_val_kind_from_type(
  ctx : GcCodegenCtx,
  ty : @core.Type,
) -> GcValKind raise WasmGenError {
  match ty {
    @core.Type::Int => GcValKind::I64
    // Char shares Int's runtime representation (tagged 62-bit i64
    // per ADR-0006). Without this case, parameters typed `Char` fell
    // through to the Named-type fallback and resolved to EqRef, which
    // mis-typed `to_int(ch: Char) -> Int` as `(eqref) -> i64` and
    // tripped wasm validation on the identity body.
    @core.Type::Char => GcValKind::I64
    @core.Type::Float => GcValKind::F32
    @core.Type::Double => GcValKind::F64
    @core.Type::Bool => GcValKind::I32
    @core.Type::Unit => GcValKind::I32
    @core.Type::String => GcValKind::Ref(ctx.string_type)
    @core.Type::Bytes => GcValKind::Ref(ctx.bytes_type)
    @core.Type::Named(name="Int64Array", ..) =>
      GcValKind::Ref(ctx.int64array_type)
    @core.Type::Tuple(items) => {
      let kinds : Array[GcValKind] = []
      for item in items {
        kinds.push(gc_val_kind_from_type(ctx, item))
      }
      let type_idx = ensure_struct_type(ctx.types, ctx.struct_type_index, kinds)
      GcValKind::Ref(type_idx)
    }
    @core.Type::Record(fields) => {
      let keys = addr_sort_record_type_keys(fields)
      let kinds : Array[GcValKind] = []
      for k in keys {
        match fields.get(k) {
          Some(t) => kinds.push(gc_val_kind_from_type(ctx, t))
          None => raise WasmGenError::Unsupported("record type")
        }
      }
      let type_idx = ensure_struct_type(ctx.types, ctx.struct_type_index, kinds)
      GcValKind::Ref(type_idx)
    }
    @core.Type::Named(name~, args~) =>
      if args.length() == 0 {
        match name {
          "Int" | "i32" | "Num" => GcValKind::I64
          "Char" => GcValKind::I64
          "Float" | "f32" => GcValKind::F32
          "Double" | "f64" => GcValKind::F64
          "Bool" | "Unit" => GcValKind::I32
          "String" => GcValKind::Ref(ctx.string_type)
          "Bytes" => GcValKind::Ref(ctx.bytes_type)
          "anyref" => GcValKind::AnyRef
          "eqref" => GcValKind::EqRef
          "i31ref" => GcValKind::I31Ref
          "structref" => GcValKind::StructRef
          "arrayref" => GcValKind::ArrayRef
          "funcref" => GcValKind::FuncRef
          "externref" => GcValKind::ExternRef
          _ =>
            // User-defined named struct types → Ref to specific struct type
            match ctx.named_struct_types.get(name) {
              Some(type_idx) => GcValKind::Ref(type_idx)
              None =>
                // Enum or other user-defined types → eqref
                GcValKind::EqRef
            }
        }
      } else {
        match name {
          "Array" => {
            // Array<T> → gc array ref
            let elem_kind = gc_val_kind_from_type(ctx, args[0])
            let type_idx = ensure_array_type(
              ctx.types,
              ctx.array_type_index,
              elem_kind,
            )
            GcValKind::Ref(type_idx)
          }
          // Issue #416: prelude functions like `Map::iter_get` declare
          // their first parameter as `Map[K, V]`, which the parser
          // encodes as Named("Map", [K, V]) (not Type::Map). Map this
          // back onto the canonical map struct so the function body's
          // `struct.get` ops validate against a typed ref.
          "Map" | "MapBuilder" => {
            let (builder_type, _, _) = map_struct_types_gc(ctx)
            GcValKind::Ref(builder_type)
          }
          "ArrayBuilder" => {
            let elem_kind = gc_val_kind_from_type(ctx, args[0])
            let arr_type = ensure_array_type(
              ctx.types,
              ctx.array_type_index,
              elem_kind,
            )
            let builder_fields : Array[GcValKind] = [
              GcValKind::I32,
              GcValKind::Ref(arr_type),
            ]
            let builder_type = ensure_struct_type(
              ctx.types,
              ctx.struct_type_index,
              builder_fields,
            )
            GcValKind::Ref(builder_type)
          }
          "Set" => {
            let arr_type = ensure_array_type(
              ctx.types,
              ctx.array_type_index,
              GcValKind::EqRef,
            )
            GcValKind::Ref(arr_type)
          }
          // Option, Result, etc. — treat as eqref (enum-like)
          _ => GcValKind::EqRef
        }
      }
    @core.Type::Array(elem_ty) => {
      let elem_kind = gc_val_kind_from_type(ctx, elem_ty)
      let type_idx = ensure_array_type(
        ctx.types,
        ctx.array_type_index,
        elem_kind,
      )
      GcValKind::Ref(type_idx)
    }
    @core.Type::Map(_, _) | @core.Type::MapBuilder(_, _) => {
      // Issue #416: Map and MapBuilder share a single runtime struct
      // `{ len: i32, keys: array<eqref>, vals: array<eqref> }`. Key
      // and value element types are erased to eqref per ADR-0044
      // (per-type kind recovered through `map_value_kinds` at call
      // sites that need it). Returning the struct ref here lets
      // generic functions like `Iterator::fold(map, ...)` typecheck
      // their `xs : C` parameter against an actual Map value kind.
      let (builder_type, _, _) = map_struct_types_gc(ctx)
      GcValKind::Ref(builder_type)
    }
    @core.Type::ArrayBuilder(elem_ty) => {
      let elem_kind = gc_val_kind_from_type(ctx, elem_ty)
      let arr_type = ensure_array_type(
        ctx.types,
        ctx.array_type_index,
        elem_kind,
      )
      let builder_fields : Array[GcValKind] = [
        GcValKind::I32,
        GcValKind::Ref(arr_type),
      ]
      let builder_type = ensure_struct_type(
        ctx.types,
        ctx.struct_type_index,
        builder_fields,
      )
      GcValKind::Ref(builder_type)
    }
    @core.Type::Set(_) => {
      // Set is internally stored as an Array of eqref values.
      let arr_type = ensure_array_type(
        ctx.types,
        ctx.array_type_index,
        GcValKind::EqRef,
      )
      GcValKind::Ref(arr_type)
    }
    @core.Type::Func(params~, ret~, ..) => {
      let param_kinds : Array[GcValKind] = []
      for p in params {
        param_kinds.push(gc_val_kind_from_type(ctx, p.ty))
      }
      let result_kind = gc_val_kind_from_type(ctx, ret)
      let (_, struct_type_idx) = ensure_closure_types_gc(
        ctx, param_kinds, result_kind,
      )
      GcValKind::Ref(struct_type_idx)
    }
    @core.Type::Param(_) =>
      // Generic payloads are boxed/ref-cast through eqref in GC mode.
      GcValKind::EqRef
    @core.Type::Variant(_) => GcValKind::EqRef
    // Unresolved unification variables (`Type::Var(_)`) leak out of
    // the checker when a generic helper is monomorphised against a
    // value whose type is itself a fresh metavariable (the common
    // case is `Option`/`Result` ctor inference at the test top-
    // level, e.g. `let r = ok(42)`). Treat them as the same generic
    // erased kind as `Type::Param` — eqref — so the codegen doesn't
    // bail out with `gc type: Var(N)` and the bundling pipeline
    // moves on to box / cast the value through eqref normally.
    @core.Type::Var(_) => GcValKind::EqRef
    _ => raise WasmGenError::Unsupported("gc type: " + ty.to_string())
  }
}

///|
fn GcFuncCtx::new(
  ctx : GcCodegenCtx,
  params : Array[@core.FuncParam],
) -> GcFuncCtx raise WasmGenError {
  let locals : Map[String, GcLocalInfo] = {}
  let map_value_kinds : Map[String, GcValKind] = {}
  let array_builder_elem_hints : Map[String, GcValKind] = {}
  let local_kinds : Array[GcValKind] = []
  let closure_call_types : Map[String, Int] = {}
  let mut idx = 0
  for param in params {
    let kind = gc_val_kind_from_type(ctx, param.ty)
    locals[param.name] = { idx, kind }
    // Register function-typed parameters for closure call dispatch
    match param.ty {
      @core.Type::Func(params=fn_params, ret~, ..) => {
        let fn_param_kinds : Array[GcValKind] = []
        for fp in fn_params {
          fn_param_kinds.push(gc_val_kind_from_type(ctx, fp.ty))
        }
        let result_kind = gc_val_kind_from_type(ctx, ret)
        let (fn_type_idx, _) = ensure_closure_types_gc(
          ctx, fn_param_kinds, result_kind,
        )
        closure_call_types[param.name] = fn_type_idx
      }
      _ =>
        // For Named types (type aliases), check if the GC kind is a
        // closure struct (Ref to a struct with [funcref, anyref])
        match kind {
          GcValKind::Ref(type_idx) =>
            match ctx.types[type_idx] {
              GcTypeDef::Struct(fields~) =>
                if fields.length() == 2 {
                  match fields[0] {
                    GcValKind::Ref(fn_idx) =>
                      match ctx.types[fn_idx] {
                        GcTypeDef::Func(..) =>
                          closure_call_types[param.name] = fn_idx
                        _ => ()
                      }
                    _ => ()
                  }
                }
              _ => ()
            }
          _ => ()
        }
    }
    idx += 1
  }
  {
    locals,
    map_value_kinds,
    array_builder_elem_hints,
    local_kinds,
    param_count: idx,
    closure_call_types,
    current_rec_binding: None,
    enclosing_function_name: None,
    direct_rec_call_name: None,
    direct_rec_call_func_idx: -1,
    direct_rec_call_type_idx: -1,
  }
}

///|
fn clone_kind_map_gc(src : Map[String, GcValKind]) -> Map[String, GcValKind] {
  let out : Map[String, GcValKind] = {}
  for k, v in src {
    out[k] = v
  }
  out
}

///|
fn alloc_local_gc(fctx : GcFuncCtx, kind : GcValKind) -> Int {
  let idx = fctx.param_count + fctx.local_kinds.length()
  fctx.local_kinds.push(kind)
  idx
}

///|
fn bind_local_gc(fctx : GcFuncCtx, name : String, kind : GcValKind) -> Int {
  let idx = alloc_local_gc(fctx, kind)
  fctx.locals[name] = { idx, kind }
  idx
}

///|
fn clone_locals_gc(src : Map[String, GcLocalInfo]) -> Map[String, GcLocalInfo] {
  let out : Map[String, GcLocalInfo] = {}
  for name, info in src {
    out[name] = info
  }
  out
}

///|
fn gc_array_builder_kind_for_elem(
  ctx : GcCodegenCtx,
  elem_kind : GcValKind,
) -> GcValKind {
  let arr_type = ensure_array_type(ctx.types, ctx.array_type_index, elem_kind)
  let builder_fields : Array[GcValKind] = [
    GcValKind::I32,
    GcValKind::Ref(arr_type),
  ]
  let builder_type = ensure_struct_type(
    ctx.types,
    ctx.struct_type_index,
    builder_fields,
  )
  GcValKind::Ref(builder_type)
}

///|
fn emit_array_builder_new_for_elem_gc(
  ctx : GcCodegenCtx,
  buf : GcByteBuf,
  elem_kind : GcValKind,
) -> Unit {
  let init_cap = 8
  let arr_type = ensure_array_type(ctx.types, ctx.array_type_index, elem_kind)
  let builder_fields : Array[GcValKind] = [
    GcValKind::I32,
    GcValKind::Ref(arr_type),
  ]
  let builder_type = ensure_struct_type(
    ctx.types,
    ctx.struct_type_index,
    builder_fields,
  )
  emit_i32_const_gc(buf, 0)
  emit_i32_const_gc(buf, init_cap)
  emit_array_new_default_gc(buf, arr_type)
  emit_struct_new_gc(buf, builder_type)
}

///|
fn positional_exprs_no_raise_gc(
  args : Array[@core.CallArg],
) -> Array[@core.Expr] {
  let out : Array[@core.Expr] = []
  for arg in args {
    match arg.label {
      Some(_) => ()
      None => out.push(arg.expr)
    }
  }
  out
}

///|
fn is_array_builder_new_expr_gc(expr : @core.Expr) -> Bool {
  match expr {
    @core.Expr::Call(name~, args~, ..) => {
      let name = @core.lower_wasm_intrinsic_name(name)
      name == "ArrayBuilder::new" &&
      positional_exprs_no_raise_gc(args).is_empty()
    }
    _ => false
  }
}

///|
fn array_builder_new_elem_hint_gc(
  fctx : GcFuncCtx,
  name : String,
  expr : @core.Expr,
) -> GcValKind? {
  if is_array_builder_new_expr_gc(expr) {
    fctx.array_builder_elem_hints.get(name)
  } else {
    None
  }
}

///|
fn gc_scan_ctx_from_gc(fctx : GcFuncCtx) -> GcFuncCtx {
  let closure_call_types : Map[String, Int] = {}
  for k, v in fctx.closure_call_types {
    closure_call_types[k] = v
  }
  {
    locals: clone_locals_gc(fctx.locals),
    map_value_kinds: clone_kind_map_gc(fctx.map_value_kinds),
    array_builder_elem_hints: clone_kind_map_gc(fctx.array_builder_elem_hints),
    local_kinds: [],
    param_count: fctx.param_count,
    closure_call_types,
    current_rec_binding: fctx.current_rec_binding,
    enclosing_function_name: fctx.enclosing_function_name,
    direct_rec_call_name: fctx.direct_rec_call_name,
    direct_rec_call_func_idx: fctx.direct_rec_call_func_idx,
    direct_rec_call_type_idx: fctx.direct_rec_call_type_idx,
  }
}

///|
fn gc_try_infer_expr_kind(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  expr : @core.Expr,
) -> GcValKind? {
  let result : Result[GcValKind, WasmGenError] = try? infer_expr_kind_gc(
    ctx, fctx, expr,
  )
  match result {
    Ok(kind) => Some(kind)
    Err(_) => None
  }
}

///|
fn record_array_builder_hint_gc(
  hints : Map[String, GcValKind],
  name : String,
  elem_kind : GcValKind,
) -> Unit {
  match hints.get(name) {
    Some(existing) =>
      if existing != elem_kind {
        hints[name] = GcValKind::EqRef
      }
    None => hints[name] = elem_kind
  }
}

///|
fn scan_array_builder_hints_module_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  body : @core.Module,
  hints : Map[String, GcValKind],
) -> Unit {
  for stmt in body.stmts {
    scan_array_builder_hints_stmt_gc(ctx, fctx, stmt, hints)
  }
}

///|
fn scan_array_builder_hints_stmt_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  stmt : @core.Stmt,
  hints : Map[String, GcValKind],
) -> Unit {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, ..) => {
      let _ = rec
      scan_array_builder_hints_expr_gc(ctx, fctx, expr, hints)
      match gc_try_infer_expr_kind(ctx, fctx, expr) {
        Some(kind) => {
          fctx.locals[name] = { idx: 0, kind }
          let map_value : Result[GcValKind?, WasmGenError] = try? infer_map_value_kind_from_expr_gc(
            ctx, fctx, expr,
          )
          match map_value {
            Ok(Some(value_kind)) => fctx.map_value_kinds[name] = value_kind
            Ok(None) | Err(_) => ()
          }
        }
        None => ()
      }
      ignore(try? track_closure_binding_gc(ctx, fctx, name, expr))
    }
    @core.Stmt::LetMut(name~, expr~, ..)
    | @core.Stmt::Assign(name~, expr~, ..) => {
      scan_array_builder_hints_expr_gc(ctx, fctx, expr, hints)
      match gc_try_infer_expr_kind(ctx, fctx, expr) {
        Some(kind) => {
          fctx.locals[name] = { idx: 0, kind }
          let map_value : Result[GcValKind?, WasmGenError] = try? infer_map_value_kind_from_expr_gc(
            ctx, fctx, expr,
          )
          match map_value {
            Ok(Some(value_kind)) => fctx.map_value_kinds[name] = value_kind
            Ok(None) | Err(_) => ()
          }
        }
        None => ()
      }
      ignore(try? track_closure_binding_gc(ctx, fctx, name, expr))
    }
    @core.Stmt::Expr(expr~, ..) =>
      scan_array_builder_hints_expr_gc(ctx, fctx, expr, hints)
    @core.Stmt::LetPat(expr~, ..) | @core.Stmt::LetPatElse(expr~, ..) =>
      scan_array_builder_hints_expr_gc(ctx, fctx, expr, hints)
    @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      scan_array_builder_hints_expr_gc(ctx, fctx, target, hints)
      scan_array_builder_hints_expr_gc(ctx, fctx, index, hints)
      scan_array_builder_hints_expr_gc(ctx, fctx, value, hints)
    }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      scan_array_builder_hints_stmt_gc(
        ctx,
        fctx,
        @core.Stmt::Let(rec~, name~, expr~, span~),
        hints,
      )
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) =>
      scan_array_builder_hints_stmt_gc(
        ctx,
        fctx,
        @core.Stmt::Let(rec~, name~, expr~, span~),
        hints,
      )
    _ => ()
  }
}

///|
fn scan_array_builder_hints_expr_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  expr : @core.Expr,
  hints : Map[String, GcValKind],
) -> Unit {
  match expr {
    @core.Expr::Call(name~, args~, ..) => {
      let name = @core.lower_wasm_intrinsic_name(name)
      let pos_args = positional_exprs_no_raise_gc(args)
      if name == "ArrayBuilder::push" && pos_args.length() == 2 {
        match pos_args[0] {
          @core.Expr::Ident(name=builder_name, ..) =>
            match gc_try_infer_expr_kind(ctx, fctx, pos_args[1]) {
              Some(elem_kind) =>
                record_array_builder_hint_gc(hints, builder_name, elem_kind)
              None => ()
            }
          _ => ()
        }
      }
      for arg in args {
        scan_array_builder_hints_expr_gc(ctx, fctx, arg.expr, hints)
      }
    }
    @core.Expr::Block(body~, ..) => {
      let child = gc_scan_ctx_from_gc(fctx)
      scan_array_builder_hints_module_gc(ctx, child, body, hints)
    }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      scan_array_builder_hints_expr_gc(ctx, fctx, cond, hints)
      let then_ctx = gc_scan_ctx_from_gc(fctx)
      scan_array_builder_hints_module_gc(ctx, then_ctx, then_body, hints)
      let else_ctx = gc_scan_ctx_from_gc(fctx)
      scan_array_builder_hints_module_gc(ctx, else_ctx, else_body, hints)
    }
    @core.Expr::While(cond~, body~, ..) => {
      scan_array_builder_hints_expr_gc(ctx, fctx, cond, hints)
      let child = gc_scan_ctx_from_gc(fctx)
      scan_array_builder_hints_module_gc(ctx, child, body, hints)
    }
    @core.Expr::ForIn(iterable~, body~, ..) => {
      scan_array_builder_hints_expr_gc(ctx, fctx, iterable, hints)
      let child = gc_scan_ctx_from_gc(fctx)
      scan_array_builder_hints_module_gc(ctx, child, body, hints)
    }
    @core.Expr::Loop(params~, body~, ..) => {
      for param in params {
        scan_array_builder_hints_expr_gc(ctx, fctx, param.init, hints)
      }
      let child = gc_scan_ctx_from_gc(fctx)
      scan_array_builder_hints_module_gc(ctx, child, body, hints)
    }
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      scan_array_builder_hints_expr_gc(ctx, fctx, scrutinee, hints)
      for arm in arms {
        match arm.cond {
          Some(cond) => scan_array_builder_hints_expr_gc(ctx, fctx, cond, hints)
          None => ()
        }
        scan_array_builder_hints_expr_gc(ctx, fctx, arm.expr, hints)
      }
    }
    @core.Expr::Handle(body~, arms~, ..) => {
      let child = gc_scan_ctx_from_gc(fctx)
      scan_array_builder_hints_module_gc(ctx, child, body, hints)
      for arm in arms {
        scan_array_builder_hints_expr_gc(ctx, fctx, arm.expr, hints)
      }
    }
    @core.Expr::Array(items~, ..) | @core.Expr::Tuple(items~, ..) =>
      for item in items {
        scan_array_builder_hints_expr_gc(ctx, fctx, item, hints)
      }
    @core.Expr::Record(fields~, ..) | @core.Expr::StructLit(fields~, ..) =>
      for field in fields {
        scan_array_builder_hints_expr_gc(ctx, fctx, field.expr, hints)
      }
    @core.Expr::Map(fields~, ..) =>
      for field in fields {
        scan_array_builder_hints_expr_gc(ctx, fctx, field.expr, hints)
      }
    @core.Expr::TupleIndex(expr=inner, ..)
    | @core.Expr::Break(value=Some(inner), ..)
    | @core.Expr::Return(value=Some(inner), ..)
    | @core.Expr::Yield(expr=inner, ..)
    | @core.Expr::Spread(expr=inner, ..) =>
      scan_array_builder_hints_expr_gc(ctx, fctx, inner, hints)
    @core.Expr::Continue(args~, ..) =>
      for arg in args {
        scan_array_builder_hints_expr_gc(ctx, fctx, arg, hints)
      }
    @core.Expr::Perform(args~, ..) =>
      for arg in args {
        scan_array_builder_hints_expr_gc(ctx, fctx, arg.expr, hints)
      }
    @core.Expr::Fn(..)
    | @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::Char(..)
    | @core.Expr::String(..)
    | @core.Expr::StringInterp(..)
    | @core.Expr::Ident(..)
    | @core.Expr::Placeholder(..)
    | @core.Expr::Break(value=None, ..)
    | @core.Expr::Return(value=None, ..) => ()
  }
}

///|
fn seed_array_builder_hints_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  body : @core.Module,
) -> Unit {
  let scan_ctx = gc_scan_ctx_from_gc(fctx)
  let hints : Map[String, GcValKind] = {}
  scan_array_builder_hints_module_gc(ctx, scan_ctx, body, hints)
  for name, elem_kind in hints {
    fctx.array_builder_elem_hints[name] = elem_kind
  }
}

///|
fn infer_block_kind_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  body : @core.Module,
) -> GcValKind raise WasmGenError {
  let len = body.stmts.length()
  if len == 0 {
    return GcValKind::I32
  }
  let temp_cct : Map[String, Int] = {}
  for k, v in fctx.closure_call_types {
    temp_cct[k] = v
  }
  let temp_ctx = GcFuncCtx::{
    locals: clone_locals_gc(fctx.locals),
    map_value_kinds: clone_kind_map_gc(fctx.map_value_kinds),
    array_builder_elem_hints: clone_kind_map_gc(fctx.array_builder_elem_hints),
    local_kinds: [],
    param_count: fctx.param_count,
    closure_call_types: temp_cct,
    current_rec_binding: None,
    enclosing_function_name: fctx.enclosing_function_name,
    direct_rec_call_name: None,
    direct_rec_call_func_idx: -1,
    direct_rec_call_type_idx: -1,
  }
  seed_array_builder_hints_gc(ctx, temp_ctx, body)
  for i in 0..<len {
    let stmt = body.stmts[i]
    let is_last = i == len - 1
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, ..) =>
        if rec {
          match expr {
            @core.Expr::Fn(params~, ret~, ..) => {
              let param_kinds : Array[GcValKind] = []
              for p in params {
                param_kinds.push(gc_val_kind_from_type(ctx, p.ty))
              }
              let result_kind = match ret {
                Some(ty) => gc_val_kind_from_type(ctx, ty)
                None => GcValKind::I32
              }
              let (fn_type_idx, closure_struct_type) = ensure_closure_types_gc(
                ctx, param_kinds, result_kind,
              )
              let kind = GcValKind::Ref(closure_struct_type)
              temp_ctx.locals[name] = { idx: 0, kind }
              temp_ctx.closure_call_types[name] = fn_type_idx
              if is_last {
                return kind
              }
            }
            _ => {
              let kind = match
                array_builder_new_elem_hint_gc(temp_ctx, name, expr) {
                Some(elem_kind) =>
                  gc_array_builder_kind_for_elem(ctx, elem_kind)
                None => infer_expr_kind_gc(ctx, temp_ctx, expr)
              }
              temp_ctx.locals[name] = { idx: 0, kind }
              match infer_map_value_kind_from_expr_gc(ctx, temp_ctx, expr) {
                Some(value_kind) => temp_ctx.map_value_kinds[name] = value_kind
                None => ()
              }
              if is_last {
                return kind
              }
            }
          }
        } else {
          let kind = match
            array_builder_new_elem_hint_gc(temp_ctx, name, expr) {
            Some(elem_kind) => gc_array_builder_kind_for_elem(ctx, elem_kind)
            None => infer_expr_kind_gc(ctx, temp_ctx, expr)
          }
          temp_ctx.locals[name] = { idx: 0, kind }
          match infer_map_value_kind_from_expr_gc(ctx, temp_ctx, expr) {
            Some(value_kind) => temp_ctx.map_value_kinds[name] = value_kind
            None => ()
          }
          track_closure_binding_gc(ctx, temp_ctx, name, expr)
          if is_last {
            return kind
          }
        }
      @core.Stmt::LetMut(name~, expr~, ..) => {
        let kind = match array_builder_new_elem_hint_gc(temp_ctx, name, expr) {
          Some(elem_kind) => gc_array_builder_kind_for_elem(ctx, elem_kind)
          None => infer_expr_kind_gc(ctx, temp_ctx, expr)
        }
        temp_ctx.locals[name] = { idx: 0, kind }
        match infer_map_value_kind_from_expr_gc(ctx, temp_ctx, expr) {
          Some(value_kind) => temp_ctx.map_value_kinds[name] = value_kind
          None => ()
        }
        track_closure_binding_gc(ctx, temp_ctx, name, expr)
        if is_last {
          return kind
        }
      }
      @core.Stmt::Assign(name~, expr~, ..) => {
        let kind = infer_expr_kind_gc(ctx, temp_ctx, expr)
        temp_ctx.locals[name] = { idx: 0, kind }
        match infer_map_value_kind_from_expr_gc(ctx, temp_ctx, expr) {
          Some(value_kind) => temp_ctx.map_value_kinds[name] = value_kind
          None => ()
        }
        if is_last {
          return kind
        }
      }
      @core.Stmt::LetPat(pat~, expr~, ..) => {
        let kind = infer_expr_kind_gc(ctx, temp_ctx, expr)
        // Bind pattern names in temp_ctx. For Tuple/Ctor patterns we
        // look up the actual struct field kinds when the scrutinee is a
        // known struct type, so that `let (a, b) = ...` binds `a`/`b`
        // with their real I32/I64/Ref kind instead of a defaulted EqRef.
        // Without this, downstream blocks that end in `a = x` infer
        // their block kind as EqRef while the actual codegen leaves an
        // i64/i32 on the stack, producing a `(result eqref)` if-block
        // with mismatched arm types (wasm validation: expected eqref,
        // found i64).
        fn struct_field_kinds(k : GcValKind) -> Array[GcValKind]? {
          match k {
            GcValKind::Ref(idx) =>
              match ctx.types[idx] {
                GcTypeDef::Struct(fields~) => Some(fields)
                _ => None
              }
            _ => None
          }
        }

        fn bind_pat_names(p : @core.Pat, k : GcValKind) -> Unit {
          match p {
            @core.Pat::Bind(name~, ..) =>
              temp_ctx.locals[name] = { idx: 0, kind: k }
            @core.Pat::Tuple(items~, ..) => {
              let field_kinds = struct_field_kinds(k)
              for i in 0..<items.length() {
                let item_kind = match field_kinds {
                  Some(fks) =>
                    if i < fks.length() {
                      fks[i]
                    } else {
                      GcValKind::EqRef
                    }
                  None => GcValKind::EqRef
                }
                bind_pat_names(items[i], item_kind)
              }
            }
            @core.Pat::Ctor(args~, ..) =>
              for arg in args {
                bind_pat_names(arg, GcValKind::EqRef)
              }
            _ => ()
          }
        }

        bind_pat_names(pat, kind)
        if is_last {
          return kind
        }
      }
      @core.Stmt::LetPatElse(pat~, expr~, ..) => {
        let kind = infer_expr_kind_gc(ctx, temp_ctx, expr)
        fn struct_field_kinds2(k : GcValKind) -> Array[GcValKind]? {
          match k {
            GcValKind::Ref(idx) =>
              match ctx.types[idx] {
                GcTypeDef::Struct(fields~) => Some(fields)
                _ => None
              }
            _ => None
          }
        }

        fn bind_pat_names(p : @core.Pat, k : GcValKind) -> Unit {
          match p {
            @core.Pat::Bind(name~, ..) =>
              temp_ctx.locals[name] = { idx: 0, kind: k }
            @core.Pat::Tuple(items~, ..) => {
              let field_kinds = struct_field_kinds2(k)
              for i in 0..<items.length() {
                let item_kind = match field_kinds {
                  Some(fks) =>
                    if i < fks.length() {
                      fks[i]
                    } else {
                      GcValKind::EqRef
                    }
                  None => GcValKind::EqRef
                }
                bind_pat_names(items[i], item_kind)
              }
            }
            @core.Pat::Ctor(args~, ..) =>
              for arg in args {
                bind_pat_names(arg, GcValKind::EqRef)
              }
            _ => ()
          }
        }

        bind_pat_names(pat, kind)
        if is_last {
          return GcValKind::I32
        }
      }
      @core.Stmt::Expr(expr~, ..) =>
        if is_last {
          return infer_expr_kind_gc(ctx, temp_ctx, expr)
        }
      _ => if is_last { return GcValKind::I32 }
    }
  }
  GcValKind::I32
}

///|
fn infer_record_kind_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  fields : Array[@core.RecordFieldExpr],
) -> GcValKind raise WasmGenError {
  let ordered = sort_record_fields_expr(fields)
  let kinds : Array[GcValKind] = []
  let names : Array[String] = []
  for field in ordered {
    kinds.push(infer_expr_kind_gc(ctx, fctx, field.expr))
    names.push(field.name)
  }
  let type_idx = ensure_struct_type(ctx.types, ctx.struct_type_index, kinds)
  // Record the sorted field-name order so `try_compile_struct_field_get_gc`
  // can resolve `record.field` even when the value came from a record
  // literal rather than a named `struct Foo { ... }` declaration.
  if !ctx.record_field_names_by_type_idx.contains(type_idx) {
    ctx.record_field_names_by_type_idx[type_idx] = names
  }
  GcValKind::Ref(type_idx)
}

///|
fn infer_tuple_kind_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  items : Array[@core.Expr],
) -> GcValKind raise WasmGenError {
  let kinds : Array[GcValKind] = []
  for item in items {
    kinds.push(infer_expr_kind_gc(ctx, fctx, item))
  }
  let type_idx = ensure_struct_type(ctx.types, ctx.struct_type_index, kinds)
  GcValKind::Ref(type_idx)
}

///|
fn infer_array_kind_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  items : Array[@core.Expr],
) -> GcValKind raise WasmGenError {
  let elem_kind = if items.length() == 0 {
    GcValKind::I64
  } else {
    let first = infer_expr_kind_gc(ctx, fctx, items[0])
    for i in 1..<items.length() {
      let item_kind = infer_expr_kind_gc(ctx, fctx, items[i])
      if item_kind != first {
        raise WasmGenError::Unsupported("array elem kind mismatch")
      }
    }
    first
  }
  let type_idx = ensure_array_type(ctx.types, ctx.array_type_index, elem_kind)
  GcValKind::Ref(type_idx)
}

///|
fn infer_for_in_parts_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  value_name : String,
  index_name : String?,
  iterable : @core.Expr,
  body : @core.Module,
) -> (Int, GcValKind, GcValKind) raise WasmGenError {
  let iterable_kind = infer_expr_kind_gc(ctx, fctx, iterable)
  let iterable_type_idx = match iterable_kind {
    GcValKind::Ref(idx) => idx
    _ => ensure_array_type(ctx.types, ctx.array_type_index, GcValKind::I64)
  }
  let iterable_elem_kind = match ctx.types[iterable_type_idx] {
    GcTypeDef::Array(elem~) => elem
    _ => GcValKind::I64
  }
  let saved_locals = clone_locals_gc(fctx.locals)
  fctx.locals[value_name] = { idx: 0, kind: iterable_elem_kind }
  match index_name {
    Some(name) => fctx.locals[name] = { idx: 0, kind: GcValKind::I32 }
    None => ()
  }
  let body_kind = infer_block_kind_gc(ctx, fctx, body)
  restore_locals_gc(fctx, saved_locals)
  (iterable_type_idx, iterable_elem_kind, body_kind)
}

///|
/// Infer kinds for string for-in: loop variable is I64 (char code).
fn infer_string_for_in_parts_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  value_name : String,
  index_name : String?,
  body : @core.Module,
) -> (GcValKind, GcValKind) raise WasmGenError {
  let elem_kind = GcValKind::I64
  let saved_locals = clone_locals_gc(fctx.locals)
  fctx.locals[value_name] = { idx: 0, kind: elem_kind }
  match index_name {
    Some(name) => fctx.locals[name] = { idx: 0, kind: GcValKind::I32 }
    None => ()
  }
  let body_kind = infer_block_kind_gc(ctx, fctx, body)
  restore_locals_gc(fctx, saved_locals)
  (elem_kind, body_kind)
}

///|
fn infer_expr_kind_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  expr : @core.Expr,
) -> GcValKind raise WasmGenError {
  match expr {
    @core.Expr::Int(..) => GcValKind::I64
    @core.Expr::Float(..) => GcValKind::F32
    @core.Expr::Double(..) => GcValKind::F64
    @core.Expr::Bool(..) => GcValKind::I32
    @core.Expr::Char(..) => GcValKind::I64
    @core.Expr::String(..) => GcValKind::Ref(ctx.string_type)
    @core.Expr::Ident(name~, ..) =>
      match fctx.locals.get(name) {
        Some(info) => info.kind
        None =>
          // Nullary enum constructor as identifier
          if ctx.enum_ctor_tags.contains(name) &&
            ctx.enum_ctor_arities[name] == 0 {
            GcValKind::EqRef
          } else if name == "None" {
            GcValKind::EqRef
          } else if ctx.global_consts.contains(name) {
            let (_, kind) = ctx.global_consts[name]
            kind
          } else if ctx.string_consts.contains(name) {
            GcValKind::Ref(ctx.string_type)
          } else if ctx.func_indices.contains(name) {
            // Top-level function used as value → closure ref
            let param_count = match ctx.func_param_counts.get(name) {
              Some(c) => c
              None => 0
            }
            let result_kind = match ctx.func_returns.get(name) {
              Some(k) => k
              None => GcValKind::I64
            }
            let param_kinds = match ctx.func_param_kinds.get(name) {
              Some(kinds) => kinds
              None => {
                let kinds : Array[GcValKind] = []
                for _ in 0..<param_count {
                  kinds.push(GcValKind::I64)
                }
                kinds
              }
            }
            let (_, struct_type_idx) = ensure_closure_types_gc(
              ctx, param_kinds, result_kind,
            )
            GcValKind::Ref(struct_type_idx)
          } else if is_gc_builtin_name(name) {
            GcValKind::EqRef
          } else {
            raise WasmGenError::UnknownName(name)
          }
      }
    @core.Expr::Map(..) => gc_map_builder_kind_gc(ctx)
    @core.Expr::Call(name~, args~, ..) => {
      let name = @core.lower_wasm_intrinsic_name(name)
      let pos_args = extract_positional_exprs(args, name)
      match name {
        // Mirror the call-side `gc_call_args_arith` guard so `infer`
        // and `compile` stay in sync — when both args are arithmetic
        // the codegen inlines an i32/i64/f32/f64 op and the result
        // kind is the unified arith kind. Otherwise fall through to
        // the function-return lookup below (relevant for user-defined
        // `add: (StringSet, String) -> StringSet` and friends).
        "add" if gc_call_args_arith(ctx, fctx, pos_args) => {
          let lk = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let rk = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          gc_arith_kind(gc_common_kind(lk, rk))
        }
        "sub" if gc_call_args_arith(ctx, fctx, pos_args) => {
          let lk = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let rk = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          gc_arith_kind(gc_common_kind(lk, rk))
        }
        "mul" if gc_call_args_arith(ctx, fctx, pos_args) => {
          let lk = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let rk = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          gc_arith_kind(gc_common_kind(lk, rk))
        }
        "div" if gc_call_args_arith(ctx, fctx, pos_args) => {
          let lk = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let rk = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          gc_arith_kind(gc_common_kind(lk, rk))
        }
        "eq" | "lt" => GcValKind::I32
        "__len" => GcValKind::I64
        "__index" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("arity: __index")
          }
          let base_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          if base_kind == GcValKind::Ref(ctx.string_type) {
            // `s[i]` returns a 1-char String substring (matches the
            // checker's type for `String[Int]`). See the corresponding
            // code-emit path below.
            GcValKind::Ref(ctx.string_type)
          } else if base_kind == GcValKind::Ref(ctx.bytes_type) {
            GcValKind::I64
          } else if base_kind == gc_map_builder_kind_gc(ctx) {
            match infer_map_value_kind_from_expr_gc(ctx, fctx, pos_args[0]) {
              Some(kind) => kind
              None => GcValKind::EqRef
            }
          } else {
            gc_array_elem_kind_from_kind(ctx, base_kind, "__index")
          }
        }
        "__set_index" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("arity: __set_index")
          }
          // Returns the value that was set
          infer_expr_kind_gc(ctx, fctx, pos_args[2])
        }
        "__slice" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("arity: __slice")
          }
          let base_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          if base_kind == GcValKind::Ref(ctx.string_type) {
            GcValKind::Ref(ctx.string_type)
          } else if base_kind == GcValKind::Ref(ctx.bytes_type) {
            GcValKind::Ref(ctx.bytes_type)
          } else {
            let _ = gc_array_type_idx_from_kind(ctx, base_kind, "__slice")
            base_kind
          }
        }
        "__add" | "__sub" | "__mul" | "__div" | "__mod" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("arity: " + name)
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          // Unify mismatched types (e.g., EqRef vs I64)
          let kind = if left_kind == right_kind {
            left_kind
          } else {
            gc_common_kind(left_kind, right_kind)
          }
          match kind {
            GcValKind::I64 | GcValKind::I32 | GcValKind::F32 | GcValKind::F64 =>
              kind
            _ => GcValKind::I64 // Default to I64 for unknown types
          }
        }
        "__neg" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("arity: " + name)
          }
          let kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          match kind {
            GcValKind::I64 | GcValKind::I32 | GcValKind::F32 | GcValKind::F64 =>
              kind
            _ => GcValKind::I64
          }
        }
        "__bit_and"
        | "__bit_or"
        | "__bit_xor"
        | "__bit_not"
        | "__bit_lshift"
        | "__bit_rshift"
        | "__lshift"
        | "__rshift"
        | "i32_shr_u" => GcValKind::I64
        "__to_string"
        | "Int::to_string"
        | "Bool::to_string"
        | "Float::to_string"
        | "Double::to_string"
        | "String::from_char_code"
        | "String::from_char_codes" => GcValKind::Ref(ctx.string_type)
        "Int::to_double" => GcValKind::F64
        "Int::to_float" => GcValKind::F32
        // Int::parse returns Option[Int]; enums are eqref-boxed in wasm-gc.
        "Int::parse" => GcValKind::EqRef
        "Int::abs"
        | "Int::max"
        | "Int::min"
        | "Int::signum"
        | "Int::clamp"
        | "Char::to_int"
        | "Char::from_int" => GcValKind::I64
        // is_even / is_odd compile to `(x & 1) i64.eq C`, which leaves
        // an i32 on the stack — not the i64 we were reporting. The
        // miscoded kind made the outer codegen apply an `i32.wrap_i64`
        // when assigning the result to a `Bool` (i32) return slot, and
        // the resulting wasm was invalid ("expected i32, found i32"
        // after the spurious wrap on validation).
        "Int::is_even" | "Int::is_odd" => GcValKind::I32
        "Double::to_int" => GcValKind::I64
        // Direct f64 math primitives. Match the compile-side dispatch
        // above and the linear backend's `f64_*` semantics — these
        // return the same kind as the argument (f32 for Float, f64 for
        // Double / Num).
        "Double::floor"
        | "Double::ceil"
        | "Double::trunc"
        | "Double::round"
        | "Double::sqrt"
        | "Double::fract"
        | "floor"
        | "ceil"
        | "trunc"
        | "round"
        | "fract" => {
          if pos_args.length() < 1 {
            raise WasmGenError::Unsupported(name + " arity")
          }
          let arg_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          if arg_kind == GcValKind::F32 {
            GcValKind::F32
          } else {
            GcValKind::F64
          }
        }
        "Float::floor"
        | "Float::ceil"
        | "Float::trunc"
        | "Float::round"
        | "Float::sqrt"
        | "Float::fract" => GcValKind::F32
        "Double::to_i64_bits" => GcValKind::I64
        "Double::parse" => GcValKind::F64
        "Double::to_float" => GcValKind::F32
        "Double::from_i64_bits" => GcValKind::F64
        "Float::to_double" => GcValKind::F64
        "Float::to_int" => GcValKind::I64
        "Array::length" => GcValKind::I64
        "FixedArray::length" => GcValKind::I64
        "Array::fold" | "fold" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("arity: Array::fold")
          }
          infer_expr_kind_gc(ctx, fctx, pos_args[1])
        }
        "Array::get" | "FixedArray::get" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("arity: " + name)
          }
          gc_array_elem_kind_from_kind(
            ctx,
            infer_expr_kind_gc(ctx, fctx, pos_args[0]),
            name,
          )
        }
        "Array::set"
        | "Array::push"
        | "Array::push_all"
        | "FixedArray::set"
        | "FixedArray::unsafe_set"
        | "FixedArray::blit" => GcValKind::I32
        "FixedArray::make" => {
          // FixedArray::make(size, default) → Array[T] where T is the
          // default's kind. Returns the corresponding gc array ref.
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("arity: FixedArray::make")
          }
          let elem_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            elem_kind,
          )
          GcValKind::Ref(arr_type)
        }
        "Array::slice" | "Array::concat" => {
          if pos_args.length() < 1 {
            raise WasmGenError::Unsupported("arity: " + name)
          }
          infer_expr_kind_gc(ctx, fctx, pos_args[0])
        }
        "Array::truncate" => GcValKind::I32
        "ArrayBuilder::new" => {
          // Return concrete builder struct type: { i32, ref array<eqref> }.
          // Mirror the compile-side default so `let b = ArrayBuilder::new()`
          // resolves to the eqref-backed builder when no explicit
          // `ArrayBuilder[T]` annotation is present.
          let arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::EqRef,
          )
          let builder_fields : Array[GcValKind] = [
            GcValKind::I32,
            GcValKind::Ref(arr_type),
          ]
          let builder_type = ensure_struct_type(
            ctx.types,
            ctx.struct_type_index,
            builder_fields,
          )
          GcValKind::Ref(builder_type)
        }
        "Array::with_capacity" => {
          // Array::with_capacity shares ArrayBuilder's struct layout but
          // keeps the historical i64 array storage for Array::push.
          let arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::I64,
          )
          let builder_fields : Array[GcValKind] = [
            GcValKind::I32,
            GcValKind::Ref(arr_type),
          ]
          let builder_type = ensure_struct_type(
            ctx.types,
            ctx.struct_type_index,
            builder_fields,
          )
          GcValKind::Ref(builder_type)
        }
        "ArrayBuilder::push" => GcValKind::I32
        "ArrayBuilder::freeze" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("arity: ArrayBuilder::freeze")
          }
          let builder_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          match builder_kind {
            GcValKind::Ref(type_idx) =>
              match ctx.types[type_idx] {
                GcTypeDef::Struct(fields~) =>
                  if fields.length() >= 2 {
                    fields[1]
                  } else {
                    GcValKind::EqRef
                  }
                _ => GcValKind::EqRef
              }
            _ => GcValKind::EqRef
          }
        }
        // Issue #414: wasm-gc StringBuilder. Layout mirrors
        // ArrayBuilder but element type is the gc String struct.
        // `new` returns a builder struct, `push` returns Unit-shape
        // i32, `freeze` returns a single concatenated String.
        "StringBuilder::new" => {
          let arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::Ref(ctx.string_type),
          )
          let builder_fields : Array[GcValKind] = [
            GcValKind::I32,
            GcValKind::Ref(arr_type),
          ]
          let builder_type = ensure_struct_type(
            ctx.types,
            ctx.struct_type_index,
            builder_fields,
          )
          GcValKind::Ref(builder_type)
        }
        "StringBuilder::push" => GcValKind::I32
        "StringBuilder::freeze" => GcValKind::Ref(ctx.string_type)
        "MapBuilder::new" | "MapBuilder::freeze" => {
          let key_arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::EqRef,
          )
          let val_arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::EqRef,
          )
          let builder_fields : Array[GcValKind] = [
            GcValKind::I32,
            GcValKind::Ref(key_arr_type),
            GcValKind::Ref(val_arr_type),
          ]
          let builder_type = ensure_struct_type(
            ctx.types,
            ctx.struct_type_index,
            builder_fields,
          )
          GcValKind::Ref(builder_type)
        }
        "MapBuilder::set" => GcValKind::I32
        "Map::iter_length" => GcValKind::I64
        "Map::iter_get" => GcValKind::EqRef
        "Map::get" => GcValKind::EqRef
        "Map::has_key" | "Map::has" => GcValKind::I32
        "Map::keys" | "Map::values" => {
          let arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::EqRef,
          )
          GcValKind::Ref(arr_type)
        }
        "Map::set" | "Map::delete" =>
          // Returns the (mutated) Map — same struct layout as the
          // input. Pull it from the first arg's kind to keep type
          // info accurate.
          if pos_args.length() >= 1 {
            infer_expr_kind_gc(ctx, fctx, pos_args[0])
          } else {
            GcValKind::EqRef
          }
        "__eq"
        | "__lt"
        | "String::equals"
        | "String::contains"
        | "String::starts_with"
        | "String::ends_with" => GcValKind::I32
        "anyref_eq"
        | "eqref_eq"
        | "i31ref_eq"
        | "structref_eq"
        | "arrayref_eq"
        | "funcref_eq"
        | "externref_eq" => GcValKind::I64
        "String::length"
        | "String::char_code_at"
        | "String::index_of"
        | "String::last_index_of"
        | "String::count"
        | "String::unicode_length" => GcValKind::I64
        "Bytes::length" | "Bytes::get" => GcValKind::I64
        "Int64Array::make" => GcValKind::Ref(ctx.int64array_type)
        "Int64Array::length" | "Int64Array::get" => GcValKind::I64
        "Int64Array::set" => GcValKind::I32
        "Bytes::new"
        | "Bytes::from_array"
        | "Bytes::from_string"
        | "Bytes::slice"
        | "Bytes::concat" => GcValKind::Ref(ctx.bytes_type)
        "Bytes::to_string" => GcValKind::Ref(ctx.string_type)
        "Bytes::push"
        | "Bytes::set"
        | "Bytes::append"
        | "Bytes::blit"
        | "Bytes::fill" => GcValKind::I32
        "Bytes::to_array" => {
          let type_idx = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::I64,
          )
          GcValKind::Ref(type_idx)
        }
        "String::substring"
        | "String::concat"
        | "String::trim"
        | "String::trim_start"
        | "String::trim_end"
        | "String::to_lower"
        | "String::to_upper"
        | "String::replace"
        | "String::join" => GcValKind::Ref(ctx.string_type)
        "String::split" => {
          let str_arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::Ref(ctx.string_type),
          )
          GcValKind::Ref(str_arr_type)
        }
        "record_set" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("arity: record_set")
          }
          infer_expr_kind_gc(ctx, fctx, pos_args[0])
        }
        _ =>
          match ctx.func_returns.get(name) {
            Some(kind) => kind
            None =>
              // Top-level function with no explicit return type annotation
              // (ret field is None after bundler/DCE). Fall back to I64.
              if ctx.func_indices.contains(name) {
                GcValKind::I64
              } else {
                match fctx.closure_call_types.get(name) {
                  Some(fn_type_idx) =>
                    match ctx.types[fn_type_idx] {
                      GcTypeDef::Func(result~, ..) => result
                      _ => raise WasmGenError::Unsupported("closure call type")
                    }
                  None =>
                    // Enum constructor call (including builtin Some/None)
                    if ctx.enum_ctor_tags.contains(name) ||
                      name == "Some" ||
                      name == "None" {
                      GcValKind::EqRef
                    } else if is_gc_builtin_name(name) {
                      GcValKind::EqRef
                    } else if pos_args.length() == 1 {
                      // Check local closure bindings first (they shadow field accessors)
                      match fctx.locals.get(name) {
                        Some(entry) =>
                          match entry.kind {
                            GcValKind::Ref(type_idx) =>
                              match ctx.types[type_idx] {
                                GcTypeDef::Struct(fields~) =>
                                  if fields.length() == 2 {
                                    match fields[0] {
                                      GcValKind::Ref(fn_idx) =>
                                        match ctx.types[fn_idx] {
                                          GcTypeDef::Func(result~, ..) => result
                                          _ => GcValKind::I64
                                        }
                                      _ => GcValKind::I64
                                    }
                                  } else {
                                    GcValKind::I64
                                  }
                                _ => GcValKind::I64
                              }
                            _ => GcValKind::I64
                          }
                        None =>
                          // Try struct field access: field_name(record_expr)
                          match
                            try_infer_struct_field_kind_gc(
                              ctx,
                              fctx,
                              name,
                              pos_args[0],
                            ) {
                            Some(kind) => kind
                            None => raise WasmGenError::UnknownName(name)
                          }
                      }
                    } else {
                      // Unknown call — check if it's in locals (HOF param)
                      match fctx.locals.get(name) {
                        Some(entry) =>
                          // Try to derive return type from closure struct type
                          match entry.kind {
                            GcValKind::Ref(type_idx) =>
                              match ctx.types[type_idx] {
                                GcTypeDef::Struct(fields~) =>
                                  if fields.length() == 2 {
                                    match fields[0] {
                                      GcValKind::Ref(fn_idx) =>
                                        match ctx.types[fn_idx] {
                                          GcTypeDef::Func(result~, ..) => result
                                          _ => GcValKind::I64
                                        }
                                      _ => GcValKind::I64
                                    }
                                  } else {
                                    GcValKind::I64
                                  }
                                _ => GcValKind::I64
                              }
                            _ => GcValKind::I64
                          }
                        None => raise WasmGenError::UnknownName(name)
                      }
                    }
                }
              }
          }
      }
    }
    @core.Expr::If(then_body~, else_body~, ..) => {
      let then_kind = infer_block_kind_gc(ctx, fctx, then_body)
      let else_kind = infer_block_kind_gc(ctx, fctx, else_body)
      if then_kind == else_kind {
        then_kind
      } else {
        // Coerce to common supertype
        gc_common_kind(then_kind, else_kind)
      }
    }
    @core.Expr::Block(body~, ..) => infer_block_kind_gc(ctx, fctx, body)
    @core.Expr::Array(items~, ..) => infer_array_kind_gc(ctx, fctx, items)
    @core.Expr::While(cond~, body~, ..) => {
      let cond_kind = infer_expr_kind_gc(ctx, fctx, cond)
      if cond_kind != GcValKind::I32 {
        raise WasmGenError::Unsupported("while cond kind")
      }
      let _ = infer_block_kind_gc(ctx, fctx, body)
      GcValKind::I32
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let _ = span
      if @core.is_string_for_in(span.start) {
        let (_, body_kind) = infer_string_for_in_parts_gc(
          ctx, fctx, value_name, index_name, body,
        )
        let type_idx = ensure_array_type(
          ctx.types,
          ctx.array_type_index,
          body_kind,
        )
        GcValKind::Ref(type_idx)
      } else {
        let (_, _, body_kind) = infer_for_in_parts_gc(
          ctx, fctx, value_name, index_name, iterable, body,
        )
        let type_idx = ensure_array_type(
          ctx.types,
          ctx.array_type_index,
          body_kind,
        )
        GcValKind::Ref(type_idx)
      }
    }
    @core.Expr::Tuple(items~, ..) => infer_tuple_kind_gc(ctx, fctx, items)
    @core.Expr::Record(fields~, ..) => infer_record_kind_gc(ctx, fctx, fields)
    @core.Expr::StructLit(fields~, ..) =>
      infer_record_kind_gc(ctx, fctx, fields)
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      if arms.length() == 0 {
        raise WasmGenError::Unsupported("match arms")
      }
      let scrut_kind = infer_expr_kind_gc(ctx, fctx, scrutinee)
      let saved = clone_locals_gc(fctx.locals)
      bind_pat_kinds_gc(ctx, fctx, scrut_kind, arms[0].pat)
      let mut kind = infer_expr_kind_gc(ctx, fctx, arms[0].expr)
      restore_locals_gc(fctx, saved)
      for i in 1..<arms.length() {
        let saved_arm = clone_locals_gc(fctx.locals)
        bind_pat_kinds_gc(ctx, fctx, scrut_kind, arms[i].pat)
        let arm_kind = infer_expr_kind_gc(ctx, fctx, arms[i].expr)
        restore_locals_gc(fctx, saved_arm)
        if arm_kind != kind {
          kind = gc_common_kind(kind, arm_kind)
        }
      }
      kind
    }
    @core.Expr::Fn(params~, ret~, body~, ..) => {
      let param_kinds : Array[GcValKind] = []
      for param in params {
        param_kinds.push(gc_val_kind_from_type(ctx, param.ty))
      }
      let result_kind = match ret {
        Some(ty) => gc_val_kind_from_type(ctx, ty)
        None => {
          let saved = clone_locals_gc(fctx.locals)
          for param in params {
            let k = gc_val_kind_from_type(ctx, param.ty)
            fctx.locals[param.name] = { idx: 0, kind: k }
          }
          let kind = infer_block_kind_gc(ctx, fctx, body)
          restore_locals_gc(fctx, saved)
          kind
        }
      }
      let (_, struct_type_idx) = ensure_closure_types_gc(
        ctx, param_kinds, result_kind,
      )
      GcValKind::Ref(struct_type_idx)
    }
    @core.Expr::Perform(effect_name="Error", op_name="Throw", ..) =>
      // throw always diverges, result type doesn't matter
      GcValKind::EqRef
    @core.Expr::Perform(..) => GcValKind::EqRef
    @core.Expr::Handle(body~, ..) =>
      // Handle result is the body's result type
      infer_block_kind_gc(ctx, fctx, body)
    @core.Expr::StringInterp(..) => GcValKind::Ref(ctx.string_type)
    @core.Expr::TupleIndex(expr~, index~, ..) => {
      let kind = infer_expr_kind_gc(ctx, fctx, expr)
      match kind {
        GcValKind::Ref(type_idx) =>
          match ctx.types[type_idx] {
            GcTypeDef::Struct(fields~) =>
              if index < fields.length() {
                fields[index]
              } else {
                GcValKind::EqRef
              }
            _ => GcValKind::EqRef
          }
        _ => GcValKind::EqRef
      }
    }
    @core.Expr::Break(..) | @core.Expr::Continue(..) | @core.Expr::Return(..) =>
      GcValKind::I32
    other =>
      raise WasmGenError::Unsupported(
        "expr: " + other.to_string()[:40].to_owned(),
      )
  }
}

///|
fn emit_string_literal(ctx : GcCodegenCtx, buf : GcByteBuf, s : String) -> Unit {
  let len = s.length()
  emit_i32_const_gc(buf, len)
  for i in 0..<len {
    let code : Int = s[i].to_int()
    emit_i32_const_gc(buf, code)
  }
  emit_array_new_fixed_gc(buf, ctx.array_i32_type, len)
  emit_struct_new_gc(buf, ctx.string_type)
}

///|
fn emit_clamp_to_len(buf : GcByteBuf, x_idx : Int, len_idx : Int) -> Unit {
  emit_local_get_gc(buf, x_idx)
  emit_i32_const_gc(buf, 0)
  emit_i32_lt_s_gc(buf)
  emit_if_gc(buf, Some(GcValKind::I32))
  emit_i32_const_gc(buf, 0)
  emit_else_gc(buf)
  emit_local_get_gc(buf, x_idx)
  emit_local_get_gc(buf, len_idx)
  emit_i32_gt_s_gc(buf)
  emit_if_gc(buf, Some(GcValKind::I32))
  emit_local_get_gc(buf, len_idx)
  emit_else_gc(buf)
  emit_local_get_gc(buf, x_idx)
  emit_end_gc(buf)
  emit_end_gc(buf)
}

///|
fn compile_string_char_code_at(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
  i_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let s_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  let len_idx = alloc_local_gc(fctx, GcValKind::I32)
  let data_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_local_set_gc(buf, s_idx)
  compile_expr_gc(ctx, fctx, buf, i_expr)
  emit_i32_wrap_i64_gc(buf) // Int (i64) → i32 index
  emit_local_set_gc(buf, i_idx)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, len_idx)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 0)
  emit_i32_lt_s_gc(buf)
  emit_if_gc(buf, None)
  emit_unreachable_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, len_idx)
  emit_i32_ge_s_gc(buf)
  emit_if_gc(buf, None)
  emit_unreachable_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, data_idx)
  emit_local_get_gc(buf, data_idx)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  // String char array is i32-typed but vibe Int = i64; extend to match
  // callers that consume the result as Int (e.g. sha1 `read_word` shifts
  // the byte left by 24 via `__lshift` which expects i64).
  emit_i64_extend_i32_s_gc(buf)
}

///|
fn compile_string_from_char_codes_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  arr_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let arr_kind = infer_expr_kind_gc(ctx, fctx, arr_expr)
  let arr_type = gc_array_type_idx_from_kind(
    ctx, arr_kind, "String::from_char_codes",
  )
  let elem_kind = gc_array_elem_kind_from_kind(
    ctx, arr_kind, "String::from_char_codes",
  )
  let arr_idx = alloc_local_gc(fctx, arr_kind)
  let len_idx = alloc_local_gc(fctx, GcValKind::I32)
  let out_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, arr_expr)
  emit_local_set_gc(buf, arr_idx)
  emit_local_get_gc(buf, arr_idx)
  emit_array_len_gc(buf)
  emit_local_set_gc(buf, len_idx)
  emit_local_get_gc(buf, len_idx)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, out_idx)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, len_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, out_idx)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, arr_idx)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, arr_type)
  match elem_kind {
    GcValKind::I64 => emit_i32_wrap_i64_gc(buf)
    GcValKind::I32 => ()
    other => {
      emit_coerce_top_gc(ctx, buf, other, GcValKind::I64)
      emit_i32_wrap_i64_gc(buf)
    }
  }
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, len_idx)
  emit_local_get_gc(buf, out_idx)
  emit_struct_new_gc(buf, ctx.string_type)
}

///|
/// Map struct type accessor: builder_type / key_arr_type / val_arr_type
/// tuple for the canonical 3-field map layout. Repeated in many Map::*
/// call sites — factored here.
fn map_struct_types_gc(ctx : GcCodegenCtx) -> (Int, Int, Int) {
  let key_arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::EqRef,
  )
  let val_arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::EqRef,
  )
  let builder_fields : Array[GcValKind] = [
    GcValKind::I32,
    GcValKind::Ref(key_arr_type),
    GcValKind::Ref(val_arr_type),
  ]
  let builder_type = ensure_struct_type(
    ctx.types,
    ctx.struct_type_index,
    builder_fields,
  )
  (builder_type, key_arr_type, val_arr_type)
}

///|
/// Map::set(map, key, value) — wasm-gc. Updates the slot if `key`
/// already exists, otherwise grows the backing arrays (2× capacity
/// when full) and appends. Returns the (now mutated) map ref.
///
/// Mirrors MapBuilder::set's traversal logic; the only difference is
/// the final stack value — Map::set leaves the map ref on the stack
/// where MapBuilder::set leaves a Unit i32.
fn compile_map_set_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  let (builder_type, key_arr_type, val_arr_type) = map_struct_types_gc(ctx)
  let b_idx = alloc_local_gc(fctx, GcValKind::Ref(builder_type))
  let len_l = alloc_local_gc(fctx, GcValKind::I32)
  let cap_l = alloc_local_gc(fctx, GcValKind::I32)
  let keys_l = alloc_local_gc(fctx, GcValKind::Ref(key_arr_type))
  let vals_l = alloc_local_gc(fctx, GcValKind::Ref(val_arr_type))
  let new_keys = alloc_local_gc(fctx, GcValKind::Ref(key_arr_type))
  let new_vals = alloc_local_gc(fctx, GcValKind::Ref(val_arr_type))
  let i_l = alloc_local_gc(fctx, GcValKind::I32)
  let key_l = alloc_local_gc(fctx, GcValKind::EqRef)
  let found_l = alloc_local_gc(fctx, GcValKind::I32)
  let val_l = alloc_local_gc(fctx, GcValKind::EqRef)
  let cur_key_l = alloc_local_gc(fctx, GcValKind::EqRef)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_local_set_gc(buf, b_idx)
  let key_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
  compile_expr_gc(ctx, fctx, buf, pos_args[1])
  emit_box_top_for_ref_kind_gc(ctx, buf, key_kind, GcValKind::EqRef)
  emit_local_set_gc(buf, key_l)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 0)
  emit_local_set_gc(buf, len_l)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 1)
  emit_local_set_gc(buf, keys_l)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 2)
  emit_local_set_gc(buf, vals_l)
  emit_local_get_gc(buf, keys_l)
  emit_array_len_gc(buf)
  emit_local_set_gc(buf, cap_l)
  let val_kind = infer_expr_kind_gc(ctx, fctx, pos_args[2])
  compile_expr_gc(ctx, fctx, buf, pos_args[2])
  emit_box_top_for_ref_kind_gc(ctx, buf, val_kind, GcValKind::EqRef)
  emit_local_set_gc(buf, val_l)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_l)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, found_l)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, len_l)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, keys_l)
  emit_local_get_gc(buf, i_l)
  emit_array_get_gc(buf, key_arr_type)
  emit_local_set_gc(buf, cur_key_l)
  emit_map_key_eq_gc(ctx, fctx, buf, cur_key_l, key_l)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, vals_l)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, val_l)
  emit_array_set_gc(buf, val_arr_type)
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, found_l)
  emit_br_gc(buf, 2)
  emit_end_gc(buf)
  emit_local_get_gc(buf, i_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_l)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, found_l)
  emit_i32_eqz_gc(buf)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, len_l)
  emit_local_get_gc(buf, cap_l)
  emit_i32_ge_s_gc(buf)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, cap_l)
  emit_i32_const_gc(buf, 2)
  emit_i32_mul_gc(buf)
  emit_array_new_default_gc(buf, key_arr_type)
  emit_local_set_gc(buf, new_keys)
  emit_local_get_gc(buf, cap_l)
  emit_i32_const_gc(buf, 2)
  emit_i32_mul_gc(buf)
  emit_array_new_default_gc(buf, val_arr_type)
  emit_local_set_gc(buf, new_vals)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_l)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, len_l)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, new_keys)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, keys_l)
  emit_local_get_gc(buf, i_l)
  emit_array_get_gc(buf, key_arr_type)
  emit_array_set_gc(buf, key_arr_type)
  emit_local_get_gc(buf, new_vals)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, vals_l)
  emit_local_get_gc(buf, i_l)
  emit_array_get_gc(buf, val_arr_type)
  emit_array_set_gc(buf, val_arr_type)
  emit_local_get_gc(buf, i_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_l)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, b_idx)
  emit_local_get_gc(buf, new_keys)
  emit_struct_set_gc(buf, builder_type, 1)
  emit_local_get_gc(buf, b_idx)
  emit_local_get_gc(buf, new_vals)
  emit_struct_set_gc(buf, builder_type, 2)
  emit_local_get_gc(buf, new_keys)
  emit_local_set_gc(buf, keys_l)
  emit_local_get_gc(buf, new_vals)
  emit_local_set_gc(buf, vals_l)
  emit_end_gc(buf)
  emit_local_get_gc(buf, keys_l)
  emit_local_get_gc(buf, len_l)
  emit_local_get_gc(buf, key_l)
  emit_array_set_gc(buf, key_arr_type)
  emit_local_get_gc(buf, vals_l)
  emit_local_get_gc(buf, len_l)
  emit_local_get_gc(buf, val_l)
  emit_array_set_gc(buf, val_arr_type)
  emit_local_get_gc(buf, b_idx)
  emit_local_get_gc(buf, len_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_struct_set_gc(buf, builder_type, 0)
  emit_end_gc(buf)
  // Return the (possibly grown) map on the stack
  emit_local_get_gc(buf, b_idx)
}

///|
/// Map::delete(map, key) — wasm-gc. Linear search; if `key` is found,
/// swap-remove with the last slot (cheap O(1) removal — order isn't
/// preserved). Returns the (mutated) map ref.
fn compile_map_delete_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  let (builder_type, key_arr_type, val_arr_type) = map_struct_types_gc(ctx)
  let b_idx = alloc_local_gc(fctx, GcValKind::Ref(builder_type))
  let len_l = alloc_local_gc(fctx, GcValKind::I32)
  let last_l = alloc_local_gc(fctx, GcValKind::I32)
  let keys_l = alloc_local_gc(fctx, GcValKind::Ref(key_arr_type))
  let vals_l = alloc_local_gc(fctx, GcValKind::Ref(val_arr_type))
  let i_l = alloc_local_gc(fctx, GcValKind::I32)
  let key_l = alloc_local_gc(fctx, GcValKind::EqRef)
  let cur_key_l = alloc_local_gc(fctx, GcValKind::EqRef)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_local_set_gc(buf, b_idx)
  let key_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
  compile_expr_gc(ctx, fctx, buf, pos_args[1])
  emit_box_top_for_ref_kind_gc(ctx, buf, key_kind, GcValKind::EqRef)
  emit_local_set_gc(buf, key_l)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 0)
  emit_local_set_gc(buf, len_l)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 1)
  emit_local_set_gc(buf, keys_l)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 2)
  emit_local_set_gc(buf, vals_l)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_l)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, len_l)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, keys_l)
  emit_local_get_gc(buf, i_l)
  emit_array_get_gc(buf, key_arr_type)
  emit_local_set_gc(buf, cur_key_l)
  emit_map_key_eq_gc(ctx, fctx, buf, cur_key_l, key_l)
  emit_if_gc(buf, None)
  // last = len - 1
  emit_local_get_gc(buf, len_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_sub_gc(buf)
  emit_local_set_gc(buf, last_l)
  // keys[i] = keys[last], vals[i] = vals[last] (skip when i == last)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, last_l)
  emit_i32_ne_gc(buf)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, keys_l)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, keys_l)
  emit_local_get_gc(buf, last_l)
  emit_array_get_gc(buf, key_arr_type)
  emit_array_set_gc(buf, key_arr_type)
  emit_local_get_gc(buf, vals_l)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, vals_l)
  emit_local_get_gc(buf, last_l)
  emit_array_get_gc(buf, val_arr_type)
  emit_array_set_gc(buf, val_arr_type)
  emit_end_gc(buf)
  // len -= 1
  emit_local_get_gc(buf, b_idx)
  emit_local_get_gc(buf, last_l)
  emit_struct_set_gc(buf, builder_type, 0)
  emit_br_gc(buf, 2)
  emit_end_gc(buf)
  emit_local_get_gc(buf, i_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_l)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // Always return the map ref (untouched if key was absent).
  emit_local_get_gc(buf, b_idx)
}

///|
fn compile_string_concat(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  a_expr : @core.Expr,
  b_expr : @core.Expr,
) -> Unit raise WasmGenError {
  // Note: tried `array.copy` (gc bulk op) here as a memcpy
  // equivalent of the linear backend's `memory.copy`. Wasmtime 36's
  // Cranelift implementation of `array.copy` turned out ~45× slower
  // than the per-element loop on small copies (3.4 s vs 74 ms for
  // a 5000-iter single-char concat benchmark). Sticking with the
  // loops until wasmtime's GC bulk-copy fast path lands; the loops
  // themselves are fine, the bottleneck for SHA-1-shaped workloads
  // is the algorithmic O(N²) of `acc|>String::concat(small)` rather
  // than the per-byte op count.
  let a_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let b_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let len_a_idx = alloc_local_gc(fctx, GcValKind::I32)
  let len_b_idx = alloc_local_gc(fctx, GcValKind::I32)
  let total_idx = alloc_local_gc(fctx, GcValKind::I32)
  let data_a_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let data_b_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let arr_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  let j_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, a_expr)
  emit_local_set_gc(buf, a_idx)
  compile_expr_gc(ctx, fctx, buf, b_expr)
  emit_local_set_gc(buf, b_idx)
  emit_local_get_gc(buf, a_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, len_a_idx)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, len_b_idx)
  emit_local_get_gc(buf, len_a_idx)
  emit_local_get_gc(buf, len_b_idx)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, total_idx)
  emit_local_get_gc(buf, a_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, data_a_idx)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, data_b_idx)
  emit_local_get_gc(buf, total_idx)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, arr_idx)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, len_a_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, arr_idx)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, data_a_idx)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, j_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, j_idx)
  emit_local_get_gc(buf, len_b_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, arr_idx)
  emit_local_get_gc(buf, len_a_idx)
  emit_local_get_gc(buf, j_idx)
  emit_i32_add_gc(buf)
  emit_local_get_gc(buf, data_b_idx)
  emit_local_get_gc(buf, j_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, j_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, j_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, total_idx)
  emit_local_get_gc(buf, arr_idx)
  emit_struct_new_gc(buf, ctx.string_type)
}

///|
fn compile_string_substring(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
  a_expr : @core.Expr,
  b_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let s_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let a_idx = alloc_local_gc(fctx, GcValKind::I32)
  let b_idx = alloc_local_gc(fctx, GcValKind::I32)
  let len_idx = alloc_local_gc(fctx, GcValKind::I32)
  let a_clamp_idx = alloc_local_gc(fctx, GcValKind::I32)
  let b_clamp_idx = alloc_local_gc(fctx, GcValKind::I32)
  let start_idx = alloc_local_gc(fctx, GcValKind::I32)
  let end_idx = alloc_local_gc(fctx, GcValKind::I32)
  let n_idx = alloc_local_gc(fctx, GcValKind::I32)
  let data_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let arr_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_local_set_gc(buf, s_idx)
  compile_expr_gc(ctx, fctx, buf, a_expr)
  emit_i32_wrap_i64_gc(buf) // Int (i64) → i32 index
  emit_local_set_gc(buf, a_idx)
  compile_expr_gc(ctx, fctx, buf, b_expr)
  emit_i32_wrap_i64_gc(buf) // Int (i64) → i32 index
  emit_local_set_gc(buf, b_idx)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, len_idx)
  emit_clamp_to_len(buf, a_idx, len_idx)
  emit_local_set_gc(buf, a_clamp_idx)
  emit_clamp_to_len(buf, b_idx, len_idx)
  emit_local_set_gc(buf, b_clamp_idx)
  emit_local_get_gc(buf, a_clamp_idx)
  emit_local_get_gc(buf, b_clamp_idx)
  emit_i32_le_s_gc(buf)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, a_clamp_idx)
  emit_local_set_gc(buf, start_idx)
  emit_local_get_gc(buf, b_clamp_idx)
  emit_local_set_gc(buf, end_idx)
  emit_else_gc(buf)
  emit_local_get_gc(buf, b_clamp_idx)
  emit_local_set_gc(buf, start_idx)
  emit_local_get_gc(buf, a_clamp_idx)
  emit_local_set_gc(buf, end_idx)
  emit_end_gc(buf)
  emit_local_get_gc(buf, end_idx)
  emit_local_get_gc(buf, start_idx)
  emit_i32_sub_gc(buf)
  emit_local_set_gc(buf, n_idx)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, data_idx)
  emit_local_get_gc(buf, n_idx)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, arr_idx)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, n_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, arr_idx)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, data_idx)
  emit_local_get_gc(buf, start_idx)
  emit_local_get_gc(buf, i_idx)
  emit_i32_add_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, n_idx)
  emit_local_get_gc(buf, arr_idx)
  emit_struct_new_gc(buf, ctx.string_type)
}

///|
fn compile_string_equals(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  a_expr : @core.Expr,
  b_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let a_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let b_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let len_a_idx = alloc_local_gc(fctx, GcValKind::I32)
  let len_b_idx = alloc_local_gc(fctx, GcValKind::I32)
  let data_a_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let data_b_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  let last_idx = alloc_local_gc(fctx, GcValKind::I32)
  let ok_idx = alloc_local_gc(fctx, GcValKind::I32)
  // Coerce both operands to the String ref type before spilling into
  // the comparison-local pair. `hash_require[T: Hash](x: T) -> T` and
  // similar generics give back an eqref-shaped result at the call
  // site, even when the static argument was a String; the local was
  // pre-allocated as `Ref(string_type)` and `local.set` rejected the
  // wider eqref otherwise.
  let a_kind = infer_expr_kind_gc(ctx, fctx, a_expr)
  let b_kind = infer_expr_kind_gc(ctx, fctx, b_expr)
  compile_expr_gc(ctx, fctx, buf, a_expr)
  emit_coerce_top_gc(ctx, buf, a_kind, GcValKind::Ref(ctx.string_type))
  emit_local_set_gc(buf, a_idx)
  compile_expr_gc(ctx, fctx, buf, b_expr)
  emit_coerce_top_gc(ctx, buf, b_kind, GcValKind::Ref(ctx.string_type))
  emit_local_set_gc(buf, b_idx)
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, ok_idx)
  emit_block_gc(buf, None)
  emit_local_get_gc(buf, a_idx)
  emit_local_get_gc(buf, b_idx)
  emit_ref_eq_gc(buf)
  emit_br_if_gc(buf, 0)
  emit_local_get_gc(buf, a_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, len_a_idx)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, len_b_idx)
  emit_local_get_gc(buf, len_a_idx)
  emit_local_get_gc(buf, len_b_idx)
  emit_i32_ne_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, ok_idx)
  emit_br_gc(buf, 1)
  emit_end_gc(buf)
  emit_local_get_gc(buf, len_a_idx)
  emit_i32_const_gc(buf, 0)
  emit_i32_eq_gc(buf)
  emit_br_if_gc(buf, 0)
  emit_local_get_gc(buf, a_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, data_a_idx)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, data_b_idx)
  emit_local_get_gc(buf, data_a_idx)
  emit_i32_const_gc(buf, 0)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, data_b_idx)
  emit_i32_const_gc(buf, 0)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_i32_ne_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, ok_idx)
  emit_br_gc(buf, 1)
  emit_end_gc(buf)
  emit_local_get_gc(buf, len_a_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_sub_gc(buf)
  emit_local_set_gc(buf, last_idx)
  emit_local_get_gc(buf, last_idx)
  emit_i32_const_gc(buf, 0)
  emit_i32_eq_gc(buf)
  emit_br_if_gc(buf, 0)
  emit_local_get_gc(buf, data_a_idx)
  emit_local_get_gc(buf, last_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, data_b_idx)
  emit_local_get_gc(buf, last_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_i32_ne_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, ok_idx)
  emit_br_gc(buf, 1)
  emit_end_gc(buf)
  emit_local_get_gc(buf, len_a_idx)
  emit_i32_const_gc(buf, 2)
  emit_i32_le_s_gc(buf)
  emit_br_if_gc(buf, 0)
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, last_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, data_a_idx)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, data_b_idx)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_i32_ne_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, ok_idx)
  emit_br_gc(buf, 2)
  emit_end_gc(buf)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, ok_idx)
}

///|
/// Emit Map key equality comparison.
/// Assumes key_a_local and key_b_local are eqref locals.
/// Leaves i32 (0 or 1) on the stack.
/// Strategy: ref_eq fast path → i31ref int compare → string structural compare → 0
fn emit_map_key_eq_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  key_a_local : Int,
  key_b_local : Int,
) -> Unit {
  let ok_idx = alloc_local_gc(fctx, GcValKind::I32)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, ok_idx)
  // block $done
  emit_block_gc(buf, None)
  // Fast path: ref_eq (handles i31ref ints and identical object refs)
  emit_local_get_gc(buf, key_a_local)
  emit_local_get_gc(buf, key_b_local)
  emit_ref_eq_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, ok_idx)
  emit_br_gc(buf, 1) // br $done
  emit_end_gc(buf) // end if
  // Int path: unbox and compare I64 values
  let i64_box_type = ensure_struct_type(ctx.types, ctx.struct_type_index, [
    GcValKind::I64,
  ])
  emit_local_get_gc(buf, key_a_local)
  emit_ref_test_gc(buf, i64_box_type)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, key_b_local)
  emit_ref_test_gc(buf, i64_box_type)
  emit_if_gc(buf, None)
  // Both are boxed I64 — unbox and compare
  emit_local_get_gc(buf, key_a_local)
  emit_ref_cast_gc(buf, i64_box_type)
  emit_struct_get_gc(buf, i64_box_type, 0)
  emit_local_get_gc(buf, key_b_local)
  emit_ref_cast_gc(buf, i64_box_type)
  emit_struct_get_gc(buf, i64_box_type, 0)
  emit_i64_eq_gc(buf)
  emit_local_set_gc(buf, ok_idx)
  emit_br_gc(buf, 2) // br $done
  emit_end_gc(buf) // end if (b is i64)
  emit_end_gc(buf) // end if (a is i64)
  // String path: structural comparison
  emit_local_get_gc(buf, key_a_local)
  emit_ref_test_gc(buf, ctx.string_type)
  emit_i32_const_gc(buf, 0)
  emit_i32_eq_gc(buf)
  emit_br_if_gc(buf, 0) // br $done if not string
  emit_local_get_gc(buf, key_b_local)
  emit_ref_test_gc(buf, ctx.string_type)
  emit_i32_const_gc(buf, 0)
  emit_i32_eq_gc(buf)
  emit_br_if_gc(buf, 0) // br $done if not string
  // Both are strings: structural comparison
  let a_str = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let b_str = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  emit_local_get_gc(buf, key_a_local)
  emit_ref_cast_gc(buf, ctx.string_type)
  emit_local_set_gc(buf, a_str)
  emit_local_get_gc(buf, key_b_local)
  emit_ref_cast_gc(buf, ctx.string_type)
  emit_local_set_gc(buf, b_str)
  let len_a = alloc_local_gc(fctx, GcValKind::I32)
  let len_b = alloc_local_gc(fctx, GcValKind::I32)
  emit_local_get_gc(buf, a_str)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, len_a)
  emit_local_get_gc(buf, b_str)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, len_b)
  // Length mismatch → not equal
  emit_local_get_gc(buf, len_a)
  emit_local_get_gc(buf, len_b)
  emit_i32_ne_gc(buf)
  emit_br_if_gc(buf, 0) // br $done
  // Empty strings are equal
  emit_local_get_gc(buf, len_a)
  emit_i32_const_gc(buf, 0)
  emit_i32_eq_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, ok_idx)
  emit_br_gc(buf, 1) // br $done
  emit_end_gc(buf) // end if
  // Compare data arrays element by element
  let data_a = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let data_b = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  emit_local_get_gc(buf, a_str)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, data_a)
  emit_local_get_gc(buf, b_str)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, data_b)
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, ok_idx)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  // block $cmp_done
  emit_block_gc(buf, None)
  // loop $cmp_loop
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, len_a)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1) // br $cmp_done
  emit_local_get_gc(buf, data_a)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, data_b)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_i32_ne_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, ok_idx)
  emit_br_gc(buf, 2) // br $cmp_done
  emit_end_gc(buf) // end if
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0) // br $cmp_loop
  emit_end_gc(buf) // end loop
  emit_end_gc(buf) // end $cmp_done
  emit_end_gc(buf) // end $done
  emit_local_get_gc(buf, ok_idx)
}

///|
fn compile_string_index_of(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
  sub_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let s_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let sub_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let s_len = alloc_local_gc(fctx, GcValKind::I32)
  let sub_len = alloc_local_gc(fctx, GcValKind::I32)
  let s_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let sub_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let outer_i = alloc_local_gc(fctx, GcValKind::I32)
  let inner_j = alloc_local_gc(fctx, GcValKind::I32)
  let result = alloc_local_gc(fctx, GcValKind::I32)
  let matched = alloc_local_gc(fctx, GcValKind::I32)
  let limit = alloc_local_gc(fctx, GcValKind::I32)
  // compile arguments
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_local_set_gc(buf, s_idx)
  compile_expr_gc(ctx, fctx, buf, sub_expr)
  emit_local_set_gc(buf, sub_idx)
  // extract lengths and data
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, s_len)
  emit_local_get_gc(buf, sub_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, sub_len)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, s_data)
  emit_local_get_gc(buf, sub_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, sub_data)
  // result = -1
  emit_i32_const_gc(buf, -1)
  emit_local_set_gc(buf, result)
  // limit = s_len - sub_len + 1
  emit_local_get_gc(buf, s_len)
  emit_local_get_gc(buf, sub_len)
  emit_i32_sub_gc(buf)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, limit)
  // outer_i = 0
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, outer_i)
  // block { loop { ... } }
  emit_block_gc(buf, None) // block 0 (break target)
  emit_loop_gc(buf, None) // loop 1
  // if outer_i >= limit, break
  emit_local_get_gc(buf, outer_i)
  emit_local_get_gc(buf, limit)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1) // break to block
  // matched = 1
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, matched)
  // inner_j = 0
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, inner_j)
  // inner: block { loop { ... } }
  emit_block_gc(buf, None) // block 2
  emit_loop_gc(buf, None) // loop 3
  // if inner_j >= sub_len, break inner
  emit_local_get_gc(buf, inner_j)
  emit_local_get_gc(buf, sub_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1) // break inner block
  // compare s_data[outer_i + inner_j] != sub_data[inner_j]
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, outer_i)
  emit_local_get_gc(buf, inner_j)
  emit_i32_add_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, sub_data)
  emit_local_get_gc(buf, inner_j)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_i32_ne_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, matched)
  emit_br_gc(buf, 2) // break inner block
  emit_end_gc(buf)
  // inner_j++
  emit_local_get_gc(buf, inner_j)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, inner_j)
  emit_br_gc(buf, 0) // continue inner loop
  emit_end_gc(buf) // end inner loop
  emit_end_gc(buf) // end inner block
  // if matched, set result and break outer
  emit_local_get_gc(buf, matched)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, outer_i)
  emit_local_set_gc(buf, result)
  emit_br_gc(buf, 2) // break outer block (depth: 0=if, 1=loop, 2=block)
  emit_end_gc(buf) // end if
  // outer_i++
  emit_local_get_gc(buf, outer_i)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, outer_i)
  emit_br_gc(buf, 0) // continue outer loop
  emit_end_gc(buf) // end outer loop
  emit_end_gc(buf) // end outer block
  // return result as i64
  emit_local_get_gc(buf, result)
  emit_i64_extend_i32_s_gc(buf)
}

///|
/// String::last_index_of(str, sub) -> i32 index or -1
fn compile_string_last_index_of(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
  sub_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let s_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let sub_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let s_len = alloc_local_gc(fctx, GcValKind::I32)
  let sub_len = alloc_local_gc(fctx, GcValKind::I32)
  let s_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let sub_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let outer_i = alloc_local_gc(fctx, GcValKind::I32)
  let inner_j = alloc_local_gc(fctx, GcValKind::I32)
  let result = alloc_local_gc(fctx, GcValKind::I32)
  let matched = alloc_local_gc(fctx, GcValKind::I32)
  let limit = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_local_set_gc(buf, s_idx)
  compile_expr_gc(ctx, fctx, buf, sub_expr)
  emit_local_set_gc(buf, sub_idx)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, s_len)
  emit_local_get_gc(buf, sub_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, sub_len)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, s_data)
  emit_local_get_gc(buf, sub_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, sub_data)
  // result = -1
  emit_i32_const_gc(buf, -1)
  emit_local_set_gc(buf, result)
  // limit = s_len - sub_len (last valid start position)
  emit_local_get_gc(buf, s_len)
  emit_local_get_gc(buf, sub_len)
  emit_i32_sub_gc(buf)
  emit_local_set_gc(buf, limit)
  // outer_i = limit (start from end)
  emit_local_get_gc(buf, limit)
  emit_local_set_gc(buf, outer_i)
  // block { loop { ... } }
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  // if outer_i < 0, break
  emit_local_get_gc(buf, outer_i)
  emit_i32_const_gc(buf, 0)
  emit_i32_lt_s_gc(buf)
  emit_br_if_gc(buf, 1)
  // matched = 1
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, matched)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, inner_j)
  // inner search
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, inner_j)
  emit_local_get_gc(buf, sub_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, outer_i)
  emit_local_get_gc(buf, inner_j)
  emit_i32_add_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, sub_data)
  emit_local_get_gc(buf, inner_j)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_i32_ne_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, matched)
  emit_br_gc(buf, 2)
  emit_end_gc(buf)
  emit_local_get_gc(buf, inner_j)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, inner_j)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // if matched, set result and break
  emit_local_get_gc(buf, matched)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, outer_i)
  emit_local_set_gc(buf, result)
  emit_br_gc(buf, 2)
  emit_end_gc(buf)
  // outer_i--
  emit_local_get_gc(buf, outer_i)
  emit_i32_const_gc(buf, 1)
  emit_i32_sub_gc(buf)
  emit_local_set_gc(buf, outer_i)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, result)
  emit_i64_extend_i32_s_gc(buf)
}

///|
/// String::contains(str, sub) -> i32 bool
fn compile_string_contains(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
  sub_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let s_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let sub_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let s_len = alloc_local_gc(fctx, GcValKind::I32)
  let sub_len = alloc_local_gc(fctx, GcValKind::I32)
  let s_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let sub_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let outer_i = alloc_local_gc(fctx, GcValKind::I32)
  let inner_j = alloc_local_gc(fctx, GcValKind::I32)
  let result = alloc_local_gc(fctx, GcValKind::I32)
  let matched = alloc_local_gc(fctx, GcValKind::I32)
  let limit = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_local_set_gc(buf, s_idx)
  compile_expr_gc(ctx, fctx, buf, sub_expr)
  emit_local_set_gc(buf, sub_idx)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, s_len)
  emit_local_get_gc(buf, sub_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, sub_len)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, s_data)
  emit_local_get_gc(buf, sub_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, sub_data)
  // result = 0 (false)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, result)
  // limit = s_len - sub_len + 1
  emit_local_get_gc(buf, s_len)
  emit_local_get_gc(buf, sub_len)
  emit_i32_sub_gc(buf)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, limit)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, outer_i)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, outer_i)
  emit_local_get_gc(buf, limit)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, matched)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, inner_j)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, inner_j)
  emit_local_get_gc(buf, sub_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, outer_i)
  emit_local_get_gc(buf, inner_j)
  emit_i32_add_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, sub_data)
  emit_local_get_gc(buf, inner_j)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_i32_ne_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, matched)
  emit_br_gc(buf, 2)
  emit_end_gc(buf)
  emit_local_get_gc(buf, inner_j)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, inner_j)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, matched)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, result)
  emit_br_gc(buf, 2)
  emit_end_gc(buf)
  emit_local_get_gc(buf, outer_i)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, outer_i)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, result)
}

///|
/// String::starts_with(str, prefix) -> i32 bool
fn compile_string_starts_with(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
  prefix_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let s_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let prefix_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let s_len = alloc_local_gc(fctx, GcValKind::I32)
  let prefix_len = alloc_local_gc(fctx, GcValKind::I32)
  let s_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let prefix_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  let result = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_local_set_gc(buf, s_idx)
  compile_expr_gc(ctx, fctx, buf, prefix_expr)
  emit_local_set_gc(buf, prefix_idx)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, s_len)
  emit_local_get_gc(buf, prefix_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, prefix_len)
  // result = 1 (assume true)
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, result)
  // if prefix_len > s_len, result = 0
  emit_local_get_gc(buf, prefix_len)
  emit_local_get_gc(buf, s_len)
  emit_i32_gt_s_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, result)
  emit_else_gc(buf)
  // extract data arrays
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, s_data)
  emit_local_get_gc(buf, prefix_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, prefix_data)
  // compare each char
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, prefix_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, prefix_data)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_i32_ne_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, result)
  emit_br_gc(buf, 2) // break outer block
  emit_end_gc(buf)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_end_gc(buf) // end else/if
  emit_local_get_gc(buf, result)
}

///|
/// String::ends_with(str, suffix) -> i32 bool
fn compile_string_ends_with(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
  suffix_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let s_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let suffix_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let s_len = alloc_local_gc(fctx, GcValKind::I32)
  let suffix_len = alloc_local_gc(fctx, GcValKind::I32)
  let s_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let suffix_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  let offset_idx = alloc_local_gc(fctx, GcValKind::I32)
  let result = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_local_set_gc(buf, s_idx)
  compile_expr_gc(ctx, fctx, buf, suffix_expr)
  emit_local_set_gc(buf, suffix_idx)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, s_len)
  emit_local_get_gc(buf, suffix_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, suffix_len)
  // result = 1
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, result)
  // if suffix_len > s_len, result = 0
  emit_local_get_gc(buf, suffix_len)
  emit_local_get_gc(buf, s_len)
  emit_i32_gt_s_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, result)
  emit_else_gc(buf)
  // offset = s_len - suffix_len
  emit_local_get_gc(buf, s_len)
  emit_local_get_gc(buf, suffix_len)
  emit_i32_sub_gc(buf)
  emit_local_set_gc(buf, offset_idx)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, s_data)
  emit_local_get_gc(buf, suffix_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, suffix_data)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, suffix_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  // compare s_data[offset + i] != suffix_data[i]
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, offset_idx)
  emit_local_get_gc(buf, i_idx)
  emit_i32_add_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, suffix_data)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_i32_ne_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, result)
  emit_br_gc(buf, 2)
  emit_end_gc(buf)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_end_gc(buf) // end else/if
  emit_local_get_gc(buf, result)
}

///|
/// String::trim(str) -> string (trim leading/trailing whitespace)
fn compile_string_trim(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let s_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let s_len = alloc_local_gc(fctx, GcValKind::I32)
  let s_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let start_idx = alloc_local_gc(fctx, GcValKind::I32)
  let end_idx = alloc_local_gc(fctx, GcValKind::I32)
  let n_idx = alloc_local_gc(fctx, GcValKind::I32)
  let arr_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  let ch_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_local_set_gc(buf, s_idx)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, s_len)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, s_data)
  // start = 0, end = s_len
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, start_idx)
  emit_local_get_gc(buf, s_len)
  emit_local_set_gc(buf, end_idx)
  // skip leading whitespace: while start < end && is_ws(data[start])
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, start_idx)
  emit_local_get_gc(buf, end_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  // check whitespace: ch == 32 || ch == 9 || ch == 10 || ch == 13
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, start_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, ch_idx)
  // is_ws = (ch == 32) | (ch == 9) | (ch == 10) | (ch == 13)
  emit_local_get_gc(buf, ch_idx)
  emit_i32_const_gc(buf, 32)
  emit_i32_eq_gc(buf)
  emit_local_get_gc(buf, ch_idx)
  emit_i32_const_gc(buf, 9)
  emit_i32_eq_gc(buf)
  emit_i32_add_gc(buf) // use add as bitwise or for booleans (0 or 1)
  emit_local_get_gc(buf, ch_idx)
  emit_i32_const_gc(buf, 10)
  emit_i32_eq_gc(buf)
  emit_i32_add_gc(buf)
  emit_local_get_gc(buf, ch_idx)
  emit_i32_const_gc(buf, 13)
  emit_i32_eq_gc(buf)
  emit_i32_add_gc(buf)
  // if not whitespace, break
  emit_i32_const_gc(buf, 0)
  emit_i32_eq_gc(buf)
  emit_br_if_gc(buf, 1)
  // start++
  emit_local_get_gc(buf, start_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, start_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // skip trailing whitespace: while end > start && is_ws(data[end-1])
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, end_idx)
  emit_local_get_gc(buf, start_idx)
  emit_i32_le_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, end_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_sub_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, ch_idx)
  emit_local_get_gc(buf, ch_idx)
  emit_i32_const_gc(buf, 32)
  emit_i32_eq_gc(buf)
  emit_local_get_gc(buf, ch_idx)
  emit_i32_const_gc(buf, 9)
  emit_i32_eq_gc(buf)
  emit_i32_add_gc(buf)
  emit_local_get_gc(buf, ch_idx)
  emit_i32_const_gc(buf, 10)
  emit_i32_eq_gc(buf)
  emit_i32_add_gc(buf)
  emit_local_get_gc(buf, ch_idx)
  emit_i32_const_gc(buf, 13)
  emit_i32_eq_gc(buf)
  emit_i32_add_gc(buf)
  emit_i32_const_gc(buf, 0)
  emit_i32_eq_gc(buf)
  emit_br_if_gc(buf, 1)
  // end--
  emit_local_get_gc(buf, end_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_sub_gc(buf)
  emit_local_set_gc(buf, end_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // n = end - start
  emit_local_get_gc(buf, end_idx)
  emit_local_get_gc(buf, start_idx)
  emit_i32_sub_gc(buf)
  emit_local_set_gc(buf, n_idx)
  // create new array and copy
  emit_local_get_gc(buf, n_idx)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, arr_idx)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, n_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, arr_idx)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, start_idx)
  emit_local_get_gc(buf, i_idx)
  emit_i32_add_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // create string struct
  emit_local_get_gc(buf, n_idx)
  emit_local_get_gc(buf, arr_idx)
  emit_struct_new_gc(buf, ctx.string_type)
}

///|
/// String::to_lower / String::to_upper shared codegen.
/// Maps ASCII case over the codepoint array: for each codepoint c,
///   new_c = c + delta * ((c >= lo) & (c <= hi))
/// (delta = +32 lo=65 hi=90 for to_lower; delta = -32 lo=97 hi=122 for to_upper)
fn compile_string_case_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
  lo : Int,
  hi : Int,
  delta : Int,
) -> Unit raise WasmGenError {
  let s_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let s_len = alloc_local_gc(fctx, GcValKind::I32)
  let s_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let arr_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  let ch_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_local_set_gc(buf, s_idx)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, s_len)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, s_data)
  // arr = new array(s_len)
  emit_local_get_gc(buf, s_len)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, arr_idx)
  // for i in 0..<s_len
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, s_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  // ch = s_data[i]
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, ch_idx)
  // arr[i] = ch + delta * ((ch >= lo) & (ch <= hi))
  emit_local_get_gc(buf, arr_idx)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, ch_idx)
  emit_local_get_gc(buf, ch_idx)
  emit_i32_const_gc(buf, lo)
  emit_i32_ge_s_gc(buf)
  emit_local_get_gc(buf, ch_idx)
  emit_i32_const_gc(buf, hi)
  emit_i32_le_s_gc(buf)
  emit_i32_and_gc(buf)
  emit_i32_const_gc(buf, delta)
  emit_i32_mul_gc(buf)
  emit_i32_add_gc(buf)
  emit_array_set_gc(buf, ctx.array_i32_type)
  // i++
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // struct.new(s_len, arr)
  emit_local_get_gc(buf, s_len)
  emit_local_get_gc(buf, arr_idx)
  emit_struct_new_gc(buf, ctx.string_type)
}

///|
/// Push i32 (1 if ch_local is ASCII whitespace, else 0), matching the prelude's
/// `is_ascii_whitespace` which counts exactly space/tab/LF/CR ({32,9,10,13}).
/// Used by trim_start / trim_end so they don't strip other control codepoints.
fn emit_is_ascii_whitespace_gc(buf : GcByteBuf, ch_local : Int) -> Unit {
  emit_local_get_gc(buf, ch_local)
  emit_i32_const_gc(buf, 32)
  emit_i32_eq_gc(buf)
  emit_local_get_gc(buf, ch_local)
  emit_i32_const_gc(buf, 9)
  emit_i32_eq_gc(buf)
  emit_i32_or_gc(buf)
  emit_local_get_gc(buf, ch_local)
  emit_i32_const_gc(buf, 10)
  emit_i32_eq_gc(buf)
  emit_i32_or_gc(buf)
  emit_local_get_gc(buf, ch_local)
  emit_i32_const_gc(buf, 13)
  emit_i32_eq_gc(buf)
  emit_i32_or_gc(buf)
}

///|
/// String::trim_start(str) -> string (drop leading ASCII-whitespace codepoints)
fn compile_string_trim_start_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let s_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let s_len = alloc_local_gc(fctx, GcValKind::I32)
  let s_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let start_idx = alloc_local_gc(fctx, GcValKind::I32)
  let n_idx = alloc_local_gc(fctx, GcValKind::I32)
  let arr_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  let ch_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_local_set_gc(buf, s_idx)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, s_len)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, s_data)
  // start = 0; while start < s_len && is_ascii_whitespace(data[start]): start++
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, start_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, start_idx)
  emit_local_get_gc(buf, s_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  // ch = data[start]; if !is_ascii_whitespace(ch) -> break
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, start_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, ch_idx)
  emit_is_ascii_whitespace_gc(buf, ch_idx)
  emit_i32_eqz_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, start_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, start_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // n = s_len - start
  emit_local_get_gc(buf, s_len)
  emit_local_get_gc(buf, start_idx)
  emit_i32_sub_gc(buf)
  emit_local_set_gc(buf, n_idx)
  // arr = new array(n); copy data[start..start+n]
  emit_local_get_gc(buf, n_idx)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, arr_idx)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, n_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, arr_idx)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, start_idx)
  emit_local_get_gc(buf, i_idx)
  emit_i32_add_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, n_idx)
  emit_local_get_gc(buf, arr_idx)
  emit_struct_new_gc(buf, ctx.string_type)
}

///|
/// String::trim_end(str) -> string (drop trailing codepoints <= 32)
fn compile_string_trim_end_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let s_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let s_len = alloc_local_gc(fctx, GcValKind::I32)
  let s_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let end_idx = alloc_local_gc(fctx, GcValKind::I32)
  let arr_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  let ch_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_local_set_gc(buf, s_idx)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, s_len)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, s_data)
  // end = s_len; while end > 0 && is_ascii_whitespace(data[end-1]): end--
  emit_local_get_gc(buf, s_len)
  emit_local_set_gc(buf, end_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, end_idx)
  emit_i32_const_gc(buf, 0)
  emit_i32_le_s_gc(buf)
  emit_br_if_gc(buf, 1)
  // ch = data[end-1]; if !is_ascii_whitespace(ch) -> break
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, end_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_sub_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, ch_idx)
  emit_is_ascii_whitespace_gc(buf, ch_idx)
  emit_i32_eqz_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, end_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_sub_gc(buf)
  emit_local_set_gc(buf, end_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // arr = new array(end); copy data[0..end]
  emit_local_get_gc(buf, end_idx)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, arr_idx)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, end_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, arr_idx)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, end_idx)
  emit_local_get_gc(buf, arr_idx)
  emit_struct_new_gc(buf, ctx.string_type)
}

///|
/// String::count(str, sub) -> Int (non-overlapping occurrence count)
fn compile_string_count_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
  sub_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let s_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let sub_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let s_len = alloc_local_gc(fctx, GcValKind::I32)
  let sub_len = alloc_local_gc(fctx, GcValKind::I32)
  let s_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let sub_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let count_idx = alloc_local_gc(fctx, GcValKind::I32)
  let outer_i = alloc_local_gc(fctx, GcValKind::I32)
  let inner_j = alloc_local_gc(fctx, GcValKind::I32)
  let matched = alloc_local_gc(fctx, GcValKind::I32)
  let limit = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_local_set_gc(buf, s_idx)
  compile_expr_gc(ctx, fctx, buf, sub_expr)
  emit_local_set_gc(buf, sub_idx)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, s_len)
  emit_local_get_gc(buf, sub_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, sub_len)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, s_data)
  emit_local_get_gc(buf, sub_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, sub_data)
  // count = 0
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, count_idx)
  // limit = s_len - sub_len + 1
  emit_local_get_gc(buf, s_len)
  emit_local_get_gc(buf, sub_len)
  emit_i32_sub_gc(buf)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, limit)
  // guard empty pattern: if sub_len <= 0 { limit = 0 } to avoid infinite loop
  emit_local_get_gc(buf, sub_len)
  emit_i32_const_gc(buf, 0)
  emit_i32_le_s_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, limit)
  emit_end_gc(buf)
  // outer_i = 0
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, outer_i)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, outer_i)
  emit_local_get_gc(buf, limit)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  // matched = 1; inner_j = 0
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, matched)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, inner_j)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, inner_j)
  emit_local_get_gc(buf, sub_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  // if s_data[outer_i + inner_j] != sub_data[inner_j] { matched = 0; break }
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, outer_i)
  emit_local_get_gc(buf, inner_j)
  emit_i32_add_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, sub_data)
  emit_local_get_gc(buf, inner_j)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_i32_ne_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, matched)
  emit_br_gc(buf, 2)
  emit_end_gc(buf)
  emit_local_get_gc(buf, inner_j)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, inner_j)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // if matched { count++; outer_i += sub_len } else { outer_i++ }
  emit_local_get_gc(buf, matched)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, count_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, count_idx)
  emit_local_get_gc(buf, outer_i)
  emit_local_get_gc(buf, sub_len)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, outer_i)
  emit_else_gc(buf)
  emit_local_get_gc(buf, outer_i)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, outer_i)
  emit_end_gc(buf)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // return count as i64
  emit_local_get_gc(buf, count_idx)
  emit_i64_extend_i32_s_gc(buf)
}

///|
/// String::unicode_length(str) -> Int. In the wasm-gc backend a string is a
/// codepoint array, so the codepoint count equals the stored length.
fn compile_string_unicode_length_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
) -> Unit raise WasmGenError {
  ignore(fctx)
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_i64_extend_i32_s_gc(buf)
}

///|
/// Int::parse(str) -> Option[Int]. Mirrors the linear backend state machine
/// (skip leading spaces, optional +/- sign, decimal digit loop, trailing
/// spaces) over the codepoint array, then builds Some(i64) / None using the
/// registered Option enum ctor structs. Each branch writes an eqref local so
/// the two differently-typed enum structs merge without a block result type.
fn compile_int_parse_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let s_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let s_len = alloc_local_gc(fctx, GcValKind::I32)
  let s_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let idx = alloc_local_gc(fctx, GcValKind::I32)
  // result accumulates in i64 so 62-bit Ints (e.g. Int::parse("4294967295"))
  // are not truncated to i32 before the sign-extend into the Some payload.
  let result = alloc_local_gc(fctx, GcValKind::I64)
  let neg = alloc_local_gc(fctx, GcValKind::I32)
  let ch = alloc_local_gc(fctx, GcValKind::I32)
  let valid = alloc_local_gc(fctx, GcValKind::I32)
  let has_digit = alloc_local_gc(fctx, GcValKind::I32)
  let opt_local = alloc_local_gc(fctx, GcValKind::EqRef)
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_local_set_gc(buf, s_idx)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, s_len)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, s_data)
  // init: result=0 idx=0 neg=0 valid=1 has_digit=0
  emit_i64_const_gc(buf, 0L)
  emit_local_set_gc(buf, result)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, idx)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, neg)
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, valid)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, has_digit)
  // skip leading spaces (codepoint == 32)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, idx)
  emit_local_get_gc(buf, s_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_i32_const_gc(buf, 32)
  emit_i32_ne_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // optional sign: '-' (45) or '+' (43)
  emit_block_gc(buf, None)
  emit_local_get_gc(buf, idx)
  emit_local_get_gc(buf, s_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 0)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, ch)
  emit_local_get_gc(buf, ch)
  emit_i32_const_gc(buf, 45)
  emit_i32_eq_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, neg)
  emit_local_get_gc(buf, idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, idx)
  emit_br_gc(buf, 1)
  emit_end_gc(buf)
  emit_local_get_gc(buf, ch)
  emit_i32_const_gc(buf, 43)
  emit_i32_eq_gc(buf)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, idx)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // digit loop: result = result*10 + (ch-48); trailing space ends; else invalid
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, idx)
  emit_local_get_gc(buf, s_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, ch)
  emit_local_get_gc(buf, ch)
  emit_i32_const_gc(buf, 32)
  emit_i32_eq_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, ch)
  emit_i32_const_gc(buf, 48)
  emit_i32_lt_s_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, valid)
  emit_br_gc(buf, 2)
  emit_end_gc(buf)
  emit_local_get_gc(buf, ch)
  emit_i32_const_gc(buf, 57)
  emit_i32_gt_s_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, valid)
  emit_br_gc(buf, 2)
  emit_end_gc(buf)
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, has_digit)
  // result = result*10 + (ch - 48), all in i64 to preserve 62-bit values
  emit_local_get_gc(buf, result)
  emit_i64_const_gc(buf, 10L)
  emit_i64_mul_gc(buf)
  emit_local_get_gc(buf, ch)
  emit_i32_const_gc(buf, 48)
  emit_i32_sub_gc(buf)
  emit_i64_extend_i32_s_gc(buf)
  emit_i64_add_gc(buf)
  emit_local_set_gc(buf, result)
  emit_local_get_gc(buf, idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // valid && has_digit ? Some(result) : None
  emit_local_get_gc(buf, valid)
  emit_local_get_gc(buf, has_digit)
  emit_i32_and_gc(buf)
  emit_if_gc(buf, None)
  // apply negation (in i64)
  emit_local_get_gc(buf, neg)
  emit_if_gc(buf, None)
  emit_i64_const_gc(buf, 0L)
  emit_local_get_gc(buf, result)
  emit_i64_sub_gc(buf)
  emit_local_set_gc(buf, result)
  emit_end_gc(buf)
  // Some(result): struct.new(some_type, [tag, eqref payload])
  emit_i32_const_gc(buf, ctx.enum_ctor_tags["Some"])
  emit_local_get_gc(buf, result)
  emit_coerce_top_gc(ctx, buf, GcValKind::I64, GcValKind::EqRef)
  emit_struct_new_gc(buf, ctx.enum_ctor_type_indices["Some"])
  emit_local_set_gc(buf, opt_local)
  emit_else_gc(buf)
  // None: struct.new(none_type, [tag])
  emit_i32_const_gc(buf, ctx.enum_ctor_tags["None"])
  emit_struct_new_gc(buf, ctx.enum_ctor_type_indices["None"])
  emit_local_set_gc(buf, opt_local)
  emit_end_gc(buf)
  emit_local_get_gc(buf, opt_local)
}

///|
/// Array::push_all(dst, src) -> Unit. Appends every element of src to dst.
/// Handles both wasm-gc array representations:
///   - bare array: allocate dst_len+src_len, copy both, rebind the receiver
///     local (mirrors Array::push path 1)
///   - builder struct {len, data}: grow data if needed, copy src in place,
///     bump len (mirrors compile_struct_array_push_gc)
/// src is unwrapped from either representation. Returns 0 (Unit).
fn compile_array_push_all_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  dst_expr : @core.Expr,
  src_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let dst_kind = infer_expr_kind_gc(ctx, fctx, dst_expr)
  let src_kind = infer_expr_kind_gc(ctx, fctx, src_expr)
  // Resolve the element array type from dst.
  let (dst_builder, arr_type) = match
    gc_is_array_builder_struct_kind(ctx, dst_kind) {
    Some(builder_type) => {
      let at = match ctx.types[builder_type] {
        GcTypeDef::Struct(fields~) =>
          match fields[1] {
            GcValKind::Ref(idx) => idx
            _ => raise WasmGenError::Unsupported("Array::push_all struct data")
          }
        _ => raise WasmGenError::Unsupported("Array::push_all struct kind")
      }
      (Some(builder_type), at)
    }
    None =>
      (None, gc_array_type_idx_from_kind(ctx, dst_kind, "Array::push_all"))
  }
  // Load src into (src_data : ref arr_type, src_len : i32).
  let src_data = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
  let src_len = alloc_local_gc(fctx, GcValKind::I32)
  match gc_is_array_builder_struct_kind(ctx, src_kind) {
    Some(src_builder) => {
      let src_idx = alloc_local_gc(fctx, src_kind)
      compile_expr_gc(ctx, fctx, buf, src_expr)
      emit_local_set_gc(buf, src_idx)
      emit_local_get_gc(buf, src_idx)
      emit_struct_get_gc(buf, src_builder, 1)
      emit_local_set_gc(buf, src_data)
      emit_local_get_gc(buf, src_idx)
      emit_struct_get_gc(buf, src_builder, 0)
      emit_local_set_gc(buf, src_len)
    }
    None => {
      compile_expr_gc(ctx, fctx, buf, src_expr)
      emit_local_set_gc(buf, src_data)
      emit_local_get_gc(buf, src_data)
      emit_array_len_gc(buf)
      emit_local_set_gc(buf, src_len)
    }
  }
  let j_idx = alloc_local_gc(fctx, GcValKind::I32)
  match dst_builder {
    Some(builder_type) => {
      // In-place struct append.
      let b_idx = alloc_local_gc(fctx, dst_kind)
      let len_l = alloc_local_gc(fctx, GcValKind::I32)
      let cap_l = alloc_local_gc(fctx, GcValKind::I32)
      let data_l = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
      let new_data = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
      let need_l = alloc_local_gc(fctx, GcValKind::I32)
      compile_expr_gc(ctx, fctx, buf, dst_expr)
      emit_local_set_gc(buf, b_idx)
      emit_local_get_gc(buf, b_idx)
      emit_struct_get_gc(buf, builder_type, 0)
      emit_local_set_gc(buf, len_l)
      emit_local_get_gc(buf, b_idx)
      emit_struct_get_gc(buf, builder_type, 1)
      emit_local_tee_gc(buf, data_l)
      emit_array_len_gc(buf)
      emit_local_set_gc(buf, cap_l)
      // need = len + src_len
      emit_local_get_gc(buf, len_l)
      emit_local_get_gc(buf, src_len)
      emit_i32_add_gc(buf)
      emit_local_set_gc(buf, need_l)
      // if need > cap: grow to need, copy old, rebind struct.data
      emit_local_get_gc(buf, need_l)
      emit_local_get_gc(buf, cap_l)
      emit_i32_gt_s_gc(buf)
      emit_if_gc(buf, None)
      emit_local_get_gc(buf, need_l)
      emit_array_new_default_gc(buf, arr_type)
      emit_local_set_gc(buf, new_data)
      emit_local_get_gc(buf, new_data)
      emit_i32_const_gc(buf, 0)
      emit_local_get_gc(buf, data_l)
      emit_i32_const_gc(buf, 0)
      emit_local_get_gc(buf, len_l)
      emit_array_copy_gc(buf, arr_type)
      emit_local_get_gc(buf, b_idx)
      emit_local_get_gc(buf, new_data)
      emit_struct_set_gc(buf, builder_type, 1)
      emit_local_get_gc(buf, new_data)
      emit_local_set_gc(buf, data_l)
      emit_end_gc(buf)
      // copy loop: data[len + j] = src_data[j]
      emit_i32_const_gc(buf, 0)
      emit_local_set_gc(buf, j_idx)
      emit_block_gc(buf, None)
      emit_loop_gc(buf, None)
      emit_local_get_gc(buf, j_idx)
      emit_local_get_gc(buf, src_len)
      emit_i32_ge_s_gc(buf)
      emit_br_if_gc(buf, 1)
      emit_local_get_gc(buf, data_l)
      emit_local_get_gc(buf, len_l)
      emit_local_get_gc(buf, j_idx)
      emit_i32_add_gc(buf)
      emit_local_get_gc(buf, src_data)
      emit_local_get_gc(buf, j_idx)
      emit_array_get_gc(buf, arr_type)
      emit_array_set_gc(buf, arr_type)
      emit_local_get_gc(buf, j_idx)
      emit_i32_const_gc(buf, 1)
      emit_i32_add_gc(buf)
      emit_local_set_gc(buf, j_idx)
      emit_br_gc(buf, 0)
      emit_end_gc(buf)
      emit_end_gc(buf)
      // struct.len = need
      emit_local_get_gc(buf, b_idx)
      emit_local_get_gc(buf, need_l)
      emit_struct_set_gc(buf, builder_type, 0)
      emit_i32_const_gc(buf, 0)
    }
    None => {
      // Bare array: realloc to dst_len + src_len, copy both, rebind local.
      let dst_arr = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
      let dst_len = alloc_local_gc(fctx, GcValKind::I32)
      let out_arr = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
      compile_expr_gc(ctx, fctx, buf, dst_expr)
      emit_local_set_gc(buf, dst_arr)
      emit_local_get_gc(buf, dst_arr)
      emit_array_len_gc(buf)
      emit_local_set_gc(buf, dst_len)
      // out = array(dst_len + src_len)
      emit_local_get_gc(buf, dst_len)
      emit_local_get_gc(buf, src_len)
      emit_i32_add_gc(buf)
      emit_array_new_default_gc(buf, arr_type)
      emit_local_set_gc(buf, out_arr)
      // copy dst[0..dst_len]
      emit_local_get_gc(buf, out_arr)
      emit_i32_const_gc(buf, 0)
      emit_local_get_gc(buf, dst_arr)
      emit_i32_const_gc(buf, 0)
      emit_local_get_gc(buf, dst_len)
      emit_array_copy_gc(buf, arr_type)
      // copy src[0..src_len] at offset dst_len
      emit_local_get_gc(buf, out_arr)
      emit_local_get_gc(buf, dst_len)
      emit_local_get_gc(buf, src_data)
      emit_i32_const_gc(buf, 0)
      emit_local_get_gc(buf, src_len)
      emit_array_copy_gc(buf, arr_type)
      // rebind receiver local if it is an Ident
      match dst_expr {
        @core.Expr::Ident(name~, ..) =>
          match fctx.locals.get(name) {
            Some(info) => {
              emit_local_get_gc(buf, out_arr)
              emit_local_set_gc(buf, info.idx)
            }
            None => ()
          }
        _ => ()
      }
      emit_i32_const_gc(buf, 0)
    }
  }
}

///|
/// Bytes::from_string(str) -> Bytes. UTF-8 encodes each codepoint of the
/// wasm-gc string (codepoint array) into a byte array (one byte per element).
/// Over-allocates 4 bytes/codepoint, then records the actual byte length.
fn compile_bytes_from_string_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let at = ctx.array_i32_type
  let s_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let s_len = alloc_local_gc(fctx, GcValKind::I32)
  let s_data = alloc_local_gc(fctx, GcValKind::Ref(at))
  let maxb = alloc_local_gc(fctx, GcValKind::I32)
  let out = alloc_local_gc(fctx, GcValKind::Ref(at))
  let i = alloc_local_gc(fctx, GcValKind::I32)
  let w = alloc_local_gc(fctx, GcValKind::I32)
  let c = alloc_local_gc(fctx, GcValKind::I32)
  // store_cont(shift): out[w] = 0x80 | ((c >> shift) & 0x3F); w++
  let store_cont = fn(shift : Int) -> Unit {
    emit_local_get_gc(buf, out)
    emit_local_get_gc(buf, w)
    emit_i32_const_gc(buf, 0x80)
    emit_local_get_gc(buf, c)
    emit_i32_const_gc(buf, shift)
    emit_i32_shr_u_gc(buf)
    emit_i32_const_gc(buf, 0x3F)
    emit_i32_and_gc(buf)
    emit_i32_or_gc(buf)
    emit_array_set_gc(buf, at)
    emit_local_get_gc(buf, w)
    emit_i32_const_gc(buf, 1)
    emit_i32_add_gc(buf)
    emit_local_set_gc(buf, w)
  }
  // store_lead(prefix, shift): out[w] = prefix | (c >> shift); w++
  let store_lead = fn(prefix : Int, shift : Int) -> Unit {
    emit_local_get_gc(buf, out)
    emit_local_get_gc(buf, w)
    emit_i32_const_gc(buf, prefix)
    emit_local_get_gc(buf, c)
    emit_i32_const_gc(buf, shift)
    emit_i32_shr_u_gc(buf)
    emit_i32_or_gc(buf)
    emit_array_set_gc(buf, at)
    emit_local_get_gc(buf, w)
    emit_i32_const_gc(buf, 1)
    emit_i32_add_gc(buf)
    emit_local_set_gc(buf, w)
  }
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_local_set_gc(buf, s_idx)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, s_len)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, s_data)
  emit_local_get_gc(buf, s_len)
  emit_i32_const_gc(buf, 4)
  emit_i32_mul_gc(buf)
  emit_local_set_gc(buf, maxb)
  emit_local_get_gc(buf, maxb)
  emit_array_new_default_gc(buf, at)
  emit_local_set_gc(buf, out)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, w)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i)
  emit_local_get_gc(buf, s_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, i)
  emit_array_get_gc(buf, at)
  emit_local_set_gc(buf, c)
  // if c < 0x80 (1 byte)
  emit_local_get_gc(buf, c)
  emit_i32_const_gc(buf, 0x80)
  emit_i32_lt_s_gc(buf)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, out)
  emit_local_get_gc(buf, w)
  emit_local_get_gc(buf, c)
  emit_array_set_gc(buf, at)
  emit_local_get_gc(buf, w)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, w)
  emit_else_gc(buf)
  // if c < 0x800 (2 bytes)
  emit_local_get_gc(buf, c)
  emit_i32_const_gc(buf, 0x800)
  emit_i32_lt_s_gc(buf)
  emit_if_gc(buf, None)
  store_lead(0xC0, 6)
  store_cont(0)
  emit_else_gc(buf)
  // if c < 0x10000 (3 bytes)
  emit_local_get_gc(buf, c)
  emit_i32_const_gc(buf, 0x10000)
  emit_i32_lt_s_gc(buf)
  emit_if_gc(buf, None)
  store_lead(0xE0, 12)
  store_cont(6)
  store_cont(0)
  emit_else_gc(buf)
  // 4 bytes
  store_lead(0xF0, 18)
  store_cont(12)
  store_cont(6)
  store_cont(0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // i++
  emit_local_get_gc(buf, i)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // struct.new bytes_type [len=w, cap=maxb, data=out]
  emit_local_get_gc(buf, w)
  emit_local_get_gc(buf, maxb)
  emit_local_get_gc(buf, out)
  emit_struct_new_gc(buf, ctx.bytes_type)
}

///|
/// Bytes::to_string(bytes) -> String. UTF-8 decodes the byte array into a
/// codepoint array. Assumes well-formed UTF-8 (linear backend likewise does
/// not validate). Over-allocates byte-count codepoints, records actual count.
fn compile_bytes_to_string_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  b_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let at = ctx.array_i32_type
  let b_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.bytes_type))
  let b_len = alloc_local_gc(fctx, GcValKind::I32)
  let b_data = alloc_local_gc(fctx, GcValKind::Ref(at))
  let out = alloc_local_gc(fctx, GcValKind::Ref(at))
  let i = alloc_local_gc(fctx, GcValKind::I32)
  let w = alloc_local_gc(fctx, GcValKind::I32)
  let b0 = alloc_local_gc(fctx, GcValKind::I32)
  let cp = alloc_local_gc(fctx, GcValKind::I32)
  // push (b_data[i + off] & 0x3F) onto the stack
  let cont_masked = fn(off : Int) -> Unit {
    emit_local_get_gc(buf, b_data)
    emit_local_get_gc(buf, i)
    emit_i32_const_gc(buf, off)
    emit_i32_add_gc(buf)
    emit_array_get_gc(buf, at)
    emit_i32_const_gc(buf, 0x3F)
    emit_i32_and_gc(buf)
  }
  compile_expr_gc(ctx, fctx, buf, b_expr)
  emit_local_set_gc(buf, b_idx)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 0)
  emit_local_set_gc(buf, b_len)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 2)
  emit_local_set_gc(buf, b_data)
  emit_local_get_gc(buf, b_len)
  emit_array_new_default_gc(buf, at)
  emit_local_set_gc(buf, out)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, w)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i)
  emit_local_get_gc(buf, b_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, b_data)
  emit_local_get_gc(buf, i)
  emit_array_get_gc(buf, at)
  emit_local_set_gc(buf, b0)
  // if b0 < 0x80 (1 byte)
  emit_local_get_gc(buf, b0)
  emit_i32_const_gc(buf, 0x80)
  emit_i32_lt_s_gc(buf)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, b0)
  emit_local_set_gc(buf, cp)
  emit_local_get_gc(buf, i)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i)
  emit_else_gc(buf)
  // if b0 < 0xE0 (2 bytes)
  emit_local_get_gc(buf, b0)
  emit_i32_const_gc(buf, 0xE0)
  emit_i32_lt_s_gc(buf)
  emit_if_gc(buf, None)
  // cp = ((b0 & 0x1F) << 6) | (b_data[i+1] & 0x3F)
  emit_local_get_gc(buf, b0)
  emit_i32_const_gc(buf, 0x1F)
  emit_i32_and_gc(buf)
  emit_i32_const_gc(buf, 6)
  emit_i32_shl_gc(buf)
  cont_masked(1)
  emit_i32_or_gc(buf)
  emit_local_set_gc(buf, cp)
  emit_local_get_gc(buf, i)
  emit_i32_const_gc(buf, 2)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i)
  emit_else_gc(buf)
  // if b0 < 0xF0 (3 bytes)
  emit_local_get_gc(buf, b0)
  emit_i32_const_gc(buf, 0xF0)
  emit_i32_lt_s_gc(buf)
  emit_if_gc(buf, None)
  // cp = ((b0 & 0x0F) << 12) | ((b_data[i+1] & 0x3F) << 6) | (b_data[i+2] & 0x3F)
  emit_local_get_gc(buf, b0)
  emit_i32_const_gc(buf, 0x0F)
  emit_i32_and_gc(buf)
  emit_i32_const_gc(buf, 12)
  emit_i32_shl_gc(buf)
  cont_masked(1)
  emit_i32_const_gc(buf, 6)
  emit_i32_shl_gc(buf)
  emit_i32_or_gc(buf)
  cont_masked(2)
  emit_i32_or_gc(buf)
  emit_local_set_gc(buf, cp)
  emit_local_get_gc(buf, i)
  emit_i32_const_gc(buf, 3)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i)
  emit_else_gc(buf)
  // 4 bytes: cp = ((b0 & 0x07) << 18) | ((i+1)<<12) | ((i+2)<<6) | (i+3)
  emit_local_get_gc(buf, b0)
  emit_i32_const_gc(buf, 0x07)
  emit_i32_and_gc(buf)
  emit_i32_const_gc(buf, 18)
  emit_i32_shl_gc(buf)
  cont_masked(1)
  emit_i32_const_gc(buf, 12)
  emit_i32_shl_gc(buf)
  emit_i32_or_gc(buf)
  cont_masked(2)
  emit_i32_const_gc(buf, 6)
  emit_i32_shl_gc(buf)
  emit_i32_or_gc(buf)
  cont_masked(3)
  emit_i32_or_gc(buf)
  emit_local_set_gc(buf, cp)
  emit_local_get_gc(buf, i)
  emit_i32_const_gc(buf, 4)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // out[w] = cp; w++
  emit_local_get_gc(buf, out)
  emit_local_get_gc(buf, w)
  emit_local_get_gc(buf, cp)
  emit_array_set_gc(buf, at)
  emit_local_get_gc(buf, w)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, w)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // struct.new string_type [len=w, data=out]
  emit_local_get_gc(buf, w)
  emit_local_get_gc(buf, out)
  emit_struct_new_gc(buf, ctx.string_type)
}

///|
/// String::replace(str, old, new) -> string (first occurrence)
fn compile_string_replace(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
  old_expr : @core.Expr,
  new_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let s_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let old_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let new_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let s_len = alloc_local_gc(fctx, GcValKind::I32)
  let old_len = alloc_local_gc(fctx, GcValKind::I32)
  let new_len = alloc_local_gc(fctx, GcValKind::I32)
  let s_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let old_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let new_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let found_pos = alloc_local_gc(fctx, GcValKind::I32)
  let outer_i = alloc_local_gc(fctx, GcValKind::I32)
  let inner_j = alloc_local_gc(fctx, GcValKind::I32)
  let matched = alloc_local_gc(fctx, GcValKind::I32)
  let limit = alloc_local_gc(fctx, GcValKind::I32)
  let result_len = alloc_local_gc(fctx, GcValKind::I32)
  let arr_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let w_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_local_set_gc(buf, s_idx)
  compile_expr_gc(ctx, fctx, buf, old_expr)
  emit_local_set_gc(buf, old_idx)
  compile_expr_gc(ctx, fctx, buf, new_expr)
  emit_local_set_gc(buf, new_idx)
  // extract fields
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, s_len)
  emit_local_get_gc(buf, old_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, old_len)
  emit_local_get_gc(buf, new_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, new_len)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, s_data)
  emit_local_get_gc(buf, old_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, old_data)
  emit_local_get_gc(buf, new_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, new_data)
  // find first occurrence: found_pos = -1
  emit_i32_const_gc(buf, -1)
  emit_local_set_gc(buf, found_pos)
  emit_local_get_gc(buf, s_len)
  emit_local_get_gc(buf, old_len)
  emit_i32_sub_gc(buf)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, limit)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, outer_i)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, outer_i)
  emit_local_get_gc(buf, limit)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, matched)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, inner_j)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, inner_j)
  emit_local_get_gc(buf, old_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, outer_i)
  emit_local_get_gc(buf, inner_j)
  emit_i32_add_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, old_data)
  emit_local_get_gc(buf, inner_j)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_i32_ne_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, matched)
  emit_br_gc(buf, 2)
  emit_end_gc(buf)
  emit_local_get_gc(buf, inner_j)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, inner_j)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, matched)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, outer_i)
  emit_local_set_gc(buf, found_pos)
  emit_br_gc(buf, 2)
  emit_end_gc(buf)
  emit_local_get_gc(buf, outer_i)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, outer_i)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // if found_pos == -1, return original string
  emit_local_get_gc(buf, found_pos)
  emit_i32_const_gc(buf, -1)
  emit_i32_eq_gc(buf)
  emit_if_gc(buf, Some(GcValKind::Ref(ctx.string_type)))
  emit_local_get_gc(buf, s_idx)
  emit_else_gc(buf)
  // result_len = s_len - old_len + new_len
  emit_local_get_gc(buf, s_len)
  emit_local_get_gc(buf, old_len)
  emit_i32_sub_gc(buf)
  emit_local_get_gc(buf, new_len)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, result_len)
  emit_local_get_gc(buf, result_len)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, arr_idx)
  // copy prefix: s[0..found_pos]
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, w_idx)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, outer_i) // reuse as copy idx
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, outer_i)
  emit_local_get_gc(buf, found_pos)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, arr_idx)
  emit_local_get_gc(buf, w_idx)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, outer_i)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, w_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, w_idx)
  emit_local_get_gc(buf, outer_i)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, outer_i)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // copy replacement
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, outer_i)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, outer_i)
  emit_local_get_gc(buf, new_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, arr_idx)
  emit_local_get_gc(buf, w_idx)
  emit_local_get_gc(buf, new_data)
  emit_local_get_gc(buf, outer_i)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, w_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, w_idx)
  emit_local_get_gc(buf, outer_i)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, outer_i)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // copy suffix: s[found_pos + old_len ..]
  emit_local_get_gc(buf, found_pos)
  emit_local_get_gc(buf, old_len)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, outer_i)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, outer_i)
  emit_local_get_gc(buf, s_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, arr_idx)
  emit_local_get_gc(buf, w_idx)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, outer_i)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, w_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, w_idx)
  emit_local_get_gc(buf, outer_i)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, outer_i)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // make string
  emit_local_get_gc(buf, result_len)
  emit_local_get_gc(buf, arr_idx)
  emit_struct_new_gc(buf, ctx.string_type)
  emit_end_gc(buf) // end if/else
}

///|
/// String::split(str, delimiter) -> array of strings
fn compile_string_split(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  s_expr : @core.Expr,
  delim_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let str_arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::Ref(ctx.string_type),
  )
  let s_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let delim_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let s_len = alloc_local_gc(fctx, GcValKind::I32)
  let delim_len = alloc_local_gc(fctx, GcValKind::I32)
  let s_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let delim_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let count = alloc_local_gc(fctx, GcValKind::I32)
  let pos = alloc_local_gc(fctx, GcValKind::I32)
  let inner_j = alloc_local_gc(fctx, GcValKind::I32)
  let matched = alloc_local_gc(fctx, GcValKind::I32)
  let result_arr = alloc_local_gc(fctx, GcValKind::Ref(str_arr_type))
  let write_idx = alloc_local_gc(fctx, GcValKind::I32)
  let seg_start = alloc_local_gc(fctx, GcValKind::I32)
  let seg_len = alloc_local_gc(fctx, GcValKind::I32)
  let seg_arr = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let k_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, s_expr)
  emit_local_set_gc(buf, s_idx)
  compile_expr_gc(ctx, fctx, buf, delim_expr)
  emit_local_set_gc(buf, delim_idx)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, s_len)
  emit_local_get_gc(buf, delim_idx)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, delim_len)
  emit_local_get_gc(buf, s_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, s_data)
  emit_local_get_gc(buf, delim_idx)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, delim_data)
  // Pass 1: count number of segments
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, count)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, pos)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  // if pos > s_len - delim_len, break
  emit_local_get_gc(buf, pos)
  emit_local_get_gc(buf, s_len)
  emit_local_get_gc(buf, delim_len)
  emit_i32_sub_gc(buf)
  emit_i32_gt_s_gc(buf)
  emit_br_if_gc(buf, 1)
  // check if delimiter matches at pos
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, matched)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, inner_j)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, inner_j)
  emit_local_get_gc(buf, delim_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, pos)
  emit_local_get_gc(buf, inner_j)
  emit_i32_add_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, delim_data)
  emit_local_get_gc(buf, inner_j)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_i32_ne_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, matched)
  emit_br_gc(buf, 2)
  emit_end_gc(buf)
  emit_local_get_gc(buf, inner_j)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, inner_j)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, matched)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, count)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, count)
  emit_local_get_gc(buf, pos)
  emit_local_get_gc(buf, delim_len)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, pos)
  emit_else_gc(buf)
  emit_local_get_gc(buf, pos)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, pos)
  emit_end_gc(buf)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // Pass 2: allocate result array and fill segments
  emit_local_get_gc(buf, count)
  emit_array_new_default_gc(buf, str_arr_type)
  emit_local_set_gc(buf, result_arr)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, write_idx)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, seg_start)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, pos)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  // if pos > s_len - delim_len, break
  emit_local_get_gc(buf, pos)
  emit_local_get_gc(buf, s_len)
  emit_local_get_gc(buf, delim_len)
  emit_i32_sub_gc(buf)
  emit_i32_gt_s_gc(buf)
  emit_br_if_gc(buf, 1)
  // check delimiter match
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, matched)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, inner_j)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, inner_j)
  emit_local_get_gc(buf, delim_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, pos)
  emit_local_get_gc(buf, inner_j)
  emit_i32_add_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, delim_data)
  emit_local_get_gc(buf, inner_j)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_i32_ne_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, matched)
  emit_br_gc(buf, 2)
  emit_end_gc(buf)
  emit_local_get_gc(buf, inner_j)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, inner_j)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, matched)
  emit_if_gc(buf, None)
  // found delimiter: create segment from seg_start..pos
  emit_local_get_gc(buf, pos)
  emit_local_get_gc(buf, seg_start)
  emit_i32_sub_gc(buf)
  emit_local_set_gc(buf, seg_len)
  emit_local_get_gc(buf, seg_len)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, seg_arr)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, k_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, k_idx)
  emit_local_get_gc(buf, seg_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, seg_arr)
  emit_local_get_gc(buf, k_idx)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, seg_start)
  emit_local_get_gc(buf, k_idx)
  emit_i32_add_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, k_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, k_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // store segment in result array
  emit_local_get_gc(buf, result_arr)
  emit_local_get_gc(buf, write_idx)
  emit_local_get_gc(buf, seg_len)
  emit_local_get_gc(buf, seg_arr)
  emit_struct_new_gc(buf, ctx.string_type)
  emit_array_set_gc(buf, str_arr_type)
  emit_local_get_gc(buf, write_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, write_idx)
  // advance pos past delimiter
  emit_local_get_gc(buf, pos)
  emit_local_get_gc(buf, delim_len)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, pos)
  emit_local_get_gc(buf, pos)
  emit_local_set_gc(buf, seg_start)
  emit_else_gc(buf)
  emit_local_get_gc(buf, pos)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, pos)
  emit_end_gc(buf)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // last segment: seg_start..s_len
  emit_local_get_gc(buf, s_len)
  emit_local_get_gc(buf, seg_start)
  emit_i32_sub_gc(buf)
  emit_local_set_gc(buf, seg_len)
  emit_local_get_gc(buf, seg_len)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, seg_arr)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, k_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, k_idx)
  emit_local_get_gc(buf, seg_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, seg_arr)
  emit_local_get_gc(buf, k_idx)
  emit_local_get_gc(buf, s_data)
  emit_local_get_gc(buf, seg_start)
  emit_local_get_gc(buf, k_idx)
  emit_i32_add_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, k_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, k_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, result_arr)
  emit_local_get_gc(buf, write_idx)
  emit_local_get_gc(buf, seg_len)
  emit_local_get_gc(buf, seg_arr)
  emit_struct_new_gc(buf, ctx.string_type)
  emit_array_set_gc(buf, str_arr_type)
  // leave result_arr on stack
  emit_local_get_gc(buf, result_arr)
}

///|
/// String::join(arr, separator) -> string
fn compile_string_join(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  arr_expr : @core.Expr,
  sep_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let str_arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::Ref(ctx.string_type),
  )
  let arr_local = alloc_local_gc(fctx, GcValKind::Ref(str_arr_type))
  let sep_local = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let sep_len = alloc_local_gc(fctx, GcValKind::I32)
  let sep_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let arr_len = alloc_local_gc(fctx, GcValKind::I32)
  let total_len = alloc_local_gc(fctx, GcValKind::I32)
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  let elem_local = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let elem_len = alloc_local_gc(fctx, GcValKind::I32)
  let elem_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let result_arr = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let w_idx = alloc_local_gc(fctx, GcValKind::I32)
  let j_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, arr_expr)
  emit_local_set_gc(buf, arr_local)
  compile_expr_gc(ctx, fctx, buf, sep_expr)
  emit_local_set_gc(buf, sep_local)
  emit_local_get_gc(buf, sep_local)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, sep_len)
  emit_local_get_gc(buf, sep_local)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, sep_data)
  emit_local_get_gc(buf, arr_local)
  emit_array_len_gc(buf)
  emit_local_set_gc(buf, arr_len)
  // Pass 1: compute total length = sum of element lengths + (arr_len - 1) * sep_len
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, total_len)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, arr_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, arr_local)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, str_arr_type)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_get_gc(buf, total_len)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, total_len)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // add separator lengths: (arr_len - 1) * sep_len (only if arr_len > 1)
  emit_local_get_gc(buf, arr_len)
  emit_i32_const_gc(buf, 1)
  emit_i32_gt_s_gc(buf)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, total_len)
  emit_local_get_gc(buf, arr_len)
  emit_i32_const_gc(buf, 1)
  emit_i32_sub_gc(buf)
  emit_local_get_gc(buf, sep_len)
  emit_i32_mul_gc(buf)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, total_len)
  emit_end_gc(buf)
  // Pass 2: allocate and fill result
  emit_local_get_gc(buf, total_len)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, result_arr)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, w_idx)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, arr_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  // if i > 0, copy separator
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 0)
  emit_i32_gt_s_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, j_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, j_idx)
  emit_local_get_gc(buf, sep_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, result_arr)
  emit_local_get_gc(buf, w_idx)
  emit_local_get_gc(buf, sep_data)
  emit_local_get_gc(buf, j_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, w_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, w_idx)
  emit_local_get_gc(buf, j_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, j_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_end_gc(buf) // end if (i > 0)
  // copy element chars
  emit_local_get_gc(buf, arr_local)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, str_arr_type)
  emit_local_set_gc(buf, elem_local)
  emit_local_get_gc(buf, elem_local)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, elem_len)
  emit_local_get_gc(buf, elem_local)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, elem_data)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, j_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, j_idx)
  emit_local_get_gc(buf, elem_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, result_arr)
  emit_local_get_gc(buf, w_idx)
  emit_local_get_gc(buf, elem_data)
  emit_local_get_gc(buf, j_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, w_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, w_idx)
  emit_local_get_gc(buf, j_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, j_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // i++
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // create string struct
  emit_local_get_gc(buf, total_len)
  emit_local_get_gc(buf, result_arr)
  emit_struct_new_gc(buf, ctx.string_type)
}

///|
// --- Bytes struct helpers (len: i32, cap: i32, data: ref array<i32>) ---
// field 0 = len, field 1 = cap, field 2 = data

///|
/// Int64Array::make(len, default) -> struct{len, data: array<i64>}.
/// i64 cells store Int values without truncation (#429).
fn compile_int64array_make_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  len_expr : @core.Expr,
  default_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::I64,
  )
  let len_idx = alloc_local_gc(fctx, GcValKind::I32)
  let data_idx = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
  // len = wrap(len_expr)
  let lk = infer_expr_kind_gc(ctx, fctx, len_expr)
  compile_expr_gc(ctx, fctx, buf, len_expr)
  if lk == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_local_set_gc(buf, len_idx)
  // data = array.new(default, len): push init value then length
  let dk = infer_expr_kind_gc(ctx, fctx, default_expr)
  compile_expr_gc(ctx, fctx, buf, default_expr)
  emit_coerce_top_gc(ctx, buf, dk, GcValKind::I64)
  emit_local_get_gc(buf, len_idx)
  emit_array_new_gc(buf, arr_type)
  emit_local_set_gc(buf, data_idx)
  // struct.new(int64array_type, [len, data])
  emit_local_get_gc(buf, len_idx)
  emit_local_get_gc(buf, data_idx)
  emit_struct_new_gc(buf, ctx.int64array_type)
}

///|
fn compile_int64array_length_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  a_expr : @core.Expr,
) -> Unit raise WasmGenError {
  compile_expr_gc(ctx, fctx, buf, a_expr)
  emit_struct_get_gc(buf, ctx.int64array_type, 0)
  emit_i64_extend_i32_s_gc(buf)
}

///|
fn compile_int64array_get_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  a_expr : @core.Expr,
  idx_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::I64,
  )
  compile_expr_gc(ctx, fctx, buf, a_expr)
  emit_struct_get_gc(buf, ctx.int64array_type, 1)
  let ik = infer_expr_kind_gc(ctx, fctx, idx_expr)
  compile_expr_gc(ctx, fctx, buf, idx_expr)
  if ik == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_array_get_gc(buf, arr_type)
}

///|
fn compile_int64array_set_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  a_expr : @core.Expr,
  idx_expr : @core.Expr,
  val_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::I64,
  )
  compile_expr_gc(ctx, fctx, buf, a_expr)
  emit_struct_get_gc(buf, ctx.int64array_type, 1)
  let ik = infer_expr_kind_gc(ctx, fctx, idx_expr)
  compile_expr_gc(ctx, fctx, buf, idx_expr)
  if ik == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  let vk = infer_expr_kind_gc(ctx, fctx, val_expr)
  compile_expr_gc(ctx, fctx, buf, val_expr)
  emit_coerce_top_gc(ctx, buf, vk, GcValKind::I64)
  emit_array_set_gc(buf, arr_type)
  emit_i32_const_gc(buf, 0)
}

///|
fn compile_bytes_new_gc(ctx : GcCodegenCtx, buf : GcByteBuf) -> Unit {
  let init_cap = 64
  // len = 0
  emit_i32_const_gc(buf, 0)
  // cap = init_cap
  emit_i32_const_gc(buf, init_cap)
  // data = array.new_default(init_cap)
  emit_i32_const_gc(buf, init_cap)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  // struct.new bytes_type
  emit_struct_new_gc(buf, ctx.bytes_type)
}

///|
fn compile_bytes_length_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  bytes_expr : @core.Expr,
) -> Unit raise WasmGenError {
  compile_expr_gc(ctx, fctx, buf, bytes_expr)
  emit_struct_get_gc(buf, ctx.bytes_type, 0) // len
  emit_i64_extend_i32_s_gc(buf)
}

///|
fn compile_bytes_from_array_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  arr_expr : @core.Expr,
) -> Unit raise WasmGenError {
  // arr_expr may be array<i64> (Int = i64); convert to array<i32> for bytes data
  let src_kind = infer_expr_kind_gc(ctx, fctx, arr_expr)
  let src_type_idx = match src_kind {
    GcValKind::Ref(idx) => idx
    _ => raise WasmGenError::Unsupported("Bytes::from_array kind")
  }
  let src_idx = alloc_local_gc(fctx, src_kind)
  let len_idx = alloc_local_gc(fctx, GcValKind::I32)
  let dst_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, arr_expr)
  emit_local_set_gc(buf, src_idx)
  emit_local_get_gc(buf, src_idx)
  emit_array_len_gc(buf)
  emit_local_set_gc(buf, len_idx)
  // Create new array<i32>
  emit_local_get_gc(buf, len_idx)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, dst_idx)
  // Copy loop with i64→i32 truncation
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, len_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, dst_idx)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, src_idx)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, src_type_idx)
  // Truncate i64 to i32 if source is i64
  let elem_kind = match ctx.types[src_type_idx] {
    GcTypeDef::Array(elem~) => elem
    _ => GcValKind::I32
  }
  if elem_kind == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // Wrap: len, cap=len, data
  emit_local_get_gc(buf, len_idx)
  emit_local_get_gc(buf, len_idx)
  emit_local_get_gc(buf, dst_idx)
  emit_struct_new_gc(buf, ctx.bytes_type)
}

///|
fn compile_bytes_get_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  bytes_expr : @core.Expr,
  idx_expr : @core.Expr,
) -> Unit raise WasmGenError {
  compile_expr_gc(ctx, fctx, buf, bytes_expr)
  emit_struct_get_gc(buf, ctx.bytes_type, 2) // data
  compile_expr_gc(ctx, fctx, buf, idx_expr)
  let idx_kind = infer_expr_kind_gc(ctx, fctx, idx_expr)
  if idx_kind == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_i64_extend_i32_s_gc(buf)
}

///|
fn compile_bytes_set_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  bytes_expr : @core.Expr,
  idx_expr : @core.Expr,
  val_expr : @core.Expr,
) -> Unit raise WasmGenError {
  compile_expr_gc(ctx, fctx, buf, bytes_expr)
  emit_struct_get_gc(buf, ctx.bytes_type, 2) // data
  compile_expr_gc(ctx, fctx, buf, idx_expr)
  let idx_kind = infer_expr_kind_gc(ctx, fctx, idx_expr)
  if idx_kind == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  compile_expr_gc(ctx, fctx, buf, val_expr)
  let val_kind = infer_expr_kind_gc(ctx, fctx, val_expr)
  if val_kind == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_i32_const_gc(buf, 0) // Unit
}

///|
/// Emit: if len >= cap { grow }
/// Leaves bytes struct local unchanged; mutates struct fields in-place.
fn emit_bytes_ensure_cap_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  b_idx : Int,
  additional : Int,
) -> Unit {
  let len_idx = alloc_local_gc(fctx, GcValKind::I32)
  let cap_idx = alloc_local_gc(fctx, GcValKind::I32)
  let new_cap_idx = alloc_local_gc(fctx, GcValKind::I32)
  let new_data_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let old_data_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let copy_i = alloc_local_gc(fctx, GcValKind::I32)
  // Load len, cap
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 0)
  emit_local_set_gc(buf, len_idx)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 1)
  emit_local_set_gc(buf, cap_idx)
  // if len + additional > cap
  emit_local_get_gc(buf, len_idx)
  emit_i32_const_gc(buf, additional)
  emit_i32_add_gc(buf)
  emit_local_get_gc(buf, cap_idx)
  emit_i32_gt_s_gc(buf)
  emit_if_gc(buf, None)
  // new_cap = max(cap * 2, len + additional)
  emit_local_get_gc(buf, cap_idx)
  emit_i32_const_gc(buf, 2)
  emit_i32_mul_gc(buf)
  emit_local_set_gc(buf, new_cap_idx)
  emit_local_get_gc(buf, len_idx)
  emit_i32_const_gc(buf, additional)
  emit_i32_add_gc(buf)
  emit_local_get_gc(buf, new_cap_idx)
  emit_i32_gt_s_gc(buf)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, len_idx)
  emit_i32_const_gc(buf, additional)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, new_cap_idx)
  emit_end_gc(buf)
  // new_data = array.new_default(new_cap)
  emit_local_get_gc(buf, new_cap_idx)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, new_data_idx)
  // Copy old data to new data
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 2)
  emit_local_set_gc(buf, old_data_idx)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, copy_i)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, copy_i)
  emit_local_get_gc(buf, len_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, new_data_idx)
  emit_local_get_gc(buf, copy_i)
  emit_local_get_gc(buf, old_data_idx)
  emit_local_get_gc(buf, copy_i)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, copy_i)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, copy_i)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // Update struct: cap, data
  emit_local_get_gc(buf, b_idx)
  emit_local_get_gc(buf, new_cap_idx)
  emit_struct_set_gc(buf, ctx.bytes_type, 1)
  emit_local_get_gc(buf, b_idx)
  emit_local_get_gc(buf, new_data_idx)
  emit_struct_set_gc(buf, ctx.bytes_type, 2)
  emit_end_gc(buf) // end if
}

///|
fn compile_bytes_push_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  bytes_expr : @core.Expr,
  val_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let b_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.bytes_type))
  let len_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, bytes_expr)
  emit_local_set_gc(buf, b_idx)
  emit_bytes_ensure_cap_gc(ctx, fctx, buf, b_idx, 1)
  // data[len] = val
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 0)
  emit_local_set_gc(buf, len_idx)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 2)
  emit_local_get_gc(buf, len_idx)
  compile_expr_gc(ctx, fctx, buf, val_expr)
  let val_kind = infer_expr_kind_gc(ctx, fctx, val_expr)
  if val_kind == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_array_set_gc(buf, ctx.array_i32_type)
  // len += 1
  emit_local_get_gc(buf, b_idx)
  emit_local_get_gc(buf, len_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_struct_set_gc(buf, ctx.bytes_type, 0)
  emit_i32_const_gc(buf, 0) // Unit
}

///|
fn compile_bytes_append_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  dst_expr : @core.Expr,
  src_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let dst_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.bytes_type))
  let src_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.bytes_type))
  let src_len = alloc_local_gc(fctx, GcValKind::I32)
  let dst_len = alloc_local_gc(fctx, GcValKind::I32)
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  let src_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let dst_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  compile_expr_gc(ctx, fctx, buf, dst_expr)
  emit_local_set_gc(buf, dst_idx)
  compile_expr_gc(ctx, fctx, buf, src_expr)
  emit_local_set_gc(buf, src_idx)
  emit_local_get_gc(buf, src_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 0)
  emit_local_set_gc(buf, src_len)
  // ensure_cap(dst, src_len) - inline the check
  emit_bytes_ensure_cap_gc(ctx, fctx, buf, dst_idx, 1)
  // Actually need dynamic ensure. For simplicity, use a loop with push-like logic:
  // We already ensured +1 but need +src_len. Let's use a different approach:
  // Re-read dst len after ensure
  emit_local_get_gc(buf, dst_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 0)
  emit_local_set_gc(buf, dst_len)
  emit_local_get_gc(buf, src_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 2)
  emit_local_set_gc(buf, src_data)
  emit_local_get_gc(buf, dst_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 2)
  emit_local_set_gc(buf, dst_data)
  // Copy loop: dst_data[dst_len + i] = src_data[i] for i in 0..src_len
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, src_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  // Ensure capacity for each element (simple but safe)
  emit_bytes_ensure_cap_gc(ctx, fctx, buf, dst_idx, 1)
  // Re-read dst_data after possible grow
  emit_local_get_gc(buf, dst_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 2)
  emit_local_set_gc(buf, dst_data)
  emit_local_get_gc(buf, dst_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 0)
  emit_local_set_gc(buf, dst_len)
  // dst_data[dst_len] = src_data[i]
  emit_local_get_gc(buf, dst_data)
  emit_local_get_gc(buf, dst_len)
  emit_local_get_gc(buf, src_data)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  // dst.len += 1
  emit_local_get_gc(buf, dst_idx)
  emit_local_get_gc(buf, dst_len)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_struct_set_gc(buf, ctx.bytes_type, 0)
  // i++
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_i32_const_gc(buf, 0) // Unit
}

///|
fn compile_bytes_slice_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  bytes_expr : @core.Expr,
  start_expr : @core.Expr,
  end_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let b_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.bytes_type))
  let s_idx = alloc_local_gc(fctx, GcValKind::I32)
  let e_idx = alloc_local_gc(fctx, GcValKind::I32)
  let n_idx = alloc_local_gc(fctx, GcValKind::I32)
  let new_arr = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let src_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, bytes_expr)
  emit_local_set_gc(buf, b_idx)
  compile_expr_gc(ctx, fctx, buf, start_expr)
  let sk = infer_expr_kind_gc(ctx, fctx, start_expr)
  if sk == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_local_set_gc(buf, s_idx)
  compile_expr_gc(ctx, fctx, buf, end_expr)
  let ek = infer_expr_kind_gc(ctx, fctx, end_expr)
  if ek == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_local_set_gc(buf, e_idx)
  // n = end - start
  emit_local_get_gc(buf, e_idx)
  emit_local_get_gc(buf, s_idx)
  emit_i32_sub_gc(buf)
  emit_local_set_gc(buf, n_idx)
  // new_arr = array.new_default(n)
  emit_local_get_gc(buf, n_idx)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, new_arr)
  // src_data
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 2)
  emit_local_set_gc(buf, src_data)
  // Copy loop
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, n_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, new_arr)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, src_data)
  emit_local_get_gc(buf, s_idx)
  emit_local_get_gc(buf, i_idx)
  emit_i32_add_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // Wrap in bytes struct: len=n, cap=n, data=new_arr
  emit_local_get_gc(buf, n_idx)
  emit_local_get_gc(buf, n_idx)
  emit_local_get_gc(buf, new_arr)
  emit_struct_new_gc(buf, ctx.bytes_type)
}

///|
fn compile_bytes_concat_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  a_expr : @core.Expr,
  b_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let a_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.bytes_type))
  let b_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.bytes_type))
  let a_len = alloc_local_gc(fctx, GcValKind::I32)
  let b_len = alloc_local_gc(fctx, GcValKind::I32)
  let total = alloc_local_gc(fctx, GcValKind::I32)
  let new_arr = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let a_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let b_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, a_expr)
  emit_local_set_gc(buf, a_idx)
  compile_expr_gc(ctx, fctx, buf, b_expr)
  emit_local_set_gc(buf, b_idx)
  emit_local_get_gc(buf, a_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 0)
  emit_local_set_gc(buf, a_len)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 0)
  emit_local_set_gc(buf, b_len)
  emit_local_get_gc(buf, a_len)
  emit_local_get_gc(buf, b_len)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, total)
  emit_local_get_gc(buf, total)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, new_arr)
  emit_local_get_gc(buf, a_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 2)
  emit_local_set_gc(buf, a_data)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 2)
  emit_local_set_gc(buf, b_data)
  // Copy a
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, a_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, new_arr)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, a_data)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // Copy b
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, b_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, new_arr)
  emit_local_get_gc(buf, a_len)
  emit_local_get_gc(buf, i_idx)
  emit_i32_add_gc(buf)
  emit_local_get_gc(buf, b_data)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // Wrap
  emit_local_get_gc(buf, total)
  emit_local_get_gc(buf, total)
  emit_local_get_gc(buf, new_arr)
  emit_struct_new_gc(buf, ctx.bytes_type)
}

///|
fn compile_bytes_blit_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  dst_expr : @core.Expr,
  src_expr : @core.Expr,
  start_expr : @core.Expr,
  end_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let dst_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.bytes_type))
  let src_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.bytes_type))
  let s_idx = alloc_local_gc(fctx, GcValKind::I32)
  let e_idx = alloc_local_gc(fctx, GcValKind::I32)
  let copy_len = alloc_local_gc(fctx, GcValKind::I32)
  let dst_len = alloc_local_gc(fctx, GcValKind::I32)
  let src_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let dst_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, dst_expr)
  emit_local_set_gc(buf, dst_idx)
  compile_expr_gc(ctx, fctx, buf, src_expr)
  emit_local_set_gc(buf, src_idx)
  compile_expr_gc(ctx, fctx, buf, start_expr)
  let sk = infer_expr_kind_gc(ctx, fctx, start_expr)
  if sk == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_local_set_gc(buf, s_idx)
  compile_expr_gc(ctx, fctx, buf, end_expr)
  let ek = infer_expr_kind_gc(ctx, fctx, end_expr)
  if ek == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_local_set_gc(buf, e_idx)
  // copy_len = end - start
  emit_local_get_gc(buf, e_idx)
  emit_local_get_gc(buf, s_idx)
  emit_i32_sub_gc(buf)
  emit_local_set_gc(buf, copy_len)
  // Ensure capacity
  emit_bytes_ensure_cap_gc(ctx, fctx, buf, dst_idx, 1)
  emit_local_get_gc(buf, src_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 2)
  emit_local_set_gc(buf, src_data)
  // Copy loop
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, copy_len)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_bytes_ensure_cap_gc(ctx, fctx, buf, dst_idx, 1)
  emit_local_get_gc(buf, dst_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 2)
  emit_local_set_gc(buf, dst_data)
  emit_local_get_gc(buf, dst_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 0)
  emit_local_set_gc(buf, dst_len)
  emit_local_get_gc(buf, dst_data)
  emit_local_get_gc(buf, dst_len)
  emit_local_get_gc(buf, src_data)
  emit_local_get_gc(buf, s_idx)
  emit_local_get_gc(buf, i_idx)
  emit_i32_add_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  // dst.len++
  emit_local_get_gc(buf, dst_idx)
  emit_local_get_gc(buf, dst_len)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_struct_set_gc(buf, ctx.bytes_type, 0)
  // i++
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_i32_const_gc(buf, 0) // Unit
}

///|
fn compile_bytes_fill_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  bytes_expr : @core.Expr,
  val_expr : @core.Expr,
  count_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let b_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.bytes_type))
  let val_idx = alloc_local_gc(fctx, GcValKind::I32)
  let count_idx = alloc_local_gc(fctx, GcValKind::I32)
  let len_idx = alloc_local_gc(fctx, GcValKind::I32)
  let data_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, bytes_expr)
  emit_local_set_gc(buf, b_idx)
  compile_expr_gc(ctx, fctx, buf, val_expr)
  let vk = infer_expr_kind_gc(ctx, fctx, val_expr)
  if vk == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_local_set_gc(buf, val_idx)
  compile_expr_gc(ctx, fctx, buf, count_expr)
  let ck = infer_expr_kind_gc(ctx, fctx, count_expr)
  if ck == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_local_set_gc(buf, count_idx)
  // fill loop
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, count_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_bytes_ensure_cap_gc(ctx, fctx, buf, b_idx, 1)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 0)
  emit_local_set_gc(buf, len_idx)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 2)
  emit_local_set_gc(buf, data_idx)
  emit_local_get_gc(buf, data_idx)
  emit_local_get_gc(buf, len_idx)
  emit_local_get_gc(buf, val_idx)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, b_idx)
  emit_local_get_gc(buf, len_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_struct_set_gc(buf, ctx.bytes_type, 0)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_i32_const_gc(buf, 0) // Unit
}

///|
fn compile_bytes_to_array_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  bytes_expr : @core.Expr,
) -> Unit raise WasmGenError {
  // Return array<i64> (Int = i64 in GC mode), converting from internal array<i32>
  let i64_arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::I64,
  )
  let b_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.bytes_type))
  let len_idx = alloc_local_gc(fctx, GcValKind::I32)
  let src_data = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let new_arr = alloc_local_gc(fctx, GcValKind::Ref(i64_arr_type))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, bytes_expr)
  emit_local_set_gc(buf, b_idx)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 0)
  emit_local_set_gc(buf, len_idx)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, ctx.bytes_type, 2)
  emit_local_set_gc(buf, src_data)
  emit_local_get_gc(buf, len_idx)
  emit_array_new_default_gc(buf, i64_arr_type)
  emit_local_set_gc(buf, new_arr)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, len_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, new_arr)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, src_data)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_i64_extend_i32_s_gc(buf) // i32 → i64
  emit_array_set_gc(buf, i64_arr_type)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, new_arr)
}

///|
fn compile_bool_to_string_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  bool_expr : @core.Expr,
) -> Unit raise WasmGenError {
  // if bool_expr { "true" } else { "false" }
  compile_expr_gc(ctx, fctx, buf, bool_expr)
  emit_if_gc(buf, Some(GcValKind::Ref(ctx.string_type)))
  emit_string_literal(ctx, buf, "true")
  emit_else_gc(buf)
  emit_string_literal(ctx, buf, "false")
  emit_end_gc(buf)
}

///|
/// Int::to_string(n) -> String: convert i64 to decimal string
fn compile_int_to_string_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  int_expr : @core.Expr,
) -> Unit raise WasmGenError {
  // Algorithm:
  // 1. Save n. If n == 0, return "0"
  // 2. If n < 0, set is_neg=1, n = -n
  // 3. Extract digits by repeated mod/div 10 into a temp array (reversed)
  // 4. Build result array in correct order, prepend '-' if negative
  // 5. Construct string struct
  let n_idx = alloc_local_gc(fctx, GcValKind::I64)
  let is_neg_idx = alloc_local_gc(fctx, GcValKind::I32)
  let digit_buf_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let digit_count_idx = alloc_local_gc(fctx, GcValKind::I32)
  let result_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let result_len_idx = alloc_local_gc(fctx, GcValKind::I32)
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, int_expr)
  emit_local_set_gc(buf, n_idx)
  // Handle n == 0
  emit_local_get_gc(buf, n_idx)
  emit_i64_const_gc(buf, 0L)
  emit_i64_eq_gc(buf)
  emit_if_gc(buf, Some(GcValKind::Ref(ctx.string_type)))
  // Return "0"
  emit_string_literal(ctx, buf, "0")
  emit_else_gc(buf)
  // Check negative
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, is_neg_idx)
  emit_local_get_gc(buf, n_idx)
  emit_i64_const_gc(buf, 0L)
  emit_i64_lt_s_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, is_neg_idx)
  emit_i64_const_gc(buf, 0L)
  emit_local_get_gc(buf, n_idx)
  emit_i64_sub_gc(buf)
  emit_local_set_gc(buf, n_idx)
  emit_end_gc(buf)
  // Allocate temp digit buffer (max 20 digits for i64)
  emit_i32_const_gc(buf, 20) // size
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, digit_buf_idx)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, digit_count_idx)
  // Extract digits loop
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  // if n == 0, break
  emit_local_get_gc(buf, n_idx)
  emit_i64_const_gc(buf, 0L)
  emit_i64_eq_gc(buf)
  emit_br_if_gc(buf, 1) // break out of block
  // digit = n % 10
  emit_local_get_gc(buf, digit_buf_idx)
  emit_local_get_gc(buf, digit_count_idx)
  emit_local_get_gc(buf, n_idx)
  emit_i64_const_gc(buf, 10L)
  emit_i64_rem_s_gc(buf)
  emit_i32_wrap_i64_gc(buf)
  emit_i32_const_gc(buf, 48) // '0'
  emit_i32_add_gc(buf)
  emit_array_set_gc(buf, ctx.array_i32_type)
  // n = n / 10
  emit_local_get_gc(buf, n_idx)
  emit_i64_const_gc(buf, 10L)
  emit_i64_div_s_gc(buf)
  emit_local_set_gc(buf, n_idx)
  // digit_count++
  emit_local_get_gc(buf, digit_count_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, digit_count_idx)
  emit_br_gc(buf, 0) // continue loop
  emit_end_gc(buf) // end loop
  emit_end_gc(buf) // end block
  // Build result: result_len = digit_count + is_neg
  emit_local_get_gc(buf, digit_count_idx)
  emit_local_get_gc(buf, is_neg_idx)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, result_len_idx)
  // Allocate result array
  emit_local_get_gc(buf, result_len_idx)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, result_idx)
  // If negative, set result[0] = '-'
  emit_local_get_gc(buf, is_neg_idx)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, result_idx)
  emit_i32_const_gc(buf, 0)
  emit_i32_const_gc(buf, 45) // '-'
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_end_gc(buf)
  // Copy digits in reverse order
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, digit_count_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1) // break
  // result[is_neg + i] = digit_buf[digit_count - 1 - i]
  emit_local_get_gc(buf, result_idx)
  emit_local_get_gc(buf, is_neg_idx)
  emit_local_get_gc(buf, i_idx)
  emit_i32_add_gc(buf)
  emit_local_get_gc(buf, digit_buf_idx)
  emit_local_get_gc(buf, digit_count_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_sub_gc(buf)
  emit_local_get_gc(buf, i_idx)
  emit_i32_sub_gc(buf)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  // i++
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0) // continue
  emit_end_gc(buf) // end loop
  emit_end_gc(buf) // end block
  // Build string struct
  emit_local_get_gc(buf, result_len_idx)
  emit_local_get_gc(buf, result_idx)
  emit_struct_new_gc(buf, ctx.string_type)
  emit_end_gc(buf) // end if (n == 0)
}

///|
/// __to_string(val) -> String: generic to_string dispatch
fn compile_to_string_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  let kind = infer_expr_kind_gc(ctx, fctx, expr)
  match kind {
    GcValKind::I64 => compile_int_to_string_gc(ctx, fctx, buf, expr)
    GcValKind::I32 => compile_bool_to_string_gc(ctx, fctx, buf, expr)
    GcValKind::Ref(type_idx) =>
      if type_idx == ctx.string_type {
        // Already a string, just return it
        compile_expr_gc(ctx, fctx, buf, expr)
      } else {
        // For other ref types, return "<value>"
        compile_expr_gc(ctx, fctx, buf, expr)
        emit_drop_gc(buf)
        emit_string_literal(ctx, buf, "<value>")
      }
    _ => {
      // For float/double/other, return "<value>"
      compile_expr_gc(ctx, fctx, buf, expr)
      emit_drop_gc(buf)
      emit_string_literal(ctx, buf, "<value>")
    }
  }
}

///|
fn compile_len_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  let kind = infer_expr_kind_gc(ctx, fctx, expr)
  match kind {
    GcValKind::Ref(type_idx) =>
      if type_idx == ctx.string_type {
        compile_expr_gc(ctx, fctx, buf, expr)
        emit_struct_get_gc(buf, ctx.string_type, 0)
        emit_i64_extend_i32_s_gc(buf)
      } else if type_idx == ctx.bytes_type {
        compile_bytes_length_gc(ctx, fctx, buf, expr)
      } else {
        match ctx.types[type_idx] {
          GcTypeDef::Array(..) => {
            compile_expr_gc(ctx, fctx, buf, expr)
            emit_array_len_gc(buf)
            emit_i64_extend_i32_s_gc(buf)
          }
          GcTypeDef::Struct(fields~) =>
            if fields.length() > 0 && fields[0] == GcValKind::I32 {
              // Struct with i32 first field (len) — e.g., ArrayBuilder, MapBuilder
              compile_expr_gc(ctx, fctx, buf, expr)
              emit_struct_get_gc(buf, type_idx, 0)
              emit_i64_extend_i32_s_gc(buf)
            } else {
              raise WasmGenError::Unsupported("__len ref")
            }
          GcTypeDef::Func(..) | GcTypeDef::TagFunc(..) =>
            raise WasmGenError::Unsupported("__len func ref")
        }
      }
    _ => {
      // Unknown type — try array.len (may trap at runtime)
      compile_expr_gc(ctx, fctx, buf, expr)
      emit_array_len_gc(buf)
      emit_i64_extend_i32_s_gc(buf)
    }
  }
}

///|
fn ensure_map_builder_type_gc(ctx : GcCodegenCtx) -> (Int, Int, Int) {
  let key_arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::EqRef,
  )
  let val_arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::EqRef,
  )
  let builder_fields : Array[GcValKind] = [
    GcValKind::I32,
    GcValKind::Ref(key_arr_type),
    GcValKind::Ref(val_arr_type),
  ]
  let builder_type = ensure_struct_type(
    ctx.types,
    ctx.struct_type_index,
    builder_fields,
  )
  (builder_type, key_arr_type, val_arr_type)
}

///|
fn gc_map_builder_kind_gc(ctx : GcCodegenCtx) -> GcValKind {
  let (builder_type, _, _) = ensure_map_builder_type_gc(ctx)
  GcValKind::Ref(builder_type)
}

///|
fn compile_map_literal_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  fields : Array[@core.MapFieldExpr],
) -> Unit raise WasmGenError {
  let saved_locals = clone_locals_gc(fctx.locals)
  let (builder_type, _, _) = ensure_map_builder_type_gc(ctx)
  let tmp_name = "__map_lit_builder_" + fctx.local_kinds.length().to_string()
  let tmp_idx = bind_local_gc(fctx, tmp_name, GcValKind::Ref(builder_type))
  let call_span = if fields.is_empty() {
    @core.Span::empty(0)
  } else {
    fields[0].span
  }
  let builder_new = @core.Expr::Call(
    name="MapBuilder::new",
    type_args=[],
    args=[],
    span=call_span,
  )
  compile_expr_gc(ctx, fctx, buf, builder_new)
  emit_local_set_gc(buf, tmp_idx)
  for field in fields {
    let set_expr = @core.Expr::Call(
      name="MapBuilder::set",
      type_args=[],
      args=[
        @core.CallArg::{
          label: None,
          expr: @core.Expr::Ident(name=tmp_name, span=field.span),
          span: field.span,
        },
        @core.CallArg::{
          label: None,
          expr: @core.Expr::String(value=field.key, span=field.span),
          span: field.span,
        },
        @core.CallArg::{ label: None, expr: field.expr, span: field.span },
      ],
      span=field.span,
    )
    compile_expr_gc(ctx, fctx, buf, set_expr)
    emit_drop_gc(buf)
  }
  emit_local_get_gc(buf, tmp_idx)
  restore_locals_gc(fctx, saved_locals)
}

///|
fn infer_map_value_kind_from_expr_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  expr : @core.Expr,
) -> GcValKind? raise WasmGenError {
  match expr {
    @core.Expr::Map(fields~, ..) =>
      if fields.is_empty() {
        None
      } else {
        Some(infer_expr_kind_gc(ctx, fctx, fields[0].expr))
      }
    @core.Expr::Ident(name~, ..) => fctx.map_value_kinds.get(name)
    @core.Expr::Call(name~, args~, ..) => {
      let lowered = @core.lower_wasm_intrinsic_name(name)
      if lowered == "MapBuilder::freeze" && args.length() == 1 {
        infer_map_value_kind_from_expr_gc(ctx, fctx, args[0].expr)
      } else {
        None
      }
    }
    _ => None
  }
}

///|
/// Detect whether `kind` is the ArrayBuilder/Array::with_capacity
/// struct representation `{len: i32, data: ref array<_>}`. Used by
/// Array::push/get/set/length to dispatch between bare-array and
/// struct-wrapped Array storage.
fn gc_is_array_builder_struct_kind(
  ctx : GcCodegenCtx,
  kind : GcValKind,
) -> Int? {
  match kind {
    GcValKind::Ref(type_idx) =>
      match ctx.types[type_idx] {
        GcTypeDef::Struct(fields~) =>
          if fields.length() == 2 && fields[0] == GcValKind::I32 {
            match fields[1] {
              GcValKind::Ref(inner_idx) =>
                match ctx.types[inner_idx] {
                  GcTypeDef::Array(..) => Some(type_idx)
                  _ => None
                }
              _ => None
            }
          } else {
            None
          }
        _ => None
      }
    _ => None
  }
}

///|
fn gc_array_type_idx_from_kind(
  ctx : GcCodegenCtx,
  kind : GcValKind,
  _opname : String,
) -> Int {
  match kind {
    GcValKind::Ref(type_idx) =>
      match ctx.types[type_idx] {
        GcTypeDef::Array(..) => type_idx
        // Struct with array field (e.g., ArrayBuilder) → use inner array
        GcTypeDef::Struct(fields~) =>
          if fields.length() >= 2 {
            match fields[1] {
              GcValKind::Ref(inner_idx) =>
                match ctx.types[inner_idx] {
                  GcTypeDef::Array(..) => inner_idx
                  _ =>
                    // Default: assume I64 array
                    ensure_array_type(
                      ctx.types,
                      ctx.array_type_index,
                      GcValKind::I64,
                    )
                }
              _ =>
                ensure_array_type(
                  ctx.types,
                  ctx.array_type_index,
                  GcValKind::I64,
                )
            }
          } else {
            ensure_array_type(ctx.types, ctx.array_type_index, GcValKind::I64)
          }
        _ => ensure_array_type(ctx.types, ctx.array_type_index, GcValKind::I64)
      }
    _ =>
      // Unknown type, default to I64 array
      ensure_array_type(ctx.types, ctx.array_type_index, GcValKind::I64)
  }
}

///|
fn gc_array_elem_kind_from_kind(
  ctx : GcCodegenCtx,
  kind : GcValKind,
  opname : String,
) -> GcValKind raise WasmGenError {
  let type_idx = gc_array_type_idx_from_kind(ctx, kind, opname)
  match ctx.types[type_idx] {
    GcTypeDef::Array(elem~) => elem
    _ => raise WasmGenError::Unsupported(opname + " kind")
  }
}

///|
fn compile_array_fold_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  array_expr : @core.Expr,
  init_expr : @core.Expr,
  func_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let array_kind = infer_expr_kind_gc(ctx, fctx, array_expr)
  let array_type_idx = gc_array_type_idx_from_kind(
    ctx, array_kind, "Array::fold",
  )
  let elem_kind = gc_array_elem_kind_from_kind(ctx, array_kind, "Array::fold")
  let result_kind = infer_expr_kind_gc(ctx, fctx, init_expr)
  let closure_kind = infer_expr_kind_gc(ctx, fctx, func_expr)
  let (closure_struct_type, fn_type_idx, fn_param_kinds, fn_result_kind) = closure_call_sig_from_kind_gc(
    ctx, closure_kind, "Array::fold",
  )
  if fn_param_kinds.length() != 3 {
    raise WasmGenError::Unsupported("Array::fold callback arity")
  }

  let array_local = alloc_local_gc(fctx, array_kind)
  let closure_local = alloc_local_gc(fctx, closure_kind)
  let acc_local = alloc_local_gc(fctx, result_kind)
  let len_local = alloc_local_gc(fctx, GcValKind::I32)
  let i_local = alloc_local_gc(fctx, GcValKind::I32)

  compile_expr_gc(ctx, fctx, buf, array_expr)
  if array_kind != GcValKind::Ref(array_type_idx) {
    emit_coerce_top_gc(ctx, buf, array_kind, GcValKind::Ref(array_type_idx))
  }
  emit_local_set_gc(buf, array_local)

  let init_kind = infer_expr_kind_gc(ctx, fctx, init_expr)
  compile_expr_gc(ctx, fctx, buf, init_expr)
  emit_coerce_top_gc(ctx, buf, init_kind, result_kind)
  emit_local_set_gc(buf, acc_local)

  compile_expr_gc(ctx, fctx, buf, func_expr)
  emit_local_set_gc(buf, closure_local)

  emit_local_get_gc(buf, array_local)
  emit_array_len_gc(buf)
  emit_local_set_gc(buf, len_local)

  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_local)

  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_local)
  emit_local_get_gc(buf, len_local)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)

  emit_local_get_gc(buf, closure_local)
  emit_struct_get_gc(buf, closure_struct_type, 1)

  emit_local_get_gc(buf, acc_local)
  emit_coerce_top_gc(ctx, buf, result_kind, fn_param_kinds[1])

  emit_local_get_gc(buf, array_local)
  emit_local_get_gc(buf, i_local)
  emit_array_get_gc(buf, array_type_idx)
  emit_coerce_top_gc(ctx, buf, elem_kind, fn_param_kinds[2])

  emit_local_get_gc(buf, closure_local)
  emit_struct_get_gc(buf, closure_struct_type, 0)
  emit_call_ref_gc(buf, fn_type_idx)
  emit_coerce_top_gc(ctx, buf, fn_result_kind, result_kind)
  emit_local_set_gc(buf, acc_local)

  emit_local_get_gc(buf, i_local)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_local)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, acc_local)
}

///|
fn compile_array_slice_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  array_expr : @core.Expr,
  start_expr : @core.Expr,
  end_expr : @core.Expr,
  opname : String,
) -> Unit raise WasmGenError {
  let array_kind = infer_expr_kind_gc(ctx, fctx, array_expr)
  let type_idx = gc_array_type_idx_from_kind(ctx, array_kind, opname)
  let arr_idx = alloc_local_gc(fctx, array_kind)
  let start_idx = alloc_local_gc(fctx, GcValKind::I32)
  let end_idx = alloc_local_gc(fctx, GcValKind::I32)
  let len_idx = alloc_local_gc(fctx, GcValKind::I32)
  let out_idx = alloc_local_gc(fctx, GcValKind::Ref(type_idx))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, array_expr)
  emit_local_set_gc(buf, arr_idx)
  compile_expr_gc(ctx, fctx, buf, start_expr)
  let sk = infer_expr_kind_gc(ctx, fctx, start_expr)
  if sk == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_local_set_gc(buf, start_idx)
  compile_expr_gc(ctx, fctx, buf, end_expr)
  let ek = infer_expr_kind_gc(ctx, fctx, end_expr)
  if ek == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_local_set_gc(buf, end_idx)
  emit_local_get_gc(buf, end_idx)
  emit_local_get_gc(buf, start_idx)
  emit_i32_sub_gc(buf)
  emit_local_set_gc(buf, len_idx)
  emit_local_get_gc(buf, len_idx)
  emit_array_new_default_gc(buf, type_idx)
  emit_local_set_gc(buf, out_idx)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, len_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, out_idx)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, arr_idx)
  emit_local_get_gc(buf, start_idx)
  emit_local_get_gc(buf, i_idx)
  emit_i32_add_gc(buf)
  emit_array_get_gc(buf, type_idx)
  emit_array_set_gc(buf, type_idx)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, out_idx)
}

///|
/// Emit a doubling-push on a struct{len:i32, data:ref array<_>} value.
/// Shared by `Array::with_capacity` (Array::push struct path) and
/// `ArrayBuilder::push` — both operate on the same wasm layout. The
/// receiver expression must evaluate to `Ref(builder_type)`.
///
/// Leaves an `i32 0` (Unit) on the stack.
fn compile_struct_array_push_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  receiver_expr : @core.Expr,
  value_expr : @core.Expr,
  builder_kind : GcValKind,
  builder_type : Int,
  arr_type : Int,
) -> Unit raise WasmGenError {
  // Reuse named locals across multiple struct-push calls in the same
  // function to avoid local-slot drift.
  let b_idx = match fctx.locals.get("__sp_push_b") {
    Some(info) => info.idx
    None => bind_local_gc(fctx, "__sp_push_b", builder_kind)
  }
  let len_l = match fctx.locals.get("__sp_push_len") {
    Some(info) => info.idx
    None => bind_local_gc(fctx, "__sp_push_len", GcValKind::I32)
  }
  let cap_l = match fctx.locals.get("__sp_push_cap") {
    Some(info) => info.idx
    None => bind_local_gc(fctx, "__sp_push_cap", GcValKind::I32)
  }
  let data_l = match fctx.locals.get("__sp_push_data") {
    Some(info) => info.idx
    None => bind_local_gc(fctx, "__sp_push_data", GcValKind::Ref(arr_type))
  }
  let new_data = match fctx.locals.get("__sp_push_new") {
    Some(info) => info.idx
    None => bind_local_gc(fctx, "__sp_push_new", GcValKind::Ref(arr_type))
  }
  compile_expr_gc(ctx, fctx, buf, receiver_expr)
  emit_local_set_gc(buf, b_idx)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 0)
  emit_local_set_gc(buf, len_l)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 1)
  emit_local_tee_gc(buf, data_l)
  emit_array_len_gc(buf)
  emit_local_set_gc(buf, cap_l)
  // if len >= cap, grow
  emit_local_get_gc(buf, len_l)
  emit_local_get_gc(buf, cap_l)
  emit_i32_ge_s_gc(buf)
  emit_if_gc(buf, None)
  // new_cap = max(cap * 2, 4) — min-4 floor covers `with_capacity(0)`,
  // is harmless for `ArrayBuilder::new` which starts at cap=8.
  emit_local_get_gc(buf, cap_l)
  emit_i32_const_gc(buf, 2)
  emit_i32_mul_gc(buf)
  emit_local_tee_gc(buf, cap_l)
  emit_i32_const_gc(buf, 4)
  emit_i32_lt_s_gc(buf)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 4)
  emit_local_set_gc(buf, cap_l)
  emit_end_gc(buf)
  // allocate new data array
  emit_local_get_gc(buf, cap_l)
  emit_array_new_default_gc(buf, arr_type)
  emit_local_set_gc(buf, new_data)
  // bulk copy: new_data[0..len] = data[0..len]
  emit_local_get_gc(buf, new_data)
  emit_i32_const_gc(buf, 0)
  emit_local_get_gc(buf, data_l)
  emit_i32_const_gc(buf, 0)
  emit_local_get_gc(buf, len_l)
  emit_array_copy_gc(buf, arr_type)
  // update struct.data = new_data and refresh data_l
  emit_local_get_gc(buf, b_idx)
  emit_local_get_gc(buf, new_data)
  emit_struct_set_gc(buf, builder_type, 1)
  emit_local_get_gc(buf, new_data)
  emit_local_set_gc(buf, data_l)
  emit_end_gc(buf)
  // data[len] = val
  let elem_kind = match ctx.types[arr_type] {
    GcTypeDef::Array(elem~) => elem
    _ => GcValKind::I64
  }
  emit_local_get_gc(buf, data_l)
  emit_local_get_gc(buf, len_l)
  let val_kind = infer_expr_kind_gc(ctx, fctx, value_expr)
  compile_expr_gc(ctx, fctx, buf, value_expr)
  emit_coerce_top_gc(ctx, buf, val_kind, elem_kind)
  emit_array_set_gc(buf, arr_type)
  // struct.len = len + 1
  emit_local_get_gc(buf, b_idx)
  emit_local_get_gc(buf, len_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_struct_set_gc(buf, builder_type, 0)
  emit_i32_const_gc(buf, 0)
}

///|
fn compile_array_concat_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  left_expr : @core.Expr,
  right_expr : @core.Expr,
  opname : String,
) -> Unit raise WasmGenError {
  let left_kind = infer_expr_kind_gc(ctx, fctx, left_expr)
  let right_kind = infer_expr_kind_gc(ctx, fctx, right_expr)
  let arr_kind = if left_kind == right_kind {
    left_kind
  } else {
    gc_common_kind(left_kind, right_kind)
  }
  let type_idx = gc_array_type_idx_from_kind(ctx, arr_kind, opname)
  let left_idx = alloc_local_gc(fctx, arr_kind)
  let right_idx = alloc_local_gc(fctx, arr_kind)
  let left_len_idx = alloc_local_gc(fctx, GcValKind::I32)
  let right_len_idx = alloc_local_gc(fctx, GcValKind::I32)
  let total_len_idx = alloc_local_gc(fctx, GcValKind::I32)
  let out_idx = alloc_local_gc(fctx, GcValKind::Ref(type_idx))
  let i_idx = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, left_expr)
  emit_local_set_gc(buf, left_idx)
  compile_expr_gc(ctx, fctx, buf, right_expr)
  emit_local_set_gc(buf, right_idx)
  emit_local_get_gc(buf, left_idx)
  emit_array_len_gc(buf)
  emit_local_set_gc(buf, left_len_idx)
  emit_local_get_gc(buf, right_idx)
  emit_array_len_gc(buf)
  emit_local_set_gc(buf, right_len_idx)
  emit_local_get_gc(buf, left_len_idx)
  emit_local_get_gc(buf, right_len_idx)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, total_len_idx)
  emit_local_get_gc(buf, total_len_idx)
  emit_array_new_default_gc(buf, type_idx)
  emit_local_set_gc(buf, out_idx)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, left_len_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, out_idx)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, left_idx)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, type_idx)
  emit_array_set_gc(buf, type_idx)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_idx)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_idx)
  emit_local_get_gc(buf, right_len_idx)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, out_idx)
  emit_local_get_gc(buf, left_len_idx)
  emit_local_get_gc(buf, i_idx)
  emit_i32_add_gc(buf)
  emit_local_get_gc(buf, right_idx)
  emit_local_get_gc(buf, i_idx)
  emit_array_get_gc(buf, type_idx)
  emit_array_set_gc(buf, type_idx)
  emit_local_get_gc(buf, i_idx)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_idx)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, out_idx)
}

///|
fn restore_locals_gc(
  fctx : GcFuncCtx,
  saved : Map[String, GcLocalInfo],
) -> Unit {
  let to_remove : Array[String] = []
  for name, _ in fctx.locals {
    if !saved.contains(name) {
      to_remove.push(name)
    }
  }
  for name in to_remove {
    fctx.locals.remove(name)
  }
  for name, info in saved {
    fctx.locals[name] = info
  }
}

///|
fn bind_pat_kinds_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  scrut_kind : GcValKind,
  pat : @core.Pat,
) -> Unit raise WasmGenError {
  match pat {
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      fctx.locals[name] = { idx: 0, kind: scrut_kind }
    }
    @core.Pat::Record(fields~, span~) | @core.Pat::Struct(fields~, span~, ..) => {
      let _ = span
      let type_idx = match scrut_kind {
        GcValKind::Ref(idx) => idx
        _ => raise WasmGenError::Unsupported("record scrutinee")
      }
      let field_kinds = match ctx.types[type_idx] {
        GcTypeDef::Struct(fields~) => fields
        _ => raise WasmGenError::Unsupported("record type")
      }
      let ordered = sort_record_fields_pat(fields)
      if ordered.length() != field_kinds.length() {
        raise WasmGenError::Unsupported("record field count")
      }
      for i in 0..<ordered.length() {
        let field = ordered[i]
        match field.pat {
          @core.Pat::Wildcard(..) => ()
          @core.Pat::Bind(name~, span~) => {
            let _ = span
            fctx.locals[name] = { idx: 0, kind: field_kinds[i] }
          }
          _ => raise WasmGenError::Unsupported("record pat field")
        }
      }
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = span
      if ctx.enum_ctor_tags.contains(name) {
        let payload_kinds = ctx.enum_ctor_field_kinds[name]
        for i in 0..<args.length() {
          match args[i] {
            @core.Pat::Bind(name=arg_name, span~) => {
              let _ = span
              let kind = if i < payload_kinds.length() {
                payload_kinds[i]
              } else {
                GcValKind::EqRef
              }
              fctx.locals[arg_name] = { idx: 0, kind }
            }
            @core.Pat::Wildcard(..) => ()
            _ =>
              bind_pat_kinds_gc(
                ctx,
                fctx,
                if i < payload_kinds.length() {
                  payload_kinds[i]
                } else {
                  GcValKind::EqRef
                },
                args[i],
              )
          }
        }
      }
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      let type_idx = match scrut_kind {
        GcValKind::Ref(idx) => idx
        _ => {
          // EqRef or unknown — create ad-hoc struct for tuple destructure
          let fields : Array[GcValKind] = []
          for _ in items {
            fields.push(GcValKind::EqRef)
          }
          ensure_struct_type(ctx.types, ctx.struct_type_index, fields)
        }
      }
      let field_kinds = match ctx.types[type_idx] {
        GcTypeDef::Struct(fields~) => fields
        _ => {
          let fields : Array[GcValKind] = []
          for _ in items {
            fields.push(GcValKind::EqRef)
          }
          fields
        }
      }
      for i in 0..<items.length() {
        let kind = if i < field_kinds.length() {
          field_kinds[i]
        } else {
          GcValKind::EqRef
        }
        bind_pat_kinds_gc(ctx, fctx, kind, items[i])
      }
    }
    _ => ()
  }
}

///|
fn compile_pat_cond_gc(
  ctx : GcCodegenCtx,
  _fctx : GcFuncCtx,
  buf : GcByteBuf,
  scrut_idx : Int,
  scrut_kind : GcValKind,
  pat : @core.Pat,
) -> Unit raise WasmGenError {
  match pat {
    @core.Pat::Wildcard(..) | @core.Pat::Bind(..) => emit_i32_const_gc(buf, 1)
    @core.Pat::Int(value=n, span~) => {
      let _ = span
      match scrut_kind {
        GcValKind::I64 => {
          emit_local_get_gc(buf, scrut_idx)
          emit_i64_const_gc(buf, n)
          emit_i64_eq_gc(buf)
        }
        GcValKind::I32 => {
          emit_local_get_gc(buf, scrut_idx)
          emit_i32_const_gc(buf, n.to_int())
          emit_i32_eq_gc(buf)
        }
        // The scrutinee is an erased generic (eqref / anyref / ref to
        // unknown struct), e.g. `match Some(7) { Some(0) => ..., ... }`
        // where the option payload is bound as eqref. Unbox through
        // the matching `{i64}` box-struct shape that
        // `emit_box_top_for_ref_kind_gc` produces on the storage side,
        // then compare to the literal. The cast trips if the eqref
        // is not actually an i64 box — which would already be a type
        // error at the source level, so let wasmtime raise it.
        _ => {
          emit_local_get_gc(buf, scrut_idx)
          emit_coerce_top_gc(ctx, buf, scrut_kind, GcValKind::I64)
          emit_i64_const_gc(buf, n)
          emit_i64_eq_gc(buf)
        }
      }
    }
    @core.Pat::Bool(value=b, span~) => {
      let _ = span
      match scrut_kind {
        GcValKind::I32 => {
          emit_local_get_gc(buf, scrut_idx)
          emit_i32_const_gc(buf, if b { 1 } else { 0 })
          emit_i32_eq_gc(buf)
        }
        _ => raise WasmGenError::Unsupported("pat bool kind")
      }
    }
    @core.Pat::Record(fields~, span~) | @core.Pat::Struct(fields~, span~, ..) => {
      let _ = span
      let ordered = sort_record_fields_pat(fields)
      for field in ordered {
        match field.pat {
          @core.Pat::Wildcard(..) | @core.Pat::Bind(..) => ()
          _ => raise WasmGenError::Unsupported("record pat field")
        }
      }
      emit_i32_const_gc(buf, 1)
    }
    @core.Pat::Ctor(name~, span~, ..) => {
      let _ = span
      match ctx.enum_ctor_tags.get(name) {
        Some(tag) => {
          let type_idx = ctx.enum_ctor_type_indices[name]
          // ref.test to check if cast is safe
          emit_local_get_gc(buf, scrut_idx)
          emit_ref_test_gc(buf, type_idx)
          // if ref.test passes, check the tag; else 0
          emit_if_gc(buf, Some(GcValKind::I32))
          emit_local_get_gc(buf, scrut_idx)
          emit_ref_cast_gc(buf, type_idx)
          emit_struct_get_gc(buf, type_idx, 0)
          emit_i32_const_gc(buf, tag)
          emit_i32_eq_gc(buf)
          emit_else_gc(buf)
          emit_i32_const_gc(buf, 0)
          emit_end_gc(buf)
        }
        None => raise WasmGenError::Unsupported("unknown ctor: " + name)
      }
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      // Tuple itself matches structurally, but any nested Ctor / literal
      // patterns must still be checked. Emit an AND-chain across items.
      let type_idx = match scrut_kind {
        GcValKind::Ref(idx) => idx
        _ => {
          let fields : Array[GcValKind] = []
          for _ in items {
            fields.push(GcValKind::EqRef)
          }
          ensure_struct_type(ctx.types, ctx.struct_type_index, fields)
        }
      }
      let field_kinds = match ctx.types[type_idx] {
        GcTypeDef::Struct(fields~) => fields
        _ => {
          let fields : Array[GcValKind] = []
          for _ in items {
            fields.push(GcValKind::EqRef)
          }
          fields
        }
      }
      let mut emitted_any = false
      for i in 0..<items.length() {
        let item = items[i]
        match item {
          @core.Pat::Wildcard(..) | @core.Pat::Bind(..) => ()
          sub_pat => {
            let kind = if i < field_kinds.length() {
              field_kinds[i]
            } else {
              GcValKind::EqRef
            }
            let sub_idx = alloc_local_gc(_fctx, kind)
            emit_local_get_gc(buf, scrut_idx)
            match scrut_kind {
              GcValKind::Ref(_) => ()
              _ => emit_ref_cast_gc(buf, type_idx)
            }
            emit_struct_get_gc(buf, type_idx, i)
            emit_local_set_gc(buf, sub_idx)
            compile_pat_cond_gc(ctx, _fctx, buf, sub_idx, kind, sub_pat)
            if emitted_any {
              emit_i32_and_gc(buf)
            }
            emitted_any = true
          }
        }
      }
      if !emitted_any {
        emit_i32_const_gc(buf, 1)
      }
    }
    @core.Pat::String(value=s, span~) => {
      let _ = span
      // String pattern: compare by ref.eq (same literal = same ref in GC)
      emit_local_get_gc(buf, scrut_idx)
      emit_string_literal(ctx, buf, s)
      emit_ref_eq_gc(buf)
    }
    _ => raise WasmGenError::Unsupported("pat")
  }
}

///|
fn compile_pat_bind_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  scrut_idx : Int,
  scrut_kind : GcValKind,
  pat : @core.Pat,
) -> Unit raise WasmGenError {
  match pat {
    @core.Pat::Wildcard(..) => ()
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      let idx = bind_local_gc(fctx, name, scrut_kind)
      emit_local_get_gc(buf, scrut_idx)
      emit_local_set_gc(buf, idx)
    }
    @core.Pat::Record(fields~, span~) | @core.Pat::Struct(fields~, span~, ..) => {
      let _ = span
      let type_idx = match scrut_kind {
        GcValKind::Ref(idx) => idx
        _ => raise WasmGenError::Unsupported("record scrutinee")
      }
      let field_kinds = match ctx.types[type_idx] {
        GcTypeDef::Struct(fields~) => fields
        _ => raise WasmGenError::Unsupported("record type")
      }
      let ordered = sort_record_fields_pat(fields)
      if ordered.length() != field_kinds.length() {
        raise WasmGenError::Unsupported("record field count")
      }
      for i in 0..<ordered.length() {
        let field = ordered[i]
        match field.pat {
          @core.Pat::Wildcard(..) => ()
          @core.Pat::Bind(name~, span~) => {
            let _ = span
            let idx = bind_local_gc(fctx, name, field_kinds[i])
            emit_local_get_gc(buf, scrut_idx)
            emit_struct_get_gc(buf, type_idx, i)
            emit_local_set_gc(buf, idx)
          }
          _ => raise WasmGenError::Unsupported("record pat field")
        }
      }
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = span
      match ctx.enum_ctor_tags.get(name) {
        Some(_) => {
          let type_idx = ctx.enum_ctor_type_indices[name]
          let payload_kinds = ctx.enum_ctor_field_kinds[name]
          // Cast scrutinee to the variant struct type
          let casted_idx = alloc_local_gc(fctx, GcValKind::Ref(type_idx))
          emit_local_get_gc(buf, scrut_idx)
          emit_ref_cast_gc(buf, type_idx)
          emit_local_set_gc(buf, casted_idx)
          // Bind each payload arg (field 0 is tag, payloads start at field 1)
          for i in 0..<args.length() {
            let arg = args[i]
            match arg {
              @core.Pat::Wildcard(..) => ()
              @core.Pat::Bind(name=arg_name, span~) => {
                let _ = span
                let kind = if i < payload_kinds.length() {
                  payload_kinds[i]
                } else {
                  GcValKind::EqRef
                }
                let idx = bind_local_gc(fctx, arg_name, kind)
                emit_local_get_gc(buf, casted_idx)
                emit_struct_get_gc(buf, type_idx, i + 1)
                emit_local_set_gc(buf, idx)
              }
              sub_pat => {
                // Nested pattern (Tuple, Ctor, etc.) — extract field, then recurse
                let kind = if i < payload_kinds.length() {
                  payload_kinds[i]
                } else {
                  GcValKind::EqRef
                }
                let sub_idx = alloc_local_gc(fctx, kind)
                emit_local_get_gc(buf, casted_idx)
                emit_struct_get_gc(buf, type_idx, i + 1)
                emit_local_set_gc(buf, sub_idx)
                compile_pat_bind_gc(ctx, fctx, buf, sub_idx, kind, sub_pat)
              }
            }
          }
        }
        None => raise WasmGenError::Unsupported("unknown ctor: " + name)
      }
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      let type_idx = match scrut_kind {
        GcValKind::Ref(idx) => idx
        _ => {
          // EqRef or unknown — create ad-hoc struct for tuple destructure
          let fields : Array[GcValKind] = []
          for _ in items {
            fields.push(GcValKind::EqRef)
          }
          ensure_struct_type(ctx.types, ctx.struct_type_index, fields)
        }
      }
      let field_kinds = match ctx.types[type_idx] {
        GcTypeDef::Struct(fields~) => fields
        _ => {
          let fields : Array[GcValKind] = []
          for _ in items {
            fields.push(GcValKind::EqRef)
          }
          fields
        }
      }
      for i in 0..<items.length() {
        let item = items[i]
        let kind = if i < field_kinds.length() {
          field_kinds[i]
        } else {
          GcValKind::EqRef
        }
        match item {
          @core.Pat::Wildcard(..) => ()
          @core.Pat::Bind(name~, span~) => {
            let _ = span
            let idx = bind_local_gc(fctx, name, kind)
            emit_local_get_gc(buf, scrut_idx)
            // Cast to struct type if scrutinee is not already the right ref
            match scrut_kind {
              GcValKind::Ref(_) => ()
              _ => emit_ref_cast_gc(buf, type_idx)
            }
            emit_struct_get_gc(buf, type_idx, i)
            emit_local_set_gc(buf, idx)
          }
          // Nested pattern (Ctor, Tuple, etc.): extract field into a fresh
          // local and recurse, so bindings inside e.g. `(Some(a), Some(b))`
          // get allocated. Without this, `a`/`b` are silently dropped and
          // later references emit "unknown name: a".
          sub_pat => {
            let sub_idx = alloc_local_gc(fctx, kind)
            emit_local_get_gc(buf, scrut_idx)
            match scrut_kind {
              GcValKind::Ref(_) => ()
              _ => emit_ref_cast_gc(buf, type_idx)
            }
            emit_struct_get_gc(buf, type_idx, i)
            emit_local_set_gc(buf, sub_idx)
            compile_pat_bind_gc(ctx, fctx, buf, sub_idx, kind, sub_pat)
          }
        }
      }
    }
    _ => ()
  }
}

///|
fn compile_match_chain_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  scrut_idx : Int,
  scrut_kind : GcValKind,
  arms : Array[@core.MatchArm],
  start : Int,
  result_kind : GcValKind,
) -> Unit raise WasmGenError {
  if start >= arms.length() {
    emit_unreachable_gc(buf)
    return
  }
  let arm = arms[start]
  if arm.cond is Some(_) {
    raise WasmGenError::Unsupported("match guard")
  }
  let saved = clone_locals_gc(fctx.locals)
  compile_pat_cond_gc(ctx, fctx, buf, scrut_idx, scrut_kind, arm.pat)
  emit_if_gc(buf, Some(result_kind))
  // Issue #417: per-arm coverage point.
  emit_coverage_gc(ctx, buf, WasmCoveragePointKind::BranchMatchArm, arm.span)
  compile_pat_bind_gc(ctx, fctx, buf, scrut_idx, scrut_kind, arm.pat)
  let arm_kind = infer_expr_kind_gc(ctx, fctx, arm.expr)
  compile_expr_gc(ctx, fctx, buf, arm.expr)
  emit_coerce_top_gc(ctx, buf, arm_kind, result_kind)
  restore_locals_gc(fctx, saved)
  emit_else_gc(buf)
  restore_locals_gc(fctx, saved)
  compile_match_chain_gc(
    ctx,
    fctx,
    buf,
    scrut_idx,
    scrut_kind,
    arms,
    start + 1,
    result_kind,
  )
  emit_end_gc(buf)
  restore_locals_gc(fctx, saved)
}

///|
fn compile_expr_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  match expr {
    @core.Expr::Int(value=n, span~) => {
      let _ = span
      emit_i64_const_gc(buf, n)
    }
    @core.Expr::Float(value=n, span~) => {
      let _ = span
      emit_f32_const_gc(buf, n)
    }
    @core.Expr::Double(value=n, span~) => {
      let _ = span
      emit_f64_const_gc(buf, n)
    }
    @core.Expr::Bool(value=b, span~) => {
      let _ = span
      emit_i32_const_gc(buf, if b { 1 } else { 0 })
    }
    @core.Expr::Char(value=c, span~) => {
      let _ = span
      emit_i64_const_gc(buf, c.to_int().to_int64())
    }
    @core.Expr::String(value=s, span~) => {
      let _ = span
      emit_string_literal(ctx, buf, s)
    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      match fctx.locals.get(name) {
        Some(info) => emit_local_get_gc(buf, info.idx)
        None =>
          // Nullary enum constructor
          if ctx.enum_ctor_tags.contains(name) &&
            ctx.enum_ctor_arities[name] == 0 {
            let tag = ctx.enum_ctor_tags[name]
            let type_idx = ctx.enum_ctor_type_indices[name]
            emit_i32_const_gc(buf, tag)
            emit_struct_new_gc(buf, type_idx)
          } else if name == "None" {
            // Builtin None: nullary struct {tag=0}
            let fields : Array[GcValKind] = [GcValKind::I32]
            let type_idx = ensure_struct_type(
              ctx.types,
              ctx.struct_type_index,
              fields,
            )
            emit_i32_const_gc(buf, 0)
            emit_struct_new_gc(buf, type_idx)
          } else if ctx.global_consts.contains(name) {
            // Top-level constant (Int, Bool, String)
            let (idx, _) = ctx.global_consts[name]
            emit_global_get_gc(buf, idx)
          } else if ctx.string_consts.contains(name) {
            // Top-level String constant: inline the literal at each use
            // site. Construction cost is the same as a per-call literal
            // — sha1 `hex_table = "0123456789abcdef"` referenced via
            // `hex_table[i]` etc.
            emit_string_literal(ctx, buf, ctx.string_consts[name])
          } else if ctx.func_indices.contains(name) {
            // Top-level function used as value: wrap in closure struct
            let func_idx = ctx.func_indices[name]
            let param_count = match ctx.func_param_counts.get(name) {
              Some(c) => c
              None => 0
            }
            let result_kind = match ctx.func_returns.get(name) {
              Some(k) => k
              None => GcValKind::I64
            }
            let param_kinds = match ctx.func_param_kinds.get(name) {
              Some(kinds) => kinds
              None => {
                let kinds : Array[GcValKind] = []
                for _ in 0..<param_count {
                  kinds.push(GcValKind::I64)
                }
                kinds
              }
            }
            let (fn_type_idx, struct_type_idx) = ensure_closure_types_gc(
              ctx, param_kinds, result_kind,
            )
            // Create a wrapper closure that calls the function
            // We need a lifted function that takes (env, args...) and calls func_idx
            let wrapper_buf = GcByteBuf::new()
            for i in 0..<param_count {
              emit_local_get_gc(wrapper_buf, i + 1) // skip env param
            }
            emit_call_gc(wrapper_buf, func_idx)
            let wrapper_sig_params : Array[GcValKind] = [GcValKind::AnyRef]
            for i in 0..<param_count {
              wrapper_sig_params.push(param_kinds[i])
            }
            let wrapper_sig = GcFuncSig::{
              params: wrapper_sig_params,
              result: result_kind,
            }
            let wrapper_idx = ctx.num_regular_funcs +
              ctx.closure_lifted_funcs.length()
            ctx.closure_lifted_funcs.push(GcWasmFunc::{
              sig: wrapper_sig,
              locals: [],
              body: wrapper_buf.to_array(),
              type_idx: fn_type_idx,
            })
            ctx.closure_lifted_labels.push("as_closure::" + name)
            emit_ref_func_gc(buf, wrapper_idx)
            // Empty environment struct
            let env_type_idx = ensure_struct_type(
              ctx.types,
              ctx.struct_type_index,
              [],
            )
            emit_struct_new_gc(buf, env_type_idx)
            emit_struct_new_gc(buf, struct_type_idx)
          } else if is_gc_builtin_name(name) {
            emit_unreachable_gc(buf)
          } else {
            raise WasmGenError::UnknownName(name)
          }
      }
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      let kind = infer_array_kind_gc(ctx, fctx, items)
      let type_idx = match kind {
        GcValKind::Ref(idx) => idx
        _ => raise WasmGenError::Unsupported("array kind")
      }
      for item in items {
        compile_expr_gc(ctx, fctx, buf, item)
      }
      emit_array_new_fixed_gc(buf, type_idx, items.length())
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      compile_map_literal_gc(ctx, fctx, buf, fields)
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      let kind = infer_tuple_kind_gc(ctx, fctx, items)
      let type_idx = match kind {
        GcValKind::Ref(idx) => idx
        _ => raise WasmGenError::Unsupported("tuple kind")
      }
      for item in items {
        compile_expr_gc(ctx, fctx, buf, item)
      }
      emit_struct_new_gc(buf, type_idx)
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      let ordered = sort_record_fields_expr(fields)
      let kind = infer_record_kind_gc(ctx, fctx, fields)
      let type_idx = match kind {
        GcValKind::Ref(idx) => idx
        _ => raise WasmGenError::Unsupported("record kind")
      }
      for field in ordered {
        compile_expr_gc(ctx, fctx, buf, field.expr)
      }
      emit_struct_new_gc(buf, type_idx)
    }
    @core.Expr::StructLit(fields~, span~, ..) => {
      // StructLit uses same layout as Record
      let _ = span
      let ordered = sort_record_fields_expr(fields)
      let kind = infer_record_kind_gc(ctx, fctx, fields)
      let type_idx = match kind {
        GcValKind::Ref(idx) => idx
        _ => raise WasmGenError::Unsupported("struct kind")
      }
      for field in ordered {
        compile_expr_gc(ctx, fctx, buf, field.expr)
      }
      emit_struct_new_gc(buf, type_idx)
    }
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      let name = @core.lower_wasm_intrinsic_name(name)
      let pos_args = extract_positional_exprs(args, name)
      // Phase B-1 (#415): table-driven dispatch for migrated builtins.
      match migrated_builtin(name) {
        Some(m) => {
          (m.compile_gc)(ctx, fctx, buf, pos_args)
          return
        }
        None => ()
      }
      match name {
        // `add` / `sub` / `mul` / `div` are prelude thin-wrapper short-
        // circuits — when both args are arithmetic (i32 / i64 / f32 /
        // f64) inline the matching wasm op so we don't have to pay a
        // call into the prelude's `(Num, Num) -> Num` wrapper (which
        // collapses to i64 in wasm-gc and would mis-type f32/f64 args).
        // When operands aren't arithmetic (e.g.
        // `vibe/collection/set.vibe::add: (StringSet, String) -> StringSet`)
        // fall through to the normal `call $name` dispatch below, so a
        // user function with the same name keeps working.
        "add" if gc_call_args_arith(ctx, fctx, pos_args) => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("add arity")
          }
          let lk = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let rk = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let arith = gc_arith_kind(gc_common_kind(lk, rk))
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_coerce_top_gc(ctx, buf, lk, arith)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_coerce_top_gc(ctx, buf, rk, arith)
          match arith {
            GcValKind::I64 => emit_i64_add_gc(buf)
            GcValKind::I32 => emit_i32_add_gc(buf)
            GcValKind::F32 => emit_f32_add_gc(buf)
            GcValKind::F64 => emit_f64_add_gc(buf)
            _ => emit_i64_add_gc(buf)
          }
        }
        "sub" if gc_call_args_arith(ctx, fctx, pos_args) => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("sub arity")
          }
          let lk = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let rk = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let arith = gc_arith_kind(gc_common_kind(lk, rk))
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_coerce_top_gc(ctx, buf, lk, arith)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_coerce_top_gc(ctx, buf, rk, arith)
          match arith {
            GcValKind::I64 => emit_i64_sub_gc(buf)
            GcValKind::I32 => emit_i32_sub_gc(buf)
            GcValKind::F32 => emit_f32_sub_gc(buf)
            GcValKind::F64 => emit_f64_sub_gc(buf)
            _ => emit_i64_sub_gc(buf)
          }
        }
        "mul" if gc_call_args_arith(ctx, fctx, pos_args) => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("mul arity")
          }
          let lk = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let rk = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let arith = gc_arith_kind(gc_common_kind(lk, rk))
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_coerce_top_gc(ctx, buf, lk, arith)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_coerce_top_gc(ctx, buf, rk, arith)
          match arith {
            GcValKind::I64 => emit_i64_mul_gc(buf)
            GcValKind::I32 => emit_i32_mul_gc(buf)
            GcValKind::F32 => emit_f32_mul_gc(buf)
            GcValKind::F64 => emit_f64_mul_gc(buf)
            _ => emit_i64_mul_gc(buf)
          }
        }
        "div" if gc_call_args_arith(ctx, fctx, pos_args) => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("div arity")
          }
          let lk = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let rk = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let arith = gc_arith_kind(gc_common_kind(lk, rk))
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_coerce_top_gc(ctx, buf, lk, arith)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_coerce_top_gc(ctx, buf, rk, arith)
          match arith {
            GcValKind::I64 => emit_i64_div_s_gc(buf)
            GcValKind::I32 => emit_i32_div_s_gc(buf)
            GcValKind::F32 => emit_f32_div_gc(buf)
            GcValKind::F64 => emit_f64_div_gc(buf)
            _ => emit_i64_div_s_gc(buf)
          }
        }
        // `eq` / `lt` are prelude thin wrappers around `__eq` / `__lt`
        // declared with the synthetic `Num` type that the wasm-gc
        // backend collapses to i64 — calling the bundled function with
        // f32 / f64 args would trip wasm validation. Always inline the
        // comparison primitive matched to the operand kinds, regardless
        // of whether a user-defined `eq` / `lt` exists. The prelude
        // `let eq = (x: Num, y: Num) -> ...` function still gets
        // bundled but its body is now unreachable; DCE drops it from
        // the final module.
        "eq" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("eq arity")
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let arith = gc_arith_kind(gc_common_kind(left_kind, right_kind))
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_coerce_top_gc(ctx, buf, left_kind, arith)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_coerce_top_gc(ctx, buf, right_kind, arith)
          match arith {
            GcValKind::I64 => emit_i64_eq_gc(buf)
            GcValKind::I32 => emit_i32_eq_gc(buf)
            GcValKind::F32 => emit_f32_eq_gc(buf)
            GcValKind::F64 => emit_f64_eq_gc(buf)
            _ => emit_i64_eq_gc(buf)
          }
        }
        "lt" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("lt arity")
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let arith = gc_arith_kind(gc_common_kind(left_kind, right_kind))
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_coerce_top_gc(ctx, buf, left_kind, arith)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_coerce_top_gc(ctx, buf, right_kind, arith)
          match arith {
            GcValKind::I64 => emit_i64_lt_s_gc(buf)
            GcValKind::I32 => emit_i32_lt_s_gc(buf)
            GcValKind::F32 => emit_f32_lt_gc(buf)
            GcValKind::F64 => emit_f64_lt_gc(buf)
            _ => emit_i64_lt_s_gc(buf)
          }
        }
        "__add" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__add arity")
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let unified = if left_kind == right_kind {
            left_kind
          } else {
            gc_common_kind(left_kind, right_kind)
          }
          let arith = gc_arith_kind(unified)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_coerce_top_gc(ctx, buf, left_kind, arith)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_coerce_top_gc(ctx, buf, right_kind, arith)
          match arith {
            GcValKind::I64 => emit_i64_add_gc(buf)
            GcValKind::I32 => emit_i32_add_gc(buf)
            GcValKind::F32 => emit_f32_add_gc(buf)
            GcValKind::F64 => emit_f64_add_gc(buf)
            _ => emit_i64_add_gc(buf)
          }
        }
        "__sub" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__sub arity")
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let unified = if left_kind == right_kind {
            left_kind
          } else {
            gc_common_kind(left_kind, right_kind)
          }
          let arith = gc_arith_kind(unified)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_coerce_top_gc(ctx, buf, left_kind, arith)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_coerce_top_gc(ctx, buf, right_kind, arith)
          match arith {
            GcValKind::I64 => emit_i64_sub_gc(buf)
            GcValKind::I32 => emit_i32_sub_gc(buf)
            GcValKind::F32 => emit_f32_sub_gc(buf)
            GcValKind::F64 => emit_f64_sub_gc(buf)
            _ => emit_i64_sub_gc(buf)
          }
        }
        "__mul" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__mul arity")
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let unified = if left_kind == right_kind {
            left_kind
          } else {
            gc_common_kind(left_kind, right_kind)
          }
          let arith = gc_arith_kind(unified)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_coerce_top_gc(ctx, buf, left_kind, arith)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_coerce_top_gc(ctx, buf, right_kind, arith)
          match arith {
            GcValKind::I64 => emit_i64_mul_gc(buf)
            GcValKind::I32 => emit_i32_mul_gc(buf)
            GcValKind::F32 => emit_f32_mul_gc(buf)
            GcValKind::F64 => emit_f64_mul_gc(buf)
            _ => emit_i64_mul_gc(buf)
          }
        }
        "__div" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__div arity")
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let unified = if left_kind == right_kind {
            left_kind
          } else {
            gc_common_kind(left_kind, right_kind)
          }
          let arith = gc_arith_kind(unified)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_coerce_top_gc(ctx, buf, left_kind, arith)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_coerce_top_gc(ctx, buf, right_kind, arith)
          match arith {
            GcValKind::I64 => emit_i64_div_s_gc(buf)
            GcValKind::I32 => emit_i32_div_s_gc(buf)
            GcValKind::F32 => emit_f32_div_gc(buf)
            GcValKind::F64 => emit_f64_div_gc(buf)
            _ => emit_i64_div_s_gc(buf)
          }
        }
        "__mod" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__mod arity")
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let unified = if left_kind == right_kind {
            left_kind
          } else {
            gc_common_kind(left_kind, right_kind)
          }
          let arith = gc_arith_kind(unified)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_coerce_top_gc(ctx, buf, left_kind, arith)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_coerce_top_gc(ctx, buf, right_kind, arith)
          match arith {
            GcValKind::I64 => emit_i64_rem_s_gc(buf)
            GcValKind::I32 => emit_i32_rem_s_gc(buf)
            _ => raise WasmGenError::Unsupported("__mod for float types")
          }
        }
        "__eq" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__eq arity")
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let unified = if left_kind == right_kind {
            left_kind
          } else {
            gc_common_kind(left_kind, right_kind)
          }
          let arith = gc_arith_kind(unified)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_coerce_top_gc(ctx, buf, left_kind, arith)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_coerce_top_gc(ctx, buf, right_kind, arith)
          match arith {
            GcValKind::I64 => emit_i64_eq_gc(buf)
            GcValKind::I32 => emit_i32_eq_gc(buf)
            GcValKind::F32 => emit_f32_eq_gc(buf)
            GcValKind::F64 => emit_f64_eq_gc(buf)
            _ => emit_i64_eq_gc(buf)
          }
        }
        "__assert" | "assert" | "assert_true" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("__assert arity")
          }
          // cond is a native i32 Bool (1=true / 0=false) in the gc backend.
          // Trap (unreachable) when it is false, then leave a Unit
          // placeholder (i32.const 0) on the stack.
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_i32_eqz_gc(buf)
          emit_if_gc(buf, None)
          emit_unreachable_gc(buf)
          emit_end_gc(buf)
          emit_i32_const_gc(buf, 0)
        }
        "__assert_eq" | "assert_eq" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__assert_eq arity")
          }
          // Compute the same equality the `__eq` arm produces (an i32 Bool),
          // dispatching on operand type so non-Int operands stay
          // wasm-validation-correct, then trap when the operands differ.
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let unified = if left_kind == right_kind {
            left_kind
          } else {
            gc_common_kind(left_kind, right_kind)
          }
          let arith = gc_arith_kind(unified)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_coerce_top_gc(ctx, buf, left_kind, arith)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_coerce_top_gc(ctx, buf, right_kind, arith)
          match arith {
            GcValKind::I64 => emit_i64_eq_gc(buf)
            GcValKind::I32 => emit_i32_eq_gc(buf)
            GcValKind::F32 => emit_f32_eq_gc(buf)
            GcValKind::F64 => emit_f64_eq_gc(buf)
            _ => emit_i64_eq_gc(buf)
          }
          // result is i32 Bool; trap when not equal, then push Unit.
          emit_i32_eqz_gc(buf)
          emit_if_gc(buf, None)
          emit_unreachable_gc(buf)
          emit_end_gc(buf)
          emit_i32_const_gc(buf, 0)
        }
        "__lt" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__lt arity")
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let unified = if left_kind == right_kind {
            left_kind
          } else {
            gc_common_kind(left_kind, right_kind)
          }
          let arith = gc_arith_kind(unified)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_coerce_top_gc(ctx, buf, left_kind, arith)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_coerce_top_gc(ctx, buf, right_kind, arith)
          match arith {
            GcValKind::I64 => emit_i64_lt_s_gc(buf)
            GcValKind::I32 => emit_i32_lt_s_gc(buf)
            GcValKind::F32 => emit_f32_lt_gc(buf)
            GcValKind::F64 => emit_f64_lt_gc(buf)
            _ => emit_i64_lt_s_gc(buf)
          }
        }
        "__or" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__or arity")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_i32_or_gc(buf)
        }
        "__not" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("__not arity")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_i32_eqz_gc(buf)
        }
        "__neg" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("__neg arity")
          }
          let kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let arith = gc_arith_kind(kind)
          match arith {
            GcValKind::I64 => {
              emit_i64_const_gc(buf, 0L)
              compile_expr_gc(ctx, fctx, buf, pos_args[0])
              emit_coerce_top_gc(ctx, buf, kind, arith)
              emit_i64_sub_gc(buf)
            }
            GcValKind::I32 => {
              emit_i32_const_gc(buf, 0)
              compile_expr_gc(ctx, fctx, buf, pos_args[0])
              emit_i32_sub_gc(buf)
            }
            GcValKind::F32 => {
              compile_expr_gc(ctx, fctx, buf, pos_args[0])
              emit_f32_neg_gc(buf)
            }
            GcValKind::F64 => {
              compile_expr_gc(ctx, fctx, buf, pos_args[0])
              emit_f64_neg_gc(buf)
            }
            _ => {
              emit_i64_const_gc(buf, 0L)
              compile_expr_gc(ctx, fctx, buf, pos_args[0])
              emit_coerce_top_gc(ctx, buf, kind, GcValKind::I64)
              emit_i64_sub_gc(buf)
            }
          }
        }
        "anyref_eq"
        | "eqref_eq"
        | "i31ref_eq"
        | "structref_eq"
        | "arrayref_eq"
        | "funcref_eq"
        | "externref_eq" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported(name + " arity")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_ref_eq_gc(buf)
          emit_i64_extend_i32_s_gc(buf)
        }
        "record_set" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("record_set arity")
          }
          let record_expr = pos_args[0]
          let name_expr = pos_args[1]
          let value_expr = pos_args[2]
          let record_kind = infer_expr_kind_gc(ctx, fctx, record_expr)
          let type_idx = match record_kind {
            GcValKind::Ref(idx) => idx
            _ => raise WasmGenError::Unsupported("record_set type")
          }
          let field_name = match name_expr {
            @core.Expr::String(value=name, ..) => name
            _ => raise WasmGenError::Unsupported("record_set field")
          }
          let field_idx = match record_expr {
            @core.Expr::Record(fields~, ..) => {
              let ordered = sort_record_fields_expr(fields)
              let mut idx = -1
              for i in 0..<ordered.length() {
                if ordered[i].name == field_name {
                  idx = i
                }
              }
              if idx < 0 {
                raise WasmGenError::Unsupported("record_set field")
              }
              idx
            }
            _ => raise WasmGenError::Unsupported("record_set record")
          }
          let rec_idx = alloc_local_gc(fctx, record_kind)
          compile_expr_gc(ctx, fctx, buf, record_expr)
          emit_local_set_gc(buf, rec_idx)
          emit_local_get_gc(buf, rec_idx)
          compile_expr_gc(ctx, fctx, buf, value_expr)
          emit_struct_set_gc(buf, type_idx, field_idx)
          emit_local_get_gc(buf, rec_idx)
        }
        "__len" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("__len arity")
          }
          compile_len_gc(ctx, fctx, buf, pos_args[0])
        }
        "__index" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__index arity")
          }
          // Struct field access: `r.field` parses as `__index(r, "field")`.
          // Try the struct path first; on miss fall through to the
          // string / bytes / map / array cases below.
          let struct_handled = match pos_args[1] {
            @core.Expr::String(value=field_name, ..) =>
              try_compile_struct_field_get_gc(
                ctx,
                fctx,
                buf,
                field_name,
                pos_args[0],
              )
            _ => false
          }
          let base_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          if struct_handled {
            // already emitted
            ()
          } else if base_kind == GcValKind::Ref(ctx.string_type) {
            // `s[i]` on String is typed as String (1-char substring) by
            // the checker — NOT as char code (use `String::char_code_at`
            // for that). Emit `substring(s, i, i+1)` so the result type
            // matches what callers expect; previously this called
            // `compile_string_char_code_at` and silently mis-typed the
            // result as i64, breaking any code that piped `s[i]` into
            // a String-returning function (e.g. sha1's `to_hex_char`).
            let next_idx = @core.Expr::Call(
              name="__add",
              type_args=[],
              args=[
                @core.CallArg::{
                  label: None,
                  expr: pos_args[1],
                  span: pos_args[1].span(),
                },
                @core.CallArg::{
                  label: None,
                  expr: @core.Expr::Int(value=1L, span=pos_args[1].span()),
                  span: pos_args[1].span(),
                },
              ],
              span=pos_args[1].span(),
            )
            compile_string_substring(
              ctx,
              fctx,
              buf,
              pos_args[0],
              pos_args[1],
              next_idx,
            )
          } else if base_kind == GcValKind::Ref(ctx.bytes_type) {
            compile_bytes_get_gc(ctx, fctx, buf, pos_args[0], pos_args[1])
          } else if base_kind == gc_map_builder_kind_gc(ctx) {
            let value_kind = match
              infer_map_value_kind_from_expr_gc(ctx, fctx, pos_args[0]) {
              Some(kind) => kind
              None => GcValKind::EqRef
            }
            let get_expr = @core.Expr::Call(
              name="Map::get",
              type_args=[],
              args=[
                @core.CallArg::{
                  label: None,
                  expr: pos_args[0],
                  span: @core.Span::empty(0),
                },
                @core.CallArg::{
                  label: None,
                  expr: pos_args[1],
                  span: @core.Span::empty(0),
                },
              ],
              span=@core.Span::empty(0),
            )
            compile_expr_gc(ctx, fctx, buf, get_expr)
            emit_coerce_top_gc(ctx, buf, GcValKind::EqRef, value_kind)
          } else {
            let type_idx = gc_array_type_idx_from_kind(
              ctx, base_kind, "__index",
            )
            compile_expr_gc(ctx, fctx, buf, pos_args[0])
            compile_expr_gc(ctx, fctx, buf, pos_args[1])
            let idx_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
            if idx_kind == GcValKind::I64 {
              emit_i32_wrap_i64_gc(buf)
            }
            emit_array_get_gc(buf, type_idx)
          }
        }
        "__set_index" => {
          // __set_index(arr, idx, value) -> arr[idx] = value; return value
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("__set_index arity")
          }
          let base_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          if base_kind == GcValKind::Ref(ctx.bytes_type) {
            compile_bytes_set_gc(
              ctx,
              fctx,
              buf,
              pos_args[0],
              pos_args[1],
              pos_args[2],
            )
          } else {
            let type_idx = gc_array_type_idx_from_kind(
              ctx, base_kind, "__set_index",
            )
            compile_expr_gc(ctx, fctx, buf, pos_args[0])
            compile_expr_gc(ctx, fctx, buf, pos_args[1])
            let idx_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
            if idx_kind == GcValKind::I64 {
              emit_i32_wrap_i64_gc(buf)
            }
            compile_expr_gc(ctx, fctx, buf, pos_args[2])
            emit_array_set_gc(buf, type_idx)
            // Return the value
            compile_expr_gc(ctx, fctx, buf, pos_args[2])
          }
        }
        "__slice" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("__slice arity")
          }
          let base_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          if base_kind == GcValKind::Ref(ctx.string_type) {
            compile_string_substring(
              ctx,
              fctx,
              buf,
              pos_args[0],
              pos_args[1],
              pos_args[2],
            )
          } else if base_kind == GcValKind::Ref(ctx.bytes_type) {
            compile_bytes_slice_gc(
              ctx,
              fctx,
              buf,
              pos_args[0],
              pos_args[1],
              pos_args[2],
            )
          } else {
            compile_array_slice_gc(
              ctx,
              fctx,
              buf,
              pos_args[0],
              pos_args[1],
              pos_args[2],
              "__slice",
            )
          }
        }
        // String::length / Bytes::length migrated to the shared builtin
        // registry (registry_string.mbt / registry_bytes.mbt).
        "Int64Array::make" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("Int64Array::make arity")
          }
          compile_int64array_make_gc(ctx, fctx, buf, pos_args[0], pos_args[1])
        }
        "Int64Array::length" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("Int64Array::length arity")
          }
          compile_int64array_length_gc(ctx, fctx, buf, pos_args[0])
        }
        "Int64Array::get" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("Int64Array::get arity")
          }
          compile_int64array_get_gc(ctx, fctx, buf, pos_args[0], pos_args[1])
        }
        "Int64Array::set" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("Int64Array::set arity")
          }
          compile_int64array_set_gc(
            ctx,
            fctx,
            buf,
            pos_args[0],
            pos_args[1],
            pos_args[2],
          )
        }
        // Bytes::new / from_array / from_string / to_string / get / set /
        // push / append / slice / concat / blit / fill / to_array migrated to
        // the shared builtin registry (registry_bytes.mbt /
        // builtin_registry.mbt).
        "String::unicode_length" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("String::unicode_length arity")
          }
          compile_string_unicode_length_gc(ctx, fctx, buf, pos_args[0])
        }
        "Int::parse" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("Int::parse arity")
          }
          compile_int_parse_gc(ctx, fctx, buf, pos_args[0])
        }
        // Bitwise ops
        "__bit_and" => {
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_i64_and_gc(buf)
        }
        "__bit_or" => {
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_i64_or_gc(buf)
        }
        "__bit_xor" => {
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_i64_xor_gc(buf)
        }
        "__bit_not" => {
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_i64_const_gc(buf, -1L)
          emit_i64_xor_gc(buf)
        }
        "__bit_lshift" => {
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_i64_shl_gc(buf)
        }
        "__bit_rshift" => {
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_i64_shr_s_gc(buf)
        }
        // Aliases for shift ops (untagged in GC mode)
        "__lshift" => {
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_i64_shl_gc(buf)
        }
        "__rshift" => {
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_i64_shr_s_gc(buf)
        }
        "i32_shr_u" => {
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          // unsigned shift right
          buf.push(0x88) // i64.shr_u
        }
        // Type conversions
        // Int::to_double migrated to the builtin registry (Phase B-1, #415).
        // Phase A.2 of docs/spec/codegen-dual-backend.md: fill in
        // the cheap Int::* arithmetic utilities that linear has but
        // wasm-gc was missing. All operate on raw i64.
        // Int::abs / max / min / clamp / signum / is_even / is_odd migrated
        // to the builtin registry (Phase B-1, #415).
        // Char::to_int / Char::from_int migrated to the builtin registry
        // (Phase B-1, #415) — see builtin_registry.mbt.
        // Int::to_float / Float::to_int / Float::to_double / Double::to_float
        // migrated to the builtin registry (Phase B-1, #415).
        "Double::from_i64_bits" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("Double::from_i64_bits arity")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_f64_reinterpret_i64_gc(buf)
        }
        // Double::to_int migrated to the builtin registry (Phase B-1, #415).
        // Direct f64 math primitives — mirror the linear backend's
        // `f64_floor`/`f64_ceil`/... builtins so wasm-gc doesn't need
        // to bundle the vibe-side `Double::floor` implementation
        // (which depends on the `double_int_{max,min}_value` Double
        // globals that the wasm-gc backend doesn't register).
        "Double::floor" | "floor" | "Float::floor" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported(name + " arity")
          }
          let arg_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          if arg_kind == GcValKind::F32 {
            buf.push(0x8e) // f32.floor
          } else {
            emit_coerce_top_gc(ctx, buf, arg_kind, GcValKind::F64)
            buf.push(0x9c) // f64.floor
          }
        }
        "Double::ceil" | "ceil" | "Float::ceil" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported(name + " arity")
          }
          let arg_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          if arg_kind == GcValKind::F32 {
            buf.push(0x8d) // f32.ceil
          } else {
            emit_coerce_top_gc(ctx, buf, arg_kind, GcValKind::F64)
            buf.push(0x9b) // f64.ceil
          }
        }
        "Double::trunc" | "trunc" | "Float::trunc" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported(name + " arity")
          }
          let arg_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          if arg_kind == GcValKind::F32 {
            buf.push(0x8f) // f32.trunc
          } else {
            emit_coerce_top_gc(ctx, buf, arg_kind, GcValKind::F64)
            buf.push(0x9d) // f64.trunc
          }
        }
        "Double::round" | "round" | "Float::round" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported(name + " arity")
          }
          let arg_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          if arg_kind == GcValKind::F32 {
            buf.push(0x90) // f32.nearest
          } else {
            emit_coerce_top_gc(ctx, buf, arg_kind, GcValKind::F64)
            buf.push(0x9e) // f64.nearest
          }
        }
        "Double::sqrt" | "Float::sqrt" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported(name + " arity")
          }
          let arg_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          if arg_kind == GcValKind::F32 {
            buf.push(0x91) // f32.sqrt
          } else {
            emit_coerce_top_gc(ctx, buf, arg_kind, GcValKind::F64)
            buf.push(0x9f) // f64.sqrt
          }
        }
        "Double::fract" | "fract" | "Float::fract" => {
          // x - trunc(x)
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported(name + " arity")
          }
          let arg_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let tmp = alloc_local_gc(
            fctx,
            if arg_kind == GcValKind::F32 {
              GcValKind::F32
            } else {
              GcValKind::F64
            },
          )
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          if arg_kind != GcValKind::F32 {
            emit_coerce_top_gc(ctx, buf, arg_kind, GcValKind::F64)
          }
          emit_local_tee_gc(buf, tmp)
          emit_local_get_gc(buf, tmp)
          if arg_kind == GcValKind::F32 {
            buf.push(0x8f) // f32.trunc
            buf.push(0x93) // f32.sub
          } else {
            buf.push(0x9d) // f64.trunc
            buf.push(0xa1) // f64.sub
          }
        }
        "Double::to_i64_bits" => {
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          // f64.reinterpret_i64 → i64
          buf.push(0xbd) // i64.reinterpret_f64
        }
        "Double::parse" => {
          // Stub: drop string arg, return 0.0
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_drop_gc(buf)
          emit_f64_const_gc(buf, 0.0)
        }
        "Int::to_string" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("Int::to_string arity")
          }
          compile_int_to_string_gc(ctx, fctx, buf, pos_args[0])
        }
        "Bool::to_string" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("Bool::to_string arity")
          }
          compile_bool_to_string_gc(ctx, fctx, buf, pos_args[0])
        }
        "Float::to_string" | "Double::to_string" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("Float/Double::to_string arity")
          }
          compile_to_string_gc(ctx, fctx, buf, pos_args[0])
        }
        "__to_string" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("__to_string arity")
          }
          compile_to_string_gc(ctx, fctx, buf, pos_args[0])
        }
        // Array ops
        "Array::length" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("Array::length arity")
          }
          compile_len_gc(ctx, fctx, buf, pos_args[0])
        }
        "Array::fold" | "fold" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("Array::fold arity")
          }
          compile_array_fold_gc(
            ctx,
            fctx,
            buf,
            pos_args[0],
            pos_args[1],
            pos_args[2],
          )
        }
        "Array::get" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("Array::get arity")
          }
          let arr_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let type_idx = gc_array_type_idx_from_kind(
            ctx, arr_kind, "Array::get",
          )
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          // If the receiver is the struct{len, data} wrapper
          // (Array::with_capacity / ArrayBuilder), unwrap to data first.
          match gc_is_array_builder_struct_kind(ctx, arr_kind) {
            Some(struct_idx) => emit_struct_get_gc(buf, struct_idx, 1)
            None => ()
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          let ik = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          if ik == GcValKind::I64 {
            emit_i32_wrap_i64_gc(buf)
          }
          emit_array_get_gc(buf, type_idx)
        }
        "Array::set" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("Array::set arity")
          }
          let arr_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let type_idx = gc_array_type_idx_from_kind(
            ctx, arr_kind, "Array::set",
          )
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          match gc_is_array_builder_struct_kind(ctx, arr_kind) {
            Some(struct_idx) => emit_struct_get_gc(buf, struct_idx, 1)
            None => ()
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          let ik = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          if ik == GcValKind::I64 {
            emit_i32_wrap_i64_gc(buf)
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[2])
          emit_array_set_gc(buf, type_idx)
          emit_i32_const_gc(buf, 0)
        }
        "Array::push" => {
          // Two paths:
          //   1. Bare-array receiver (default Array[T] kind on wasm-gc):
          //      Allocate a fresh array of len+1, copy elements, append.
          //      O(N) per push.
          //   2. Struct-wrapped receiver (Array::with_capacity result,
          //      shares ArrayBuilder layout {len:i32, data:ref array}):
          //      ArrayBuilder-style: if len < cap, write data[len] = v
          //      and len++. If full, double cap, array.copy, then write.
          //      Amortized O(1) per push.
          // If the receiver is a bare local binding (`Array::push(arr,
          // v)` where `arr` is an Ident → local var), the new array (path
          // 1) is written back into the local. Path 2 mutates the struct
          // in place, so no rebind is needed.
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("Array::push arity")
          }
          let arr_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          match gc_is_array_builder_struct_kind(ctx, arr_kind) {
            Some(builder_type) => {
              // Path 2: doubling push on struct{len, data}. Shared
              // with ArrayBuilder::push via compile_struct_array_push_gc.
              let arr_type = match ctx.types[builder_type] {
                GcTypeDef::Struct(fields~) =>
                  match fields[1] {
                    GcValKind::Ref(idx) => idx
                    _ =>
                      raise WasmGenError::Unsupported(
                        "Array::push struct data kind",
                      )
                  }
                _ => raise WasmGenError::Unsupported("Array::push struct kind")
              }
              compile_struct_array_push_gc(
                ctx,
                fctx,
                buf,
                pos_args[0],
                pos_args[1],
                arr_kind,
                builder_type,
                arr_type,
              )
            }
            None => {
              // Path 1: bare array, realloc-per-push (pre-existing
              // wasm-gc behavior).
              let type_idx = gc_array_type_idx_from_kind(
                ctx, arr_kind, "Array::push",
              )
              let old_arr = alloc_local_gc(fctx, arr_kind)
              let new_arr = alloc_local_gc(fctx, arr_kind)
              let len_l = alloc_local_gc(fctx, GcValKind::I32)
              let i_l = alloc_local_gc(fctx, GcValKind::I32)
              compile_expr_gc(ctx, fctx, buf, pos_args[0])
              emit_local_set_gc(buf, old_arr)
              emit_local_get_gc(buf, old_arr)
              emit_array_len_gc(buf)
              emit_local_set_gc(buf, len_l)
              // new array of len+1
              emit_local_get_gc(buf, len_l)
              emit_i32_const_gc(buf, 1)
              emit_i32_add_gc(buf)
              emit_array_new_default_gc(buf, type_idx)
              emit_local_set_gc(buf, new_arr)
              // copy loop
              emit_i32_const_gc(buf, 0)
              emit_local_set_gc(buf, i_l)
              emit_block_gc(buf, None)
              emit_loop_gc(buf, None)
              emit_local_get_gc(buf, i_l)
              emit_local_get_gc(buf, len_l)
              emit_i32_ge_s_gc(buf)
              emit_br_if_gc(buf, 1)
              emit_local_get_gc(buf, new_arr)
              emit_local_get_gc(buf, i_l)
              emit_local_get_gc(buf, old_arr)
              emit_local_get_gc(buf, i_l)
              emit_array_get_gc(buf, type_idx)
              emit_array_set_gc(buf, type_idx)
              emit_local_get_gc(buf, i_l)
              emit_i32_const_gc(buf, 1)
              emit_i32_add_gc(buf)
              emit_local_set_gc(buf, i_l)
              emit_br_gc(buf, 0)
              emit_end_gc(buf)
              emit_end_gc(buf)
              // set last element
              emit_local_get_gc(buf, new_arr)
              emit_local_get_gc(buf, len_l)
              compile_expr_gc(ctx, fctx, buf, pos_args[1])
              emit_array_set_gc(buf, type_idx)
              // Write the new array back into the receiver's local so
              // the caller's binding observes the growth.
              match pos_args[0] {
                @core.Expr::Ident(name~, ..) =>
                  match fctx.locals.get(name) {
                    Some(info) => {
                      emit_local_get_gc(buf, new_arr)
                      emit_local_set_gc(buf, info.idx)
                    }
                    None => () // captured from outer scope: silently no-op (pre-existing wasm-gc gap)
                  }
                _ => () // complex receiver: silently no-op
              }
              emit_i32_const_gc(buf, 0)
            }
          }
        }
        "Array::push_all" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("Array::push_all arity")
          }
          compile_array_push_all_gc(ctx, fctx, buf, pos_args[0], pos_args[1])
        }
        // FixedArray builtins (declared in vibe/builtins/declarations.vibe
        // as operating on `Array[T]`). Linear backend already implements
        // these; the wasm-gc parity gap meant `vibe/wasm/wasm_opt/wasm_opt.vibe`
        // and other FixedArray-using code couldn't be compiled with the
        // wasm-gc backend. Implementation here mirrors the corresponding
        // Array ops — `make` does one `array.new` at fixed size, `set`
        // is a direct `array.set` (no grow logic; the array is
        // immutable in capacity), `get` / `length` are aliases of the
        // Array versions.
        "FixedArray::make" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("FixedArray::make arity")
          }
          let elem_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            elem_kind,
          )
          // array.new $arr_type (default value) (size)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          let ik = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          if ik == GcValKind::I64 {
            emit_i32_wrap_i64_gc(buf)
          }
          emit_array_new_gc(buf, arr_type)
        }
        "FixedArray::length" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("FixedArray::length arity")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_array_len_gc(buf)
          emit_i64_extend_i32_s_gc(buf)
        }
        "FixedArray::get" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("FixedArray::get arity")
          }
          let arr_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let type_idx = gc_array_type_idx_from_kind(
            ctx, arr_kind, "FixedArray::get",
          )
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          let ik = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          if ik == GcValKind::I64 {
            emit_i32_wrap_i64_gc(buf)
          }
          emit_array_get_gc(buf, type_idx)
        }
        "FixedArray::set" | "FixedArray::unsafe_set" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported(name + " arity")
          }
          let arr_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let type_idx = gc_array_type_idx_from_kind(ctx, arr_kind, name)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          let ik = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          if ik == GcValKind::I64 {
            emit_i32_wrap_i64_gc(buf)
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[2])
          emit_array_set_gc(buf, type_idx)
          emit_i32_const_gc(buf, 0)
        }
        "FixedArray::blit" => {
          // FixedArray::blit(dst, dst_idx, src, src_idx, len) — copy a
          // range of elements. Backed by wasm `array.copy`.
          // Note: wasmtime 36's Cranelift implementation of array.copy
          // is roughly memcpy-equivalent for typed-array element
          // copies, faster than the manual per-element loop the
          // String concat path can't use (see profile report).
          if pos_args.length() != 5 {
            raise WasmGenError::Unsupported("FixedArray::blit arity")
          }
          let dst_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let dst_type = gc_array_type_idx_from_kind(
            ctx, dst_kind, "FixedArray::blit/dst",
          )
          let src_kind = infer_expr_kind_gc(ctx, fctx, pos_args[2])
          let src_type = gc_array_type_idx_from_kind(
            ctx, src_kind, "FixedArray::blit/src",
          )
          compile_expr_gc(ctx, fctx, buf, pos_args[0]) // dst
          compile_expr_gc(ctx, fctx, buf, pos_args[1]) // dst_idx
          let di = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          if di == GcValKind::I64 {
            emit_i32_wrap_i64_gc(buf)
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[2]) // src
          compile_expr_gc(ctx, fctx, buf, pos_args[3]) // src_idx
          let si = infer_expr_kind_gc(ctx, fctx, pos_args[3])
          if si == GcValKind::I64 {
            emit_i32_wrap_i64_gc(buf)
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[4]) // len
          let li = infer_expr_kind_gc(ctx, fctx, pos_args[4])
          if li == GcValKind::I64 {
            emit_i32_wrap_i64_gc(buf)
          }
          // array.copy dst_type src_type
          buf.push(0xfb)
          buf.push(0x11)
          write_u32_leb_gc(buf, dst_type)
          write_u32_leb_gc(buf, src_type)
          emit_i32_const_gc(buf, 0) // Unit
        }
        "Array::slice" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("Array::slice arity")
          }
          compile_array_slice_gc(
            ctx,
            fctx,
            buf,
            pos_args[0],
            pos_args[1],
            pos_args[2],
            "Array::slice",
          )
        }
        "Array::concat" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("Array::concat arity")
          }
          compile_array_concat_gc(
            ctx,
            fctx,
            buf,
            pos_args[0],
            pos_args[1],
            "Array::concat",
          )
        }
        "Array::truncate" => {
          // Array::truncate(arr_builder, new_len) -> set len field
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("Array::truncate arity")
          }
          let builder_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let builder_type = match builder_kind {
            GcValKind::Ref(idx) => idx
            _ => raise WasmGenError::Unsupported("Array::truncate kind")
          }
          let b_idx = alloc_local_gc(fctx, builder_kind)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_local_set_gc(buf, b_idx)
          emit_local_get_gc(buf, b_idx)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          let idx_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          if idx_kind == GcValKind::I64 {
            emit_i32_wrap_i64_gc(buf)
          }
          emit_struct_set_gc(buf, builder_type, 0)
          emit_i32_const_gc(buf, 0)
        }
        "ArrayBuilder::new" => {
          // Create struct { len: i32, data: ref array<eqref> }.
          // Default to eqref element storage so the same builder
          // shape works for both primitive (`ArrayBuilder[Int]`,
          // boxed on push via `emit_coerce_top_gc`) and reference
          // (`ArrayBuilder[Json]`) element types. Explicit
          // `ArrayBuilder[T]` annotations still pick `T`'s exact
          // kind via the `gc_val_kind_from_type` path.
          let init_cap = 8
          let arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::EqRef,
          )
          let builder_fields : Array[GcValKind] = [
            GcValKind::I32,
            GcValKind::Ref(arr_type),
          ]
          let builder_type = ensure_struct_type(
            ctx.types,
            ctx.struct_type_index,
            builder_fields,
          )
          emit_i32_const_gc(buf, 0)
          emit_i32_const_gc(buf, init_cap)
          emit_array_new_default_gc(buf, arr_type)
          emit_struct_new_gc(buf, builder_type)
        }
        "Array::with_capacity" => {
          // Same struct layout as ArrayBuilder. Caller-supplied
          // capacity is used for the initial data allocation; len=0.
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("Array::with_capacity arity")
          }
          let arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::I64,
          )
          let builder_fields : Array[GcValKind] = [
            GcValKind::I32,
            GcValKind::Ref(arr_type),
          ]
          let builder_type = ensure_struct_type(
            ctx.types,
            ctx.struct_type_index,
            builder_fields,
          )
          // len = 0
          emit_i32_const_gc(buf, 0)
          // data = array.new_default(cap)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          let cap_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          if cap_kind == GcValKind::I64 {
            emit_i32_wrap_i64_gc(buf)
          }
          emit_array_new_default_gc(buf, arr_type)
          emit_struct_new_gc(buf, builder_type)
        }
        "ArrayBuilder::push" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("ArrayBuilder::push arity")
          }
          let builder_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let builder_type = match builder_kind {
            GcValKind::Ref(idx) => idx
            _ => {
              // Default ArrayBuilder type: {len: i32, data: ref array<i64>}
              let arr_type = ensure_array_type(
                ctx.types,
                ctx.array_type_index,
                GcValKind::I64,
              )
              ensure_struct_type(ctx.types, ctx.struct_type_index, [
                GcValKind::I32,
                GcValKind::Ref(arr_type),
              ])
            }
          }
          let arr_type = match ctx.types[builder_type] {
            GcTypeDef::Struct(fields~) =>
              match fields[1] {
                GcValKind::Ref(idx) => idx
                _ =>
                  ensure_array_type(
                    ctx.types,
                    ctx.array_type_index,
                    GcValKind::I64,
                  )
              }
            _ =>
              ensure_array_type(ctx.types, ctx.array_type_index, GcValKind::I64)
          }
          compile_struct_array_push_gc(
            ctx,
            fctx,
            buf,
            pos_args[0],
            pos_args[1],
            builder_kind,
            builder_type,
            arr_type,
          )
        }
        "ArrayBuilder::freeze" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("ArrayBuilder::freeze arity")
          }
          let builder_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let builder_type = match builder_kind {
            GcValKind::Ref(idx) => idx
            _ => {
              let arr_type = ensure_array_type(
                ctx.types,
                ctx.array_type_index,
                GcValKind::I64,
              )
              ensure_struct_type(ctx.types, ctx.struct_type_index, [
                GcValKind::I32,
                GcValKind::Ref(arr_type),
              ])
            }
          }
          let arr_type = match ctx.types[builder_type] {
            GcTypeDef::Struct(fields~) =>
              match fields[1] {
                GcValKind::Ref(idx) => idx
                _ =>
                  ensure_array_type(
                    ctx.types,
                    ctx.array_type_index,
                    GcValKind::I64,
                  )
              }
            _ =>
              ensure_array_type(ctx.types, ctx.array_type_index, GcValKind::I64)
          }
          let b_idx = alloc_local_gc(fctx, builder_kind)
          let len_l = alloc_local_gc(fctx, GcValKind::I32)
          let src_l = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
          let dst_l = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
          let i_l = alloc_local_gc(fctx, GcValKind::I32)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_local_set_gc(buf, b_idx)
          emit_local_get_gc(buf, b_idx)
          emit_struct_get_gc(buf, builder_type, 0)
          emit_local_set_gc(buf, len_l)
          emit_local_get_gc(buf, b_idx)
          emit_struct_get_gc(buf, builder_type, 1)
          emit_local_set_gc(buf, src_l)
          emit_local_get_gc(buf, len_l)
          emit_array_new_default_gc(buf, arr_type)
          emit_local_set_gc(buf, dst_l)
          emit_i32_const_gc(buf, 0)
          emit_local_set_gc(buf, i_l)
          emit_block_gc(buf, None)
          emit_loop_gc(buf, None)
          emit_local_get_gc(buf, i_l)
          emit_local_get_gc(buf, len_l)
          emit_i32_ge_s_gc(buf)
          emit_br_if_gc(buf, 1)
          emit_local_get_gc(buf, dst_l)
          emit_local_get_gc(buf, i_l)
          emit_local_get_gc(buf, src_l)
          emit_local_get_gc(buf, i_l)
          emit_array_get_gc(buf, arr_type)
          emit_array_set_gc(buf, arr_type)
          emit_local_get_gc(buf, i_l)
          emit_i32_const_gc(buf, 1)
          emit_i32_add_gc(buf)
          emit_local_set_gc(buf, i_l)
          emit_br_gc(buf, 0)
          emit_end_gc(buf)
          emit_end_gc(buf)
          emit_local_get_gc(buf, dst_l)
        }
        // Issue #414: StringBuilder. Layout = { len: i32, data: ref
        // array<Ref(string_type)> }. `push` appends a String reference,
        // growing the data array if needed. `freeze` concatenates all
        // collected strings into a single fresh String.
        "StringBuilder::new" => {
          let init_cap = 8
          let arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::Ref(ctx.string_type),
          )
          let builder_fields : Array[GcValKind] = [
            GcValKind::I32,
            GcValKind::Ref(arr_type),
          ]
          let builder_type = ensure_struct_type(
            ctx.types,
            ctx.struct_type_index,
            builder_fields,
          )
          let _ = builder_type
          emit_i32_const_gc(buf, 0)
          emit_i32_const_gc(buf, init_cap)
          emit_array_new_default_gc(buf, arr_type)
          emit_struct_new_gc(buf, builder_type)
        }
        "StringBuilder::push" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("StringBuilder::push arity")
          }
          let arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::Ref(ctx.string_type),
          )
          let builder_fields : Array[GcValKind] = [
            GcValKind::I32,
            GcValKind::Ref(arr_type),
          ]
          let builder_type = ensure_struct_type(
            ctx.types,
            ctx.struct_type_index,
            builder_fields,
          )
          let builder_kind = GcValKind::Ref(builder_type)
          let b_l = alloc_local_gc(fctx, builder_kind)
          let len_l = alloc_local_gc(fctx, GcValKind::I32)
          let cap_l = alloc_local_gc(fctx, GcValKind::I32)
          let data_l = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
          let new_data_l = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
          let i_l = alloc_local_gc(fctx, GcValKind::I32)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_local_set_gc(buf, b_l)
          emit_local_get_gc(buf, b_l)
          emit_struct_get_gc(buf, builder_type, 0)
          emit_local_set_gc(buf, len_l)
          emit_local_get_gc(buf, b_l)
          emit_struct_get_gc(buf, builder_type, 1)
          emit_local_tee_gc(buf, data_l)
          emit_array_len_gc(buf)
          emit_local_set_gc(buf, cap_l)
          // grow if needed
          emit_local_get_gc(buf, len_l)
          emit_local_get_gc(buf, cap_l)
          emit_i32_ge_s_gc(buf)
          emit_if_gc(buf, None)
          // new_cap = max(cap * 2, 1)
          emit_local_get_gc(buf, cap_l)
          emit_i32_const_gc(buf, 2)
          emit_i32_mul_gc(buf)
          emit_local_tee_gc(buf, cap_l)
          emit_i32_const_gc(buf, 0)
          emit_i32_eq_gc(buf)
          emit_if_gc(buf, Some(GcValKind::I32))
          emit_i32_const_gc(buf, 1)
          emit_else_gc(buf)
          emit_local_get_gc(buf, cap_l)
          emit_end_gc(buf)
          emit_array_new_default_gc(buf, arr_type)
          emit_local_set_gc(buf, new_data_l)
          emit_i32_const_gc(buf, 0)
          emit_local_set_gc(buf, i_l)
          emit_block_gc(buf, None)
          emit_loop_gc(buf, None)
          emit_local_get_gc(buf, i_l)
          emit_local_get_gc(buf, len_l)
          emit_i32_ge_s_gc(buf)
          emit_br_if_gc(buf, 1)
          emit_local_get_gc(buf, new_data_l)
          emit_local_get_gc(buf, i_l)
          emit_local_get_gc(buf, data_l)
          emit_local_get_gc(buf, i_l)
          emit_array_get_gc(buf, arr_type)
          emit_array_set_gc(buf, arr_type)
          emit_local_get_gc(buf, i_l)
          emit_i32_const_gc(buf, 1)
          emit_i32_add_gc(buf)
          emit_local_set_gc(buf, i_l)
          emit_br_gc(buf, 0)
          emit_end_gc(buf)
          emit_end_gc(buf)
          emit_local_get_gc(buf, b_l)
          emit_local_get_gc(buf, new_data_l)
          emit_struct_set_gc(buf, builder_type, 1)
          emit_local_get_gc(buf, new_data_l)
          emit_local_set_gc(buf, data_l)
          emit_end_gc(buf)
          // data[len] = value
          emit_local_get_gc(buf, data_l)
          emit_local_get_gc(buf, len_l)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_array_set_gc(buf, arr_type)
          // len += 1
          emit_local_get_gc(buf, b_l)
          emit_local_get_gc(buf, len_l)
          emit_i32_const_gc(buf, 1)
          emit_i32_add_gc(buf)
          emit_struct_set_gc(buf, builder_type, 0)
          // Unit result
          emit_i32_const_gc(buf, 0)
        }
        "StringBuilder::freeze" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("StringBuilder::freeze arity")
          }
          let arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::Ref(ctx.string_type),
          )
          let builder_fields : Array[GcValKind] = [
            GcValKind::I32,
            GcValKind::Ref(arr_type),
          ]
          let builder_type = ensure_struct_type(
            ctx.types,
            ctx.struct_type_index,
            builder_fields,
          )
          let b_l = alloc_local_gc(fctx, GcValKind::Ref(builder_type))
          let len_l = alloc_local_gc(fctx, GcValKind::I32)
          let data_l = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
          let total_l = alloc_local_gc(fctx, GcValKind::I32)
          let out_data_l = alloc_local_gc(
            fctx,
            GcValKind::Ref(ctx.array_i32_type),
          )
          let i_l = alloc_local_gc(fctx, GcValKind::I32)
          let cur_s_l = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
          let cur_len_l = alloc_local_gc(fctx, GcValKind::I32)
          let cur_data_l = alloc_local_gc(
            fctx,
            GcValKind::Ref(ctx.array_i32_type),
          )
          let write_l = alloc_local_gc(fctx, GcValKind::I32)
          let j_l = alloc_local_gc(fctx, GcValKind::I32)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_local_set_gc(buf, b_l)
          emit_local_get_gc(buf, b_l)
          emit_struct_get_gc(buf, builder_type, 0)
          emit_local_set_gc(buf, len_l)
          emit_local_get_gc(buf, b_l)
          emit_struct_get_gc(buf, builder_type, 1)
          emit_local_set_gc(buf, data_l)
          // Pass 1: total = sum of each string's len
          emit_i32_const_gc(buf, 0)
          emit_local_set_gc(buf, total_l)
          emit_i32_const_gc(buf, 0)
          emit_local_set_gc(buf, i_l)
          emit_block_gc(buf, None)
          emit_loop_gc(buf, None)
          emit_local_get_gc(buf, i_l)
          emit_local_get_gc(buf, len_l)
          emit_i32_ge_s_gc(buf)
          emit_br_if_gc(buf, 1)
          emit_local_get_gc(buf, data_l)
          emit_local_get_gc(buf, i_l)
          emit_array_get_gc(buf, arr_type)
          emit_local_tee_gc(buf, cur_s_l)
          emit_struct_get_gc(buf, ctx.string_type, 0)
          emit_local_get_gc(buf, total_l)
          emit_i32_add_gc(buf)
          emit_local_set_gc(buf, total_l)
          emit_local_get_gc(buf, i_l)
          emit_i32_const_gc(buf, 1)
          emit_i32_add_gc(buf)
          emit_local_set_gc(buf, i_l)
          emit_br_gc(buf, 0)
          emit_end_gc(buf)
          emit_end_gc(buf)
          // Allocate output array<i32> of total_l codepoints
          emit_local_get_gc(buf, total_l)
          emit_array_new_default_gc(buf, ctx.array_i32_type)
          emit_local_set_gc(buf, out_data_l)
          // Pass 2: copy each string's data
          emit_i32_const_gc(buf, 0)
          emit_local_set_gc(buf, write_l)
          emit_i32_const_gc(buf, 0)
          emit_local_set_gc(buf, i_l)
          emit_block_gc(buf, None)
          emit_loop_gc(buf, None)
          emit_local_get_gc(buf, i_l)
          emit_local_get_gc(buf, len_l)
          emit_i32_ge_s_gc(buf)
          emit_br_if_gc(buf, 1)
          emit_local_get_gc(buf, data_l)
          emit_local_get_gc(buf, i_l)
          emit_array_get_gc(buf, arr_type)
          emit_local_set_gc(buf, cur_s_l)
          emit_local_get_gc(buf, cur_s_l)
          emit_struct_get_gc(buf, ctx.string_type, 0)
          emit_local_set_gc(buf, cur_len_l)
          emit_local_get_gc(buf, cur_s_l)
          emit_struct_get_gc(buf, ctx.string_type, 1)
          emit_local_set_gc(buf, cur_data_l)
          emit_i32_const_gc(buf, 0)
          emit_local_set_gc(buf, j_l)
          emit_block_gc(buf, None)
          emit_loop_gc(buf, None)
          emit_local_get_gc(buf, j_l)
          emit_local_get_gc(buf, cur_len_l)
          emit_i32_ge_s_gc(buf)
          emit_br_if_gc(buf, 1)
          emit_local_get_gc(buf, out_data_l)
          emit_local_get_gc(buf, write_l)
          emit_local_get_gc(buf, j_l)
          emit_i32_add_gc(buf)
          emit_local_get_gc(buf, cur_data_l)
          emit_local_get_gc(buf, j_l)
          emit_array_get_gc(buf, ctx.array_i32_type)
          emit_array_set_gc(buf, ctx.array_i32_type)
          emit_local_get_gc(buf, j_l)
          emit_i32_const_gc(buf, 1)
          emit_i32_add_gc(buf)
          emit_local_set_gc(buf, j_l)
          emit_br_gc(buf, 0)
          emit_end_gc(buf)
          emit_end_gc(buf)
          emit_local_get_gc(buf, write_l)
          emit_local_get_gc(buf, cur_len_l)
          emit_i32_add_gc(buf)
          emit_local_set_gc(buf, write_l)
          emit_local_get_gc(buf, i_l)
          emit_i32_const_gc(buf, 1)
          emit_i32_add_gc(buf)
          emit_local_set_gc(buf, i_l)
          emit_br_gc(buf, 0)
          emit_end_gc(buf)
          emit_end_gc(buf)
          // Construct result String { len, data }
          emit_local_get_gc(buf, total_l)
          emit_local_get_gc(buf, out_data_l)
          emit_struct_new_gc(buf, ctx.string_type)
        }
        "MapBuilder::new" => {
          // Map: struct { len: i32, keys: ref array<eqref>, vals: ref array<eqref> }
          let init_cap = 8
          let key_arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::EqRef,
          )
          let val_arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::EqRef,
          )
          let builder_fields : Array[GcValKind] = [
            GcValKind::I32,
            GcValKind::Ref(key_arr_type),
            GcValKind::Ref(val_arr_type),
          ]
          let builder_type = ensure_struct_type(
            ctx.types,
            ctx.struct_type_index,
            builder_fields,
          )
          emit_i32_const_gc(buf, 0) // len = 0
          emit_i32_const_gc(buf, init_cap)
          emit_array_new_default_gc(buf, key_arr_type)
          emit_i32_const_gc(buf, init_cap)
          emit_array_new_default_gc(buf, val_arr_type)
          emit_struct_new_gc(buf, builder_type)
        }
        "MapBuilder::set" => {
          // MapBuilder::set(builder, key, value)
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("MapBuilder::set arity")
          }
          let key_arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::EqRef,
          )
          let val_arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::EqRef,
          )
          let builder_fields : Array[GcValKind] = [
            GcValKind::I32,
            GcValKind::Ref(key_arr_type),
            GcValKind::Ref(val_arr_type),
          ]
          let builder_type = ensure_struct_type(
            ctx.types,
            ctx.struct_type_index,
            builder_fields,
          )
          let b_idx = alloc_local_gc(fctx, GcValKind::Ref(builder_type))
          let len_l = alloc_local_gc(fctx, GcValKind::I32)
          let cap_l = alloc_local_gc(fctx, GcValKind::I32)
          let keys_l = alloc_local_gc(fctx, GcValKind::Ref(key_arr_type))
          let vals_l = alloc_local_gc(fctx, GcValKind::Ref(val_arr_type))
          let new_keys = alloc_local_gc(fctx, GcValKind::Ref(key_arr_type))
          let new_vals = alloc_local_gc(fctx, GcValKind::Ref(val_arr_type))
          let i_l = alloc_local_gc(fctx, GcValKind::I32)
          let key_l = alloc_local_gc(fctx, GcValKind::EqRef)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_local_set_gc(buf, b_idx)
          // Box key to eqref (handles int keys, string keys, etc.)
          let key_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_box_top_for_ref_kind_gc(ctx, buf, key_kind, GcValKind::EqRef)
          emit_local_set_gc(buf, key_l)
          emit_local_get_gc(buf, b_idx)
          emit_struct_get_gc(buf, builder_type, 0)
          emit_local_set_gc(buf, len_l)
          emit_local_get_gc(buf, b_idx)
          emit_struct_get_gc(buf, builder_type, 1)
          emit_local_set_gc(buf, keys_l)
          emit_local_get_gc(buf, b_idx)
          emit_struct_get_gc(buf, builder_type, 2)
          emit_local_set_gc(buf, vals_l)
          emit_local_get_gc(buf, keys_l)
          emit_array_len_gc(buf)
          emit_local_set_gc(buf, cap_l)
          let found_l = alloc_local_gc(fctx, GcValKind::I32) // 1 if found
          let val_l = alloc_local_gc(fctx, GcValKind::EqRef)
          // Compile value once, box to eqref, and save to local
          let val_kind = infer_expr_kind_gc(ctx, fctx, pos_args[2])
          compile_expr_gc(ctx, fctx, buf, pos_args[2])
          emit_box_top_for_ref_kind_gc(ctx, buf, val_kind, GcValKind::EqRef)
          emit_local_set_gc(buf, val_l)
          // Search for existing key
          emit_i32_const_gc(buf, 0)
          emit_local_set_gc(buf, i_l)
          emit_i32_const_gc(buf, 0)
          emit_local_set_gc(buf, found_l)
          // block $done
          emit_block_gc(buf, None)
          // loop $search
          emit_loop_gc(buf, None)
          emit_local_get_gc(buf, i_l)
          emit_local_get_gc(buf, len_l)
          emit_i32_ge_s_gc(buf)
          emit_br_if_gc(buf, 1) // br $done
          let cur_key_l = alloc_local_gc(fctx, GcValKind::EqRef)
          emit_local_get_gc(buf, keys_l)
          emit_local_get_gc(buf, i_l)
          emit_array_get_gc(buf, key_arr_type)
          emit_local_set_gc(buf, cur_key_l)
          emit_map_key_eq_gc(ctx, fctx, buf, cur_key_l, key_l)
          emit_if_gc(buf, None)
          // Found: update value and break
          emit_local_get_gc(buf, vals_l)
          emit_local_get_gc(buf, i_l)
          emit_local_get_gc(buf, val_l)
          emit_array_set_gc(buf, val_arr_type)
          emit_i32_const_gc(buf, 1)
          emit_local_set_gc(buf, found_l)
          emit_br_gc(buf, 2) // br $done
          emit_end_gc(buf) // end if
          emit_local_get_gc(buf, i_l)
          emit_i32_const_gc(buf, 1)
          emit_i32_add_gc(buf)
          emit_local_set_gc(buf, i_l)
          emit_br_gc(buf, 0) // br $search
          emit_end_gc(buf) // end loop
          emit_end_gc(buf) // end $done
          // If not found, append
          emit_local_get_gc(buf, found_l)
          emit_i32_eqz_gc(buf)
          emit_if_gc(buf, None)
          // Grow if needed
          emit_local_get_gc(buf, len_l)
          emit_local_get_gc(buf, cap_l)
          emit_i32_ge_s_gc(buf)
          emit_if_gc(buf, None)
          emit_local_get_gc(buf, cap_l)
          emit_i32_const_gc(buf, 2)
          emit_i32_mul_gc(buf)
          emit_array_new_default_gc(buf, key_arr_type)
          emit_local_set_gc(buf, new_keys)
          emit_local_get_gc(buf, cap_l)
          emit_i32_const_gc(buf, 2)
          emit_i32_mul_gc(buf)
          emit_array_new_default_gc(buf, val_arr_type)
          emit_local_set_gc(buf, new_vals)
          // copy old to new
          emit_i32_const_gc(buf, 0)
          emit_local_set_gc(buf, i_l)
          emit_block_gc(buf, None)
          emit_loop_gc(buf, None)
          emit_local_get_gc(buf, i_l)
          emit_local_get_gc(buf, len_l)
          emit_i32_ge_s_gc(buf)
          emit_br_if_gc(buf, 1)
          emit_local_get_gc(buf, new_keys)
          emit_local_get_gc(buf, i_l)
          emit_local_get_gc(buf, keys_l)
          emit_local_get_gc(buf, i_l)
          emit_array_get_gc(buf, key_arr_type)
          emit_array_set_gc(buf, key_arr_type)
          emit_local_get_gc(buf, new_vals)
          emit_local_get_gc(buf, i_l)
          emit_local_get_gc(buf, vals_l)
          emit_local_get_gc(buf, i_l)
          emit_array_get_gc(buf, val_arr_type)
          emit_array_set_gc(buf, val_arr_type)
          emit_local_get_gc(buf, i_l)
          emit_i32_const_gc(buf, 1)
          emit_i32_add_gc(buf)
          emit_local_set_gc(buf, i_l)
          emit_br_gc(buf, 0)
          emit_end_gc(buf) // end copy loop
          emit_end_gc(buf) // end copy block
          emit_local_get_gc(buf, b_idx)
          emit_local_get_gc(buf, new_keys)
          emit_struct_set_gc(buf, builder_type, 1)
          emit_local_get_gc(buf, b_idx)
          emit_local_get_gc(buf, new_vals)
          emit_struct_set_gc(buf, builder_type, 2)
          emit_local_get_gc(buf, new_keys)
          emit_local_set_gc(buf, keys_l)
          emit_local_get_gc(buf, new_vals)
          emit_local_set_gc(buf, vals_l)
          emit_end_gc(buf) // end if grow
          // Append: keys[len] = key, vals[len] = val
          emit_local_get_gc(buf, keys_l)
          emit_local_get_gc(buf, len_l)
          emit_local_get_gc(buf, key_l)
          emit_array_set_gc(buf, key_arr_type)
          emit_local_get_gc(buf, vals_l)
          emit_local_get_gc(buf, len_l)
          emit_local_get_gc(buf, val_l)
          emit_array_set_gc(buf, val_arr_type)
          // len++
          emit_local_get_gc(buf, b_idx)
          emit_local_get_gc(buf, len_l)
          emit_i32_const_gc(buf, 1)
          emit_i32_add_gc(buf)
          emit_struct_set_gc(buf, builder_type, 0)
          emit_end_gc(buf) // end if !found
          emit_i32_const_gc(buf, 0) // return Unit
        }
        "MapBuilder::freeze" => {
          // freeze returns builder as-is (same representation)
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("MapBuilder::freeze arity")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
        }
        _ => {
          let handled_direct_rec = match fctx.direct_rec_call_name {
            Some(rec_name) if name == rec_name => {
              let call_param_kinds = match
                ctx.types[fctx.direct_rec_call_type_idx] {
                GcTypeDef::Func(params~, ..) => params
                _ =>
                  raise WasmGenError::Unsupported("direct recursive call type")
              }
              emit_local_get_gc(buf, 0)
              for i in 0..<pos_args.length() {
                let arg = pos_args[i]
                let arg_kind = infer_expr_kind_gc(ctx, fctx, arg)
                compile_expr_gc(ctx, fctx, buf, arg)
                if i + 1 < call_param_kinds.length() {
                  emit_coerce_top_gc(
                    ctx,
                    buf,
                    arg_kind,
                    call_param_kinds[i + 1],
                  )
                }
              }
              emit_call_gc(buf, fctx.direct_rec_call_func_idx)
              true
            }
            _ => false
          }
          if !handled_direct_rec {
            match ctx.func_indices.get(name) {
              Some(idx) => {
                // Skip arity check — bundler may produce mismatched counts
                match ctx.func_param_kinds.get(name) {
                  Some(param_kinds) =>
                    for i in 0..<pos_args.length() {
                      let arg = pos_args[i]
                      let arg_kind = infer_expr_kind_gc(ctx, fctx, arg)
                      compile_expr_gc(ctx, fctx, buf, arg)
                      if i < param_kinds.length() {
                        emit_coerce_top_gc(ctx, buf, arg_kind, param_kinds[i])
                      }
                    }
                  None =>
                    for arg in pos_args {
                      compile_expr_gc(ctx, fctx, buf, arg)
                    }
                }
                emit_call_gc(buf, idx)
              }
              None =>
                if ctx.enum_ctor_tags.contains(name) {
                  // Enum constructor call
                  let tag = ctx.enum_ctor_tags[name]
                  let type_idx = ctx.enum_ctor_type_indices[name]
                  let payload_kinds = ctx.enum_ctor_field_kinds[name]
                  emit_i32_const_gc(buf, tag)
                  for i in 0..<pos_args.length() {
                    let arg = pos_args[i]
                    let arg_kind = infer_expr_kind_gc(ctx, fctx, arg)
                    compile_expr_gc(ctx, fctx, buf, arg)
                    if i < payload_kinds.length() {
                      emit_coerce_top_gc(ctx, buf, arg_kind, payload_kinds[i])
                    }
                  }
                  emit_struct_new_gc(buf, type_idx)
                } else {
                  // Check local closure bindings first (they shadow field accessors)
                  match fctx.closure_call_types.get(name) {
                    Some(fn_type_idx) =>
                      match fctx.locals.get(name) {
                        Some(closure_info) => {
                          let closure_struct_type = match closure_info.kind {
                            GcValKind::Ref(idx) => idx
                            _ => raise WasmGenError::Unsupported("closure kind")
                          }
                          let call_param_kinds = match ctx.types[fn_type_idx] {
                            GcTypeDef::Func(params~, ..) => params
                            _ =>
                              raise WasmGenError::Unsupported(
                                "closure call type",
                              )
                          }
                          emit_local_get_gc(buf, closure_info.idx)
                          emit_struct_get_gc(buf, closure_struct_type, 1)
                          for i in 0..<pos_args.length() {
                            let arg = pos_args[i]
                            let arg_kind = infer_expr_kind_gc(ctx, fctx, arg)
                            compile_expr_gc(ctx, fctx, buf, arg)
                            if i + 1 < call_param_kinds.length() {
                              emit_coerce_top_gc(
                                ctx,
                                buf,
                                arg_kind,
                                call_param_kinds[i + 1],
                              )
                            }
                          }
                          emit_local_get_gc(buf, closure_info.idx)
                          emit_struct_get_gc(buf, closure_struct_type, 0)
                          emit_call_ref_gc(buf, fn_type_idx)
                        }
                        None => {
                          // Closure type known but not in locals — trap
                          for arg in pos_args {
                            compile_expr_gc(ctx, fctx, buf, arg)
                            emit_drop_gc(buf)
                          }
                          emit_unreachable_gc(buf)
                        }
                      }
                    None =>
                      if is_gc_builtin_name(name) {
                        // Builtin/effect call — emit unreachable (trap at runtime)
                        for arg in pos_args {
                          compile_expr_gc(ctx, fctx, buf, arg)
                          emit_drop_gc(buf)
                        }
                        emit_unreachable_gc(buf)
                      } else {
                        // Try to derive closure type from local's struct kind
                        match fctx.locals.get(name) {
                          Some(closure_info) =>
                            match closure_info.kind {
                              GcValKind::Ref(struct_idx) =>
                                match ctx.types[struct_idx] {
                                  GcTypeDef::Struct(fields~) =>
                                    if fields.length() == 2 {
                                      match fields[0] {
                                        GcValKind::Ref(fn_idx) =>
                                          match ctx.types[fn_idx] {
                                            GcTypeDef::Func(
                                              params=call_param_kinds,
                                              ..
                                            ) => {
                                              emit_local_get_gc(
                                                buf,
                                                closure_info.idx,
                                              )
                                              emit_struct_get_gc(
                                                buf, struct_idx, 1,
                                              )
                                              for i in 0..<pos_args.length() {
                                                let arg = pos_args[i]
                                                let arg_kind = infer_expr_kind_gc(
                                                  ctx, fctx, arg,
                                                )
                                                compile_expr_gc(
                                                  ctx, fctx, buf, arg,
                                                )
                                                if i + 1 <
                                                  call_param_kinds.length() {
                                                  emit_coerce_top_gc(
                                                    ctx,
                                                    buf,
                                                    arg_kind,
                                                    call_param_kinds[i + 1],
                                                  )
                                                }
                                              }
                                              emit_local_get_gc(
                                                buf,
                                                closure_info.idx,
                                              )
                                              emit_struct_get_gc(
                                                buf, struct_idx, 0,
                                              )
                                              emit_call_ref_gc(buf, fn_idx)
                                            }
                                            _ => {
                                              for arg in pos_args {
                                                compile_expr_gc(
                                                  ctx, fctx, buf, arg,
                                                )
                                                emit_drop_gc(buf)
                                              }
                                              emit_unreachable_gc(buf)
                                            }
                                          }
                                        _ => {
                                          for arg in pos_args {
                                            compile_expr_gc(ctx, fctx, buf, arg)
                                            emit_drop_gc(buf)
                                          }
                                          emit_unreachable_gc(buf)
                                        }
                                      }
                                    } else {
                                      for arg in pos_args {
                                        compile_expr_gc(ctx, fctx, buf, arg)
                                        emit_drop_gc(buf)
                                      }
                                      emit_unreachable_gc(buf)
                                    }
                                  _ => {
                                    for arg in pos_args {
                                      compile_expr_gc(ctx, fctx, buf, arg)
                                      emit_drop_gc(buf)
                                    }
                                    emit_unreachable_gc(buf)
                                  }
                                }
                              _ => {
                                for arg in pos_args {
                                  compile_expr_gc(ctx, fctx, buf, arg)
                                  emit_drop_gc(buf)
                                }
                                emit_unreachable_gc(buf)
                              }
                            }
                          None =>
                            if pos_args.length() == 1 &&
                              try_compile_struct_field_get_gc(
                                ctx,
                                fctx,
                                buf,
                                name,
                                pos_args[0],
                              ) {
                              // Named struct field access: field_name(record) → struct.get
                              () // already compiled by try_compile_struct_field_get_gc
                            } else {
                              for arg in pos_args {
                                compile_expr_gc(ctx, fctx, buf, arg)
                                emit_drop_gc(buf)
                              }
                              emit_unreachable_gc(buf)
                            }
                        }
                      }
                  }
                }
            }
          }
        }
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      compile_expr_gc(ctx, fctx, buf, cond)
      let then_kind = infer_block_kind_gc(ctx, fctx, then_body)
      let else_kind = infer_block_kind_gc(ctx, fctx, else_body)
      let result_kind = if then_kind == else_kind {
        then_kind
      } else {
        gc_common_kind(then_kind, else_kind)
      }
      emit_if_gc(buf, Some(result_kind))
      // Issue #417: branch-then / branch-else coverage points.
      emit_coverage_gc(ctx, buf, WasmCoveragePointKind::BranchIfThen, span)
      compile_block_expr_gc(ctx, fctx, buf, then_body)
      emit_coerce_top_gc(ctx, buf, then_kind, result_kind)
      emit_else_gc(buf)
      emit_coverage_gc(ctx, buf, WasmCoveragePointKind::BranchIfElse, span)
      compile_block_expr_gc(ctx, fctx, buf, else_body)
      emit_coerce_top_gc(ctx, buf, else_kind, result_kind)
      emit_end_gc(buf)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      if arms.length() == 0 {
        raise WasmGenError::Unsupported("match arms")
      }
      let scrut_kind = infer_expr_kind_gc(ctx, fctx, scrutinee)
      let scrut_idx = alloc_local_gc(fctx, scrut_kind)
      compile_expr_gc(ctx, fctx, buf, scrutinee)
      emit_local_set_gc(buf, scrut_idx)
      let saved = clone_locals_gc(fctx.locals)
      bind_pat_kinds_gc(ctx, fctx, scrut_kind, arms[0].pat)
      let mut result_kind = infer_expr_kind_gc(ctx, fctx, arms[0].expr)
      restore_locals_gc(fctx, saved)
      for i in 1..<arms.length() {
        let saved_arm = clone_locals_gc(fctx.locals)
        bind_pat_kinds_gc(ctx, fctx, scrut_kind, arms[i].pat)
        let arm_kind = infer_expr_kind_gc(ctx, fctx, arms[i].expr)
        restore_locals_gc(fctx, saved_arm)
        if arm_kind != result_kind {
          result_kind = gc_common_kind(result_kind, arm_kind)
        }
      }
      compile_match_chain_gc(
        ctx, fctx, buf, scrut_idx, scrut_kind, arms, 0, result_kind,
      )
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      compile_block_expr_gc(ctx, fctx, buf, body)
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      emit_block_gc(buf, None)
      emit_loop_gc(buf, None)
      compile_expr_gc(ctx, fctx, buf, cond)
      emit_i32_const_gc(buf, 0)
      emit_i32_eq_gc(buf)
      emit_br_if_gc(buf, 1)
      for i in 0..<body.stmts.length() {
        compile_stmt_gc(ctx, fctx, buf, body.stmts[i], false)
      }
      emit_br_gc(buf, 0)
      emit_end_gc(buf)
      emit_end_gc(buf)
      emit_i32_const_gc(buf, 0)
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let _ = span
      if @core.is_string_for_in(span.start) {
        // String for-in: iterate char codes (I64)
        let (elem_kind, body_kind) = infer_string_for_in_parts_gc(
          ctx, fctx, value_name, index_name, body,
        )
        let result_type_idx = ensure_array_type(
          ctx.types,
          ctx.array_type_index,
          body_kind,
        )
        let str_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
        let data_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
        let len_idx = alloc_local_gc(fctx, GcValKind::I32)
        let result_idx = alloc_local_gc(fctx, GcValKind::Ref(result_type_idx))
        let i_idx = alloc_local_gc(fctx, GcValKind::I32)
        // Evaluate string iterable
        compile_expr_gc(ctx, fctx, buf, iterable)
        emit_local_set_gc(buf, str_idx)
        // Get string length
        emit_local_get_gc(buf, str_idx)
        emit_struct_get_gc(buf, ctx.string_type, 0) // length field
        emit_local_set_gc(buf, len_idx)
        // Get string data array
        emit_local_get_gc(buf, str_idx)
        emit_struct_get_gc(buf, ctx.string_type, 1) // data field
        emit_local_set_gc(buf, data_idx)
        // Allocate result array
        emit_local_get_gc(buf, len_idx)
        emit_array_new_default_gc(buf, result_type_idx)
        emit_local_set_gc(buf, result_idx)
        // Initialize counter
        emit_i32_const_gc(buf, 0)
        emit_local_set_gc(buf, i_idx)
        let saved_locals = clone_locals_gc(fctx.locals)
        let value_idx = bind_local_gc(fctx, value_name, elem_kind)
        let index_idx : Int? = match index_name {
          Some(name) => Some(bind_local_gc(fctx, name, GcValKind::I32))
          None => None
        }
        // Loop
        emit_block_gc(buf, None)
        emit_loop_gc(buf, None)
        emit_local_get_gc(buf, i_idx)
        emit_local_get_gc(buf, len_idx)
        emit_i32_ge_s_gc(buf)
        emit_br_if_gc(buf, 1)
        // Get char code: data[i] as i64
        emit_local_get_gc(buf, data_idx)
        emit_local_get_gc(buf, i_idx)
        emit_array_get_gc(buf, ctx.array_i32_type)
        emit_i64_extend_i32_s_gc(buf) // char code as I64
        emit_local_set_gc(buf, value_idx)
        // Optional index binding
        match index_idx {
          Some(idx) => {
            emit_local_get_gc(buf, i_idx)
            emit_local_set_gc(buf, idx)
          }
          None => ()
        }
        // Store body result
        emit_local_get_gc(buf, result_idx)
        emit_local_get_gc(buf, i_idx)
        compile_block_expr_gc(ctx, fctx, buf, body)
        emit_array_set_gc(buf, result_type_idx)
        // Increment
        emit_local_get_gc(buf, i_idx)
        emit_i32_const_gc(buf, 1)
        emit_i32_add_gc(buf)
        emit_local_set_gc(buf, i_idx)
        emit_br_gc(buf, 0)
        emit_end_gc(buf)
        emit_end_gc(buf)
        restore_locals_gc(fctx, saved_locals)
        emit_local_get_gc(buf, result_idx)
      } else {
        // Array for-in (existing logic)
        let (iterable_type_idx, iterable_elem_kind, body_kind) = infer_for_in_parts_gc(
          ctx, fctx, value_name, index_name, iterable, body,
        )
        let result_type_idx = ensure_array_type(
          ctx.types,
          ctx.array_type_index,
          body_kind,
        )
        let iterable_idx = alloc_local_gc(
          fctx,
          GcValKind::Ref(iterable_type_idx),
        )
        let len_idx = alloc_local_gc(fctx, GcValKind::I32)
        let result_idx = alloc_local_gc(fctx, GcValKind::Ref(result_type_idx))
        let i_idx = alloc_local_gc(fctx, GcValKind::I32)
        compile_expr_gc(ctx, fctx, buf, iterable)
        emit_local_set_gc(buf, iterable_idx)
        emit_local_get_gc(buf, iterable_idx)
        emit_array_len_gc(buf)
        emit_local_set_gc(buf, len_idx)
        emit_local_get_gc(buf, len_idx)
        emit_array_new_default_gc(buf, result_type_idx)
        emit_local_set_gc(buf, result_idx)
        emit_i32_const_gc(buf, 0)
        emit_local_set_gc(buf, i_idx)
        let saved_locals = clone_locals_gc(fctx.locals)
        let value_idx = bind_local_gc(fctx, value_name, iterable_elem_kind)
        let index_idx : Int? = match index_name {
          Some(name) => Some(bind_local_gc(fctx, name, GcValKind::I32))
          None => None
        }
        emit_block_gc(buf, None)
        emit_loop_gc(buf, None)
        emit_local_get_gc(buf, i_idx)
        emit_local_get_gc(buf, len_idx)
        emit_i32_ge_s_gc(buf)
        emit_br_if_gc(buf, 1)
        emit_local_get_gc(buf, iterable_idx)
        emit_local_get_gc(buf, i_idx)
        emit_array_get_gc(buf, iterable_type_idx)
        emit_local_set_gc(buf, value_idx)
        match index_idx {
          Some(idx) => {
            emit_local_get_gc(buf, i_idx)
            emit_local_set_gc(buf, idx)
          }
          None => ()
        }
        emit_local_get_gc(buf, result_idx)
        emit_local_get_gc(buf, i_idx)
        compile_block_expr_gc(ctx, fctx, buf, body)
        emit_array_set_gc(buf, result_type_idx)
        emit_local_get_gc(buf, i_idx)
        emit_i32_const_gc(buf, 1)
        emit_i32_add_gc(buf)
        emit_local_set_gc(buf, i_idx)
        emit_br_gc(buf, 0)
        emit_end_gc(buf)
        emit_end_gc(buf)
        restore_locals_gc(fctx, saved_locals)
        emit_local_get_gc(buf, result_idx)
      }
    }
    @core.Expr::Fn(params~, ret~, body~, span=lambda_span, ..) => {
      let param_kinds : Array[GcValKind] = []
      for param in params {
        param_kinds.push(gc_val_kind_from_type(ctx, param.ty))
      }
      let bound : Map[String, Bool] = {}
      for param in params {
        bound[param.name] = true
      }
      let free : Map[String, Bool] = {}
      collect_free_vars_module_gc(body, bound, free)
      let rec_binding = fctx.current_rec_binding
      // Also capture closure-typed call targets (let rec self-reference)
      let call_names : Map[String, Bool] = {}
      collect_call_names_module_gc(body, call_names)
      for cname, _ in call_names {
        if fctx.closure_call_types.contains(cname) &&
          !bound.contains(cname) &&
          !free.contains(cname) {
          match rec_binding {
            Some(self_name) => if cname != self_name { free[cname] = true }
            None => free[cname] = true
          }
        }
      }
      let capture_names : Array[String] = []
      let capture_kinds : Array[GcValKind] = []
      let capture_indices : Array[Int] = []
      for name, _ in free {
        match fctx.locals.get(name) {
          Some(info) => {
            capture_names.push(name)
            capture_kinds.push(info.kind)
            capture_indices.push(info.idx)
          }
          None => ()
        }
      }
      let env_type_idx = ensure_struct_type(
        ctx.types,
        ctx.struct_type_index,
        if capture_kinds.length() > 0 {
          capture_kinds
        } else {
          []
        },
      )
      let result_kind = match ret {
        Some(ty) => gc_val_kind_from_type(ctx, ty)
        None => {
          let saved = clone_locals_gc(fctx.locals)
          for param in params {
            fctx.locals[param.name] = {
              idx: 0,
              kind: gc_val_kind_from_type(ctx, param.ty),
            }
          }
          for i in 0..<capture_names.length() {
            fctx.locals[capture_names[i]] = { idx: 0, kind: capture_kinds[i] }
          }
          let kind = infer_block_kind_gc(ctx, fctx, body)
          restore_locals_gc(fctx, saved)
          kind
        }
      }
      let (fn_type_idx, struct_type_idx) = ensure_closure_types_gc(
        ctx, param_kinds, result_kind,
      )
      let func_idx = ctx.num_regular_funcs + ctx.closure_lifted_funcs.length()
      // Propagate closure_call_types from parent so let-rec and
      // captured closures can be called inside the lifted body.
      let lifted_closure_types : Map[String, Int] = {}
      for k, v in fctx.closure_call_types {
        lifted_closure_types[k] = v
      }
      let lifted_fctx = GcFuncCtx::{
        locals: {},
        map_value_kinds: clone_kind_map_gc(fctx.map_value_kinds),
        array_builder_elem_hints: clone_kind_map_gc(
          fctx.array_builder_elem_hints,
        ),
        local_kinds: [],
        param_count: 1 + params.length(),
        closure_call_types: lifted_closure_types,
        current_rec_binding: None,
        enclosing_function_name: fctx.enclosing_function_name,
        direct_rec_call_name: rec_binding,
        direct_rec_call_func_idx: func_idx,
        direct_rec_call_type_idx: fn_type_idx,
      }
      for i in 0..<params.length() {
        let k = gc_val_kind_from_type(ctx, params[i].ty)
        lifted_fctx.locals[params[i].name] = { idx: i + 1, kind: k }
      }
      let lifted_buf = GcByteBuf::new()
      if capture_names.length() > 0 {
        let env_local = alloc_local_gc(
          lifted_fctx,
          GcValKind::Ref(env_type_idx),
        )
        emit_local_get_gc(lifted_buf, 0)
        emit_ref_cast_gc(lifted_buf, env_type_idx)
        emit_local_set_gc(lifted_buf, env_local)
        for i in 0..<capture_names.length() {
          let cap_local = bind_local_gc(
            lifted_fctx,
            capture_names[i],
            capture_kinds[i],
          )
          emit_local_get_gc(lifted_buf, env_local)
          emit_struct_get_gc(lifted_buf, env_type_idx, i)
          emit_local_set_gc(lifted_buf, cap_local)
        }
      }
      compile_block_expr_gc(ctx, lifted_fctx, lifted_buf, body)
      let lifted_sig_params : Array[GcValKind] = [GcValKind::AnyRef]
      for k in param_kinds {
        lifted_sig_params.push(k)
      }
      let lifted_sig = GcFuncSig::{
        params: lifted_sig_params,
        result: result_kind,
      }
      ctx.closure_lifted_funcs.push(GcWasmFunc::{
        sig: lifted_sig,
        locals: lifted_fctx.local_kinds,
        body: lifted_buf.to_array(),
        type_idx: fn_type_idx,
      })
      // Prefer the let-rec binding name (so a `let rec foo = ...` lambda
      // shows as `foo::lambda@N`), falling back to the enclosing
      // function's source name. If neither is available (top-level
      // lambda directly in `_start`), only the position is used.
      let parent_label = match rec_binding {
        Some(p) => Some(p)
        None => fctx.enclosing_function_name
      }
      let pos = format_lambda_position_gc(ctx, lambda_span.start)
      let lambda_label = match parent_label {
        Some(parent) => parent + "::lambda@" + pos
        None => "lambda@" + pos
      }
      ctx.closure_lifted_labels.push(lambda_label)
      emit_ref_func_gc(buf, func_idx)
      for i in 0..<capture_indices.length() {
        emit_local_get_gc(buf, capture_indices[i])
      }
      emit_struct_new_gc(buf, env_type_idx)
      emit_struct_new_gc(buf, struct_type_idx)
    }
    @core.Expr::Perform(effect_name="Error", op_name="Throw", args~, span~) => {
      let _ = span
      // throw: compile error value, then emit throw instruction
      let value = if args.length() >= 1 {
        args[0].expr
      } else {
        @core.Expr::Int(value=0L, span~)
      }
      compile_expr_gc(ctx, fctx, buf, value)
      ctx.needs_exceptions = true
      buf.push(0x08) // throw opcode
      write_u32_leb_gc(buf, ctx.error_tag_index)
    }
    @core.Expr::Perform(effect_name~, op_name~, args~, span~) => {
      let _ = span
      let _ = effect_name
      let _ = op_name
      // Non-Error effect: compile args (for side effects) then trap
      // WASI/IO effects need proper import integration for runtime support
      for arg in args {
        compile_expr_gc(ctx, fctx, buf, arg.expr)
        emit_drop_gc(buf)
      }
      emit_unreachable_gc(buf)
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      let _ = span
      // Error-only handle: try_table with catch
      let catch_arm = if arms.length() > 0 {
        arms[0]
      } else {
        raise WasmGenError::Unsupported("handle with no arms")
      }
      // Infer result type from body
      let result_kind = infer_block_kind_gc(ctx, fctx, body)
      // Structure:
      // block $outer (result result_kind)     ; depth +1
      //   block $catch_target (result eqref)  ; depth +1 — catch lands here
      //     try_table (result result_kind) (catch error_tag $catch_target)
      //       {body}
      //     end try_table
      //     br $outer                         ; success → skip handler
      //   end $catch_target                   ; error value (eqref) on stack
      //   {handler code}
      // end $outer
      // block $outer
      emit_block_gc(buf, Some(result_kind))
      // block $catch_target (result eqref)
      emit_block_gc(buf, Some(GcValKind::EqRef))
      // try_table (result result_kind) (catch error_tag 0)
      ctx.needs_exceptions = true
      buf.push(0x1f) // try_table opcode
      write_valtype_gc(buf, result_kind)
      write_u32_leb_gc(buf, 1) // 1 handler
      buf.push(0x00) // catch (not catch_ref)
      write_u32_leb_gc(buf, ctx.error_tag_index)
      write_u32_leb_gc(buf, 0) // branch depth 0 = $catch_target
      // {body}
      compile_block_expr_gc(ctx, fctx, buf, body)
      // end try_table
      emit_end_gc(buf)
      // br $outer (success)
      emit_br_gc(buf, 1)
      // end $catch_target — eqref error value on stack
      emit_end_gc(buf)
      // Handler code: error value is on stack as eqref
      let error_local = alloc_local_gc(fctx, GcValKind::EqRef)
      emit_local_set_gc(buf, error_local)
      // Bind error name if pattern is Error::Throw(e) or Bind(e)
      let saved_locals = clone_locals_gc(fctx.locals)
      match catch_arm.pat {
        @core.Pat::Bind(name~, ..) => {
          let idx = alloc_local_gc(fctx, GcValKind::EqRef)
          emit_local_get_gc(buf, error_local)
          emit_local_set_gc(buf, idx)
          fctx.locals[name] = { idx, kind: GcValKind::EqRef }
        }
        @core.Pat::Ctor(name="Error::Throw", args~, ..) if args.length() > 0 =>
          match args[0] {
            @core.Pat::Bind(name~, ..) => {
              let idx = alloc_local_gc(fctx, GcValKind::EqRef)
              emit_local_get_gc(buf, error_local)
              emit_local_set_gc(buf, idx)
              fctx.locals[name] = { idx, kind: GcValKind::EqRef }
            }
            _ => ()
          }
        _ => ()
      }
      // Compile handler body
      let catch_body = match catch_arm.expr {
        @core.Expr::Block(body=blk_body, ..) => blk_body
        other => @core.Module::{ stmts: [@core.Stmt::Expr(expr=other, span~)] }
      }
      compile_block_expr_gc(ctx, fctx, buf, catch_body)
      restore_locals_gc(fctx, saved_locals)
      // end $outer
      emit_end_gc(buf)
    }
    @core.Expr::StringInterp(parts~, span~) =>
      // Build string by concatenating parts using compile_string_concat
      if parts.length() == 0 {
        emit_string_literal(ctx, buf, "")
      } else if parts.length() == 1 {
        match parts[0] {
          @core.StringInterpPart::Lit(s) => emit_string_literal(ctx, buf, s)
          @core.StringInterpPart::Expr(e) => compile_expr_gc(ctx, fctx, buf, e)
        }
      } else {
        // Use wrapper Expr for each part to feed compile_string_concat
        fn part_to_expr(p : @core.StringInterpPart) -> @core.Expr {
          match p {
            @core.StringInterpPart::Lit(s) => @core.Expr::String(value=s, span~)
            @core.StringInterpPart::Expr(e) => e
          }
        }

        // Concat parts left-to-right using compile_string_concat
        compile_string_concat(
          ctx,
          fctx,
          buf,
          part_to_expr(parts[0]),
          part_to_expr(parts[1]),
        )
        for i in 2..<parts.length() {
          let acc_local = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
          emit_local_set_gc(buf, acc_local)
          let acc_expr = @core.Expr::Ident(
            name="__interp_acc_" + i.to_string(),
            span~,
          )
          // Bind the local so we can reference it
          fctx.locals["__interp_acc_" + i.to_string()] = {
            idx: acc_local,
            kind: GcValKind::Ref(ctx.string_type),
          }
          compile_string_concat(
            ctx,
            fctx,
            buf,
            acc_expr,
            part_to_expr(parts[i]),
          )
        }
      }
    @core.Expr::TupleIndex(expr~, index~, span~) => {
      let _ = span
      let kind = infer_expr_kind_gc(ctx, fctx, expr)
      let type_idx = match kind {
        GcValKind::Ref(idx) => idx
        _ => {
          // EqRef or unknown — create ad-hoc 2-field struct for tuple access
          let fields : Array[GcValKind] = []
          for _ in 0..<(index + 1) {
            fields.push(GcValKind::EqRef)
          }
          ensure_struct_type(ctx.types, ctx.struct_type_index, fields)
        }
      }
      compile_expr_gc(ctx, fctx, buf, expr)
      // Cast to struct type if needed
      match kind {
        GcValKind::Ref(_) => ()
        _ => emit_ref_cast_gc(buf, type_idx)
      }
      emit_struct_get_gc(buf, type_idx, index)
    }
    @core.Expr::Break(..) =>
      // Break from while loop: br to outer block (depth 1 from inside loop)
      emit_br_gc(buf, 1)
    @core.Expr::Continue(..) =>
      // Continue while loop: br to loop header (depth 0)
      emit_br_gc(buf, 0)
    @core.Expr::Return(value~, ..) => {
      // Emit the value (if any), then wasm `return`. Bare `return`
      // produces a Unit tagged constant since the function frame
      // always expects a result on the stack.
      match value {
        Some(v) => compile_expr_gc(ctx, fctx, buf, v)
        None => emit_i64_const_gc(buf, 0L)
      }
      emit_return_gc(buf)
    }
    other =>
      raise WasmGenError::Unsupported(
        "expr: " + other.to_string()[:40].to_owned(),
      )
  }
}

///|
fn compile_stmt_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  stmt : @core.Stmt,
  is_last : Bool,
) -> Unit raise WasmGenError {
  // Issue #417: emit a line coverage point before each statement when
  // coverage is enabled. Mirrors the linear backend's hook in
  // `wasm_codegen_stmt.mbt::compile_stmt::line 97`.
  emit_coverage_gc(ctx, buf, WasmCoveragePointKind::Line, stmt.span())
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, ..) =>
      if rec {
        // let rec: pre-bind name so body can reference itself
        // For Fn expressions, derive closure type from params/ret
        match expr {
          @core.Expr::Fn(params~, ret~, ..) => {
            let param_kinds : Array[GcValKind] = []
            for p in params {
              param_kinds.push(gc_val_kind_from_type(ctx, p.ty))
            }
            let result_kind = match ret {
              Some(ty) => gc_val_kind_from_type(ctx, ty)
              None => GcValKind::I32
            }
            let (fn_type_idx, closure_struct_type) = ensure_closure_types_gc(
              ctx, param_kinds, result_kind,
            )
            let kind = GcValKind::Ref(closure_struct_type)
            let idx = bind_local_gc(fctx, name, kind)
            fctx.closure_call_types[name] = fn_type_idx
            track_closure_binding_gc(ctx, fctx, name, expr)
            let rec_compile_cct : Map[String, Int] = {}
            for k, v in fctx.closure_call_types {
              rec_compile_cct[k] = v
            }
            let rec_compile_fctx = GcFuncCtx::{
              locals: clone_locals_gc(fctx.locals),
              map_value_kinds: clone_kind_map_gc(fctx.map_value_kinds),
              array_builder_elem_hints: clone_kind_map_gc(
                fctx.array_builder_elem_hints,
              ),
              local_kinds: [],
              param_count: fctx.param_count,
              closure_call_types: rec_compile_cct,
              current_rec_binding: Some(name),
              enclosing_function_name: Some(name),
              direct_rec_call_name: None,
              direct_rec_call_func_idx: -1,
              direct_rec_call_type_idx: -1,
            }
            compile_expr_gc(ctx, rec_compile_fctx, buf, expr)
            if is_last {
              emit_local_tee_gc(buf, idx)
            } else {
              emit_local_set_gc(buf, idx)
            }
          }
          _ => {
            let elem_hint = array_builder_new_elem_hint_gc(fctx, name, expr)
            let kind = match elem_hint {
              Some(elem_kind) => gc_array_builder_kind_for_elem(ctx, elem_kind)
              None => infer_expr_kind_gc(ctx, fctx, expr)
            }
            let idx = bind_local_gc(fctx, name, kind)
            match infer_map_value_kind_from_expr_gc(ctx, fctx, expr) {
              Some(value_kind) => fctx.map_value_kinds[name] = value_kind
              None => ()
            }
            track_closure_binding_gc(ctx, fctx, name, expr)
            match elem_hint {
              Some(elem_kind) =>
                emit_array_builder_new_for_elem_gc(ctx, buf, elem_kind)
              None => compile_expr_gc(ctx, fctx, buf, expr)
            }
            if is_last {
              emit_local_tee_gc(buf, idx)
            } else {
              emit_local_set_gc(buf, idx)
            }
          }
        }
      } else {
        let elem_hint = array_builder_new_elem_hint_gc(fctx, name, expr)
        let kind = match elem_hint {
          Some(elem_kind) => gc_array_builder_kind_for_elem(ctx, elem_kind)
          None => infer_expr_kind_gc(ctx, fctx, expr)
        }
        let idx = bind_local_gc(fctx, name, kind)
        match infer_map_value_kind_from_expr_gc(ctx, fctx, expr) {
          Some(value_kind) => fctx.map_value_kinds[name] = value_kind
          None => ()
        }
        track_closure_binding_gc(ctx, fctx, name, expr)
        match elem_hint {
          Some(elem_kind) =>
            emit_array_builder_new_for_elem_gc(ctx, buf, elem_kind)
          None => compile_expr_gc(ctx, fctx, buf, expr)
        }
        if is_last {
          emit_local_tee_gc(buf, idx)
        } else {
          emit_local_set_gc(buf, idx)
        }
      }
    @core.Stmt::LetMut(name~, expr~, ..) => {
      let elem_hint = array_builder_new_elem_hint_gc(fctx, name, expr)
      let kind = match elem_hint {
        Some(elem_kind) => gc_array_builder_kind_for_elem(ctx, elem_kind)
        None => infer_expr_kind_gc(ctx, fctx, expr)
      }
      let idx = bind_local_gc(fctx, name, kind)
      match infer_map_value_kind_from_expr_gc(ctx, fctx, expr) {
        Some(value_kind) => fctx.map_value_kinds[name] = value_kind
        None => ()
      }
      track_closure_binding_gc(ctx, fctx, name, expr)
      match elem_hint {
        Some(elem_kind) =>
          emit_array_builder_new_for_elem_gc(ctx, buf, elem_kind)
        None => compile_expr_gc(ctx, fctx, buf, expr)
      }
      if is_last {
        emit_local_tee_gc(buf, idx)
      } else {
        emit_local_set_gc(buf, idx)
      }
    }
    @core.Stmt::Assign(name~, expr~, ..) => {
      // Track closure types for let rec desugar (Assign after Let placeholder)
      track_closure_binding_gc(ctx, fctx, name, expr)
      // Update local kind for Fn assignments (let rec desugar)
      match expr {
        @core.Expr::Fn(..) => {
          let kind = infer_expr_kind_gc(ctx, fctx, expr)
          match fctx.locals.get(name) {
            Some(info) => fctx.locals[name] = { idx: info.idx, kind }
            None => ()
          }
        }
        _ => ()
      }
      match infer_map_value_kind_from_expr_gc(ctx, fctx, expr) {
        Some(value_kind) => fctx.map_value_kinds[name] = value_kind
        None => ()
      }
      match fctx.locals.get(name) {
        Some(info) => {
          compile_expr_gc(ctx, fctx, buf, expr)
          if is_last {
            emit_local_tee_gc(buf, info.idx)
          } else {
            emit_local_set_gc(buf, info.idx)
          }
        }
        None => {
          // Assign to previously unknown name (e.g., from let rec desugar)
          let kind = infer_expr_kind_gc(ctx, fctx, expr)
          let idx = bind_local_gc(fctx, name, kind)
          compile_expr_gc(ctx, fctx, buf, expr)
          if is_last {
            emit_local_tee_gc(buf, idx)
          } else {
            emit_local_set_gc(buf, idx)
          }
        }
      }
    }
    @core.Stmt::Expr(expr~, ..) => {
      compile_expr_gc(ctx, fctx, buf, expr)
      if !is_last {
        emit_drop_gc(buf)
      }
    }
    @core.Stmt::ExternLet(..)
    | @core.Stmt::Test(..)
    | @core.Stmt::Bench(..)
    | @core.Stmt::TypeAlias(..)
    | @core.Stmt::ExportTypeAlias(..)
    | @core.Stmt::InternalExportTypeAlias(..)
    | @core.Stmt::EnumDef(..)
    | @core.Stmt::ExportEnumDef(..)
    | @core.Stmt::InternalExportEnumDef(..)
    | @core.Stmt::Export(..)
    | @core.Stmt::ReExport(..)
    | @core.Stmt::TraitDef(..)
    | @core.Stmt::InternalTraitDef(..)
    | @core.Stmt::TraitImpl(..)
    | @core.Stmt::StructDef(..)
    | @core.Stmt::ExportStructDef(..)
    | @core.Stmt::InternalExportStructDef(..)
    | @core.Stmt::EffectDef(..)
    | @core.Stmt::ExportEffectDef(..)
    | @core.Stmt::AliasDecl(..) => if is_last { emit_i32_const_gc(buf, 0) }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      compile_stmt_gc(
        ctx,
        fctx,
        buf,
        @core.Stmt::Let(rec~, name~, expr~, span~),
        is_last,
      )
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) =>
      compile_stmt_gc(
        ctx,
        fctx,
        buf,
        @core.Stmt::Let(rec~, name~, expr~, span~),
        is_last,
      )
    @core.Stmt::LetPat(pat~, expr~, ..) => {
      let kind = infer_expr_kind_gc(ctx, fctx, expr)
      let scrut_idx = alloc_local_gc(fctx, kind)
      compile_expr_gc(ctx, fctx, buf, expr)
      emit_local_set_gc(buf, scrut_idx)
      compile_pat_bind_gc(ctx, fctx, buf, scrut_idx, kind, pat)
      if is_last {
        emit_local_get_gc(buf, scrut_idx)
      }
    }
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, ..) => {
      let kind = infer_expr_kind_gc(ctx, fctx, expr)
      let scrut_idx = alloc_local_gc(fctx, kind)
      compile_expr_gc(ctx, fctx, buf, expr)
      emit_local_set_gc(buf, scrut_idx)
      let else_kind = infer_block_kind_gc(ctx, fctx, else_body)
      let match_result_kind = gc_common_kind(GcValKind::I32, else_kind)
      compile_pat_cond_gc(ctx, fctx, buf, scrut_idx, kind, pat)
      emit_if_gc(buf, Some(match_result_kind))
      compile_pat_bind_gc(ctx, fctx, buf, scrut_idx, kind, pat)
      emit_i32_const_gc(buf, 0)
      emit_coerce_top_gc(ctx, buf, GcValKind::I32, match_result_kind)
      emit_else_gc(buf)
      compile_block_expr_gc(ctx, fctx, buf, else_body)
      emit_coerce_top_gc(ctx, buf, else_kind, match_result_kind)
      emit_end_gc(buf)
      emit_drop_gc(buf)
      if is_last {
        emit_i32_const_gc(buf, 0)
      }
    }
    @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      // Struct-field assignment `r.field = v` is parsed as
      // IndexAssign(r, "field", v). Try the struct path first; on miss
      // fall through to array/element-set.
      let handled = match index {
        @core.Expr::String(value=field_name, ..) =>
          try_compile_struct_field_set_gc(
            ctx, fctx, buf, field_name, target, value,
          )
        _ => false
      }
      if !handled {
        let base_kind = infer_expr_kind_gc(ctx, fctx, target)
        let type_idx = gc_array_type_idx_from_kind(
          ctx, base_kind, "IndexAssign",
        )
        compile_expr_gc(ctx, fctx, buf, target)
        compile_expr_gc(ctx, fctx, buf, index)
        let idx_kind = infer_expr_kind_gc(ctx, fctx, index)
        if idx_kind == GcValKind::I64 {
          emit_i32_wrap_i64_gc(buf)
        }
        compile_expr_gc(ctx, fctx, buf, value)
        emit_array_set_gc(buf, type_idx)
      }
      if is_last {
        emit_i32_const_gc(buf, 0)
      }
    }
    // Type/trait/effect definitions, imports, etc. — no codegen needed
    _ =>
      if is_last {
        emit_i32_const_gc(buf, 0) // Unit
      }
  }
}

///|
fn compile_block_expr_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  body : @core.Module,
) -> Unit raise WasmGenError {
  let len = body.stmts.length()
  if len == 0 {
    emit_i32_const_gc(buf, 0)
    return
  }
  seed_array_builder_hints_gc(ctx, fctx, body)
  for i in 0..<len {
    let is_last = i == len - 1
    compile_stmt_gc(ctx, fctx, buf, body.stmts[i], is_last)
  }
}

///|
fn collect_top_level_funcs_gc(
  ast : @core.Module,
  enum_ctor_names? : Map[String, Bool] = {},
) -> Array[GcFuncDef] {
  // Only Fn definitions and immutable literal constants are safe for
  // free-var filtering. Non-literal bindings (Call, Array, String, etc.)
  // are NOT added — functions referencing them become closures instead
  // of top-level extractions. This avoids mutable wasm globals which
  // would complicate future threading.
  let top_func_names : Map[String, Bool] = {}
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..)
      | @core.Stmt::ExportLet(name~, expr~, ..)
      | @core.Stmt::InternalExportLet(name~, expr~, ..) =>
        match unwrap_type_assert_block(expr) {
          @core.Expr::Fn(..) => top_func_names[name] = true
          @core.Expr::Int(..) | @core.Expr::Bool(..) | @core.Expr::String(..) =>
            top_func_names[name] = true
          _ => ()
        }
      _ => ()
    }
  }
  let funcs : Array[GcFuncDef] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, ..) => {
        let _ = rec
        match unwrap_type_assert_block(expr) {
          @core.Expr::Fn(params~, ret~, body~, ..) =>
            if !has_free_vars_gc(body, params, top_func_names, enum_ctor_names~) {
              funcs.push({ name, params, ret, body })
            }
          _ => ()
        }
      }
      @core.Stmt::ExportLet(rec~, name~, expr~, ..) => {
        let _ = rec
        match unwrap_type_assert_block(expr) {
          @core.Expr::Fn(params~, ret~, body~, ..) =>
            if !has_free_vars_gc(body, params, top_func_names, enum_ctor_names~) {
              funcs.push({ name, params, ret, body })
            }
          _ => ()
        }
      }
      @core.Stmt::InternalExportLet(rec~, name~, expr~, ..) => {
        let _ = rec
        match unwrap_type_assert_block(expr) {
          @core.Expr::Fn(params~, ret~, body~, ..) =>
            if !has_free_vars_gc(body, params, top_func_names, enum_ctor_names~) {
              funcs.push({ name, params, ret, body })
            }
          _ => ()
        }
      }
      _ => ()
    }
  }
  funcs
}

///|
fn filter_top_level_funcs_gc(
  ast : @core.Module,
  collected : Map[String, Bool],
) -> @core.Module {
  let stmts : Array[@core.Stmt] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..) =>
        match unwrap_type_assert_block(expr) {
          @core.Expr::Fn(..) =>
            if !collected.contains(name) {
              stmts.push(stmt)
            }
          _ => stmts.push(stmt)
        }
      @core.Stmt::ExportLet(name~, expr~, ..) =>
        match unwrap_type_assert_block(expr) {
          @core.Expr::Fn(..) =>
            if !collected.contains(name) {
              stmts.push(stmt)
            }
          _ => stmts.push(stmt)
        }
      @core.Stmt::InternalExportLet(name~, expr~, ..) =>
        match unwrap_type_assert_block(expr) {
          @core.Expr::Fn(..) =>
            if !collected.contains(name) {
              stmts.push(stmt)
            }
          _ => stmts.push(stmt)
        }
      _ => stmts.push(stmt)
    }
  }
  @core.Module::{ stmts, }
}

///|
fn compile_function_gc(
  ctx : GcCodegenCtx,
  def : GcFuncDef,
) -> GcWasmFunc raise WasmGenError {
  let fctx = GcFuncCtx::new(ctx, def.params)
  // Let lambdas inside this body label themselves
  // `<def.name>::lambda@<offset>` in the wasm name section.
  fctx.enclosing_function_name = Some(def.name)
  let body_kind = infer_block_kind_gc(ctx, fctx, def.body)
  let result_kind = match def.ret {
    Some(ty) => gc_val_kind_from_type(ctx, ty)
    None => body_kind
  }
  let sig = GcFuncSig::{ params: [], result: result_kind }
  for param in def.params {
    sig.params.push(gc_val_kind_from_type(ctx, param.ty))
  }
  let buf = GcByteBuf::new()
  compile_block_expr_gc(ctx, fctx, buf, def.body)
  emit_coerce_top_gc(ctx, buf, body_kind, result_kind)
  { sig, locals: fctx.local_kinds, body: buf.to_array(), type_idx: -1 }
}

///|
fn compile_run_gc(
  ctx : GcCodegenCtx,
  body : @core.Module,
) -> GcWasmFunc raise WasmGenError {
  let fctx = GcFuncCtx::new(ctx, [])
  let result_kind = infer_block_kind_gc(ctx, fctx, body)
  let sig = GcFuncSig::{ params: [], result: result_kind }
  let buf = GcByteBuf::new()
  compile_block_expr_gc(ctx, fctx, buf, body)
  { sig, locals: fctx.local_kinds, body: buf.to_array(), type_idx: -1 }
}

///|
fn write_section_gc(buf : GcByteBuf, id : Int, content : Array[Byte]) -> Unit {
  buf.push(id)
  write_u32_leb_gc(buf, content.length())
  buf.extend(content)
}

///|
fn write_type_entry_gc(buf : GcByteBuf, ty : GcTypeDef) -> Unit {
  match ty {
    GcTypeDef::Array(elem~) => {
      buf.push(0x5e)
      write_valtype_gc(buf, elem)
      buf.push(0x01)
    }
    GcTypeDef::Struct(fields~) => {
      buf.push(0x5f)
      write_u32_leb_gc(buf, fields.length())
      for field in fields {
        write_valtype_gc(buf, field)
        buf.push(0x01)
      }
    }
    GcTypeDef::Func(params~, result~) => {
      buf.push(0x60)
      write_u32_leb_gc(buf, params.length())
      for p in params {
        write_valtype_gc(buf, p)
      }
      write_u32_leb_gc(buf, 1)
      write_valtype_gc(buf, result)
    }
    GcTypeDef::TagFunc(params~) => {
      buf.push(0x60)
      write_u32_leb_gc(buf, params.length())
      for p in params {
        write_valtype_gc(buf, p)
      }
      write_u32_leb_gc(buf, 0) // no results (tag payload type)
    }
  }
}

///|
fn write_func_type_gc(buf : GcByteBuf, sig : GcFuncSig) -> Unit {
  buf.push(0x60)
  write_u32_leb_gc(buf, sig.params.length())
  for param in sig.params {
    write_valtype_gc(buf, param)
  }
  write_u32_leb_gc(buf, 1)
  write_valtype_gc(buf, sig.result)
}

///|
fn write_locals_gc(buf : GcByteBuf, locals : Array[GcValKind]) -> Unit {
  if locals.length() == 0 {
    write_u32_leb_gc(buf, 0)
    return
  }
  write_u32_leb_gc(buf, locals.length())
  for kind in locals {
    write_u32_leb_gc(buf, 1)
    write_valtype_gc(buf, kind)
  }
}

///|
fn build_module_gc(
  ctx : GcCodegenCtx,
  funcs : Array[GcWasmFunc],
  run_index : Int,
  global_init_values? : Array[(GcValKind, Int64)] = [],
  // Additional user-declared exports (e.g. `_bench_run`, custom-named
  // entry points). Each name is looked up in `ctx.func_indices` and
  // emitted in the export section alongside the synthesized `_start`.
  // Empty for tests/run/build that only need `_start`.
  user_exports? : Array[String] = [],
  // Function names parallel to `funcs[]` for the wasm `name` custom
  // section. Empty disables emission. Improves stack-trace readability
  // in `wasmtime --profile=guest` (and in browser devtools); without
  // it every frame shows as `<wasm function N>`.
  func_names? : Array[String] = [],
) -> Bytes {
  let buf = GcByteBuf::new()
  buf.push(0x00)
  buf.push(0x61)
  buf.push(0x73)
  buf.push(0x6d)
  buf.push(0x01)
  buf.push(0x00)
  buf.push(0x00)
  buf.push(0x00)
  let type_sec = GcByteBuf::new()
  let mut auto_type_count = 0
  for f in funcs {
    if f.type_idx < 0 {
      auto_type_count += 1
    }
  }
  let type_count = ctx.types.length() + auto_type_count
  write_u32_leb_gc(type_sec, type_count)
  for ty in ctx.types {
    write_type_entry_gc(type_sec, ty)
  }
  for f in funcs {
    if f.type_idx < 0 {
      write_func_type_gc(type_sec, f.sig)
    }
  }
  write_section_gc(buf, 1, type_sec.to_array())
  let func_sec = GcByteBuf::new()
  write_u32_leb_gc(func_sec, funcs.length())
  let mut auto_type_offset = ctx.types.length()
  for f in funcs {
    if f.type_idx >= 0 {
      write_u32_leb_gc(func_sec, f.type_idx)
    } else {
      write_u32_leb_gc(func_sec, auto_type_offset)
      auto_type_offset += 1
    }
  }
  write_section_gc(buf, 3, func_sec.to_array())
  // Memory section (section 5): only emitted when coverage is enabled
  // (issue #417). The wasm-gc backend is memory-free by default; the
  // counters live in a 1-page (64 KB = 16 384 i32 slots) linear
  // memory that the JS reader (`scripts/coverage_wasm_source.mjs`)
  // reads through the `memory` export, identically to the linear
  // backend's path.
  if ctx.coverage_enabled {
    let mem_sec = GcByteBuf::new()
    write_u32_leb_gc(mem_sec, 1) // 1 memory entry
    mem_sec.push(0x00) // limits flag: only min, no max
    write_u32_leb_gc(mem_sec, 1) // initial = 1 page
    write_section_gc(buf, 5, mem_sec.to_array())
  }
  // Tag section (section 13): only emit if throw/handle is used
  // Per exception handling spec, placed between func(3) and global(6)
  if ctx.needs_exceptions {
    let tag_sec = GcByteBuf::new()
    write_u32_leb_gc(tag_sec, 1) // 1 tag
    tag_sec.push(0x00) // tag attribute: exception
    write_u32_leb_gc(tag_sec, ctx.error_tag_type_index) // type index
    write_section_gc(buf, 13, tag_sec.to_array())
  }
  // Global section (section 6): immutable compile-time constants plus
  // the two coverage descriptor globals (__vibe_cov_base /
  // __vibe_cov_count) when coverage is enabled. No mutable globals —
  // thread-safe by design.
  let cov_global_count = if ctx.coverage_enabled { 2 } else { 0 }
  if global_init_values.length() > 0 || cov_global_count > 0 {
    let global_sec = GcByteBuf::new()
    write_u32_leb_gc(global_sec, global_init_values.length() + cov_global_count)
    for entry in global_init_values {
      let kind = entry.0
      let value = entry.1
      write_valtype_gc(global_sec, kind)
      global_sec.push(0x00) // immutable
      match kind {
        GcValKind::I64 => {
          global_sec.push(0x42) // i64.const
          write_i64_leb_gc(global_sec, value)
        }
        GcValKind::I32 => {
          global_sec.push(0x41) // i32.const
          write_i32_leb_gc(global_sec, value.to_int())
        }
        _ => {
          global_sec.push(0x41)
          write_i32_leb_gc(global_sec, 0)
        }
      }
      global_sec.push(0x0b) // end
    }
    if ctx.coverage_enabled {
      // __vibe_cov_base : i32 immutable = 0 (counters at addr 0)
      write_valtype_gc(global_sec, GcValKind::I32)
      global_sec.push(0x00) // immutable
      global_sec.push(0x41) // i32.const
      write_i32_leb_gc(global_sec, 0)
      global_sec.push(0x0b) // end
      // __vibe_cov_count : i32 immutable = registered point count
      write_valtype_gc(global_sec, GcValKind::I32)
      global_sec.push(0x00) // immutable
      global_sec.push(0x41)
      write_i32_leb_gc(global_sec, ctx.coverage_points.length())
      global_sec.push(0x0b)
    }
    write_section_gc(buf, 6, global_sec.to_array())
  }
  let export_sec = GcByteBuf::new()
  // Collect (name, func_index) pairs. Default `_start` points at the
  // synthesized module run wrapper (which executes any top-level
  // statements). If the user wrote `export let _start = ...` themselves,
  // their function takes over `_start` — the run wrapper is unused in
  // that case (which is fine: bench / test source emits its work into
  // `_start` directly and has no top-level statements).
  let export_entries : Array[(String, Int)] = []
  let user_start_idx = ctx.func_indices.get("_start")
  match user_start_idx {
    Some(idx) => export_entries.push(("_start", idx))
    None => export_entries.push(("_start", run_index))
  }
  // Mirror the linear backend's `_vibe_run_tagged` export so the test
  // / repl framework (`run_wasmtime_invoke_run_capture` in
  // `src/cmd/vibe/cli_run_cmd.mbt`) can find a run entry. The export
  // always aliases the run wrapper — for user-supplied `_start` we
  // want the wrapper's top-level body, not the user's manual entry.
  export_entries.push(("_vibe_run_tagged", run_index))
  for export_name in user_exports {
    if export_name == "_start" {
      continue // already pushed above
    }
    match ctx.func_indices.get(export_name) {
      Some(idx) => export_entries.push((export_name, idx))
      None => () // user named a non-function export (e.g. a top-level constant) — skip
    }
  }
  // Coverage exports (issue #417): the JS reader expects `memory`,
  // `__vibe_cov_base`, and `__vibe_cov_count`. They're indexed into
  // separate spaces (memory→memidx 0; globals→last 2 global slots).
  let extra_export_count = if ctx.coverage_enabled { 3 } else { 0 }
  write_u32_leb_gc(export_sec, export_entries.length() + extra_export_count)
  for entry in export_entries {
    let (name, idx) = entry
    write_u32_leb_gc(export_sec, name.length())
    for c in name {
      export_sec.push(c.to_int())
    }
    export_sec.push(0x00)
    write_u32_leb_gc(export_sec, idx)
  }
  if ctx.coverage_enabled {
    let cov_base_global_idx = global_init_values.length()
    let cov_count_global_idx = cov_base_global_idx + 1
    // export "memory" memory 0
    let mem_name = "memory"
    write_u32_leb_gc(export_sec, mem_name.length())
    for c in mem_name {
      export_sec.push(c.to_int())
    }
    export_sec.push(0x02) // memory kind
    write_u32_leb_gc(export_sec, 0)
    // export "__vibe_cov_base" global N
    let base_name = "__vibe_cov_base"
    write_u32_leb_gc(export_sec, base_name.length())
    for c in base_name {
      export_sec.push(c.to_int())
    }
    export_sec.push(0x03) // global kind
    write_u32_leb_gc(export_sec, cov_base_global_idx)
    // export "__vibe_cov_count" global N+1
    let count_name = "__vibe_cov_count"
    write_u32_leb_gc(export_sec, count_name.length())
    for c in count_name {
      export_sec.push(c.to_int())
    }
    export_sec.push(0x03)
    write_u32_leb_gc(export_sec, cov_count_global_idx)
  }
  write_section_gc(buf, 7, export_sec.to_array())
  // Element section: declare closure function refs for ref.func
  if ctx.closure_lifted_funcs.length() > 0 {
    let elem_sec = GcByteBuf::new()
    write_u32_leb_gc(elem_sec, 1) // 1 element segment
    // Declarative element segment (flags = 0x07: declarative, element type, elem exprs)
    elem_sec.push(0x07) // declarative segment with element expressions
    elem_sec.push(0x70) // funcref element type
    write_u32_leb_gc(elem_sec, ctx.closure_lifted_funcs.length())
    for i in 0..<ctx.closure_lifted_funcs.length() {
      let func_idx = ctx.num_regular_funcs + i
      elem_sec.push(0xd2) // ref.func
      write_u32_leb_gc(elem_sec, func_idx)
      elem_sec.push(0x0b) // end
    }
    write_section_gc(buf, 9, elem_sec.to_array())
  }
  let code_sec = GcByteBuf::new()
  write_u32_leb_gc(code_sec, funcs.length())
  for f in funcs {
    let func_body = GcByteBuf::new()
    write_locals_gc(func_body, f.locals)
    func_body.extend(f.body)
    func_body.push(0x0b)
    write_u32_leb_gc(code_sec, func_body.len())
    code_sec.extend_buf(func_body)
  }
  write_section_gc(buf, 10, code_sec.to_array())
  // Custom "name" section (after data per convention) — improves
  // profiler / devtools readability so frames render with their vibe
  // identifier instead of `<wasm function N>`. Subsection 1 is the
  // function-name map; we don't emit subsection 2 (locals) yet
  // because the wasm-gc backend allocates locals without keeping the
  // source identifiers around.
  if func_names.length() > 0 {
    let function_names_sub = GcByteBuf::new()
    // namemap = vec(naming)
    let mut entry_count = 0
    for n in func_names {
      if n.length() > 0 {
        entry_count += 1
      }
    }
    if entry_count > 0 {
      write_u32_leb_gc(function_names_sub, entry_count)
      for i in 0..<func_names.length() {
        let n = func_names[i]
        if n.length() == 0 {
          continue
        }
        write_u32_leb_gc(function_names_sub, i)
        write_name_string_gc(function_names_sub, n)
      }
      let name_sec = GcByteBuf::new()
      // Custom section payload: name "name" + subsection 1
      write_name_string_gc(name_sec, "name")
      // Subsection 1: function names — id=1, size, content
      name_sec.push(0x01)
      let sub_bytes = function_names_sub.to_array()
      write_u32_leb_gc(name_sec, sub_bytes.length())
      for b in sub_bytes {
        name_sec.push(b.to_int())
      }
      write_section_gc(buf, 0, name_sec.to_array())
    }
  }
  buf.to_bytes()
}

///|
/// Format a byte offset as `<line>:<col>` when the codegen has the
/// original source string, falling back to the raw offset otherwise.
/// Used only for lambda labels in the wasm `name` section so the
/// profiler / devtools can show a human-friendly position. Lines and
/// columns are 1-based, matching `@core.line_info`.
fn format_lambda_position_gc(ctx : GcCodegenCtx, offset : Int) -> String {
  if ctx.source.length() == 0 {
    return offset.to_string()
  }
  let (lc, _, _) = @core.line_info(ctx.source, offset)
  lc.line.to_string() + ":" + lc.column.to_string()
}

///|
/// Write a length-prefixed UTF-8 string (wasm name encoding). Mirrors
/// the linear backend's `write_name` but for the GC byte buffer.
fn write_name_string_gc(buf : GcByteBuf, s : String) -> Unit {
  let bytes = @utf8.encode(s)
  write_u32_leb_gc(buf, bytes.length())
  for b in bytes {
    buf.push(b.to_int())
  }
}

///|
pub fn emit_module_wasm_gc(ast : @core.Module) -> Bytes raise WasmGenError {
  let (bytes, _) = emit_module_wasm_gc_inner(ast, coverage_enabled=false)
  bytes
}

///|
/// Same as `emit_module_wasm_gc` but threads the original source
/// string through so lambda labels in the wasm `name` section can be
/// upgraded from `lambda@<offset>` to `lambda@<line>:<col>`. Callers
/// that don't have the source (e.g. wbtests, synthetic ASTs) can keep
/// using the bare entry point.
pub fn emit_module_wasm_gc_with_source(
  ast : @core.Module,
  source : String,
) -> Bytes raise WasmGenError {
  let (bytes, _) = emit_module_wasm_gc_inner(
    ast,
    coverage_enabled=false,
    source~,
  )
  bytes
}

///|
/// Issue #417: wasm-gc backend coverage-instrumented emit. Mirrors the
/// linear backend's `emit_module_wasm_with_coverage`. Returns the wasm
/// bytes plus a `WasmCoverageArtifact` whose `points` array describes
/// every counter slot. The .wasm has a linear memory + the two
/// `__vibe_cov_base` / `__vibe_cov_count` globals plus a `memory`
/// export so the existing `scripts/coverage_wasm_source.mjs` reader
/// works unchanged.
pub fn emit_module_wasm_gc_with_coverage(
  ast : @core.Module,
) -> WasmCoverageArtifact raise WasmGenError {
  let (bytes, ctx) = emit_module_wasm_gc_inner(ast, coverage_enabled=true)
  {
    bytes,
    counter_base: 0,
    counter_count: ctx.coverage_points.length(),
    points: ctx.coverage_points,
  }
}

///|
fn emit_module_wasm_gc_inner(
  ast : @core.Module,
  coverage_enabled? : Bool = false,
  source? : String = "",
) -> (Bytes, GcCodegenCtx) raise WasmGenError {
  // Mirror the linear backend's prologue: strip type-assertion blocks
  // first (so the AST has bare Int/Bool literals where the user wrote
  // `let c: Int = 100`), then fold pure top-level expressions
  // (`let mask32 = __bit_or(__lshift(...), 0xFFFF)`, etc.) into Int /
  // Bool literals so they can be lifted to wasm globals and referenced
  // from inside other top-level functions. Without these passes, the
  // value stays a Call expression and any function body that references
  // it (e.g. `read_word` in sha1) becomes a closure with a free var
  // the gc backend can't resolve → "unknown name: mask32".
  // Coverage-enabled compilation skips the static folding pass so that
  // every source statement remains a distinct instrumentation point.
  let ast = if coverage_enabled {
    strip_type_assert_module(ast)
  } else {
    static_fold_module(strip_type_assert_module(ast))
  }
  let ctx = GcCodegenCtx::new()
  ctx.coverage_enabled = coverage_enabled
  ctx.source = source
  scan_enum_defs_gc(ctx, ast)
  register_struct_types_gc(ctx, ast)
  // Build enum ctor name set for free-var filtering
  let enum_ctor_names : Map[String, Bool] = {}
  for name, _ in ctx.enum_ctor_tags {
    enum_ctor_names[name] = true
  }
  // Scan for immutable constant let bindings and register as globals.
  // Only Int/Bool literals are supported (compile-time known values).
  // Non-literal bindings (String, Call, Array, etc.) stay in the run
  // body and are accessed via closure capture — no mutable globals.
  let mut global_idx = 0
  let global_init_values : Array[(GcValKind, Int64)] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..)
      | @core.Stmt::ExportLet(name~, expr~, ..)
      | @core.Stmt::InternalExportLet(name~, expr~, ..) =>
        // unwrap_type_assert_block matters: `let c: Int = 100` is wrapped
        // by the parser in a type-annotation block. Without unwrapping
        // the match below sees a Block, never an Int literal, so the
        // global gets silently dropped — leaving downstream functions
        // that reference it with an "unknown name" error.
        match unwrap_type_assert_block(expr) {
          @core.Expr::Int(value~, ..) => {
            ctx.global_consts[name] = (global_idx, GcValKind::I64)
            global_init_values.push((GcValKind::I64, value))
            global_idx += 1
          }
          @core.Expr::Bool(value~, ..) => {
            ctx.global_consts[name] = (global_idx, GcValKind::I32)
            global_init_values.push(
              (GcValKind::I32, if value { 1L } else { 0L }),
            )
            global_idx += 1
          }
          @core.Expr::String(value~, ..) =>
            // Record the literal value; emit fresh per use site.
            ctx.string_consts[name] = value
          _ => ()
        }
      @core.Stmt::LetMut(name~, expr~, ..) =>
        match unwrap_type_assert_block(expr) {
          @core.Expr::Int(value~, ..) => {
            ctx.global_consts[name] = (global_idx, GcValKind::I64)
            global_init_values.push((GcValKind::I64, value))
            global_idx += 1
          }
          _ => ()
        }
      _ => ()
    }
  }
  let funcs = collect_top_level_funcs_gc(ast, enum_ctor_names~)
  ctx.num_regular_funcs = funcs.length() + 1
  for i in 0..<funcs.length() {
    ctx.func_indices[funcs[i].name] = i
    ctx.func_param_counts[funcs[i].name] = funcs[i].params.length()
    let pk : Array[GcValKind] = []
    for p in funcs[i].params {
      pk.push(gc_val_kind_from_type(ctx, p.ty))
    }
    ctx.func_param_kinds[funcs[i].name] = pk
    match funcs[i].ret {
      Some(ty) => {
        let kind = gc_val_kind_from_type(ctx, ty)
        ctx.func_returns[funcs[i].name] = kind
        match ty {
          @core.Type::Func(params~, ret~, ..) => {
            let param_kinds : Array[GcValKind] = []
            for p in params {
              param_kinds.push(gc_val_kind_from_type(ctx, p.ty))
            }
            let result_kind = gc_val_kind_from_type(ctx, ret)
            let (fn_type_idx, _) = ensure_closure_types_gc(
              ctx, param_kinds, result_kind,
            )
            ctx.closure_call_type_for_func[funcs[i].name] = fn_type_idx
          }
          _ => ()
        }
      }
      None =>
        // No explicit return type — default to I64 (tagged int).
        // This happens when bundler/DCE strips type annotations.
        ctx.func_returns[funcs[i].name] = GcValKind::I64
    }
  }
  // Resolve function aliases: let f = g where g is in func_indices
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..)
      | @core.Stmt::ExportLet(name~, expr~, ..)
      | @core.Stmt::InternalExportLet(name~, expr~, ..) =>
        match expr {
          @core.Expr::Ident(name=target, ..) =>
            match ctx.func_indices.get(target) {
              Some(idx) => {
                ctx.func_indices[name] = idx
                match ctx.func_param_counts.get(target) {
                  Some(c) => ctx.func_param_counts[name] = c
                  None => ()
                }
                match ctx.func_returns.get(target) {
                  Some(k) => ctx.func_returns[name] = k
                  None => ()
                }
              }
              None => ()
            }
          _ => ()
        }
      _ => ()
    }
  }
  let wasm_funcs : Array[GcWasmFunc] = []
  // Parallel array of human-readable names for the wasm `name` custom
  // section. Improves profiler / devtools stack traces; without it
  // every frame renders as `<wasm function N>`.
  let func_names : Array[String] = []
  for f in funcs {
    let wf = compile_function_gc(ctx, f)
    ctx.func_returns[f.name] = wf.sig.result
    wasm_funcs.push(wf)
    func_names.push(f.name)
  }
  let collected_names : Map[String, Bool] = {}
  for f in funcs {
    collected_names[f.name] = true
  }
  let run_body = filter_top_level_funcs_gc(ast, collected_names)
  let run_func = compile_run_gc(ctx, run_body)
  let run_index = wasm_funcs.length()
  wasm_funcs.push(run_func)
  // `_start` is the canonical name; even when the user re-exports a
  // different function under that name we still want this stable label
  // so wasmtime --invoke and the profiler agree.
  func_names.push("_start")
  for i in 0..<ctx.closure_lifted_funcs.length() {
    wasm_funcs.push(ctx.closure_lifted_funcs[i])
    // Label set when the closure was lifted (see `closure_lifted_labels`
    // doc comment) — gives `<parent>::lambda@<offset>` /
    // `as_closure::<name>` rather than a bare ordinal.
    let lbl = if i < ctx.closure_lifted_labels.length() {
      ctx.closure_lifted_labels[i]
    } else {
      "lambda_" + i.to_string()
    }
    func_names.push(lbl)
  }
  // Collect user `export let` function names so they appear in the wasm
  // export section (otherwise wasmtime --invoke can only call `_start`).
  // Required for `vibe bench --backend=gc` which invokes `_bench_run`,
  // and for any future entrypoint customization.
  let user_exports : Array[String] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::ExportLet(name~, expr~, ..)
      | @core.Stmt::InternalExportLet(name~, expr~, ..) =>
        match unwrap_type_assert_block(expr) {
          @core.Expr::Fn(..) => user_exports.push(name)
          _ => ()
        }
      _ => ()
    }
  }
  let bytes = build_module_gc(
    ctx,
    wasm_funcs,
    run_index,
    global_init_values~,
    user_exports~,
    func_names~,
  )
  (bytes, ctx)
}
