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
  expr : @core.Expr,
) -> PurityInfo {
  let locals : Map[String, Bool] = {}
  if rec {
    locals[name] = true
  }
  match expr {
    @core.Expr::Fn(params~, ret~, effects=_, body~, span~, ..) => {
      let _ = span
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
pub fn purity_expr(env : TypeEnv, expr : @core.Expr) -> Bool {
  purity_expr_inner(env, expr, {})
}

///|
pub fn purity_block(env : TypeEnv, body : @core.Module) -> Bool {
  purity_block_inner(env, body, {})
}

///|
fn purity_expr_inner(
  env : TypeEnv,
  expr : @core.Expr,
  locals : Map[String, Bool],
) -> Bool {
  match expr {
    @core.Expr::Int(value~, span~) => {
      let _ = value
      let _ = span
      true
    }
    @core.Expr::Float(value~, span~) => {
      let _ = value
      let _ = span
      true
    }
    @core.Expr::Double(value~, span~) => {
      let _ = value
      let _ = span
      true
    }
    @core.Expr::Bool(value~, span~) => {
      let _ = value
      let _ = span
      true
    }
    @core.Expr::String(value~, span~) => {
      let _ = value
      let _ = span
      true
    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      match locals.get(name) {
        Some(pure) => pure
        None =>
          match env.get_purity(name) {
            Some(pure) => pure
            None => is_pure_builtin_name(name)
          }
      }
    }
    @core.Expr::Placeholder(..) =>
      // Placeholder should be desugared; treat as pure
      true
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      if is_effectful_call_name(name) {
        false
      } else {
        let callee_pure = if is_pure_builtin_name(name) ||
          @core.is_ctor_name(name) {
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
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      purity_all(env, items, locals)
    }
    @core.Expr::TupleIndex(expr~, ..) => purity_expr_inner(env, expr, locals)
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      let mut ok = true
      for field in fields {
        if not(purity_expr_inner(env, field.expr, locals)) {
          ok = false
          break
        }
      }
      ok
    }
    @core.Expr::StructLit(fields~, span~, ..) => {
      let _ = span
      let mut ok = true
      for field in fields {
        if not(purity_expr_inner(env, field.expr, locals)) {
          ok = false
          break
        }
      }
      ok
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      purity_all(env, items, locals)
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      let mut ok = true
      for field in fields {
        if not(purity_expr_inner(env, field.expr, locals)) {
          ok = false
          break
        }
      }
      ok
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      purity_expr_inner(env, cond, locals) &&
      purity_block_inner(env, then_body, locals) &&
      purity_block_inner(env, else_body, locals)
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      purity_block_inner(env, body, locals)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      purity_block_inner(env, try_body, locals) &&
      purity_block_inner(env, catch_body, locals)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
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
    }
    @core.Expr::Do(body~, span~) => {
      let _ = body
      let _ = span
      false
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
      let _ = params
      let _ = ret
      let _ = effects
      let _ = body
      let _ = span
      true
    }
    @core.Expr::While(..) => false
    @core.Expr::Break(..) | @core.Expr::Continue(..) => false
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      purity_expr_inner(env, value, locals)
    }
    @core.Expr::Await(..) | @core.Expr::Yield(..) => false
  }
}

///|
fn purity_block_inner(
  env : TypeEnv,
  body : @core.Module,
  locals : Map[String, Bool],
) -> Bool {
  let scope = clone_bool_map(locals)
  let mut ok = true
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
        let info = purity_for_let_in_scope(env, rec, name, expr, scope)
        if not(info.expr) {
          ok = false
          break
        }
        scope[name] = info.value
      }
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        if not(purity_expr_inner(env, expr, scope)) {
          ok = false
          break
        }
      }
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = name
        let _ = body
        let _ = span
      }
      @core.Stmt::Bench(name~, body~, span~) => {
        let _ = name
        let _ = body
        let _ = span
      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = span
        if not(purity_expr_inner(env, expr, scope)) {
          ok = false
          break
        }
        bind_pattern_names(scope, pat)
      }
      @core.Stmt::LetMut(..) | @core.Stmt::Assign(..) => {
        ok = false
        break
      }
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
  expr : @core.Expr,
  locals : Map[String, Bool],
) -> PurityInfo {
  let scope = clone_bool_map(locals)
  if rec {
    scope[name] = true
  }
  match expr {
    @core.Expr::Fn(params~, ret~, effects=_, body~, span~, ..) => {
      let _ = span
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
  items : Array[@core.Expr],
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
pub fn bind_pattern_names(bound : Map[String, Bool], pat : @core.Pat) -> Unit {
  match pat {
    @core.Pat::Wildcard(span~) => {
      let _ = span
    }
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      bound[name] = true
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = span
      for arg in args {
        bind_pattern_names(bound, arg)
      }
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        bind_pattern_names(bound, item)
      }
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        bind_pattern_names(bound, field.pat)
      }
    }
    @core.Pat::Struct(name~, fields~, span~) => {
      let _ = name
      let _ = span
      for field in fields {
        bind_pattern_names(bound, field.pat)
      }
    }
    @core.Pat::Int(value~, span~) => {
      let _ = value
      let _ = span
    }
    @core.Pat::Float(value~, span~) => {
      let _ = value
      let _ = span
    }
    @core.Pat::Double(value~, span~) => {
      let _ = value
      let _ = span
    }
    @core.Pat::Bool(value~, span~) => {
      let _ = value
      let _ = span
    }
    @core.Pat::String(value~, span~) => {
      let _ = value
      let _ = span
    }
    @core.Pat::Or(pats~, span~) => {
      let _ = span
      for p in pats {
        bind_pattern_names(bound, p)
      }
    }
  }
}

///|
fn is_effectful_call_name(name : String) -> Bool {
  name == "sh" ||
  name == "stdout_write_char" ||
  name == "stdout_write_stream" ||
  name == "stdin_read_char" ||
  name == "stdin_read_stream" ||
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
  name == "__mod" ||
  name == "__index" ||
  name == "__eq" ||
  name == "__lt" ||
  name == "__neg" ||
  name == "__assert" ||
  name == "record_set" ||
  name == "map_keys" ||
  name == "map_values" ||
  name == "map_has_key" ||
  name == "array_slice" ||
  name == "int_to_float" ||
  name == "int_to_double" ||
  name == "float_to_int" ||
  name == "float_to_double" ||
  name == "double_to_int" ||
  name == "double_to_float" ||
  name == "__to_string" ||
  name == "string_split" ||
  name == "string_index_of" ||
  name == "string_contains" ||
  name == "string_trim" ||
  name == "string_from_char_code"
}

///|
pub fn clone_bool_map(src : Map[String, Bool]) -> Map[String, Bool] {
  src.copy()
}
