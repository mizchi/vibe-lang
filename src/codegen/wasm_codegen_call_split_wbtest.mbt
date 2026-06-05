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
fn call_split_bytes_contains_ascii(bytes : Bytes, needle : String) -> Bool {
  let hay_len = bytes.length()
  let needle_len = needle.length()
  if needle_len == 0 {
    return true
  }
  let limit = hay_len - needle_len
  if limit < 0 {
    return false
  }
  for i in 0..<=limit {
    let mut ok = true
    for j in 0..<needle_len {
      if bytes[i + j].to_int() != needle[j].to_int() {
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
fn call_split_bytes_contains_atomic_subop(
  bytes : Bytes,
  subop : Int,
) -> Bool {
  let arr = bytes.to_array()
  if arr.length() < 2 {
    return false
  }
  for i in 0..<(arr.length() - 1) {
    if arr[i] == b'\xfe' {
      let mut shift = 0
      let mut value = 0
      let mut pos = i + 1
      while pos < arr.length() {
        let byte = arr[pos].to_int()
        value = value | ((byte & 0x7f) << shift)
        pos += 1
        if (byte & 0x80) == 0 {
          break
        }
        shift += 7
      }
      if value == subop {
        return true
      }
    }
  }
  false
}

///|
fn call_split_bytes_contains_opcode(bytes : Bytes, opcode : Byte) -> Bool {
  let arr = bytes.to_array()
  for b in arr {
    if b == opcode {
      return true
    }
  }
  false
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
test "wasm emit options carry thread backend id" {
  let options = wasm_emit_options(
    thread_backend_id="component-unsafe-os-threads",
  )
  assert_eq(options.thread_backend_id, "component-unsafe-os-threads")
}

///|
test "wasm emit options carry thread component runtime imports" {
  let options = wasm_emit_options(thread_component_runtime_imports=true)
  assert_true(options.thread_component_runtime_imports)
}

///|
test "component thread runtime import mode emits spawn-indirect core import" {
  let ast = try! @parser.parse_ast(
    (
      #|let main = () -> Int with {Threads} {
      #|  let ch = Threads::channel_new(1)
      #|  let task = Threads::spawn("noop", ch)
      #|  Threads::wait(task)
      #|}
      #|0
    ),
  )
  let wasm = emit_module_wasm_with_options(
    ast,
    wasm_emit_options(
      thread_backend_id="component-unsafe-os-threads",
      thread_component_runtime_imports=true,
    ),
  ) catch {
    err => fail(err.to_string())
  }
  assert_true(call_split_bytes_contains_ascii(wasm, "thread.spawn-indirect"))
  assert_true(call_split_bytes_contains_ascii(wasm, "vibe:thread-runtime"))
  assert_true(
    call_split_bytes_contains_ascii(wasm, "__indirect_function_table"),
  )
}

///|
test "compile_call_builtin_pre_user rejects unconnected Threads backend" {
  let ctx = CodegenCtx::new(false, thread_backend_id="wasi-threads")
  let buf = ByteBuf::new()
  let result : Result[Bool, WasmGenError] = try? compile_call_builtin_pre_user(
    ctx,
    buf,
    "Threads::spawn",
    [
      call_split_test_arg(call_split_test_string("worker")),
      call_split_test_arg(call_split_test_int(0L)),
    ],
    false,
  )
  match result {
    Ok(_) => fail("expected Unsupported")
    Err(WasmGenError::Unsupported(message)) =>
      assert_true(
        message.contains("Threads::spawn has no compiled thread lowering"),
      )
    Err(other) => fail("unexpected error: \{other.to_string()}")
  }
}

///|
test "compile_call_builtin_pre_user lowers linear-local Threads channel builtins" {
  let cases : Array[(String, Array[@core.CallArg])] = [
    ("Threads::channel_new", [call_split_test_arg(call_split_test_int(1L))]),
    (
      "Threads::send",
      [
        call_split_test_arg(call_split_test_int(16L)),
        call_split_test_arg(call_split_test_string("msg")),
      ],
    ),
    ("Threads::recv", [call_split_test_arg(call_split_test_int(16L))]),
    (
      "Threads::spawn",
      [
        call_split_test_arg(call_split_test_string("noop")),
        call_split_test_arg(call_split_test_int(16L)),
      ],
    ),
    ("Threads::wait", [call_split_test_arg(call_split_test_int(1L))]),
  ]
  for case in cases {
    let (name, args) = case
    let ctx = CodegenCtx::new(false, thread_backend_id="linear-local")
    let buf = ByteBuf::new()
    let handled = compile_call_builtin_pre_user(ctx, buf, name, args, false) catch {
      err => fail("\{name}: \{err.to_string()}")
    }
    assert_true(handled)
    assert_true(buf.len() > 0)
  }
}

///|
test "compile_call_builtin_pre_user lowers shared-atomic Threads spawn wait" {
  let cases : Array[(String, Array[@core.CallArg])] = [
    (
      "Threads::spawn",
      [
        call_split_test_arg(call_split_test_string("noop")),
        call_split_test_arg(call_split_test_int(16L)),
      ],
    ),
    ("Threads::wait", [call_split_test_arg(call_split_test_int(1L))]),
  ]
  for case in cases {
    let (name, args) = case
    let ctx = CodegenCtx::new(
      false,
      thread_backend_id="component-unsafe-os-threads",
    )
    let buf = ByteBuf::new()
    let handled = compile_call_builtin_pre_user(ctx, buf, name, args, false) catch {
      err => fail("\{name}: \{err.to_string()}")
    }
    assert_true(handled)
    assert_true(buf.len() > 0)
  }
}

///|
test "shared thread builder grow avoids heap tip in-place path" {
  let ctx = CodegenCtx::new(
    false,
    thread_backend_id="component-unsafe-os-threads",
  )
  ctx.use_heap_global = true
  ctx.heap_global = 0
  ctx.heap_local = alloc_temp_local(ctx)
  let ptr_local = alloc_temp_local(ctx)
  let buf = ByteBuf::new()
  emit_builder_grow_check(ctx, buf, ptr_local, 4)
  let bytes = buf.to_bytes()
  assert_true(call_split_bytes_contains_atomic_subop(bytes, 0x1e))
  assert_false(call_split_bytes_contains_opcode(bytes, b'\x46'))
}

///|
test "shared thread builder bulk grow avoids heap tip in-place path" {
  let ctx = CodegenCtx::new(
    false,
    thread_backend_id="component-unsafe-os-threads",
  )
  ctx.use_heap_global = true
  ctx.heap_global = 0
  ctx.heap_local = alloc_temp_local(ctx)
  let ptr_local = alloc_temp_local(ctx)
  let additional_count_local = alloc_temp_local(ctx)
  let buf = ByteBuf::new()
  emit_builder_bulk_grow_check(ctx, buf, ptr_local, additional_count_local, 4)
  let bytes = buf.to_bytes()
  assert_true(call_split_bytes_contains_atomic_subop(bytes, 0x1e))
  assert_false(call_split_bytes_contains_opcode(bytes, b'\x46'))
}

///|
test "shared thread cabi_realloc uses cmpxchg for dynamic alignment" {
  let ctx = CodegenCtx::new(
    false,
    thread_backend_id="component-unsafe-os-threads",
  )
  ctx.use_heap_global = true
  ctx.heap_global = 0
  let func = compile_cabi_realloc_function(ctx) catch {
    err => fail(err.to_string())
  }
  let bytes = Bytes::from_array(func.body)
  assert_true(call_split_bytes_contains_atomic_subop(bytes, 0x48))
  assert_false(call_split_bytes_contains_atomic_subop(bytes, 0x1e))
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
test "scan_needs_expr enables fs and heap for Json::parse" {
  let ctx = CodegenCtx::new(false)
  let expr = call_split_test_call("Json::parse", [
    call_split_test_arg(call_split_test_string("{}")),
  ])
  scan_needs_expr(ctx, expr)
  assert_true(ctx.need_fs)
  assert_true(ctx.need_heap)
  assert_true(ctx.need_json_host_parse)
}

///|
test "scan_needs_expr enables targeted json host imports" {
  let ctx = CodegenCtx::new(false)
  let get_expr = call_split_test_call("Json::get", [
    call_split_test_arg(call_split_test_string("{}")),
    call_split_test_arg(call_split_test_string("name")),
  ])
  let string_expr = call_split_test_call("Json::string", [
    call_split_test_arg(call_split_test_string("\"ok\"")),
  ])
  scan_needs_expr(ctx, get_expr)
  scan_needs_expr(ctx, string_expr)
  assert_true(ctx.need_fs)
  assert_true(ctx.need_heap)
  assert_true(ctx.need_json_host_get)
  assert_true(ctx.need_json_host_string)
  assert_false(ctx.need_json_host_parse)
  assert_false(ctx.need_json_host_stringify)
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
test "needs_heap_expr returns false for string literal (S7: pre-interned)" {
  let ctx = CodegenCtx::new(false)
  assert_false(needs_heap_expr(ctx, call_split_test_string("x")))
}

///|
test "needs_heap_expr returns true for multivalue user call" {
  let ctx = CodegenCtx::new(false)
  ctx.fn_multivalue_results["mv_fn"] = [ValueKind::I64, ValueKind::I64]
  let expr = call_split_test_call("mv_fn", [])
  assert_true(needs_heap_expr(ctx, expr))
}

///|
test "needs_heap_expr returns true for named closure with captures" {
  let ctx = CodegenCtx::new(false)
  let span = call_split_test_span()
  let params : Array[@core.FuncParam] = []
  let key = span_key_named(Some("captured"), span, params)
  ctx.fn_closure_captures[key] = ["outer"]
  let expr = @core.Expr::Fn(
    type_params=[],
    type_bounds={},
    params~,
    ret=Some(@core.Type::Int),
    effects=[],
    body=@core.Module::{ stmts: [] },
    span~,
  )
  assert_true(needs_heap_expr(ctx, expr))
}

///|
test "scan_needs_stmt registers struct fields as known record fields" {
  let ctx = CodegenCtx::new(false)
  let field = @core.StructField::{
    name: "name",
    ty: @core.Type::String,
    is_mut: false,
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
