///| xsh compile + run pipeline (prototype)

suberror CompileError {
  MissingSource(String)
  Parse(ParseError)
  Type(TypeError)
} derive(Show, Eq)

suberror WasmCompileError {
  Compile(CompileError)
  Gen(WasmGenError)
} derive(Show, Eq)

pub struct CompiledModule {
  path : String
  ir : String
  ir_hash : String
  module_ref : String
  imports : Array[String]
  aliases : Map[String, Ref]
  ast : Module
}

///| Compile a module from the database (WASM target: wasm-gc + js builtin).
pub fn compile_module(db : XshDb, path : String) -> CompiledModule raise CompileError {
  let source = match db.get_source(path) {
    Some(s) => s
    None => raise CompileError::MissingSource(path)
  }
  let ast = try parse_ast(source) catch {
    e => raise CompileError::Parse(e)
  }
  let aliases = build_alias_map(ast, db.import_aliases(path))
  try {
    let _ = type_check_with_aliases(ast, aliases)
  } catch {
    e => raise CompileError::Type(e)
  }
  let ir = module_to_sexp(ast, aliases)
  let ir_hash = git_blob_hash_string(ir)
  let module_ref = module_ref_from_hash(ir_hash)
  let imports : Array[String] = []
  for imp in db.imports(path) {
    match imp.module_ref {
      Some(r) => imports.push(r)
      None => ()
    }
  }
  {
    path,
    ir,
    ir_hash,
    module_ref,
    imports,
    aliases,
    ast,
  }
}

///| Execute compiled module using the xsh runtime (interpreter).
pub fn Runtime::run_compiled(self : Runtime, compiled : CompiledModule) -> EvalResult raise XshError {
  let _ = compiled // keep for future wasm backend
  for name, target in compiled.aliases {
    self.set_alias(name, target)
  }
  try {
    self.eval_module(compiled.ast)
  } catch {
    e => raise XshError::Eval(e)
  }
}

///| Compile a module to WASM (wasm-gc compatible, minimal MVP).
pub fn compile_module_wasm(db : XshDb, path : String) -> Bytes raise WasmCompileError {
  let compiled = try {
    compile_module(db, path)
  } catch {
    e => raise WasmCompileError::Compile(e)
  }
  try {
    emit_module_wasm(compiled.ast)
  } catch {
    e => raise WasmCompileError::Gen(e)
  }
}

///| Merge alias statements into import alias map.
fn build_alias_map(ast : Module, import_aliases : Map[String, Ref]) -> Map[String, Ref] {
  let aliases = import_aliases
  for stmt in ast.stmts {
    match stmt {
      Stmt::Alias(name~, target~) => aliases[name] = target
      _ => ()
    }
  }
  aliases
}

///| Convert module to canonical S-expression for hashing.
fn module_to_sexp(ast : Module, aliases : Map[String, Ref]) -> String {
  "(module " + stmts_to_sexp(ast.stmts, aliases) + ")"
}

fn stmts_to_sexp(stmts : Array[Stmt], aliases : Map[String, Ref]) -> String {
  let buf = StringBuilder::new()
  buf.write_string("(stmts")
  for stmt in stmts {
    match stmt {
      Stmt::Let(name~, expr~) => {
        buf.write_string(" (let ")
        buf.write_string(escape_atom(name))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(expr, aliases))
        buf.write_char(')')
      }
      Stmt::Expr(expr~) => {
        buf.write_string(" (expr ")
        buf.write_string(expr_to_sexp(expr, aliases))
        buf.write_char(')')
      }
      Stmt::Flake(_) => {
        buf.write_string(" (flake)")
      }
      Stmt::Alias(..) => ()
      Stmt::Import(..) => ()
      Stmt::Test(..) => ()
    }
  }
  buf.write_char(')')
  buf.to_string()
}

fn block_to_sexp(body : Module, aliases : Map[String, Ref]) -> String {
  "(block " + stmts_to_sexp(body.stmts, aliases) + ")"
}

///| Convert expression to S-expression.
fn expr_to_sexp(expr : Expr, aliases : Map[String, Ref]) -> String {
  match expr {
    Expr::Int(n) => "(lit (int " + n.to_string() + "))"
    Expr::Bool(b) => "(lit (bool " + (if b { "true" } else { "false" }) + "))"
    Expr::String(s) => "(lit (string " + escape_string(s) + "))"
    Expr::Ident(name) => {
      let resolved = resolve_qualified(name, aliases)
      "(ref " + escape_string(resolved) + ")"
    }
    Expr::Call(name~, args~) => {
      let resolved = resolve_qualified(name, aliases)
      let buf = StringBuilder::new()
      buf.write_string("(call ")
      buf.write_string(escape_string(resolved))
      buf.write_string(" (args")
      for arg in args {
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(arg, aliases))
      }
      buf.write_string("))")
      buf.to_string()
    }
    Expr::If(cond~, then_body~, else_body~) => {
      let buf = StringBuilder::new()
      buf.write_string("(if ")
      buf.write_string(expr_to_sexp(cond, aliases))
      buf.write_char(' ')
      buf.write_string(block_to_sexp(then_body, aliases))
      buf.write_char(' ')
      buf.write_string(block_to_sexp(else_body, aliases))
      buf.write_char(')')
      buf.to_string()
    }
    Expr::Block(body~) => block_to_sexp(body, aliases)
    Expr::Match(scrutinee~, arms~) => {
      let buf = StringBuilder::new()
      buf.write_string("(match ")
      buf.write_string(expr_to_sexp(scrutinee, aliases))
      buf.write_string(" (arms")
      for arm in arms {
        buf.write_char(' ')
        buf.write_string(match_arm_to_sexp(arm, aliases))
      }
      buf.write_string("))")
      buf.to_string()
    }
    Expr::Do(body~) => "(do " + block_to_sexp(body, aliases) + ")"
    Expr::Tuple(items) => {
      let buf = StringBuilder::new()
      buf.write_string("(tuple")
      for item in items {
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(item, aliases))
      }
      buf.write_char(')')
      buf.to_string()
    }
    Expr::Record(fields) => {
      let buf = StringBuilder::new()
      buf.write_string("(record")
      for field in fields {
        buf.write_char(' ')
        buf.write_string("(field ")
        buf.write_string(escape_string(field.name))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(field.expr, aliases))
        buf.write_char(')')
      }
      buf.write_char(')')
      buf.to_string()
    }
  }
}

fn match_arm_to_sexp(arm : MatchArm, aliases : Map[String, Ref]) -> String {
  let buf = StringBuilder::new()
  buf.write_string("(arm ")
  buf.write_string(pat_to_sexp(arm.pat))
  match arm.cond {
    Some(c) => {
      buf.write_string(" (guard ")
      buf.write_string(expr_to_sexp(c, aliases))
      buf.write_char(')')
    }
    None => ()
  }
  buf.write_char(' ')
  buf.write_string(expr_to_sexp(arm.expr, aliases))
  buf.write_char(')')
  buf.to_string()
}

fn pat_to_sexp(pat : Pat) -> String {
  match pat {
    Pat::Wildcard => "(pat _)"
    Pat::Bind(name) => "(pat (bind " + escape_string(name) + "))"
    Pat::Tuple(items) => {
      let buf = StringBuilder::new()
      buf.write_string("(pat (tuple")
      for item in items {
        buf.write_char(' ')
        buf.write_string(pat_to_sexp(item))
      }
      buf.write_string("))")
      buf.to_string()
    }
    Pat::Record(fields) => {
      let buf = StringBuilder::new()
      buf.write_string("(pat (record")
      for field in fields {
        buf.write_char(' ')
        buf.write_string("(field ")
        buf.write_string(escape_string(field.name))
        buf.write_char(' ')
        buf.write_string(pat_to_sexp(field.pat))
        buf.write_char(')')
      }
      buf.write_string("))")
      buf.to_string()
    }
    Pat::Int(n) => "(pat (int " + n.to_string() + "))"
    Pat::Bool(b) => "(pat (bool " + (if b { "true" } else { "false" }) + "))"
    Pat::String(s) => "(pat (string " + escape_string(s) + "))"
  }
}

///| Escape a string literal for S-expr.
fn escape_string(s : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('\"')
  for ch in s {
    match ch {
      '\"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(ch)
    }
  }
  buf.write_char('\"')
  buf.to_string()
}

///| Escape atom when used as name.
fn escape_atom(s : String) -> String {
  if s.is_empty() {
    "\"\""
  } else {
    escape_string(s)
  }
}
