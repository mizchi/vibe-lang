///|
/// xsh public API
suberror XshError {
  Parse(@parser.ParseError)
  Type(@checker.TypeError)
  Eval(EvalError)
} derive(Show, Eq)

///|
pub(all) enum ParserMode {
  XshMode
  PosixMode
} derive(Show, Eq)

///|
/// Detect xsh by leading keyword token
pub fn is_xsh_script(script : String) -> Bool {
  let tokens = @parser.tokenize(script)
  for tok in tokens {
    if @parser.is_trivia(tok.kind()) {
      continue
    }
    let kind = tok.kind()
    return kind == @parser.let_kw() ||
      kind == @parser.test_kw() ||
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
) -> @core.Module raise XshError {
  match mode {
    ParserMode::XshMode =>
      @parser.parse_ast(script) catch {
        e => raise XshError::Parse(e)
      }
    ParserMode::PosixMode => {
      let parsed = @parser.parse_ast(script) catch {
        e => raise XshError::Parse(e)
      }
      desugar_xshell_commands(parsed)
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
  let raw_ast = parse_script_with_mode(script, mode)
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
    self.type_env = next_env
  } catch {
    e => raise XshError::Type(e)
  }
  self.eval_module(ast) catch {
    e => raise XshError::Eval(e)
  }
}

///|
/// Parse, type-check, and evaluate xsh script.
pub fn Runtime::eval_script(
  self : Runtime,
  script : String,
) -> EvalResult raise XshError {
  self.eval_script_with_mode(script, ParserMode::XshMode)
}

///|
/// Parse, type-check, and run xsh test blocks.
pub fn Runtime::run_script_tests_with_mode(
  self : Runtime,
  script : String,
  mode : ParserMode,
) -> TestReport raise XshError {
  let raw_ast = parse_script_with_mode(script, mode)
  let aliases = self.aliases
  let ast = desugar_method_calls(raw_ast, aliases)
  try {
    let _ = @checker.type_check_with_env(self.type_env.clone(), ast, aliases)

  } catch {
    e => raise XshError::Type(e)
  }
  self.run_tests(ast) catch {
    e => raise XshError::Eval(e)
  }
}

///|
/// Parse, type-check, and run xsh test blocks.
pub fn Runtime::run_script_tests(
  self : Runtime,
  script : String,
) -> TestReport raise XshError {
  self.run_script_tests_with_mode(script, ParserMode::XshMode)
}
