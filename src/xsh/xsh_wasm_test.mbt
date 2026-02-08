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
    #|import { Json, is_null } from ./lib.xsh
    #|let x = JNull
    #|is_null(x)
  db.set_source("./lib.xsh", lib_src)
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
  let src = try
    @os_fs.read_file_to_string("xsh/std/wasm/opcodes.xsh")
  catch {
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
