///|
test "vibe compile simple to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source("main", "export let x = 1\nexport let y = 2")
  let wasm = compile_module_wasm(db, "main") catch {
    e => fail("compile_module_wasm failed: " + e.user_message())
  }
  assert_true(wasm.length() > 8)
}

///|
test "vibe compile ignores test block" {
  let db = @runtime.VibeDb::new()
  db.set_source("main", "export let x = 1\ntest { let y = 2 }")
  db.set_source("plain", "export let x = 1")
  let compiled_with = compile_module(db, "main")
  let compiled_plain = compile_module(db, "plain")
  assert_eq(compiled_with.ir, compiled_plain.ir)
  assert_eq(compiled_with.ir_hash, compiled_plain.ir_hash)
}
