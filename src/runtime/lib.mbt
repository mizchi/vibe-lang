///|
/// vibe public API
suberror XshError {
  Parse(@parser.ParseError)
  Type(@checker.TypeError)
  Eval(EvalError)
} derive(Show, Eq)

///|
pub fn XshError::format_for_repl(self : XshError, source : String) -> String {
  match self {
    XshError::Type(type_err) => type_err.diagnostic().render("<repl>", source)
    XshError::Parse(parse_err) =>
      parse_err.diagnostic().render("<repl>", source)
    XshError::Eval(eval_err) => "error: " + eval_err.to_string()
  }
}

///|
/// Format any Error for REPL display. Tries XshError diagnostic, falls back to string.
/// `unwrap_prefix` is the prefix added by wrapping (e.g. "do { "), used to adjust span offsets.
pub fn format_error_for_repl(
  e : Error,
  source : String,
  unwrap_prefix? : String = "",
) -> String {
  let offset = unwrap_prefix.length()
  match e {
    XshError::Type(type_err) => {
      let diag = type_err.diagnostic()
      if offset > 0 {
        // Shift span back by prefix length and render against original source
        let suffix_len = 2 // strip " }" suffix
        let end = source.length() - suffix_len
        let original = source[offset:end].to_string() catch { _ => source }
        let shifted = match diag.span {
          Some(span) =>
            @core.Diagnostic::{
              ..diag,
              span: Some(@core.Span::{
                start: span.start - offset,
                end: span.end - offset,
              }),
            }
          None => diag
        }
        shifted.render("<repl>", original)
      } else {
        diag.render("<repl>", source)
      }
    }
    XshError::Parse(parse_err) =>
      parse_err.diagnostic().render("<repl>", source)
    XshError::Eval(eval_err) => "error: " + eval_err.to_string()
    _ => "error: " + e.to_string()
  }
}

///|
pub(all) enum ParserMode {
  XshMode
  PosixMode
} derive(Show, Eq)

///|
/// Detect vibe by leading keyword token
pub fn is_vibe_script(script : String) -> Bool {
  let tokens = @parser.tokenize(script)
  for tok in tokens {
    if @parser.is_trivia(tok.kind()) {
      continue
    }
    let kind = tok.kind()
    return kind == @parser.let_kw() ||
      kind == @parser.test_kw() ||
      kind == @parser.bench_kw() ||
      kind == @parser.type_kw() ||
      kind == @parser.enum_kw() ||
      kind == @parser.map_kw() ||
      kind == @parser.lbracket()
  }
  false
}

///|
fn parse_script_with_mode(
  script : String,
  mode : ParserMode,
) -> (@core.Module, Array[String]) raise XshError {
  match mode {
    ParserMode::XshMode =>
      (@parser.parse_ast(script) catch { e => raise XshError::Parse(e) }, [])
    ParserMode::PosixMode => {
      let parsed = @parser.parse_ast(script) catch {
        e => raise XshError::Parse(e)
      }
      let (desugared, notes) = desugar_vibe_commands_with_notes(parsed)
      let out_notes : Array[String] = []
      for note in notes {
        out_notes.push("posix-mode command-head desugar: " + note)
      }
      (desugared, out_notes)
    }
  }
}

///|
/// Parse, type-check, and evaluate script with explicit parser mode.
pub fn Runtime::eval_script_with_mode(
  self : Runtime,
  script : String,
  mode : ParserMode,
) -> EvalResult raise XshError {
  let (raw_ast, mode_notes) = parse_script_with_mode(script, mode)
  let aliases = self.aliases
  let ast = if script.contains(".") {
    desugar_method_calls(raw_ast, aliases)
  } else {
    raw_ast
  }
  try {
    let next_env = @checker.type_check_with_env(
      self.type_env.fork_for_check(),
      ast,
      aliases,
    )
    self.type_env = next_env.compact_for_eval()
  } catch {
    e => raise XshError::Type(e)
  }
  let result = self.eval_module(ast) catch { e => raise XshError::Eval(e) }
  if mode_notes.length() == 0 {
    result
  } else {
    let effects : Array[Effect] = []
    for note in mode_notes {
      effects.push(Effect::PosixDesugar(note))
    }
    for effect in result.effects {
      effects.push(effect)
    }
    EvalResult::{ last: result.last, effects }
  }
}

///|
/// Parse, type-check, and evaluate vibe script.
pub fn Runtime::eval_script(
  self : Runtime,
  script : String,
) -> EvalResult raise XshError {
  self.eval_script_with_mode(script, ParserMode::XshMode)
}

///|
/// Parse, type-check, and run vibe test blocks.
pub fn Runtime::run_script_tests_with_mode(
  self : Runtime,
  script : String,
  mode : ParserMode,
) -> TestReport raise XshError {
  let (raw_ast, _) = parse_script_with_mode(script, mode)
  let aliases = self.aliases
  let ast = desugar_method_calls(raw_ast, aliases)
  try {
    let next_env = @checker.type_check_with_env(
      self.type_env.fork_for_check(),
      ast,
      aliases,
    )
    self.type_env = next_env.compact_for_eval()
  } catch {
    e => raise XshError::Type(e)
  }
  self.run_tests(ast) catch {
    e => raise XshError::Eval(e)
  }
}

///|
/// Parse, type-check, and run vibe bench blocks.
pub fn Runtime::run_script_benches_with_mode(
  self : Runtime,
  script : String,
  count : Int,
  warmup : Int,
  mode : ParserMode,
) -> BenchReport raise XshError {
  let (raw_ast, _) = parse_script_with_mode(script, mode)
  let aliases = self.aliases
  let ast = desugar_method_calls(raw_ast, aliases)
  try {
    let next_env = @checker.type_check_with_env(
      self.type_env.fork_for_check(),
      ast,
      aliases,
    )
    self.type_env = next_env.compact_for_eval()
  } catch {
    e => raise XshError::Type(e)
  }
  self.run_benches(ast, count, warmup) catch {
    e => raise XshError::Eval(e)
  }
}

///|
/// Parse/type-check test script and collect dependency snapshot (`name -> addr`).
pub fn Runtime::collect_script_test_dep_snapshot_with_mode(
  self : Runtime,
  script : String,
  mode : ParserMode,
) -> Map[String, String]? raise XshError {
  let (raw_ast, _) = parse_script_with_mode(script, mode)
  let aliases = self.aliases
  let ast = desugar_method_calls(raw_ast, aliases)
  try {
    let _ = @checker.type_check_with_env(self.type_env.clone(), ast, aliases)
  } catch {
    e => raise XshError::Type(e)
  }
  self.collect_test_dep_snapshot(ast)
}

///|
/// Parse/type-check test script and collect dependency snapshot (`name -> addr`).
pub fn Runtime::collect_script_test_dep_snapshot(
  self : Runtime,
  script : String,
) -> Map[String, String]? raise XshError {
  self.collect_script_test_dep_snapshot_with_mode(script, ParserMode::XshMode)
}

///|
/// Parse, type-check, and run vibe test blocks.
pub fn Runtime::run_script_tests(
  self : Runtime,
  script : String,
) -> TestReport raise XshError {
  self.run_script_tests_with_mode(script, ParserMode::XshMode)
}

///|
/// Parse, type-check, and run vibe bench blocks.
pub fn Runtime::run_script_benches(
  self : Runtime,
  script : String,
  count : Int,
  warmup : Int,
) -> BenchReport raise XshError {
  self.run_script_benches_with_mode(script, count, warmup, ParserMode::XshMode)
}
