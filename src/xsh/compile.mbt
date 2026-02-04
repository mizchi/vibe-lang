///|
/// xsh compile + run pipeline (prototype)
suberror CompileError {
  MissingSource(String)
  Parse(ParseError)
  Type(TypeError)
} derive(Show, Eq)

///|
suberror WasmCompileError {
  Compile(CompileError)
  Gen(WasmGenError)
} derive(Show, Eq)

///|
pub struct CompiledModule {
  path : String
  ir : String
  ir_hash : String
  module_ref : String
  imports : Array[String]
  aliases : Map[String, Ref]
  ast : Module
}

///|
/// Compile a module from the database (WASM target: wasm-gc + js builtin).
pub fn compile_module(
  db : XshDb,
  path : String,
) -> CompiledModule raise CompileError {
  let source = match db.get_source(path) {
    Some(s) => s
    None => raise CompileError::MissingSource(path)
  }
  let ast = parse_ast(source) catch { e => raise CompileError::Parse(e) }
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
  { path, ir, ir_hash, module_ref, imports, aliases, ast }
}

///|
/// Execute compiled module using the xsh runtime (interpreter).
pub fn Runtime::run_compiled(
  self : Runtime,
  compiled : CompiledModule,
) -> EvalResult raise XshError {
  let _ = compiled // keep for future wasm backend
  for name, target in compiled.aliases {
    self.set_alias(name, target)
  }
  self.eval_module(compiled.ast) catch {
    e => raise XshError::Eval(e)
  }
}

///|
/// Compile a module to WASM (wasm-gc compatible, minimal MVP).
pub fn compile_module_wasm(
  db : XshDb,
  path : String,
) -> Bytes raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  emit_module_wasm(compiled.ast) catch {
    e => raise WasmCompileError::Gen(e)
  }
}

///|
/// Compile a module to WASM using wasm-gc opcodes (fixture-focused).
pub fn compile_module_wasm_gc(
  db : XshDb,
  path : String,
) -> Bytes raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  emit_module_wasm_gc(compiled.ast) catch {
    e => raise WasmCompileError::Gen(e)
  }
}

///|
/// Merge alias statements into import alias map.
fn build_alias_map(
  ast : Module,
  import_aliases : Map[String, Ref],
) -> Map[String, Ref] {
  let aliases = import_aliases
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

///|
/// Convert module to canonical S-expression for hashing.
fn module_to_sexp(ast : Module, aliases : Map[String, Ref]) -> String {
  "(module " + stmts_to_sexp(ast.stmts, aliases) + ")"
}

///|
fn stmts_to_sexp(stmts : Array[Stmt], aliases : Map[String, Ref]) -> String {
  let buf = StringBuilder::new()
  buf.write_string("(stmts")
  for stmt in stmts {
    match stmt {
      Stmt::Let(rec~, name~, expr~) => {
        if rec {
          buf.write_string(" (let-rec ")
        } else {
          buf.write_string(" (let ")
        }
        buf.write_string(escape_atom(name))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(expr, aliases))
        buf.write_char(')')
      }
      Stmt::EnumDef(name~, params~, ctors~) => {
        buf.write_string(" (enum ")
        buf.write_string(escape_atom(name))
        buf.write_string(" (params")
        for param in params {
          buf.write_char(' ')
          buf.write_string(escape_atom(param))
        }
        buf.write_string(") (ctors")
        let sorted = sort_type_ctors(ctors)
        for ctor in sorted {
          buf.write_string(" (ctor ")
          buf.write_string(escape_atom(ctor.name))
          buf.write_char(' ')
          buf.write_string(type_to_sexp(type_ctor_payload(ctor)))
          buf.write_char(')')
        }
        buf.write_string("))")
      }
      Stmt::TypeAlias(name~, params~, target~) => {
        buf.write_string(" (type-alias ")
        buf.write_string(escape_atom(name))
        buf.write_string(" (params")
        for param in params {
          buf.write_char(' ')
          buf.write_string(escape_atom(param))
        }
        buf.write_string(") ")
        buf.write_string(type_to_sexp(target))
        buf.write_char(')')
      }
      Stmt::Expr(expr~) => {
        buf.write_string(" (expr ")
        buf.write_string(expr_to_sexp(expr, aliases))
        buf.write_char(')')
      }
      Stmt::Flake(_) => buf.write_string(" (flake)")
      Stmt::Alias(..) => ()
      Stmt::Import(..) => ()
      Stmt::Test(..) => ()
    }
  }
  buf.write_char(')')
  buf.to_string()
}

///|
fn block_to_sexp(body : Module, aliases : Map[String, Ref]) -> String {
  "(block " + stmts_to_sexp(body.stmts, aliases) + ")"
}

///|
/// Convert expression to S-expression.
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
      buf.write_char(' ')
      buf.write_string(call_args_to_sexp(args, aliases))
      buf.write_char(')')
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
      let sorted = sort_record_fields_expr(fields)
      for field in sorted {
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
    Expr::Array(items) => {
      let buf = StringBuilder::new()
      buf.write_string("(array")
      for item in items {
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(item, aliases))
      }
      buf.write_char(')')
      buf.to_string()
    }
    Expr::Map(fields) => {
      let buf = StringBuilder::new()
      buf.write_string("(map")
      let sorted = sort_map_fields_expr(fields)
      for field in sorted {
        buf.write_char(' ')
        buf.write_string("(field ")
        buf.write_string(escape_string(field.key))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(field.expr, aliases))
        buf.write_char(')')
      }
      buf.write_char(')')
      buf.to_string()
    }
    Expr::Fn(params~, ret~, body~) => {
      let buf = StringBuilder::new()
      buf.write_string("(fn (params")
      for param in params {
        buf.write_char(' ')
        buf.write_string(param_to_sexp(param))
      }
      buf.write_string(") (ret ")
      match ret {
        Some(r) => buf.write_string(type_to_sexp(r))
        None => buf.write_string("_")
      }
      buf.write_string(") ")
      buf.write_string(block_to_sexp(body, aliases))
      buf.write_char(')')
      buf.to_string()
    }
  }
}

///|
fn call_args_to_sexp(
  args : Array[CallArg],
  aliases : Map[String, Ref],
) -> String {
  let buf = StringBuilder::new()
  buf.write_string("(args")
  for arg in args {
    buf.write_string(" (arg ")
    match arg.label {
      Some(label) => buf.write_string(escape_atom(label))
      None => buf.write_string("_")
    }
    buf.write_char(' ')
    buf.write_string(expr_to_sexp(arg.expr, aliases))
    buf.write_char(')')
  }
  buf.write_char(')')
  buf.to_string()
}

///|
fn param_to_sexp(param : FuncParam) -> String {
  let buf = StringBuilder::new()
  buf.write_string("(param ")
  buf.write_string(escape_atom(param.name))
  buf.write_char(' ')
  buf.write_string(label_to_sexp(param.label))
  buf.write_char(' ')
  buf.write_string(type_to_sexp(param.ty))
  buf.write_char(')')
  buf.to_string()
}

///|
fn label_to_sexp(label : ParamLabel) -> String {
  match label {
    ParamLabel::Positional => "pos"
    ParamLabel::Required => "req"
    ParamLabel::Optional => "opt"
  }
}

///|
fn type_to_sexp(ty : Type) -> String {
  match ty {
    Type::Int => "Int"
    Type::Bool => "Bool"
    Type::String => "String"
    Type::Path => "Path"
    Type::Unit => "Unit"
    Type::Named(name~, args~) => {
      let buf = StringBuilder::new()
      buf.write_string("(Named ")
      buf.write_string(escape_atom(name))
      for arg in args {
        buf.write_char(' ')
        buf.write_string(type_to_sexp(arg))
      }
      buf.write_char(')')
      buf.to_string()
    }
    Type::Param(name) => "(Param " + escape_atom(name) + ")"
    Type::Var(id) => "(Var " + id.to_string() + ")"
    Type::Tuple(items) => {
      let buf = StringBuilder::new()
      buf.write_string("(Tuple")
      for item in items {
        buf.write_char(' ')
        buf.write_string(type_to_sexp(item))
      }
      buf.write_char(')')
      buf.to_string()
    }
    Type::Record(fields) => {
      let keys = sort_record_type_keys(fields)
      let buf = StringBuilder::new()
      buf.write_string("(Record")
      for key in keys {
        match fields.get(key) {
          Some(field_ty) => {
            buf.write_char(' ')
            buf.write_string("(field ")
            buf.write_string(escape_atom(key))
            buf.write_char(' ')
            buf.write_string(type_to_sexp(field_ty))
            buf.write_char(')')
          }
          None => ()
        }
      }
      buf.write_char(')')
      buf.to_string()
    }
    Type::Array(inner) => "(Array " + type_to_sexp(inner) + ")"
    Type::Map(inner) => "(Map " + type_to_sexp(inner) + ")"
    Type::ArrayBuilder(inner) => "(ArrayBuilder " + type_to_sexp(inner) + ")"
    Type::MapBuilder(inner) => "(MapBuilder " + type_to_sexp(inner) + ")"
    Type::Variant(fields) => {
      let keys = sort_record_type_keys(fields)
      let buf = StringBuilder::new()
      buf.write_string("(Variant")
      for key in keys {
        match fields.get(key) {
          Some(field_ty) => {
            buf.write_char(' ')
            buf.write_string("(ctor ")
            buf.write_string(escape_atom(key))
            buf.write_char(' ')
            buf.write_string(type_to_sexp(field_ty))
            buf.write_char(')')
          }
          None => ()
        }
      }
      buf.write_char(')')
      buf.to_string()
    }
    Type::Func(params~, ret~) => {
      let buf = StringBuilder::new()
      buf.write_string("(Func (params")
      for param in params {
        buf.write_char(' ')
        buf.write_string(param_to_sexp(param))
      }
      buf.write_string(") ")
      buf.write_string(type_to_sexp(ret))
      buf.write_char(')')
      buf.to_string()
    }
  }
}

///|
fn type_ctor_payload(ctor : TypeCtor) -> Type {
  if ctor.args.length() == 0 {
    Type::Unit
  } else if ctor.args.length() == 1 {
    ctor.args[0]
  } else {
    Type::Tuple(ctor.args)
  }
}

///|
fn sort_record_type_keys(fields : Map[String, Type]) -> Array[String] {
  let out : Array[String] = []
  for name, _ in fields {
    out.push(name)
    let mut i = out.length() - 1
    while i > 0 && string_lt_compile(out[i], out[i - 1]) {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn sort_map_fields_expr(fields : Array[MapFieldExpr]) -> Array[MapFieldExpr] {
  let out : Array[MapFieldExpr] = []
  for field in fields {
    out.push(field)
    let mut i = out.length() - 1
    while i > 0 && string_lt_compile(out[i].key, out[i - 1].key) {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn sort_type_ctors(ctors : Array[TypeCtor]) -> Array[TypeCtor] {
  let out : Array[TypeCtor] = []
  for ctor in ctors {
    out.push(ctor)
    let mut i = out.length() - 1
    while i > 0 && string_lt_compile(out[i].name, out[i - 1].name) {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn string_lt_compile(a : String, b : String) -> Bool {
  let ac : Array[Char] = []
  for c in a {
    ac.push(c)
  }
  let bc : Array[Char] = []
  for c in b {
    bc.push(c)
  }
  let min = if ac.length() < bc.length() { ac.length() } else { bc.length() }
  for i in 0..<min {
    if ac[i] < bc[i] {
      return true
    }
    if ac[i] > bc[i] {
      return false
    }
  }
  ac.length() < bc.length()
}

///|
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

///|
fn pat_to_sexp(pat : Pat) -> String {
  match pat {
    Pat::Wildcard => "(pat _)"
    Pat::Bind(name) => "(pat (bind " + escape_string(name) + "))"
    Pat::Ctor(name~, args~) => {
      let buf = StringBuilder::new()
      buf.write_string("(pat (ctor ")
      buf.write_string(escape_string(name))
      for arg in args {
        buf.write_char(' ')
        buf.write_string(pat_to_sexp(arg))
      }
      buf.write_string("))")
      buf.to_string()
    }
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

///|
/// Escape a string literal for S-expr.
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

///|
/// Escape atom when used as name.
fn escape_atom(s : String) -> String {
  if s.is_empty() {
    "\"\""
  } else {
    escape_string(s)
  }
}
