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
  let done = (rest == 0 && not(sign_bit_set)) || (rest == -1 && sign_bit_set)
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
  local_kinds : Array[GcValKind]
  param_count : Int
  closure_call_types : Map[String, Int]
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
  string_type : Int
  array_i32_type : Int
  bytes_type : Int
  closure_fn_type_cache : Map[String, Int]
  closure_struct_type_cache : Map[String, Int]
  closure_lifted_funcs : Array[GcWasmFunc]
  closure_call_type_for_func : Map[String, Int]
  mut num_regular_funcs : Int
  enum_ctor_tags : Map[String, Int]
  enum_ctor_arities : Map[String, Int]
  enum_ctor_type_indices : Map[String, Int]
  enum_ctor_field_kinds : Map[String, Array[GcValKind]]
  enum_names : Map[String, Bool]
  error_tag_index : Int
  error_tag_type_index : Int
  /// Compile-time known constants from top-level let bindings.
  /// Maps name → (global_index, val_kind)
  global_consts : Map[String, (Int, GcValKind)]
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
    _ => GcValKind::AnyRef
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
    string_type,
    array_i32_type,
    bytes_type,
    closure_fn_type_cache: {},
    closure_struct_type_cache: {},
    closure_lifted_funcs: [],
    closure_call_type_for_func: {},
    num_regular_funcs: 0,
    enum_ctor_tags: {},
    enum_ctor_arities: {},
    enum_ctor_type_indices: {},
    enum_ctor_field_kinds: {},
    enum_names: {},
    error_tag_index,
    error_tag_type_index,
    global_consts: {},
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
      buf.push(0x63)
      write_u32_leb_gc(buf, idx)
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
  buf.push(0x99)
}

///|
fn write_i64_leb_gc(buf : GcByteBuf, n : Int64) -> Unit {
  let mut value = n
  while true {
    let mut byte = (value & 0x7fL).to_int()
    value = value >> 7
    let sign_bit_set = (byte & 0x40) != 0
    let done = (value == 0L && not(sign_bit_set)) ||
      (value == -1L && sign_bit_set)
    if not(done) {
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
fn emit_i32_eq_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x46)
}

///|
fn emit_i32_and_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x71)
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
      if not(ctx.enum_ctor_tags.contains(ctor.name)) {
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
      if not(ctx.enum_ctor_tags.contains(qualified)) {
        ctx.enum_ctor_tags[qualified] = tag
        ctx.enum_ctor_arities[qualified] = ctor.args.length()
        ctx.enum_ctor_type_indices[qualified] = type_idx
        ctx.enum_ctor_field_kinds[qualified] = payload_kinds
      }
    }
  }
  // Register builtin Option enum (Some/None) if not already defined
  if not(ctx.enum_ctor_tags.contains("Some")) {
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
  if not(ctx.enum_ctor_tags.contains("None")) {
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
      if not(bound.contains(name)) {
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
      @core.Stmt::Let(name~, expr~, ..) => {
        collect_free_vars_expr_gc(expr, bound, free)
        bound[name] = true
      }
      @core.Stmt::ExportLet(name~, expr~, ..) => {
        collect_free_vars_expr_gc(expr, bound, free)
        bound[name] = true
      }
      @core.Stmt::InternalExportLet(name~, expr~, ..) => {
        collect_free_vars_expr_gc(expr, bound, free)
        bound[name] = true
      }
      @core.Stmt::LetMut(name~, expr~, ..) => {
        collect_free_vars_expr_gc(expr, bound, free)
        bound[name] = true
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
    if not(top_level_funcs.contains(name)) &&
      not(enum_ctor_names.contains(name)) &&
      not(is_gc_builtin_name(name)) {
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
  name.has_prefix("Bytes::") ||
  // Common builtins
  name == "add" ||
  name == "sub" ||
  name == "mul" ||
  name == "div" ||
  name == "eq" ||
  name == "lt" ||
  name == "not" ||
  name == "neg" ||
  name == "println" ||
  name == "print" ||
  name == "abort" ||
  name == "throw" ||
  name == "record_set"
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
    _ => ()
  }
}

///|
fn gc_val_kind_from_type(
  ctx : GcCodegenCtx,
  ty : @core.Type,
) -> GcValKind raise WasmGenError {
  match ty {
    @core.Type::Int => GcValKind::I64
    @core.Type::Float => GcValKind::F32
    @core.Type::Double => GcValKind::F64
    @core.Type::Bool => GcValKind::I32
    @core.Type::Unit => GcValKind::I32
    @core.Type::String => GcValKind::Ref(ctx.string_type)
    @core.Type::Bytes => GcValKind::Ref(ctx.bytes_type)
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
            // User-defined enum/struct types → eqref
            GcValKind::EqRef
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
      // Unresolved type parameter — treat as anyref in GC mode
      GcValKind::AnyRef
    @core.Type::Variant(_) => GcValKind::EqRef
    _ => raise WasmGenError::Unsupported("gc type: " + ty.to_string())
  }
}

///|
fn GcFuncCtx::new(
  ctx : GcCodegenCtx,
  params : Array[@core.FuncParam],
) -> GcFuncCtx raise WasmGenError {
  let locals : Map[String, GcLocalInfo] = {}
  let local_kinds : Array[GcValKind] = []
  let mut idx = 0
  for param in params {
    let kind = gc_val_kind_from_type(ctx, param.ty)
    locals[param.name] = { idx, kind }
    idx += 1
  }
  { locals, local_kinds, param_count: idx, closure_call_types: {} }
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
    local_kinds: [],
    param_count: fctx.param_count,
    closure_call_types: temp_cct,
  }
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
              let kind = infer_expr_kind_gc(ctx, temp_ctx, expr)
              temp_ctx.locals[name] = { idx: 0, kind }
              if is_last {
                return kind
              }
            }
          }
        } else {
          let kind = infer_expr_kind_gc(ctx, temp_ctx, expr)
          temp_ctx.locals[name] = { idx: 0, kind }
          track_closure_binding_gc(ctx, temp_ctx, name, expr)
          if is_last {
            return kind
          }
        }
      @core.Stmt::LetMut(name~, expr~, ..) => {
        let kind = infer_expr_kind_gc(ctx, temp_ctx, expr)
        temp_ctx.locals[name] = { idx: 0, kind }
        track_closure_binding_gc(ctx, temp_ctx, name, expr)
        if is_last {
          return kind
        }
      }
      @core.Stmt::Assign(name~, expr~, ..) => {
        let kind = infer_expr_kind_gc(ctx, temp_ctx, expr)
        temp_ctx.locals[name] = { idx: 0, kind }
        if is_last {
          return kind
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
  for field in ordered {
    kinds.push(infer_expr_kind_gc(ctx, fctx, field.expr))
  }
  let type_idx = ensure_struct_type(ctx.types, ctx.struct_type_index, kinds)
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
    _ => raise WasmGenError::Unsupported("for-in iterable kind")
  }
  let iterable_elem_kind = match ctx.types[iterable_type_idx] {
    GcTypeDef::Array(elem~) => elem
    _ => raise WasmGenError::Unsupported("for-in iterable type")
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
            let param_kinds : Array[GcValKind] = []
            for _ in 0..<param_count {
              param_kinds.push(GcValKind::I64)
            }
            let (_, struct_type_idx) = ensure_closure_types_gc(
              ctx, param_kinds, result_kind,
            )
            GcValKind::Ref(struct_type_idx)
          } else {
            raise WasmGenError::UnknownName(name)
          }
      }
    @core.Expr::Call(name~, args~, ..) => {
      let name = @core.lower_wasm_intrinsic_name(name)
      let pos_args = extract_positional_exprs(args, name)
      match name {
        "add" | "sub" | "mul" | "div" => GcValKind::I64
        "eq" | "lt" => GcValKind::I32
        "__len" => GcValKind::I64
        "__index" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("arity: __index")
          }
          let base_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          if base_kind == GcValKind::Ref(ctx.string_type) {
            GcValKind::I64
          } else if base_kind == GcValKind::Ref(ctx.bytes_type) {
            GcValKind::I64
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
        | "String::from_char_code" => GcValKind::Ref(ctx.string_type)
        "Int::to_double" => GcValKind::F64
        "Double::to_int" => GcValKind::I64
        "Double::parse" => GcValKind::F64
        "Array::length" => GcValKind::I64
        "Array::get" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("arity: Array::get")
          }
          gc_array_elem_kind_from_kind(
            ctx,
            infer_expr_kind_gc(ctx, fctx, pos_args[0]),
            "Array::get",
          )
        }
        "Array::set" | "Array::push" => GcValKind::I32
        "Array::slice" | "Array::concat" => {
          if pos_args.length() < 1 {
            raise WasmGenError::Unsupported("arity: " + name)
          }
          infer_expr_kind_gc(ctx, fctx, pos_args[0])
        }
        "ArrayBuilder::new" => {
          // Return concrete builder struct type: { i32, ref array<i64> }
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
        "MapBuilder::new" | "MapBuilder::freeze" => {
          let key_arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::EqRef,
          )
          let val_arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::I64,
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
        "Map::get" => GcValKind::I64
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
        | "String::last_index_of" => GcValKind::I64
        "Bytes::length" | "Bytes::get" => GcValKind::I64
        "Bytes::new" | "Bytes::from_array" | "Bytes::slice" | "Bytes::concat" =>
          GcValKind::Ref(ctx.bytes_type)
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
                  } else {
                    raise WasmGenError::UnknownName(name)
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
      let kind = infer_expr_kind_gc(ctx, fctx, arms[0].expr)
      restore_locals_gc(fctx, saved)
      for i in 1..<arms.length() {
        let saved_arm = clone_locals_gc(fctx.locals)
        bind_pat_kinds_gc(ctx, fctx, scrut_kind, arms[i].pat)
        let arm_kind = infer_expr_kind_gc(ctx, fctx, arms[i].expr)
        restore_locals_gc(fctx, saved_arm)
        if arm_kind != kind {
          raise WasmGenError::Unsupported("match kind mismatch")
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
    _ => raise WasmGenError::Unsupported("expr")
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
}

///|
fn compile_string_concat(
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
  emit_local_set_gc(buf, a_idx)
  compile_expr_gc(ctx, fctx, buf, b_expr)
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
  compile_expr_gc(ctx, fctx, buf, a_expr)
  emit_local_set_gc(buf, a_idx)
  compile_expr_gc(ctx, fctx, buf, b_expr)
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
    GcValKind::EqRef => {
      // Unknown ref type — try array.len, trap at runtime if not array
      compile_expr_gc(ctx, fctx, buf, expr)
      emit_array_len_gc(buf)
      emit_i64_extend_i32_s_gc(buf)
    }
    _ => raise WasmGenError::Unsupported("__len kind")
  }
}

///|
fn gc_array_type_idx_from_kind(
  ctx : GcCodegenCtx,
  kind : GcValKind,
  opname : String,
) -> Int raise WasmGenError {
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
            raise WasmGenError::Unsupported(opname + " kind")
          }
        _ => raise WasmGenError::Unsupported(opname + " kind")
      }
    GcValKind::EqRef =>
      // Unknown ref type, default to I64 array
      ensure_array_type(ctx.types, ctx.array_type_index, GcValKind::I64)
    _ => raise WasmGenError::Unsupported(opname + " kind")
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
  emit_local_set_gc(buf, start_idx)
  compile_expr_gc(ctx, fctx, buf, end_expr)
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
  if left_kind != right_kind {
    raise WasmGenError::Unsupported(opname + " kind mismatch")
  }
  let type_idx = gc_array_type_idx_from_kind(ctx, left_kind, opname)
  let left_idx = alloc_local_gc(fctx, left_kind)
  let right_idx = alloc_local_gc(fctx, right_kind)
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
    if not(saved.contains(name)) {
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
        _ => return
      }
      let field_kinds = match ctx.types[type_idx] {
        GcTypeDef::Struct(fields~) => fields
        _ => return
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
        _ => raise WasmGenError::Unsupported("pat int kind")
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
      let _ = items
      // Tuples always match structurally (no tag check needed)
      emit_i32_const_gc(buf, 1)
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
              _ => ()
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
        _ => return
      }
      let field_kinds = match ctx.types[type_idx] {
        GcTypeDef::Struct(fields~) => fields
        _ => return
      }
      for i in 0..<items.length() {
        let item = items[i]
        match item {
          @core.Pat::Wildcard(..) => ()
          @core.Pat::Bind(name~, span~) => {
            let _ = span
            let kind = if i < field_kinds.length() {
              field_kinds[i]
            } else {
              GcValKind::EqRef
            }
            let idx = bind_local_gc(fctx, name, kind)
            emit_local_get_gc(buf, scrut_idx)
            emit_struct_get_gc(buf, type_idx, i)
            emit_local_set_gc(buf, idx)
          }
          _ => ()
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
  compile_pat_bind_gc(ctx, fctx, buf, scrut_idx, scrut_kind, arm.pat)
  compile_expr_gc(ctx, fctx, buf, arm.expr)
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
            let param_kinds : Array[GcValKind] = []
            for _ in 0..<param_count {
              param_kinds.push(GcValKind::I64)
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
            for _ in 0..<param_count {
              wrapper_sig_params.push(GcValKind::I64)
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
            emit_ref_func_gc(buf, wrapper_idx)
            // Empty environment struct
            let env_type_idx = ensure_struct_type(
              ctx.types,
              ctx.struct_type_index,
              [],
            )
            emit_struct_new_gc(buf, env_type_idx)
            emit_struct_new_gc(buf, struct_type_idx)
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
      match name {
        "add" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("add arity")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_i64_add_gc(buf)
        }
        "sub" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("sub arity")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_i64_sub_gc(buf)
        }
        "mul" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("mul arity")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_i64_mul_gc(buf)
        }
        "div" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("div arity")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_i64_div_s_gc(buf)
        }
        "eq" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("eq arity")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_i64_eq_gc(buf)
        }
        "lt" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("lt arity")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_i64_lt_s_gc(buf)
        }
        "__add" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__add arity")
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let left_kind = if left_kind == right_kind {
            left_kind
          } else {
            gc_common_kind(left_kind, right_kind)
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          match left_kind {
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
          let left_kind = if left_kind == right_kind {
            left_kind
          } else {
            gc_common_kind(left_kind, right_kind)
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          match left_kind {
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
          let left_kind = if left_kind == right_kind {
            left_kind
          } else {
            gc_common_kind(left_kind, right_kind)
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          match left_kind {
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
          let left_kind = if left_kind == right_kind {
            left_kind
          } else {
            gc_common_kind(left_kind, right_kind)
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          match left_kind {
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
          let left_kind = if left_kind == right_kind {
            left_kind
          } else {
            gc_common_kind(left_kind, right_kind)
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          match left_kind {
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
          let left_kind = if left_kind == right_kind {
            left_kind
          } else {
            gc_common_kind(left_kind, right_kind)
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          match left_kind {
            GcValKind::I64 => emit_i64_eq_gc(buf)
            GcValKind::I32 => emit_i32_eq_gc(buf)
            GcValKind::F32 => emit_f32_eq_gc(buf)
            GcValKind::F64 => emit_f64_eq_gc(buf)
            _ => emit_i64_eq_gc(buf)
          }
        }
        "__lt" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__lt arity")
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          let left_kind = if left_kind == right_kind {
            left_kind
          } else {
            gc_common_kind(left_kind, right_kind)
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          match left_kind {
            GcValKind::I64 => emit_i64_lt_s_gc(buf)
            GcValKind::I32 => emit_i32_lt_s_gc(buf)
            GcValKind::F32 => emit_f32_lt_gc(buf)
            GcValKind::F64 => emit_f64_lt_gc(buf)
            _ => emit_i64_lt_s_gc(buf)
          }
        }
        "__neg" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("__neg arity")
          }
          let kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          match kind {
            GcValKind::I64 => {
              emit_i64_const_gc(buf, 0L)
              compile_expr_gc(ctx, fctx, buf, pos_args[0])
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
            _ => emit_i64_add_gc(buf)
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
          let base_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          if base_kind == GcValKind::Ref(ctx.string_type) {
            compile_string_char_code_at(
              ctx,
              fctx,
              buf,
              pos_args[0],
              pos_args[1],
            )
          } else if base_kind == GcValKind::Ref(ctx.bytes_type) {
            compile_bytes_get_gc(ctx, fctx, buf, pos_args[0], pos_args[1])
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
            compile_bytes_set_gc(ctx, fctx, buf, pos_args[0], pos_args[1], pos_args[2])
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
        "String::length" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("String::length arity")
          }
          compile_len_gc(ctx, fctx, buf, pos_args[0])
        }
        "Bytes::length" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("Bytes::length arity")
          }
          compile_bytes_length_gc(ctx, fctx, buf, pos_args[0])
        }
        "Bytes::new" => compile_bytes_new_gc(ctx, buf)
        "Bytes::from_array" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("Bytes::from_array arity")
          }
          compile_bytes_from_array_gc(ctx, fctx, buf, pos_args[0])
        }
        "Bytes::get" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("Bytes::get arity")
          }
          compile_bytes_get_gc(ctx, fctx, buf, pos_args[0], pos_args[1])
        }
        "Bytes::set" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("Bytes::set arity")
          }
          compile_bytes_set_gc(
            ctx,
            fctx,
            buf,
            pos_args[0],
            pos_args[1],
            pos_args[2],
          )
        }
        "Bytes::push" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("Bytes::push arity")
          }
          compile_bytes_push_gc(ctx, fctx, buf, pos_args[0], pos_args[1])
        }
        "Bytes::append" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("Bytes::append arity")
          }
          compile_bytes_append_gc(ctx, fctx, buf, pos_args[0], pos_args[1])
        }
        "Bytes::slice" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("Bytes::slice arity")
          }
          compile_bytes_slice_gc(
            ctx,
            fctx,
            buf,
            pos_args[0],
            pos_args[1],
            pos_args[2],
          )
        }
        "Bytes::concat" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("Bytes::concat arity")
          }
          compile_bytes_concat_gc(ctx, fctx, buf, pos_args[0], pos_args[1])
        }
        "Bytes::blit" => {
          if pos_args.length() != 4 {
            raise WasmGenError::Unsupported("Bytes::blit arity")
          }
          compile_bytes_blit_gc(
            ctx,
            fctx,
            buf,
            pos_args[0],
            pos_args[1],
            pos_args[2],
            pos_args[3],
          )
        }
        "Bytes::fill" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("Bytes::fill arity")
          }
          compile_bytes_fill_gc(
            ctx,
            fctx,
            buf,
            pos_args[0],
            pos_args[1],
            pos_args[2],
          )
        }
        "Bytes::to_array" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("Bytes::to_array arity")
          }
          compile_bytes_to_array_gc(ctx, fctx, buf, pos_args[0])
        }
        "String::char_code_at" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("String::char_code_at arity")
          }
          compile_string_char_code_at(ctx, fctx, buf, pos_args[0], pos_args[1])
        }
        "String::substring" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("String::substring arity")
          }
          compile_string_substring(
            ctx,
            fctx,
            buf,
            pos_args[0],
            pos_args[1],
            pos_args[2],
          )
        }
        "String::concat" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("String::concat arity")
          }
          compile_string_concat(ctx, fctx, buf, pos_args[0], pos_args[1])
        }
        "String::equals" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("String::equals arity")
          }
          compile_string_equals(ctx, fctx, buf, pos_args[0], pos_args[1])
        }
        "String::index_of" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("String::index_of arity")
          }
          compile_string_index_of(ctx, fctx, buf, pos_args[0], pos_args[1])
        }
        "String::last_index_of" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("String::last_index_of arity")
          }
          compile_string_last_index_of(ctx, fctx, buf, pos_args[0], pos_args[1])
        }
        "String::contains" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("String::contains arity")
          }
          compile_string_contains(ctx, fctx, buf, pos_args[0], pos_args[1])
        }
        "String::starts_with" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("String::starts_with arity")
          }
          compile_string_starts_with(ctx, fctx, buf, pos_args[0], pos_args[1])
        }
        "String::ends_with" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("String::ends_with arity")
          }
          compile_string_ends_with(ctx, fctx, buf, pos_args[0], pos_args[1])
        }
        "String::trim" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("String::trim arity")
          }
          compile_string_trim(ctx, fctx, buf, pos_args[0])
        }
        "String::replace" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("String::replace arity")
          }
          compile_string_replace(
            ctx,
            fctx,
            buf,
            pos_args[0],
            pos_args[1],
            pos_args[2],
          )
        }
        "String::split" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("String::split arity")
          }
          compile_string_split(ctx, fctx, buf, pos_args[0], pos_args[1])
        }
        "String::join" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("String::join arity")
          }
          compile_string_join(ctx, fctx, buf, pos_args[0], pos_args[1])
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
        "Int::to_double" => {
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_f64_convert_i64_s_gc(buf)
        }
        "Double::to_int" => {
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_i64_trunc_f64_s_gc(buf)
        }
        "Double::parse" => {
          // Stub: drop string arg, return 0.0
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_drop_gc(buf)
          emit_f64_const_gc(buf, 0.0)
        }
        "String::from_char_code" => {
          // Build 1-char string: struct(len=1, data=array[charcode])
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          let ck = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          if ck == GcValKind::I64 {
            emit_i32_wrap_i64_gc(buf)
          }
          emit_array_new_fixed_gc(buf, ctx.array_i32_type, 1)
          let arr_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
          emit_local_set_gc(buf, arr_idx)
          emit_i32_const_gc(buf, 1)
          emit_local_get_gc(buf, arr_idx)
          emit_struct_new_gc(buf, ctx.string_type)
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
        "Array::get" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("Array::get arity")
          }
          let arr_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let type_idx = gc_array_type_idx_from_kind(
            ctx, arr_kind, "Array::get",
          )
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
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
          // GC arrays are fixed-size; create new array of len+1 with copy
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("Array::push arity")
          }
          let arr_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
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
          emit_i32_const_gc(buf, 0)
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
        "ArrayBuilder::new" => {
          // Create struct { len: i32, data: ref array<i64> }
          let init_cap = 8
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
          emit_i32_const_gc(buf, 0)
          emit_i32_const_gc(buf, init_cap)
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
            _ => raise WasmGenError::Unsupported("ArrayBuilder::push kind")
          }
          let arr_type = match ctx.types[builder_type] {
            GcTypeDef::Struct(fields~) =>
              match fields[1] {
                GcValKind::Ref(idx) => idx
                _ => raise WasmGenError::Unsupported("ArrayBuilder field")
              }
            _ => raise WasmGenError::Unsupported("ArrayBuilder type")
          }
          let b_idx = alloc_local_gc(fctx, builder_kind)
          let len_l = alloc_local_gc(fctx, GcValKind::I32)
          let cap_l = alloc_local_gc(fctx, GcValKind::I32)
          let data_l = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
          let new_data = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
          let i_l = alloc_local_gc(fctx, GcValKind::I32)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
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
          // new capacity = cap * 2
          emit_local_get_gc(buf, cap_l)
          emit_i32_const_gc(buf, 2)
          emit_i32_mul_gc(buf)
          emit_array_new_default_gc(buf, arr_type)
          emit_local_set_gc(buf, new_data)
          // copy
          emit_i32_const_gc(buf, 0)
          emit_local_set_gc(buf, i_l)
          emit_block_gc(buf, None)
          emit_loop_gc(buf, None)
          emit_local_get_gc(buf, i_l)
          emit_local_get_gc(buf, len_l)
          emit_i32_ge_s_gc(buf)
          emit_br_if_gc(buf, 1)
          emit_local_get_gc(buf, new_data)
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
          // update struct
          emit_local_get_gc(buf, b_idx)
          emit_local_get_gc(buf, new_data)
          emit_struct_set_gc(buf, builder_type, 1)
          emit_local_get_gc(buf, new_data)
          emit_local_set_gc(buf, data_l)
          emit_end_gc(buf)
          // data[len] = val
          emit_local_get_gc(buf, data_l)
          emit_local_get_gc(buf, len_l)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          emit_array_set_gc(buf, arr_type)
          // len++
          emit_local_get_gc(buf, b_idx)
          emit_local_get_gc(buf, len_l)
          emit_i32_const_gc(buf, 1)
          emit_i32_add_gc(buf)
          emit_struct_set_gc(buf, builder_type, 0)
          emit_i32_const_gc(buf, 0)
        }
        "ArrayBuilder::freeze" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("ArrayBuilder::freeze arity")
          }
          let builder_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let builder_type = match builder_kind {
            GcValKind::Ref(idx) => idx
            _ => raise WasmGenError::Unsupported("ArrayBuilder::freeze kind")
          }
          let arr_type = match ctx.types[builder_type] {
            GcTypeDef::Struct(fields~) =>
              match fields[1] {
                GcValKind::Ref(idx) => idx
                _ => raise WasmGenError::Unsupported("ArrayBuilder field")
              }
            _ => raise WasmGenError::Unsupported("ArrayBuilder type")
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
        "MapBuilder::new" => {
          // Map: struct { len: i32, keys: ref array<ref string>, vals: ref array<i64> }
          let init_cap = 8
          let key_arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::EqRef,
          )
          let val_arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::I64,
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
            GcValKind::I64,
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
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
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
          let val_l = alloc_local_gc(fctx, GcValKind::I64)
          // Compile value once and save to local
          compile_expr_gc(ctx, fctx, buf, pos_args[2])
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
          emit_local_get_gc(buf, keys_l)
          emit_local_get_gc(buf, i_l)
          emit_array_get_gc(buf, key_arr_type)
          emit_local_get_gc(buf, key_l)
          emit_ref_eq_gc(buf)
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
        "Map::get" => {
          // Map::get(map, key) -> eqref (None encoded as i31ref 0)
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("Map::get arity")
          }
          let key_arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::EqRef,
          )
          let val_arr_type = ensure_array_type(
            ctx.types,
            ctx.array_type_index,
            GcValKind::I64,
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
          let keys_l = alloc_local_gc(fctx, GcValKind::Ref(key_arr_type))
          let vals_l = alloc_local_gc(fctx, GcValKind::Ref(val_arr_type))
          let i_l = alloc_local_gc(fctx, GcValKind::I32)
          let key_l = alloc_local_gc(fctx, GcValKind::EqRef)
          let result_l = alloc_local_gc(fctx, GcValKind::I64)
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_local_set_gc(buf, b_idx)
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
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
          // Linear search with result in local
          emit_i32_const_gc(buf, 0)
          emit_local_set_gc(buf, i_l)
          // block $done
          emit_block_gc(buf, None)
          // loop $search
          emit_loop_gc(buf, None)
          emit_local_get_gc(buf, i_l)
          emit_local_get_gc(buf, len_l)
          emit_i32_ge_s_gc(buf)
          emit_br_if_gc(buf, 1) // br $done (not found)
          emit_local_get_gc(buf, keys_l)
          emit_local_get_gc(buf, i_l)
          emit_array_get_gc(buf, key_arr_type)
          emit_local_get_gc(buf, key_l)
          emit_ref_eq_gc(buf)
          emit_if_gc(buf, None)
          // Found: store vals[i] and break
          emit_local_get_gc(buf, vals_l)
          emit_local_get_gc(buf, i_l)
          emit_array_get_gc(buf, val_arr_type)
          emit_local_set_gc(buf, result_l)
          emit_br_gc(buf, 2) // br $done
          emit_end_gc(buf) // end if
          emit_local_get_gc(buf, i_l)
          emit_i32_const_gc(buf, 1)
          emit_i32_add_gc(buf)
          emit_local_set_gc(buf, i_l)
          emit_br_gc(buf, 0) // br $search
          emit_end_gc(buf) // end loop
          emit_end_gc(buf) // end $done
          // result_l has the value (or default null eqref if not found)
          emit_local_get_gc(buf, result_l)
        }
        _ =>
          match ctx.func_indices.get(name) {
            Some(idx) => {
              match ctx.func_param_counts.get(name) {
                Some(count) =>
                  if pos_args.length() != count {
                    raise WasmGenError::Unsupported("arity: " + name)
                  }
                None => ()
              }
              for arg in pos_args {
                compile_expr_gc(ctx, fctx, buf, arg)
              }
              emit_call_gc(buf, idx)
            }
            None =>
              if ctx.enum_ctor_tags.contains(name) {
                // Enum constructor call
                let tag = ctx.enum_ctor_tags[name]
                let type_idx = if name == "Some" && pos_args.length() == 1 {
                  // Polymorphic Some: create per-call struct type
                  let val_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
                  let fields : Array[GcValKind] = [GcValKind::I32, val_kind]
                  ensure_struct_type(
                    ctx.types,
                    ctx.struct_type_index,
                    fields,
                  )
                } else {
                  ctx.enum_ctor_type_indices[name]
                }
                emit_i32_const_gc(buf, tag)
                for arg in pos_args {
                  compile_expr_gc(ctx, fctx, buf, arg)
                }
                emit_struct_new_gc(buf, type_idx)
              } else if name == "Some" && pos_args.length() == 1 {
                // Builtin Some(value): wrap in ad-hoc struct {tag=1, payload}
                let val_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
                let fields : Array[GcValKind] = [GcValKind::I32, val_kind]
                let type_idx = ensure_struct_type(
                  ctx.types,
                  ctx.struct_type_index,
                  fields,
                )
                emit_i32_const_gc(buf, 1) // tag = 1 (Some)
                compile_expr_gc(ctx, fctx, buf, pos_args[0])
                emit_struct_new_gc(buf, type_idx)
              } else if name == "None" && pos_args.length() == 0 {
                // Builtin None: nullary struct {tag=0}
                let fields : Array[GcValKind] = [GcValKind::I32]
                let type_idx = ensure_struct_type(
                  ctx.types,
                  ctx.struct_type_index,
                  fields,
                )
                emit_i32_const_gc(buf, 0) // tag = 0 (None)
                emit_struct_new_gc(buf, type_idx)
              } else {
                match fctx.closure_call_types.get(name) {
                  Some(fn_type_idx) =>
                    match fctx.locals.get(name) {
                      Some(closure_info) => {
                        let closure_struct_type = match closure_info.kind {
                          GcValKind::Ref(idx) => idx
                          _ => raise WasmGenError::Unsupported("closure kind")
                        }
                        emit_local_get_gc(buf, closure_info.idx)
                        emit_struct_get_gc(buf, closure_struct_type, 1)
                        for arg in pos_args {
                          compile_expr_gc(ctx, fctx, buf, arg)
                        }
                        emit_local_get_gc(buf, closure_info.idx)
                        emit_struct_get_gc(buf, closure_struct_type, 0)
                        emit_call_ref_gc(buf, fn_type_idx)
                      }
                      None => raise WasmGenError::UnknownName(name)
                    }
                  None => raise WasmGenError::UnknownName(name)
                }
              }
          }
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      compile_expr_gc(ctx, fctx, buf, cond)
      let then_kind = infer_block_kind_gc(ctx, fctx, then_body)
      let else_kind = infer_block_kind_gc(ctx, fctx, else_body)
      let result_kind = if then_kind == else_kind {
        then_kind
      } else {
        gc_common_kind(then_kind, else_kind)
      }
      emit_if_gc(buf, Some(result_kind))
      compile_block_expr_gc(ctx, fctx, buf, then_body)
      emit_else_gc(buf)
      compile_block_expr_gc(ctx, fctx, buf, else_body)
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
      let result_kind = infer_expr_kind_gc(ctx, fctx, arms[0].expr)
      restore_locals_gc(fctx, saved)
      for i in 1..<arms.length() {
        let saved_arm = clone_locals_gc(fctx.locals)
        bind_pat_kinds_gc(ctx, fctx, scrut_kind, arms[i].pat)
        let arm_kind = infer_expr_kind_gc(ctx, fctx, arms[i].expr)
        restore_locals_gc(fctx, saved_arm)
        if arm_kind != result_kind {
          // Allow mismatched types by unifying to common supertype
          ()
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
    @core.Expr::Fn(params~, ret~, body~, ..) => {
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
      // Also capture closure-typed call targets (let rec self-reference)
      let call_names : Map[String, Bool] = {}
      collect_call_names_module_gc(body, call_names)
      for cname, _ in call_names {
        if fctx.closure_call_types.contains(cname) &&
          not(bound.contains(cname)) &&
          not(free.contains(cname)) {
          free[cname] = true
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
      // Propagate closure_call_types from parent so let-rec and
      // captured closures can be called inside the lifted body.
      let lifted_closure_types : Map[String, Int] = {}
      for k, v in fctx.closure_call_types {
        lifted_closure_types[k] = v
      }
      let lifted_fctx = GcFuncCtx::{
        locals: {},
        local_kinds: [],
        param_count: 1 + params.length(),
        closure_call_types: lifted_closure_types,
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
      let func_idx = ctx.num_regular_funcs + ctx.closure_lifted_funcs.length()
      ctx.closure_lifted_funcs.push(GcWasmFunc::{
        sig: lifted_sig,
        locals: lifted_fctx.local_kinds,
        body: lifted_buf.to_array(),
        type_idx: fn_type_idx,
      })
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
      buf.push(0x08) // throw opcode
      write_u32_leb_gc(buf, ctx.error_tag_index)
    }
    @core.Expr::Perform(effect_name~, op_name~, args~, span~) => {
      let _ = span
      let _ = args
      raise WasmGenError::Unsupported(
        "perform " + effect_name + "::" + op_name,
      )
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
      // Bind error name if pattern is Error(e) or Bind(e)
      let saved_locals = clone_locals_gc(fctx.locals)
      match catch_arm.pat {
        @core.Pat::Bind(name~, ..) => {
          let idx = alloc_local_gc(fctx, GcValKind::EqRef)
          emit_local_get_gc(buf, error_local)
          emit_local_set_gc(buf, idx)
          fctx.locals[name] = { idx, kind: GcValKind::EqRef }
        }
        @core.Pat::Ctor(name="Error", args~, ..) if args.length() > 0 =>
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
        other =>
          @core.Module::{ stmts: [@core.Stmt::Expr(expr=other, span~)] }
      }
      compile_block_expr_gc(ctx, fctx, buf, catch_body)
      restore_locals_gc(fctx, saved_locals)
      // end $outer
      emit_end_gc(buf)
    }
    @core.Expr::StringInterp(parts~, span~) => {
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
            @core.StringInterpPart::Lit(s) =>
              @core.Expr::String(value=s, span~)
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
          let acc_local = alloc_local_gc(
            fctx,
            GcValKind::Ref(ctx.string_type),
          )
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
    }
    @core.Expr::TupleIndex(expr~, index~, span~) => {
      let _ = span
      let kind = infer_expr_kind_gc(ctx, fctx, expr)
      let type_idx = match kind {
        GcValKind::Ref(idx) => idx
        _ => raise WasmGenError::Unsupported("tuple index kind")
      }
      compile_expr_gc(ctx, fctx, buf, expr)
      emit_struct_get_gc(buf, type_idx, index)
    }
    _ => raise WasmGenError::Unsupported("expr")
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
            compile_expr_gc(ctx, fctx, buf, expr)
            if is_last {
              emit_local_tee_gc(buf, idx)
            } else {
              emit_local_set_gc(buf, idx)
            }
          }
          _ => {
            let kind = infer_expr_kind_gc(ctx, fctx, expr)
            let idx = bind_local_gc(fctx, name, kind)
            track_closure_binding_gc(ctx, fctx, name, expr)
            compile_expr_gc(ctx, fctx, buf, expr)
            if is_last {
              emit_local_tee_gc(buf, idx)
            } else {
              emit_local_set_gc(buf, idx)
            }
          }
        }
      } else {
        let kind = infer_expr_kind_gc(ctx, fctx, expr)
        let idx = bind_local_gc(fctx, name, kind)
        track_closure_binding_gc(ctx, fctx, name, expr)
        compile_expr_gc(ctx, fctx, buf, expr)
        if is_last {
          emit_local_tee_gc(buf, idx)
        } else {
          emit_local_set_gc(buf, idx)
        }
      }
    @core.Stmt::LetMut(name~, expr~, ..) => {
      let kind = infer_expr_kind_gc(ctx, fctx, expr)
      let idx = bind_local_gc(fctx, name, kind)
      track_closure_binding_gc(ctx, fctx, name, expr)
      compile_expr_gc(ctx, fctx, buf, expr)
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
      if not(is_last) {
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
  // Collect top-level names that are safe for free-var filtering:
  // - Fn definitions (extracted as wasm functions)
  // - Simple literal constants (compiled as wasm globals)
  let top_func_names : Map[String, Bool] = {}
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..)
      | @core.Stmt::ExportLet(name~, expr~, ..)
      | @core.Stmt::InternalExportLet(name~, expr~, ..) =>
        match expr {
          @core.Expr::Fn(..)
          | @core.Expr::Int(..)
          | @core.Expr::Bool(..)
          | @core.Expr::String(..) => top_func_names[name] = true
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
        match expr {
          @core.Expr::Fn(params~, ret~, body~, ..) =>
            if not(
                has_free_vars_gc(body, params, top_func_names, enum_ctor_names~),
              ) {
              funcs.push({ name, params, ret, body })
            }
          _ => ()
        }
      }
      @core.Stmt::ExportLet(rec~, name~, expr~, ..) => {
        let _ = rec
        match expr {
          @core.Expr::Fn(params~, ret~, body~, ..) =>
            if not(
                has_free_vars_gc(body, params, top_func_names, enum_ctor_names~),
              ) {
              funcs.push({ name, params, ret, body })
            }
          _ => ()
        }
      }
      @core.Stmt::InternalExportLet(rec~, name~, expr~, ..) => {
        let _ = rec
        match expr {
          @core.Expr::Fn(params~, ret~, body~, ..) =>
            if not(
                has_free_vars_gc(body, params, top_func_names, enum_ctor_names~),
              ) {
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
        match expr {
          @core.Expr::Fn(..) =>
            if not(collected.contains(name)) {
              stmts.push(stmt)
            }
          _ => stmts.push(stmt)
        }
      @core.Stmt::ExportLet(name~, expr~, ..) =>
        match expr {
          @core.Expr::Fn(..) =>
            if not(collected.contains(name)) {
              stmts.push(stmt)
            }
          _ => stmts.push(stmt)
        }
      @core.Stmt::InternalExportLet(name~, expr~, ..) =>
        match expr {
          @core.Expr::Fn(..) =>
            if not(collected.contains(name)) {
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
  let result_kind = match def.ret {
    Some(ty) => gc_val_kind_from_type(ctx, ty)
    None => infer_block_kind_gc(ctx, fctx, def.body)
  }
  let sig = GcFuncSig::{ params: [], result: result_kind }
  for param in def.params {
    sig.params.push(gc_val_kind_from_type(ctx, param.ty))
  }
  let buf = GcByteBuf::new()
  compile_block_expr_gc(ctx, fctx, buf, def.body)
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
  global_init_values~ : Array[(GcValKind, Int64)] = [],
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
  // Global section (section 6): compile-time constants
  if global_init_values.length() > 0 {
    let global_sec = GcByteBuf::new()
    write_u32_leb_gc(global_sec, global_init_values.length())
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
          global_sec.push(0x41) // i32.const 0 fallback
          write_i32_leb_gc(global_sec, 0)
        }
      }
      global_sec.push(0x0b) // end
    }
    write_section_gc(buf, 6, global_sec.to_array())
  }
  // Tag section (section 13): error tag for throw/catch
  // Must appear between func(3) and export(7) per exception handling proposal
  let tag_sec = GcByteBuf::new()
  write_u32_leb_gc(tag_sec, 1) // 1 tag
  tag_sec.push(0x00) // tag attribute: exception
  write_u32_leb_gc(tag_sec, ctx.error_tag_type_index) // type index
  write_section_gc(buf, 13, tag_sec.to_array())
  let export_sec = GcByteBuf::new()
  write_u32_leb_gc(export_sec, 1)
  let name = "_start"
  write_u32_leb_gc(export_sec, name.length())
  for c in name {
    export_sec.push(c.to_int())
  }
  export_sec.push(0x00)
  write_u32_leb_gc(export_sec, run_index)
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
  buf.to_bytes()
}

///|
pub fn emit_module_wasm_gc(ast : @core.Module) -> Bytes raise WasmGenError {
  let ctx = GcCodegenCtx::new()
  scan_enum_defs_gc(ctx, ast)
  // Build enum ctor name set for free-var filtering
  let enum_ctor_names : Map[String, Bool] = {}
  for name, _ in ctx.enum_ctor_tags {
    enum_ctor_names[name] = true
  }
  // Scan for constant let bindings (non-Fn) and register as globals.
  // Only simple literals (Int, Bool) are supported as immutable globals
  // with compile-time known init values.
  let mut global_idx = 0
  let global_init_values : Array[(GcValKind, Int64)] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..)
      | @core.Stmt::ExportLet(name~, expr~, ..)
      | @core.Stmt::InternalExportLet(name~, expr~, ..) =>
        match expr {
          @core.Expr::Fn(..) => () // Functions are extracted, not globals
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
      None => ()
    }
  }
  let wasm_funcs : Array[GcWasmFunc] = []
  for f in funcs {
    let wf = compile_function_gc(ctx, f)
    ctx.func_returns[f.name] = wf.sig.result
    wasm_funcs.push(wf)
  }
  let collected_names : Map[String, Bool] = {}
  for f in funcs {
    collected_names[f.name] = true
  }
  let run_body = filter_top_level_funcs_gc(ast, collected_names)
  let run_func = compile_run_gc(ctx, run_body)
  let run_index = wasm_funcs.length()
  wasm_funcs.push(run_func)
  for lf in ctx.closure_lifted_funcs {
    wasm_funcs.push(lf)
  }
  build_module_gc(ctx, wasm_funcs, run_index, global_init_values~)
}
