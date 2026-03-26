///|
/// vibe public API
suberror VibeError {
  Parse(@parser.ParseError)
  Type(@checker.TypeError)
  Eval(EvalError)
} derive(Show, Eq)

///|
pub(all) enum ParserMode {
  VibeMode
  PosixMode
  PosixStrictMode
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
      kind == @parser.lbracket()
  }
  false
}

///|
fn parse_script_with_mode(
  script : String,
  mode : ParserMode,
) -> (@core.Module, Array[String]) raise VibeError {
  fn parse_posix_script(
    strict : Bool,
  ) -> (@core.Module, Array[String]) raise VibeError {
    let (preprocessed, compat_notes) = if strict {
      preprocess_posix_source_with_compat_notes(script)
    } else {
      (preprocess_posix_source(script), [])
    }
    let parsed = @parser.parse_ast(preprocessed) catch {
      e => raise VibeError::Parse(e)
    }
    let (desugared, notes) = @pipeline.desugar_vibe_commands_with_notes(parsed)
    let out_notes : Array[String] = []
    if strict {
      for note in compat_notes {
        out_notes.push("posix-strict compatibility: " + note)
      }
    }
    for note in notes {
      out_notes.push("posix-mode command-head desugar: " + note)
    }
    (desugared, out_notes)
  }

  match mode {
    ParserMode::VibeMode =>
      (@parser.parse_ast(script) catch { e => raise VibeError::Parse(e) }, [])
    ParserMode::PosixMode => parse_posix_script(false)
    ParserMode::PosixStrictMode => parse_posix_script(true)
  }
}

///|
fn runtime_desugar_script_ast(
  runtime : Runtime,
  script : String,
  raw_ast : @core.Module,
) -> (@core.Module, Map[String, @core.Ref]) {
  let aliases = runtime.aliases
  let ast = if script.contains(".") {
    @pipeline.desugar_method_calls(raw_ast, aliases)
  } else {
    raw_ast
  }
  (ast, aliases)
}

///|
fn runtime_type_check_script_ast(
  runtime : Runtime,
  ast : @core.Module,
  aliases : Map[String, @core.Ref],
  compact_for_eval : Bool,
) -> Unit raise VibeError {
  try {
    let next_env = @checker.type_check_with_env(
      if compact_for_eval {
        runtime.type_env.fork_for_check()
      } else {
        runtime.type_env.clone()
      },
      ast,
      aliases,
    )
    if compact_for_eval {
      runtime.type_env = next_env.compact_for_eval()
    }
  } catch {
    e => raise VibeError::Type(e)
  }
}

///|
/// Parse, type-check, and evaluate script with explicit parser mode.
pub fn Runtime::eval_script_with_mode(
  self : Runtime,
  script : String,
  mode : ParserMode,
) -> EvalResult raise VibeError {
  let (raw_ast, mode_notes) = parse_script_with_mode(script, mode)
  let (ast, aliases) = runtime_desugar_script_ast(self, script, raw_ast)
  runtime_type_check_script_ast(self, ast, aliases, true)
  let result = self.eval_module(ast) catch { e => raise VibeError::Eval(e) }
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
) -> EvalResult raise VibeError {
  self.eval_script_with_mode(script, ParserMode::VibeMode)
}

///|
/// Parse, type-check, and run script test blocks with explicit parser mode.
fn run_script_tests_with_mode(
  runtime : Runtime,
  script : String,
  mode : ParserMode,
) -> TestReport raise VibeError {
  let (raw_ast, _) = parse_script_with_mode(script, mode)
  let (ast, aliases) = runtime_desugar_script_ast(runtime, script, raw_ast)
  runtime_type_check_script_ast(runtime, ast, aliases, true)
  runtime.run_tests(ast) catch {
    e => raise VibeError::Eval(e)
  }
}

///|
/// Parse, type-check, and run script bench blocks with explicit parser mode.
fn run_script_benches_with_mode(
  runtime : Runtime,
  script : String,
  count : Int,
  warmup : Int,
  mode : ParserMode,
) -> BenchReport raise VibeError {
  let (raw_ast, _) = parse_script_with_mode(script, mode)
  let (ast, aliases) = runtime_desugar_script_ast(runtime, script, raw_ast)
  runtime_type_check_script_ast(runtime, ast, aliases, true)
  runtime.run_benches(ast, count, warmup) catch {
    e => raise VibeError::Eval(e)
  }
}

///|
/// Parse, type-check, and run vibe test blocks.
pub fn Runtime::run_script_tests(
  self : Runtime,
  script : String,
) -> TestReport raise VibeError {
  run_script_tests_with_mode(self, script, ParserMode::VibeMode)
}

///|
/// Parse, type-check, and run vibe bench blocks.
pub fn Runtime::run_script_benches(
  self : Runtime,
  script : String,
  count : Int,
  warmup : Int,
) -> BenchReport raise VibeError {
  run_script_benches_with_mode(
    self,
    script,
    count,
    warmup,
    ParserMode::VibeMode,
  )
}
