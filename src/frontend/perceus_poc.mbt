///|
/// Lexical Perceus planning PoC.
///
/// This pass is intentionally narrow:
/// - it works on core AST before type-guided ownership filtering,
/// - it treats local identifier uses as consuming one ownership token,
/// - it models closure capture as one use at closure creation time,
/// - it is not yet path-sensitive for branches / loops.
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
