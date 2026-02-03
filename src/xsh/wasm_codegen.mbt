///| Minimal WASM (wasm-gc compatible) codegen for xsh

suberror WasmGenError {
  UnknownName(String)
  Unsupported(String)
} derive(Show, Eq)

priv struct StringSegment {
  offset : Int
  bytes : Array[Byte]
}

priv struct StringTable {
  mut next_offset : Int
  map : Map[String, Int]
  segments : Array[StringSegment]
}

fn StringTable::new() -> StringTable {
  { next_offset: 0, map: {}, segments: [] }
}

fn align4(n : Int) -> Int {
  let rem = n % 4
  if rem == 0 { n } else { n + (4 - rem) }
}

let tag_mask = 3
let tag_int = 0
let tag_obj = 1
let tag_bool = 3

let obj_string = 1
let obj_tuple = 3
let obj_record = 4

fn tag_ptr(ptr : Int, tag : Int) -> Int {
  ptr | (tag & tag_mask)
}

fn tag_int_value(n : Int) -> Int {
  (n << 2) | tag_int
}

fn tag_bool_value(b : Bool) -> Int {
  let n = if b { 1 } else { 0 }
  (n << 2) | tag_bool
}

fn StringTable::intern(self : StringTable, s : String) -> Int {
  match self.map.get(s) {
    Some(offset) => offset
    None => {
      let bytes = @utf8.encode(s)
      let content = bytes.to_array()
      let len = content.length()
      let data : Array[Byte] = []
      write_u32_le_bytes(data, obj_string)
      write_u32_le_bytes(data, len)
      for b in content {
        data.push(b)
      }
      let offset = self.next_offset
      self.map[s] = offset
      self.segments.push(StringSegment::{ offset, bytes: data })
      self.next_offset = align4(offset + data.length())
      offset
    }
  }
}

priv struct CodegenCtx {
  locals : Map[String, Int]
  mut local_count : Int
  mut need_sh : Bool
  mut need_path : Bool
  mut need_heap : Bool
  mut heap_local : Int
  strings : StringTable
}

fn CodegenCtx::new() -> CodegenCtx {
  {
    locals: {},
    local_count: 0,
    need_sh: false,
    need_path: false,
    need_heap: false,
    heap_local: -1,
    strings: StringTable::new(),
  }
}

priv struct ByteBuf {
  data : Array[Byte]
}

fn ByteBuf::new() -> ByteBuf {
  { data: [] }
}

fn ByteBuf::push(self : ByteBuf, b : Byte) -> Unit {
  self.data.push(b)
}

fn ByteBuf::extend(self : ByteBuf, bytes : Array[Byte]) -> Unit {
  for b in bytes {
    self.data.push(b)
  }
}

fn ByteBuf::len(self : ByteBuf) -> Int {
  self.data.length()
}

fn ByteBuf::to_bytes(self : ByteBuf) -> Bytes {
  Bytes::from_array(self.data)
}

fn write_u32_leb(buf : ByteBuf, n : Int) -> Unit {
  let mut value = n
  while { true } {
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

fn write_u32_le_bytes(out : Array[Byte], n : Int) -> Unit {
  let v = n
  out.push((v & 0xff).to_byte())
  out.push(((v >> 8) & 0xff).to_byte())
  out.push(((v >> 16) & 0xff).to_byte())
  out.push(((v >> 24) & 0xff).to_byte())
}

fn write_name(buf : ByteBuf, s : String) -> Unit {
  let bytes = @utf8.encode(s)
  let arr = bytes.to_array()
  write_u32_leb(buf, arr.length())
  buf.extend(arr)
}

fn emit_i32_const_raw(buf : ByteBuf, n : Int) -> Unit {
  buf.push((65).to_byte())
  write_u32_leb(buf, n)
}

fn emit_i32_const_tagged(buf : ByteBuf, n : Int) -> Unit {
  emit_i32_const_raw(buf, tag_int_value(n))
}

fn emit_bool_from_i32(buf : ByteBuf) -> Unit {
  emit_i32_const_raw(buf, 2)
  emit_i32_shl(buf)
  emit_i32_const_raw(buf, tag_bool)
  emit_i32_or(buf)
}

fn emit_local_get(buf : ByteBuf, idx : Int) -> Unit {
  buf.push((32).to_byte())
  write_u32_leb(buf, idx)
}

fn emit_local_set(buf : ByteBuf, idx : Int) -> Unit {
  buf.push((33).to_byte())
  write_u32_leb(buf, idx)
}

fn emit_local_tee(buf : ByteBuf, idx : Int) -> Unit {
  buf.push((34).to_byte())
  write_u32_leb(buf, idx)
}

fn emit_call(buf : ByteBuf, idx : Int) -> Unit {
  buf.push((16).to_byte())
  write_u32_leb(buf, idx)
}

fn emit_drop(buf : ByteBuf) -> Unit {
  buf.push((26).to_byte())
}

fn emit_i32_add(buf : ByteBuf) -> Unit {
  buf.push((106).to_byte())
}

fn emit_i32_sub(buf : ByteBuf) -> Unit {
  buf.push((107).to_byte())
}

fn emit_i32_eq(buf : ByteBuf) -> Unit {
  buf.push((70).to_byte())
}

fn emit_i32_lt_s(buf : ByteBuf) -> Unit {
  buf.push((72).to_byte())
}

fn emit_i32_shl(buf : ByteBuf) -> Unit {
  buf.push((116).to_byte())
}

fn emit_i32_shr_u(buf : ByteBuf) -> Unit {
  buf.push((118).to_byte())
}

fn emit_i32_or(buf : ByteBuf) -> Unit {
  buf.push((114).to_byte())
}

fn emit_i32_and(buf : ByteBuf) -> Unit {
  buf.push((113).to_byte())
}

fn emit_i32_xor(buf : ByteBuf) -> Unit {
  buf.push((115).to_byte())
}

fn emit_i32_load(buf : ByteBuf, offset : Int) -> Unit {
  buf.push((40).to_byte())
  write_u32_leb(buf, 2)
  write_u32_leb(buf, offset)
}

fn emit_i32_store(buf : ByteBuf, offset : Int) -> Unit {
  buf.push((54).to_byte())
  write_u32_leb(buf, 2)
  write_u32_leb(buf, offset)
}

fn is_qualified_name(name : String) -> Bool {
  for c in name {
    if c == '.' || c == '#' {
      return true
    }
  }
  false
}

fn scan_needs_expr(ctx : CodegenCtx, expr : Expr) -> Unit {
  match expr {
    Expr::Call(name~, args~) => {
      if name == "sh" {
        ctx.need_sh = true
      } else if name == "path" {
        ctx.need_path = true
      }
      for arg in args {
        scan_needs_expr(ctx, arg)
      }
    }
    Expr::Tuple(items) => {
      ctx.need_heap = true
      for item in items {
        scan_needs_expr(ctx, item)
      }
    }
    Expr::Record(fields) => {
      ctx.need_heap = true
      for field in fields {
        scan_needs_expr(ctx, field.expr)
      }
    }
    Expr::If(cond~, then_body~, else_body~) => {
      scan_needs_expr(ctx, cond)
      scan_needs_block(ctx, then_body)
      scan_needs_block(ctx, else_body)
    }
    Expr::Match(scrutinee~, arms~) => {
      scan_needs_expr(ctx, scrutinee)
      for arm in arms {
        scan_needs_expr(ctx, arm.expr)
        match arm.cond {
          Some(c) => scan_needs_expr(ctx, c)
          None => ()
        }
      }
    }
    Expr::Do(body~) => {
      scan_needs_block(ctx, body)
    }
    _ => ()
  }
}

fn scan_needs_block(ctx : CodegenCtx, body : Module) -> Unit {
  for stmt in body.stmts {
    scan_needs_stmt(ctx, stmt)
  }
}

fn scan_needs_stmt(ctx : CodegenCtx, stmt : Stmt) -> Unit {
  match stmt {
    Stmt::Let(name~, expr~) => {
      let _ = name
      scan_needs_expr(ctx, expr)
    }
    Stmt::Expr(expr~) => scan_needs_expr(ctx, expr)
    Stmt::Test(name~, body~) => {
      let _ = name
      for s in body.stmts {
        scan_needs_stmt(ctx, s)
      }
    }
    _ => ()
  }
}

fn scan_needs(ctx : CodegenCtx, ast : Module) -> Unit {
  for stmt in ast.stmts {
    scan_needs_stmt(ctx, stmt)
  }
}

fn import_index_path(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_path) {
    raise WasmGenError::Unsupported("path import missing")
  }
  0
}

fn import_index_sh(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_sh) {
    raise WasmGenError::Unsupported("sh import missing")
  }
  if ctx.need_path { 1 } else { 0 }
}

fn compile_expr(ctx : CodegenCtx, buf : ByteBuf, expr : Expr) -> Unit raise WasmGenError {
  match expr {
    Expr::Int(n) => emit_i32_const_tagged(buf, n)
    Expr::Bool(b) => emit_i32_const_raw(buf, tag_bool_value(b))
    Expr::String(s) => {
      let offset = ctx.strings.intern(s)
      emit_i32_const_raw(buf, tag_ptr(offset, tag_obj))
    }
    Expr::Ident(name) => {
      if is_qualified_name(name) {
        raise WasmGenError::Unsupported("qualified name: " + name)
      }
      match ctx.locals.get(name) {
        Some(idx) => emit_local_get(buf, idx)
        None => raise WasmGenError::UnknownName(name)
      }
    }
    Expr::Call(name~, args~) => {
      if name == "sh" {
        if args.length() != 1 {
          raise WasmGenError::Unsupported("sh arity")
        }
        compile_expr(ctx, buf, args[0])
        emit_call(buf, import_index_sh(ctx))
        emit_drop(buf)
        emit_i32_const_tagged(buf, 0)
      } else if name == "path" {
        if args.length() != 1 {
          raise WasmGenError::Unsupported("path arity")
        }
        compile_expr(ctx, buf, args[0])
        emit_call(buf, import_index_path(ctx))
      } else if name == "add" {
        if args.length() != 2 {
          raise WasmGenError::Unsupported("add arity")
        }
        compile_expr(ctx, buf, args[0])
        compile_expr(ctx, buf, args[1])
        emit_i32_add(buf)
      } else if name == "sub" {
        if args.length() != 2 {
          raise WasmGenError::Unsupported("sub arity")
        }
        compile_expr(ctx, buf, args[0])
        compile_expr(ctx, buf, args[1])
        emit_i32_sub(buf)
      } else if name == "eq" {
        if args.length() != 2 {
          raise WasmGenError::Unsupported("eq arity")
        }
        compile_expr(ctx, buf, args[0])
        compile_expr(ctx, buf, args[1])
        emit_i32_eq(buf)
        emit_bool_from_i32(buf)
      } else if name == "lt" {
        if args.length() != 2 {
          raise WasmGenError::Unsupported("lt arity")
        }
        compile_expr(ctx, buf, args[0])
        compile_expr(ctx, buf, args[1])
        emit_i32_lt_s(buf)
        emit_bool_from_i32(buf)
      } else if name == "not" {
        if args.length() != 1 {
          raise WasmGenError::Unsupported("not arity")
        }
        compile_expr(ctx, buf, args[0])
        emit_i32_const_raw(buf, 4)
        emit_i32_xor(buf)
      } else if name == "and" {
        if args.length() != 2 {
          raise WasmGenError::Unsupported("and arity")
        }
        compile_expr(ctx, buf, args[0])
        compile_expr(ctx, buf, args[1])
        emit_i32_and(buf)
      } else if name == "or" {
        if args.length() != 2 {
          raise WasmGenError::Unsupported("or arity")
        }
        compile_expr(ctx, buf, args[0])
        compile_expr(ctx, buf, args[1])
        emit_i32_or(buf)
      } else {
        if is_qualified_name(name) {
          raise WasmGenError::Unsupported("qualified call: " + name)
        }
        raise WasmGenError::Unsupported("call: " + name)
      }
    }
    Expr::Tuple(items) => {
      compile_tuple_expr(ctx, buf, items)
    }
    Expr::Record(fields) => {
      compile_record_expr(ctx, buf, fields)
    }
    Expr::If(cond~, then_body~, else_body~) => {
      compile_expr(ctx, buf, cond)
      emit_i32_const_raw(buf, 2)
      emit_i32_shr_u(buf)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      compile_block_expr(ctx, buf, then_body)
      buf.push((5).to_byte())
      compile_block_expr(ctx, buf, else_body)
      buf.push((11).to_byte())
    }
    Expr::Block(body~) => {
      compile_block_expr(ctx, buf, body)
    }
    Expr::Match(scrutinee~, arms~) => {
      let saved = clone_locals(ctx.locals)
      let scrut_idx = ctx.local_count
      ctx.local_count += 1
      compile_expr(ctx, buf, scrutinee)
      emit_local_set(buf, scrut_idx)
      compile_match_chain(ctx, buf, scrut_idx, arms, 0)
      restore_locals(ctx, saved)
    }
    Expr::Do(body~) => {
      compile_block_expr(ctx, buf, body)
    }
  }
}

fn compile_stmt(ctx : CodegenCtx, buf : ByteBuf, stmt : Stmt, is_last : Bool) -> Unit raise WasmGenError {
  match stmt {
    Stmt::Let(name~, expr~) => {
      let idx = ctx.local_count
      ctx.local_count += 1
      ctx.locals[name] = idx
      compile_expr(ctx, buf, expr)
      if is_last {
        emit_local_tee(buf, idx)
      } else {
        emit_local_set(buf, idx)
      }
    }
    Stmt::Expr(expr~) => {
      compile_expr(ctx, buf, expr)
      if not(is_last) {
        emit_drop(buf)
      }
    }
    Stmt::Flake(_) => {
      if is_last {
        emit_i32_const_tagged(buf, 0)
      }
    }
    Stmt::Test(..) => {
      if is_last {
        emit_i32_const_tagged(buf, 0)
      }
    }
    Stmt::Alias(..) => raise WasmGenError::Unsupported("alias")
    Stmt::Import(..) => raise WasmGenError::Unsupported("import")
  }
}

fn compile_block_expr(ctx : CodegenCtx, buf : ByteBuf, body : Module) -> Unit raise WasmGenError {
  let saved = clone_locals(ctx.locals)
  let len = body.stmts.length()
  if len == 0 {
    emit_i32_const_tagged(buf, 0)
  } else {
    for i in 0..<len {
      let is_last = i == len - 1
      compile_stmt(ctx, buf, body.stmts[i], is_last)
    }
  }
  restore_locals(ctx, saved)
}

fn require_heap(ctx : CodegenCtx) -> Unit raise WasmGenError {
  if ctx.heap_local < 0 {
    raise WasmGenError::Unsupported("heap not initialized")
  }
}

fn compile_tuple_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  items : Array[Expr]
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let len = items.length()
  let size = align4(8 + len * 4)
  let obj_local = alloc_temp_local(ctx)
  emit_local_get(buf, ctx.heap_local)
  emit_local_set(buf, obj_local)
  emit_local_get(buf, ctx.heap_local)
  emit_i32_const_raw(buf, size)
  emit_i32_add(buf)
  emit_local_set(buf, ctx.heap_local)

  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_tuple)
  emit_i32_store(buf, 0)

  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, len)
  emit_i32_store(buf, 4)

  for i in 0..<len {
    emit_local_get(buf, obj_local)
    compile_expr(ctx, buf, items[i])
    emit_i32_store(buf, 8 + i * 4)
  }

  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_or(buf)
}

fn compile_record_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  fields : Array[RecordFieldExpr]
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let ordered = sort_record_fields_expr(fields)
  let len = ordered.length()
  let size = align4(8 + len * 8)
  let obj_local = alloc_temp_local(ctx)
  emit_local_get(buf, ctx.heap_local)
  emit_local_set(buf, obj_local)
  emit_local_get(buf, ctx.heap_local)
  emit_i32_const_raw(buf, size)
  emit_i32_add(buf)
  emit_local_set(buf, ctx.heap_local)

  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_record)
  emit_i32_store(buf, 0)

  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, len)
  emit_i32_store(buf, 4)

  for i in 0..<len {
    let field = ordered[i]
    let name_ptr = ctx.strings.intern(field.name)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, name_ptr)
    emit_i32_store(buf, 8 + i * 8)
    emit_local_get(buf, obj_local)
    compile_expr(ctx, buf, field.expr)
    emit_i32_store(buf, 8 + i * 8 + 4)
  }

  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_or(buf)
}

fn sort_record_fields_expr(fields : Array[RecordFieldExpr]) -> Array[RecordFieldExpr] {
  let out : Array[RecordFieldExpr] = []
  for field in fields {
    out.push(field)
    let mut i = out.length() - 1
    while i > 0 && string_lt(out[i].name, out[i - 1].name) {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

fn sort_record_fields_pat(fields : Array[RecordFieldPat]) -> Array[RecordFieldPat] {
  let out : Array[RecordFieldPat] = []
  for field in fields {
    out.push(field)
    let mut i = out.length() - 1
    while i > 0 && string_lt(out[i].name, out[i - 1].name) {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

fn string_lt(a : String, b : String) -> Bool {
  let ac : Array[Char] = []
  for c in a {
    ac.push(c)
  }
  let bc : Array[Char] = []
  for c in b {
    bc.push(c)
  }
  let min = if ac.length() < bc.length() { ac.length() } else { bc.length() }
  for i in 0..<min {
    if ac[i] < bc[i] {
      return true
    }
    if ac[i] > bc[i] {
      return false
    }
  }
  ac.length() < bc.length()
}

fn compile_body(ctx : CodegenCtx, ast : Module) -> Array[Byte] raise WasmGenError {
  let instr = ByteBuf::new()
  if ctx.need_heap {
    ctx.heap_local = ctx.local_count
    ctx.local_count += 1
  }
  compile_block_expr(ctx, instr, ast)
  instr.push((11).to_byte())
  if ctx.need_heap {
    let prologue = ByteBuf::new()
    let heap_start = align4(ctx.strings.next_offset)
    emit_i32_const_raw(prologue, heap_start)
    emit_local_set(prologue, ctx.heap_local)
    prologue.extend(instr.data)
    prologue.data
  } else {
    instr.data
  }
}

fn build_module(ctx : CodegenCtx, body : Array[Byte]) -> Bytes {
  let buf = ByteBuf::new()
  // magic + version
  buf.push((0).to_byte())
  buf.push((97).to_byte())
  buf.push((115).to_byte())
  buf.push((109).to_byte())
  buf.push((1).to_byte())
  buf.push((0).to_byte())
  buf.push((0).to_byte())
  buf.push((0).to_byte())

  // type section
  let type_sec = ByteBuf::new()
  let has_import_type = ctx.need_sh || ctx.need_path
  let type_count = if has_import_type { 2 } else { 1 }
  write_u32_leb(type_sec, type_count)
  if has_import_type {
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 1)
    type_sec.push((127).to_byte())
    write_u32_leb(type_sec, 1)
    type_sec.push((127).to_byte())
  }
  type_sec.push((96).to_byte())
  write_u32_leb(type_sec, 0)
  write_u32_leb(type_sec, 1)
  type_sec.push((127).to_byte())
  write_section(buf, 1, type_sec.data)

  // import section
  let mut import_count = 0
  if ctx.need_path {
    import_count += 1
  }
  if ctx.need_sh {
    import_count += 1
  }
  if import_count > 0 {
    let import_sec = ByteBuf::new()
    write_u32_leb(import_sec, import_count)
    if ctx.need_path {
      write_name(import_sec, "xsh")
      write_name(import_sec, "path")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, 0)
    }
    if ctx.need_sh {
      write_name(import_sec, "xsh")
      write_name(import_sec, "sh")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, 0)
    }
    write_section(buf, 2, import_sec.data)
  }

  // function section
  let func_sec = ByteBuf::new()
  write_u32_leb(func_sec, 1)
  let run_type_idx = if has_import_type { 1 } else { 0 }
  write_u32_leb(func_sec, run_type_idx)
  write_section(buf, 3, func_sec.data)

  // memory section
  let mem_sec = ByteBuf::new()
  write_u32_leb(mem_sec, 1)
  mem_sec.push((0).to_byte())
  write_u32_leb(mem_sec, 1)
  write_section(buf, 5, mem_sec.data)

  // export section
  let export_sec = ByteBuf::new()
  write_u32_leb(export_sec, 2)
  write_name(export_sec, "run")
  export_sec.push((0).to_byte())
  write_u32_leb(export_sec, import_count)
  write_name(export_sec, "memory")
  export_sec.push((2).to_byte())
  write_u32_leb(export_sec, 0)
  write_section(buf, 7, export_sec.data)

  // code section
  let code_sec = ByteBuf::new()
  write_u32_leb(code_sec, 1)
  let func_body = ByteBuf::new()
  if ctx.local_count == 0 {
    write_u32_leb(func_body, 0)
  } else {
    write_u32_leb(func_body, 1)
    write_u32_leb(func_body, ctx.local_count)
    func_body.push((127).to_byte())
  }
  func_body.extend(body)
  write_u32_leb(code_sec, func_body.len())
  code_sec.extend(func_body.data)
  write_section(buf, 10, code_sec.data)

  // data section
  let data_sec = ByteBuf::new()
  write_u32_leb(data_sec, ctx.strings.segments.length())
  for seg in ctx.strings.segments {
    data_sec.push((0).to_byte())
    emit_i32_const_raw(data_sec, seg.offset)
    data_sec.push((11).to_byte())
    write_u32_leb(data_sec, seg.bytes.length())
    data_sec.extend(seg.bytes)
  }
  write_section(buf, 11, data_sec.data)

  buf.to_bytes()
}

fn write_section(buf : ByteBuf, id : Int, content : Array[Byte]) -> Unit {
  buf.push(id.to_byte())
  write_u32_leb(buf, content.length())
  buf.extend(content)
}

fn clone_locals(src : Map[String, Int]) -> Map[String, Int] {
  let out : Map[String, Int] = {}
  for k, v in src {
    out[k] = v
  }
  out
}

fn restore_locals(ctx : CodegenCtx, saved : Map[String, Int]) -> Unit {
  let to_remove : Array[String] = []
  for name, _ in ctx.locals {
    if not(saved.contains(name)) {
      to_remove.push(name)
    }
  }
  for name in to_remove {
    ctx.locals.remove(name)
  }
  for name, idx in saved {
    ctx.locals[name] = idx
  }
}

priv enum PatCont {
  Arm
  Tuple(Int, Array[Pat], Int, PatCont)
  Record(Int, Array[RecordFieldPat], Int, PatCont)
}

fn compile_pat_cont(
  ctx : CodegenCtx,
  buf : ByteBuf,
  cont : PatCont,
  match_scrut_idx : Int,
  arms : Array[MatchArm],
  start : Int,
  arm : MatchArm,
  bindings : Map[String, Int]
) -> Unit raise WasmGenError {
  match cont {
    PatCont::Arm => {
      compile_guarded_arm_with_bindings(ctx, buf, match_scrut_idx, arms, start, arm, bindings)
    }
    PatCont::Tuple(tuple_idx, items, index, next) => {
      compile_tuple_items_cont(ctx, buf, tuple_idx, items, index, next, match_scrut_idx, arms, start, arm, bindings)
    }
    PatCont::Record(record_idx, fields, index, next) => {
      compile_record_fields_cont(ctx, buf, record_idx, fields, index, next, match_scrut_idx, arms, start, arm, bindings)
    }
  }
}

fn compile_pat_match(
  ctx : CodegenCtx,
  buf : ByteBuf,
  value_idx : Int,
  pat : Pat,
  match_scrut_idx : Int,
  arms : Array[MatchArm],
  start : Int,
  arm : MatchArm,
  bindings : Map[String, Int],
  cont : PatCont
) -> Unit raise WasmGenError {
  match pat {
    Pat::Wildcard => {
      compile_pat_cont(ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings)
    }
    Pat::Bind(name) => {
      let idx = bind_local(ctx, name)
      emit_local_get(buf, value_idx)
      emit_local_set(buf, idx)
      bindings[name] = idx
      compile_pat_cont(ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings)
    }
    Pat::Int(_) | Pat::Bool(_) | Pat::String(_) => {
      emit_local_get(buf, value_idx)
      emit_pat_literal(ctx, buf, pat)
      emit_i32_eq(buf)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      compile_pat_cont(ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings)
      buf.push((5).to_byte())
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte())
    }
    Pat::Tuple(items) => {
      emit_tag_obj_check(buf, value_idx)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      emit_load_obj_type(buf, value_idx)
      emit_i32_const_raw(buf, obj_tuple)
      emit_i32_eq(buf)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      emit_load_obj_len(buf, value_idx)
      emit_i32_const_raw(buf, items.length())
      emit_i32_eq(buf)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      compile_tuple_items_cont(ctx, buf, value_idx, items, 0, cont, match_scrut_idx, arms, start, arm, bindings)
      buf.push((5).to_byte())
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte())
      buf.push((5).to_byte())
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte())
      buf.push((5).to_byte())
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte())
    }
    Pat::Record(fields) => {
      let ordered = sort_record_fields_pat(fields)
      emit_tag_obj_check(buf, value_idx)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      emit_load_obj_type(buf, value_idx)
      emit_i32_const_raw(buf, obj_record)
      emit_i32_eq(buf)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      emit_load_obj_len(buf, value_idx)
      emit_i32_const_raw(buf, ordered.length())
      emit_i32_eq(buf)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      compile_record_fields_cont(ctx, buf, value_idx, ordered, 0, cont, match_scrut_idx, arms, start, arm, bindings)
      buf.push((5).to_byte())
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte())
      buf.push((5).to_byte())
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte())
      buf.push((5).to_byte())
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte())
    }
  }
}

fn compile_tuple_items_cont(
  ctx : CodegenCtx,
  buf : ByteBuf,
  tuple_idx : Int,
  items : Array[Pat],
  index : Int,
  next : PatCont,
  match_scrut_idx : Int,
  arms : Array[MatchArm],
  start : Int,
  arm : MatchArm,
  bindings : Map[String, Int]
) -> Unit raise WasmGenError {
  if index >= items.length() {
    compile_pat_cont(ctx, buf, next, match_scrut_idx, arms, start, arm, bindings)
    return
  }
  let tmp = alloc_temp_local(ctx)
  emit_load_tuple_elem(buf, tuple_idx, index)
  emit_local_set(buf, tmp)
  let cont = PatCont::Tuple(tuple_idx, items, index + 1, next)
  compile_pat_match(ctx, buf, tmp, items[index], match_scrut_idx, arms, start, arm, bindings, cont)
}

fn compile_record_fields_cont(
  ctx : CodegenCtx,
  buf : ByteBuf,
  record_idx : Int,
  fields : Array[RecordFieldPat],
  index : Int,
  next : PatCont,
  match_scrut_idx : Int,
  arms : Array[MatchArm],
  start : Int,
  arm : MatchArm,
  bindings : Map[String, Int]
) -> Unit raise WasmGenError {
  if index >= fields.length() {
    compile_pat_cont(ctx, buf, next, match_scrut_idx, arms, start, arm, bindings)
    return
  }
  let field = fields[index]
  let name_ptr = ctx.strings.intern(field.name)
  emit_load_record_name(buf, record_idx, index)
  emit_i32_const_raw(buf, name_ptr)
  emit_i32_eq(buf)
  buf.push((4).to_byte())
  buf.push((127).to_byte())
  let tmp = alloc_temp_local(ctx)
  emit_load_record_value(buf, record_idx, index)
  emit_local_set(buf, tmp)
  let cont = PatCont::Record(record_idx, fields, index + 1, next)
  compile_pat_match(ctx, buf, tmp, field.pat, match_scrut_idx, arms, start, arm, bindings, cont)
  buf.push((5).to_byte())
  compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
  buf.push((11).to_byte())
}

fn emit_pat_literal(ctx : CodegenCtx, buf : ByteBuf, pat : Pat) -> Unit raise WasmGenError {
  match pat {
    Pat::Wildcard => raise WasmGenError::Unsupported("wildcard literal")
    Pat::Bind(_) => raise WasmGenError::Unsupported("bind literal")
    Pat::Tuple(_) => raise WasmGenError::Unsupported("tuple literal")
    Pat::Record(_) => raise WasmGenError::Unsupported("record literal")
    Pat::Int(n) => emit_i32_const_tagged(buf, n)
    Pat::Bool(b) => emit_i32_const_raw(buf, tag_bool_value(b))
    Pat::String(s) => {
      let offset = ctx.strings.intern(s)
      emit_i32_const_raw(buf, tag_ptr(offset, tag_obj))
    }
  }
}

fn compile_match_chain(
  ctx : CodegenCtx,
  buf : ByteBuf,
  scrut_idx : Int,
  arms : Array[MatchArm],
  start : Int
) -> Unit raise WasmGenError {
  if start >= arms.length() {
    emit_i32_const_tagged(buf, 0)
    return
  }
  let arm = arms[start]
  let saved = clone_locals(ctx.locals)
  let bindings : Map[String, Int] = {}
  compile_pat_match(ctx, buf, scrut_idx, arm.pat, scrut_idx, arms, start, arm, bindings, PatCont::Arm)
  restore_locals(ctx, saved)
}

fn compile_guarded_arm_with_bindings(
  ctx : CodegenCtx,
  buf : ByteBuf,
  scrut_idx : Int,
  arms : Array[MatchArm],
  index : Int,
  arm : MatchArm,
  bindings : Map[String, Int]
) -> Unit raise WasmGenError {
  let saved = clone_locals(ctx.locals)
  for name, idx in bindings {
    ctx.locals[name] = idx
  }
  match arm.cond {
    Some(c) => {
      compile_expr(ctx, buf, c)
      emit_i32_const_raw(buf, 2)
      emit_i32_shr_u(buf)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      compile_expr(ctx, buf, arm.expr)
      buf.push((5).to_byte())
      restore_locals(ctx, saved)
      compile_match_chain(ctx, buf, scrut_idx, arms, index + 1)
      buf.push((11).to_byte())
      restore_locals(ctx, saved)
    }
    None => {
      compile_expr(ctx, buf, arm.expr)
      restore_locals(ctx, saved)
    }
  }
}

fn bind_local(ctx : CodegenCtx, _name : String) -> Int {
  let idx = ctx.local_count
  ctx.local_count += 1
  idx
}

fn alloc_temp_local(ctx : CodegenCtx) -> Int {
  let idx = ctx.local_count
  ctx.local_count += 1
  idx
}

fn emit_tag_obj_check(buf : ByteBuf, scrut_idx : Int) -> Unit {
  emit_local_get(buf, scrut_idx)
  emit_i32_const_raw(buf, tag_mask)
  emit_i32_and(buf)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_eq(buf)
}

fn emit_untag_ptr(buf : ByteBuf, scrut_idx : Int) -> Unit {
  emit_local_get(buf, scrut_idx)
  emit_local_get(buf, scrut_idx)
  emit_i32_const_raw(buf, tag_mask)
  emit_i32_and(buf)
  emit_i32_sub(buf)
}

fn emit_load_obj_type(buf : ByteBuf, scrut_idx : Int) -> Unit {
  emit_untag_ptr(buf, scrut_idx)
  emit_i32_load(buf, 0)
}

fn emit_load_obj_len(buf : ByteBuf, scrut_idx : Int) -> Unit {
  emit_untag_ptr(buf, scrut_idx)
  emit_i32_load(buf, 4)
}

fn emit_load_tuple_elem(buf : ByteBuf, scrut_idx : Int, index : Int) -> Unit {
  emit_untag_ptr(buf, scrut_idx)
  emit_i32_load(buf, 8 + index * 4)
}

fn emit_load_record_name(buf : ByteBuf, scrut_idx : Int, index : Int) -> Unit {
  emit_untag_ptr(buf, scrut_idx)
  emit_i32_load(buf, 8 + index * 8)
}

fn emit_load_record_value(buf : ByteBuf, scrut_idx : Int, index : Int) -> Unit {
  emit_untag_ptr(buf, scrut_idx)
  emit_i32_load(buf, 8 + index * 8 + 4)
}

///| Emit a WASM module for a typed xsh AST.
pub fn emit_module_wasm(ast : Module) -> Bytes raise WasmGenError {
  let ctx = CodegenCtx::new()
  scan_needs(ctx, ast)
  let body = compile_body(ctx, ast)
  build_module(ctx, body)
}
