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
fn call_split_test_arg(expr : @core.Expr) -> @core.CallArg {
  @core.CallArg::{ label: None, expr, span: call_split_test_span() }
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
    args, "array_get", 2,
  )
  match result {
    Ok(_) => fail("expected Unsupported")
    Err(WasmGenError::Unsupported(message)) =>
      assert_eq(message, "array_get arity")
    Err(other) => fail("unexpected error: \{other.to_string()}")
  }
}

///|
test "compile_call_builtin_pre_user handles __add" {
  let ctx = CodegenCtx::new(false)
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
test "compile_call_builtin_post_user handles path_ref" {
  let ctx = CodegenCtx::new(false)
  ctx.need_path = true
  let buf = ByteBuf::new()
  let args = [call_split_test_arg(call_split_test_string("./tmp"))]
  let handled = compile_call_builtin_post_user(ctx, buf, "path_ref", args) catch {
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
  let handled = compile_call_record_field_fallback_by_name(
    ctx, buf, "id", args,
  ) catch {
    err => fail(err.to_string())
  }
  assert_true(handled)
  assert_true(buf.len() > 0)
}
