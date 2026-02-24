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
test "type query resolves extensionless directory import to index.vibe" {
  let db = VibeDb::new()
  db.set_source(
    "./dep/index.vibe",
    "export let value = 1\n",
  )
  db.set_source(
    "main",
    "import ./dep { value }\n" +
    "let x = value\n" +
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
  match env.get_scheme("x") {
    Some(_) => ()
    None => fail("expected imported symbol type for x")
  }
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
    "import ./option.vibe { unwrap_or }\n" +
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

///|
test "type query imports re-exported Process functions through index" {
  let db = VibeDb::new()
  db.set_source(
    "./process.vibe",
    "export let run_lines = (cmd: String) -> Array[String] with { Process } {\n" +
    "  [cmd]\n" +
    "}\n" +
    "export { run_lines }\n",
  )
  db.set_source(
    "./index.vibe",
    "export ./process.vibe { run_lines }\n" + "export { run_lines }\n",
  )
  db.set_source(
    "main",
    "import ./index.vibe { run_lines }\n" +
    "let lines = run_lines(\"ok\")\n" +
    "assert(eq(array_length(lines), 1))\n",
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
  match env.get_scheme("run_lines") {
    Some(scheme) =>
      match scheme.ty {
        @core.Type::Func(..) => ()
        _ => fail("expected function scheme: run_lines")
      }
    None => fail("expected imported scheme: run_lines")
  }
}

///|
test "type query keeps exported schemes for thread runtime-style wrappers" {
  let db = VibeDb::new()
  db.set_source(
    "main",
    "export let recv = (channel: Int) -> String with { Threads } {\n" +
    "  threads_recv(channel)\n" +
    "}\n" +
    "export let send = (channel: Int, message: String) -> Bool with { Threads } {\n" +
    "  threads_send(channel, message)\n" +
    "}\n" +
    "export let wait = (task: Int) -> Int with { Threads } {\n" +
    "  threads_wait(task)\n" +
    "}\n" +
    "export let spawn = (name: String, mailbox: Int) -> Int with { Threads } {\n" +
    "  { threads_spawn(name, mailbox) }\n" +
    "}\n" +
    "export let probe_wat = () -> String with { Threads } {\n" +
    "  threads_probe_wat()\n" +
    "}\n" +
    "export let channel_new = (capacity: Int) -> Int with { Threads } {\n" +
    "  threads_channel_new(capacity)\n" +
    "}\n" +
    "export let runtime_hints = () -> Unit with { Threads } {\n" +
    "  let _ = threads_runtime_hints()\n" +
    "  if true {\n" +
    "  } else {\n" +
    "  }\n" +
    "}\n",
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
  let names = [
    "recv", "send", "wait", "spawn", "probe_wat", "channel_new", "runtime_hints",
  ]
  for name in names {
    match env.get_scheme(name) {
      Some(_) => ()
      None => fail("expected exported scheme: " + name)
    }
  }
}

///|
test "cross-directory import to non-index.vibe emits warning" {
  let db = VibeDb::new()
  db.set_source(
    "/project/lib/helper.vibe", "export let add = (a: Int, b: Int) -> Int { a + b }\n",
  )
  db.set_source(
    "/project/src/main.vibe", "import ../lib/helper.vibe { add }\nlet x = add(1, 2)\n",
  )
  let _imports = db.imports("/project/src/main.vibe")
  let diags = db.import_diagnostics("/project/src/main.vibe")
  let has_cross_module_warning = diags
    .iter()
    .any(fn(d) {
      d.message.contains("cross-module import should target index.vibe")
    })
  assert_true(has_cross_module_warning)
}

///|
test "cross-directory import to index.vibe does not emit warning" {
  let db = VibeDb::new()
  db.set_source(
    "/project/lib/helper.vibe", "export let add = (a: Int, b: Int) -> Int { a + b }\n",
  )
  db.set_source(
    "/project/lib/index.vibe", "export ./helper.vibe { add }\nexport { add }\n",
  )
  db.set_source(
    "/project/src/main.vibe", "import ../lib/index.vibe { add }\nlet x = add(1, 2)\n",
  )
  let _imports = db.imports("/project/src/main.vibe")
  let diags = db.import_diagnostics("/project/src/main.vibe")
  let has_cross_module_warning = diags
    .iter()
    .any(fn(d) {
      d.message.contains("cross-module import should target index.vibe")
    })
  if has_cross_module_warning {
    fail("should not warn when importing index.vibe")
  }
}

///|
test "same-directory import does not emit cross-module warning" {
  let db = VibeDb::new()
  db.set_source(
    "/project/src/helper.vibe", "export let add = (a: Int, b: Int) -> Int { a + b }\n",
  )
  db.set_source(
    "/project/src/main.vibe", "import ./helper.vibe { add }\nlet x = add(1, 2)\n",
  )
  let _imports = db.imports("/project/src/main.vibe")
  let diags = db.import_diagnostics("/project/src/main.vibe")
  let has_cross_module_warning = diags
    .iter()
    .any(fn(d) {
      d.message.contains("cross-module import should target index.vibe")
    })
  if has_cross_module_warning {
    fail("should not warn for same-directory import")
  }
}

///|
test "internal export is importable from same directory" {
  let db = VibeDb::new()
  db.set_source(
    "/project/lib/helper.vibe", "internal export let hidden = () -> Int { 1 }\n",
  )
  db.set_source(
    "/project/lib/main.vibe", "import ./helper.vibe { hidden }\nlet x = hidden()\n",
  )
  let env = db.types("/project/lib/main.vibe")
  let diags = db.diagnostics("/project/lib/main.vibe")
  if not(diags.is_empty()) {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected diagnostics: " + lines.join(","))
  }
  match env.get_scheme("hidden") {
    Some(_) => ()
    None => fail("expected same-directory internal export import: hidden")
  }
}

///|
test "internal export is not importable across directories" {
  let db = VibeDb::new()
  db.set_source(
    "/project/lib/helper.vibe", "internal export let hidden = () -> Int { 1 }\n",
  )
  db.set_source(
    "/project/src/main.vibe", "import ../lib/helper.vibe { hidden }\nlet x = hidden()\n",
  )
  let env = db.types("/project/src/main.vibe")
  let diags = db.diagnostics("/project/src/main.vibe")
  match env.get_scheme("hidden") {
    Some(_) => fail("internal export must not be importable across directories")
    None => ()
  }
  assert_true(diags.length() > 0)
}

///|
test "module-level cycle detection: A -> B -> A directories" {
  let db = VibeDb::new()
  db.set_source(
    "/project/a/index.vibe", "export ../b/index.vibe { greet }\nexport let hello = () -> String { greet() }\nexport { hello }\n",
  )
  db.set_source(
    "/project/b/index.vibe", "export ../a/index.vibe { hello }\nexport let greet = () -> String { hello() }\nexport { greet }\n",
  )
  let _imports = db.imports("/project/a/index.vibe")
  let diags = db.import_diagnostics("/project/a/index.vibe")
  let has_module_cycle = diags
    .iter()
    .any(fn(d) {
      d.message.contains("module cycle") || d.message.contains("import cycle")
    })
  assert_true(has_module_cycle)
}

///|
test "index.vibe cross-directory imports shared with same-dir files" {
  let db = VibeDb::new()
  // External module in /project/lib/
  db.set_source(
    "/project/lib/math.vibe", "export let add = (a: Int, b: Int) -> Int { a + b }\nexport { add }\n",
  )
  // index.vibe in /project/src/ imports from external module
  db.set_source("/project/src/index.vibe", "export ../lib/math.vibe { add }\n")
  // sibling.vibe in /project/src/ should have access to `add` without importing
  db.set_source("/project/src/sibling.vibe", "let x = add(1, 2)\nx\n")
  let env = db.types("/project/src/sibling.vibe")
  let diags = db.diagnostics("/project/src/sibling.vibe")
  if not(diags.is_empty()) {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected diagnostics: " + lines.join(","))
  }
  match env.get_scheme("x") {
    Some(_) => ()
    None => fail("expected scheme for x (add result)")
  }
}

///|
test "index.vibe sharing does not apply to index.vibe itself" {
  let db = VibeDb::new()
  db.set_source(
    "/project/lib/math.vibe", "export let add = (a: Int, b: Int) -> Int { a + b }\nexport { add }\n",
  )
  // index.vibe cannot use its own exports without explicit import
  db.set_source(
    "/project/src/index.vibe", "export ../lib/math.vibe { add }\nlet y = add(1, 2)\ny\n",
  )
  let env = db.types("/project/src/index.vibe")
  let diags = db.diagnostics("/project/src/index.vibe")
  // This should work because index.vibe has its own imports
  if not(diags.is_empty()) {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected diagnostics: " + lines.join(","))
  }
  match env.get_scheme("y") {
    Some(_) => ()
    None => fail("expected scheme for y")
  }
}

///|
test "cascading diagnostics: upstream type error produces root cause diagnostic" {
  let db = VibeDb::new()
  // lib.vibe has a type error: calls undefined function `undefined_fn`
  db.set_source(
    "./lib.vibe", "export let helper = () -> Int { undefined_fn(1) }\nexport { helper }\n",
  )
  // main imports helper from lib.vibe
  db.set_source("main", "import ./lib.vibe { helper }\nlet x = helper()\n")
  let _env = db.types("main")
  let diags = db.diagnostics("main")
  // Current behavior: no useful diagnostic for main — helper silently becomes
  // unavailable, and main gets "unknown function: helper" instead of the root
  // cause ("undefined_fn" error in lib.vibe).
  //
  // Expected: at least one diagnostic mentioning the upstream dependency error,
  // e.g. "dependency export unavailable due to upstream errors in ./lib.vibe"
  let has_upstream_hint = diags
    .iter()
    .any(fn(d) {
      d.message.contains("upstream") || d.message.contains("./lib.vibe")
    })
  assert_true(has_upstream_hint)
}
