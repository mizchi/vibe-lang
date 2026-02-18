///|
/// Purity inference for effect-aware caching.
pub struct PurityInfo {
  expr : Bool
  value : Bool
} derive(Show, Eq)

///|
priv struct PurityScope {
  bindings : Map[String, Bool]
  parent : PurityScope?
}

///|
fn PurityScope::new() -> PurityScope {
  { bindings: {}, parent: None }
}

///|
fn PurityScope::child(self : PurityScope) -> PurityScope {
  { bindings: {}, parent: Some(self) }
}

///|
fn PurityScope::get(self : PurityScope, name : String) -> Bool? {
  match self.bindings.get(name) {
    Some(v) => Some(v)
    None =>
      match self.parent {
        Some(p) => p.get(name)
        None => None
      }
  }
}

///|
pub fn purity_for_let(
  env : TypeEnv,
  rec : Bool,
  name : String,
  expr : @core.Expr,
) -> PurityInfo {
  let locals = PurityScope::new()
  if rec {
    locals.bindings[name] = true
  }
  match expr {
    @core.Expr::Fn(params~, ret~, effects=_, body~, span~, ..) => {
      let _ = span
      let _ = ret
      let fn_locals = locals.child()
      for param in params {
        fn_locals.bindings[param.name] = true
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
  purity_expr_inner(env, expr, PurityScope::new())
}

///|
pub fn purity_block(env : TypeEnv, body : @core.Module) -> Bool {
  purity_block_inner(env, body, PurityScope::new())
}

///|
fn purity_expr_inner(
  env : TypeEnv,
  expr : @core.Expr,
  locals : PurityScope,
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
    @core.Expr::Char(value~, span~) => {
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
    @core.Expr::Handle(body~, arms~, span~) => {
      let _ = span
      if not(purity_block_inner(env, body, locals)) {
        false
      } else {
        let mut ok = true
        for arm in arms {
          let arm_locals = locals.child()
          bind_pattern_names(arm_locals.bindings, arm.pat)
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
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      if not(purity_expr_inner(env, scrutinee, locals)) {
        false
      } else {
        let mut ok = true
        for arm in arms {
          let arm_locals = locals.child()
          bind_pattern_names(arm_locals.bindings, arm.pat)
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
    @core.Expr::While(..) | @core.Expr::Loop(..) => false
    @core.Expr::Break(..) | @core.Expr::Continue(..) => false
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      purity_expr_inner(env, value, locals)
    }
    @core.Expr::Yield(..) => false
  }
}

///|
fn purity_block_inner(
  env : TypeEnv,
  body : @core.Module,
  locals : PurityScope,
) -> Bool {
  let scope = locals.child()
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
        scope.bindings[name] = info.value
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
        bind_pattern_names(scope.bindings, pat)
      }
      @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
        let _ = span
        if not(purity_expr_inner(env, expr, scope)) {
          ok = false
          break
        }
        bind_pattern_names(scope.bindings, pat)
        if not(purity_block_inner(env, else_body, scope)) {
          ok = false
          break
        }
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
  locals : PurityScope,
) -> PurityInfo {
  let scope = locals.child()
  if rec {
    scope.bindings[name] = true
  }
  match expr {
    @core.Expr::Fn(params~, ret~, effects=_, body~, span~, ..) => {
      let _ = span
      let _ = ret
      let fn_locals = scope.child()
      for param in params {
        fn_locals.bindings[param.name] = true
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
  locals : PurityScope,
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
    @core.Pat::Char(value~, span~) => {
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
  name == "map_builder_freeze" ||
  name == "string_builder" ||
  name == "string_builder_push" ||
  name == "string_builder_freeze" ||
  name == "fs_read_file" ||
  name == "fs_write_file" ||
  name == "fs_exists" ||
  name == "fs_readdir" ||
  name == "fs_is_dir" ||
  name == "fs_mkdir" ||
  name == "fs_mkdir_p" ||
  name == "fs_getcwd" ||
  name == "fs_chdir" ||
  name == "fs_remove" ||
  name == "fs_is_file" ||
  name == "fs_copy" ||
  name == "fs_rename" ||
  name == "fs_append" ||
  name == "env_get" ||
  name == "socket_tcp_connect" ||
  name == "socket_tcp_read" ||
  name == "socket_tcp_write" ||
  name == "socket_tcp_close" ||
  name == "http_request" ||
  name == "http_response_status" ||
  name == "http_response_header" ||
  name == "http_response_body" ||
  name == "http_close" ||
  name == "http_listen" ||
  name == "http_accept" ||
  name == "http_request_method" ||
  name == "http_request_url" ||
  name == "http_request_header" ||
  name == "http_request_body" ||
  name == "http_respond"
}

///|
fn is_pure_builtin_name(name : String) -> Bool {
  name == "path" ||
  name == "addr" ||
  name == "array_length" ||
  name == "array_get" ||
  name == "map_get" ||
  name == "string_length" ||
  name == "string_utf8_length" ||
  name == "string_utf16_length" ||
  name == "string_unicode_length" ||
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
  name == "string_from_char_code" ||
  name == "char_to_int" ||
  name == "char_from_int" ||
  name == "string_starts_with" ||
  name == "string_ends_with" ||
  name == "string_replace" ||
  name == "string_replace_all" ||
  name == "string_trim_start" ||
  name == "string_trim_end" ||
  name == "string_last_index_of" ||
  name == "string_count" ||
  name == "int_abs" ||
  name == "int_max" ||
  name == "int_min" ||
  name == "int_clamp" ||
  name == "int_signum" ||
  name == "int_is_even" ||
  name == "int_is_odd" ||
  name == "double_abs" ||
  name == "double_max" ||
  name == "double_min" ||
  name == "double_floor" ||
  name == "double_ceil" ||
  name == "string_to_upper" ||
  name == "string_to_lower"
}

///|
pub fn clone_bool_map(src : Map[String, Bool]) -> Map[String, Bool] {
  src.copy()
}

///|
pub fn check_toplevel_purity(
  env : TypeEnv,
  stmts : Array[@core.Stmt],
) -> Unit raise TypeError {
  for stmt in stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let info = purity_for_let(env, rec, name, expr)
        if not(info.expr) {
          raise TypeError::TopLevelImpure(name~, span~)
        }
      }
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
        let info = purity_for_let(env, rec, name, expr)
        if not(info.expr) {
          raise TypeError::TopLevelImpure(name~, span~)
        }
      }
      @core.Stmt::LetMut(name~, span~, ..) =>
        raise TypeError::TopLevelImpure(name~, span~)
      @core.Stmt::Assign(name~, span~, ..) =>
        raise TypeError::TopLevelImpure(name~, span~)
      @core.Stmt::Expr(expr~, span~) =>
        if not(purity_expr(env, expr)) {
          raise TypeError::TopLevelImpure(name="_", span~)
        }
      _ => ()
    }
  }
}
