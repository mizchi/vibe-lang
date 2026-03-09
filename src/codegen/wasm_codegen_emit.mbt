///|
priv struct ByteBuf {
  data : Array[Byte]
}

///|
fn ByteBuf::new() -> ByteBuf {
  { data: [] }
}

///|
fn ByteBuf::push(self : ByteBuf, b : Byte) -> Unit {
  self.data.push(b)
}

///|
fn ByteBuf::extend(self : ByteBuf, bytes : Array[Byte]) -> Unit {
  for b in bytes {
    self.data.push(b)
  }
}

///|
fn ByteBuf::len(self : ByteBuf) -> Int {
  self.data.length()
}

///|
fn ByteBuf::to_bytes(self : ByteBuf) -> Bytes {
  Bytes::from_array(self.data)
}

///|
fn write_u32_leb(buf : ByteBuf, n : Int) -> Unit {
  let mut value = n
  while true {
    let mut byte = value & 0x7f
    value = value >> 7
    if value != 0 {
      byte = byte | 0x80
    }
    buf.push(byte.to_byte())
    if value == 0 {
      break
    }
  }
}

///|
fn write_i32_leb(buf : ByteBuf, n : Int) -> Unit {
  let mut value = n
  while true {
    let mut byte = value & 0x7f
    value = value >> 7
    let sign_bit_set = (byte & 0x40) != 0
    let done = (value == 0 && not(sign_bit_set)) ||
      (value == -1 && sign_bit_set)
    if not(done) {
      byte = byte | 0x80
    }
    buf.push(byte.to_byte())
    if done {
      break
    }
  }
}

///|
fn write_u32_le_bytes(out : Array[Byte], n : Int) -> Unit {
  let v = n
  out.push((v & 0xff).to_byte())
  out.push(((v >> 8) & 0xff).to_byte())
  out.push(((v >> 16) & 0xff).to_byte())
  out.push(((v >> 24) & 0xff).to_byte())
}

///|
fn write_name(buf : ByteBuf, s : String) -> Unit {
  let bytes = @utf8.encode(s)
  let arr = bytes.to_array()
  write_u32_leb(buf, arr.length())
  buf.extend(arr)
}

///|
fn write_ref_extern(buf : ByteBuf) -> Unit {
  buf.push((100).to_byte())
  buf.push((111).to_byte())
}

///|
fn emit_i32_const_raw(buf : ByteBuf, n : Int) -> Unit {
  buf.push((65).to_byte())
  write_i32_leb(buf, n)
}

///|
fn emit_string_const(ctx : CodegenCtx, buf : ByteBuf, s : String) -> Unit {
  if ctx.use_js_strings {
    let idx = ctx.js_strings.intern(s)
    emit_global_get(buf, idx)
  } else {
    let offset = ctx.strings.intern(s)
    emit_i64_const_raw(buf, tag_ptr64(offset, tag_obj))
  }
}

///|
fn intern_error_code(ctx : CodegenCtx, message : String) -> Int {
  // 0 is reserved for unknown/unmapped errors.
  ctx.error_codes.intern(message) + 1
}

///|
fn emit_local_get(buf : ByteBuf, idx : Int) -> Unit {
  buf.push((32).to_byte())
  write_u32_leb(buf, idx)
}

///|
fn emit_local_set(buf : ByteBuf, idx : Int) -> Unit {
  buf.push((33).to_byte())
  write_u32_leb(buf, idx)
}

///|
fn emit_local_tee(buf : ByteBuf, idx : Int) -> Unit {
  buf.push((34).to_byte())
  write_u32_leb(buf, idx)
}

///|
fn emit_global_get(buf : ByteBuf, idx : Int) -> Unit {
  buf.push((35).to_byte())
  write_u32_leb(buf, idx)
}

///|
fn emit_global_set(buf : ByteBuf, idx : Int) -> Unit {
  buf.push((36).to_byte())
  write_u32_leb(buf, idx)
}

///|
fn emit_call(buf : ByteBuf, idx : Int) -> Unit {
  buf.push((16).to_byte())
  write_u32_leb(buf, idx)
}

///|
fn emit_call_indirect(buf : ByteBuf, type_idx : Int) -> Unit {
  buf.push((17).to_byte())
  write_u32_leb(buf, type_idx)
  buf.push((0).to_byte())
}

///|
fn emit_table_get(buf : ByteBuf, table_idx : Int) -> Unit {
  buf.push((37).to_byte()) // table.get = 0x25
  write_u32_leb(buf, table_idx)
}

///|
fn emit_table_set(buf : ByteBuf, table_idx : Int) -> Unit {
  buf.push((38).to_byte()) // table.set = 0x26
  write_u32_leb(buf, table_idx)
}

///|
fn emit_memory_size(buf : ByteBuf) -> Unit {
  buf.push((63).to_byte()) // memory.size = 0x3f
  buf.push((0).to_byte()) // memory index
}

///|
fn emit_memory_grow(buf : ByteBuf) -> Unit {
  buf.push((64).to_byte()) // memory.grow = 0x40
  buf.push((0).to_byte()) // memory index
}

///|
fn emit_drop(buf : ByteBuf) -> Unit {
  buf.push((26).to_byte())
}

///|
/// Emit block instruction (blocktype is void for now)
fn emit_block(buf : ByteBuf) -> Unit {
  buf.push((2).to_byte()) // block = 0x02
  buf.push((64).to_byte()) // void blocktype = 0x40
}

///|
/// Emit if instruction (consumes i32 condition from stack)
fn emit_if(buf : ByteBuf) -> Unit {
  buf.push((4).to_byte()) // if = 0x04
  buf.push((64).to_byte()) // void blocktype = 0x40
}

///|
/// Emit else instruction
fn emit_else(buf : ByteBuf) -> Unit {
  buf.push((5).to_byte()) // else = 0x05
}

///|
/// Emit block instruction with i64 result type
fn emit_block_i64(buf : ByteBuf) -> Unit {
  buf.push((2).to_byte()) // block = 0x02
  buf.push((126).to_byte()) // i64 blocktype = 0x7E
}

///|
/// Emit loop instruction (blocktype is void for now)
fn emit_loop(buf : ByteBuf) -> Unit {
  buf.push((3).to_byte()) // loop = 0x03
  buf.push((64).to_byte()) // void blocktype = 0x40
}

///|
fn emit_unreachable(buf : ByteBuf) -> Unit {
  buf.push((0).to_byte()) // unreachable = 0x00
}

///|
/// Emit br instruction (unconditional branch)
fn emit_br(buf : ByteBuf, label_idx : Int) -> Unit {
  buf.push((12).to_byte()) // br = 0x0c
  write_u32_leb(buf, label_idx)
}

///|
/// Emit br_if instruction (conditional branch)
fn emit_br_if(buf : ByteBuf, label_idx : Int) -> Unit {
  buf.push((13).to_byte()) // br_if = 0x0d
  write_u32_leb(buf, label_idx)
}

///|
/// Emit end instruction
fn emit_end(buf : ByteBuf) -> Unit {
  buf.push((11).to_byte()) // end = 0x0b
}

///|
/// Emit i32.eqz instruction (test if zero)
fn emit_i32_eqz(buf : ByteBuf) -> Unit {
  buf.push((69).to_byte()) // i32.eqz = 0x45
}

///|
fn emit_i32_add(buf : ByteBuf) -> Unit {
  buf.push((106).to_byte())
}

///|
fn emit_i32_sub(buf : ByteBuf) -> Unit {
  buf.push((107).to_byte())
}

///|
fn emit_i32_mul(buf : ByteBuf) -> Unit {
  buf.push((108).to_byte())
}

///|
fn emit_i32_div_s(buf : ByteBuf) -> Unit {
  buf.push((109).to_byte())
}

///|
fn emit_i32_rem_s(buf : ByteBuf) -> Unit {
  buf.push((111).to_byte())
}

///|
fn emit_i32_eq(buf : ByteBuf) -> Unit {
  buf.push((70).to_byte())
}

///|
fn emit_i32_ne(buf : ByteBuf) -> Unit {
  buf.push((71).to_byte())
}

///|
fn emit_i32_lt_s(buf : ByteBuf) -> Unit {
  buf.push((72).to_byte())
}

///|
fn emit_i32_gt_s(buf : ByteBuf) -> Unit {
  buf.push((74).to_byte())
}

///|
fn emit_i32_gt_u(buf : ByteBuf) -> Unit {
  buf.push((75).to_byte())
}

///|
fn emit_i32_le_s(buf : ByteBuf) -> Unit {
  buf.push((76).to_byte())
}

///|
fn emit_i32_ge_s(buf : ByteBuf) -> Unit {
  buf.push((78).to_byte())
}

///|
fn emit_i32_shr_u(buf : ByteBuf) -> Unit {
  buf.push((118).to_byte())
}

///|
fn emit_i32_or(buf : ByteBuf) -> Unit {
  buf.push((114).to_byte())
}

///|
fn emit_i32_and(buf : ByteBuf) -> Unit {
  buf.push((113).to_byte())
}

///|
fn emit_i32_xor(buf : ByteBuf) -> Unit {
  buf.push((115).to_byte())
}

///|
fn emit_i32_load(buf : ByteBuf, offset : Int) -> Unit {
  buf.push((40).to_byte())
  write_u32_leb(buf, 2)
  write_u32_leb(buf, offset)
}

///|
fn emit_i32_load8_u(buf : ByteBuf, offset : Int) -> Unit {
  buf.push((45).to_byte())
  write_u32_leb(buf, 0)
  write_u32_leb(buf, offset)
}

///|
fn emit_i32_store(buf : ByteBuf, offset : Int) -> Unit {
  buf.push((54).to_byte())
  write_u32_leb(buf, 2)
  write_u32_leb(buf, offset)
}

///|
fn register_coverage_point(
  ctx : CodegenCtx,
  kind : WasmCoveragePointKind,
  span : @core.Span,
) -> Int {
  if not(ctx.coverage_enabled) {
    return -1
  }
  let id = ctx.coverage_points.length()
  ctx.coverage_points.push({ id, kind, span })
  id
}

///|
fn emit_coverage_hit(ctx : CodegenCtx, buf : ByteBuf, point_id : Int) -> Unit {
  if point_id < 0 {
    return
  }
  let addr = ctx.coverage_base_offset + point_id * 4
  emit_i32_const_raw(buf, addr)
  emit_i32_const_raw(buf, addr)
  emit_i32_load(buf, 0)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_i32_store(buf, 0)
}

///|
fn emit_coverage(
  ctx : CodegenCtx,
  buf : ByteBuf,
  kind : WasmCoveragePointKind,
  span : @core.Span,
) -> Unit {
  if not(ctx.coverage_enabled) {
    return
  }
  let point_id = register_coverage_point(ctx, kind, span)
  emit_coverage_hit(ctx, buf, point_id)
}

///|
fn emit_i32_store8(buf : ByteBuf, offset : Int) -> Unit {
  buf.push((58).to_byte())
  write_u32_leb(buf, 0)
  write_u32_leb(buf, offset)
}

///|
fn emit_f32_const(buf : ByteBuf, n : Float) -> Unit {
  buf.push((67).to_byte())
  let bytes = Float::to_le_bytes(n)
  buf.extend(bytes.to_array())
}

///|
fn emit_f64_const(buf : ByteBuf, n : Double) -> Unit {
  buf.push((68).to_byte())
  let bits = Double::reinterpret_as_uint64(n)
  let bytes = UInt64::to_le_bytes(bits)
  buf.extend(bytes.to_array())
}

///|
fn emit_f32_add(buf : ByteBuf) -> Unit {
  buf.push((146).to_byte())
}

///|
fn emit_f32_sub(buf : ByteBuf) -> Unit {
  buf.push((147).to_byte())
}

///|
fn emit_f32_mul(buf : ByteBuf) -> Unit {
  buf.push((148).to_byte())
}

///|
fn emit_f32_div(buf : ByteBuf) -> Unit {
  buf.push((149).to_byte())
}

///|
fn emit_f32_eq(buf : ByteBuf) -> Unit {
  buf.push((91).to_byte())
}

///|
fn emit_f32_ne(buf : ByteBuf) -> Unit {
  buf.push((92).to_byte())
}

///|
fn emit_f32_lt(buf : ByteBuf) -> Unit {
  buf.push((93).to_byte())
}

///|
fn emit_f32_gt(buf : ByteBuf) -> Unit {
  buf.push((94).to_byte())
}

///|
fn emit_f32_le(buf : ByteBuf) -> Unit {
  buf.push((95).to_byte())
}

///|
fn emit_f32_ge(buf : ByteBuf) -> Unit {
  buf.push((96).to_byte())
}

///|
fn emit_f32_neg(buf : ByteBuf) -> Unit {
  buf.push((140).to_byte())
}

///|
fn emit_f32_abs(buf : ByteBuf) -> Unit {
  buf.push((139).to_byte())
}

///|
fn emit_f32_ceil(buf : ByteBuf) -> Unit {
  buf.push((141).to_byte())
}

///|
fn emit_f32_floor(buf : ByteBuf) -> Unit {
  buf.push((142).to_byte())
}

///|
fn emit_f32_trunc(buf : ByteBuf) -> Unit {
  buf.push((143).to_byte())
}

///|
fn emit_f32_nearest(buf : ByteBuf) -> Unit {
  buf.push((144).to_byte())
}

///|
fn emit_f32_sqrt(buf : ByteBuf) -> Unit {
  buf.push((145).to_byte())
}

///|
fn emit_f64_add(buf : ByteBuf) -> Unit {
  buf.push((160).to_byte())
}

///|
fn emit_f64_sub(buf : ByteBuf) -> Unit {
  buf.push((161).to_byte())
}

///|
fn emit_f64_mul(buf : ByteBuf) -> Unit {
  buf.push((162).to_byte())
}

///|
fn emit_f64_div(buf : ByteBuf) -> Unit {
  buf.push((163).to_byte())
}

///|
fn emit_f64_eq(buf : ByteBuf) -> Unit {
  buf.push((97).to_byte())
}

///|
fn emit_f64_ne(buf : ByteBuf) -> Unit {
  buf.push((98).to_byte())
}

///|
fn emit_f64_lt(buf : ByteBuf) -> Unit {
  buf.push((99).to_byte())
}

///|
fn emit_f64_gt(buf : ByteBuf) -> Unit {
  buf.push((100).to_byte())
}

///|
fn emit_f64_le(buf : ByteBuf) -> Unit {
  buf.push((101).to_byte())
}

///|
fn emit_f64_ge(buf : ByteBuf) -> Unit {
  buf.push((102).to_byte())
}

///|
fn emit_f64_neg(buf : ByteBuf) -> Unit {
  buf.push((154).to_byte())
}

///|
fn emit_f64_abs(buf : ByteBuf) -> Unit {
  buf.push((153).to_byte())
}

///|
fn emit_f64_ceil(buf : ByteBuf) -> Unit {
  buf.push((155).to_byte())
}

///|
fn emit_f64_floor(buf : ByteBuf) -> Unit {
  buf.push((156).to_byte())
}

///|
fn emit_f64_trunc(buf : ByteBuf) -> Unit {
  buf.push((157).to_byte())
}

///|
fn emit_f64_nearest(buf : ByteBuf) -> Unit {
  buf.push((158).to_byte())
}

///|
fn emit_f64_sqrt(buf : ByteBuf) -> Unit {
  buf.push((159).to_byte())
}

///|
fn emit_i32_trunc_f32_s(buf : ByteBuf) -> Unit {
  buf.push((168).to_byte())
}

///|
fn emit_i64_trunc_f64_s(buf : ByteBuf) -> Unit {
  buf.push((176).to_byte())
}

///|
fn emit_f32_convert_i32_s(buf : ByteBuf) -> Unit {
  buf.push((178).to_byte())
}

///|
fn emit_f32_demote_f64(buf : ByteBuf) -> Unit {
  buf.push((182).to_byte())
}

///|
fn emit_f64_convert_i64_s(buf : ByteBuf) -> Unit {
  buf.push((185).to_byte())
}

///|
fn emit_f64_promote_f32(buf : ByteBuf) -> Unit {
  buf.push((187).to_byte())
}

///|
fn emit_i64_load(buf : ByteBuf, offset : Int) -> Unit {
  buf.push((41).to_byte())
  write_u32_leb(buf, 3)
  write_u32_leb(buf, offset)
}

///|
fn emit_i64_store(buf : ByteBuf, offset : Int) -> Unit {
  buf.push((55).to_byte())
  write_u32_leb(buf, 3)
  write_u32_leb(buf, offset)
}

///|
fn emit_f32_load(buf : ByteBuf, offset : Int) -> Unit {
  buf.push((42).to_byte())
  write_u32_leb(buf, 2)
  write_u32_leb(buf, offset)
}

///|
fn emit_f64_load(buf : ByteBuf, offset : Int) -> Unit {
  buf.push((43).to_byte())
  write_u32_leb(buf, 3)
  write_u32_leb(buf, offset)
}

///|
fn emit_f32_store(buf : ByteBuf, offset : Int) -> Unit {
  buf.push((56).to_byte())
  write_u32_leb(buf, 2)
  write_u32_leb(buf, offset)
}

///|
fn emit_f64_store(buf : ByteBuf, offset : Int) -> Unit {
  buf.push((57).to_byte())
  write_u32_leb(buf, 3)
  write_u32_leb(buf, offset)
}

///|
fn emit_f64_reinterpret_i64(buf : ByteBuf) -> Unit {
  buf.push((0xBF).to_byte())
}

///|
fn write_i64_leb(buf : ByteBuf, n : Int64) -> Unit {
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
    buf.push(byte.to_byte())
    if done {
      break
    }
  }
}

///|
fn emit_i64_const_raw(buf : ByteBuf, n : Int64) -> Unit {
  buf.push((0x42).to_byte())
  write_i64_leb(buf, n)
}

///|
fn emit_i64_const_tagged(buf : ByteBuf, n : Int64) -> Unit {
  emit_i64_const_raw(buf, tag_int_value64(n))
}

///|
fn emit_i64_add(buf : ByteBuf) -> Unit {
  buf.push((0x7C).to_byte())
}

///|
fn emit_i64_sub(buf : ByteBuf) -> Unit {
  buf.push((0x7D).to_byte())
}

///|
fn emit_i64_mul(buf : ByteBuf) -> Unit {
  buf.push((0x7E).to_byte())
}

///|
fn emit_i64_div_s(buf : ByteBuf) -> Unit {
  buf.push((0x7F).to_byte())
}

///|
fn emit_i64_rem_s(buf : ByteBuf) -> Unit {
  buf.push((0x81).to_byte())
}

///|
fn emit_i64_eq(buf : ByteBuf) -> Unit {
  buf.push((0x51).to_byte())
}

///|
fn emit_i64_lt_s(buf : ByteBuf) -> Unit {
  buf.push((0x53).to_byte())
}

///|
fn emit_i64_gt_s(buf : ByteBuf) -> Unit {
  buf.push((0x55).to_byte())
}

///|
fn emit_i64_eqz(buf : ByteBuf) -> Unit {
  buf.push((0x50).to_byte())
}

///|
/// select: pops (val1, val2, cond:i32), pushes val1 if cond != 0, else val2
fn emit_select(buf : ByteBuf) -> Unit {
  buf.push((0x1B).to_byte())
}

///|
fn emit_i64_shl(buf : ByteBuf) -> Unit {
  buf.push((0x86).to_byte())
}

///|
fn emit_i64_shr_u(buf : ByteBuf) -> Unit {
  buf.push((0x88).to_byte())
}

///|
fn emit_i64_shr_s(buf : ByteBuf) -> Unit {
  buf.push((0x87).to_byte())
}

///|
fn emit_i64_or(buf : ByteBuf) -> Unit {
  buf.push((0x84).to_byte())
}

///|
fn emit_i64_and(buf : ByteBuf) -> Unit {
  buf.push((0x83).to_byte())
}

///|
fn emit_i64_xor(buf : ByteBuf) -> Unit {
  buf.push((0x85).to_byte())
}

///|
fn emit_i32_wrap_i64(buf : ByteBuf) -> Unit {
  buf.push((0xA7).to_byte())
}

///|
fn emit_i64_extend_i32_s(buf : ByteBuf) -> Unit {
  buf.push((0xAC).to_byte())
}

///|
fn emit_i64_extend_i32_u(buf : ByteBuf) -> Unit {
  buf.push((0xAD).to_byte())
}

///|
