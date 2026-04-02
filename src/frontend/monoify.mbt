///|
pub struct MonoifyResult {
  ast : @core.Module
  instantiations : Map[String, Int]
} derive(Show, Eq)

///|
priv struct MonoifyInstantiation {
  tag : String
  type_subst : Map[String, @core.Type]
}

///|
priv struct MonoifyContext {
  expr_types : @core.ExprTypeIndex
  instantiations : Map[String, Int]
  inst_type_subst : Map[String, Map[String, @core.Type]]
  specializable : Map[String, @core.Expr]
}

///|
pub fn monoify_module(
  ast : @core.Module,
  expr_types : @core.ExprTypeIndex,
) -> MonoifyResult {
  let specializable = collect_specializable_defs(ast)
  let (instantiations, inst_type_subst) = collect_instantiations(
    ast, expr_types, specializable,
  )
  let ctx : MonoifyContext = {
    expr_types,
    instantiations,
    inst_type_subst,
    specializable,
  }
  if instantiations.is_empty() {
    return { ast, instantiations }
  }
  expand_monoify_instantiations(ctx)
  let rewritten = monoify_module_top(ast, ctx)
  { ast: rewritten, instantiations }
}

///|
fn expand_monoify_instantiations(ctx : MonoifyContext) -> Unit {
  let mut changed = true
  while changed {
    let before = ctx.instantiations.length()
    for name, expr in ctx.specializable {
      let tags = ctx.tags_for_name(name)
      for tag in tags {
        ignore(specialize_fn_expr(expr, name, tag, ctx))
      }
    }
    changed = ctx.instantiations.length() > before
  }
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
          @core.Expr::Fn(
            type_params~,
            params~,
            ret~,
            effects~,
            body~,
            span~,
            ..
          ) =>
            if fn_has_num(params, ret) ||
              fn_uses_iter_dispatch_module(body) ||
              fn_has_root_specializable_param(type_params, params) {
              let _ = type_params
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
  expr_types : @core.ExprTypeIndex,
  specializable : Map[String, @core.Expr],
) -> (Map[String, Int], Map[String, Map[String, @core.Type]]) {
  let instantiations : Map[String, Int] = {}
  let inst_type_subst : Map[String, Map[String, @core.Type]] = {}
  let ctx : MonoifyContext = {
    expr_types,
    instantiations,
    inst_type_subst,
    specializable,
  }
  let scope = DesugarScope::new()
  collect_instantiations_module(ast, ctx, scope, false)
  collect_transitive_instantiations(ctx)
  (instantiations, inst_type_subst)
}

///|
fn collect_transitive_instantiations(ctx : MonoifyContext) -> Unit {
  let visited : Map[String, Bool] = {}
  let mut has_pending = true
  while has_pending {
    has_pending = false
    for name, expr in ctx.specializable {
      let tags = ctx.tags_for_name(name)
      for tag in tags {
        let key = inst_key(name, tag)
        if not(visited.contains(key)) {
          visited[key] = true
          has_pending = true
          let specialized = specialize_fn_expr(expr, name, tag, ctx)
          collect_instantiations_expr(specialized, ctx, DesugarScope::new())
        }
      }
    }
  }
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
        match ctx.tag_for_call(name, args, {}) {
          Some(inst) => ctx.add_instantiation(name, inst)
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
            let tags = ctx.tags_for_name(name)
            if tags.is_empty() {
              let rewritten = monoify_expr(
                expr,
                ctx,
                DesugarScope::new(),
                {},
                {},
                {},
              )
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
            let rewritten = monoify_expr(
              expr,
              ctx,
              DesugarScope::new(),
              {},
              {},
              {},
            )
            out_stmts.push(@core.Stmt::Let(rec~, name~, expr=rewritten, span~))
          }
        }
      @core.Stmt::Expr(expr~, span~) => {
        let rewritten = monoify_expr(expr, ctx, DesugarScope::new(), {}, {}, {})
        out_stmts.push(@core.Stmt::Expr(expr=rewritten, span~))
      }
      @core.Stmt::Test(name~, body~, span~) => {
        let rewritten = monoify_block(body, ctx, DesugarScope::new(), {}, {}, {})
        out_stmts.push(@core.Stmt::Test(name~, body=rewritten, span~))
      }
      @core.Stmt::Bench(name~, body~, span~) => {
        let rewritten = monoify_block(body, ctx, DesugarScope::new(), {}, {}, {})
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
  iterable_spec : Map[String, String],
  local_types : Map[String, @core.Type],
) -> @core.Module {
  let out_stmts : Array[@core.Stmt] = []
  let local_scope = scope.child()
  let local_iterable_spec : Map[String, String] = {}
  for name, root in iterable_spec {
    local_iterable_spec[name] = root
  }
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
        let rewritten = monoify_expr(
          expr, ctx, expr_scope, current_spec, local_iterable_spec, local_types,
        )
        out_stmts.push(@core.Stmt::Let(rec~, name~, expr=rewritten, span~))
        local_scope.bindings[name] = true
        ignore(local_iterable_spec.remove(name))
      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        let rewritten = monoify_expr(
          expr, ctx, local_scope, current_spec, local_iterable_spec, local_types,
        )
        out_stmts.push(@core.Stmt::LetMut(name~, expr=rewritten, span~))
        local_scope.bindings[name] = true
        ignore(local_iterable_spec.remove(name))
      }
      @core.Stmt::Assign(name~, expr~, span~) => {
        let rewritten = monoify_expr(
          expr, ctx, local_scope, current_spec, local_iterable_spec, local_types,
        )
        out_stmts.push(@core.Stmt::Assign(name~, expr=rewritten, span~))
      }
      @core.Stmt::IndexAssign(target~, index~, value~, span~) => {
        let rewritten_target = monoify_expr(
          target, ctx, local_scope, current_spec, local_iterable_spec, local_types,
        )
        let rewritten_index = monoify_expr(
          index, ctx, local_scope, current_spec, local_iterable_spec, local_types,
        )
        let rewritten_value = monoify_expr(
          value, ctx, local_scope, current_spec, local_iterable_spec, local_types,
        )
        out_stmts.push(
          @core.Stmt::IndexAssign(
            target=rewritten_target,
            index=rewritten_index,
            value=rewritten_value,
            span~,
          ),
        )
      }
      @core.Stmt::Expr(expr~, span~) => {
        let rewritten = monoify_expr(
          expr, ctx, local_scope, current_spec, local_iterable_spec, local_types,
        )
        out_stmts.push(@core.Stmt::Expr(expr=rewritten, span~))
      }
      @core.Stmt::Test(name~, body~, span~) => {
        let rewritten = monoify_block(
          body, ctx, local_scope, current_spec, local_iterable_spec, local_types,
        )
        out_stmts.push(@core.Stmt::Test(name~, body=rewritten, span~))
      }
      @core.Stmt::Bench(name~, body~, span~) => {
        let rewritten = monoify_block(
          body, ctx, local_scope, current_spec, local_iterable_spec, local_types,
        )
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
  iterable_spec : Map[String, String],
  local_types : Map[String, @core.Type],
) -> @core.Expr {
  match expr {
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let next_args : Array[@core.CallArg] = []
      for arg in args {
        let rewritten = monoify_expr(
          arg.expr,
          ctx,
          scope,
          current_spec,
          iterable_spec,
          local_types,
        )
        next_args.push(@core.CallArg::{
          label: arg.label,
          expr: rewritten,
          span: arg.span,
        })
      }
      let rewritten_name = rewrite_iter_dispatch_call_name(
        name, next_args, iterable_spec,
      )
      match current_spec.get(rewritten_name) {
        Some(mapped) =>
          @core.Expr::Call(name=mapped, type_args~, args=next_args, span~)
        None =>
          if ctx.specializable.contains(rewritten_name) &&
            not(scope.contains(rewritten_name)) {
            match ctx.tag_for_call(rewritten_name, args, local_types) {
              Some(inst) => {
                if !ctx.has_instantiation(rewritten_name, inst.tag) {
                  ctx.add_instantiation(rewritten_name, inst)
                }
                let updated_args : Array[@core.CallArg] = []
                for arg in next_args {
                  let adjusted = maybe_specialize_ident_arg(
                    arg.expr,
                    ctx,
                    scope,
                    inst.tag,
                  )
                  updated_args.push(@core.CallArg::{
                    label: arg.label,
                    expr: adjusted,
                    span: arg.span,
                  })
                }
                let new_name = specialized_name(rewritten_name, inst.tag)
                @core.Expr::Call(
                  name=new_name,
                  type_args~,
                  args=updated_args,
                  span~,
                )
              }
              None =>
                @core.Expr::Call(
                  name=rewritten_name,
                  type_args~,
                  args=next_args,
                  span~,
                )
            }
          } else {
            @core.Expr::Call(
              name=rewritten_name,
              type_args~,
              args=next_args,
              span~,
            )
          }
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let out : Array[@core.Expr] = []
      for item in items {
        out.push(
          monoify_expr(
            item, ctx, scope, current_spec, iterable_spec, local_types,
          ),
        )
      }
      @core.Expr::Tuple(items=out, span~)
    }
    @core.Expr::Record(fields~, span~) => {
      let out : Array[@core.RecordFieldExpr] = []
      for field in fields {
        out.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: monoify_expr(
            field.expr,
            ctx,
            scope,
            current_spec,
            iterable_spec,
            local_types,
          ),
          span: field.span,
        })
      }
      @core.Expr::Record(fields=out, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let out : Array[@core.Expr] = []
      for item in items {
        out.push(
          monoify_expr(
            item, ctx, scope, current_spec, iterable_spec, local_types,
          ),
        )
      }
      @core.Expr::Array(items=out, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let out : Array[@core.MapFieldExpr] = []
      for field in fields {
        out.push(@core.MapFieldExpr::{
          key: field.key,
          expr: monoify_expr(
            field.expr,
            ctx,
            scope,
            current_spec,
            iterable_spec,
            local_types,
          ),
          span: field.span,
        })
      }
      @core.Expr::Map(fields=out, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=monoify_expr(
          cond, ctx, scope, current_spec, iterable_spec, local_types,
        ),
        then_body=monoify_block(
          then_body, ctx, scope, current_spec, iterable_spec, local_types,
        ),
        else_body=monoify_block(
          else_body, ctx, scope, current_spec, iterable_spec, local_types,
        ),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(
        body=monoify_block(
          body, ctx, scope, current_spec, iterable_spec, local_types,
        ),
        span~,
      )
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=monoify_expr(
          cond, ctx, scope, current_spec, iterable_spec, local_types,
        ),
        body=monoify_block(
          body,
          ctx,
          scope.child(),
          current_spec,
          iterable_spec,
          local_types,
        ),
        span~,
      )
    @core.Expr::Loop(params~, body~, span~) => {
      let loop_scope = scope.child()
      for param in params {
        loop_scope.bindings[param.name] = true
      }
      @core.Expr::Loop(
        params~,
        body=monoify_block(
          body, ctx, loop_scope, current_spec, iterable_spec, local_types,
        ),
        span~,
      )
    }
    @core.Expr::Break(value~, span~) =>
      @core.Expr::Break(
        value=value.map(fn(inner) {
          monoify_expr(
            inner, ctx, scope, current_spec, iterable_spec, local_types,
          )
        }),
        span~,
      )
    @core.Expr::Continue(args~, span~) => {
      let next_args : Array[@core.Expr] = []
      for arg in args {
        next_args.push(
          monoify_expr(
            arg, ctx, scope, current_spec, iterable_spec, local_types,
          ),
        )
      }
      @core.Expr::Continue(args=next_args, span~)
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      for arm in arms {
        let arm_scope = scope.child()
        let bindings : Array[String] = []
        collect_pat_bindings(arm.pat, bindings)
        for name in bindings {
          arm_scope.bindings[name] = true
        }
        let arm_iterable_spec = monoify_iterable_spec_without(
          iterable_spec, bindings,
        )
        let next_cond = match arm.cond {
          Some(c) =>
            Some(
              monoify_expr(
                c, ctx, arm_scope, current_spec, arm_iterable_spec, local_types,
              ),
            )
          None => None
        }
        let next_expr = monoify_expr(
          arm.expr,
          ctx,
          arm_scope,
          current_spec,
          arm_iterable_spec,
          local_types,
        )
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: next_cond,
          expr: next_expr,
          span: arm.span,
        })
      }
      @core.Expr::Handle(
        body=monoify_block(
          body, ctx, scope, current_spec, iterable_spec, local_types,
        ),
        arms=next_arms,
        span~,
      )
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      let scrut = monoify_expr(
        scrutinee, ctx, scope, current_spec, iterable_spec, local_types,
      )
      for arm in arms {
        let arm_scope = scope.child()
        let bindings : Array[String] = []
        collect_pat_bindings(arm.pat, bindings)
        for name in bindings {
          arm_scope.bindings[name] = true
        }
        let arm_iterable_spec = monoify_iterable_spec_without(
          iterable_spec, bindings,
        )
        let next_cond = match arm.cond {
          Some(c) =>
            Some(
              monoify_expr(
                c, ctx, arm_scope, current_spec, arm_iterable_spec, local_types,
              ),
            )
          None => None
        }
        let next_expr = monoify_expr(
          arm.expr,
          ctx,
          arm_scope,
          current_spec,
          arm_iterable_spec,
          local_types,
        )
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
      let fn_iterable_spec = monoify_iterable_spec_without(
        iterable_spec,
        param_names(params),
      )
      for param in params {
        fn_scope.bindings[param.name] = true
      }
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects~,
        body=monoify_block(
          body, ctx, fn_scope, current_spec, fn_iterable_spec, local_types,
        ),
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
      let type_subst = ctx.type_subst_for_instantiation(name, tag)
      let iter_root = monoify_iter_inst_root_tag(tag)
      let iter_param_types = if is_num_tag(tag) {
        {}
      } else {
        monoify_iter_dispatch_param_types(
          ctx, type_params, type_bounds, params, body, iter_root, type_subst,
        )
      }
      let updated_params : Array[@core.FuncParam] = []
      let updated_ret = if is_num_tag(tag) {
        let concrete = tag_to_type(tag)
        for param in params {
          updated_params.push(@core.FuncParam::{
            name: param.name,
            label: param.label,
            ty: replace_num_type(param.ty, concrete),
            bounds: param.bounds,
          })
        }
        match ret {
          Some(r) => Some(replace_num_type(r, concrete))
          None => None
        }
      } else {
        for param in params {
          let rewritten_ty = replace_type_params(param.ty, type_subst)
          match iter_param_types.get(param.name) {
            Some(ty) =>
              updated_params.push(@core.FuncParam::{
                name: param.name,
                label: param.label,
                ty,
                bounds: param.bounds,
              })
            None =>
              updated_params.push(@core.FuncParam::{
                name: param.name,
                label: param.label,
                ty: rewritten_ty,
                bounds: param.bounds,
              })
          }
        }
        match ret {
          Some(r) => Some(replace_type_params(r, type_subst))
          None => None
        }
      }
      let fn_scope = DesugarScope::new()
      for param in params {
        fn_scope.bindings[param.name] = true
      }
      let current_spec : Map[String, String] = {}
      current_spec[name] = specialized_name(name, tag)
      if !is_num_tag(tag) {
        let helper_root_ty = monoify_first_iter_param_type(
          params, updated_params, iter_param_types, type_bounds,
        )
        let helper_names = [
          iter_root + "::iter_get",
          iter_root + "::iter_length",
        ]
        for helper_name in helper_names {
          if ctx.specializable.contains(helper_name) {
            match ctx.specializable.get(helper_name) {
              Some(
                @core.Expr::Fn(
                  type_params=helper_type_params,
                  type_bounds=helper_type_bounds,
                  params=helper_params,
                  ..
                )
              ) => {
                let helper_subst : Map[String, @core.Type] = {}
                match helper_root_ty {
                  Some(actual_root_ty) =>
                    if helper_params.length() >= 1 {
                      monoify_collect_type_subst(
                        helper_params[0].ty,
                        actual_root_ty,
                        helper_subst,
                      )
                    }
                  None => ()
                }
                let helper_tag = monoify_iter_inst_tag(
                  iter_root, helper_type_params, helper_type_bounds, helper_subst,
                )
                ctx.add_instantiation(helper_name, {
                  tag: helper_tag,
                  type_subst: helper_subst,
                })
                current_spec[helper_name] = specialized_name(
                  helper_name, helper_tag,
                )
              }
              _ => ()
            }
          }
        }
      }
      let iterable_spec = if is_num_tag(tag) {
        {}
      } else {
        monoify_iter_dispatch_param_spec(params, body, iter_root)
      }
      let local_types = monoify_param_type_map(updated_params)
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params=updated_params,
        ret=updated_ret,
        effects~,
        body=monoify_block(
          body, ctx, fn_scope, current_spec, iterable_spec, local_types,
        ),
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
fn MonoifyContext::tag_for_call(
  self : MonoifyContext,
  name : String,
  args : Array[@core.CallArg],
  local_types : Map[String, @core.Type],
) -> MonoifyInstantiation? {
  let pos_args = positional_args(args)
  match name {
    "add" | "sub" | "mul" | "div" | "eq" | "lt" =>
      if pos_args.length() >= 1 {
        match self.num_tag_from_expr(pos_args[0].expr) {
          Some(tag) => Some({ tag, type_subst: {} })
          None => None
        }
      } else {
        None
      }
    "Array::map" | "Array::filter" =>
      if pos_args.length() >= 2 {
        match self.array_elem_tag_from_expr(pos_args[1].expr) {
          Some(tag) => Some({ tag, type_subst: {} })
          None => None
        }
      } else {
        None
      }
    "Array::fold" =>
      if pos_args.length() >= 2 {
        match self.num_tag_from_expr(pos_args[1].expr) {
          Some(tag) => Some({ tag, type_subst: {} })
          None =>
            if pos_args.length() >= 3 {
              match self.array_elem_tag_from_expr(pos_args[2].expr) {
                Some(tag) => Some({ tag, type_subst: {} })
                None => None
              }
            } else {
              None
            }
        }
      } else {
        None
      }
    _ =>
      if self.specializable_uses_iter_dispatch(name) && pos_args.length() >= 1 {
        self.iter_dispatch_instantiation_for_call(name, pos_args, local_types)
      } else {
        self.root_specialization_for_call(name, pos_args, local_types)
      }
  }
}

///|
fn MonoifyContext::root_specialization_for_call(
  self : MonoifyContext,
  name : String,
  pos_args : Array[@core.CallArg],
  local_types : Map[String, @core.Type],
) -> MonoifyInstantiation? {
  match self.specializable.get(name) {
    Some(@core.Expr::Fn(type_params~, type_bounds~, params~, ..)) =>
      match self.specializable_root_tag_from_call(name, pos_args) {
        Some(root) => {
          let type_subst : Map[String, @core.Type] = {}
          let arg_count = if params.length() < pos_args.length() {
            params.length()
          } else {
            pos_args.length()
          }
          for i in 0..<arg_count {
            match self.actual_arg_type(pos_args[i].expr, local_types) {
              Some(actual_ty) =>
                monoify_collect_type_subst(params[i].ty, actual_ty, type_subst)
              None => ()
            }
            match monoify_expr_annotation_type(pos_args[i].expr) {
              Some(actual_ty) =>
                monoify_collect_type_subst(params[i].ty, actual_ty, type_subst)
              None => ()
            }
          }
          let tag = monoify_iter_inst_tag(
            root, type_params, type_bounds, type_subst,
          )
          Some({ tag, type_subst })
        }
        None => None
      }
    _ => None
  }
}

///|
fn MonoifyContext::iter_dispatch_instantiation_for_call(
  self : MonoifyContext,
  name : String,
  pos_args : Array[@core.CallArg],
  local_types : Map[String, @core.Type],
) -> MonoifyInstantiation? {
  match self.specializable.get(name) {
    Some(@core.Expr::Fn(type_params~, type_bounds~, params~, ..)) =>
      match self.iterable_root_tag_from_expr(pos_args[0].expr) {
        Some(root) => {
          let type_subst : Map[String, @core.Type] = {}
          let arg_count = if params.length() < pos_args.length() {
            params.length()
          } else {
            pos_args.length()
          }
          for i in 0..<arg_count {
            match self.actual_arg_type(pos_args[i].expr, local_types) {
              Some(actual_ty) =>
                monoify_collect_type_subst(params[i].ty, actual_ty, type_subst)
              None => ()
            }
            match monoify_expr_annotation_type(pos_args[i].expr) {
              Some(actual_ty) =>
                monoify_collect_type_subst(params[i].ty, actual_ty, type_subst)
              None => ()
            }
          }
          let tag = monoify_iter_inst_tag(
            root, type_params, type_bounds, type_subst,
          )
          Some({ tag, type_subst })
        }
        None => None
      }
    _ => None
  }
}

///|
fn MonoifyContext::actual_arg_type(
  self : MonoifyContext,
  expr : @core.Expr,
  local_types : Map[String, @core.Type],
) -> @core.Type? {
  match expr {
    @core.Expr::Ident(name~, ..) =>
      match local_types.get(name) {
        Some(ty) => Some(ty)
        None => self.expr_types.get_expr_type(expr.span())
      }
    _ => self.expr_types.get_expr_type(expr.span())
  }
}

///|
fn monoify_expr_annotation_type(expr : @core.Expr) -> @core.Type? {
  match expr {
    @core.Expr::Fn(params~, ret~, effects~, ..) =>
      match ret {
        Some(ret_ty) => Some(@core.Type::Func(params~, ret=ret_ty, effects~))
        None => None
      }
    _ => None
  }
}

///|
fn monoify_collect_type_subst(
  formal : @core.Type,
  actual : @core.Type,
  out : Map[String, @core.Type],
) -> Unit {
  match formal {
    @core.Type::Param(name) =>
      match out.get(name) {
        Some(_) => ()
        None => out[name] = actual
      }
    @core.Type::Named(name~, args~) =>
      match actual {
        @core.Type::Named(name=actual_name, args=actual_args) =>
          if name == actual_name && args.length() == actual_args.length() {
            for i in 0..<args.length() {
              monoify_collect_type_subst(args[i], actual_args[i], out)
            }
          }
        _ => ()
      }
    @core.Type::Tuple(items) =>
      match actual {
        @core.Type::Tuple(actual_items) =>
          if items.length() == actual_items.length() {
            for i in 0..<items.length() {
              monoify_collect_type_subst(items[i], actual_items[i], out)
            }
          }
        _ => ()
      }
    @core.Type::Record(fields) =>
      match actual {
        @core.Type::Record(actual_fields) =>
          for key, item in fields {
            match actual_fields.get(key) {
              Some(actual_item) =>
                monoify_collect_type_subst(item, actual_item, out)
              None => ()
            }
          }
        _ => ()
      }
    @core.Type::Array(inner) =>
      match actual {
        @core.Type::Array(actual_inner) =>
          monoify_collect_type_subst(inner, actual_inner, out)
        _ => ()
      }
    @core.Type::Set(inner) =>
      match actual {
        @core.Type::Set(actual_inner) =>
          monoify_collect_type_subst(inner, actual_inner, out)
        _ => ()
      }
    @core.Type::ArrayBuilder(inner) =>
      match actual {
        @core.Type::ArrayBuilder(actual_inner) =>
          monoify_collect_type_subst(inner, actual_inner, out)
        _ => ()
      }
    @core.Type::Map(key, value) =>
      match actual {
        @core.Type::Map(actual_key, actual_value) => {
          monoify_collect_type_subst(key, actual_key, out)
          monoify_collect_type_subst(value, actual_value, out)
        }
        _ => ()
      }
    @core.Type::MapBuilder(key, value) =>
      match actual {
        @core.Type::MapBuilder(actual_key, actual_value) => {
          monoify_collect_type_subst(key, actual_key, out)
          monoify_collect_type_subst(value, actual_value, out)
        }
        _ => ()
      }
    @core.Type::Variant(fields) =>
      match actual {
        @core.Type::Variant(actual_fields) =>
          for key, item in fields {
            match actual_fields.get(key) {
              Some(actual_item) =>
                monoify_collect_type_subst(item, actual_item, out)
              None => ()
            }
          }
        _ => ()
      }
    @core.Type::Func(params~, ret~, ..) =>
      match actual {
        @core.Type::Func(params=actual_params, ret=actual_ret, ..) => {
          let count = if params.length() < actual_params.length() {
            params.length()
          } else {
            actual_params.length()
          }
          for i in 0..<count {
            monoify_collect_type_subst(params[i].ty, actual_params[i].ty, out)
          }
          monoify_collect_type_subst(ret, actual_ret, out)
        }
        _ => ()
      }
    _ => ()
  }
}

///|
fn monoify_iter_inst_tag(
  root : String,
  type_params : Array[String],
  type_bounds : Map[String, Array[String]],
  type_subst : Map[String, @core.Type],
) -> String {
  let mut tag = root
  for name in type_params {
    let should_include = match type_bounds.get(name) {
      Some(bounds) => !monoify_type_bounds_contains(bounds, "Iterable")
      None => true
    }
    if should_include {
      match type_subst.get(name) {
        Some(ty) => tag = tag + "|" + name + "=" + monoify_type_key(ty)
        None => ()
      }
    }
  }
  tag
}

///|
fn monoify_iter_inst_root_tag(tag : String) -> String {
  let len = String::length(tag)
  let mut i = 0
  while i < len {
    if String::unsafe_get(tag, i) == '|' {
      return String::unsafe_substring(tag, start=0, end=i)
    }
    i = i + 1
  }
  tag
}

///|
fn monoify_type_key(ty : @core.Type) -> String {
  match ty {
    @core.Type::Int => "Int"
    @core.Type::Float => "Float"
    @core.Type::Double => "Double"
    @core.Type::Bool => "Bool"
    @core.Type::Char => "Char"
    @core.Type::String => "String"
    @core.Type::Path => "Path"
    @core.Type::PromptText => "PromptText"
    @core.Type::Unit => "Unit"
    @core.Type::Bytes => "Bytes"
    @core.Type::Param(name) => "Param__" + name
    @core.Type::Named(name~, args~) => {
      let mut out = name
      for arg in args {
        out = out + "__" + monoify_type_key(arg)
      }
      out
    }
    @core.Type::Array(inner) => "Array__" + monoify_type_key(inner)
    @core.Type::Set(inner) => "Set__" + monoify_type_key(inner)
    @core.Type::ArrayBuilder(inner) =>
      "ArrayBuilder__" + monoify_type_key(inner)
    @core.Type::Map(key, value) =>
      "Map__" + monoify_type_key(key) + "__" + monoify_type_key(value)
    @core.Type::MapBuilder(key, value) =>
      "MapBuilder__" + monoify_type_key(key) + "__" + monoify_type_key(value)
    @core.Type::Tuple(items) => {
      let mut out = "Tuple"
      for item in items {
        out = out + "__" + monoify_type_key(item)
      }
      out
    }
    @core.Type::Func(params~, ret~, ..) => {
      let mut out = "Fn"
      for param in params {
        out = out + "__" + monoify_type_key(param.ty)
      }
      out + "__To__" + monoify_type_key(ret)
    }
    _ => ty.to_string()
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
fn MonoifyContext::num_tag_from_expr(
  self : MonoifyContext,
  expr : @core.Expr,
) -> String? {
  match self.expr_types.get_expr_type(expr.span()) {
    Some(ty) => num_tag_from_type(ty)
    None => None
  }
}

///|
fn MonoifyContext::array_elem_tag_from_expr(
  self : MonoifyContext,
  expr : @core.Expr,
) -> String? {
  match self.expr_types.get_expr_type(expr.span()) {
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
fn is_num_tag(tag : String) -> Bool {
  tag == "i32" || tag == "f32" || tag == "f64"
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
fn MonoifyContext::add_instantiation(
  self : MonoifyContext,
  name : String,
  inst : MonoifyInstantiation,
) -> Unit {
  let key = inst_key(name, inst.tag)
  let count = match self.instantiations.get(key) {
    Some(c) => c
    None => 0
  }
  self.instantiations[key] = count + 1
  self.inst_type_subst[key] = inst.type_subst
}

///|
fn MonoifyContext::tags_for_name(
  self : MonoifyContext,
  name : String,
) -> Array[String] {
  let prefix = name + ":"
  let out : Array[String] = []
  for key, _ in self.instantiations {
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
fn MonoifyContext::has_instantiation(
  self : MonoifyContext,
  name : String,
  tag : String,
) -> Bool {
  self.instantiations.contains(inst_key(name, tag))
}

///|
fn MonoifyContext::type_subst_for_instantiation(
  self : MonoifyContext,
  name : String,
  tag : String,
) -> Map[String, @core.Type] {
  match self.inst_type_subst.get(inst_key(name, tag)) {
    Some(subst) => subst
    None => {}
  }
}

///|
fn specialized_name(name : String, tag : String) -> String {
  name + "$" + tag
}

///|
fn MonoifyContext::specializable_uses_iter_dispatch(
  self : MonoifyContext,
  name : String,
) -> Bool {
  match self.specializable.get(name) {
    Some(expr) => fn_uses_iter_dispatch_expr(expr)
    None => false
  }
}

///|
fn MonoifyContext::specializable_root_tag_from_call(
  self : MonoifyContext,
  name : String,
  pos_args : Array[@core.CallArg],
) -> String? {
  if pos_args.is_empty() {
    return None
  }
  match self.specializable.get(name) {
    Some(@core.Expr::Fn(type_params~, params~, ..)) =>
      if fn_has_root_specializable_param(type_params, params) {
        match explicit_root_tag_from_name(name) {
          Some(root) => Some(root)
          None => self.iterable_root_tag_from_expr(pos_args[0].expr)
        }
      } else {
        None
      }
    _ => None
  }
}

///|
fn MonoifyContext::iterable_root_tag_from_expr(
  self : MonoifyContext,
  expr : @core.Expr,
) -> String? {
  match self.expr_types.get_expr_type(expr.span()) {
    Some(@core.Type::Array(_)) => Some("Array")
    Some(@core.Type::Named(name~, ..)) => Some(name)
    _ => None
  }
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
fn fn_has_root_specializable_param(
  type_params : Array[String],
  params : Array[@core.FuncParam],
) -> Bool {
  if type_params.is_empty() || params.is_empty() {
    return false
  }
  match params[0].ty {
    @core.Type::Named(args~, ..) => {
      for arg in args {
        if type_uses_param_names(arg, type_params) {
          return true
        }
      }
      false
    }
    _ => false
  }
}

///|
fn explicit_root_tag_from_name(name : String) -> String? {
  if not(name.contains("::")) {
    return None
  }
  let parts : Array[String] = []
  for part_view in name.split("::") {
    parts.push(part_view.to_string())
  }
  if parts.length() != 2 || parts[0] == "" || parts[1] == "" {
    None
  } else {
    Some(parts[0])
  }
}

///|
fn type_uses_param_names(ty : @core.Type, type_params : Array[String]) -> Bool {
  match ty {
    @core.Type::Param(name) => type_param_names_contains(type_params, name)
    @core.Type::Named(args~, ..) => {
      for arg in args {
        if type_uses_param_names(arg, type_params) {
          return true
        }
      }
      false
    }
    @core.Type::Tuple(items) => {
      for item in items {
        if type_uses_param_names(item, type_params) {
          return true
        }
      }
      false
    }
    @core.Type::Record(fields) => {
      for _, item in fields {
        if type_uses_param_names(item, type_params) {
          return true
        }
      }
      false
    }
    @core.Type::Array(inner)
    | @core.Type::ArrayBuilder(inner)
    | @core.Type::Set(inner) => type_uses_param_names(inner, type_params)
    @core.Type::Map(key, inner) | @core.Type::MapBuilder(key, inner) =>
      type_uses_param_names(key, type_params) ||
      type_uses_param_names(inner, type_params)
    @core.Type::StringBuilder => false
    @core.Type::Variant(fields) => {
      for _, item in fields {
        if type_uses_param_names(item, type_params) {
          return true
        }
      }
      false
    }
    @core.Type::Func(params~, ret~, ..) => {
      for param in params {
        if type_uses_param_names(param.ty, type_params) {
          return true
        }
      }
      type_uses_param_names(ret, type_params)
    }
    _ => false
  }
}

///|
fn type_param_names_contains(
  type_params : Array[String],
  target : String,
) -> Bool {
  for name in type_params {
    if name == target {
      return true
    }
  }
  false
}

///|
fn fn_uses_iter_dispatch_expr(expr : @core.Expr) -> Bool {
  match expr {
    @core.Expr::Fn(body~, ..) => fn_uses_iter_dispatch_module(body)
    _ => false
  }
}

///|
fn fn_uses_iter_dispatch_module(body : @core.Module) -> Bool {
  for stmt in body.stmts {
    if monoify_stmt_uses_iter_dispatch(stmt) {
      return true
    }
  }
  false
}

///|
fn monoify_stmt_uses_iter_dispatch(stmt : @core.Stmt) -> Bool {
  match stmt {
    @core.Stmt::Let(expr~, ..)
    | @core.Stmt::ExportLet(expr~, ..)
    | @core.Stmt::InternalExportLet(expr~, ..)
    | @core.Stmt::LetMut(expr~, ..)
    | @core.Stmt::Expr(expr~, ..) => monoify_expr_uses_iter_dispatch(expr)
    @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
      fn_uses_iter_dispatch_module(body)
    _ => false
  }
}

///|
fn monoify_expr_uses_iter_dispatch(expr : @core.Expr) -> Bool {
  match expr {
    @core.Expr::Call(name~, args~, ..) => {
      if is_iter_dispatch_call_name(name) {
        return true
      }
      for arg in args {
        if monoify_expr_uses_iter_dispatch(arg.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) => {
      for item in items {
        if monoify_expr_uses_iter_dispatch(item) {
          return true
        }
      }
      false
    }
    @core.Expr::Record(fields~, ..) => {
      for field in fields {
        if monoify_expr_uses_iter_dispatch(field.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Map(fields~, ..) => {
      for field in fields {
        if monoify_expr_uses_iter_dispatch(field.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::If(cond~, then_body~, else_body~, ..) =>
      monoify_expr_uses_iter_dispatch(cond) ||
      fn_uses_iter_dispatch_module(then_body) ||
      fn_uses_iter_dispatch_module(else_body)
    @core.Expr::Block(body~, ..) => fn_uses_iter_dispatch_module(body)
    @core.Expr::Handle(body~, arms~, ..) => {
      if fn_uses_iter_dispatch_module(body) {
        return true
      }
      for arm in arms {
        if monoify_expr_uses_iter_dispatch(arm.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      if monoify_expr_uses_iter_dispatch(scrutinee) {
        return true
      }
      for arm in arms {
        if monoify_expr_uses_iter_dispatch(arm.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Fn(body~, ..) => fn_uses_iter_dispatch_module(body)
    _ => false
  }
}

///|
fn is_iter_dispatch_call_name(name : String) -> Bool {
  name == "iter_require" || name == "iter_length" || name == "iter_get"
}

///|
fn param_names(params : Array[@core.FuncParam]) -> Array[String] {
  let out : Array[String] = []
  for param in params {
    out.push(param.name)
  }
  out
}

///|
fn monoify_iterable_spec_without(
  iterable_spec : Map[String, String],
  names : Array[String],
) -> Map[String, String] {
  let next : Map[String, String] = {}
  for key, value in iterable_spec {
    next[key] = value
  }
  for name in names {
    ignore(next.remove(name))
  }
  next
}

///|
fn monoify_iter_dispatch_param_spec(
  params : Array[@core.FuncParam],
  body : @core.Module,
  root : String,
) -> Map[String, String] {
  let params_map : Map[String, Bool] = {}
  for param in params {
    params_map[param.name] = true
  }
  let out : Map[String, String] = {}
  let names = monoify_iter_dispatch_param_names(body)
  for name in names {
    if params_map.contains(name) {
      out[name] = root
    }
  }
  out
}

///|
fn monoify_iter_dispatch_param_types(
  ctx : MonoifyContext,
  type_params : Array[String],
  type_bounds : Map[String, Array[String]],
  params : Array[@core.FuncParam],
  body : @core.Module,
  root : String,
  type_subst : Map[String, @core.Type],
) -> Map[String, @core.Type] {
  let root_ty = monoify_iter_dispatch_root_type(
    ctx, type_params, type_bounds, root, type_subst,
  )
  let out : Map[String, @core.Type] = {}
  match root_ty {
    Some(ty) => {
      let names : Map[String, Bool] = {}
      for name in monoify_iter_dispatch_param_names(body) {
        names[name] = true
      }
      for param in params {
        if names.contains(param.name) &&
          monoify_param_is_iterable_type_param(param, type_bounds) {
          out[param.name] = ty
        }
      }
      out
    }
    None => out
  }
}

///|
fn monoify_first_iter_param_type(
  params : Array[@core.FuncParam],
  updated_params : Array[@core.FuncParam],
  iter_param_types : Map[String, @core.Type],
  type_bounds : Map[String, Array[String]],
) -> @core.Type? {
  let param_count = if params.length() < updated_params.length() {
    params.length()
  } else {
    updated_params.length()
  }
  for i in 0..<param_count {
    if iter_param_types.contains(params[i].name) {
      return Some(updated_params[i].ty)
    }
  }
  for i in 0..<param_count {
    if monoify_param_is_iterable_type_param(params[i], type_bounds) {
      return Some(updated_params[i].ty)
    }
  }
  None
}

///|
fn monoify_param_type_map(
  params : Array[@core.FuncParam],
) -> Map[String, @core.Type] {
  let out : Map[String, @core.Type] = {}
  for param in params {
    out[param.name] = param.ty
  }
  out
}

///|
fn monoify_param_is_iterable_type_param(
  param : @core.FuncParam,
  type_bounds : Map[String, Array[String]],
) -> Bool {
  match param.ty {
    @core.Type::Param(name) =>
      match type_bounds.get(name) {
        Some(bounds) => monoify_type_bounds_contains(bounds, "Iterable")
        None => false
      }
    _ => false
  }
}

///|
fn monoify_type_bounds_contains(
  bounds : Array[String],
  target : String,
) -> Bool {
  for bound in bounds {
    if bound == target {
      return true
    }
  }
  false
}

///|
fn monoify_iter_dispatch_root_type(
  ctx : MonoifyContext,
  type_params : Array[String],
  type_bounds : Map[String, Array[String]],
  root : String,
  type_subst : Map[String, @core.Type],
) -> @core.Type? {
  match monoify_iter_dispatch_root_type_from_helper(ctx, root, type_params) {
    Some(ty) => Some(replace_type_params(ty, type_subst))
    None =>
      if root == "Array" {
        match monoify_first_non_iterable_type_param(type_params, type_bounds) {
          Some(name) =>
            Some(
              replace_type_params(
                @core.Type::Array(@core.Type::Param(name)),
                type_subst,
              ),
            )
          None => None
        }
      } else {
        None
      }
  }
}

///|
fn monoify_iter_dispatch_root_type_from_helper(
  ctx : MonoifyContext,
  root : String,
  type_params : Array[String],
) -> @core.Type? {
  let helper_names = [root + "::iter_get", root + "::iter_length"]
  for helper_name in helper_names {
    match ctx.specializable.get(helper_name) {
      Some(@core.Expr::Fn(params~, ..)) =>
        if params.length() >= 1 &&
          monoify_type_uses_only_params(params[0].ty, type_params) {
          return Some(params[0].ty)
        }
      _ => ()
    }
  }
  None
}

///|
fn monoify_first_non_iterable_type_param(
  type_params : Array[String],
  type_bounds : Map[String, Array[String]],
) -> String? {
  for name in type_params {
    match type_bounds.get(name) {
      Some(bounds) =>
        if !monoify_type_bounds_contains(bounds, "Iterable") {
          return Some(name)
        }
      None => return Some(name)
    }
  }
  None
}

///|
fn monoify_type_uses_only_params(
  ty : @core.Type,
  allowed_params : Array[String],
) -> Bool {
  match ty {
    @core.Type::Param(name) => type_param_names_contains(allowed_params, name)
    @core.Type::Named(args~, ..) => {
      for arg in args {
        if !monoify_type_uses_only_params(arg, allowed_params) {
          return false
        }
      }
      true
    }
    @core.Type::Tuple(items) => {
      for item in items {
        if !monoify_type_uses_only_params(item, allowed_params) {
          return false
        }
      }
      true
    }
    @core.Type::Record(fields) => {
      for _, item in fields {
        if !monoify_type_uses_only_params(item, allowed_params) {
          return false
        }
      }
      true
    }
    @core.Type::Array(inner)
    | @core.Type::ArrayBuilder(inner)
    | @core.Type::Set(inner) =>
      monoify_type_uses_only_params(inner, allowed_params)
    @core.Type::Map(key, inner) | @core.Type::MapBuilder(key, inner) =>
      monoify_type_uses_only_params(key, allowed_params) &&
      monoify_type_uses_only_params(inner, allowed_params)
    @core.Type::Variant(fields) => {
      for _, item in fields {
        if !monoify_type_uses_only_params(item, allowed_params) {
          return false
        }
      }
      true
    }
    @core.Type::Func(params~, ret~, ..) => {
      for param in params {
        if !monoify_type_uses_only_params(param.ty, allowed_params) {
          return false
        }
      }
      monoify_type_uses_only_params(ret, allowed_params)
    }
    _ => true
  }
}

///|
fn monoify_iter_dispatch_param_names(body : @core.Module) -> Array[String] {
  let seen : Map[String, Bool] = {}
  let out : Array[String] = []
  monoify_collect_iter_dispatch_param_names_module(body, seen, out)
  out
}

///|
fn monoify_collect_iter_dispatch_param_names_module(
  body : @core.Module,
  seen : Map[String, Bool],
  out : Array[String],
) -> Unit {
  for stmt in body.stmts {
    monoify_collect_iter_dispatch_param_names_stmt(stmt, seen, out)
  }
}

///|
fn monoify_collect_iter_dispatch_param_names_stmt(
  stmt : @core.Stmt,
  seen : Map[String, Bool],
  out : Array[String],
) -> Unit {
  match stmt {
    @core.Stmt::Let(expr~, ..)
    | @core.Stmt::ExportLet(expr~, ..)
    | @core.Stmt::InternalExportLet(expr~, ..)
    | @core.Stmt::LetMut(expr~, ..)
    | @core.Stmt::Expr(expr~, ..) =>
      monoify_collect_iter_dispatch_param_names_expr(expr, seen, out)
    @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
      monoify_collect_iter_dispatch_param_names_module(body, seen, out)
    _ => ()
  }
}

///|
fn monoify_collect_iter_dispatch_param_names_expr(
  expr : @core.Expr,
  seen : Map[String, Bool],
  out : Array[String],
) -> Unit {
  match expr {
    @core.Expr::Call(name~, args~, ..) => {
      if is_iter_dispatch_call_name(name) {
        let pos_args = positional_args(args)
        for arg in pos_args {
          match arg.expr {
            @core.Expr::Ident(name=recv, ..) =>
              if not(seen.contains(recv)) {
                seen[recv] = true
                out.push(recv)
              }
            _ => ()
          }
        }
      }
      for arg in args {
        monoify_collect_iter_dispatch_param_names_expr(arg.expr, seen, out)
      }
    }
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) =>
      for item in items {
        monoify_collect_iter_dispatch_param_names_expr(item, seen, out)
      }
    @core.Expr::Record(fields~, ..) =>
      for field in fields {
        monoify_collect_iter_dispatch_param_names_expr(field.expr, seen, out)
      }
    @core.Expr::Map(fields~, ..) =>
      for field in fields {
        monoify_collect_iter_dispatch_param_names_expr(field.expr, seen, out)
      }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      monoify_collect_iter_dispatch_param_names_expr(cond, seen, out)
      monoify_collect_iter_dispatch_param_names_module(then_body, seen, out)
      monoify_collect_iter_dispatch_param_names_module(else_body, seen, out)
    }
    @core.Expr::Block(body~, ..) =>
      monoify_collect_iter_dispatch_param_names_module(body, seen, out)
    @core.Expr::Handle(body~, arms~, ..) => {
      monoify_collect_iter_dispatch_param_names_module(body, seen, out)
      for arm in arms {
        monoify_collect_iter_dispatch_param_names_expr(arm.expr, seen, out)
      }
    }
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      monoify_collect_iter_dispatch_param_names_expr(scrutinee, seen, out)
      for arm in arms {
        monoify_collect_iter_dispatch_param_names_expr(arm.expr, seen, out)
      }
    }
    @core.Expr::Fn(body~, ..) =>
      monoify_collect_iter_dispatch_param_names_module(body, seen, out)
    _ => ()
  }
}

///|
fn rewrite_iter_dispatch_call_name(
  name : String,
  args : Array[@core.CallArg],
  iterable_spec : Map[String, String],
) -> String {
  if not(is_iter_dispatch_call_name(name)) {
    return name
  }
  let pos_args = positional_args(args)
  for arg in pos_args {
    match arg.expr {
      @core.Expr::Ident(name=recv, ..) =>
        match iterable_spec.get(recv) {
          Some(root) =>
            return if root == "Array" { name } else { root + "::" + name }
          None => ()
        }
      _ => ()
    }
  }
  name
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
    | @core.Type::ArrayBuilder(inner)
    | @core.Type::Set(inner) => has_num_type(inner)
    @core.Type::Map(_key, inner) | @core.Type::MapBuilder(_key, inner) =>
      has_num_type(inner)
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
fn replace_type_params(
  ty : @core.Type,
  type_subst : Map[String, @core.Type],
) -> @core.Type {
  match ty {
    @core.Type::Param(name) =>
      match type_subst.get(name) {
        Some(concrete) => concrete
        None => ty
      }
    @core.Type::Named(name~, args~) => {
      let out : Array[@core.Type] = []
      for arg in args {
        out.push(replace_type_params(arg, type_subst))
      }
      @core.Type::Named(name~, args=out)
    }
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      for item in items {
        out.push(replace_type_params(item, type_subst))
      }
      @core.Type::Tuple(out)
    }
    @core.Type::Record(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = replace_type_params(item, type_subst)
      }
      @core.Type::Record(out)
    }
    @core.Type::Array(inner) =>
      @core.Type::Array(replace_type_params(inner, type_subst))
    @core.Type::Set(inner) =>
      @core.Type::Set(replace_type_params(inner, type_subst))
    @core.Type::Map(key, inner) =>
      @core.Type::Map(
        replace_type_params(key, type_subst),
        replace_type_params(inner, type_subst),
      )
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(replace_type_params(inner, type_subst))
    @core.Type::MapBuilder(key, inner) =>
      @core.Type::MapBuilder(
        replace_type_params(key, type_subst),
        replace_type_params(inner, type_subst),
      )
    @core.Type::Variant(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = replace_type_params(item, type_subst)
      }
      @core.Type::Variant(out)
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let out : Array[@core.FuncParam] = []
      for param in params {
        out.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: replace_type_params(param.ty, type_subst),
          bounds: param.bounds,
        })
      }
      @core.Type::Func(
        params=out,
        ret=replace_type_params(ret, type_subst),
        effects~,
      )
    }
    _ => ty
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
    @core.Type::Set(inner) => @core.Type::Set(replace_num_type(inner, concrete))
    @core.Type::Map(key, inner) =>
      @core.Type::Map(
        replace_num_type(key, concrete),
        replace_num_type(inner, concrete),
      )
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(replace_num_type(inner, concrete))
    @core.Type::MapBuilder(key, inner) =>
      @core.Type::MapBuilder(
        replace_num_type(key, concrete),
        replace_num_type(inner, concrete),
      )
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
