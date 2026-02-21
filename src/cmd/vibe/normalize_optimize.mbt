///|
fn normalize_optimize_module(
  ast : @vibe_core.Module,
) -> NormalizeOptimizeResult {
  let exported = normalize_collect_export_name_map(ast)
  let inlined = normalize_inline_single_use(ast, exported)
  normalize_fold_top_level_consts(
    inlined.normalized_module,
    inlined.rewritten_exprs,
  )
}

///|
fn normalize_collect_export_name_map(
  ast : @vibe_core.Module,
) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for name in normalize_collect_export_names(ast) {
    out[name] = true
  }
  out
}

///|
fn normalize_inline_single_use(
  ast : @vibe_core.Module,
  exported_names : Map[String, Bool],
) -> NormalizeOptimizeResult {
  let candidates : Map[String, NormalizeInlineCandidate] = {}
  for i, stmt in ast.stmts {
    match normalize_stmt_inline_candidate(stmt) {
      Some((name, body_expr)) =>
        if not(exported_names.contains(name)) {
          candidates[name] = { stmt_index: i, name, body_expr }
        }
      None => ()
    }
  }
  if candidates.length() == 0 {
    return { normalized_module: ast, rewritten_exprs: {} }
  }
  let ref_counts = normalize_count_candidate_refs_module(ast, candidates)
  let callsite_index_by_name : Map[String, Int] = {}
  for i, stmt in ast.stmts {
    match normalize_stmt_inline_call_name(stmt, candidates) {
      Some(name) =>
        match callsite_index_by_name.get(name) {
          Some(_) => callsite_index_by_name[name] = -1
          None => callsite_index_by_name[name] = i
        }
      None => ()
    }
  }
  let callsite_name_by_index : Map[Int, String] = {}
  let dropped_candidate_names : Map[String, Bool] = {}
  for name, candidate in candidates {
    let ref_count = match ref_counts.get(name) {
      Some(v) => v
      None => 0
    }
    match callsite_index_by_name.get(name) {
      Some(callsite_idx) =>
        if callsite_idx >= 0 && ref_count == 1 {
          callsite_name_by_index[callsite_idx] = name
          dropped_candidate_names[name] = true
          dropped_candidate_names[candidate.name] = true
        }
      None => ()
    }
  }
  if callsite_name_by_index.length() == 0 {
    return { normalized_module: ast, rewritten_exprs: {} }
  }
  let rewritten_exprs : Map[String, @vibe_core.Expr] = {}
  let out_stmts : Array[@vibe_core.Stmt] = []
  for i, stmt in ast.stmts {
    match callsite_name_by_index.get(i) {
      Some(name) =>
        match candidates.get(name) {
          Some(candidate) => {
            let rewritten = normalize_stmt_replace_expr(
              stmt,
              candidate.body_expr,
            )
            rewritten_exprs[normalize_stmt_key(stmt)] = candidate.body_expr
            out_stmts.push(rewritten)
          }
          None => out_stmts.push(stmt)
        }
      None => {
        let mut drop_stmt = false
        match normalize_stmt_def_name(stmt) {
          Some(name) =>
            if dropped_candidate_names.contains(name) {
              match candidates.get(name) {
                Some(candidate) =>
                  if candidate.stmt_index == i {
                    drop_stmt = true
                  }
                None => ()
              }
            }
          None => ()
        }
        if not(drop_stmt) {
          out_stmts.push(stmt)
        }
      }
    }
  }
  {
    normalized_module: @vibe_core.Module::{ stmts: out_stmts },
    rewritten_exprs,
  }
}

///|
fn normalize_stmt_inline_candidate(
  stmt : @vibe_core.Stmt,
) -> (String, @vibe_core.Expr)? {
  match stmt {
    @vibe_core.Stmt::Let(rec~, name~, expr~, ..) =>
      if rec {
        None
      } else {
        match expr {
          @vibe_core.Expr::Fn(type_params~, params~, effects~, body~, ..) =>
            if type_params.length() > 0 ||
              params.length() > 0 ||
              effects.length() > 0 ||
              body.stmts.length() != 1 {
              None
            } else {
              match body.stmts[0] {
                @vibe_core.Stmt::Expr(expr=body_expr, ..) =>
                  Some((name, body_expr))
                _ => None
              }
            }
          _ => None
        }
      }
    _ => None
  }
}

///|
fn normalize_stmt_inline_call_name(
  stmt : @vibe_core.Stmt,
  candidates : Map[String, NormalizeInlineCandidate],
) -> String? {
  let expr = match stmt {
    @vibe_core.Stmt::Let(expr~, ..) | @vibe_core.Stmt::ExportLet(expr~, ..) =>
      Some(expr)
    _ => None
  }
  match expr {
    Some(@vibe_core.Expr::Call(name~, type_args~, args~, ..)) =>
      if candidates.contains(name) &&
        type_args.length() == 0 &&
        args.length() == 0 {
        Some(name)
      } else {
        None
      }
    _ => None
  }
}

///|
fn normalize_stmt_replace_expr(
  stmt : @vibe_core.Stmt,
  next_expr : @vibe_core.Expr,
) -> @vibe_core.Stmt {
  match stmt {
    @vibe_core.Stmt::Let(rec~, name~, span~, ..) =>
      @vibe_core.Stmt::Let(rec~, name~, expr=next_expr, span~)
    @vibe_core.Stmt::ExportLet(rec~, name~, span~, ..) =>
      @vibe_core.Stmt::ExportLet(rec~, name~, expr=next_expr, span~)
    _ => stmt
  }
}

///|
fn normalize_count_candidate_refs_module(
  mod : @vibe_core.Module,
  candidates : Map[String, NormalizeInlineCandidate],
) -> Map[String, Int] {
  let counts : Map[String, Int] = {}
  let candidate_names : Map[String, Bool] = {}
  for name, _ in candidates {
    candidate_names[name] = true
  }
  for stmt in mod.stmts {
    @vibe_core.walk_stmt_refs(
      stmt,
      @vibe_core.WalkerScope::new(),
      candidate_names,
      fn(name, bound, cands) {
        if bound.contains(name) || not(cands.contains(name)) {
          return
        }
        match counts.get(name) {
          Some(v) => counts[name] = v + 1
          None => counts[name] = 1
        }
      },
    )
  }
  counts
}

///|
fn normalize_fold_top_level_consts(
  mod : @vibe_core.Module,
  rewritten_exprs : Map[String, @vibe_core.Expr],
) -> NormalizeOptimizeResult {
  let out_rewrites = normalize_clone_expr_map(rewritten_exprs)
  let out_stmts : Array[@vibe_core.Stmt] = []
  for stmt in mod.stmts {
    let next_stmt = match stmt {
      @vibe_core.Stmt::Let(expr~, ..) | @vibe_core.Stmt::ExportLet(expr~, ..) =>
        match normalize_fold_const_expr(expr) {
          Some(folded) =>
            match normalize_render_expr(folded) {
              Some(_) => {
                out_rewrites[normalize_stmt_key(stmt)] = folded
                normalize_stmt_replace_expr(stmt, folded)
              }
              None => stmt
            }
          None => stmt
        }
      _ => stmt
    }
    out_stmts.push(next_stmt)
  }
  {
    normalized_module: @vibe_core.Module::{ stmts: out_stmts },
    rewritten_exprs: out_rewrites,
  }
}

///|
fn normalize_clone_expr_map(
  m : Map[String, @vibe_core.Expr],
) -> Map[String, @vibe_core.Expr] {
  let out : Map[String, @vibe_core.Expr] = {}
  for k, v in m {
    out[k] = v
  }
  out
}

///|
fn normalize_fold_const_expr(expr : @vibe_core.Expr) -> @vibe_core.Expr? {
  match normalize_eval_const_expr(expr) {
    Some(value) =>
      if normalize_expr_is_literal(expr) {
        None
      } else {
        Some(value)
      }
    None => None
  }
}

///|
fn normalize_expr_is_literal(expr : @vibe_core.Expr) -> Bool {
  match expr {
    @vibe_core.Expr::Int(..)
    | @vibe_core.Expr::Float(..)
    | @vibe_core.Expr::Double(..)
    | @vibe_core.Expr::Bool(..)
    | @vibe_core.Expr::String(..) => true
    _ => false
  }
}

///|
fn normalize_eval_const_expr(expr : @vibe_core.Expr) -> @vibe_core.Expr? {
  match expr {
    @vibe_core.Expr::Int(..)
    | @vibe_core.Expr::Float(..)
    | @vibe_core.Expr::Double(..)
    | @vibe_core.Expr::Bool(..)
    | @vibe_core.Expr::String(..) => Some(expr)
    @vibe_core.Expr::Call(name~, type_args~, args~, span~) => {
      if type_args.length() > 0 {
        return None
      }
      let values : Array[@vibe_core.Expr] = []
      for arg in args {
        if arg.label is Some(_) {
          return None
        }
        match normalize_eval_const_expr(arg.expr) {
          Some(v) => values.push(v)
          None => return None
        }
      }
      normalize_fold_builtin_call(name, values, span)
    }
    _ => None
  }
}

///|
fn normalize_fold_builtin_call(
  name : String,
  args : Array[@vibe_core.Expr],
  span : @vibe_core.Span,
) -> @vibe_core.Expr? {
  match name {
    "__add" =>
      if args.length() == 2 {
        match (normalize_expr_as_int(args[0]), normalize_expr_as_int(args[1])) {
          (Some(left), Some(right)) =>
            Some(@vibe_core.Expr::Int(value=left + right, span~))
          _ => None
        }
      } else {
        None
      }
    "__sub" =>
      if args.length() == 2 {
        match (normalize_expr_as_int(args[0]), normalize_expr_as_int(args[1])) {
          (Some(left), Some(right)) =>
            Some(@vibe_core.Expr::Int(value=left - right, span~))
          _ => None
        }
      } else {
        None
      }
    "__mul" =>
      if args.length() == 2 {
        match (normalize_expr_as_int(args[0]), normalize_expr_as_int(args[1])) {
          (Some(left), Some(right)) =>
            Some(@vibe_core.Expr::Int(value=left * right, span~))
          _ => None
        }
      } else {
        None
      }
    "__div" =>
      if args.length() == 2 {
        match (normalize_expr_as_int(args[0]), normalize_expr_as_int(args[1])) {
          (Some(_), Some(0L)) => None
          (Some(left), Some(right)) =>
            Some(@vibe_core.Expr::Int(value=left / right, span~))
          _ => None
        }
      } else {
        None
      }
    "__mod" =>
      if args.length() == 2 {
        match (normalize_expr_as_int(args[0]), normalize_expr_as_int(args[1])) {
          (Some(_), Some(0L)) => None
          (Some(left), Some(right)) =>
            Some(@vibe_core.Expr::Int(value=left % right, span~))
          _ => None
        }
      } else {
        None
      }
    "__eq" =>
      if args.length() == 2 {
        match (normalize_expr_as_int(args[0]), normalize_expr_as_int(args[1])) {
          (Some(left), Some(right)) =>
            Some(@vibe_core.Expr::Bool(value=left == right, span~))
          _ =>
            match
              (normalize_expr_as_bool(args[0]), normalize_expr_as_bool(args[1])) {
              (Some(left), Some(right)) =>
                Some(@vibe_core.Expr::Bool(value=left == right, span~))
              _ =>
                match
                  (
                    normalize_expr_as_string(args[0]),
                    normalize_expr_as_string(args[1]),
                  ) {
                  (Some(left), Some(right)) =>
                    Some(@vibe_core.Expr::Bool(value=left == right, span~))
                  _ => None
                }
            }
        }
      } else {
        None
      }
    "__lt" =>
      if args.length() == 2 {
        match (normalize_expr_as_int(args[0]), normalize_expr_as_int(args[1])) {
          (Some(left), Some(right)) =>
            Some(@vibe_core.Expr::Bool(value=left < right, span~))
          _ => None
        }
      } else {
        None
      }
    "and" =>
      if args.length() == 2 {
        match
          (normalize_expr_as_bool(args[0]), normalize_expr_as_bool(args[1])) {
          (Some(left), Some(right)) =>
            Some(@vibe_core.Expr::Bool(value=left && right, span~))
          _ => None
        }
      } else {
        None
      }
    "or" =>
      if args.length() == 2 {
        match
          (normalize_expr_as_bool(args[0]), normalize_expr_as_bool(args[1])) {
          (Some(left), Some(right)) =>
            Some(@vibe_core.Expr::Bool(value=left || right, span~))
          _ => None
        }
      } else {
        None
      }
    "not" =>
      if args.length() == 1 {
        match normalize_expr_as_bool(args[0]) {
          Some(value) => Some(@vibe_core.Expr::Bool(value=not(value), span~))
          None => None
        }
      } else {
        None
      }
    _ => None
  }
}

///|
fn normalize_expr_as_int(expr : @vibe_core.Expr) -> Int64? {
  match expr {
    @vibe_core.Expr::Int(value~, ..) => Some(value)
    _ => None
  }
}

///|
fn normalize_expr_as_bool(expr : @vibe_core.Expr) -> Bool? {
  match expr {
    @vibe_core.Expr::Bool(value~, ..) => Some(value)
    _ => None
  }
}

///|
fn normalize_expr_as_string(expr : @vibe_core.Expr) -> String? {
  match expr {
    @vibe_core.Expr::String(value~, ..) => Some(value)
    _ => None
  }
}
