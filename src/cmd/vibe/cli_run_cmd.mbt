///|
fn cli_use_session_http_with(raw : String?, _has_self_bin : Bool) -> Bool {
  match raw {
    Some(value) => parse_bool_flag(value)
    None => false
  }
}

///|
fn cli_use_session_http() -> Bool {
  cli_use_session_http_with(
    @sys.get_env_var("VIBE_USE_SESSION_HTTP"),
    current_cli_binary_path() is Some(_),
  )
}

///|
fn first_non_empty_line(text : String) -> String {
  for line_view in text.split("\n") {
    let line = line_view.trim().to_owned()
    if line.length() > 0 {
      return line
    }
  }
  ""
}

///|
fn last_non_empty_line(text : String) -> String {
  let mut out = ""
  for line_view in text.split("\n") {
    let line = line_view.trim().to_owned()
    if line.length() > 0 {
      out = line
    }
  }
  out
}

///|
fn parse_numeric_line_int64(line : String) -> Int64? {
  let trimmed = line.trim().to_owned()
  if trimmed.length() == 0 {
    return None
  }
  let mut has_digit = false
  for i, c in trimmed {
    if i == 0 && c == '-' {
      continue
    }
    if c < '0' || c > '9' {
      return None
    }
    has_digit = true
  }
  if !has_digit {
    return None
  }
  let value = @string.parse_int(trimmed) catch { _ => return None }
  Some(value.to_int64())
}

///|
fn parse_last_numeric_line_int64(text : String) -> Int64? {
  let mut out : Int64? = None
  for line_view in text.split("\n") {
    let line = line_view.to_owned()
    match parse_numeric_line_int64(line) {
      Some(value) => out = Some(value)
      None => ()
    }
  }
  out
}

///|
struct WasmtimeInvokeOutput {
  status : Int
  stdout : String
  stderr : String
} derive(Debug, Eq)

///|
struct HttpHostRunner {
  node_bin : String
  node_flags : Array[String]
  runner_script : String
} derive(Debug, Eq)

///|
enum WasmRunValue {
  Int(Int64)
  Bool(Bool)
} derive(Debug, Eq)

///|
let cli_tagged_run_export_name = "_vibe_run_tagged"

///|
fn run_wasmtime_invoke_run_capture(
  runner : BenchWasmRunner,
  wasm_path : String,
  tmp_prefix : String,
) -> WasmtimeInvokeOutput {
  run_wasmtime_invoke_named_capture(
    runner, wasm_path, tmp_prefix, cli_tagged_run_export_name,
  )
}

///|
fn run_wasmtime_invoke_named_capture(
  runner : BenchWasmRunner,
  wasm_path : String,
  tmp_prefix : String,
  invoke_name : String,
) -> WasmtimeInvokeOutput {
  let out_path = tmp_prefix + ".out"
  let err_path = tmp_prefix + ".err"
  let cmd = build_wasmtime_invoke_command(runner, wasm_path, invoke_name) +
    " >" +
    shell_quote_command_arg(out_path) +
    " 2>" +
    shell_quote_command_arg(err_path)
  let status = c_system(system_command_bytes(cmd))
  let stdout = @os_fs.read_file_to_string(out_path) catch { _ => "" }
  let stderr = @os_fs.read_file_to_string(err_path) catch { _ => "" }
  remove_file_if_exists(out_path)
  remove_file_if_exists(err_path)
  { status, stdout, stderr }
}

///|
fn resolve_http_host_runner(
  entry_path : String,
) -> Result[HttpHostRunner, String] {
  let node_bin = match @sys.get_env_var("NODE_BIN") {
    Some(raw) => {
      let value = raw.trim().to_owned()
      if value.length() > 0 {
        value
      } else {
        match find_command_in_path("node") {
          Some(path) => path
          None =>
            return Err(
              "node not found in PATH (required for HTTP compiled backend)",
            )
        }
      }
    }
    None =>
      match find_command_in_path("node") {
        Some(path) => path
        None =>
          return Err(
            "node not found in PATH (required for HTTP compiled backend)",
          )
      }
  }
  let node_flags = resolve_http_host_runner_node_flags()
  let root_candidates : Array[String] = []
  let add_root = fn(root : String) -> Unit {
    if root.length() == 0 {
      return
    }
    for existing in root_candidates {
      if existing == root {
        return
      }
    }
    root_candidates.push(root)
  }
  add_root(project_root_for_path(entry_path))
  let argv = @env.args()
  if argv.length() > 0 {
    add_root(project_root_for_path(argv[0]))
  }
  add_root(project_root_for_path(@io.current_dir_or_root()))
  // Prefer wasm_vibe_host_runner.js (supports Fs + HTTP + Env),
  // fall back to wasm_http_host_runner.js (HTTP only)
  for project_root in root_candidates {
    let vibe_runner = project_root + "/scripts/wasm_vibe_host_runner.js"
    if is_existing_file(vibe_runner) {
      return Ok({ node_bin, node_flags, runner_script: vibe_runner })
    }
    let http_runner = project_root + "/scripts/wasm_http_host_runner.js"
    if is_existing_file(http_runner) {
      return Ok({ node_bin, node_flags, runner_script: http_runner })
    }
  }
  Err(
    "host runner script not found under project roots: " +
    root_candidates.join(", "),
  )
}

///|
fn split_command_flag_words(raw : String) -> Array[String] {
  let out : Array[String] = []
  for part in raw.trim().to_owned().split(" ") {
    let token = part.trim().to_owned()
    if token.length() > 0 {
      out.push(token)
    }
  }
  out
}

///|
fn resolve_http_host_runner_node_flags() -> Array[String] {
  match @sys.get_env_var("VIBE_NODE_WASM_FLAGS") {
    Some(raw) => split_command_flag_words(raw)
    None => split_command_flag_words("--experimental-wasm-exnref")
  }
}

///|
fn build_http_host_run_command(
  runner : HttpHostRunner,
  wasm_path : String,
) -> String {
  let cmd = StringBuilder::new()
  cmd.write_string(shell_quote_command_arg(runner.node_bin))
  for flag in runner.node_flags {
    cmd.write_string(" ")
    cmd.write_string(shell_quote_command_arg(flag))
  }
  cmd.write_string(" ")
  cmd.write_string(shell_quote_command_arg(runner.runner_script))
  cmd.write_string(" --invoke ")
  cmd.write_string(cli_tagged_run_export_name)
  cmd.write_string(" ")
  cmd.write_string(shell_quote_command_arg(wasm_path))
  cmd.to_string()
}

///|
fn build_http_host_run_command_with_invokes(
  runner : HttpHostRunner,
  wasm_path : String,
  invokes : Array[String],
) -> String {
  let cmd = StringBuilder::new()
  cmd.write_string(shell_quote_command_arg(runner.node_bin))
  for flag in runner.node_flags {
    cmd.write_string(" ")
    cmd.write_string(shell_quote_command_arg(flag))
  }
  cmd.write_string(" ")
  cmd.write_string(shell_quote_command_arg(runner.runner_script))
  for invoke_name in invokes {
    cmd.write_string(" --invoke ")
    cmd.write_string(shell_quote_command_arg(invoke_name))
  }
  cmd.write_string(" ")
  cmd.write_string(shell_quote_command_arg(wasm_path))
  cmd.to_string()
}

///|
fn run_http_host_invoke_run_capture(
  runner : HttpHostRunner,
  wasm_path : String,
  tmp_prefix : String,
) -> WasmtimeInvokeOutput {
  run_http_host_invoke_run_capture_with_invokes(runner, wasm_path, tmp_prefix, [
    cli_tagged_run_export_name,
  ])
}

///|
fn run_http_host_invoke_run_capture_with_invokes(
  runner : HttpHostRunner,
  wasm_path : String,
  tmp_prefix : String,
  invokes : Array[String],
) -> WasmtimeInvokeOutput {
  let out_path = tmp_prefix + ".out"
  let err_path = tmp_prefix + ".err"
  let cmd = build_http_host_run_command_with_invokes(runner, wasm_path, invokes) +
    " >" +
    shell_quote_command_arg(out_path) +
    " 2>" +
    shell_quote_command_arg(err_path)
  let status = c_system(system_command_bytes(cmd))
  let stdout = @os_fs.read_file_to_string(out_path) catch { _ => "" }
  let stderr = @os_fs.read_file_to_string(err_path) catch { _ => "" }
  remove_file_if_exists(out_path)
  remove_file_if_exists(err_path)
  { status, stdout, stderr }
}

///|
fn decode_tagged_wasm_run_value(tagged : Int64) -> WasmRunValue? {
  let tag = tagged & 3L
  if tag == 0L {
    return Some(WasmRunValue::Int(tagged >> 2))
  }
  if tag == 3L {
    return Some(WasmRunValue::Bool(tagged >> 2 != 0L))
  }
  None
}

///|
fn is_http_builtin_name(name : String) -> Bool {
  match name {
    "Http::request"
    | "Http::response_status"
    | "Http::response_header"
    | "Http::response_body"
    | "Http::close"
    | "Http::listen"
    | "Http::accept"
    | "Http::request_method"
    | "Http::request_url"
    | "Http::request_header"
    | "Http::request_body"
    | "Http::respond" => true
    _ => false
  }
}

///|
fn is_wasm_runtime_fallback_builtin_name(name : String) -> Bool {
  match name {
    "Json::parse"
    | "Json::stringify"
    | "Json::parse_lines"
    | "Json::stringify_lines"
    | "Lines::parse"
    | "Lines::stringify"
    | "Json::type_of"
    | "Json::string"
    | "Json::get"
    | "Json::index"
    | "Json::number"
    | "Json::bool"
    | "Json::is_null"
    | "Json::length"
    | "Json::keys"
    | "Fs::read_file"
    | "Fs::write_file"
    | "Fs::write_bytes"
    | "Fs::exists"
    | "Fs::chdir"
    | "Fs::copy"
    | "Fs::readdir"
    | "Fs::is_dir"
    | "Fs::is_file"
    | "Fs::mkdir"
    | "Fs::mkdir_p"
    | "Fs::getcwd"
    | "Fs::remove"
    | "Fs::rename"
    | "Fs::append"
    | "Fs::open_write"
    | "Fs::write_chunk"
    | "Fs::close_write"
    | "Llm::complete"
    | "Rlm::run"
    | "Rlm::finalize"
    | "PromptText::new"
    | "PromptText::to_string"
    | "select"
    | "sh"
    | "sh_lines"
    | "path"
    | "Path::ref"
    | "Path::resolve"
    | "Env::get"
    | "Env::args_len"
    | "Env::args_get"
    | "__perform"
    | "__resume" => true
    _ => false
  }
}

///|
fn expr_uses_wasm_runtime_fallback_builtins(expr : @vibe_core.Expr) -> Bool {
  match expr {
    @vibe_core.Expr::Call(name~, args~, ..) => {
      if is_wasm_runtime_fallback_builtin_name(name) {
        return true
      }
      for arg in args {
        if expr_uses_wasm_runtime_fallback_builtins(arg.expr) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Tuple(items~, ..) => {
      for item in items {
        if expr_uses_wasm_runtime_fallback_builtins(item) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::TupleIndex(expr~, ..) =>
      expr_uses_wasm_runtime_fallback_builtins(expr)
    @vibe_core.Expr::Record(fields~, ..)
    | @vibe_core.Expr::StructLit(fields~, ..) => {
      for field in fields {
        if expr_uses_wasm_runtime_fallback_builtins(field.expr) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Array(items~, ..) => {
      for item in items {
        if expr_uses_wasm_runtime_fallback_builtins(item) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Map(fields~, ..) => {
      for field in fields {
        if expr_uses_wasm_runtime_fallback_builtins(field.expr) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::If(cond~, then_body~, else_body~, ..) =>
      expr_uses_wasm_runtime_fallback_builtins(cond) ||
      module_uses_wasm_runtime_fallback_builtins(then_body) ||
      module_uses_wasm_runtime_fallback_builtins(else_body)
    @vibe_core.Expr::Block(body~, ..) =>
      module_uses_wasm_runtime_fallback_builtins(body)
    @vibe_core.Expr::Match(scrutinee~, arms~, ..) => {
      if expr_uses_wasm_runtime_fallback_builtins(scrutinee) {
        return true
      }
      for arm in arms {
        if expr_uses_wasm_runtime_fallback_builtins(arm.expr) {
          return true
        }
        match arm.cond {
          Some(cond) =>
            if expr_uses_wasm_runtime_fallback_builtins(cond) {
              return true
            }
          None => ()
        }
      }
      false
    }
    @vibe_core.Expr::ForIn(iterable~, body~, ..) =>
      expr_uses_wasm_runtime_fallback_builtins(iterable) ||
      module_uses_wasm_runtime_fallback_builtins(body)
    @vibe_core.Expr::Fn(body~, ..) =>
      module_uses_wasm_runtime_fallback_builtins(body)
    @vibe_core.Expr::While(cond~, body~, ..) =>
      expr_uses_wasm_runtime_fallback_builtins(cond) ||
      module_uses_wasm_runtime_fallback_builtins(body)
    @vibe_core.Expr::Loop(params~, body~, ..) => {
      for param in params {
        if expr_uses_wasm_runtime_fallback_builtins(param.init) {
          return true
        }
      }
      module_uses_wasm_runtime_fallback_builtins(body)
    }
    @vibe_core.Expr::Break(value~, ..) =>
      match value {
        Some(v) => expr_uses_wasm_runtime_fallback_builtins(v)
        None => false
      }
    @vibe_core.Expr::Continue(args~, ..) => {
      for arg in args {
        if expr_uses_wasm_runtime_fallback_builtins(arg) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Yield(expr~, ..) =>
      expr_uses_wasm_runtime_fallback_builtins(expr)
    @vibe_core.Expr::Handle(body~, arms~, ..) => {
      if module_uses_wasm_runtime_fallback_builtins(body) {
        return true
      }
      for arm in arms {
        if expr_uses_wasm_runtime_fallback_builtins(arm.expr) {
          return true
        }
        match arm.cond {
          Some(cond) =>
            if expr_uses_wasm_runtime_fallback_builtins(cond) {
              return true
            }
          None => ()
        }
      }
      false
    }
    // `perform Effect::Op(...)` for capability effects (Fs/Stdin/Stdout/Net/
    // Env/Process) lowers to a host import call that wasmtime cannot resolve;
    // route those modules through the node-based host runner instead.
    @vibe_core.Expr::Perform(effect_name~, args~, ..) => {
      if effect_name == "Fs" ||
        effect_name == "Stdin" ||
        effect_name == "Stdout" ||
        effect_name == "Net" ||
        effect_name == "Socket" ||
        effect_name == "Http" ||
        effect_name == "Env" ||
        effect_name == "Process" {
        return true
      }
      for arg in args {
        if expr_uses_wasm_runtime_fallback_builtins(arg.expr) {
          return true
        }
      }
      false
    }
    _ => false
  }
}

///|
fn stmt_uses_wasm_runtime_fallback_builtins(stmt : @vibe_core.Stmt) -> Bool {
  match stmt {
    @vibe_core.Stmt::Let(expr~, ..)
    | @vibe_core.Stmt::LetMut(expr~, ..)
    | @vibe_core.Stmt::Assign(expr~, ..)
    | @vibe_core.Stmt::LetPat(expr~, ..)
    | @vibe_core.Stmt::Expr(expr~, ..)
    | @vibe_core.Stmt::ExportLet(expr~, ..)
    | @vibe_core.Stmt::InternalExportLet(expr~, ..) =>
      expr_uses_wasm_runtime_fallback_builtins(expr)
    @vibe_core.Stmt::IndexAssign(target~, index~, value~, ..) =>
      expr_uses_wasm_runtime_fallback_builtins(target) ||
      expr_uses_wasm_runtime_fallback_builtins(index) ||
      expr_uses_wasm_runtime_fallback_builtins(value)
    @vibe_core.Stmt::LetPatElse(expr~, else_body~, ..) =>
      expr_uses_wasm_runtime_fallback_builtins(expr) ||
      module_uses_wasm_runtime_fallback_builtins(else_body)
    @vibe_core.Stmt::Test(body~, ..) | @vibe_core.Stmt::Bench(body~, ..) =>
      module_uses_wasm_runtime_fallback_builtins(body)
    _ => false
  }
}

///|
fn module_uses_wasm_runtime_fallback_builtins(ast : @vibe_core.Module) -> Bool {
  for stmt in ast.stmts {
    if stmt_uses_wasm_runtime_fallback_builtins(stmt) {
      return true
    }
  }
  false
}

///|
fn expr_uses_http_builtins(expr : @vibe_core.Expr) -> Bool {
  match expr {
    @vibe_core.Expr::Call(name~, args~, ..) => {
      if is_http_builtin_name(name) {
        return true
      }
      for arg in args {
        if expr_uses_http_builtins(arg.expr) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Tuple(items~, ..) => {
      for item in items {
        if expr_uses_http_builtins(item) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::TupleIndex(expr~, ..) => expr_uses_http_builtins(expr)
    @vibe_core.Expr::Record(fields~, ..)
    | @vibe_core.Expr::StructLit(fields~, ..) => {
      for field in fields {
        if expr_uses_http_builtins(field.expr) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Array(items~, ..) => {
      for item in items {
        if expr_uses_http_builtins(item) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Map(fields~, ..) => {
      for field in fields {
        if expr_uses_http_builtins(field.expr) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::If(cond~, then_body~, else_body~, ..) =>
      expr_uses_http_builtins(cond) ||
      module_uses_http_builtins(then_body) ||
      module_uses_http_builtins(else_body)
    @vibe_core.Expr::Block(body~, ..) => module_uses_http_builtins(body)
    @vibe_core.Expr::Match(scrutinee~, arms~, ..) => {
      if expr_uses_http_builtins(scrutinee) {
        return true
      }
      for arm in arms {
        if expr_uses_http_builtins(arm.expr) {
          return true
        }
        match arm.cond {
          Some(cond) => if expr_uses_http_builtins(cond) { return true }
          None => ()
        }
      }
      false
    }
    @vibe_core.Expr::ForIn(iterable~, body~, ..) =>
      expr_uses_http_builtins(iterable) || module_uses_http_builtins(body)
    @vibe_core.Expr::Fn(body~, ..) => module_uses_http_builtins(body)
    @vibe_core.Expr::While(cond~, body~, ..) =>
      expr_uses_http_builtins(cond) || module_uses_http_builtins(body)
    @vibe_core.Expr::Loop(params~, body~, ..) => {
      for param in params {
        if expr_uses_http_builtins(param.init) {
          return true
        }
      }
      module_uses_http_builtins(body)
    }
    @vibe_core.Expr::Break(value~, ..) =>
      match value {
        Some(v) => expr_uses_http_builtins(v)
        None => false
      }
    @vibe_core.Expr::Continue(args~, ..) => {
      for arg in args {
        if expr_uses_http_builtins(arg) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Yield(expr~, ..) => expr_uses_http_builtins(expr)
    @vibe_core.Expr::Handle(body~, arms~, ..) => {
      if module_uses_http_builtins(body) {
        return true
      }
      for arm in arms {
        if expr_uses_http_builtins(arm.expr) {
          return true
        }
        match arm.cond {
          Some(cond) => if expr_uses_http_builtins(cond) { return true }
          None => ()
        }
      }
      false
    }
    _ => false
  }
}

///|
fn stmt_uses_http_builtins(stmt : @vibe_core.Stmt) -> Bool {
  match stmt {
    @vibe_core.Stmt::Let(expr~, ..)
    | @vibe_core.Stmt::LetMut(expr~, ..)
    | @vibe_core.Stmt::Assign(expr~, ..)
    | @vibe_core.Stmt::LetPat(expr~, ..)
    | @vibe_core.Stmt::Expr(expr~, ..)
    | @vibe_core.Stmt::ExportLet(expr~, ..)
    | @vibe_core.Stmt::InternalExportLet(expr~, ..) =>
      expr_uses_http_builtins(expr)
    @vibe_core.Stmt::IndexAssign(target~, index~, value~, ..) =>
      expr_uses_http_builtins(target) ||
      expr_uses_http_builtins(index) ||
      expr_uses_http_builtins(value)
    @vibe_core.Stmt::LetPatElse(expr~, else_body~, ..) =>
      expr_uses_http_builtins(expr) || module_uses_http_builtins(else_body)
    @vibe_core.Stmt::Test(body~, ..) | @vibe_core.Stmt::Bench(body~, ..) =>
      module_uses_http_builtins(body)
    _ => false
  }
}

///|
fn module_uses_http_builtins(ast : @vibe_core.Module) -> Bool {
  for stmt in ast.stmts {
    if stmt_uses_http_builtins(stmt) {
      return true
    }
  }
  false
}

///|
fn detect_exec_host_runner_requirements(
  db : @runtime.VibeDb,
  entry : String,
) -> (Bool, Bool) {
  let ast = db.ast(entry)
  let detect_ast = @runtime_compile.bundle_for_wasm_no_dce(db, entry, ast)
  (
    module_uses_http_builtins(detect_ast),
    module_uses_wasm_runtime_fallback_builtins(detect_ast),
  )
}

///|
fn compile_module_wasm_for_exec(
  db : @runtime.VibeDb,
  entry : String,
  http_host_imports? : Bool = false,
  fs_host_imports? : Bool = false,
) -> Bytes raise @runtime_compile.WasmCompileError {
  @runtime_compile.compile_module_wasm_with_opt_level(
    db,
    entry,
    no_dce=false,
    opt_level=None,
    // Preserve thrown string payloads for `handle { ... } with Error { Throw(msg) => ... }`
    // across compiled CLI execution paths.
    debug_errors=true,
    http_host_imports~,
    fs_host_imports~,
  )
}

///|
fn emit_module_source_cmd(args : Array[String]) -> Unit {
  if args.length() != 3 {
    abort("emit-module-source: expected <in> <out> <entry>")
  }
  let fs = @io.default_fs_adapter()
  match emit_module_source_file(args[0], args[1], args[2], fs) {
    Ok(_) => ()
    Err(msg) => abort("emit-module-source: " + msg)
  }
}

///|
fn emit_closure_payload_cmd(args : Array[String]) -> Unit {
  if args.length() != 2 {
    abort("emit-closure-payload: expected <in> <out>")
  }
  let fs = @io.default_fs_adapter()
  match emit_closure_payload_file(args[0], args[1], fs) {
    Ok(_) => ()
    Err(msg) => abort("emit-closure-payload: " + msg)
  }
}

///|
fn compile_closure_payload_cmd(args : Array[String]) -> Unit {
  if args.length() < 2 || args.length() > 3 {
    abort("compile-closure-payload: expected <in> <out> [mvp|no-dce]")
  }
  let mode = if args.length() == 3 { args[2] } else { "mvp" }
  let fs = @io.default_fs_adapter()
  match compile_closure_payload_file(args[0], args[1], mode, fs) {
    Ok(_) => ()
    Err(msg) => abort("compile-closure-payload: " + msg)
  }
}

///|
/// Fast linked run: reuse cached library .wasm, compile only user code.
fn run_cmd_wasm_linked(
  entry_path : String,
  resolved : String,
  parent : String,
  cache_dir : String,
) -> Result[WasmRunValue, String] {
  let _ = entry_path
  // Read cached linked imports
  let imports_cache = cache_dir + "/linked_imports.txt"
  let cached_text = @os_fs.read_file_to_string(imports_cache) catch {
    _ => return Err("read cache failed")
  }
  let cached_imports = parse_linked_imports_cache(cached_text)
  if cached_imports.length() == 0 {
    return Err("empty linked imports")
  }
  // Check source hashes
  let hash_cache = cache_dir + "/source_hashes.txt"
  if @os_fs.path_exists(hash_cache) {
    let hash_text = @os_fs.read_file_to_string(hash_cache) catch { _ => "" }
    let saved = parse_source_hash_cache(hash_text)
    for path, saved_hash in saved {
      let src = @os_fs.read_file_to_string(path) catch { _ => "" }
      if src.length() > 0 {
        let h = @vibe_core.content_address_hash_string(src)
        if h != saved_hash {
          return Err("source changed")
        }
      }
    }
  }
  // Verify all library .wasm exist
  let module_names : Map[String, Bool] = {}
  for li in cached_imports {
    if !module_names.contains(li.module_name) {
      module_names[li.module_name] = true
      let lib_path = cache_dir + "/" + li.module_name + ".wasm"
      if !@os_fs.path_exists(lib_path) {
        return Err("missing library")
      }
    }
  }
  // Compile user code only
  let source = @os_fs.read_file_to_string(resolved) catch {
    e => return Err(e.to_string())
  }
  let raw_ast = @parser.parse_ast(source) catch {
    e => return Err(e.to_string())
  }
  let desugared = @frontend.desugar_method_calls(raw_ast, {})
  let ast = @frontend.rewrite_effect_handles(desugared)
  let codegen_linked : Array[(String, String, Int, Int)] = []
  for li in cached_imports {
    codegen_linked.push(
      (li.module_name, li.func_name, li.param_count, li.return_count),
    )
  }
  let (bundled, _) = @runtime_compile.bundle_for_wasm_linked_with_imports(
    ast, cached_imports,
  )
  let wasm_bytes = @runtime_compile.emit_wasm_with_linked_imports(
    bundled, codegen_linked,
  ) catch {
    e => return Err(e.to_string())
  }
  // Write user wasm
  let stamp = @env.now().to_string() + "_" + vibe_getpid().to_string()
  let wasm_path = parent + "/.vibe_run_linked_" + stamp + ".wasm"
  @os_fs.write_bytes_to_file(wasm_path, wasm_bytes) catch {
    e => return Err(e.to_string())
  }
  // Build preload args and run
  let runner = match resolve_bench_wasm_runner(resolved) {
    Ok(v) => v
    Err(err) => {
      remove_file_if_exists(wasm_path)
      return Err(err)
    }
  }
  let mut cmd = build_wasmtime_invoke_command(
    runner, wasm_path, cli_tagged_run_export_name,
  )
  let seen : Map[String, Bool] = {}
  for li in cached_imports {
    if !seen.contains(li.module_name) {
      seen[li.module_name] = true
      let lib_path = cache_dir + "/" + li.module_name + ".wasm"
      cmd = shell_quote_command_arg(runner.wasmtime_bin)
      for flag in runner.wasm_flags {
        cmd = cmd + " -W " + shell_quote_command_arg(flag)
      }
      for flag in runner.wasi_flags {
        cmd = cmd + " -S " + shell_quote_command_arg(flag)
      }
      cmd = cmd +
        " --preload " +
        shell_quote_command_arg(li.module_name) +
        "=" +
        shell_quote_command_arg(lib_path)
      cmd = cmd +
        " --invoke " +
        cli_tagged_run_export_name +
        " " +
        shell_quote_command_arg(wasm_path)
    }
  }
  let out_path = wasm_path + ".out"
  let err_path = wasm_path + ".err"
  let full_cmd = cmd +
    " >" +
    shell_quote_command_arg(out_path) +
    " 2>" +
    shell_quote_command_arg(err_path)
  let status = c_system(system_command_bytes(full_cmd))
  let stdout = @os_fs.read_file_to_string(out_path) catch { _ => "" }
  let stderr = @os_fs.read_file_to_string(err_path) catch { _ => "" }
  remove_file_if_exists(out_path)
  remove_file_if_exists(err_path)
  remove_file_if_exists(wasm_path)
  if status != 0 {
    let detail = wasmtime_failure_detail(stdout, stderr)
    return Err("linked run failed: " + detail)
  }
  let tagged = match parse_last_numeric_line_int64(stdout) {
    Some(v) => v
    None => return Err("linked run: missing numeric result")
  }
  match decode_tagged_wasm_run_value(tagged) {
    Some(result) => Ok(result)
    None => Err("linked run: unsupported tag: " + tagged.to_string())
  }
}

///|
fn run_cmd_wasm_backend_with_cache(
  cache : CliEntryDbCache,
  entry_path : String,
) -> Result[WasmRunValue, String] {
  // Default: linked build (debug mode). Use VIBE_RUN_BACKEND=release for monolithic.
  let force_release = match @sys.get_env_var("VIBE_RUN_BACKEND") {
    Some("release") | Some("monolithic") => true
    _ => false
  }
  if !force_release {
    let resolved = @loader.resolve_entry_path(entry_path)
    let parent = @vibe_fs.parent_path(resolved)
    let (vibe_root, cache_key) = find_vibe_cache_root(resolved)
    let cache_dir = vibe_root + "/debug/" + cache_key
    let imports_cache = cache_dir + "/linked_imports.txt"
    // If cache exists, try linked fast path
    if @os_fs.path_exists(imports_cache) {
      match run_cmd_wasm_linked(entry_path, resolved, parent, cache_dir) {
        Ok(v) => return Ok(v)
        Err(_) => () // fall through
      }
    }
    // No cache yet: fall through to monolithic run.
    // After execution, spawn background cache creation for next run.
  }
  // Monolithic fallback
  let (db, entry) = match load_db_for_run_with_cache(cache, entry_path) {
    Err(err) => return Err("load error: " + err)
    Ok(v) => v
  }
  let (use_http_host_runner, use_fs_host_runner) = detect_exec_host_runner_requirements(
    db, entry,
  )
  let use_node_runner = use_http_host_runner || use_fs_host_runner
  let http_runner = match use_node_runner {
    true =>
      match resolve_http_host_runner(entry) {
        Ok(v) => Some(v)
        Err(err) => return Err(err)
      }
    false => None
  }
  let runner = match resolve_bench_wasm_runner(entry) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let parent = @vibe_fs.parent_path(entry)
  let stamp = @env.now().to_string() + "_" + vibe_getpid().to_string()
  let (run_cache_dir, cached_wasm_path, cached_hash_path) = run_monolithic_cache_paths(
    entry, use_node_runner,
  )
  let current_hashes = collect_source_hash_cache(db, entry, true)
  let has_cached_wasm = @os_fs.path_exists(cached_wasm_path)
  let has_cached_hashes = @os_fs.path_exists(cached_hash_path)
  let use_cached_wasm = if has_cached_wasm && has_cached_hashes {
    let saved_hashes = parse_source_hash_cache(
      @os_fs.read_file_to_string(cached_hash_path) catch {
        _ => ""
      },
    )
    source_hash_cache_matches(saved_hashes, current_hashes)
  } else {
    false
  }
  let wasm_path = if use_cached_wasm {
    cached_wasm_path
  } else {
    parent + "/.vibe_run_wasm_" + stamp + ".wasm"
  }
  if !use_cached_wasm {
    let wasm_bytes = compile_module_wasm_for_exec(
      db,
      entry,
      http_host_imports=use_node_runner,
      fs_host_imports=use_node_runner,
    ) catch {
      e => return Err("compile wasm error: " + e.user_message())
    }
    @os_fs.write_bytes_to_file(wasm_path, wasm_bytes) catch {
      e => return Err("write wasm failed: " + e.to_string())
    }
    match ensure_parent_dir_for_file(cached_wasm_path, "run cache") {
      Ok(_) => {
        @os_fs.write_bytes_to_file(cached_wasm_path, wasm_bytes) catch {
          _ => ()
        }
        @os_fs.write_string_to_file(
          cached_hash_path,
          serialize_source_hash_cache(current_hashes),
        ) catch {
          _ => ()
        }
        let _ = run_cache_dir
      }
      Err(_) => ()
    }
  }
  defer (if !use_cached_wasm { remove_file_if_exists(wasm_path) })
  let exec_out = match http_runner {
    Some(host_runner) =>
      run_http_host_invoke_run_capture(
        host_runner,
        wasm_path,
        parent + "/.vibe_run_http_host_" + stamp,
      )
    None =>
      run_wasmtime_invoke_run_capture(
        runner,
        wasm_path,
        parent + "/.vibe_run_wasmtime_" + stamp,
      )
  }
  if exec_out.status != 0 {
    let detail = first_non_empty_line(exec_out.stderr)
    let runner_name = if use_node_runner {
      "node host runner"
    } else {
      "wasmtime"
    }
    if detail.length() > 0 {
      return Err(
        runner_name +
        " command failed: status=" +
        exec_out.status.to_string() +
        " detail=" +
        detail,
      )
    }
    return Err(
      runner_name + " command failed: status=" + exec_out.status.to_string(),
    )
  }
  // Check for VIBE_DISPLAY: prefix from Node runner
  let node_display = extract_vibe_display_line_run(exec_out.stdout)
  let tagged = match parse_last_numeric_line_int64(exec_out.stdout) {
    Some(v) => v
    None =>
      return Err(
        (if use_node_runner { "node host runner" } else { "wasmtime" }) +
        " output missing numeric result: " +
        first_non_empty_line(exec_out.stdout),
      )
  }
  match node_display {
    Some(display) => {
      println("last: " + display)
      Ok(WasmRunValue::Int(0L))
    }
    None =>
      match decode_tagged_wasm_run_value(tagged) {
        Some(result) => Ok(result)
        None => Err("unsupported wasm return tag: " + tagged.to_string())
      }
  }
}

///|
fn extract_vibe_display_line_run(stdout : String) -> String? {
  for line_view in stdout.split("\n") {
    let line = line_view.to_owned()
    if line.has_prefix("VIBE_DISPLAY:") {
      return Some(line[13:].to_owned())
    }
  }
  None
}

///|
fn run_cmd_wasm_backend(entry_path : String) -> Result[WasmRunValue, String] {
  run_cmd_wasm_backend_with_cache(CliEntryDbCache::new(), entry_path)
}

///|
fn print_wasm_run_value(value : WasmRunValue) -> Unit {
  match value {
    WasmRunValue::Int(n) => println("last: " + n.to_string())
    WasmRunValue::Bool(b) => println("last: " + b.to_string())
  }
}

///|
fn run_cmd(
  args : Array[String],
  _syntax_mode : @runtime.ParserMode,
  _features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  @runtime_compile.init_hooks()
  let _ = enable_llm
  if has_help_flag(args) {
    print_run_help()
    return
  }
  if args.length() != 1 {
    abort("run: expected <file>")
  }
  let entry_path = args[0]
  let use_session_http = cli_use_session_http()
  if use_session_http {
    match run_entry_via_session(entry_path, _features) {
      Ok(result) => {
        print_wasm_run_value(result)
        return
      }
      Err(_) => ()
    }
  }
  match run_cmd_wasm_backend(entry_path) {
    Ok(result) => {
      print_wasm_run_value(result)
      maybe_create_linked_cache_background(entry_path)
    }
    Err(err) => die("error: run wasm backend: " + err)
  }
}
