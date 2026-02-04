///|
/// Minimal wasm-gc codegen for fixtures (struct.new / struct.get).
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
  let mut value = n
  while true {
    let mut byte = value & 0x7f
    value = value >> 7
    if value != 0 {
      byte = byte | 0x80
    }
    buf.push(byte)
    if value == 0 {
      break
    }
  }
}

///|
priv struct GcCodegenCtx {
  struct_types : Array[Int]
  struct_type_index : Map[Int, Int]
  locals : Map[String, Int]
  mut local_count : Int
}

///|
fn GcCodegenCtx::new() -> GcCodegenCtx {
  { struct_types: [], struct_type_index: {}, locals: {}, local_count: 0 }
}

///|
fn get_struct_type_index_gc(ctx : GcCodegenCtx, field_len : Int) -> Int {
  match ctx.struct_type_index.get(field_len) {
    Some(idx) => idx
    None => {
      let idx = ctx.struct_types.length()
      ctx.struct_types.push(field_len)
      ctx.struct_type_index[field_len] = idx
      idx
    }
  }
}

///|
fn emit_i32_const_gc(buf : GcByteBuf, n : Int) -> Unit {
  buf.push(0x41)
  write_u32_leb_gc(buf, n)
}

///|
fn emit_drop_gc(buf : GcByteBuf) -> Unit {
  buf.push(0x1a)
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
fn compile_expr_gc(
  ctx : GcCodegenCtx,
  buf : GcByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  match expr {
    @core.Expr::Int(value=n, span~) => {
      let _ = span
      emit_i32_const_gc(buf, n)
    }
    @core.Expr::Bool(value=b, span~) => {
      let _ = span
      emit_i32_const_gc(buf, if b { 1 } else { 0 })
    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      match ctx.locals.get(name) {
        Some(idx) => emit_local_get_gc(buf, idx)
        None => raise WasmGenError::UnknownName(name)
      }
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      let ordered = sort_record_fields_expr(fields)
      let type_idx = get_struct_type_index_gc(ctx, ordered.length())
      for field in ordered {
        compile_expr_gc(ctx, buf, field.expr)
      }
      emit_struct_new_gc(buf, type_idx)
    }
    @core.Expr::Call(name~, args~, span~) => {
      let _ = span
      if name == "record_set" {
        let pos_args : Array[@core.Expr] = []
        for arg in args {
          match arg.label {
            Some(_) => raise WasmGenError::Unsupported("record_set labeled")
            None => pos_args.push(arg.expr)
          }
        }
        if pos_args.length() != 3 {
          raise WasmGenError::Unsupported("record_set arity")
        }
        let record_expr = pos_args[0]
        let field_name = match pos_args[1] {
          @core.Expr::String(value=s, span~) => {
            let _ = span
            s
          }
          _ => raise WasmGenError::Unsupported("record_set field")
        }
        let value_expr = pos_args[2]
        match record_expr {
          @core.Expr::Record(fields~, span~) => {
            let _ = span
            let ordered = sort_record_fields_expr(fields)
            let type_idx = get_struct_type_index_gc(ctx, ordered.length())
            let mut field_idx = -1
            for i in 0..<ordered.length() {
              if ordered[i].name == field_name {
                field_idx = i
                break
              }
            }
            if field_idx < 0 {
              raise WasmGenError::Unsupported("record_set field")
            }
            for field in ordered {
              compile_expr_gc(ctx, buf, field.expr)
            }
            emit_struct_new_gc(buf, type_idx)
            let tmp = ctx.local_count
            ctx.local_count += 1
            emit_local_set_gc(buf, tmp)
            emit_local_get_gc(buf, tmp)
            compile_expr_gc(ctx, buf, value_expr)
            emit_struct_set_gc(buf, type_idx, field_idx)
            emit_local_get_gc(buf, tmp)
          }
          _ => raise WasmGenError::Unsupported("record_set record")
        }
      } else {
        raise WasmGenError::Unsupported("call")
      }
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      if arms.length() == 0 {
        raise WasmGenError::Unsupported("empty match")
      }
      match arms[0].pat {
        @core.Pat::Record(fields~, span~) => {
          let _ = span
          let ordered = sort_record_fields_pat(fields)
          let type_idx = get_struct_type_index_gc(ctx, ordered.length())
          compile_expr_gc(ctx, buf, scrutinee)
          emit_struct_get_gc(buf, type_idx, 0)
        }
        _ => raise WasmGenError::Unsupported("match pattern")
      }
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = try_body
      let _ = catch_body
      let _ = span
      raise WasmGenError::Unsupported("try")
    }
    _ => raise WasmGenError::Unsupported("expr")
  }
}

///|
fn compile_stmt_gc(
  ctx : GcCodegenCtx,
  buf : GcByteBuf,
  stmt : @core.Stmt,
  is_last : Bool,
) -> Unit raise WasmGenError {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let _ = span
      let _ = rec
      let idx = ctx.local_count
      ctx.local_count += 1
      ctx.locals[name] = idx
      compile_expr_gc(ctx, buf, expr)
      if is_last {
        emit_local_tee_gc(buf, idx)
      } else {
        emit_local_set_gc(buf, idx)
      }
    }
    @core.Stmt::Expr(expr~, span~) => {
      let _ = span
      compile_expr_gc(ctx, buf, expr)
      emit_drop_gc(buf)
    }
    _ => raise WasmGenError::Unsupported("stmt")
  }
}

///|
fn compile_block_gc(
  ctx : GcCodegenCtx,
  buf : GcByteBuf,
  body : @core.Module,
) -> Unit raise WasmGenError {
  let len = body.stmts.length()
  if len == 0 {
    return
  }
  for i in 0..<len {
    let is_last = i == len - 1
    compile_stmt_gc(ctx, buf, body.stmts[i], is_last)
  }
}

///|
fn write_section_gc(buf : GcByteBuf, id : Int, content : Array[Byte]) -> Unit {
  buf.push(id)
  write_u32_leb_gc(buf, content.length())
  buf.extend(content)
}

///|
fn build_module_gc(ctx : GcCodegenCtx, body : Array[Byte]) -> Bytes {
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
  let type_count = ctx.struct_types.length() + 1
  write_u32_leb_gc(type_sec, type_count)
  for field_len in ctx.struct_types {
    type_sec.push(0x5f)
    write_u32_leb_gc(type_sec, field_len)
    for _ in 0..<field_len {
      type_sec.push(0x7f)
      type_sec.push(0x00)
    }
  }
  type_sec.push(0x60)
  write_u32_leb_gc(type_sec, 0)
  write_u32_leb_gc(type_sec, 0)
  write_section_gc(buf, 1, type_sec.data)
  let func_sec = GcByteBuf::new()
  write_u32_leb_gc(func_sec, 1)
  write_u32_leb_gc(func_sec, ctx.struct_types.length())
  write_section_gc(buf, 3, func_sec.data)
  let code_sec = GcByteBuf::new()
  write_u32_leb_gc(code_sec, 1)
  let func_body = GcByteBuf::new()
  if ctx.local_count == 0 {
    write_u32_leb_gc(func_body, 0)
  } else {
    write_u32_leb_gc(func_body, 1)
    write_u32_leb_gc(func_body, ctx.local_count)
    func_body.push(0x7f)
  }
  func_body.extend(body)
  func_body.push(0x0b)
  write_u32_leb_gc(code_sec, func_body.len())
  code_sec.extend(func_body.data)
  write_section_gc(buf, 10, code_sec.data)
  buf.to_bytes()
}

///|
pub fn emit_module_wasm_gc(ast : @core.Module) -> Bytes raise WasmGenError {
  let ctx = GcCodegenCtx::new()
  let body = GcByteBuf::new()
  compile_block_gc(ctx, body, ast)
  build_module_gc(ctx, body.data)
}
