///|
fn AstParser::parse_expr(self : AstParser) -> @core.Expr raise ParseError {
  self.skip_trivia()
  if self.peek_kind() == if_kw() {
    self.parse_if_expr()
  } else if self.peek_kind() == name() && self.peek().text() == "for" {
    self.parse_for_in_expr()
  } else if self.peek_kind() == while_kw() {
    self.parse_while_expr()
  } else if self.peek_kind() == loop_kw() {
    self.parse_loop_expr()
  } else if self.peek_kind() == name() &&
    self.peek().text() == "loop" &&
    self.is_parameterized_loop() {
    self.parse_loop_expr()
  } else if self.peek_kind() == match_kw() {
    self.parse_match_expr()
  } else if self.peek_kind() == handle_kw() {
    self.parse_handle_expr()
  } else if self.peek_kind() == break_kw() {
    self.parse_break_expr()
  } else if self.peek_kind() == continue_kw() {
    self.parse_continue_expr()
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
    if self.peek_kind() == name() && self.peek().text() == "is" {
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
    k if k == neq() => call1("not", call2("__eq", left, right))
    k if k == lt() => call2("__lt", left, right)
    k if k == gt() => call2("__lt", right, left)
    k if k == lte() =>
      call2("or", call2("__lt", left, right), call2("__eq", left, right))
    _ => call2("or", call2("__lt", right, left), call2("__eq", left, right))
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
        expected="throw(<expr>)",
        got="throw[<type>](...)",
        span~,
      )
    }
    if args.length() != 1 {
      raise ParseError::UnexpectedToken(
        expected="throw(<expr>)",
        got="throw(...)",
        span~,
      )
    }
    match args[0].label {
      Some(_) =>
        raise ParseError::UnexpectedToken(
          expected="throw(<expr>)",
          got="throw(label=...)",
          span~,
        )
      None => return @core.Expr::Raise(value=args[0].expr, span~)
    }
  }
  if name == "perform" {
    if type_args.length() != 0 {
      raise ParseError::UnexpectedToken(
        expected="perform(<expr>)",
        got="perform[<type>](...)",
        span~,
      )
    }
    if args.length() != 1 {
      raise ParseError::UnexpectedToken(
        expected="perform(<expr>)",
        got="perform(...)",
        span~,
      )
    }
    match args[0].label {
      Some(_) =>
        raise ParseError::UnexpectedToken(
          expected="perform(<expr>)",
          got="perform(label=...)",
          span~,
        )
      None =>
        return @core.Expr::Call(name="__perform", type_args=[], args~, span~)
    }
  }
  if type_args.length() != 0 {
    raise ParseError::UnexpectedToken(
      expected="resume(<expr>)",
      got="resume[<type>](...)",
      span~,
    )
  }
  if args.length() != 1 {
    raise ParseError::UnexpectedToken(
      expected="resume(<expr>)",
      got="resume(...)",
      span~,
    )
  }
  match args[0].label {
    Some(_) =>
      raise ParseError::UnexpectedToken(
        expected="resume(<expr>)",
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
      let out : Array[@core.CallArg] = []
      out.push(@core.CallArg::{ label: None, expr: left, span: left_span })
      for arg in args {
        out.push(arg)
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
      call1("not", value)
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
fn AstParser::parse_if_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(if_kw(), "if")
  // Use parse_or_expr (not parse_expr) so `is` is not consumed as Bool-returning
  let cond = self.parse_or_expr()
  // Check for `if expr is pattern { ... }` syntax
  self.skip_trivia()
  if self.peek_kind() == name() && self.peek().text() == "is" {
    let _ = self.bump() // consume "is"
    let pat = self.parse_pattern()
    let then_body = self.parse_block()
    self.skip_trivia()
    let else_body = if self.peek_kind() == else_kw() {
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
    let span = self.span_from(start)
    let wildcard_span = span
    let else_expr = module_to_match_body(else_body, wildcard_span)
    let then_expr = module_to_match_body(then_body, span)
    return @core.Expr::Match(
      scrutinee=cond,
      arms=[
        @core.MatchArm::{ pat, cond: None, expr: then_expr, span },
        @core.MatchArm::{
          pat: @core.Pat::Wildcard(span=wildcard_span),
          cond: None,
          expr: else_expr,
          span: wildcard_span,
        },
      ],
      span~,
    )
  }
  let then_body = self.parse_block()
  self.skip_trivia()
  let else_body = if self.peek_kind() == else_kw() {
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
    // if without else: implicit empty else block returning Unit
    @core.Module::{ stmts: [] }
  }
  let span = self.span_from(start)
  @core.Expr::If(cond~, then_body~, else_body~, span~)
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
  let _ = self.expect(name(), "for") // consume contextual keyword "for"
  // Parse first binding name
  let first_name = self.expect(name(), "binding name").text()
  self.skip_trivia()
  // Check for index,value form: `for i, x in ...`
  let (index_name, value_name) = if self.peek_kind() == comma() {
    let _ = self.bump() // consume comma
    self.skip_trivia()
    let second_name = self.expect(name(), "value binding name").text()
    (Some(first_name), second_name)
  } else {
    (None, first_name)
  }
  // Expect contextual keyword "in"
  let in_tok = self.expect(name(), "in")
  if in_tok.text() != "in" {
    raise ParseError::UnexpectedToken(
      expected="in",
      got=in_tok.text(),
      span=self.token_span(),
    )
  }
  let iterable = self.parse_expr()
  let body = self.parse_block()
  let span = self.span_from(start)
  @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~)
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
  // Accept either loop_kw() or name() "loop" (for parameterized loop via name token)
  let loop_tok = if self.peek_kind() == loop_kw() {
    self.expect(loop_kw(), "loop")
  } else {
    self.expect(name(), "loop")
  }
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
  @core.Expr::Handle(body~, arms~, span~)
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
    expected="throw(<expr>)",
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
    if self.peek_kind() == dotdotdot() {
      let spread_start = self.pos
      let _ = self.expect(dotdotdot(), "...")
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
  if self.peek_kind() == name() && self.peek().text() == "with" {
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
    @core.Type::Unit // Placeholder for type inference
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
    let after_text = self.peek().text()
    self.pos = saved // restore position
    // If after () there's "with", "{", or "->", it's a type annotation
    if after_kind == lbrace() {
      return false // type annotation: (Int, String) { ... }
    } else if after_kind == name() && after_text == "with" {
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
  let next_text = self.peek().text()
  self.pos = saved // restore position
  // If name is followed by { or [ (for generic type), it's likely a type annotation
  // If name is followed by "with" (for effects), it's also a type annotation
  // Otherwise it's an expression
  if next_kind == lbrace() || next_kind == lbracket() {
    false // type annotation: Int { ... } or Array[Int] { ... }
  } else if next_kind == name() && next_text == "with" {
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
    if not(first == '0' || first == '1') {
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
  let parsed : Result[Int64, @strconv.StrConvError] = try? @strconv.parse_int64(
    text,
  )
  match parsed {
    Ok(v) => v
    Err(_) => raise ParseError::IntLiteralOverflow(literal=text, span~)
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
    self.skip_trivia()
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
        ty: @core.Type::Unit, // Placeholder for inference
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
    } else if self.peek_kind() == double_colon() &&
      @core.is_ctor_name(base_name) &&
      self.peek_non_trivia_kind(self.pos + 1) == lbrace() {
      // StructName::{ field: value } or StructName[T]::{ field: value }
      let type_args : Array[@core.Type] = []
      let _ = self.bump() // consume ::
      self.skip_trivia()
      let _ = self.expect(lbrace(), "{")
      let fields = self.parse_struct_lit_fields()
      let _ = self.expect(rbrace(), "}")
      let span = self.span_from(start)
      @core.Expr::StructLit(name=base_name, type_args~, fields~, span~)
    } else if self.peek_kind() == double_colon() &&
      self.peek_non_trivia_kind(self.pos + 1) == name() {
      // Type-qualified symbol: Type::member
      let _ = self.bump()
      self.skip_trivia()
      let member_tok = self.expect(name(), "member name")
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
    } else if self.peek_kind() == lparen() {
      let _ = self.bump()
      let args = self.parse_args()
      let _ = self.expect(rparen(), ")")
      let span = self.span_from(start)
      call_or_throw_expr(qualified_name, [], args, span)
    } else if base_name == "_" {
      // Placeholder for lambda shorthand: _ * 2 → x -> x * 2
      let span = self.span_from(start)
      @core.Expr::Placeholder(index=0, span~)
    } else if qualified_name == "throw" {
      let span = self.span_from(start)
      raise ParseError::UnexpectedToken(
        expected="throw(<expr>)",
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
        let index = @strconv.parse_int(index_tok.text()) catch {
          // This shouldn't happen for valid int literals
          _ => 0
        }
        let span = self.span_from(start)
        expr = @core.Expr::TupleIndex(expr~, index~, span~)
        continue
      }
      let method_tok = self.expect(name(), "method name")
      self.skip_trivia()
      if self.peek_kind() == lparen() {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="member access (`expr.field`), method-call sugar is removed; use `(expr.field)(...)`",
          got=method_tok.text() + "(...)",
          span~,
        )
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
    } else if self.peek_kind() == lbracket() && not(saw_newline) {
      // Index access: expr[index] — only on the same line.
      // A newline before [ starts a new array literal expression.
      let _ = self.bump()
      let index = self.parse_expr()
      let _ = self.expect(rbracket(), "]")
      expr = call2("__index", expr, index)
    } else if self.peek_kind() == lparen() && not(saw_newline) {
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
  if not(saw_segment) {
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
          raw = (try! text[0:len - 1]).to_string()
        }
      }
      let parsed : Result[Double, @strconv.StrConvError] = try? @strconv.parse_double(
        raw,
      )
      match parsed {
        Ok(v) => {
          let span = self.span_from(start)
          if is_float {
            @core.Expr::Float(value=Float::from_double(v), span~)
          } else {
            @core.Expr::Double(value=v, span~)
          }
        }
        Err(_) =>
          raise ParseError::UnexpectedToken(
            expected="float",
            got=tok.text(),
            span=self.token_span(),
          )
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
  let parts : Array[@core.Expr] = []
  let chars = raw.to_array()
  let len = chars.length()
  let mut i = 0
  let buf = StringBuilder::new()
  while i < len {
    if i + 1 < len && chars[i] == '\\' && chars[i + 1] == '{' {
      if buf.to_string().length() > 0 {
        parts.push(@core.Expr::String(value=buf.to_string(), span~))
        buf.reset()
      }
      i += 2
      let expr_buf = StringBuilder::new()
      let mut depth = 1
      while i < len && depth > 0 {
        if chars[i] == '{' {
          depth += 1
          expr_buf.write_char(chars[i])
        } else if chars[i] == '}' {
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
      parts.push(
        @core.Expr::Call(
          name="__to_string",
          type_args=[],
          args=[@core.CallArg::{ label: None, expr: inner, span }],
          span~,
        ),
      )
    } else if chars[i] == '\\' && i + 1 < len {
      match chars[i + 1] {
        'n' => buf.write_char('\n')
        't' => buf.write_char('\t')
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
    parts.push(@core.Expr::String(value=buf.to_string(), span~))
  }
  if parts.length() == 0 {
    @core.Expr::String(value="", span~)
  } else if parts.length() == 1 {
    parts[0]
  } else {
    let mut result = parts[0]
    for j in 1..<parts.length() {
      result = @core.Expr::Call(
        name="String::concat",
        type_args=[],
        args=[
          @core.CallArg::{ label: None, expr: result, span },
          @core.CallArg::{ label: None, expr: parts[j], span },
        ],
        span~,
      )
    }
    result
  }
}

///|
/// Parse input into AST
pub fn parse_ast(input : String) -> @core.Module raise ParseError {
  let tokens = tokenize(input)
  let parser = AstParser::new(tokens)
  let parsed = parser.parse()
  // Desugar placeholders in Call args after parsing
  desugar_module(parsed)
}

// ============================================================
// Placeholder desugar: _ * 2 → x -> x * 2
// ============================================================

///|
/// Check if an expression contains any placeholder (_)
fn contains_placeholder(expr : @core.Expr) -> Bool {
  match expr {
    @core.Expr::Placeholder(..) => true
    @core.Expr::Call(args~, ..) => {
      for arg in args {
        if contains_placeholder(arg.expr) {
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
    @core.Expr::Raise(value~, ..) => contains_placeholder(value)
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
    @core.Expr::Raise(value~, span~) =>
      @core.Expr::Raise(value=reindex_placeholders(value, counter), span~)
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
    @core.Expr::Raise(value~, span~) =>
      @core.Expr::Raise(value=replace_placeholders(value), span~)
    @core.Expr::Yield(expr~, span~) =>
      @core.Expr::Yield(expr=replace_placeholders(expr), span~)
    _ => expr
  }
}

///|
/// Desugar placeholder expression to lambda: _ * 2 → (__p0) -> __p0 * 2
pub fn desugar_placeholder_expr(expr : @core.Expr) -> @core.Expr {
  if not(contains_placeholder(expr)) {
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
      ty: @core.Type::Unit, // Placeholder for type inference
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
    | @core.Stmt::ExternLet(..) => stmt
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
    @core.Expr::Raise(value~, span~) =>
      @core.Expr::Raise(value=desugar_expr_deep(value), span~)
    @core.Expr::Yield(expr=e, span~) =>
      @core.Expr::Yield(expr=desugar_expr_deep(e), span~)
    _ => expr
  }
}
