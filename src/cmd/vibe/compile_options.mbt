///|
pub enum CompileMode {
  Ir
  Wasm
  WasmJsString
  WasmGc
  Component
  Wac
  Wit
  WitComponent
} derive(Eq, Show)

///|
pub struct CompileCmdOptions {
  mode : CompileMode
  no_dce : Bool
  coverage : Bool
  coverage_run_tests : Bool
  debug_errors : Bool
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
  let mut coverage = false
  let mut coverage_run_tests = false
  let mut debug_errors = false
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
      Ok({
        mode,
        no_dce,
        coverage,
        coverage_run_tests,
        debug_errors,
        out_path,
        entry_path: path,
        opt_level,
      })
    }
  }
}
