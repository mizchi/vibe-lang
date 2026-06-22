///|
fn AstParser::parse_expr(self : AstParser) -> @core.Expr raise ParseError {
  self.skip_trivia()
  if self.peek_kind() == if_kw() {
    self.parse_if_expr()
  } else if self.peek_kind() == for_kw() {
    self.parse_for_in_expr()
  } else if self.peek_kind() == while_kw() {
    self.parse_while_expr()
  } else if self.peek_kind() == loop_kw() {
    self.parse_loop_expr()
  } else if self.peek_kind() == match_kw() {
    self.parse_match_expr()
  } else if self.peek_kind() == handle_kw() {
    self.parse_handle_expr()
  } else if self.peek_kind() == break_kw() {
    self.parse_break_expr()
  } else if self.peek_kind() == continue_kw() {
    self.parse_continue_expr()
  } else if self.peek_kind() == return_kw() {
    self.parse_return_expr()
  } else if self.peek_kind() == raise_kw() {
    self.parse_removed_raise_expr()
  } else if self.peek_kind() == yield_kw() {
    self.parse_yield_expr()
  } else if self.peek_kind() == record_kw() {
    self.parse_record_expr()
  } else if self.peek_kind() == map_kw() {
    self.parse_map_expr()
  } else if self.peek_kind() == lbracket() {
    // Could be array literal or generic function: [T](x: T) -> T { x }
    match self.try_parse_arrow_fn() {
      Some(fn_expr) => fn_expr
      None => self.parse_array_expr()
    }
  } else if self.peek_kind() == lbrace() {
    let start = self.pos
    let body = self.parse_block()
    let span = self.span_from(start)
    @core.Expr::Block(body~, span~)
  } else {
    let left = self.parse_or_expr()
    // Check for `expr is pattern` (Bool-returning) outside if context
    self.skip_trivia()
    if self.peek_kind() == is_kw() {
      let is_start = self.pos
      let _ = self.bump() // consume "is"
      let pat = self.parse_pattern()
      let span = self.span_from(is_start)
      @core.Expr::Match(
        scrutinee=left,
        arms=[
          @core.MatchArm::{
            pat,
            cond: None,
            expr: @core.Expr::Bool(value=true, span~),
            span,
          },
          @core.MatchArm::{
            pat: @core.Pat::Wildcard(span~),
            cond: None,
            expr: @core.Expr::Bool(value=false, span~),
            span,
          },
        ],
        span~,
      )
    } else {
      left
    }
  }
}

///|
fn AstParser::parse_pipe_expr(self : AstParser) -> @core.Expr raise ParseError {
  let left_start = self.pos
  let mut left = self.parse_expr_bp(0)
  let mut left_has_top_level_infix = self.has_top_level_non_pipe_infix(
    left_start,
    self.pos,
  )
  while ({
          self.skip_trivia()
          self.peek_kind() == pipe_gt()
        }) {
    let pipe_span = self.token_span()
    let pipe_tok = self.bump()
    if left_has_top_level_infix {
      raise ParseError::UnexpectedToken(
        expected="parenthesize infix expression when mixing with `|>`",
        got=pipe_tok.text(),
        span=pipe_span,
      )
    }
    let right_start = self.pos
    let right = self.parse_expr_bp(0)
    if self.has_top_level_non_pipe_infix(right_start, self.pos) {
      raise ParseError::UnexpectedToken(
        expected="parenthesize infix expression when mixing with `|>`",
        got=pipe_tok.text(),
        span=pipe_span,
      )
    }
    left = pipe_apply(left, right)
    left_has_top_level_infix = false
  }
  left
}

///|
fn is_non_pipe_infix_token(kind : @cst.SyntaxKind) -> Bool {
  kind == plus() ||
  kind == minus() ||
  kind == star() ||
  kind == slash() ||
  kind == percent() ||
  kind == lshift() ||
  kind == rshift() ||
  kind == lt() ||
  kind == lte() ||
  kind == gt() ||
  kind == gte() ||
  kind == eqeq() ||
  kind == neq() ||
  kind == bit_and() ||
  kind == bit_or() ||
  kind == bit_xor() ||
  kind == and_and() ||
  kind == or_or()
}

///|
fn AstParser::has_top_level_non_pipe_infix(
  self : AstParser,
  start_pos : Int,
  end_pos : Int,
) -> Bool {
  let mut paren_depth = 0
  let mut bracket_depth = 0
  let mut brace_depth = 0
  let mut i = start_pos
  while i < end_pos && i < self.tokens.length() {
    let kind = self.tokens[i].kind()
    if kind == lparen() {
      paren_depth += 1
    } else if kind == rparen() {
      if paren_depth > 0 {
        paren_depth -= 1
      }
    } else if kind == lbracket() {
      bracket_depth += 1
    } else if kind == rbracket() {
      if bracket_depth > 0 {
        bracket_depth -= 1
      }
    } else if kind == lbrace() {
      brace_depth += 1
    } else if kind == rbrace() {
      if brace_depth > 0 {
        brace_depth -= 1
      }
    } else if paren_depth == 0 &&
      bracket_depth == 0 &&
      brace_depth == 0 &&
      is_non_pipe_infix_token(kind) {
      return true
    }
    i += 1
  }
  false
}

///|
fn binary_binding_power(kind : @cst.SyntaxKind) -> (Int, Int)? {
  if kind == bit_or() {
    Some((2, 3))
  } else if kind == bit_xor() {
    Some((4, 5))
  } else if kind == bit_and() {
    Some((6, 7))
  } else if kind == eqeq() ||
    kind == neq() ||
    kind == lt() ||
    kind == lte() ||
    kind == gt() ||
    kind == gte() {
    Some((8, 9))
  } else if kind == lshift() || kind == rshift() {
    Some((10, 11))
  } else if kind == plus() || kind == minus() {
    Some((12, 13))
  } else if kind == star() || kind == slash() || kind == percent() {
    Some((14, 15))
  } else {
    None
  }
}

///|
fn make_binary_expr(
  op : @cst.SyntaxKind,
  left : @core.Expr,
  right : @core.Expr,
) -> @core.Expr {
  if op == bit_or() {
    call2("__bit_or", left, right)
  } else if op == bit_xor() {
    call2("__bit_xor", left, right)
  } else if op == bit_and() {
    call2("__bit_and", left, right)
  } else if op == lshift() {
    call2("__lshift", left, right)
  } else if op == rshift() {
    call2("__rshift", left, right)
  } else if op == plus() {
    call2("__add", left, right)
  } else if op == minus() {
    call2("__sub", left, right)
  } else if op == star() {
    call2("__mul", left, right)
  } else if op == slash() {
    call2("__div", left, right)
  } else if op == percent() {
    call2("__mod", left, right)
  } else {
    cmp_expr_from_op(op, left, right)
  }
}

///|
fn AstParser::parse_expr_bp(
  self : AstParser,
  min_bp : Int,
) -> @core.Expr raise ParseError {
  let mut left = self.parse_unary_expr()
  while true {
    self.skip_trivia()
    let kind = self.peek_kind()
    match binary_binding_power(kind) {
      Some((l_bp, r_bp)) =>
        if l_bp < min_bp {
          break
        } else {
          let _ = self.bump()
          let right = self.parse_expr_bp(r_bp)
          left = make_binary_expr(kind, left, right)
        }
      None => break
    }
  }
  left
}

///|
fn AstParser::parse_or_expr(self : AstParser) -> @core.Expr raise ParseError {
  let mut left = self.parse_and_expr()
  while ({
          self.skip_trivia()
          self.peek_kind() == or_or()
        }) {
    let _ = self.bump()
    let right = self.parse_and_expr()
    let left_span = left.span()
    let right_span = right.span()
    let span = @core.Span::merge(left_span, right_span)
    let then_expr = @core.Expr::Bool(value=true, span~)
    let then_body = @core.Module::{
      stmts: [@core.Stmt::Expr(expr=then_expr, span~)],
    }
    let else_body = @core.Module::{
      stmts: [@core.Stmt::Expr(expr=right, span=right_span)],
    }
    left = @core.Expr::If(cond=left, then_body~, else_body~, span~)
  }
  left
}

///|
fn AstParser::parse_and_expr(self : AstParser) -> @core.Expr raise ParseError {
  let mut left = self.parse_pipe_expr()
  while ({
          self.skip_trivia()
          self.peek_kind() == and_and()
        }) {
    let _ = self.bump()
    let right = self.parse_pipe_expr()
    let left_span = left.span()
    let right_span = right.span()
    let span = @core.Span::merge(left_span, right_span)
    let else_expr = @core.Expr::Bool(value=false, span~)
    let then_body = @core.Module::{
      stmts: [@core.Stmt::Expr(expr=right, span=right_span)],
    }
    let else_body = @core.Module::{
      stmts: [@core.Stmt::Expr(expr=else_expr, span~)],
    }
    left = @core.Expr::If(cond=left, then_body~, else_body~, span~)
  }
  left
}

///|
fn cmp_expr_from_op(
  op : @cst.SyntaxKind,
  left : @core.Expr,
  right : @core.Expr,
) -> @core.Expr {
  match op {
    k if k == eqeq() => call2("__eq", left, right)
    k if k == neq() => call1("__not", call2("__eq", left, right))
    k if k == lt() => call2("__lt", left, right)
    k if k == gt() => call2("__lt", right, left)
    k if k == lte() =>
      call2("__or", call2("__lt", left, right), call2("__eq", left, right))
    _ => call2("__or", call2("__lt", right, left), call2("__eq", left, right))
  }
}

///|
fn call1(name : String, value : @core.Expr) -> @core.Expr {
  let span = value.span()
  @core.Expr::Call(
    name~,
    type_args=[],
    args=[@core.CallArg::{ label: None, expr: value, span }],
    span~,
  )
}

///|
fn call2(name : String, left : @core.Expr, right : @core.Expr) -> @core.Expr {
  let left_span = left.span()
  let right_span = right.span()
  let span = @core.Span::merge(left_span, right_span)
  @core.Expr::Call(
    name~,
    type_args=[],
    args=[
      @core.CallArg::{ label: None, expr: left, span: left_span },
      @core.CallArg::{ label: None, expr: right, span: right_span },
    ],
    span~,
  )
}

///|
fn call3(
  name : String,
  a : @core.Expr,
  b : @core.Expr,
  c : @core.Expr,
) -> @core.Expr {
  let a_span = a.span()
  let c_span = c.span()
  let span = @core.Span::merge(a_span, c_span)
  @core.Expr::Call(
    name~,
    type_args=[],
    args=[
      @core.CallArg::{ label: None, expr: a, span: a_span },
      @core.CallArg::{ label: None, expr: b, span: b.span() },
      @core.CallArg::{ label: None, expr: c, span: c_span },
    ],
    span~,
  )
}

///|
fn call_or_throw_expr(
  name : String,
  type_args : Array[@core.Type],
  args : Array[@core.CallArg],
  span : @core.Span,
) -> @core.Expr raise ParseError {
  if name != "throw" && name != "perform" && name != "resume" {
    return @core.Expr::Call(name~, type_args~, args~, span~)
  }
  if name == "throw" {
    if type_args.length() != 0 {
      raise ParseError::UnexpectedToken(
        expected="throw does not accept type arguments. Use `throw(expr)` instead.",
        got="throw[<type>](...)",
        span~,
      )
    }
    if args.length() != 1 {
      raise ParseError::UnexpectedToken(
        expected="throw takes exactly one argument. Use `throw(expr)` instead.",
        got="throw(...) with \{args.length()} arguments",
        span~,
      )
    }
    match args[0].label {
      Some(_) =>
        raise ParseError::UnexpectedToken(
          expected="throw does not accept labeled arguments. Use `throw(expr)` instead.",
          got="throw(label=...)",
          span~,
        )
      None =>
        return @core.Expr::Perform(
          effect_name="Error",
          op_name="Throw",
          args~,
          span~,
        )
    }
  }
  if name == "perform" {
    if type_args.length() != 0 {
      raise ParseError::UnexpectedToken(
        expected="perform does not accept type arguments. Use `perform Effect::Op(args)` instead.",
        got="perform[<type>](...)",
        span~,
      )
    }
    if args.length() != 1 {
      raise ParseError::UnexpectedToken(
        expected="perform requires the form `perform Effect::Op(args)`.",
        got="perform(...) with \{args.length()} arguments",
        span~,
      )
    }
    match args[0].label {
      Some(_) =>
        raise ParseError::UnexpectedToken(
          expected="perform does not accept labeled arguments. Use `perform Effect::Op(args)` instead.",
          got="perform(label=...)",
          span~,
        )
      None =>
        return @core.Expr::Call(name="__perform", type_args=[], args~, span~)
    }
  }
  if type_args.length() != 0 {
    raise ParseError::UnexpectedToken(
      expected="resume does not accept type arguments. Use `resume(expr)` instead.",
      got="resume[<type>](...)",
      span~,
    )
  }
  if args.length() != 1 {
    raise ParseError::UnexpectedToken(
      expected="resume takes exactly one argument. Use `resume(expr)` instead.",
      got="resume(...) with \{args.length()} arguments",
      span~,
    )
  }
  match args[0].label {
    Some(_) =>
      raise ParseError::UnexpectedToken(
        expected="resume does not accept labeled arguments. Use `resume(expr)` instead.",
        got="resume(label=...)",
        span~,
      )
    None => @core.Expr::Call(name="__resume", type_args=[], args~, span~)
  }
}

///|
fn pipe_apply(
  left : @core.Expr,
  right : @core.Expr,
) -> @core.Expr raise ParseError {
  match right {
    @core.Expr::Ident(name~, span~) => {
      let left_span = left.span()
      let call_span = @core.Span::merge(left_span, span)
      @core.Expr::Call(
        name~,
        type_args=[],
        args=[@core.CallArg::{ label: None, expr: left, span: left_span }],
        span=call_span,
      )
    }
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let left_span = left.span()
      let call_span = @core.Span::merge(left_span, span)
      // Bare `_` placeholder slot: `x |> f(a, _)` substitutes the piped value
      // at each `_` hole (`f(a, x)`) instead of prepending. Only direct args
      // are checked; a compound `_ * 2` arg is a section lambda and still
      // triggers the prepend path (matches selfhost `pipe_desugar`).
      let mut has_hole = false
      for arg in args {
        if arg.expr is @core.Expr::Placeholder(..) {
          has_hole = true
        }
      }
      let out : Array[@core.CallArg] = []
      if has_hole {
        for arg in args {
          if arg.expr is @core.Expr::Placeholder(..) {
            out.push(@core.CallArg::{ label: None, expr: left, span: left_span })
          } else {
            out.push(arg)
          }
        }
      } else {
        out.push(@core.CallArg::{ label: None, expr: left, span: left_span })
        for arg in args {
          out.push(arg)
        }
      }
      @core.Expr::Call(name~, type_args~, args=out, span=call_span)
    }
    _ =>
      raise ParseError::UnexpectedToken(
        expected="call",
        got=right.to_string(),
        span=right.span(),
      )
  }
}

///|
fn AstParser::parse_unary_expr(self : AstParser) -> @core.Expr raise ParseError {
  self.skip_trivia()
  match self.peek_kind() {
    k if k == minus() => {
      let start_pos = self.pos
      let _ = self.bump()
      self.skip_trivia()
      if self.peek_kind() == int_lit() {
        let lit = self.peek()
        if lit.text() == "2305843009213693952" {
          let span = @core.Span::new(
            self.offset_at(start_pos),
            self.offset_at(self.pos) + lit.text().length(),
          )
          raise ParseError::IntMinLiteralBoundary(span~)
        }
      }
      let value = self.parse_unary_expr()
      call1("__neg", value)
    }
    k if k == bang() => {
      let _ = self.bump()
      let value = self.parse_unary_expr()
      call1("__not", value)
    }
    _ => self.parse_call_or_primary()
  }
}

///|
/// Convert a Module (block body) into a single expression for use in match arms.
/// Unlike Expr::Block, this does not create a new scope, so pattern bindings
/// from the match arm remain visible.
fn module_to_match_body(body : @core.Module, span : @core.Span) -> @core.Expr {
  if body.stmts.is_empty() {
    @core.Expr::Tuple(items=[], span~)
  } else if body.stmts.length() == 1 {
    match body.stmts[0] {
      @core.Stmt::Expr(expr~, ..) => expr
      _ => @core.Expr::Block(body~, span~)
    }
  } else {
    @core.Expr::Block(body~, span~)
  }
}

///|
/// Parse an optional else branch: `else { ... }` or `else if ...` or `else expr`.
/// Returns an empty Module (Unit) if no else branch is present.
fn AstParser::parse_else_body(
  self : AstParser,
) -> @core.Module raise ParseError {
  self.skip_trivia()
  if self.peek_kind() == else_kw() {
    let _ = self.bump()
    self.skip_trivia()
    if self.peek_kind() == lbrace() {
      self.parse_block()
    } else {
      let expr = self.parse_expr()
      let expr_span = expr.span()
      @core.Module::{ stmts: [@core.Stmt::Expr(expr~, span=expr_span)] }
    }
  } else {
    @core.Module::{ stmts: [] }
  }
}

///|
fn AstParser::parse_if_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(if_kw(), "if")
  // Use parse_or_expr (not parse_expr) so `is` is not consumed as Bool-returning
  let cond = self.parse_or_expr()
  // Check for `if expr is pattern { ... }` syntax
  self.skip_trivia()
  let is_pat : @core.Pat? = if self.peek_kind() == is_kw() {
    let _ = self.bump() // consume "is"
    Some(self.parse_pattern())
  } else {
    None
  }
  let then_body = self.parse_block()
  let else_body = self.parse_else_body()
  let span = self.span_from(start)
  match is_pat {
    Some(pat) => {
      let then_expr = module_to_match_body(then_body, span)
      let else_expr = module_to_match_body(else_body, span)
      @core.Expr::Match(
        scrutinee=cond,
        arms=[
          @core.MatchArm::{ pat, cond: None, expr: then_expr, span },
          @core.MatchArm::{
            pat: @core.Pat::Wildcard(span~),
            cond: None,
            expr: else_expr,
            span,
          },
        ],
        span~,
      )
    }
    None => @core.Expr::If(cond~, then_body~, else_body~, span~)
  }
}

///|
fn AstParser::parse_while_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(while_kw(), "while")
  let cond = self.parse_expr()
  let body = self.parse_block()
  let span = self.span_from(start)
  @core.Expr::While(cond~, body~, span~)
}

///|
/// Parse `for x in expr { body }` or `for i, x in expr { body }`
/// Returns Expr::ForIn AST node; desugaring happens in eval/codegen layers.
fn AstParser::parse_for_in_expr(
  self : AstParser,
) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(for_kw(), "for") // consume keyword "for"
  // `for await x in s` — `await` is a marker (not a keyword) distinguishing
  // async-stream iteration; it desugars to the same ForIn node. Skip it when a
  // binding name follows. `for await in s` (binding literally named "await") is
  // preserved because the token after `await` is then the `in` keyword.
  self.skip_trivia()
  let marker = self.peek()
  if marker.kind() == name() &&
    marker.text() == "await" &&
    self.peek_non_trivia_ahead(1) == name() {
    let _ = self.bump()
    self.skip_trivia()
  }
  // Parse first binding name
  let first_name = self.expect(name(), "binding name").text()
  self.skip_trivia()
  // Check for C-style for: `for i = init; cond; update { body }`
  if self.peek_kind() == eq() {
    return self.parse_for_c_style(start, first_name)
  }
  // Check for index,value form: `for i, x in ...`
  let (index_name, value_name) = if self.peek_kind() == comma() {
    let _ = self.bump() // consume comma
    self.skip_trivia()
    let second_name = self.expect(name(), "value binding name").text()
    (Some(first_name), second_name)
  } else {
    (None, first_name)
  }
  // Expect keyword "in"
  let _ = self.expect(in_kw(), "in")
  let iterable = self.parse_expr()
  let body = self.parse_block()
  let span = self.span_from(start)
  @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~)
}

///|
/// Parse C-style for loop: `for name = init; cond; name = update { body }`
/// Desugars to: `loop (name = init) { if !(cond) { break }; body_rewritten; continue(update) }`
/// where bare `continue` in body becomes `continue(update)`.
fn AstParser::parse_for_c_style(
  self : AstParser,
  start : Int,
  var_name : String,
) -> @core.Expr raise ParseError {
  // Consume `=`
  let _ = self.expect(eq(), "=")
  // Parse init expression
  let init_expr = self.parse_expr()
  // Consume `;`
  let _ = self.expect(semicolon(), ";")
  // Parse condition expression
  let cond_expr = self.parse_expr()
  // Consume `;`
  let _ = self.expect(semicolon(), ";")
  // Parse update: `name = expr`
  // For the update expression, we need to substitute var_name with the loop param.
  // We parse "name = expr" and extract the expression.
  let _update_name = self.expect(name(), "update variable").text()
  self.skip_trivia()
  let _ = self.expect(eq(), "=")
  let update_expr = self.parse_expr()
  // Parse body block
  let body = self.parse_block()
  let span = self.span_from(start)
  // Build: loop (var_name = init_expr) {
  //   if !(cond) { break }
  //   <body with continue rewritten to continue(update_expr)>
  //   continue(update_expr)
  // }
  let loop_param : @core.LoopParam = { name: var_name, init: init_expr, span }
  // Negate condition: if !(cond) { break }
  let break_check = @core.Stmt::Expr(
    expr=@core.Expr::If(
      cond=cond_expr,
      then_body={ stmts: [] },
      else_body={
        stmts: [
          @core.Stmt::Expr(expr=@core.Expr::Break(value=None, span~), span~),
        ],
      },
      span~,
    ),
    span~,
  )
  // Rewrite bare continue in body to continue(update_expr)
  let rewritten_stmts = rewrite_continue_for_loop(body.stmts, update_expr, span)
  // Build final loop body stmts
  let loop_stmts : Array[@core.Stmt] = [break_check]
  for stmt in rewritten_stmts {
    loop_stmts.push(stmt)
  }
  // Append continue(update_expr) at end
  loop_stmts.push(
    @core.Stmt::Expr(
      expr=@core.Expr::Continue(args=[update_expr], span~),
      span~,
    ),
  )
  @core.Expr::Loop(params=[loop_param], body={ stmts: loop_stmts }, span~)
}

///|
/// Rewrite bare `continue` to `continue(update_expr)` in stmts for for-C desugaring.
fn rewrite_continue_for_loop(
  stmts : Array[@core.Stmt],
  update_expr : @core.Expr,
  span : @core.Span,
) -> Array[@core.Stmt] {
  let out : Array[@core.Stmt] = []
  for stmt in stmts {
    out.push(rewrite_continue_for_loop_stmt(stmt, update_expr, span))
  }
  out
}

///|
fn rewrite_continue_for_loop_stmt(
  stmt : @core.Stmt,
  update_expr : @core.Expr,
  span : @core.Span,
) -> @core.Stmt {
  match stmt {
    @core.Stmt::Expr(expr~, span=stmt_span) =>
      @core.Stmt::Expr(
        expr=rewrite_continue_for_loop_expr(expr, update_expr, span),
        span=stmt_span,
      )
    @core.Stmt::Let(rec~, name~, expr~, span=stmt_span) =>
      @core.Stmt::Let(
        rec~,
        name~,
        expr=rewrite_continue_for_loop_expr(expr, update_expr, span),
        span=stmt_span,
      )
    @core.Stmt::LetMut(name~, expr~, span=stmt_span) =>
      @core.Stmt::LetMut(
        name~,
        expr=rewrite_continue_for_loop_expr(expr, update_expr, span),
        span=stmt_span,
      )
    @core.Stmt::Assign(name~, expr~, span=stmt_span) =>
      @core.Stmt::Assign(
        name~,
        expr=rewrite_continue_for_loop_expr(expr, update_expr, span),
        span=stmt_span,
      )
    _ => stmt
  }
}

///|
/// Rewrite bare `continue` to `continue(update_expr)` in expressions.
/// Stop at nested While/Loop/ForIn boundaries.
fn rewrite_continue_for_loop_expr(
  expr : @core.Expr,
  update_expr : @core.Expr,
  span : @core.Span,
) -> @core.Expr {
  match expr {
    @core.Expr::Continue(args~, span=cont_span) =>
      if args.is_empty() {
        @core.Expr::Continue(args=[update_expr], span=cont_span)
      } else {
        expr
      }
    @core.Expr::If(cond~, then_body~, else_body~, span=if_span) =>
      @core.Expr::If(
        cond~,
        then_body=rewrite_continue_for_loop_module(then_body, update_expr, span),
        else_body=rewrite_continue_for_loop_module(else_body, update_expr, span),
        span=if_span,
      )
    @core.Expr::Block(body~, span=blk_span) =>
      @core.Expr::Block(
        body=rewrite_continue_for_loop_module(body, update_expr, span),
        span=blk_span,
      )
    @core.Expr::Match(scrutinee~, arms~, span=m_span) => {
      let new_arms : Array[@core.MatchArm] = []
      for arm in arms {
        new_arms.push({
          ..arm,
          expr: rewrite_continue_for_loop_expr(arm.expr, update_expr, span),
        })
      }
      @core.Expr::Match(scrutinee~, arms=new_arms, span=m_span)
    }
    // Do NOT recurse into While/Loop/ForIn — their continue targets the inner loop
    @core.Expr::While(..) | @core.Expr::Loop(..) | @core.Expr::ForIn(..) => expr
    _ => expr
  }
}

///|
fn rewrite_continue_for_loop_module(
  mod_ : @core.Module,
  update_expr : @core.Expr,
  span : @core.Span,
) -> @core.Module {
  { stmts: rewrite_continue_for_loop(mod_.stmts, update_expr, span) }
}

///|
/// Check if current `name()` "loop" token starts a parameterized loop.
/// Looks ahead for: loop ( name = ...
fn AstParser::is_parameterized_loop(self : AstParser) -> Bool {
  // Current token is name() "loop"
  // Check: next non-trivia is (, then name(), then =
  self.peek_non_trivia_ahead(1) == lparen() &&
  self.peek_non_trivia_ahead(2) == name() &&
  self.peek_non_trivia_ahead(3) == eq()
}

///|
fn AstParser::parse_loop_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let loop_tok = self.expect(loop_kw(), "loop")
  self.skip_trivia()
  // Check if parameterized loop: loop (name = expr, ...) { body }
  if self.peek_kind() == lparen() {
    let _ = self.bump() // consume (
    let params : Array[@core.LoopParam] = []
    self.skip_trivia()
    if self.peek_kind() != rparen() {
      // Parse first param: name = expr
      let param_start = self.pos
      let param_name = self.expect(name(), "parameter name").text()
      let _ = self.expect(eq(), "=")
      let init = self.parse_expr()
      let param_span = self.span_from(param_start)
      params.push(@core.LoopParam::{ name: param_name, init, span: param_span })
      self.skip_trivia()
      while self.peek_kind() == comma() {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rparen() {
          break
        }
        let p_start = self.pos
        let p_name = self.expect(name(), "parameter name").text()
        let _ = self.expect(eq(), "=")
        let p_init = self.parse_expr()
        let p_span = self.span_from(p_start)
        params.push(@core.LoopParam::{
          name: p_name,
          init: p_init,
          span: p_span,
        })
        self.skip_trivia()
      }
    }
    let _ = self.expect(rparen(), ")")
    let body = self.parse_block()
    let span = self.span_from(start)
    @core.Expr::Loop(params~, body~, span~)
  } else {
    // Bare loop { body } → desugar to while(true) { body }
    let body = self.parse_block()
    let span = self.span_from(start)
    let cond_span = @core.Span::new(
      span.start,
      span.start + loop_tok.text().length(),
    )
    let cond = @core.Expr::Bool(value=true, span=cond_span)
    @core.Expr::While(cond~, body~, span~)
  }
}

///|
fn AstParser::parse_match_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(match_kw(), "match")
  let scrutinee = self.parse_expr()
  let _ = self.expect(lbrace(), "{")
  let arms : Array[@core.MatchArm] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    let first_pat = self.parse_pattern()
    self.skip_trivia()
    // Check for or-pattern: A | B | C => ...
    let pat = if self.peek_kind() == bit_or() {
      let pats : Array[@core.Pat] = [first_pat]
      while ({
              self.skip_trivia()
              self.peek_kind() == bit_or()
            }) {
        let _ = self.bump() // consume |
        pats.push(self.parse_pattern())
      }
      let span = @core.Span::merge(
        pats[0].span(),
        pats[pats.length() - 1].span(),
      )
      @core.Pat::Or(pats~, span~)
    } else {
      first_pat
    }
    self.skip_trivia()
    let mut cond : @core.Expr? = None
    if self.peek_kind() == if_kw() {
      let _ = self.bump()
      cond = Some(self.parse_expr())
    }
    let _ = self.expect(arrow(), "=>")
    let expr = self.parse_expr()
    let mut arm_span = @core.Span::merge(pat.span(), expr.span())
    match cond {
      Some(c) => arm_span = @core.Span::merge(arm_span, c.span())
      None => ()
    }
    arms.push(@core.MatchArm::{ pat, cond, expr, span: arm_span })
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())
  }
  let _ = self.expect(rbrace(), "}")
  let span = self.span_from(start)
  @core.Expr::Match(scrutinee~, arms~, span~)
}

///|
fn AstParser::parse_handle_expr(
  self : AstParser,
) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(handle_kw(), "handle")
  let body = self.parse_block()
  self.skip_trivia()
  let _ = self.expect(with_kw(), "`with`")
  self.skip_trivia()
  let effect_name = self.expect(name(), "effect name").text()
  self.skip_trivia()
  let _ = self.expect(lbrace(), "{")
  let arms : Array[@core.MatchArm] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    let first_pat = self.parse_pattern()
    self.skip_trivia()
    let pat = if self.peek_kind() == bit_or() {
      let pats : Array[@core.Pat] = [first_pat]
      while ({
              self.skip_trivia()
              self.peek_kind() == bit_or()
            }) {
        let _ = self.bump()
        pats.push(self.parse_pattern())
      }
      let span = @core.Span::merge(
        pats[0].span(),
        pats[pats.length() - 1].span(),
      )
      @core.Pat::Or(pats~, span~)
    } else {
      first_pat
    }
    let qualified_pat = qualify_handle_arm_pattern(effect_name, pat)
    self.skip_trivia()
    let mut cond : @core.Expr? = None
    if self.peek_kind() == if_kw() {
      let _ = self.bump()
      cond = Some(self.parse_expr())
    }
    let _ = self.expect(arrow(), "=>")
    let expr = self.parse_expr()
    let mut arm_span = @core.Span::merge(qualified_pat.span(), expr.span())
    match cond {
      Some(c) => arm_span = @core.Span::merge(arm_span, c.span())
      None => ()
    }
    arms.push(@core.MatchArm::{ pat: qualified_pat, cond, expr, span: arm_span })
    let _ = self.eat(semicolon())
  }
  let _ = self.expect(rbrace(), "}")
  let span = self.span_from(start)
  @core.Expr::Handle(body~, arms~, span~)
}

///|
fn qualify_handle_arm_pattern(
  effect_name : String,
  pat : @core.Pat,
) -> @core.Pat {
  match pat {
    @core.Pat::Ctor(name~, args~, span~) =>
      if name.contains("::") {
        pat
      } else {
        @core.Pat::Ctor(name=effect_name + "::" + name, args~, span~)
      }
    @core.Pat::Or(pats~, span~) =>
      @core.Pat::Or(
        pats=pats.map(fn(item) { qualify_handle_arm_pattern(effect_name, item) }),
        span~,
      )
    _ => pat
  }
}

///|
fn AstParser::parse_break_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(break_kw(), "break")
  self.skip_trivia()
  // Check if next token starts a value expression (not } or ; or EOF)
  let next = self.peek_kind()
  let value : @core.Expr? = if next == rbrace() ||
    next == semicolon() ||
    next == eof() {
    None
  } else {
    Some(self.parse_expr())
  }
  let span = self.span_from(start)
  @core.Expr::Break(value~, span~)
}

///|
fn AstParser::parse_return_expr(
  self : AstParser,
) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(return_kw(), "return")
  self.skip_trivia()
  let next = self.peek_kind()
  let value : @core.Expr? = if next == rbrace() ||
    next == semicolon() ||
    next == eof() {
    None
  } else {
    Some(self.parse_expr())
  }
  let span = self.span_from(start)
  @core.Expr::Return(value~, span~)
}

///|
fn AstParser::parse_continue_expr(
  self : AstParser,
) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(continue_kw(), "continue")
  self.skip_trivia()
  // Check if continue has arguments: continue(expr, expr, ...)
  let args : Array[@core.Expr] = if self.peek_kind() == lparen() {
    let _ = self.bump() // consume (
    let exprs : Array[@core.Expr] = []
    self.skip_trivia()
    if self.peek_kind() != rparen() {
      exprs.push(self.parse_expr())
      self.skip_trivia()
      while self.peek_kind() == comma() {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rparen() {
          break
        }
        exprs.push(self.parse_expr())
        self.skip_trivia()
      }
    }
    let _ = self.expect(rparen(), ")")
    exprs
  } else {
    []
  }
  let span = self.span_from(start)
  @core.Expr::Continue(args~, span~)
}

///|
fn AstParser::parse_removed_raise_expr(
  self : AstParser,
) -> @core.Expr raise ParseError {
  let start = self.pos
  let tok = self.peek()
  let _ = self.expect(raise_kw(), "raise")
  let span = self.span_from(start)
  raise ParseError::UnexpectedToken(
    expected="`raise` is not supported. Use `throw(expr)` instead.",
    got=tok.text(),
    span~,
  )
}

///|
fn AstParser::parse_yield_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(yield_kw(), "yield")
  let expr = self.parse_expr()
  let span = self.span_from(start)
  @core.Expr::Yield(expr~, span~)
}

///|
fn AstParser::parse_record_expr(
  self : AstParser,
) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(record_kw(), "record")
  let _ = self.expect(lbrace(), "{")
  let fields : Array[@core.RecordFieldExpr] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    let field_start = self.pos
    let name_tok = self.expect(name(), "field")
    self.skip_trivia()
    let expr = if self.peek_kind() == colon() {
      let _ = self.bump()
      self.parse_expr()
    } else {
      let ident_span = self.span_from(field_start)
      @core.Expr::Ident(name=name_tok.text(), span=ident_span)
    }
    let field_span = self.span_from(field_start)
    fields.push(@core.RecordFieldExpr::{
      name: name_tok.text(),
      expr,
      span: field_span,
    })
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())
  }
  let _ = self.expect(rbrace(), "}")
  let span = self.span_from(start)
  @core.Expr::Record(fields~, span~)
}

///|
/// Check if `{` starts a struct literal (name: value pattern) vs a block.
fn AstParser::looks_like_struct_lit_brace(self : AstParser) -> Bool {
  // Look ahead: { <name> : ... } means struct literal
  let saved = self.pos
  let mut ok = false
  if self.peek_kind() == lbrace() {
    self.pos += 1
    while is_trivia(self.peek_kind()) {
      self.pos += 1
    }
    if self.peek_kind() == name() {
      self.pos += 1
      while is_trivia(self.peek_kind()) {
        self.pos += 1
      }
      if self.peek_kind() == colon() {
        ok = true
      }
    }
    // Also match empty struct: Type { }
    if self.peek_kind() == rbrace() {
      ok = true
    }
  }
  self.pos = saved
  ok
}

///|
fn AstParser::parse_struct_lit_fields(
  self : AstParser,
) -> Array[@core.RecordFieldExpr] raise ParseError {
  let fields : Array[@core.RecordFieldExpr] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    let field_start = self.pos
    let name_tok = self.expect(name(), "field")
    self.skip_trivia()
    let expr = if self.peek_kind() == colon() {
      let _ = self.bump()
      self.parse_expr()
    } else {
      let ident_span = self.span_from(field_start)
      @core.Expr::Ident(name=name_tok.text(), span=ident_span)
    }
    let field_span = self.span_from(field_start)
    fields.push(@core.RecordFieldExpr::{
      name: name_tok.text(),
      expr,
      span: field_span,
    })
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())
  }
  fields
}

///|
fn AstParser::parse_map_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(map_kw(), "map")
  let _ = self.expect(lbrace(), "{")
  let fields : Array[@core.MapFieldExpr] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    let field_start = self.pos
    let key_tok = self.peek()
    if key_tok.kind() != name() && key_tok.kind() != string_lit() {
      raise ParseError::UnexpectedToken(
        expected="map key",
        got=key_tok.text(),
        span=self.token_span(),
      )
    }
    let _ = self.bump()
    let _ = self.expect(colon(), ":")
    let expr = self.parse_expr()
    let field_span = self.span_from(field_start)
    fields.push(@core.MapFieldExpr::{
      key: key_tok.text(),
      expr,
      span: field_span,
    })
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())
  }
  let _ = self.expect(rbrace(), "}")
  let span = self.span_from(start)
  @core.Expr::Map(fields~, span~)
}

///|
fn AstParser::parse_array_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(lbracket(), "[")
  let items : Array[@core.Expr] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != rbracket()
        }) {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    if self.peek_kind() == dotdotdot() || self.peek_kind() == dotdot() {
      let spread_start = self.pos
      let _ = self.bump() // consume .. or ...
      let expr = self.parse_expr()
      let spread_span = self.span_from(spread_start)
      items.push(@core.Expr::Spread(expr~, span=spread_span))
    } else {
      items.push(self.parse_expr())
    }
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())
  }
  let _ = self.expect(rbracket(), "]")
  let span = self.span_from(start)
  @core.Expr::Array(items~, span~)
}

///|
fn AstParser::parse_effect_list(
  self : AstParser,
) -> Array[@core.EffectAtom] raise ParseError {
  let effects : Array[@core.EffectAtom] = []
  self.skip_trivia()
  if self.peek_kind() == with_kw() {
    let _ = self.bump()
    self.skip_trivia()
    let _ = self.expect(lbrace(), "{")
    self.skip_trivia()
    if self.peek_kind() != rbrace() {
      let name_tok = self.expect(name(), "effect")
      effects.push(effect_atom_from_name(name_tok.text()))
      while ({
              self.skip_trivia()
              self.peek_kind() == comma()
            }) {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rbrace() {
          break
        }
        let tok = self.expect(name(), "effect")
        effects.push(effect_atom_from_name(tok.text()))
      }
      // Check for row variable: | e
      self.skip_trivia()
      if self.peek_kind() == bit_or() {
        let _ = self.bump()
        self.skip_trivia()
        let var_tok = self.expect(name(), "effect row variable")
        effects.push(@core.EffectAtom::Var(var_tok.text()))
      }
    }
    let _ = self.expect(rbrace(), "}")
  }
  effects
}

///|
fn AstParser::parse_param_list(
  self : AstParser,
  params : Map[String, Bool],
) -> Array[@core.FuncParam] raise ParseError {
  let _ = self.expect(lparen(), "(")
  let out : Array[@core.FuncParam] = []
  self.skip_trivia()
  if self.peek_kind() != rparen() {
    out.push(self.parse_param(params))
    while ({
            self.skip_trivia()
            self.peek_kind() == comma()
          }) {
      let _ = self.bump()
      self.skip_trivia()
      if self.peek_kind() == rparen() {
        break
      }
      out.push(self.parse_param(params))
    }
  }
  let _ = self.expect(rparen(), ")")
  validate_variadic_param_order(out, self.token_span())
  out
}

///|
/// Parse parameter list for function type signatures.
/// Supports both `(x: T)` and `(T)` syntax where uppercase names are treated as types.
fn AstParser::parse_fn_type_param_list(
  self : AstParser,
  params : Map[String, Bool],
) -> Array[@core.FuncParam] raise ParseError {
  let _ = self.expect(lparen(), "(")
  let out : Array[@core.FuncParam] = []
  let mut idx = 0
  self.skip_trivia()
  if self.peek_kind() != rparen() {
    out.push(self.parse_fn_type_param(params, idx))
    idx += 1
    while ({
            self.skip_trivia()
            self.peek_kind() == comma()
          }) {
      let _ = self.bump()
      self.skip_trivia()
      if self.peek_kind() == rparen() {
        break
      }
      out.push(self.parse_fn_type_param(params, idx))
      idx += 1
    }
  }
  let _ = self.expect(rparen(), ")")
  validate_variadic_param_order(out, self.token_span())
  out
}

///|
/// Parse a single parameter for function type signatures.
/// If the token is an uppercase name without `:`, treat it as a type-only parameter.
fn AstParser::parse_fn_type_param(
  self : AstParser,
  params : Map[String, Bool],
  idx : Int,
) -> @core.FuncParam raise ParseError {
  let saved = self.pos
  let tok = self.peek()
  if tok.kind() == name() {
    let text = tok.text()
    let chars : Array[Char] = []
    for c in text {
      chars.push(c)
    }
    if chars.length() > 0 {
      let first = chars[0]
      // Check if it's an uppercase name (type) without `:`
      if first >= 'A' && first <= 'Z' {
        // Look ahead for colon
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() != colon() {
          // This is a type-only parameter like `(Int)` or `(A)`
          self.pos = saved
          let ty = self.parse_type_with_params(params)
          let param_name = "_" + idx.to_string()
          return @core.FuncParam::{
            name: param_name,
            label: @core.ParamLabel::Positional,
            ty,
            bounds: [],
          }
        }
        // Has colon, restore and use normal parsing
        self.pos = saved
      }
    }
  }
  // Handle type-only parameters that start with `(` or `[`
  // e.g., `(Int) -> Int` or `[T](T) -> T`
  if self.peek_kind() == lparen() || self.peek_kind() == lbracket() {
    let ty = self.parse_type_with_params(params)
    let param_name = "_" + idx.to_string()
    return @core.FuncParam::{
      name: param_name,
      label: @core.ParamLabel::Positional,
      ty,
      bounds: [],
    }
  }
  // Fall back to normal param parsing
  self.parse_param(params)
}

///|
fn AstParser::parse_param(
  self : AstParser,
  params : Map[String, Bool],
) -> @core.FuncParam raise ParseError {
  let variadic = self.eat_variadic_prefix()
  let name_start = self.pos
  let name_tok = self.expect(name(), "param")
  let name_span = self.span_from(name_start)
  let (base, parsed_label) = split_param_label(name_tok.text(), name_span)
  let label = if variadic {
    if parsed_label != @core.ParamLabel::Positional {
      raise ParseError::UnexpectedToken(
        expected="variadic parameter label",
        got=name_tok.text(),
        span=name_span,
      )
    }
    @core.ParamLabel::Variadic
  } else {
    parsed_label
  }
  self.skip_trivia()
  // Type annotation is optional - use Unit as placeholder for inference
  let ty = if self.peek_kind() == colon() {
    let _ = self.bump()
    let parsed_ty = self.parse_type_with_params(params)
    if label == @core.ParamLabel::Variadic {
      match parsed_ty {
        @core.Type::Array(_) => parsed_ty
        _ =>
          raise ParseError::UnexpectedToken(
            expected="variadic param type `T[]`",
            got=name_tok.text(),
            span=name_span,
          )
      }
    } else {
      parsed_ty
    }
  } else {
    if label == @core.ParamLabel::Variadic {
      raise ParseError::UnexpectedToken(
        expected="variadic param type annotation",
        got=name_tok.text(),
        span=name_span,
      )
    }
    @core.Type::Infer // Placeholder for type inference
  }
  self.skip_trivia()
  let bounds : Array[String] = if self.peek_kind() == colon() {
    let _ = self.bump()
    self.skip_trivia()
    self.parse_trait_bounds()
  } else {
    []
  }
  @core.FuncParam::{ name: base, label, ty, bounds }
}

///|
fn AstParser::eat_variadic_prefix(self : AstParser) -> Bool {
  self.skip_trivia()
  if self.peek_kind() == dotdotdot() {
    let _ = self.bump()
    return true
  }
  let saved = self.pos
  if self.peek_kind() != dot() {
    return false
  }
  let _ = self.bump()
  if self.peek_kind() != dot() {
    self.pos = saved
    return false
  }
  let _ = self.bump()
  if self.peek_kind() != dot() {
    self.pos = saved
    return false
  }
  let _ = self.bump()
  true
}

///|
fn validate_variadic_param_order(
  params : Array[@core.FuncParam],
  span : @core.Span,
) -> Unit raise ParseError {
  let mut seen_variadic = false
  for param in params {
    match param.label {
      @core.ParamLabel::Variadic =>
        if seen_variadic {
          raise ParseError::UnexpectedToken(
            expected="single variadic parameter",
            got=param.name,
            span~,
          )
        } else {
          seen_variadic = true
        }
      _ =>
        if seen_variadic && @core.ParamLabel::is_positional(param.label) {
          raise ParseError::UnexpectedToken(
            expected="variadic parameter must be the last positional parameter",
            got=param.name,
            span~,
          )
        }
    }
  }
}

///|
fn split_param_label(
  name : String,
  span : @core.Span,
) -> (String, @core.ParamLabel) raise ParseError {
  let chars : Array[Char] = []
  for c in name {
    chars.push(c)
  }
  if chars.is_empty() {
    raise ParseError::UnexpectedToken(expected="param", got=name, span~)
  }
  let last = chars[chars.length() - 1]
  if last == '~' || last == '?' {
    if chars.length() == 1 {
      raise ParseError::UnexpectedToken(expected="param", got=name, span~)
    }
    let buf = StringBuilder::new()
    for i in 0..<(chars.length() - 1) {
      buf.write_char(chars[i])
    }
    let label = if last == '~' {
      @core.ParamLabel::Required
    } else {
      @core.ParamLabel::Optional
    }
    (buf.to_string(), label)
  } else {
    (name, @core.ParamLabel::Positional)
  }
}

///|
/// Parse type parameters for generic functions: [T, U]
/// Supports optional trait bounds: [T: Eq, U: Show]
priv struct ParsedTypeParams {
  names : Array[String]
  bounds : Map[String, Array[String]]
}

///|
fn AstParser::parse_trait_bounds(
  self : AstParser,
) -> Array[String] raise ParseError {
  let bounds : Array[String] = []
  let first = self.expect(name(), "trait")
  bounds.push(first.text())
  while ({
          self.skip_trivia()
          self.peek_kind() == plus()
        }) {
    let _ = self.bump()
    self.skip_trivia()
    let next = self.expect(name(), "trait")
    bounds.push(next.text())
  }
  bounds
}

///|
fn AstParser::parse_fn_type_params(
  self : AstParser,
) -> ParsedTypeParams raise ParseError {
  let type_params : Array[String] = []
  let type_bounds : Map[String, Array[String]] = {}
  self.skip_trivia()
  if self.peek_kind() == lbracket() {
    let _ = self.bump()
    self.skip_trivia()
    if self.peek_kind() != rbracket() {
      let name_tok = self.expect(name(), "type parameter name")
      type_params.push(name_tok.text())
      self.skip_trivia()
      if self.peek_kind() == colon() {
        let _ = self.bump()
        self.skip_trivia()
        type_bounds[name_tok.text()] = self.parse_trait_bounds()
      }
      while ({
              self.skip_trivia()
              self.peek_kind() == comma()
            }) {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rbracket() {
          break
        }
        let name_tok = self.expect(name(), "type parameter name")
        type_params.push(name_tok.text())
        self.skip_trivia()
        if self.peek_kind() == colon() {
          let _ = self.bump()
          self.skip_trivia()
          type_bounds[name_tok.text()] = self.parse_trait_bounds()
        }
      }
    }
    let _ = self.expect(rbracket(), "]")
  }
  ParsedTypeParams::{ names: type_params, bounds: type_bounds }
}

///|
/// Parse type arguments for function calls: [Int, String]
/// Returns array of types
fn AstParser::parse_call_type_args(
  self : AstParser,
) -> Array[@core.Type] raise ParseError {
  let type_args : Array[@core.Type] = []
  self.skip_trivia()
  if self.peek_kind() == lbracket() {
    let _ = self.bump()
    self.skip_trivia()
    if self.peek_kind() != rbracket() {
      type_args.push(self.parse_type())
      while ({
              self.skip_trivia()
              self.peek_kind() == comma()
            }) {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rbracket() {
          break
        }
        type_args.push(self.parse_type())
      }
    }
    let _ = self.expect(rbracket(), "]")
  }
  type_args
}

///|
/// Check if the next tokens after [ look like type arguments (e.g., [Int])
/// rather than an index expression (e.g., [0] or ["hello"])
/// Type arguments start with uppercase letter (Int, String, etc.)
fn AstParser::is_type_arg_context(self : AstParser) -> Bool {
  let saved = self.pos
  let _ = self.bump() // consume [
  self.skip_trivia()
  let result = if self.peek_kind() == name() {
    let text = self.peek().text()
    if text.length() > 0 {
      let first = text.to_array()[0]
      first >= 'A' && first <= 'Z'
    } else {
      false
    }
  } else {
    false
  }
  self.pos = saved
  result
}

///|
fn AstParser::try_parse_arrow_fn(
  self : AstParser,
) -> @core.Expr? raise ParseError {
  let saved = self.pos
  // confirmed_arrow is set only when -> is found (not just {)
  // because (a, b) { ... } is ambiguous (could be tuple + block in match contexts)
  let mut confirmed_arrow = false
  let mut deferred_error : ParseError? = None
  let result : @core.Expr? = try {
    // Try to parse type parameters: [T, U] / [T: Trait]
    let parsed = self.parse_fn_type_params()
    let type_params = parsed.names
    let type_bounds = parsed.bounds
    let params = self.parse_param_list(param_set_from_params(type_params))
    self.skip_trivia()
    if self.peek_kind() != thin_arrow() && self.peek_kind() != lbrace() {
      raise ParseError::UnexpectedToken(
        expected="-> or {",
        got=self.peek().text(),
        span=self.span_from(saved),
      )
    }
    let mut ret : @core.Type? = None
    let mut effects : Array[@core.EffectAtom] = []
    if self.peek_kind() == thin_arrow() {
      // -> found: this is definitively an arrow function
      confirmed_arrow = true
      let _ = self.bump()
      self.skip_trivia()
      // Check if this is expression body: (x) -> expr (no block)
      // or type annotation: (x) -> Int { ... }
      if self.peek_kind() != lbrace() {
        // Could be expression body OR type annotation
        // Try to determine: if next token is a type keyword or name followed by {, it's a type
        let is_expr_body = self.is_arrow_expr_body()
        if is_expr_body {
          // Expression body: (x) -> x + 1
          let expr = self.parse_expr()
          let span = self.span_from(saved)
          let body = @core.Module::{
            stmts: [@core.Stmt::Expr(expr~, span=expr.span())],
          }
          return Some(
            @core.Expr::Fn(
              type_params~,
              type_bounds~,
              params~,
              ret~,
              effects~,
              body~,
              span~,
            ),
          )
        }
      }
      // Type annotation followed by block: (x) -> Int { ... }
      if self.peek_kind() != lbrace() {
        ret = Some(
          self.parse_type_with_params(param_set_from_params(type_params)),
        )
        effects = self.parse_effect_list()
      }
    }
    let body = self.parse_block()
    let span = self.span_from(saved)
    Some(
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects~,
        body~,
        span~,
      ),
    )
  } catch {
    e => {
      if confirmed_arrow {
        deferred_error = Some(e)
      }
      None
    }
  }
  match deferred_error {
    Some(e) => raise e
    None => ()
  }
  match result {
    Some(_) => result
    None => {
      self.pos = saved
      None
    }
  }
}

///|
/// Determine if after -> we have expression body or type annotation
/// Expression body: any expression that doesn't start with a type-like token followed by {
fn AstParser::is_arrow_expr_body(self : AstParser) -> Bool {
  // Look at current token
  let tok = self.peek()
  let saved = self.pos

  // If it starts with (, could be tuple type or expression
  // Check if after matching ) there's "with" or "{" for type annotation
  if tok.kind() == lparen() {
    // Skip the entire parenthesized part
    let _ = self.bump() // consume (
    let mut depth = 1
    while depth > 0 && self.peek_kind() != eof() {
      let k = self.peek_kind()
      if k == lparen() {
        depth = depth + 1
      } else if k == rparen() {
        depth = depth - 1
      }
      let _ = self.bump()
    }
    self.skip_trivia()
    let after_kind = self.peek_kind()
    self.pos = saved // restore position
    // If after () there's "with", "{", or "->", it's a type annotation
    if after_kind == lbrace() {
      return false // type annotation: (Int, String) { ... }
    } else if after_kind == with_kw() {
      return false // type annotation: (Int, String) with {Error} { ... }
    } else if after_kind == thin_arrow() {
      return false // function type: (A) -> C { ... }
    } else {
      return true // expression: (a, b).foo() or (x + 1)
    }
  }

  // If it's not a name, it's definitely an expression
  if tok.kind() != name() {
    return true
  }
  // Check if this looks like a type annotation (name followed by { or [ for generic or "with")
  // Save position to peek ahead
  let _ = self.bump() // consume the name
  self.skip_trivia()
  let next_kind = self.peek_kind()
  self.pos = saved // restore position
  // If name is followed by { or [ (for generic type), it's likely a type annotation
  // If name is followed by "with" (for effects), it's also a type annotation
  // Otherwise it's an expression
  if next_kind == lbrace() || next_kind == lbracket() {
    false // type annotation: Int { ... } or Array[Int] { ... }
  } else if next_kind == with_kw() {
    false // type annotation with effects: Int with {Error} { ... }
  } else {
    true // expression: x + 1, foo(bar), etc.
  }
}

///|
fn AstParser::parse_paren_expr(self : AstParser) -> @core.Expr raise ParseError {
  match self.try_parse_arrow_fn() {
    Some(expr) => expr
    None => {
      let start = self.pos
      let _ = self.expect(lparen(), "(")
      self.skip_trivia()
      // () → unit (empty tuple)
      if self.peek_kind() == rparen() {
        let _ = self.bump()
        let span = self.span_from(start)
        return @core.Expr::Tuple(items=[], span~)
      }
      let first = self.parse_expr()
      self.skip_trivia()
      if self.peek_kind() == comma() {
        let items : Array[@core.Expr] = []
        items.push(first)
        while ({
                self.skip_trivia()
                self.peek_kind() == comma()
              }) {
          let _ = self.bump()
          self.skip_trivia()
          if self.peek_kind() == rparen() {
            break
          }
          items.push(self.parse_expr())
        }
        let _ = self.expect(rparen(), ")")
        let span = self.span_from(start)
        @core.Expr::Tuple(items~, span~)
      } else {
        let _ = self.expect(rparen(), ")")
        first
      }
    }
  }
}

///|
fn hex_char_value(c : Char) -> Int {
  if c >= '0' && c <= '9' {
    c.to_int() - '0'.to_int()
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 'a'.to_int() + 10
  } else {
    c.to_int() - 'A'.to_int() + 10
  }
}

///|
fn parse_hex_int64(text : String, span : @core.Span) -> Int64 raise ParseError {
  // Skip "0x" prefix
  let mut i = 2
  // Skip leading zeros
  while i < text.length() {
    let c = text[i].to_int().unsafe_to_char()
    if c != '0' {
      break
    }
    i += 1
  }
  let sig_len = text.length() - i
  // Overflow guard: >16 significant hex digits always overflow Int64
  if sig_len > 16 {
    raise ParseError::IntLiteralOverflow(literal=text, span~)
  }
  // 16 significant digits with first digit >= 2 overflows tagged range
  // (0x2000000000000000 = 2^61 > tagged max) and could overflow Int64
  // for first digit >= 8
  if sig_len == 16 {
    let first = text[i].to_int().unsafe_to_char()
    if !(first == '0' || first == '1') {
      raise ParseError::IntLiteralOverflow(literal=text, span~)
    }
  }
  // Safe to accumulate without Int64 overflow
  let mut v : Int64 = 0L
  let mut j = 2
  while j < text.length() {
    let c = text[j].to_int().unsafe_to_char()
    v = v * 16L + hex_char_value(c).to_int64()
    j += 1
  }
  v
}

///|
fn parse_decimal_int64(
  text : String,
  span : @core.Span,
) -> Int64 raise ParseError {
  @string.parse_int64(text) catch {
    _ => raise ParseError::IntLiteralOverflow(literal=text, span~)
  }
}

///|
fn is_hex_prefix(text : String) -> Bool {
  if text.length() <= 2 {
    return false
  }
  let c0 = text[0].to_int().unsafe_to_char()
  let c1 = text[1].to_int().unsafe_to_char()
  c0 == '0' && (c1 == 'x' || c1 == 'X')
}

///|
fn parse_int_literal_token(
  tok : Token,
  span : @core.Span,
) -> Int64 raise ParseError {
  let text = tok.text()
  let v : Int64 = if is_hex_prefix(text) {
    parse_hex_int64(text, span)
  } else {
    parse_decimal_int64(text, span)
  }
  // Tagged range check: max 2^61 - 1
  if v > 2305843009213693951L {
    raise ParseError::IntLiteralOverflow(literal=text, span~)
  }
  v
}

///|
fn AstParser::parse_call_or_primary(
  self : AstParser,
) -> @core.Expr raise ParseError {
  self.skip_trivia()
  let start = self.pos
  let tok = self.peek()
  let mut expr : @core.Expr = if tok.kind() == name() {
    let name_tok = self.bump()
    let base_name = name_tok.text()
    let mut qualified_name = base_name
    // Track whether trivia between the bare `name` and the next non-trivia
    // token contains a newline. We need this for the bare-name `name(args)`
    // call at the bottom of this branch — without it `else exp\n(s, 1)` was
    // mis-parsed as `exp(s, 1)` (#325 follow-up json.vibe regression).
    let pre_skip_pos = self.pos
    self.skip_trivia()
    let mut name_followed_by_newline = false
    let mut probe = pre_skip_pos
    while probe < self.pos {
      if self.tokens[probe].kind() == newline() {
        name_followed_by_newline = true
        break
      }
      probe += 1
    }
    if self.can_parse_slash_qualified_name() {
      while true {
        self.skip_trivia()
        if self.peek_kind() != slash() {
          break
        }
        let _ = self.bump()
        self.skip_trivia()
        let seg = self.expect(name(), "namespace segment")
        qualified_name = qualified_name + "/" + seg.text()
      }
      self.skip_trivia()
    }
    // Check for single-parameter lambda: x -> expr
    if self.peek_kind() == thin_arrow() {
      let _ = self.bump() // consume ->
      self.skip_trivia()
      let param = @core.FuncParam::{
        name: base_name,
        label: @core.ParamLabel::Positional,
        ty: @core.Type::Infer, // Placeholder for inference
        bounds: [],
      }
      // Check if block body or expression body
      if self.peek_kind() == lbrace() {
        // Block body: x -> { ... }
        let body = self.parse_block()
        let span = self.span_from(start)
        @core.Expr::Fn(
          type_params=[],
          type_bounds={},
          params=[param],
          ret=None,
          effects=[],
          body~,
          span~,
        )
      } else {
        // Expression body: x -> x + 1
        let body_expr = self.parse_expr()
        let span = self.span_from(start)
        let body = @core.Module::{
          stmts: [@core.Stmt::Expr(expr=body_expr, span=body_expr.span())],
        }
        @core.Expr::Fn(
          type_params=[],
          type_bounds={},
          params=[param],
          ret=None,
          effects=[],
          body~,
          span~,
        )
      }
    } else if self.peek_kind() == lbracket() && self.is_type_arg_context() {
      // name[Type, ...] - explicit type arguments (only if next token looks like a type)
      let type_args = self.parse_call_type_args()
      self.skip_trivia()
      if self.peek_kind() == double_colon() && @core.is_ctor_name(base_name) {
        // StructName[T]::{ field: value }
        let _ = self.bump() // consume ::
        self.skip_trivia()
        let _ = self.expect(lbrace(), "{")
        let fields = self.parse_struct_lit_fields()
        let _ = self.expect(rbrace(), "}")
        let span = self.span_from(start)
        @core.Expr::StructLit(name=base_name, type_args~, fields~, span~)
      } else if self.peek_kind() == lparen() {
        // name[Type](args) - generic function call
        let _ = self.bump()
        let args = self.parse_args()
        let _ = self.expect(rparen(), ")")
        let span = self.span_from(start)
        call_or_throw_expr(qualified_name, type_args, args, span)
      } else {
        // name[Type] without parens - might be generic function reference
        let span = self.span_from(start)
        call_or_throw_expr(qualified_name, type_args, [], span)
      }
    } else if self.peek_kind() == lbrace() &&
      @core.is_ctor_name(base_name) &&
      self.looks_like_struct_lit_brace() {
      // Sugar: Type { field: value } → Type::{ field: value }
      let type_args : Array[@core.Type] = []
      let _ = self.bump() // consume {
      let fields = self.parse_struct_lit_fields()
      let _ = self.expect(rbrace(), "}")
      let span = self.span_from(start)
      @core.Expr::StructLit(name=base_name, type_args~, fields~, span~)
    } else if self.peek_kind() == double_colon() &&
      @core.is_ctor_name(base_name) &&
      self.peek_non_trivia_kind(self.pos + 1) == lbrace() {
      // StructName::{ field: value } (explicit syntax)
      let type_args : Array[@core.Type] = []
      let _ = self.bump() // consume ::
      self.skip_trivia()
      let _ = self.expect(lbrace(), "{")
      let fields = self.parse_struct_lit_fields()
      let _ = self.expect(rbrace(), "}")
      let span = self.span_from(start)
      @core.Expr::StructLit(name=base_name, type_args~, fields~, span~)
    } else if self.peek_kind() == double_colon() &&
      is_name_like(self.peek_non_trivia_kind(self.pos + 1)) {
      // Type-qualified symbol: Type::member
      let _ = self.bump()
      self.skip_trivia()
      let member_tok = self.expect_name_like("member name")
      qualified_name = qualified_name + "::" + member_tok.text()
      self.skip_trivia()
      if self.peek_kind() == lparen() {
        let _ = self.bump()
        let args = self.parse_args()
        let _ = self.expect(rparen(), ")")
        let span = self.span_from(start)
        @core.Expr::Call(name=qualified_name, type_args=[], args~, span~)
      } else {
        let span = self.span_from(start)
        @core.Expr::Ident(name=qualified_name, span~)
      }
    } else if self.peek_kind() == lparen() && !name_followed_by_newline {
      let _ = self.bump()
      let args = self.parse_args()
      let _ = self.expect(rparen(), ")")
      let span = self.span_from(start)
      call_or_throw_expr(qualified_name, [], args, span)
    } else if self.peek_kind() == lparen() && name_followed_by_newline {
      // Bare name followed by newline + `(...)`: treat as a standalone
      // identifier and let the surrounding statement boundary detection
      // (or the postfix loop, which respects newlines) handle the next
      // expression. Rewind the trivia consumption so the postfix loop sees
      // the newline.
      self.pos = pre_skip_pos
      let span = self.span_from(start)
      @core.Expr::Ident(name=qualified_name, span~)
    } else if base_name == "_" {
      // Placeholder for lambda shorthand: _ * 2 → x -> x * 2
      let span = self.span_from(start)
      @core.Expr::Placeholder(index=0, span~)
    } else if qualified_name == "perform" {
      // perform Effect::Op or perform Effect::Op(args)
      self.skip_trivia()
      let effect_tok = self.expect(name(), "effect name")
      let effect_name = effect_tok.text()
      let _ = self.expect(double_colon(), "::")
      let op_tok = self.expect(name(), "operation name")
      let op_name = op_tok.text()
      self.skip_trivia()
      let args : Array[@core.CallArg] = if self.peek_kind() == lparen() {
        let _ = self.bump()
        let parsed = self.parse_args()
        let _ = self.expect(rparen(), ")")
        parsed
      } else {
        []
      }
      let span = self.span_from(start)
      @core.Expr::Perform(effect_name~, op_name~, args~, span~)
    } else if qualified_name == "throw" {
      let span = self.span_from(start)
      raise ParseError::UnexpectedToken(
        expected="`throw` must be called as a function. Use `throw(expr)` instead.",
        got=qualified_name,
        span~,
      )
    } else {
      let span = self.span_from(start)
      @core.Expr::Ident(name=qualified_name, span~)
    }
  } else if tok.kind() == lparen() {
    // Parenthesized expression or tuple
    self.parse_paren_expr()
  } else {
    self.parse_primary()
  }
  // Postfix chain: .method(args), .prop, [index], (chained call)
  while true {
    // Track whether trivia before next token contains a newline.
    // Chained call f(a)(b) is only valid on the same line to avoid
    // ambiguity with tuple/parenthesized expressions on the next line.
    //
    // We save `pos` before consuming trivia so that we can rewind if no
    // postfix operator applies. Otherwise an inner postfix loop (e.g. on
    // the bare `exp` returned from `else exp`) would eat the newline before
    // the next `(...)`, leaving the *outer* caller's postfix loop blind to
    // the line break and (incorrectly) treating the following parenthesised
    // expression as a chained call (#325 follow-up).
    let pre_trivia_pos = self.pos
    let mut saw_newline = false
    while is_trivia(self.peek_kind()) {
      if self.peek_kind() == newline() {
        saw_newline = true
      }
      self.pos += 1
    }
    if self.peek_kind() == dot() {
      let _ = self.bump()
      self.skip_trivia()
      // Check for tuple index access: expr.0, expr.1, etc.
      if self.peek_kind() == int_lit() {
        let index_tok = self.bump()
        let index = @string.parse_int(index_tok.text()) catch {
          // This shouldn't happen for valid int literals
          _ => 0
        }
        let span = self.span_from(start)
        expr = @core.Expr::TupleIndex(expr~, index~, span~)
        continue
      }
      let method_tok = self.expect_name_like("method name")
      self.skip_trivia()
      if self.peek_kind() == lparen() {
        // UFCS: expr.method(args) → method(expr, args)
        let _ = self.bump() // consume (
        self.skip_trivia()
        let call_args : Array[@core.CallArg] = []
        let expr_span = expr.span()
        call_args.push(@core.CallArg::{ label: None, expr, span: expr_span })
        if self.peek_kind() != rparen() {
          let args = self.parse_args()
          for arg in args {
            call_args.push(arg)
          }
        }
        let _ = self.expect(rparen(), ")")
        let span = self.span_from(start)
        expr = @core.Expr::Call(
          name=method_tok.text(),
          type_args=[],
          args=call_args,
          span~,
        )
        continue
      } else {
        // expr.prop → __index(expr, "prop") — member access only
        let span = self.span_from(start)
        let expr_span = expr.span()
        expr = @core.Expr::Call(
          name="__index",
          type_args=[],
          args=[
            @core.CallArg::{ label: None, expr, span: expr_span },
            @core.CallArg::{
              label: None,
              expr: @core.Expr::String(value=method_tok.text(), span~),
              span,
            },
          ],
          span~,
        )
      }
    } else if self.peek_kind() == question() && !saw_newline {
      // Error propagation: expr? → handle { expr } with Error { Throw(e) => throw(e) }
      let _ = self.bump()
      let span = self.span_from(start)
      let err_name = "__err$" + span.start.to_string()
      expr = @core.Expr::Handle(
        body=@core.Module::{ stmts: [@core.Stmt::Expr(expr~, span~)] },
        arms=[
          {
            pat: @core.Pat::Ctor(
              name="Error::Throw",
              args=[@core.Pat::Bind(name=err_name, span~)],
              span~,
            ),
            cond: None,
            expr: @core.Expr::Perform(
              effect_name="Error",
              op_name="Throw",
              args=[
                @core.CallArg::{
                  label: None,
                  expr: @core.Expr::Ident(name=err_name, span~),
                  span,
                },
              ],
              span~,
            ),
            span,
          },
        ],
        span~,
      )
    } else if self.peek_kind() == lbracket() && !saw_newline {
      // Index/slice access: expr[index] or expr[i:j] — only on the same line.
      // A newline before [ starts a new array literal expression.
      let _ = self.bump()
      if self.peek_kind() == colon() {
        // expr[:j] — slice from 0 to j, or expr[:] — full copy
        let _ = self.bump() // consume :
        if self.peek_kind() == rbracket() {
          // expr[:] — slice from 0 to length
          let _ = self.bump() // consume ]
          let slice_pos = self.pos
          let temp_name = "__slice$" + slice_pos.to_string()
          let span = expr.span()
          let temp_ref = @core.Expr::Ident(name=temp_name, span~)
          let zero = @core.Expr::Int(value=0L, span~)
          let len_call = @core.Expr::Call(
            name="__len",
            type_args=[],
            args=[
              @core.CallArg::{
                label: None,
                expr: temp_ref,
                span: temp_ref.span(),
              },
            ],
            span~,
          )
          expr = @core.Expr::Block(
            body=@core.Module::{
              stmts: [
                @core.Stmt::Let(rec=false, name=temp_name, expr~, span~),
                @core.Stmt::Expr(
                  expr=call3("__slice", temp_ref, zero, len_call),
                  span~,
                ),
              ],
            },
            span~,
          )
        } else {
          let end_expr = self.parse_expr()
          let _ = self.expect(rbracket(), "]")
          let zero = @core.Expr::Int(value=0L, span=end_expr.span())
          expr = call3("__slice", expr, zero, end_expr)
        }
      } else {
        let index = self.parse_expr()
        if self.peek_kind() == colon() {
          // expr[i:j] or expr[i:]
          let _ = self.bump() // consume :
          if self.peek_kind() == rbracket() {
            // expr[i:] — slice from i to length
            let _ = self.bump() // consume ]
            let slice_pos = self.pos
            let temp_name = "__slice$" + slice_pos.to_string()
            let span = @core.Span::merge(expr.span(), index.span())
            let temp_ref = @core.Expr::Ident(name=temp_name, span~)
            let len_call = @core.Expr::Call(
              name="__len",
              type_args=[],
              args=[
                @core.CallArg::{
                  label: None,
                  expr: temp_ref,
                  span: temp_ref.span(),
                },
              ],
              span~,
            )
            expr = @core.Expr::Block(
              body=@core.Module::{
                stmts: [
                  @core.Stmt::Let(rec=false, name=temp_name, expr~, span~),
                  @core.Stmt::Expr(
                    expr=call3("__slice", temp_ref, index, len_call),
                    span~,
                  ),
                ],
              },
              span~,
            )
          } else {
            // expr[i:j]
            let end_expr = self.parse_expr()
            let _ = self.expect(rbracket(), "]")
            expr = call3("__slice", expr, index, end_expr)
          }
        } else {
          // expr[index] — regular index access
          let _ = self.expect(rbracket(), "]")
          expr = call2("__index", expr, index)
        }
      }
    } else if self.peek_kind() == lparen() && !saw_newline {
      // Chained call: expr(args) where expr is not a simple name.
      // Only on the same line — a newline before ( starts a new statement.
      // Desugar f(a)(b) into { let __chain$N = f(a); __chain$N(b) }
      let chain_pos = self.pos
      let _ = self.bump() // consume (
      let args = self.parse_args()
      let _ = self.expect(rparen(), ")")
      let span = self.span_from(start)
      let chain_name = "__chain$" + chain_pos.to_string()
      expr = @core.Expr::Block(
        body=@core.Module::{
          stmts: [
            @core.Stmt::Let(rec=false, name=chain_name, expr~, span~),
            @core.Stmt::Expr(
              expr=@core.Expr::Call(name=chain_name, type_args=[], args~, span~),
              span~,
            ),
          ],
        },
        span~,
      )
    } else {
      // No postfix applied — rewind the trivia consumption so an outer
      // postfix loop (or statement boundary detection in the caller) can
      // see the original trivia, including newlines.
      self.pos = pre_trivia_pos
      break
    }
  }
  expr
}

///|
fn AstParser::can_parse_slash_qualified_name(self : AstParser) -> Bool {
  let mut i = self.pos
  let mut saw_segment = false
  while true {
    while i < self.tokens.length() && is_trivia(self.tokens[i].kind()) {
      i += 1
    }
    if i >= self.tokens.length() || self.tokens[i].kind() != slash() {
      break
    }
    saw_segment = true
    i += 1
    while i < self.tokens.length() && is_trivia(self.tokens[i].kind()) {
      i += 1
    }
    if i >= self.tokens.length() || self.tokens[i].kind() != name() {
      return false
    }
    i += 1
  }
  if !saw_segment {
    return false
  }
  while i < self.tokens.length() && is_trivia(self.tokens[i].kind()) {
    i += 1
  }
  if i >= self.tokens.length() || self.tokens[i].kind() != double_colon() {
    return false
  }
  i += 1
  while i < self.tokens.length() && is_trivia(self.tokens[i].kind()) {
    i += 1
  }
  i < self.tokens.length() && self.tokens[i].kind() == name()
}

///|
fn AstParser::parse_args(
  self : AstParser,
) -> Array[@core.CallArg] raise ParseError {
  let args : Array[@core.CallArg] = []
  self.skip_trivia()
  if self.peek_kind() != rparen() {
    args.push(self.parse_arg())
    while ({
            self.skip_trivia()
            self.peek_kind() == comma()
          }) {
      let _ = self.bump()
      args.push(self.parse_arg())
    }
  }
  args
}

///|
fn AstParser::parse_arg(self : AstParser) -> @core.CallArg raise ParseError {
  self.skip_trivia()
  let start = self.pos
  if self.peek_kind() == name() &&
    self.peek_non_trivia_kind(self.pos + 1) == eq() {
    let label_tok = self.expect(name(), "label")
    if label_tok.text().has_suffix("?") || label_tok.text().has_suffix("~") {
      raise ParseError::UnexpectedToken(
        expected="label",
        got=label_tok.text(),
        span=self.token_span(),
      )
    }
    let _ = self.expect(eq(), "=")
    let expr = self.parse_expr()
    let span = self.span_from(start)
    @core.CallArg::{ label: Some(label_tok.text()), expr, span }
  } else {
    let expr = self.parse_expr()
    let span = self.span_from(start)
    @core.CallArg::{ label: None, expr, span }
  }
}

///|
fn AstParser::parse_primary(self : AstParser) -> @core.Expr raise ParseError {
  self.skip_trivia()
  let start = self.pos
  let tok = self.peek()
  match tok.kind() {
    k if k == int_lit() => {
      let _ = self.bump()
      let span = self.span_from(start)
      let value = parse_int_literal_token(tok, span)
      @core.Expr::Int(value~, span~)
    }
    k if k == float_lit() => {
      let _ = self.bump()
      let text = tok.text()
      let len = text.length()
      let mut is_float = false
      let mut raw = text
      if len > 0 {
        let last = text[len - 1]
        if last == 'f' || last == 'F' {
          is_float = true
          raw = text[0:len - 1].to_owned()
        }
      }
      let v = @string.parse_double(raw) catch {
        _ =>
          raise ParseError::UnexpectedToken(
            expected="valid numeric literal",
            got=tok.text(),
            span=self.token_span(),
          )
      }
      let span = self.span_from(start)
      if is_float {
        @core.Expr::Float(value=Float::from_double(v), span~)
      } else {
        @core.Expr::Double(value=v, span~)
      }
    }
    k if k == bool_lit() => {
      let _ = self.bump()
      if tok.text() == "true" {
        let span = self.span_from(start)
        @core.Expr::Bool(value=true, span~)
      } else if tok.text() == "false" {
        let span = self.span_from(start)
        @core.Expr::Bool(value=false, span~)
      } else {
        raise ParseError::UnexpectedToken(
          expected="bool",
          got=tok.text(),
          span=self.token_span(),
        )
      }
    }
    k if k == string_lit() => {
      let _ = self.bump()
      let span = self.span_from(start)
      @core.Expr::String(value=tok.text(), span~)
    }
    k if k == string_interp_lit() => {
      let _ = self.bump()
      let span = self.span_from(start)
      desugar_string_interp(tok.text(), span)
    }
    k if k == char_lit() => {
      let _ = self.bump()
      let chars = tok.text().to_array()
      if chars.length() == 1 {
        let span = self.span_from(start)
        @core.Expr::Char(value=chars[0], span~)
      } else {
        raise ParseError::UnexpectedToken(
          expected="char",
          got=tok.text(),
          span=self.token_span(),
        )
      }
    }
    k if k == name() => {
      let _ = self.bump()
      let span = self.span_from(start)
      @core.Expr::Ident(name=tok.text(), span~)
    }
    _ =>
      raise ParseError::UnexpectedToken(
        expected="expr",
        got=tok.text(),
        span=self.token_span(),
      )
  }
}

///|
fn desugar_string_interp(
  raw : String,
  span : @core.Span,
) -> @core.Expr raise ParseError {
  let parts : Array[@core.StringInterpPart] = []
  let chars = raw.to_array()
  let len = chars.length()
  let mut i = 0
  let buf = StringBuilder::new()
  while i < len {
    if i + 1 < len &&
      chars[i] == '\\' &&
      (chars[i + 1] == '{' || chars[i + 1] == '(') {
      if buf.to_string().length() > 0 {
        parts.push(@core.StringInterpPart::Lit(buf.to_string()))
        buf.reset()
      }
      let open_char = chars[i + 1]
      let close_char = if open_char == '(' { ')' } else { '}' }
      i += 2
      let expr_buf = StringBuilder::new()
      let mut depth = 1
      while i < len && depth > 0 {
        if chars[i] == open_char {
          depth += 1
          expr_buf.write_char(chars[i])
        } else if chars[i] == close_char {
          depth -= 1
          if depth > 0 {
            expr_buf.write_char(chars[i])
          }
        } else {
          expr_buf.write_char(chars[i])
        }
        i += 1
      }
      let expr_text = expr_buf.to_string()
      let expr_ast = parse_ast(expr_text) catch { e => raise e }
      let inner = if expr_ast.stmts.length() == 1 {
        match expr_ast.stmts[0] {
          @core.Stmt::Expr(expr~, span~) => {
            let _ = span
            expr
          }
          _ =>
            raise ParseError::UnexpectedToken(
              expected="expr in interpolation",
              got=expr_text,
              span~,
            )
        }
      } else {
        raise ParseError::UnexpectedToken(
          expected="single expr in interpolation",
          got=expr_text,
          span~,
        )
      }
      parts.push(@core.StringInterpPart::Expr(inner))
    } else if chars[i] == '\\' && i + 1 < len {
      match chars[i + 1] {
        'n' => buf.write_char('\n')
        't' => buf.write_char('\t')
        'r' => buf.write_char('\r')
        '"' => buf.write_char('"')
        '\\' => buf.write_char('\\')
        c => buf.write_char(c)
      }
      i += 2
    } else {
      buf.write_char(chars[i])
      i += 1
    }
  }
  if buf.to_string().length() > 0 {
    parts.push(@core.StringInterpPart::Lit(buf.to_string()))
  }
  if parts.length() == 0 {
    @core.Expr::String(value="", span~)
  } else if parts.length() == 1 {
    match parts[0] {
      @core.StringInterpPart::Lit(s) => @core.Expr::String(value=s, span~)
      @core.StringInterpPart::Expr(e) =>
        @core.Expr::Call(
          name="__to_string",
          type_args=[],
          args=[@core.CallArg::{ label: None, expr: e, span }],
          span~,
        )
    }
  } else {
    @core.Expr::StringInterp(parts~, span~)
  }
}

///|
/// Parse input into AST
pub fn parse_ast(input : String) -> @core.Module raise ParseError {
  @profiler.profiler_enter("parser/parse_ast")
  @profiler.profiler_enter("parser/tokenize")
  let tokens = tokenize(input)
  @profiler.profiler_leave()
  let parser = AstParser::new(tokens)
  @profiler.profiler_enter("parser/parse_stmts")
  let parsed = parser.parse()
  @profiler.profiler_leave()
  // Desugar placeholders in Call args after parsing
  @profiler.profiler_enter("parser/desugar")
  let desugared = desugar_module(parsed)
  @profiler.profiler_leave()
  @profiler.profiler_leave()
  desugared
}

///|
/// Parse with error recovery. Returns partial AST and all collected errors.
/// Continues parsing after syntax errors by skipping to the next statement.
pub fn parse_ast_with_recovery(
  input : String,
) -> (@core.Module, Array[ParseError]) {
  let tokens = tokenize(input)
  let parser = AstParser::new(tokens)
  let (parsed, errors) = parser.parse_with_recovery()
  let desugared = desugar_module(parsed)
  (desugared, errors)
}

// ============================================================
// Placeholder desugar: _ * 2 → x -> x * 2
// ============================================================

///|
/// Check if an expression contains any placeholder (_)
///
/// Operator calls (`__` prefix — `__add`, `__lt`, `__eq`, …) are transparent:
/// a placeholder anywhere within them belongs to the enclosing lambda, so we
/// recurse into their args. Regular function calls are opaque — a placeholder
/// in a nested non-operator call scopes to that call, not outward (matches
/// Scala's `_` rule: `Array::any(xs, _ > 5)` wraps at `_ > 5`, not at `any`).
fn contains_placeholder(expr : @core.Expr) -> Bool {
  match expr {
    @core.Expr::Placeholder(..) => true
    @core.Expr::Call(name~, args~, ..) => {
      let is_operator_call = name.has_prefix("__")
      for arg in args {
        let found = if is_operator_call {
          contains_placeholder(arg.expr)
        } else {
          arg.expr is @core.Expr::Placeholder(..)
        }
        if found {
          return true
        }
      }
      false
    }
    @core.Expr::Tuple(items~, ..) => {
      for item in items {
        if contains_placeholder(item) {
          return true
        }
      }
      false
    }
    @core.Expr::Array(items~, ..) => {
      for item in items {
        if contains_placeholder(item) {
          return true
        }
      }
      false
    }
    @core.Expr::Record(fields~, ..) => {
      for field in fields {
        if contains_placeholder(field.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Map(fields~, ..) => {
      for field in fields {
        if contains_placeholder(field.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::If(cond~, ..) => contains_placeholder(cond)
    @core.Expr::Block(..)
    | @core.Expr::Match(..)
    | @core.Expr::ForIn(..)
    | @core.Expr::Handle(..)
    | @core.Expr::Fn(..)
    | @core.Expr::While(..) => false // Don't look inside blocks/lambdas
    @core.Expr::Yield(expr~, ..) => contains_placeholder(expr)
    _ => false
  }
}

///|
/// Count placeholders in an expression and reindex them
fn reindex_placeholders(expr : @core.Expr, counter : Ref[Int]) -> @core.Expr {
  match expr {
    @core.Expr::Placeholder(span~, ..) => {
      let idx = counter.val
      counter.val += 1
      @core.Expr::Placeholder(index=idx, span~)
    }
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let new_args : Array[@core.CallArg] = []
      for arg in args {
        new_args.push(@core.CallArg::{
          label: arg.label,
          expr: reindex_placeholders(arg.expr, counter),
          span: arg.span,
        })
      }
      @core.Expr::Call(name~, type_args~, args=new_args, span~)
    }
    @core.Expr::Tuple(items~, span~) => {
      let new_items : Array[@core.Expr] = []
      for item in items {
        new_items.push(reindex_placeholders(item, counter))
      }
      @core.Expr::Tuple(items=new_items, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let new_items : Array[@core.Expr] = []
      for item in items {
        new_items.push(reindex_placeholders(item, counter))
      }
      @core.Expr::Array(items=new_items, span~)
    }
    @core.Expr::Record(fields~, span~) => {
      let new_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        new_fields.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: reindex_placeholders(field.expr, counter),
          span: field.span,
        })
      }
      @core.Expr::Record(fields=new_fields, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let new_fields : Array[@core.MapFieldExpr] = []
      for field in fields {
        new_fields.push(@core.MapFieldExpr::{
          key: field.key,
          expr: reindex_placeholders(field.expr, counter),
          span: field.span,
        })
      }
      @core.Expr::Map(fields=new_fields, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=reindex_placeholders(cond, counter),
        then_body~,
        else_body~,
        span~,
      )
    @core.Expr::Yield(expr~, span~) =>
      @core.Expr::Yield(expr=reindex_placeholders(expr, counter), span~)
    _ => expr
  }
}

///|
/// Replace placeholders with identifiers
fn replace_placeholders(expr : @core.Expr) -> @core.Expr {
  match expr {
    @core.Expr::Placeholder(index~, span~) => {
      let name = "__p" + index.to_string()
      @core.Expr::Ident(name~, span~)
    }
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let new_args : Array[@core.CallArg] = []
      for arg in args {
        new_args.push(@core.CallArg::{
          label: arg.label,
          expr: replace_placeholders(arg.expr),
          span: arg.span,
        })
      }
      @core.Expr::Call(name~, type_args~, args=new_args, span~)
    }
    @core.Expr::Tuple(items~, span~) => {
      let new_items : Array[@core.Expr] = []
      for item in items {
        new_items.push(replace_placeholders(item))
      }
      @core.Expr::Tuple(items=new_items, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let new_items : Array[@core.Expr] = []
      for item in items {
        new_items.push(replace_placeholders(item))
      }
      @core.Expr::Array(items=new_items, span~)
    }
    @core.Expr::Record(fields~, span~) => {
      let new_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        new_fields.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: replace_placeholders(field.expr),
          span: field.span,
        })
      }
      @core.Expr::Record(fields=new_fields, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let new_fields : Array[@core.MapFieldExpr] = []
      for field in fields {
        new_fields.push(@core.MapFieldExpr::{
          key: field.key,
          expr: replace_placeholders(field.expr),
          span: field.span,
        })
      }
      @core.Expr::Map(fields=new_fields, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=replace_placeholders(cond),
        then_body~,
        else_body~,
        span~,
      )
    @core.Expr::Yield(expr~, span~) =>
      @core.Expr::Yield(expr=replace_placeholders(expr), span~)
    _ => expr
  }
}

///|
/// Desugar placeholder expression to lambda: _ * 2 → (__p0) -> __p0 * 2
pub fn desugar_placeholder_expr(expr : @core.Expr) -> @core.Expr {
  if !contains_placeholder(expr) {
    return expr
  }
  let counter : Ref[Int] = @ref.new(0)
  let reindexed = reindex_placeholders(expr, counter)
  let num_params = counter.val
  let body_expr = replace_placeholders(reindexed)
  let span = expr.span()
  // Build params: __p0, __p1, ...
  let params : Array[@core.FuncParam] = []
  for i in 0..<num_params {
    params.push(@core.FuncParam::{
      name: "__p" + i.to_string(),
      label: @core.ParamLabel::Positional,
      ty: @core.Type::Infer, // Placeholder for type inference
      bounds: [],
    })
  }
  let body = @core.Module::{
    stmts: [@core.Stmt::Expr(expr=body_expr, span=body_expr.span())],
  }
  @core.Expr::Fn(
    type_params=[],
    type_bounds={},
    params~,
    ret=None,
    effects=[],
    body~,
    span~,
  )
}

// ============================================================
// Module-level desugar pass: desugar placeholders in Call args
// ============================================================

///|
/// Desugar placeholders in module
fn desugar_module(m : @core.Module) -> @core.Module {
  let new_stmts : Array[@core.Stmt] = []
  for stmt in m.stmts {
    new_stmts.push(desugar_stmt(stmt))
  }
  @core.Module::{ stmts: new_stmts }
}

///|
fn desugar_stmt(stmt : @core.Stmt) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) =>
      @core.Stmt::Let(rec~, name~, expr=desugar_expr_deep(expr), span~)
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::ExportLet(rec~, name~, expr=desugar_expr_deep(expr), span~)
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::InternalExportLet(
        rec~,
        name~,
        expr=desugar_expr_deep(expr),
        span~,
      )
    @core.Stmt::Test(name~, body~, span~) =>
      @core.Stmt::Test(name~, body=desugar_module(body), span~)
    @core.Stmt::Bench(name~, body~, span~) =>
      @core.Stmt::Bench(name~, body=desugar_module(body), span~)
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(expr=desugar_expr_deep(expr), span~)
    @core.Stmt::LetMut(name~, expr~, span~) =>
      @core.Stmt::LetMut(name~, expr=desugar_expr_deep(expr), span~)
    @core.Stmt::Assign(name~, expr~, span~) =>
      @core.Stmt::Assign(name~, expr=desugar_expr_deep(expr), span~)
    @core.Stmt::IndexAssign(target~, index~, value~, span~) =>
      @core.Stmt::IndexAssign(
        target=desugar_expr_deep(target),
        index=desugar_expr_deep(index),
        value=desugar_expr_deep(value),
        span~,
      )
    @core.Stmt::LetPat(pat~, expr~, span~) =>
      @core.Stmt::LetPat(pat~, expr=desugar_expr_deep(expr), span~)
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) =>
      @core.Stmt::LetPatElse(
        pat~,
        expr=desugar_expr_deep(expr),
        else_body=desugar_module(else_body),
        span~,
      )
    // Non-expression statements pass through
    @core.Stmt::EnumDef(..)
    | @core.Stmt::TypeAlias(..)
    | @core.Stmt::TraitDef(..)
    | @core.Stmt::InternalTraitDef(..)
    | @core.Stmt::TraitImpl(..)
    | @core.Stmt::Import(..)
    | @core.Stmt::Export(..)
    | @core.Stmt::ExportEnumDef(..)
    | @core.Stmt::InternalExportEnumDef(..)
    | @core.Stmt::ExportTypeAlias(..)
    | @core.Stmt::InternalExportTypeAlias(..)
    | @core.Stmt::ReExport(..)
    | @core.Stmt::StructDef(..)
    | @core.Stmt::ExportStructDef(..)
    | @core.Stmt::InternalExportStructDef(..)
    | @core.Stmt::EffectDef(..)
    | @core.Stmt::ExportEffectDef(..)
    | @core.Stmt::ExternLet(..)
    | @core.Stmt::AliasDecl(..) => stmt
  }
}

///|
/// Desugar expression deeply, applying placeholder desugar to Call args
fn desugar_expr_deep(expr : @core.Expr) -> @core.Expr {
  match expr {
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      // Desugar each argument (top-level of Call args)
      let new_args : Array[@core.CallArg] = []
      for arg in args {
        let desugared = desugar_placeholder_expr(arg.expr)
        let deep = desugar_expr_deep(desugared)
        new_args.push(@core.CallArg::{
          label: arg.label,
          expr: deep,
          span: arg.span,
        })
      }
      @core.Expr::Call(name~, type_args~, args=new_args, span~)
    }
    @core.Expr::Tuple(items~, span~) => {
      let new_items : Array[@core.Expr] = []
      for item in items {
        new_items.push(desugar_expr_deep(item))
      }
      @core.Expr::Tuple(items=new_items, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let new_items : Array[@core.Expr] = []
      for item in items {
        new_items.push(desugar_expr_deep(item))
      }
      @core.Expr::Array(items=new_items, span~)
    }
    @core.Expr::Record(fields~, span~) => {
      let new_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        new_fields.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: desugar_expr_deep(field.expr),
          span: field.span,
        })
      }
      @core.Expr::Record(fields=new_fields, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let new_fields : Array[@core.MapFieldExpr] = []
      for field in fields {
        new_fields.push(@core.MapFieldExpr::{
          key: field.key,
          expr: desugar_expr_deep(field.expr),
          span: field.span,
        })
      }
      @core.Expr::Map(fields=new_fields, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=desugar_expr_deep(cond),
        then_body=desugar_module(then_body),
        else_body=desugar_module(else_body),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(body=desugar_module(body), span~)
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let new_arms : Array[@core.MatchArm] = []
      for arm in arms {
        let new_cond : @core.Expr? = match arm.cond {
          Some(c) => Some(desugar_expr_deep(c))
          None => None
        }
        new_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: new_cond,
          expr: desugar_expr_deep(arm.expr),
          span: arm.span,
        })
      }
      @core.Expr::Match(
        scrutinee=desugar_expr_deep(scrutinee),
        arms=new_arms,
        span~,
      )
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) =>
      @core.Expr::ForIn(
        value_name~,
        index_name~,
        iterable=desugar_expr_deep(iterable),
        body=desugar_module(body),
        span~,
      )
    @core.Expr::Handle(body~, arms~, span~) => {
      let new_arms : Array[@core.MatchArm] = []
      for arm in arms {
        new_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: arm.cond.map(desugar_expr_deep),
          expr: desugar_expr_deep(arm.expr),
          span: arm.span,
        })
      }
      @core.Expr::Handle(body=desugar_module(body), arms=new_arms, span~)
    }
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
        body=desugar_module(body),
        span~,
      )
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=desugar_expr_deep(cond),
        body=desugar_module(body),
        span~,
      )
    @core.Expr::Yield(expr=e, span~) =>
      @core.Expr::Yield(expr=desugar_expr_deep(e), span~)
    _ => expr
  }
}
