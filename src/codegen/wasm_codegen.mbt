///|
/// Minimal WASM (wasm-gc compatible) codegen for xsh
suberror WasmGenError {
  UnknownName(String)
  Unsupported(String)
} derive(Show, Eq)

///|
priv struct StringSegment {
  offset : Int
  bytes : Array[Byte]
}

///|
priv struct StringTable {
  mut next_offset : Int
  map : Map[String, Int]
  segments : Array[StringSegment]
}

///|
fn StringTable::new() -> StringTable {
  { next_offset: 0, map: {}, segments: [] }
}

///|
fn align4(n : Int) -> Int {
  let rem = n % 4
  if rem == 0 {
    n
  } else {
    n + (4 - rem)
  }
}

///|
let tag_mask = 3

///|
let tag_int = 0

///|
let tag_obj = 1

///|
let tag_bool = 3

///|
let obj_string = 1

///|
let obj_tuple = 3

///|
let obj_record = 4

///|
let obj_array = 5

///|
let obj_map = 6

///|
enum ValueKind {
  I32
  ExternRef
} derive(Show, Eq)

///|
fn valtype_byte(kind : ValueKind) -> Byte {
  match kind {
    ValueKind::I32 => (127).to_byte()
    ValueKind::ExternRef => (111).to_byte()
  }
}

///|
priv struct StringConstTable {
  map : Map[String, Int]
  names : Array[String]
}

///|
fn StringConstTable::new() -> StringConstTable {
  { map: {}, names: [] }
}

///|
fn StringConstTable::intern(self : StringConstTable, s : String) -> Int {
  match self.map.get(s) {
    Some(idx) => idx
    None => {
      let idx = self.names.length()
      self.map[s] = idx
      self.names.push(s)
      idx
    }
  }
}

///|
fn tag_ptr(ptr : Int, tag : Int) -> Int {
  ptr | (tag & tag_mask)
}

///|
fn tag_int_value(n : Int) -> Int {
  (n << 2) | tag_int
}

///|
fn tag_bool_value(b : Bool) -> Int {
  let n = if b { 1 } else { 0 }
  (n << 2) | tag_bool
}

///|
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

///|
priv struct CodegenCtx {
  locals : Map[String, Int]
  local_kinds : Map[String, ValueKind]
  local_types : Array[ValueKind]
  mut local_count : Int
  mut need_sh : Bool
  mut need_path : Bool
  mut need_js_length : Bool
  mut need_js_char_code_at : Bool
  mut need_js_substring : Bool
  mut need_js_concat : Bool
  mut need_js_equals : Bool
  use_js_strings : Bool
  mut need_heap : Bool
  mut heap_local : Int
  strings : StringTable
  js_strings : StringConstTable
}

///|
fn CodegenCtx::new(use_js_strings : Bool) -> CodegenCtx {
  {
    locals: {},
    local_kinds: {},
    local_types: [],
    local_count: 0,
    need_sh: false,
    need_path: false,
    need_js_length: false,
    need_js_char_code_at: false,
    need_js_substring: false,
    need_js_concat: false,
    need_js_equals: false,
    use_js_strings,
    need_heap: false,
    heap_local: -1,
    strings: StringTable::new(),
    js_strings: StringConstTable::new(),
  }
}

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
fn emit_i32_const_raw(buf : ByteBuf, n : Int) -> Unit {
  buf.push((65).to_byte())
  write_u32_leb(buf, n)
}

///|
fn emit_i32_const_tagged(buf : ByteBuf, n : Int) -> Unit {
  emit_i32_const_raw(buf, tag_int_value(n))
}

///|
fn emit_bool_from_i32(buf : ByteBuf) -> Unit {
  emit_i32_const_raw(buf, 2)
  emit_i32_shl(buf)
  emit_i32_const_raw(buf, tag_bool)
  emit_i32_or(buf)
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
fn emit_call(buf : ByteBuf, idx : Int) -> Unit {
  buf.push((16).to_byte())
  write_u32_leb(buf, idx)
}

///|
fn emit_drop(buf : ByteBuf) -> Unit {
  buf.push((26).to_byte())
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
fn emit_i32_eq(buf : ByteBuf) -> Unit {
  buf.push((70).to_byte())
}

///|
fn emit_i32_lt_s(buf : ByteBuf) -> Unit {
  buf.push((72).to_byte())
}

///|
fn emit_i32_shl(buf : ByteBuf) -> Unit {
  buf.push((116).to_byte())
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
fn emit_i32_store(buf : ByteBuf, offset : Int) -> Unit {
  buf.push((54).to_byte())
  write_u32_leb(buf, 2)
  write_u32_leb(buf, offset)
}

///|
fn is_qualified_name(name : String) -> Bool {
  for c in name {
    if c == '.' || c == '#' {
      return true
    }
  }
  false
}

///|
fn clone_kind_map(src : Map[String, ValueKind]) -> Map[String, ValueKind] {
  let out : Map[String, ValueKind] = {}
  for k, v in src {
    out[k] = v
  }
  out
}

///|
fn infer_expr_kind(
  ctx : CodegenCtx,
  expr : @core.Expr,
) -> ValueKind raise WasmGenError {
  if not(ctx.use_js_strings) {
    return ValueKind::I32
  }
  infer_expr_kind_with(ctx, expr, ctx.local_kinds)
}

///|
fn infer_expr_kind_with(
  ctx : CodegenCtx,
  expr : @core.Expr,
  locals : Map[String, ValueKind],
) -> ValueKind raise WasmGenError {
  if not(ctx.use_js_strings) {
    return ValueKind::I32
  }
  match expr {
    @core.Expr::Int(value~, span~) => {
      let _ = value
      let _ = span
      ValueKind::I32
    }
    @core.Expr::Bool(value~, span~) => {
      let _ = value
      let _ = span
      ValueKind::I32
    }
    @core.Expr::String(value~, span~) => {
      let _ = value
      let _ = span
      ValueKind::ExternRef
    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      match locals.get(name) {
        Some(kind) => kind
        None => ValueKind::I32
      }
    }
    @core.Expr::Call(name~, args~, span~) => {
      let _ = args
      let _ = span
      match name {
        "string_length" => ValueKind::I32
        "string_char_code_at" => ValueKind::I32
        "string_substring" => ValueKind::ExternRef
        "string_concat" => ValueKind::ExternRef
        "string_equals" => ValueKind::I32
        _ => ValueKind::I32
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      let _ = cond
      let then_kind = infer_block_kind(ctx, then_body, locals)
      let else_kind = infer_block_kind(ctx, else_body, locals)
      if then_kind != else_kind {
        raise WasmGenError::Unsupported("js-string if kind mismatch")
      }
      then_kind
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      infer_block_kind(ctx, body, locals)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      let try_kind = infer_block_kind(ctx, try_body, locals)
      let catch_kind = infer_block_kind(ctx, catch_body, locals)
      if try_kind != catch_kind {
        raise WasmGenError::Unsupported("js-string try kind mismatch")
      }
      try_kind
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = scrutinee
      let _ = arms
      let _ = span
      ValueKind::I32
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = items
      let _ = span
      ValueKind::I32
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = fields
      let _ = span
      ValueKind::I32
    }
    @core.Expr::Array(items~, span~) => {
      let _ = items
      let _ = span
      ValueKind::I32
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = fields
      let _ = span
      ValueKind::I32
    }
    @core.Expr::Do(body~, span~) => {
      let _ = span
      infer_block_kind(ctx, body, locals)
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~) => {
      let _ = params
      let _ = ret
      let _ = effects
      let _ = body
      let _ = span
      raise WasmGenError::Unsupported("fn")
    }
  }
}

///|
fn infer_block_kind(
  ctx : CodegenCtx,
  body : @core.Module,
  locals : Map[String, ValueKind],
) -> ValueKind raise WasmGenError {
  let kinds = clone_kind_map(locals)
  let mut last = ValueKind::I32
  for stmt in body.stmts {
    last = infer_stmt_kind(ctx, stmt, kinds)
  }
  last
}

///|
fn infer_stmt_kind(
  ctx : CodegenCtx,
  stmt : @core.Stmt,
  locals : Map[String, ValueKind],
) -> ValueKind raise WasmGenError {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let _ = span
      let _ = rec
      let kind = infer_expr_kind_with(ctx, expr, locals)
      locals[name] = kind
      kind
    }
    @core.Stmt::Expr(expr~, span~) => {
      let _ = span
      infer_expr_kind_with(ctx, expr, locals)
    }
    @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
      let _ = name
      let _ = params
      let _ = ctors
      let _ = span
      ValueKind::I32
    }
    @core.Stmt::TypeAlias(name~, params~, target~, span~) => {
      let _ = name
      let _ = params
      let _ = target
      let _ = span
      ValueKind::I32
    }
    @core.Stmt::Test(name~, body~, span~) => {
      let _ = name
      let _ = body
      let _ = span
      ValueKind::I32
    }
    _ => ValueKind::I32
  }
}

///|
fn compile_expr_i32(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  if ctx.use_js_strings {
    let kind = infer_expr_kind(ctx, expr)
    if kind != ValueKind::I32 {
      raise WasmGenError::Unsupported("js-string i32 expr")
    }
  }
  compile_expr(ctx, buf, expr)
}

///|
fn compile_expr_ref(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  if ctx.use_js_strings {
    let kind = infer_expr_kind(ctx, expr)
    if kind != ValueKind::ExternRef {
      raise WasmGenError::Unsupported("js-string ref expr")
    }
  }
  compile_expr(ctx, buf, expr)
}

///|
fn scan_needs_expr(ctx : CodegenCtx, expr : @core.Expr) -> Unit {
  match expr {
    @core.Expr::Call(name~, args~, span~) => {
      let _ = span
      if name == "sh" {
        ctx.need_sh = true
      } else if name == "path" {
        ctx.need_path = true
      } else if name == "string_length" {
        ctx.need_js_length = true
      } else if name == "string_char_code_at" {
        ctx.need_js_char_code_at = true
      } else if name == "string_substring" {
        ctx.need_js_substring = true
      } else if name == "string_concat" {
        ctx.need_js_concat = true
      } else if name == "string_equals" {
        ctx.need_js_equals = true
      }
      for arg in args {
        scan_needs_expr(ctx, arg.expr)
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      ctx.need_heap = true
      for item in items {
        scan_needs_expr(ctx, item)
      }
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      ctx.need_heap = true
      for field in fields {
        scan_needs_expr(ctx, field.expr)
      }
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      ctx.need_heap = true
      for item in items {
        scan_needs_expr(ctx, item)
      }
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      ctx.need_heap = true
      for field in fields {
        scan_needs_expr(ctx, field.expr)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      scan_needs_expr(ctx, cond)
      scan_needs_block(ctx, then_body)
      scan_needs_block(ctx, else_body)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      scan_needs_block(ctx, try_body)
      scan_needs_block(ctx, catch_body)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      scan_needs_expr(ctx, scrutinee)
      for arm in arms {
        scan_needs_expr(ctx, arm.expr)
        match arm.cond {
          Some(c) => scan_needs_expr(ctx, c)
          None => ()
        }
      }
    }
    @core.Expr::Do(body~, span~) => {
      let _ = span
      scan_needs_block(ctx, body)
    }
    @core.Expr::Fn(params~, ret~, effects=_, body~, span~) => {
      let _ = span
      let _ = params
      let _ = ret
      scan_needs_block(ctx, body)
    }
    _ => ()
  }
}

///|
fn scan_needs_block(ctx : CodegenCtx, body : @core.Module) -> Unit {
  for stmt in body.stmts {
    scan_needs_stmt(ctx, stmt)
  }
}

///|
fn scan_needs_stmt(ctx : CodegenCtx, stmt : @core.Stmt) -> Unit {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let _ = span
      let _ = rec
      let _ = name
      scan_needs_expr(ctx, expr)
    }
    @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
      let _ = name
      let _ = params
      let _ = ctors
      let _ = span

    }
    @core.Stmt::TypeAlias(name~, params~, target~, span~) => {
      let _ = name
      let _ = params
      let _ = target
      let _ = span

    }
    @core.Stmt::Expr(expr~, span~) => {
      let _ = span
      scan_needs_expr(ctx, expr)
    }
    @core.Stmt::Test(name~, body~, span~) => {
      let _ = name
      let _ = span
      for s in body.stmts {
        scan_needs_stmt(ctx, s)
      }
    }
    _ => ()
  }
}

///|
fn scan_needs(ctx : CodegenCtx, ast : @core.Module) -> Unit {
  for stmt in ast.stmts {
    scan_needs_stmt(ctx, stmt)
  }
}

///|
fn js_import_count(ctx : CodegenCtx) -> Int {
  let mut idx = 0
  if ctx.need_js_length {
    idx += 1
  }
  if ctx.need_js_char_code_at {
    idx += 1
  }
  if ctx.need_js_substring {
    idx += 1
  }
  if ctx.need_js_concat {
    idx += 1
  }
  if ctx.need_js_equals {
    idx += 1
  }
  idx
}

///|
fn import_index_path(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_path) {
    raise WasmGenError::Unsupported("path import missing")
  }
  js_import_count(ctx)
}

///|
fn import_index_sh(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_sh) {
    raise WasmGenError::Unsupported("sh import missing")
  }
  let mut idx = js_import_count(ctx)
  if ctx.need_path {
    idx += 1
  }
  idx
}

///|
fn import_index_js_length(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_js_length) {
    raise WasmGenError::Unsupported("js-string length import missing")
  }
  0
}

///|
fn import_index_js_char_code_at(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_js_char_code_at) {
    raise WasmGenError::Unsupported("js-string charCodeAt import missing")
  }
  let mut idx = 0
  if ctx.need_js_length {
    idx += 1
  }
  idx
}

///|
fn import_index_js_substring(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_js_substring) {
    raise WasmGenError::Unsupported("js-string substring import missing")
  }
  let mut idx = 0
  if ctx.need_js_length {
    idx += 1
  }
  if ctx.need_js_char_code_at {
    idx += 1
  }
  idx
}

///|
fn import_index_js_concat(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_js_concat) {
    raise WasmGenError::Unsupported("js-string concat import missing")
  }
  let mut idx = 0
  if ctx.need_js_length {
    idx += 1
  }
  if ctx.need_js_char_code_at {
    idx += 1
  }
  if ctx.need_js_substring {
    idx += 1
  }
  idx
}

///|
fn import_index_js_equals(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_js_equals) {
    raise WasmGenError::Unsupported("js-string equals import missing")
  }
  let mut idx = 0
  if ctx.need_js_length {
    idx += 1
  }
  if ctx.need_js_char_code_at {
    idx += 1
  }
  if ctx.need_js_substring {
    idx += 1
  }
  if ctx.need_js_concat {
    idx += 1
  }
  idx
}

///|
fn compile_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  match expr {
    @core.Expr::Int(value=n, span~) => {
      let _ = span
      emit_i32_const_tagged(buf, n)
    }
    @core.Expr::Bool(value=b, span~) => {
      let _ = span
      emit_i32_const_raw(buf, tag_bool_value(b))
    }
    @core.Expr::String(value=s, span~) => {
      let _ = span
      if ctx.use_js_strings {
        let idx = ctx.js_strings.intern(s)
        emit_global_get(buf, idx)
      } else {
        let offset = ctx.strings.intern(s)
        emit_i32_const_raw(buf, tag_ptr(offset, tag_obj))
      }
    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      if is_qualified_name(name) {
        raise WasmGenError::Unsupported("qualified name: " + name)
      }
      match ctx.locals.get(name) {
        Some(idx) => emit_local_get(buf, idx)
        None => raise WasmGenError::UnknownName(name)
      }
    }
    @core.Expr::Call(name~, args~, span~) => {
      let _ = span
      if name == "sh" {
        let pos_args = extract_positional_exprs(args, "sh")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("sh arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_call(buf, import_index_sh(ctx))
        emit_drop(buf)
        emit_i32_const_tagged(buf, 0)
      } else if name == "path" {
        let pos_args = extract_positional_exprs(args, "path")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("path arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_call(buf, import_index_path(ctx))
      } else if name == "add" {
        let pos_args = extract_positional_exprs(args, "add")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("add arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_add(buf)
      } else if name == "sub" {
        let pos_args = extract_positional_exprs(args, "sub")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("sub arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_sub(buf)
      } else if name == "eq" {
        let pos_args = extract_positional_exprs(args, "eq")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("eq arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_eq(buf)
        emit_bool_from_i32(buf)
      } else if name == "lt" {
        let pos_args = extract_positional_exprs(args, "lt")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("lt arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_lt_s(buf)
        emit_bool_from_i32(buf)
      } else if name == "not" {
        let pos_args = extract_positional_exprs(args, "not")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("not arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i32_const_raw(buf, 4)
        emit_i32_xor(buf)
      } else if name == "and" {
        let pos_args = extract_positional_exprs(args, "and")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("and arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_and(buf)
      } else if name == "or" {
        let pos_args = extract_positional_exprs(args, "or")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("or arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_or(buf)
      } else if name == "string_length" {
        if not(ctx.use_js_strings) {
          raise WasmGenError::Unsupported(
            "string_length requires --wasm-js-string",
          )
        }
        let pos_args = extract_positional_exprs(args, "string_length")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("string_length arity")
        }
        ctx.need_js_length = true
        compile_expr_ref(ctx, buf, pos_args[0])
        emit_call(buf, import_index_js_length(ctx))
        emit_i32_const_raw(buf, 2)
        emit_i32_shl(buf)
      } else if name == "string_char_code_at" {
        if not(ctx.use_js_strings) {
          raise WasmGenError::Unsupported(
            "string_char_code_at requires --wasm-js-string",
          )
        }
        let pos_args = extract_positional_exprs(args, "string_char_code_at")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("string_char_code_at arity")
        }
        ctx.need_js_char_code_at = true
        compile_expr_ref(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_const_raw(buf, 2)
        emit_i32_shr_u(buf)
        emit_call(buf, import_index_js_char_code_at(ctx))
        emit_i32_const_raw(buf, 2)
        emit_i32_shl(buf)
      } else if name == "string_substring" {
        if not(ctx.use_js_strings) {
          raise WasmGenError::Unsupported(
            "string_substring requires --wasm-js-string",
          )
        }
        let pos_args = extract_positional_exprs(args, "string_substring")
        if pos_args.length() != 3 {
          raise WasmGenError::Unsupported("string_substring arity")
        }
        ctx.need_js_substring = true
        compile_expr_ref(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_const_raw(buf, 2)
        emit_i32_shr_u(buf)
        compile_expr_i32(ctx, buf, pos_args[2])
        emit_i32_const_raw(buf, 2)
        emit_i32_shr_u(buf)
        emit_call(buf, import_index_js_substring(ctx))
      } else if name == "string_concat" {
        if not(ctx.use_js_strings) {
          raise WasmGenError::Unsupported(
            "string_concat requires --wasm-js-string",
          )
        }
        let pos_args = extract_positional_exprs(args, "string_concat")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("string_concat arity")
        }
        ctx.need_js_concat = true
        compile_expr_ref(ctx, buf, pos_args[0])
        compile_expr_ref(ctx, buf, pos_args[1])
        emit_call(buf, import_index_js_concat(ctx))
      } else if name == "string_equals" {
        if not(ctx.use_js_strings) {
          raise WasmGenError::Unsupported(
            "string_equals requires --wasm-js-string",
          )
        }
        let pos_args = extract_positional_exprs(args, "string_equals")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("string_equals arity")
        }
        ctx.need_js_equals = true
        compile_expr_ref(ctx, buf, pos_args[0])
        compile_expr_ref(ctx, buf, pos_args[1])
        emit_call(buf, import_index_js_equals(ctx))
        emit_bool_from_i32(buf)
      } else {
        if is_qualified_name(name) {
          raise WasmGenError::Unsupported("qualified call: " + name)
        }
        raise WasmGenError::Unsupported("call: " + name)
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      compile_tuple_expr(ctx, buf, items)
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      compile_record_expr(ctx, buf, fields)
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      compile_array_expr(ctx, buf, items)
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      compile_map_expr(ctx, buf, fields)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      let if_kind = if ctx.use_js_strings {
        infer_expr_kind(ctx, expr)
      } else {
        ValueKind::I32
      }
      compile_expr_i32(ctx, buf, cond)
      emit_i32_const_raw(buf, 2)
      emit_i32_shr_u(buf)
      buf.push((4).to_byte())
      buf.push(valtype_byte(if_kind))
      compile_block_expr(ctx, buf, then_body)
      buf.push((5).to_byte())
      compile_block_expr(ctx, buf, else_body)
      buf.push((11).to_byte())
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      compile_block_expr(ctx, buf, body)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      let saved = clone_locals(ctx.locals)
      let saved_kinds = clone_kind_map(ctx.local_kinds)
      let scrut_idx = ctx.local_count
      ctx.local_count += 1
      ctx.local_types.push(ValueKind::I32)
      compile_expr_i32(ctx, buf, scrutinee)
      emit_local_set(buf, scrut_idx)
      compile_match_chain(ctx, buf, scrut_idx, arms, 0)
      restore_locals(ctx, saved)
      restore_local_kinds(ctx, saved_kinds)
    }
    @core.Expr::Do(body~, span~) => {
      let _ = span
      compile_block_expr(ctx, buf, body)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = try_body
      let _ = catch_body
      let _ = span
      raise WasmGenError::Unsupported("try")
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~) => {
      let _ = params
      let _ = ret
      let _ = effects
      let _ = body
      let _ = span
      raise WasmGenError::Unsupported("fn")
    }
  }
}

///|
fn extract_positional_exprs(
  args : Array[@core.CallArg],
  name : String,
) -> Array[@core.Expr] raise WasmGenError {
  let out : Array[@core.Expr] = []
  for arg in args {
    match arg.label {
      Some(_) => raise WasmGenError::Unsupported("labeled arg: " + name)
      None => out.push(arg.expr)
    }
  }
  out
}

///|
fn compile_stmt(
  ctx : CodegenCtx,
  buf : ByteBuf,
  stmt : @core.Stmt,
  is_last : Bool,
) -> Unit raise WasmGenError {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let _ = span
      let _ = rec
      let kind = infer_expr_kind(ctx, expr)
      let idx = ctx.local_count
      ctx.local_count += 1
      ctx.local_types.push(kind)
      ctx.locals[name] = idx
      ctx.local_kinds[name] = kind
      compile_expr(ctx, buf, expr)
      if is_last {
        emit_local_tee(buf, idx)
      } else {
        emit_local_set(buf, idx)
      }
    }
    @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
      let _ = name
      let _ = params
      let _ = ctors
      let _ = span
      if is_last {
        emit_i32_const_tagged(buf, 0)
      }
    }
    @core.Stmt::TypeAlias(name~, params~, target~, span~) => {
      let _ = name
      let _ = params
      let _ = target
      let _ = span
      if is_last {
        emit_i32_const_tagged(buf, 0)
      }
    }
    @core.Stmt::Expr(expr~, span~) => {
      let _ = span
      compile_expr(ctx, buf, expr)
      if not(is_last) {
        emit_drop(buf)
      }
    }
    @core.Stmt::Flake(raw~, span~) => {
      let _ = raw
      let _ = span
      if is_last {
        emit_i32_const_tagged(buf, 0)
      }
    }
    @core.Stmt::Test(name~, body~, span~) => {
      let _ = name
      let _ = body
      let _ = span
      if is_last {
        emit_i32_const_tagged(buf, 0)
      }
    }
    @core.Stmt::Alias(name~, target~, span~) => {
      let _ = name
      let _ = target
      let _ = span
      raise WasmGenError::Unsupported("alias")
    }
    @core.Stmt::Import(path~, span~) => {
      let _ = path
      let _ = span
      raise WasmGenError::Unsupported("import")
    }
  }
}

///|
fn compile_block_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  body : @core.Module,
) -> Unit raise WasmGenError {
  let saved = clone_locals(ctx.locals)
  let saved_kinds = clone_kind_map(ctx.local_kinds)
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
  restore_local_kinds(ctx, saved_kinds)
}

///|
fn require_heap(ctx : CodegenCtx) -> Unit raise WasmGenError {
  if ctx.heap_local < 0 {
    raise WasmGenError::Unsupported("heap not initialized")
  }
}

///|
fn compile_tuple_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  items : Array[@core.Expr],
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
    compile_expr_i32(ctx, buf, items[i])
    emit_i32_store(buf, 8 + i * 4)
  }
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_or(buf)
}

///|
fn compile_record_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  fields : Array[@core.RecordFieldExpr],
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
    compile_expr_i32(ctx, buf, field.expr)
    emit_i32_store(buf, 8 + i * 8 + 4)
  }
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_or(buf)
}

///|
fn compile_array_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  items : Array[@core.Expr],
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
  emit_i32_const_raw(buf, obj_array)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, len)
  emit_i32_store(buf, 4)
  for i in 0..<len {
    emit_local_get(buf, obj_local)
    compile_expr_i32(ctx, buf, items[i])
    emit_i32_store(buf, 8 + i * 4)
  }
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_or(buf)
}

///|
fn compile_map_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  fields : Array[@core.MapFieldExpr],
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let len = fields.length()
  let size = align4(8 + len * 8)
  let obj_local = alloc_temp_local(ctx)
  emit_local_get(buf, ctx.heap_local)
  emit_local_set(buf, obj_local)
  emit_local_get(buf, ctx.heap_local)
  emit_i32_const_raw(buf, size)
  emit_i32_add(buf)
  emit_local_set(buf, ctx.heap_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_map)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, len)
  emit_i32_store(buf, 4)
  for i in 0..<len {
    let field = fields[i]
    let key_ptr = ctx.strings.intern(field.key)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, key_ptr)
    emit_i32_store(buf, 8 + i * 8)
    emit_local_get(buf, obj_local)
    compile_expr_i32(ctx, buf, field.expr)
    emit_i32_store(buf, 8 + i * 8 + 4)
  }
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_or(buf)
}

///|
fn sort_record_fields_expr(
  fields : Array[@core.RecordFieldExpr],
) -> Array[@core.RecordFieldExpr] {
  let out : Array[@core.RecordFieldExpr] = []
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

///|
fn sort_record_fields_pat(
  fields : Array[@core.RecordFieldPat],
) -> Array[@core.RecordFieldPat] {
  let out : Array[@core.RecordFieldPat] = []
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

///|
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

///|
fn compile_body(
  ctx : CodegenCtx,
  ast : @core.Module,
) -> Array[Byte] raise WasmGenError {
  let instr = ByteBuf::new()
  if ctx.use_js_strings {
    let result_kind = infer_block_kind(ctx, ast, ctx.local_kinds)
    if result_kind != ValueKind::I32 {
      raise WasmGenError::Unsupported("js-string return kind")
    }
  }
  if ctx.need_heap {
    ctx.heap_local = ctx.local_count
    ctx.local_count += 1
    ctx.local_types.push(ValueKind::I32)
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

///|
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
  let ref_type = valtype_byte(ValueKind::ExternRef)
  let mut type_count = 0
  let mut js_length_type = -1
  let mut js_char_code_at_type = -1
  let mut js_substring_type = -1
  let mut js_concat_type = -1
  let mut js_equals_type = -1
  let mut import_type = -1
  if ctx.need_js_length {
    js_length_type = type_count
    type_count += 1
  }
  if ctx.need_js_char_code_at {
    js_char_code_at_type = type_count
    type_count += 1
  }
  if ctx.need_js_substring {
    js_substring_type = type_count
    type_count += 1
  }
  if ctx.need_js_concat {
    js_concat_type = type_count
    type_count += 1
  }
  if ctx.need_js_equals {
    js_equals_type = type_count
    type_count += 1
  }
  if ctx.need_sh || ctx.need_path {
    import_type = type_count
    type_count += 1
  }
  let run_type = type_count
  type_count += 1
  write_u32_leb(type_sec, type_count)
  if ctx.need_js_length {
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 1)
    type_sec.push(ref_type)
    write_u32_leb(type_sec, 1)
    type_sec.push((127).to_byte())
  }
  if ctx.need_js_char_code_at {
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 2)
    type_sec.push(ref_type)
    type_sec.push((127).to_byte())
    write_u32_leb(type_sec, 1)
    type_sec.push((127).to_byte())
  }
  if ctx.need_js_substring {
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 3)
    type_sec.push(ref_type)
    type_sec.push((127).to_byte())
    type_sec.push((127).to_byte())
    write_u32_leb(type_sec, 1)
    type_sec.push(ref_type)
  }
  if ctx.need_js_concat {
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 2)
    type_sec.push(ref_type)
    type_sec.push(ref_type)
    write_u32_leb(type_sec, 1)
    type_sec.push(ref_type)
  }
  if ctx.need_js_equals {
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 2)
    type_sec.push(ref_type)
    type_sec.push(ref_type)
    write_u32_leb(type_sec, 1)
    type_sec.push((127).to_byte())
  }
  if ctx.need_sh || ctx.need_path {
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
  let mut func_import_count = 0
  if ctx.need_js_length {
    func_import_count += 1
  }
  if ctx.need_js_char_code_at {
    func_import_count += 1
  }
  if ctx.need_js_substring {
    func_import_count += 1
  }
  if ctx.need_js_concat {
    func_import_count += 1
  }
  if ctx.need_js_equals {
    func_import_count += 1
  }
  if ctx.need_path {
    func_import_count += 1
  }
  if ctx.need_sh {
    func_import_count += 1
  }
  let global_import_count = if ctx.use_js_strings {
    ctx.js_strings.names.length()
  } else {
    0
  }
  let import_count = func_import_count + global_import_count
  if import_count > 0 {
    let import_sec = ByteBuf::new()
    write_u32_leb(import_sec, import_count)
    if ctx.need_js_length {
      write_name(import_sec, "wasm:js-string")
      write_name(import_sec, "length")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, js_length_type)
    }
    if ctx.need_js_char_code_at {
      write_name(import_sec, "wasm:js-string")
      write_name(import_sec, "charCodeAt")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, js_char_code_at_type)
    }
    if ctx.need_js_substring {
      write_name(import_sec, "wasm:js-string")
      write_name(import_sec, "substring")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, js_substring_type)
    }
    if ctx.need_js_concat {
      write_name(import_sec, "wasm:js-string")
      write_name(import_sec, "concat")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, js_concat_type)
    }
    if ctx.need_js_equals {
      write_name(import_sec, "wasm:js-string")
      write_name(import_sec, "equals")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, js_equals_type)
    }
    if ctx.need_path {
      write_name(import_sec, "xsh")
      write_name(import_sec, "path")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, import_type)
    }
    if ctx.need_sh {
      write_name(import_sec, "xsh")
      write_name(import_sec, "sh")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, import_type)
    }
    if ctx.use_js_strings {
      for name in ctx.js_strings.names {
        write_name(import_sec, "string_constants")
        write_name(import_sec, name)
        import_sec.push((3).to_byte())
        import_sec.push(ref_type)
        import_sec.push((0).to_byte())
      }
    }
    write_section(buf, 2, import_sec.data)
  }

  // function section
  let func_sec = ByteBuf::new()
  write_u32_leb(func_sec, 1)
  write_u32_leb(func_sec, run_type)
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
  write_u32_leb(export_sec, func_import_count)
  write_name(export_sec, "memory")
  export_sec.push((2).to_byte())
  write_u32_leb(export_sec, 0)
  write_section(buf, 7, export_sec.data)

  // code section
  let code_sec = ByteBuf::new()
  write_u32_leb(code_sec, 1)
  let func_body = ByteBuf::new()
  if ctx.local_types.length() == 0 {
    write_u32_leb(func_body, 0)
  } else {
    let group_kinds : Array[ValueKind] = []
    let group_counts : Array[Int] = []
    for kind in ctx.local_types {
      if group_kinds.length() == 0 ||
        group_kinds[group_kinds.length() - 1] != kind {
        group_kinds.push(kind)
        group_counts.push(1)
      } else {
        let last = group_counts.length() - 1
        group_counts[last] = group_counts[last] + 1
      }
    }
    write_u32_leb(func_body, group_kinds.length())
    for i in 0..<group_kinds.length() {
      write_u32_leb(func_body, group_counts[i])
      func_body.push(valtype_byte(group_kinds[i]))
    }
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

///|
fn write_section(buf : ByteBuf, id : Int, content : Array[Byte]) -> Unit {
  buf.push(id.to_byte())
  write_u32_leb(buf, content.length())
  buf.extend(content)
}

///|
fn clone_locals(src : Map[String, Int]) -> Map[String, Int] {
  let out : Map[String, Int] = {}
  for k, v in src {
    out[k] = v
  }
  out
}

///|
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

///|
fn restore_local_kinds(
  ctx : CodegenCtx,
  saved : Map[String, ValueKind],
) -> Unit {
  let to_remove : Array[String] = []
  for name, _ in ctx.local_kinds {
    if not(saved.contains(name)) {
      to_remove.push(name)
    }
  }
  for name in to_remove {
    ctx.local_kinds.remove(name)
  }
  for name, kind in saved {
    ctx.local_kinds[name] = kind
  }
}

///|
priv enum PatCont {
  Arm
  Tuple(Int, Array[@core.Pat], Int, PatCont)
  Record(Int, Array[@core.RecordFieldPat], Int, PatCont)
}

///|
fn compile_pat_cont(
  ctx : CodegenCtx,
  buf : ByteBuf,
  cont : PatCont,
  match_scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
) -> Unit raise WasmGenError {
  match cont {
    PatCont::Arm =>
      compile_guarded_arm_with_bindings(
        ctx, buf, match_scrut_idx, arms, start, arm, bindings,
      )
    PatCont::Tuple(tuple_idx, items, index, next) =>
      compile_tuple_items_cont(
        ctx, buf, tuple_idx, items, index, next, match_scrut_idx, arms, start, arm,
        bindings,
      )
    PatCont::Record(record_idx, fields, index, next) =>
      compile_record_fields_cont(
        ctx, buf, record_idx, fields, index, next, match_scrut_idx, arms, start,
        arm, bindings,
      )
  }
}

///|
fn compile_pat_match(
  ctx : CodegenCtx,
  buf : ByteBuf,
  value_idx : Int,
  pat : @core.Pat,
  match_scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
  cont : PatCont,
) -> Unit raise WasmGenError {
  match pat {
    @core.Pat::Wildcard(span~) => {
      let _ = span
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
    }
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      let idx = bind_local(ctx, name)
      emit_local_get(buf, value_idx)
      emit_local_set(buf, idx)
      bindings[name] = idx
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
    }
    @core.Pat::Int(value~, span~) => {
      let _ = value
      let _ = span
      emit_local_get(buf, value_idx)
      emit_pat_literal(ctx, buf, pat)
      emit_i32_eq(buf)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte())
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte())
    }
    @core.Pat::Bool(value~, span~) => {
      let _ = value
      let _ = span
      emit_local_get(buf, value_idx)
      emit_pat_literal(ctx, buf, pat)
      emit_i32_eq(buf)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte())
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte())
    }
    @core.Pat::String(value~, span~) => {
      let _ = value
      let _ = span
      emit_local_get(buf, value_idx)
      emit_pat_literal(ctx, buf, pat)
      emit_i32_eq(buf)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte())
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte())
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let base_span = span
      let field_pat = if args.length() == 0 {
        @core.Pat::Wildcard(span=base_span)
      } else if args.length() == 1 {
        args[0]
      } else {
        @core.Pat::Tuple(items=args, span=base_span)
      }
      let fields = [
        @core.RecordFieldPat::{ name, pat: field_pat, span: base_span },
      ]
      let record_pat = @core.Pat::Record(fields~, span=base_span)
      compile_pat_match(
        ctx, buf, value_idx, record_pat, match_scrut_idx, arms, start, arm, bindings,
        cont,
      )
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
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
      compile_tuple_items_cont(
        ctx, buf, value_idx, items, 0, cont, match_scrut_idx, arms, start, arm, bindings,
      )
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
    @core.Pat::Record(fields~, span~) => {
      let _ = span
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
      compile_record_fields_cont(
        ctx, buf, value_idx, ordered, 0, cont, match_scrut_idx, arms, start, arm,
        bindings,
      )
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

///|
fn compile_tuple_items_cont(
  ctx : CodegenCtx,
  buf : ByteBuf,
  tuple_idx : Int,
  items : Array[@core.Pat],
  index : Int,
  next : PatCont,
  match_scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
) -> Unit raise WasmGenError {
  if index >= items.length() {
    compile_pat_cont(
      ctx, buf, next, match_scrut_idx, arms, start, arm, bindings,
    )
    return
  }
  let tmp = alloc_temp_local(ctx)
  emit_load_tuple_elem(buf, tuple_idx, index)
  emit_local_set(buf, tmp)
  let cont = PatCont::Tuple(tuple_idx, items, index + 1, next)
  compile_pat_match(
    ctx,
    buf,
    tmp,
    items[index],
    match_scrut_idx,
    arms,
    start,
    arm,
    bindings,
    cont,
  )
}

///|
fn compile_record_fields_cont(
  ctx : CodegenCtx,
  buf : ByteBuf,
  record_idx : Int,
  fields : Array[@core.RecordFieldPat],
  index : Int,
  next : PatCont,
  match_scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
) -> Unit raise WasmGenError {
  if index >= fields.length() {
    compile_pat_cont(
      ctx, buf, next, match_scrut_idx, arms, start, arm, bindings,
    )
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
  compile_pat_match(
    ctx,
    buf,
    tmp,
    field.pat,
    match_scrut_idx,
    arms,
    start,
    arm,
    bindings,
    cont,
  )
  buf.push((5).to_byte())
  compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
  buf.push((11).to_byte())
}

///|
fn emit_pat_literal(
  ctx : CodegenCtx,
  buf : ByteBuf,
  pat : @core.Pat,
) -> Unit raise WasmGenError {
  match pat {
    @core.Pat::Wildcard(span~) => {
      let _ = span
      raise WasmGenError::Unsupported("wildcard literal")
    }
    @core.Pat::Bind(name~, span~) => {
      let _ = name
      let _ = span
      raise WasmGenError::Unsupported("bind literal")
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = args
      let _ = span
      raise WasmGenError::Unsupported("ctor literal")
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = items
      let _ = span
      raise WasmGenError::Unsupported("tuple literal")
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = fields
      let _ = span
      raise WasmGenError::Unsupported("record literal")
    }
    @core.Pat::Int(value=n, span~) => {
      let _ = span
      emit_i32_const_tagged(buf, n)
    }
    @core.Pat::Bool(value=b, span~) => {
      let _ = span
      emit_i32_const_raw(buf, tag_bool_value(b))
    }
    @core.Pat::String(value=s, span~) => {
      let _ = span
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported("js-string string pattern")
      }
      let offset = ctx.strings.intern(s)
      emit_i32_const_raw(buf, tag_ptr(offset, tag_obj))
    }
  }
}

///|
fn compile_match_chain(
  ctx : CodegenCtx,
  buf : ByteBuf,
  scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
) -> Unit raise WasmGenError {
  if start >= arms.length() {
    emit_i32_const_tagged(buf, 0)
    return
  }
  let arm = arms[start]
  let saved = clone_locals(ctx.locals)
  let saved_kinds = clone_kind_map(ctx.local_kinds)
  let bindings : Map[String, Int] = {}
  compile_pat_match(
    ctx,
    buf,
    scrut_idx,
    arm.pat,
    scrut_idx,
    arms,
    start,
    arm,
    bindings,
    PatCont::Arm,
  )
  restore_locals(ctx, saved)
  restore_local_kinds(ctx, saved_kinds)
}

///|
fn compile_guarded_arm_with_bindings(
  ctx : CodegenCtx,
  buf : ByteBuf,
  scrut_idx : Int,
  arms : Array[@core.MatchArm],
  index : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
) -> Unit raise WasmGenError {
  let saved = clone_locals(ctx.locals)
  let saved_kinds = clone_kind_map(ctx.local_kinds)
  for name, idx in bindings {
    ctx.locals[name] = idx
    ctx.local_kinds[name] = ValueKind::I32
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
      restore_local_kinds(ctx, saved_kinds)
      compile_match_chain(ctx, buf, scrut_idx, arms, index + 1)
      buf.push((11).to_byte())
      restore_locals(ctx, saved)
      restore_local_kinds(ctx, saved_kinds)
    }
    None => {
      compile_expr(ctx, buf, arm.expr)
      restore_locals(ctx, saved)
      restore_local_kinds(ctx, saved_kinds)
    }
  }
}

///|
fn bind_local(ctx : CodegenCtx, _name : String) -> Int {
  let idx = ctx.local_count
  ctx.local_count += 1
  ctx.local_types.push(ValueKind::I32)
  idx
}

///|
fn alloc_temp_local(ctx : CodegenCtx) -> Int {
  let idx = ctx.local_count
  ctx.local_count += 1
  ctx.local_types.push(ValueKind::I32)
  idx
}

///|
fn emit_tag_obj_check(buf : ByteBuf, scrut_idx : Int) -> Unit {
  emit_local_get(buf, scrut_idx)
  emit_i32_const_raw(buf, tag_mask)
  emit_i32_and(buf)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_eq(buf)
}

///|
fn emit_untag_ptr(buf : ByteBuf, scrut_idx : Int) -> Unit {
  emit_local_get(buf, scrut_idx)
  emit_local_get(buf, scrut_idx)
  emit_i32_const_raw(buf, tag_mask)
  emit_i32_and(buf)
  emit_i32_sub(buf)
}

///|
fn emit_load_obj_type(buf : ByteBuf, scrut_idx : Int) -> Unit {
  emit_untag_ptr(buf, scrut_idx)
  emit_i32_load(buf, 0)
}

///|
fn emit_load_obj_len(buf : ByteBuf, scrut_idx : Int) -> Unit {
  emit_untag_ptr(buf, scrut_idx)
  emit_i32_load(buf, 4)
}

///|
fn emit_load_tuple_elem(buf : ByteBuf, scrut_idx : Int, index : Int) -> Unit {
  emit_untag_ptr(buf, scrut_idx)
  emit_i32_load(buf, 8 + index * 4)
}

///|
fn emit_load_record_name(buf : ByteBuf, scrut_idx : Int, index : Int) -> Unit {
  emit_untag_ptr(buf, scrut_idx)
  emit_i32_load(buf, 8 + index * 8)
}

///|
fn emit_load_record_value(buf : ByteBuf, scrut_idx : Int, index : Int) -> Unit {
  emit_untag_ptr(buf, scrut_idx)
  emit_i32_load(buf, 8 + index * 8 + 4)
}

///|
/// Emit a WASM module for a typed xsh AST.
pub fn emit_module_wasm(ast : @core.Module) -> Bytes raise WasmGenError {
  let ctx = CodegenCtx::new(false)
  scan_needs(ctx, ast)
  let body = compile_body(ctx, ast)
  build_module(ctx, body)
}

///|
pub fn emit_module_wasm_js_string(
  ast : @core.Module,
) -> Bytes raise WasmGenError {
  let ctx = CodegenCtx::new(true)
  scan_needs(ctx, ast)
  let body = compile_body(ctx, ast)
  build_module(ctx, body)
}
