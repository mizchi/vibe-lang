///|
fn wbtest_ensure_dir(path : String) -> Unit {
  if @io.path_exists(path) {
    return
  }
  let parent = @path.Path(path).dirname().normalize().to_string()
  if parent != path && parent.length() > 0 {
    wbtest_ensure_dir(parent)
  }
  let _ = @io.create_dir(path)
}

///|
test "normalize path object resolves std namespace under index root" {
  let root = "/tmp/runtime_std_ns_wbtest"
  wbtest_ensure_dir(root + "/vibe/std")
  match
    @io.write_string(root + "/index.vibe", "export let version = \"0.1.0\"\n") {
    Ok(_) => ()
    Err(err) => fail("write index failed: " + err)
  }
  let from_entry = normalize_path_obj(root, "std/string.vibe")
  assert_eq(from_entry.normalized, root + "/vibe/std/string.vibe")
  let from_std = normalize_path_obj(root + "/vibe/std", "std/int.vibe")
  assert_eq(from_std.normalized, root + "/vibe/std/int.vibe")
}

///|
test "compile_module keeps parse error variant" {
  let db = VibeDb::new()
  db.set_source("main", "let x =")
  let result : Result[CompiledModule, CompileError] = try? compile_module(
    db, "main",
  )
  match result {
    Ok(_) => fail("expected parse error")
    Err(CompileError::Parse(_)) => ()
    Err(err) => fail("expected CompileError::Parse, got " + err.to_string())
  }
}

///|
test "compile_module cache reuses same key" {
  let db = VibeDb::new()
  let before = compile_module_cache.val.length()
  let path = "cache-main-" + before.to_string()
  db.set_source(path, "let x = 1")
  let _ = compile_module(db, path)
  let after_first = compile_module_cache.val.length()
  let _ = compile_module(db, path)
  let after_second = compile_module_cache.val.length()
  assert_eq(after_first, before + 1)
  assert_eq(after_second, after_first)
}
