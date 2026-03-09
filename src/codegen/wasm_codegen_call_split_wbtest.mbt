///|
fn call_split_test_span() -> @core.Span {
  @core.Span::empty(0)
}

///|
fn call_split_test_int(value : Int64) -> @core.Expr {
  @core.Expr::Int(value~, span=call_split_test_span())
}

///|
fn call_split_test_string(value : String) -> @core.Expr {
  @core.Expr::String(value~, span=call_split_test_span())
}

///|
fn call_split_test_bool(value : Bool) -> @core.Expr {
  @core.Expr::Bool(value~, span=call_split_test_span())
}

///|
fn call_split_test_arg(expr : @core.Expr) -> @core.CallArg {
  @core.CallArg::{ label: None, expr, span: call_split_test_span() }
}

///|
fn call_split_test_call(
  name : String,
  args : Array[@core.CallArg],
) -> @core.Expr {
  @core.Expr::Call(name~, type_args=[], args~, span=call_split_test_span())
}

///|
fn call_split_test_array(items : Array[@core.Expr]) -> @core.Expr {
  @core.Expr::Array(items~, span=call_split_test_span())
}

///|
test "extract_positional_exprs_with_arity returns positional args" {
  let args = [
    call_split_test_arg(call_split_test_int(1L)),
    call_split_test_arg(call_split_test_int(2L)),
  ]
  let pos_args = extract_positional_exprs_with_arity(args, "__add", 2) catch {
    err => fail(err.to_string())
  }
  assert_eq(pos_args.length(), 2)
}

///|
test "extract_positional_exprs_with_arity raises arity error" {
  let args = [call_split_test_arg(call_split_test_int(1L))]
  let result : Result[Array[@core.Expr], WasmGenError] = try? extract_positional_exprs_with_arity(
    args, "Array::get", 2,
  )
  match result {
    Ok(_) => fail("expected Unsupported")
    Err(WasmGenError::Unsupported(message)) =>
      assert_eq(message, "Array::get arity")
    Err(other) => fail("unexpected error: \{other.to_string()}")
  }
}

///|
test "compile_call_builtin_pre_user handles __add" {
  let ctx = CodegenCtx::new(false)
  ctx.heap_local = alloc_temp_local(ctx)
  let buf = ByteBuf::new()
  let args = [
    call_split_test_arg(call_split_test_int(1L)),
    call_split_test_arg(call_split_test_int(2L)),
  ]
  let handled = compile_call_builtin_pre_user(ctx, buf, "__add", args, false) catch {
    err => fail(err.to_string())
  }
  assert_true(handled)
  assert_true(buf.len() > 0)
}

///|
test "compile_call_builtin_pre_user handles __assert" {
  let ctx = CodegenCtx::new(false)
  let buf = ByteBuf::new()
  let args = [call_split_test_arg(call_split_test_bool(true))]
  let handled = compile_call_builtin_pre_user(ctx, buf, "__assert", args, false) catch {
    err => fail(err.to_string())
  }
  assert_true(handled)
  assert_true(buf.len() > 0)
}

///|
test "compile_call_builtin_pre_user returns false for unknown" {
  let ctx = CodegenCtx::new(false)
  let buf = ByteBuf::new()
  let args : Array[@core.CallArg] = []
  let handled = compile_call_builtin_pre_user(
    ctx, buf, "__not_supported_builtin", args, false,
  ) catch {
    err => fail(err.to_string())
  }
  assert_false(handled)
}

///|
test "compile_call_builtin_pre_user emits wasm fallback throw for Json::parse" {
  let ctx = CodegenCtx::new(false)
  ctx.need_exceptions = true
  let buf = ByteBuf::new()
  let args = [call_split_test_arg(call_split_test_string("{}"))]
  let handled = compile_call_builtin_pre_user(
    ctx, buf, "Json::parse", args, false,
  ) catch {
    err => fail(err.to_string())
  }
  assert_true(handled)
  assert_true(buf.len() > 0)
}

///|
test "compile_call_builtin_pre_user handles String::join" {
  let ctx = CodegenCtx::new(false)
  ctx.heap_local = alloc_temp_local(ctx)
  let buf = ByteBuf::new()
  let args = [
    call_split_test_arg(
      call_split_test_array([
        call_split_test_string("a"),
        call_split_test_string("b"),
      ]),
    ),
    call_split_test_arg(call_split_test_string(",")),
  ]
  let handled = compile_call_builtin_pre_user(
    ctx, buf, "String::join", args, false,
  ) catch {
    err => fail(err.to_string())
  }
  assert_true(handled)
  assert_true(buf.len() > 0)
}

///|
test "compile_call_builtin_pre_user keeps user fn priority for fallback names" {
  let ctx = CodegenCtx::new(false)
  let buf = ByteBuf::new()
  let args = [call_split_test_arg(call_split_test_string("{}"))]
  let handled = compile_call_builtin_pre_user(
    ctx, buf, "Json::parse", args, true,
  ) catch {
    err => fail(err.to_string())
  }
  assert_false(handled)
}

///|
test "compile_call_builtin_pre_user handles __set_index" {
  let ctx = CodegenCtx::new(false)
  let buf = ByteBuf::new()
  let args = [
    call_split_test_arg(call_split_test_int(0L)),
    call_split_test_arg(call_split_test_int(0L)),
    call_split_test_arg(call_split_test_int(1L)),
  ]
  let handled = compile_call_builtin_pre_user(
    ctx, buf, "__set_index", args, false,
  ) catch {
    err => fail(err.to_string())
  }
  assert_true(handled)
  assert_true(buf.len() > 0)
}

///|
test "compile_call_by_name handles __set_index" {
  let ctx = CodegenCtx::new(false)
  let buf = ByteBuf::new()
  let args = [
    call_split_test_arg(call_split_test_int(0L)),
    call_split_test_arg(call_split_test_int(0L)),
    call_split_test_arg(call_split_test_int(1L)),
  ]
  compile_call_by_name(ctx, buf, "__set_index", args) catch {
    err => fail(err.to_string())
  }
  assert_true(buf.len() > 0)
}

///|
test "scan_needs_expr enables exceptions for wasm fallback builtins" {
  let ctx = CodegenCtx::new(false)
  let expr = call_split_test_call("Json::parse", [
    call_split_test_arg(call_split_test_string("{}")),
  ])
  scan_needs_expr(ctx, expr)
  assert_true(ctx.need_exceptions)
}

///|
test "scan_needs_expr marks heap need for String::join" {
  let ctx = CodegenCtx::new(false)
  let expr = call_split_test_call("String::join", [
    call_split_test_arg(call_split_test_int(0L)),
    call_split_test_arg(call_split_test_string(",")),
  ])
  scan_needs_expr(ctx, expr)
  assert_true(ctx.need_heap)
}

///|
test "needs_heap_expr returns true for MapBuilder::new call" {
  let ctx = CodegenCtx::new(false)
  let expr = call_split_test_call("MapBuilder::new", [])
  assert_true(needs_heap_expr(ctx, expr))
}

///|
test "needs_heap_expr returns true for String::join call" {
  let ctx = CodegenCtx::new(false)
  let expr = call_split_test_call("String::join", [
    call_split_test_arg(call_split_test_int(0L)),
    call_split_test_arg(call_split_test_string(",")),
  ])
  assert_true(needs_heap_expr(ctx, expr))
}

///|
test "needs_heap_expr returns true for string literal" {
  let ctx = CodegenCtx::new(false)
  assert_true(needs_heap_expr(ctx, call_split_test_string("x")))
}

///|
test "needs_heap_expr returns true for multivalue user call" {
  let ctx = CodegenCtx::new(false)
  ctx.fn_multivalue_results["mv_fn"] = [ValueKind::I64, ValueKind::I64]
  let expr = call_split_test_call("mv_fn", [])
  assert_true(needs_heap_expr(ctx, expr))
}

///|
test "scan_needs_stmt registers struct fields as known record fields" {
  let ctx = CodegenCtx::new(false)
  let field = @core.StructField::{
    name: "name",
    ty: @core.Type::String,
    span: call_split_test_span(),
  }
  let stmt = @core.Stmt::StructDef(
    name="FileEntry",
    params=[],
    fields=[field],
    span=call_split_test_span(),
  )
  scan_needs_stmt(ctx, stmt)
  assert_true(ctx.known_record_fields.contains("name"))
}

///|
test "compile_call_builtin_post_user handles Path::ref" {
  let ctx = CodegenCtx::new(false)
  ctx.need_path = true
  let buf = ByteBuf::new()
  let args = [call_split_test_arg(call_split_test_string("./tmp"))]
  let handled = compile_call_builtin_post_user(ctx, buf, "Path::ref", args) catch {
    err => fail(err.to_string())
  }
  assert_true(handled)
  assert_true(buf.len() > 0)
}

///|
test "compile_call_builtin_post_user returns false for unknown" {
  let ctx = CodegenCtx::new(false)
  let buf = ByteBuf::new()
  let args : Array[@core.CallArg] = []
  let handled = compile_call_builtin_post_user(
    ctx, buf, "__not_supported_builtin", args,
  ) catch {
    err => fail(err.to_string())
  }
  assert_false(handled)
}

///|
test "compile_call_enum_ctor_by_name handles zero-arity ctor" {
  let ctx = CodegenCtx::new(false)
  ctx.heap_local = alloc_temp_local(ctx)
  ctx.enum_ctor_tags["CtorX"] = 7
  ctx.enum_ctor_arities["CtorX"] = 0
  let buf = ByteBuf::new()
  let args : Array[@core.CallArg] = []
  let handled = compile_call_enum_ctor_by_name(ctx, buf, "CtorX", args) catch {
    err => fail(err.to_string())
  }
  assert_true(handled)
  assert_true(buf.len() > 0)
}

///|
test "compile_call_record_field_fallback_by_name handles known field" {
  let ctx = CodegenCtx::new(false)
  ctx.known_record_fields["id"] = true
  let buf = ByteBuf::new()
  let args = [call_split_test_arg(call_split_test_int(1L))]
  let handled = compile_call_record_field_fallback_by_name(ctx, buf, "id", args) catch {
    err => fail(err.to_string())
  }
  assert_true(handled)
  assert_true(buf.len() > 0)
}
