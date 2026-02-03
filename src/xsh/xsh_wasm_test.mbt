///| Tests for xsh wasm codegen

test "xsh wasm header" {
  let db = XshDb::new()
  db.set_source("main", "let x = 1\nx")
  let wasm = try {
    compile_module_wasm(db, "main")
  } catch {
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

test "xsh wasm export run" {
  let db = XshDb::new()
  db.set_source("main", "let x = 1\nx")
  let wasm = try {
    compile_module_wasm(db, "main")
  } catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(bytes_contains_ascii(wasm, "run"))
}

test "xsh wasm import sh" {
  let db = XshDb::new()
  db.set_source("main", "do { sh(\"ls\") }")
  let wasm = try {
    compile_module_wasm(db, "main")
  } catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(bytes_contains_ascii(wasm, "xsh"))
  assert_true(bytes_contains_ascii(wasm, "sh"))
}

test "xsh wasm import path" {
  let db = XshDb::new()
  db.set_source("main", "let p = path(\"a/../b\")\np")
  let wasm = try {
    compile_module_wasm(db, "main")
  } catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(bytes_contains_ascii(wasm, "xsh"))
  assert_true(bytes_contains_ascii(wasm, "path"))
}

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
  for i in 0..=limit {
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
