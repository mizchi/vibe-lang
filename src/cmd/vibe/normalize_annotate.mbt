///|
fn normalize_collect_inferred_annotations(
  ast : @vibe_core.Module,
  env : @checker.TypeEnv,
) -> Map[String, String] {
  let out : Map[String, String] = {}
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::Let(rec~, name~, expr~, ..)
      | @vibe_core.Stmt::ExportLet(rec~, name~, expr~, ..) => {
        if rec || normalize_stmt_has_explicit_type_assert(expr) {
          continue
        }
        match expr {
          @vibe_core.Expr::Fn(..) => continue
          _ => ()
        }
        let ty = match env.get(name) {
          Some(v) => v
          None => continue
        }
        if not(normalize_type_annotation_allowed(ty)) {
          continue
        }
        let rendered = normalize_render_type_annotation(ty)
        if rendered.length() == 0 {
          continue
        }
        let probe = "let __normalize_probe: " + rendered + " = 0"
        let _ = @parser.parse_ast(probe) catch { _ => continue }
        out[normalize_stmt_key(stmt)] = rendered
      }
      _ => ()
    }
  }
  out
}

///|
fn normalize_collect_export_decl_annotations(
  ast : @vibe_core.Module,
  inferred_annotations : Map[String, String],
  env : @checker.TypeEnv,
) -> Map[String, String] {
  let out : Map[String, String] = {}
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::ExportLet(rec~, name~, expr~, ..) => {
        if rec {
          continue
        }
        let inner_expr = match normalize_unwrap_local_type_assert(expr) {
          Some((_, inner)) => inner
          None => expr
        }
        match inner_expr {
          @vibe_core.Expr::Fn(..) => continue
          _ => ()
        }
        let key = normalize_stmt_key(stmt)
        match normalize_unwrap_local_type_assert(expr) {
          Some((ann_ty, _)) =>
            match normalize_render_decl_annotation_type(ann_ty) {
              Some(ty_text) => {
                out[key] = ty_text
                continue
              }
              None => ()
            }
          None => ()
        }
        match inferred_annotations.get(key) {
          Some(ty_text) => {
            out[key] = ty_text
            continue
          }
          None => ()
        }
        match env.get(name) {
          Some(ty) =>
            match normalize_render_decl_annotation_type(ty) {
              Some(ty_text) => out[key] = ty_text
              None => ()
            }
          None => ()
        }
      }
      _ => ()
    }
  }
  out
}

///|
fn normalize_render_decl_annotation_type(ty : @vibe_core.Type) -> String? {
  if not(normalize_type_annotation_allowed(ty)) {
    return None
  }
  let rendered = normalize_render_type_annotation(ty)
  if rendered.length() == 0 {
    None
  } else {
    Some(rendered)
  }
}

///|
fn normalize_stmt_has_explicit_type_assert(expr : @vibe_core.Expr) -> Bool {
  normalize_unwrap_local_type_assert(expr) is Some(_)
}

///|
fn normalize_unwrap_local_type_assert(
  expr : @vibe_core.Expr,
) -> (@vibe_core.Type, @vibe_core.Expr)? {
  match expr {
    @vibe_core.Expr::Block(body~, ..) => {
      if body.stmts.length() != 2 {
        return None
      }
      let helper_stmt = body.stmts[0]
      let call_stmt = body.stmts[1]
      let (helper_name, helper_ty) = match helper_stmt {
        @vibe_core.Stmt::Let(
          rec~,
          name~,
          expr=@vibe_core.Expr::Fn(params~, ret~, body=helper_body, ..),
          ..
        ) =>
          if rec ||
            not(name.has_prefix("__vibe_local_type_assert_")) ||
            params.length() != 1 ||
            helper_body.stmts.length() != 1 {
            return None
          } else {
            match helper_body.stmts[0] {
              @vibe_core.Stmt::Expr(
                expr=@vibe_core.Expr::Ident(name=returned_name, ..),
                ..
              ) => if returned_name != params[0].name { return None }
              _ => return None
            }
            let ret_ty = match ret {
              Some(v) => v
              None => return None
            }
            if params[0].ty != ret_ty {
              return None
            }
            (name, ret_ty)
          }
        _ => return None
      }
      match call_stmt {
        @vibe_core.Stmt::Expr(expr=@vibe_core.Expr::Call(name~, args~, ..), ..) =>
          if name != helper_name || args.length() != 1 {
            None
          } else {
            Some((helper_ty, args[0].expr))
          }
        _ => None
      }
    }
    _ => None
  }
}

///|
fn normalize_collect_decl_assign_stmt_names(
  m : @vibe_core.Module,
) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for stmt in m.stmts {
    match stmt {
      @vibe_core.Stmt::ExportLet(name~, expr~, ..) =>
        if normalize_unwrap_local_type_assert(expr) is Some(_) {
          out[name] = true
        }
      _ => ()
    }
  }
  out
}

///|
fn normalize_strip_decl_assign_fn_param_types(
  m : @vibe_core.Module,
  decl_assign_names : Map[String, Bool],
) -> @vibe_core.Module {
  let next : Array[@vibe_core.Stmt] = []
  for stmt in m.stmts {
    next.push(
      normalize_strip_decl_assign_fn_param_types_stmt(stmt, decl_assign_names),
    )
  }
  @vibe_core.Module::{ stmts: next }
}

///|
fn normalize_strip_decl_assign_fn_param_types_stmt(
  stmt : @vibe_core.Stmt,
  decl_assign_names : Map[String, Bool],
) -> @vibe_core.Stmt {
  match stmt {
    @vibe_core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      if not(decl_assign_names.contains(name)) {
        stmt
      } else {
        @vibe_core.Stmt::ExportLet(
          rec~,
          name~,
          expr=normalize_strip_decl_assign_fn_param_types_expr(expr),
          span~,
        )
      }
    _ => stmt
  }
}

///|
fn normalize_strip_decl_assign_fn_param_types_expr(
  expr : @vibe_core.Expr,
) -> @vibe_core.Expr {
  match expr {
    @vibe_core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret~,
      effects~,
      body~,
      span~
    ) => {
      if type_params.length() > 0 {
        return expr
      }
      let next_params : Array[@vibe_core.FuncParam] = []
      let mut changed = false
      for param in params {
        if param.bounds.length() > 0 {
          return expr
        }
        if param.ty != @vibe_core.Type::Unit {
          changed = true
        }
        next_params.push(@vibe_core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: @vibe_core.Type::Unit,
          bounds: param.bounds,
        })
      }
      if not(changed) {
        expr
      } else {
        @vibe_core.Expr::Fn(
          type_params~,
          type_bounds~,
          params=next_params,
          ret~,
          effects~,
          body~,
          span~,
        )
      }
    }
    _ => expr
  }
}

///|
fn normalize_type_annotation_allowed(ty : @vibe_core.Type) -> Bool {
  match ty {
    @vibe_core.Type::Int
    | @vibe_core.Type::Float
    | @vibe_core.Type::Double
    | @vibe_core.Type::Bool
    | @vibe_core.Type::Char
    | @vibe_core.Type::String
    | @vibe_core.Type::Path
    | @vibe_core.Type::PromptText
    | @vibe_core.Type::Unit
    | @vibe_core.Type::Never => true
    @vibe_core.Type::Tuple(items) => {
      for item in items {
        if not(normalize_type_annotation_allowed(item)) {
          return false
        }
      }
      true
    }
    @vibe_core.Type::Array(inner)
    | @vibe_core.Type::Map(inner)
    | @vibe_core.Type::ArrayBuilder(inner)
    | @vibe_core.Type::MapBuilder(inner) =>
      normalize_type_annotation_allowed(inner)
    @vibe_core.Type::StringBuilder => true
    @vibe_core.Type::Named(args~, ..) => {
      for arg in args {
        if not(normalize_type_annotation_allowed(arg)) {
          return false
        }
      }
      true
    }
    @vibe_core.Type::Func(params~, ret~, effects~) => {
      for param in params {
        if not(normalize_type_annotation_allowed(param.ty)) {
          return false
        }
      }
      if not(normalize_type_annotation_allowed(ret)) {
        return false
      }
      for effect in effects {
        match effect {
          @vibe_core.EffectAtom::Const(_) => ()
          @vibe_core.EffectAtom::Var(_) => return false
        }
      }
      true
    }
    @vibe_core.Type::Record(_)
    | @vibe_core.Type::Variant(_)
    | @vibe_core.Type::Param(_)
    | @vibe_core.Type::Var(_) => false
  }
}

///|
fn normalize_render_type_annotation(ty : @vibe_core.Type) -> String {
  match ty {
    @vibe_core.Type::Int => "Int"
    @vibe_core.Type::Float => "Float"
    @vibe_core.Type::Double => "Double"
    @vibe_core.Type::Bool => "Bool"
    @vibe_core.Type::Char => "Char"
    @vibe_core.Type::String => "String"
    @vibe_core.Type::Path => "@core.Path"
    @vibe_core.Type::PromptText => "PromptText"
    @vibe_core.Type::Unit => "Unit"
    @vibe_core.Type::Never => "Never"
    @vibe_core.Type::Tuple(items) => {
      let out = StringBuilder::new()
      out.write_char('(')
      for i, item in items {
        if i > 0 {
          out.write_string(", ")
        }
        out.write_string(normalize_render_type_annotation(item))
      }
      out.write_char(')')
      out.to_string()
    }
    @vibe_core.Type::Array(inner) =>
      "Array[" + normalize_render_type_annotation(inner) + "]"
    @vibe_core.Type::Map(inner) =>
      "Map[" + normalize_render_type_annotation(inner) + "]"
    @vibe_core.Type::ArrayBuilder(inner) =>
      "ArrayBuilder[" + normalize_render_type_annotation(inner) + "]"
    @vibe_core.Type::MapBuilder(inner) =>
      "MapBuilder[" + normalize_render_type_annotation(inner) + "]"
    @vibe_core.Type::StringBuilder => "StringBuilder"
    @vibe_core.Type::Named(name~, args~) =>
      if args.length() == 0 {
        name
      } else {
        let out = StringBuilder::new()
        out.write_string(name)
        out.write_char('[')
        for i, arg in args {
          if i > 0 {
            out.write_string(", ")
          }
          out.write_string(normalize_render_type_annotation(arg))
        }
        out.write_char(']')
        out.to_string()
      }
    @vibe_core.Type::Func(params~, ret~, effects~) => {
      let out = StringBuilder::new()
      out.write_char('(')
      for i, param in params {
        if i > 0 {
          out.write_string(", ")
        }
        out.write_string(normalize_render_type_annotation(param.ty))
      }
      out.write_string(") -> ")
      out.write_string(normalize_render_type_annotation(ret))
      if effects.length() > 0 {
        out.write_string(" with {")
        for i, effect in effects {
          if i > 0 {
            out.write_string(", ")
          }
          match effect {
            @vibe_core.EffectAtom::Const(name) => out.write_string(name)
            @vibe_core.EffectAtom::Var(name) => out.write_string(name)
          }
        }
        out.write_char('}')
      }
      out.to_string()
    }
    @vibe_core.Type::Param(name) => name
    @vibe_core.Type::Var(_) => "_"
    @vibe_core.Type::Record(_) | @vibe_core.Type::Variant(_) => ""
  }
}

///|
fn normalize_strip_local_type_assert_module(
  mod : @vibe_core.Module,
) -> @vibe_core.Module {
  let out : Array[@vibe_core.Stmt] = []
  for stmt in mod.stmts {
    out.push(normalize_strip_local_type_assert_stmt(stmt))
  }
  @vibe_core.Module::{ stmts: out }
}

///|
fn normalize_strip_local_type_assert_stmt(
  stmt : @vibe_core.Stmt,
) -> @vibe_core.Stmt {
  match stmt {
    @vibe_core.Stmt::Let(rec~, name~, expr~, span~) =>
      @vibe_core.Stmt::Let(
        rec~,
        name~,
        expr=normalize_strip_local_type_assert_expr(expr),
        span~,
      )
    @vibe_core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @vibe_core.Stmt::ExportLet(
        rec~,
        name~,
        expr=normalize_strip_local_type_assert_expr(expr),
        span~,
      )
    @vibe_core.Stmt::Expr(expr~, span~) =>
      @vibe_core.Stmt::Expr(
        expr=normalize_strip_local_type_assert_expr(expr),
        span~,
      )
    @vibe_core.Stmt::LetMut(name~, expr~, span~) =>
      @vibe_core.Stmt::LetMut(
        name~,
        expr=normalize_strip_local_type_assert_expr(expr),
        span~,
      )
    @vibe_core.Stmt::Assign(name~, expr~, span~) =>
      @vibe_core.Stmt::Assign(
        name~,
        expr=normalize_strip_local_type_assert_expr(expr),
        span~,
      )
    @vibe_core.Stmt::IndexAssign(target~, index~, value~, span~) =>
      @vibe_core.Stmt::IndexAssign(
        target=normalize_strip_local_type_assert_expr(target),
        index=normalize_strip_local_type_assert_expr(index),
        value=normalize_strip_local_type_assert_expr(value),
        span~,
      )
    @vibe_core.Stmt::LetPat(pat~, expr~, span~) =>
      @vibe_core.Stmt::LetPat(
        pat~,
        expr=normalize_strip_local_type_assert_expr(expr),
        span~,
      )
    @vibe_core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) =>
      @vibe_core.Stmt::LetPatElse(
        pat~,
        expr=normalize_strip_local_type_assert_expr(expr),
        else_body=normalize_strip_local_type_assert_module(else_body),
        span~,
      )
    @vibe_core.Stmt::Test(name~, body~, span~) =>
      @vibe_core.Stmt::Test(
        name~,
        body=normalize_strip_local_type_assert_module(body),
        span~,
      )
    @vibe_core.Stmt::Bench(name~, body~, span~) =>
      @vibe_core.Stmt::Bench(
        name~,
        body=normalize_strip_local_type_assert_module(body),
        span~,
      )
    _ => stmt
  }
}

///|
fn normalize_strip_local_type_assert_expr(
  expr : @vibe_core.Expr,
) -> @vibe_core.Expr {
  match normalize_unwrap_local_type_assert(expr) {
    Some((_, unwrapped)) => normalize_strip_local_type_assert_expr(unwrapped)
    None =>
      match expr {
        @vibe_core.Expr::Call(name~, type_args~, args~, span~) => {
          let next_args : Array[@vibe_core.CallArg] = []
          for arg in args {
            next_args.push(@vibe_core.CallArg::{
              label: arg.label,
              expr: normalize_strip_local_type_assert_expr(arg.expr),
              span: arg.span,
            })
          }
          @vibe_core.Expr::Call(name~, type_args~, args=next_args, span~)
        }
        @vibe_core.Expr::Tuple(items~, span~) => {
          let next_items : Array[@vibe_core.Expr] = []
          for item in items {
            next_items.push(normalize_strip_local_type_assert_expr(item))
          }
          @vibe_core.Expr::Tuple(items=next_items, span~)
        }
        @vibe_core.Expr::TupleIndex(expr~, index~, span~) =>
          @vibe_core.Expr::TupleIndex(
            expr=normalize_strip_local_type_assert_expr(expr),
            index~,
            span~,
          )
        @vibe_core.Expr::Record(fields~, span~) => {
          let next_fields : Array[@vibe_core.RecordFieldExpr] = []
          for field in fields {
            next_fields.push(@vibe_core.RecordFieldExpr::{
              name: field.name,
              expr: normalize_strip_local_type_assert_expr(field.expr),
              span: field.span,
            })
          }
          @vibe_core.Expr::Record(fields=next_fields, span~)
        }
        @vibe_core.Expr::Array(items~, span~) => {
          let next_items : Array[@vibe_core.Expr] = []
          for item in items {
            next_items.push(normalize_strip_local_type_assert_expr(item))
          }
          @vibe_core.Expr::Array(items=next_items, span~)
        }
        @vibe_core.Expr::Map(fields~, span~) => {
          let next_fields : Array[@vibe_core.MapFieldExpr] = []
          for field in fields {
            next_fields.push(@vibe_core.MapFieldExpr::{
              key: field.key,
              expr: normalize_strip_local_type_assert_expr(field.expr),
              span: field.span,
            })
          }
          @vibe_core.Expr::Map(fields=next_fields, span~)
        }
        @vibe_core.Expr::If(cond~, then_body~, else_body~, span~) =>
          @vibe_core.Expr::If(
            cond=normalize_strip_local_type_assert_expr(cond),
            then_body=normalize_strip_local_type_assert_module(then_body),
            else_body=normalize_strip_local_type_assert_module(else_body),
            span~,
          )
        @vibe_core.Expr::Block(body~, span~) =>
          @vibe_core.Expr::Block(
            body=normalize_strip_local_type_assert_module(body),
            span~,
          )
        @vibe_core.Expr::Match(scrutinee~, arms~, span~) => {
          let next_arms : Array[@vibe_core.MatchArm] = []
          for arm in arms {
            next_arms.push(@vibe_core.MatchArm::{
              pat: arm.pat,
              cond: match arm.cond {
                Some(cond) => Some(normalize_strip_local_type_assert_expr(cond))
                None => None
              },
              expr: normalize_strip_local_type_assert_expr(arm.expr),
              span: arm.span,
            })
          }
          @vibe_core.Expr::Match(
            scrutinee=normalize_strip_local_type_assert_expr(scrutinee),
            arms=next_arms,
            span~,
          )
        }
        @vibe_core.Expr::Handle(body~, arms~, span~) => {
          let new_arms : Array[@vibe_core.MatchArm] = []
          for arm in arms {
            new_arms.push(@vibe_core.MatchArm::{
              pat: arm.pat,
              cond: arm.cond.map(normalize_strip_local_type_assert_expr),
              expr: normalize_strip_local_type_assert_expr(arm.expr),
              span: arm.span,
            })
          }
          @vibe_core.Expr::Handle(
            body=normalize_strip_local_type_assert_module(body),
            arms=new_arms,
            span~,
          )
        }
        @vibe_core.Expr::Fn(
          type_params~,
          type_bounds~,
          params~,
          ret~,
          effects~,
          body~,
          span~
        ) =>
          @vibe_core.Expr::Fn(
            type_params~,
            type_bounds~,
            params~,
            ret~,
            effects~,
            body=normalize_strip_local_type_assert_module(body),
            span~,
          )
        @vibe_core.Expr::While(cond~, body~, span~) =>
          @vibe_core.Expr::While(
            cond=normalize_strip_local_type_assert_expr(cond),
            body=normalize_strip_local_type_assert_module(body),
            span~,
          )
        @vibe_core.Expr::Loop(params~, body~, span~) => {
          let next_params : Array[@vibe_core.LoopParam] = []
          for param in params {
            next_params.push(@vibe_core.LoopParam::{
              name: param.name,
              init: normalize_strip_local_type_assert_expr(param.init),
              span: param.span,
            })
          }
          @vibe_core.Expr::Loop(
            params=next_params,
            body=normalize_strip_local_type_assert_module(body),
            span~,
          )
        }
        @vibe_core.Expr::Raise(value~, span~) =>
          @vibe_core.Expr::Raise(
            value=normalize_strip_local_type_assert_expr(value),
            span~,
          )
        @vibe_core.Expr::Yield(expr~, span~) =>
          @vibe_core.Expr::Yield(
            expr=normalize_strip_local_type_assert_expr(expr),
            span~,
          )
        @vibe_core.Expr::StructLit(name~, type_args~, fields~, span~) => {
          let next_fields : Array[@vibe_core.RecordFieldExpr] = []
          for field in fields {
            next_fields.push(@vibe_core.RecordFieldExpr::{
              name: field.name,
              expr: normalize_strip_local_type_assert_expr(field.expr),
              span: field.span,
            })
          }
          @vibe_core.Expr::StructLit(
            name~,
            type_args~,
            fields=next_fields,
            span~,
          )
        }
        _ => expr
      }
  }
}
