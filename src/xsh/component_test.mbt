///|
/// Tests for Component Model WASM output
test "component wasm header" {
  let db = XshDb::new()
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
  let db = XshDb::new()
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
  let db = XshDb::new()
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
