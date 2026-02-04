///|
/// Purity inference for effect-aware caching.
pub struct PurityInfo {
  expr : Bool
  value : Bool
} derive(Show, Eq)

///|
pub fn purity_for_let(
  env : TypeEnv,
  rec : Bool,
  name : String,
  expr : Expr,
) -> PurityInfo {
  let locals : Map[String, Bool] = {}
  if rec {
    locals[name] = true
  }
  match expr {
    Expr::Fn(params~, ret~, effects=_, body~) => {
      let _ = ret
      let fn_locals : Map[String, Bool] = {}
      for key, val in locals {
        fn_locals[key] = val
      }
      for param in params {
        fn_locals[param.name] = true
      }
      let body_pure = purity_block_inner(env, body, fn_locals)
      PurityInfo::{ expr: true, value: body_pure }
    }
    _ => {
      let expr_pure = purity_expr_inner(env, expr, locals)
      PurityInfo::{ expr: expr_pure, value: expr_pure }
    }
  }
}

///|
pub fn purity_expr(env : TypeEnv, expr : Expr) -> Bool {
  purity_expr_inner(env, expr, {})
}

///|
pub fn purity_block(env : TypeEnv, body : Module) -> Bool {
  purity_block_inner(env, body, {})
}

///|
fn purity_expr_inner(
  env : TypeEnv,
  expr : Expr,
  locals : Map[String, Bool],
) -> Bool {
  match expr {
    Expr::Int(_) => true
    Expr::Bool(_) => true
    Expr::String(_) => true
    Expr::Ident(name) =>
      match locals.get(name) {
        Some(pure) => pure
        None =>
          match env.get_purity(name) {
            Some(pure) => pure
            None => is_pure_builtin_name(name)
          }
      }
    Expr::Call(name~, args~) =>
      if is_effectful_call_name(name) {
        false
      } else {
        let callee_pure = if is_pure_builtin_name(name) || is_ctor_name(name) {
          true
        } else {
          match locals.get(name) {
            Some(pure) => pure
            None =>
              match env.get_purity(name) {
                Some(pure) => pure
                None => false
              }
          }
        }
        if not(callee_pure) {
          false
        } else {
          let mut ok = true
          for arg in args {
            if not(purity_expr_inner(env, arg.expr, locals)) {
              ok = false
              break
            }
          }
          ok
        }
      }
    Expr::Tuple(items) => purity_all(env, items, locals)
    Expr::Record(fields) => {
      let mut ok = true
      for field in fields {
        if not(purity_expr_inner(env, field.expr, locals)) {
          ok = false
          break
        }
      }
      ok
    }
    Expr::Array(items) => purity_all(env, items, locals)
    Expr::Map(fields) => {
      let mut ok = true
      for field in fields {
        if not(purity_expr_inner(env, field.expr, locals)) {
          ok = false
          break
        }
      }
      ok
    }
    Expr::If(cond~, then_body~, else_body~) =>
      purity_expr_inner(env, cond, locals) &&
      purity_block_inner(env, then_body, locals) &&
      purity_block_inner(env, else_body, locals)
    Expr::Block(body~) => purity_block_inner(env, body, locals)
    Expr::Try(try_body~, catch_body~) =>
      purity_block_inner(env, try_body, locals) &&
      purity_block_inner(env, catch_body, locals)
    Expr::Match(scrutinee~, arms~) =>
      if not(purity_expr_inner(env, scrutinee, locals)) {
        false
      } else {
        let mut ok = true
        for arm in arms {
          let arm_locals = clone_bool_map(locals)
          bind_pattern_names(arm_locals, arm.pat)
          match arm.cond {
            Some(cond) =>
              if not(purity_expr_inner(env, cond, arm_locals)) {
                ok = false
                break
              }
            None => ()
          }
          if not(purity_expr_inner(env, arm.expr, arm_locals)) {
            ok = false
            break
          }
        }
        ok
      }
    Expr::Do(_) => false
    Expr::Fn(..) => true
  }
}

///|
fn purity_block_inner(
  env : TypeEnv,
  body : Module,
  locals : Map[String, Bool],
) -> Bool {
  let scope = clone_bool_map(locals)
  let mut ok = true
  for stmt in body.stmts {
    match stmt {
      Stmt::Let(rec~, name~, expr~) => {
        let info = purity_for_let_in_scope(env, rec, name, expr, scope)
        if not(info.expr) {
          ok = false
          break
        }
        scope[name] = info.value
      }
      Stmt::Expr(expr~) =>
        if not(purity_expr_inner(env, expr, scope)) {
          ok = false
          break
        }
      Stmt::Test(..) => ()
      _ => ()
    }
  }
  ok
}

///|
fn purity_for_let_in_scope(
  env : TypeEnv,
  rec : Bool,
  name : String,
  expr : Expr,
  locals : Map[String, Bool],
) -> PurityInfo {
  let scope = clone_bool_map(locals)
  if rec {
    scope[name] = true
  }
  match expr {
    Expr::Fn(params~, ret~, effects=_, body~) => {
      let _ = ret
      let fn_locals = clone_bool_map(scope)
      for param in params {
        fn_locals[param.name] = true
      }
      let body_pure = purity_block_inner(env, body, fn_locals)
      PurityInfo::{ expr: true, value: body_pure }
    }
    _ => {
      let expr_pure = purity_expr_inner(env, expr, scope)
      PurityInfo::{ expr: expr_pure, value: expr_pure }
    }
  }
}

///|
fn purity_all(
  env : TypeEnv,
  items : Array[Expr],
  locals : Map[String, Bool],
) -> Bool {
  let mut ok = true
  for item in items {
    if not(purity_expr_inner(env, item, locals)) {
      ok = false
      break
    }
  }
  ok
}

///|
fn bind_pattern_names(bound : Map[String, Bool], pat : Pat) -> Unit {
  match pat {
    Pat::Wildcard => ()
    Pat::Bind(name) => bound[name] = true
    Pat::Ctor(name~, args~) => {
      let _ = name
      for arg in args {
        bind_pattern_names(bound, arg)
      }
    }
    Pat::Tuple(items) =>
      for item in items {
        bind_pattern_names(bound, item)
      }
    Pat::Record(fields) =>
      for field in fields {
        bind_pattern_names(bound, field.pat)
      }
    Pat::Int(_) => ()
    Pat::Bool(_) => ()
    Pat::String(_) => ()
  }
}

///|
fn is_effectful_call_name(name : String) -> Bool {
  name == "sh" ||
  name == "array_builder" ||
  name == "array_builder_push" ||
  name == "array_builder_freeze" ||
  name == "map_builder" ||
  name == "map_builder_set" ||
  name == "map_builder_freeze"
}

///|
fn is_pure_builtin_name(name : String) -> Bool {
  name == "path" ||
  name == "addr" ||
  name == "array_length" ||
  name == "array_get" ||
  name == "map_get" ||
  name == "string_length" ||
  name == "string_char_code_at" ||
  name == "string_substring" ||
  name == "string_concat" ||
  name == "string_equals" ||
  name == "__add" ||
  name == "__sub" ||
  name == "__mul" ||
  name == "__div" ||
  name == "__eq" ||
  name == "__lt" ||
  name == "__assert" ||
  name == "record_set"
}

///|
fn clone_bool_map(src : Map[String, Bool]) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for key, val in src {
    out[key] = val
  }
  out
}
