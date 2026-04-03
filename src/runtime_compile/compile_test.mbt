///|
test "vibe compile simple" {
  let db = @runtime.VibeDb::new()
  db.set_source("main", "export let x = 1\nexport let y = 2")
  let compiled = compile_module(db, "main")
  let rt = @runtime.Runtime::new(@capability.CapabilitySet::new())
  let _ = run_compiled(rt, compiled)
  match rt.get("x") {
    Some(@core.Value::Int(v)) => assert_eq(v, 1)
    _ => fail("missing x binding")
  }
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
