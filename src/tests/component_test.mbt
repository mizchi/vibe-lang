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
test "component wit includes wasi http client imports when used" {
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
  assert_true(String::contains(wit, "import wasi:http/client@0.3.0-draft;"))
  assert_false(String::contains(wit, "import wasi:http/handler@0.3.0-draft;"))
  assert_true(String::contains(wit, "export run: func() -> s64;"))
}

///|
test "component wit includes wasi http handler imports when server builtins are used" {
  let db = VibeDb::new()
  let src =
    #|let run = () -> Int with {Net} {
    #|  let listener = http_listen(8080)
    #|  let req = http_accept(listener)
    #|  let method = http_request_method(req)
    #|  let _ = http_request_url(req)
    #|  let _ = http_request_header(req, "x-test")
    #|  let _ = http_request_body(req)
    #|  http_respond(req, 200, "", "")
    #|  string_length(method)
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
  assert_true(String::contains(wit, "export wasi:http/handler@0.3.0-draft;"))
  assert_false(String::contains(wit, "import wasi:http/client@0.3.0-draft;"))
  assert_false(String::contains(wit, "import wasi:http/handler@0.3.0-draft;"))
  assert_true(String::contains(wit, "export run: func() -> s64;"))
}

///|
test "component wasm instantiation carries import args when core has imports" {
  let db = VibeDb::new()
  let src =
    #|let run = () -> Int with {Stdout} {
    #|  stdout_write_char(65)
    #|  1
    #|}
    #|run()
  db.set_source("main", src)
  let wasm = try compile_module_component(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(component_has_instantiate_with_non_zero_args(wasm))
}

///|
test "component wasm uses stable func imports for stdio" {
  let db = VibeDb::new()
  let src =
    #|let run = () -> Int with {Stdout} {
    #|  stdout_write_char(65)
    #|  1
    #|}
    #|run()
  db.set_source("main", src)
  let wasm = try compile_module_component(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(component_bytes_contains_ascii(wasm, "import-0"))
  assert_true(component_bytes_contains_ascii(wasm, "import-1"))
  assert_true(component_bytes_contains_ascii(wasm, "wasi:cli/stdout@0.2.0"))
  assert_true(component_bytes_contains_ascii(wasm, "wasi:io/streams@0.2.0"))
  assert_false(component_bytes_contains_ascii(wasm, "core-import-"))
}

///|
test "component wasm uses stable func imports for http host imports" {
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
  let wasm = try
    compile_module_component(db, "main", http_host_imports=true)
  catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(component_bytes_contains_ascii(wasm, "import-0"))
  assert_true(component_bytes_contains_ascii(wasm, "vibe:http"))
  assert_false(component_bytes_contains_ascii(wasm, "core-import-"))
}

///|
fn component_has_instantiate_with_non_zero_args(bytes : Bytes) -> Bool {
  let arr = bytes.to_array()
  if arr.length() < 8 {
    return false
  }
  let mut i = 8
  while i < arr.length() {
    let section_id = arr[i].to_int()
    i += 1
    let (section_size, after_size) = read_uleb_u32(arr, i)
    i = after_size
    let section_end = i + section_size
    if section_end > arr.length() {
      return false
    }
    if section_id == 0x02 {
      let mut j = i
      let (count, after_count) = read_uleb_u32(arr, j)
      j = after_count
      for _ in 0..<count {
        if j >= section_end {
          break
        }
        let kind = arr[j].to_int()
        j += 1
        match kind {
          0x00 => {
            let (_, after_module_idx) = read_uleb_u32(arr, j)
            j = after_module_idx
            let (arg_count, after_args_count) = read_uleb_u32(arr, j)
            j = after_args_count
            if arg_count > 0 {
              return true
            }
            for _ in 0..<arg_count {
              let (_, after_name) = read_name(arr, j)
              j = after_name
              if j < section_end {
                j += 1
              }
              let (_, after_idx) = read_uleb_u32(arr, j)
              j = after_idx
            }
          }
          0x01 => {
            let (export_count, after_export_count) = read_uleb_u32(arr, j)
            j = after_export_count
            for _ in 0..<export_count {
              let (_, after_name) = read_name(arr, j)
              j = after_name
              if j < section_end {
                j += 1
              }
              let (_, after_idx) = read_uleb_u32(arr, j)
              j = after_idx
            }
          }
          _ => break
        }
      }
    }
    i = section_end
  }
  false
}

///|
fn read_uleb_u32(arr : Array[Byte], start : Int) -> (Int, Int) {
  let mut value = 0
  let mut shift = 0
  let mut i = start
  while i < arr.length() {
    let b = arr[i].to_int()
    value = value | ((b & 0x7f) << shift)
    i += 1
    if (b & 0x80) == 0 {
      return (value, i)
    }
    shift += 7
  }
  (value, i)
}

///|
fn read_name(arr : Array[Byte], start : Int) -> (String, Int) {
  let (len, after_len) = read_uleb_u32(arr, start)
  let end = after_len + len
  if end > arr.length() {
    return ("", arr.length())
  }
  ("", end)
}

///|
fn component_bytes_contains_ascii(bytes : Bytes, needle : String) -> Bool {
  let hay = bytes.to_array()
  let pat = @utf8.encode(needle).to_array()
  if pat.length() == 0 {
    return true
  }
  let limit = hay.length() - pat.length()
  if limit < 0 {
    return false
  }
  for i in 0..<=limit {
    let mut ok = true
    for j in 0..<pat.length() {
      if hay[i + j] != pat[j] {
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
