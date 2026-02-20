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
  wbtest_ensure_dir(root + "/vibe/builtin")
  match
    @io.write_string(root + "/index.vibe", "export let version = \"0.1.0\"\n") {
    Ok(_) => ()
    Err(err) => fail("write index failed: " + err)
  }
  let from_entry = normalize_path_obj(root, "std/string.vibe")
  assert_eq(from_entry.normalized, root + "/vibe/builtin/string.vibe")
  let from_std = normalize_path_obj(root + "/vibe/builtin", "std/int.vibe")
  assert_eq(from_std.normalized, root + "/vibe/builtin/int.vibe")
}

///|
test "type query keeps no-import dependency exports for alias call" {
  let db = VibeDb::new()
  db.set_source(
    "./option.vibe",
    "export trait Eq\n" +
    "impl Eq for Int\n" +
    "impl [T: Eq] Eq for Option[T]\n" +
    "export let unwrap_or = [T](opt: Option[T], default: T) -> T {\n" +
    "  match opt {\n" +
    "    Some(v) => v,\n" +
    "    _ => default\n" +
    "  }\n" +
    "}\n",
  )
  db.set_source(
    "main",
    "use ./option.vibe { unwrap_or }\n" +
    "let option_unwrap_or = unwrap_or\n" +
    "let x = option_unwrap_or(Some(1), 0)\n" +
    "x\n",
  )
  let env = db.types("main")
  let diags = db.diagnostics("main")
  if not(diags.is_empty()) {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected diagnostics: " + lines.join(","))
  }
  match env.get_scheme("option_unwrap_or") {
    Some(_) => ()
    None => fail("expected imported alias scheme: option_unwrap_or")
  }
}
