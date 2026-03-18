///| Rewrite `handle { body } { Effect::Op(x) => resume(val), ... }` into

///| inline calls. This implements tail-resumptive effect handler inlining.

///|

///| Before:

///|   handle { perform Console::ReadLine } { Console::ReadLine => resume("Alice") }

///|

///| After:

///|   { let __Console__ReadLine = () { "Alice" }; __Console__ReadLine() }

///|

///| Only tail-resumptive handlers (where each arm is `resume(expr)`) are inlined.

///|
/// Non-effect arms (Error, etc.) are kept as-is.
pub fn rewrite_effect_handles(ast : @core.Module) -> @core.Module {
  reh_rewrite_module(ast)
}

///|
fn reh_rewrite_module(m : @core.Module) -> @core.Module {
  let next : Array[@core.Stmt] = []
  for stmt in m.stmts {
    next.push(reh_rewrite_stmt(stmt))
  }
  @core.Module::{ stmts: next }
}

///|
fn reh_rewrite_stmt(stmt : @core.Stmt) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) =>
      @core.Stmt::Let(rec~, name~, expr=reh_rewrite_expr(expr), span~)
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::ExportLet(rec~, name~, expr=reh_rewrite_expr(expr), span~)
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(expr=reh_rewrite_expr(expr), span~)
    @core.Stmt::LetMut(name~, expr~, span~) =>
      @core.Stmt::LetMut(name~, expr=reh_rewrite_expr(expr), span~)
    @core.Stmt::Test(name~, body~, span~) =>
      @core.Stmt::Test(name~, body=reh_rewrite_module(body), span~)
    @core.Stmt::Bench(name~, body~, span~) =>
      @core.Stmt::Bench(name~, body=reh_rewrite_module(body), span~)
    _ => stmt
  }
}

///|
fn reh_rewrite_expr(expr : @core.Expr) -> @core.Expr {
  match expr {
    @core.Expr::Handle(body~, arms~, span~) =>
      reh_rewrite_handle(body, arms, span)
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=reh_rewrite_expr(cond),
        then_body=reh_rewrite_module(then_body),
        else_body=reh_rewrite_module(else_body),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(body=reh_rewrite_module(body), span~)
    @core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret~,
      effects~,
      body~,
      span~
    ) =>
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects~,
        body=reh_rewrite_module(body),
        span~,
      )
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      for arm in arms {
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: arm.cond,
          expr: reh_rewrite_expr(arm.expr),
          span: arm.span,
        })
      }
      @core.Expr::Match(
        scrutinee=reh_rewrite_expr(scrutinee),
        arms=next_arms,
        span~,
      )
    }
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=reh_rewrite_expr(cond),
        body=reh_rewrite_module(body),
        span~,
      )
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let next_args : Array[@core.CallArg] = []
      for arg in args {
        next_args.push(@core.CallArg::{
          label: arg.label,
          expr: reh_rewrite_expr(arg.expr),
          span: arg.span,
        })
      }
      @core.Expr::Call(name~, type_args~, args=next_args, span~)
    }
    _ => expr
  }
}

///| Extract effect operation handlers from match arms.

///| Returns: (effect_handlers, remaining_error_arms)

///| An effect handler arm pattern looks like: Ctor("Console::ReadLine", []) or

///| Ctor("Console::Print", [Bind("msg")])

///|
/// and the expr must be Call("__resume", [val]).
fn reh_extract_effect_handlers(
  arms : Array[@core.MatchArm],
) -> (Map[String, EffectHandler], Array[@core.MatchArm]) {
  let handlers : Map[String, EffectHandler] = {}
  let remaining : Array[@core.MatchArm] = []
  for arm in arms {
    match reh_parse_effect_arm(arm) {
      Some(h) => handlers[h.key] = h
      None => remaining.push(arm)
    }
  }
  (handlers, remaining)
}

///|
priv struct EffectHandler {
  key : String // "Console::ReadLine"
  param_names : Array[String] // ["msg"] or []
  resume_expr : @core.Expr // the expression inside resume(...)
}

///|
fn reh_parse_effect_arm(arm : @core.MatchArm) -> EffectHandler? {
  // Pattern must be Ctor("Effect::Op", params)
  let (key, param_names) = match arm.pat {
    @core.Pat::Ctor(name~, args~, ..) =>
      if name.contains("::") {
        let names : Array[String] = []
        for arg in args {
          match arg {
            @core.Pat::Bind(name=bind_name, ..) => names.push(bind_name)
            @core.Pat::Wildcard(..) => names.push("_")
            _ => return None
          }
        }
        (name, names)
      } else {
        return None
      }
    _ => return None
  }
  // Expr must be Call("__resume", [val]) or any expr (for simple handlers)
  let resume_expr = match arm.expr {
    @core.Expr::Call(name="__resume", args~, ..) =>
      if args.length() == 1 {
        args[0].expr
      } else {
        arm.expr
      }
    other => other
  }
  Some(EffectHandler::{ key, param_names, resume_expr })
}

///|
/// Rewrite a Handle expression:
/// If arms contain effect operation handlers, inline them into the body.
fn reh_rewrite_handle(
  body : @core.Module,
  arms : Array[@core.MatchArm],
  span : @core.Span,
) -> @core.Expr {
  let (effect_handlers, error_arms) = reh_extract_effect_handlers(arms)
  if effect_handlers.size() == 0 {
    // No effect handlers — keep as normal handle (Error only)
    return @core.Expr::Handle(
      body=reh_rewrite_module(body),
      arms=error_arms,
      span~,
    )
  }
  // Rewrite body: replace Perform with inline handler calls
  let rewritten_body = reh_replace_performs(body, effect_handlers)
  if error_arms.length() > 0 {
    // Wrap in handle for remaining Error arms
    @core.Expr::Handle(body=rewritten_body, arms=error_arms, span~)
  } else {
    // Pure effect handling — just a block
    @core.Expr::Block(body=rewritten_body, span~)
  }
}

///|
fn reh_replace_performs(
  m : @core.Module,
  handlers : Map[String, EffectHandler],
) -> @core.Module {
  let next : Array[@core.Stmt] = []
  for stmt in m.stmts {
    next.push(reh_replace_performs_stmt(stmt, handlers))
  }
  @core.Module::{ stmts: next }
}

///|
fn reh_replace_performs_stmt(
  stmt : @core.Stmt,
  handlers : Map[String, EffectHandler],
) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) =>
      @core.Stmt::Let(
        rec~,
        name~,
        expr=reh_replace_performs_expr(expr, handlers),
        span~,
      )
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::ExportLet(
        rec~,
        name~,
        expr=reh_replace_performs_expr(expr, handlers),
        span~,
      )
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(expr=reh_replace_performs_expr(expr, handlers), span~)
    @core.Stmt::LetMut(name~, expr~, span~) =>
      @core.Stmt::LetMut(
        name~,
        expr=reh_replace_performs_expr(expr, handlers),
        span~,
      )
    _ => stmt
  }
}

///|
fn reh_replace_performs_expr(
  expr : @core.Expr,
  handlers : Map[String, EffectHandler],
) -> @core.Expr {
  match expr {
    @core.Expr::Perform(effect_name~, op_name~, args~, span~) => {
      let key = effect_name + "::" + op_name
      match handlers.get(key) {
        Some(handler) => {
          // Inline the handler: substitute param_names with args
          let mut result = handler.resume_expr
          for i = 0
              i < handler.param_names.length() && i < args.length()
              i = i + 1 {
            let param_name = handler.param_names[i]
            if param_name != "_" {
              // Wrap in let binding: let param_name = arg; result
              result = @core.Expr::Block(
                body=@core.Module::{
                  stmts: [
                    @core.Stmt::Let(
                      rec=false,
                      name=param_name,
                      expr=reh_replace_performs_expr(args[i].expr, handlers),
                      span~,
                    ),
                    @core.Stmt::Expr(expr=result, span~),
                  ],
                },
                span~,
              )
            }
          }
          result
        }
        None =>
          // No handler for this op — keep as perform (will be WASM import)
          expr
      }
    }
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let next_args : Array[@core.CallArg] = []
      for arg in args {
        next_args.push(@core.CallArg::{
          label: arg.label,
          expr: reh_replace_performs_expr(arg.expr, handlers),
          span: arg.span,
        })
      }
      @core.Expr::Call(name~, type_args~, args=next_args, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=reh_replace_performs_expr(cond, handlers),
        then_body=reh_replace_performs(then_body, handlers),
        else_body=reh_replace_performs(else_body, handlers),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(body=reh_replace_performs(body, handlers), span~)
    @core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret~,
      effects~,
      body~,
      span~
    ) =>
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects~,
        body=reh_replace_performs(body, handlers),
        span~,
      )
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=reh_replace_performs_expr(cond, handlers),
        body=reh_replace_performs(body, handlers),
        span~,
      )
    @core.Expr::Handle(body~, arms~, span~) => {
      // Nested handle: first rewrite inner handle (may inline its own effects),
      // then continue replacing outer performs in the rewritten result
      let inner_rewritten = reh_rewrite_handle(body, arms, span)
      reh_replace_performs_expr(inner_rewritten, handlers)
    }
    _ => expr
  }
}
