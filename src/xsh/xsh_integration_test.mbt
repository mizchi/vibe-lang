///|
/// Integration test for import parsing
test "xsh integration import parsing" {
  let db = XshDb::new()
  let lib_source = "export let value = 7"
  let main_source = "import { value } from ./lib.xsh\nlet x = 1"
  db.set_source("./lib.xsh", lib_source)
  db.set_source("main", main_source)
  let compiled = compile_module(db, "main")
  let import_hash = @core.git_blob_hash_string(lib_source)
  let import_ref = @core.module_ref_from_hash(import_hash)
  assert_eq(compiled.imports.length(), 1)
  assert_eq(compiled.imports[0], import_ref)
  // Note: import bindings are not yet resolved, just check parsing works
}
