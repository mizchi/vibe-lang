///|
fn is_threads_builtin_name(name : String) -> Bool {
  match name {
    "Threads::probe_wat"
    | "Threads::runtime_hints"
    | "Threads::channel_new"
    | "Threads::send"
    | "Threads::recv"
    | "Threads::spawn"
    | "Threads::wait" => true
    _ => false
  }
}

///|
fn is_stateful_threads_builtin_name(name : String) -> Bool {
  match name {
    "Threads::channel_new"
    | "Threads::send"
    | "Threads::recv"
    | "Threads::spawn"
    | "Threads::wait" => true
    _ => false
  }
}

///|
fn expr_uses_call_or_perform_matching(
  expr : @vibe_core.Expr,
  is_call_name : (String) -> Bool,
  is_perform_effect_name : (String) -> Bool,
) -> Bool {
  match expr {
    @vibe_core.Expr::Call(name~, args~, ..) => {
      if is_call_name(name) {
        return true
      }
      for arg in args {
        if expr_uses_call_or_perform_matching(
            arg.expr,
            is_call_name,
            is_perform_effect_name,
          ) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Tuple(items~, ..) => {
      for item in items {
        if expr_uses_call_or_perform_matching(
            item, is_call_name, is_perform_effect_name,
          ) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::TupleIndex(expr~, ..) =>
      expr_uses_call_or_perform_matching(
        expr, is_call_name, is_perform_effect_name,
      )
    @vibe_core.Expr::Record(fields~, ..)
    | @vibe_core.Expr::StructLit(fields~, ..) => {
      for field in fields {
        if expr_uses_call_or_perform_matching(
            field.expr,
            is_call_name,
            is_perform_effect_name,
          ) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Array(items~, ..) => {
      for item in items {
        if expr_uses_call_or_perform_matching(
            item, is_call_name, is_perform_effect_name,
          ) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Map(fields~, ..) => {
      for field in fields {
        if expr_uses_call_or_perform_matching(
            field.expr,
            is_call_name,
            is_perform_effect_name,
          ) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::If(cond~, then_body~, else_body~, ..) =>
      expr_uses_call_or_perform_matching(
        cond, is_call_name, is_perform_effect_name,
      ) ||
      module_uses_call_or_perform_matching(
        then_body, is_call_name, is_perform_effect_name,
      ) ||
      module_uses_call_or_perform_matching(
        else_body, is_call_name, is_perform_effect_name,
      )
    @vibe_core.Expr::Block(body~, ..) =>
      module_uses_call_or_perform_matching(
        body, is_call_name, is_perform_effect_name,
      )
    @vibe_core.Expr::Match(scrutinee~, arms~, ..) => {
      if expr_uses_call_or_perform_matching(
          scrutinee, is_call_name, is_perform_effect_name,
        ) {
        return true
      }
      for arm in arms {
        if expr_uses_call_or_perform_matching(
            arm.expr,
            is_call_name,
            is_perform_effect_name,
          ) {
          return true
        }
        match arm.cond {
          Some(cond) =>
            if expr_uses_call_or_perform_matching(
                cond, is_call_name, is_perform_effect_name,
              ) {
              return true
            }
          None => ()
        }
      }
      false
    }
    @vibe_core.Expr::ForIn(iterable~, body~, ..) =>
      expr_uses_call_or_perform_matching(
        iterable, is_call_name, is_perform_effect_name,
      ) ||
      module_uses_call_or_perform_matching(
        body, is_call_name, is_perform_effect_name,
      )
    @vibe_core.Expr::Fn(body~, ..) =>
      module_uses_call_or_perform_matching(
        body, is_call_name, is_perform_effect_name,
      )
    @vibe_core.Expr::While(cond~, body~, ..) =>
      expr_uses_call_or_perform_matching(
        cond, is_call_name, is_perform_effect_name,
      ) ||
      module_uses_call_or_perform_matching(
        body, is_call_name, is_perform_effect_name,
      )
    @vibe_core.Expr::Loop(params~, body~, ..) => {
      for param in params {
        if expr_uses_call_or_perform_matching(
            param.init,
            is_call_name,
            is_perform_effect_name,
          ) {
          return true
        }
      }
      module_uses_call_or_perform_matching(
        body, is_call_name, is_perform_effect_name,
      )
    }
    @vibe_core.Expr::Break(value~, ..) =>
      match value {
        Some(v) =>
          expr_uses_call_or_perform_matching(
            v, is_call_name, is_perform_effect_name,
          )
        None => false
      }
    @vibe_core.Expr::Continue(args~, ..) => {
      for arg in args {
        if expr_uses_call_or_perform_matching(
            arg, is_call_name, is_perform_effect_name,
          ) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Return(value~, ..) =>
      match value {
        Some(v) =>
          expr_uses_call_or_perform_matching(
            v, is_call_name, is_perform_effect_name,
          )
        None => false
      }
    @vibe_core.Expr::Yield(expr~, ..) =>
      expr_uses_call_or_perform_matching(
        expr, is_call_name, is_perform_effect_name,
      )
    @vibe_core.Expr::Handle(body~, arms~, ..) => {
      if module_uses_call_or_perform_matching(
          body, is_call_name, is_perform_effect_name,
        ) {
        return true
      }
      for arm in arms {
        if expr_uses_call_or_perform_matching(
            arm.expr,
            is_call_name,
            is_perform_effect_name,
          ) {
          return true
        }
        match arm.cond {
          Some(cond) =>
            if expr_uses_call_or_perform_matching(
                cond, is_call_name, is_perform_effect_name,
              ) {
              return true
            }
          None => ()
        }
      }
      false
    }
    @vibe_core.Expr::Perform(effect_name~, args~, ..) => {
      if is_perform_effect_name(effect_name) {
        return true
      }
      for arg in args {
        if expr_uses_call_or_perform_matching(
            arg.expr,
            is_call_name,
            is_perform_effect_name,
          ) {
          return true
        }
      }
      false
    }
    _ => false
  }
}

///|
fn stmt_uses_call_or_perform_matching(
  stmt : @vibe_core.Stmt,
  is_call_name : (String) -> Bool,
  is_perform_effect_name : (String) -> Bool,
) -> Bool {
  match stmt {
    @vibe_core.Stmt::Let(expr~, ..)
    | @vibe_core.Stmt::LetMut(expr~, ..)
    | @vibe_core.Stmt::Assign(expr~, ..)
    | @vibe_core.Stmt::LetPat(expr~, ..)
    | @vibe_core.Stmt::Expr(expr~, ..)
    | @vibe_core.Stmt::ExportLet(expr~, ..)
    | @vibe_core.Stmt::InternalExportLet(expr~, ..) =>
      expr_uses_call_or_perform_matching(
        expr, is_call_name, is_perform_effect_name,
      )
    @vibe_core.Stmt::IndexAssign(target~, index~, value~, ..) =>
      expr_uses_call_or_perform_matching(
        target, is_call_name, is_perform_effect_name,
      ) ||
      expr_uses_call_or_perform_matching(
        index, is_call_name, is_perform_effect_name,
      ) ||
      expr_uses_call_or_perform_matching(
        value, is_call_name, is_perform_effect_name,
      )
    @vibe_core.Stmt::LetPatElse(expr~, else_body~, ..) =>
      expr_uses_call_or_perform_matching(
        expr, is_call_name, is_perform_effect_name,
      ) ||
      module_uses_call_or_perform_matching(
        else_body, is_call_name, is_perform_effect_name,
      )
    @vibe_core.Stmt::Test(body~, ..) | @vibe_core.Stmt::Bench(body~, ..) =>
      module_uses_call_or_perform_matching(
        body, is_call_name, is_perform_effect_name,
      )
    _ => false
  }
}

///|
fn module_uses_call_or_perform_matching(
  ast : @vibe_core.Module,
  is_call_name : (String) -> Bool,
  is_perform_effect_name : (String) -> Bool,
) -> Bool {
  for stmt in ast.stmts {
    if stmt_uses_call_or_perform_matching(
        stmt, is_call_name, is_perform_effect_name,
      ) {
      return true
    }
  }
  false
}

///|
fn never_match_effect_name(_name : String) -> Bool {
  false
}

///|
fn module_uses_threads_builtins(ast : @vibe_core.Module) -> Bool {
  module_uses_call_or_perform_matching(
    ast, is_threads_builtin_name, never_match_effect_name,
  )
}

///|
fn module_uses_stateful_threads_builtins(ast : @vibe_core.Module) -> Bool {
  module_uses_call_or_perform_matching(
    ast, is_stateful_threads_builtin_name, never_match_effect_name,
  )
}

///|
fn require_unstable_threads_for_module(
  ast : @vibe_core.Module,
  features : @runtime.RuntimeFeatureFlags,
) -> String? {
  if !module_uses_threads_builtins(ast) {
    return None
  }
  if !features.is_unstable_threads_enabled() {
    Some("Threads builtins require --unstable-threads")
  } else {
    let backend_id = features.thread_backend_id()
    let default_backend_id = @runtime.RuntimeFeatureFlags::default_thread_backend_id()
    if backend_id == default_backend_id {
      return None
    }
    if !module_uses_stateful_threads_builtins(ast) {
      return None
    }
    let backend = match @threads.thread_backend_from_id(backend_id) {
      Some(v) => v
      None => return Some("unknown Threads backend: " + backend_id)
    }
    if @threads.thread_backend_has_compiled_stateful_lowering(backend) {
      return None
    }
    Some(
      "Threads backend " +
      backend_id +
      " is not connected to compiled stateful lowering yet; use --thread-backend " +
      default_backend_id,
    )
  }
}

///|
fn require_unstable_threads_for_db_entry(
  db : @runtime.VibeDb,
  entry : String,
  features : @runtime.RuntimeFeatureFlags,
) -> String? {
  let ast = db.ast(entry)
  let detect_ast = @runtime_compile.bundle_for_wasm_no_dce(db, entry, ast)
  require_unstable_threads_for_module(detect_ast, features)
}
