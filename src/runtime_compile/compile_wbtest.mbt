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
    compile_module_wasm_with_opt_level_profiled(db, "main") catch {
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
