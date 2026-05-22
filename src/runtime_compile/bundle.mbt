///|
/// Bundle a module with all its dependencies for WASM compilation.
/// This inlines all exported definitions from dependencies and removes imports.
/// Applies DCE to eliminate unused definitions.
pub fn bundle_for_wasm(
  db : @runtime.VibeDb,
  path : String,
  ast : @core.Module,
) -> @core.Module {
  bundle_for_wasm_impl(
    db,
    path,
    ast,
    apply_dce=true,
    include_test_entries=false,
    keep_for_in_helpers=true,
  )
}

///|
pub fn bundle_for_wasm_gc(
  db : @runtime.VibeDb,
  path : String,
  ast : @core.Module,
) -> @core.Module {
  bundle_for_wasm_impl(
    db,
    path,
    ast,
    apply_dce=true,
    include_test_entries=false,
    keep_for_in_helpers=false,
  )
}

///|
/// Bundle without DCE (for benchmarking comparison).
pub fn bundle_for_wasm_no_dce(
  db : @runtime.VibeDb,
  path : String,
  ast : @core.Module,
) -> @core.Module {
  bundle_for_wasm_impl(
    db,
    path,
    ast,
    apply_dce=false,
    include_test_entries=false,
    keep_for_in_helpers=true,
  )
}

///|
/// Bundle for coverage mode that executes top-level tests.
/// Keeps definitions referenced from test bodies when applying DCE.
pub fn bundle_for_wasm_test_coverage(
  db : @runtime.VibeDb,
  path : String,
  ast : @core.Module,
) -> @core.Module {
  bundle_for_wasm_impl(
    db,
    path,
    ast,
    apply_dce=true,
    include_test_entries=true,
    keep_for_in_helpers=true,
  )
}

///|
/// Linked import info for debug linked builds.
pub(all) struct LinkedImport {
  /// wasm module name (used in wasmtime --preload)
  module_name : String
  /// function name (wasm export name in library module)
  func_name : String
  /// number of i64 params (excluding i32 env)
  param_count : Int
  /// number of i64 return values (1 for scalar, 2+ for tuple)
  return_count : Int
} derive(Debug, Eq)

///|
pub fn prelude_core_module_name() -> String {
  "prelude_core"
}

///|
fn prelude_core_linked_import(stmt : @core.Stmt) -> LinkedImport? {
  match stmt {
    @core.Stmt::Let(name~, expr~, ..)
    | @core.Stmt::ExportLet(name~, expr~, ..)
    | @core.Stmt::InternalExportLet(name~, expr~, ..) =>
      match expr {
        @core.Expr::Fn(params~, ret~, ..) =>
          if linked_fn_has_func_param(params) {
            None
          } else {
            Some(LinkedImport::{
              module_name: prelude_core_module_name(),
              func_name: name,
              param_count: params.length(),
              return_count: fn_return_count(ret),
            })
          }
        _ => None
      }
    _ => None
  }
}

///|
fn prelude_core_library_stmts() -> Array[@core.Stmt] {
  let stmts : Array[@core.Stmt] = []
  for stmt in @checker.prelude_core_value_stmts() {
    match prelude_core_linked_import(stmt) {
      Some(_) => stmts.push(stmt)
      None => ()
    }
  }
  stmts
}

///|
fn prelude_linked_build_inline_stmts() -> Array[@core.Stmt] {
  let stmts : Array[@core.Stmt] = []
  for stmt in @checker.prelude_core_value_stmts() {
    match prelude_core_linked_import(stmt) {
      Some(_) => ()
      None => stmts.push(stmt)
    }
  }
  for stmt in @checker.prelude_builtin_value_stmts() {
    stmts.push(stmt)
  }
  stmts
}

///|
fn append_prelude_core_linked_imports(
  linked_imports : Array[LinkedImport],
  existing_value_names : Map[String, Bool],
) -> Unit {
  for stmt in prelude_core_library_stmts() {
    match prelude_core_linked_import(stmt) {
      Some(li) =>
        if !existing_value_names.contains(li.func_name) {
          existing_value_names[li.func_name] = true
          linked_imports.push(li)
        }
      None => ()
    }
  }
}

///|
fn append_prelude_inline_stmts_for_linked_build(
  bundled_stmts : Array[@core.Stmt],
  existing_value_names : Map[String, Bool],
) -> Unit {
  for stmt in prelude_linked_build_inline_stmts() {
    match bundle_stmt_value_name(stmt) {
      Some(name) =>
        if !existing_value_names.contains(name) {
          bundled_stmts.push(stmt)
          existing_value_names[name] = true
        }
      None => ()
    }
  }
}

///|
fn bundle_import_alias_map(ast : @core.Module) -> Map[String, String] {
  bundle_import_alias_map_with_skips(ast, {})
}

///|
fn bundle_import_alias_map_with_skips(
  ast : @core.Module,
  skipped_locals : Map[String, Bool],
) -> Map[String, String] {
  let aliases : Map[String, String] = {}
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(spec~, ..) =>
        for item in spec.items {
          match item.rename {
            Some(alias_name) =>
              if alias_name != item.name && !skipped_locals.contains(alias_name) {
                aliases[alias_name] = item.name
              }
            None => ()
          }
        }
      _ => ()
    }
  }
  aliases
}

///|
fn bundle_clone_scope(scope : Map[String, Bool]) -> Map[String, Bool] {
  let next : Map[String, Bool] = {}
  for name, value in scope {
    next[name] = value
  }
  next
}

///|
fn bundle_alias_name(
  name : String,
  aliases : Map[String, String],
  scope : Map[String, Bool],
) -> String {
  if scope.contains(name) {
    name
  } else {
    match aliases.get(name) {
      Some(original) => original
      None => name
    }
  }
}

///|
fn bundle_rewrite_alias_call_args(
  args : Array[@core.CallArg],
  aliases : Map[String, String],
  scope : Map[String, Bool],
) -> Array[@core.CallArg] {
  let next : Array[@core.CallArg] = []
  for arg in args {
    next.push(@core.CallArg::{
      label: arg.label,
      expr: bundle_rewrite_alias_expr(arg.expr, aliases, scope),
      span: arg.span,
    })
  }
  next
}

///|
fn bundle_rewrite_alias_record_fields(
  fields : Array[@core.RecordFieldExpr],
  aliases : Map[String, String],
  scope : Map[String, Bool],
) -> Array[@core.RecordFieldExpr] {
  let next : Array[@core.RecordFieldExpr] = []
  for field in fields {
    next.push(@core.RecordFieldExpr::{
      name: field.name,
      expr: bundle_rewrite_alias_expr(field.expr, aliases, scope),
      span: field.span,
    })
  }
  next
}

///|
fn bundle_rewrite_alias_map_fields(
  fields : Array[@core.MapFieldExpr],
  aliases : Map[String, String],
  scope : Map[String, Bool],
) -> Array[@core.MapFieldExpr] {
  let next : Array[@core.MapFieldExpr] = []
  for field in fields {
    next.push(@core.MapFieldExpr::{
      key: field.key,
      expr: bundle_rewrite_alias_expr(field.expr, aliases, scope),
      span: field.span,
    })
  }
  next
}

///|
fn bundle_rewrite_alias_match_arms(
  arms : Array[@core.MatchArm],
  aliases : Map[String, String],
  scope : Map[String, Bool],
) -> Array[@core.MatchArm] {
  let next : Array[@core.MatchArm] = []
  for arm in arms {
    let arm_scope = bundle_clone_scope(scope)
    @core.bind_pattern_names_walker(arm_scope, arm.pat)
    next.push(@core.MatchArm::{
      pat: arm.pat,
      cond: match arm.cond {
        Some(cond) => Some(bundle_rewrite_alias_expr(cond, aliases, arm_scope))
        None => None
      },
      expr: bundle_rewrite_alias_expr(arm.expr, aliases, arm_scope),
      span: arm.span,
    })
  }
  next
}

///|
fn bundle_rewrite_alias_expr(
  expr : @core.Expr,
  aliases : Map[String, String],
  scope : Map[String, Bool],
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
                bundle_rewrite_alias_expr(inner, aliases, scope),
              ),
            )
        }
      }
      @core.Expr::StringInterp(parts=next, span~)
    }
    @core.Expr::Ident(name~, span~) =>
      @core.Expr::Ident(name=bundle_alias_name(name, aliases, scope), span~)
    @core.Expr::Call(name~, type_args~, args~, span~) =>
      @core.Expr::Call(
        name=bundle_alias_name(name, aliases, scope),
        type_args~,
        args=bundle_rewrite_alias_call_args(args, aliases, scope),
        span~,
      )
    @core.Expr::Tuple(items~, span~) => {
      let next : Array[@core.Expr] = []
      for item in items {
        next.push(bundle_rewrite_alias_expr(item, aliases, scope))
      }
      @core.Expr::Tuple(items=next, span~)
    }
    @core.Expr::TupleIndex(expr~, index~, span~) =>
      @core.Expr::TupleIndex(
        expr=bundle_rewrite_alias_expr(expr, aliases, scope),
        index~,
        span~,
      )
    @core.Expr::Record(fields~, span~) =>
      @core.Expr::Record(
        fields=bundle_rewrite_alias_record_fields(fields, aliases, scope),
        span~,
      )
    @core.Expr::Array(items~, span~) => {
      let next : Array[@core.Expr] = []
      for item in items {
        next.push(bundle_rewrite_alias_expr(item, aliases, scope))
      }
      @core.Expr::Array(items=next, span~)
    }
    @core.Expr::Map(fields~, span~) =>
      @core.Expr::Map(
        fields=bundle_rewrite_alias_map_fields(fields, aliases, scope),
        span~,
      )
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=bundle_rewrite_alias_expr(cond, aliases, scope),
        then_body=bundle_rewrite_alias_module_with_scope(
          then_body, aliases, scope,
        ),
        else_body=bundle_rewrite_alias_module_with_scope(
          else_body, aliases, scope,
        ),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(
        body=bundle_rewrite_alias_module_with_scope(body, aliases, scope),
        span~,
      )
    @core.Expr::Match(scrutinee~, arms~, span~) =>
      @core.Expr::Match(
        scrutinee=bundle_rewrite_alias_expr(scrutinee, aliases, scope),
        arms=bundle_rewrite_alias_match_arms(arms, aliases, scope),
        span~,
      )
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let body_scope = bundle_clone_scope(scope)
      body_scope[value_name] = true
      match index_name {
        Some(name) => body_scope[name] = true
        None => ()
      }
      @core.Expr::ForIn(
        value_name~,
        index_name~,
        iterable=bundle_rewrite_alias_expr(iterable, aliases, scope),
        body=bundle_rewrite_alias_module_with_scope(body, aliases, body_scope),
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
      let body_scope = bundle_clone_scope(scope)
      for param in params {
        body_scope[param.name] = true
      }
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects~,
        body=bundle_rewrite_alias_module_with_scope(body, aliases, body_scope),
        span~,
      )
    }
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=bundle_rewrite_alias_expr(cond, aliases, scope),
        body=bundle_rewrite_alias_module_with_scope(body, aliases, scope),
        span~,
      )
    @core.Expr::Loop(params~, body~, span~) => {
      let next_params : Array[@core.LoopParam] = []
      let body_scope = bundle_clone_scope(scope)
      for param in params {
        next_params.push(@core.LoopParam::{
          name: param.name,
          init: bundle_rewrite_alias_expr(param.init, aliases, scope),
          span: param.span,
        })
        body_scope[param.name] = true
      }
      @core.Expr::Loop(
        params=next_params,
        body=bundle_rewrite_alias_module_with_scope(body, aliases, body_scope),
        span~,
      )
    }
    @core.Expr::Break(value~, span~) =>
      @core.Expr::Break(
        value=match value {
          Some(inner) => Some(bundle_rewrite_alias_expr(inner, aliases, scope))
          None => None
        },
        span~,
      )
    @core.Expr::Continue(args~, span~) => {
      let next : Array[@core.Expr] = []
      for arg in args {
        next.push(bundle_rewrite_alias_expr(arg, aliases, scope))
      }
      @core.Expr::Continue(args=next, span~)
    }
    @core.Expr::Yield(expr~, span~) =>
      @core.Expr::Yield(
        expr=bundle_rewrite_alias_expr(expr, aliases, scope),
        span~,
      )
    @core.Expr::Handle(body~, arms~, span~) =>
      @core.Expr::Handle(
        body=bundle_rewrite_alias_module_with_scope(body, aliases, scope),
        arms=bundle_rewrite_alias_match_arms(arms, aliases, scope),
        span~,
      )
    @core.Expr::StructLit(name~, type_args~, fields~, span~) =>
      @core.Expr::StructLit(
        name~,
        type_args~,
        fields=bundle_rewrite_alias_record_fields(fields, aliases, scope),
        span~,
      )
    @core.Expr::Spread(expr~, span~) =>
      @core.Expr::Spread(
        expr=bundle_rewrite_alias_expr(expr, aliases, scope),
        span~,
      )
    @core.Expr::Perform(effect_name~, op_name~, args~, span~) =>
      @core.Expr::Perform(
        effect_name~,
        op_name~,
        args=bundle_rewrite_alias_call_args(args, aliases, scope),
        span~,
      )
  }
}

///|
fn bundle_rewrite_alias_stmt(
  stmt : @core.Stmt,
  aliases : Map[String, String],
  scope : Map[String, Bool],
) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let expr_scope = if rec {
        let child = bundle_clone_scope(scope)
        child[name] = true
        child
      } else {
        scope
      }
      @core.Stmt::Let(
        rec~,
        name~,
        expr=bundle_rewrite_alias_expr(expr, aliases, expr_scope),
        span~,
      )
    }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
      let expr_scope = if rec {
        let child = bundle_clone_scope(scope)
        child[name] = true
        child
      } else {
        scope
      }
      @core.Stmt::ExportLet(
        rec~,
        name~,
        expr=bundle_rewrite_alias_expr(expr, aliases, expr_scope),
        span~,
      )
    }
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) => {
      let expr_scope = if rec {
        let child = bundle_clone_scope(scope)
        child[name] = true
        child
      } else {
        scope
      }
      @core.Stmt::InternalExportLet(
        rec~,
        name~,
        expr=bundle_rewrite_alias_expr(expr, aliases, expr_scope),
        span~,
      )
    }
    @core.Stmt::LetMut(name~, expr~, span~) =>
      @core.Stmt::LetMut(
        name~,
        expr=bundle_rewrite_alias_expr(expr, aliases, scope),
        span~,
      )
    @core.Stmt::Assign(name~, expr~, span~) =>
      @core.Stmt::Assign(
        name=bundle_alias_name(name, aliases, scope),
        expr=bundle_rewrite_alias_expr(expr, aliases, scope),
        span~,
      )
    @core.Stmt::IndexAssign(target~, index~, value~, span~) =>
      @core.Stmt::IndexAssign(
        target=bundle_rewrite_alias_expr(target, aliases, scope),
        index=bundle_rewrite_alias_expr(index, aliases, scope),
        value=bundle_rewrite_alias_expr(value, aliases, scope),
        span~,
      )
    @core.Stmt::LetPat(pat~, expr~, span~) =>
      @core.Stmt::LetPat(
        pat~,
        expr=bundle_rewrite_alias_expr(expr, aliases, scope),
        span~,
      )
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) =>
      @core.Stmt::LetPatElse(
        pat~,
        expr=bundle_rewrite_alias_expr(expr, aliases, scope),
        else_body=bundle_rewrite_alias_module_with_scope(
          else_body, aliases, scope,
        ),
        span~,
      )
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(
        expr=bundle_rewrite_alias_expr(expr, aliases, scope),
        span~,
      )
    @core.Stmt::Test(name~, body~, span~) =>
      @core.Stmt::Test(
        name~,
        body=bundle_rewrite_alias_module_with_scope(body, aliases, scope),
        span~,
      )
    @core.Stmt::Bench(name~, body~, span~) =>
      @core.Stmt::Bench(
        name~,
        body=bundle_rewrite_alias_module_with_scope(body, aliases, scope),
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
        next_methods.push(@core.ImplMethodDef::{
          name: impl_method.name,
          expr: bundle_rewrite_alias_expr(impl_method.expr, aliases, scope),
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
fn bundle_extend_alias_scope(
  scope : Map[String, Bool],
  stmt : @core.Stmt,
) -> Unit {
  match stmt {
    @core.Stmt::Let(name~, ..)
    | @core.Stmt::ExportLet(name~, ..)
    | @core.Stmt::InternalExportLet(name~, ..)
    | @core.Stmt::LetMut(name~, ..)
    | @core.Stmt::ExternLet(name~, ..) => scope[name] = true
    @core.Stmt::LetPat(pat~, ..) | @core.Stmt::LetPatElse(pat~, ..) =>
      @core.bind_pattern_names_walker(scope, pat)
    _ => ()
  }
}

///|
fn bundle_rewrite_alias_module_with_scope(
  ast : @core.Module,
  aliases : Map[String, String],
  parent_scope : Map[String, Bool],
) -> @core.Module {
  let scope = bundle_clone_scope(parent_scope)
  let next : Array[@core.Stmt] = []
  for stmt in ast.stmts {
    next.push(bundle_rewrite_alias_stmt(stmt, aliases, scope))
    bundle_extend_alias_scope(scope, stmt)
  }
  @core.Module::{ stmts: next }
}

///|
fn bundle_rewrite_import_aliases(ast : @core.Module) -> @core.Module {
  bundle_rewrite_import_aliases_from_map(ast, bundle_import_alias_map(ast))
}

///|
fn bundle_rewrite_import_aliases_with_skips(
  ast : @core.Module,
  skipped_locals : Map[String, Bool],
) -> @core.Module {
  let aliases = bundle_import_alias_map_with_skips(ast, skipped_locals)
  bundle_rewrite_import_aliases_from_map(ast, aliases)
}

///|
fn bundle_rewrite_import_aliases_from_map(
  ast : @core.Module,
  aliases : Map[String, String],
) -> @core.Module {
  if aliases.length() == 0 {
    ast
  } else {
    bundle_rewrite_alias_module_with_scope(ast, aliases, {})
  }
}

///|
priv struct BundleImportAliasCollision {
  source_path : String
  original_name : String
  local_name : String
}

///|
fn bundle_import_item_is_value(item : @core.ImportItem) -> Bool {
  item.kind == @core.ImportKind::Value
}

///|
fn bundle_resolve_import_source_path(
  db : @runtime.VibeDb,
  owner_path : String,
  source : @core.ModuleRef,
) -> String? {
  let imports = db.imports(owner_path)
  let base_dir = @path.Path(owner_path).dirname().to_string()
  for imp in imports {
    if @runtime.import_stmt_matches_spec(base_dir, source, imp) {
      return Some(imp.path)
    }
  }
  resolve_module_ref_path(base_dir, source, dep_imports=imports)
}

///|
fn bundle_collect_import_alias_collisions(
  db : @runtime.VibeDb,
  owner_path : String,
  ast : @core.Module,
) -> Array[BundleImportAliasCollision] {
  let import_paths_by_name : Map[String, Map[String, Bool]] = {}
  let imports : Array[BundleImportAliasCollision] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(spec~, source~, ..) =>
        match bundle_resolve_import_source_path(db, owner_path, source) {
          Some(source_path) =>
            for item in spec.items {
              if bundle_import_item_is_value(item) {
                let local_name = @core.import_item_local_name(item)
                imports.push(BundleImportAliasCollision::{
                  source_path,
                  original_name: item.name,
                  local_name,
                })
                match import_paths_by_name.get(item.name) {
                  Some(paths) => paths[source_path] = true
                  None => {
                    let paths : Map[String, Bool] = {}
                    paths[source_path] = true
                    import_paths_by_name[item.name] = paths
                  }
                }
              }
            }
          None => ()
        }
      _ => ()
    }
  }
  let collisions : Array[BundleImportAliasCollision] = []
  for imp in imports {
    match import_paths_by_name.get(imp.original_name) {
      Some(paths) => if paths.length() > 1 { collisions.push(imp) }
      None => ()
    }
  }
  collisions
}

///|
fn bundle_collision_local_names(
  collisions : Array[BundleImportAliasCollision],
) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for collision in collisions {
    out[collision.local_name] = true
  }
  out
}

///|
fn bundle_collision_original_names(
  collisions : Array[BundleImportAliasCollision],
) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for collision in collisions {
    out[collision.original_name] = true
  }
  out
}

///|
fn bundle_drop_colliding_value_defs(
  stmts : Array[@core.Stmt],
  colliding_originals : Map[String, Bool],
) -> Array[@core.Stmt] {
  if colliding_originals.length() == 0 {
    return stmts
  }
  let out : Array[@core.Stmt] = []
  for stmt in stmts {
    match bundle_stmt_value_name(stmt) {
      Some(name) => if !colliding_originals.contains(name) { out.push(stmt) }
      None => out.push(stmt)
    }
  }
  out
}

///|
fn bundle_rewrite_imported_value_to_local(
  stmt : @core.Stmt,
  original_name : String,
  local_name : String,
) -> @core.Stmt? {
  let rewrite_expr = fn(expr : @core.Expr) {
    if local_name == original_name {
      expr
    } else {
      let aliases : Map[String, String] = {}
      aliases[original_name] = local_name
      bundle_rewrite_alias_expr(expr, aliases, {})
    }
  }
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~)
    | @core.Stmt::ExportLet(rec~, name~, expr~, span~)
    | @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) =>
      if name == original_name {
        Some(
          @core.Stmt::Let(rec~, name=local_name, expr=rewrite_expr(expr), span~),
        )
      } else {
        None
      }
    @core.Stmt::LetMut(name~, expr~, span~) =>
      if name == original_name {
        Some(
          @core.Stmt::LetMut(name=local_name, expr=rewrite_expr(expr), span~),
        )
      } else {
        None
      }
    _ => None
  }
}

///|
fn bundle_append_import_alias_collision_defs(
  db : @runtime.VibeDb,
  collisions : Array[BundleImportAliasCollision],
  out : Array[@core.Stmt],
) -> Unit {
  let emitted_aliases : Map[String, Bool] = {}
  let emitted_helpers : Map[String, Bool] = {}
  for collision in collisions {
    if emitted_aliases.contains(collision.local_name) {
      continue
    }
    let rewritten_source_ast = bundle_rewrite_import_aliases(
      db.ast_with_hash_imports(collision.source_path),
    )
    let source_ast = namespace_private_module_values(
      collision.source_path,
      rewritten_source_ast,
    )
    let private_names = collect_private_value_rename_map(
      collision.source_path,
      rewritten_source_ast,
    )
    for stmt in source_ast.stmts {
      match bundle_stmt_value_name(stmt) {
        Some(name) =>
          for _, renamed in private_names {
            if name == renamed && !emitted_helpers.contains(name) {
              out.push(stmt)
              emitted_helpers[name] = true
            }
          }
        None => ()
      }
    }
    for stmt in source_ast.stmts {
      match
        bundle_rewrite_imported_value_to_local(
          stmt,
          collision.original_name,
          collision.local_name,
        ) {
        Some(local_stmt) => {
          out.push(local_stmt)
          emitted_aliases[collision.local_name] = true
          break
        }
        None => ()
      }
    }
  }
}

///|
pub fn prelude_core_library_module() -> @core.Module {
  @core.Module::{ stmts: prelude_core_library_stmts() }
}

///|
priv struct SelectedReExport {
  spec : @core.ImportSpec
  source : @core.ModuleRef
}

///|
fn push_linked_import(
  linked_imports : Array[LinkedImport],
  existing_value_names : Map[String, Bool],
  li : LinkedImport,
) -> Unit {
  if !existing_value_names.contains(li.func_name) {
    existing_value_names[li.func_name] = true
    linked_imports.push(li)
  }
}

///|
fn linked_import_from_resolved_fn(
  module_name : String,
  local_name : String,
  resolved : ResolvedReExportFn,
) -> LinkedImport {
  LinkedImport::{
    module_name,
    func_name: local_name,
    param_count: resolved.params.length(),
    return_count: resolved.return_count,
  }
}

///|
fn collect_dependency_defs_selected(
  db : @runtime.VibeDb,
  path : String,
  out : Array[@core.Stmt],
  visited : Map[String, Bool],
  protected_value_names : Map[String, Bool],
  protected_type_names : Map[String, Bool],
  selected_export_names : Map[String, Bool],
  selected_reexports : Array[SelectedReExport],
) -> Unit {
  if visited.contains(path) {
    return
  }
  let is_entry = visited.length() == 0
  visited[path] = true
  let imports = db.imports(path)
  for imp in imports {
    collect_dependency_defs_with_protected_names(
      db,
      imp.path,
      out,
      visited,
      protected_value_names,
      protected_type_names,
    )
  }
  if !is_entry {
    let existing_values = bundle_existing_value_names_with_protected(
      out, protected_value_names,
    )
    let existing_types = bundle_existing_type_names_with_protected(
      out, protected_type_names,
    )
    let dep_ast = namespace_private_module_defs_for_existing_names(
      path,
      bundle_rewrite_import_aliases(db.ast_with_hash_imports(path)),
      existing_values,
      existing_types,
    )
    let emitted_types = bundle_existing_type_names_with_protected(
      out, protected_type_names,
    )
    for stmt in dep_ast.stmts {
      match stmt {
        @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
          if selected_export_names.contains(name) {
            out.push(@core.Stmt::Let(rec~, name~, expr~, span~))
          }
        @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
          if !emitted_types.contains(name) {
            out.push(@core.Stmt::EnumDef(name~, params~, ctors~, span~))
            emitted_types[name] = true
          }
        @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
          if !emitted_types.contains(name) {
            out.push(@core.Stmt::TypeAlias(name~, params~, target~, span~))
            emitted_types[name] = true
          }
        @core.Stmt::Let(..) => out.push(stmt)
        @core.Stmt::EnumDef(name~, ..) =>
          if !emitted_types.contains(name) {
            out.push(stmt)
            emitted_types[name] = true
          }
        @core.Stmt::TypeAlias(name~, ..) =>
          if !emitted_types.contains(name) {
            out.push(stmt)
            emitted_types[name] = true
          }
        @core.Stmt::ReExport(..) => ()
        @core.Stmt::Import(..) | @core.Stmt::Export(..) => ()
        @core.Stmt::Test(..) | @core.Stmt::Bench(..) => ()
        @core.Stmt::TraitDef(..)
        | @core.Stmt::TraitImpl(..)
        | @core.Stmt::InternalTraitDef(..) => out.push(stmt)
        @core.Stmt::LetMut(..) => out.push(stmt)
        _ => out.push(stmt)
      }
    }
    for selected in selected_reexports {
      collect_reexport_defs(
        db,
        path,
        selected.spec,
        selected.source,
        out,
        visited,
        protected_value_names,
        protected_type_names,
      )
    }
  }
}

///|
/// Bundle for linked mode: don't inline import dependencies, instead return
/// their exported function names as linked imports. These become wasm imports
/// that are resolved at runtime via `wasmtime --preload`.
pub fn bundle_for_wasm_linked(
  db : @runtime.VibeDb,
  path : String,
  ast : @core.Module,
) -> (@core.Module, Array[LinkedImport]) {
  let bundled_stmts : Array[@core.Stmt] = []
  let linked_imports : Array[LinkedImport] = []
  let existing_value_names : Map[String, Bool] = {}
  // Collect linked imports from dependency modules.
  // If all exported functions have scalar params → linked import (static wasm call).
  // If any export has Func params (HOF) → inline the entire module (monolithic).
  let imports = db.imports(path)
  let visited : Map[String, Bool] = {}
  let entry_value_names = bundle_module_all_value_binder_names(
    bundle_rewrite_import_aliases(ast),
  )
  let entry_type_names = bundle_module_type_names(
    bundle_rewrite_import_aliases(ast),
  )
  // Mark user module as visited so collect_dependency_defs treats
  // import modules as non-entry (their ExportLet defs will be included).
  visited[path] = true
  for imp in imports {
    let dep_ast = bundle_rewrite_import_aliases(
      db.ast_with_hash_imports(imp.path),
    )
    let module_name = linked_module_name(imp.path)
    let host_imports_visited : Map[String, Bool] = {}
    let needs_host_import_inline = module_requires_preload_host_imports(
      db,
      imp.path,
      host_imports_visited,
    )
    if needs_host_import_inline {
      // Inline deps that need host imports because wasmtime --preload cannot
      // instantiate library modules that carry their own host/WASI imports.
      collect_dependency_defs_with_protected_names(
        db,
        imp.path,
        bundled_stmts,
        visited,
        entry_value_names,
        entry_type_names,
      )
    } else {
      let selected_export_names : Map[String, Bool] = {}
      let selected_reexports : Array[SelectedReExport] = []
      for stmt in dep_ast.stmts {
        match stmt {
          @core.Stmt::ExportLet(name~, expr=_, ..) =>
            match resolve_bound_fn_at_path(db, imp.path, name, {}) {
              Some(resolved) =>
                if linked_fn_has_func_param(resolved.params) {
                  selected_export_names[name] = true
                } else {
                  push_linked_import(
                    linked_imports,
                    existing_value_names,
                    linked_import_from_resolved_fn(module_name, name, resolved),
                  )
                }
              _ => ()
            }
          @core.Stmt::ReExport(spec~, source~, ..) => {
            let resolved = resolve_reexport_all(db, imp.path, spec, source)
            let resolved_fn_map : Map[String, ResolvedReExportFn] = {}
            for r in resolved.functions {
              resolved_fn_map[r.name] = r
            }
            let hof_items : Array[@core.ImportItem] = []
            for item in spec.items {
              let local_name = import_local_name(item)
              match resolved_fn_map.get(local_name) {
                Some(resolved_fn) =>
                  if linked_fn_has_func_param(resolved_fn.params) {
                    hof_items.push(item)
                  } else {
                    push_linked_import(
                      linked_imports,
                      existing_value_names,
                      linked_import_from_resolved_fn(
                        module_name, local_name, resolved_fn,
                      ),
                    )
                  }
                None => ()
              }
            }
            if hof_items.length() > 0 {
              selected_reexports.push(SelectedReExport::{
                spec: { items: hof_items },
                source,
              })
            }
            for t in resolved.type_stmts {
              bundled_stmts.push(t)
            }
          }
          @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
            bundled_stmts.push(
              @core.Stmt::EnumDef(name~, params~, ctors~, span~),
            )
          @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
            bundled_stmts.push(
              @core.Stmt::TypeAlias(name~, params~, target~, span~),
            )
          _ => ()
        }
      }
      if selected_export_names.length() > 0 || selected_reexports.length() > 0 {
        collect_dependency_defs_selected(
          db,
          imp.path,
          bundled_stmts,
          visited,
          entry_value_names,
          entry_type_names,
          selected_export_names,
          selected_reexports,
        )
      }
    }
  }
  append_prelude_core_linked_imports(linked_imports, existing_value_names)
  append_prelude_inline_stmts_for_linked_build(
    bundled_stmts, existing_value_names,
  )
  // Add main module statements (excluding imports; resolve re-exports for types)
  let raw_entry_ast = db.ast(path)
  let entry_ast = bundle_rewrite_import_aliases(ast)
  let non_prelude_names : Array[String] = []
  for stmt in entry_ast.stmts {
    match stmt {
      @core.Stmt::Import(..) => ()
      @core.Stmt::ReExport(..) => ()
      _ => {
        match bundle_stmt_value_name(stmt) {
          Some(name) => non_prelude_names.push(name)
          None => ()
        }
        bundled_stmts.push(stmt)
      }
    }
  }
  // Resolve type definitions from entry module's own ReExport stmts
  for stmt in raw_entry_ast.stmts {
    match stmt {
      @core.Stmt::ReExport(spec~, source~, ..) => {
        let resolved = resolve_reexport_all(db, path, spec, source)
        for t in resolved.type_stmts {
          bundled_stmts.push(t)
        }
      }
      _ => ()
    }
  }
  let bundled = @core.Module::{
    stmts: dedupe_bundle_structural_defs(bundled_stmts),
  }
  let after_dce = @pipeline.dce_module_with_entry_names(
    bundled, non_prelude_names,
  )
  (demote_unused_let_mut(after_dce), linked_imports)
}

///|
/// Build linked bundle from already-resolved user AST plus externally supplied
/// linked imports. Used by cached fast paths that skip rebuilding dependency db.
pub fn bundle_for_wasm_linked_with_imports(
  ast : @core.Module,
  linked_imports : Array[LinkedImport],
  extra_type_stmts? : Array[@core.Stmt] = [],
) -> (@core.Module, Array[LinkedImport]) {
  let bundled_stmts : Array[@core.Stmt] = []
  let existing_value_names : Map[String, Bool] = {}
  for li in linked_imports {
    existing_value_names[li.func_name] = true
  }
  append_prelude_inline_stmts_for_linked_build(
    bundled_stmts, existing_value_names,
  )
  for stmt in extra_type_stmts {
    bundled_stmts.push(stmt)
  }
  let non_prelude_names : Array[String] = []
  let rewritten_ast = bundle_rewrite_import_aliases(ast)
  for stmt in rewritten_ast.stmts {
    match stmt {
      @core.Stmt::Import(..) | @core.Stmt::ReExport(..) => ()
      _ => {
        match bundle_stmt_value_name(stmt) {
          Some(name) => non_prelude_names.push(name)
          None => ()
        }
        bundled_stmts.push(stmt)
      }
    }
  }
  let bundled = @core.Module::{
    stmts: dedupe_bundle_structural_defs(bundled_stmts),
  }
  let after_dce = @pipeline.dce_module_with_entry_names(
    bundled, non_prelude_names,
  )
  (demote_unused_let_mut(after_dce), linked_imports)
}

///|
/// Check if any function parameter has a Func type (higher-order function).
/// HOF functions need funcref table sharing, so they must be inlined.
fn linked_fn_has_func_param(params : Array[@core.FuncParam]) -> Bool {
  for param in params {
    if linked_type_is_func(param.ty) {
      return true
    }
  }
  false
}

///|
pub fn linked_module_name(path : String) -> String {
  let mut name = path
  let mut last_slash = -1
  for i, c in name {
    if c == '/' {
      last_slash = i
    }
  }
  if last_slash >= 0 {
    name = name.unsafe_substring(start=last_slash + 1, end=name.length())
  }
  if name.has_suffix(".vibe") {
    name = name.unsafe_substring(start=0, end=name.length() - 5)
  }
  name
}

///|
fn linked_type_is_func(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::Func(..) => true
    _ => false
  }
}

///|
fn module_requires_preload_host_imports(
  db : @runtime.VibeDb,
  path : String,
  visited : Map[String, Bool],
) -> Bool {
  if visited.contains(path) {
    return false
  }
  visited[path] = true
  let ast = db.ast(path)
  if module_stmt_list_requires_preload_host_imports(ast.stmts) {
    return true
  }
  let dep_imports = db.imports(path)
  for imp in dep_imports {
    if module_requires_preload_host_imports(db, imp.path, visited) {
      return true
    }
  }
  let base_dir = @path.Path(path).dirname().to_string()
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::ReExport(source~, ..) =>
        match resolve_module_ref_path(base_dir, source, dep_imports~) {
          Some(source_path) =>
            if module_requires_preload_host_imports(db, source_path, visited) {
              return true
            }
          None => ()
        }
      _ => ()
    }
  }
  false
}

///|
fn module_stmt_list_requires_preload_host_imports(
  stmts : Array[@core.Stmt],
) -> Bool {
  for stmt in stmts {
    if module_stmt_requires_preload_host_imports(stmt) {
      return true
    }
  }
  false
}

///|
fn module_stmt_requires_preload_host_imports(stmt : @core.Stmt) -> Bool {
  match stmt {
    @core.Stmt::Let(expr~, ..)
    | @core.Stmt::ExportLet(expr~, ..)
    | @core.Stmt::InternalExportLet(expr~, ..)
    | @core.Stmt::LetMut(expr~, ..)
    | @core.Stmt::Expr(expr~, ..)
    | @core.Stmt::LetPat(expr~, ..) =>
      module_expr_requires_preload_host_imports(expr)
    @core.Stmt::LetPatElse(expr~, else_body~, ..) =>
      module_expr_requires_preload_host_imports(expr) ||
      module_stmt_list_requires_preload_host_imports(else_body.stmts)
    @core.Stmt::Assign(expr~, ..) =>
      module_expr_requires_preload_host_imports(expr)
    @core.Stmt::IndexAssign(target~, index~, value~, ..) =>
      module_expr_requires_preload_host_imports(target) ||
      module_expr_requires_preload_host_imports(index) ||
      module_expr_requires_preload_host_imports(value)
    @core.Stmt::Test(..) | @core.Stmt::Bench(..) => false
    _ => false
  }
}

///|
fn module_expr_requires_preload_host_imports(expr : @core.Expr) -> Bool {
  match expr {
    @core.Expr::Call(name~, args~, ..) => {
      if is_preload_unsafe_builtin_name(name) {
        return true
      }
      for arg in args {
        if module_expr_requires_preload_host_imports(arg.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Perform(effect_name~, args~, ..) => {
      if is_preload_unsafe_effect_name(effect_name) {
        return true
      }
      for arg in args {
        if module_expr_requires_preload_host_imports(arg.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) => {
      for item in items {
        if module_expr_requires_preload_host_imports(item) {
          return true
        }
      }
      false
    }
    @core.Expr::TupleIndex(expr~, ..)
    | @core.Expr::Spread(expr~, ..)
    | @core.Expr::Yield(expr~, ..) =>
      module_expr_requires_preload_host_imports(expr)
    @core.Expr::Record(fields~, ..) | @core.Expr::StructLit(fields~, ..) => {
      for field in fields {
        if module_expr_requires_preload_host_imports(field.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Map(fields~, ..) => {
      for field in fields {
        if module_expr_requires_preload_host_imports(field.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::If(cond~, then_body~, else_body~, ..) =>
      module_expr_requires_preload_host_imports(cond) ||
      module_stmt_list_requires_preload_host_imports(then_body.stmts) ||
      module_stmt_list_requires_preload_host_imports(else_body.stmts)
    @core.Expr::Block(body~, ..) | @core.Expr::Fn(body~, ..) =>
      module_stmt_list_requires_preload_host_imports(body.stmts)
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      if module_expr_requires_preload_host_imports(scrutinee) {
        return true
      }
      for arm in arms {
        if module_expr_requires_preload_host_imports(arm.expr) {
          return true
        }
        match arm.cond {
          Some(cond) =>
            if module_expr_requires_preload_host_imports(cond) {
              return true
            }
          None => ()
        }
      }
      false
    }
    @core.Expr::Handle(body~, arms~, ..) => {
      if module_stmt_list_requires_preload_host_imports(body.stmts) {
        return true
      }
      for arm in arms {
        if module_expr_requires_preload_host_imports(arm.expr) {
          return true
        }
        match arm.cond {
          Some(cond) =>
            if module_expr_requires_preload_host_imports(cond) {
              return true
            }
          None => ()
        }
      }
      false
    }
    @core.Expr::ForIn(iterable~, body~, ..) =>
      module_expr_requires_preload_host_imports(iterable) ||
      module_stmt_list_requires_preload_host_imports(body.stmts)
    @core.Expr::While(cond~, body~, ..) =>
      module_expr_requires_preload_host_imports(cond) ||
      module_stmt_list_requires_preload_host_imports(body.stmts)
    @core.Expr::Loop(params~, body~, ..) => {
      for param in params {
        if module_expr_requires_preload_host_imports(param.init) {
          return true
        }
      }
      module_stmt_list_requires_preload_host_imports(body.stmts)
    }
    @core.Expr::Break(value~, ..) =>
      match value {
        Some(inner) => module_expr_requires_preload_host_imports(inner)
        None => false
      }
    @core.Expr::Continue(args~, ..) => {
      for arg in args {
        if module_expr_requires_preload_host_imports(arg) {
          return true
        }
      }
      false
    }
    @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::Char(..)
    | @core.Expr::String(..)
    | @core.Expr::Ident(..)
    | @core.Expr::Placeholder(..) => false
    // StringInterp is lowered in desugar; should never reach here
    @core.Expr::StringInterp(..) => false
  }
}

///|
fn is_preload_unsafe_builtin_name(name : String) -> Bool {
  name == "sh" ||
  name == "path" ||
  name == "Path::resolve" ||
  name == "sleep" ||
  name == "Env::get" ||
  name == "Env::args_len" ||
  name == "Env::args_get" ||
  name == "Stdout::write_char" ||
  name == "Stdout::write_stream" ||
  name == "Stdin::read_char" ||
  name == "Stdin::read_stream" ||
  name == "Fs::read_file" ||
  name == "Fs::write_file" ||
  name == "Fs::write_bytes" ||
  name == "Fs::exists" ||
  name == "Fs::stat_token" ||
  name == "Socket::tcp_connect" ||
  name == "Socket::tcp_read" ||
  name == "Socket::tcp_write" ||
  name == "Socket::tcp_close" ||
  name == "Http::request" ||
  name == "Http::response_status" ||
  name == "Http::response_header" ||
  name == "Http::response_body" ||
  name == "Http::close" ||
  name == "Http::listen" ||
  name == "Http::accept" ||
  name == "Http::request_method" ||
  name == "Http::request_url" ||
  name == "Http::request_header" ||
  name == "Http::request_body" ||
  name == "Http::respond"
}

///|
fn is_preload_unsafe_effect_name(effect_name : String) -> Bool {
  effect_name == "Fs" ||
  effect_name == "Env" ||
  effect_name == "Stdout" ||
  effect_name == "Stdin" ||
  effect_name == "Socket" ||
  effect_name == "Http" ||
  effect_name == "Process"
}

///|
/// Resolved function info from a ReExport chain.
priv struct ResolvedReExportFn {
  name : String
  params : Array[@core.FuncParam]
  return_count : Int
}

///|
/// Result of resolving all items in a ReExport statement.
priv struct ResolvedReExport {
  functions : Array[ResolvedReExportFn]
  type_stmts : Array[@core.Stmt]
}

///|
fn fn_return_count(ret : @core.Type?) -> Int {
  match ret {
    Some(@core.Type::Tuple(items)) => items.length()
    _ => 1
  }
}

///|
fn import_local_name(item : @core.ImportItem) -> String {
  match item.rename {
    Some(alias_name) => alias_name
    None => item.name
  }
}

///|
fn resolve_bound_fn_via_imports(
  db : @runtime.VibeDb,
  source_path : String,
  source_ast : @core.Module,
  name : String,
  visited : Map[String, Bool],
) -> ResolvedReExportFn? {
  let dep_imports = db.imports(source_path)
  let base_dir = @path.Path(source_path).dirname().to_string()
  for stmt in source_ast.stmts {
    match stmt {
      @core.Stmt::Import(spec~, source~, ..) =>
        for item in spec.items {
          if import_local_name(item) == name {
            match resolve_module_ref_path(base_dir, source, dep_imports~) {
              Some(import_path) =>
                match
                  resolve_bound_fn_at_path(db, import_path, item.name, visited) {
                  Some(resolved) =>
                    return Some(ResolvedReExportFn::{ ..resolved, name, })
                  None => ()
                }
              None => ()
            }
          }
        }
      _ => ()
    }
  }
  None
}

///|
fn resolve_bound_fn_at_path(
  db : @runtime.VibeDb,
  source_path : String,
  name : String,
  visited : Map[String, Bool],
) -> ResolvedReExportFn? {
  let visit_key = source_path + "#" + name
  if visited.contains(visit_key) {
    return None
  }
  visited[visit_key] = true
  let source_ast = db.ast_with_hash_imports(source_path)
  for stmt in source_ast.stmts {
    match stmt {
      @core.Stmt::Let(name=bound_name, expr~, ..)
      | @core.Stmt::ExportLet(name=bound_name, expr~, ..)
      | @core.Stmt::InternalExportLet(name=bound_name, expr~, ..) =>
        if bound_name == name {
          match expr {
            @core.Expr::Fn(params~, ret~, ..) =>
              return Some(ResolvedReExportFn::{
                name,
                params,
                return_count: fn_return_count(ret),
              })
            @core.Expr::Ident(name=target_name, ..) =>
              match
                resolve_bound_fn_via_imports(
                  db, source_path, source_ast, target_name, visited,
                ) {
                Some(resolved) =>
                  return Some(ResolvedReExportFn::{ ..resolved, name, })
                None => return None
              }
            _ => return None
          }
        }
      _ => ()
    }
  }
  resolve_bound_fn_via_imports(db, source_path, source_ast, name, visited)
}

///|
/// Resolve the file path that a ModuleRef points to, given the directory of the
/// referencing module and the import specs for the referrer.
fn resolve_module_ref_path(
  base_dir : String,
  source : @core.ModuleRef,
  dep_imports? : Array[@runtime.ImportSpec] = [],
) -> String? {
  match source {
    @core.ModuleRef::Path(path~) =>
      Some(@runtime.normalize_path_obj(base_dir, path).normalized)
    @core.ModuleRef::PinnedPath(path~, ..) =>
      Some(@runtime.normalize_path_obj(base_dir, path).normalized)
    @core.ModuleRef::Hash(hash~) => {
      // Resolve hash to path using pre-resolved import specs
      for imp in dep_imports {
        match imp.hash {
          Some(h) => if h == hash { return Some(imp.path) }
          None => ()
        }
      }
      None
    }
    _ => None
  }
}

///|
/// Resolve all items in a ReExport: functions become LinkedImports, types become
/// inlined definitions. Uses raw ASTs so ModuleRef::Path is preserved.
/// All item names are treated as potential matches regardless of ImportKind,
/// because vibe import syntax uses Value kind by default for all names.
fn resolve_reexport_all(
  db : @runtime.VibeDb,
  dep_path : String,
  spec : @core.ImportSpec,
  source : @core.ModuleRef,
) -> ResolvedReExport {
  let result = ResolvedReExport::{ functions: [], type_stmts: [] }
  let wanted : Map[String, String] = {}
  for item in spec.items {
    let export_name = match item.rename {
      Some(alias_name) => alias_name
      None => item.name
    }
    wanted[item.name] = export_name
  }
  if wanted.length() == 0 {
    return result
  }
  let dep_imports = db.imports(dep_path)
  let base_dir = @path.Path(dep_path).dirname().to_string()
  let source_path = match
    resolve_module_ref_path(base_dir, source, dep_imports~) {
    Some(p) => p
    None => return result
  }
  resolve_reexport_at_path(db, source_path, wanted, result)
  result
}

///|
/// Resolve ReExport items at a known source path.
fn resolve_reexport_at_path(
  db : @runtime.VibeDb,
  source_path : String,
  wanted : Map[String, String],
  result : ResolvedReExport,
) -> Unit {
  let source_ast = db.ast_with_hash_imports(source_path)
  for stmt in source_ast.stmts {
    match stmt {
      @core.Stmt::ExportLet(name~, expr=_, ..) =>
        match wanted.get(name) {
          Some(export_name) =>
            match resolve_bound_fn_at_path(db, source_path, name, {}) {
              Some(resolved) =>
                result.functions.push(ResolvedReExportFn::{
                  ..resolved,
                  name: export_name,
                })
              _ => ()
            }
          None => ()
        }
      @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
        match wanted.get(name) {
          Some(_export_name) =>
            result.type_stmts.push(
              @core.Stmt::EnumDef(name~, params~, ctors~, span~),
            )
          None => ()
        }
      @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
        match wanted.get(name) {
          Some(_export_name) =>
            result.type_stmts.push(
              @core.Stmt::TypeAlias(name~, params~, target~, span~),
            )
          None => ()
        }
      @core.Stmt::ExportStructDef(name~, params~, fields~, span~) =>
        match wanted.get(name) {
          Some(_export_name) =>
            result.type_stmts.push(
              @core.Stmt::StructDef(name~, params~, fields~, span~),
            )
          None => ()
        }
      @core.Stmt::ReExport(spec=inner_spec, source=inner_source, ..) => {
        // Recurse into nested ReExport chains
        let inner = resolve_reexport_all(
          db, source_path, inner_spec, inner_source,
        )
        for r in inner.functions {
          match wanted.get(r.name) {
            Some(export_name) =>
              result.functions.push(ResolvedReExportFn::{
                ..r,
                name: export_name,
              })
            None => ()
          }
        }
        for t in inner.type_stmts {
          let type_name = match t {
            @core.Stmt::EnumDef(name~, ..) => Some(name)
            @core.Stmt::TypeAlias(name~, ..) => Some(name)
            @core.Stmt::StructDef(name~, ..) => Some(name)
            _ => None
          }
          match type_name {
            Some(n) => if wanted.contains(n) { result.type_stmts.push(t) }
            None => ()
          }
        }
      }
      _ => ()
    }
  }
}

///|
fn bundle_for_wasm_impl(
  db : @runtime.VibeDb,
  path : String,
  ast : @core.Module,
  apply_dce~ : Bool,
  include_test_entries~ : Bool,
  keep_for_in_helpers~ : Bool,
) -> @core.Module {
  ensure_hooks()
  let import_alias_collisions = bundle_collect_import_alias_collisions(
    db, path, ast,
  )
  let main_ast = bundle_rewrite_import_aliases_with_skips(
    ast,
    bundle_collision_local_names(import_alias_collisions),
  )
  let collected_dep_stmts : Array[@core.Stmt] = []
  let visited : Map[String, Bool] = {}
  let entry_value_names = bundle_module_all_value_binder_names(main_ast)
  let entry_type_names = bundle_module_type_names(main_ast)
  // Collect all dependency definitions in topological order
  collect_dependency_defs_with_protected_names(
    db, path, collected_dep_stmts, visited, entry_value_names, entry_type_names,
  )
  let dep_stmts = bundle_drop_colliding_value_defs(
    collected_dep_stmts,
    bundle_collision_original_names(import_alias_collisions),
  )
  bundle_append_import_alias_collision_defs(
    db, import_alias_collisions, dep_stmts,
  )
  let bundled_stmts = dedupe_dependency_value_defs(dep_stmts)
  let existing_value_names : Map[String, Bool] = {}
  for stmt in bundled_stmts {
    match bundle_stmt_value_name(stmt) {
      Some(name) => existing_value_names[name] = true
      None => ()
    }
  }
  for stmt in main_ast.stmts {
    match bundle_stmt_value_name(stmt) {
      Some(name) => existing_value_names[name] = true
      None => ()
    }
  }
  // Include prelude function definitions so that higher-order functions
  // like array_map, array_filter, array_fold etc. are available in WASM.
  // These are defined as user-level .vibe code using primitive builtins
  // (array_builder, array_builder_push, etc.) that the WASM backend handles.
  // DCE will remove any prelude definitions that aren't actually used.
  // Snapshot non-prelude names before adding prelude stmts.
  // Used for surgical prelude DCE in --no-dce mode.
  let non_prelude_names : Array[String] = []
  for stmt in bundled_stmts {
    match bundle_stmt_value_name(stmt) {
      Some(name) => non_prelude_names.push(name)
      None => ()
    }
    match bundle_stmt_type_name(stmt) {
      Some(name) => non_prelude_names.push(name)
      None => ()
    }
  }
  for
    prelude_stmts in [
      @checker.prelude_core_value_stmts(),
      @checker.prelude_builtin_value_stmts(),
    ] {
    for stmt in prelude_stmts {
      match bundle_stmt_value_name(stmt) {
        Some(name) =>
          if !existing_value_names.contains(name) {
            bundled_stmts.push(stmt)
            existing_value_names[name] = true
          }
        None => ()
      }
    }
  }
  // Add main module statements (excluding imports and expanding re-exports)
  let main_stmts : Array[@core.Stmt] = []
  for stmt in main_ast.stmts {
    match stmt {
      @core.Stmt::Import(..) => () // Skip imports
      @core.Stmt::ReExport(spec~, source~, span=_) =>
        // Expand re-exports in main module
        collect_reexport_defs(
          db, path, spec, source, bundled_stmts, visited, entry_value_names, entry_type_names,
        )
      _ => main_stmts.push(stmt)
    }
  }
  // Topologically sort main module let-bindings so forward references
  // are evaluated after their dependencies (mirrors checker pre-scan).
  // Skip when interleaved side-effect statements exist (LetMut, Assign,
  // IndexAssign, or non-trailing Expr) to preserve evaluation order.
  let has_side_effects = {
    let len = main_stmts.length()
    let mut found = false
    for idx = 0; idx < len; idx = idx + 1 {
      match main_stmts[idx] {
        @core.Stmt::LetMut(..)
        | @core.Stmt::Assign(..)
        | @core.Stmt::IndexAssign(..) => {
          found = true
          break
        }
        @core.Stmt::Expr(..) =>
          if idx < len - 1 {
            found = true
            break
          }
        _ => ()
      }
    }
    found
  }
  let sorted_main = if has_side_effects {
    main_stmts
  } else {
    @core.topo_sort_let_stmts(main_stmts)
  }
  for stmt in sorted_main {
    match bundle_stmt_value_name(stmt) {
      Some(name) => non_prelude_names.push(name)
      None => ()
    }
    match bundle_stmt_type_name(stmt) {
      Some(name) => non_prelude_names.push(name)
      None => ()
    }
    bundled_stmts.push(stmt)
  }
  let bundled = @core.Module::{
    stmts: dedupe_bundle_structural_defs(bundled_stmts),
  }
  let after_dce = if apply_dce {
    if include_test_entries {
      @pipeline.dce_module_for_tests(bundled)
    } else if keep_for_in_helpers {
      @pipeline.dce_module(bundled)
    } else {
      @pipeline.dce_module_gc(bundled)
    }
  } else {
    // Without full DCE, still remove unused prelude functions to avoid
    // compiling ~30+ unused standard library functions per module.
    // All user/dependency names are kept as roots so only prelude is affected.
    @pipeline.dce_module_with_entry_names(bundled, non_prelude_names)
  }
  demote_unused_let_mut(after_dce)
}

///|
fn bundle_stmt_value_name(stmt : @core.Stmt) -> String? {
  match stmt {
    @core.Stmt::Let(name~, ..)
    | @core.Stmt::ExportLet(name~, ..)
    | @core.Stmt::InternalExportLet(name~, ..)
    | @core.Stmt::LetMut(name~, ..) => Some(name)
    _ => None
  }
}

///|
fn bundle_existing_value_names(stmts : Array[@core.Stmt]) -> Map[String, Bool] {
  let names : Map[String, Bool] = {}
  for stmt in stmts {
    match bundle_stmt_value_name(stmt) {
      Some(name) => names[name] = true
      None => ()
    }
    match stmt {
      @core.Stmt::EnumDef(ctors~, ..)
      | @core.Stmt::ExportEnumDef(ctors~, ..)
      | @core.Stmt::InternalExportEnumDef(ctors~, ..) =>
        for ctor in ctors {
          names[ctor.name] = true
        }
      _ => ()
    }
  }
  names
}

///|
fn bundle_existing_value_names_with_protected(
  stmts : Array[@core.Stmt],
  protected_value_names : Map[String, Bool],
) -> Map[String, Bool] {
  let names = bundle_existing_value_names(stmts)
  for name, _ in protected_value_names {
    names[name] = true
  }
  names
}

///|
fn bundle_collect_pattern_binder_names(
  names : Map[String, Bool],
  pat : @core.Pat,
) -> Unit {
  let bound : Map[String, Bool] = {}
  @core.bind_pattern_names_walker(bound, pat)
  for name, _ in bound {
    names[name] = true
  }
}

///|
fn bundle_collect_call_arg_binder_names(
  names : Map[String, Bool],
  args : Array[@core.CallArg],
) -> Unit {
  for arg in args {
    bundle_collect_expr_binder_names(names, arg.expr)
  }
}

///|
fn bundle_collect_expr_binder_names(
  names : Map[String, Bool],
  expr : @core.Expr,
) -> Unit {
  match expr {
    @core.Expr::StringInterp(parts~, ..) =>
      for part in parts {
        match part {
          @core.StringInterpPart::Expr(inner) =>
            bundle_collect_expr_binder_names(names, inner)
          @core.StringInterpPart::Lit(_) => ()
        }
      }
    @core.Expr::Call(args~, ..) =>
      bundle_collect_call_arg_binder_names(names, args)
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) =>
      for item in items {
        bundle_collect_expr_binder_names(names, item)
      }
    @core.Expr::TupleIndex(expr=inner, ..)
    | @core.Expr::Spread(expr=inner, ..) =>
      bundle_collect_expr_binder_names(names, inner)
    @core.Expr::Record(fields~, ..) =>
      for field in fields {
        bundle_collect_expr_binder_names(names, field.expr)
      }
    @core.Expr::Map(fields~, ..) =>
      for field in fields {
        bundle_collect_expr_binder_names(names, field.expr)
      }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      bundle_collect_expr_binder_names(names, cond)
      bundle_collect_module_binder_names(names, then_body)
      bundle_collect_module_binder_names(names, else_body)
    }
    @core.Expr::Block(body~, ..) =>
      bundle_collect_module_binder_names(names, body)
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      bundle_collect_expr_binder_names(names, scrutinee)
      for arm in arms {
        bundle_collect_pattern_binder_names(names, arm.pat)
        match arm.cond {
          Some(cond) => bundle_collect_expr_binder_names(names, cond)
          None => ()
        }
        bundle_collect_expr_binder_names(names, arm.expr)
      }
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, ..) => {
      names[value_name] = true
      match index_name {
        Some(name) => names[name] = true
        None => ()
      }
      bundle_collect_expr_binder_names(names, iterable)
      bundle_collect_module_binder_names(names, body)
    }
    @core.Expr::Fn(params~, body~, ..) => {
      for param in params {
        names[param.name] = true
      }
      bundle_collect_module_binder_names(names, body)
    }
    @core.Expr::While(cond~, body~, ..) => {
      bundle_collect_expr_binder_names(names, cond)
      bundle_collect_module_binder_names(names, body)
    }
    @core.Expr::Loop(params~, body~, ..) => {
      for param in params {
        names[param.name] = true
        bundle_collect_expr_binder_names(names, param.init)
      }
      bundle_collect_module_binder_names(names, body)
    }
    @core.Expr::Break(value~, ..) =>
      match value {
        Some(inner) => bundle_collect_expr_binder_names(names, inner)
        None => ()
      }
    @core.Expr::Continue(args~, ..) =>
      for arg in args {
        bundle_collect_expr_binder_names(names, arg)
      }
    @core.Expr::Yield(expr=inner, ..) =>
      bundle_collect_expr_binder_names(names, inner)
    @core.Expr::Handle(body~, arms~, ..) => {
      bundle_collect_module_binder_names(names, body)
      for arm in arms {
        bundle_collect_pattern_binder_names(names, arm.pat)
        match arm.cond {
          Some(cond) => bundle_collect_expr_binder_names(names, cond)
          None => ()
        }
        bundle_collect_expr_binder_names(names, arm.expr)
      }
    }
    @core.Expr::StructLit(fields~, ..) =>
      for field in fields {
        bundle_collect_expr_binder_names(names, field.expr)
      }
    @core.Expr::Perform(args~, ..) =>
      bundle_collect_call_arg_binder_names(names, args)
    @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::Char(..)
    | @core.Expr::String(..)
    | @core.Expr::Ident(..)
    | @core.Expr::Placeholder(..) => ()
  }
}

///|
fn bundle_collect_stmt_binder_names(
  names : Map[String, Bool],
  stmt : @core.Stmt,
) -> Unit {
  match stmt {
    @core.Stmt::Let(name~, expr~, ..)
    | @core.Stmt::ExportLet(name~, expr~, ..)
    | @core.Stmt::InternalExportLet(name~, expr~, ..)
    | @core.Stmt::LetMut(name~, expr~, ..) => {
      names[name] = true
      bundle_collect_expr_binder_names(names, expr)
    }
    @core.Stmt::ExternLet(name~, ..) => names[name] = true
    @core.Stmt::LetPat(pat~, expr~, ..) => {
      bundle_collect_pattern_binder_names(names, pat)
      bundle_collect_expr_binder_names(names, expr)
    }
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, ..) => {
      bundle_collect_pattern_binder_names(names, pat)
      bundle_collect_expr_binder_names(names, expr)
      bundle_collect_module_binder_names(names, else_body)
    }
    @core.Stmt::Assign(expr~, ..) =>
      bundle_collect_expr_binder_names(names, expr)
    @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      bundle_collect_expr_binder_names(names, target)
      bundle_collect_expr_binder_names(names, index)
      bundle_collect_expr_binder_names(names, value)
    }
    @core.Stmt::Expr(expr~, ..) => bundle_collect_expr_binder_names(names, expr)
    @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
      bundle_collect_module_binder_names(names, body)
    @core.Stmt::TraitImpl(methods~, ..) =>
      for impl_method in methods {
        bundle_collect_expr_binder_names(names, impl_method.expr)
      }
    @core.Stmt::EnumDef(ctors~, ..)
    | @core.Stmt::ExportEnumDef(ctors~, ..)
    | @core.Stmt::InternalExportEnumDef(ctors~, ..) =>
      for ctor in ctors {
        names[ctor.name] = true
      }
    @core.Stmt::Import(..)
    | @core.Stmt::TypeAlias(..)
    | @core.Stmt::TraitDef(..)
    | @core.Stmt::ExportTypeAlias(..)
    | @core.Stmt::InternalExportTypeAlias(..)
    | @core.Stmt::InternalTraitDef(..)
    | @core.Stmt::Export(..)
    | @core.Stmt::ReExport(..)
    | @core.Stmt::AliasDecl(..)
    | @core.Stmt::StructDef(..)
    | @core.Stmt::ExportStructDef(..)
    | @core.Stmt::InternalExportStructDef(..)
    | @core.Stmt::EffectDef(..)
    | @core.Stmt::ExportEffectDef(..) => ()
  }
}

///|
fn bundle_collect_module_binder_names(
  names : Map[String, Bool],
  ast : @core.Module,
) -> Unit {
  for stmt in ast.stmts {
    bundle_collect_stmt_binder_names(names, stmt)
  }
}

///|
fn bundle_module_all_value_binder_names(
  ast : @core.Module,
) -> Map[String, Bool] {
  let names : Map[String, Bool] = {}
  bundle_collect_module_binder_names(names, ast)
  names
}

///|
fn bundle_existing_type_names(stmts : Array[@core.Stmt]) -> Map[String, Bool] {
  let names : Map[String, Bool] = {}
  for stmt in stmts {
    match bundle_stmt_type_name(stmt) {
      Some(name) => names[name] = true
      None => ()
    }
  }
  names
}

///|
fn bundle_existing_type_names_with_protected(
  stmts : Array[@core.Stmt],
  protected_type_names : Map[String, Bool],
) -> Map[String, Bool] {
  let names = bundle_existing_type_names(stmts)
  for name, _ in protected_type_names {
    names[name] = true
  }
  names
}

///|
fn bundle_module_type_names(ast : @core.Module) -> Map[String, Bool] {
  let names : Map[String, Bool] = {}
  for stmt in ast.stmts {
    match bundle_stmt_type_name(stmt) {
      Some(name) => names[name] = true
      None => ()
    }
  }
  names
}

///|
fn collect_dependency_defs_with_protected_names(
  db : @runtime.VibeDb,
  path : String,
  out : Array[@core.Stmt],
  visited : Map[String, Bool],
  protected_value_names : Map[String, Bool],
  protected_type_names : Map[String, Bool],
) -> Unit {
  if visited.contains(path) {
    return
  }
  let is_entry = visited.length() == 0
  visited[path] = true
  let imports = db.imports(path)
  // First, recursively process dependencies
  for imp in imports {
    collect_dependency_defs_with_protected_names(
      db,
      imp.path,
      out,
      visited,
      protected_value_names,
      protected_type_names,
    )
  }
  // Then add definitions from this module (if it's an imported module)
  // Skip the entry module itself (it will be added separately)
  if !is_entry {
    let existing_values = bundle_existing_value_names_with_protected(
      out, protected_value_names,
    )
    let existing_types = bundle_existing_type_names_with_protected(
      out, protected_type_names,
    )
    let dep_ast = namespace_private_module_defs_for_existing_names(
      path,
      bundle_rewrite_import_aliases(db.ast_with_hash_imports(path)),
      existing_values,
      existing_types,
    )
    let emitted_types = bundle_existing_type_names_with_protected(
      out, protected_type_names,
    )
    for stmt in dep_ast.stmts {
      match stmt {
        // Convert exports to regular definitions
        @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
          out.push(@core.Stmt::Let(rec~, name~, expr~, span~))
        @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
          if !emitted_types.contains(name) {
            out.push(@core.Stmt::EnumDef(name~, params~, ctors~, span~))
            emitted_types[name] = true
          }
        @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
          if !emitted_types.contains(name) {
            out.push(@core.Stmt::TypeAlias(name~, params~, target~, span~))
            emitted_types[name] = true
          }
        // Also include non-exported definitions that exported ones might depend on
        @core.Stmt::Let(..) => out.push(stmt)
        @core.Stmt::EnumDef(name~, ..) =>
          if !emitted_types.contains(name) {
            out.push(stmt)
            emitted_types[name] = true
          }
        @core.Stmt::TypeAlias(name~, ..) =>
          if !emitted_types.contains(name) {
            out.push(stmt)
            emitted_types[name] = true
          }
        // Handle re-exports: fetch definitions from source module
        @core.Stmt::ReExport(spec~, source~, span=_) =>
          collect_reexport_defs(
            db, path, spec, source, out, visited, protected_value_names, protected_type_names,
          )
        // Skip imports and exports in dependencies
        @core.Stmt::Import(..) | @core.Stmt::Export(..) => ()
        // Skip tests from dependencies
        @core.Stmt::Test(..) | @core.Stmt::Bench(..) => ()
        // Keep trait defs/impls so bundle-time typecheck can resolve bounds.
        @core.Stmt::TraitDef(..)
        | @core.Stmt::TraitImpl(..)
        | @core.Stmt::InternalTraitDef(..) => out.push(stmt)
        // Include mutable variable definitions
        @core.Stmt::LetMut(..) => out.push(stmt)
        // Other statements are passed through
        _ => out.push(stmt)
      }
    }
  }
}

///|
fn bundle_stmt_type_name(stmt : @core.Stmt) -> String? {
  match stmt {
    @core.Stmt::EnumDef(name~, ..)
    | @core.Stmt::ExportEnumDef(name~, ..)
    | @core.Stmt::TypeAlias(name~, ..)
    | @core.Stmt::ExportTypeAlias(name~, ..)
    | @core.Stmt::StructDef(name~, ..)
    | @core.Stmt::ExportStructDef(name~, ..) => Some(name)
    _ => None
  }
}

///|
fn dedupe_bundle_structural_defs(
  stmts : Array[@core.Stmt],
) -> Array[@core.Stmt] {
  let out : Array[@core.Stmt] = []
  let seen_type_names : Map[String, Bool] = {}
  for stmt in stmts {
    match bundle_stmt_type_name(stmt) {
      Some(name) =>
        if !seen_type_names.contains(name) {
          out.push(stmt)
          seen_type_names[name] = true
        }
      None => out.push(stmt)
    }
  }
  out
}

///|
fn dedupe_dependency_value_defs(stmts : Array[@core.Stmt]) -> Array[@core.Stmt] {
  let out : Array[@core.Stmt] = []
  let seen_value_names : Map[String, Bool] = {}
  for stmt in stmts {
    match bundle_stmt_value_name(stmt) {
      Some(name) =>
        if !seen_value_names.contains(name) {
          out.push(stmt)
          seen_value_names[name] = true
        }
      None => out.push(stmt)
    }
  }
  out
}

///|
/// Collect definitions for re-export statement.
fn collect_reexport_defs(
  db : @runtime.VibeDb,
  owner_path : String,
  spec : @core.ImportSpec,
  source : @core.ModuleRef,
  out : Array[@core.Stmt],
  visited : Map[String, Bool],
  protected_value_names : Map[String, Bool],
  protected_type_names : Map[String, Bool],
) -> Unit {
  let normalize_hash_ref = fn(hash : String) {
    if hash.has_prefix("#") && hash.length() > 1 {
      hash.unsafe_substring(start=1, end=hash.length())
    } else {
      hash
    }
  }
  let base_dir = @path.Path(owner_path).dirname().to_string()
  let resolved_from_imports = fn() -> String? {
    for imp in db.imports(owner_path) {
      if @runtime.import_stmt_matches_spec(base_dir, source, imp) {
        return Some(imp.path)
      }
    }
    None
  }
  // Resolve source module path
  let source_path = match source {
    @core.ModuleRef::Path(path~) =>
      match resolved_from_imports() {
        Some(resolved) => resolved
        None =>
          if path.has_prefix("/") {
            path
          } else {
            @path.Path(base_dir).join(@path.Path(path)).normalize().to_string()
          }
      }
    @core.ModuleRef::Hash(hash~) => "__hash__/" + normalize_hash_ref(hash)
    @core.ModuleRef::Version(name~) =>
      match db.get_source("__ref__/version/" + name) {
        Some(hash_text) => "__hash__/" + normalize_hash_ref(hash_text)
        None => "__missing__/version/" + name
      }
    @core.ModuleRef::Symbol(name~) =>
      match db.get_source("__ref__/symbol/" + name) {
        Some(hash_text) => "__hash__/" + normalize_hash_ref(hash_text)
        None => "__missing__/symbol/" + name
      }
    @core.ModuleRef::Alias(name~) => "__alias__/" + name
    @core.ModuleRef::PinnedPath(path=_, hash~) =>
      "__hash__/" + normalize_hash_ref(hash)
  }
  // Recursively process the source module's dependencies first
  collect_dependency_defs_with_protected_names(
    db, source_path, out, visited, protected_value_names, protected_type_names,
  )
  // Get the source module AST
  let source_ast = db.ast_with_hash_imports(source_path)
  let requested_items : Map[String, Array[@core.ImportItem]] = {}
  for item in spec.items {
    match requested_items.get(item.name) {
      Some(items) => items.push(item)
      None => requested_items[item.name] = [item]
    }
  }
  let append_value_aliases = fn(source_name : String, span : @core.Span) {
    match requested_items.get(source_name) {
      Some(items) =>
        for item in items {
          let export_name = @core.import_item_local_name(item)
          if item.kind == @core.ImportKind::Value && export_name != source_name {
            out.push(
              @core.Stmt::Let(
                rec=false,
                name=export_name,
                expr=@core.Expr::Ident(name=source_name, span~),
                span~,
              ),
            )
          }
        }
      None => ()
    }
  }
  // Track already-emitted types to avoid duplicates
  let emitted_types = bundle_existing_type_names_with_protected(
    out, protected_type_names,
  )
  // Extract matching definitions from source module
  for stmt in source_ast.stmts {
    match stmt {
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
        if requested_items.contains(name) {
          out.push(@core.Stmt::Let(rec~, name~, expr~, span~))
          append_value_aliases(name, span)
        }
      @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
        if requested_items.contains(name) && !emitted_types.contains(name) {
          out.push(@core.Stmt::EnumDef(name~, params~, ctors~, span~))
          emitted_types[name] = true
        }
      @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
        if requested_items.contains(name) && !emitted_types.contains(name) {
          out.push(@core.Stmt::TypeAlias(name~, params~, target~, span~))
          emitted_types[name] = true
        }
      @core.Stmt::Let(rec~, name~, expr~, span~) =>
        if requested_items.contains(name) {
          out.push(@core.Stmt::Let(rec~, name~, expr~, span~))
          append_value_aliases(name, span)
        }
      @core.Stmt::EnumDef(name~, params~, ctors~, span~) =>
        if requested_items.contains(name) && !emitted_types.contains(name) {
          out.push(@core.Stmt::EnumDef(name~, params~, ctors~, span~))
          emitted_types[name] = true
        }
      @core.Stmt::TypeAlias(name~, params~, target~, span~) =>
        if requested_items.contains(name) && !emitted_types.contains(name) {
          out.push(@core.Stmt::TypeAlias(name~, params~, target~, span~))
          emitted_types[name] = true
        }
      @core.Stmt::ExportStructDef(name~, params~, fields~, span~) =>
        if requested_items.contains(name) && !emitted_types.contains(name) {
          out.push(@core.Stmt::StructDef(name~, params~, fields~, span~))
          emitted_types[name] = true
        }
      @core.Stmt::StructDef(name~, params~, fields~, span~) =>
        if requested_items.contains(name) && !emitted_types.contains(name) {
          out.push(@core.Stmt::StructDef(name~, params~, fields~, span~))
          emitted_types[name] = true
        }
      @core.Stmt::TraitDef(
        name~,
        supertraits~,
        methods~,
        open_impl~,
        exported~,
        span~
      ) =>
        if requested_items.contains(name) {
          out.push(
            @core.Stmt::TraitDef(
              name~,
              supertraits~,
              methods~,
              open_impl~,
              exported~,
              span~,
            ),
          )
        }
      _ => ()
    }
  }
}

///|
/// Demote `let mut` bindings that are never assigned to into plain `let`.
/// This prevents unnecessary ref cell allocation when captured by closures.
fn demote_unused_let_mut(mod_ : @core.Module) -> @core.Module {
  let assigned : Map[String, Bool] = {}
  collect_all_assign_targets_block(mod_, assigned)
  let mut changed = false
  let new_stmts : Array[@core.Stmt] = []
  for stmt in mod_.stmts {
    match stmt {
      @core.Stmt::LetMut(name~, expr~, span~) =>
        if !assigned.contains(name) {
          new_stmts.push(@core.Stmt::Let(rec=false, name~, expr~, span~))
          changed = true
        } else {
          new_stmts.push(stmt)
        }
      _ => new_stmts.push(stmt)
    }
  }
  if changed {
    @core.Module::{ stmts: new_stmts }
  } else {
    mod_
  }
}

///|
fn collect_all_assign_targets_block(
  body : @core.Module,
  out : Map[String, Bool],
) -> Unit {
  for stmt in body.stmts {
    collect_all_assign_targets_stmt(stmt, out)
  }
}

///|
fn collect_all_assign_targets_stmt(
  stmt : @core.Stmt,
  out : Map[String, Bool],
) -> Unit {
  match stmt {
    @core.Stmt::Assign(name~, expr~, ..) => {
      out[name] = true
      collect_all_assign_targets_expr(expr, out)
    }
    @core.Stmt::Let(expr~, ..)
    | @core.Stmt::ExportLet(expr~, ..)
    | @core.Stmt::InternalExportLet(expr~, ..)
    | @core.Stmt::LetMut(expr~, ..) =>
      collect_all_assign_targets_expr(expr, out)
    @core.Stmt::Expr(expr~, ..) => collect_all_assign_targets_expr(expr, out)
    @core.Stmt::LetPat(expr~, ..) => collect_all_assign_targets_expr(expr, out)
    @core.Stmt::LetPatElse(expr~, else_body~, ..) => {
      collect_all_assign_targets_expr(expr, out)
      collect_all_assign_targets_block(else_body, out)
    }
    @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      collect_all_assign_targets_expr(target, out)
      collect_all_assign_targets_expr(index, out)
      collect_all_assign_targets_expr(value, out)
    }
    @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
      collect_all_assign_targets_block(body, out)
    _ => ()
  }
}

///|
fn collect_all_assign_targets_expr(
  expr : @core.Expr,
  out : Map[String, Bool],
) -> Unit {
  match expr {
    @core.Expr::Call(args~, ..) =>
      for arg in args {
        collect_all_assign_targets_expr(arg.expr, out)
      }
    @core.Expr::Tuple(items~, ..) =>
      for item in items {
        collect_all_assign_targets_expr(item, out)
      }
    @core.Expr::TupleIndex(expr~, ..) =>
      collect_all_assign_targets_expr(expr, out)
    @core.Expr::Record(fields~, ..) =>
      for f in fields {
        collect_all_assign_targets_expr(f.expr, out)
      }
    @core.Expr::StructLit(fields~, ..) =>
      for f in fields {
        collect_all_assign_targets_expr(f.expr, out)
      }
    @core.Expr::Array(items~, ..) =>
      for item in items {
        collect_all_assign_targets_expr(item, out)
      }
    @core.Expr::Map(fields~, ..) =>
      for f in fields {
        collect_all_assign_targets_expr(f.expr, out)
      }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      collect_all_assign_targets_expr(cond, out)
      collect_all_assign_targets_block(then_body, out)
      collect_all_assign_targets_block(else_body, out)
    }
    @core.Expr::Block(body~, ..) => collect_all_assign_targets_block(body, out)
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      collect_all_assign_targets_expr(scrutinee, out)
      for arm in arms {
        collect_all_assign_targets_expr(arm.expr, out)
        match arm.cond {
          Some(c) => collect_all_assign_targets_expr(c, out)
          None => ()
        }
      }
    }
    @core.Expr::Handle(body~, arms~, ..) => {
      collect_all_assign_targets_block(body, out)
      for arm in arms {
        collect_all_assign_targets_expr(arm.expr, out)
        match arm.cond {
          Some(c) => collect_all_assign_targets_expr(c, out)
          None => ()
        }
      }
    }
    @core.Expr::Fn(body~, ..) => collect_all_assign_targets_block(body, out)
    @core.Expr::While(cond~, body~, ..) => {
      collect_all_assign_targets_expr(cond, out)
      collect_all_assign_targets_block(body, out)
    }
    @core.Expr::Loop(params~, body~, ..) => {
      for p in params {
        collect_all_assign_targets_expr(p.init, out)
      }
      collect_all_assign_targets_block(body, out)
    }
    @core.Expr::Yield(expr~, ..) => collect_all_assign_targets_expr(expr, out)
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let desugared = if @core.is_string_for_in(span.start) {
        @core.desugar_for_in_string(
          value_name, index_name, iterable, body, span,
        )
      } else {
        @core.desugar_for_in(value_name, index_name, iterable, body, span)
      }
      collect_all_assign_targets_block(desugared, out)
    }
    _ => ()
  }
}
