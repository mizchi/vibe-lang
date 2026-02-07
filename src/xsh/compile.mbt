///|
/// xsh compile + run pipeline (prototype)
suberror CompileError {
  MissingSource(String)
  Parse(@parser.ParseError)
  TypeDiag(@core.Diagnostic)
} derive(Show, Eq)

///|
suberror WasmCompileError {
  Compile(CompileError)
  Gen(@codegen.WasmGenError)
} derive(Show, Eq)

///|
pub struct CompiledModule {
  path : String
  ir : String
  ir_hash : String
  module_ref : String
  imports : Array[String]
  aliases : Map[String, @core.Ref]
  ast : @core.Module
  instantiations : Map[String, Int]
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
  let raw_ast = @parser.parse_ast(source) catch {
    e => raise CompileError::Parse(e)
  }
  let aliases = build_alias_map(raw_ast, db.import_aliases(path))
  let ast = desugar_method_calls(raw_ast, aliases)
  // Use db.types() which handles import type resolution (including imported symbols)
  let env = db.types(path)
  // Check for any type errors that were collected as diagnostics
  let diags = db.diagnostics(path)
  for diag in diags {
    if diag.stage == "type" {
      raise CompileError::TypeDiag(diag)
    }
  }
  let mono = monoify_module(ast, env)
  let ir = module_to_sexp(mono.ast, aliases)
  let ir_hash = @core.git_blob_hash_string(ir)
  let module_ref = @core.module_ref_from_hash(ir_hash)
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
    ast: mono.ast,
    instantiations: mono.instantiations,
  }
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
  let bundled = bundle_for_wasm(db, path, compiled.ast)
  @codegen.emit_module_wasm(bundled) catch {
    e => raise WasmCompileError::Gen(e)
  }
}

///|
/// Compile a module to WASM using wasm js-string builtins.
pub fn compile_module_wasm_js_string(
  db : XshDb,
  path : String,
) -> Bytes raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let bundled = bundle_for_wasm(db, path, compiled.ast)
  @codegen.emit_module_wasm_js_string(bundled) catch {
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
  let bundled = bundle_for_wasm(db, path, compiled.ast)
  @codegen.emit_module_wasm_gc(bundled) catch {
    e => raise WasmCompileError::Gen(e)
  }
}

///|
/// Compile a module to WASM without DCE (for benchmarking).
pub fn compile_module_wasm_no_dce(
  db : XshDb,
  path : String,
) -> Bytes raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let bundled = bundle_for_wasm_no_dce(db, path, compiled.ast)
  @codegen.emit_module_wasm(bundled) catch {
    e => raise WasmCompileError::Gen(e)
  }
}

///|
/// Compile a module to Component Model WASM (for wkg/wa.dev compatibility).
/// Uses Canon lift to properly expose the run function as a component export.
pub fn compile_module_component(
  db : XshDb,
  path : String,
) -> Bytes raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let bundled = bundle_for_wasm(db, path, compiled.ast)
  let core_wasm = @codegen.emit_module_wasm(bundled) catch {
    e => raise WasmCompileError::Gen(e)
  }
  @codegen.emit_component_wasm_with_lift(core_wasm, "run")
}

///|
/// Generate WIT interface definition for a module.
/// Uses pre-bundling AST to preserve all export declarations.
pub fn generate_module_wit(
  db : XshDb,
  path : String,
  package_name : String,
  world_name : String,
) -> String raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  // Use pre-bundling AST to preserve Export statements and all Let definitions
  @codegen.generate_wit(compiled.ast, package_name, world_name)
}

///|
/// Bundle a module with all its dependencies for WASM compilation.
/// This inlines all exported definitions from dependencies and removes imports.
/// Applies DCE to eliminate unused definitions.
fn bundle_for_wasm(
  db : XshDb,
  path : String,
  ast : @core.Module,
) -> @core.Module {
  bundle_for_wasm_impl(db, path, ast, apply_dce=true)
}

///|
/// Bundle without DCE (for benchmarking comparison).
pub fn bundle_for_wasm_no_dce(
  db : XshDb,
  path : String,
  ast : @core.Module,
) -> @core.Module {
  bundle_for_wasm_impl(db, path, ast, apply_dce=false)
}

///|
fn bundle_for_wasm_impl(
  db : XshDb,
  path : String,
  ast : @core.Module,
  apply_dce~ : Bool,
) -> @core.Module {
  let bundled_stmts : Array[@core.Stmt] = []
  let visited : Map[String, Bool] = {}
  // Collect all dependency definitions in topological order
  collect_dependency_defs(db, path, bundled_stmts, visited)
  // Add main module statements (excluding imports, aliases, and expanding re-exports)
  let base_dir = @path.Path(path).dirname().to_string()
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(..) => () // Skip imports
      @core.Stmt::Alias(..) => () // Skip aliases
      @core.Stmt::ReExport(names~, source~, span=_) =>
        // Expand re-exports in main module
        collect_reexport_defs(
          db, base_dir, names, source, bundled_stmts, visited,
        )
      _ => bundled_stmts.push(stmt)
    }
  }
  let bundled = @core.Module::{ stmts: bundled_stmts }
  if apply_dce {
    dce_module(bundled)
  } else {
    bundled
  }
}

///|
/// Recursively collect definitions from dependencies.
fn collect_dependency_defs(
  db : XshDb,
  path : String,
  out : Array[@core.Stmt],
  visited : Map[String, Bool],
) -> Unit {
  if visited.contains(path) {
    return
  }
  visited[path] = true
  let imports = db.imports(path)
  // First, recursively process dependencies
  for imp in imports {
    collect_dependency_defs(db, imp.path, out, visited)
  }
  // Then add definitions from this module (if it's an imported module)
  // Skip the entry module itself (it will be added separately)
  if visited.length() > 1 {
    let dep_ast = db.ast(path)
    let base_dir = @path.Path(path).dirname().to_string()
    for stmt in dep_ast.stmts {
      match stmt {
        // Convert exports to regular definitions
        @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
          out.push(@core.Stmt::Let(rec~, name~, expr~, span~))
        @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
          out.push(@core.Stmt::EnumDef(name~, params~, ctors~, span~))
        @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
          out.push(@core.Stmt::TypeAlias(name~, params~, target~, span~))
        // Also include non-exported definitions that exported ones might depend on
        @core.Stmt::Let(..)
        | @core.Stmt::EnumDef(..)
        | @core.Stmt::TypeAlias(..) => out.push(stmt)
        // Handle re-exports: fetch definitions from source module
        @core.Stmt::ReExport(names~, source~, span=_) =>
          collect_reexport_defs(db, base_dir, names, source, out, visited)
        // Skip imports, exports, aliases in dependencies
        @core.Stmt::Import(..)
        | @core.Stmt::Alias(..)
        | @core.Stmt::Export(..) => ()
        // Skip tests from dependencies
        @core.Stmt::Test(..) => ()
        // Other statements are passed through
        _ => out.push(stmt)
      }
    }
  }
}

///|
/// Collect definitions for re-export statement.
fn collect_reexport_defs(
  db : XshDb,
  base_dir : String,
  names : Array[String],
  source : @core.ModuleRef,
  out : Array[@core.Stmt],
  visited : Map[String, Bool],
) -> Unit {
  // Resolve source module path
  let source_path = match source {
    @core.ModuleRef::Path(path~) =>
      if path.has_prefix("/") {
        path
      } else {
        @path.Path(base_dir).join(@path.Path(path)).normalize().to_string()
      }
    @core.ModuleRef::Hash(hash~) => hash // Use hash as path for now
  }
  // Recursively process the source module's dependencies first
  collect_dependency_defs(db, source_path, out, visited)
  // Get the source module AST
  let source_ast = db.ast(source_path)
  // Build a set of requested names for quick lookup
  let requested : Map[String, Bool] = {}
  for name in names {
    requested[name] = true
  }
  // Extract matching definitions from source module
  for stmt in source_ast.stmts {
    match stmt {
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
        if requested.contains(name) {
          out.push(@core.Stmt::Let(rec~, name~, expr~, span~))
        }
      @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
        if requested.contains(name) {
          out.push(@core.Stmt::EnumDef(name~, params~, ctors~, span~))
        }
      @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
        if requested.contains(name) {
          out.push(@core.Stmt::TypeAlias(name~, params~, target~, span~))
        }
      @core.Stmt::Let(rec~, name~, expr~, span~) =>
        if requested.contains(name) {
          out.push(@core.Stmt::Let(rec~, name~, expr~, span~))
        }
      @core.Stmt::EnumDef(name~, params~, ctors~, span~) =>
        if requested.contains(name) {
          out.push(@core.Stmt::EnumDef(name~, params~, ctors~, span~))
        }
      @core.Stmt::TypeAlias(name~, params~, target~, span~) =>
        if requested.contains(name) {
          out.push(@core.Stmt::TypeAlias(name~, params~, target~, span~))
        }
      _ => ()
    }
  }
}

///|
/// Merge alias statements into import alias map.
fn build_alias_map(
  ast : @core.Module,
  import_aliases : Map[String, @core.Ref],
) -> Map[String, @core.Ref] {
  let aliases = import_aliases
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
/// Convert module to canonical S-expression for hashing.
fn module_to_sexp(
  ast : @core.Module,
  aliases : Map[String, @core.Ref],
) -> String {
  "(module " + stmts_to_sexp(ast.stmts, aliases) + ")"
}

///|
fn stmts_to_sexp(
  stmts : Array[@core.Stmt],
  aliases : Map[String, @core.Ref],
) -> String {
  let buf = StringBuilder::new()
  buf.write_string("(stmts")
  for stmt in stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
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
      @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
        let _ = span
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
      @core.Stmt::TypeAlias(name~, params~, target~, span~) => {
        let _ = span
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
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        buf.write_string(" (expr ")
        buf.write_string(expr_to_sexp(expr, aliases))
        buf.write_char(')')
      }
      @core.Stmt::Flake(raw~, span~) => {
        let _ = raw
        let _ = span
        buf.write_string(" (flake)")
      }
      @core.Stmt::Alias(name~, target~, span~) => {
        let _ = name
        let _ = target
        let _ = span

      }
      @core.Stmt::Import(spec~, source~, span~) => {
        let _ = spec
        let _ = source
        let _ = span

      }
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
        let _ = span
        if rec {
          buf.write_string(" (export-let-rec ")
        } else {
          buf.write_string(" (export-let ")
        }
        buf.write_string(escape_atom(name))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(expr, aliases))
        buf.write_char(')')
      }
      @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) => {
        let _ = span
        buf.write_string(" (export-enum ")
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
      @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) => {
        let _ = span
        buf.write_string(" (export-type-alias ")
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
      @core.Stmt::Export(..) | @core.Stmt::ReExport(..) => ()
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = name
        let _ = body
        let _ = span

      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        let _ = span
        buf.write_string(" (let-mut ")
        buf.write_string(escape_atom(name))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(expr, aliases))
        buf.write_char(')')
      }
      @core.Stmt::Assign(name~, expr~, span~) => {
        let _ = span
        buf.write_string(" (assign ")
        buf.write_string(escape_atom(name))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(expr, aliases))
        buf.write_char(')')
      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = span
        buf.write_string(" (let-pat ")
        buf.write_string(pat_to_sexp(pat))
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(expr, aliases))
        buf.write_char(')')
      }
    }
  }
  buf.write_char(')')
  buf.to_string()
}

///|
fn block_to_sexp(
  body : @core.Module,
  aliases : Map[String, @core.Ref],
) -> String {
  "(block " + stmts_to_sexp(body.stmts, aliases) + ")"
}

///|
/// Convert expression to S-expression.
fn expr_to_sexp(expr : @core.Expr, aliases : Map[String, @core.Ref]) -> String {
  match expr {
    @core.Expr::Int(value=n, span~) => {
      let _ = span
      "(lit (int " + n.to_string() + "))"
    }
    @core.Expr::Float(value=n, span~) => {
      let _ = span
      "(lit (float " + n.to_string() + "))"
    }
    @core.Expr::Double(value=n, span~) => {
      let _ = span
      "(lit (double " + n.to_string() + "))"
    }
    @core.Expr::Bool(value=b, span~) => {
      let _ = span
      "(lit (bool " + (if b { "true" } else { "false" }) + "))"
    }
    @core.Expr::String(value=s, span~) => {
      let _ = span
      "(lit (string " + escape_string(s) + "))"
    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      let resolved = @core.resolve_qualified(name, aliases)
      "(ref " + escape_string(resolved) + ")"
    }
    @core.Expr::Placeholder(..) =>
      // Placeholder should be desugared before compile
      "(placeholder)"
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      let resolved = @core.resolve_qualified(name, aliases)
      let buf = StringBuilder::new()
      buf.write_string("(call ")
      buf.write_string(escape_string(resolved))
      buf.write_char(' ')
      buf.write_string(call_args_to_sexp(args, aliases))
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
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
    @core.Expr::Block(body~, span~) => {
      let _ = span
      block_to_sexp(body, aliases)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
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
    @core.Expr::Do(body~, span~) => {
      let _ = span
      "(do " + block_to_sexp(body, aliases) + ")"
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(tuple")
      for item in items {
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(item, aliases))
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::TupleIndex(expr~, index~, span~) => {
      let _ = span
      "(tuple-index " + expr_to_sexp(expr, aliases) + " " + index.to_string() +
      ")"
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
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
    @core.Expr::Array(items~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(array")
      for item in items {
        buf.write_char(' ')
        buf.write_string(expr_to_sexp(item, aliases))
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
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
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(try ")
      buf.write_string(block_to_sexp(try_body, aliases))
      buf.write_char(' ')
      buf.write_string(block_to_sexp(catch_body, aliases))
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
      let _ = span
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
      buf.write_string(") (effects")
      for effect in effects {
        buf.write_char(' ')
        buf.write_string(effect_atom_to_sexp(effect))
      }
      buf.write_string(") ")
      buf.write_string(block_to_sexp(body, aliases))
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(while ")
      buf.write_string(expr_to_sexp(cond, aliases))
      buf.write_char(' ')
      buf.write_string(block_to_sexp(body, aliases))
      buf.write_char(')')
      buf.to_string()
    }
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      "(raise " + expr_to_sexp(value, aliases) + ")"
    }
    @core.Expr::Await(expr~, span~) => {
      let _ = span
      "(await " + expr_to_sexp(expr, aliases) + ")"
    }
    @core.Expr::Yield(expr~, span~) => {
      let _ = span
      "(yield " + expr_to_sexp(expr, aliases) + ")"
    }
  }
}

///|
fn call_args_to_sexp(
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
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
fn param_to_sexp(param : @core.FuncParam) -> String {
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
fn label_to_sexp(label : @core.ParamLabel) -> String {
  match label {
    @core.ParamLabel::Positional => "pos"
    @core.ParamLabel::Required => "req"
    @core.ParamLabel::Optional => "opt"
  }
}

///|
fn type_to_sexp(ty : @core.Type) -> String {
  match ty {
    @core.Type::Int => "Int"
    @core.Type::Float => "Float"
    @core.Type::Double => "Double"
    @core.Type::Bool => "Bool"
    @core.Type::String => "String"
    @core.Type::Path => "@core.Path"
    @core.Type::Unit => "Unit"
    @core.Type::Named(name~, args~) => {
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
    @core.Type::Param(name) => "(Param " + escape_atom(name) + ")"
    @core.Type::Var(id) => "(Var " + id.to_string() + ")"
    @core.Type::Tuple(items) => {
      let buf = StringBuilder::new()
      buf.write_string("(Tuple")
      for item in items {
        buf.write_char(' ')
        buf.write_string(type_to_sexp(item))
      }
      buf.write_char(')')
      buf.to_string()
    }
    @core.Type::Record(fields) => {
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
    @core.Type::Array(inner) => "(Array " + type_to_sexp(inner) + ")"
    @core.Type::Map(inner) => "(Map " + type_to_sexp(inner) + ")"
    @core.Type::ArrayBuilder(inner) =>
      "(ArrayBuilder " + type_to_sexp(inner) + ")"
    @core.Type::MapBuilder(inner) => "(MapBuilder " + type_to_sexp(inner) + ")"
    @core.Type::Variant(fields) => {
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
    @core.Type::Func(params~, ret~, effects~) => {
      let buf = StringBuilder::new()
      buf.write_string("(Func (params")
      for param in params {
        buf.write_char(' ')
        buf.write_string(param_to_sexp(param))
      }
      buf.write_string(") (ret ")
      buf.write_string(type_to_sexp(ret))
      buf.write_string(") (effects")
      for effect in effects {
        buf.write_char(' ')
        buf.write_string(effect_atom_to_sexp(effect))
      }
      buf.write_char(')')
      buf.write_char(')')
      buf.to_string()
    }
    @core.Type::Never => "Never"
  }
}

///|
fn effect_atom_to_sexp(effect : @core.EffectAtom) -> String {
  match effect {
    @core.EffectAtom::Const(name) => escape_atom(name)
    @core.EffectAtom::Var(name) => escape_atom(name)
  }
}

///|
fn type_ctor_payload(ctor : @core.TypeCtor) -> @core.Type {
  if ctor.args.length() == 0 {
    @core.Type::Unit
  } else if ctor.args.length() == 1 {
    ctor.args[0]
  } else {
    @core.Type::Tuple(ctor.args)
  }
}

///|
fn sort_record_type_keys(fields : Map[String, @core.Type]) -> Array[String] {
  let out : Array[String] = []
  for name, _ in fields {
    out.push(name)
    let mut i = out.length() - 1
    while i > 0 && out[i] < out[i - 1] {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn sort_map_fields_expr(
  fields : Array[@core.MapFieldExpr],
) -> Array[@core.MapFieldExpr] {
  let out : Array[@core.MapFieldExpr] = []
  for field in fields {
    out.push(field)
    let mut i = out.length() - 1
    while i > 0 && out[i].key < out[i - 1].key {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn sort_record_fields_expr(
  fields : Array[@core.RecordFieldExpr],
) -> Array[@core.RecordFieldExpr] {
  let out : Array[@core.RecordFieldExpr] = []
  for field in fields {
    out.push(field)
    let mut i = out.length() - 1
    while i > 0 && out[i].name < out[i - 1].name {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn sort_type_ctors(ctors : Array[@core.TypeCtor]) -> Array[@core.TypeCtor] {
  let out : Array[@core.TypeCtor] = []
  for ctor in ctors {
    out.push(ctor)
    let mut i = out.length() - 1
    while i > 0 && out[i].name < out[i - 1].name {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn match_arm_to_sexp(
  arm : @core.MatchArm,
  aliases : Map[String, @core.Ref],
) -> String {
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
fn pat_to_sexp(pat : @core.Pat) -> String {
  match pat {
    @core.Pat::Wildcard(span~) => {
      let _ = span
      "(pat _)"
    }
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      "(pat (bind " + escape_string(name) + "))"
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = span
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
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(pat (tuple")
      for item in items {
        buf.write_char(' ')
        buf.write_string(pat_to_sexp(item))
      }
      buf.write_string("))")
      buf.to_string()
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
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
    @core.Pat::Int(value=n, span~) => {
      let _ = span
      "(pat (int " + n.to_string() + "))"
    }
    @core.Pat::Float(value=n, span~) => {
      let _ = span
      "(pat (float " + n.to_string() + "))"
    }
    @core.Pat::Double(value=n, span~) => {
      let _ = span
      "(pat (double " + n.to_string() + "))"
    }
    @core.Pat::Bool(value=b, span~) => {
      let _ = span
      "(pat (bool " + (if b { "true" } else { "false" }) + "))"
    }
    @core.Pat::String(value=s, span~) => {
      let _ = span
      "(pat (string " + escape_string(s) + "))"
    }
    @core.Pat::Or(pats~, span~) => {
      let _ = span
      let buf = StringBuilder::new()
      buf.write_string("(pat (or")
      for p in pats {
        buf.write_char(' ')
        buf.write_string(pat_to_sexp(p))
      }
      buf.write_string("))")
      buf.to_string()
    }
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
