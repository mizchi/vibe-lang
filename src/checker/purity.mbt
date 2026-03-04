///|
/// Purity inference for effect-aware caching.
pub struct PurityInfo {
  expr : Bool
  value : Bool
  expr_tier : TopLevelPurityTier
  value_tier : TopLevelPurityTier
} derive(Show, Eq)

///|
priv struct PurityScope {
  bindings : Map[String, TopLevelPurityTier]
  parent : PurityScope?
}

///|
priv struct PurityAnalysis {
  has_state_local : Bool
  has_impure : Bool
}

///|
fn purity_analysis_pure() -> PurityAnalysis {
  { has_state_local: false, has_impure: false }
}

///|
fn purity_analysis_state_local() -> PurityAnalysis {
  { has_state_local: true, has_impure: false }
}

///|
fn purity_analysis_impure() -> PurityAnalysis {
  { has_state_local: false, has_impure: true }
}

///|
fn purity_analysis_merge(
  lhs : PurityAnalysis,
  rhs : PurityAnalysis,
) -> PurityAnalysis {
  {
    has_state_local: lhs.has_state_local || rhs.has_state_local,
    has_impure: lhs.has_impure || rhs.has_impure,
  }
}

///|
fn purity_analysis_from_tier(tier : TopLevelPurityTier) -> PurityAnalysis {
  match tier {
    TopLevelPurityTier::Pure => purity_analysis_pure()
    TopLevelPurityTier::StateLocal => purity_analysis_state_local()
    TopLevelPurityTier::Impure => purity_analysis_impure()
  }
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
fn PurityScope::get(self : PurityScope, name : String) -> TopLevelPurityTier? {
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
fn purity_tier_from_bool(pure : Bool) -> TopLevelPurityTier {
  if pure {
    TopLevelPurityTier::Pure
  } else {
    TopLevelPurityTier::Impure
  }
}

///|
fn env_purity_tier(env : TypeEnv, name : String) -> TopLevelPurityTier? {
  match env.get_purity_tier(name) {
    Some(tier) => Some(tier)
    None =>
      match env.get_purity(name) {
        Some(pure) => Some(purity_tier_from_bool(pure))
        None => None
      }
  }
}

///|
fn PurityAnalysis::is_pure(self : PurityAnalysis) -> Bool {
  not(self.has_state_local) && not(self.has_impure)
}

///|
fn PurityAnalysis::tier(self : PurityAnalysis) -> TopLevelPurityTier {
  if self.has_impure {
    TopLevelPurityTier::Impure
  } else if self.has_state_local {
    TopLevelPurityTier::StateLocal
  } else {
    TopLevelPurityTier::Pure
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
    locals.bindings[name] = TopLevelPurityTier::Pure
  }
  match expr {
    @core.Expr::Fn(params~, ret~, effects=fn_effects, body~, span~, ..) => {
      let _ = span
      let _ = ret
      let fn_locals = locals.child()
      for param in params {
        fn_locals.bindings[param.name] = TopLevelPurityTier::Pure
      }
      let expr_info = purity_analysis_pure()
      // Functions with declared effects (e.g. `with { Fs }`) are impure
      // regardless of body analysis — they perform side effects.
      let has_effects = fn_effects.length() > 0
      let value_info = if has_effects {
        purity_analysis_impure()
      } else {
        purity_block_analysis_inner(env, body, fn_locals)
      }
      PurityInfo::{
        expr: expr_info.is_pure(),
        value: value_info.is_pure(),
        expr_tier: expr_info.tier(),
        value_tier: value_info.tier(),
      }
    }
    _ => {
      let expr_info = purity_expr_analysis_inner(env, expr, locals)
      PurityInfo::{
        expr: expr_info.is_pure(),
        value: expr_info.is_pure(),
        expr_tier: expr_info.tier(),
        value_tier: expr_info.tier(),
      }
    }
  }
}

///|
pub fn purity_expr(env : TypeEnv, expr : @core.Expr) -> Bool {
  let info = purity_expr_analysis_inner(env, expr, PurityScope::new())
  info.is_pure()
}

///|
pub fn purity_block(env : TypeEnv, body : @core.Module) -> Bool {
  let info = purity_block_analysis_inner(env, body, PurityScope::new())
  info.is_pure()
}

///|
fn purity_expr_analysis_inner(
  env : TypeEnv,
  expr : @core.Expr,
  locals : PurityScope,
) -> PurityAnalysis {
  match expr {
    @core.Expr::Int(value~, span~) => {
      let _ = value
      let _ = span
      purity_analysis_pure()
    }
    @core.Expr::Float(value~, span~) => {
      let _ = value
      let _ = span
      purity_analysis_pure()
    }
    @core.Expr::Double(value~, span~) => {
      let _ = value
      let _ = span
      purity_analysis_pure()
    }
    @core.Expr::Bool(value~, span~) => {
      let _ = value
      let _ = span
      purity_analysis_pure()
    }
    @core.Expr::Char(value~, span~) => {
      let _ = value
      let _ = span
      purity_analysis_pure()
    }
    @core.Expr::String(value~, span~) => {
      let _ = value
      let _ = span
      purity_analysis_pure()
    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      let tier = match locals.get(name) {
        Some(local_tier) => local_tier
        None =>
          match env_purity_tier(env, name) {
            Some(env_tier) => env_tier
            None =>
              if is_pure_builtin_name(name) {
                TopLevelPurityTier::Pure
              } else {
                TopLevelPurityTier::Impure
              }
          }
      }
      purity_analysis_from_tier(tier)
    }
    @core.Expr::Placeholder(..) =>
      // Placeholder should be desugared; treat as pure
      purity_analysis_pure()
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      let mut args_info = purity_analysis_pure()
      for arg in args {
        args_info = purity_analysis_merge(
          args_info,
          purity_expr_analysis_inner(env, arg.expr, locals),
        )
      }
      if is_effectful_call_name(name) {
        purity_analysis_merge(args_info, purity_analysis_impure())
      } else {
        let callee_tier = if is_pure_builtin_name(name) ||
          @core.is_ctor_name(name) {
          TopLevelPurityTier::Pure
        } else {
          match locals.get(name) {
            Some(local_tier) => local_tier
            None =>
              match env_purity_tier(env, name) {
                Some(env_tier) => env_tier
                None => TopLevelPurityTier::Impure
              }
          }
        }
        purity_analysis_merge(args_info, purity_analysis_from_tier(callee_tier))
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      purity_all_analysis(env, items, locals)
    }
    @core.Expr::TupleIndex(expr~, ..) =>
      purity_expr_analysis_inner(env, expr, locals)
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      let mut out = purity_analysis_pure()
      for field in fields {
        out = purity_analysis_merge(
          out,
          purity_expr_analysis_inner(env, field.expr, locals),
        )
      }
      out
    }
    @core.Expr::StructLit(fields~, span~, ..) => {
      let _ = span
      let mut out = purity_analysis_pure()
      for field in fields {
        out = purity_analysis_merge(
          out,
          purity_expr_analysis_inner(env, field.expr, locals),
        )
      }
      out
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      purity_all_analysis(env, items, locals)
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      let mut out = purity_analysis_pure()
      for field in fields {
        out = purity_analysis_merge(
          out,
          purity_expr_analysis_inner(env, field.expr, locals),
        )
      }
      out
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      let cond_info = purity_expr_analysis_inner(env, cond, locals)
      let then_info = purity_block_analysis_inner(env, then_body, locals)
      let else_info = purity_block_analysis_inner(env, else_body, locals)
      purity_analysis_merge(
        cond_info,
        purity_analysis_merge(then_info, else_info),
      )
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      purity_block_analysis_inner(env, body, locals)
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      let _ = span
      let mut out = purity_block_analysis_inner(env, body, locals)
      for arm in arms {
        let arm_locals = locals.child()
        bind_pattern_names(arm_locals.bindings, arm.pat)
        match arm.cond {
          Some(cond) =>
            out = purity_analysis_merge(
              out,
              purity_expr_analysis_inner(env, cond, arm_locals),
            )
          None => ()
        }
        out = purity_analysis_merge(
          out,
          purity_expr_analysis_inner(env, arm.expr, arm_locals),
        )
      }
      out
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      let mut out = purity_expr_analysis_inner(env, scrutinee, locals)
      for arm in arms {
        let arm_locals = locals.child()
        bind_pattern_names(arm_locals.bindings, arm.pat)
        match arm.cond {
          Some(cond) =>
            out = purity_analysis_merge(
              out,
              purity_expr_analysis_inner(env, cond, arm_locals),
            )
          None => ()
        }
        out = purity_analysis_merge(
          out,
          purity_expr_analysis_inner(env, arm.expr, arm_locals),
        )
      }
      out
    }
    @core.Expr::ForIn(..) =>
      // for-in is a language construct that encapsulates local mutation: pure.
      purity_analysis_pure()
    @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
      let _ = params
      let _ = ret
      let _ = effects
      let _ = body
      let _ = span
      purity_analysis_pure()
    }
    @core.Expr::While(..) | @core.Expr::Loop(..) => purity_analysis_impure()
    @core.Expr::Break(..) | @core.Expr::Continue(..) => purity_analysis_impure()
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      purity_expr_analysis_inner(env, value, locals)
    }
    @core.Expr::Yield(..) => purity_analysis_impure()
  }
}

///|
fn purity_block_analysis_inner(
  env : TypeEnv,
  body : @core.Module,
  locals : PurityScope,
) -> PurityAnalysis {
  let scope = locals.child()
  let mut out = purity_analysis_pure()
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
        let info = purity_for_let_in_scope(env, rec, name, expr, scope)
        out = purity_analysis_merge(
          out,
          purity_analysis_from_tier(info.expr_tier),
        )
        scope.bindings[name] = info.value_tier
      }
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        out = purity_analysis_merge(
          out,
          purity_expr_analysis_inner(env, expr, scope),
        )
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
        out = purity_analysis_merge(
          out,
          purity_expr_analysis_inner(env, expr, scope),
        )
        bind_pattern_names(scope.bindings, pat)
      }
      @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
        let _ = span
        out = purity_analysis_merge(
          out,
          purity_expr_analysis_inner(env, expr, scope),
        )
        bind_pattern_names(scope.bindings, pat)
        out = purity_analysis_merge(
          out,
          purity_block_analysis_inner(env, else_body, scope),
        )
      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        let _ = span
        out = purity_analysis_merge(
          out,
          purity_expr_analysis_inner(env, expr, scope),
        )
        out = purity_analysis_merge(out, purity_analysis_state_local())
        scope.bindings[name] = TopLevelPurityTier::StateLocal
      }
      @core.Stmt::Assign(name~, expr~, span~) => {
        let _ = span
        out = purity_analysis_merge(
          out,
          purity_expr_analysis_inner(env, expr, scope),
        )
        out = purity_analysis_merge(out, purity_analysis_state_local())
        if scope.bindings.contains(name) {
          scope.bindings[name] = TopLevelPurityTier::StateLocal
        }
      }
      _ => ()
    }
  }
  out
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
    scope.bindings[name] = TopLevelPurityTier::Pure
  }
  match expr {
    @core.Expr::Fn(params~, ret~, effects=fn_effects, body~, span~, ..) => {
      let _ = span
      let _ = ret
      let fn_locals = scope.child()
      for param in params {
        fn_locals.bindings[param.name] = TopLevelPurityTier::Pure
      }
      let expr_info = purity_analysis_pure()
      let has_effects = fn_effects.length() > 0
      let value_info = if has_effects {
        purity_analysis_impure()
      } else {
        purity_block_analysis_inner(env, body, fn_locals)
      }
      PurityInfo::{
        expr: expr_info.is_pure(),
        value: value_info.is_pure(),
        expr_tier: expr_info.tier(),
        value_tier: value_info.tier(),
      }
    }
    _ => {
      let expr_info = purity_expr_analysis_inner(env, expr, scope)
      PurityInfo::{
        expr: expr_info.is_pure(),
        value: expr_info.is_pure(),
        expr_tier: expr_info.tier(),
        value_tier: expr_info.tier(),
      }
    }
  }
}

///|
fn purity_all_analysis(
  env : TypeEnv,
  items : Array[@core.Expr],
  locals : PurityScope,
) -> PurityAnalysis {
  let mut out = purity_analysis_pure()
  for item in items {
    out = purity_analysis_merge(
      out,
      purity_expr_analysis_inner(env, item, locals),
    )
  }
  out
}

///|
pub fn bind_pattern_names(
  bound : Map[String, TopLevelPurityTier],
  pat : @core.Pat,
) -> Unit {
  match pat {
    @core.Pat::Wildcard(span~) => {
      let _ = span
    }
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      bound[name] = TopLevelPurityTier::Pure
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
  name == "__perform" ||
  name == "__resume" ||
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
  name == "f32_neg" ||
  name == "f32_abs" ||
  name == "f32_ceil" ||
  name == "f32_floor" ||
  name == "f32_trunc" ||
  name == "f32_nearest" ||
  name == "f32_sqrt" ||
  name == "f64_neg" ||
  name == "f64_abs" ||
  name == "f64_ceil" ||
  name == "f64_floor" ||
  name == "f64_trunc" ||
  name == "f64_nearest" ||
  name == "f64_sqrt" ||
  name == "f32_neg" ||
  name == "f32_abs" ||
  name == "f32_ceil" ||
  name == "f32_floor" ||
  name == "f32_trunc" ||
  name == "f32_nearest" ||
  name == "f32_sqrt" ||
  name == "f64_neg" ||
  name == "f64_abs" ||
  name == "f64_ceil" ||
  name == "f64_floor" ||
  name == "f64_trunc" ||
  name == "f64_nearest" ||
  name == "f64_sqrt" ||
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
  let scope = PurityScope::new()
  for stmt in stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let info = purity_for_let_in_scope(env, rec, name, expr, scope)
        if not(info.expr) {
          raise TypeError::TopLevelImpure(name~, tier=info.expr_tier, span~)
        }
        scope.bindings[name] = info.value_tier
      }
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
        let info = purity_for_let_in_scope(env, rec, name, expr, scope)
        if not(info.expr) {
          raise TypeError::TopLevelImpure(name~, tier=info.expr_tier, span~)
        }
        scope.bindings[name] = info.value_tier
      }
      @core.Stmt::LetMut(name~, span~, ..) =>
        raise TypeError::TopLevelImpure(
          name~,
          tier=TopLevelPurityTier::StateLocal,
          span~,
        )
      @core.Stmt::Assign(name~, span~, ..) =>
        raise TypeError::TopLevelImpure(
          name~,
          tier=TopLevelPurityTier::StateLocal,
          span~,
        )
      @core.Stmt::Expr(expr~, span~) => {
        let info = purity_expr_analysis_inner(env, expr, scope)
        if not(info.is_pure()) {
          raise TypeError::TopLevelImpure(name="_", tier=info.tier(), span~)
        }
      }
      _ => ()
    }
  }
}
