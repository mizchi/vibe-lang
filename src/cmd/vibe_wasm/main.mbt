///|
pub enum CommandKind {
  Run
  Compile
  Compare
} derive(Eq, Show)

///|
pub enum RunMode {
  CoreWasm
  Component
} derive(Eq, Show)

///|
pub struct CmdOptions {
  command : CommandKind
  mode : RunMode
  entry_path : String
  out_path : String?
  keep_artifact : Bool
  opt_level : String?
  http_host_imports : Bool
  invoke : String?
} derive(Eq, Show)

///|
struct WasmtimeRunner {
  wasmtime_bin : String
  wasm_flags : Array[String]
  wasi_flags : Array[String]
} derive(Eq, Show)

///|
struct ExecCapture {
  status : Int
  elapsed_ms : Int
  stdout : String
  stderr : String
} derive(Eq, Show)

///|
struct FileSnapshot {
  exists : Bool
  content : String
} derive(Eq, Show)

///|
fn args_tail(args : Array[String], start : Int) -> Array[String] {
  let out : Array[String] = []
  for i in start..<args.length() {
    out.push(args[i])
  }
  out
}

///|
fn is_opt_level_flag(arg : String) -> Bool {
  match arg {
    "-O0" | "-O1" | "-O" | "-O2" | "-O3" | "-O4" | "-Os" | "-Oz" => true
    _ => false
  }
}

///|
fn elapsed_us_to_ms_int(elapsed_us : Double) -> Int {
  let elapsed_ms = (elapsed_us / 1000.0).to_int()
  if elapsed_ms <= 0 {
    1
  } else {
    elapsed_ms
  }
}

///|
fn remove_file_if_exists(path : String) -> Unit {
  if not(@os_fs.path_exists(path)) {
    return
  }
  let is_file = @os_fs.is_file(path) catch { _ => false }
  if is_file {
    ignore(@os_fs.remove_file(path) catch { _ => () })
  }
}

///|
fn snapshot_file(path : String) -> FileSnapshot {
  if not(@os_fs.path_exists(path)) {
    return { exists: false, content: "" }
  }
  if not(@os_fs.is_file(path) catch { _ => false }) {
    return { exists: false, content: "" }
  }
  let content = @os_fs.read_file_to_string(path) catch { _ => "" }
  { exists: true, content }
}

///|
fn restore_file_snapshot(path : String, snapshot : FileSnapshot) -> Unit {
  if snapshot.exists {
    @os_fs.write_string_to_file(path, snapshot.content) catch {
      _ => ()
    }
    return
  }
  remove_file_if_exists(path)
}

///|
fn is_existing_file(path : String) -> Bool {
  if not(@os_fs.path_exists(path)) {
    return false
  }
  @os_fs.is_file(path) catch {
    _ => false
  }
}

///|
fn split_env_flags(raw : String) -> Array[String] {
  let out : Array[String] = []
  for part_view in raw.split(" ") {
    let token = part_view.trim().to_string()
    if token.length() > 0 {
      out.push(token)
    }
  }
  out
}

///|
fn has_wasm_feature_flag(flags : Array[String], feature : String) -> Bool {
  let prefix = feature.to_lower() + "="
  for flag in flags {
    let token = flag.trim().to_string().to_lower()
    if token == feature || token.has_prefix(prefix) {
      return true
    }
  }
  false
}

///|
fn with_default_core_wasm_flags(flags : Array[String]) -> Array[String] {
  let out = flags.copy()
  if not(has_wasm_feature_flag(out, "exceptions")) {
    out.push("exceptions=y")
  }
  out
}

///|
fn find_command_in_path(name : String) -> String? {
  match @sys.get_env_var("PATH") {
    None => None
    Some(path_value) => {
      for dir_view in path_value.split(":") {
        let dir = dir_view.trim().to_string()
        if dir.length() == 0 {
          continue
        }
        let candidate = dir + "/" + name
        if is_existing_file(candidate) {
          return Some(candidate)
        }
      }
      None
    }
  }
}

///|
fn project_root_for_path(path : String) -> String {
  let is_dir = @os_fs.is_dir(path) catch { _ => false }
  let mut dir = if is_dir { path } else { @vibe_fs.parent_path(path) }
  for _ in 0..<64 {
    let marker = dir + "/moon.mod.json"
    if is_existing_file(marker) {
      return dir
    }
    let parent = @vibe_fs.parent_path(dir)
    if parent == dir {
      break
    }
    dir = parent
  }
  @io.current_dir_or_root()
}

///|
fn absolute_path_from_cwd(path : String) -> String {
  if path.has_prefix("/") {
    @vibe_fs.normalize_path(path)
  } else {
    @vibe_fs.normalize_path(@io.current_dir_or_root() + "/" + path)
  }
}

///|
fn resolve_wasmtime_bin(project_root : String) -> Result[String, String] {
  match @sys.get_env_var("WASMTIME_BIN") {
    Some(value) => {
      let trimmed = value.trim().to_string()
      if trimmed.length() > 0 {
        return Ok(trimmed)
      }
    }
    None => ()
  }
  let local_release = project_root + "/deps/wasmtime/target/release/wasmtime"
  let local_debug = project_root + "/deps/wasmtime/target/debug/wasmtime"
  let use_submodule = match @sys.get_env_var("VIBE_USE_WASMTIME_SUBMODULE") {
    Some(value) => value.trim().to_string() == "1"
    None => false
  }
  if use_submodule {
    if is_existing_file(local_release) {
      return Ok(local_release)
    }
    if is_existing_file(local_debug) {
      return Ok(local_debug)
    }
    return Err(
      "VIBE_USE_WASMTIME_SUBMODULE=1 but deps/wasmtime binary is not built. run: just build-wasmtime-submodule",
    )
  }
  match find_command_in_path("wasmtime") {
    Some(path) => return Ok(path)
    None => ()
  }
  if is_existing_file(local_release) {
    return Ok(local_release)
  }
  if is_existing_file(local_debug) {
    return Ok(local_debug)
  }
  Err(
    "wasmtime not found (PATH and deps/wasmtime build). install wasmtime or run: just build-wasmtime-submodule",
  )
}

///|
fn resolve_wasmtime_runner(
  entry_path : String,
  mode : RunMode,
) -> Result[WasmtimeRunner, String] {
  let project_root = project_root_for_path(entry_path)
  let wasmtime_bin = match resolve_wasmtime_bin(project_root) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let wasm_flags = match @sys.get_env_var("VIBE_WASMTIME_WASM_FLAGS") {
    Some(raw) => split_env_flags(raw)
    None => []
  }
  let wasm_flags = match mode {
    RunMode::CoreWasm => with_default_core_wasm_flags(wasm_flags)
    RunMode::Component => wasm_flags
  }
  let wasi_flags = match @sys.get_env_var("VIBE_WASMTIME_WASI_FLAGS") {
    Some(raw) => split_env_flags(raw)
    None => []
  }
  Ok({ wasmtime_bin, wasm_flags, wasi_flags })
}

///|
fn resolve_vibe_bin(project_root : String) -> Result[String, String] {
  match @sys.get_env_var("VIBE_BIN") {
    Some(value) => {
      let trimmed = value.trim().to_string()
      if trimmed.length() > 0 {
        return Ok(trimmed)
      }
    }
    None => ()
  }
  let local_debug = project_root +
    "/_build/native/debug/build/cmd/vibe/vibe.exe"
  if is_existing_file(local_debug) {
    return Ok(local_debug)
  }
  let local_release = project_root +
    "/_build/native/release/build/cmd/vibe/vibe.exe"
  if is_existing_file(local_release) {
    return Ok(local_release)
  }
  match find_command_in_path("vibe") {
    Some(path) => Ok(path)
    None =>
      Err(
        "vibe binary not found. set VIBE_BIN or build src/cmd/vibe (moon build --target native src/cmd/vibe)",
      )
  }
}

///|
fn shell_quote_command_arg(value : String) -> String {
  let mut escaped = value.replace_all(old="\\", new="\\\\")
  escaped = escaped.replace_all(old="\"", new="\\\"")
  escaped = escaped.replace_all(old="$", new="\\$")
  escaped = escaped.replace_all(old="`", new="\\`")
  "\"" + escaped + "\""
}

///|
#borrow(cmd)
extern "c" fn c_system(cmd : Bytes) -> Int = "system"

///|
extern "c" fn vibe_getpid() -> Int = "getpid"

///|
fn system_command_bytes(cmd : String) -> Bytes {
  let encoded = @utf8.encode(cmd[:])
  let n = encoded.length()
  Bytes::makei(n + 1, fn(i) { if i == n { b'\x00' } else { encoded[i] } })
}

///|
fn first_non_empty_line(text : String) -> String {
  for line_view in text.split("\n") {
    let line = line_view.trim().to_string()
    if line.length() > 0 {
      return line
    }
  }
  ""
}

///|
fn run_shell_capture(
  cmd : String,
  tmp_prefix : String,
) -> (Int, String, String) {
  let out_path = tmp_prefix + ".out"
  let err_path = tmp_prefix + ".err"
  let captured_cmd = cmd +
    " >" +
    shell_quote_command_arg(out_path) +
    " 2>" +
    shell_quote_command_arg(err_path)
  let status = c_system(system_command_bytes(captured_cmd))
  let stdout = @os_fs.read_file_to_string(out_path) catch { _ => "" }
  let stderr = @os_fs.read_file_to_string(err_path) catch { _ => "" }
  remove_file_if_exists(out_path)
  remove_file_if_exists(err_path)
  (status, stdout, stderr)
}

///|
fn mode_file_suffix(mode : RunMode) -> String {
  match mode {
    RunMode::CoreWasm => ".wasm"
    RunMode::Component => ".component.wasm"
  }
}

///|
fn mode_label(mode : RunMode) -> String {
  match mode {
    RunMode::CoreWasm => "wasm"
    RunMode::Component => "component"
  }
}

///|
fn basename_without_ext(path : String) -> String {
  let mut last_slash = -1
  for i, c in path {
    if c == '/' {
      last_slash = i
    }
  }
  let filename = if last_slash >= 0 {
    let buf = StringBuilder::new()
    for i, c in path {
      if i > last_slash {
        buf.write_char(c)
      }
    }
    buf.to_string()
  } else {
    path
  }
  let mut last_dot = -1
  for i, c in filename {
    if c == '.' {
      last_dot = i
    }
  }
  if last_dot > 0 {
    let buf = StringBuilder::new()
    for i, c in filename {
      if i < last_dot {
        buf.write_char(c)
      }
    }
    buf.to_string()
  } else {
    filename
  }
}

///|
pub fn default_output_path(entry_path : String, mode : RunMode) -> String {
  let basename = basename_without_ext(entry_path)
  "dist/" + basename + mode_file_suffix(mode)
}

///|
fn ensure_dir_recursive_best_effort(path : String) -> Unit {
  if path.length() == 0 || path == "." {
    return
  }
  if @os_fs.path_exists(path) {
    return
  }
  let parent = @vibe_fs.parent_path(path)
  if parent != path && parent.length() > 0 {
    ensure_dir_recursive_best_effort(parent)
  }
  @os_fs.create_dir(path) catch {
    _ => ()
  }
}

///|
pub fn parse_cmd_args(args : Array[String]) -> Result[CmdOptions, String] {
  let mut command = CommandKind::Run
  let mut mode = RunMode::CoreWasm
  let mut out_path : String? = None
  let mut entry_path : String? = None
  let mut keep_artifact = false
  let mut opt_level : String? = None
  let mut http_host_imports = false
  let mut invoke : String? = None
  let mut i = 0

  if args.length() > 0 {
    match args[0] {
      "run" => {
        command = CommandKind::Run
        i = 1
      }
      "compile" => {
        command = CommandKind::Compile
        i = 1
      }
      "compare" | "compare-run" => {
        command = CommandKind::Compare
        i = 1
      }
      _ => ()
    }
  }

  while i < args.length() {
    let arg = args[i]
    match arg {
      "--component" => {
        mode = RunMode::Component
        i += 1
      }
      "--wasm" => {
        mode = RunMode::CoreWasm
        i += 1
      }
      "--http-host-imports" => {
        http_host_imports = true
        i += 1
      }
      "--keep" => {
        keep_artifact = true
        i += 1
      }
      "--invoke" => {
        i += 1
        if i >= args.length() {
          return Err("vibe_wasm: missing function signature after --invoke")
        }
        invoke = Some(args[i])
        i += 1
      }
      "--wite" => {
        if opt_level is None {
          opt_level = Some("-Oz")
        }
        i += 1
      }
      "-o" | "--out" => {
        i += 1
        if i >= args.length() {
          return Err("vibe_wasm: missing output path after " + arg)
        }
        out_path = Some(args[i])
        i += 1
      }
      "-h" | "--help" => return Err("help")
      _ if is_opt_level_flag(arg) => {
        opt_level = Some(arg)
        i += 1
      }
      _ if arg.has_prefix("-") =>
        return Err("vibe_wasm: unknown option: " + arg)
      _ =>
        if entry_path is None {
          entry_path = Some(arg)
          i += 1
        } else {
          return Err("vibe_wasm: too many input files")
        }
    }
  }

  let entry_path = match entry_path {
    Some(path) => path
    None => return Err("vibe_wasm: missing <file>")
  }

  if command == CommandKind::Compare {
    if out_path is Some(_) {
      return Err("vibe_wasm compare: -o/--out is not supported")
    }
    if keep_artifact {
      return Err("vibe_wasm compare: --keep is not supported")
    }
  }

  Ok({
    command,
    mode,
    entry_path,
    out_path,
    keep_artifact,
    opt_level,
    http_host_imports,
    invoke,
  })
}

///|
fn compile_mode_bytes(
  entry_path : String,
  mode : RunMode,
  opt_level : String?,
  http_host_imports : Bool,
) -> Result[Bytes, String] {
  let (db, entry) = match @loader.load_db(entry_path) {
    Ok(v) => v
    Err(err) => return Err("load error: " + err)
  }
  match mode {
    RunMode::CoreWasm => {
      let bytes = @runtime_compile.compile_module_wasm_with_opt_level(
        db,
        entry,
        no_dce=false,
        opt_level~,
        debug_errors=true,
        http_host_imports~,
      ) catch {
        e => return Err("compile wasm error: " + e.user_message())
      }
      Ok(bytes)
    }
    RunMode::Component => {
      let bytes = @runtime_compile.compile_module_component_with_opt_level(
        db,
        entry,
        opt_level~,
        http_host_imports~,
      ) catch {
        e => return Err("compile component error: " + e.user_message())
      }
      Ok(bytes)
    }
  }
}

///|
fn compile_to_path(
  entry_path : String,
  mode : RunMode,
  out_path : String?,
  opt_level : String?,
  http_host_imports : Bool,
) -> Result[(String, Int), String] {
  let bytes = match
    compile_mode_bytes(entry_path, mode, opt_level, http_host_imports) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let output = match out_path {
    Some(path) => path
    None => default_output_path(entry_path, mode)
  }
  let parent = @vibe_fs.parent_path(output)
  if parent != output && parent.length() > 0 {
    ensure_dir_recursive_best_effort(parent)
  }
  @os_fs.write_bytes_to_file(output, bytes) catch {
    e => return Err("write failed: " + e.to_string())
  }
  Ok((output, bytes.length()))
}

///|
fn build_wasmtime_invoke_command(
  runner : WasmtimeRunner,
  mode : RunMode,
  artifact_path : String,
  invoke_override : String?,
) -> String {
  let invoke = match invoke_override {
    Some(value) => value
    None =>
      match mode {
        RunMode::CoreWasm => "run"
        RunMode::Component => "run()"
      }
  }
  let cmd = StringBuilder::new()
  cmd.write_string(shell_quote_command_arg(runner.wasmtime_bin))
  for flag in runner.wasm_flags {
    cmd.write_string(" -W ")
    cmd.write_string(shell_quote_command_arg(flag))
  }
  for flag in runner.wasi_flags {
    cmd.write_string(" -S ")
    cmd.write_string(shell_quote_command_arg(flag))
  }
  cmd.write_string(" --invoke ")
  cmd.write_string(shell_quote_command_arg(invoke))
  cmd.write_string(" ")
  cmd.write_string(shell_quote_command_arg(artifact_path))
  cmd.to_string()
}

///|
fn make_temp_artifact_path(entry_path : String, mode : RunMode) -> String {
  let resolved_entry = absolute_path_from_cwd(entry_path)
  let parent = @vibe_fs.parent_path(resolved_entry)
  let stamp = @env.now().to_string() + "_" + vibe_getpid().to_string()
  parent +
  "/.vibe_wasm_" +
  mode_label(mode) +
  "_" +
  stamp +
  mode_file_suffix(mode)
}

///|
fn run_mode_capture(
  entry_path : String,
  mode : RunMode,
  out_path : String?,
  keep_artifact : Bool,
  opt_level : String?,
  http_host_imports : Bool,
  invoke : String?,
) -> Result[(String, ExecCapture), String] {
  let total_start = @bench.monotonic_clock_start()
  let artifact_path = match out_path {
    Some(path) => path
    None => make_temp_artifact_path(entry_path, mode)
  }
  let compile_size = match
    compile_to_path(
      entry_path,
      mode,
      Some(artifact_path),
      opt_level,
      http_host_imports,
    ) {
    Ok((_, size)) => size
    Err(err) => return Err(err)
  }
  ignore(compile_size)
  let runner = match
    resolve_wasmtime_runner(absolute_path_from_cwd(entry_path), mode) {
    Ok(v) => v
    Err(err) => {
      if out_path is None && not(keep_artifact) {
        remove_file_if_exists(artifact_path)
      }
      return Err(err)
    }
  }
  let cmd = build_wasmtime_invoke_command(runner, mode, artifact_path, invoke)
  let tmp_prefix = artifact_path + ".exec"
  let (status, stdout, stderr) = run_shell_capture(cmd, tmp_prefix)
  let elapsed_ms = elapsed_us_to_ms_int(@bench.monotonic_clock_end(total_start))
  if out_path is None && not(keep_artifact) {
    remove_file_if_exists(artifact_path)
  }
  Ok((artifact_path, { status, elapsed_ms, stdout, stderr }))
}

///|
fn run_vibe_capture(entry_path : String) -> Result[ExecCapture, String] {
  let total_start = @bench.monotonic_clock_start()
  let resolved_entry = absolute_path_from_cwd(entry_path)
  let lock_path = @codebase.lock_file_path(resolved_entry)
  let lock_snapshot = snapshot_file(lock_path)
  let project_root = project_root_for_path(resolved_entry)
  let vibe_bin = match resolve_vibe_bin(project_root) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let cmd = shell_quote_command_arg(vibe_bin) +
    " run " +
    shell_quote_command_arg(resolved_entry)
  let stamp = @env.now().to_string() + "_" + vibe_getpid().to_string()
  let tmp_prefix = @vibe_fs.parent_path(resolved_entry) +
    "/.vibe_wasm_vibe_" +
    stamp
  let (status, stdout, stderr) = run_shell_capture(cmd, tmp_prefix)
  restore_file_snapshot(lock_path, lock_snapshot)
  let elapsed_ms = elapsed_us_to_ms_int(@bench.monotonic_clock_end(total_start))
  Ok({ status, elapsed_ms, stdout, stderr })
}

///|
fn usage() -> Unit {
  println(
    "vibe_wasm [run|compile|compare] [--wasm|--component] [--http-host-imports] [--wite|-O{0,1,2,3,4,s,z}] [--invoke <name>] [--keep] [-o out] <file>",
  )
  println("  run      compile + execute via wasmtime (default)")
  println("  compile  emit wasm/component artifact")
  println(
    "  compare  run `vibe run`, wasm core, and component paths and print elapsed_ms",
  )
}

///|
fn print_capture_output(capture : ExecCapture) -> Unit {
  if capture.stdout.length() > 0 {
    println(capture.stdout)
  }
  if capture.stderr.length() > 0 {
    println(capture.stderr)
  }
}

///|
fn print_compare_row(label : String, capture : ExecCapture) -> Unit {
  let summary = first_non_empty_line(capture.stdout)
  let detail = if summary.length() > 0 {
    summary
  } else {
    first_non_empty_line(capture.stderr)
  }
  println(
    label +
    "\tstatus=" +
    capture.status.to_string() +
    "\telapsed_ms=" +
    capture.elapsed_ms.to_string() +
    "\t" +
    detail,
  )
}

///|
fn compile_cmd(opts : CmdOptions) -> Unit {
  match
    compile_to_path(
      opts.entry_path,
      opts.mode,
      opts.out_path,
      opts.opt_level,
      opts.http_host_imports,
    ) {
    Ok((path, size)) =>
      println("wrote " + path + " (" + size.to_string() + " bytes)")
    Err(err) => abort("vibe_wasm compile: " + err)
  }
}

///|
fn run_cmd(opts : CmdOptions) -> Unit {
  match
    run_mode_capture(
      opts.entry_path,
      opts.mode,
      opts.out_path,
      opts.keep_artifact,
      opts.opt_level,
      opts.http_host_imports,
      opts.invoke,
    ) {
    Ok((artifact_path, capture)) => {
      print_capture_output(capture)
      if capture.status != 0 {
        abort(
          "vibe_wasm run: wasmtime failed (status=" +
          capture.status.to_string() +
          ") " +
          first_non_empty_line(capture.stderr),
        )
      }
      if opts.keep_artifact || opts.out_path is Some(_) {
        println("artifact: " + artifact_path)
      }
    }
    Err(err) => abort("vibe_wasm run: " + err)
  }
}

///|
fn compare_cmd(opts : CmdOptions) -> Unit {
  let vibe_capture = match run_vibe_capture(opts.entry_path) {
    Ok(v) => v
    Err(err) => abort("vibe_wasm compare: " + err)
  }
  let wasm_capture = match
    run_mode_capture(
      opts.entry_path,
      RunMode::CoreWasm,
      None,
      false,
      opts.opt_level,
      opts.http_host_imports,
      None,
    ) {
    Ok((_, capture)) => capture
    Err(err) => abort("vibe_wasm compare: wasm mode failed: " + err)
  }
  let component_capture = match
    run_mode_capture(
      opts.entry_path,
      RunMode::Component,
      None,
      false,
      opts.opt_level,
      opts.http_host_imports,
      None,
    ) {
    Ok((_, capture)) => capture
    Err(err) => abort("vibe_wasm compare: component mode failed: " + err)
  }
  println("mode\tstatus\telapsed_ms\tsummary")
  print_compare_row("vibe-run", vibe_capture)
  print_compare_row("wasm-core", wasm_capture)
  print_compare_row("component", component_capture)
}

///|
fn main {
  let args = args_tail(@sys.get_cli_args(), 1)
  let opts = match parse_cmd_args(args) {
    Ok(v) => v
    Err("help") => {
      usage()
      return
    }
    Err(msg) => abort(msg)
  }
  match opts.command {
    CommandKind::Run => run_cmd(opts)
    CommandKind::Compile => compile_cmd(opts)
    CommandKind::Compare => compare_cmd(opts)
  }
}
