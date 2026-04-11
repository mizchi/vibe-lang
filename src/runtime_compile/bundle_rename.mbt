///|
/// Per-module renaming pass for bundler name collision protection.
///
/// See issue #287: multiple vibe source files can define non-exported
/// let-bindings with the same name but different bodies. The old bundler
/// deduplicated by name only via `dedupe_dependency_value_defs`, so one
/// definition would silently win and the other's references would
/// dispatch to the wrong function. The classic case was
/// `lookup_string_group_a` defined in both
/// `vibe/compiler/checker/builtins_string1.vibe` and
/// `builtins_string2.vibe` with different bodies, causing
/// `lookup_string2` to call string1's helper and return None for every
/// string2 method lookup (#287 builtins_test 6/62 failures).
///
/// Strategy: during `collect_dependency_defs`, scan the candidate module
/// for non-exported `Stmt::Let` names that are either:
///   (a) already emitted by a previous module with a structurally
///       distinct body — in which case we rename the current module's
///       copy with a source-path-prefixed tag; or
///   (b) a fresh name not yet emitted — no rename needed.
///
/// The rename is applied both to the `Stmt::Let` definition and to every
/// `Expr::Ident(name)` / `Expr::Call(name, ..)` / `Stmt::Assign(name, ..)`
/// reference in the SAME module's statements.  Scoped local bindings that
/// shadow the renamed name are left alone (full `WalkerScope` tracking).
///
/// Exported names (`ExportLet`, `InternalExportLet`, `ExportEnumDef`,
/// etc.) are never renamed because they form the module's public API and
/// cross-module references rely on stable symbols.

///|
/// Build a rename for a non-exported let-binding that collides at bundle
/// time.  The tag is derived from the source file's basename so that
/// debugging stack traces keep enough context.
fn mangle_internal_name(module_path : String, name : String) -> String {
  // Strip directory + ".vibe" extension
  let mut start = 0
  let mut i = module_path.length() - 1
  while i >= 0 {
    let ch = module_path[i]
    if ch == '/' {
      start = i + 1
      break
    }
    i = i - 1
  }
  let mut end = module_path.length()
  if module_path.has_suffix(".vibe") {
    end = module_path.length() - 5
  }
  let base = if start < end {
    module_path.unsafe_substring(start~, end~)
  } else {
    "anon"
  }
  // Replace any path-unfriendly chars with `_` for wasm symbol safety.
  // (Basenames are usually safe already, but belt-and-braces.)
  let buf = StringBuilder::new()
  for ch in base {
    if (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '_' {
      buf.write_char(ch)
    } else {
      buf.write_char('_')
    }
  }
  "__m_" + buf.to_string() + "__" + name
}

///|
/// Compute a cheap structural hash of an expression for body-equivalence
/// checking.  Two Lets with the same name and hash-equal bodies are
/// deduplicated; same name and different bodies triggers a rename.
fn expr_body_hash(expr : @core.Expr) -> String {
  // `@core.structural_hash` would be ideal but isn't exposed here; fall
  // back to `Show`-serialization of the expression which is stable
  // modulo spans.  We strip the span suffix "(span: ...)" patterns so
  // span variation across parse runs doesn't defeat dedup.  This is
  // only used as a fast-path equality check — when it collides we
  // conservatively rename, so a weak hash is fine.
  expr.to_string()
}

///|
/// Collect the module-local `let` names that must be renamed in `dep_stmts`
/// because they collide with a previously emitted let in `out_stmts`.
///
/// Returns a rename map: original-name -> mangled-name.  Non-colliding
/// non-exported lets and all exported definitions are left alone and do
/// NOT appear in the map.
fn compute_module_rename_map(
  dep_stmts : Array[@core.Stmt],
  out_stmts : Array[@core.Stmt],
  module_path : String,
) -> Map[String, String] {
  // Gather the body hashes of already-emitted Lets (and Let-downgraded
  // ExportLets) from `out_stmts`.
  let emitted : Map[String, String] = {}
  for stmt in out_stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..)
      | @core.Stmt::ExportLet(name~, expr~, ..)
      | @core.Stmt::InternalExportLet(name~, expr~, ..) =>
        if not(emitted.contains(name)) {
          emitted[name] = expr_body_hash(expr)
        }
      _ => ()
    }
  }
  let rename_map : Map[String, String] = {}
  for stmt in dep_stmts {
    match stmt {
      // Only non-exported Lets are eligible for rename.  Exported names
      // form the module's public API and must stay stable for other
      // modules to resolve them.
      @core.Stmt::Let(name~, expr~, ..) =>
        match emitted.get(name) {
          Some(prev_hash) => {
            let this_hash = expr_body_hash(expr)
            if prev_hash != this_hash {
              rename_map[name] = mangle_internal_name(module_path, name)
            }
          }
          None => ()
        }
      _ => ()
    }
  }
  rename_map
}

///|
/// Rewrite references to renamed names inside an expression, respecting
/// `let`/param/pattern shadowing via a `WalkerScope`.
fn rewrite_expr_rename(
  expr : @core.Expr,
  rename_map : Map[String, String],
  bound : @core.WalkerScope,
) -> @core.Expr {
  match expr {
    @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::Char(..)
    | @core.Expr::String(..)
    | @core.Expr::Placeholder(..) => expr
    @core.Expr::Ident(name~, span~) =>
      if bound.contains(name) {
        expr
      } else {
        match rename_map.get(name) {
          Some(new_name) => @core.Expr::Ident(name=new_name, span~)
          None => expr
        }
      }
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let new_name = if bound.contains(name) {
        name
      } else {
        match rename_map.get(name) {
          Some(n) => n
          None => name
        }
      }
      let new_args : Array[@core.CallArg] = []
      for arg in args {
        new_args.push(
          @core.CallArg::{
            label: arg.label,
            expr: rewrite_expr_rename(arg.expr, rename_map, bound),
            span: arg.span,
          },
        )
      }
      @core.Expr::Call(name=new_name, type_args~, args=new_args, span~)
    }
    @core.Expr::Tuple(items~, span~) => {
      let new_items : Array[@core.Expr] = []
      for item in items {
        new_items.push(rewrite_expr_rename(item, rename_map, bound))
      }
      @core.Expr::Tuple(items=new_items, span~)
    }
    @core.Expr::TupleIndex(expr=inner, index~, span~) =>
      @core.Expr::TupleIndex(
        expr=rewrite_expr_rename(inner, rename_map, bound),
        index~,
        span~,
      )
    @core.Expr::Record(fields~, span~) => {
      let new_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        new_fields.push(
          @core.RecordFieldExpr::{
            name: field.name,
            expr: rewrite_expr_rename(field.expr, rename_map, bound),
            span: field.span,
          },
        )
      }
      @core.Expr::Record(fields=new_fields, span~)
    }
    @core.Expr::StructLit(name~, type_args~, fields~, span~) => {
      let new_name = if bound.contains(name) {
        name
      } else {
        match rename_map.get(name) {
          Some(n) => n
          None => name
        }
      }
      let new_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        new_fields.push(
          @core.RecordFieldExpr::{
            name: field.name,
            expr: rewrite_expr_rename(field.expr, rename_map, bound),
            span: field.span,
          },
        )
      }
      @core.Expr::StructLit(name=new_name, type_args~, fields=new_fields, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let new_items : Array[@core.Expr] = []
      for item in items {
        new_items.push(rewrite_expr_rename(item, rename_map, bound))
      }
      @core.Expr::Array(items=new_items, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let new_fields : Array[@core.MapFieldExpr] = []
      for field in fields {
        new_fields.push(
          @core.MapFieldExpr::{
            key: field.key,
            expr: rewrite_expr_rename(field.expr, rename_map, bound),
            span: field.span,
          },
        )
      }
      @core.Expr::Map(fields=new_fields, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=rewrite_expr_rename(cond, rename_map, bound),
        then_body=rewrite_block_rename(then_body, rename_map, bound),
        else_body=rewrite_block_rename(else_body, rename_map, bound),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(
        body=rewrite_block_rename(body, rename_map, bound),
        span~,
      )
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let new_scrutinee = rewrite_expr_rename(scrutinee, rename_map, bound)
      let new_arms : Array[@core.MatchArm] = []
      for arm in arms {
        let arm_bound = bound.child()
        @core.bind_pattern_names_scope(arm_bound, arm.pat)
        let new_cond = match arm.cond {
          Some(cond) => Some(rewrite_expr_rename(cond, rename_map, arm_bound))
          None => None
        }
        let new_expr = rewrite_expr_rename(arm.expr, rename_map, arm_bound)
        new_arms.push(
          @core.MatchArm::{
            pat: arm.pat,
            cond: new_cond,
            expr: new_expr,
            span: arm.span,
          },
        )
      }
      @core.Expr::Match(scrutinee=new_scrutinee, arms=new_arms, span~)
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let new_iter = rewrite_expr_rename(iterable, rename_map, bound)
      let for_bound = bound.child()
      for_bound.bindings[value_name] = true
      match index_name {
        Some(idx) => for_bound.bindings[idx] = true
        None => ()
      }
      let new_body = rewrite_block_rename(body, rename_map, for_bound)
      @core.Expr::ForIn(
        value_name~,
        index_name~,
        iterable=new_iter,
        body=new_body,
        span~,
      )
    }
    @core.Expr::Fn(
      type_params~, type_bounds~, params~, ret~, effects~, body~, span~
    ) => {
      let fn_bound = bound.child()
      for param in params {
        fn_bound.bindings[param.name] = true
      }
      let new_body = rewrite_block_rename(body, rename_map, fn_bound)
      @core.Expr::Fn(
        type_params~, type_bounds~, params~, ret~, effects~, body=new_body, span~,
      )
    }
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=rewrite_expr_rename(cond, rename_map, bound),
        body=rewrite_block_rename(body, rename_map, bound),
        span~,
      )
    @core.Expr::Loop(params~, body~, span~) => {
      let loop_bound = bound.child()
      let new_params : Array[@core.LoopParam] = []
      for param in params {
        let new_init = rewrite_expr_rename(param.init, rename_map, bound)
        new_params.push(
          @core.LoopParam::{ name: param.name, init: new_init, span: param.span },
        )
        loop_bound.bindings[param.name] = true
      }
      @core.Expr::Loop(
        params=new_params,
        body=rewrite_block_rename(body, rename_map, loop_bound),
        span~,
      )
    }
    @core.Expr::Break(value~, span~) => {
      let new_value = match value {
        Some(e) => Some(rewrite_expr_rename(e, rename_map, bound))
        None => None
      }
      @core.Expr::Break(value=new_value, span~)
    }
    @core.Expr::Continue(args~, span~) => {
      let new_args : Array[@core.Expr] = []
      for arg in args {
        new_args.push(rewrite_expr_rename(arg, rename_map, bound))
      }
      @core.Expr::Continue(args=new_args, span~)
    }
    @core.Expr::Yield(expr=inner, span~) =>
      @core.Expr::Yield(
        expr=rewrite_expr_rename(inner, rename_map, bound),
        span~,
      )
    @core.Expr::Handle(body~, arms~, span~) => {
      let new_body = rewrite_block_rename(body, rename_map, bound)
      let new_arms : Array[@core.MatchArm] = []
      for arm in arms {
        let arm_bound = bound.child()
        @core.bind_pattern_names_scope(arm_bound, arm.pat)
        let new_cond = match arm.cond {
          Some(cond) => Some(rewrite_expr_rename(cond, rename_map, arm_bound))
          None => None
        }
        let new_expr = rewrite_expr_rename(arm.expr, rename_map, arm_bound)
        new_arms.push(
          @core.MatchArm::{
            pat: arm.pat,
            cond: new_cond,
            expr: new_expr,
            span: arm.span,
          },
        )
      }
      @core.Expr::Handle(body=new_body, arms=new_arms, span~)
    }
    @core.Expr::Spread(expr=inner, span~) =>
      @core.Expr::Spread(
        expr=rewrite_expr_rename(inner, rename_map, bound),
        span~,
      )
    @core.Expr::Perform(effect_name~, op_name~, args~, span~) => {
      let new_args : Array[@core.CallArg] = []
      for arg in args {
        new_args.push(
          @core.CallArg::{
            label: arg.label,
            expr: rewrite_expr_rename(arg.expr, rename_map, bound),
            span: arg.span,
          },
        )
      }
      @core.Expr::Perform(effect_name~, op_name~, args=new_args, span~)
    }
    @core.Expr::StringInterp(parts~, span~) => {
      let new_parts : Array[@core.StringInterpPart] = []
      for part in parts {
        match part {
          @core.StringInterpPart::Expr(e) =>
            new_parts.push(
              @core.StringInterpPart::Expr(
                rewrite_expr_rename(e, rename_map, bound),
              ),
            )
          @core.StringInterpPart::Lit(s) =>
            new_parts.push(@core.StringInterpPart::Lit(s))
        }
      }
      @core.Expr::StringInterp(parts=new_parts, span~)
    }
  }
}

///|
/// Rewrite a block (Module) under a fresh child scope.
fn rewrite_block_rename(
  body : @core.Module,
  rename_map : Map[String, String],
  bound : @core.WalkerScope,
) -> @core.Module {
  let scope = bound.child()
  let new_stmts : Array[@core.Stmt] = []
  for stmt in body.stmts {
    new_stmts.push(rewrite_stmt_rename(stmt, rename_map, scope))
  }
  @core.Module::{ stmts: new_stmts }
}

///|
/// Rewrite a single statement, mutating `scope` so that bound names
/// shadow renames inside subsequent expressions within the same block.
fn rewrite_stmt_rename(
  stmt : @core.Stmt,
  rename_map : Map[String, String],
  scope : @core.WalkerScope,
) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      if rec {
        scope.bindings[name] = true
      }
      let new_expr = rewrite_expr_rename(expr, rename_map, scope)
      if not(rec) {
        scope.bindings[name] = true
      }
      @core.Stmt::Let(rec~, name~, expr=new_expr, span~)
    }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
      if rec {
        scope.bindings[name] = true
      }
      let new_expr = rewrite_expr_rename(expr, rename_map, scope)
      if not(rec) {
        scope.bindings[name] = true
      }
      @core.Stmt::ExportLet(rec~, name~, expr=new_expr, span~)
    }
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) => {
      if rec {
        scope.bindings[name] = true
      }
      let new_expr = rewrite_expr_rename(expr, rename_map, scope)
      if not(rec) {
        scope.bindings[name] = true
      }
      @core.Stmt::InternalExportLet(rec~, name~, expr=new_expr, span~)
    }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let new_expr = rewrite_expr_rename(expr, rename_map, scope)
      scope.bindings[name] = true
      @core.Stmt::LetMut(name~, expr=new_expr, span~)
    }
    @core.Stmt::Assign(name~, expr~, span~) => {
      let new_name = if scope.contains(name) {
        name
      } else {
        match rename_map.get(name) {
          Some(n) => n
          None => name
        }
      }
      let new_expr = rewrite_expr_rename(expr, rename_map, scope)
      @core.Stmt::Assign(name=new_name, expr=new_expr, span~)
    }
    @core.Stmt::IndexAssign(target~, index~, value~, span~) =>
      @core.Stmt::IndexAssign(
        target=rewrite_expr_rename(target, rename_map, scope),
        index=rewrite_expr_rename(index, rename_map, scope),
        value=rewrite_expr_rename(value, rename_map, scope),
        span~,
      )
    @core.Stmt::LetPat(pat~, expr~, span~) => {
      let new_expr = rewrite_expr_rename(expr, rename_map, scope)
      @core.bind_pattern_names_scope(scope, pat)
      @core.Stmt::LetPat(pat~, expr=new_expr, span~)
    }
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
      let new_expr = rewrite_expr_rename(expr, rename_map, scope)
      let new_else = rewrite_block_rename(else_body, rename_map, scope)
      @core.bind_pattern_names_scope(scope, pat)
      @core.Stmt::LetPatElse(pat~, expr=new_expr, else_body=new_else, span~)
    }
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(
        expr=rewrite_expr_rename(expr, rename_map, scope),
        span~,
      )
    @core.Stmt::Test(name~, body~, span~) =>
      @core.Stmt::Test(
        name~,
        body=rewrite_block_rename(body, rename_map, scope),
        span~,
      )
    @core.Stmt::Bench(name~, body~, span~) =>
      @core.Stmt::Bench(
        name~,
        body=rewrite_block_rename(body, rename_map, scope),
        span~,
      )
    // Type-level declarations and non-value statements are untouched:
    // the rename pass only affects value-binding names and their
    // references in expression context.
    _ => stmt
  }
}

///|
/// Apply `rename_map` to an entire module's statement list, renaming both
/// definitions and references.  The top-level scope starts empty so every
/// free reference in the module body is a candidate for rename (subject
/// to shadowing detected during the walk).
fn apply_module_rename(
  stmts : Array[@core.Stmt],
  rename_map : Map[String, String],
) -> Array[@core.Stmt] {
  // Top-level module statements are processed with an *empty* scope for
  // each stmt: we deliberately do NOT accumulate top-level let names
  // across the loop, because those are the bindings being renamed. If
  // we pre-bound them into the walker's scope, the inner expression
  // walker would treat every later reference to `helper` as a
  // "shadowed" local and skip the rename — which defeats the whole
  // pass.  Scope tracking still fires for lexical bindings *inside*
  // each top-level expression (let inside a function body, match pat,
  // for-in iter var, etc.) — see `rewrite_expr_rename` / Fn / Match /
  // ForIn / Let(inner) cases.
  let rewritten : Array[@core.Stmt] = []
  for stmt in stmts {
    let fresh_scope = @core.WalkerScope::new()
    let with_body_rewritten = rewrite_stmt_rename(
      stmt, rename_map, fresh_scope,
    )
    let with_name_rewritten = match with_body_rewritten {
      @core.Stmt::Let(rec~, name~, expr~, span~) =>
        match rename_map.get(name) {
          Some(new_name) =>
            @core.Stmt::Let(rec~, name=new_name, expr~, span~)
          None => with_body_rewritten
        }
      @core.Stmt::LetMut(name~, expr~, span~) =>
        match rename_map.get(name) {
          Some(new_name) =>
            @core.Stmt::LetMut(name=new_name, expr~, span~)
          None => with_body_rewritten
        }
      _ => with_body_rewritten
    }
    rewritten.push(with_name_rewritten)
  }
  rewritten
}
