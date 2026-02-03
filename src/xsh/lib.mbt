///| xsh public API

suberror XshError {
  Parse(ParseError)
  Type(TypeError)
  Eval(EvalError)
} derive(Show, Eq)

///| Detect xsh by leading keyword token
pub fn is_xsh_script(script : String) -> Bool {
  let tokens = tokenize(script)
  for tok in tokens {
    if is_trivia(tok.kind()) {
      continue
    }
    let kind = tok.kind()
    return kind == let_kw() || kind == flake_kw() || kind == alias_kw() || kind == test_kw()
  }
  false
}

///| Parse, type-check, and evaluate xsh script
pub fn Runtime::eval_script(self : Runtime, script : String) -> EvalResult raise XshError {
  let ast = try parse_ast(script) catch {
    e => raise XshError::Parse(e)
  }
  try {
    let _ = type_check(ast)
  } catch {
    e => raise XshError::Type(e)
  }
  try {
    self.eval_module(ast)
  } catch {
    e => raise XshError::Eval(e)
  }
}

///| Parse, type-check, and run xsh test blocks.
pub fn Runtime::run_script_tests(self : Runtime, script : String) -> TestReport raise XshError {
  let ast = try parse_ast(script) catch {
    e => raise XshError::Parse(e)
  }
  try {
    let _ = type_check(ast)
  } catch {
    e => raise XshError::Type(e)
  }
  try {
    self.run_tests(ast)
  } catch {
    e => raise XshError::Eval(e)
  }
}
