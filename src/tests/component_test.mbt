///|
/// Tests for Component Model WASM output
test "component wasm header" {
  let db = VibeDb::new()
  db.set_source("main", "let x = 1\nx")
  let wasm = try compile_module_component(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  // Check component magic and version
  assert_true(wasm.length() >= 8)
  assert_eq(wasm[0].to_int(), 0x00) // \0
  assert_eq(wasm[1].to_int(), 0x61) // a
  assert_eq(wasm[2].to_int(), 0x73) // s
  assert_eq(wasm[3].to_int(), 0x6d) // m
  // Component version 13
  assert_eq(wasm[4].to_int(), 0x0d)
  assert_eq(wasm[5].to_int(), 0x00)
  assert_eq(wasm[6].to_int(), 0x01)
  assert_eq(wasm[7].to_int(), 0x00)
}

///|
test "component wasm contains core module" {
  let db = VibeDb::new()
  db.set_source("main", "let x = 42\nx")
  let wasm = try compile_module_component(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  // Component should be larger than core WASM due to wrapping
  let core = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() > core.length())
}

///|
test "component wasm size overhead" {
  let db = VibeDb::new()
  db.set_source("main", "let x = 1\nx")
  let core = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  let component = try compile_module_component(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  // Component overhead should be small (< 50 bytes for wrapping)
  let overhead = component.length() - core.length()
  assert_true(overhead > 0)
  assert_true(overhead < 100) // Reasonable overhead bound
}

///|
test "component wasm compile with wite opt level" {
  let db = VibeDb::new()
  db.set_source("main", "let x = 1\nx")
  let wasm = try
    compile_module_component_with_opt_level(db, "main", opt_level=Some("-O3"))
  catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_eq(wasm[0].to_int(), 0x00)
  assert_eq(wasm[1].to_int(), 0x61)
  assert_eq(wasm[2].to_int(), 0x73)
  assert_eq(wasm[3].to_int(), 0x6d)
  assert_eq(wasm[4].to_int(), 0x0d)
}

///|
test "component wit includes wasi stdio imports when used" {
  let db = VibeDb::new()
  let src =
    #|let run = () -> Int with {Stdout, Stdin} {
    #|  {
    #|    stdout_write_char(65)
    #|    stdin_read_char()
    #|  }
    #|}
    #|run()
  db.set_source("main", src)
  let wit = try
    generate_module_component_wit(db, "main", "local:main", "main")
  catch {
    e => fail("wit error: " + e.to_string())
  } noraise {
    w => w
  }
  assert_true(String::contains(wit, "world main"))
  assert_true(String::contains(wit, "import wasi:cli/stdout@0.2.0;"))
  assert_true(String::contains(wit, "import wasi:cli/stdin@0.2.0;"))
  assert_true(String::contains(wit, "import wasi:io/streams@0.2.0;"))
  assert_false(String::contains(wit, "stdout-write-char"))
  assert_false(String::contains(wit, "stdin-read-char"))
  assert_true(String::contains(wit, "export run: func() -> s64;"))
}

///|
test "component wit includes wasi stdio imports for stream builtins" {
  let db = VibeDb::new()
  let src =
    #|let run = () -> Int with {Stdout, Stdin} {
    #|  {
    #|    stdout_write_stream("hello")
    #|    stdin_read_stream(16)
    #|    1
    #|  }
    #|}
    #|run()
  db.set_source("main", src)
  let wit = try
    generate_module_component_wit(db, "main", "local:main", "main")
  catch {
    e => fail("wit error: " + e.to_string())
  } noraise {
    w => w
  }
  assert_true(String::contains(wit, "world main"))
  assert_true(String::contains(wit, "import wasi:cli/stdout@0.2.0;"))
  assert_true(String::contains(wit, "import wasi:cli/stdin@0.2.0;"))
  assert_true(String::contains(wit, "import wasi:io/streams@0.2.0;"))
  assert_true(String::contains(wit, "export run: func() -> s64;"))
}

///|
test "component wit scans for-in bodies for host imports" {
  let db = VibeDb::new()
  let src =
    #|let run = () -> Int with {Sleep, Async} {
    #|  let _ = for x in [1, 2] {
    #|    sleep(x)
    #|    x
    #|  }
    #|  0
    #|}
    #|run()
  db.set_source("main", src)
  let wit = try
    generate_module_component_wit(db, "main", "local:main", "main")
  catch {
    e => fail("wit error: " + e.to_string())
  } noraise {
    w => w
  }
  assert_true(String::contains(wit, "world main"))
  assert_true(String::contains(wit, "sleep: func(ms: s32);"))
  assert_true(String::contains(wit, "export run: func() -> s64;"))
}

///|
test "component wit includes wasi http imports when used" {
  let db = VibeDb::new()
  let src =
    #|let run = () -> Int with {Net} {
    #|  let req = http_request("GET", "https://example.com", "", "")
    #|  let status = http_response_status(req)
    #|  http_close(req)
    #|  status
    #|}
    #|run()
  db.set_source("main", src)
  let wit = try
    generate_module_component_wit(db, "main", "local:main", "main")
  catch {
    e => fail("wit error: " + e.to_string())
  } noraise {
    w => w
  }
  assert_true(String::contains(wit, "world main"))
  assert_true(String::contains(wit, "import wasi:http/types@0.3.0-draft;"))
  assert_true(String::contains(wit, "import wasi:http/handler@0.3.0-draft;"))
  assert_true(String::contains(wit, "export run: func() -> s64;"))
}
