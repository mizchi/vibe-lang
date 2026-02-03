///| Type checking for xsh

suberror TypeError {
  UnknownName(String)
  Mismatch(expected~ : Type, actual~ : Type)
  BadCall(String)
  BadMatch(String)
  NonExhaustiveMatch
  EffectNotAllowed(String)
} derive(Show, Eq)

pub struct TypeEnv {
  bindings : Map[String, Type]
} derive(Show, Eq)

///|
pub fn TypeEnv::new() -> TypeEnv {
  { bindings: {} }
}

///|
pub fn TypeEnv::get(self : TypeEnv, name : String) -> Type? {
  self.bindings.get(name)
}

///|
pub fn TypeEnv::set(self : TypeEnv, name : String, ty : Type) -> Unit {
  self.bindings[name] = ty
}

///|
pub fn type_check(ast : Module) -> TypeEnv raise TypeError {
  type_check_with_aliases(ast, {})
}

///| Type check with import aliases (qualified names treated as external).
pub fn type_check_with_aliases(
  ast : Module,
  aliases : Map[String, Ref]
) -> TypeEnv raise TypeError {
  let env = TypeEnv::new()
  type_check_stmts(env, ast.stmts, aliases, false)
}

fn type_check_stmts(
  env : TypeEnv,
  stmts : Array[Stmt],
  aliases : Map[String, Ref],
  allow_effect : Bool
) -> TypeEnv raise TypeError {
  for stmt in stmts {
    match stmt {
      Stmt::Let(name~, expr~) => {
        let ty = type_expr_eff(env, expr, aliases, allow_effect)
        env.set(name, ty)
      }
      Stmt::Expr(expr~) => {
        let _ = type_expr_eff(env, expr, aliases, allow_effect)
      }
      Stmt::Flake(_) => ()
      Stmt::Alias(..) => ()
      Stmt::Import(..) => ()
      Stmt::Test(name~, body~) => {
        let _ = name
        let _ = type_check_stmts(clone_env(env), body.stmts, aliases, allow_effect)
      }
    }
  }
  env
}

fn clone_env(env : TypeEnv) -> TypeEnv {
  let bindings : Map[String, Type] = {}
  for name, ty in env.bindings {
    bindings[name] = ty
  }
  { bindings, }
}

///|
fn type_expr_eff(
  env : TypeEnv,
  expr : Expr,
  aliases : Map[String, Ref],
  allow_effect : Bool
) -> Type raise TypeError {
  match expr {
    Expr::Int(_) => Type::Int
    Expr::Bool(_) => Type::Bool
    Expr::String(_) => Type::String
    Expr::Ident(name) =>
      match env.get(name) {
        Some(ty) => ty
        None =>
          if has_alias_prefix(name, aliases) {
            Type::Unit
          } else {
            raise TypeError::UnknownName(name)
          }
      }
    Expr::Call(name~, args~) =>
      if has_alias_prefix(name, aliases) {
        Type::Unit
      } else {
        type_call(env, name, args, aliases, allow_effect)
      }
    Expr::Tuple(items) => {
      let tys : Array[Type] = []
      for item in items {
        tys.push(type_expr_eff(env, item, aliases, allow_effect))
      }
      Type::Tuple(tys)
    }
    Expr::Record(fields) => {
      let map : Map[String, Type] = {}
      for field in fields {
        let ty = type_expr_eff(env, field.expr, aliases, allow_effect)
        map[field.name] = ty
      }
      Type::Record(map)
    }
    Expr::If(cond~, then_body~, else_body~) => {
      let cond_ty = type_expr_eff(env, cond, aliases, allow_effect)
      if cond_ty != Type::Bool {
        raise TypeError::Mismatch(expected=Type::Bool, actual=cond_ty)
      }
      let then_ty = type_block(env, then_body, aliases, allow_effect)
      let else_ty = type_block(env, else_body, aliases, allow_effect)
      if then_ty != else_ty {
        raise TypeError::Mismatch(expected=then_ty, actual=else_ty)
      }
      then_ty
    }
    Expr::Block(body~) => type_block(env, body, aliases, allow_effect)
    Expr::Match(scrutinee~, arms~) => {
      if arms.is_empty() {
        raise TypeError::BadMatch("empty match")
      }
      let scrutinee_ty = type_expr_eff(env, scrutinee, aliases, allow_effect)
      let mut result : Type? = None
      let mut has_wildcard = false
      for arm in arms {
        if is_top_wildcard(arm.pat) {
          has_wildcard = true
        }
        let arm_env = clone_env(env)
        let bindings = collect_pattern_bindings(arm.pat, scrutinee_ty)
        for name, ty in bindings {
          arm_env.set(name, ty)
        }
        match arm.cond {
          Some(c) => {
            let g_ty = type_expr_eff(arm_env, c, aliases, allow_effect)
            if g_ty != Type::Bool {
              raise TypeError::Mismatch(expected=Type::Bool, actual=g_ty)
            }
          }
          None => ()
        }
        let arm_ty = type_expr_eff(arm_env, arm.expr, aliases, allow_effect)
        match result {
          Some(t) =>
            if t != arm_ty {
              raise TypeError::Mismatch(expected=t, actual=arm_ty)
            }
          None => result = Some(arm_ty)
        }
      }
      if not(has_wildcard) {
        raise TypeError::NonExhaustiveMatch
      }
      match result {
        Some(t) => t
        None => Type::Unit
      }
    }
    Expr::Do(body~) => type_block(env, body, aliases, true)
  }
}

fn is_top_wildcard(pat : Pat) -> Bool {
  match pat {
    Pat::Wildcard => true
    Pat::Bind(_) => true
    _ => false
  }
}

fn collect_pattern_bindings(
  pat : Pat,
  scrutinee_ty : Type
) -> Map[String, Type] raise TypeError {
  let out : Map[String, Type] = {}
  collect_pattern_bindings_inner(out, pat, scrutinee_ty)
  out
}

fn collect_pattern_bindings_inner(
  out : Map[String, Type],
  pat : Pat,
  scrutinee_ty : Type
) -> Unit raise TypeError {
  match pat {
    Pat::Wildcard => ()
    Pat::Bind(name) => {
      if out.contains(name) {
        raise TypeError::BadMatch("duplicate bind: " + name)
      }
      out[name] = scrutinee_ty
    }
    Pat::Int(_) => {
      if scrutinee_ty != Type::Int {
        raise TypeError::Mismatch(expected=Type::Int, actual=scrutinee_ty)
      }
    }
    Pat::Bool(_) => {
      if scrutinee_ty != Type::Bool {
        raise TypeError::Mismatch(expected=Type::Bool, actual=scrutinee_ty)
      }
    }
    Pat::String(_) => {
      if scrutinee_ty != Type::String {
        raise TypeError::Mismatch(expected=Type::String, actual=scrutinee_ty)
      }
    }
    Pat::Tuple(items) =>
      match scrutinee_ty {
        Type::Tuple(types) => {
          if items.length() != types.length() {
            raise TypeError::BadMatch("tuple arity")
          }
          for i in 0..<items.length() {
            collect_pattern_bindings_inner(out, items[i], types[i])
          }
        }
        _ => raise TypeError::BadMatch("expected tuple")
      }
    Pat::Record(fields) =>
      match scrutinee_ty {
        Type::Record(types) => {
          for field in fields {
            match types.get(field.name) {
              Some(field_ty) => collect_pattern_bindings_inner(out, field.pat, field_ty)
              None => raise TypeError::BadMatch("missing field: " + field.name)
            }
          }
        }
        _ => raise TypeError::BadMatch("expected record")
      }
  }
}

fn type_block(
  env : TypeEnv,
  body : Module,
  aliases : Map[String, Ref],
  allow_effect : Bool
) -> Type raise TypeError {
  let scope_env = clone_env(env)
  let mut last = Type::Unit
  for stmt in body.stmts {
    match stmt {
      Stmt::Let(name~, expr~) => {
        let ty = type_expr_eff(scope_env, expr, aliases, allow_effect)
        scope_env.set(name, ty)
        last = ty
      }
      Stmt::Expr(expr~) => {
        last = type_expr_eff(scope_env, expr, aliases, allow_effect)
      }
      Stmt::Flake(_) => {
        last = Type::Unit
      }
      Stmt::Alias(..) => {
        last = Type::Unit
      }
      Stmt::Import(..) => {
        last = Type::Unit
      }
      Stmt::Test(name~, body~) => {
        let _ = name
        let _ = type_block(scope_env, body, aliases, allow_effect)
        last = Type::Unit
      }
    }
  }
  last
}

///|
fn type_call(
  env : TypeEnv,
  name : String,
  args : Array[Expr],
  aliases : Map[String, Ref],
  allow_effect : Bool
) -> Type raise TypeError {
  match name {
    "path" => {
      if args.length() != 1 {
        raise TypeError::BadCall("path")
      }
      let arg_ty = type_expr_eff(env, args[0], aliases, allow_effect)
      if arg_ty != Type::String {
        raise TypeError::Mismatch(expected=Type::String, actual=arg_ty)
      }
      Type::Path
    }
    "sh" => {
      if args.length() != 1 {
        raise TypeError::BadCall("sh")
      }
      if not(allow_effect) {
        raise TypeError::EffectNotAllowed("sh")
      }
      let arg_ty = type_expr_eff(env, args[0], aliases, allow_effect)
      if arg_ty != Type::String {
        raise TypeError::Mismatch(expected=Type::String, actual=arg_ty)
      }
      Type::Unit
    }
    "add" => {
      if args.length() != 2 {
        raise TypeError::BadCall("add")
      }
      let a = type_expr_eff(env, args[0], aliases, allow_effect)
      let b = type_expr_eff(env, args[1], aliases, allow_effect)
      if a != Type::Int {
        raise TypeError::Mismatch(expected=Type::Int, actual=a)
      }
      if b != Type::Int {
        raise TypeError::Mismatch(expected=Type::Int, actual=b)
      }
      Type::Int
    }
    "sub" => {
      if args.length() != 2 {
        raise TypeError::BadCall("sub")
      }
      let a = type_expr_eff(env, args[0], aliases, allow_effect)
      let b = type_expr_eff(env, args[1], aliases, allow_effect)
      if a != Type::Int {
        raise TypeError::Mismatch(expected=Type::Int, actual=a)
      }
      if b != Type::Int {
        raise TypeError::Mismatch(expected=Type::Int, actual=b)
      }
      Type::Int
    }
    "eq" => {
      if args.length() != 2 {
        raise TypeError::BadCall("eq")
      }
      let a = type_expr_eff(env, args[0], aliases, allow_effect)
      let b = type_expr_eff(env, args[1], aliases, allow_effect)
      if a != Type::Int {
        raise TypeError::Mismatch(expected=Type::Int, actual=a)
      }
      if b != Type::Int {
        raise TypeError::Mismatch(expected=Type::Int, actual=b)
      }
      Type::Bool
    }
    "lt" => {
      if args.length() != 2 {
        raise TypeError::BadCall("lt")
      }
      let a = type_expr_eff(env, args[0], aliases, allow_effect)
      let b = type_expr_eff(env, args[1], aliases, allow_effect)
      if a != Type::Int {
        raise TypeError::Mismatch(expected=Type::Int, actual=a)
      }
      if b != Type::Int {
        raise TypeError::Mismatch(expected=Type::Int, actual=b)
      }
      Type::Bool
    }
    "not" => {
      if args.length() != 1 {
        raise TypeError::BadCall("not")
      }
      let a = type_expr_eff(env, args[0], aliases, allow_effect)
      if a != Type::Bool {
        raise TypeError::Mismatch(expected=Type::Bool, actual=a)
      }
      Type::Bool
    }
    "and" => {
      if args.length() != 2 {
        raise TypeError::BadCall("and")
      }
      let a = type_expr_eff(env, args[0], aliases, allow_effect)
      let b = type_expr_eff(env, args[1], aliases, allow_effect)
      if a != Type::Bool {
        raise TypeError::Mismatch(expected=Type::Bool, actual=a)
      }
      if b != Type::Bool {
        raise TypeError::Mismatch(expected=Type::Bool, actual=b)
      }
      Type::Bool
    }
    "or" => {
      if args.length() != 2 {
        raise TypeError::BadCall("or")
      }
      let a = type_expr_eff(env, args[0], aliases, allow_effect)
      let b = type_expr_eff(env, args[1], aliases, allow_effect)
      if a != Type::Bool {
        raise TypeError::Mismatch(expected=Type::Bool, actual=a)
      }
      if b != Type::Bool {
        raise TypeError::Mismatch(expected=Type::Bool, actual=b)
      }
      Type::Bool
    }
    _ => raise TypeError::BadCall(name)
  }
}

fn has_alias_prefix(name : String, aliases : Map[String, Ref]) -> Bool {
  let chars : Array[Char] = []
  for c in name {
    chars.push(c)
  }
  let mut dot = -1
  for i in 0..<chars.length() {
    if chars[i] == '.' {
      dot = i
      break
    }
  }
  if dot == -1 {
    return false
  }
  let buf = StringBuilder::new()
  for i in 0..<dot {
    buf.write_char(chars[i])
  }
  let prefix = buf.to_string()
  aliases.contains(prefix)
}
