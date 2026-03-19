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
    // Desugar: perform Error::Throw(msg) → throw(msg) (Raise)
    @core.Expr::Perform(effect_name="Error", op_name="Throw", args~, span~) =>
      if args.length() >= 1 {
        @core.Expr::Raise(value=reh_rewrite_expr(args[0].expr), span~)
      } else {
        @core.Expr::Raise(value=@core.Expr::String(value="", span~), span~)
      }
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
  param_names : Array[String] // ["msg"] or [] (excludes k)
  resume_expr : @core.Expr // the expression inside resume(...)
  has_continuation : Bool // true if handler has k parameter (CPS mode)
  continuation_name : String // "k" or "" — name of continuation param
  raw_expr : @core.Expr // original handler expression (for CPS)
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
  // Detect CPS mode: last param name is the continuation (not matching op arity)
  // Convention: handler arm has one more param than the effect op = continuation
  // E.g. Yield::Yield(v, k) where Yield has 1 param → k is continuation
  let has_continuation = param_names.length() > 0 &&
    param_names[param_names.length() - 1] == "k"
  let (effective_params, cont_name) = if has_continuation {
    let p : Array[String] = []
    for i = 0; i < param_names.length() - 1; i = i + 1 {
      p.push(param_names[i])
    }
    (p, "k")
  } else {
    (param_names, "")
  }
  // Expr must be Call("__resume", [val]) or any expr
  let resume_expr = match arm.expr {
    @core.Expr::Call(name="__resume", args~, ..) =>
      if args.length() == 1 {
        args[0].expr
      } else {
        arm.expr
      }
    other => other
  }
  Some(EffectHandler::{
    key,
    param_names: effective_params,
    resume_expr,
    has_continuation,
    continuation_name: cont_name,
    raw_expr: arm.expr,
  })
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
  if effect_handlers.length() == 0 {
    // No effect handlers — keep as normal handle (Error only)
    return @core.Expr::Handle(
      body=reh_rewrite_module(body),
      arms=error_arms,
      span~,
    )
  }
  // Check if any handler uses CPS (has_continuation)
  let mut has_cps = false
  for _key, handler in effect_handlers {
    if handler.has_continuation {
      has_cps = true
      break
    }
  }
  if has_cps {
    // Try defunctionalization first: fold accumulate patterns into a loop
    match reh_try_defunctionalize(body.stmts, effect_handlers, span) {
      Some(defunc_expr) =>
        if error_arms.length() > 0 {
          return @core.Expr::Handle(
            body=@core.Module::{
              stmts: [@core.Stmt::Expr(expr=defunc_expr, span~)],
            },
            arms=error_arms,
            span~,
          )
        } else {
          return defunc_expr
        }
      None => ()
    }
    // Fallback: CPS transform with nested continuations
    let cps_expr = reh_cps_transform(body.stmts, effect_handlers, span)
    if error_arms.length() > 0 {
      @core.Expr::Handle(
        body=@core.Module::{ stmts: [@core.Stmt::Expr(expr=cps_expr, span~)] },
        arms=error_arms,
        span~,
      )
    } else {
      cps_expr
    }
  } else {
    // Tail-resumptive: inline handler at perform sites
    let rewritten_body = reh_replace_performs(body, effect_handlers)
    if error_arms.length() > 0 {
      @core.Expr::Handle(body=rewritten_body, arms=error_arms, span~)
    } else {
      // Pure effect handling — just a block
      @core.Expr::Block(body=rewritten_body, span~)
    }
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
      let inner_rewritten = reh_rewrite_handle(body, arms, span)
      reh_replace_performs_expr(inner_rewritten, handlers)
    }
    _ => expr
  }
}

///| Try to defunctionalize CPS handlers into unrolled fold statements.

///| Pattern: `Op(v, k) => v + k(base)` with all performs being `perform Op(const)`.

///|
/// Generates: `{ let mut acc = base; acc = vN + acc; ...; acc = v1 + acc; acc }`
fn reh_try_defunctionalize(
  stmts : Array[@core.Stmt],
  handlers : Map[String, EffectHandler],
  span : @core.Span,
) -> @core.Expr? {
  // Collect all performs and non-perform stmts
  let performs : Array[(@core.Expr, String)] = [] // (arg_expr, handler_key)
  let mut base_expr : @core.Expr? = None
  for i = 0; i < stmts.length(); i = i + 1 {
    match stmts[i] {
      @core.Stmt::Expr(
        expr=@core.Expr::Perform(effect_name~, op_name~, args~, ..),
        ..
      ) => {
        let key = effect_name + "::" + op_name
        match handlers.get(key) {
          Some(handler) =>
            if handler.has_continuation {
              let arg = if args.length() > 0 {
                args[0].expr
              } else {
                @core.Expr::Int(value=0L, span~)
              }
              performs.push((arg, key))
            } else {
              return None // mixed tail-resumptive and CPS
            }
          None => return None
        }
      }
      @core.Stmt::Expr(expr~, ..) =>
        if i == stmts.length() - 1 {
          base_expr = Some(expr)
        } else {
          return None // non-perform non-final stmt
        }
      _ => return None
    }
  }
  // Check all handlers match the accumulate pattern: v OP k(base)
  // For now: only support `v + k(0)` or `v + k(base)` pattern
  let base = match base_expr {
    Some(e) => e
    None => @core.Expr::Int(value=0L, span~)
  }
  // Verify all handlers are accumulate: raw_expr is BinOp("+", v, Call(k, [arg]))
  for _key, handler in handlers {
    if not(handler.has_continuation) {
      return None
    }
    if not(reh_is_accumulate_pattern(handler)) {
      return None
    }
  }
  // Generate unrolled fold: { let mut __acc = base; __acc = vN + __acc; ...; __acc }
  let acc_name = "__defunc_acc"
  // Get the handler template for fold step generation
  let mut fold_handler : EffectHandler? = None
  for _key, handler in handlers {
    if handler.has_continuation {
      fold_handler = Some(handler)
      break
    }
  }
  let handler = match fold_handler {
    Some(h) => h
    None => return None
  }
  let v_name = if handler.param_names.length() > 0 {
    handler.param_names[0]
  } else {
    "_"
  }
  let fold_stmts : Array[@core.Stmt] = []
  fold_stmts.push(@core.Stmt::LetMut(name=acc_name, expr=base, span~))
  // Reverse order: last perform first (right fold)
  for i = performs.length() - 1; i >= 0; i = i - 1 {
    let (arg_expr, _key) = performs[i]
    // acc = template[v := arg, k(base) := acc]
    let step_expr = reh_substitute_fold_template(
      handler.raw_expr,
      v_name,
      handler.continuation_name,
      arg_expr,
      acc_name,
      span,
    )
    fold_stmts.push(@core.Stmt::Assign(name=acc_name, expr=step_expr, span~))
  }
  fold_stmts.push(
    @core.Stmt::Expr(expr=@core.Expr::Ident(name=acc_name, span~), span~),
  )
  Some(@core.Expr::Block(body=@core.Module::{ stmts: fold_stmts }, span~))
}

///| Check if a CPS handler can be defunctionalized.

///| The handler body must contain exactly one call to k (the continuation).

///|
/// Returns true if the handler body is a pure expression using v and k(base).
fn reh_is_accumulate_pattern(handler : EffectHandler) -> Bool {
  reh_count_k_calls(handler.raw_expr, handler.continuation_name) == 1
}

///|
/// Count how many times the continuation k is called in an expression.
fn reh_count_k_calls(expr : @core.Expr, k_name : String) -> Int {
  match expr {
    @core.Expr::Call(name~, args~, ..) => {
      let mut count = 0
      if name == k_name {
        count += 1
      }
      for arg in args {
        count += reh_count_k_calls(arg.expr, k_name)
      }
      count
    }
    @core.Expr::Ident(name~, ..) => if name == k_name { 1 } else { 0 }
    _ => 0
  }
}

///| Substitute v → arg_expr and k(base) → acc_ident in a handler body expression.

///|
/// Returns the fold step expression.
fn reh_substitute_fold_template(
  expr : @core.Expr,
  v_name : String,
  k_name : String,
  arg_expr : @core.Expr,
  acc_name : String,
  span : @core.Span,
) -> @core.Expr {
  match expr {
    @core.Expr::Ident(name~, ..) =>
      if name == v_name {
        arg_expr
      } else if name == k_name {
        // bare k reference (shouldn't happen in well-formed code)
        @core.Expr::Ident(name=acc_name, span~)
      } else {
        expr
      }
    @core.Expr::Call(name~, type_args~, args~, span=call_span) =>
      // Check if this is k(base) — Call where callee resolves to k
      // In the parsed AST, k(0) is Call(name="k", args=[0])
      if name == k_name {
        // Replace k(base) with acc
        @core.Expr::Ident(name=acc_name, span~)
      } else {
        // Recursively substitute in args
        let new_args : Array[@core.CallArg] = []
        for arg in args {
          new_args.push(@core.CallArg::{
            label: arg.label,
            expr: reh_substitute_fold_template(
              arg.expr,
              v_name,
              k_name,
              arg_expr,
              acc_name,
              span,
            ),
            span: arg.span,
          })
        }
        @core.Expr::Call(name~, type_args~, args=new_args, span=call_span)
      }
    @core.Expr::If(cond~, then_body~, else_body~, span=if_span) =>
      @core.Expr::If(
        cond=reh_substitute_fold_template(
          cond, v_name, k_name, arg_expr, acc_name, span,
        ),
        then_body~,
        else_body~,
        span=if_span,
      )
    _ => expr
  }
}

///|
/// CPS transform: convert a list of statements into nested continuation calls.
fn reh_cps_transform(
  stmts : Array[@core.Stmt],
  handlers : Map[String, EffectHandler],
  span : @core.Span,
) -> @core.Expr {
  reh_cps_stmts(stmts, 0, handlers, span)
}

///|
fn reh_cps_stmts(
  stmts : Array[@core.Stmt],
  idx : Int,
  handlers : Map[String, EffectHandler],
  span : @core.Span,
) -> @core.Expr {
  if idx >= stmts.length() {
    @core.Expr::Int(value=0L, span~)
  } else {
    match stmts[idx] {
      @core.Stmt::Expr(expr~, ..) =>
        reh_cps_expr(expr, stmts, idx + 1, handlers, span)
      @core.Stmt::Let(name~, expr~, ..) =>
        reh_cps_let(name, expr, stmts, idx + 1, handlers, span)
      _ => reh_cps_stmts(stmts, idx + 1, handlers, span)
    }
  }
}

///|

///|
/// Global counter for generating unique spans in CPS expansion
let cps_counter : Ref[Int] = Ref::new(0)

///|
/// Generate a unique span offset for CPS expansion
fn cps_unique_span(base : @core.Span) -> @core.Span {
  let c = cps_counter.val
  cps_counter.val = c + 1
  // Offset the span slightly to make each CPS expansion unique
  @core.Span::{
    start: base.start + 100000 + c * 100,
    end: base.end + 100000 + c * 100,
  }
}

///|
fn reh_cps_expr(
  expr : @core.Expr,
  stmts : Array[@core.Stmt],
  next_idx : Int,
  handlers : Map[String, EffectHandler],
  span : @core.Span,
) -> @core.Expr {
  match expr {
    @core.Expr::Perform(effect_name~, op_name~, args~, ..) => {
      let key = effect_name + "::" + op_name
      match handlers.get(key) {
        Some(handler) =>
          if handler.has_continuation {
            let rest = reh_cps_stmts(stmts, next_idx, handlers, span)
            let unique_span = cps_unique_span(span)
            let k_fn = @core.Expr::Fn(
              type_params=[],
              type_bounds={},
              params=[
                @core.FuncParam::{
                  name: "__cps_arg",
                  label: @core.ParamLabel::Positional,
                  ty: @core.Type::Unit,
                  bounds: [],
                },
              ],
              ret=None,
              effects=[],
              body=@core.Module::{
                stmts: [@core.Stmt::Expr(expr=rest, span=unique_span)],
              },
              span=unique_span,
            )
            reh_build_cps_call(handler, args, k_fn, unique_span)
          } else {
            let inlined = reh_inline_handler(handler, args, span)
            if next_idx >= stmts.length() {
              inlined
            } else {
              let rest = reh_cps_stmts(stmts, next_idx, handlers, span)
              @core.Expr::Block(
                body=@core.Module::{
                  stmts: [
                    @core.Stmt::Expr(expr=inlined, span~),
                    @core.Stmt::Expr(expr=rest, span~),
                  ],
                },
                span~,
              )
            }
          }
        None =>
          if next_idx >= stmts.length() {
            expr
          } else {
            let rest = reh_cps_stmts(stmts, next_idx, handlers, span)
            @core.Expr::Block(
              body=@core.Module::{
                stmts: [
                  @core.Stmt::Expr(expr~, span~),
                  @core.Stmt::Expr(expr=rest, span~),
                ],
              },
              span~,
            )
          }
      }
    }
    _ =>
      if next_idx >= stmts.length() {
        expr
      } else {
        let rest = reh_cps_stmts(stmts, next_idx, handlers, span)
        @core.Expr::Block(
          body=@core.Module::{
            stmts: [
              @core.Stmt::Expr(expr~, span~),
              @core.Stmt::Expr(expr=rest, span~),
            ],
          },
          span~,
        )
      }
  }
}

///|
fn reh_cps_let(
  name : String,
  expr : @core.Expr,
  stmts : Array[@core.Stmt],
  next_idx : Int,
  handlers : Map[String, EffectHandler],
  span : @core.Span,
) -> @core.Expr {
  match expr {
    @core.Expr::Perform(effect_name~, op_name~, args~, ..) => {
      let key = effect_name + "::" + op_name
      match handlers.get(key) {
        Some(handler) =>
          if handler.has_continuation {
            let rest = reh_cps_stmts(stmts, next_idx, handlers, span)
            let unique_span = cps_unique_span(span)
            let k_fn = @core.Expr::Fn(
              type_params=[],
              type_bounds={},
              params=[
                @core.FuncParam::{
                  name,
                  label: @core.ParamLabel::Positional,
                  ty: @core.Type::Unit,
                  bounds: [],
                },
              ],
              ret=None,
              effects=[],
              body=@core.Module::{
                stmts: [@core.Stmt::Expr(expr=rest, span=unique_span)],
              },
              span=unique_span,
            )
            reh_build_cps_call(handler, args, k_fn, unique_span)
          } else {
            let rest = reh_cps_stmts(stmts, next_idx, handlers, span)
            @core.Expr::Block(
              body=@core.Module::{
                stmts: [
                  @core.Stmt::Let(
                    rec=false,
                    name~,
                    expr=reh_inline_handler(handler, args, span),
                    span~,
                  ),
                  @core.Stmt::Expr(expr=rest, span~),
                ],
              },
              span~,
            )
          }
        None => {
          let rest = reh_cps_stmts(stmts, next_idx, handlers, span)
          @core.Expr::Block(
            body=@core.Module::{
              stmts: [
                @core.Stmt::Let(rec=false, name~, expr~, span~),
                @core.Stmt::Expr(expr=rest, span~),
              ],
            },
            span~,
          )
        }
      }
    }
    _ => {
      let rest = reh_cps_stmts(stmts, next_idx, handlers, span)
      @core.Expr::Block(
        body=@core.Module::{
          stmts: [
            @core.Stmt::Let(rec=false, name~, expr~, span~),
            @core.Stmt::Expr(expr=rest, span~),
          ],
        },
        span~,
      )
    }
  }
}

///|
fn reh_build_cps_call(
  handler : EffectHandler,
  args : Array[@core.CallArg],
  k_fn : @core.Expr,
  span : @core.Span,
) -> @core.Expr {
  let bindings : Array[@core.Stmt] = []
  for i = 0; i < handler.param_names.length() && i < args.length(); i = i + 1 {
    if handler.param_names[i] != "_" {
      bindings.push(
        @core.Stmt::Let(
          rec=false,
          name=handler.param_names[i],
          expr=args[i].expr,
          span~,
        ),
      )
    }
  }
  bindings.push(
    @core.Stmt::Let(rec=false, name=handler.continuation_name, expr=k_fn, span~),
  )
  bindings.push(@core.Stmt::Expr(expr=handler.raw_expr, span~))
  @core.Expr::Block(body=@core.Module::{ stmts: bindings }, span~)
}

///|
fn reh_inline_handler(
  handler : EffectHandler,
  args : Array[@core.CallArg],
  span : @core.Span,
) -> @core.Expr {
  let mut result = handler.resume_expr
  for i = 0; i < handler.param_names.length() && i < args.length(); i = i + 1 {
    let param_name = handler.param_names[i]
    if param_name != "_" {
      result = @core.Expr::Block(
        body=@core.Module::{
          stmts: [
            @core.Stmt::Let(
              rec=false,
              name=param_name,
              expr=args[i].expr,
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
