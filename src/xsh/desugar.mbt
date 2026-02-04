///|
/// Desugar method-call syntax (t.foo(...)) into foo(t, ...)
pub fn desugar_method_calls(ast : Module, aliases : Map[String, Ref]) -> Module {
  let scope : Map[String, Bool] = {}
  desugar_block(ast, scope, aliases)
}

///|
fn desugar_block(
  body : Module,
  scope : Map[String, Bool],
  aliases : Map[String, Ref],
) -> Module {
  let scope_map = clone_scope(scope)
  let out : Array[Stmt] = []
  for stmt in body.stmts {
    let next = desugar_stmt(stmt, scope_map, aliases)
    out.push(next)
    match stmt {
      Stmt::Let(name~, ..) => scope_map[name] = true
      _ => ()
    }
  }
  Module::{ stmts: out }
}

///|
fn desugar_stmt(
  stmt : Stmt,
  scope : Map[String, Bool],
  aliases : Map[String, Ref],
) -> Stmt {
  match stmt {
    Stmt::Let(rec~, name~, expr~) =>
      Stmt::Let(rec~, name~, expr=desugar_expr(expr, scope, aliases))
    Stmt::Expr(expr~) => Stmt::Expr(expr=desugar_expr(expr, scope, aliases))
    Stmt::Test(name~, body~) =>
      Stmt::Test(name~, body=desugar_block(body, scope, aliases))
    Stmt::EnumDef(..) => stmt
    Stmt::TypeAlias(..) => stmt
    Stmt::Flake(..) => stmt
    Stmt::Alias(..) => stmt
    Stmt::Import(..) => stmt
  }
}

///|
fn desugar_expr(
  expr : Expr,
  scope : Map[String, Bool],
  aliases : Map[String, Ref],
) -> Expr {
  match expr {
    Expr::Call(name~, args~) => {
      let next_args : Array[CallArg] = []
      for arg in args {
        next_args.push(CallArg::{
          label: arg.label,
          expr: desugar_expr(arg.expr, scope, aliases),
        })
      }
      match split_method_call_name(name) {
        Some((recv, method_name)) =>
          if scope.contains(recv) && not(aliases.contains(recv)) {
            let merged : Array[CallArg] = []
            merged.push(CallArg::{ label: None, expr: Expr::Ident(recv) })
            for arg in next_args {
              merged.push(arg)
            }
            Expr::Call(name=method_name, args=merged)
          } else {
            Expr::Call(name~, args=next_args)
          }
        None => Expr::Call(name~, args=next_args)
      }
    }
    Expr::If(cond~, then_body~, else_body~) =>
      Expr::If(
        cond=desugar_expr(cond, scope, aliases),
        then_body=desugar_block(then_body, scope, aliases),
        else_body=desugar_block(else_body, scope, aliases),
      )
    Expr::Block(body~) => Expr::Block(body=desugar_block(body, scope, aliases))
    Expr::Do(body~) => Expr::Do(body=desugar_block(body, scope, aliases))
    Expr::Match(scrutinee~, arms~) => {
      let next_arms : Array[MatchArm] = []
      let scrut = desugar_expr(scrutinee, scope, aliases)
      for arm in arms {
        let arm_scope = clone_scope(scope)
        let bindings : Array[String] = []
        collect_pat_bindings(arm.pat, bindings)
        for name in bindings {
          arm_scope[name] = true
        }
        let next_cond = match arm.cond {
          Some(c) => Some(desugar_expr(c, arm_scope, aliases))
          None => None
        }
        let next_expr = desugar_expr(arm.expr, arm_scope, aliases)
        next_arms.push(MatchArm::{
          pat: arm.pat,
          cond: next_cond,
          expr: next_expr,
        })
      }
      Expr::Match(scrutinee=scrut, arms=next_arms)
    }
    Expr::Tuple(items) => {
      let out : Array[Expr] = []
      for item in items {
        out.push(desugar_expr(item, scope, aliases))
      }
      Expr::Tuple(out)
    }
    Expr::Record(fields) => {
      let out : Array[RecordFieldExpr] = []
      for field in fields {
        out.push(RecordFieldExpr::{
          name: field.name,
          expr: desugar_expr(field.expr, scope, aliases),
        })
      }
      Expr::Record(out)
    }
    Expr::Array(items) => {
      let out : Array[Expr] = []
      for item in items {
        out.push(desugar_expr(item, scope, aliases))
      }
      Expr::Array(out)
    }
    Expr::Map(fields) => {
      let out : Array[MapFieldExpr] = []
      for field in fields {
        out.push(MapFieldExpr::{
          key: field.key,
          expr: desugar_expr(field.expr, scope, aliases),
        })
      }
      Expr::Map(out)
    }
    Expr::Try(try_body~, catch_body~) =>
      Expr::Try(
        try_body=desugar_block(try_body, clone_scope(scope), aliases),
        catch_body=desugar_block(catch_body, clone_scope(scope), aliases),
      )
    Expr::Fn(params~, ret~, effects~, body~) => {
      let next_scope = clone_scope(scope)
      for param in params {
        next_scope[param.name] = true
      }
      Expr::Fn(
        params~,
        ret~,
        effects~,
        body=desugar_block(body, next_scope, aliases),
      )
    }
    _ => expr
  }
}

///|
fn split_method_call_name(name : String) -> (String, String)? {
  let chars = name.to_array()
  let mut dot = -1
  let mut count = 0
  for i in 0..<chars.length() {
    if chars[i] == '.' {
      dot = i
      count += 1
    }
  }
  if count != 1 {
    return None
  }
  if dot <= 0 || dot >= chars.length() - 1 {
    return None
  }
  let left = (try! name[0:dot]).to_string()
  let right = (try! name[dot + 1:chars.length()]).to_string()
  if not(is_simple_ident(left)) || not(is_simple_ident(right)) {
    return None
  }
  Some((left, right))
}

///|
fn is_simple_ident(name : String) -> Bool {
  let chars = name.to_array()
  if chars.length() == 0 {
    return false
  }
  for c in chars {
    let code = c.to_int()
    let ok = (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 95
    if not(ok) {
      return false
    }
  }
  true
}

///|
fn collect_pat_bindings(pat : Pat, out : Array[String]) -> Unit {
  match pat {
    Pat::Bind(name) => out.push(name)
    Pat::Ctor(name~, args~) => {
      let _ = name
      for arg in args {
        collect_pat_bindings(arg, out)
      }
    }
    Pat::Tuple(items) =>
      for item in items {
        collect_pat_bindings(item, out)
      }
    Pat::Record(fields) =>
      for field in fields {
        collect_pat_bindings(field.pat, out)
      }
    _ => ()
  }
}

///|
fn clone_scope(src : Map[String, Bool]) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for k, v in src {
    out[k] = v
  }
  out
}
