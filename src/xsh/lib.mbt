///|
/// xsh public API
suberror XshError {
  Parse(ParseError)
  Type(TypeError)
  Eval(EvalError)
} derive(Show, Eq)

///|
/// Detect xsh by leading keyword token
pub fn is_xsh_script(script : String) -> Bool {
  let tokens = tokenize(script)
  for tok in tokens {
    if is_trivia(tok.kind()) {
      continue
    }
    let kind = tok.kind()
    return kind == let_kw() ||
      kind == flake_kw() ||
      kind == alias_kw() ||
      kind == test_kw() ||
      kind == type_kw() ||
      kind == enum_kw() ||
      kind == map_kw() ||
      kind == lbracket()
  }
  false
}

///|
/// Parse, type-check, and evaluate xsh script
pub fn Runtime::eval_script(
  self : Runtime,
  script : String,
) -> EvalResult raise XshError {
  let ast = parse_ast(script) catch { e => raise XshError::Parse(e) }
  let aliases = merge_aliases(self.aliases, ast)
  try {
    let next_env = type_check_with_env(self.type_env.clone(), ast, aliases)
    self.type_env = next_env
  } catch {
    e => raise XshError::Type(e)
  }
  self.eval_module(ast) catch {
    e => raise XshError::Eval(e)
  }
}

///|
/// Parse, type-check, and run xsh test blocks.
pub fn Runtime::run_script_tests(
  self : Runtime,
  script : String,
) -> TestReport raise XshError {
  let ast = parse_ast(script) catch { e => raise XshError::Parse(e) }
  let aliases = merge_aliases(self.aliases, ast)
  try {
    let _ = type_check_with_env(self.type_env.clone(), ast, aliases)

  } catch {
    e => raise XshError::Type(e)
  }
  self.run_tests(ast) catch {
    e => raise XshError::Eval(e)
  }
}

///|
fn merge_aliases(base : Map[String, Ref], ast : Module) -> Map[String, Ref] {
  let aliases : Map[String, Ref] = {}
  for name, target in base {
    aliases[name] = target
  }
  for stmt in ast.stmts {
    match stmt {
      Stmt::Alias(name~, target~) =>
        match target {
          AliasTarget::Module(r) => aliases[name] = r
          AliasTarget::Name(_) => ()
        }
      _ => ()
    }
  }
  aliases
}
