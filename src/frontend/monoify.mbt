///|
pub struct MonoifyResult {
  ast : @core.Module
  instantiations : Map[String, Int]
} derive(Show, Eq)

///|
priv struct MonoifyContext {
  env : @checker.TypeEnv
  instantiations : Map[String, Int]
  specializable : Map[String, @core.Expr]
}

///|
pub fn monoify_module(
  ast : @core.Module,
  env : @checker.TypeEnv,
) -> MonoifyResult {
  let specializable = collect_specializable_defs(ast)
  let instantiations = collect_instantiations(ast, env, specializable)
  let ctx : MonoifyContext = { env, instantiations, specializable }
  if instantiations.is_empty() {
    return { ast, instantiations }
  }
  let rewritten = monoify_module_top(ast, ctx)
  { ast: rewritten, instantiations }
}

///|
fn collect_specializable_defs(ast : @core.Module) -> Map[String, @core.Expr] {
  let defs : Map[String, @core.Expr] = {}
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = rec
        let _ = span
        match expr {
          @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) =>
            if fn_has_num(params, ret) {
              let _ = effects
              let _ = body
              let _ = span
              defs[name] = expr
            }
          _ => ()
        }
      }
      _ => ()
    }
  }
  defs
}

///|
fn collect_instantiations(
  ast : @core.Module,
  env : @checker.TypeEnv,
  specializable : Map[String, @core.Expr],
) -> Map[String, Int] {
  let instantiations : Map[String, Int] = {}
  let ctx : MonoifyContext = { env, instantiations, specializable }
  let scope = DesugarScope::new()
  collect_instantiations_module(ast, ctx, scope, false)
  instantiations
}

///|
fn collect_instantiations_module(
  ast : @core.Module,
  ctx : MonoifyContext,
  scope : DesugarScope,
  track_let : Bool,
) -> Unit {
  let local_scope = scope.child()
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
        let expr_scope = if rec {
          let next = local_scope.child()
          next.bindings[name] = true
          next
        } else {
          local_scope
        }
        collect_instantiations_expr(expr, ctx, expr_scope)
        if track_let {
          local_scope.bindings[name] = true
        }
      }
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        collect_instantiations_expr(expr, ctx, local_scope)
      }
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = name
        let _ = span
        collect_instantiations_module(body, ctx, local_scope, true)
      }
      @core.Stmt::Bench(name~, body~, span~) => {
        let _ = name
        let _ = span
        collect_instantiations_module(body, ctx, local_scope, true)
      }
      _ => ()
    }
  }
}

///|
fn collect_instantiations_expr(
  expr : @core.Expr,
  ctx : MonoifyContext,
  scope : DesugarScope,
) -> Unit {
  match expr {
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      if ctx.specializable.contains(name) && not(scope.contains(name)) {
        match tag_for_call(ctx.env, name, args) {
          Some(tag) => add_instantiation(ctx.instantiations, name, tag)
          None => ()
        }
      }
      for arg in args {
        collect_instantiations_expr(arg.expr, ctx, scope)
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        collect_instantiations_expr(item, ctx, scope)
      }
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_instantiations_expr(field.expr, ctx, scope)
      }
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      for item in items {
        collect_instantiations_expr(item, ctx, scope)
      }
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_instantiations_expr(field.expr, ctx, scope)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      collect_instantiations_expr(cond, ctx, scope)
      collect_instantiations_module(then_body, ctx, scope, true)
      collect_instantiations_module(else_body, ctx, scope, true)
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      collect_instantiations_module(body, ctx, scope, true)
    }
    @core.Expr::Do(body~, span~) => {
      let _ = span
      collect_instantiations_module(body, ctx, scope, true)
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      let _ = span
      collect_instantiations_module(body, ctx, scope, true)
      for arm in arms {
        let arm_scope = scope.child()
        let bindings : Array[String] = []
        collect_pat_bindings(arm.pat, bindings)
        for name in bindings {
          arm_scope.bindings[name] = true
        }
        match arm.cond {
          Some(c) => collect_instantiations_expr(c, ctx, arm_scope)
          None => ()
        }
        collect_instantiations_expr(arm.expr, ctx, arm_scope)
      }
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      collect_instantiations_expr(scrutinee, ctx, scope)
      for arm in arms {
        let arm_scope = scope.child()
        let bindings : Array[String] = []
        collect_pat_bindings(arm.pat, bindings)
        for name in bindings {
          arm_scope.bindings[name] = true
        }
        match arm.cond {
          Some(c) => collect_instantiations_expr(c, ctx, arm_scope)
          None => ()
        }
        collect_instantiations_expr(arm.expr, ctx, arm_scope)
      }
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
      let _ = span
      let _ = ret
      let _ = effects
      let fn_scope = scope.child()
      for param in params {
        fn_scope.bindings[param.name] = true
      }
      collect_instantiations_module(body, ctx, fn_scope, true)
    }
    _ => ()
  }
}

///|
fn monoify_module_top(ast : @core.Module, ctx : MonoifyContext) -> @core.Module {
  let out_stmts : Array[@core.Stmt] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) =>
        match expr {
          @core.Expr::Fn(params~, ret~, effects~, body~, span=fn_span, ..) if ctx.specializable.contains(
              name,
            ) => {
            let _ = params
            let _ = ret
            let _ = effects
            let _ = body
            let _ = fn_span
            let tags = tags_for_name(ctx.instantiations, name)
            if tags.is_empty() {
              let rewritten = monoify_expr(expr, ctx, DesugarScope::new(), {})
              out_stmts.push(
                @core.Stmt::Let(rec~, name~, expr=rewritten, span~),
              )
            } else {
              for tag in tags {
                let new_name = specialized_name(name, tag)
                let specialized = specialize_fn_expr(expr, name, tag, ctx)
                out_stmts.push(
                  @core.Stmt::Let(rec~, name=new_name, expr=specialized, span~),
                )
              }
            }
          }
          _ => {
            let rewritten = monoify_expr(expr, ctx, DesugarScope::new(), {})
            out_stmts.push(@core.Stmt::Let(rec~, name~, expr=rewritten, span~))
          }
        }
      @core.Stmt::Expr(expr~, span~) => {
        let rewritten = monoify_expr(expr, ctx, DesugarScope::new(), {})
        out_stmts.push(@core.Stmt::Expr(expr=rewritten, span~))
      }
      @core.Stmt::Test(name~, body~, span~) => {
        let rewritten = monoify_block(body, ctx, DesugarScope::new(), {})
        out_stmts.push(@core.Stmt::Test(name~, body=rewritten, span~))
      }
      @core.Stmt::Bench(name~, body~, span~) => {
        let rewritten = monoify_block(body, ctx, DesugarScope::new(), {})
        out_stmts.push(@core.Stmt::Bench(name~, body=rewritten, span~))
      }
      _ => out_stmts.push(stmt)
    }
  }
  @core.Module::{ stmts: out_stmts }
}

///|
fn monoify_block(
  body : @core.Module,
  ctx : MonoifyContext,
  scope : DesugarScope,
  current_spec : Map[String, String],
) -> @core.Module {
  let out_stmts : Array[@core.Stmt] = []
  let local_scope = scope.child()
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let expr_scope = if rec {
          let next = local_scope.child()
          next.bindings[name] = true
          next
        } else {
          local_scope
        }
        let rewritten = monoify_expr(expr, ctx, expr_scope, current_spec)
        out_stmts.push(@core.Stmt::Let(rec~, name~, expr=rewritten, span~))
        local_scope.bindings[name] = true
      }
      @core.Stmt::Expr(expr~, span~) => {
        let rewritten = monoify_expr(expr, ctx, local_scope, current_spec)
        out_stmts.push(@core.Stmt::Expr(expr=rewritten, span~))
      }
      @core.Stmt::Test(name~, body~, span~) => {
        let rewritten = monoify_block(body, ctx, local_scope, current_spec)
        out_stmts.push(@core.Stmt::Test(name~, body=rewritten, span~))
      }
      @core.Stmt::Bench(name~, body~, span~) => {
        let rewritten = monoify_block(body, ctx, local_scope, current_spec)
        out_stmts.push(@core.Stmt::Bench(name~, body=rewritten, span~))
      }
      _ => out_stmts.push(stmt)
    }
  }
  @core.Module::{ stmts: out_stmts }
}

///|
fn monoify_expr(
  expr : @core.Expr,
  ctx : MonoifyContext,
  scope : DesugarScope,
  current_spec : Map[String, String],
) -> @core.Expr {
  match expr {
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let next_args : Array[@core.CallArg] = []
      for arg in args {
        let rewritten = monoify_expr(arg.expr, ctx, scope, current_spec)
        next_args.push(@core.CallArg::{
          label: arg.label,
          expr: rewritten,
          span: arg.span,
        })
      }
      match current_spec.get(name) {
        Some(mapped) =>
          @core.Expr::Call(name=mapped, type_args~, args=next_args, span~)
        None =>
          if ctx.specializable.contains(name) && not(scope.contains(name)) {
            match tag_for_call(ctx.env, name, args) {
              Some(tag) =>
                if ctx.instantiations.contains(inst_key(name, tag)) {
                  let updated_args : Array[@core.CallArg] = []
                  for arg in next_args {
                    let adjusted = maybe_specialize_ident_arg(
                      arg.expr,
                      ctx,
                      scope,
                      tag,
                    )
                    updated_args.push(@core.CallArg::{
                      label: arg.label,
                      expr: adjusted,
                      span: arg.span,
                    })
                  }
                  let new_name = specialized_name(name, tag)
                  @core.Expr::Call(
                    name=new_name,
                    type_args~,
                    args=updated_args,
                    span~,
                  )
                } else {
                  @core.Expr::Call(name~, type_args~, args=next_args, span~)
                }
              None => @core.Expr::Call(name~, type_args~, args=next_args, span~)
            }
          } else {
            @core.Expr::Call(name~, type_args~, args=next_args, span~)
          }
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let out : Array[@core.Expr] = []
      for item in items {
        out.push(monoify_expr(item, ctx, scope, current_spec))
      }
      @core.Expr::Tuple(items=out, span~)
    }
    @core.Expr::Record(fields~, span~) => {
      let out : Array[@core.RecordFieldExpr] = []
      for field in fields {
        out.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: monoify_expr(field.expr, ctx, scope, current_spec),
          span: field.span,
        })
      }
      @core.Expr::Record(fields=out, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let out : Array[@core.Expr] = []
      for item in items {
        out.push(monoify_expr(item, ctx, scope, current_spec))
      }
      @core.Expr::Array(items=out, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let out : Array[@core.MapFieldExpr] = []
      for field in fields {
        out.push(@core.MapFieldExpr::{
          key: field.key,
          expr: monoify_expr(field.expr, ctx, scope, current_spec),
          span: field.span,
        })
      }
      @core.Expr::Map(fields=out, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=monoify_expr(cond, ctx, scope, current_spec),
        then_body=monoify_block(then_body, ctx, scope, current_spec),
        else_body=monoify_block(else_body, ctx, scope, current_spec),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(
        body=monoify_block(body, ctx, scope, current_spec),
        span~,
      )
    @core.Expr::Do(body~, span~) =>
      @core.Expr::Do(body=monoify_block(body, ctx, scope, current_spec), span~)
    @core.Expr::Handle(body~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      for arm in arms {
        let arm_scope = scope.child()
        let bindings : Array[String] = []
        collect_pat_bindings(arm.pat, bindings)
        for name in bindings {
          arm_scope.bindings[name] = true
        }
        let next_cond = match arm.cond {
          Some(c) => Some(monoify_expr(c, ctx, arm_scope, current_spec))
          None => None
        }
        let next_expr = monoify_expr(arm.expr, ctx, arm_scope, current_spec)
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: next_cond,
          expr: next_expr,
          span: arm.span,
        })
      }
      @core.Expr::Handle(
        body=monoify_block(body, ctx, scope, current_spec),
        arms=next_arms,
        span~,
      )
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      let scrut = monoify_expr(scrutinee, ctx, scope, current_spec)
      for arm in arms {
        let arm_scope = scope.child()
        let bindings : Array[String] = []
        collect_pat_bindings(arm.pat, bindings)
        for name in bindings {
          arm_scope.bindings[name] = true
        }
        let next_cond = match arm.cond {
          Some(c) => Some(monoify_expr(c, ctx, arm_scope, current_spec))
          None => None
        }
        let next_expr = monoify_expr(arm.expr, ctx, arm_scope, current_spec)
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: next_cond,
          expr: next_expr,
          span: arm.span,
        })
      }
      @core.Expr::Match(scrutinee=scrut, arms=next_arms, span~)
    }
    @core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret~,
      effects~,
      body~,
      span~
    ) => {
      let fn_scope = scope.child()
      for param in params {
        fn_scope.bindings[param.name] = true
      }
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects~,
        body=monoify_block(body, ctx, fn_scope, current_spec),
        span~,
      )
    }
    _ => expr
  }
}

///|
fn specialize_fn_expr(
  expr : @core.Expr,
  name : String,
  tag : String,
  ctx : MonoifyContext,
) -> @core.Expr {
  match expr {
    @core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret~,
      effects~,
      body~,
      span~
    ) => {
      let concrete = tag_to_type(tag)
      let updated_params : Array[@core.FuncParam] = []
      for param in params {
        updated_params.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: replace_num_type(param.ty, concrete),
          bounds: param.bounds,
        })
      }
      let updated_ret = match ret {
        Some(r) => Some(replace_num_type(r, concrete))
        None => None
      }
      let fn_scope = DesugarScope::new()
      for param in params {
        fn_scope.bindings[param.name] = true
      }
      let current_spec : Map[String, String] = {}
      current_spec[name] = specialized_name(name, tag)
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params=updated_params,
        ret=updated_ret,
        effects~,
        body=monoify_block(body, ctx, fn_scope, current_spec),
        span~,
      )
    }
    _ => expr
  }
}

///|
fn maybe_specialize_ident_arg(
  expr : @core.Expr,
  ctx : MonoifyContext,
  scope : DesugarScope,
  tag : String,
) -> @core.Expr {
  match expr {
    @core.Expr::Ident(name~, span~) =>
      if ctx.specializable.contains(name) && not(scope.contains(name)) {
        if ctx.instantiations.contains(inst_key(name, tag)) {
          @core.Expr::Ident(name=specialized_name(name, tag), span~)
        } else {
          expr
        }
      } else {
        expr
      }
    _ => expr
  }
}

///|
fn tag_for_call(
  env : @checker.TypeEnv,
  name : String,
  args : Array[@core.CallArg],
) -> String? {
  let pos_args = positional_args(args)
  match name {
    "add" | "sub" | "mul" | "div" | "eq" | "lt" =>
      if pos_args.length() >= 1 {
        num_tag_from_expr(env, pos_args[0].expr)
      } else {
        None
      }
    "array_map" | "array_filter" =>
      if pos_args.length() >= 2 {
        array_elem_tag_from_expr(env, pos_args[1].expr)
      } else {
        None
      }
    "array_fold" =>
      if pos_args.length() >= 2 {
        match num_tag_from_expr(env, pos_args[1].expr) {
          Some(tag) => Some(tag)
          None =>
            if pos_args.length() >= 3 {
              array_elem_tag_from_expr(env, pos_args[2].expr)
            } else {
              None
            }
        }
      } else {
        None
      }
    _ => None
  }
}

///|
fn positional_args(args : Array[@core.CallArg]) -> Array[@core.CallArg] {
  let out : Array[@core.CallArg] = []
  for arg in args {
    if arg.label is None {
      out.push(arg)
    }
  }
  out
}

///|
fn num_tag_from_expr(env : @checker.TypeEnv, expr : @core.Expr) -> String? {
  match env.get_expr_type(expr.span()) {
    Some(ty) => num_tag_from_type(ty)
    None => None
  }
}

///|
fn array_elem_tag_from_expr(
  env : @checker.TypeEnv,
  expr : @core.Expr,
) -> String? {
  match env.get_expr_type(expr.span()) {
    Some(@core.Type::Array(inner)) => num_tag_from_type(inner)
    _ => None
  }
}

///|
fn num_tag_from_type(ty : @core.Type) -> String? {
  match ty {
    @core.Type::Int => Some("i32")
    @core.Type::Float => Some("f32")
    @core.Type::Double => Some("f64")
    _ => None
  }
}

///|
fn tag_to_type(tag : String) -> @core.Type {
  match tag {
    "i32" => @core.Type::Int
    "f32" => @core.Type::Float
    "f64" => @core.Type::Double
    _ => @core.Type::Int
  }
}

///|
fn inst_key(name : String, tag : String) -> String {
  name + ":" + tag
}

///|
fn add_instantiation(
  instantiations : Map[String, Int],
  name : String,
  tag : String,
) -> Unit {
  let key = inst_key(name, tag)
  let count = match instantiations.get(key) {
    Some(c) => c
    None => 0
  }
  instantiations[key] = count + 1
}

///|
fn tags_for_name(
  instantiations : Map[String, Int],
  name : String,
) -> Array[String] {
  let prefix = name + ":"
  let out : Array[String] = []
  for key, _ in instantiations {
    if String::has_prefix(key, prefix) {
      out.push(
        String::unsafe_substring(
          key,
          start=String::length(prefix),
          end=String::length(key),
        ),
      )
    }
  }
  out
}

///|
fn specialized_name(name : String, tag : String) -> String {
  name + "$" + tag
}

///|
fn fn_has_num(params : Array[@core.FuncParam], ret : @core.Type?) -> Bool {
  let mut found = false
  for param in params {
    if has_num_type(param.ty) {
      found = true
      break
    }
  }
  if found {
    true
  } else {
    match ret {
      Some(r) => has_num_type(r)
      None => false
    }
  }
}

///|
fn has_num_type(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::Named(name~, args~) =>
      if name == "Num" && args.is_empty() {
        true
      } else {
        let mut found = false
        for arg in args {
          if has_num_type(arg) {
            found = true
            break
          }
        }
        found
      }
    @core.Type::Tuple(items) => {
      let mut found = false
      for item in items {
        if has_num_type(item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Record(fields) => {
      let mut found = false
      for _, item in fields {
        if has_num_type(item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Array(inner)
    | @core.Type::Map(inner)
    | @core.Type::ArrayBuilder(inner)
    | @core.Type::MapBuilder(inner) => has_num_type(inner)
    @core.Type::StringBuilder => false
    @core.Type::Variant(fields) => {
      let mut found = false
      for _, item in fields {
        if has_num_type(item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Func(params~, ret~, ..) => {
      let mut found = false
      for param in params {
        if has_num_type(param.ty) {
          found = true
          break
        }
      }
      if found {
        true
      } else {
        has_num_type(ret)
      }
    }
    _ => false
  }
}

///|
fn replace_num_type(ty : @core.Type, concrete : @core.Type) -> @core.Type {
  match ty {
    @core.Type::Named(name~, args~) =>
      if name == "Num" && args.is_empty() {
        concrete
      } else {
        let out : Array[@core.Type] = []
        for arg in args {
          out.push(replace_num_type(arg, concrete))
        }
        @core.Type::Named(name~, args=out)
      }
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      for item in items {
        out.push(replace_num_type(item, concrete))
      }
      @core.Type::Tuple(out)
    }
    @core.Type::Record(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = replace_num_type(item, concrete)
      }
      @core.Type::Record(out)
    }
    @core.Type::Array(inner) =>
      @core.Type::Array(replace_num_type(inner, concrete))
    @core.Type::Map(inner) => @core.Type::Map(replace_num_type(inner, concrete))
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(replace_num_type(inner, concrete))
    @core.Type::MapBuilder(inner) =>
      @core.Type::MapBuilder(replace_num_type(inner, concrete))
    @core.Type::StringBuilder => @core.Type::StringBuilder
    @core.Type::Variant(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = replace_num_type(item, concrete)
      }
      @core.Type::Variant(out)
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let out : Array[@core.FuncParam] = []
      for param in params {
        out.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: replace_num_type(param.ty, concrete),
          bounds: param.bounds,
        })
      }
      @core.Type::Func(
        params=out,
        ret=replace_num_type(ret, concrete),
        effects~,
      )
    }
    _ => ty
  }
}
