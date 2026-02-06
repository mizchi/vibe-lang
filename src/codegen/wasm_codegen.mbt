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
let tag_fn = 2

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
let obj_fn = 7

///|
let obj_float = 8

///|
let obj_double = 9

///|
let obj_enum = 10

///|
enum ValueKind {
  I32
  BoxedF32
  BoxedF64
  ExternRef
} derive(Show, Eq)

///|
fn valtype_byte(kind : ValueKind) -> Byte {
  match kind {
    ValueKind::I32 | ValueKind::BoxedF32 | ValueKind::BoxedF64 =>
      (127).to_byte()
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
fn tag_fn_value(idx : Int) -> Int {
  (idx << 2) | tag_fn
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
fn u32_leb_len(n : Int) -> Int {
  let mut v = if n < 0 { 0 } else { n }
  let mut len = 1
  while v >= 128 {
    v = v >> 7
    len += 1
  }
  len
}

///|
fn data_segment_entry_len(offset : Int, len : Int) -> Int {
  1 + 1 + u32_leb_len(offset) + 1 + u32_leb_len(len) + len
}

///|
fn segmented_data_content_len(strings : StringTable) -> Int {
  let mut total = u32_leb_len(strings.segments.length())
  for seg in strings.segments {
    total += data_segment_entry_len(seg.offset, seg.bytes.length())
  }
  total
}

///|
fn packed_data_content_len(strings : StringTable) -> Int {
  let data_len = strings.next_offset
  u32_leb_len(1) + data_segment_entry_len(0, data_len)
}

///|
fn pack_string_segments(strings : StringTable) -> Array[Byte] {
  let total_len = strings.next_offset
  let data : Array[Byte] = Array::make(total_len, (0).to_byte())
  for seg in strings.segments {
    let seg_len = seg.bytes.length()
    for i in 0..<seg_len {
      data[seg.offset + i] = seg.bytes[i]
    }
  }
  data
}

///|
priv struct CodegenCtx {
  mut locals : Map[String, Int]
  mut local_kinds : Map[String, ValueKind]
  mut local_types : Array[ValueKind]
  mut local_count : Int
  fn_indices : Map[String, Int]
  fn_params : Map[String, Array[ValueKind]]
  fn_returns : Map[String, ValueKind]
  fn_return_sigs : Map[String, FuncSig] // return sig if function returns a function
  fn_closure_indices : Map[String, Int]
  fn_closure_captures : Map[String, Array[String]]
  fn_closure_capture_kinds : Map[String, Array[ValueKind]]
  // enum info: ctor_name -> (tag_index, arity, arg_kinds)
  enum_ctor_tags : Map[String, Int]
  enum_ctor_arities : Map[String, Int]
  enum_ctor_arg_kinds : Map[String, Array[ValueKind]]
  mut fn_local_sigs : Map[String, FuncSig]
  mut fn_sig_type_indices : Map[String, Int]
  mut fn_sig_order : Array[FuncSig]
  mut fn_type_indices : Map[String, Int]
  mut need_sh : Bool
  mut need_path : Bool
  mut need_js_length : Bool
  mut need_js_char_code_at : Bool
  mut need_js_substring : Bool
  mut need_js_concat : Bool
  mut need_js_equals : Bool
  use_js_strings : Bool
  mut use_heap_global : Bool
  mut heap_global : Int
  mut need_heap : Bool
  mut heap_local : Int
  mut need_exceptions : Bool
  mut error_tag_type_index : Int
  error_tag_index : Int
  mut need_extern_table : Bool
  mut extern_table_index : Int
  mut extern_table_next_slot : Int
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
    fn_indices: {},
    fn_params: {},
    fn_returns: {},
    fn_return_sigs: {},
    fn_closure_indices: {},
    fn_closure_captures: {},
    fn_closure_capture_kinds: {},
    enum_ctor_tags: {},
    enum_ctor_arities: {},
    enum_ctor_arg_kinds: {},
    fn_local_sigs: {},
    fn_sig_type_indices: {},
    fn_sig_order: [],
    fn_type_indices: {},
    need_sh: false,
    need_path: false,
    need_js_length: false,
    need_js_char_code_at: false,
    need_js_substring: false,
    need_js_concat: false,
    need_js_equals: false,
    use_js_strings,
    use_heap_global: false,
    heap_global: -1,
    need_heap: false,
    heap_local: -1,
    need_exceptions: false,
    error_tag_type_index: -1,
    error_tag_index: 0,
    need_extern_table: false,
    extern_table_index: -1,
    extern_table_next_slot: 0,
    strings: StringTable::new(),
    js_strings: StringConstTable::new(),
  }
}

///|
priv struct FuncDef {
  name : String?
  params : Array[@core.FuncParam]
  ret : @core.Type?
  body : @core.Module
  span_key : String
  captures : Array[String]
}

///|
priv struct FuncSig {
  params : Array[ValueKind]
  result : ValueKind
}

///|
fn span_key(span : @core.Span) -> String {
  "\{span.start}:\{span.end}"
}

///|
fn push_capture(
  name : String,
  captures : Array[String],
  seen : Map[String, Bool],
) -> Unit {
  if not(seen.contains(name)) {
    seen[name] = true
    captures.push(name)
  }
}

///|
fn collect_pat_bindings_codegen(pat : @core.Pat, out : Array[String]) -> Unit {
  match pat {
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      out.push(name)
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = span
      for arg in args {
        collect_pat_bindings_codegen(arg, out)
      }
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        collect_pat_bindings_codegen(item, out)
      }
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_pat_bindings_codegen(field.pat, out)
      }
    }
    _ => ()
  }
}

///|
fn collect_captures_block(
  body : @core.Module,
  bound : Map[String, Bool],
  outer_bound : Map[String, Bool],
  captures : Array[String],
  seen : Map[String, Bool],
) -> Unit {
  let scope = bound.copy()
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
        if rec {
          scope[name] = true
        }
        collect_captures_expr(expr, scope, outer_bound, captures, seen)
        scope[name] = true
      }
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        collect_captures_expr(expr, scope, outer_bound, captures, seen)
      }
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = name
        let _ = span
        collect_captures_block(body, scope, outer_bound, captures, seen)
      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = span
        collect_captures_expr(expr, scope, outer_bound, captures, seen)
        let bindings : Array[String] = []
        collect_pat_bindings_codegen(pat, bindings)
        for name in bindings {
          scope[name] = true
        }
      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        let _ = span
        collect_captures_expr(expr, scope, outer_bound, captures, seen)
        scope[name] = true
      }
      @core.Stmt::Assign(name~, expr~, span~) => {
        let _ = span
        if not(scope.contains(name)) && outer_bound.contains(name) {
          push_capture(name, captures, seen)
        }
        collect_captures_expr(expr, scope, outer_bound, captures, seen)
      }
      _ => ()
    }
  }
}

///|
fn collect_captures_expr(
  expr : @core.Expr,
  bound : Map[String, Bool],
  outer_bound : Map[String, Bool],
  captures : Array[String],
  seen : Map[String, Bool],
) -> Unit {
  match expr {
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      if not(bound.contains(name)) && outer_bound.contains(name) {
        push_capture(name, captures, seen)
      }
    }
    @core.Expr::Call(name~, args~, span~) => {
      let _ = span
      if not(bound.contains(name)) && outer_bound.contains(name) {
        push_capture(name, captures, seen)
      }
      for arg in args {
        collect_captures_expr(arg.expr, bound, outer_bound, captures, seen)
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        collect_captures_expr(item, bound, outer_bound, captures, seen)
      }
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_captures_expr(field.expr, bound, outer_bound, captures, seen)
      }
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      for item in items {
        collect_captures_expr(item, bound, outer_bound, captures, seen)
      }
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_captures_expr(field.expr, bound, outer_bound, captures, seen)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      collect_captures_expr(cond, bound, outer_bound, captures, seen)
      collect_captures_block(then_body, bound, outer_bound, captures, seen)
      collect_captures_block(else_body, bound, outer_bound, captures, seen)
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      collect_captures_block(body, bound, outer_bound, captures, seen)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      collect_captures_expr(scrutinee, bound, outer_bound, captures, seen)
      for arm in arms {
        let arm_bound = bound.copy()
        let bindings : Array[String] = []
        collect_pat_bindings_codegen(arm.pat, bindings)
        for name in bindings {
          arm_bound[name] = true
        }
        match arm.cond {
          Some(c) =>
            collect_captures_expr(c, arm_bound, outer_bound, captures, seen)
          None => ()
        }
        collect_captures_expr(arm.expr, arm_bound, outer_bound, captures, seen)
      }
    }
    @core.Expr::Do(body~, span~) => {
      let _ = span
      collect_captures_block(body, bound, outer_bound, captures, seen)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      collect_captures_block(try_body, bound, outer_bound, captures, seen)
      collect_captures_block(catch_body, bound, outer_bound, captures, seen)
    }
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      collect_captures_expr(value, bound, outer_bound, captures, seen)
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      collect_captures_expr(cond, bound, outer_bound, captures, seen)
      collect_captures_block(body, bound, outer_bound, captures, seen)
    }
    @core.Expr::Fn(..) => ()
    _ => ()
  }
}

///|
fn collect_nested_funcs_block(
  body : @core.Module,
  bound : Map[String, Bool],
  funcs : Array[FuncDef],
  skip_top_level : Bool,
) -> Unit {
  let scope = bound.copy()
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
        if rec {
          scope[name] = true
        }
        match expr {
          @core.Expr::Fn(params~, ret~, effects~, body~, span~) => {
            let _ = effects
            let key = span_key(span)
            let captures : Array[String] = []
            let seen : Map[String, Bool] = {}
            let fn_bound : Map[String, Bool] = {}
            for param in params {
              fn_bound[param.name] = true
            }
            collect_captures_block(body, fn_bound, scope, captures, seen)
            if not(skip_top_level) {
              funcs.push(FuncDef::{
                name: Some(name),
                params,
                ret,
                body,
                span_key: key,
                captures,
              })
            }
            let inner_bound = fn_bound.copy()
            for cap in captures {
              inner_bound[cap] = true
            }
            collect_nested_funcs_block(body, inner_bound, funcs, false)
          }
          _ => collect_nested_funcs_expr(expr, scope, funcs)
        }
        scope[name] = true
      }
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        collect_nested_funcs_expr(expr, scope, funcs)
      }
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = name
        let _ = body
        let _ = span

      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = span
        collect_nested_funcs_expr(expr, scope, funcs)
        let bindings : Array[String] = []
        collect_pat_bindings_codegen(pat, bindings)
        for name in bindings {
          scope[name] = true
        }
      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        let _ = span
        collect_nested_funcs_expr(expr, scope, funcs)
        scope[name] = true
      }
      _ => ()
    }
  }
}

///|
fn collect_nested_funcs_expr(
  expr : @core.Expr,
  bound : Map[String, Bool],
  funcs : Array[FuncDef],
) -> Unit {
  match expr {
    @core.Expr::Fn(params~, ret~, effects~, body~, span~) => {
      let _ = effects
      let key = span_key(span)
      let captures : Array[String] = []
      let seen : Map[String, Bool] = {}
      let fn_bound : Map[String, Bool] = {}
      for param in params {
        fn_bound[param.name] = true
      }
      collect_captures_block(body, fn_bound, bound, captures, seen)
      funcs.push(FuncDef::{
        name: None,
        params,
        ret,
        body,
        span_key: key,
        captures,
      })
      let inner_bound = fn_bound.copy()
      for cap in captures {
        inner_bound[cap] = true
      }
      collect_nested_funcs_block(body, inner_bound, funcs, false)
    }
    @core.Expr::Call(name~, args~, span~) => {
      let _ = name
      let _ = span
      for arg in args {
        collect_nested_funcs_expr(arg.expr, bound, funcs)
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        collect_nested_funcs_expr(item, bound, funcs)
      }
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_nested_funcs_expr(field.expr, bound, funcs)
      }
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      for item in items {
        collect_nested_funcs_expr(item, bound, funcs)
      }
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_nested_funcs_expr(field.expr, bound, funcs)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      collect_nested_funcs_expr(cond, bound, funcs)
      collect_nested_funcs_block(then_body, bound, funcs, false)
      collect_nested_funcs_block(else_body, bound, funcs, false)
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      collect_nested_funcs_block(body, bound, funcs, false)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      collect_nested_funcs_expr(scrutinee, bound, funcs)
      for arm in arms {
        let arm_bound = bound.copy()
        let bindings : Array[String] = []
        collect_pat_bindings_codegen(arm.pat, bindings)
        for name in bindings {
          arm_bound[name] = true
        }
        match arm.cond {
          Some(c) => collect_nested_funcs_expr(c, arm_bound, funcs)
          None => ()
        }
        collect_nested_funcs_expr(arm.expr, arm_bound, funcs)
      }
    }
    @core.Expr::Do(body~, span~) => {
      let _ = span
      collect_nested_funcs_block(body, bound, funcs, false)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      collect_nested_funcs_block(try_body, bound, funcs, false)
      collect_nested_funcs_block(catch_body, bound, funcs, false)
    }
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      collect_nested_funcs_expr(value, bound, funcs)
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      collect_nested_funcs_expr(cond, bound, funcs)
      collect_nested_funcs_block(body, bound, funcs, false)
    }
    _ => ()
  }
}

///|
fn collect_func_defs(ast : @core.Module) -> Array[FuncDef] {
  let funcs : Array[FuncDef] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
        let _ = rec
        match expr {
          @core.Expr::Fn(params~, ret~, effects~, body~, span~) => {
            let _ = effects
            let key = span_key(span)
            funcs.push(FuncDef::{
              name: Some(name),
              params,
              ret,
              body,
              span_key: key,
              captures: [],
            })
          }
          _ => ()
        }
      }
      _ => ()
    }
  }
  let bound : Map[String, Bool] = {}
  collect_nested_funcs_block(ast, bound, funcs, true)
  funcs
}

///|
priv struct WasmFunc {
  params : Array[ValueKind]
  locals : Array[ValueKind]
  result : ValueKind
  body : Array[Byte]
}

///|
fn value_kind_from_type(ctx : CodegenCtx, ty : @core.Type) -> ValueKind {
  if not(ctx.use_js_strings) {
    return ValueKind::I32
  }
  match ty {
    @core.Type::String => ValueKind::ExternRef
    @core.Type::Float => ValueKind::BoxedF32
    @core.Type::Double => ValueKind::BoxedF64
    _ => ValueKind::I32
  }
}

///|
fn func_sig_key_from_parts(
  params : Array[ValueKind],
  result : ValueKind,
) -> String {
  let sb = StringBuilder::new()
  sb.write_char('(')
  for i in 0..<params.length() {
    if i > 0 {
      sb.write_char(',')
    }
    let c = if params[i] == ValueKind::ExternRef { 'r' } else { 'i' }
    sb.write_char(c)
  }
  sb.write_string(")->")
  let rc = if result == ValueKind::ExternRef { 'r' } else { 'i' }
  sb.write_char(rc)
  sb.to_string()
}

///|
fn func_sig_key(sig : FuncSig) -> String {
  func_sig_key_from_parts(sig.params, sig.result)
}

///|
fn func_sig_with_env(params : Array[ValueKind], result : ValueKind) -> FuncSig {
  let out : Array[ValueKind] = []
  for kind in params {
    out.push(kind)
  }
  out.push(ValueKind::I32)
  FuncSig::{ params: out, result }
}

///|
fn func_sig_from_type(ctx : CodegenCtx, ty : @core.Type) -> FuncSig? {
  match ty {
    @core.Type::Func(params~, ret~, effects~) => {
      let _ = effects
      let param_kinds : Array[ValueKind] = []
      for param in params {
        param_kinds.push(value_kind_from_type(ctx, param.ty))
      }
      let result = value_kind_from_type(ctx, ret)
      Some(func_sig_with_env(param_kinds, result))
    }
    _ => None
  }
}

///|
fn infer_expr_func_sig(ctx : CodegenCtx, expr : @core.Expr) -> FuncSig? {
  match expr {
    @core.Expr::Fn(params~, ret~, effects~, body~, span~) => {
      let _ = effects
      let _ = body
      let _ = span
      let param_kinds : Array[ValueKind] = []
      for param in params {
        param_kinds.push(value_kind_from_type(ctx, param.ty))
      }
      let result = match ret {
        Some(r) => value_kind_from_type(ctx, r)
        None => ValueKind::I32
      }
      Some(func_sig_with_env(param_kinds, result))
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      if body.stmts.length() > 0 {
        match body.stmts[body.stmts.length() - 1] {
          @core.Stmt::Expr(expr~, span~) => {
            let _ = span
            infer_expr_func_sig(ctx, expr)
          }
          _ => None
        }
      } else {
        None
      }
    }
    _ => None
  }
}

///|
fn infer_body_return_sig(ctx : CodegenCtx, body : @core.Module) -> FuncSig? {
  if body.stmts.length() > 0 {
    match body.stmts[body.stmts.length() - 1] {
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        infer_expr_func_sig(ctx, expr)
      }
      _ => None
    }
  } else {
    None
  }
}

///|
fn builtin_type_count(ctx : CodegenCtx) -> Int {
  let mut count = 0
  if ctx.need_js_length {
    count += 1
  }
  if ctx.need_js_char_code_at {
    count += 1
  }
  if ctx.need_js_substring {
    count += 1
  }
  if ctx.need_js_concat {
    count += 1
  }
  if ctx.need_js_equals {
    count += 1
  }
  if ctx.need_sh || ctx.need_path {
    count += 1
  }
  count
}

///|
fn ensure_sig_index(ctx : CodegenCtx, sig : FuncSig) -> Int {
  let key = func_sig_key(sig)
  match ctx.fn_sig_type_indices.get(key) {
    Some(idx) => idx
    None => {
      let idx = builtin_type_count(ctx) + ctx.fn_sig_order.length()
      ctx.fn_sig_type_indices[key] = idx
      ctx.fn_sig_order.push(sig)
      idx
    }
  }
}

///|
fn func_import_count(ctx : CodegenCtx) -> Int {
  let mut count = 0
  if ctx.need_js_length {
    count += 1
  }
  if ctx.need_js_char_code_at {
    count += 1
  }
  if ctx.need_js_substring {
    count += 1
  }
  if ctx.need_js_concat {
    count += 1
  }
  if ctx.need_js_equals {
    count += 1
  }
  if ctx.need_path {
    count += 1
  }
  if ctx.need_sh {
    count += 1
  }
  count
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
fn emit_f32_lt(buf : ByteBuf) -> Unit {
  buf.push((93).to_byte())
}

///|
fn emit_f32_neg(buf : ByteBuf) -> Unit {
  buf.push((140).to_byte())
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
fn emit_f64_lt(buf : ByteBuf) -> Unit {
  buf.push((99).to_byte())
}

///|
fn emit_f64_neg(buf : ByteBuf) -> Unit {
  buf.push((153).to_byte())
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
fn is_qualified_name(name : String) -> Bool {
  for c in name {
    if c == '.' || c == '#' {
      return true
    }
  }
  false
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
    @core.Expr::Float(value~, span~) => {
      let _ = value
      let _ = span
      ValueKind::BoxedF32
    }
    @core.Expr::Double(value~, span~) => {
      let _ = value
      let _ = span
      ValueKind::BoxedF64
    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      match locals.get(name) {
        Some(kind) => kind
        None => ValueKind::I32
      }
    }
    @core.Expr::Call(name~, args~, span~) => {
      let _ = span
      let pos_args = extract_positional_exprs(args, name)
      match name {
        "add" | "sub" | "mul" | "div" | "eq" | "lt" => ValueKind::I32
        "__index" => ValueKind::I32
        "__add" | "__sub" | "__mul" | "__div" | "__mod" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("js-string arity: " + name)
          }
          let left_kind = infer_expr_kind_with(ctx, pos_args[0], locals)
          let right_kind = infer_expr_kind_with(ctx, pos_args[1], locals)
          // When one side is I32 (generic tagged), coerce to the other side's type
          let resolved_kind = if left_kind == right_kind {
            left_kind
          } else if left_kind == ValueKind::I32 {
            right_kind
          } else if right_kind == ValueKind::I32 {
            left_kind
          } else {
            raise WasmGenError::Unsupported("numeric kind mismatch")
          }
          match resolved_kind {
            ValueKind::I32 | ValueKind::BoxedF32 | ValueKind::BoxedF64 =>
              resolved_kind
            _ => raise WasmGenError::Unsupported("js-string numeric kind")
          }
        }
        "__neg" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("js-string arity: " + name)
          }
          let kind = infer_expr_kind_with(ctx, pos_args[0], locals)
          match kind {
            ValueKind::I32 | ValueKind::BoxedF32 | ValueKind::BoxedF64 => kind
            _ => raise WasmGenError::Unsupported("js-string numeric kind")
          }
        }
        "__eq" | "__lt" => ValueKind::I32
        "string_length" => ValueKind::I32
        "string_char_code_at" => ValueKind::I32
        "string_substring" => ValueKind::ExternRef
        "string_concat" => ValueKind::ExternRef
        "string_equals" => ValueKind::I32
        "array_builder" | "array_builder_freeze" => ValueKind::I32
        "array_builder_push" => ValueKind::I32
        "map_builder" | "map_builder_freeze" => ValueKind::I32
        "map_builder_set" => ValueKind::I32
        "array_length" => ValueKind::I32
        "array_get" => ValueKind::I32
        "map_get" => ValueKind::I32
        _ if ctx.fn_local_sigs.contains(name) =>
          match ctx.fn_local_sigs.get(name) {
            Some(sig) => sig.result
            None => ValueKind::I32
          }
        _ =>
          if ctx.fn_returns.contains(name) {
            match ctx.fn_returns.get(name) {
              Some(kind) => kind
              None => ValueKind::I32
            }
          } else {
            ValueKind::I32
          }
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
      let _ = span
      if arms.length() == 0 {
        ValueKind::I32
      } else {
        // Infer type from the first arm's expression
        let arm = arms[0]
        let arm_locals = locals.copy()
        let bindings : Array[String] = []
        collect_pat_bindings_codegen(arm.pat, bindings)
        for name in bindings {
          arm_locals[name] = ValueKind::I32
        }
        infer_expr_kind_with(ctx, arm.expr, arm_locals)
      }
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
      ValueKind::I32
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = cond
      let _ = body
      let _ = span
      ValueKind::I32
    }
    @core.Expr::Raise(value~, span~) => {
      let _ = value
      let _ = span
      ValueKind::I32
    }
  }
}

///|
fn infer_block_kind(
  ctx : CodegenCtx,
  body : @core.Module,
  locals : Map[String, ValueKind],
) -> ValueKind raise WasmGenError {
  let kinds = locals.copy()
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
    @core.Stmt::LetPat(pat~, expr~, span~) => {
      let _ = span
      let kind = infer_expr_kind_with(ctx, expr, locals)
      let _ = kind
      let bindings : Array[String] = []
      collect_pat_bindings_codegen(pat, bindings)
      for name in bindings {
        locals[name] = ValueKind::I32
      }
      ValueKind::I32
    }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let _ = span
      let kind = infer_expr_kind_with(ctx, expr, locals)
      locals[name] = kind
      kind
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
    if kind == ValueKind::ExternRef {
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
fn emit_boxed_f32(
  ctx : CodegenCtx,
  buf : ByteBuf,
  emit_value : () -> Unit,
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let obj_local = alloc_temp_local(ctx)
  emit_local_get(buf, ctx.heap_local)
  emit_local_set(buf, obj_local)
  emit_local_get(buf, ctx.heap_local)
  emit_i32_const_raw(buf, align4(8))
  emit_i32_add(buf)
  emit_local_set(buf, ctx.heap_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_float)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_value()
  emit_f32_store(buf, 4)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_or(buf)
}

///|
fn emit_boxed_f64(
  ctx : CodegenCtx,
  buf : ByteBuf,
  emit_value : () -> Unit,
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let obj_local = alloc_temp_local(ctx)
  emit_local_get(buf, ctx.heap_local)
  emit_local_set(buf, obj_local)
  emit_local_get(buf, ctx.heap_local)
  emit_i32_const_raw(buf, align4(12))
  emit_i32_add(buf)
  emit_local_set(buf, ctx.heap_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_double)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_value()
  emit_f64_store(buf, 4)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_or(buf)
}

///|
fn emit_boxed_f32_raise(
  ctx : CodegenCtx,
  buf : ByteBuf,
  emit_value : () -> Unit raise WasmGenError,
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let obj_local = alloc_temp_local(ctx)
  emit_local_get(buf, ctx.heap_local)
  emit_local_set(buf, obj_local)
  emit_local_get(buf, ctx.heap_local)
  emit_i32_const_raw(buf, align4(8))
  emit_i32_add(buf)
  emit_local_set(buf, ctx.heap_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_float)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_value()
  emit_f32_store(buf, 4)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_or(buf)
}

///|
fn emit_boxed_f64_raise(
  ctx : CodegenCtx,
  buf : ByteBuf,
  emit_value : () -> Unit raise WasmGenError,
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let obj_local = alloc_temp_local(ctx)
  emit_local_get(buf, ctx.heap_local)
  emit_local_set(buf, obj_local)
  emit_local_get(buf, ctx.heap_local)
  emit_i32_const_raw(buf, align4(12))
  emit_i32_add(buf)
  emit_local_set(buf, ctx.heap_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_double)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_value()
  emit_f64_store(buf, 4)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_or(buf)
}

///|
fn emit_unbox_f32_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  let tmp = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, expr)
  emit_local_set(buf, tmp)
  emit_untag_ptr(buf, tmp)
  emit_f32_load(buf, 4)
}

///|
fn emit_unbox_f64_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  let tmp = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, expr)
  emit_local_set(buf, tmp)
  emit_untag_ptr(buf, tmp)
  emit_f64_load(buf, 4)
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
      } else if name == "array_builder" || name == "map_builder" {
        ctx.need_heap = true
      } else if name == "map_get" {
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
    @core.Expr::Block(body~, span~) => {
      let _ = span
      scan_needs_block(ctx, body)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      ctx.need_exceptions = true
      scan_needs_block(ctx, try_body)
      scan_needs_block(ctx, catch_body)
    }
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      ctx.need_exceptions = true
      scan_needs_expr(ctx, value)
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
      let key = span_key(span)
      match ctx.fn_closure_captures.get(key) {
        Some(captures) => if captures.length() > 0 { ctx.need_heap = true }
        None => ()
      }
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
      let _ = span
      for i in 0..<ctors.length() {
        let ctor = ctors[i]
        ctx.enum_ctor_tags[ctor.name] = i
        ctx.enum_ctor_arities[ctor.name] = ctor.args.length()
        let arg_kinds : Array[ValueKind] = []
        for arg in ctor.args {
          arg_kinds.push(value_kind_from_type(ctx, arg))
        }
        ctx.enum_ctor_arg_kinds[ctor.name] = arg_kinds
      }
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
      let _ = body
      let _ = span

    }
    @core.Stmt::LetPat(pat~, expr~, span~) => {
      let _ = pat
      let _ = span
      scan_needs_expr(ctx, expr)
    }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let _ = name
      let _ = span
      scan_needs_expr(ctx, expr)
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
fn scan_strings(ctx : CodegenCtx, ast : @core.Module) -> Unit {
  for stmt in ast.stmts {
    scan_strings_stmt(ctx, stmt)
  }
}

///|
fn scan_strings_stmt(ctx : CodegenCtx, stmt : @core.Stmt) -> Unit {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let _ = rec
      let _ = name
      let _ = span
      scan_strings_expr(ctx, expr)
    }
    @core.Stmt::Expr(expr~, span~) => {
      let _ = span
      scan_strings_expr(ctx, expr)
    }
    @core.Stmt::Test(name~, body~, span~) => {
      let _ = name
      let _ = span
      let _ = body

    }
    @core.Stmt::LetPat(pat~, expr~, span~) => {
      let _ = pat
      let _ = span
      scan_strings_expr(ctx, expr)
    }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let _ = name
      let _ = span
      scan_strings_expr(ctx, expr)
    }
    _ => ()
  }
}

///|
fn scan_strings_expr(ctx : CodegenCtx, expr : @core.Expr) -> Unit {
  match expr {
    @core.Expr::String(value=s, span~) => {
      let _ = span
      if ctx.use_js_strings {
        let _ = ctx.js_strings.intern(s)

      } else {
        let _ = ctx.strings.intern(s)

      }
    }
    @core.Expr::Call(name~, args~, span~) => {
      let _ = name
      let _ = span
      for arg in args {
        scan_strings_expr(ctx, arg.expr)
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        scan_strings_expr(ctx, item)
      }
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      let ordered = sort_record_fields_expr(fields)
      for field in ordered {
        let _ = ctx.strings.intern(field.name)
        scan_strings_expr(ctx, field.expr)
      }
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      for item in items {
        scan_strings_expr(ctx, item)
      }
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      for field in fields {
        let _ = ctx.strings.intern(field.key)
        scan_strings_expr(ctx, field.expr)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      scan_strings_expr(ctx, cond)
      scan_strings(ctx, then_body)
      scan_strings(ctx, else_body)
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      scan_strings(ctx, body)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      scan_strings_expr(ctx, scrutinee)
      for arm in arms {
        scan_strings_pat(ctx, arm.pat)
        scan_strings_expr(ctx, arm.expr)
        match arm.cond {
          Some(c) => scan_strings_expr(ctx, c)
          None => ()
        }
      }
    }
    @core.Expr::Do(body~, span~) => {
      let _ = span
      scan_strings(ctx, body)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      scan_strings(ctx, try_body)
      scan_strings(ctx, catch_body)
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~) => {
      let _ = params
      let _ = ret
      let _ = effects
      let _ = span
      scan_strings(ctx, body)
    }
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      scan_strings_expr(ctx, value)
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      scan_strings_expr(ctx, cond)
      scan_strings(ctx, body)
    }
    _ => ()
  }
}

///|
fn scan_strings_pat(ctx : CodegenCtx, pat : @core.Pat) -> Unit {
  match pat {
    @core.Pat::String(value=s, span~) => {
      let _ = span
      if not(ctx.use_js_strings) {
        let _ = ctx.strings.intern(s)

      }
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        scan_strings_pat(ctx, item)
      }
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        scan_strings_pat(ctx, field.pat)
      }
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = span
      for arg in args {
        scan_strings_pat(ctx, arg)
      }
    }
    _ => ()
  }
}

///|
fn collect_top_level_funcs(ast : @core.Module) -> Array[FuncDef] {
  let out : Array[FuncDef] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = rec
        let _ = span
        match expr {
          @core.Expr::Fn(params~, ret~, effects~, body~, span~) => {
            let _ = effects
            let _ = span
            out.push(FuncDef::{
              name: Some(name),
              params,
              ret,
              body,
              span_key: span_key(span),
              captures: [],
            })
          }
          _ => ()
        }
      }
      _ => ()
    }
  }
  out
}

///|
fn filter_top_level_funcs(ast : @core.Module) -> @core.Module {
  let out : Array[@core.Stmt] = []
  for stmt in ast.stmts {
    let skip = match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = rec
        let _ = name
        let _ = span
        match expr {
          @core.Expr::Fn(..) => true
          _ => false
        }
      }
      _ => false
    }
    if not(skip) {
      out.push(stmt)
    }
  }
  @core.Module::{ stmts: out }
}

///|
fn needs_heap_block(ctx : CodegenCtx, body : @core.Module) -> Bool {
  for stmt in body.stmts {
    if needs_heap_stmt(ctx, stmt) {
      return true
    }
  }
  false
}

///|
fn needs_heap_stmt(ctx : CodegenCtx, stmt : @core.Stmt) -> Bool {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let _ = rec
      let _ = name
      let _ = span
      needs_heap_expr(ctx, expr)
    }
    @core.Stmt::Expr(expr~, span~) => {
      let _ = span
      needs_heap_expr(ctx, expr)
    }
    @core.Stmt::Test(name~, body~, span~) => {
      let _ = name
      let _ = span
      needs_heap_block(ctx, body)
    }
    @core.Stmt::LetPat(pat~, expr~, span~) => {
      let _ = pat
      let _ = span
      needs_heap_expr(ctx, expr)
    }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let _ = name
      let _ = span
      needs_heap_expr(ctx, expr)
    }
    _ => false
  }
}

///|
fn needs_heap_expr(ctx : CodegenCtx, expr : @core.Expr) -> Bool {
  match expr {
    @core.Expr::Float(..) => true
    @core.Expr::Double(..) => true
    @core.Expr::Tuple(..) => true
    @core.Expr::Record(..) => true
    @core.Expr::Array(..) => true
    @core.Expr::Map(..) => true
    @core.Expr::Call(name~, args~, span~) => {
      let _ = name
      let _ = span
      if name == "__add" ||
        name == "__sub" ||
        name == "__mul" ||
        name == "__div" ||
        name == "__mod" ||
        name == "__neg" {
        return true
      }
      for arg in args {
        if needs_heap_expr(ctx, arg.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      needs_heap_expr(ctx, cond) ||
      needs_heap_block(ctx, then_body) ||
      needs_heap_block(ctx, else_body)
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      needs_heap_block(ctx, body)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      if needs_heap_expr(ctx, scrutinee) {
        return true
      }
      for arm in arms {
        if needs_heap_expr(ctx, arm.expr) {
          return true
        }
        match arm.cond {
          Some(c) => if needs_heap_expr(ctx, c) { return true }
          None => ()
        }
      }
      false
    }
    @core.Expr::Do(body~, span~) => {
      let _ = span
      needs_heap_block(ctx, body)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      needs_heap_block(ctx, try_body) || needs_heap_block(ctx, catch_body)
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~) => {
      let _ = params
      let _ = ret
      let _ = effects
      let _ = body
      let key = span_key(span)
      match ctx.fn_closure_captures.get(key) {
        Some(captures) => captures.length() > 0
        None => false
      }
    }
    _ => false
  }
}

///|
fn param_kinds(
  ctx : CodegenCtx,
  params : Array[@core.FuncParam],
) -> Array[ValueKind] {
  let out : Array[ValueKind] = []
  for param in params {
    out.push(value_kind_from_type(ctx, param.ty))
  }
  out
}

///|
fn param_kind_map(
  params : Array[@core.FuncParam],
  kinds : Array[ValueKind],
) -> Map[String, ValueKind] {
  let out : Map[String, ValueKind] = {}
  let len = if params.length() < kinds.length() {
    params.length()
  } else {
    kinds.length()
  }
  for i in 0..<len {
    out[params[i].name] = kinds[i]
  }
  out
}

///|
fn infer_func_return_kind(
  ctx : CodegenCtx,
  params : Array[@core.FuncParam],
  kinds : Array[ValueKind],
  ret : @core.Type?,
  body : @core.Module,
) -> ValueKind raise WasmGenError {
  let locals = param_kind_map(params, kinds)
  let saved_fn_locals = ctx.fn_local_sigs
  ctx.fn_local_sigs = {}
  for param in params {
    match func_sig_from_type(ctx, param.ty) {
      Some(sig) => ctx.fn_local_sigs[param.name] = sig
      None => ()
    }
  }
  let inferred = if ctx.use_js_strings {
    infer_block_kind(ctx, body, locals)
  } else {
    ValueKind::I32
  }
  ctx.fn_local_sigs = saved_fn_locals
  match ret {
    Some(r) => {
      let declared = value_kind_from_type(ctx, r)
      if ctx.use_js_strings && declared != inferred {
        raise WasmGenError::Unsupported(
          "fn return kind mismatch: declared=" +
            declared.to_string() +
            " inferred=" +
            inferred.to_string(),
        )
      }
      declared
    }
    None => inferred
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
fn resolve_numeric_kind(
  ctx : CodegenCtx,
  left : @core.Expr,
  right : @core.Expr,
) -> ValueKind raise WasmGenError {
  let left_kind = infer_expr_kind(ctx, left)
  let right_kind = infer_expr_kind(ctx, right)
  if left_kind == right_kind {
    left_kind
  } else if left_kind == ValueKind::I32 {
    right_kind
  } else if right_kind == ValueKind::I32 {
    left_kind
  } else {
    raise WasmGenError::Unsupported("numeric kind mismatch")
  }
}

///|
fn compile_binary_arith_op(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  emit_i32 : (ByteBuf) -> Unit,
  emit_f32 : (ByteBuf) -> Unit,
  emit_f64 : (ByteBuf) -> Unit,
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs(args, name)
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported(name + " arity")
  }
  let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
  match resolved_kind {
    ValueKind::I32 => {
      compile_expr_i32(ctx, buf, pos_args[0])
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i32(buf)
    }
    ValueKind::BoxedF32 =>
      emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f32_expr(ctx, buf, pos_args[0])
        emit_unbox_f32_expr(ctx, buf, pos_args[1])
        emit_f32(buf)
      })
    ValueKind::BoxedF64 =>
      emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f64_expr(ctx, buf, pos_args[0])
        emit_unbox_f64_expr(ctx, buf, pos_args[1])
        emit_f64(buf)
      })
    _ => raise WasmGenError::Unsupported("numeric kind")
  }
}

///|
fn compile_binary_cmp_op(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  emit_i32 : (ByteBuf) -> Unit,
  emit_f32 : (ByteBuf) -> Unit,
  emit_f64 : (ByteBuf) -> Unit,
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs(args, name)
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported(name + " arity")
  }
  let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
  match resolved_kind {
    ValueKind::I32 => {
      compile_expr_i32(ctx, buf, pos_args[0])
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i32(buf)
      emit_bool_from_i32(buf)
    }
    ValueKind::BoxedF32 => {
      emit_unbox_f32_expr(ctx, buf, pos_args[0])
      emit_unbox_f32_expr(ctx, buf, pos_args[1])
      emit_f32(buf)
      emit_bool_from_i32(buf)
    }
    ValueKind::BoxedF64 => {
      emit_unbox_f64_expr(ctx, buf, pos_args[0])
      emit_unbox_f64_expr(ctx, buf, pos_args[1])
      emit_f64(buf)
      emit_bool_from_i32(buf)
    }
    _ => raise WasmGenError::Unsupported("numeric kind")
  }
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
    @core.Expr::Float(value=n, span~) => {
      let _ = span
      emit_boxed_f32(ctx, buf, () => emit_f32_const(buf, n))
    }
    @core.Expr::Double(value=n, span~) => {
      let _ = span
      emit_boxed_f64(ctx, buf, () => emit_f64_const(buf, n))
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
        None =>
          match ctx.fn_indices.get(name) {
            Some(idx) => emit_i32_const_raw(buf, tag_fn_value(idx))
            None =>
              if ctx.enum_ctor_tags.contains(name) {
                // Nullary enum constructor
                let tag = match ctx.enum_ctor_tags.get(name) {
                  Some(t) => t
                  None => 0
                }
                require_heap(ctx)
                let size = align4(8)
                let obj_local = alloc_temp_local(ctx)
                emit_local_get(buf, ctx.heap_local)
                emit_local_set(buf, obj_local)
                emit_local_get(buf, ctx.heap_local)
                emit_i32_const_raw(buf, size)
                emit_i32_add(buf)
                emit_local_set(buf, ctx.heap_local)
                emit_local_get(buf, obj_local)
                emit_i32_const_raw(buf, obj_enum)
                emit_i32_store(buf, 0)
                emit_local_get(buf, obj_local)
                emit_i32_const_raw(buf, tag)
                emit_i32_store(buf, 4)
                emit_local_get(buf, obj_local)
                emit_i32_const_raw(buf, tag_obj)
                emit_i32_or(buf)
              } else {
                raise WasmGenError::UnknownName(name)
              }
          }
      }
    }
    @core.Expr::Call(name~, args~, span~) => {
      let _ = span
      if ctx.fn_local_sigs.contains(name) {
        let sig = match ctx.fn_local_sigs.get(name) {
          Some(s) => s
          None => raise WasmGenError::Unsupported("call: " + name)
        }
        let pos_args = extract_positional_exprs(args, name)
        let sig_param_len = if sig.params.length() > 0 {
          sig.params.length() - 1
        } else {
          0
        }
        if pos_args.length() != sig_param_len {
          raise WasmGenError::Unsupported("arity: " + name)
        }
        let fn_value_idx = match ctx.locals.get(name) {
          Some(idx) => idx
          None => raise WasmGenError::UnknownName(name)
        }
        let env_idx = alloc_temp_local(ctx)
        let func_idx = alloc_temp_local(ctx)
        emit_local_get(buf, fn_value_idx)
        emit_i32_const_raw(buf, tag_mask)
        emit_i32_and(buf)
        emit_i32_const_raw(buf, tag_fn)
        emit_i32_eq(buf)
        buf.push((4).to_byte())
        buf.push((64).to_byte())
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, env_idx)
        emit_local_get(buf, fn_value_idx)
        emit_i32_const_raw(buf, tag_fn)
        emit_i32_sub(buf)
        emit_i32_const_raw(buf, 2)
        emit_i32_shr_u(buf)
        emit_local_set(buf, func_idx)
        buf.push((5).to_byte())
        emit_untag_ptr(buf, fn_value_idx)
        emit_local_set(buf, env_idx)
        emit_local_get(buf, env_idx)
        emit_i32_load(buf, 4)
        emit_local_set(buf, func_idx)
        buf.push((11).to_byte())
        for i in 0..<sig_param_len {
          let kind = sig.params[i]
          if ctx.use_js_strings && kind == ValueKind::ExternRef {
            compile_expr_ref(ctx, buf, pos_args[i])
          } else {
            compile_expr_i32(ctx, buf, pos_args[i])
          }
        }
        emit_local_get(buf, env_idx)
        emit_local_get(buf, func_idx)
        let type_idx = match ctx.fn_sig_type_indices.get(func_sig_key(sig)) {
          Some(idx) => idx
          None => raise WasmGenError::Unsupported("call: " + name)
        }
        // Sync heap pointer to global before call so callee sees current heap
        if ctx.heap_local >= 0 && ctx.use_heap_global {
          emit_local_get(buf, ctx.heap_local)
          emit_global_set(buf, ctx.heap_global)
        }
        emit_call_indirect(buf, type_idx)
        // Reload heap pointer from global after call (callee may have bumped it)
        if ctx.heap_local >= 0 && ctx.use_heap_global {
          emit_global_get(buf, ctx.heap_global)
          emit_local_set(buf, ctx.heap_local)
        }
      } else if ctx.locals.contains(name) && not(ctx.fn_indices.contains(name)) {
        raise WasmGenError::Unsupported("call local: " + name)
      } else if name == "sh" {
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
      } else if name == "mul" {
        let pos_args = extract_positional_exprs(args, "mul")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("mul arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_mul(buf)
      } else if name == "div" {
        let pos_args = extract_positional_exprs(args, "div")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("div arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_div_s(buf)
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
      } else if name == "__add" {
        compile_binary_arith_op(
          ctx, buf, "__add", args, emit_i32_add, emit_f32_add, emit_f64_add,
        )
      } else if name == "__sub" {
        compile_binary_arith_op(
          ctx, buf, "__sub", args, emit_i32_sub, emit_f32_sub, emit_f64_sub,
        )
      } else if name == "__mul" {
        compile_binary_arith_op(
          ctx, buf, "__mul", args, emit_i32_mul, emit_f32_mul, emit_f64_mul,
        )
      } else if name == "__div" {
        compile_binary_arith_op(
          ctx, buf, "__div", args, emit_i32_div_s, emit_f32_div, emit_f64_div,
        )
      } else if name == "__mod" {
        let pos_args = extract_positional_exprs(args, "__mod")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("__mod arity")
        }
        let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
        match resolved_kind {
          ValueKind::I32 => {
            compile_expr_i32(ctx, buf, pos_args[0])
            compile_expr_i32(ctx, buf, pos_args[1])
            emit_i32_rem_s(buf)
          }
          _ => raise WasmGenError::Unsupported("__mod for float types")
        }
      } else if name == "__eq" {
        compile_binary_cmp_op(
          ctx, buf, "__eq", args, emit_i32_eq, emit_f32_eq, emit_f64_eq,
        )
      } else if name == "__lt" {
        compile_binary_cmp_op(
          ctx, buf, "__lt", args, emit_i32_lt_s, emit_f32_lt, emit_f64_lt,
        )
      } else if name == "__neg" {
        let pos_args = extract_positional_exprs(args, "__neg")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("__neg arity")
        }
        let kind = infer_expr_kind(ctx, pos_args[0])
        match kind {
          ValueKind::I32 => {
            emit_i32_const_raw(buf, tag_int_value(0))
            compile_expr_i32(ctx, buf, pos_args[0])
            emit_i32_sub(buf)
          }
          ValueKind::BoxedF32 =>
            emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
              emit_unbox_f32_expr(ctx, buf, pos_args[0])
              emit_f32_neg(buf)
            })
          ValueKind::BoxedF64 =>
            emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
              emit_unbox_f64_expr(ctx, buf, pos_args[0])
              emit_f64_neg(buf)
            })
          _ => raise WasmGenError::Unsupported("numeric kind")
        }
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
      } else if name == "array_builder" {
        // array_builder() -> allocate empty array obj with len=0
        // Reserve max_capacity * 4 bytes after header for future pushes
        let max_cap = 256
        require_heap(ctx)
        let size = align4(8 + max_cap * 4)
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
        emit_i32_const_raw(buf, 0)
        emit_i32_store(buf, 4)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, tag_obj)
        emit_i32_or(buf)
      } else if name == "array_builder_push" {
        // array_builder_push(builder, value) -> store value at [builder + 8 + len*4], increment len
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("array_builder_push arity")
        }
        let builder_local = alloc_temp_local(ctx)
        let ptr_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        // untag pointer
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_tee(buf, builder_local)
        emit_local_set(buf, ptr_local)
        // store value at [ptr + 8 + len*4]
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, ptr_local)
        emit_i32_load(buf, 4) // len
        emit_i32_const_raw(buf, 4)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_store(buf, 8)
        // increment len
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, ptr_local)
        emit_i32_load(buf, 4)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_i32_store(buf, 4)
        // return unit
        emit_i32_const_tagged(buf, 0)
      } else if name == "array_builder_freeze" {
        // array_builder_freeze(builder) -> return builder as-is (it is already an array obj)
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("array_builder_freeze arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
      } else if name == "map_builder" {
        // map_builder() -> allocate empty map obj with len=0
        let max_cap = 128
        require_heap(ctx)
        let size = align4(8 + max_cap * 8)
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
        emit_i32_const_raw(buf, 0)
        emit_i32_store(buf, 4)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, tag_obj)
        emit_i32_or(buf)
      } else if name == "map_builder_set" {
        // map_builder_set(builder, key, value) -> store key+value at end, increment len
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 3 {
          raise WasmGenError::Unsupported("map_builder_set arity")
        }
        let ptr_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, ptr_local)
        // key slot offset = 8 + len*8
        let offset_local = alloc_temp_local(ctx)
        emit_local_get(buf, ptr_local)
        emit_i32_load(buf, 4) // len
        emit_i32_const_raw(buf, 8)
        emit_i32_mul(buf)
        emit_local_set(buf, offset_local)
        // store key at [ptr + 8 + len*8]
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, offset_local)
        emit_i32_add(buf)
        if ctx.use_js_strings {
          // key is externref -> store in extern table
          let key_kind = infer_expr_kind(ctx, pos_args[1])
          if key_kind == ValueKind::ExternRef {
            ctx.need_extern_table = true
            let slot = ctx.extern_table_next_slot
            ctx.extern_table_next_slot += 1
            emit_i32_const_raw(buf, slot)
            compile_expr(ctx, buf, pos_args[1])
            emit_table_set(buf, ctx.extern_table_index)
            emit_i32_const_raw(buf, slot)
          } else {
            compile_expr_i32(ctx, buf, pos_args[1])
          }
        } else {
          compile_expr_i32(ctx, buf, pos_args[1])
        }
        emit_i32_store(buf, 8)
        // store value at [ptr + 8 + len*8 + 4]
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, offset_local)
        emit_i32_add(buf)
        compile_expr_i32(ctx, buf, pos_args[2])
        emit_i32_store(buf, 12)
        // increment len
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, ptr_local)
        emit_i32_load(buf, 4)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_i32_store(buf, 4)
        // return unit
        emit_i32_const_tagged(buf, 0)
      } else if name == "map_builder_freeze" {
        // map_builder_freeze(builder) -> return builder as-is (it is already a map obj)
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("map_builder_freeze arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
      } else if name == "array_length" {
        // array_length(arr) -> load len field, shift left 2 (tag as int)
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("array_length arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_i32_load(buf, 4)
        emit_i32_const_raw(buf, 2)
        emit_i32_shl(buf)
      } else if name == "array_get" || name == "__index" {
        // array_get(arr, idx) -> load arr[idx]
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("array_get arity")
        }
        let ptr_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, ptr_local)
        // offset = 8 + (idx >> 2) * 4
        emit_local_get(buf, ptr_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_const_raw(buf, 2)
        emit_i32_shr_u(buf)
        emit_i32_const_raw(buf, 4)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 8)
      } else if name == "map_get" {
        // map_get(map, key) -> linear search for key, return value
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("map_get arity")
        }
        let map_ptr = alloc_temp_local(ctx)
        let map_len = alloc_temp_local(ctx)
        let loop_i = alloc_temp_local(ctx)
        let result_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, map_ptr)
        emit_local_get(buf, map_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, map_len)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, loop_i)
        emit_i32_const_tagged(buf, 0)
        emit_local_set(buf, result_local)
        if ctx.use_js_strings {
          // key is externref: store in temp table slot for comparison
          let key_kind = infer_expr_kind(ctx, pos_args[1])
          if key_kind == ValueKind::ExternRef {
            ctx.need_extern_table = true
            ctx.need_js_equals = true
            let key_local = alloc_temp_local_with_kind(
              ctx,
              ValueKind::ExternRef,
            )
            compile_expr(ctx, buf, pos_args[1])
            emit_local_set(buf, key_local)
            // loop
            buf.push((3).to_byte()) // loop
            buf.push((64).to_byte()) // void
            emit_local_get(buf, loop_i)
            emit_local_get(buf, map_len)
            emit_i32_lt_s(buf)
            buf.push((4).to_byte()) // if
            buf.push((64).to_byte()) // void
            // load stored key from extern table
            emit_local_get(buf, map_ptr)
            emit_local_get(buf, loop_i)
            emit_i32_const_raw(buf, 8)
            emit_i32_mul(buf)
            emit_i32_add(buf)
            emit_i32_load(buf, 8) // slot index
            emit_table_get(buf, ctx.extern_table_index)
            emit_local_get(buf, key_local)
            emit_call(buf, import_index_js_equals(ctx))
            buf.push((4).to_byte()) // if (equals)
            buf.push((64).to_byte()) // void
            // found: load value
            emit_local_get(buf, map_ptr)
            emit_local_get(buf, loop_i)
            emit_i32_const_raw(buf, 8)
            emit_i32_mul(buf)
            emit_i32_add(buf)
            emit_i32_load(buf, 12) // value at key_offset + 4
            emit_local_set(buf, result_local)
            buf.push((11).to_byte()) // end if (equals)
            // loop_i++
            emit_local_get(buf, loop_i)
            emit_i32_const_raw(buf, 1)
            emit_i32_add(buf)
            emit_local_set(buf, loop_i)
            buf.push((12).to_byte()) // br
            write_u32_leb(buf, 1) // to loop
            buf.push((11).to_byte()) // end if (i < len)
            buf.push((11).to_byte()) // end loop
            emit_local_get(buf, result_local)
          } else {
            // non-externref key (unlikely for map_get in json.xsh, but handle)
            let key_local = alloc_temp_local(ctx)
            compile_expr_i32(ctx, buf, pos_args[1])
            emit_local_set(buf, key_local)
            buf.push((3).to_byte()) // loop
            buf.push((64).to_byte()) // void
            emit_local_get(buf, loop_i)
            emit_local_get(buf, map_len)
            emit_i32_lt_s(buf)
            buf.push((4).to_byte()) // if
            buf.push((64).to_byte()) // void
            emit_local_get(buf, map_ptr)
            emit_local_get(buf, loop_i)
            emit_i32_const_raw(buf, 8)
            emit_i32_mul(buf)
            emit_i32_add(buf)
            emit_i32_load(buf, 8) // key
            emit_local_get(buf, key_local)
            emit_i32_eq(buf)
            buf.push((4).to_byte()) // if
            buf.push((64).to_byte()) // void
            emit_local_get(buf, map_ptr)
            emit_local_get(buf, loop_i)
            emit_i32_const_raw(buf, 8)
            emit_i32_mul(buf)
            emit_i32_add(buf)
            emit_i32_load(buf, 12) // value
            emit_local_set(buf, result_local)
            buf.push((11).to_byte()) // end if
            emit_local_get(buf, loop_i)
            emit_i32_const_raw(buf, 1)
            emit_i32_add(buf)
            emit_local_set(buf, loop_i)
            buf.push((12).to_byte()) // br
            write_u32_leb(buf, 1) // to loop
            buf.push((11).to_byte()) // end if
            buf.push((11).to_byte()) // end loop
            emit_local_get(buf, result_local)
          }
        } else {
          // non-js-string mode: keys are i32 string pointers
          let key_local = alloc_temp_local(ctx)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_local_set(buf, key_local)
          buf.push((3).to_byte()) // loop
          buf.push((64).to_byte()) // void
          emit_local_get(buf, loop_i)
          emit_local_get(buf, map_len)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, map_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 8)
          emit_i32_mul(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8) // key
          emit_local_get(buf, key_local)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, map_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 8)
          emit_i32_mul(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 12) // value
          emit_local_set(buf, result_local)
          buf.push((11).to_byte()) // end if
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, loop_i)
          buf.push((12).to_byte()) // br
          write_u32_leb(buf, 1) // to loop
          buf.push((11).to_byte()) // end if
          buf.push((11).to_byte()) // end loop
          emit_local_get(buf, result_local)
        }
      } else if ctx.fn_indices.contains(name) {
        let pos_args = extract_positional_exprs(args, name)
        let param_kinds = match ctx.fn_params.get(name) {
          Some(kinds) => kinds
          None => []
        }
        if pos_args.length() != param_kinds.length() {
          raise WasmGenError::Unsupported("arity: " + name)
        }
        for i in 0..<pos_args.length() {
          let kind = param_kinds[i]
          if ctx.use_js_strings && kind == ValueKind::ExternRef {
            compile_expr_ref(ctx, buf, pos_args[i])
          } else {
            compile_expr_i32(ctx, buf, pos_args[i])
          }
        }
        // Pass correct env: if function is a local (closure), extract env from closure value
        match ctx.locals.get(name) {
          Some(local_idx) => {
            let env_local = alloc_temp_local(ctx)
            emit_local_get(buf, local_idx)
            emit_i32_const_raw(buf, tag_mask)
            emit_i32_and(buf)
            emit_i32_const_raw(buf, tag_fn)
            emit_i32_eq(buf)
            buf.push((4).to_byte()) // if
            buf.push((127).to_byte()) // result i32
            emit_i32_const_raw(buf, 0) // bare fn: env = 0
            buf.push((5).to_byte()) // else
            // closure: env ptr = untag obj ptr
            emit_local_get(buf, local_idx)
            emit_local_get(buf, local_idx)
            emit_i32_const_raw(buf, tag_mask)
            emit_i32_and(buf)
            emit_i32_sub(buf)
            buf.push((11).to_byte()) // end
            emit_local_set(buf, env_local)
            emit_local_get(buf, env_local)
          }
          None => emit_i32_const_raw(buf, 0)
        }
        if ctx.heap_local >= 0 && ctx.use_heap_global {
          emit_local_get(buf, ctx.heap_local)
          emit_global_set(buf, ctx.heap_global)
        }
        let idx = func_import_count(ctx) +
          (match ctx.fn_indices.get(name) {
            Some(i) => i
            None => 0
          })
        emit_call(buf, idx)
        if ctx.heap_local >= 0 && ctx.use_heap_global {
          emit_global_get(buf, ctx.heap_global)
          emit_local_set(buf, ctx.heap_local)
        }
      } else if ctx.enum_ctor_tags.contains(name) {
        // Enum constructor call
        let tag = match ctx.enum_ctor_tags.get(name) {
          Some(t) => t
          None => 0
        }
        let arity = match ctx.enum_ctor_arities.get(name) {
          Some(a) => a
          None => 0
        }
        let pos_args = extract_positional_exprs(args, name)
        if arity == 0 {
          // Nullary ctor: heap object with just type + tag
          require_heap(ctx)
          let size = align4(8)
          let obj_local = alloc_temp_local(ctx)
          emit_local_get(buf, ctx.heap_local)
          emit_local_set(buf, obj_local)
          emit_local_get(buf, ctx.heap_local)
          emit_i32_const_raw(buf, size)
          emit_i32_add(buf)
          emit_local_set(buf, ctx.heap_local)
          emit_local_get(buf, obj_local)
          emit_i32_const_raw(buf, obj_enum)
          emit_i32_store(buf, 0)
          emit_local_get(buf, obj_local)
          emit_i32_const_raw(buf, tag)
          emit_i32_store(buf, 4)
          emit_local_get(buf, obj_local)
          emit_i32_const_raw(buf, tag_obj)
          emit_i32_or(buf)
        } else {
          // Ctor with args: heap object with type + tag + payload
          require_heap(ctx)
          let size = align4(8 + arity * 4)
          let obj_local = alloc_temp_local(ctx)
          emit_local_get(buf, ctx.heap_local)
          emit_local_set(buf, obj_local)
          emit_local_get(buf, ctx.heap_local)
          emit_i32_const_raw(buf, size)
          emit_i32_add(buf)
          emit_local_set(buf, ctx.heap_local)
          emit_local_get(buf, obj_local)
          emit_i32_const_raw(buf, obj_enum)
          emit_i32_store(buf, 0)
          emit_local_get(buf, obj_local)
          emit_i32_const_raw(buf, tag)
          emit_i32_store(buf, 4)
          for i in 0..<arity {
            let arg_kind = infer_expr_kind(ctx, pos_args[i])
            if ctx.use_js_strings && arg_kind == ValueKind::ExternRef {
              // Store externref in extern table, put slot index in payload
              ctx.need_extern_table = true
              let slot = ctx.extern_table_next_slot
              ctx.extern_table_next_slot += 1
              emit_i32_const_raw(buf, slot)
              compile_expr(ctx, buf, pos_args[i])
              emit_table_set(buf, ctx.extern_table_index)
              emit_local_get(buf, obj_local)
              emit_i32_const_raw(buf, slot)
              emit_i32_store(buf, 8 + i * 4)
            } else {
              emit_local_get(buf, obj_local)
              compile_expr_i32(ctx, buf, pos_args[i])
              emit_i32_store(buf, 8 + i * 4)
            }
          }
          emit_local_get(buf, obj_local)
          emit_i32_const_raw(buf, tag_obj)
          emit_i32_or(buf)
        }
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
      let saved = ctx.locals.copy()
      let saved_kinds = ctx.local_kinds.copy()
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
      let _ = span
      let try_kind = if ctx.use_js_strings {
        infer_block_kind(ctx, try_body, ctx.local_kinds)
      } else {
        ValueKind::I32
      }
      // (block $outer (result <type>)
      buf.push((2).to_byte()) // block opcode
      buf.push(valtype_byte(try_kind)) // result type
      //   (block $catch_target  ;; catch_all: no result
      buf.push((2).to_byte()) // block opcode
      buf.push((64).to_byte()) // empty type (0x40)
      //     (try_table (result <type>) (catch_all 0)
      buf.push((31).to_byte()) // try_table opcode = 0x1F
      buf.push(valtype_byte(try_kind)) // result type
      write_u32_leb(buf, 1) // catch clause count = 1
      buf.push((2).to_byte()) // catch_all = 0x02
      write_u32_leb(buf, 0) // label depth = 0 ($catch_target)
      //       compile try_body
      compile_block_expr(ctx, buf, try_body)
      //     end try_table
      buf.push((11).to_byte())
      //     br $outer (label depth = 1)
      buf.push((12).to_byte()) // br opcode
      write_u32_leb(buf, 1) // label depth = 1
      //   end $catch_target
      buf.push((11).to_byte())
      //   compile catch_body
      compile_block_expr(ctx, buf, catch_body)
      // end $outer
      buf.push((11).to_byte())
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~) => {
      let _ = params
      let _ = ret
      let _ = effects
      let _ = body
      let key = span_key(span)
      let func_idx = match ctx.fn_closure_indices.get(key) {
        Some(idx) => idx
        None => raise WasmGenError::Unsupported("fn index")
      }
      let captures = match ctx.fn_closure_captures.get(key) {
        Some(list) => list
        None => []
      }
      if captures.length() == 0 {
        emit_i32_const_raw(buf, tag_fn_value(func_idx))
      } else {
        require_heap(ctx)
        let len = captures.length()
        let size = align4(8 + len * 4)
        let obj_local = alloc_temp_local(ctx)
        emit_local_get(buf, ctx.heap_local)
        emit_local_set(buf, obj_local)
        emit_local_get(buf, ctx.heap_local)
        emit_i32_const_raw(buf, size)
        emit_i32_add(buf)
        emit_local_set(buf, ctx.heap_local)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_fn)
        emit_i32_store(buf, 0)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, func_idx)
        emit_i32_store(buf, 4)
        let capture_kinds : Array[ValueKind] = []
        for i in 0..<len {
          let name = captures[i]
          let cap_kind = match ctx.local_kinds.get(name) {
            Some(kind) => kind
            None => ValueKind::I32
          }
          capture_kinds.push(cap_kind)
          if ctx.use_js_strings && cap_kind == ValueKind::ExternRef {
            // Store externref in extern table, put slot index in closure env
            ctx.need_extern_table = true
            let slot = ctx.extern_table_next_slot
            ctx.extern_table_next_slot += 1
            // table.set $extern_table slot externref_value
            emit_i32_const_raw(buf, slot)
            match ctx.locals.get(name) {
              Some(idx) => emit_local_get(buf, idx)
              None => raise WasmGenError::UnknownName(name)
            }
            emit_table_set(buf, ctx.extern_table_index)
            // Store slot index in closure env
            emit_local_get(buf, obj_local)
            emit_i32_const_raw(buf, slot)
            emit_i32_store(buf, 8 + i * 4)
          } else {
            emit_local_get(buf, obj_local)
            match ctx.locals.get(name) {
              Some(idx) => emit_local_get(buf, idx)
              None =>
                match ctx.fn_indices.get(name) {
                  Some(idx) => emit_i32_const_raw(buf, tag_fn_value(idx))
                  None => raise WasmGenError::UnknownName(name)
                }
            }
            emit_i32_store(buf, 8 + i * 4)
          }
        }
        ctx.fn_closure_capture_kinds[key] = capture_kinds
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, tag_obj)
        emit_i32_or(buf)
      }
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = cond
      let _ = body
      let _ = span
      raise WasmGenError::Unsupported("while")
    }
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      if ctx.use_js_strings {
        compile_expr(ctx, buf, value) // externref string on stack
      } else {
        compile_expr_i32(ctx, buf, value) // tagged i32 string on stack
      }
      buf.push((8).to_byte()) // throw opcode = 0x08
      write_u32_leb(buf, ctx.error_tag_index) // tag index
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
      match expr {
        @core.Expr::Fn(
          params=fn_params,
          ret=fn_ret,
          effects~,
          body=fn_body,
          span=fn_span
        ) => {
          let _ = effects
          let key = span_key(fn_span)
          let func_idx = match ctx.fn_closure_indices.get(key) {
            Some(i) => i
            None => -1
          }
          if func_idx >= 0 {
            // Register as callable function (direct call)
            ctx.fn_indices[name] = func_idx
            let kinds = param_kinds(ctx, fn_params)
            ctx.fn_params[name] = kinds
            let ret_kind = match fn_ret {
              Some(r) => value_kind_from_type(ctx, r)
              None => ValueKind::I32
            }
            ctx.fn_returns[name] = ret_kind
            // Infer return signature if function returns a function type
            match fn_ret {
              Some(r) =>
                match func_sig_from_type(ctx, r) {
                  Some(sig) => ctx.fn_return_sigs[name] = sig
                  None => ()
                }
              None => {
                // Try to infer from body's last expression
                match infer_body_return_sig(ctx, fn_body) {
                  Some(sig) => ctx.fn_return_sigs[name] = sig
                  None => ()
                }
              }
            }
          }
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
          // Back-patch self-reference for recursive closures
          if rec {
            let captures = match ctx.fn_closure_captures.get(key) {
              Some(list) => list
              None => []
            }
            for i in 0..<captures.length() {
              if captures[i] == name {
                // Found self-reference capture at slot i
                // Load env pointer (untag obj ptr), write closure value to slot
                let env_local = alloc_temp_local(ctx)
                emit_local_get(buf, idx)
                emit_i32_const_raw(buf, -4)
                emit_i32_and(buf) // untag obj pointer
                emit_local_set(buf, env_local)
                emit_local_get(buf, env_local)
                emit_local_get(buf, idx) // closure value
                emit_i32_store(buf, 8 + i * 4) // write to capture slot
                break
              }
            }
          }
        }
        _ => {
          let kind = infer_expr_kind(ctx, expr)
          let idx = ctx.local_count
          ctx.local_count += 1
          ctx.local_types.push(kind)
          ctx.locals[name] = idx
          ctx.local_kinds[name] = kind
          // If the expression is a Call that returns a function, register in fn_local_sigs
          match expr {
            @core.Expr::Call(name=call_name, args~, span~) => {
              let _ = args
              let _ = span
              match ctx.fn_return_sigs.get(call_name) {
                Some(sig) => ctx.fn_local_sigs[name] = sig
                None => ()
              }
            }
            _ => ()
          }
          compile_expr(ctx, buf, expr)
          if is_last {
            emit_local_tee(buf, idx)
          } else {
            emit_local_set(buf, idx)
          }
        }
      }
    }
    @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
      let _ = name
      let _ = params
      let _ = span
      for i in 0..<ctors.length() {
        let ctor = ctors[i]
        ctx.enum_ctor_tags[ctor.name] = i
        ctx.enum_ctor_arities[ctor.name] = ctor.args.length()
        if not(ctx.enum_ctor_arg_kinds.contains(ctor.name)) {
          let arg_kinds : Array[ValueKind] = []
          for arg in ctor.args {
            arg_kinds.push(value_kind_from_type(ctx, arg))
          }
          ctx.enum_ctor_arg_kinds[ctor.name] = arg_kinds
        }
      }
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
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let _ = name
      let _ = expr
      let _ = span
      raise WasmGenError::Unsupported("let mut")
    }
    @core.Stmt::Assign(name~, expr~, span~) => {
      let _ = name
      let _ = expr
      let _ = span
      raise WasmGenError::Unsupported("assign")
    }
    @core.Stmt::LetPat(pat~, expr~, span~) => {
      let _ = span
      match pat {
        @core.Pat::Tuple(items~, span=pat_span) => {
          let _ = pat_span
          compile_expr_i32(ctx, buf, expr) // tuple pointer (tagged i32)
          let tuple_local = alloc_temp_local(ctx)
          emit_local_set(buf, tuple_local)
          let len = items.length()
          for i in 0..<len {
            match items[i] {
              @core.Pat::Bind(name~, span=bind_span) => {
                let _ = bind_span
                let local_idx = ctx.local_count
                ctx.local_count += 1
                ctx.local_types.push(ValueKind::I32)
                ctx.locals[name] = local_idx
                ctx.local_kinds[name] = ValueKind::I32
                emit_load_tuple_elem(buf, tuple_local, i)
                if is_last && i == len - 1 {
                  emit_local_tee(buf, local_idx)
                } else {
                  emit_local_set(buf, local_idx)
                }
              }
              @core.Pat::Wildcard(..) =>
                if is_last && i == len - 1 {
                  emit_load_tuple_elem(buf, tuple_local, i)
                }
              _ => raise WasmGenError::Unsupported("let pat: non-bind element")
            }
          }
          if is_last && len == 0 {
            emit_i32_const_tagged(buf, 0)
          }
        }
        _ => raise WasmGenError::Unsupported("let pat: non-tuple")
      }
    }
  }
}

///|
fn compile_block_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  body : @core.Module,
) -> Unit raise WasmGenError {
  let saved = ctx.locals.copy()
  let saved_kinds = ctx.local_kinds.copy()
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
    let item_kind = if ctx.use_js_strings {
      infer_expr_kind(ctx, items[i])
    } else {
      ValueKind::I32
    }
    if ctx.use_js_strings && item_kind == ValueKind::ExternRef {
      // Store externref in extern table, put slot index in tuple
      ctx.need_extern_table = true
      let slot = ctx.extern_table_next_slot
      ctx.extern_table_next_slot += 1
      emit_i32_const_raw(buf, slot)
      compile_expr(ctx, buf, items[i])
      emit_table_set(buf, ctx.extern_table_index)
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, slot)
      emit_i32_store(buf, 8 + i * 4)
    } else {
      emit_local_get(buf, obj_local)
      compile_expr_i32(ctx, buf, items[i])
      emit_i32_store(buf, 8 + i * 4)
    }
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
    while i > 0 && out[i].name < out[i - 1].name {
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
    while i > 0 && out[i].name < out[i - 1].name {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn compile_func_body(
  ctx : CodegenCtx,
  ast : @core.Module,
  result_kind : ValueKind,
  need_heap : Bool,
  prelude : Array[Byte],
) -> Array[Byte] raise WasmGenError {
  let instr = ByteBuf::new()
  if ctx.use_js_strings && result_kind != ValueKind::I32 {
    let inferred = infer_block_kind(ctx, ast, ctx.local_kinds)
    if inferred != result_kind {
      raise WasmGenError::Unsupported("js-string return kind")
    }
  }
  ctx.need_heap = need_heap
  if ctx.need_heap {
    ctx.heap_local = ctx.local_count
    ctx.local_count += 1
    ctx.local_types.push(ValueKind::I32)
  }
  compile_block_expr(ctx, instr, ast)
  if ctx.need_heap && ctx.use_heap_global {
    emit_local_get(instr, ctx.heap_local)
    emit_global_set(instr, ctx.heap_global)
  }
  instr.push((11).to_byte())
  if ctx.need_heap || prelude.length() > 0 {
    let prologue = ByteBuf::new()
    if ctx.need_heap {
      if ctx.use_heap_global {
        emit_global_get(prologue, ctx.heap_global)
        emit_local_set(prologue, ctx.heap_local)
      } else {
        let heap_start = align4(ctx.strings.next_offset)
        emit_i32_const_raw(prologue, heap_start)
        emit_local_set(prologue, ctx.heap_local)
      }
    }
    if prelude.length() > 0 {
      prologue.extend(prelude)
    }
    prologue.extend(instr.data)
    prologue.data
  } else {
    instr.data
  }
}

///|
fn compile_function(
  ctx : CodegenCtx,
  params : Array[@core.FuncParam],
  param_kinds : Array[ValueKind],
  result_kind : ValueKind,
  body : @core.Module,
  need_heap : Bool,
  captures : Array[String],
  capture_kinds : Array[ValueKind],
  with_env : Bool,
) -> WasmFunc raise WasmGenError {
  let saved_locals = ctx.locals
  let saved_kinds = ctx.local_kinds
  let saved_types = ctx.local_types
  let saved_count = ctx.local_count
  let saved_need_heap = ctx.need_heap
  let saved_heap_local = ctx.heap_local
  let saved_fn_locals = ctx.fn_local_sigs
  ctx.locals = {}
  ctx.local_kinds = {}
  ctx.local_types = []
  ctx.local_count = 0
  ctx.need_heap = false
  ctx.heap_local = -1
  ctx.fn_local_sigs = {}
  let param_len = if params.length() < param_kinds.length() {
    params.length()
  } else {
    param_kinds.length()
  }
  for i in 0..<param_len {
    ctx.locals[params[i].name] = i
    ctx.local_kinds[params[i].name] = param_kinds[i]
    ctx.local_count += 1
    match func_sig_from_type(ctx, params[i].ty) {
      Some(sig) => ctx.fn_local_sigs[params[i].name] = sig
      None => ()
    }
  }
  let env_idx = if with_env {
    let idx = ctx.local_count
    ctx.local_count += 1
    idx
  } else {
    -1
  }
  let prelude = ByteBuf::new()
  if with_env && captures.length() > 0 {
    for i in 0..<captures.length() {
      let name = captures[i]
      let kind = if i < capture_kinds.length() {
        capture_kinds[i]
      } else {
        ValueKind::I32
      }
      let idx = ctx.local_count
      ctx.local_count += 1
      if ctx.use_js_strings && kind == ValueKind::ExternRef {
        // ExternRef capture: load table slot index from env, then table.get
        ctx.local_types.push(ValueKind::ExternRef)
        ctx.locals[name] = idx
        ctx.local_kinds[name] = ValueKind::ExternRef
        emit_local_get(prelude, env_idx)
        emit_i32_load(prelude, 8 + i * 4) // load slot index
        emit_table_get(prelude, ctx.extern_table_index)
        emit_local_set(prelude, idx)
      } else {
        ctx.local_types.push(ValueKind::I32)
        ctx.locals[name] = idx
        ctx.local_kinds[name] = kind
        emit_local_get(prelude, env_idx)
        emit_i32_load(prelude, 8 + i * 4)
        emit_local_set(prelude, idx)
      }
    }
  }
  let body_bytes = compile_func_body(
    ctx,
    body,
    result_kind,
    need_heap,
    prelude.data,
  )
  let locals = ctx.local_types
  let params_with_env : Array[ValueKind] = []
  for kind in param_kinds {
    params_with_env.push(kind)
  }
  if with_env {
    params_with_env.push(ValueKind::I32)
  }
  let func = WasmFunc::{
    params: params_with_env,
    locals,
    result: result_kind,
    body: body_bytes,
  }
  ctx.locals = saved_locals
  ctx.local_kinds = saved_kinds
  ctx.local_types = saved_types
  ctx.local_count = saved_count
  ctx.need_heap = saved_need_heap
  ctx.heap_local = saved_heap_local
  ctx.fn_local_sigs = saved_fn_locals
  func
}

///|
fn write_func_type(
  buf : ByteBuf,
  params : Array[ValueKind],
  result : ValueKind,
) -> Unit {
  buf.push((96).to_byte())
  write_u32_leb(buf, params.length())
  for kind in params {
    buf.push(valtype_byte(kind))
  }
  write_u32_leb(buf, 1)
  buf.push(valtype_byte(result))
}

///|
fn build_module(ctx : CodegenCtx, funcs : Array[WasmFunc]) -> Bytes {
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
  let builtin_count = type_count
  let func_type_indices : Array[Int] = []
  for func in funcs {
    let key = func_sig_key_from_parts(func.params, func.result)
    let idx = match ctx.fn_sig_type_indices.get(key) {
      Some(i) => i
      None => builtin_count
    }
    func_type_indices.push(idx)
  }
  let exception_type_count = if ctx.need_exceptions { 1 } else { 0 }
  let total_type_count = builtin_count +
    ctx.fn_sig_order.length() +
    exception_type_count
  write_u32_leb(type_sec, total_type_count)
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
    write_ref_extern(type_sec)
  }
  if ctx.need_js_concat {
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 2)
    type_sec.push(ref_type)
    type_sec.push(ref_type)
    write_u32_leb(type_sec, 1)
    write_ref_extern(type_sec)
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
  for sig in ctx.fn_sig_order {
    write_func_type(type_sec, sig.params, sig.result)
  }
  if ctx.need_exceptions {
    ctx.error_tag_type_index = builtin_count + ctx.fn_sig_order.length()
    // tag type: (param <valtype>) -> () (no results)
    type_sec.push((96).to_byte()) // func type
    write_u32_leb(type_sec, 1) // param count = 1
    if ctx.use_js_strings {
      type_sec.push(ref_type) // externref
    } else {
      type_sec.push((127).to_byte()) // i32
    }
    write_u32_leb(type_sec, 0) // result count = 0
  }
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
  write_u32_leb(func_sec, funcs.length())
  for idx in func_type_indices {
    write_u32_leb(func_sec, idx)
  }
  write_section(buf, 3, func_sec.data)

  // table section (for function values + optional externref table)
  let user_func_count = if funcs.length() > 0 { funcs.length() - 1 } else { 0 }
  let has_extern_table = ctx.need_extern_table && ctx.extern_table_next_slot > 0
  let table_count = (if user_func_count > 0 { 1 } else { 0 }) +
    (if has_extern_table { 1 } else { 0 })
  if table_count > 0 {
    let table_sec = ByteBuf::new()
    write_u32_leb(table_sec, table_count)
    if user_func_count > 0 {
      // table 0: funcref
      table_sec.push((112).to_byte()) // funcref
      table_sec.push((0).to_byte()) // limits: min only
      write_u32_leb(table_sec, user_func_count)
    }
    if has_extern_table {
      // table 1 (or 0 if no funcref table): externref
      table_sec.push((111).to_byte()) // externref
      table_sec.push((0).to_byte()) // limits: min only
      write_u32_leb(table_sec, ctx.extern_table_next_slot)
    }
    write_section(buf, 4, table_sec.data)
  }

  // memory section
  let mem_sec = ByteBuf::new()
  write_u32_leb(mem_sec, 1)
  mem_sec.push((0).to_byte())
  write_u32_leb(mem_sec, 1)
  write_section(buf, 5, mem_sec.data)

  // tag section (section ID 13, placed between memory and global per spec)
  if ctx.need_exceptions {
    let tag_sec = ByteBuf::new()
    write_u32_leb(tag_sec, 1) // tag count = 1
    tag_sec.push((0).to_byte()) // attribute: 0x00 = exception
    write_u32_leb(tag_sec, ctx.error_tag_type_index) // type index
    write_section(buf, 13, tag_sec.data)
  }

  // global section
  if ctx.use_heap_global {
    let global_sec = ByteBuf::new()
    write_u32_leb(global_sec, 1)
    global_sec.push((127).to_byte())
    global_sec.push((1).to_byte())
    let heap_start = align4(ctx.strings.next_offset)
    emit_i32_const_raw(global_sec, heap_start)
    global_sec.push((11).to_byte())
    write_section(buf, 6, global_sec.data)
  }

  // export section
  let export_count = 2 + (if ctx.need_exceptions { 1 } else { 0 })
  let export_sec = ByteBuf::new()
  write_u32_leb(export_sec, export_count)
  write_name(export_sec, "run")
  export_sec.push((0).to_byte()) // func export
  let run_index = func_import_count + funcs.length() - 1
  write_u32_leb(export_sec, run_index)
  write_name(export_sec, "memory")
  export_sec.push((2).to_byte()) // memory export
  write_u32_leb(export_sec, 0)
  if ctx.need_exceptions {
    write_name(export_sec, "error")
    export_sec.push((4).to_byte()) // tag export
    write_u32_leb(export_sec, 0) // tag index 0
  }
  write_section(buf, 7, export_sec.data)

  // element section
  if user_func_count > 0 {
    let elem_sec = ByteBuf::new()
    write_u32_leb(elem_sec, 1)
    elem_sec.push((0).to_byte())
    emit_i32_const_raw(elem_sec, 0)
    elem_sec.push((11).to_byte())
    write_u32_leb(elem_sec, user_func_count)
    for i in 0..<user_func_count {
      write_u32_leb(elem_sec, func_import_count + i)
    }
    write_section(buf, 9, elem_sec.data)
  }

  // code section
  let code_sec = ByteBuf::new()
  write_u32_leb(code_sec, funcs.length())
  for func in funcs {
    let func_body = ByteBuf::new()
    if func.locals.length() == 0 {
      write_u32_leb(func_body, 0)
    } else {
      let group_kinds : Array[ValueKind] = []
      let group_counts : Array[Int] = []
      for kind in func.locals {
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
    func_body.extend(func.body)
    write_u32_leb(code_sec, func_body.len())
    code_sec.extend(func_body.data)
  }
  write_section(buf, 10, code_sec.data)

  // data section
  let seg_count = ctx.strings.segments.length()
  if seg_count > 0 {
    let data_sec = ByteBuf::new()
    let use_packed = if seg_count > 1 {
      packed_data_content_len(ctx.strings) <
      segmented_data_content_len(ctx.strings)
    } else {
      false
    }
    if use_packed {
      let data = pack_string_segments(ctx.strings)
      write_u32_leb(data_sec, 1)
      data_sec.push((0).to_byte())
      emit_i32_const_raw(data_sec, 0)
      data_sec.push((11).to_byte())
      write_u32_leb(data_sec, data.length())
      data_sec.extend(data)
    } else {
      write_u32_leb(data_sec, seg_count)
      for seg in ctx.strings.segments {
        data_sec.push((0).to_byte())
        emit_i32_const_raw(data_sec, seg.offset)
        data_sec.push((11).to_byte())
        write_u32_leb(data_sec, seg.bytes.length())
        data_sec.extend(seg.bytes)
      }
    }
    write_section(buf, 11, data_sec.data)
  }
  buf.to_bytes()
}

///|
fn write_section(buf : ByteBuf, id : Int, content : Array[Byte]) -> Unit {
  buf.push(id.to_byte())
  write_u32_leb(buf, content.length())
  buf.extend(content)
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
  Ctor(Int, Array[@core.Pat], Int, String, PatCont) // ctor_idx, args, index, ctor_name, next
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
    PatCont::Ctor(ctor_idx, args, index, ctor_name, next) =>
      compile_ctor_args_cont(
        ctx, buf, ctor_idx, args, index, ctor_name, next, match_scrut_idx, arms,
        start, arm, bindings,
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
    @core.Pat::Float(value=n, span~) => {
      let _ = span
      emit_tag_obj_check(buf, value_idx)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      emit_load_obj_type(buf, value_idx)
      emit_i32_const_raw(buf, obj_float)
      emit_i32_eq(buf)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      emit_untag_ptr(buf, value_idx)
      emit_f32_load(buf, 4)
      emit_f32_const(buf, n)
      emit_f32_eq(buf)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
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
    @core.Pat::Double(value=n, span~) => {
      let _ = span
      emit_tag_obj_check(buf, value_idx)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      emit_load_obj_type(buf, value_idx)
      emit_i32_const_raw(buf, obj_double)
      emit_i32_eq(buf)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      emit_untag_ptr(buf, value_idx)
      emit_f64_load(buf, 4)
      emit_f64_const(buf, n)
      emit_f64_eq(buf)
      buf.push((4).to_byte())
      buf.push((127).to_byte())
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
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
      let _ = span
      let tag = match ctx.enum_ctor_tags.get(name) {
        Some(t) => t
        None => raise WasmGenError::Unsupported("unknown ctor: " + name)
      }
      // Check: is obj_enum?
      emit_tag_obj_check(buf, value_idx)
      buf.push((4).to_byte()) // if
      buf.push((127).to_byte()) // result i32
      emit_load_obj_type(buf, value_idx)
      emit_i32_const_raw(buf, obj_enum)
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if
      buf.push((127).to_byte()) // result i32
      // Check: tag matches?
      emit_untag_ptr(buf, value_idx)
      emit_i32_load(buf, 4) // load tag
      emit_i32_const_raw(buf, tag)
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if
      buf.push((127).to_byte()) // result i32
      // Bind args
      if args.length() == 0 {
        compile_pat_cont(
          ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
        )
      } else {
        compile_ctor_args_cont(
          ctx, buf, value_idx, args, 0, name, cont, match_scrut_idx, arms, start,
          arm, bindings,
        )
      }
      buf.push((5).to_byte()) // else (tag mismatch)
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte()) // end
      buf.push((5).to_byte()) // else (not obj_enum)
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte()) // end
      buf.push((5).to_byte()) // else (not tagged obj)
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte()) // end
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
    @core.Pat::Or(pats~, span~) => {
      let _ = span
      // Expand Or pattern: try each sub-pattern, first match wins
      // Create synthetic arms for each sub-pattern with the same body
      let expanded_arms : Array[@core.MatchArm] = []
      for p in pats {
        expanded_arms.push(@core.MatchArm::{
          pat: p,
          cond: arm.cond,
          expr: arm.expr,
          span: arm.span,
        })
      }
      // Add remaining arms after this one
      for i in (start + 1)..<arms.length() {
        expanded_arms.push(arms[i])
      }
      compile_match_chain(ctx, buf, match_scrut_idx, expanded_arms, 0)
    }
  }
}

///|
fn compile_ctor_args_cont(
  ctx : CodegenCtx,
  buf : ByteBuf,
  ctor_idx : Int,
  args : Array[@core.Pat],
  index : Int,
  ctor_name : String,
  next : PatCont,
  match_scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
) -> Unit raise WasmGenError {
  if index >= args.length() {
    compile_pat_cont(
      ctx, buf, next, match_scrut_idx, arms, start, arm, bindings,
    )
    return
  }
  let arg_kinds = match ctx.enum_ctor_arg_kinds.get(ctor_name) {
    Some(kinds) => kinds
    None => []
  }
  let field_kind = if index < arg_kinds.length() {
    arg_kinds[index]
  } else {
    ValueKind::I32
  }
  if ctx.use_js_strings && field_kind == ValueKind::ExternRef {
    // ExternRef field: load table slot index, then table.get
    let tmp = alloc_temp_local_with_kind(ctx, ValueKind::ExternRef)
    emit_untag_ptr(buf, ctor_idx)
    emit_i32_load(buf, 8 + index * 4) // slot index
    emit_table_get(buf, ctx.extern_table_index)
    emit_local_set(buf, tmp)
    let cont = PatCont::Ctor(ctor_idx, args, index + 1, ctor_name, next)
    compile_pat_match(
      ctx,
      buf,
      tmp,
      args[index],
      match_scrut_idx,
      arms,
      start,
      arm,
      bindings,
      cont,
    )
  } else {
    let tmp = alloc_temp_local(ctx)
    emit_untag_ptr(buf, ctor_idx)
    emit_i32_load(buf, 8 + index * 4)
    emit_local_set(buf, tmp)
    let cont = PatCont::Ctor(ctor_idx, args, index + 1, ctor_name, next)
    compile_pat_match(
      ctx,
      buf,
      tmp,
      args[index],
      match_scrut_idx,
      arms,
      start,
      arm,
      bindings,
      cont,
    )
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
    @core.Pat::Float(value~, span~) => {
      let _ = value
      let _ = span
      raise WasmGenError::Unsupported("float literal")
    }
    @core.Pat::Double(value~, span~) => {
      let _ = value
      let _ = span
      raise WasmGenError::Unsupported("double literal")
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
    @core.Pat::Or(pats~, span~) => {
      let _ = pats
      let _ = span
      raise WasmGenError::Unsupported("or pattern literal")
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
  let saved = ctx.locals.copy()
  let saved_kinds = ctx.local_kinds.copy()
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
  let saved = ctx.locals.copy()
  let saved_kinds = ctx.local_kinds.copy()
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
fn alloc_temp_local_with_kind(ctx : CodegenCtx, kind : ValueKind) -> Int {
  let idx = ctx.local_count
  ctx.local_count += 1
  ctx.local_types.push(kind)
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
fn emit_module(
  ctx : CodegenCtx,
  ast : @core.Module,
) -> Bytes raise WasmGenError {
  let funcs = collect_func_defs(ast)
  let top_funcs = collect_top_level_funcs(ast)
  let top_keys : Map[String, Bool] = {}
  for f in top_funcs {
    top_keys[f.span_key] = true
  }
  for i in 0..<funcs.length() {
    let f = funcs[i]
    ctx.fn_closure_indices[f.span_key] = i
    ctx.fn_closure_captures[f.span_key] = f.captures
    match f.name {
      Some(name) => ctx.fn_indices[name] = i
      None => ()
    }
  }
  scan_needs(ctx, ast)
  scan_strings(ctx, ast)
  let func_param_kinds : Array[Array[ValueKind]] = []
  let func_return_kinds : Array[ValueKind] = []
  for i in 0..<funcs.length() {
    let f = funcs[i]
    let kinds = param_kinds(ctx, f.params)
    func_param_kinds.push(kinds)
    match f.name {
      Some(name) => {
        ctx.fn_params[name] = kinds
        if top_keys.contains(f.span_key) {
          let default_ret = match f.ret {
            Some(r) => value_kind_from_type(ctx, r)
            None => ValueKind::I32
          }
          ctx.fn_returns[name] = default_ret
          // Register return signature if function returns a function type
          match f.ret {
            Some(r) =>
              match func_sig_from_type(ctx, r) {
                Some(sig) => ctx.fn_return_sigs[name] = sig
                None => ()
              }
            None =>
              // Try to infer from body's last expression
              match infer_body_return_sig(ctx, f.body) {
                Some(sig) => ctx.fn_return_sigs[name] = sig
                None => ()
              }
          }
        }
      }
      None => ()
    }
  }
  for i in 0..<funcs.length() {
    let f = funcs[i]
    let ret_kind = if top_keys.contains(f.span_key) {
      infer_func_return_kind(ctx, f.params, func_param_kinds[i], f.ret, f.body) catch {
        e =>
          match f.name {
            Some(name) =>
              raise WasmGenError::Unsupported("in function " + name + ": " + e.to_string())
            None => raise e
          }
      }
    } else {
      // Nested functions: use declared return type or default I32
      match f.ret {
        Some(r) => value_kind_from_type(ctx, r)
        None => ValueKind::I32
      }
    }
    func_return_kinds.push(ret_kind)
    if top_keys.contains(f.span_key) {
      match f.name {
        Some(name) => ctx.fn_returns[name] = ret_kind
        None => ()
      }
    }
  }
  ctx.fn_sig_type_indices = {}
  ctx.fn_sig_order = []
  ctx.fn_type_indices = {}
  for f in funcs {
    for param in f.params {
      match func_sig_from_type(ctx, param.ty) {
        Some(sig) => ignore(ensure_sig_index(ctx, sig))
        None => ()
      }
    }
  }
  for i in 0..<funcs.length() {
    let sig = func_sig_with_env(func_param_kinds[i], func_return_kinds[i])
    let type_idx = ensure_sig_index(ctx, sig)
    ctx.fn_type_indices[funcs[i].span_key] = type_idx
  }
  let run_sig = FuncSig::{ params: [], result: ValueKind::I32 }
  let _ = ensure_sig_index(ctx, run_sig)
  let run_ast = filter_top_level_funcs(ast)
  let func_needs_heap : Array[Bool] = []
  let mut any_user_heap = false
  for f in funcs {
    let need = needs_heap_block(ctx, f.body)
    if need {
      any_user_heap = true
    }
    func_needs_heap.push(need)
  }
  let run_need_heap = needs_heap_block(ctx, run_ast)
  if any_user_heap {
    ctx.use_heap_global = true
    let global_imports = if ctx.use_js_strings {
      ctx.js_strings.names.length()
    } else {
      0
    }
    ctx.heap_global = global_imports
  }
  // Pre-compute extern_table_index for externref captures
  let user_func_count = if funcs.length() > 0 { funcs.length() - 1 } else { 0 }
  ctx.extern_table_index = if user_func_count > 0 { 1 } else { 0 }
  let compiled_funcs : Array[WasmFunc] = []
  for i in 0..<funcs.length() {
    let f = funcs[i]
    let cap_kinds = match ctx.fn_closure_capture_kinds.get(f.span_key) {
      Some(kinds) => kinds
      None => []
    }
    compiled_funcs.push(
      compile_function(
        ctx,
        f.params,
        func_param_kinds[i],
        func_return_kinds[i],
        f.body,
        func_needs_heap[i],
        f.captures,
        cap_kinds,
        true,
      ),
    )
  }
  compiled_funcs.push(
    compile_function(
      ctx,
      [],
      [],
      ValueKind::I32,
      run_ast,
      run_need_heap,
      [],
      [],
      false,
    ),
  )
  build_module(ctx, compiled_funcs)
}

///|
pub fn emit_module_wasm(ast : @core.Module) -> Bytes raise WasmGenError {
  let ctx = CodegenCtx::new(false)
  emit_module(ctx, ast)
}

///|
pub fn emit_module_wasm_js_string(
  ast : @core.Module,
) -> Bytes raise WasmGenError {
  let ctx = CodegenCtx::new(true)
  emit_module(ctx, ast)
}
