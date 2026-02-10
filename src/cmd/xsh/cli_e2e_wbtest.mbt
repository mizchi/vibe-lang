///|
test "cli save fetch expand workflow keeps codebase artifacts" {
  let root = wbtest_make_temp_dir("save_fetch_expand")
  let entry = root + "/main.xsh"
  let lib = root + "/lib.xsh"
  let entry_source = "import { inc } from \"./lib.xsh\"\nlet main = inc(1)\nexport { main }\n"
  let lib_source = "let inc = (x: Int) -> Int { x + 1 }\nexport { inc }\n"
  @os_fs.write_string_to_file(entry, entry_source) catch {
    e => fail("write entry failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(lib, lib_source) catch {
    e => fail("write lib failed: " + e.to_string())
  }
  save_cmd([entry])
  let xsh_dir = find_xsh_dir(entry)
  let codebase = @codebase.Codebase::new(xsh_dir)
  let main_hash = match codebase.resolve_path_mapping(entry) {
    Some(hash) => hash
    None => fail("expected path mapping for entry")
  }
  match codebase.read_object(main_hash) {
    Some(json) => {
      let _ = @xsh_core.deserialize_module(json) catch {
        e => fail("deserialize saved module failed: " + e.to_string())
      }

    }
    None => fail("expected object for saved hash")
  }
  fetch_cmd([entry])
  let lock_path = @codebase.lock_file_path(entry)
  assert_true(@os_fs.path_exists(lock_path))
  let lock = match @codebase.load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let entry_norm = @loader.resolve_entry_path(entry)
  let lib_norm = @loader.resolve_import_path(root, "./lib.xsh")
  match lock.path_refs.get(entry_norm) {
    Some(hash) => assert_eq(hash, @xsh_core.git_blob_hash_string(entry_source))
    None => fail("expected entry lock ref")
  }
  match lock.path_refs.get(lib_norm) {
    Some(hash) => assert_eq(hash, @xsh_core.git_blob_hash_string(lib_source))
    None => fail("expected import lock ref")
  }
  let prelude_hash = match lock.version_refs.get("prelude") {
    Some(hash) => hash
    None => fail("expected prelude version ref")
  }
  match lock.symbol_refs.get("std/prelude") {
    Some(hash) => assert_eq(hash, prelude_hash)
    None => fail("expected prelude symbol ref")
  }
  match codebase.read_object(prelude_hash) {
    Some(json) => {
      let _ = @xsh_core.deserialize_module(json) catch {
        e => fail("deserialize prelude module failed: " + e.to_string())
      }

    }
    None => fail("expected prelude object in codebase")
  }
  let resolved = resolve_target_to_hash(entry, codebase)
  assert_eq(resolved, main_hash)
  let short_target = target_substring(main_hash, 0, 8)
  let resolved_short = resolve_target_to_hash(short_target, codebase)
  assert_eq(resolved_short, main_hash)
  expand_cmd([entry, "--json"])
  wbtest_remove_if_exists(root)
}
