///|
/// Desugar method-call syntax (t.foo(...)) into foo(t, ...)
pub fn desugar_method_calls(
  ast : @core.Module,
  aliases : Map[String, @core.Ref],
) -> @core.Module {
  let scope : Map[String, Bool] = {}
  desugar_block(ast, scope, aliases)
}

///|
fn desugar_block(
  body : @core.Module,
  scope : Map[String, Bool],
  aliases : Map[String, @core.Ref],
) -> @core.Module {
  let scope_map = clone_scope(scope)
  let out : Array[@core.Stmt] = []
  for stmt in body.stmts {
    let next = desugar_stmt(stmt, scope_map, aliases)
    out.push(next)
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~)
      | @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
        let _ = rec
        let _ = expr
        let _ = span
        scope_map[name] = true
      }
      _ => ()
    }
  }
  @core.Module::{ stmts: out }
}

///|
fn desugar_stmt(
  stmt : @core.Stmt,
  scope : Map[String, Bool],
  aliases : Map[String, @core.Ref],
) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) =>
      @core.Stmt::Let(
        rec~,
        name~,
        expr=desugar_expr(expr, scope, aliases),
        span~,
      )
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(expr=desugar_expr(expr, scope, aliases), span~)
    @core.Stmt::Test(name~, body~, span~) =>
      @core.Stmt::Test(name~, body=desugar_block(body, scope, aliases), span~)
    @core.Stmt::EnumDef(..) => stmt
    @core.Stmt::TypeAlias(..) => stmt
    @core.Stmt::Import(..) => stmt
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::ExportLet(
        rec~,
        name~,
        expr=desugar_expr(expr, scope, aliases),
        span~,
      )
    @core.Stmt::ExportEnumDef(..)
    | @core.Stmt::ExportTypeAlias(..)
    | @core.Stmt::StructDef(..)
    | @core.Stmt::ExportStructDef(..)
    | @core.Stmt::Export(..)
    | @core.Stmt::ReExport(..) => stmt
    @core.Stmt::LetMut(name~, expr~, span~) =>
      @core.Stmt::LetMut(name~, expr=desugar_expr(expr, scope, aliases), span~)
    @core.Stmt::Assign(name~, expr~, span~) =>
      @core.Stmt::Assign(name~, expr=desugar_expr(expr, scope, aliases), span~)
    @core.Stmt::IndexAssign(target~, index~, value~, span~) =>
      @core.Stmt::IndexAssign(
        target=desugar_expr(target, scope, aliases),
        index=desugar_expr(index, scope, aliases),
        value=desugar_expr(value, scope, aliases),
        span~,
      )
    @core.Stmt::LetPat(pat~, expr~, span~) =>
      @core.Stmt::LetPat(pat~, expr=desugar_expr(expr, scope, aliases), span~)
  }
}

///|
fn desugar_expr(
  expr : @core.Expr,
  scope : Map[String, Bool],
  aliases : Map[String, @core.Ref],
) -> @core.Expr {
  match expr {
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let next_args : Array[@core.CallArg] = []
      for arg in args {
        next_args.push(@core.CallArg::{
          label: arg.label,
          expr: desugar_expr(arg.expr, scope, aliases),
          span: arg.span,
        })
      }
      // Handle dot-access desugared by parser: Call("method", [Ident("recv"), ...])
      // If recv is an alias (imported module), convert to qualified name
      if next_args.length() >= 1 {
        match next_args[0].expr {
          @core.Expr::Ident(name=recv, ..) =>
            if aliases.contains(recv) && not(scope.contains(recv)) {
              let qualified = recv + "." + name
              if next_args.length() == 1 {
                // foo.bar → Ident("foo.bar")
                return @core.Expr::Ident(name=qualified, span~)
              } else {
                // foo.bar(args) → Call("foo.bar", args)
                let rest_args : Array[@core.CallArg] = []
                for i in 1..<next_args.length() {
                  rest_args.push(next_args[i])
                }
                return @core.Expr::Call(
                  name=qualified,
                  type_args~,
                  args=rest_args,
                  span~,
                )
              }
            }
          _ => ()
        }
      }
      match split_method_call_name(name) {
        Some((recv, method_name)) =>
          if scope.contains(recv) && not(aliases.contains(recv)) {
            let merged : Array[@core.CallArg] = []
            let recv_expr = @core.Expr::Ident(name=recv, span~)
            merged.push(@core.CallArg::{ label: None, expr: recv_expr, span })
            for arg in next_args {
              merged.push(arg)
            }
            @core.Expr::Call(name=method_name, type_args~, args=merged, span~)
          } else {
            @core.Expr::Call(name~, type_args~, args=next_args, span~)
          }
        None => @core.Expr::Call(name~, type_args~, args=next_args, span~)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=desugar_expr(cond, scope, aliases),
        then_body=desugar_block(then_body, scope, aliases),
        else_body=desugar_block(else_body, scope, aliases),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(body=desugar_block(body, scope, aliases), span~)
    @core.Expr::Do(body~, span~) =>
      @core.Expr::Do(body=desugar_block(body, scope, aliases), span~)
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
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
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: next_cond,
          expr: next_expr,
          span: arm.span,
        })
      }
      @core.Expr::Match(scrutinee=scrut, arms=next_arms, span~)
    }
    @core.Expr::Tuple(items~, span~) => {
      let out : Array[@core.Expr] = []
      for item in items {
        out.push(desugar_expr(item, scope, aliases))
      }
      @core.Expr::Tuple(items=out, span~)
    }
    @core.Expr::Record(fields~, span~) => {
      let out : Array[@core.RecordFieldExpr] = []
      for field in fields {
        out.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: desugar_expr(field.expr, scope, aliases),
          span: field.span,
        })
      }
      @core.Expr::Record(fields=out, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let out : Array[@core.Expr] = []
      for item in items {
        out.push(desugar_expr(item, scope, aliases))
      }
      @core.Expr::Array(items=out, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let out : Array[@core.MapFieldExpr] = []
      for field in fields {
        out.push(@core.MapFieldExpr::{
          key: field.key,
          expr: desugar_expr(field.expr, scope, aliases),
          span: field.span,
        })
      }
      @core.Expr::Map(fields=out, span~)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) =>
      @core.Expr::Try(
        try_body=desugar_block(try_body, clone_scope(scope), aliases),
        catch_body=desugar_block(catch_body, clone_scope(scope), aliases),
        span~,
      )
    @core.Expr::Fn(type_params~, params~, ret~, effects~, body~, span~) => {
      let next_scope = clone_scope(scope)
      for param in params {
        next_scope[param.name] = true
      }
      @core.Expr::Fn(
        type_params~,
        params~,
        ret~,
        effects~,
        body=desugar_block(body, next_scope, aliases),
        span~,
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
fn collect_pat_bindings(pat : @core.Pat, out : Array[String]) -> Unit {
  match pat {
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      out.push(name)
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = span
      for arg in args {
        collect_pat_bindings(arg, out)
      }
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        collect_pat_bindings(item, out)
      }
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_pat_bindings(field.pat, out)
      }
    }
    @core.Pat::Or(pats~, span~) => {
      let _ = span
      if pats.length() > 0 {
        collect_pat_bindings(pats[0], out)
      }
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
