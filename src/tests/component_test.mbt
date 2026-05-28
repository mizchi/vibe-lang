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
    #|export let _start = () -> Int with {Stdout, Stdin} {
    #|  {
    #|    Stdout::write_char(65)
    #|    Stdin::read_char()
    #|  }
    #|}
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
    #|export let _start = () -> Int with {Stdout, Stdin} {
    #|  {
    #|    Stdout::write_stream("hello")
    #|    Stdin::read_stream(16)
    #|    1
    #|  }
    #|}
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
test "component wit includes vibe env import when Env::get is used" {
  let db = VibeDb::new()
  let src =
    #|export let _start = () -> Int with {Env} {
    #|  let home = Env::get("HOME")
    #|  String::length(home)
    #|}
  db.set_source("main", src)
  let wit = try
    generate_module_component_wit(db, "main", "local:main", "main")
  catch {
    e => fail("wit error: " + e.to_string())
  } noraise {
    w => w
  }
  assert_true(String::contains(wit, "world main"))
  assert_true(String::contains(wit, "import vibe: interface {"))
  assert_true(String::contains(wit, "env-get: func(name: s32) -> s32;"))
  assert_true(String::contains(wit, "export run: func() -> s64;"))
}

///|
test "component wit includes vibe args imports when Env::args is used" {
  let db = VibeDb::new()
  let src =
    #|export let _start = () -> Int with {Env} {
    #|  if Env::args_len() > 0 {
    #|    String::length(Env::args_get(0))
    #|  } else {
    #|    0
    #|  }
    #|}
  db.set_source("main", src)
  let wit = try
    generate_module_component_wit(db, "main", "local:main", "main")
  catch {
    e => fail("wit error: " + e.to_string())
  } noraise {
    w => w
  }
  assert_true(String::contains(wit, "world main"))
  assert_true(String::contains(wit, "import vibe: interface {"))
  assert_true(String::contains(wit, "args-len: func() -> s64;"))
  assert_true(String::contains(wit, "args-get: func(index: s64) -> s32;"))
  assert_true(String::contains(wit, "export run: func() -> s64;"))
}

///|
test "component wit includes preview2 filesystem imports when fs builtins are used" {
  let db = VibeDb::new()
  let src =
    #|export let _start = () -> Int with {Fs} {
    #|  if Fs::exists("foo.txt") {
    #|    String::length(Fs::read_file("foo.txt"))
    #|  } else {
    #|    0
    #|  }
    #|}
  db.set_source("main", src)
  let wit = try
    generate_module_component_wit(db, "main", "local:main", "main")
  catch {
    e => fail("wit error: " + e.to_string())
  } noraise {
    w => w
  }
  assert_true(String::contains(wit, "world main"))
  assert_true(String::contains(wit, "import wasi:filesystem/types@0.2.6;"))
  assert_true(String::contains(wit, "import wasi:filesystem/preopens@0.2.6;"))
  assert_false(String::contains(wit, "import wasi:filesystem/types@0.3.0;"))
}

///|
test "component wit includes preview2 metadata hash imports when Fs::stat_token is used" {
  let db = VibeDb::new()
  db.set_source(
    "main", "export let _start = () -> Int with {Fs} { Fs::stat_token(\"foo.txt\") }",
  )
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("wasm error: " + e.to_string())
  } noraise {
    b => b
  }
  let wit = try
    generate_module_component_wit(db, "main", "local:main", "main")
  catch {
    e => fail("wit error: " + e.to_string())
  } noraise {
    w => w
  }
  assert_true(String::contains(wit, "import wasi:filesystem/types@0.2.6;"))
  assert_true(String::contains(wit, "import wasi:filesystem/preopens@0.2.6;"))
  assert_true(
    component_bytes_contains_ascii(wasm, "[method]descriptor.metadata-hash-at"),
  )
}

///|
test "component wit scans for-in bodies for host imports" {
  let db = VibeDb::new()
  let src =
    #|export let _start = () -> Int with {Sleep, Async} {
    #|  let _ = for x in [1, 2] {
    #|    sleep(x)
    #|    x
    #|  }
    #|  0
    #|}
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
    #|export let _start = () -> Int with {Net} {
    #|  let req = Http::request("GET", "https://example.com", "", "")
    #|  let status = Http::response_status(req)
    #|  Http::close(req)
    #|  status
    #|}
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
    #|export let _start = () -> Int with {Net} {
    #|  let listener = Http::listen(8080)
    #|  let req = Http::accept(listener)
    #|  let method = Http::request_method(req)
    #|  let _ = Http::request_url(req)
    #|  let _ = Http::request_header(req, "x-test")
    #|  let _ = Http::request_body(req)
    #|  Http::respond(req, 200, "", "")
    #|  String::length(method)
    #|}
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
    #|export let _start = () -> Int with {Stdout} {
    #|  Stdout::write_char(65)
    #|  1
    #|}
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
    #|export let _start = () -> Int with {Stdout} {
    #|  Stdout::write_char(65)
    #|  1
    #|}
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
test "component wasm uses wasi http shim imports for http host imports" {
  let db = VibeDb::new()
  let src =
    #|export let _start = () -> Int with {Net} {
    #|  let req = Http::request("GET", "https://example.com", "", "")
    #|  let status = Http::response_status(req)
    #|  Http::close(req)
    #|  status
    #|}
  db.set_source("main", src)
  let wasm = try
    compile_module_component(db, "main", http_host_imports=true)
  catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(component_bytes_contains_ascii(wasm, "import-0"))
  assert_true(
    component_bytes_contains_ascii(wasm, "wasi:http/client@0.3.0-draft"),
  )
  assert_true(
    component_bytes_contains_ascii(wasm, "wasi:http/types@0.3.0-draft"),
  )
  assert_true(component_bytes_contains_ascii(wasm, "send"))
  assert_true(component_bytes_contains_ascii(wasm, "response-status"))
  assert_true(component_bytes_contains_ascii(wasm, "[drop]response"))
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
  let bytes : Array[Byte] = []
  for i in after_len..<end {
    bytes.push(arr[i])
  }
  (@utf8.decode_lossy(Bytes::from_array(bytes)), end)
}

///|
fn array_contains_string(arr : Array[String], needle : String) -> Bool {
  for item in arr {
    if item == needle {
      return true
    }
  }
  false
}

///|
fn component_export_names(bytes : Bytes) -> Array[String] {
  let arr = bytes.to_array()
  let out : Array[String] = []
  let mut i = 8
  while i < arr.length() {
    let section_id = arr[i].to_int()
    i += 1
    let (section_size, after_size) = read_uleb_u32(arr, i)
    let section_start = after_size
    let section_end = section_start + section_size
    if section_end > arr.length() {
      break
    }
    if section_id == 0x0b {
      let mut j = section_start
      let (count, after_count) = read_uleb_u32(arr, j)
      j = after_count
      for _ in 0..<count {
        if j >= section_end {
          break
        }
        if arr[j].to_int() == 0x00 {
          j += 1
        }
        let (name, after_name) = read_name(arr, j)
        j = after_name
        out.push(name)
        if j < section_end {
          j += 1
        }
        let (_, after_idx) = read_uleb_u32(arr, j)
        j = after_idx
        let (_, after_desc) = read_uleb_u32(arr, j)
        j = after_desc
      }
    }
    i = section_end
  }
  out
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

///|
test "P3 handler: component_string_lift_auto exports handler" {
  let db = VibeDb::new()
  let src =
    #|export let handler = (method: String, url: String) -> Int {
    #|  if String::equals(method, "GET") { 200 } else { 405 }
    #|}
    #|handler("GET", "/")
  db.set_source("main", src)
  let wasm = try compile_module_component_string_lift_auto(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  // Component should export "handler" function
  assert_true(component_bytes_contains_ascii(wasm, "handler"))
  // Should have component header
  assert_eq(wasm[0].to_int(), 0x00) // \0
  assert_eq(wasm[1].to_int(), 0x61) // a
  assert_eq(wasm[4].to_int(), 0x0d) // component version
}

///|
test "P3 handler: component_string_lift_auto kebab-cases snake_case export names" {
  let db = VibeDb::new()
  let src =
    #|export let compile_cli_request = (method: String, url: String) -> Int {
    #|  if String::equals(method, url) { 1 } else { 0 }
    #|}
    #|compile_cli_request("GET", "GET")
  db.set_source("main", src)
  let wasm = try compile_module_component_string_lift_auto(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  let names = component_export_names(wasm)
  assert_true(array_contains_string(names, "compile-cli-request"))
  assert_false(array_contains_string(names, "compile_cli_request"))
}

///|
test "P3 handler: component_string_lift_auto kebab-cases snake_case parameter names" {
  let db = VibeDb::new()
  let src =
    #|export let run_cli_request = (input_path: String, output_path: String) -> Int {
    #|  if String::equals(input_path, output_path) { 1 } else { 0 }
    #|}
    #|run_cli_request("GET", "GET")
  db.set_source("main", src)
  let wasm = try compile_module_component_string_lift_auto(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(component_bytes_contains_ascii(wasm, "input-path"))
  assert_true(component_bytes_contains_ascii(wasm, "output-path"))
  assert_false(component_bytes_contains_ascii(wasm, "input_path"))
  assert_false(component_bytes_contains_ascii(wasm, "output_path"))
}

///|
test "P3 handler: component_string_lift_auto supports annotated function type" {
  let db = VibeDb::new()
  let src =
    #|export let compile_cli_request: (String, String) -> Int = (source, request) -> {
    #|  if String::equals(source, request) { 1 } else { 0 }
    #|}
    #|compile_cli_request("GET", "GET")
  db.set_source("main", src)
  let wasm = try compile_module_component_string_lift_auto(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  let names = component_export_names(wasm)
  assert_true(array_contains_string(names, "compile-cli-request"))
}

///|
test "P3 handler: component_string_lift_auto supports annotated string result" {
  let db = VibeDb::new()
  let src =
    #|export let check_source_report: (String) -> String = (source) -> {
    #|  String::concat("ok:", source)
    #|}
  db.set_source("main", src)
  let wasm = try compile_module_component_string_lift_auto(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(component_bytes_contains_ascii(wasm, "check-source-report"))
  assert_true(component_bytes_contains_ascii(wasm, "source"))
}

///|
test "P3 handler: component_string_lift_auto injects run_init when run export exists" {
  let db = VibeDb::new()
  let src =
    #|export let handler = (method: String, url: String) -> Int {
    #|  if String::equals(method, "GET") { 200 } else { 405 }
    #|}
    #|export let _start = () -> Int { handler("GET", "/") }
  db.set_source("main", src)
  let wasm = try compile_module_component_string_lift_auto(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(component_bytes_contains_ascii(wasm, "run_init"))
}

///|
test "P3 handler: async component func type (0x43) prototype" {
  let db = VibeDb::new()
  let src =
    #|export let handler = (method: String, url: String) -> Int {
    #|  if String::equals(method, "GET") { 200 } else { 405 }
    #|}
    #|handler("GET", "/")
  db.set_source("main", src)
  let compiled = try compile_module(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    c => c
  }
  let bundled = @runtime_compile.bundle_for_wasm(db, "main", compiled.ast)
  let core_wasm = try
    @codegen.emit_module_wasm_with_options(
      bundled,
      @codegen.wasm_emit_options(force_cabi_realloc=true),
    )
  catch {
    e => fail("wasm gen error: " + e.to_string())
  } noraise {
    w => w
  }
  let async_component = @codegen.emit_component_wasm_with_string_lift(
    core_wasm,
    "handler",
    "handler",
    2,
    param_names=["method", "url"],
    is_async=true,
  )
  // Component header
  assert_eq(async_component[0].to_int(), 0x00) // \0
  assert_eq(async_component[4].to_int(), 0x0d) // component version
  // Should contain 0x43 (async func type) somewhere in the binary
  let bytes = async_component
  let mut found_async = false
  for i in 0..<(bytes.length() - 2) {
    // Look for 0x43 followed by param count 2
    if bytes[i].to_int() == 0x43 && bytes[i + 1].to_int() == 0x02 {
      found_async = true
      break
    }
  }
  assert_true(found_async)
}
