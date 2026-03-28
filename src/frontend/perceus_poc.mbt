///|
/// Perceus reference counting analysis.
///
/// Two implementations:
/// 1. `build_perceus_plan_poc` — original PoC, linear (non-branch-sensitive)
/// 2. `build_perceus_plan` — full implementation with:
///    - branch-sensitive dup/drop (if/else, match arms)
///    - scope-end drops for bindings that leave scope with live references
///    - reuse tokens for in-place constructor update optimization
///    - proper loop/for-in handling
pub enum PerceusActionKind {
  Dup
  Drop
} derive(Show, Eq)

///|
pub struct PerceusAction {
  site : String
  kind : PerceusActionKind
  name : String
} derive(Show, Eq)

///|
priv struct PerceusScope {
  name_index : Map[String, Array[Int]]
}

///|
priv struct PerceusCountCtx {
  mut next_binding_id : Int
  binding_names : Map[Int, String]
  use_counts : Map[Int, Int]
}

///|
priv struct PerceusEmitCtx {
  mut next_binding_id : Int
  remaining_uses : Map[Int, Int]
  actions : Array[PerceusAction]
}

///|
fn perceus_scope_new() -> PerceusScope {
  { name_index: {} }
}

///|
fn perceus_scope_declare(
  scopes : Array[PerceusScope],
  name : String,
  id : Int,
) -> Unit {
  if scopes.length() == 0 {
    return
  }
  let idx = scopes.length() - 1
  let scope = scopes[idx]
  match scope.name_index.get(name) {
    Some(ids) => {
      ids.push(id)
      scope.name_index[name] = ids
    }
    None => scope.name_index[name] = [id]
  }
  scopes[idx] = scope
}

///|
fn perceus_scope_lookup(scopes : Array[PerceusScope], name : String) -> Int? {
  let mut i = scopes.length()
  while i > 0 {
    i -= 1
    let scope = scopes[i]
    match scope.name_index.get(name) {
      Some(ids) => if ids.length() > 0 { return Some(ids[ids.length() - 1]) }
      None => ()
    }
  }
  None
}

///|
fn perceus_local_scope_lookup(
  scopes : Array[Map[String, Bool]],
  name : String,
) -> Bool {
  let mut i = scopes.length()
  while i > 0 {
    i -= 1
    let scope = scopes[i]
    if scope.contains(name) {
      return true
    }
  }
  false
}

///|
fn perceus_local_scope_declare(
  scopes : Array[Map[String, Bool]],
  name : String,
) -> Unit {
  if scopes.length() == 0 {
    return
  }
  let idx = scopes.length() - 1
  let scope = scopes[idx]
  scope[name] = true
  scopes[idx] = scope
}

///|
fn perceus_next_binding_id(ctx : PerceusCountCtx, name : String) -> Int {
  let id = ctx.next_binding_id
  ctx.next_binding_id = id + 1
  ctx.binding_names[id] = name
  ctx.use_counts[id] = 0
  id
}

///|
fn perceus_replay_binding_id(ctx : PerceusEmitCtx) -> Int {
  let id = ctx.next_binding_id
  ctx.next_binding_id = id + 1
  id
}

///|
fn perceus_increment_use(ctx : PerceusCountCtx, id : Int) -> Unit {
  match ctx.use_counts.get(id) {
    Some(count) => ctx.use_counts[id] = count + 1
    None => ctx.use_counts[id] = 1
  }
}

///|
fn perceus_remaining_count(ctx : PerceusEmitCtx, id : Int) -> Int {
  match ctx.remaining_uses.get(id) {
    Some(count) => count
    None => 0
  }
}

///|
fn perceus_emit_action(
  ctx : PerceusEmitCtx,
  site : String,
  kind : PerceusActionKind,
  name : String,
) -> Unit {
  ctx.actions.push({ site, kind, name })
}

///|
fn perceus_emit_use(
  ctx : PerceusEmitCtx,
  binding_names : Map[Int, String],
  site : String,
  id : Int,
) -> Unit {
  let remaining = perceus_remaining_count(ctx, id)
  if remaining > 1 {
    perceus_emit_action(
      ctx,
      site + ".before",
      PerceusActionKind::Dup,
      binding_names.at(id),
    )
  }
  if remaining > 0 {
    ctx.remaining_uses[id] = remaining - 1
  }
}

///|
fn perceus_drop_if_unused(
  ctx : PerceusEmitCtx,
  binding_names : Map[Int, String],
  site : String,
  id : Int,
) -> Unit {
  if perceus_remaining_count(ctx, id) == 0 {
    perceus_emit_action(
      ctx,
      site,
      PerceusActionKind::Drop,
      binding_names.at(id),
    )
  }
}

///|
fn perceus_collect_pattern_names(
  pat : @core.Pat,
  seen : Map[String, Bool],
  out : Array[String],
) -> Unit {
  match pat {
    @core.Pat::Bind(name~, ..) =>
      if !seen.contains(name) {
        seen[name] = true
        out.push(name)
      }
    @core.Pat::Ctor(args~, ..) =>
      for arg in args {
        perceus_collect_pattern_names(arg, seen, out)
      }
    @core.Pat::Tuple(items~, ..) =>
      for item in items {
        perceus_collect_pattern_names(item, seen, out)
      }
    @core.Pat::Record(fields~, ..) | @core.Pat::Struct(fields~, ..) =>
      for field in fields {
        perceus_collect_pattern_names(field.pat, seen, out)
      }
    @core.Pat::Or(pats~, ..) =>
      for item in pats {
        perceus_collect_pattern_names(item, seen, out)
      }
    _ => ()
  }
}

///|
fn perceus_pattern_names(pat : @core.Pat) -> Array[String] {
  let out : Array[String] = []
  let seen : Map[String, Bool] = {}
  perceus_collect_pattern_names(pat, seen, out)
  out
}

///|
fn perceus_collect_capture_ids(
  body : @core.Module,
  outer_scopes : Array[PerceusScope],
  params : Array[@core.FuncParam],
) -> Array[Int] {
  let captures : Array[Int] = []
  let seen : Map[Int, Bool] = {}
  let local_scopes : Array[Map[String, Bool]] = [{}]
  for param in params {
    perceus_local_scope_declare(local_scopes, param.name)
  }
  perceus_collect_capture_ids_module(
    body, outer_scopes, local_scopes, captures, seen,
  )
  captures
}

///|
fn perceus_capture_mark(
  name : String,
  outer_scopes : Array[PerceusScope],
  local_scopes : Array[Map[String, Bool]],
  captures : Array[Int],
  seen : Map[Int, Bool],
) -> Unit {
  if perceus_local_scope_lookup(local_scopes, name) {
    return
  }
  match perceus_scope_lookup(outer_scopes, name) {
    Some(id) =>
      if !seen.contains(id) {
        seen[id] = true
        captures.push(id)
      }
    None => ()
  }
}

///|
fn perceus_collect_capture_ids_expr(
  expr : @core.Expr,
  outer_scopes : Array[PerceusScope],
  local_scopes : Array[Map[String, Bool]],
  captures : Array[Int],
  seen : Map[Int, Bool],
) -> Unit {
  match expr {
    @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::Char(..)
    | @core.Expr::String(..)
    | @core.Expr::Placeholder(..) => ()
    @core.Expr::Ident(name~, ..) =>
      perceus_capture_mark(name, outer_scopes, local_scopes, captures, seen)
    @core.Expr::Call(name~, args~, ..) => {
      perceus_capture_mark(name, outer_scopes, local_scopes, captures, seen)
      for i = 0; i < args.length(); i = i + 1 {
        perceus_collect_capture_ids_expr(
          args[i].expr,
          outer_scopes,
          local_scopes,
          captures,
          seen,
        )
      }
    }
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) =>
      for item in items {
        perceus_collect_capture_ids_expr(
          item, outer_scopes, local_scopes, captures, seen,
        )
      }
    @core.Expr::TupleIndex(expr~, ..) | @core.Expr::Spread(expr~, ..) =>
      perceus_collect_capture_ids_expr(
        expr, outer_scopes, local_scopes, captures, seen,
      )
    @core.Expr::Record(fields~, ..) | @core.Expr::StructLit(fields~, ..) =>
      for field in fields {
        perceus_collect_capture_ids_expr(
          field.expr,
          outer_scopes,
          local_scopes,
          captures,
          seen,
        )
      }
    @core.Expr::Map(fields~, ..) =>
      for field in fields {
        perceus_collect_capture_ids_expr(
          field.expr,
          outer_scopes,
          local_scopes,
          captures,
          seen,
        )
      }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      perceus_collect_capture_ids_expr(
        cond, outer_scopes, local_scopes, captures, seen,
      )
      perceus_collect_capture_ids_module(
        then_body, outer_scopes, local_scopes, captures, seen,
      )
      perceus_collect_capture_ids_module(
        else_body, outer_scopes, local_scopes, captures, seen,
      )
    }
    @core.Expr::Block(body~, ..) | @core.Expr::Handle(body~, ..) =>
      perceus_collect_capture_ids_module(
        body, outer_scopes, local_scopes, captures, seen,
      )
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      perceus_collect_capture_ids_expr(
        scrutinee, outer_scopes, local_scopes, captures, seen,
      )
      for i = 0; i < arms.length(); i = i + 1 {
        let arm = arms[i]
        local_scopes.push({})
        let names = perceus_pattern_names(arm.pat)
        for name in names {
          perceus_local_scope_declare(local_scopes, name)
        }
        match arm.cond {
          Some(cond) =>
            perceus_collect_capture_ids_expr(
              cond, outer_scopes, local_scopes, captures, seen,
            )
          None => ()
        }
        perceus_collect_capture_ids_expr(
          arm.expr,
          outer_scopes,
          local_scopes,
          captures,
          seen,
        )
        ignore(local_scopes.pop())
      }
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, ..) => {
      perceus_collect_capture_ids_expr(
        iterable, outer_scopes, local_scopes, captures, seen,
      )
      local_scopes.push({})
      perceus_local_scope_declare(local_scopes, value_name)
      match index_name {
        Some(idx) => perceus_local_scope_declare(local_scopes, idx)
        None => ()
      }
      perceus_collect_capture_ids_module(
        body, outer_scopes, local_scopes, captures, seen,
      )
      ignore(local_scopes.pop())
    }
    @core.Expr::Fn(..) => ()
    @core.Expr::While(cond~, body~, ..) => {
      perceus_collect_capture_ids_expr(
        cond, outer_scopes, local_scopes, captures, seen,
      )
      perceus_collect_capture_ids_module(
        body, outer_scopes, local_scopes, captures, seen,
      )
    }
    @core.Expr::Loop(params~, body~, ..) => {
      local_scopes.push({})
      for param in params {
        perceus_collect_capture_ids_expr(
          param.init,
          outer_scopes,
          local_scopes,
          captures,
          seen,
        )
        perceus_local_scope_declare(local_scopes, param.name)
      }
      perceus_collect_capture_ids_module(
        body, outer_scopes, local_scopes, captures, seen,
      )
      ignore(local_scopes.pop())
    }
    @core.Expr::Break(value~, ..) =>
      match value {
        Some(expr) =>
          perceus_collect_capture_ids_expr(
            expr, outer_scopes, local_scopes, captures, seen,
          )
        None => ()
      }
    @core.Expr::Continue(args~, ..) =>
      for arg in args {
        perceus_collect_capture_ids_expr(
          arg, outer_scopes, local_scopes, captures, seen,
        )
      }
    @core.Expr::Yield(expr~, ..) =>
      perceus_collect_capture_ids_expr(
        expr, outer_scopes, local_scopes, captures, seen,
      )
    @core.Expr::Perform(args~, ..) =>
      for i = 0; i < args.length(); i = i + 1 {
        perceus_collect_capture_ids_expr(
          args[i].expr,
          outer_scopes,
          local_scopes,
          captures,
          seen,
        )
      }
    @core.Expr::StringInterp(parts~, ..) =>
      for i = 0; i < parts.length(); i = i + 1 {
        match parts[i] {
          @core.StringInterpPart::Expr(expr) =>
            perceus_collect_capture_ids_expr(
              expr, outer_scopes, local_scopes, captures, seen,
            )
          @core.StringInterpPart::Lit(_) => ()
        }
      }
  }
}

///|
fn perceus_collect_capture_ids_stmt(
  stmt : @core.Stmt,
  outer_scopes : Array[PerceusScope],
  local_scopes : Array[Map[String, Bool]],
  captures : Array[Int],
  seen : Map[Int, Bool],
) -> Unit {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, ..)
    | @core.Stmt::ExportLet(rec~, name~, expr~, ..)
    | @core.Stmt::InternalExportLet(rec~, name~, expr~, ..) => {
      if rec {
        perceus_local_scope_declare(local_scopes, name)
      }
      perceus_collect_capture_ids_expr(
        expr, outer_scopes, local_scopes, captures, seen,
      )
      if !rec {
        perceus_local_scope_declare(local_scopes, name)
      }
    }
    @core.Stmt::LetMut(name~, expr~, ..) => {
      perceus_collect_capture_ids_expr(
        expr, outer_scopes, local_scopes, captures, seen,
      )
      perceus_local_scope_declare(local_scopes, name)
    }
    @core.Stmt::ExternLet(name~, ..) =>
      perceus_local_scope_declare(local_scopes, name)
    @core.Stmt::Assign(name~, expr~, ..) => {
      perceus_capture_mark(name, outer_scopes, local_scopes, captures, seen)
      perceus_collect_capture_ids_expr(
        expr, outer_scopes, local_scopes, captures, seen,
      )
    }
    @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      perceus_collect_capture_ids_expr(
        target, outer_scopes, local_scopes, captures, seen,
      )
      perceus_collect_capture_ids_expr(
        index, outer_scopes, local_scopes, captures, seen,
      )
      perceus_collect_capture_ids_expr(
        value, outer_scopes, local_scopes, captures, seen,
      )
    }
    @core.Stmt::LetPat(pat~, expr~, ..) => {
      perceus_collect_capture_ids_expr(
        expr, outer_scopes, local_scopes, captures, seen,
      )
      let names = perceus_pattern_names(pat)
      for name in names {
        perceus_local_scope_declare(local_scopes, name)
      }
    }
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, ..) => {
      perceus_collect_capture_ids_expr(
        expr, outer_scopes, local_scopes, captures, seen,
      )
      perceus_collect_capture_ids_module(
        else_body, outer_scopes, local_scopes, captures, seen,
      )
      let names = perceus_pattern_names(pat)
      for name in names {
        perceus_local_scope_declare(local_scopes, name)
      }
    }
    @core.Stmt::Expr(expr~, ..) =>
      perceus_collect_capture_ids_expr(
        expr, outer_scopes, local_scopes, captures, seen,
      )
    @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
      perceus_collect_capture_ids_module(
        body, outer_scopes, local_scopes, captures, seen,
      )
    _ => ()
  }
}

///|
fn perceus_collect_capture_ids_module(
  body : @core.Module,
  outer_scopes : Array[PerceusScope],
  local_scopes : Array[Map[String, Bool]],
  captures : Array[Int],
  seen : Map[Int, Bool],
) -> Unit {
  local_scopes.push({})
  for stmt in body.stmts {
    perceus_collect_capture_ids_stmt(
      stmt, outer_scopes, local_scopes, captures, seen,
    )
  }
  ignore(local_scopes.pop())
}

///|
fn perceus_count_expr(
  expr : @core.Expr,
  scopes : Array[PerceusScope],
  ctx : PerceusCountCtx,
) -> Unit {
  match expr {
    @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::Char(..)
    | @core.Expr::String(..)
    | @core.Expr::Placeholder(..) => ()
    @core.Expr::Ident(name~, ..) =>
      match perceus_scope_lookup(scopes, name) {
        Some(id) => perceus_increment_use(ctx, id)
        None => ()
      }
    @core.Expr::Call(name~, args~, ..) => {
      match perceus_scope_lookup(scopes, name) {
        Some(id) => perceus_increment_use(ctx, id)
        None => ()
      }
      for arg in args {
        perceus_count_expr(arg.expr, scopes, ctx)
      }
    }
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) =>
      for item in items {
        perceus_count_expr(item, scopes, ctx)
      }
    @core.Expr::TupleIndex(expr~, ..) | @core.Expr::Spread(expr~, ..) =>
      perceus_count_expr(expr, scopes, ctx)
    @core.Expr::Record(fields~, ..) | @core.Expr::StructLit(fields~, ..) =>
      for field in fields {
        perceus_count_expr(field.expr, scopes, ctx)
      }
    @core.Expr::Map(fields~, ..) =>
      for field in fields {
        perceus_count_expr(field.expr, scopes, ctx)
      }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      perceus_count_expr(cond, scopes, ctx)
      perceus_count_block(then_body, scopes, ctx)
      perceus_count_block(else_body, scopes, ctx)
    }
    @core.Expr::Block(body~, ..) | @core.Expr::Handle(body~, ..) =>
      perceus_count_block(body, scopes, ctx)
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      perceus_count_expr(scrutinee, scopes, ctx)
      for arm in arms {
        scopes.push(perceus_scope_new())
        let names = perceus_pattern_names(arm.pat)
        for name in names {
          let id = perceus_next_binding_id(ctx, name)
          perceus_scope_declare(scopes, name, id)
        }
        match arm.cond {
          Some(cond) => perceus_count_expr(cond, scopes, ctx)
          None => ()
        }
        perceus_count_expr(arm.expr, scopes, ctx)
        ignore(scopes.pop())
      }
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, ..) => {
      perceus_count_expr(iterable, scopes, ctx)
      scopes.push(perceus_scope_new())
      let value_id = perceus_next_binding_id(ctx, value_name)
      perceus_scope_declare(scopes, value_name, value_id)
      match index_name {
        Some(idx) => {
          let index_id = perceus_next_binding_id(ctx, idx)
          perceus_scope_declare(scopes, idx, index_id)
        }
        None => ()
      }
      perceus_count_block(body, scopes, ctx)
      ignore(scopes.pop())
    }
    @core.Expr::Fn(params~, body~, ..) => {
      let captures = perceus_collect_capture_ids(body, scopes, params)
      for id in captures {
        perceus_increment_use(ctx, id)
      }
    }
    @core.Expr::While(cond~, body~, ..) => {
      perceus_count_expr(cond, scopes, ctx)
      perceus_count_block(body, scopes, ctx)
    }
    @core.Expr::Loop(params~, body~, ..) => {
      scopes.push(perceus_scope_new())
      for param in params {
        perceus_count_expr(param.init, scopes, ctx)
        let id = perceus_next_binding_id(ctx, param.name)
        perceus_scope_declare(scopes, param.name, id)
      }
      perceus_count_block(body, scopes, ctx)
      ignore(scopes.pop())
    }
    @core.Expr::Break(value~, ..) =>
      match value {
        Some(expr) => perceus_count_expr(expr, scopes, ctx)
        None => ()
      }
    @core.Expr::Continue(args~, ..) =>
      for arg in args {
        perceus_count_expr(arg, scopes, ctx)
      }
    @core.Expr::Yield(expr~, ..) => perceus_count_expr(expr, scopes, ctx)
    @core.Expr::Perform(args~, ..) =>
      for arg in args {
        perceus_count_expr(arg.expr, scopes, ctx)
      }
    @core.Expr::StringInterp(parts~, ..) =>
      for part in parts {
        match part {
          @core.StringInterpPart::Expr(expr) =>
            perceus_count_expr(expr, scopes, ctx)
          @core.StringInterpPart::Lit(_) => ()
        }
      }
  }
}

///|
fn perceus_count_stmt(
  stmt : @core.Stmt,
  scopes : Array[PerceusScope],
  ctx : PerceusCountCtx,
) -> Unit {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, ..)
    | @core.Stmt::ExportLet(rec~, name~, expr~, ..)
    | @core.Stmt::InternalExportLet(rec~, name~, expr~, ..) => {
      if rec {
        let id = perceus_next_binding_id(ctx, name)
        perceus_scope_declare(scopes, name, id)
      }
      perceus_count_expr(expr, scopes, ctx)
      if !rec {
        let id = perceus_next_binding_id(ctx, name)
        perceus_scope_declare(scopes, name, id)
      }
    }
    @core.Stmt::LetMut(name~, expr~, ..) => {
      perceus_count_expr(expr, scopes, ctx)
      let id = perceus_next_binding_id(ctx, name)
      perceus_scope_declare(scopes, name, id)
    }
    @core.Stmt::ExternLet(name~, ..) => {
      let id = perceus_next_binding_id(ctx, name)
      perceus_scope_declare(scopes, name, id)
    }
    @core.Stmt::Assign(expr~, ..) => perceus_count_expr(expr, scopes, ctx)
    @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      perceus_count_expr(target, scopes, ctx)
      perceus_count_expr(index, scopes, ctx)
      perceus_count_expr(value, scopes, ctx)
    }
    @core.Stmt::LetPat(pat~, expr~, ..) => {
      perceus_count_expr(expr, scopes, ctx)
      let names = perceus_pattern_names(pat)
      for name in names {
        let id = perceus_next_binding_id(ctx, name)
        perceus_scope_declare(scopes, name, id)
      }
    }
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, ..) => {
      perceus_count_expr(expr, scopes, ctx)
      perceus_count_block(else_body, scopes, ctx)
      let names = perceus_pattern_names(pat)
      for name in names {
        let id = perceus_next_binding_id(ctx, name)
        perceus_scope_declare(scopes, name, id)
      }
    }
    @core.Stmt::Expr(expr~, ..) => perceus_count_expr(expr, scopes, ctx)
    @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
      perceus_count_block(body, scopes, ctx)
    _ => ()
  }
}

///|
fn perceus_count_block(
  body : @core.Module,
  scopes : Array[PerceusScope],
  ctx : PerceusCountCtx,
) -> Unit {
  scopes.push(perceus_scope_new())
  for stmt in body.stmts {
    perceus_count_stmt(stmt, scopes, ctx)
  }
  ignore(scopes.pop())
}

///|
fn perceus_emit_expr(
  expr : @core.Expr,
  scopes : Array[PerceusScope],
  count_ctx : PerceusCountCtx,
  emit_ctx : PerceusEmitCtx,
  site : String,
) -> Unit {
  match expr {
    @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::Char(..)
    | @core.Expr::String(..)
    | @core.Expr::Placeholder(..) => ()
    @core.Expr::Ident(name~, ..) =>
      match perceus_scope_lookup(scopes, name) {
        Some(id) =>
          perceus_emit_use(emit_ctx, count_ctx.binding_names, site, id)
        None => ()
      }
    @core.Expr::Call(name~, args~, ..) => {
      match perceus_scope_lookup(scopes, name) {
        Some(id) =>
          perceus_emit_use(
            emit_ctx,
            count_ctx.binding_names,
            site + ".callee",
            id,
          )
        None => ()
      }
      for i = 0; i < args.length(); i = i + 1 {
        perceus_emit_expr(
          args[i].expr,
          scopes,
          count_ctx,
          emit_ctx,
          site + ".arg[\{i.to_string()}]",
        )
      }
    }
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) =>
      for i = 0; i < items.length(); i = i + 1 {
        perceus_emit_expr(
          items[i],
          scopes,
          count_ctx,
          emit_ctx,
          site + ".item[\{i.to_string()}]",
        )
      }
    @core.Expr::TupleIndex(expr~, ..) | @core.Expr::Spread(expr~, ..) =>
      perceus_emit_expr(expr, scopes, count_ctx, emit_ctx, site + ".inner")
    @core.Expr::Record(fields~, ..) | @core.Expr::StructLit(fields~, ..) =>
      for i = 0; i < fields.length(); i = i + 1 {
        perceus_emit_expr(
          fields[i].expr,
          scopes,
          count_ctx,
          emit_ctx,
          site + ".field[\{i.to_string()}]",
        )
      }
    @core.Expr::Map(fields~, ..) =>
      for i = 0; i < fields.length(); i = i + 1 {
        perceus_emit_expr(
          fields[i].expr,
          scopes,
          count_ctx,
          emit_ctx,
          site + ".field[\{i.to_string()}]",
        )
      }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      perceus_emit_expr(cond, scopes, count_ctx, emit_ctx, site + ".cond")
      perceus_emit_block(then_body, scopes, count_ctx, emit_ctx, site + ".then")
      perceus_emit_block(else_body, scopes, count_ctx, emit_ctx, site + ".else")
    }
    @core.Expr::Block(body~, ..) | @core.Expr::Handle(body~, ..) =>
      perceus_emit_block(body, scopes, count_ctx, emit_ctx, site + ".body")
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      perceus_emit_expr(
        scrutinee,
        scopes,
        count_ctx,
        emit_ctx,
        site + ".scrutinee",
      )
      for i = 0; i < arms.length(); i = i + 1 {
        scopes.push(perceus_scope_new())
        let names = perceus_pattern_names(arms[i].pat)
        for name in names {
          let id = perceus_replay_binding_id(emit_ctx)
          perceus_scope_declare(scopes, name, id)
          perceus_drop_if_unused(
            emit_ctx,
            count_ctx.binding_names,
            site + ".arm[\{i.to_string()}].after[\{name}]",
            id,
          )
        }
        match arms[i].cond {
          Some(cond) =>
            perceus_emit_expr(
              cond,
              scopes,
              count_ctx,
              emit_ctx,
              site + ".arm[\{i.to_string()}].cond",
            )
          None => ()
        }
        perceus_emit_expr(
          arms[i].expr,
          scopes,
          count_ctx,
          emit_ctx,
          site + ".arm[\{i.to_string()}].expr",
        )
        ignore(scopes.pop())
      }
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, ..) => {
      perceus_emit_expr(
        iterable,
        scopes,
        count_ctx,
        emit_ctx,
        site + ".iterable",
      )
      scopes.push(perceus_scope_new())
      let value_id = perceus_replay_binding_id(emit_ctx)
      perceus_scope_declare(scopes, value_name, value_id)
      perceus_drop_if_unused(
        emit_ctx,
        count_ctx.binding_names,
        site + ".after[\{value_name}]",
        value_id,
      )
      match index_name {
        Some(idx) => {
          let index_id = perceus_replay_binding_id(emit_ctx)
          perceus_scope_declare(scopes, idx, index_id)
          perceus_drop_if_unused(
            emit_ctx,
            count_ctx.binding_names,
            site + ".after[\{idx}]",
            index_id,
          )
        }
        None => ()
      }
      perceus_emit_block(body, scopes, count_ctx, emit_ctx, site + ".body")
      ignore(scopes.pop())
    }
    @core.Expr::Fn(params~, body~, ..) => {
      let captures = perceus_collect_capture_ids(body, scopes, params)
      for id in captures {
        let name = count_ctx.binding_names.at(id)
        perceus_emit_use(
          emit_ctx,
          count_ctx.binding_names,
          site + ".capture[\{name}]",
          id,
        )
      }
    }
    @core.Expr::While(cond~, body~, ..) => {
      perceus_emit_expr(cond, scopes, count_ctx, emit_ctx, site + ".cond")
      perceus_emit_block(body, scopes, count_ctx, emit_ctx, site + ".body")
    }
    @core.Expr::Loop(params~, body~, ..) => {
      scopes.push(perceus_scope_new())
      for i = 0; i < params.length(); i = i + 1 {
        perceus_emit_expr(
          params[i].init,
          scopes,
          count_ctx,
          emit_ctx,
          site + ".param[\{i.to_string()}].init",
        )
        let id = perceus_replay_binding_id(emit_ctx)
        perceus_scope_declare(scopes, params[i].name, id)
        perceus_drop_if_unused(
          emit_ctx,
          count_ctx.binding_names,
          site + ".param[\{i.to_string()}].after",
          id,
        )
      }
      perceus_emit_block(body, scopes, count_ctx, emit_ctx, site + ".body")
      ignore(scopes.pop())
    }
    @core.Expr::Break(value~, ..) =>
      match value {
        Some(expr) =>
          perceus_emit_expr(expr, scopes, count_ctx, emit_ctx, site + ".value")
        None => ()
      }
    @core.Expr::Continue(args~, ..) =>
      for i = 0; i < args.length(); i = i + 1 {
        perceus_emit_expr(
          args[i],
          scopes,
          count_ctx,
          emit_ctx,
          site + ".arg[\{i.to_string()}]",
        )
      }
    @core.Expr::Yield(expr~, ..) =>
      perceus_emit_expr(expr, scopes, count_ctx, emit_ctx, site + ".value")
    @core.Expr::Perform(args~, ..) =>
      for i = 0; i < args.length(); i = i + 1 {
        perceus_emit_expr(
          args[i].expr,
          scopes,
          count_ctx,
          emit_ctx,
          site + ".arg[\{i.to_string()}]",
        )
      }
    @core.Expr::StringInterp(parts~, ..) =>
      for i = 0; i < parts.length(); i = i + 1 {
        match parts[i] {
          @core.StringInterpPart::Expr(expr) =>
            perceus_emit_expr(
              expr,
              scopes,
              count_ctx,
              emit_ctx,
              site + ".part[\{i.to_string()}]",
            )
          @core.StringInterpPart::Lit(_) => ()
        }
      }
  }
}

///|
fn perceus_emit_stmt(
  stmt : @core.Stmt,
  scopes : Array[PerceusScope],
  count_ctx : PerceusCountCtx,
  emit_ctx : PerceusEmitCtx,
  site : String,
) -> Unit {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, ..)
    | @core.Stmt::ExportLet(rec~, name~, expr~, ..)
    | @core.Stmt::InternalExportLet(rec~, name~, expr~, ..) =>
      if rec {
        let id = perceus_replay_binding_id(emit_ctx)
        perceus_scope_declare(scopes, name, id)
        perceus_emit_expr(expr, scopes, count_ctx, emit_ctx, site + ".expr")
        perceus_drop_if_unused(
          emit_ctx,
          count_ctx.binding_names,
          site + ".after",
          id,
        )
      } else {
        perceus_emit_expr(expr, scopes, count_ctx, emit_ctx, site + ".expr")
        let id = perceus_replay_binding_id(emit_ctx)
        perceus_scope_declare(scopes, name, id)
        perceus_drop_if_unused(
          emit_ctx,
          count_ctx.binding_names,
          site + ".after",
          id,
        )
      }
    @core.Stmt::LetMut(name~, expr~, ..) => {
      perceus_emit_expr(expr, scopes, count_ctx, emit_ctx, site + ".expr")
      let id = perceus_replay_binding_id(emit_ctx)
      perceus_scope_declare(scopes, name, id)
      perceus_drop_if_unused(
        emit_ctx,
        count_ctx.binding_names,
        site + ".after",
        id,
      )
    }
    @core.Stmt::ExternLet(name~, ..) => {
      let id = perceus_replay_binding_id(emit_ctx)
      perceus_scope_declare(scopes, name, id)
      let _ = id
    }
    @core.Stmt::Assign(expr~, ..) =>
      perceus_emit_expr(expr, scopes, count_ctx, emit_ctx, site + ".expr")
    @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      perceus_emit_expr(target, scopes, count_ctx, emit_ctx, site + ".target")
      perceus_emit_expr(index, scopes, count_ctx, emit_ctx, site + ".index")
      perceus_emit_expr(value, scopes, count_ctx, emit_ctx, site + ".value")
    }
    @core.Stmt::LetPat(pat~, expr~, ..) => {
      perceus_emit_expr(expr, scopes, count_ctx, emit_ctx, site + ".expr")
      let names = perceus_pattern_names(pat)
      for name in names {
        let id = perceus_replay_binding_id(emit_ctx)
        perceus_scope_declare(scopes, name, id)
        perceus_drop_if_unused(
          emit_ctx,
          count_ctx.binding_names,
          site + ".after[\{name}]",
          id,
        )
      }
    }
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, ..) => {
      perceus_emit_expr(expr, scopes, count_ctx, emit_ctx, site + ".expr")
      perceus_emit_block(else_body, scopes, count_ctx, emit_ctx, site + ".else")
      let names = perceus_pattern_names(pat)
      for name in names {
        let id = perceus_replay_binding_id(emit_ctx)
        perceus_scope_declare(scopes, name, id)
        perceus_drop_if_unused(
          emit_ctx,
          count_ctx.binding_names,
          site + ".after[\{name}]",
          id,
        )
      }
    }
    @core.Stmt::Expr(expr~, ..) =>
      perceus_emit_expr(expr, scopes, count_ctx, emit_ctx, site + ".expr")
    @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
      perceus_emit_block(body, scopes, count_ctx, emit_ctx, site + ".body")
    _ => ()
  }
}

///|
fn perceus_emit_block(
  body : @core.Module,
  scopes : Array[PerceusScope],
  count_ctx : PerceusCountCtx,
  emit_ctx : PerceusEmitCtx,
  prefix : String,
) -> Unit {
  scopes.push(perceus_scope_new())
  for i = 0; i < body.stmts.length(); i = i + 1 {
    perceus_emit_stmt(
      body.stmts[i],
      scopes,
      count_ctx,
      emit_ctx,
      prefix + ".stmt[\{i.to_string()}]",
    )
  }
  ignore(scopes.pop())
}

///|
fn perceus_action_kind_name(kind : PerceusActionKind) -> String {
  match kind {
    PerceusActionKind::Dup => "dup"
    PerceusActionKind::Drop => "drop"
  }
}

///|
pub fn perceus_action_debug_string(action : PerceusAction) -> String {
  "\{action.site} \{perceus_action_kind_name(action.kind)} \{action.name}"
}

///|
pub fn build_perceus_plan_poc(mod : @core.Module) -> Array[PerceusAction] {
  let count_ctx = { next_binding_id: 0, binding_names: {}, use_counts: {} }
  let count_scopes : Array[PerceusScope] = [perceus_scope_new()]
  for stmt in mod.stmts {
    perceus_count_stmt(stmt, count_scopes, count_ctx)
  }
  let emit_ctx = {
    next_binding_id: 0,
    remaining_uses: count_ctx.use_counts.copy(),
    actions: [],
  }
  let emit_scopes : Array[PerceusScope] = [perceus_scope_new()]
  for i = 0; i < mod.stmts.length(); i = i + 1 {
    perceus_emit_stmt(
      mod.stmts[i],
      emit_scopes,
      count_ctx,
      emit_ctx,
      "stmt[\{i.to_string()}]",
    )
  }
  emit_ctx.actions
}

///|
/// Branch-sensitive Perceus analysis — two-pass approach.
///
/// Pass 1 (Count): Walk the AST and count uses per binding. For branches
/// (if/else, match), take the max use count across branches. This gives us
/// the total "ownership tokens" each binding needs.
///
/// Pass 2 (Emit): Walk the AST again with remaining_uses initialized from
/// pass 1. At each use, if remaining > 1, emit dup. At branch points,
/// distribute tokens to branches and emit drops in branches that need fewer.
/// At scope end, if remaining > 0, emit drop.

///|
/// Pass 1 context: counts uses per binding with branch-max semantics.
priv struct PerceusCountCtx2 {
  mut next_id : Int
  names : Map[Int, String]
  /// Accumulated owning use counts per binding (triggers dup when > 1)
  uses : Map[Int, Int]
  /// Accumulated borrow counts per binding (keeps alive but no dup)
  borrows : Map[Int, Int]
  /// Scope stack: name → binding_id
  scopes : Array[Map[String, Int]]
}

///|
fn p2_count_ctx_new() -> PerceusCountCtx2 {
  { next_id: 0, names: {}, uses: {}, borrows: {}, scopes: [{}] }
}

///|
fn p2_count_declare(ctx : PerceusCountCtx2, name : String) -> Int {
  let id = ctx.next_id
  ctx.next_id = id + 1
  ctx.names[id] = name
  ctx.uses[id] = 0
  let top = ctx.scopes[ctx.scopes.length() - 1]
  top[name] = id
  id
}

///|
fn p2_count_lookup(ctx : PerceusCountCtx2, name : String) -> Int? {
  let mut i = ctx.scopes.length()
  while i > 0 {
    i -= 1
    match ctx.scopes[i].get(name) {
      Some(id) => return Some(id)
      None => ()
    }
  }
  None
}

///|
fn p2_count_use(ctx : PerceusCountCtx2, name : String) -> Unit {
  match p2_count_lookup(ctx, name) {
    Some(id) => ctx.uses[id] = ctx.uses.get(id).unwrap_or(0) + 1
    None => ()
  }
}

///|
/// Count a borrowing use: keeps the binding alive but does not require dup.
fn p2_count_borrow(ctx : PerceusCountCtx2, name : String) -> Unit {
  match p2_count_lookup(ctx, name) {
    Some(id) => ctx.borrows[id] = ctx.borrows.get(id).unwrap_or(0) + 1
    None => ()
  }
}

///|
fn p2_count_push_scope(ctx : PerceusCountCtx2) -> Unit {
  ctx.scopes.push({})
}

///|
fn p2_count_pop_scope(ctx : PerceusCountCtx2) -> Unit {
  ignore(ctx.scopes.pop())
}

///|
fn p2_count_snapshot(ctx : PerceusCountCtx2) -> (Map[Int, Int], Map[Int, Int]) {
  let snap : Map[Int, Int] = {}
  ctx.uses.each(fn(k, v) { snap[k] = v })
  let snap_b : Map[Int, Int] = {}
  ctx.borrows.each(fn(k, v) { snap_b[k] = v })
  (snap, snap_b)
}

///|
fn p2_count_restore(
  ctx : PerceusCountCtx2,
  snap : (Map[Int, Int], Map[Int, Int]),
) -> Unit {
  snap.0.each(fn(k, v) { ctx.uses[k] = v })
  snap.1.each(fn(k, v) { ctx.borrows[k] = v })
}

///|
/// After analyzing all branches, merge by taking max counts per binding.
fn p2_count_merge_branches(
  ctx : PerceusCountCtx2,
  pre : (Map[Int, Int], Map[Int, Int]),
  branch_snaps : Array[(Map[Int, Int], Map[Int, Int])],
) -> Unit {
  let pre_uses = pre.0
  let pre_borrows = pre.1
  // For each binding, find max consumed across branches
  let max_uses : Map[Int, Int] = {}
  let max_borrows : Map[Int, Int] = {}
  pre_uses.each(fn(id, pre_count) {
    let mut best = 0
    for snap in branch_snaps {
      let post = snap.0.get(id).unwrap_or(pre_count)
      let consumed = post - pre_count
      if consumed > best {
        best = consumed
      }
    }
    if best > 0 {
      max_uses[id] = best
    }
  })
  pre_borrows.each(fn(id, pre_count) {
    let mut best = 0
    for snap in branch_snaps {
      let post = snap.1.get(id).unwrap_or(pre_count)
      let consumed = post - pre_count
      if consumed > best {
        best = consumed
      }
    }
    if best > 0 {
      max_borrows[id] = best
    }
  })
  // Set uses = pre + max
  max_uses.each(fn(id, max_c) {
    let pre_count = pre_uses.get(id).unwrap_or(0)
    ctx.uses[id] = pre_count + max_c
  })
  max_borrows.each(fn(id, max_c) {
    let pre_count = pre_borrows.get(id).unwrap_or(0)
    ctx.borrows[id] = pre_count + max_c
  })
}

///|
fn p2_count_expr(ctx : PerceusCountCtx2, expr : @core.Expr) -> Unit {
  match expr {
    @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::Char(..)
    | @core.Expr::String(..)
    | @core.Expr::Placeholder(..) => ()
    @core.Expr::Ident(name~, ..) => p2_count_use(ctx, name)
    @core.Expr::Call(name~, args~, ..) => {
      p2_count_use(ctx, name)
      for arg in args {
        p2_count_expr(ctx, arg.expr)
      }
    }
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) =>
      for item in items {
        p2_count_expr(ctx, item)
      }
    @core.Expr::TupleIndex(expr=inner, ..) =>
      // Field access borrows the container — no ownership transfer
      match inner {
        @core.Expr::Ident(name~, ..) => p2_count_borrow(ctx, name)
        _ => p2_count_expr(ctx, inner)
      }
    @core.Expr::Spread(expr~, ..) => p2_count_expr(ctx, expr)
    @core.Expr::Record(fields~, ..) | @core.Expr::StructLit(fields~, ..) =>
      for field in fields {
        p2_count_expr(ctx, field.expr)
      }
    @core.Expr::Map(fields~, ..) =>
      for field in fields {
        p2_count_expr(ctx, field.expr)
      }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      p2_count_expr(ctx, cond)
      let pre = p2_count_snapshot(ctx)
      p2_count_block(ctx, then_body)
      let then_snap = p2_count_snapshot(ctx)
      p2_count_restore(ctx, pre)
      p2_count_block(ctx, else_body)
      let else_snap = p2_count_snapshot(ctx)
      p2_count_merge_branches(ctx, pre, [then_snap, else_snap])
    }
    @core.Expr::Block(body~, ..) | @core.Expr::Handle(body~, ..) =>
      p2_count_block(ctx, body)
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      p2_count_expr(ctx, scrutinee)
      if arms.length() == 0 {
        return
      }
      let pre = p2_count_snapshot(ctx)
      let snaps : Array[(Map[Int, Int], Map[Int, Int])] = []
      for i = 0; i < arms.length(); i = i + 1 {
        p2_count_restore(ctx, pre)
        p2_count_push_scope(ctx)
        let names = perceus_pattern_names(arms[i].pat)
        for name in names {
          ignore(p2_count_declare(ctx, name))
        }
        match arms[i].cond {
          Some(cond) => p2_count_expr(ctx, cond)
          None => ()
        }
        p2_count_expr(ctx, arms[i].expr)
        p2_count_pop_scope(ctx)
        snaps.push(p2_count_snapshot(ctx))
      }
      p2_count_merge_branches(ctx, pre, snaps)
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, ..) => {
      p2_count_expr(ctx, iterable)
      p2_count_push_scope(ctx)
      ignore(p2_count_declare(ctx, value_name))
      match index_name {
        Some(idx) => ignore(p2_count_declare(ctx, idx))
        None => ()
      }
      p2_count_block(ctx, body)
      p2_count_pop_scope(ctx)
    }
    @core.Expr::Fn(params~, body~, ..) => {
      let captures = perceus_collect_capture_ids(
        body,
        ctx.scopes.map(fn(scope) {
          let ps : PerceusScope = { name_index: {} }
          scope.each(fn(name, id) { ps.name_index[name] = [id] })
          ps
        }),
        params,
      )
      for id in captures {
        ctx.uses[id] = ctx.uses.get(id).unwrap_or(0) + 1
      }
    }
    @core.Expr::While(cond~, body~, ..) => {
      let pre = p2_count_snapshot(ctx)
      p2_count_expr(ctx, cond)
      p2_count_block(ctx, body)
      let loop_snap = p2_count_snapshot(ctx)
      p2_count_merge_branches(ctx, pre, [loop_snap, pre])
    }
    @core.Expr::Loop(params~, body~, ..) => {
      p2_count_push_scope(ctx)
      for param in params {
        p2_count_expr(ctx, param.init)
        ignore(p2_count_declare(ctx, param.name))
      }
      p2_count_block(ctx, body)
      p2_count_pop_scope(ctx)
    }
    @core.Expr::Break(value~, ..) =>
      match value {
        Some(expr) => p2_count_expr(ctx, expr)
        None => ()
      }
    @core.Expr::Continue(args~, ..) =>
      for arg in args {
        p2_count_expr(ctx, arg)
      }
    @core.Expr::Yield(expr~, ..) => p2_count_expr(ctx, expr)
    @core.Expr::Perform(args~, ..) =>
      for arg in args {
        p2_count_expr(ctx, arg.expr)
      }
    @core.Expr::StringInterp(parts~, ..) =>
      for part in parts {
        match part {
          @core.StringInterpPart::Expr(expr) => p2_count_expr(ctx, expr)
          @core.StringInterpPart::Lit(_) => ()
        }
      }
  }
}

///|
fn p2_count_stmt(ctx : PerceusCountCtx2, stmt : @core.Stmt) -> Unit {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, ..)
    | @core.Stmt::ExportLet(rec~, name~, expr~, ..)
    | @core.Stmt::InternalExportLet(rec~, name~, expr~, ..) => {
      if rec {
        ignore(p2_count_declare(ctx, name))
      }
      p2_count_expr(ctx, expr)
      if !rec {
        ignore(p2_count_declare(ctx, name))
      }
    }
    @core.Stmt::LetMut(name~, expr~, ..) => {
      p2_count_expr(ctx, expr)
      ignore(p2_count_declare(ctx, name))
    }
    @core.Stmt::ExternLet(name~, ..) => ignore(p2_count_declare(ctx, name))
    @core.Stmt::Assign(expr~, ..) => p2_count_expr(ctx, expr)
    @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      p2_count_expr(ctx, target)
      p2_count_expr(ctx, index)
      p2_count_expr(ctx, value)
    }
    @core.Stmt::LetPat(pat~, expr~, ..) => {
      p2_count_expr(ctx, expr)
      let names = perceus_pattern_names(pat)
      for name in names {
        ignore(p2_count_declare(ctx, name))
      }
    }
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, ..) => {
      p2_count_expr(ctx, expr)
      p2_count_block(ctx, else_body)
      let names = perceus_pattern_names(pat)
      for name in names {
        ignore(p2_count_declare(ctx, name))
      }
    }
    @core.Stmt::Expr(expr~, ..) => p2_count_expr(ctx, expr)
    @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
      p2_count_block(ctx, body)
    _ => ()
  }
}

///|
fn p2_count_block(ctx : PerceusCountCtx2, body : @core.Module) -> Unit {
  p2_count_push_scope(ctx)
  for stmt in body.stmts {
    p2_count_stmt(ctx, stmt)
  }
  p2_count_pop_scope(ctx)
}

///|
/// Pass 2 context: emits dup/drop using remaining counts from pass 1.
priv struct PerceusEmitCtx2 {
  /// Binding ID replayed in lock-step with pass 1
  mut next_id : Int
  /// Map from binding_id → remaining total tokens (owning + borrows)
  remaining : Map[Int, Int]
  /// Map from binding_id → remaining owning uses only (triggers dup)
  remaining_owning : Map[Int, Int]
  /// Variable names from pass 1
  names : Map[Int, String]
  /// Accumulated actions
  actions : Array[PerceusAction]
  /// Scope stack: name → binding_id
  scopes : Array[Map[String, Int]]
}

///|
fn p2_emit_ctx_new(
  names : Map[Int, String],
  uses : Map[Int, Int],
  borrows : Map[Int, Int],
) -> PerceusEmitCtx2 {
  let remaining : Map[Int, Int] = {}
  let remaining_owning : Map[Int, Int] = {}
  uses.each(fn(k, v) {
    remaining[k] = v
    remaining_owning[k] = v
  })
  // Pure-borrow bindings (0 owning uses, only field accesses):
  // Need exactly 1 remaining token so scope-end drop fires.
  borrows.each(fn(k, v) {
    if v > 0 {
      let owning = uses.get(k).unwrap_or(0)
      if owning == 0 {
        remaining[k] = 1
        remaining_owning[k] = 0
      }
    }
  })
  { next_id: 0, remaining, remaining_owning, names, actions: [], scopes: [{}] }
}

///|
fn p2_emit_declare(ctx : PerceusEmitCtx2, name : String) -> Int {
  let id = ctx.next_id
  ctx.next_id = id + 1
  let top = ctx.scopes[ctx.scopes.length() - 1]
  top[name] = id
  id
}

///|
fn p2_emit_lookup(ctx : PerceusEmitCtx2, name : String) -> Int? {
  let mut i = ctx.scopes.length()
  while i > 0 {
    i -= 1
    match ctx.scopes[i].get(name) {
      Some(id) => return Some(id)
      None => ()
    }
  }
  None
}

///|
fn p2_emit_push_scope(ctx : PerceusEmitCtx2) -> Unit {
  ctx.scopes.push({})
}

///|
/// Pop scope and emit drops for any bindings with remaining uses > 0.
fn p2_emit_pop_scope(ctx : PerceusEmitCtx2, site : String) -> Unit {
  let scope = ctx.scopes.pop()
  match scope {
    Some(bindings) =>
      bindings.each(fn(name, id) {
        let rem = ctx.remaining.get(id).unwrap_or(0)
        if rem > 0 {
          ctx.actions.push({
            site: site + ".scope_end",
            kind: PerceusActionKind::Drop,
            name,
          })
          ctx.remaining[id] = 0
        }
      })
    None => ()
  }
}

///|
/// Emit an owning use of a binding. If remaining owning > 1, emit dup.
fn p2_emit_use(ctx : PerceusEmitCtx2, name : String, site : String) -> Unit {
  match p2_emit_lookup(ctx, name) {
    Some(id) => {
      let rem = ctx.remaining.get(id).unwrap_or(0)
      let rem_own = ctx.remaining_owning.get(id).unwrap_or(0)
      if rem_own > 1 {
        ctx.actions.push({
          site: site + ".before",
          kind: PerceusActionKind::Dup,
          name,
        })
      }
      if rem > 0 {
        ctx.remaining[id] = rem - 1
      }
      if rem_own > 0 {
        ctx.remaining_owning[id] = rem_own - 1
      }
    }
    None => ()
  }
}

///|
/// Emit a borrowing use. For pure-borrow bindings (0 owning uses), this is
/// a no-op — the container stays alive and gets dropped at scope end.
/// For mixed bindings (borrows merged into owning), delegates to p2_emit_use.
fn p2_emit_borrow(ctx : PerceusEmitCtx2, name : String, site : String) -> Unit {
  match p2_emit_lookup(ctx, name) {
    Some(id) => {
      let rem_own = ctx.remaining_owning.get(id).unwrap_or(0)
      if rem_own > 0 {
        // Mixed case: borrows were merged into owning, use normal path
        p2_emit_use(ctx, name, site)
      }
      // Pure-borrow case: no-op, container stays alive
    }
    None => ()
  }
}

///|
fn p2_emit_snapshot(ctx : PerceusEmitCtx2) -> (Map[Int, Int], Map[Int, Int]) {
  let snap : Map[Int, Int] = {}
  ctx.remaining.each(fn(k, v) { snap[k] = v })
  let snap_own : Map[Int, Int] = {}
  ctx.remaining_owning.each(fn(k, v) { snap_own[k] = v })
  (snap, snap_own)
}

///|
fn p2_emit_restore(
  ctx : PerceusEmitCtx2,
  snap : (Map[Int, Int], Map[Int, Int]),
) -> Unit {
  snap.0.each(fn(k, v) { ctx.remaining[k] = v })
  snap.1.each(fn(k, v) { ctx.remaining_owning[k] = v })
}

///|
/// Merge branch emit results: in branches that consumed fewer tokens, emit drops.
/// Set remaining to the minimum across all branches (= most consumed path).
fn p2_emit_merge_branches(
  ctx : PerceusEmitCtx2,
  pre : (Map[Int, Int], Map[Int, Int]),
  branch_results : Array[((Map[Int, Int], Map[Int, Int]), String)],
) -> Unit {
  let pre_rem = pre.0
  // Find the minimum remaining per binding across branches
  // (= maximum consumed = worst case for ownership)
  let min_remaining : Map[Int, Int] = {}
  let min_remaining_own : Map[Int, Int] = {}
  let initialized : Map[Int, Bool] = {}
  for entry in branch_results {
    let snap = entry.0.0
    let snap_own = entry.0.1
    pre_rem.each(fn(id, _pre_val) {
      let post = snap.get(id).unwrap_or(0)
      let post_own = snap_own.get(id).unwrap_or(0)
      if !initialized.contains(id) {
        min_remaining[id] = post
        min_remaining_own[id] = post_own
        initialized[id] = true
      } else {
        let cur = min_remaining.get(id).unwrap_or(0)
        if post < cur {
          min_remaining[id] = post
        }
        let cur_own = min_remaining_own.get(id).unwrap_or(0)
        if post_own < cur_own {
          min_remaining_own[id] = post_own
        }
      }
    })
  }
  // Emit drops in branches that ended up with more remaining than the minimum
  for entry in branch_results {
    let snap = entry.0.0
    let branch_site = entry.1
    min_remaining.each(fn(id, min_rem) {
      let branch_rem = snap.get(id).unwrap_or(0)
      let excess = branch_rem - min_rem
      if excess > 0 {
        let name = ctx.names.get(id).unwrap_or("?")
        for _j = 0; _j < excess; _j = _j + 1 {
          ctx.actions.push({
            site: branch_site + ".end",
            kind: PerceusActionKind::Drop,
            name,
          })
        }
      }
    })
  }
  // Set remaining to the minimum
  min_remaining.each(fn(id, min_rem) { ctx.remaining[id] = min_rem })
  min_remaining_own.each(fn(id, min_rem) { ctx.remaining_owning[id] = min_rem })
}

///|
fn p2_emit_expr(
  ctx : PerceusEmitCtx2,
  expr : @core.Expr,
  site : String,
) -> Unit {
  match expr {
    @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::Char(..)
    | @core.Expr::String(..)
    | @core.Expr::Placeholder(..) => ()
    @core.Expr::Ident(name~, ..) => p2_emit_use(ctx, name, site)
    @core.Expr::Call(name~, args~, ..) => {
      p2_emit_use(ctx, name, site + ".callee")
      for i = 0; i < args.length(); i = i + 1 {
        p2_emit_expr(ctx, args[i].expr, site + ".arg[\{i.to_string()}]")
      }
    }
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) =>
      for i = 0; i < items.length(); i = i + 1 {
        p2_emit_expr(ctx, items[i], site + ".item[\{i.to_string()}]")
      }
    @core.Expr::TupleIndex(expr=inner, ..) =>
      // Field access borrows the container — no dup needed
      match inner {
        @core.Expr::Ident(name~, ..) =>
          p2_emit_borrow(ctx, name, site + ".inner")
        _ => p2_emit_expr(ctx, inner, site + ".inner")
      }
    @core.Expr::Spread(expr~, ..) => p2_emit_expr(ctx, expr, site + ".inner")
    @core.Expr::Record(fields~, ..) | @core.Expr::StructLit(fields~, ..) =>
      for i = 0; i < fields.length(); i = i + 1 {
        p2_emit_expr(ctx, fields[i].expr, site + ".field[\{i.to_string()}]")
      }
    @core.Expr::Map(fields~, ..) =>
      for i = 0; i < fields.length(); i = i + 1 {
        p2_emit_expr(ctx, fields[i].expr, site + ".field[\{i.to_string()}]")
      }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      p2_emit_expr(ctx, cond, site + ".cond")
      let pre = p2_emit_snapshot(ctx)
      p2_emit_block(ctx, then_body, site + ".then")
      let then_snap = p2_emit_snapshot(ctx)
      p2_emit_restore(ctx, pre)
      p2_emit_block(ctx, else_body, site + ".else")
      let else_snap = p2_emit_snapshot(ctx)
      p2_emit_merge_branches(ctx, pre, [
        (then_snap, site + ".then"),
        (else_snap, site + ".else"),
      ])
    }
    @core.Expr::Block(body~, ..) | @core.Expr::Handle(body~, ..) =>
      p2_emit_block(ctx, body, site + ".body")
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      p2_emit_expr(ctx, scrutinee, site + ".scrutinee")
      if arms.length() == 0 {
        return
      }
      let pre = p2_emit_snapshot(ctx)
      let branch_results : Array[((Map[Int, Int], Map[Int, Int]), String)] = []
      for i = 0; i < arms.length(); i = i + 1 {
        p2_emit_restore(ctx, pre)
        let arm_site = site + ".arm[\{i.to_string()}]"
        p2_emit_push_scope(ctx)
        let names = perceus_pattern_names(arms[i].pat)
        for name in names {
          let id = p2_emit_declare(ctx, name)
          // Drop pattern binding if unused (remaining == 0)
          let rem = ctx.remaining.get(id).unwrap_or(0)
          if rem == 0 {
            ctx.actions.push({
              site: arm_site + ".pat_bind",
              kind: PerceusActionKind::Drop,
              name,
            })
          }
        }
        match arms[i].cond {
          Some(cond) => p2_emit_expr(ctx, cond, arm_site + ".cond")
          None => ()
        }
        p2_emit_expr(ctx, arms[i].expr, arm_site + ".expr")
        p2_emit_pop_scope(ctx, arm_site)
        branch_results.push((p2_emit_snapshot(ctx), arm_site))
      }
      p2_emit_merge_branches(ctx, pre, branch_results)
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, ..) => {
      p2_emit_expr(ctx, iterable, site + ".iterable")
      p2_emit_push_scope(ctx)
      let vid = p2_emit_declare(ctx, value_name)
      let vrem = ctx.remaining.get(vid).unwrap_or(0)
      if vrem == 0 {
        ctx.actions.push({
          site: site + ".value_bind",
          kind: PerceusActionKind::Drop,
          name: value_name,
        })
      }
      match index_name {
        Some(idx) => {
          let iid = p2_emit_declare(ctx, idx)
          let irem = ctx.remaining.get(iid).unwrap_or(0)
          if irem == 0 {
            ctx.actions.push({
              site: site + ".index_bind",
              kind: PerceusActionKind::Drop,
              name: idx,
            })
          }
        }
        None => ()
      }
      p2_emit_block(ctx, body, site + ".body")
      p2_emit_pop_scope(ctx, site)
    }
    @core.Expr::Fn(params~, body~, ..) => {
      let captures = perceus_collect_capture_ids(
        body,
        ctx.scopes.map(fn(scope) {
          let ps : PerceusScope = { name_index: {} }
          scope.each(fn(name, id) { ps.name_index[name] = [id] })
          ps
        }),
        params,
      )
      for id in captures {
        let name = ctx.names.get(id).unwrap_or("?")
        p2_emit_use(ctx, name, site + ".capture[\{name}]")
      }
    }
    @core.Expr::While(cond~, body~, ..) => {
      let pre = p2_emit_snapshot(ctx)
      p2_emit_expr(ctx, cond, site + ".cond")
      p2_emit_block(ctx, body, site + ".body")
      let loop_snap = p2_emit_snapshot(ctx)
      p2_emit_merge_branches(ctx, pre, [
        (loop_snap, site + ".body"),
        (pre, site + ".skip"),
      ])
    }
    @core.Expr::Loop(params~, body~, ..) => {
      p2_emit_push_scope(ctx)
      for i = 0; i < params.length(); i = i + 1 {
        p2_emit_expr(
          ctx,
          params[i].init,
          site + ".param[\{i.to_string()}].init",
        )
        let id = p2_emit_declare(ctx, params[i].name)
        let rem = ctx.remaining.get(id).unwrap_or(0)
        if rem == 0 {
          ctx.actions.push({
            site: site + ".param[\{i.to_string()}].bind",
            kind: PerceusActionKind::Drop,
            name: params[i].name,
          })
        }
      }
      p2_emit_block(ctx, body, site + ".body")
      p2_emit_pop_scope(ctx, site)
    }
    @core.Expr::Break(value~, ..) =>
      match value {
        Some(expr) => p2_emit_expr(ctx, expr, site + ".value")
        None => ()
      }
    @core.Expr::Continue(args~, ..) =>
      for i = 0; i < args.length(); i = i + 1 {
        p2_emit_expr(ctx, args[i], site + ".arg[\{i.to_string()}]")
      }
    @core.Expr::Yield(expr~, ..) => p2_emit_expr(ctx, expr, site + ".value")
    @core.Expr::Perform(args~, ..) =>
      for i = 0; i < args.length(); i = i + 1 {
        p2_emit_expr(ctx, args[i].expr, site + ".arg[\{i.to_string()}]")
      }
    @core.Expr::StringInterp(parts~, ..) =>
      for i = 0; i < parts.length(); i = i + 1 {
        match parts[i] {
          @core.StringInterpPart::Expr(expr) =>
            p2_emit_expr(ctx, expr, site + ".part[\{i.to_string()}]")
          @core.StringInterpPart::Lit(_) => ()
        }
      }
  }
}

///|
fn p2_emit_stmt(
  ctx : PerceusEmitCtx2,
  stmt : @core.Stmt,
  site : String,
) -> Unit {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, ..)
    | @core.Stmt::ExportLet(rec~, name~, expr~, ..)
    | @core.Stmt::InternalExportLet(rec~, name~, expr~, ..) =>
      if rec {
        let id = p2_emit_declare(ctx, name)
        p2_emit_expr(ctx, expr, site + ".expr")
        let rem = ctx.remaining.get(id).unwrap_or(0)
        if rem == 0 {
          ctx.actions.push({
            site: site + ".after",
            kind: PerceusActionKind::Drop,
            name,
          })
        }
      } else {
        p2_emit_expr(ctx, expr, site + ".expr")
        let id = p2_emit_declare(ctx, name)
        let rem = ctx.remaining.get(id).unwrap_or(0)
        if rem == 0 {
          ctx.actions.push({
            site: site + ".after",
            kind: PerceusActionKind::Drop,
            name,
          })
        }
      }
    @core.Stmt::LetMut(name~, expr~, ..) => {
      p2_emit_expr(ctx, expr, site + ".expr")
      let id = p2_emit_declare(ctx, name)
      // For mutable vars, remaining == 0 only means no reads
      // The value still exists and may be overwritten via Assign
      let rem = ctx.remaining.get(id).unwrap_or(0)
      if rem == 0 {
        ctx.actions.push({
          site: site + ".after",
          kind: PerceusActionKind::Drop,
          name,
        })
      }
    }
    @core.Stmt::ExternLet(name~, ..) => {
      let id = p2_emit_declare(ctx, name)
      let _ = id
    }
    @core.Stmt::Assign(name~, expr~, ..) => {
      // Mutable reassignment: old value must be dropped
      match p2_emit_lookup(ctx, name) {
        Some(id) => {
          let name_str = ctx.names.get(id).unwrap_or("?")
          ctx.actions.push({
            site: site + ".old_value",
            kind: PerceusActionKind::Drop,
            name: name_str,
          })
        }
        None => ()
      }
      p2_emit_expr(ctx, expr, site + ".expr")
    }
    @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      p2_emit_expr(ctx, target, site + ".target")
      p2_emit_expr(ctx, index, site + ".index")
      p2_emit_expr(ctx, value, site + ".value")
    }
    @core.Stmt::LetPat(pat~, expr~, ..) => {
      p2_emit_expr(ctx, expr, site + ".expr")
      let names = perceus_pattern_names(pat)
      for name in names {
        let id = p2_emit_declare(ctx, name)
        let rem = ctx.remaining.get(id).unwrap_or(0)
        if rem == 0 {
          ctx.actions.push({
            site: site + ".after[\{name}]",
            kind: PerceusActionKind::Drop,
            name,
          })
        }
      }
    }
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, ..) => {
      p2_emit_expr(ctx, expr, site + ".expr")
      p2_emit_block(ctx, else_body, site + ".else")
      let names = perceus_pattern_names(pat)
      for name in names {
        let id = p2_emit_declare(ctx, name)
        let rem = ctx.remaining.get(id).unwrap_or(0)
        if rem == 0 {
          ctx.actions.push({
            site: site + ".after[\{name}]",
            kind: PerceusActionKind::Drop,
            name,
          })
        }
      }
    }
    @core.Stmt::Expr(expr~, ..) => p2_emit_expr(ctx, expr, site + ".expr")
    @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
      p2_emit_block(ctx, body, site + ".body")
    _ => ()
  }
}

///|
fn p2_emit_block(
  ctx : PerceusEmitCtx2,
  body : @core.Module,
  prefix : String,
) -> Unit {
  p2_emit_push_scope(ctx)
  for i = 0; i < body.stmts.length(); i = i + 1 {
    p2_emit_stmt(ctx, body.stmts[i], prefix + ".stmt[\{i.to_string()}]")
  }
  p2_emit_pop_scope(ctx, prefix)
}

///|
/// Build a branch-sensitive Perceus plan with proper dup/drop placement.
///
/// Two-pass approach:
/// - Pass 1: Count uses per binding (branch-max semantics)
/// - Pass 2: Emit dup/drop using remaining counts from pass 1
pub fn build_perceus_plan(mod : @core.Module) -> Array[PerceusAction] {
  // Pass 1: Count
  let count_ctx = p2_count_ctx_new()
  for stmt in mod.stmts {
    p2_count_stmt(count_ctx, stmt)
  }
  // Post-pass 1: Merge borrows into uses for mixed bindings.
  // Borrow optimization only applies to pure-borrow bindings (0 owning uses).
  // For mixed bindings (has both owning + borrow), treat borrows as owning
  // to prevent use-after-free if a borrow occurs after the last owning use.
  count_ctx.borrows.each(fn(id, b) {
    if b > 0 {
      let owning = count_ctx.uses.get(id).unwrap_or(0)
      if owning > 0 {
        count_ctx.uses[id] = owning + b
        count_ctx.borrows[id] = 0
      }
    }
  })
  // Pass 2: Emit
  let emit_ctx = p2_emit_ctx_new(
    count_ctx.names,
    count_ctx.uses,
    count_ctx.borrows,
  )
  for i = 0; i < mod.stmts.length(); i = i + 1 {
    p2_emit_stmt(emit_ctx, mod.stmts[i], "stmt[\{i.to_string()}]")
  }
  // Pop the initial scope to emit scope-end drops for any remaining bindings
  // (e.g., pure-borrow bindings that need cleanup)
  let n = mod.stmts.length()
  p2_emit_pop_scope(emit_ctx, "stmt[\{n.to_string()}]")
  // Pass 3: Optimize — cancel redundant dup-drop pairs
  optimize_perceus_actions(emit_ctx.actions)
}

///|
/// Cancel adjacent dup-drop pairs for the same variable at the same
/// statement scope. A dup followed immediately by a drop of the same
/// variable is only safe to cancel when both share the same top-level
/// statement index (i.e., no intervening use between them).
fn optimize_perceus_actions(
  actions : Array[PerceusAction],
) -> Array[PerceusAction] {
  let result : Array[PerceusAction] = []
  let mut i = 0
  while i < actions.length() {
    let action = actions[i]
    if action.kind == PerceusActionKind::Dup && i + 1 < actions.length() {
      let next = actions[i + 1]
      if next.kind == PerceusActionKind::Drop &&
        next.name == action.name &&
        perceus_same_stmt_scope(action.site, next.site) {
        // Skip both — the dup and drop cancel out within the same scope
        i = i + 2
        continue
      }
    }
    result.push(action)
    i = i + 1
  }
  result
}

///|
/// Check if two action sites share the same block-level scope.
/// Sites like "stmt[1].expr.then.stmt[0].expr.arg[0].before" and
/// "stmt[1].expr.then.scope_end" share block prefix "stmt[1].expr.then".
fn perceus_same_stmt_scope(site_a : String, site_b : String) -> Bool {
  let prefix_a = perceus_block_prefix(site_a)
  let prefix_b = perceus_block_prefix(site_b)
  prefix_a == prefix_b
}

///|
/// Extract block-level prefix: everything before the last ".stmt[N]" or
/// terminal component like ".scope_end", ".end", ".after", ".before".
/// For "stmt[1].expr.then.stmt[0].expr.arg[0].before" → "stmt[1].expr.then"
/// For "stmt[1].expr.then.scope_end" → "stmt[1].expr.then"
fn perceus_block_prefix(site : String) -> String {
  // Find the last occurrence of ".stmt[" in the site
  let mut last_dot_stmt = -1
  let mut i = 0
  while i + 5 < site.length() {
    if site[i] == '.' &&
      site[i + 1] == 's' &&
      site[i + 2] == 't' &&
      site[i + 3] == 'm' &&
      site[i + 4] == 't' &&
      site[i + 5] == '[' {
      last_dot_stmt = i
    }
    i = i + 1
  }
  if last_dot_stmt > 0 {
    return site[0:last_dot_stmt].to_string()
  }
  // No nested stmt — find last '.' for terminal suffixes
  let mut last_dot = -1
  let mut j = 0
  while j < site.length() {
    if site[j] == '.' {
      last_dot = j
    }
    j = j + 1
  }
  if last_dot > 0 {
    return site[0:last_dot].to_string()
  }
  site
}

///|
/// Heap simulation event: tracks allocations and frees in execution order.
pub enum PerceusSimEvent {
  Alloc(name~ : String)
  Free(name~ : String)
} derive(Show, Eq)

///|
/// Result of a Perceus memory simulation.
pub struct PerceusSimResult {
  total_allocs : Int
  total_drops : Int
  peak_bump : Int
  peak_rc : Int
  events : Array[PerceusSimEvent]
} derive(Show, Eq)

///|
/// Walk the AST and Perceus plan to produce a unified event stream,
/// then compute peak live object counts for bump vs RC allocation.
pub fn perceus_simulate(mod : @core.Module) -> PerceusSimResult {
  let plan = build_perceus_plan(mod)
  let events : Array[PerceusSimEvent] = []
  let pre_drops : Map[Int, Array[String]] = {}
  let post_drops : Map[Int, Array[String]] = {}
  for action in plan {
    if action.kind == PerceusActionKind::Drop {
      let idx = perceus_parse_top_stmt_index(action.site)
      if idx >= 0 {
        if action.site.contains(".old_value") {
          match pre_drops.get(idx) {
            Some(arr) => arr.push(action.name)
            None => pre_drops[idx] = [action.name]
          }
        } else {
          match post_drops.get(idx) {
            Some(arr) => arr.push(action.name)
            None => post_drops[idx] = [action.name]
          }
        }
      }
    }
  }
  let mut total_allocs = 0
  for i = 0; i < mod.stmts.length(); i = i + 1 {
    match pre_drops.get(i) {
      Some(names) =>
        for name in names {
          events.push(PerceusSimEvent::Free(name~))
        }
      None => ()
    }
    match mod.stmts[i] {
      @core.Stmt::Let(name~, ..)
      | @core.Stmt::ExportLet(name~, ..)
      | @core.Stmt::InternalExportLet(name~, ..) => {
        events.push(PerceusSimEvent::Alloc(name~))
        total_allocs += 1
      }
      @core.Stmt::LetMut(name~, ..) => {
        events.push(PerceusSimEvent::Alloc(name~))
        total_allocs += 1
      }
      @core.Stmt::Assign(name~, ..) => {
        events.push(PerceusSimEvent::Alloc(name~))
        total_allocs += 1
      }
      _ => ()
    }
    match post_drops.get(i) {
      Some(names) =>
        for name in names {
          events.push(PerceusSimEvent::Free(name~))
        }
      None => ()
    }
  }
  let mut live_rc = 0
  let mut peak_rc = 0
  let mut total_drops = 0
  for event in events {
    match event {
      PerceusSimEvent::Alloc(..) => {
        live_rc += 1
        if live_rc > peak_rc {
          peak_rc = live_rc
        }
      }
      PerceusSimEvent::Free(..) => {
        live_rc -= 1
        total_drops += 1
      }
    }
  }
  { total_allocs, total_drops, peak_bump: total_allocs, peak_rc, events }
}

///|
fn perceus_parse_top_stmt_index(site : String) -> Int {
  if site.length() < 6 {
    return -1
  }
  let start = 5
  let mut end = start
  while end < site.length() {
    if site[end] == ']' {
      break
    }
    end += 1
  }
  if end == start {
    return -1
  }
  let mut result = 0
  let mut i = start
  while i < end {
    let c = site[i]
    if c >= '0' && c <= '9' {
      result = result * 10 + (c.to_int() - '0'.to_int())
    } else {
      return -1
    }
    i += 1
  }
  result
}
