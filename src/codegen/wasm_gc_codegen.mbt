///|
priv struct GcByteBuf {
  data : Array[Byte]
}

///|
fn GcByteBuf::new() -> GcByteBuf {
  { data: [] }
}

///|
fn GcByteBuf::push(self : GcByteBuf, b : Int) -> Unit {
  self.data.push(b.to_byte())
}

///|
fn GcByteBuf::extend(self : GcByteBuf, bytes : Array[Byte]) -> Unit {
  for b in bytes {
    self.data.push(b)
  }
}

///|
fn GcByteBuf::len(self : GcByteBuf) -> Int {
  self.data.length()
}

///|
fn GcByteBuf::to_bytes(self : GcByteBuf) -> Bytes {
  Bytes::from_array(self.data)
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
}

///|
priv struct GcWasmFunc {
  sig : GcFuncSig
  locals : Array[GcValKind]
  body : Array[Byte]
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
  {
    types,
    struct_type_index,
    array_type_index,
    func_indices: {},
    func_param_counts: {},
    func_returns: {},
    string_type,
    array_i32_type,
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
fn emit_i64_eq_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x51)
}

///|
fn emit_i64_extend_i32_s_gc(buf : GcByteBuf) -> Unit {
  buf.push(0xac)
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
          "anyref" => GcValKind::AnyRef
          "eqref" => GcValKind::EqRef
          "i31ref" => GcValKind::I31Ref
          "structref" => GcValKind::StructRef
          "arrayref" => GcValKind::ArrayRef
          "funcref" => GcValKind::FuncRef
          "externref" => GcValKind::ExternRef
          _ => raise WasmGenError::Unsupported("gc type: " + name)
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
          // Option, Result, etc. — treat as anyref
          _ => GcValKind::AnyRef
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
    @core.Type::Func(..) =>
      // Function values in GC mode are represented as funcref
      GcValKind::FuncRef
    @core.Type::Param(_) =>
      // Unresolved type parameter — treat as anyref in GC mode
      GcValKind::AnyRef
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
  { locals, local_kinds, param_count: idx }
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
  let temp_ctx = GcFuncCtx::{
    locals: clone_locals_gc(fctx.locals),
    local_kinds: [],
    param_count: fctx.param_count,
  }
  for i in 0..<len {
    let stmt = body.stmts[i]
    let is_last = i == len - 1
    match stmt {
      @core.Stmt::Let(name~, expr~, ..) => {
        let kind = infer_expr_kind_gc(ctx, temp_ctx, expr)
        temp_ctx.locals[name] = { idx: 0, kind }
        if is_last {
          return kind
        }
      }
      @core.Stmt::LetMut(name~, expr~, ..) => {
        let kind = infer_expr_kind_gc(ctx, temp_ctx, expr)
        temp_ctx.locals[name] = { idx: 0, kind }
        if is_last {
          return kind
        }
      }
      @core.Stmt::Assign(name~, expr~, ..) => {
        let kind = infer_expr_kind_gc(ctx, temp_ctx, expr)
        match temp_ctx.locals.get(name) {
          Some(_) => temp_ctx.locals[name] = { idx: 0, kind }
          None => raise WasmGenError::UnknownName(name)
        }
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
    Some(name) => fctx.locals[name] = { idx: 0, kind: GcValKind::I64 }
    None => ()
  }
  let body_kind = infer_block_kind_gc(ctx, fctx, body)
  restore_locals_gc(fctx, saved_locals)
  (iterable_type_idx, iterable_elem_kind, body_kind)
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
        None => raise WasmGenError::UnknownName(name)
      }
    @core.Expr::Call(name~, args~, ..) => {
      let name = @core.lower_wasm_intrinsic_name(name)
      let pos_args = extract_positional_exprs(args, name)
      match name {
        "add" | "sub" | "mul" | "div" => GcValKind::I64
        "eq" | "lt" => GcValKind::I32
        "__index" => GcValKind::I64
        "__add" | "__sub" | "__mul" | "__div" | "__mod" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("arity: " + name)
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          if left_kind != right_kind {
            raise WasmGenError::Unsupported("numeric kind mismatch")
          }
          match left_kind {
            GcValKind::I64 | GcValKind::I32 | GcValKind::F32 | GcValKind::F64 =>
              left_kind
            _ => raise WasmGenError::Unsupported("numeric kind")
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
            _ => raise WasmGenError::Unsupported("numeric kind")
          }
        }
        "__eq" | "__lt" | "String::equals" => GcValKind::I32
        "anyref_eq"
        | "eqref_eq"
        | "i31ref_eq"
        | "structref_eq"
        | "arrayref_eq"
        | "funcref_eq"
        | "externref_eq" => GcValKind::I64
        "String::length" | "String::char_code_at" => GcValKind::I64
        "String::substring" | "String::concat" =>
          GcValKind::Ref(ctx.string_type)
        "record_set" => {
          if pos_args.length() != 3 {
            raise WasmGenError::Unsupported("arity: record_set")
          }
          infer_expr_kind_gc(ctx, fctx, pos_args[0])
        }
        _ =>
          match ctx.func_returns.get(name) {
            Some(kind) => kind
            None => raise WasmGenError::UnknownName(name)
          }
      }
    }
    @core.Expr::If(then_body~, else_body~, ..) => {
      let then_kind = infer_block_kind_gc(ctx, fctx, then_body)
      let else_kind = infer_block_kind_gc(ctx, fctx, else_body)
      if then_kind != else_kind {
        raise WasmGenError::Unsupported("if kind mismatch")
      }
      then_kind
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
    @core.Pat::Record(fields~, span~) => {
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
    _ => ()
  }
}

///|
fn compile_pat_cond_gc(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  scrut_idx : Int,
  scrut_kind : GcValKind,
  pat : @core.Pat,
) -> Unit raise WasmGenError {
  let _ = ctx
  let _ = fctx
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
    @core.Pat::Record(fields~, span~) => {
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
    @core.Pat::Record(fields~, span~) => {
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
        None => raise WasmGenError::UnknownName(name)
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
          if left_kind != right_kind {
            raise WasmGenError::Unsupported("numeric kind mismatch")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          match left_kind {
            GcValKind::I64 => emit_i64_add_gc(buf)
            GcValKind::I32 => emit_i32_add_gc(buf)
            GcValKind::F32 => emit_f32_add_gc(buf)
            GcValKind::F64 => emit_f64_add_gc(buf)
            _ => raise WasmGenError::Unsupported("numeric kind")
          }
        }
        "__sub" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__sub arity")
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          if left_kind != right_kind {
            raise WasmGenError::Unsupported("numeric kind mismatch")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          match left_kind {
            GcValKind::I64 => emit_i64_sub_gc(buf)
            GcValKind::I32 => emit_i32_sub_gc(buf)
            GcValKind::F32 => emit_f32_sub_gc(buf)
            GcValKind::F64 => emit_f64_sub_gc(buf)
            _ => raise WasmGenError::Unsupported("numeric kind")
          }
        }
        "__mul" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__mul arity")
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          if left_kind != right_kind {
            raise WasmGenError::Unsupported("numeric kind mismatch")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          match left_kind {
            GcValKind::I64 => emit_i64_mul_gc(buf)
            GcValKind::I32 => emit_i32_mul_gc(buf)
            GcValKind::F32 => emit_f32_mul_gc(buf)
            GcValKind::F64 => emit_f64_mul_gc(buf)
            _ => raise WasmGenError::Unsupported("numeric kind")
          }
        }
        "__div" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__div arity")
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          if left_kind != right_kind {
            raise WasmGenError::Unsupported("numeric kind mismatch")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          match left_kind {
            GcValKind::I64 => emit_i64_div_s_gc(buf)
            GcValKind::I32 => emit_i32_div_s_gc(buf)
            GcValKind::F32 => emit_f32_div_gc(buf)
            GcValKind::F64 => emit_f64_div_gc(buf)
            _ => raise WasmGenError::Unsupported("numeric kind")
          }
        }
        "__mod" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__mod arity")
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          if left_kind != right_kind {
            raise WasmGenError::Unsupported("numeric kind mismatch")
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
          if left_kind != right_kind {
            raise WasmGenError::Unsupported("numeric kind mismatch")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          match left_kind {
            GcValKind::I64 => emit_i64_eq_gc(buf)
            GcValKind::I32 => emit_i32_eq_gc(buf)
            GcValKind::F32 => emit_f32_eq_gc(buf)
            GcValKind::F64 => emit_f64_eq_gc(buf)
            _ => raise WasmGenError::Unsupported("numeric kind")
          }
        }
        "__lt" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("__lt arity")
          }
          let left_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
          let right_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
          if left_kind != right_kind {
            raise WasmGenError::Unsupported("numeric kind mismatch")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          compile_expr_gc(ctx, fctx, buf, pos_args[1])
          match left_kind {
            GcValKind::I64 => emit_i64_lt_s_gc(buf)
            GcValKind::I32 => emit_i32_lt_s_gc(buf)
            GcValKind::F32 => emit_f32_lt_gc(buf)
            GcValKind::F64 => emit_f64_lt_gc(buf)
            _ => raise WasmGenError::Unsupported("numeric kind")
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
            _ => raise WasmGenError::Unsupported("numeric kind")
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
        "String::length" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("String::length arity")
          }
          compile_expr_gc(ctx, fctx, buf, pos_args[0])
          emit_struct_get_gc(buf, ctx.string_type, 0)
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
            None => raise WasmGenError::UnknownName(name)
          }
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      compile_expr_gc(ctx, fctx, buf, cond)
      let result_kind = infer_block_kind_gc(ctx, fctx, then_body)
      let else_kind = infer_block_kind_gc(ctx, fctx, else_body)
      if result_kind != else_kind {
        raise WasmGenError::Unsupported("if kind mismatch")
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
          raise WasmGenError::Unsupported("match kind mismatch")
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
      let (iterable_type_idx, iterable_elem_kind, body_kind) = infer_for_in_parts_gc(
        ctx, fctx, value_name, index_name, iterable, body,
      )
      let result_type_idx = ensure_array_type(
        ctx.types,
        ctx.array_type_index,
        body_kind,
      )
      let iterable_idx = alloc_local_gc(fctx, GcValKind::Ref(iterable_type_idx))
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
        Some(name) => Some(bind_local_gc(fctx, name, GcValKind::I64))
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
          emit_i64_extend_i32_s_gc(buf)
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
    @core.Stmt::Let(rec~, name~, expr~, ..) => {
      let _ = rec
      let kind = infer_expr_kind_gc(ctx, fctx, expr)
      let idx = bind_local_gc(fctx, name, kind)
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
      compile_expr_gc(ctx, fctx, buf, expr)
      if is_last {
        emit_local_tee_gc(buf, idx)
      } else {
        emit_local_set_gc(buf, idx)
      }
    }
    @core.Stmt::Assign(name~, expr~, ..) =>
      match fctx.locals.get(name) {
        Some(info) => {
          compile_expr_gc(ctx, fctx, buf, expr)
          if is_last {
            emit_local_tee_gc(buf, info.idx)
          } else {
            emit_local_set_gc(buf, info.idx)
          }
        }
        None => raise WasmGenError::UnknownName(name)
      }
    @core.Stmt::Expr(expr~, ..) => {
      compile_expr_gc(ctx, fctx, buf, expr)
      if not(is_last) {
        emit_drop_gc(buf)
      }
    }
    _ => raise WasmGenError::Unsupported("stmt")
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
fn collect_top_level_funcs_gc(ast : @core.Module) -> Array[GcFuncDef] {
  let funcs : Array[GcFuncDef] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, ..) => {
        let _ = rec
        match expr {
          @core.Expr::Fn(params~, ret~, body~, ..) =>
            funcs.push({ name, params, ret, body })
          _ => ()
        }
      }
      _ => ()
    }
  }
  funcs
}

///|
fn filter_top_level_funcs_gc(ast : @core.Module) -> @core.Module {
  let stmts : Array[@core.Stmt] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(rec~, expr~, ..) => {
        let _ = rec
        match expr {
          @core.Expr::Fn(..) => ()
          _ => stmts.push(stmt)
        }
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
  { sig, locals: fctx.local_kinds, body: buf.data }
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
  { sig, locals: fctx.local_kinds, body: buf.data }
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
  let type_count = ctx.types.length() + funcs.length()
  write_u32_leb_gc(type_sec, type_count)
  for ty in ctx.types {
    write_type_entry_gc(type_sec, ty)
  }
  for f in funcs {
    write_func_type_gc(type_sec, f.sig)
  }
  write_section_gc(buf, 1, type_sec.data)
  let func_sec = GcByteBuf::new()
  write_u32_leb_gc(func_sec, funcs.length())
  let type_offset = ctx.types.length()
  for i in 0..<funcs.length() {
    write_u32_leb_gc(func_sec, type_offset + i)
  }
  write_section_gc(buf, 3, func_sec.data)
  let export_sec = GcByteBuf::new()
  write_u32_leb_gc(export_sec, 1)
  let name = "run"
  write_u32_leb_gc(export_sec, name.length())
  for c in name {
    export_sec.push(c.to_int())
  }
  export_sec.push(0x00)
  write_u32_leb_gc(export_sec, run_index)
  write_section_gc(buf, 7, export_sec.data)
  let code_sec = GcByteBuf::new()
  write_u32_leb_gc(code_sec, funcs.length())
  for f in funcs {
    let func_body = GcByteBuf::new()
    write_locals_gc(func_body, f.locals)
    func_body.extend(f.body)
    func_body.push(0x0b)
    write_u32_leb_gc(code_sec, func_body.len())
    code_sec.extend(func_body.data)
  }
  write_section_gc(buf, 10, code_sec.data)
  buf.to_bytes()
}

///|
pub fn emit_module_wasm_gc(ast : @core.Module) -> Bytes raise WasmGenError {
  let ctx = GcCodegenCtx::new()
  let funcs = collect_top_level_funcs_gc(ast)
  for i in 0..<funcs.length() {
    ctx.func_indices[funcs[i].name] = i
    ctx.func_param_counts[funcs[i].name] = funcs[i].params.length()
    match funcs[i].ret {
      Some(ty) =>
        ctx.func_returns[funcs[i].name] = gc_val_kind_from_type(ctx, ty)
      None => ()
    }
  }
  let wasm_funcs : Array[GcWasmFunc] = []
  for f in funcs {
    let wf = compile_function_gc(ctx, f)
    ctx.func_returns[f.name] = wf.sig.result
    wasm_funcs.push(wf)
  }
  let run_body = filter_top_level_funcs_gc(ast)
  let run_func = compile_run_gc(ctx, run_body)
  let run_index = wasm_funcs.length()
  wasm_funcs.push(run_func)
  build_module_gc(ctx, wasm_funcs, run_index)
}
