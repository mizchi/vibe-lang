///|
/// Tests for xsh wasm codegen
test "xsh wasm header" {
  let db = XshDb::new()
  db.set_source("main", "let x = 1\nx")
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_eq(wasm[0].to_int(), 0x00)
  assert_eq(wasm[1].to_int(), 0x61)
  assert_eq(wasm[2].to_int(), 0x73)
  assert_eq(wasm[3].to_int(), 0x6d)
}

///|
test "xsh wasm compile with wite opt level" {
  let db = XshDb::new()
  db.set_source("main", "let x = 1\nx")
  let wasm = try
    compile_module_wasm_with_opt_level(db, "main", opt_level=Some("-Oz"))
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
}

///|
test "xsh wasm compile rejects unknown wite opt level" {
  let db = XshDb::new()
  db.set_source("main", "let x = 1\nx")
  let result : Result[Bytes, WasmCompileError] = try? compile_module_wasm_with_opt_level(
    db,
    "main",
    opt_level=Some("-Ox"),
  )
  match result {
    Ok(_) => fail("expected optimize error")
    Err(err) =>
      assert_true(
        err
        .to_string()
        .contains(
          "unsupported wite optimize level -Ox (expected: -O0|-O1|-O2|-O3|-Os|-Oz",
        ),
      )
  }
}

///|
test "xsh wasm export run" {
  let db = XshDb::new()
  db.set_source("main", "let x = 1\nx")
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(bytes_contains_ascii(wasm, "run"))
}

///|
test "xsh wasm coverage exports counters and collects points" {
  let db = XshDb::new()
  let src =
    #|let x = 1
    #|if true {
    #|  x
    #|} else {
    #|  0
    #|}
  db.set_source("main", src)
  let artifact = try compile_module_wasm_with_coverage(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    v => v
  }
  assert_true(artifact.bytes.length() >= 8)
  assert_true(bytes_contains_ascii(artifact.bytes, "__xsh_cov_base"))
  assert_true(bytes_contains_ascii(artifact.bytes, "__xsh_cov_count"))
  assert_true(artifact.counter_base >= 0)
  assert_true(artifact.counter_count >= 3)
  assert_eq(artifact.counter_count, artifact.points.length())
  let mut has_line = false
  let mut has_then = false
  let mut has_else = false
  for point in artifact.points {
    match point.kind {
      WasmCoveragePointKind::Line => has_line = true
      WasmCoveragePointKind::BranchIfThen => has_then = true
      WasmCoveragePointKind::BranchIfElse => has_else = true
      _ => ()
    }
  }
  assert_true(has_line)
  assert_true(has_then)
  assert_true(has_else)
}

///|
test "xsh wasm coverage run-tests keeps test-referenced branches" {
  let db = XshDb::new()
  let src =
    #|let helper = (x: Int) -> Int {
    #|  if x < 0 { 0 - x } else { x }
    #|}
    #|test "helper" {
    #|  assert(eq(helper(-3), 3))
    #|}
    #|0
  db.set_source("main", src)
  let baseline = try compile_module_wasm_with_coverage(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    v => v
  }
  let run_tests = try
    compile_module_wasm_with_coverage(db, "main", run_tests=true)
  catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    v => v
  }
  assert_true(run_tests.counter_count > baseline.counter_count)
  let mut baseline_has_branch = false
  for point in baseline.points {
    match point.kind {
      WasmCoveragePointKind::BranchIfThen
      | WasmCoveragePointKind::BranchIfElse
      | WasmCoveragePointKind::BranchMatchArm => baseline_has_branch = true
      _ => ()
    }
  }
  assert_false(baseline_has_branch)
  let mut run_tests_has_then = false
  let mut run_tests_has_else = false
  for point in run_tests.points {
    match point.kind {
      WasmCoveragePointKind::BranchIfThen => run_tests_has_then = true
      WasmCoveragePointKind::BranchIfElse => run_tests_has_else = true
      _ => ()
    }
  }
  assert_true(run_tests_has_then)
  assert_true(run_tests_has_else)
}

///|
test "xsh wasm import sh" {
  let db = XshDb::new()
  db.set_source("main", "do { sh(\"ls\") }")
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(bytes_contains_ascii(wasm, "xsh"))
  assert_true(bytes_contains_ascii(wasm, "sh"))
}

///|
test "xsh wasm import path" {
  let db = XshDb::new()
  db.set_source("main", "let p = path(\"a/../b\")\np")
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(bytes_contains_ascii(wasm, "xsh"))
  assert_true(bytes_contains_ascii(wasm, "path"))
}

///|
test "xsh wasm compile export enum ctor call" {
  let db = XshDb::new()
  let src =
    #|export enum Json {
    #|  JNum(Double)
    #|}
    #|
    #|export let make = (s: String) -> Json {
    #|  let _ = s
    #|  JNum(1.0)
    #|}
    #|
    #|make("x")
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
}

///|
fn bytes_contains_ascii(bytes : Bytes, needle : String) -> Bool {
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
fn raise_literal_source(message : String) -> String {
  let src =
    #|let fail = () -> Int with {Error} {
    #|  raise "@MSG@"
    #|}
    #|try {
    #|  fail()
    #|} catch {
    #|  0
    #|}
  src.replace(old="@MSG@", new=message)
}

///|
fn bytes_contains_opcode(bytes : Bytes, opcode : Int) -> Bool {
  let arr = bytes.to_array()
  for b in arr {
    if b.to_int() == opcode {
      return true
    }
  }
  false
}

///|
fn read_u32_leb_at(bytes : Array[Byte], start : Int) -> (Int, Int) {
  let mut value = 0
  let mut shift = 0
  let mut i = start
  while true {
    if i >= bytes.length() {
      return (value, i)
    }
    let b = bytes[i].to_int()
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
fn bytes_range_equals(
  bytes : Array[Byte],
  start : Int,
  needle : Array[Byte],
) -> Bool {
  if start < 0 || start + needle.length() > bytes.length() {
    return false
  }
  for i in 0..<needle.length() {
    if bytes[start + i] != needle[i] {
      return false
    }
  }
  true
}

///|
fn find_custom_section_payload(
  bytes : Bytes,
  section_name : String,
) -> Array[Byte]? {
  let arr = bytes.to_array()
  if arr.length() < 8 {
    return None
  }
  let name_bytes = @utf8.encode(section_name).to_array()
  let mut i = 8
  while i < arr.length() {
    let section_id = arr[i].to_int()
    i += 1
    let (section_size, next_i) = read_u32_leb_at(arr, i)
    i = next_i
    let section_end = i + section_size
    if section_end > arr.length() {
      return None
    }
    if section_id == 0 {
      let (name_len, name_start) = read_u32_leb_at(arr, i)
      let name_end = name_start + name_len
      if name_end <= section_end &&
        bytes_range_equals(arr, name_start, name_bytes) {
        let payload_len = section_end - name_end
        let payload : Array[Byte] = []
        for j in 0..<payload_len {
          payload.push(arr[name_end + j])
        }
        return Some(payload)
      }
    }
    i = section_end
  }
  None
}

///|
fn wasm_has_custom_section_named(bytes : Bytes, section_name : String) -> Bool {
  match find_custom_section_payload(bytes, section_name) {
    Some(_) => true
    None => false
  }
}

///|
fn wasm_error_map_contains(bytes : Bytes, code : Int, message : String) -> Bool {
  let payload = match find_custom_section_payload(bytes, "xsh.error_map") {
    Some(v) => v
    None => return false
  }
  let msg_bytes = @utf8.encode(message).to_array()
  let mut i = 0
  let (version, after_version) = read_u32_leb_at(payload, i)
  if version != 1 {
    return false
  }
  i = after_version
  let (count, after_count) = read_u32_leb_at(payload, i)
  i = after_count
  for _ in 0..<count {
    let (entry_code, after_code) = read_u32_leb_at(payload, i)
    i = after_code
    let (msg_len, after_len) = read_u32_leb_at(payload, i)
    i = after_len
    if i + msg_len > payload.length() {
      return false
    }
    if entry_code == code && bytes_range_equals(payload, i, msg_bytes) {
      return true
    }
    i += msg_len
  }
  false
}

///|
fn wasm_has_section(bytes : Bytes, section_id : Int) -> Bool {
  let arr = bytes.to_array()
  if arr.length() < 8 {
    return false
  }
  let mut i = 8
  while i < arr.length() {
    let id = arr[i].to_int()
    i += 1
    let (size, next_i) = read_u32_leb_at(arr, i)
    i = next_i
    if id == section_id {
      return true
    }
    i += size
  }
  false
}

///|
test "xsh wasm omits table/element when no function values are used" {
  let db = XshDb::new()
  let src =
    #|let inc = (x: Int) -> Int { x + 1 }
    #|let dec = (x: Int) -> Int { x - 1 }
    #|inc(1) + dec(2)
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_false(wasm_has_section(wasm, 4))
  assert_false(wasm_has_section(wasm, 9))
}

///|
test "xsh wasm keeps table/element when function values are used" {
  let db = XshDb::new()
  let src =
    #|let apply = (f: (Int) -> Int, v: Int) -> Int { f(v) }
    #|let id = (x: Int) -> Int { x }
    #|apply(id, 7)
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm_has_section(wasm, 4))
  assert_true(wasm_has_section(wasm, 9))
}

///|
test "xsh wasm strips raise string literal in default build" {
  let db = XshDb::new()
  let needle = "ERR_LITERAL_ONLY_FOR_DEBUG_9f0d5c2a"
  db.set_source("main", raise_literal_source(needle))
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_false(bytes_contains_ascii(wasm, needle))
  assert_false(wasm_has_custom_section_named(wasm, "xsh.error_map"))
}

///|
test "xsh wasm keeps raise string literal when debug errors enabled" {
  let db = XshDb::new()
  let needle = "ERR_LITERAL_ONLY_FOR_DEBUG_9f0d5c2a"
  db.set_source("main", raise_literal_source(needle))
  let wasm = try
    compile_module_wasm_with_opt_level(
      db,
      "main",
      opt_level=None,
      debug_errors=true,
    )
  catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(bytes_contains_ascii(wasm, needle))
  assert_true(wasm_has_custom_section_named(wasm, "xsh.error_map"))
  assert_true(wasm_error_map_contains(wasm, 1, needle))
}

///|
test "xsh wasm import sleep" {
  let db = XshDb::new()
  db.set_source("main", "do { sleep(100) }")
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(bytes_contains_ascii(wasm, "xsh"))
  assert_true(bytes_contains_ascii(wasm, "sleep"))
}

///|
test "xsh wasm enum and match" {
  let db = XshDb::new()
  let src =
    #|enum MyResult { Ok(Int); Err }
    #|let x = Ok(42)
    #|match x {
    #|  Ok(n) => n
    #|  Err => 0
    #|}
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "run"))
  assert_true(bytes_contains_ascii(wasm, "memory"))
}

///|
test "xsh wasm enum import and match" {
  let db = XshDb::new()
  let lib_src =
    #|export enum Json { JNull; JBool(Bool); JNum(Double); JStr(String) }
    #|export let is_null = (j: Json) -> Bool {
    #|  match j {
    #|    JNull => true
    #|    _ => false
    #|  }
    #|}
  let main_src =
    #|use ./lib.vibe { Json, is_null }
    #|let x = JNull
    #|is_null(x)
  db.set_source("./lib.vibe", lib_src)
  db.set_source("main", main_src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "run"))
  assert_true(bytes_contains_ascii(wasm, "memory"))
}

///|
test "xsh wasm export user functions" {
  let db = XshDb::new()
  let src =
    #|export let add = (a: Int, b: Int) -> Int { a + b }
    #|export let mul = (a: Int, b: Int) -> Int { a * b }
    #|let helper = (x: Int) -> Int { x + 1 }
    #|add(1, 2)
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "run"))
  assert_true(bytes_contains_ascii(wasm, "memory"))
  // Exported functions should be in the export section
  assert_true(bytes_contains_ascii(wasm, "add"))
  assert_true(bytes_contains_ascii(wasm, "mul"))
}

///|
test "xsh wasm accepts i32/f32/f64 type aliases" {
  let db = XshDb::new()
  let src =
    #|let id_i32 = (x: i32) -> i32 { x }
    #|let id_f64 = (x: f64) -> f64 { x }
    #|let id_f32 = (x: f32) -> f32 { x }
    #|let _ = id_i32(42)
    #|let _ = id_f64(1.25)
    #|let _ = id_f32(2.5f)
    #|42
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "run"))
  assert_true(bytes_contains_ascii(wasm, "memory"))
}

///|
test "xsh wasm compiles std wasm opcode module" {
  let src = try @os_fs.read_file_to_string("vibe/std/wasm/opcodes.vibe") catch {
    e => fail("read error: " + e.to_string())
  } noraise {
    s => s
  }
  let db = XshDb::new()
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "run"))
  assert_true(bytes_contains_ascii(wasm, "memory"))
}

///|
test "xsh wasm compiles multiple local recursive `go` helpers" {
  let src =
    #|let reverse_count = (n: Int) -> Int {
    #|  let rec go = (acc: Int, rest: Int) -> Int {
    #|    if rest <= 0 { acc } else { go(acc + 1, rest - 1) }
    #|  }
    #|  go(0, n)
    #|}
    #|let take_count = (n: Int) -> Int {
    #|  let rec go = (acc: Int, rest: Int, count: Int) -> Int {
    #|    if count <= 0 || rest <= 0 { acc }
    #|    else { go(acc + 1, rest - 1, count - 1) }
    #|  }
    #|  go(0, n, n)
    #|}
    #|reverse_count(5) + take_count(3)
  let db = XshDb::new()
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "run"))
  assert_true(bytes_contains_ascii(wasm, "memory"))
}

///|
test "xsh wasm compiles numeric conversion builtins" {
  let db = XshDb::new()
  let src =
    #|let a = int_to_float(42)
    #|let b = int_to_double(42)
    #|let c = float_to_int(a)
    #|let d = double_to_int(b)
    #|let e = float_to_double(a)
    #|let f = double_to_float(b)
    #|c + d + float_to_int(f) + double_to_int(e)
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "run"))
  assert_true(bytes_contains_ascii(wasm, "memory"))
}

///|
test "xsh wasm uses f32/f64 compare opcodes for typed params" {
  let db = XshDb::new()
  let src =
    #|let float_eq = (a: Float, b: Float) -> Bool { a == b }
    #|let double_eq = (a: Double, b: Double) -> Bool { a == b }
    #|if float_eq(1.0f, 1.0f) && double_eq(1.0, 1.0) { 1 } else { 0 }
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(bytes_contains_opcode(wasm, 0x5b))
  assert_true(bytes_contains_opcode(wasm, 0x61))
}

///|
test "xsh wasm compiles function alias calls" {
  let db = XshDb::new()
  let src =
    #|let abs_impl = (x: Double) -> Double {
    #|  if x < 0.0 { 0.0 - x } else { x }
    #|}
    #|let abs = abs_impl
    #|abs(-3.5)
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "run"))
}

///|
test "xsh wasm compiles local recursive helper calls" {
  let db = XshDb::new()
  let src =
    #|let run = (n: Int) -> Int {
    #|  let rec go = (acc: Int, rest: Int) -> Int {
    #|    if rest <= 0 { acc } else { go(acc + 1, rest - 1) }
    #|  }
    #|  go(0, n)
    #|}
    #|run(5)
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "run"))
}

///|
test "xsh wasm compiles recursive helper with captured function param" {
  let db = XshDb::new()
  let src =
    #|let apply_n = (f: (x: Int) -> Int, n: Int) -> Int {
    #|  let rec go = (acc: Int, rest: Int) -> Int {
    #|    if rest <= 0 { acc } else { go(f(acc), rest - 1) }
    #|  }
    #|  go(0, n)
    #|}
    #|apply_n((x: Int) -> Int { x + 2 }, 3)
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "run"))
}

///|
test "xsh wasm compiles Int method-style to_double call" {
  let db = XshDb::new()
  let src =
    #|let v = 7
    #|let d = v.to_double()
    #|double_to_int(d)
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "run"))
}

///|
test "xsh wasm imports stdio char builtins" {
  let db = XshDb::new()
  let src =
    #|do {
    #|  stdout_write_char(65)
    #|  stdin_read_char()
    #|}
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(bytes_contains_ascii(wasm, "wasi:cli/stdout@0.2.0"))
  assert_true(bytes_contains_ascii(wasm, "get-stdout"))
  assert_true(bytes_contains_ascii(wasm, "wasi:cli/stdin@0.2.0"))
  assert_true(bytes_contains_ascii(wasm, "get-stdin"))
  assert_true(bytes_contains_ascii(wasm, "wasi:io/streams@0.2.0"))
  assert_true(
    bytes_contains_ascii(wasm, "[method]output-stream.blocking-write-and-flush"),
  )
  assert_true(bytes_contains_ascii(wasm, "[method]input-stream.blocking-read"))
  assert_true(bytes_contains_ascii(wasm, "cabi_realloc"))
}

///|
test "xsh wasm imports stdio stream builtins" {
  let db = XshDb::new()
  let src =
    #|do {
    #|  stdout_write_stream("hello")
    #|  stdin_read_stream(8)
    #|}
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(bytes_contains_ascii(wasm, "wasi:cli/stdout@0.2.0"))
  assert_true(bytes_contains_ascii(wasm, "get-stdout"))
  assert_true(bytes_contains_ascii(wasm, "wasi:cli/stdin@0.2.0"))
  assert_true(bytes_contains_ascii(wasm, "get-stdin"))
  assert_true(bytes_contains_ascii(wasm, "wasi:io/streams@0.2.0"))
  assert_true(
    bytes_contains_ascii(wasm, "[method]output-stream.blocking-write-and-flush"),
  )
  assert_true(bytes_contains_ascii(wasm, "[method]input-stream.blocking-read"))
  assert_true(bytes_contains_ascii(wasm, "cabi_realloc"))
}

///|
test "xsh wasm compiles while with stdio char builtins" {
  let db = XshDb::new()
  let src =
    #|let run = () -> Int with {Stdin, Stdout} {
    #|  do {
    #|    let mut i = 0
    #|    while i < 1 {
    #|      let c = stdin_read_char()
    #|      if c < 0 {
    #|        i = 1
    #|      } else {
    #|        stdout_write_char(c)
    #|        i = i + 1
    #|      }
    #|    }
    #|    0
    #|  }
    #|}
    #|run()
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "wasi:io/streams@0.2.0"))
}

///|
test "xsh wasm compiles string_from_char_code builtin" {
  let db = XshDb::new()
  let src =
    #|string_from_char_code(65)
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "run"))
}

///|
test "xsh wasm compiles non-js string builtins" {
  let db = XshDb::new()
  let src =
    #|let s = "ab"
    #|let len = string_length(s)
    #|let code = string_char_code_at(s, 1)
    #|let joined = string_concat(s, "cd")
    #|let part = string_substring(joined, 1, 3)
    #|if string_equals(part, "bc") { len + code } else { 0 }
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "run"))
}

///|
test "xsh wasm compiles __to_string builtin" {
  let db = XshDb::new()
  let src =
    #|let s1 = __to_string(42)
    #|let s2 = __to_string(true)
    #|if string_equals(s1, "42") && string_equals(s2, "true") { 1 } else { 0 }
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "run"))
}

///|
test "xsh wasm compiles threads builtin thunks" {
  let db = XshDb::new()
  let src =
    #|let probe = () -> String { threads_probe_wat() }
    #|let hints = () { threads_runtime_hints() }
    #|let new_ch = () -> Int { threads_channel_new(1) }
    #|let spawn_w = () -> Int { threads_spawn("worker", 1) }
    #|let send_w = () -> Bool { threads_send(1, "msg") }
    #|let recv_w = () -> String { threads_recv(1) }
    #|let wait_w = () -> Int { threads_wait(1) }
    #|0
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "run"))
}

///|
test "xsh wasm rejects unknown record accessor call" {
  let db = XshDb::new()
  let src =
    #|let hints = record { kind: "ok" }
    #|unknown_accessor(hints)
  db.set_source("main", src)
  let result : Result[Bytes, WasmCompileError] = try? compile_module_wasm(
    db, "main",
  )
  match result {
    Ok(_) => fail("expected compile error")
    Err(err) => assert_true(err.to_string().contains("call: unknown_accessor"))
  }
}

///|
test "xsh wasm compiles wasm primitive memory and conversion builtins" {
  let db = XshDb::new()
  let src =
    #|let base = 128
    #|do {
    #|  i32_store(base, 0, 42)
    #|  i32_store8(base, 1, 255)
    #|  f32_store(base, 8, f32_convert_i32_s(3))
    #|  f64_store(base, 16, f64_convert_i32_s(4))
    #|}
    #|let a = i32_load(base, 0)
    #|let b = i32_load8_u(base, 1)
    #|let c = i32_shr_u(84, 1)
    #|let d = f32_neg(f32_load(base, 8))
    #|let e = f64_neg(f64_load(base, 16))
    #|let f = i32_trunc_f32_s(f32_demote_f64(f64_promote_f32(d)))
    #|let g = i32_trunc_f64_s(e)
    #|a + b + c + f + g
  db.set_source("main", src)
  let wasm = try compile_module_wasm(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(wasm.length() >= 8)
  assert_true(bytes_contains_ascii(wasm, "run"))
  assert_true(bytes_contains_ascii(wasm, "memory"))
}
