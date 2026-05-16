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
test "normalize path object resolves std prelude and path namespaces under index root" {
  let root = "/tmp/runtime_std_ns_wbtest"
  wbtest_ensure_dir(root + "/vibe/prelude")
  wbtest_ensure_dir(root + "/vibe/path")
  match
    @io.write_string(root + "/index.vibe", "export let version = \"0.1.0\"\n") {
    Ok(_) => ()
    Err(err) => fail("write index failed: " + err)
  }
  let from_entry = normalize_path_obj(root, "std/string.vibe")
  assert_eq(from_entry.normalized, root + "/vibe/prelude/string.vibe")
  let from_std = normalize_path_obj(root + "/vibe/prelude", "std/int.vibe")
  assert_eq(from_std.normalized, root + "/vibe/prelude/int.vibe")
  let from_prelude = normalize_path_obj(root, "prelude/int.vibe")
  assert_eq(from_prelude.normalized, root + "/vibe/prelude/int.vibe")
  let from_path = normalize_path_obj(root, "path/index.vibe")
  assert_eq(from_path.normalized, root + "/vibe/path/index.vibe")
}

///|
test "type query resolves extensionless directory import to index.vibe" {
  let db = VibeDb::new()
  db.set_source("./dep/index.vibe", "export let value = 1\n")
  db.set_source("main", "import ./dep { value }\n" + "let x = value\n" + "x\n")
  let env = db.types("main")
  let diags = db.diagnostics("main")
  if !diags.is_empty() {
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
test "type query resolves cross-directory transitive dependency through sibling index" {
  let db = VibeDb::new()
  db.set_source("/project/x/index.vibe", "export let version = \"0.1.0\"\n")
  db.set_source(
    "/project/x/regexp/index.vibe",
    "export ./regexp.vibe { compile }\n" + "export { compile }\n",
  )
  db.set_source(
    "/project/x/regexp/regexp.vibe", "export let compile = (s: String) -> String { s }\n",
  )
  db.set_source(
    "/project/x/url/pattern.vibe",
    "import ../regexp { compile }\n" +
    "export let make_pattern = (s: String) -> String { compile(s) }\n",
  )
  db.set_source(
    "/project/x/url/index.vibe",
    "export ./pattern.vibe { make_pattern }\n" + "export { make_pattern }\n",
  )
  db.set_source(
    "/project/x/url_test.vibe",
    "import ./url { make_pattern }\n" + "let x = make_pattern(\"x\")\n" + "x\n",
  )
  let env = db.types("/project/x/url_test.vibe")
  let diags = db.diagnostics("/project/x/url_test.vibe")
  if !diags.is_empty() {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected diagnostics: " + lines.join(","))
  }
  match env.get_scheme("x") {
    Some(scheme) =>
      match scheme.ty {
        @core.Type::String => ()
        _ => fail("expected String scheme for x")
      }
    None => fail("expected imported symbol type for x")
  }
}

///|
test "type query keeps re-exported value return type through directory index" {
  let db = VibeDb::new()
  db.set_source(
    "/project/scan/scan.vibe",
    "export struct Scanner {\n" +
    "  input: String;\n" +
    "  pos: Int\n" +
    "}\n" +
    "export let new = (input: String) -> Scanner {\n" +
    "  Scanner::{ input: input, pos: 0 }\n" +
    "}\n" +
    "export let Scanner::remaining = (scan: Scanner) -> String {\n" +
    "  String::substring(scan.input, scan.pos, String::length(scan.input))\n" +
    "}\n" +
    "export let remaining = (scan: Scanner) -> String {\n" +
    "  Scanner::remaining(scan)\n" +
    "}\n",
  )
  db.set_source(
    "/project/scan/index.vibe",
    "export ./scan.vibe { Scanner, Scanner::remaining, new, remaining }\n" +
    "export { Scanner, Scanner::remaining, new, remaining }\n",
  )
  db.set_source(
    "/project/main.vibe",
    "import ./scan { Scanner, new, remaining }\n" +
    "let scan = new(\"abc\")\n" +
    "let rest = remaining(scan)\n" +
    "let x = String::length(rest)\n" +
    "x\n",
  )
  let index_env = db.types("/project/scan/index.vibe")
  let index_diags = db.diagnostics("/project/scan/index.vibe")
  if !index_diags.is_empty() {
    let lines : Array[String] = []
    for diag in index_diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected index diagnostics: " + lines.join(","))
  }
  match index_env.get_scheme("new") {
    Some(_) => ()
    None => fail("expected re-exported scheme in index: new")
  }
  match index_env.get_scheme("remaining") {
    Some(_) => ()
    None => fail("expected re-exported scheme in index: remaining")
  }
  let env = db.types("/project/main.vibe")
  let diags = db.diagnostics("/project/main.vibe")
  if !diags.is_empty() {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected diagnostics: " + lines.join(","))
  }
  match env.get_scheme("rest") {
    Some(scheme) =>
      match scheme.ty {
        @core.Type::String => ()
        _ => fail("expected String scheme for rest")
      }
    None => fail("expected scheme for rest")
  }
  match env.get_scheme("x") {
    Some(_) => ()
    None => fail("expected scheme for x")
  }
}

///|
test "type query explicit namespace member import does not duplicate auto-forward" {
  let db = VibeDb::new()
  db.set_source(
    "/project/scan/scan.vibe",
    "export struct Scanner {\n" +
    "  input: String;\n" +
    "  pos: Int\n" +
    "}\n" +
    "export let new = (input: String) -> Scanner {\n" +
    "  Scanner::{ input: input, pos: 0 }\n" +
    "}\n" +
    "export let Scanner::remaining = (scan: Scanner) -> String {\n" +
    "  String::substring(scan.input, scan.pos, String::length(scan.input))\n" +
    "}\n" +
    "export let remaining = (scan: Scanner) -> String {\n" +
    "  Scanner::remaining(scan)\n" +
    "}\n",
  )
  db.set_source(
    "/project/scan/index.vibe",
    "export ./scan.vibe { Scanner, Scanner::remaining, new, remaining }\n" +
    "export { Scanner, Scanner::remaining, new, remaining }\n",
  )
  db.set_source(
    "/project/main.vibe",
    "import ./scan { Scanner, Scanner::remaining, new }\n" +
    "let scan = new(\"abc\")\n" +
    "let rest = Scanner::remaining(scan)\n" +
    "rest\n",
  )
  let env = db.types("/project/main.vibe")
  let diags = db.diagnostics("/project/main.vibe")
  let has_duplicate = diags
    .iter()
    .any(fn(diag) {
      diag.message.contains("duplicate declaration: Scanner::remaining")
    })
  if has_duplicate {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected duplicate diagnostics: " + lines.join(","))
  }
  let has_unknown = diags
    .iter()
    .any(fn(diag) {
      diag.message.contains("unknown function: `new`") ||
      diag.message.contains("unknown function: `Scanner::remaining`")
    })
  if has_unknown {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected import resolution diagnostics: " + lines.join(","))
  }
  match env.get_scheme("rest") {
    Some(scheme) =>
      match scheme.ty {
        @core.Type::String => ()
        _ => fail("expected String scheme for rest")
      }
    None => fail("expected scheme for rest")
  }
}

///|
test "type query root import exposes constructor-like helpers under namespace" {
  let db = VibeDb::new()
  db.set_source(
    "/project/scan/scan.vibe",
    "export struct Scanner {\n" +
    "  input: String;\n" +
    "  pos: Int\n" +
    "}\n" +
    "export let new = (input: String) -> Scanner {\n" +
    "  Scanner::{ input: input, pos: 0 }\n" +
    "}\n" +
    "export let Scanner::remaining = (scan: Scanner) -> String {\n" +
    "  String::substring(scan.input, scan.pos, String::length(scan.input))\n" +
    "}\n",
  )
  db.set_source(
    "/project/scan/index.vibe",
    "export ./scan.vibe { Scanner, new, Scanner::remaining }\n" +
    "export { Scanner, new, Scanner::remaining }\n",
  )
  db.set_source(
    "/project/main.vibe",
    "import ./scan { Scanner }\n" +
    "let scan = Scanner::new(\"abc\")\n" +
    "let rest = Scanner::remaining(scan)\n" +
    "rest\n",
  )
  let env = db.types("/project/main.vibe")
  let diags = db.diagnostics("/project/main.vibe")
  if !diags.is_empty() {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected diagnostics: " + lines.join(","))
  }
  match env.get_scheme("Scanner::new") {
    Some(scheme) =>
      match scheme.ty {
        @core.Type::Func(..) => ()
        _ => fail("expected function scheme for Scanner::new")
      }
    None => fail("expected imported namespaced helper: Scanner::new")
  }
  match env.get_scheme("rest") {
    Some(scheme) =>
      match scheme.ty {
        @core.Type::String => ()
        _ => fail("expected String scheme for rest")
      }
    None => fail("expected scheme for rest")
  }
}

///|
test "type query resolves nested relative re-export from dot-prefixed keys" {
  let db = VibeDb::new()
  db.set_source(
    "./scan/scan.vibe",
    "export let value = () -> Int {\n" + "  1\n" + "}\n" + "export { value }\n",
  )
  db.set_source(
    "./scan/index.vibe",
    "export ./scan.vibe { value }\n" + "export { value }\n",
  )
  db.set_source(
    "main",
    "import ./scan { value }\n" + "let x = value()\n" + "x\n",
  )
  let env = db.types("main")
  let diags = db.diagnostics("main")
  if !diags.is_empty() {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected diagnostics: " + lines.join(","))
  }
  match env.get_scheme("x") {
    Some(_) => ()
    None => fail("expected scheme for x")
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
  if !diags.is_empty() {
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
test "type query resolves Bytes parameter in imported function" {
  let db = VibeDb::new()
  db.set_source(
    "./lib.vibe",
    "export let my_bytes_len = (b: Bytes) -> Int {\n" +
    "  Bytes::length(b)\n" +
    "}\n",
  )
  db.set_source(
    "main",
    "import ./lib.vibe { my_bytes_len }\n" +
    "let b = Bytes::new()\n" +
    "let x = my_bytes_len(b)\n" +
    "x\n",
  )
  let env = db.types("main")
  let diags = db.diagnostics("main")
  if !diags.is_empty() {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected diagnostics: " + lines.join(","))
  }
  match env.get_scheme("x") {
    Some(_) => ()
    None => fail("expected scheme for x after importing Bytes function")
  }
}

///|
test "type query imports transitive type deps from imported value schemes" {
  let db = VibeDb::new()
  db.set_source("./dep_types.vibe", "export enum TypeEnv { EnvEmpty }\n")
  db.set_source(
    "./dep_api.vibe",
    "import ./dep_types.vibe { TypeEnv }\n" +
    "export enum Db { Db(Int) }\n" +
    "export let f = (db: Db) -> (Option[TypeEnv], Db) with { Error } {\n" +
    "  (None, db)\n" +
    "}\n",
  )
  db.set_source(
    "main",
    "import ./dep_api.vibe { Db, f }\n" +
    "let x = handle {\n" +
    "  let (_, db2) = f(Db(1))\n" +
    "  match db2 { Db(n) => n }\n" +
    "} with Error { Throw(_) => -1 }\n" +
    "x\n",
  )
  let env = db.types("main")
  let diags = db.diagnostics("main")
  if !diags.is_empty() {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected diagnostics: " + lines.join(","))
  }
  match env.get_scheme("x") {
    Some(_) => ()
    None => fail("expected scheme for x")
  }
}

///|
test "type query re-exported enum type imports constructors" {
  let db = VibeDb::new()
  db.set_source(
    "./types_impl.vibe",
    "export enum Type {\n" + "  CtInt;\n" + "  CtArray(Type)\n" + "}\n",
  )
  db.set_source(
    "./types.vibe",
    "export ./types_impl.vibe { Type }\n" + "export { Type }\n",
  )
  db.set_source(
    "main",
    "import ./types.vibe { Type }\n" +
    "let value: Type = CtArray(CtInt)\n" +
    "let result = match value { CtArray(inner) => inner, _ => CtInt }\n" +
    "result\n",
  )
  let env = db.types("main")
  let diags = db.diagnostics("main")
  if !diags.is_empty() {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected diagnostics: " + lines.join(","))
  }
  match env.get_scheme("value") {
    Some(scheme) =>
      match scheme.ty {
        @core.Type::Named(name~, ..) => assert_eq(name, "Type")
        _ => fail("expected Type scheme for value")
      }
    None => fail("expected scheme for value")
  }
  match env.get_ctor("CtInt") {
    Some(_) => ()
    None => fail("expected imported constructor: CtInt")
  }
  match env.get_ctor("CtArray") {
    Some(_) => ()
    None => fail("expected imported constructor: CtArray")
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
    "let caller = () -> Array[String] with { Process } { run_lines(\"ok\") }\n" +
    "0\n",
  )
  let env = db.types("main")
  let diags = db.diagnostics("main")
  if !diags.is_empty() {
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
    "  Threads::recv(channel)\n" +
    "}\n" +
    "export let send = (channel: Int, message: String) -> Bool with { Threads } {\n" +
    "  Threads::send(channel, message)\n" +
    "}\n" +
    "export let wait = (task: Int) -> Int with { Threads } {\n" +
    "  Threads::wait(task)\n" +
    "}\n" +
    "export let spawn = (name: String, mailbox: Int) -> Int with { Threads } {\n" +
    "  { Threads::spawn(name, mailbox) }\n" +
    "}\n" +
    "export let probe_wat = () -> String with { Threads } {\n" +
    "  Threads::probe_wat()\n" +
    "}\n" +
    "export let channel_new = (capacity: Int) -> Int with { Threads } {\n" +
    "  Threads::channel_new(capacity)\n" +
    "}\n" +
    "export let runtime_hints = () -> Unit with { Threads } {\n" +
    "  let _ = Threads::runtime_hints()\n" +
    "  if true {\n" +
    "  } else {\n" +
    "  }\n" +
    "}\n",
  )
  let env = db.types("main")
  let diags = db.diagnostics("main")
  if !diags.is_empty() {
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
  if !diags.is_empty() {
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
test "module-level cycle detection: A -> B -> A directories via import" {
  let db = VibeDb::new()
  db.set_source(
    "/project/a/index.vibe", "import ../b/index.vibe { greet }\nexport let hello = () -> String { greet() }\nexport { hello }\n",
  )
  db.set_source(
    "/project/b/index.vibe", "import ../a/index.vibe { hello }\nexport let greet = () -> String { hello() }\nexport { greet }\n",
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
test "module-level cycle detection ignores direct implementation imports" {
  let db = VibeDb::new()
  db.set_source(
    "/project/compiler/type_db.vibe", "export ./runtime { db_new }\n",
  )
  db.set_source(
    "/project/compiler/runtime/index.vibe", "import ../helper.vibe { helper }\nexport let db_new = () -> Int { helper() }\nexport { db_new }\n",
  )
  db.set_source(
    "/project/compiler/helper.vibe", "export let helper = () -> Int { 1 }\nexport { helper }\n",
  )
  let _imports = db.imports("/project/compiler/type_db.vibe")
  let diags = db.import_diagnostics("/project/compiler/type_db.vibe")
  let has_module_cycle = diags
    .iter()
    .any(fn(d) { d.message.contains("module cycle") })
  assert_false(has_module_cycle)
}

///|
test "cross-package re-export is rejected and not shared with siblings" {
  let db = VibeDb::new()
  // External module in /project/lib/
  db.set_source(
    "/project/lib/math.vibe", "export let plus2 = (a: Int, b: Int) -> Int { a + b }\nexport { plus2 }\n",
  )
  // index.vibe in /project/src/ re-exports from external package (forbidden)
  db.set_source(
    "/project/src/index.vibe", "export ../lib/math.vibe { plus2 }\n",
  )
  let _index_imports = db.imports("/project/src/index.vibe")
  let index_import_diags = db.import_diagnostics("/project/src/index.vibe")
  let has_forbidden_reexport_diag = index_import_diags
    .iter()
    .any(fn(d) { d.message.contains("cross-package re-export is forbidden") })
  assert_true(has_forbidden_reexport_diag)
  // sibling.vibe in /project/src/ must not see `plus2` from forbidden re-export
  db.set_source("/project/src/sibling.vibe", "let x = plus2(1, 2)\nx\n")
  let env = db.types("/project/src/sibling.vibe")
  let diags = db.diagnostics("/project/src/sibling.vibe")
  assert_true(diags.length() > 0)
  match env.get_scheme("plus2") {
    Some(_) => fail("forbidden cross-package re-export must not leak plus2")
    None => ()
  }
}

///|
test "cross-package re-export is rejected in index.vibe itself" {
  let db = VibeDb::new()
  db.set_source(
    "/project/lib/math.vibe", "export let plus2 = (a: Int, b: Int) -> Int { a + b }\nexport { plus2 }\n",
  )
  // index.vibe cannot use forbidden cross-package re-exported symbols
  db.set_source(
    "/project/src/index.vibe", "export ../lib/math.vibe { plus2 }\nlet y = plus2(1, 2)\ny\n",
  )
  let env = db.types("/project/src/index.vibe")
  let diags = db.diagnostics("/project/src/index.vibe")
  let has_forbidden_reexport_diag = diags
    .iter()
    .any(fn(d) { d.message.contains("cross-package re-export is forbidden") })
  assert_true(has_forbidden_reexport_diag)
  match env.get_scheme("y") {
    Some(_) => fail("forbidden cross-package re-export should break y")
    None => ()
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

///|
test "preparsed ast cache seeds ast and imports queries" {
  let db = VibeDb::new()
  db.set_source("/project/lib/dep.vibe", "export let dep = 1\nexport { dep }\n")
  let source = "import ./lib/dep.vibe { dep }\nlet x = dep\n"
  let ast = match hook_parse_ast_diagnostic(source) {
    (Some(m), _) => m
    (None, Some(d)) => fail("parse failed: " + d.to_string())
    _ => fail("parse failed")
  }
  db.set_source("/project/main.vibe", source)
  db.set_preparsed_ast("/project/main.vibe", source, ast)
  let loaded_ast = db.ast("/project/main.vibe")
  let imports = db.imports("/project/main.vibe")
  assert_eq(imports.length(), 1)
  match loaded_ast.stmts[1] {
    @core.Stmt::Let(name~, ..) => assert_eq(name, "x")
    _ => fail("expected second stmt to be let x")
  }
}

///|
test "preparsed ast cache is ignored after source changes" {
  let db = VibeDb::new()
  let source1 = "let x = 1\n"
  let ast1 = match hook_parse_ast_diagnostic(source1) {
    (Some(m), _) => m
    (None, Some(d)) => fail("parse failed: " + d.to_string())
    _ => fail("parse failed")
  }
  db.set_source("/project/main.vibe", source1)
  db.set_preparsed_ast("/project/main.vibe", source1, ast1)
  let source2 = "let y = 2\n"
  db.set_source("/project/main.vibe", source2)
  let loaded_ast = db.ast("/project/main.vibe")
  match loaded_ast.stmts[0] {
    @core.Stmt::Let(name~, ..) => assert_eq(name, "y")
    _ => fail("expected let y after source update")
  }
}

///|
test "preparsed import cache seeds imports query" {
  let db = VibeDb::new()
  let source = "import ./lib/dep.vibe { dep }\nlet x = dep\n"
  db.set_source("/project/main.vibe", source)
  db.set_preparsed_imports("/project/main.vibe", source, [
    ImportSpec::{
      path: "/project/lib/dep.vibe",
      alias_name: @core.import_alias_name("./lib/dep.vibe"),
      hash: Some("abc"),
      module_ref: Some(@core.module_ref_from_hash("abc")),
      path_obj: None,
      source_hash: Some("abc"),
      source_version: None,
      source_symbol: None,
    },
  ])
  let imports = db.imports("/project/main.vibe")
  assert_eq(imports.length(), 1)
  assert_eq(imports[0].path, "/project/lib/dep.vibe")
}

///|
test "preparsed import cache is ignored after source changes" {
  let db = VibeDb::new()
  let source1 = "import ./lib/a.vibe { a }\n"
  db.set_source("/project/main.vibe", source1)
  db.set_source("/project/lib/a.vibe", "export let a = 1\nexport { a }\n")
  db.set_source("/project/lib/b.vibe", "export let b = 2\nexport { b }\n")
  db.set_preparsed_imports("/project/main.vibe", source1, [
    ImportSpec::{
      path: "/project/lib/a.vibe",
      alias_name: @core.import_alias_name("./lib/a.vibe"),
      hash: Some("abc"),
      module_ref: Some(@core.module_ref_from_hash("abc")),
      path_obj: None,
      source_hash: Some("abc"),
      source_version: None,
      source_symbol: None,
    },
  ])
  let source2 = "import ./lib/b.vibe { b }\n"
  db.set_source("/project/main.vibe", source2)
  let imports = db.imports("/project/main.vibe")
  assert_eq(imports.length(), 1)
  assert_eq(imports[0].path, "/project/lib/b.vibe")
}

///|
test "type import query backdates when dependency private impl changes" {
  let db = VibeDb::new()
  db.set_source(
    "/project/lib.vibe",
    "let helper = 1\n" + "export let value = helper\n",
  )
  db.set_source(
    "/project/main.vibe",
    "import ./lib.vibe { value }\n" + "let x = value\n" + "x\n",
  )
  let _ = db.types("/project/main.vibe")
  let lib_type_changed_1 = match
    db.queries.type_query.changed_at("/project/lib.vibe") {
    Some(rev) => rev.get()
    None => fail("expected lib type_query revision")
  }
  let lib_import_changed_1 = match
    db.queries.type_import_query.changed_at("/project/lib.vibe") {
    Some(rev) => rev.get()
    None => fail("expected lib type_import_query revision")
  }
  let main_type_changed_1 = match
    db.queries.type_query.changed_at("/project/main.vibe") {
    Some(rev) => rev.get()
    None => fail("expected main type_query revision")
  }
  db.set_source(
    "/project/lib.vibe",
    "let helper = 2 - 1\n" + "export let value = helper\n",
  )
  let _ = db.types("/project/main.vibe")
  let lib_type_changed_2 = match
    db.queries.type_query.changed_at("/project/lib.vibe") {
    Some(rev) => rev.get()
    None => fail("expected lib type_query revision after update")
  }
  let lib_import_changed_2 = match
    db.queries.type_import_query.changed_at("/project/lib.vibe") {
    Some(rev) => rev.get()
    None => fail("expected lib type_import_query revision after update")
  }
  let main_type_changed_2 = match
    db.queries.type_query.changed_at("/project/main.vibe") {
    Some(rev) => rev.get()
    None => fail("expected main type_query revision after update")
  }
  assert_true(lib_type_changed_2 > lib_type_changed_1)
  assert_eq(lib_import_changed_2, lib_import_changed_1)
  assert_eq(main_type_changed_2, main_type_changed_1)
}

///|
test "downstream type query does not re-run on dependency private impl change" {
  let db = VibeDb::new()
  db.set_source(
    "/project/lib.vibe",
    "let helper = 1\n" + "export let value = helper\n",
  )
  db.set_source(
    "/project/main.vibe",
    "import ./lib.vibe { value, value }\n" + "let x = value\n" + "x\n",
  )
  let _ = db.types("/project/main.vibe")
  let duplicate_count_1 = db
    .diagnostics("/project/main.vibe")
    .iter()
    .filter(fn(diag) { diag.message == "duplicate declaration: value" })
    .count()
  assert_eq(duplicate_count_1, 1)
  db.set_source(
    "/project/lib.vibe",
    "let helper = 2 - 1\n" + "export let value = helper\n",
  )
  let _ = db.types("/project/main.vibe")
  let duplicate_count_2 = db
    .diagnostics("/project/main.vibe")
    .iter()
    .filter(fn(diag) { diag.message == "duplicate declaration: value" })
    .count()
  assert_eq(duplicate_count_2, 1)
}
