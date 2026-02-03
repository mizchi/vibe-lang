///| Integration test for compile + import + run

test "xsh integration compile/import/run" {
  let db = XshDb::new()
  let lib_source = "let value = 7"
  let main_source = "import \"lib.xsh\"\nlet x = 1\nlib.value"
  db.set_source("lib.xsh", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let import_hash = git_blob_hash_string(lib_source)
  let import_ref = module_ref_from_hash(import_hash)
  assert_eq(compiled.imports.length(), 1)
  assert_eq(compiled.imports[0], import_ref)
  match compiled.aliases.get("lib") {
    Some(r) => assert_eq(r.name, import_ref)
    None => fail("missing import alias")
  }
  assert_true(compiled.ir.contains(import_ref + "/value"))
  let rt = Runtime::new(@capability.CapabilitySet::new())
  let _ = rt.run_compiled(compiled)
  match rt.get("x") {
    Some(Value::Int(v)) => assert_eq(v, 1)
    _ => fail("missing x binding")
  }
}
