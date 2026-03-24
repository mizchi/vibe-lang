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
test "compile_module_wasm_with_opt_level_profiled reuses wasm artifact cache" {
  let db = @runtime.VibeDb::new()
  db.set_source("main", "let main = () -> Int { 1 + 2 }")
  let (bytes1, profile1) = compile_module_wasm_with_opt_level_profiled(
    db,
    "main",
    no_dce=true,
  )
  let (bytes2, profile2) = compile_module_wasm_with_opt_level_profiled(
    db,
    "main",
    no_dce=true,
  )
  assert_eq(bytes1, bytes2)
  assert_true(profile1.emit_us > 0)
  assert_eq(profile2.emit_us, 0)
  assert_eq(profile2.optimize_us, 0)
}

///|
test "compile_module_wasm_with_opt_level_profiled separates artifact cache by mode" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "cache_mode_probe", "let cache_mode_probe_unique = () -> Int { 1 + 2 }",
  )
  let (_, profile1) = compile_module_wasm_with_opt_level_profiled(
    db,
    "cache_mode_probe",
    no_dce=true,
  )
  let (_, profile2) = compile_module_wasm_with_opt_level_profiled(
    db,
    "cache_mode_probe",
    no_dce=true,
    library_mode=true,
  )
  assert_true(profile1.emit_us > 0)
  assert_true(profile2.emit_us > 0)
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
  let mut saw_helper = false
  for li in linked_imports {
    if li.module_name == "lib" && li.func_name == "helper" {
      assert_eq(li.param_count, 0)
      assert_eq(li.return_count, 1)
      saw_helper = true
    }
  }
  assert_true(saw_helper)
  assert_true(bytes_contains_ascii(main_wasm, "lib"))
  assert_true(bytes_contains_ascii(main_wasm, "helper"))
  assert_true(bytes_contains_ascii(main_wasm, "memory"))
  assert_true(bytes_contains_ascii(main_wasm, "__heap_ptr"))
  assert_true(bytes_contains_ascii(lib_wasm, "helper"))
  assert_true(bytes_contains_ascii(lib_wasm, "memory"))
  assert_true(bytes_contains_ascii(lib_wasm, "__heap_ptr"))
}

///|
test "linked compile uses prelude_core library for scalar helpers" {
  let db = @runtime.VibeDb::new()
  db.set_source("main", "option_is_none(None)")
  let (main_wasm, linked_imports) = try
    compile_module_wasm_linked(db, "main")
  catch {
    e => fail("linked compile error: " + e.to_string())
  } noraise {
    v => v
  }
  let mut saw_option_is_none = false
  let mut saw_option_is_some = false
  let mut saw_not = false
  let mut saw_option_map = false
  for li in linked_imports {
    if li.module_name == @runtime.prelude_core_module_name() {
      if li.func_name == "option_is_none" {
        saw_option_is_none = true
      }
      if li.func_name == "option_is_some" {
        saw_option_is_some = true
      }
      if li.func_name == "not" {
        saw_not = true
      }
      if li.func_name == "option_map" {
        saw_option_map = true
      }
    }
  }
  let prelude_lib_wasm = try
    emit_library_module_wasm(@runtime.prelude_core_library_module())
  catch {
    e => fail("prelude core library compile error: " + e.to_string())
  } noraise {
    v => v
  }
  assert_true(saw_option_is_none)
  assert_true(saw_option_is_some)
  assert_true(saw_not)
  assert_false(saw_option_map)
  assert_true(
    bytes_contains_ascii(main_wasm, @runtime.prelude_core_module_name()),
  )
  assert_true(bytes_contains_ascii(prelude_lib_wasm, "option_is_none"))
  assert_true(bytes_contains_ascii(prelude_lib_wasm, "option_is_some"))
  assert_true(bytes_contains_ascii(prelude_lib_wasm, "not"))
  assert_false(bytes_contains_ascii(prelude_lib_wasm, "option_map"))
  assert_false(bytes_contains_ascii(prelude_lib_wasm, "add"))
}

///|
test "linked compile inlines HOF exports but keeps scalar exports linked" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "./lib.vibe",
    (
      #|export let add1 = (x : Int) -> Int { x + 1 }
      #|export let apply_twice = (f : (Int) -> Int, x : Int) -> Int {
      #|  f(f(x))
      #|}
    ),
  )
  db.set_source(
    "main",
    (
      #|import ./lib.vibe { add1, apply_twice }
      #|apply_twice(add1, 40)
    ),
  )
  let (main_wasm, linked_imports) = try
    compile_module_wasm_linked(db, "main")
  catch {
    e => fail("linked compile error: " + e.to_string())
  } noraise {
    v => v
  }
  let mut saw_add1 = false
  let mut saw_apply_twice = false
  for li in linked_imports {
    if li.module_name == "lib" && li.func_name == "add1" {
      saw_add1 = true
    }
    if li.module_name == "lib" && li.func_name == "apply_twice" {
      saw_apply_twice = true
    }
  }
  assert_true(saw_add1)
  assert_false(saw_apply_twice)
  assert_true(bytes_contains_ascii(main_wasm, "lib"))
  assert_true(bytes_contains_ascii(main_wasm, "add1"))
  assert_false(bytes_contains_ascii(main_wasm, "apply_twice"))
}

///|
test "linked compile keeps scalar re-exports linked when HOF re-exports are inlined" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "./lib.vibe",
    (
      #|export let add1 = (x : Int) -> Int { x + 1 }
      #|export let apply_twice = (f : (Int) -> Int, x : Int) -> Int {
      #|  f(f(x))
      #|}
    ),
  )
  db.set_source("./mid.vibe", "export ./lib.vibe { add1, apply_twice }")
  db.set_source(
    "main",
    (
      #|import ./mid.vibe { add1, apply_twice }
      #|apply_twice(add1, 40)
    ),
  )
  let (main_wasm, linked_imports) = try
    compile_module_wasm_linked(db, "main")
  catch {
    e => fail("linked compile error: " + e.to_string())
  } noraise {
    v => v
  }
  let mut saw_add1 = false
  let mut saw_apply_twice = false
  for li in linked_imports {
    if li.module_name == "mid" && li.func_name == "add1" {
      saw_add1 = true
    }
    if li.module_name == "mid" && li.func_name == "apply_twice" {
      saw_apply_twice = true
    }
  }
  assert_true(saw_add1)
  assert_false(saw_apply_twice)
  assert_true(bytes_contains_ascii(main_wasm, "mid"))
  assert_true(bytes_contains_ascii(main_wasm, "add1"))
  assert_false(bytes_contains_ascii(main_wasm, "apply_twice"))
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
