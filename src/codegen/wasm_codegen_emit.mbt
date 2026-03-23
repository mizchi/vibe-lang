///|
priv struct ByteBuf {
  mut data : FixedArray[Byte]
  mut len : Int
}

///|
fn ByteBuf::new() -> ByteBuf {
  { data: FixedArray::make(4096, b'\x00'), len: 0 }
}

///|
fn ByteBuf::grow_to(self : ByteBuf, needed : Int) -> Unit {
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
fn ByteBuf::ensure(self : ByteBuf, additional : Int) -> Unit {
  let needed = self.len + additional
  if needed > self.data.length() {
    self.grow_to(needed)
  }
}

///|
fn ByteBuf::push(self : ByteBuf, b : Byte) -> Unit {
  if self.len == self.data.length() {
    self.grow_to(self.data.length() * 2)
  }
  self.data.unsafe_set(self.len, b)
  self.len += 1
}

///|
fn ByteBuf::extend(self : ByteBuf, bytes : Array[Byte]) -> Unit {
  self.ensure(bytes.length())
  for i in 0..<bytes.length() {
    self.data.unsafe_set(self.len + i, bytes[i])
  }
  self.len += bytes.length()
}

///|
fn ByteBuf::extend_buf(self : ByteBuf, other : ByteBuf) -> Unit {
  self.ensure(other.len)
  FixedArray::unsafe_blit(self.data, self.len, other.data, 0, other.len)
  self.len += other.len
}

///|
fn ByteBuf::len(self : ByteBuf) -> Int {
  self.len
}

///|
fn ByteBuf::to_array(self : ByteBuf) -> Array[Byte] {
  Array::makei(self.len, fn(i) { self.data[i] })
}

///|
fn ByteBuf::to_bytes(self : ByteBuf) -> Bytes {
  Bytes::from_array(self.to_array())
}

///|
/// Unrolled u32 LEB128 — single ensure + unsafe_set, zero capacity checks per byte.
fn write_u32_leb(buf : ByteBuf, n : Int) -> Unit {
  buf.ensure(5)
  let u = n.reinterpret_as_uint()
  let v0 = u & 0x7fU
  let r0 = u >> 7
  if r0 == 0U {
    buf.data.unsafe_set(buf.len, v0.reinterpret_as_int().to_byte())
    buf.len += 1
    return
  }
  buf.data.unsafe_set(buf.len, (v0 | 0x80U).reinterpret_as_int().to_byte())
  let v1 = r0 & 0x7fU
  let r1 = r0 >> 7
  if r1 == 0U {
    buf.data.unsafe_set(buf.len + 1, v1.reinterpret_as_int().to_byte())
    buf.len += 2
    return
  }
  buf.data.unsafe_set(buf.len + 1, (v1 | 0x80U).reinterpret_as_int().to_byte())
  let v2 = r1 & 0x7fU
  let r2 = r1 >> 7
  if r2 == 0U {
    buf.data.unsafe_set(buf.len + 2, v2.reinterpret_as_int().to_byte())
    buf.len += 3
    return
  }
  buf.data.unsafe_set(buf.len + 2, (v2 | 0x80U).reinterpret_as_int().to_byte())
  let v3 = r2 & 0x7fU
  let r3 = r2 >> 7
  if r3 == 0U {
    buf.data.unsafe_set(buf.len + 3, v3.reinterpret_as_int().to_byte())
    buf.len += 4
    return
  }
  buf.data.unsafe_set(buf.len + 3, (v3 | 0x80U).reinterpret_as_int().to_byte())
  buf.data.unsafe_set(buf.len + 4, (r3 & 0x7fU).reinterpret_as_int().to_byte())
  buf.len += 5
}

///|
/// u32 LEB128 without ensure — caller must have ensured at least 5 bytes.
fn write_u32_leb_unchecked(buf : ByteBuf, n : Int) -> Unit {
  let u = n.reinterpret_as_uint()
  let v0 = u & 0x7fU
  let r0 = u >> 7
  if r0 == 0U {
    buf.data.unsafe_set(buf.len, v0.reinterpret_as_int().to_byte())
    buf.len += 1
    return
  }
  buf.data.unsafe_set(buf.len, (v0 | 0x80U).reinterpret_as_int().to_byte())
  let v1 = r0 & 0x7fU
  let r1 = r0 >> 7
  if r1 == 0U {
    buf.data.unsafe_set(buf.len + 1, v1.reinterpret_as_int().to_byte())
    buf.len += 2
    return
  }
  buf.data.unsafe_set(buf.len + 1, (v1 | 0x80U).reinterpret_as_int().to_byte())
  let v2 = r1 & 0x7fU
  let r2 = r1 >> 7
  if r2 == 0U {
    buf.data.unsafe_set(buf.len + 2, v2.reinterpret_as_int().to_byte())
    buf.len += 3
    return
  }
  buf.data.unsafe_set(buf.len + 2, (v2 | 0x80U).reinterpret_as_int().to_byte())
  let v3 = r2 & 0x7fU
  let r3 = r2 >> 7
  if r3 == 0U {
    buf.data.unsafe_set(buf.len + 3, v3.reinterpret_as_int().to_byte())
    buf.len += 4
    return
  }
  buf.data.unsafe_set(buf.len + 3, (v3 | 0x80U).reinterpret_as_int().to_byte())
  buf.data.unsafe_set(buf.len + 4, (r3 & 0x7fU).reinterpret_as_int().to_byte())
  buf.len += 5
}

///|
/// Unrolled signed LEB128 — single ensure + unsafe_set.
fn write_i32_leb(buf : ByteBuf, n : Int) -> Unit {
  buf.ensure(5)
  write_i32_leb_unchecked(buf, n, 0)
}

///|
/// Recursive helper for signed LEB128 — writes directly via unsafe_set after ensure.
fn write_i32_leb_unchecked(buf : ByteBuf, value : Int, depth : Int) -> Unit {
  let byte_val = value & 0x7f
  let rest = value >> 7
  let sign_bit_set = (byte_val & 0x40) != 0
  let done = (rest == 0 && not(sign_bit_set)) || (rest == -1 && sign_bit_set)
  if done {
    buf.data.unsafe_set(buf.len, byte_val.to_byte())
    buf.len += 1
  } else if depth < 4 {
    buf.data.unsafe_set(buf.len, (byte_val | 0x80).to_byte())
    buf.len += 1
    write_i32_leb_unchecked(buf, rest, depth + 1)
  } else {
    buf.data.unsafe_set(buf.len, byte_val.to_byte())
    buf.len += 1
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
  buf.ensure(2)
  buf.data.unsafe_set(buf.len, b'\x64')
  buf.data.unsafe_set(buf.len + 1, b'\x6f')
  buf.len += 2
}

///|
fn emit_i32_const_raw(buf : ByteBuf, n : Int) -> Unit {
  buf.ensure(6)
  buf.data.unsafe_set(buf.len, b'\x41')
  buf.len += 1
  write_i32_leb_unchecked(buf, n, 0)
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
  buf.ensure(6)
  buf.data.unsafe_set(buf.len, b'\x20')
  buf.len += 1
  write_u32_leb_unchecked(buf, idx)
}

///|
fn emit_local_set(buf : ByteBuf, idx : Int) -> Unit {
  buf.ensure(6)
  buf.data.unsafe_set(buf.len, b'\x21')
  buf.len += 1
  write_u32_leb_unchecked(buf, idx)
}

///|
fn emit_local_tee(buf : ByteBuf, idx : Int) -> Unit {
  buf.ensure(6)
  buf.data.unsafe_set(buf.len, b'\x22')
  buf.len += 1
  write_u32_leb_unchecked(buf, idx)
}

///|
fn emit_global_get(buf : ByteBuf, idx : Int) -> Unit {
  buf.ensure(6)
  buf.data.unsafe_set(buf.len, b'\x23')
  buf.len += 1
  write_u32_leb_unchecked(buf, idx)
}

///|
fn emit_global_set(buf : ByteBuf, idx : Int) -> Unit {
  buf.ensure(6)
  buf.data.unsafe_set(buf.len, b'\x24')
  buf.len += 1
  write_u32_leb_unchecked(buf, idx)
}

///|
fn emit_call(buf : ByteBuf, idx : Int) -> Unit {
  buf.ensure(6)
  buf.data.unsafe_set(buf.len, b'\x10')
  buf.len += 1
  write_u32_leb_unchecked(buf, idx)
}

///|
fn emit_call_indirect(buf : ByteBuf, type_idx : Int) -> Unit {
  buf.ensure(7)
  buf.data.unsafe_set(buf.len, b'\x11')
  buf.len += 1
  write_u32_leb_unchecked(buf, type_idx)
  buf.data.unsafe_set(buf.len, b'\x00')
  buf.len += 1
}

///|
fn emit_return_call(buf : ByteBuf, idx : Int) -> Unit {
  buf.ensure(6)
  buf.data.unsafe_set(buf.len, b'\x12')
  buf.len += 1
  write_u32_leb_unchecked(buf, idx)
}

///|
fn emit_return_call_indirect(buf : ByteBuf, type_idx : Int) -> Unit {
  buf.ensure(7)
  buf.data.unsafe_set(buf.len, b'\x13')
  buf.len += 1
  write_u32_leb_unchecked(buf, type_idx)
  buf.data.unsafe_set(buf.len, b'\x00')
  buf.len += 1
}

///|
fn emit_table_get(buf : ByteBuf, table_idx : Int) -> Unit {
  buf.ensure(6)
  buf.data.unsafe_set(buf.len, b'\x25')
  buf.len += 1
  write_u32_leb_unchecked(buf, table_idx)
}

///|
fn emit_table_set(buf : ByteBuf, table_idx : Int) -> Unit {
  buf.ensure(6)
  buf.data.unsafe_set(buf.len, b'\x26')
  buf.len += 1
  write_u32_leb_unchecked(buf, table_idx)
}

///|
fn emit_memory_size(buf : ByteBuf) -> Unit {
  buf.ensure(2)
  buf.data.unsafe_set(buf.len, b'\x3f')
  buf.data.unsafe_set(buf.len + 1, b'\x00')
  buf.len += 2
}

///|
fn emit_memory_grow(buf : ByteBuf) -> Unit {
  buf.ensure(2)
  buf.data.unsafe_set(buf.len, b'\x40')
  buf.data.unsafe_set(buf.len + 1, b'\x00')
  buf.len += 2
}

///|
fn emit_drop(buf : ByteBuf) -> Unit {
  buf.push((26).to_byte())
}

///|
/// Emit block instruction (blocktype is void for now)
fn emit_block(buf : ByteBuf) -> Unit {
  buf.ensure(2)
  buf.data.unsafe_set(buf.len, b'\x02')
  buf.data.unsafe_set(buf.len + 1, b'\x40')
  buf.len += 2
}

///|
/// Emit if instruction (consumes i32 condition from stack)
fn emit_if(buf : ByteBuf) -> Unit {
  buf.push(b'\x04')
  buf.push(b'\x40')
}

///|
/// Emit else instruction
fn emit_else(buf : ByteBuf) -> Unit {
  buf.ensure(1)
  buf.data.unsafe_set(buf.len, b'\x05')
  buf.len += 1
}

///|
/// Emit block instruction with i64 result type
fn emit_block_i64(buf : ByteBuf) -> Unit {
  buf.ensure(2)
  buf.data.unsafe_set(buf.len, b'\x02')
  buf.data.unsafe_set(buf.len + 1, b'\x7e')
  buf.len += 2
}

///|
/// Emit loop instruction (blocktype is void for now)
fn emit_loop(buf : ByteBuf) -> Unit {
  buf.ensure(2)
  buf.data.unsafe_set(buf.len, b'\x03')
  buf.data.unsafe_set(buf.len + 1, b'\x40')
  buf.len += 2
}

///|
fn emit_unreachable(buf : ByteBuf) -> Unit {
  buf.push((0).to_byte()) // unreachable = 0x00
}

///|
/// Emit br instruction (unconditional branch)
fn emit_br(buf : ByteBuf, label_idx : Int) -> Unit {
  buf.ensure(6)
  buf.data.unsafe_set(buf.len, b'\x0c')
  buf.len += 1
  write_u32_leb_unchecked(buf, label_idx)
}

///|
/// Emit br_if instruction (conditional branch)
fn emit_br_if(buf : ByteBuf, label_idx : Int) -> Unit {
  buf.ensure(6)
  buf.data.unsafe_set(buf.len, b'\x0d')
  buf.len += 1
  write_u32_leb_unchecked(buf, label_idx)
}

///|
/// Emit br_table instruction (multi-way branch)
/// labels: target label indices for each case (0..N-1)
/// default_label: fallback label index
fn _emit_br_table(
  buf : ByteBuf,
  labels : Array[Int],
  default_label : Int,
) -> Unit {
  buf.push((14).to_byte()) // br_table = 0x0e
  write_u32_leb(buf, labels.length())
  for label in labels {
    write_u32_leb(buf, label)
  }
  write_u32_leb(buf, default_label)
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
fn emit_i32_shl(buf : ByteBuf) -> Unit {
  buf.push((116).to_byte()) // i32.shl = 0x74
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
  buf.ensure(11) // opcode + align_leb(5) + offset_leb(5)
  buf.data.unsafe_set(buf.len, b'\x28')
  buf.len += 1
  write_u32_leb_unchecked(buf, 2)
  write_u32_leb_unchecked(buf, offset)
}

///|
fn emit_i32_load8_u(buf : ByteBuf, offset : Int) -> Unit {
  buf.ensure(11)
  buf.data.unsafe_set(buf.len, b'\x2d')
  buf.len += 1
  write_u32_leb_unchecked(buf, 0)
  write_u32_leb_unchecked(buf, offset)
}

///|
fn emit_i32_store(buf : ByteBuf, offset : Int) -> Unit {
  buf.ensure(11)
  buf.data.unsafe_set(buf.len, b'\x36')
  buf.len += 1
  write_u32_leb_unchecked(buf, 2)
  write_u32_leb_unchecked(buf, offset)
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
  buf.ensure(11)
  buf.data.unsafe_set(buf.len, b'\x3a')
  buf.len += 1
  write_u32_leb_unchecked(buf, 0)
  write_u32_leb_unchecked(buf, offset)
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
  buf.ensure(11)
  buf.data.unsafe_set(buf.len, b'\x29')
  buf.len += 1
  write_u32_leb_unchecked(buf, 3)
  write_u32_leb_unchecked(buf, offset)
}

///|
fn emit_i64_store(buf : ByteBuf, offset : Int) -> Unit {
  buf.ensure(11)
  buf.data.unsafe_set(buf.len, b'\x37')
  buf.len += 1
  write_u32_leb_unchecked(buf, 3)
  write_u32_leb_unchecked(buf, offset)
}

///|
fn emit_f32_load(buf : ByteBuf, offset : Int) -> Unit {
  buf.ensure(11)
  buf.data.unsafe_set(buf.len, b'\x2a')
  buf.len += 1
  write_u32_leb_unchecked(buf, 2)
  write_u32_leb_unchecked(buf, offset)
}

///|
fn emit_f64_load(buf : ByteBuf, offset : Int) -> Unit {
  buf.ensure(11)
  buf.data.unsafe_set(buf.len, b'\x2b')
  buf.len += 1
  write_u32_leb_unchecked(buf, 3)
  write_u32_leb_unchecked(buf, offset)
}

///|
fn emit_f32_store(buf : ByteBuf, offset : Int) -> Unit {
  buf.ensure(11)
  buf.data.unsafe_set(buf.len, b'\x38')
  buf.len += 1
  write_u32_leb_unchecked(buf, 2)
  write_u32_leb_unchecked(buf, offset)
}

///|
fn emit_f64_store(buf : ByteBuf, offset : Int) -> Unit {
  buf.ensure(11)
  buf.data.unsafe_set(buf.len, b'\x39')
  buf.len += 1
  write_u32_leb_unchecked(buf, 3)
  write_u32_leb_unchecked(buf, offset)
}

///|
fn emit_f64_reinterpret_i64(buf : ByteBuf) -> Unit {
  buf.push((0xBF).to_byte())
}

///|
/// i64 LEB128 — max 10 bytes. Uses ensure + unsafe_set.
fn write_i64_leb(buf : ByteBuf, n : Int64) -> Unit {
  buf.ensure(10)
  write_i64_leb_unchecked(buf, n)
}

///|
fn write_i64_leb_unchecked(buf : ByteBuf, n : Int64) -> Unit {
  write_i64_leb_unchecked_inner(buf, n, 0)
}

///|
fn write_i64_leb_unchecked_inner(
  buf : ByteBuf,
  value : Int64,
  depth : Int,
) -> Unit {
  let byte_val = (value & 0x7fL).to_int()
  let rest = value >> 7
  let sign_bit_set = (byte_val & 0x40) != 0
  let done = (rest == 0L && not(sign_bit_set)) || (rest == -1L && sign_bit_set)
  if done {
    buf.data.unsafe_set(buf.len, byte_val.to_byte())
    buf.len += 1
  } else if depth < 9 {
    buf.data.unsafe_set(buf.len, (byte_val | 0x80).to_byte())
    buf.len += 1
    write_i64_leb_unchecked_inner(buf, rest, depth + 1)
  } else {
    buf.data.unsafe_set(buf.len, byte_val.to_byte())
    buf.len += 1
  }
}

///|
fn emit_i64_const_raw(buf : ByteBuf, n : Int64) -> Unit {
  buf.ensure(11) // opcode + max 10 LEB128 bytes
  buf.data.unsafe_set(buf.len, b'\x42')
  buf.len += 1
  write_i64_leb_unchecked(buf, n)
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
fn emit_memory_copy(buf : ByteBuf) -> Unit {
  buf.push((0xFC).to_byte()) // prefix
  write_u32_leb(buf, 10) // memory.copy
  buf.push((0).to_byte()) // src memory 0
  buf.push((0).to_byte()) // dst memory 0
}

///|
fn emit_memory_fill(buf : ByteBuf) -> Unit {
  buf.push((0xFC).to_byte()) // prefix
  write_u32_leb(buf, 11) // memory.fill
  buf.push((0).to_byte()) // memory 0
}

///|
/// Convert i32 comparison result (0/1) on stack to tagged i64 bool.
/// Replaces the 5-instruction pattern: extend_i32_s, const 2, shl, const tag_bool, or
fn emit_tag_bool_from_i32(buf : ByteBuf) -> Unit {
  emit_i64_extend_i32_s(buf)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
  emit_i64_const_raw(buf, tag_bool.to_int64())
  emit_i64_or(buf)
}

///|
