///|
fn effect_test_span() -> @core.Span {
  @core.Span::empty(0)
}

///|
fn effect_test_expr_stmt(expr : @core.Expr) -> @core.Stmt {
  @core.Stmt::Expr(expr~, span=effect_test_span())
}

///|
fn effect_test_call_arg(expr : @core.Expr) -> @core.CallArg {
  { label: None, expr, span: effect_test_span() }
}

///|
fn effect_test_let(name : String, expr : @core.Expr) -> @core.Stmt {
  @core.Stmt::Let(rec=false, name~, expr~, span=effect_test_span())
}

///|
fn effect_test_fn(body_stmts : Array[@core.Stmt]) -> @core.Expr {
  @core.Expr::Fn(
    type_params=[],
    type_bounds={},
    params=[],
    ret=Some(@core.Type::Int),
    effects=[],
    body=@core.Module::{ stmts: body_stmts },
    span=effect_test_span(),
  )
}

///|
struct EffectTestCursor {
  bytes : Bytes
  mut pos : Int
}

///|
fn EffectTestCursor::new(bytes : Bytes) -> EffectTestCursor {
  { bytes, pos: 0 }
}

///|
fn EffectTestCursor::read_u8(self : EffectTestCursor) -> Int {
  if self.pos >= self.bytes.length() {
    abort("unexpected eof")
  }
  let b = self.bytes[self.pos]
  self.pos += 1
  b.to_int()
}

///|
fn EffectTestCursor::read_bytes(self : EffectTestCursor, n : Int) -> Bytes {
  if self.pos + n > self.bytes.length() {
    abort("unexpected eof")
  }
  let view = self.bytes[self.pos:self.pos + n]
  self.pos += n
  view.to_bytes()
}

///|
fn EffectTestCursor::read_leb_u32(self : EffectTestCursor) -> Int {
  let mut result = 0
  let mut shift = 0
  while true {
    let b = self.read_u8()
    result = result | ((b & 0x7f) << shift)
    if (b & 0x80) == 0 {
      return result
    }
    shift += 7
    if shift > 35 {
      abort("leb overflow")
    }
  }
  result
}

///|
fn effect_test_code_section_bytes(wasm : Bytes) -> Bytes {
  let cur = EffectTestCursor::new(wasm)
  if cur.read_u8() != 0x00 ||
    cur.read_u8() != 0x61 ||
    cur.read_u8() != 0x73 ||
    cur.read_u8() != 0x6d {
    abort("invalid wasm magic")
  }
  let _ = cur.read_u8()
  let _ = cur.read_u8()
  let _ = cur.read_u8()
  let _ = cur.read_u8()
  while cur.pos < wasm.length() {
    let id = cur.read_u8()
    let size = cur.read_leb_u32()
    let section = cur.read_bytes(size)
    if id == 10 {
      return section
    }
  }
  abort("code section not found")
}

///|
fn effect_test_bytes_contains(hay : Bytes, needle : Array[Byte]) -> Bool {
  if needle.length() == 0 {
    return true
  }
  let hay_arr = hay.to_array()
  let limit = hay_arr.length() - needle.length()
  if limit < 0 {
    return false
  }
  for i in 0..<=limit {
    let mut ok = true
    for j in 0..<needle.length() {
      if hay_arr[i + j] != needle[j] {
        ok = false
        break
      }
    }
    if ok {
      return true
    }
  }
  false
}

///|
test "compile_expr_handle encodes error-tag catch and typed catch block" {
  let span = effect_test_span()
  let ctx = CodegenCtx::new(false)
  let buf = ByteBuf::new()
  let body = @core.Module::{
    stmts: [effect_test_expr_stmt(@core.Expr::Int(value=1L, span~))],
  }
  let arm = @core.MatchArm::{
    pat: @core.Pat::Bind(name="err", span~),
    cond: None,
    expr: @core.Expr::Int(value=2L, span~),
    span,
  }
  compile_expr_handle(ctx, buf, body, [arm], span) catch {
    err => fail(err.to_string())
  }
  let arr = buf.to_bytes().to_array()
  assert_true(arr.length() >= 10)
  assert_eq(arr[0].to_int(), 2)
  assert_eq(arr[1].to_int(), valtype_byte(ValueKind::I64).to_int())
  assert_eq(arr[2].to_int(), 2)
  assert_eq(arr[3].to_int(), valtype_byte(ValueKind::I64).to_int())
  assert_eq(arr[4].to_int(), 31)
  assert_eq(arr[5].to_int(), valtype_byte(ValueKind::I64).to_int())
  assert_eq(arr[6].to_int(), 1)
  assert_eq(arr[7].to_int(), 0)
  assert_eq(arr[8].to_int(), 0)
  assert_eq(arr[9].to_int(), 0)
}

///|
test "compile_expr_multivalue handle encodes error-tag catch" {
  let span = effect_test_span()
  let ctx = CodegenCtx::new(false)
  let buf = ByteBuf::new()
  let body = @core.Module::{
    stmts: [effect_test_expr_stmt(@core.Expr::Int(value=1L, span~))],
  }
  let arm = @core.MatchArm::{
    pat: @core.Pat::Bind(name="err", span~),
    cond: None,
    expr: @core.Expr::Int(value=2L, span~),
    span,
  }
  let expr = @core.Expr::Handle(body~, arms=[arm], span~)
  compile_expr_multivalue(ctx, buf, expr, [ValueKind::I64]) catch {
    err => fail(err.to_string())
  }
  let arr = buf.to_bytes().to_array()
  assert_true(arr.length() >= 10)
  assert_eq(arr[0].to_int(), 2)
  assert_eq(arr[2].to_int(), 2)
  assert_eq(arr[3].to_int(), valtype_byte(ValueKind::I64).to_int())
  assert_eq(arr[4].to_int(), 31)
  assert_eq(arr[6].to_int(), 1)
  assert_eq(arr[7].to_int(), 0)
}

///|
test "perform uses effect import index before linked imports" {
  let span = effect_test_span()
  let perform_expr = @core.Expr::Perform(
    effect_name="Fs",
    op_name="ReadFile",
    args=[effect_test_call_arg(@core.Expr::String(value="x", span~))],
    span~,
  )
  let ast = @core.Module::{
    stmts: [
      effect_test_let(
        "run",
        effect_test_fn([effect_test_expr_stmt(perform_expr)]),
      ),
    ],
  }
  let wasm = try
    emit_module_wasm_with_options(
      ast,
      wasm_emit_options(library_mode=true, linked_imports=[
        ("lib", "one", 1, 1),
        ("lib", "two", 5, 1),
      ]),
    )
  catch {
    err => fail(err.to_string())
  } noraise {
    bytes => bytes
  }
  let code_sec = effect_test_code_section_bytes(wasm)
  assert_true(
    effect_test_bytes_contains(code_sec, [
      (0x41).to_byte(),
      (0x00).to_byte(),
      (0x10).to_byte(),
      (0x00).to_byte(),
    ]),
  )
  assert_false(
    effect_test_bytes_contains(code_sec, [
      (0x41).to_byte(),
      (0x00).to_byte(),
      (0x10).to_byte(),
      (0x02).to_byte(),
    ]),
  )
}
