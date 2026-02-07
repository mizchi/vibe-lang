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
    #|enum MyResult { Ok(Int), Err }
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
    #|export enum Json { JNull, JBool(Bool), JNum(Double), JStr(String) }
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
