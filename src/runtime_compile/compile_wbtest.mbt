///|

///|
fn bytes_contains_ascii(bytes : Bytes, needle : String) -> Bool {
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
test "compile_module keeps parse error variant" {
  let db = @runtime.VibeDb::new()
  db.set_source("main", "let x =")
  let result : Result[CompiledModule, CompileError] = try? compile_module(
    db, "main",
  )
  match result {
    Ok(_) => fail("expected parse error")
    Err(CompileError::Parse(_)) => ()
    Err(err) => fail("expected CompileError::Parse, got " + err.to_string())
  }
}

///|
test "compile_module cache reuses same key" {
  let db = @runtime.VibeDb::new()
  let before = compile_module_cache.val.length()
  let path = "cache-main-" + before.to_string()
  db.set_source(path, "let x = 1")
  let _ = compile_module(db, path)
  let after_first = compile_module_cache.val.length()
  let _ = compile_module(db, path)
  let after_second = compile_module_cache.val.length()
  assert_eq(after_first, before + 1)
  assert_eq(after_second, after_first)
}

///|
test "check_incompatible_server_builtins detects Http::listen" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let run = () -> Int with {Net} {
      #|  let listener = Http::listen(8080)
      #|  let req = Http::accept(listener)
      #|  Http::respond(req, 200, "", "ok")
      #|  0
      #|}
      #|run()
    ),
  )
  let compiled = compile_module(db, "main")
  let found = check_incompatible_server_builtins(compiled.ast)
  assert_true(found.contains("Http::listen"))
  assert_true(found.contains("Http::accept"))
  assert_true(found.contains("Http::respond"))
}

///|
test "check_incompatible_server_builtins passes handler pattern" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|export let handler = (method: String, url: String) -> Int {
      #|  if String::equals(method, "GET") { 200 } else { 405 }
      #|}
      #|handler("GET", "/")
    ),
  )
  let compiled = compile_module(db, "main")
  let found = check_incompatible_server_builtins(compiled.ast)
  assert_eq(found.length(), 0)
}

///|
test "component_string_lift_auto rejects server builtins" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|export let handler = (method: String, url: String) -> Int with {Net} {
      #|  let listener = Http::listen(8080)
      #|  let _ = Http::accept(listener)
      #|  200
      #|}
      #|handler("GET", "/")
    ),
  )
  let result : Result[Bytes, WasmCompileError] = try? compile_module_component_string_lift_auto(
    db, "main",
  )
  match result {
    Ok(_) => fail("expected error for incompatible builtins")
    Err(WasmCompileError::Optimize(msg)) =>
      assert_true(String::contains(msg, "incompatible"))
    Err(err) => fail("expected Optimize error, got " + err.to_string())
  }
}

///|
test "component_string_lift_auto kebab-cases snake_case export names" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|export let compile_cli_request = (method: String, url: String) -> Int {
      #|  if String::equals(method, url) { 1 } else { 0 }
      #|}
      #|compile_cli_request("GET", "GET")
    ),
  )
  let wasm = try compile_module_component_string_lift_auto(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(bytes_contains_ascii(wasm, "compile-cli-request"))
}

///|
test "compile_module_wasm_with_opt_level_profiled returns wasm and stage timings" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let add = (x : Int, y : Int) -> Int { x + y }
      #|add(20, 22)
    ),
  )
  let plain = try compile_module_wasm_with_opt_level(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    bytes => bytes
  }
  let (profiled, stage_profile) = try
    compile_module_wasm_with_opt_level_profiled(db, "main")
  catch {
    e => fail("profiled compile error: " + e.to_string())
  } noraise {
    value => value
  }
  assert_eq(profiled, plain)
  assert_true(stage_profile.module_us >= 0)
  assert_true(stage_profile.bundle_us >= 0)
  assert_true(stage_profile.emit_us >= 0)
  assert_true(stage_profile.optimize_us >= 0)
  assert_true(stage_profile.total_us >= 0)
}

///|
test "linked library mode exports heap ptr for static string helper" {
  let db = @runtime.VibeDb::new()
  db.set_source("./lib.vibe", "export let helper = () -> String { \"Hello\" }")
  db.set_source(
    "main", "import ./lib.vibe { helper }\nString::length(String::concat(helper(), \", world\"))",
  )
  let (main_wasm, linked_imports) = try
    compile_module_wasm_linked(db, "main")
  catch {
    e => fail("linked compile error: " + e.to_string())
  } noraise {
    v => v
  }
  let lib_wasm = try
    compile_module_wasm_with_opt_level(db, "./lib.vibe", library_mode=true)
  catch {
    e => fail("library compile error: " + e.to_string())
  } noraise {
    v => v
  }
  assert_eq(linked_imports.length(), 1)
  assert_eq(linked_imports[0].module_name, "lib")
  assert_eq(linked_imports[0].func_name, "helper")
  assert_eq(linked_imports[0].param_count, 0)
  assert_eq(linked_imports[0].return_count, 1)
  assert_true(bytes_contains_ascii(main_wasm, "lib"))
  assert_true(bytes_contains_ascii(main_wasm, "helper"))
  assert_true(bytes_contains_ascii(main_wasm, "memory"))
  assert_true(bytes_contains_ascii(main_wasm, "__heap_ptr"))
  assert_true(bytes_contains_ascii(lib_wasm, "helper"))
  assert_true(bytes_contains_ascii(lib_wasm, "memory"))
  assert_true(bytes_contains_ascii(lib_wasm, "__heap_ptr"))
}

///|
test "wasm_compile_profile_tsv emits compile substage rows" {
  let content = wasm_compile_profile_tsv(
    1000,
    2000,
    {
      module_us: 3000,
      bundle_us: 4000,
      emit_us: 5000,
      optimize_us: 6000,
      total_us: 18000,
    },
    7000,
    28000,
  )
  assert_true(String::contains(content, "stage\telapsed_ms\telapsed_us\n"))
  assert_true(String::contains(content, "compile_module\t3\t3000\n"))
  assert_true(String::contains(content, "bundle\t4\t4000\n"))
  assert_true(String::contains(content, "emit\t5\t5000\n"))
  assert_true(String::contains(content, "optimize\t6\t6000\n"))
  assert_true(String::contains(content, "compile\t18\t18000\n"))
  assert_true(String::contains(content, "write\t7\t7000\n"))
  assert_true(String::contains(content, "total\t28\t28000\n"))
}

///|
test "lower_top_level_tests_to_exprs wraps each test body in a function" {
  let source =
    #|let mut counter = 0
    #|test "a" {
    #|  counter = counter + 1
    #|}
    #|test "b" {
    #|  assert(eq(counter, 0))
    #|}
    #|0
  let ast = try @parser.parse_ast(source) catch {
    e => fail("parse error: " + e.to_string())
  } noraise {
    v => v
  }
  let lowered = lower_top_level_tests_to_exprs(ast)
  assert_eq(lowered.stmts.length(), 6)
  match lowered.stmts[0] {
    @core.Stmt::LetMut(name~, expr=@core.Expr::Int(value~, ..), ..) => {
      assert_eq(name, "counter")
      assert_eq(value, 0L)
    }
    _ => fail("expected mutable prelude to stay top-level")
  }
  match lowered.stmts[1] {
    @core.Stmt::Let(name~, expr=@core.Expr::Fn(body~, ret~, ..), ..) => {
      assert_eq(name, "__vibe_cov_test_0")
      match ret {
        Some(@core.Type::Int) => ()
        _ => fail("expected wrapped test function to return Int")
      }
      assert_eq(body.stmts.length(), 2)
      match body.stmts[1] {
        @core.Stmt::Expr(expr=@core.Expr::Int(value~, ..), ..) =>
          assert_eq(value, 0L)
        _ => fail("expected wrapped test function to append explicit 0")
      }
    }
    _ => fail("expected first wrapper function")
  }
  match lowered.stmts[2] {
    @core.Stmt::Expr(expr=@core.Expr::Call(name~, args~, ..), ..) => {
      assert_eq(name, "__vibe_cov_test_0")
      assert_eq(args.length(), 0)
    }
    _ => fail("expected first wrapper invocation")
  }
  match lowered.stmts[3] {
    @core.Stmt::Let(name~, expr=@core.Expr::Fn(body~, ..), ..) => {
      assert_eq(name, "__vibe_cov_test_1")
      assert_eq(body.stmts.length(), 2)
      match body.stmts[1] {
        @core.Stmt::Expr(expr=@core.Expr::Int(value~, ..), ..) =>
          assert_eq(value, 0L)
        _ => fail("expected second wrapped test function to append explicit 0")
      }
    }
    _ => fail("expected second wrapper function")
  }
  match lowered.stmts[4] {
    @core.Stmt::Expr(expr=@core.Expr::Call(name~, args~, ..), ..) => {
      assert_eq(name, "__vibe_cov_test_1")
      assert_eq(args.length(), 0)
    }
    _ => fail("expected second wrapper invocation")
  }
  match lowered.stmts[5] {
    @core.Stmt::Expr(expr=@core.Expr::Int(value~, ..), ..) =>
      assert_eq(value, 0L)
    _ => fail("expected non-test expr to stay top-level")
  }
}

///|
test "lower_top_level_tests_to_exprs keeps imports and helpers top-level" {
  let source =
    #|import ./helper.vibe { helper }
    #|let support = () -> Int { 1 }
    #|test "a" {
    #|  assert(helper(support()) == 2)
    #|}
  let ast = try @parser.parse_ast(source) catch {
    e => fail("parse error: " + e.to_string())
  } noraise {
    v => v
  }
  let lowered = lower_top_level_tests_to_exprs(ast)
  assert_eq(lowered.stmts.length(), 4)
  match lowered.stmts[0] {
    @core.Stmt::Import(..) => ()
    _ => fail("expected import to remain top-level")
  }
  match lowered.stmts[1] {
    @core.Stmt::Let(name~, expr=@core.Expr::Fn(..), ..) =>
      assert_eq(name, "support")
    _ => fail("expected helper definition to remain top-level")
  }
  match lowered.stmts[2] {
    @core.Stmt::Let(name~, expr=@core.Expr::Fn(body~, ..), ..) => {
      assert_eq(name, "__vibe_cov_test_0")
      assert_eq(body.stmts.length(), 2)
      match body.stmts[0] {
        @core.Stmt::Expr(..) => ()
        _ => fail("expected original test body inside wrapper function")
      }
    }
    _ => fail("expected lowered test wrapper")
  }
  match lowered.stmts[3] {
    @core.Stmt::Expr(expr=@core.Expr::Call(name~, args~, ..), ..) => {
      assert_eq(name, "__vibe_cov_test_0")
      assert_eq(args.length(), 0)
    }
    _ => fail("expected wrapper invocation")
  }
}
