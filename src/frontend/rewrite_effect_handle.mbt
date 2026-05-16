///| Rewrite `handle { body } with Effect { Op(x) => resume(val); ... }` into

///| inline calls. This implements tail-resumptive effect handler inlining.

///|

///| Before:

///|   handle { perform Console::ReadLine } with Console { ReadLine => resume("Alice"); }

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
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::InternalExportLet(
        rec~,
        name~,
        expr=reh_rewrite_expr(expr),
        span~,
      )
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
    // perform Error::Throw(msg) flows through as Perform (unified with Raise)
    // Desugar: perform Fs::Op(args) → Fs::builtin(args)
    @core.Expr::Perform(effect_name="Fs", op_name~, args~, span~) => {
      let builtin_name = match op_name {
        "ReadFile" => "Fs::read_file"
        "WriteFile" => "Fs::write_file"
        "Exists" => "Fs::exists"
        "Mkdir" => "Fs::mkdir"
        "MkdirP" => "Fs::mkdir_p"
        "Remove" => "Fs::remove"
        "Copy" => "Fs::copy"
        "Rename" => "Fs::rename"
        "ReadDir" => "Fs::readdir"
        "IsDir" => "Fs::is_dir"
        "IsFile" => "Fs::is_file"
        "Getcwd" => "Fs::getcwd"
        "Chdir" => "Fs::chdir"
        "Append" => "Fs::append"
        _ => "Fs::" + op_name
      }
      @core.Expr::Call(name=builtin_name, type_args=[], args~, span~)
    }
    // Desugar: perform Http::Op → Http::builtin
    @core.Expr::Perform(effect_name="Http", op_name~, args~, span~) => {
      let builtin_name = match op_name {
        "Listen" => "Http::listen"
        "Accept" => "Http::accept"
        "Close" => "Http::close"
        "Request" => "Http::request"
        "Respond" => "Http::respond"
        "RequestMethod" => "Http::request_method"
        "RequestUrl" => "Http::request_url"
        "RequestHeader" => "Http::request_header"
        "RequestBody" => "Http::request_body"
        "ResponseStatus" => "Http::response_status"
        "ResponseHeader" => "Http::response_header"
        "ResponseBody" => "Http::response_body"
        _ => "Http::" + op_name
      }
      @core.Expr::Call(name=builtin_name, type_args=[], args~, span~)
    }
    // Desugar: perform Socket::Op → Socket::builtin
    @core.Expr::Perform(effect_name="Socket", op_name~, args~, span~) => {
      let builtin_name = match op_name {
        "Connect" => "Socket::tcp_connect"
        "Read" => "Socket::tcp_read"
        "Write" => "Socket::tcp_write"
        "Close" => "Socket::tcp_close"
        _ => "Socket::" + op_name
      }
      @core.Expr::Call(name=builtin_name, type_args=[], args~, span~)
    }
    // Desugar: perform Process::Exec(cmd) → sh(cmd)
    @core.Expr::Perform(effect_name="Process", op_name="Exec", args~, span~) =>
      @core.Expr::Call(name="sh", type_args=[], args~, span~)
    // Desugar: perform Env::Op → Env::builtin
    @core.Expr::Perform(effect_name="Env", op_name~, args~, span~) => {
      let builtin_name = match op_name {
        "Get" => "Env::get"
        "ArgsLen" => "Env::args_len"
        "ArgsGet" => "Env::args_get"
        _ => "Env::" + op_name
      }
      @core.Expr::Call(name=builtin_name, type_args=[], args~, span~)
    }
    // Desugar: perform Stdout::Op → builtin
    @core.Expr::Perform(effect_name="Stdout", op_name~, args~, span~) => {
      let builtin_name = match op_name {
        "WriteChar" => "stdout_write_char"
        "WriteStream" => "Stdout::write_stream"
        _ => "Stdout::" + op_name
      }
      @core.Expr::Call(name=builtin_name, type_args=[], args~, span~)
    }
    // Desugar: perform Stdin::Op → builtin
    @core.Expr::Perform(effect_name="Stdin", op_name~, args~, span~) => {
      let builtin_name = match op_name {
        "ReadChar" => "stdin_read_char"
        "ReadStream" => "Stdin::read_stream"
        _ => "Stdin::" + op_name
      }
      @core.Expr::Call(name=builtin_name, type_args=[], args~, span~)
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
          cond: arm.cond.map(fn(c) { reh_rewrite_expr(c) }),
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
    @core.Expr::Tuple(items~, span~) =>
      @core.Expr::Tuple(items=items.map(reh_rewrite_expr), span~)
    @core.Expr::Array(items~, span~) =>
      @core.Expr::Array(items=items.map(reh_rewrite_expr), span~)
    @core.Expr::TupleIndex(expr=inner, index~, span~) =>
      @core.Expr::TupleIndex(expr=reh_rewrite_expr(inner), index~, span~)
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) =>
      @core.Expr::ForIn(
        value_name~,
        index_name~,
        iterable=reh_rewrite_expr(iterable),
        body=reh_rewrite_module(body),
        span~,
      )
    @core.Expr::Loop(params~, body~, span~) => {
      let next_params : Array[@core.LoopParam] = []
      for param in params {
        next_params.push(@core.LoopParam::{
          name: param.name,
          init: reh_rewrite_expr(param.init),
          span: param.span,
        })
      }
      @core.Expr::Loop(params=next_params, body=reh_rewrite_module(body), span~)
    }
    @core.Expr::Break(value~, span~) =>
      @core.Expr::Break(value=value.map(fn(v) { reh_rewrite_expr(v) }), span~)
    @core.Expr::Continue(args~, span~) =>
      @core.Expr::Continue(args=args.map(reh_rewrite_expr), span~)
    @core.Expr::Record(fields~, span~) => {
      let next_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        next_fields.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: reh_rewrite_expr(field.expr),
          span: field.span,
        })
      }
      @core.Expr::Record(fields=next_fields, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let next_fields : Array[@core.MapFieldExpr] = []
      for field in fields {
        next_fields.push(@core.MapFieldExpr::{
          key: field.key,
          expr: reh_rewrite_expr(field.expr),
          span: field.span,
        })
      }
      @core.Expr::Map(fields=next_fields, span~)
    }
    @core.Expr::StructLit(name~, type_args~, fields~, span~) => {
      let next_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        next_fields.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: reh_rewrite_expr(field.expr),
          span: field.span,
        })
      }
      @core.Expr::StructLit(name~, type_args~, fields=next_fields, span~)
    }
    @core.Expr::StringInterp(parts~, span~) => {
      let next_parts : Array[@core.StringInterpPart] = []
      for part in parts {
        match part {
          @core.StringInterpPart::Lit(_) => next_parts.push(part)
          @core.StringInterpPart::Expr(e) =>
            next_parts.push(@core.StringInterpPart::Expr(reh_rewrite_expr(e)))
        }
      }
      @core.Expr::StringInterp(parts=next_parts, span~)
    }
    @core.Expr::Yield(expr=inner, span~) =>
      @core.Expr::Yield(expr=reh_rewrite_expr(inner), span~)
    @core.Expr::Spread(expr=inner, span~) =>
      @core.Expr::Spread(expr=reh_rewrite_expr(inner), span~)
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
fn reh_is_builtin_error_handler_name(name : String) -> Bool {
  name == "Error" || name == "Error::Throw" || name == "Throw"
}

///|
fn reh_parse_effect_arm(arm : @core.MatchArm) -> EffectHandler? {
  // Pattern must be Ctor("Effect::Op", params)
  let (key, param_names) = match arm.pat {
    @core.Pat::Ctor(name~, args~, ..) =>
      if name.contains("::") && !reh_is_builtin_error_handler_name(name) {
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
  // Also handle Block where last stmt is resume(val)
  let resume_expr = reh_extract_resume_expr(arm.expr)
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
/// Extract resume expression from handler arm body.
/// Handles: `resume(val)`, `{ stmts...; resume(val) }`, or returns expr as-is.
fn reh_extract_resume_expr(expr : @core.Expr) -> @core.Expr {
  match expr {
    @core.Expr::Call(name="__resume", args~, ..) =>
      if args.length() == 1 {
        args[0].expr
      } else {
        expr
      }
    @core.Expr::Block(body~, span~) => {
      // Check if last statement is Expr(Call("__resume", [val]))
      let stmts = body.stmts
      if stmts.length() > 0 {
        let last = stmts[stmts.length() - 1]
        match last {
          @core.Stmt::Expr(
            expr=@core.Expr::Call(name="__resume", args~, ..),
            ..
          ) =>
            if args.length() == 1 {
              // Replace last stmt with just the resume arg value
              let new_stmts : Array[@core.Stmt] = []
              for i = 0; i < stmts.length() - 1; i = i + 1 {
                new_stmts.push(stmts[i])
              }
              let last_span = last.span()
              new_stmts.push(
                @core.Stmt::Expr(expr=args[0].expr, span=last_span),
              )
              @core.Expr::Block(body=@core.Module::{ stmts: new_stmts }, span~)
            } else {
              expr
            }
          _ => expr
        }
      } else {
        expr
      }
    }
    _ => expr
  }
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
    // No effect handlers — keep as ordinary handle
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
    // Reconstruct effect handler arms for codegen (cross-function dispatch)
    let all_arms : Array[@core.MatchArm] = []
    for _key, handler in effect_handlers {
      all_arms.push({
        pat: reh_handler_to_pat(handler, span),
        cond: None,
        expr: handler.raw_expr,
        span,
      })
    }
    for arm in error_arms {
      all_arms.push(arm)
    }
    // Always keep Handle for cross-function dispatch via try-catch
    @core.Expr::Handle(body=rewritten_body, arms=all_arms, span~)
  }
}

///|
fn reh_handler_to_pat(handler : EffectHandler, span : @core.Span) -> @core.Pat {
  let args : Array[@core.Pat] = handler.param_names.map(fn(name) {
    if name == "_" {
      @core.Pat::Wildcard(span~)
    } else {
      @core.Pat::Bind(name~, span~)
    }
  })
  @core.Pat::Ctor(name=handler.key, args~, span~)
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
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::InternalExportLet(
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
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      for arm in arms {
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: arm.cond.map(fn(c) { reh_replace_performs_expr(c, handlers) }),
          expr: reh_replace_performs_expr(arm.expr, handlers),
          span: arm.span,
        })
      }
      @core.Expr::Match(
        scrutinee=reh_replace_performs_expr(scrutinee, handlers),
        arms=next_arms,
        span~,
      )
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      // Replace performs in the inner handle body, but do NOT re-enter
      // reh_rewrite_handle (which would cause infinite recursion when
      // the inner handle has error-only arms and the outer handler inlines
      // performs inside the body).
      let inner_body = reh_replace_performs(body, handlers)
      let inner_arms : Array[@core.MatchArm] = []
      for arm in arms {
        inner_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: arm.cond.map(fn(c) { reh_replace_performs_expr(c, handlers) }),
          expr: reh_replace_performs_expr(arm.expr, handlers),
          span: arm.span,
        })
      }
      @core.Expr::Handle(body=inner_body, arms=inner_arms, span~)
    }
    @core.Expr::Tuple(items~, span~) =>
      @core.Expr::Tuple(
        items=items.map(fn(e) { reh_replace_performs_expr(e, handlers) }),
        span~,
      )
    @core.Expr::Array(items~, span~) =>
      @core.Expr::Array(
        items=items.map(fn(e) { reh_replace_performs_expr(e, handlers) }),
        span~,
      )
    @core.Expr::TupleIndex(expr=inner, index~, span~) =>
      @core.Expr::TupleIndex(
        expr=reh_replace_performs_expr(inner, handlers),
        index~,
        span~,
      )
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) =>
      @core.Expr::ForIn(
        value_name~,
        index_name~,
        iterable=reh_replace_performs_expr(iterable, handlers),
        body=reh_replace_performs(body, handlers),
        span~,
      )
    @core.Expr::Loop(params~, body~, span~) => {
      let next_params : Array[@core.LoopParam] = []
      for param in params {
        next_params.push(@core.LoopParam::{
          name: param.name,
          init: reh_replace_performs_expr(param.init, handlers),
          span: param.span,
        })
      }
      @core.Expr::Loop(
        params=next_params,
        body=reh_replace_performs(body, handlers),
        span~,
      )
    }
    @core.Expr::Break(value~, span~) =>
      @core.Expr::Break(
        value=value.map(fn(v) { reh_replace_performs_expr(v, handlers) }),
        span~,
      )
    @core.Expr::Continue(args~, span~) =>
      @core.Expr::Continue(
        args=args.map(fn(e) { reh_replace_performs_expr(e, handlers) }),
        span~,
      )
    @core.Expr::Record(fields~, span~) => {
      let next_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        next_fields.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: reh_replace_performs_expr(field.expr, handlers),
          span: field.span,
        })
      }
      @core.Expr::Record(fields=next_fields, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let next_fields : Array[@core.MapFieldExpr] = []
      for field in fields {
        next_fields.push(@core.MapFieldExpr::{
          key: field.key,
          expr: reh_replace_performs_expr(field.expr, handlers),
          span: field.span,
        })
      }
      @core.Expr::Map(fields=next_fields, span~)
    }
    @core.Expr::StructLit(name~, type_args~, fields~, span~) => {
      let next_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        next_fields.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: reh_replace_performs_expr(field.expr, handlers),
          span: field.span,
        })
      }
      @core.Expr::StructLit(name~, type_args~, fields=next_fields, span~)
    }
    @core.Expr::StringInterp(parts~, span~) => {
      let next_parts : Array[@core.StringInterpPart] = []
      for part in parts {
        match part {
          @core.StringInterpPart::Lit(_) => next_parts.push(part)
          @core.StringInterpPart::Expr(e) =>
            next_parts.push(
              @core.StringInterpPart::Expr(
                reh_replace_performs_expr(e, handlers),
              ),
            )
        }
      }
      @core.Expr::StringInterp(parts=next_parts, span~)
    }
    @core.Expr::Yield(expr=inner, span~) =>
      @core.Expr::Yield(expr=reh_replace_performs_expr(inner, handlers), span~)
    @core.Expr::Spread(expr=inner, span~) =>
      @core.Expr::Spread(expr=reh_replace_performs_expr(inner, handlers), span~)
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
    if !handler.has_continuation {
      return None
    }
    if !reh_is_accumulate_pattern(handler) {
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
let cps_counter : Ref[Int] = Ref(0)

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
  // Rewrite __resume → k (continuation name) in the handler body
  let rewritten_raw = reh_rewrite_resume_to_k(
    handler.raw_expr,
    handler.continuation_name,
  )
  bindings.push(@core.Stmt::Expr(expr=rewritten_raw, span~))
  @core.Expr::Block(body=@core.Module::{ stmts: bindings }, span~)
}

///|
/// Rewrite Call("__resume", [val]) → Call(k_name, [val]) in an expression tree.
fn reh_rewrite_resume_to_k(expr : @core.Expr, k_name : String) -> @core.Expr {
  match expr {
    @core.Expr::Call(name="__resume", type_args~, args~, span~) =>
      @core.Expr::Call(
        name=k_name,
        type_args~,
        args=args.map(fn(a) {
          @core.CallArg::{
            label: a.label,
            expr: reh_rewrite_resume_to_k(a.expr, k_name),
            span: a.span,
          }
        }),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(
        body=@core.Module::{
          stmts: body.stmts.map(fn(s) {
            reh_rewrite_resume_to_k_stmt(s, k_name)
          }),
        },
        span~,
      )
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=reh_rewrite_resume_to_k(cond, k_name),
        then_body=@core.Module::{
          stmts: then_body.stmts.map(fn(s) {
            reh_rewrite_resume_to_k_stmt(s, k_name)
          }),
        },
        else_body=@core.Module::{
          stmts: else_body.stmts.map(fn(s) {
            reh_rewrite_resume_to_k_stmt(s, k_name)
          }),
        },
        span~,
      )
    @core.Expr::Call(name~, type_args~, args~, span~) =>
      @core.Expr::Call(
        name~,
        type_args~,
        args=args.map(fn(a) {
          @core.CallArg::{
            label: a.label,
            expr: reh_rewrite_resume_to_k(a.expr, k_name),
            span: a.span,
          }
        }),
        span~,
      )
    _ => expr
  }
}

///|
fn reh_rewrite_resume_to_k_stmt(
  stmt : @core.Stmt,
  k_name : String,
) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) =>
      @core.Stmt::Let(
        rec~,
        name~,
        expr=reh_rewrite_resume_to_k(expr, k_name),
        span~,
      )
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(expr=reh_rewrite_resume_to_k(expr, k_name), span~)
    @core.Stmt::LetMut(name~, expr~, span~) =>
      @core.Stmt::LetMut(
        name~,
        expr=reh_rewrite_resume_to_k(expr, k_name),
        span~,
      )
    _ => stmt
  }
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
