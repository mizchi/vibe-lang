///|
/// xsh public API
suberror XshError {
  Parse(@parser.ParseError)
  Type(@checker.TypeError)
  Eval(EvalError)
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
      kind == @parser.flake_kw() ||
      kind == @parser.alias_kw() ||
      kind == @parser.test_kw() ||
      kind == @parser.type_kw() ||
      kind == @parser.enum_kw() ||
      kind == @parser.map_kw() ||
      kind == @parser.lbracket()
  }
  false
}

///|
/// Parse, type-check, and evaluate xsh script
pub fn Runtime::eval_script(
  self : Runtime,
  script : String,
) -> EvalResult raise XshError {
  let raw_ast = @parser.parse_ast(script) catch {
    e => raise XshError::Parse(e)
  }
  let aliases = if has_alias_stmt(raw_ast) {
    merge_aliases(self.aliases, raw_ast)
  } else {
    self.aliases
  }
  let ast = desugar_method_calls(raw_ast, aliases)
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
/// Parse, type-check, and run xsh test blocks.
pub fn Runtime::run_script_tests(
  self : Runtime,
  script : String,
) -> TestReport raise XshError {
  let raw_ast = @parser.parse_ast(script) catch {
    e => raise XshError::Parse(e)
  }
  let aliases = merge_aliases(self.aliases, raw_ast)
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
fn merge_aliases(
  base : Map[String, @core.Ref],
  ast : @core.Module,
) -> Map[String, @core.Ref] {
  let aliases = base.copy()
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Alias(name~, target~, span~) => {
        let _ = span
        match target {
          @core.AliasTarget::Module(r) => aliases[name] = r
          @core.AliasTarget::Name(_) => ()
        }
      }
      _ => ()
    }
  }
  aliases
}

///|
fn has_alias_stmt(ast : @core.Module) -> Bool {
  let mut found = false
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Alias(..) => {
        found = true
        break
      }
      _ => ()
    }
  }
  found
}
