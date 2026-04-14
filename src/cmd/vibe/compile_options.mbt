///|
pub enum CompileMode {
  Ir
  Wasm
  WasmJsString
  WasmGc
  Component
  ComponentStringLift
  ComposeP3
  Wac
  Wit
  WitComponent
} derive(Eq, Debug)

///|
pub impl Show for CompileMode with output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
pub struct CompileCmdOptions {
  mode : CompileMode
  no_dce : Bool
  coverage : Bool
  coverage_run_tests : Bool
  debug_errors : Bool
  http_host_imports : Bool
  force_cabi_realloc : Bool
  is_async : Bool
  library_mode : Bool
  adapter_path : String?
  out_path : String?
  entry_path : String
  opt_level : String?
}

///|
fn compile_mode_supports_no_dce(mode : CompileMode) -> Bool {
  match mode {
    CompileMode::Wasm | CompileMode::WasmJsString | CompileMode::WasmGc => true
    _ => false
  }
}

///|
fn compile_mode_supports_wite_opt(mode : CompileMode) -> Bool {
  match mode {
    CompileMode::Wasm
    | CompileMode::WasmJsString
    | CompileMode::WasmGc
    | CompileMode::Component
    | CompileMode::ComponentStringLift
    | CompileMode::Wac => true
    _ => false
  }
}

///|
fn compile_mode_supports_coverage(mode : CompileMode) -> Bool {
  match mode {
    CompileMode::Wasm | CompileMode::WasmJsString => true
    _ => false
  }
}

///|
fn compile_mode_supports_debug_errors(mode : CompileMode) -> Bool {
  match mode {
    CompileMode::Wasm | CompileMode::WasmJsString => true
    _ => false
  }
}

///|
fn compile_mode_supports_http_host_imports(mode : CompileMode) -> Bool {
  match mode {
    CompileMode::Wasm | CompileMode::Component => true
    _ => false
  }
}

///|
fn is_opt_level_flag(arg : String) -> Bool {
  match arg {
    "-O0" | "-O1" | "-O" | "-O2" | "-O3" | "-O4" | "-Os" | "-Oz" => true
    _ => false
  }
}

///|
pub fn parse_compile_cmd_args(
  args : Array[String],
) -> Result[CompileCmdOptions, String] {
  let mut mode = CompileMode::Ir
  let mut no_dce = false
  let mut library_mode = false
  let mut coverage = false
  let mut coverage_run_tests = false
  let mut debug_errors = false
  let mut http_host_imports = false
  let mut force_cabi_realloc = false
  let mut is_async = false
  let mut adapter_path : String? = None
  let mut out_path : String? = None
  let mut entry_path : String? = None
  let mut opt_level : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--wasm" => {
        mode = CompileMode::Wasm
        i += 1
      }
      "--wasm-linear" => {
        mode = CompileMode::Wasm
        i += 1
      }
      "--wasm-js-string" => {
        mode = CompileMode::WasmJsString
        i += 1
      }
      "--wasm-gc" => {
        mode = CompileMode::WasmGc
        i += 1
      }
      "--component" => {
        mode = CompileMode::Component
        i += 1
      }
      "--component-string-lift" => {
        mode = CompileMode::ComponentStringLift
        i += 1
      }
      "--compose-p3" => {
        mode = CompileMode::ComposeP3
        i += 1
      }
      "--adapter" => {
        if i + 1 >= args.length() {
          return Err("compile: missing adapter path after --adapter")
        }
        adapter_path = Some(args[i + 1])
        i += 2
      }
      "--wac" => {
        mode = CompileMode::Wac
        i += 1
      }
      "--wit" => {
        mode = CompileMode::Wit
        i += 1
      }
      "--wit-component" => {
        mode = CompileMode::WitComponent
        i += 1
      }
      "--no-dce" => {
        no_dce = true
        i += 1
      }
      "--library" => {
        library_mode = true
        i += 1
      }
      "--coverage" => {
        coverage = true
        i += 1
      }
      "--coverage-run-tests" => {
        coverage_run_tests = true
        i += 1
      }
      "--debug-errors" => {
        debug_errors = true
        i += 1
      }
      "--http-host-imports" => {
        http_host_imports = true
        i += 1
      }
      "--force-cabi-realloc" => {
        force_cabi_realloc = true
        i += 1
      }
      "--async" => {
        is_async = true
        i += 1
      }
      "--wite" => {
        if opt_level is None {
          opt_level = Some("-Oz")
        }
        i += 1
      }
      "-o" | "--out" => {
        if i + 1 >= args.length() {
          return Err("compile: missing output path after " + arg)
        }
        out_path = Some(args[i + 1])
        i += 2
      }
      _ if is_opt_level_flag(arg) => {
        opt_level = Some(arg)
        i += 1
      }
      _ => {
        if entry_path is None {
          entry_path = Some(arg)
        } else {
          return Err("compile: too many input files")
        }
        i += 1
      }
    }
  }
  match entry_path {
    None => Err("compile: missing <file>")
    Some(path) => {
      if no_dce && not(compile_mode_supports_no_dce(mode)) {
        return Err(
          "compile: --no-dce is only supported with --wasm, --wasm-js-string, or --wasm-gc",
        )
      }
      if opt_level is Some(_) && not(compile_mode_supports_wite_opt(mode)) {
        return Err(
          "compile: --wite/-O* is only supported with --wasm, --wasm-js-string, --wasm-gc, --component, or --wac",
        )
      }
      if coverage && not(compile_mode_supports_coverage(mode)) {
        return Err(
          "compile: --coverage is only supported with --wasm or --wasm-js-string",
        )
      }
      if coverage_run_tests && not(coverage) {
        return Err("compile: --coverage-run-tests requires --coverage")
      }
      if debug_errors && not(compile_mode_supports_debug_errors(mode)) {
        return Err(
          "compile: --debug-errors is only supported with --wasm or --wasm-js-string",
        )
      }
      if http_host_imports && not(compile_mode_supports_http_host_imports(mode)) {
        return Err(
          "compile: --http-host-imports is only supported with --wasm or --component",
        )
      }
      if is_async && mode != CompileMode::ComponentStringLift {
        return Err(
          "compile: --async is only supported with --component-string-lift",
        )
      }
      if mode == CompileMode::ComposeP3 && adapter_path is None {
        return Err("compile: --compose-p3 requires --adapter <adapter.wasm>")
      }
      Ok({
        mode,
        no_dce,
        coverage,
        coverage_run_tests,
        debug_errors,
        http_host_imports,
        force_cabi_realloc,
        is_async,
        library_mode,
        adapter_path,
        out_path,
        entry_path: path,
        opt_level,
      })
    }
  }
}
