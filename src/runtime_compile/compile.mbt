///|
/// vibe compile + run pipeline (prototype)
suberror CompileError {
  MissingSource(String)
  Parse(@parser.ParseError)
  TypeDiag(@core.Diagnostic)
} derive(Debug, Eq)

///|
pub impl Show for CompileError with output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
suberror WasmCompileError {
  Compile(CompileError)
  Gen(@codegen.WasmGenError)
  Optimize(String)
} derive(Debug, Eq)

///|
pub impl Show for WasmCompileError with output(self, logger) {
  logger.write_string(self.user_message())
}

///|
pub fn WasmCompileError::user_message(self : WasmCompileError) -> String {
  match self {
    Compile(MissingSource(path)) => "missing source: " + path
    Compile(Parse(e)) => "parse error: " + e.to_string()
    Compile(TypeDiag(d)) => "type error: " + d.to_string()
    Gen(e) => e.format_message()
    Optimize(msg) => "optimize: " + msg
  }
}

///|
pub enum WasmCoveragePointKind {
  Line
  BranchIfThen
  BranchIfElse
  BranchMatchArm
} derive(Debug, Eq)

///|
pub struct WasmCoveragePoint {
  id : Int
  kind : WasmCoveragePointKind
  span : @core.Span
} derive(Debug, Eq)

///|
pub struct WasmCoverageArtifact {
  bytes : Bytes
  counter_base : Int
  counter_count : Int
  points : Array[WasmCoveragePoint]
} derive(Debug, Eq)

///|
pub struct WasmCompileStageProfile {
  module_us : Int
  bundle_us : Int
  emit_us : Int
  optimize_us : Int
  total_us : Int
} derive(Debug, Eq)

///|
pub impl Show for WasmCompileStageProfile with output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
pub struct CompiledModule {
  path : String
  ir : String
  ir_hash : String
  module_ref : String
  imports : Array[String]
  aliases : Map[String, @core.Ref]
  ast : @core.Module
  expr_type_index : @core.ExprTypeIndex
  type_env : @checker.TypeEnv
  instantiations : Map[String, Int]
}

///|
let compile_module_cache : Ref[Map[String, CompiledModule]] = @ref.new({})

///|
let wasm_artifact_cache : Ref[Map[String, Bytes]] = @ref.new({})

///|
priv struct RenameScope {
  bindings : Map[String, String]
  parent : RenameScope?
}

///|
fn RenameScope::new() -> RenameScope {
  { bindings: {}, parent: None }
}

///|
fn RenameScope::child(self : RenameScope) -> RenameScope {
  { bindings: {}, parent: Some(self) }
}

///|
fn rename_scope_lookup(scope : RenameScope, name : String) -> String? {
  if scope.bindings.contains(name) {
    Some(scope.bindings[name])
  } else {
    match scope.parent {
      Some(parent) => rename_scope_lookup(parent, name)
      None => None
    }
  }
}

///|
fn prefixed_private_value_name(path : String, name : String) -> String {
  let hash = @core.git_blob_hash_string(path)
  let short = hash.unsafe_substring(start=0, end=8)
  name + "$dep$" + short
}

///|
fn collect_exported_value_names(ast : @core.Module) -> Map[String, Bool] {
  let exported : Map[String, Bool] = {}
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::ExportLet(name~, ..)
      | @core.Stmt::InternalExportLet(name~, ..)
      | @core.Stmt::ExportEnumDef(name~, ..)
      | @core.Stmt::InternalExportEnumDef(name~, ..)
      | @core.Stmt::ExportTypeAlias(name~, ..)
      | @core.Stmt::InternalExportTypeAlias(name~, ..)
      | @core.Stmt::ExportStructDef(name~, ..)
      | @core.Stmt::InternalExportStructDef(name~, ..)
      | @core.Stmt::ExportEffectDef(name~, ..) => exported[name] = true
      @core.Stmt::Export(names~, ..) =>
        for name in names {
          exported[name] = true
        }
      _ => ()
    }
  }
  exported
}

///|
fn collect_private_value_rename_map(
  path : String,
  ast : @core.Module,
) -> Map[String, String] {
  let exported = collect_exported_value_names(ast)
  let rename_map : Map[String, String] = {}
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..)
      | @core.Stmt::LetMut(name~, ..)
      | @core.Stmt::ExternLet(name~, ..) =>
        if !exported.contains(name) {
          rename_map[name] = prefixed_private_value_name(path, name)
        }
      _ => ()
    }
  }
  rename_map
}

///|
fn rename_lookup_name(
  scope : RenameScope,
  rename_map : Map[String, String],
  name : String,
) -> String {
  match rename_scope_lookup(scope, name) {
    Some(mapped) => mapped
    None =>
      match rename_map.get(name) {
        Some(mapped) => mapped
        None => name
      }
  }
}

///|
fn bind_pattern_names_into_scope(scope : RenameScope, pat : @core.Pat) -> Unit {
  let bound : Map[String, Bool] = {}
  @core.bind_pattern_names_walker(bound, pat)
  for name, _ in bound {
    scope.bindings[name] = name
  }
}

///|
fn rename_call_args(
  args : Array[@core.CallArg],
  scope : RenameScope,
  rename_map : Map[String, String],
) -> Array[@core.CallArg] {
  let next : Array[@core.CallArg] = []
  for arg in args {
    next.push({
      label: arg.label,
      expr: rename_private_expr_refs(arg.expr, scope, rename_map),
      span: arg.span,
    })
  }
  next
}

///|
fn rename_match_arms(
  arms : Array[@core.MatchArm],
  scope : RenameScope,
  rename_map : Map[String, String],
) -> Array[@core.MatchArm] {
  let next : Array[@core.MatchArm] = []
  for arm in arms {
    let arm_scope = scope.child()
    bind_pattern_names_into_scope(arm_scope, arm.pat)
    let cond = match arm.cond {
      Some(expr) => Some(rename_private_expr_refs(expr, arm_scope, rename_map))
      None => None
    }
    next.push({
      pat: arm.pat,
      cond,
      expr: rename_private_expr_refs(arm.expr, arm_scope, rename_map),
      span: arm.span,
    })
  }
  next
}

///|
fn rename_record_fields(
  fields : Array[@core.RecordFieldExpr],
  scope : RenameScope,
  rename_map : Map[String, String],
) -> Array[@core.RecordFieldExpr] {
  let next : Array[@core.RecordFieldExpr] = []
  for field in fields {
    next.push({
      name: field.name,
      expr: rename_private_expr_refs(field.expr, scope, rename_map),
      span: field.span,
    })
  }
  next
}

///|
fn rename_map_fields(
  fields : Array[@core.MapFieldExpr],
  scope : RenameScope,
  rename_map : Map[String, String],
) -> Array[@core.MapFieldExpr] {
  let next : Array[@core.MapFieldExpr] = []
  for field in fields {
    next.push({
      key: field.key,
      expr: rename_private_expr_refs(field.expr, scope, rename_map),
      span: field.span,
    })
  }
  next
}

///|
fn rename_private_expr_refs(
  expr : @core.Expr,
  scope : RenameScope,
  rename_map : Map[String, String],
) -> @core.Expr {
  match expr {
    @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::Char(..)
    | @core.Expr::String(..)
    | @core.Expr::Placeholder(..) => expr
    @core.Expr::StringInterp(parts~, span~) => {
      let next : Array[@core.StringInterpPart] = []
      for part in parts {
        match part {
          @core.StringInterpPart::Lit(text) =>
            next.push(@core.StringInterpPart::Lit(text))
          @core.StringInterpPart::Expr(inner) =>
            next.push(
              @core.StringInterpPart::Expr(
                rename_private_expr_refs(inner, scope, rename_map),
              ),
            )
        }
      }
      @core.Expr::StringInterp(parts=next, span~)
    }
    @core.Expr::Ident(name~, span~) =>
      @core.Expr::Ident(name=rename_lookup_name(scope, rename_map, name), span~)
    @core.Expr::Call(name~, type_args~, args~, span~) =>
      @core.Expr::Call(
        name=rename_lookup_name(scope, rename_map, name),
        type_args~,
        args=rename_call_args(args, scope, rename_map),
        span~,
      )
    @core.Expr::Tuple(items~, span~) => {
      let next : Array[@core.Expr] = []
      for item in items {
        next.push(rename_private_expr_refs(item, scope, rename_map))
      }
      @core.Expr::Tuple(items=next, span~)
    }
    @core.Expr::TupleIndex(expr~, index~, span~) =>
      @core.Expr::TupleIndex(
        expr=rename_private_expr_refs(expr, scope, rename_map),
        index~,
        span~,
      )
    @core.Expr::Record(fields~, span~) =>
      @core.Expr::Record(
        fields=rename_record_fields(fields, scope, rename_map),
        span~,
      )
    @core.Expr::Array(items~, span~) => {
      let next : Array[@core.Expr] = []
      for item in items {
        next.push(rename_private_expr_refs(item, scope, rename_map))
      }
      @core.Expr::Array(items=next, span~)
    }
    @core.Expr::Map(fields~, span~) =>
      @core.Expr::Map(
        fields=rename_map_fields(fields, scope, rename_map),
        span~,
      )
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=rename_private_expr_refs(cond, scope, rename_map),
        then_body=rename_private_module_refs(
          then_body, scope, rename_map, false,
        ),
        else_body=rename_private_module_refs(
          else_body, scope, rename_map, false,
        ),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(
        body=rename_private_module_refs(body, scope, rename_map, false),
        span~,
      )
    @core.Expr::Match(scrutinee~, arms~, span~) =>
      @core.Expr::Match(
        scrutinee=rename_private_expr_refs(scrutinee, scope, rename_map),
        arms=rename_match_arms(arms, scope, rename_map),
        span~,
      )
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let body_scope = scope.child()
      body_scope.bindings[value_name] = value_name
      match index_name {
        Some(name) => body_scope.bindings[name] = name
        None => ()
      }
      @core.Expr::ForIn(
        value_name~,
        index_name~,
        iterable=rename_private_expr_refs(iterable, scope, rename_map),
        body=rename_private_module_refs(body, body_scope, rename_map, false),
        span~,
      )
    }
    @core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret~,
      effects~,
      body~,
      span~
    ) => {
      let body_scope = scope.child()
      for param in params {
        body_scope.bindings[param.name] = param.name
      }
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects~,
        body=rename_private_module_refs(body, body_scope, rename_map, false),
        span~,
      )
    }
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=rename_private_expr_refs(cond, scope, rename_map),
        body=rename_private_module_refs(body, scope, rename_map, false),
        span~,
      )
    @core.Expr::Loop(params~, body~, span~) => {
      let next_params : Array[@core.LoopParam] = []
      let body_scope = scope.child()
      for param in params {
        next_params.push({
          name: param.name,
          init: rename_private_expr_refs(param.init, scope, rename_map),
          span: param.span,
        })
        body_scope.bindings[param.name] = param.name
      }
      @core.Expr::Loop(
        params=next_params,
        body=rename_private_module_refs(body, body_scope, rename_map, false),
        span~,
      )
    }
    @core.Expr::Break(value~, span~) =>
      @core.Expr::Break(
        value=match value {
          Some(inner) =>
            Some(rename_private_expr_refs(inner, scope, rename_map))
          None => None
        },
        span~,
      )
    @core.Expr::Continue(args~, span~) => {
      let next : Array[@core.Expr] = []
      for arg in args {
        next.push(rename_private_expr_refs(arg, scope, rename_map))
      }
      @core.Expr::Continue(args=next, span~)
    }
    @core.Expr::Return(value~, span~) =>
      @core.Expr::Return(
        value=match value {
          Some(inner) =>
            Some(rename_private_expr_refs(inner, scope, rename_map))
          None => None
        },
        span~,
      )
    @core.Expr::Yield(expr~, span~) =>
      @core.Expr::Yield(
        expr=rename_private_expr_refs(expr, scope, rename_map),
        span~,
      )
    @core.Expr::Handle(body~, arms~, span~) =>
      @core.Expr::Handle(
        body=rename_private_module_refs(body, scope, rename_map, false),
        arms=rename_match_arms(arms, scope, rename_map),
        span~,
      )
    @core.Expr::StructLit(name~, type_args~, fields~, span~) =>
      @core.Expr::StructLit(
        name~,
        type_args~,
        fields=rename_record_fields(fields, scope, rename_map),
        span~,
      )
    @core.Expr::Spread(expr~, span~) =>
      @core.Expr::Spread(
        expr=rename_private_expr_refs(expr, scope, rename_map),
        span~,
      )
    @core.Expr::Perform(effect_name~, op_name~, args~, span~) =>
      @core.Expr::Perform(
        effect_name~,
        op_name~,
        args=rename_call_args(args, scope, rename_map),
        span~,
      )
  }
}

///|
fn rename_private_stmt_refs(
  stmt : @core.Stmt,
  scope : RenameScope,
  rename_map : Map[String, String],
  rename_toplevel_binders : Bool,
) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let next_name = if rename_toplevel_binders && rename_map.contains(name) {
        rename_map[name]
      } else {
        name
      }
      let expr_scope = if rec {
        let child = scope.child()
        child.bindings[name] = next_name
        child
      } else {
        scope
      }
      @core.Stmt::Let(
        rec~,
        name=next_name,
        expr=rename_private_expr_refs(expr, expr_scope, rename_map),
        span~,
      )
    }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::ExportLet(
        rec~,
        name~,
        expr=rename_private_expr_refs(expr, scope, rename_map),
        span~,
      )
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::InternalExportLet(
        rec~,
        name~,
        expr=rename_private_expr_refs(expr, scope, rename_map),
        span~,
      )
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let next_name = if rename_toplevel_binders && rename_map.contains(name) {
        rename_map[name]
      } else {
        name
      }
      @core.Stmt::LetMut(
        name=next_name,
        expr=rename_private_expr_refs(expr, scope, rename_map),
        span~,
      )
    }
    @core.Stmt::ExternLet(name~, ty~, span~) => {
      let next_name = if rename_toplevel_binders && rename_map.contains(name) {
        rename_map[name]
      } else {
        name
      }
      @core.Stmt::ExternLet(name=next_name, ty~, span~)
    }
    @core.Stmt::Assign(name~, expr~, span~) =>
      @core.Stmt::Assign(
        name=rename_lookup_name(scope, rename_map, name),
        expr=rename_private_expr_refs(expr, scope, rename_map),
        span~,
      )
    @core.Stmt::IndexAssign(target~, index~, value~, span~) =>
      @core.Stmt::IndexAssign(
        target=rename_private_expr_refs(target, scope, rename_map),
        index=rename_private_expr_refs(index, scope, rename_map),
        value=rename_private_expr_refs(value, scope, rename_map),
        span~,
      )
    @core.Stmt::LetPat(pat~, expr~, span~) =>
      @core.Stmt::LetPat(
        pat~,
        expr=rename_private_expr_refs(expr, scope, rename_map),
        span~,
      )
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) =>
      @core.Stmt::LetPatElse(
        pat~,
        expr=rename_private_expr_refs(expr, scope, rename_map),
        else_body=rename_private_module_refs(
          else_body, scope, rename_map, false,
        ),
        span~,
      )
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(
        expr=rename_private_expr_refs(expr, scope, rename_map),
        span~,
      )
    @core.Stmt::Test(name~, body~, span~) =>
      @core.Stmt::Test(
        name~,
        body=rename_private_module_refs(body, scope, rename_map, false),
        span~,
      )
    @core.Stmt::Bench(name~, body~, span~) =>
      @core.Stmt::Bench(
        name~,
        body=rename_private_module_refs(body, scope, rename_map, false),
        span~,
      )
    @core.Stmt::TraitImpl(
      type_params~,
      type_bounds~,
      trait_name~,
      target~,
      methods~,
      span~
    ) => {
      let next_methods : Array[@core.ImplMethodDef] = []
      for impl_method in methods {
        next_methods.push({
          name: impl_method.name,
          expr: rename_private_expr_refs(impl_method.expr, scope, rename_map),
          span: impl_method.span,
        })
      }
      @core.Stmt::TraitImpl(
        type_params~,
        type_bounds~,
        trait_name~,
        target~,
        methods=next_methods,
        span~,
      )
    }
    _ => stmt
  }
}

///|
fn extend_scope_with_stmt_bindings(
  scope : RenameScope,
  stmt : @core.Stmt,
  rename_map : Map[String, String],
  rename_toplevel_binders : Bool,
) -> Unit {
  match stmt {
    @core.Stmt::Let(name~, ..)
    | @core.Stmt::LetMut(name~, ..)
    | @core.Stmt::ExternLet(name~, ..) =>
      if rename_toplevel_binders && rename_map.contains(name) {
        scope.bindings[name] = rename_map[name]
      } else {
        scope.bindings[name] = name
      }
    @core.Stmt::ExportLet(name~, ..)
    | @core.Stmt::InternalExportLet(name~, ..) => scope.bindings[name] = name
    @core.Stmt::LetPat(pat~, ..) | @core.Stmt::LetPatElse(pat~, ..) =>
      bind_pattern_names_into_scope(scope, pat)
    _ => ()
  }
}

///|
fn rename_private_module_refs(
  mod_ : @core.Module,
  parent_scope : RenameScope,
  rename_map : Map[String, String],
  rename_toplevel_binders : Bool,
) -> @core.Module {
  let scope = parent_scope.child()
  let next_stmts : Array[@core.Stmt] = []
  for stmt in mod_.stmts {
    let next = rename_private_stmt_refs(
      stmt, scope, rename_map, rename_toplevel_binders,
    )
    next_stmts.push(next)
    extend_scope_with_stmt_bindings(
      scope, stmt, rename_map, rename_toplevel_binders,
    )
  }
  { stmts: next_stmts }
}

///|
fn namespace_private_module_values(
  path : String,
  ast : @core.Module,
) -> @core.Module {
  let rename_map = collect_private_value_rename_map(path, ast)
  if rename_map.length() == 0 {
    ast
  } else {
    rename_private_module_refs(ast, RenameScope::new(), rename_map, true)
  }
}

///|
fn namespace_private_module_values_for_existing_names(
  path : String,
  ast : @core.Module,
  existing_names : Map[String, Bool],
) -> @core.Module {
  let all_renames = collect_private_value_rename_map(path, ast)
  let rename_map : Map[String, String] = {}
  for name, renamed in all_renames {
    if existing_names.contains(name) {
      rename_map[name] = renamed
    }
  }
  if rename_map.length() == 0 {
    ast
  } else {
    rename_private_module_refs(ast, RenameScope::new(), rename_map, true)
  }
}

///|
fn rename_private_type_name(
  type_rename_map : Map[String, String],
  name : String,
) -> String {
  match type_rename_map.get(name) {
    Some(mapped) => mapped
    None => name
  }
}

///|
fn rename_private_ctor_lookup_name(
  scope : RenameScope,
  ctor_rename_map : Map[String, String],
  name : String,
) -> String {
  match rename_scope_lookup(scope, name) {
    Some(mapped) => mapped
    None =>
      match ctor_rename_map.get(name) {
        Some(mapped) => mapped
        None => name
      }
  }
}

///|
fn rename_private_type_refs(
  ty : @core.Type,
  type_rename_map : Map[String, String],
) -> @core.Type {
  match ty {
    @core.Type::Tuple(items) => {
      let next : Array[@core.Type] = []
      for item in items {
        next.push(rename_private_type_refs(item, type_rename_map))
      }
      @core.Type::Tuple(next)
    }
    @core.Type::Record(fields) => {
      let next : Map[String, @core.Type] = {}
      for name, field_ty in fields {
        next[name] = rename_private_type_refs(field_ty, type_rename_map)
      }
      @core.Type::Record(next)
    }
    @core.Type::Array(item) =>
      @core.Type::Array(rename_private_type_refs(item, type_rename_map))
    @core.Type::Map(key, value) =>
      @core.Type::Map(
        rename_private_type_refs(key, type_rename_map),
        rename_private_type_refs(value, type_rename_map),
      )
    @core.Type::Set(item) =>
      @core.Type::Set(rename_private_type_refs(item, type_rename_map))
    @core.Type::ArrayBuilder(item) =>
      @core.Type::ArrayBuilder(rename_private_type_refs(item, type_rename_map))
    @core.Type::MapBuilder(key, value) =>
      @core.Type::MapBuilder(
        rename_private_type_refs(key, type_rename_map),
        rename_private_type_refs(value, type_rename_map),
      )
    @core.Type::Variant(fields) => {
      let next : Map[String, @core.Type] = {}
      for name, field_ty in fields {
        next[name] = rename_private_type_refs(field_ty, type_rename_map)
      }
      @core.Type::Variant(next)
    }
    @core.Type::Named(name~, args~) => {
      let next_args : Array[@core.Type] = []
      for arg in args {
        next_args.push(rename_private_type_refs(arg, type_rename_map))
      }
      @core.Type::Named(
        name=rename_private_type_name(type_rename_map, name),
        args=next_args,
      )
    }
    @core.Type::Func(params~, ret~, effects~) =>
      @core.Type::Func(
        params=rename_private_func_params(params, type_rename_map),
        ret=rename_private_type_refs(ret, type_rename_map),
        effects~,
      )
    _ => ty
  }
}

///|
fn rename_private_func_params(
  params : Array[@core.FuncParam],
  type_rename_map : Map[String, String],
) -> Array[@core.FuncParam] {
  let next : Array[@core.FuncParam] = []
  for param in params {
    next.push(@core.FuncParam::{
      ..param,
      ty: rename_private_type_refs(param.ty, type_rename_map),
    })
  }
  next
}

///|
fn rename_private_type_args(
  type_args : Array[@core.Type],
  type_rename_map : Map[String, String],
) -> Array[@core.Type] {
  let next : Array[@core.Type] = []
  for ty in type_args {
    next.push(rename_private_type_refs(ty, type_rename_map))
  }
  next
}

///|
fn rename_private_type_ctors(
  ctors : Array[@core.TypeCtor],
  type_rename_map : Map[String, String],
  ctor_rename_map : Map[String, String],
) -> Array[@core.TypeCtor] {
  let next : Array[@core.TypeCtor] = []
  for ctor in ctors {
    next.push(@core.TypeCtor::{
      name: match ctor_rename_map.get(ctor.name) {
        Some(mapped) => mapped
        None => ctor.name
      },
      args: rename_private_type_args(ctor.args, type_rename_map),
      span: ctor.span,
    })
  }
  next
}

///|
fn rename_private_struct_fields(
  fields : Array[@core.StructField],
  type_rename_map : Map[String, String],
) -> Array[@core.StructField] {
  let next : Array[@core.StructField] = []
  for field in fields {
    next.push(@core.StructField::{
      ..field,
      ty: rename_private_type_refs(field.ty, type_rename_map),
    })
  }
  next
}

///|
fn rename_private_effect_ops(
  ops : Array[@core.EffectOp],
  type_rename_map : Map[String, String],
) -> Array[@core.EffectOp] {
  let next : Array[@core.EffectOp] = []
  for op in ops {
    next.push(@core.EffectOp::{
      ..op,
      params: rename_private_type_args(op.params, type_rename_map),
      ret: rename_private_type_refs(op.ret, type_rename_map),
    })
  }
  next
}

///|
fn rename_private_trait_method_sigs(
  methods : Array[@core.TraitMethodSig],
  type_rename_map : Map[String, String],
) -> Array[@core.TraitMethodSig] {
  let next : Array[@core.TraitMethodSig] = []
  for sig in methods {
    next.push(@core.TraitMethodSig::{
      ..sig,
      params: rename_private_func_params(sig.params, type_rename_map),
      ret: rename_private_type_refs(sig.ret, type_rename_map),
    })
  }
  next
}

///|
fn rename_private_type_ctor_pat_refs(
  pat : @core.Pat,
  type_rename_map : Map[String, String],
  ctor_rename_map : Map[String, String],
) -> @core.Pat {
  match pat {
    @core.Pat::Ctor(name~, args~, span~) => {
      let next_args : Array[@core.Pat] = []
      for arg in args {
        next_args.push(
          rename_private_type_ctor_pat_refs(
            arg, type_rename_map, ctor_rename_map,
          ),
        )
      }
      @core.Pat::Ctor(
        name=match ctor_rename_map.get(name) {
          Some(mapped) => mapped
          None => name
        },
        args=next_args,
        span~,
      )
    }
    @core.Pat::Tuple(items~, span~) => {
      let next_items : Array[@core.Pat] = []
      for item in items {
        next_items.push(
          rename_private_type_ctor_pat_refs(
            item, type_rename_map, ctor_rename_map,
          ),
        )
      }
      @core.Pat::Tuple(items=next_items, span~)
    }
    @core.Pat::Record(fields~, span~) => {
      let next_fields : Array[@core.RecordFieldPat] = []
      for field in fields {
        next_fields.push(@core.RecordFieldPat::{
          ..field,
          pat: rename_private_type_ctor_pat_refs(
            field.pat,
            type_rename_map,
            ctor_rename_map,
          ),
        })
      }
      @core.Pat::Record(fields=next_fields, span~)
    }
    @core.Pat::Struct(name~, fields~, span~) => {
      let next_fields : Array[@core.RecordFieldPat] = []
      for field in fields {
        next_fields.push(@core.RecordFieldPat::{
          ..field,
          pat: rename_private_type_ctor_pat_refs(
            field.pat,
            type_rename_map,
            ctor_rename_map,
          ),
        })
      }
      @core.Pat::Struct(
        name=rename_private_type_name(type_rename_map, name),
        fields=next_fields,
        span~,
      )
    }
    @core.Pat::Or(pats~, span~) => {
      let next_pats : Array[@core.Pat] = []
      for item in pats {
        next_pats.push(
          rename_private_type_ctor_pat_refs(
            item, type_rename_map, ctor_rename_map,
          ),
        )
      }
      @core.Pat::Or(pats=next_pats, span~)
    }
    _ => pat
  }
}

///|
fn rename_private_type_ctor_call_args(
  args : Array[@core.CallArg],
  scope : RenameScope,
  type_rename_map : Map[String, String],
  ctor_rename_map : Map[String, String],
) -> Array[@core.CallArg] {
  let next : Array[@core.CallArg] = []
  for arg in args {
    next.push(@core.CallArg::{
      ..arg,
      expr: rename_private_type_ctor_expr_refs(
        arg.expr,
        scope,
        type_rename_map,
        ctor_rename_map,
      ),
    })
  }
  next
}

///|
fn rename_private_type_ctor_record_fields(
  fields : Array[@core.RecordFieldExpr],
  scope : RenameScope,
  type_rename_map : Map[String, String],
  ctor_rename_map : Map[String, String],
) -> Array[@core.RecordFieldExpr] {
  let next : Array[@core.RecordFieldExpr] = []
  for field in fields {
    next.push(@core.RecordFieldExpr::{
      ..field,
      expr: rename_private_type_ctor_expr_refs(
        field.expr,
        scope,
        type_rename_map,
        ctor_rename_map,
      ),
    })
  }
  next
}

///|
fn rename_private_type_ctor_map_fields(
  fields : Array[@core.MapFieldExpr],
  scope : RenameScope,
  type_rename_map : Map[String, String],
  ctor_rename_map : Map[String, String],
) -> Array[@core.MapFieldExpr] {
  let next : Array[@core.MapFieldExpr] = []
  for field in fields {
    next.push(@core.MapFieldExpr::{
      ..field,
      expr: rename_private_type_ctor_expr_refs(
        field.expr,
        scope,
        type_rename_map,
        ctor_rename_map,
      ),
    })
  }
  next
}

///|
fn rename_private_type_ctor_match_arms(
  arms : Array[@core.MatchArm],
  scope : RenameScope,
  type_rename_map : Map[String, String],
  ctor_rename_map : Map[String, String],
) -> Array[@core.MatchArm] {
  let next : Array[@core.MatchArm] = []
  for arm in arms {
    let next_pat = rename_private_type_ctor_pat_refs(
      arm.pat,
      type_rename_map,
      ctor_rename_map,
    )
    let arm_scope = scope.child()
    bind_pattern_names_into_scope(arm_scope, next_pat)
    next.push(@core.MatchArm::{
      pat: next_pat,
      cond: match arm.cond {
        Some(expr) =>
          Some(
            rename_private_type_ctor_expr_refs(
              expr, arm_scope, type_rename_map, ctor_rename_map,
            ),
          )
        None => None
      },
      expr: rename_private_type_ctor_expr_refs(
        arm.expr,
        arm_scope,
        type_rename_map,
        ctor_rename_map,
      ),
      span: arm.span,
    })
  }
  next
}

///|
fn rename_private_type_ctor_expr_refs(
  expr : @core.Expr,
  scope : RenameScope,
  type_rename_map : Map[String, String],
  ctor_rename_map : Map[String, String],
) -> @core.Expr {
  match expr {
    @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::Char(..)
    | @core.Expr::String(..)
    | @core.Expr::Placeholder(..) => expr
    @core.Expr::StringInterp(parts~, span~) => {
      let next : Array[@core.StringInterpPart] = []
      for part in parts {
        match part {
          @core.StringInterpPart::Lit(text) =>
            next.push(@core.StringInterpPart::Lit(text))
          @core.StringInterpPart::Expr(inner) =>
            next.push(
              @core.StringInterpPart::Expr(
                rename_private_type_ctor_expr_refs(
                  inner, scope, type_rename_map, ctor_rename_map,
                ),
              ),
            )
        }
      }
      @core.Expr::StringInterp(parts=next, span~)
    }
    @core.Expr::Ident(name~, span~) =>
      @core.Expr::Ident(
        name=rename_private_ctor_lookup_name(scope, ctor_rename_map, name),
        span~,
      )
    @core.Expr::Call(name~, type_args~, args~, span~) =>
      @core.Expr::Call(
        name=rename_private_ctor_lookup_name(scope, ctor_rename_map, name),
        type_args=rename_private_type_args(type_args, type_rename_map),
        args=rename_private_type_ctor_call_args(
          args, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Expr::Tuple(items~, span~) => {
      let next : Array[@core.Expr] = []
      for item in items {
        next.push(
          rename_private_type_ctor_expr_refs(
            item, scope, type_rename_map, ctor_rename_map,
          ),
        )
      }
      @core.Expr::Tuple(items=next, span~)
    }
    @core.Expr::TupleIndex(expr~, index~, span~) =>
      @core.Expr::TupleIndex(
        expr=rename_private_type_ctor_expr_refs(
          expr, scope, type_rename_map, ctor_rename_map,
        ),
        index~,
        span~,
      )
    @core.Expr::Record(fields~, span~) =>
      @core.Expr::Record(
        fields=rename_private_type_ctor_record_fields(
          fields, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Expr::Array(items~, span~) => {
      let next : Array[@core.Expr] = []
      for item in items {
        next.push(
          rename_private_type_ctor_expr_refs(
            item, scope, type_rename_map, ctor_rename_map,
          ),
        )
      }
      @core.Expr::Array(items=next, span~)
    }
    @core.Expr::Map(fields~, span~) =>
      @core.Expr::Map(
        fields=rename_private_type_ctor_map_fields(
          fields, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=rename_private_type_ctor_expr_refs(
          cond, scope, type_rename_map, ctor_rename_map,
        ),
        then_body=rename_private_type_ctor_module_refs(
          then_body, scope, type_rename_map, ctor_rename_map,
        ),
        else_body=rename_private_type_ctor_module_refs(
          else_body, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(
        body=rename_private_type_ctor_module_refs(
          body, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Expr::Match(scrutinee~, arms~, span~) =>
      @core.Expr::Match(
        scrutinee=rename_private_type_ctor_expr_refs(
          scrutinee, scope, type_rename_map, ctor_rename_map,
        ),
        arms=rename_private_type_ctor_match_arms(
          arms, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let body_scope = scope.child()
      body_scope.bindings[value_name] = value_name
      match index_name {
        Some(name) => body_scope.bindings[name] = name
        None => ()
      }
      @core.Expr::ForIn(
        value_name~,
        index_name~,
        iterable=rename_private_type_ctor_expr_refs(
          iterable, scope, type_rename_map, ctor_rename_map,
        ),
        body=rename_private_type_ctor_module_refs(
          body, body_scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    }
    @core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret~,
      effects~,
      body~,
      span~
    ) => {
      let body_scope = scope.child()
      for param in params {
        body_scope.bindings[param.name] = param.name
      }
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params=rename_private_func_params(params, type_rename_map),
        ret=match ret {
          Some(ty) => Some(rename_private_type_refs(ty, type_rename_map))
          None => None
        },
        effects~,
        body=rename_private_type_ctor_module_refs(
          body, body_scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    }
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=rename_private_type_ctor_expr_refs(
          cond, scope, type_rename_map, ctor_rename_map,
        ),
        body=rename_private_type_ctor_module_refs(
          body, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Expr::Loop(params~, body~, span~) => {
      let next_params : Array[@core.LoopParam] = []
      let body_scope = scope.child()
      for param in params {
        next_params.push(@core.LoopParam::{
          name: param.name,
          init: rename_private_type_ctor_expr_refs(
            param.init,
            scope,
            type_rename_map,
            ctor_rename_map,
          ),
          span: param.span,
        })
        body_scope.bindings[param.name] = param.name
      }
      @core.Expr::Loop(
        params=next_params,
        body=rename_private_type_ctor_module_refs(
          body, body_scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    }
    @core.Expr::Break(value~, span~) =>
      @core.Expr::Break(
        value=match value {
          Some(inner) =>
            Some(
              rename_private_type_ctor_expr_refs(
                inner, scope, type_rename_map, ctor_rename_map,
              ),
            )
          None => None
        },
        span~,
      )
    @core.Expr::Continue(args~, span~) => {
      let next : Array[@core.Expr] = []
      for arg in args {
        next.push(
          rename_private_type_ctor_expr_refs(
            arg, scope, type_rename_map, ctor_rename_map,
          ),
        )
      }
      @core.Expr::Continue(args=next, span~)
    }
    @core.Expr::Return(value~, span~) =>
      @core.Expr::Return(
        value=match value {
          Some(inner) =>
            Some(
              rename_private_type_ctor_expr_refs(
                inner, scope, type_rename_map, ctor_rename_map,
              ),
            )
          None => None
        },
        span~,
      )
    @core.Expr::Yield(expr~, span~) =>
      @core.Expr::Yield(
        expr=rename_private_type_ctor_expr_refs(
          expr, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Expr::Handle(body~, arms~, span~) =>
      @core.Expr::Handle(
        body=rename_private_type_ctor_module_refs(
          body, scope, type_rename_map, ctor_rename_map,
        ),
        arms=rename_private_type_ctor_match_arms(
          arms, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Expr::StructLit(name~, type_args~, fields~, span~) =>
      @core.Expr::StructLit(
        name=rename_private_type_name(type_rename_map, name),
        type_args=rename_private_type_args(type_args, type_rename_map),
        fields=rename_private_type_ctor_record_fields(
          fields, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Expr::Spread(expr~, span~) =>
      @core.Expr::Spread(
        expr=rename_private_type_ctor_expr_refs(
          expr, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Expr::Perform(effect_name~, op_name~, args~, span~) =>
      @core.Expr::Perform(
        effect_name~,
        op_name~,
        args=rename_private_type_ctor_call_args(
          args, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
  }
}

///|
fn rename_private_impl_methods(
  methods : Array[@core.ImplMethodDef],
  scope : RenameScope,
  type_rename_map : Map[String, String],
  ctor_rename_map : Map[String, String],
) -> Array[@core.ImplMethodDef] {
  let next : Array[@core.ImplMethodDef] = []
  for impl_method in methods {
    next.push(@core.ImplMethodDef::{
      ..impl_method,
      expr: rename_private_type_ctor_expr_refs(
        impl_method.expr,
        scope,
        type_rename_map,
        ctor_rename_map,
      ),
    })
  }
  next
}

///|
fn rename_private_type_ctor_stmt_refs(
  stmt : @core.Stmt,
  scope : RenameScope,
  type_rename_map : Map[String, String],
  ctor_rename_map : Map[String, String],
) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let expr_scope = if rec {
        let child = scope.child()
        child.bindings[name] = name
        child
      } else {
        scope
      }
      @core.Stmt::Let(
        rec~,
        name~,
        expr=rename_private_type_ctor_expr_refs(
          expr, expr_scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::ExportLet(
        rec~,
        name~,
        expr=rename_private_type_ctor_expr_refs(
          expr, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::InternalExportLet(
        rec~,
        name~,
        expr=rename_private_type_ctor_expr_refs(
          expr, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Stmt::EnumDef(name~, params~, ctors~, span~) =>
      @core.Stmt::EnumDef(
        name=rename_private_type_name(type_rename_map, name),
        params~,
        ctors=rename_private_type_ctors(ctors, type_rename_map, ctor_rename_map),
        span~,
      )
    @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
      @core.Stmt::ExportEnumDef(
        name~,
        params~,
        ctors=rename_private_type_ctors(ctors, type_rename_map, ctor_rename_map),
        span~,
      )
    @core.Stmt::InternalExportEnumDef(name~, params~, ctors~, span~) =>
      @core.Stmt::InternalExportEnumDef(
        name~,
        params~,
        ctors=rename_private_type_ctors(ctors, type_rename_map, ctor_rename_map),
        span~,
      )
    @core.Stmt::TypeAlias(name~, params~, target~, span~) =>
      @core.Stmt::TypeAlias(
        name=rename_private_type_name(type_rename_map, name),
        params~,
        target=rename_private_type_refs(target, type_rename_map),
        span~,
      )
    @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
      @core.Stmt::ExportTypeAlias(
        name~,
        params~,
        target=rename_private_type_refs(target, type_rename_map),
        span~,
      )
    @core.Stmt::InternalExportTypeAlias(name~, params~, target~, span~) =>
      @core.Stmt::InternalExportTypeAlias(
        name~,
        params~,
        target=rename_private_type_refs(target, type_rename_map),
        span~,
      )
    @core.Stmt::TraitDef(
      name~,
      supertraits~,
      methods~,
      open_impl~,
      exported~,
      span~
    ) =>
      @core.Stmt::TraitDef(
        name~,
        supertraits~,
        methods=rename_private_trait_method_sigs(methods, type_rename_map),
        open_impl~,
        exported~,
        span~,
      )
    @core.Stmt::InternalTraitDef(
      name~,
      supertraits~,
      methods~,
      open_impl~,
      span~
    ) =>
      @core.Stmt::InternalTraitDef(
        name~,
        supertraits~,
        methods=rename_private_trait_method_sigs(methods, type_rename_map),
        open_impl~,
        span~,
      )
    @core.Stmt::TraitImpl(
      type_params~,
      type_bounds~,
      trait_name~,
      target~,
      methods~,
      span~
    ) =>
      @core.Stmt::TraitImpl(
        type_params~,
        type_bounds~,
        trait_name~,
        target=rename_private_type_refs(target, type_rename_map),
        methods=rename_private_impl_methods(
          methods, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(
        expr=rename_private_type_ctor_expr_refs(
          expr, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Stmt::Test(name~, body~, span~) =>
      @core.Stmt::Test(
        name~,
        body=rename_private_type_ctor_module_refs(
          body, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Stmt::Bench(name~, body~, span~) =>
      @core.Stmt::Bench(
        name~,
        body=rename_private_type_ctor_module_refs(
          body, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Stmt::LetMut(name~, expr~, span~) =>
      @core.Stmt::LetMut(
        name~,
        expr=rename_private_type_ctor_expr_refs(
          expr, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Stmt::ExternLet(name~, ty~, span~) =>
      @core.Stmt::ExternLet(
        name~,
        ty=rename_private_type_refs(ty, type_rename_map),
        span~,
      )
    @core.Stmt::Assign(name~, expr~, span~) =>
      @core.Stmt::Assign(
        name~,
        expr=rename_private_type_ctor_expr_refs(
          expr, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Stmt::IndexAssign(target~, index~, value~, span~) =>
      @core.Stmt::IndexAssign(
        target=rename_private_type_ctor_expr_refs(
          target, scope, type_rename_map, ctor_rename_map,
        ),
        index=rename_private_type_ctor_expr_refs(
          index, scope, type_rename_map, ctor_rename_map,
        ),
        value=rename_private_type_ctor_expr_refs(
          value, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Stmt::LetPat(pat~, expr~, span~) =>
      @core.Stmt::LetPat(
        pat=rename_private_type_ctor_pat_refs(
          pat, type_rename_map, ctor_rename_map,
        ),
        expr=rename_private_type_ctor_expr_refs(
          expr, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) =>
      @core.Stmt::LetPatElse(
        pat=rename_private_type_ctor_pat_refs(
          pat, type_rename_map, ctor_rename_map,
        ),
        expr=rename_private_type_ctor_expr_refs(
          expr, scope, type_rename_map, ctor_rename_map,
        ),
        else_body=rename_private_type_ctor_module_refs(
          else_body, scope, type_rename_map, ctor_rename_map,
        ),
        span~,
      )
    @core.Stmt::StructDef(name~, params~, fields~, span~) =>
      @core.Stmt::StructDef(
        name=rename_private_type_name(type_rename_map, name),
        params~,
        fields=rename_private_struct_fields(fields, type_rename_map),
        span~,
      )
    @core.Stmt::ExportStructDef(name~, params~, fields~, span~) =>
      @core.Stmt::ExportStructDef(
        name~,
        params~,
        fields=rename_private_struct_fields(fields, type_rename_map),
        span~,
      )
    @core.Stmt::InternalExportStructDef(name~, params~, fields~, span~) =>
      @core.Stmt::InternalExportStructDef(
        name~,
        params~,
        fields=rename_private_struct_fields(fields, type_rename_map),
        span~,
      )
    @core.Stmt::EffectDef(name~, params~, ops~, import_path~, span~) =>
      @core.Stmt::EffectDef(
        name~,
        params~,
        ops=rename_private_effect_ops(ops, type_rename_map),
        import_path~,
        span~,
      )
    @core.Stmt::ExportEffectDef(name~, params~, ops~, import_path~, span~) =>
      @core.Stmt::ExportEffectDef(
        name~,
        params~,
        ops=rename_private_effect_ops(ops, type_rename_map),
        import_path~,
        span~,
      )
    _ => stmt
  }
}

///|
fn extend_type_ctor_scope_with_stmt_bindings(
  scope : RenameScope,
  stmt : @core.Stmt,
) -> Unit {
  match stmt {
    @core.Stmt::Let(name~, ..)
    | @core.Stmt::LetMut(name~, ..)
    | @core.Stmt::ExternLet(name~, ..)
    | @core.Stmt::ExportLet(name~, ..)
    | @core.Stmt::InternalExportLet(name~, ..) => scope.bindings[name] = name
    @core.Stmt::LetPat(pat~, ..) | @core.Stmt::LetPatElse(pat~, ..) =>
      bind_pattern_names_into_scope(scope, pat)
    _ => ()
  }
}

///|
fn rename_private_type_ctor_module_refs(
  mod_ : @core.Module,
  parent_scope : RenameScope,
  type_rename_map : Map[String, String],
  ctor_rename_map : Map[String, String],
) -> @core.Module {
  let scope = parent_scope.child()
  let next_stmts : Array[@core.Stmt] = []
  for stmt in mod_.stmts {
    let next = rename_private_type_ctor_stmt_refs(
      stmt, scope, type_rename_map, ctor_rename_map,
    )
    next_stmts.push(next)
    extend_type_ctor_scope_with_stmt_bindings(scope, next)
  }
  { stmts: next_stmts }
}

///|
fn collect_private_type_rename_map_for_existing_names(
  path : String,
  ast : @core.Module,
  existing_type_names : Map[String, Bool],
) -> Map[String, String] {
  let exported = collect_exported_value_names(ast)
  let rename_map : Map[String, String] = {}
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::EnumDef(name~, ..)
      | @core.Stmt::TypeAlias(name~, ..)
      | @core.Stmt::StructDef(name~, ..) =>
        if !exported.contains(name) && existing_type_names.contains(name) {
          rename_map[name] = prefixed_private_value_name(path, name)
        }
      _ => ()
    }
  }
  rename_map
}

///|
fn collect_private_ctor_rename_map(
  path : String,
  ast : @core.Module,
  type_rename_map : Map[String, String],
  existing_value_names : Map[String, Bool],
) -> Map[String, String] {
  let exported = collect_exported_value_names(ast)
  let rename_map : Map[String, String] = {}
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::EnumDef(name~, ctors~, ..) =>
        if !exported.contains(name) {
          let next_type_name = rename_private_type_name(type_rename_map, name)
          let rename_all_ctors = type_rename_map.contains(name)
          for ctor in ctors {
            if rename_all_ctors || existing_value_names.contains(ctor.name) {
              let next_ctor_name = prefixed_private_value_name(path, ctor.name)
              rename_map[ctor.name] = next_ctor_name
              rename_map[name + "::" + ctor.name] = next_type_name +
                "::" +
                next_ctor_name
            }
          }
        }
      @core.Stmt::ExportEnumDef(name~, ctors~, ..)
      | @core.Stmt::InternalExportEnumDef(name~, ctors~, ..) =>
        match type_rename_map.get(name) {
          Some(next_type_name) =>
            for ctor in ctors {
              let next_ctor_name = prefixed_private_value_name(path, ctor.name)
              rename_map[ctor.name] = next_ctor_name
              rename_map[name + "::" + ctor.name] = next_type_name +
                "::" +
                next_ctor_name
            }
          None => ()
        }
      _ => ()
    }
  }
  rename_map
}

///|
fn namespace_private_module_defs_for_existing_names(
  path : String,
  ast : @core.Module,
  existing_value_names : Map[String, Bool],
  existing_type_names : Map[String, Bool],
) -> @core.Module {
  let value_renamed = namespace_private_module_values_for_existing_names(
    path, ast, existing_value_names,
  )
  let type_rename_map = collect_private_type_rename_map_for_existing_names(
    path, value_renamed, existing_type_names,
  )
  let ctor_rename_map = collect_private_ctor_rename_map(
    path, value_renamed, type_rename_map, existing_value_names,
  )
  if type_rename_map.length() == 0 && ctor_rename_map.length() == 0 {
    value_renamed
  } else {
    rename_private_type_ctor_module_refs(
      value_renamed,
      RenameScope::new(),
      type_rename_map,
      ctor_rename_map,
    )
  }
}

///|
fn elapsed_us_from(start : @bench.Timestamp) -> Int {
  @bench.monotonic_clock_end(start).to_int()
}

///|
fn compile_module_cache_key(
  path : String,
  source : String,
  imports : Array[@runtime.ImportSpec],
) -> String {
  let buf = StringBuilder::new()
  buf.write_string(path)
  buf.write_char('\n')
  buf.write_string(@core.git_blob_hash_string(source))
  for imp in imports {
    buf.write_char('\n')
    buf.write_string(imp.path)
    buf.write_char('|')
    match imp.hash {
      Some(hash) => buf.write_string(hash)
      None => buf.write_char('-')
    }
    buf.write_char('|')
    match imp.source_hash {
      Some(source_hash) => buf.write_string(source_hash)
      None => buf.write_char('-')
    }
  }
  @core.git_blob_hash_string(buf.to_string())
}

///|
fn wasm_artifact_cache_key(
  bundled : @core.Module,
  import_aliases : Map[String, @core.Ref],
  cache_namespace : String,
  opt_level : String?,
) -> String {
  let buf = StringBuilder::new()
  buf.write_string(cache_namespace)
  buf.write_char('\n')
  match opt_level {
    Some(level) => buf.write_string(level)
    None => buf.write_string("none")
  }
  buf.write_char('\n')
  buf.write_string(
    module_to_sexp(bundled, build_alias_map(bundled, import_aliases)),
  )
  @core.git_blob_hash_string(buf.to_string())
}

///|
fn wasm_artifact_cache_namespace(
  bundler_kind : String,
  debug_errors : Bool,
  http_host_imports : Bool,
  fs_host_imports : Bool,
  force_cabi_realloc : Bool,
  library_mode : Bool,
) -> String {
  let buf = StringBuilder::new()
  buf.write_string(bundler_kind)
  buf.write_char('\n')
  buf.write_string(debug_errors.to_string())
  buf.write_char('\n')
  buf.write_string(http_host_imports.to_string())
  buf.write_char('\n')
  buf.write_string(fs_host_imports.to_string())
  buf.write_char('\n')
  buf.write_string(force_cabi_realloc.to_string())
  buf.write_char('\n')
  buf.write_string(library_mode.to_string())
  buf.to_string()
}

///|
fn compile_module_import_aliases(
  imports : Array[@runtime.ImportSpec],
) -> Map[String, @core.Ref] {
  let aliases : Map[String, @core.Ref] = {}
  for imp in imports {
    match imp.module_ref {
      Some(m) =>
        aliases[imp.alias_name] = @core.Ref::{ name: m, hash_prefix: None }
      None => ()
    }
  }
  aliases
}

///|
/// Collect specializable function defs from imported modules so cross-module
/// calls (e.g. `Iterator::fold(xs : UserType, ...)`) can be specialized for
/// the receiver's concrete root at the user-file's monoify pass. See #330.
///
/// Uses `db.ast` (raw, parsed-and-desugared) rather than `compile_module`
/// to avoid the per-import typecheck/monoify/hash work — the imported fn
/// bodies are read as templates, not executed, so the parsed form is enough
/// and the perf gate doesn't blow up on selfhost.
fn collect_import_specializable_defs(
  db : @runtime.VibeDb,
  imports : Array[@runtime.ImportSpec],
) -> Map[String, @core.Expr] {
  let out : Map[String, @core.Expr] = {}
  for imp in imports {
    let imp_ast = db.ast(imp.path)
    for stmt in imp_ast.stmts {
      let (name, expr) = match stmt {
        @core.Stmt::Let(name~, expr~, ..)
        | @core.Stmt::ExportLet(name~, expr~, ..)
        | @core.Stmt::InternalExportLet(name~, expr~, ..) => (name, expr)
        _ => continue
      }
      // First import wins on collision; the user file's own defs override
      // both later inside monoify_module itself.
      if out.contains(name) {
        continue
      }
      match expr {
        @core.Expr::Fn(type_params~, params~, ret~, body~, ..) =>
          if @frontend.fn_is_monoify_specializable(
              type_params, params, ret, body,
            ) {
            out[name] = expr
          }
        _ => ()
      }
    }
  }
  out
}

///|
fn wasm_coverage_kind_from_codegen(
  kind : @codegen.WasmCoveragePointKind,
) -> WasmCoveragePointKind {
  match kind {
    @codegen.WasmCoveragePointKind::Line => WasmCoveragePointKind::Line
    @codegen.WasmCoveragePointKind::BranchIfThen =>
      WasmCoveragePointKind::BranchIfThen
    @codegen.WasmCoveragePointKind::BranchIfElse =>
      WasmCoveragePointKind::BranchIfElse
    @codegen.WasmCoveragePointKind::BranchMatchArm =>
      WasmCoveragePointKind::BranchMatchArm
  }
}

///|
fn wasm_coverage_artifact_from_codegen(
  artifact : @codegen.WasmCoverageArtifact,
) -> WasmCoverageArtifact {
  let points : Array[WasmCoveragePoint] = []
  for point in artifact.points {
    points.push({
      id: point.id,
      kind: wasm_coverage_kind_from_codegen(point.kind),
      span: point.span,
    })
  }
  {
    bytes: artifact.bytes,
    counter_base: artifact.counter_base,
    counter_count: artifact.counter_count,
    points,
  }
}

///|
/// Compile a module from the database (WASM target: wasm-gc + js builtin).
pub fn compile_module(
  db : @runtime.VibeDb,
  path : String,
) -> CompiledModule raise CompileError {
  ensure_hooks()
  let source = match db.get_source(path) {
    Some(s) => s
    None => raise CompileError::MissingSource(path)
  }
  let imports = db.imports(path)
  let cache_key = compile_module_cache_key(path, source, imports)
  match compile_module_cache.val.get(cache_key) {
    Some(cached) => return cached
    None => ()
  }
  // Trigger parse/import/type queries once and reuse their cached results below.
  let env = db.types(path)
  let diags = db.diagnostics(path)
  for diag in diags {
    if diag.stage == "parse" {
      // Preserve CompileError::Parse API without reparsing on the success path.
      let _ = @parser.parse_ast(source) catch {
        e => raise CompileError::Parse(e)
      }
      raise CompileError::TypeDiag(diag)
    }
    if diag.stage == "type" || diag.stage == "import" {
      raise CompileError::TypeDiag(diag)
    }
  }
  let raw_ast = db.ast(path)
  let aliases = build_alias_map(raw_ast, compile_module_import_aliases(imports))
  let desugared = @frontend.desugar_method_calls(raw_ast, aliases)
  let ast = @frontend.rewrite_effect_handles(desugared)
  let expr_type_index = env.expr_type_index()
  // Gather specializable defs from imports so cross-module calls get
  // specialized for the receiver's concrete root. See #330: without this,
  // `Iterator::fold(xs : Trio[Int], ...)` would dispatch through the
  // prelude Array fallback at codegen because the user file's monoify
  // doesn't see fold's body.
  let imported_specializable = collect_import_specializable_defs(db, imports)
  let mono = @frontend.monoify_module(
    ast,
    expr_type_index,
    additional_specializable=imported_specializable,
  )
  @core.clear_string_for_in_spans()
  let rewritten = @frontend.rewrite_string_add(mono.ast, expr_type_index)
  let resolved_ast = db.rewrite_imports_to_hash(path, rewritten)
  let ir = module_to_sexp(resolved_ast, aliases)
  let ir_hash = @core.git_blob_hash_string(ir)
  let module_ref = @core.module_ref_from_hash(ir_hash)
  let module_refs : Array[String] = []
  for imp in imports {
    match imp.module_ref {
      Some(r) => module_refs.push(r)
      None => ()
    }
  }
  let compiled = {
    path,
    ir,
    ir_hash,
    module_ref,
    imports: module_refs,
    aliases,
    ast: resolved_ast,
    expr_type_index,
    type_env: env,
    instantiations: mono.instantiations,
  }
  compile_module_cache.val[cache_key] = compiled
  compiled
}

///|
fn dedupe_bundled_value_defs(ast : @core.Module) -> @core.Module {
  // Last-wins deduplication: when duplicate value names exist in a bundle
  // (e.g. __to_string from multiple polyfill modules), keep the last
  // definition so that module-local references resolve to their own version.
  let last_index : Map[String, Int] = {}
  for idx = 0; idx < ast.stmts.length(); idx = idx + 1 {
    let name : String? = match ast.stmts[idx] {
      @core.Stmt::Let(name~, ..)
      | @core.Stmt::ExportLet(name~, ..)
      | @core.Stmt::InternalExportLet(name~, ..)
      | @core.Stmt::LetMut(name~, ..)
      | @core.Stmt::ExternLet(name~, ..) => Some(name)
      _ => None
    }
    match name {
      Some(n) => last_index[n] = idx
      None => ()
    }
  }
  let out : Array[@core.Stmt] = []
  let seen : Map[String, Bool] = {}
  for idx = 0; idx < ast.stmts.length(); idx = idx + 1 {
    let stmt = ast.stmts[idx]
    let name : String? = match stmt {
      @core.Stmt::Let(name~, ..)
      | @core.Stmt::ExportLet(name~, ..)
      | @core.Stmt::InternalExportLet(name~, ..)
      | @core.Stmt::LetMut(name~, ..)
      | @core.Stmt::ExternLet(name~, ..) => Some(name)
      _ => None
    }
    match name {
      Some(n) =>
        if seen.contains(n) {
          continue
        } else if last_index.get(n) == Some(idx) {
          seen[n] = true
          out.push(stmt)
        } else {
          continue
        }
      None => out.push(stmt)
    }
  }
  { stmts: out }
}

///|
fn prepare_bundled_ast_for_codegen(
  bundled : @core.Module,
) -> @core.Module raise CompileError {
  let aliases : Map[String, @core.Ref] = {}
  let desugared = @frontend.desugar_method_calls(bundled, aliases)
  let ast = @frontend.rewrite_effect_handles(desugared)
  let env : Result[@checker.TypeEnv, @checker.TypeError] = try? @checker.type_check(
    ast,
    allow_duplicate_decl=true,
  )
  let typed_env = match env {
    Ok(value) => value
    Err(err) => raise CompileError::TypeDiag(err.diagnostic())
  }
  let expr_type_index = typed_env.expr_type_index()
  let mono = @frontend.monoify_module(ast, expr_type_index)
  @core.clear_string_for_in_spans()
  @frontend.rewrite_string_add(mono.ast, expr_type_index)
}

///|
fn bundle_for_codegen(
  db : @runtime.VibeDb,
  path : String,
  ast : @core.Module,
  bundle_kind : String,
) -> @core.Module raise CompileError {
  let raw = bundle_for_wasm_no_dce(db, path, ast)
  match bundle_kind {
    "default" => @pipeline.dce_module(raw)
    "gc" => @pipeline.dce_module_gc(raw)
    "tests" => @pipeline.dce_module_for_tests(raw)
    _ => raw
  }
}

///|
/// Internal helper for compile_module_wasm_* functions
fn compile_module_wasm_with(
  db : @runtime.VibeDb,
  path : String,
  bundle_kind : String,
  emitter : (@core.Module) -> Bytes raise @codegen.WasmGenError,
) -> Bytes raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let bundled = bundle_for_codegen(db, path, compiled.ast, bundle_kind) catch {
    e => raise WasmCompileError::Compile(e)
  }
  emitter(bundled) catch {
    e => raise WasmCompileError::Gen(e)
  }
}

///|
fn wasm_emit_options(
  debug_errors : Bool,
  http_host_imports? : Bool = false,
  http_component_wasi_shim? : Bool = false,
  fs_host_imports? : Bool = false,
) -> @codegen.WasmEmitOptions {
  @codegen.wasm_emit_options(
    embed_error_strings=debug_errors,
    http_host_imports~,
    http_component_wasi_shim~,
    fs_host_imports~,
  )
}

///|
/// Convert PerceusAction array to the (site, is_dup, name) tuples expected by codegen.
fn perceus_actions_to_tuples(
  actions : Array[@frontend.PerceusAction],
) -> Array[(String, Bool, String)] {
  let result : Array[(String, Bool, String)] = []
  for action in actions {
    let is_dup = match action.kind {
      Dup => true
      Drop => false
    }
    result.push((action.site, is_dup, action.name))
  }
  result
}

///|
/// Extract named function bodies from a module for per-function analysis.
/// Returns (func_name, body_module) pairs.
fn extract_func_bodies(ast : @core.Module) -> Array[(String, @core.Module)] {
  let result : Array[(String, @core.Module)] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..)
      | @core.Stmt::ExportLet(name~, expr~, ..)
      | @core.Stmt::InternalExportLet(name~, expr~, ..) =>
        match expr {
          @core.Expr::Fn(body~, ..) => result.push((name, body))
          _ => ()
        }
      _ => ()
    }
  }
  result
}

///|
/// Build a "run AST" from the module — top-level stmts minus function defs.
/// This approximates what the codegen's run_ast contains.
fn extract_run_stmts(ast : @core.Module) -> @core.Module {
  let stmts : Array[@core.Stmt] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(expr~, ..)
      | @core.Stmt::ExportLet(expr~, ..)
      | @core.Stmt::InternalExportLet(expr~, ..) =>
        match expr {
          @core.Expr::Fn(..) => () // skip function defs
          _ => stmts.push(stmt)
        }
      _ => stmts.push(stmt)
    }
  }
  @core.Module::{ stmts, }
}

///|
/// Run Perceus analysis on an AST and return RC-enabled emit options.
/// Analyzes both top-level statements and each named function body.
fn wasm_emit_options_with_rc(
  ast : @core.Module,
  debug_errors? : Bool = false,
  http_host_imports? : Bool = false,
  http_component_wasi_shim? : Bool = false,
  fs_host_imports? : Bool = false,
  rc_debug? : Bool = false,
) -> (@codegen.WasmEmitOptions, @core.Module) {
  // Desugar StringInterp into let-binding chains before Perceus analysis
  // so that intermediate String::concat results are RC-tracked.
  let desugared_ast = @frontend.desugar_string_interp(ast)
  // Analyze top-level (non-function) statements
  let run_ast = extract_run_stmts(desugared_ast)
  let top_plan = @frontend.build_perceus_plan(run_ast)
  let rc_actions = perceus_actions_to_tuples(top_plan)
  // Analyze each named function body
  let rc_func_actions : Map[String, Array[(String, Bool, String)]] = {}
  let func_bodies = extract_func_bodies(desugared_ast)
  for pair in func_bodies {
    let (name, body) = pair
    let plan = @frontend.build_perceus_plan(body)
    if plan.length() > 0 {
      rc_func_actions[name] = perceus_actions_to_tuples(plan)
    }
  }
  // Store top-level actions also under "_start" for the codegen to restore
  if rc_actions.length() > 0 {
    rc_func_actions["_start"] = rc_actions
  }
  (
    @codegen.wasm_emit_options(
      embed_error_strings=debug_errors,
      http_host_imports~,
      http_component_wasi_shim~,
      fs_host_imports~,
      enable_rc=true,
      rc_debug~,
      rc_actions~,
      rc_func_actions~,
    ),
    desugared_ast,
  )
}

///|
fn compile_module_wasm_coverage_with(
  db : @runtime.VibeDb,
  path : String,
  bundle_kind : String,
  emitter : (@core.Module) -> @codegen.WasmCoverageArtifact raise @codegen.WasmGenError,
  run_tests? : Bool = false,
) -> WasmCoverageArtifact raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let bundled = bundle_for_codegen(db, path, compiled.ast, bundle_kind) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let lowered = if run_tests {
    lower_top_level_tests_to_exprs(bundled)
  } else {
    bundled
  }
  let coverage = emitter(lowered) catch { e => raise WasmCompileError::Gen(e) }
  wasm_coverage_artifact_from_codegen(coverage)
}

///|
fn lower_top_level_tests_to_exprs(ast : @core.Module) -> @core.Module {
  let stmts : Array[@core.Stmt] = []
  let mut test_i = 0
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Test(body~, span~, ..)
      | @core.Stmt::Bench(body~, span~, ..) => {
        let wrapper_name = "__vibe_cov_test_" + test_i.to_string()
        let fn_body_stmts : Array[@core.Stmt] = []
        for body_stmt in body.stmts {
          fn_body_stmts.push(body_stmt)
        }
        fn_body_stmts.push(
          @core.Stmt::Expr(expr=@core.Expr::Int(value=0L, span~), span~),
        )
        stmts.push(
          @core.Stmt::Let(
            rec=false,
            name=wrapper_name,
            expr=@core.Expr::Fn(
              type_params=[],
              type_bounds={},
              params=[],
              ret=Some(@core.Type::Int),
              effects=[],
              body=@core.Module::{ stmts: fn_body_stmts },
              span~,
            ),
            span~,
          ),
        )
        stmts.push(
          @core.Stmt::Expr(
            expr=@core.Expr::Call(
              name=wrapper_name,
              type_args=[],
              args=[],
              span~,
            ),
            span~,
          ),
        )
        test_i += 1
      }
      _ => stmts.push(stmt)
    }
  }
  @core.Module::{ stmts, }
}

///|
fn optimize_wasm_bytes_with_opt_level(
  bytes : Bytes,
  opt_level : String?,
) -> Bytes raise WasmCompileError {
  match opt_level {
    None => bytes
    Some(level) => {
      let config = match @wite.optimize_config_from_opt_level(level) {
        Some(v) => v
        None =>
          raise WasmCompileError::Optimize(
            "unsupported wite optimize level " +
            level +
            " (expected: -O0|-O1|-O2|-O3|-O4|-Os|-Oz)",
          )
      }
      match @wite.optimize_binary_for_size(bytes, config~) {
        Ok(result) => result.bytes
        Err(msg) =>
          raise WasmCompileError::Optimize("wite optimize failed: " + msg)
      }
    }
  }
}

///|
fn optimize_wasm_coverage_with_opt_level(
  coverage : WasmCoverageArtifact,
  opt_level : String?,
) -> WasmCoverageArtifact raise WasmCompileError {
  let optimized = optimize_wasm_bytes_with_opt_level(coverage.bytes, opt_level)
  {
    bytes: optimized,
    counter_base: coverage.counter_base,
    counter_count: coverage.counter_count,
    points: coverage.points,
  }
}

///|
fn compile_module_wasm_profiled_with(
  db : @runtime.VibeDb,
  path : String,
  bundle_kind : String,
  emitter : (@core.Module) -> Bytes raise @codegen.WasmGenError,
  cache_namespace : String,
  opt_level : String?,
) -> (Bytes, WasmCompileStageProfile) raise WasmCompileError {
  let start_total = @bench.monotonic_clock_start()
  @profiler.profiler_enter("compile/module")
  let start_module = @bench.monotonic_clock_start()
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let module_us = elapsed_us_from(start_module)
  @profiler.profiler_leave()
  @profiler.profiler_enter("compile/bundle")
  let start_bundle = @bench.monotonic_clock_start()
  let bundled = bundle_for_codegen(db, path, compiled.ast, bundle_kind) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let cache_key = wasm_artifact_cache_key(
    bundled,
    compiled.aliases,
    cache_namespace,
    opt_level,
  )
  let bundle_us = elapsed_us_from(start_bundle)
  @profiler.profiler_leave()
  match wasm_artifact_cache.val.get(cache_key) {
    Some(cached) => {
      let total_us = elapsed_us_from(start_total)
      return (
        cached,
        { module_us, bundle_us, emit_us: 0, optimize_us: 0, total_us },
      )
    }
    None => ()
  }
  @profiler.profiler_enter("compile/emit")
  let start_emit = @bench.monotonic_clock_start()
  let wasm = emitter(bundled) catch { e => raise WasmCompileError::Gen(e) }
  let emit_us = elapsed_us_from(start_emit)
  @profiler.profiler_leave()
  @profiler.profiler_enter("compile/optimize")
  let start_optimize = @bench.monotonic_clock_start()
  let optimized = optimize_wasm_bytes_with_opt_level(wasm, opt_level)
  let optimize_us = elapsed_us_from(start_optimize)
  @profiler.profiler_leave()
  wasm_artifact_cache.val[cache_key] = optimized
  let total_us = elapsed_us_from(start_total)
  (optimized, { module_us, bundle_us, emit_us, optimize_us, total_us })
}

///|
/// Compile a module to WASM (wasm-gc compatible, minimal MVP).
pub fn compile_module_wasm(
  db : @runtime.VibeDb,
  path : String,
  debug_errors? : Bool = false,
  http_host_imports? : Bool = false,
  force_cabi_realloc? : Bool = false,
  enable_rc? : Bool = false,
  rc_debug? : Bool = false,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(db, path, "default", ast => {
    if enable_rc {
      let (options, desugared_ast) = wasm_emit_options_with_rc(
        ast,
        debug_errors~,
        http_host_imports~,
        rc_debug~,
      )
      @codegen.emit_module_wasm_with_options(desugared_ast, options)
    } else {
      let options = @codegen.wasm_emit_options(
        embed_error_strings=debug_errors,
        http_host_imports~,
        force_cabi_realloc~,
      )
      @codegen.emit_module_wasm_with_options(ast, options)
    }
  })
}

///|
pub fn compile_module_wasm_with_codegen_options(
  db : @runtime.VibeDb,
  path : String,
  options : @codegen.WasmEmitOptions,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(db, path, "default", ast => {
    @codegen.emit_module_wasm_with_options(ast, options)
  })
}

///|
pub fn compile_module_wasm_with_opt_level(
  db : @runtime.VibeDb,
  path : String,
  no_dce? : Bool = false,
  opt_level? : String? = None,
  debug_errors? : Bool = false,
  http_host_imports? : Bool = false,
  fs_host_imports? : Bool = false,
  force_cabi_realloc? : Bool = false,
  library_mode? : Bool = false,
) -> Bytes raise WasmCompileError {
  let (wasm, _) = compile_module_wasm_with_opt_level_profiled(
    db,
    path,
    no_dce~,
    opt_level~,
    debug_errors~,
    http_host_imports~,
    fs_host_imports~,
    force_cabi_realloc~,
    library_mode~,
  )
  wasm
}

///|
pub fn compile_module_wasm_with_opt_level_profiled(
  db : @runtime.VibeDb,
  path : String,
  no_dce? : Bool = false,
  opt_level? : String? = None,
  debug_errors? : Bool = false,
  http_host_imports? : Bool = false,
  fs_host_imports? : Bool = false,
  force_cabi_realloc? : Bool = false,
  library_mode? : Bool = false,
) -> (Bytes, WasmCompileStageProfile) raise WasmCompileError {
  ensure_hooks()
  let cache_namespace = wasm_artifact_cache_namespace(
    if no_dce {
      "no_dce"
    } else {
      "default"
    },
    debug_errors,
    http_host_imports,
    fs_host_imports,
    force_cabi_realloc,
    library_mode,
  )
  if no_dce {
    compile_module_wasm_profiled_with(
      db,
      path,
      "no_dce",
      ast => {
        @codegen.emit_module_wasm_with_options(
          ast,
          @codegen.wasm_emit_options(
            embed_error_strings=debug_errors,
            http_host_imports~,
            fs_host_imports~,
            force_cabi_realloc~,
            library_mode~,
          ),
        )
      },
      cache_namespace,
      opt_level,
    )
  } else {
    compile_module_wasm_profiled_with(
      db,
      path,
      "default",
      ast => {
        @codegen.emit_module_wasm_with_options(
          ast,
          @codegen.wasm_emit_options(
            embed_error_strings=debug_errors,
            http_host_imports~,
            fs_host_imports~,
            force_cabi_realloc~,
            library_mode~,
          ),
        )
      },
      cache_namespace,
      opt_level,
    )
  }
}

///|
pub fn compile_module_wasm_with_coverage(
  db : @runtime.VibeDb,
  path : String,
  no_dce? : Bool = false,
  opt_level? : String? = None,
  run_tests? : Bool = false,
  debug_errors? : Bool = false,
  http_host_imports? : Bool = false,
) -> WasmCoverageArtifact raise WasmCompileError {
  let coverage = if no_dce {
    compile_module_wasm_no_dce_with_coverage(
      db,
      path,
      run_tests~,
      debug_errors~,
      http_host_imports~,
    )
  } else if run_tests {
    compile_module_wasm_coverage_with(
      db,
      path,
      "tests",
      ast => {
        @codegen.emit_module_wasm_with_coverage_options(
          ast,
          wasm_emit_options(debug_errors, http_host_imports~),
        )
      },
      run_tests=true,
    )
  } else {
    compile_module_wasm_coverage_with(db, path, "default", ast => {
      @codegen.emit_module_wasm_with_coverage_options(
        ast,
        wasm_emit_options(debug_errors, http_host_imports~),
      )
    })
  }
  optimize_wasm_coverage_with_opt_level(coverage, opt_level)
}

///|
fn compile_module_wasm_no_dce_with_coverage(
  db : @runtime.VibeDb,
  path : String,
  run_tests? : Bool = false,
  debug_errors? : Bool = false,
  http_host_imports? : Bool = false,
) -> WasmCoverageArtifact raise WasmCompileError {
  compile_module_wasm_coverage_with(
    db,
    path,
    "no_dce",
    ast => {
      @codegen.emit_module_wasm_with_coverage_options(
        ast,
        wasm_emit_options(debug_errors, http_host_imports~),
      )
    },
    run_tests~,
  )
}

///|
/// Compile a module to WASM using wasm js-string builtins.
pub fn compile_module_wasm_js_string(
  db : @runtime.VibeDb,
  path : String,
  debug_errors? : Bool = false,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(db, path, "default", ast => {
    @codegen.emit_module_wasm_js_string_with_options(
      ast,
      wasm_emit_options(debug_errors),
    )
  })
}

///|
/// Compile a module to WASM using wasm-gc opcodes (fixture-focused).
pub fn compile_module_wasm_gc(
  db : @runtime.VibeDb,
  path : String,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(db, path, "gc", @codegen.emit_module_wasm_gc)
}

///|
/// Issue #417: wasm-gc coverage entry. Same shape as
/// `compile_module_wasm_with_coverage` for the linear backend so the
/// CLI dispatch in `cli_compile_cmd.mbt` is symmetric.
pub fn compile_module_wasm_gc_with_coverage(
  db : @runtime.VibeDb,
  path : String,
  no_dce? : Bool = false,
  opt_level? : String? = None,
  run_tests? : Bool = false,
) -> WasmCoverageArtifact raise WasmCompileError {
  let _ = no_dce // wasm-gc backend currently always inlines; no DCE toggle yet
  let coverage = compile_module_wasm_coverage_with(
    db, path, "gc_coverage", @codegen.emit_module_wasm_gc_with_coverage, run_tests~,
  )
  optimize_wasm_coverage_with_opt_level(coverage, opt_level)
}

///|
/// Compile a module to WASM without DCE (for benchmarking).
pub fn compile_module_wasm_no_dce(
  db : @runtime.VibeDb,
  path : String,
  debug_errors? : Bool = false,
  http_host_imports? : Bool = false,
  force_cabi_realloc? : Bool = false,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(db, path, "no_dce", ast => {
    @codegen.emit_module_wasm_with_options(
      ast,
      @codegen.wasm_emit_options(
        embed_error_strings=debug_errors,
        http_host_imports~,
        force_cabi_realloc~,
      ),
    )
  })
}

///|
/// Compile a module to Component Model WASM (for wkg/wa.dev compatibility).
/// Uses Canon lift to properly expose the run function as a component export.
pub fn compile_module_component(
  db : @runtime.VibeDb,
  path : String,
  http_host_imports? : Bool = false,
) -> Bytes raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let bundled = bundle_for_wasm(db, path, compiled.ast)
  let core_wasm = @codegen.emit_module_wasm_with_options(
    bundled,
    wasm_emit_options(
      false,
      http_host_imports~,
      http_component_wasi_shim=http_host_imports,
    ),
  ) catch {
    e => raise WasmCompileError::Gen(e)
  }
  @codegen.emit_component_wasm_with_lift(core_wasm, "run")
}

///|
/// Auto-detect exported function with string params and compile to Component
/// with string lift trampoline. Scans AST for the first ExportLet with Fn
/// whose params include Type::String.
pub fn compile_module_component_string_lift_auto(
  db : @runtime.VibeDb,
  path : String,
  opt_level? : String? = None,
  is_async? : Bool = false,
) -> Bytes raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  // Check for incompatible server builtins (listen/accept model is not supported in P3 handler mode)
  let incompatible = check_incompatible_server_builtins(compiled.ast)
  if incompatible.length() > 0 {
    raise WasmCompileError::Optimize(
      "P3 handler mode is incompatible with server builtins: " +
      incompatible
      .iter()
      .fold(init="", fn(acc, s) { if acc == "" { s } else { acc + ", " + s } }) +
      ". Use `export let handler = (method: String, url: String) -> Int` pattern instead.",
    )
  }
  // Find first exported function with string params
  let mut target_func_name : String? = None
  let mut string_param_count = 0
  let string_param_names : Array[String] = []
  let mut string_result = false
  for stmt in compiled.ast.stmts {
    match stmt {
      @core.Stmt::ExportLet(name~, expr~, ..) =>
        match expr {
          @core.Expr::Fn(params~, ret~, ..) => {
            for p in params {
              if p.ty == @core.Type::String ||
                p.ty == @core.Type::Named(name="String", args=[]) {
                string_param_names.push(p.name)
              }
            }
            if string_param_names.length() > 0 {
              target_func_name = Some(name)
              string_param_count = string_param_names.length()
              string_result = ret == Some(@core.Type::String) ||
                ret == Some(@core.Type::Named(name="String", args=[]))
              break
            }
          }
          _ => ()
        }
      _ => ()
    }
  }
  let func_name = match target_func_name {
    Some(n) => n
    None =>
      raise WasmCompileError::Optimize(
        "no exported function with string params found",
      )
  }
  let bundled = bundle_for_wasm(db, path, compiled.ast)
  let core_wasm = @codegen.emit_module_wasm_with_options(
    bundled,
    @codegen.wasm_emit_options(force_cabi_realloc=true),
  ) catch {
    e => raise WasmCompileError::Gen(e)
  }
  let component = @codegen.emit_component_wasm_with_string_lift(
    core_wasm,
    func_name,
    func_name,
    string_param_count,
    param_names=string_param_names,
    is_async~,
    string_result~,
  )
  optimize_wasm_bytes_with_opt_level(component, opt_level)
}

///|
/// Check if AST uses server builtins incompatible with P3 handler mode.
fn check_incompatible_server_builtins(ast : @core.Module) -> Array[String] {
  let found : Array[String] = []
  let incompatible_names = [
    "Http::listen", "Http::accept", "Http::request_method", "Http::request_url",
    "Http::request_header", "Http::request_body", "Http::respond",
  ]
  scan_server_builtins_block(ast, incompatible_names, found)
  found
}

///|
fn scan_server_builtins_block(
  block : @core.Module,
  names : Array[String],
  found : Array[String],
) -> Unit {
  for stmt in block.stmts {
    match stmt {
      @core.Stmt::Let(expr~, ..)
      | @core.Stmt::ExportLet(expr~, ..)
      | @core.Stmt::Expr(expr~, ..)
      | @core.Stmt::LetMut(expr~, ..)
      | @core.Stmt::Assign(expr~, ..) =>
        scan_server_builtins_expr(expr, names, found)
      _ => ()
    }
  }
}

///|
fn scan_server_builtins_expr(
  expr : @core.Expr,
  names : Array[String],
  found : Array[String],
) -> Unit {
  match expr {
    @core.Expr::Call(name~, args~, ..) => {
      for n in names {
        if name == n && !found.contains(n) {
          found.push(n)
        }
      }
      for arg in args {
        scan_server_builtins_expr(arg.expr, names, found)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      scan_server_builtins_expr(cond, names, found)
      scan_server_builtins_block(then_body, names, found)
      scan_server_builtins_block(else_body, names, found)
    }
    @core.Expr::Block(body~, ..) =>
      scan_server_builtins_block(body, names, found)
    @core.Expr::Fn(body~, ..) => scan_server_builtins_block(body, names, found)
    _ => ()
  }
}

///|
pub fn compile_module_component_with_opt_level(
  db : @runtime.VibeDb,
  path : String,
  opt_level? : String? = None,
  http_host_imports? : Bool = false,
) -> Bytes raise WasmCompileError {
  let component = compile_module_component(db, path, http_host_imports~)
  optimize_wasm_bytes_with_opt_level(component, opt_level)
}

///|
/// Generate WIT world for component embedding (`wasm-tools component embed/new`).
/// Uses bundled AST so builtins used through imports are reflected in the interface.
pub fn generate_module_component_wit(
  db : @runtime.VibeDb,
  path : String,
  package_name : String,
  world_name : String,
) -> String raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let bundled = bundle_for_wasm(db, path, compiled.ast)
  @codegen.generate_component_wit(bundled, package_name, world_name)
}

///|
fn elapsed_ms_from_us(elapsed_us : Int) -> Int {
  let elapsed_ms = elapsed_us / 1000
  if elapsed_ms <= 0 {
    1
  } else {
    elapsed_ms
  }
}

///|
fn profile_tsv_line(stage : String, elapsed_us : Int) -> String {
  let elapsed_ms = if elapsed_us <= 0 {
    0
  } else {
    elapsed_ms_from_us(elapsed_us)
  }
  stage + "\t" + elapsed_ms.to_string() + "\t" + elapsed_us.to_string() + "\n"
}

///|
pub fn wasm_compile_profile_tsv(
  load_us : Int,
  type_us : Int,
  compile_profile : WasmCompileStageProfile,
  write_us : Int,
  total_us : Int,
) -> String {
  "stage\telapsed_ms\telapsed_us\n" +
  profile_tsv_line("load", load_us) +
  profile_tsv_line("type", type_us) +
  profile_tsv_line("compile_module", compile_profile.module_us) +
  profile_tsv_line("bundle", compile_profile.bundle_us) +
  profile_tsv_line("emit", compile_profile.emit_us) +
  profile_tsv_line("optimize", compile_profile.optimize_us) +
  profile_tsv_line("compile", compile_profile.total_us) +
  profile_tsv_line("write", write_us) +
  profile_tsv_line("total", total_us)
}

///|
/// Compile in linked mode: don't inline imports, emit wasm imports instead.
/// Returns (user_wasm_bytes, linked_imports_info).
pub fn compile_module_wasm_linked(
  db : @runtime.VibeDb,
  path : String,
  debug_errors? : Bool = false,
  skip_typecheck? : Bool = false,
) -> (Bytes, Array[LinkedImport]) raise WasmCompileError {
  let compiled_ast = if skip_typecheck {
    let raw_ast = db.ast(path)
    let imports = db.imports(path)
    let aliases = build_alias_map(
      raw_ast,
      compile_module_import_aliases(imports),
    )
    let desugared = @frontend.desugar_method_calls(raw_ast, aliases)
    @frontend.rewrite_effect_handles(desugared)
  } else {
    let compiled = compile_module(db, path) catch {
      e => raise WasmCompileError::Compile(e)
    }
    compiled.ast
  }
  let (bundled, linked_imports) = bundle_for_wasm_linked(db, path, compiled_ast)
  let codegen_linked : Array[(String, String, Int, Int)] = []
  for li in linked_imports {
    codegen_linked.push(
      (li.module_name, li.func_name, li.param_count, li.return_count),
    )
  }
  let wasm = @codegen.emit_module_wasm_with_options(
    bundled,
    @codegen.wasm_emit_options(
      embed_error_strings=debug_errors,
      linked_imports=codegen_linked,
    ),
  ) catch {
    e => raise WasmCompileError::Gen(e)
  }
  (wasm, linked_imports)
}

///|
/// Emit WASM with linked imports (used by fast path in build --debug).
pub fn emit_wasm_with_linked_imports(
  bundled : @core.Module,
  linked_imports : Array[(String, String, Int, Int)],
) -> Bytes raise WasmCompileError {
  @codegen.emit_module_wasm_with_options(
    bundled,
    @codegen.wasm_emit_options(embed_error_strings=true, linked_imports~),
  ) catch {
    e => raise WasmCompileError::Gen(e)
  }
}

///|
pub fn emit_library_module_wasm(
  ast : @core.Module,
  debug_errors? : Bool = false,
) -> Bytes raise WasmCompileError {
  @codegen.emit_module_wasm_with_options(
    ast,
    @codegen.wasm_emit_options(
      embed_error_strings=debug_errors,
      library_mode=true,
    ),
  ) catch {
    e => raise WasmCompileError::Gen(e)
  }
}

///|
pub fn compile_module_wasm_js_string_with_opt_level(
  db : @runtime.VibeDb,
  path : String,
  no_dce? : Bool = false,
  opt_level? : String? = None,
  debug_errors? : Bool = false,
) -> Bytes raise WasmCompileError {
  let wasm = if no_dce {
    compile_module_wasm_js_string_no_dce(db, path, debug_errors~)
  } else {
    compile_module_wasm_js_string(db, path, debug_errors~)
  }
  optimize_wasm_bytes_with_opt_level(wasm, opt_level)
}

///|
pub fn compile_module_wasm_js_string_with_coverage(
  db : @runtime.VibeDb,
  path : String,
  no_dce? : Bool = false,
  opt_level? : String? = None,
  run_tests? : Bool = false,
  debug_errors? : Bool = false,
) -> WasmCoverageArtifact raise WasmCompileError {
  let coverage = if no_dce {
    compile_module_wasm_js_string_no_dce_with_coverage(
      db,
      path,
      run_tests~,
      debug_errors~,
    )
  } else if run_tests {
    compile_module_wasm_coverage_with(
      db,
      path,
      "tests",
      ast => {
        @codegen.emit_module_wasm_js_string_with_coverage_options(
          ast,
          wasm_emit_options(debug_errors),
        )
      },
      run_tests=true,
    )
  } else {
    compile_module_wasm_coverage_with(db, path, "default", ast => {
      @codegen.emit_module_wasm_js_string_with_coverage_options(
        ast,
        wasm_emit_options(debug_errors),
      )
    })
  }
  optimize_wasm_coverage_with_opt_level(coverage, opt_level)
}

///|
fn compile_module_wasm_js_string_no_dce_with_coverage(
  db : @runtime.VibeDb,
  path : String,
  run_tests? : Bool = false,
  debug_errors? : Bool = false,
) -> WasmCoverageArtifact raise WasmCompileError {
  compile_module_wasm_coverage_with(
    db,
    path,
    "no_dce",
    ast => {
      @codegen.emit_module_wasm_js_string_with_coverage_options(
        ast,
        wasm_emit_options(debug_errors),
      )
    },
    run_tests~,
  )
}

///|
/// Compile a module to WASM using wasm js-string builtins without DCE.
pub fn compile_module_wasm_js_string_no_dce(
  db : @runtime.VibeDb,
  path : String,
  debug_errors? : Bool = false,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(db, path, "no_dce", ast => {
    @codegen.emit_module_wasm_js_string_with_options(
      ast,
      wasm_emit_options(debug_errors),
    )
  })
}

///|
pub fn compile_module_wasm_gc_with_opt_level(
  db : @runtime.VibeDb,
  path : String,
  no_dce? : Bool = false,
  opt_level? : String? = None,
) -> Bytes raise WasmCompileError {
  let wasm = if no_dce {
    compile_module_wasm_gc_no_dce(db, path)
  } else {
    compile_module_wasm_gc(db, path)
  }
  optimize_wasm_bytes_with_opt_level(wasm, opt_level)
}

///|
pub fn compile_module_wasm_gc_with_opt_level_profiled(
  db : @runtime.VibeDb,
  path : String,
  no_dce? : Bool = false,
  opt_level? : String? = None,
) -> (Bytes, WasmCompileStageProfile) raise WasmCompileError {
  let cache_namespace = if no_dce { "gc_no_dce" } else { "gc_default" }
  if no_dce {
    compile_module_wasm_profiled_with(
      db, path, "no_dce", @codegen.emit_module_wasm_gc, cache_namespace, opt_level,
    )
  } else {
    compile_module_wasm_profiled_with(
      db, path, "gc", @codegen.emit_module_wasm_gc, cache_namespace, opt_level,
    )
  }
}

///|
/// Compile a module to WASM using wasm-gc opcodes without DCE.
pub fn compile_module_wasm_gc_no_dce(
  db : @runtime.VibeDb,
  path : String,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(db, path, "no_dce", @codegen.emit_module_wasm_gc)
}

///|
/// Compile a module to Component WASM with string param support.
pub fn compile_module_component_with_string_lift(
  db : @runtime.VibeDb,
  path : String,
  target_func_name : String,
  export_name : String,
  string_param_count : Int,
) -> Bytes raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let bundled = bundle_for_wasm(db, path, compiled.ast)
  let core_wasm = @codegen.emit_module_wasm_with_options(
    bundled,
    @codegen.wasm_emit_options(force_cabi_realloc=true),
  ) catch {
    e => raise WasmCompileError::Gen(e)
  }
  @codegen.emit_component_wasm_with_string_lift(
    core_wasm, target_func_name, export_name, string_param_count,
  )
}

///|
/// Patch sync func types to async for P3 components.
pub fn patch_p3_async_func_types(data : Bytes) -> Bytes {
  let patterns : Array[Array[Byte]] = [
    [
      b'\x40', b'\x02', b'\x06', b'\x6d', b'\x65', b'\x74', b'\x68', b'\x6f', b'\x64',
    ],
    [
      b'\x40', b'\x01', b'\x07', b'\x72', b'\x65', b'\x71', b'\x75', b'\x65', b'\x73',
      b'\x74',
    ],
  ]
  let buf = data.to_array()
  for pattern in patterns {
    for i in 0..<(buf.length() - pattern.length()) {
      let mut match_ = true
      for j in 0..<pattern.length() {
        if buf[i + j] != pattern[j] {
          match_ = false
          break
        }
      }
      if match_ {
        buf[i] = b'\x43'
      }
    }
  }
  Bytes::from_array(buf)
}

///|
/// Compose a vibe app component with a P3 adapter using mwac plug.
pub fn compose_p3_component(
  app_bytes : Bytes,
  adapter_bytes : Bytes,
) -> Bytes raise WasmCompileError {
  match @mwac.plug_components(adapter_bytes, [app_bytes], best_effort=true) {
    Ok(composed) => composed
    Err(e) =>
      raise WasmCompileError::Optimize("mwac plug failed: " + e.to_string())
  }
}

///|
/// Generate WIT interface definition for a module.
pub fn generate_module_wit(
  db : @runtime.VibeDb,
  path : String,
  package_name : String,
  world_name : String,
) -> String raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  @codegen.generate_wit(compiled.ast, package_name, world_name)
}

///|
/// Build module alias map from imports only.
fn build_alias_map(
  ast : @core.Module,
  import_aliases : Map[String, @core.Ref],
) -> Map[String, @core.Ref] {
  let _ = ast
  import_aliases
}
