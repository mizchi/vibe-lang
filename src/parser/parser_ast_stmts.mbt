///|
fn AstParser::parse_stmt(self : AstParser) -> @core.Stmt? raise ParseError {
  self.skip_trivia()
  match self.peek_kind() {
    k if k == let_kw() => Some(self.parse_let_stmt())
    k if k == enum_kw() => Some(self.parse_enum_stmt())
    k if k == struct_kw() => Some(self.parse_struct_stmt())
    k if k == type_kw() => Some(self.parse_type_alias_stmt())
    k if k == trait_kw() => Some(self.parse_trait_stmt())
    k if k == impl_kw() => Some(self.parse_impl_stmt())
    k if k == import_kw() => Some(self.parse_import_stmt())
    k if k == use_kw() =>
      raise ParseError::UnexpectedToken(
        expected="`import <module-ref> { ... }` (`use` is removed)",
        got=self.peek().text(),
        span=self.token_span(),
      )
    k if k == declare_kw() =>
      raise ParseError::UnexpectedToken(
        expected="`extern let %name: Type` (`declare` is removed)",
        got=self.peek().text(),
        span=self.token_span(),
      )
    k if k == export_kw() => Some(self.parse_export_stmt())
    k if k == test_kw() => Some(self.parse_test_stmt())
    k if k == bench_kw() => Some(self.parse_bench_stmt())
    k if k == name() => {
      let tok = self.peek()
      let next = self.peek_non_trivia_ahead(1)
      let next2 = self.peek_non_trivia_ahead(2)
      if tok.text() == "internal" && next == export_kw() {
        Some(self.parse_internal_export_stmt())
      } else if tok.text() == "extern" && next == let_kw() {
        Some(self.parse_extern_let_stmt())
      } else if tok.text() == "module" && next == name() && next2 == lbrace() {
        Some(self.parse_module_stmt(false))
      } else if tok.text() == "suberror" {
        Some(self.parse_suberror_stmt())
      } else if tok.text() == "effect" {
        Some(self.parse_effect_stmt(false))
      } else {
        if tok.text() == "open" && next == trait_kw() {
          raise ParseError::UnexpectedToken(
            expected="`open trait` is only allowed as `export open trait`",
            got=tok.text(),
            span=self.token_span(),
          )
        }
        if tok.text() == "alias" && next == name() && next2 == eq() {
          raise ParseError::UnexpectedToken(
            expected="`alias` statement is removed; use `type` for type aliases",
            got=tok.text(),
            span=self.token_span(),
          )
        }
        if tok.text() == "flake" && next == lbrace() {
          raise ParseError::UnexpectedToken(
            expected="`flake` block is removed",
            got=tok.text(),
            span=self.token_span(),
          )
        }
        let assign_next = self.peek_assign_op_kind_after_name()
        if assign_next == eq() || is_compound_assign(assign_next) {
          Some(self.parse_assign_stmt())
        } else {
          Some(self.parse_expr_or_index_assign_stmt())
        }
      }
    }
    _ => Some(self.parse_expr_or_index_assign_stmt())
  }
}

///|
fn AstParser::peek_assign_op_kind_after_name(
  self : AstParser,
) -> @cst.SyntaxKind {
  let next = self.peek_non_trivia_ahead(1)
  if next != double_colon() {
    return next
  }
  if self.peek_non_trivia_ahead(2) != name() {
    return eof()
  }
  self.peek_non_trivia_ahead(3)
}

///|
fn AstParser::parse_let_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(let_kw(), "let")
  self.skip_trivia()
  let mut rec_flag = false
  let mut mut_flag = false
  if self.peek_kind() == rec_kw() {
    let _ = self.bump()
    rec_flag = true
  }
  if self.peek_kind() == mut_kw() {
    let _ = self.bump()
    mut_flag = true
  }
  self.skip_trivia()
  if !rec_flag && !mut_flag {
    // Check if this is a pattern: tuple, record, or ctor
    let next_kind = self.peek_non_trivia_kind(self.pos + 1)
    let next2_kind = self.peek_non_trivia_kind(self.pos + 2)
    let is_pattern = self.peek_kind() == lparen() ||
      self.peek_kind() == record_kw() ||
      self.peek_kind() == lbracket() ||
      (
        self.peek_kind() == name() &&
        next_kind != colon() &&
        @core.is_ctor_name(self.peek().text()) &&
        (
          next_kind != double_colon() ||
          (next_kind == double_colon() && next2_kind == lbrace())
        )
      )
    if is_pattern {
      let pat = self.parse_pattern()
      let _ = self.expect(eq(), "=")
      let expr = self.parse_expr()
      self.skip_trivia()
      // Check for else clause: let Pat = expr else { body }
      if self.peek_kind() == else_kw() {
        let _ = self.bump() // consume else
        let else_body = self.parse_block()
        let _ = self.eat(semicolon())
        let span = self.span_from(start)
        return @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~)
      }
      let _ = self.eat(semicolon())
      let span = self.span_from(start)
      return @core.Stmt::LetPat(pat~, expr~, span~)
    }
  }
  let binding_name = self.parse_type_member_name("name")
  let ann_ty : @core.Type? = if self.peek_kind() == colon() {
    let _ = self.bump()
    self.skip_trivia()
    Some(self.parse_type())
  } else {
    None
  }
  let _ = self.expect(eq(), "=")
  let raw_expr = self.parse_expr()
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  let expr = match ann_ty {
    Some(ty) =>
      if rec_flag {
        fill_fn_ret_from_annotation(ty, raw_expr)
      } else {
        // Step 1: propagate the annotation (param types, return type, effects)
        // into the Fn RHS so the checker sees the declared effects and
        // tuple/generic shapes when typing `body`. `fill_fn_ret_from_annotation`
        // only fills *missing* fields — user-written param types, return type,
        // and effects are preserved so mismatches can still be flagged.
        let filled = match (ty, raw_expr) {
          (@core.Type::Func(_), @core.Expr::Fn(_)) =>
            fill_fn_ret_from_annotation(ty, raw_expr)
          _ => raw_expr
        }
        // Step 2: wrap the (possibly filled) RHS in a type-assertion helper so
        // the checker still verifies that the lambda type actually matches the
        // declared annotation. Skip the wrapper only for generic annotations
        // (the helper cannot be instantiated at an unresolved type param).
        if type_contains_param(ty) {
          filled
        } else {
          wrap_local_let_with_annotation(ty, filled, span)
        }
      }
    None => raw_expr
  }
  if mut_flag {
    @core.Stmt::LetMut(name=binding_name, expr~, span~)
  } else {
    @core.Stmt::Let(rec=rec_flag, name=binding_name, expr~, span~)
  }
}

///|
/// For `let rec f: (A) -> R = (x) -> { ... }`, fill in the Fn node's missing
/// ret type and param types from the top-level annotation so the checker sees them.
fn fill_fn_ret_from_annotation(
  ann_ty : @core.Type,
  raw_expr : @core.Expr,
) -> @core.Expr {
  match (ann_ty, raw_expr) {
    (
      @core.Type::Func(params=ann_params, ret=ann_ret, effects=ann_effects),
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects~,
        body~,
        span~
      ),
    ) => {
      // Fill param types from annotation when the Fn node params lack types
      let filled_params : Array[@core.FuncParam] = []
      for i, p in params {
        if p.ty.is_infer_placeholder() && i < ann_params.length() {
          filled_params.push(@core.FuncParam::{
            name: p.name,
            label: p.label,
            ty: ann_params[i].ty,
            bounds: p.bounds,
          })
        } else {
          filled_params.push(p)
        }
      }
      // Fill ret from annotation when missing
      let filled_ret = match ret {
        None => Some(ann_ret)
        Some(_) => ret
      }
      // Fill effects from annotation when the Fn node has none
      let filled_effects = if effects.is_empty() && !ann_effects.is_empty() {
        ann_effects
      } else {
        effects
      }
      // If the annotation's return type is itself a function type and the
      // body reduces to a single `Fn` expression (the common curried-function
      // pattern `let f: (A) -> (B) -> C = (a) -> (b) -> body`), recursively
      // fill the inner Fn so its placeholder params also get the expected
      // types. Without this the checker sees the inner lambda's params as
      // `Unit` (the placeholder sentinel) and raises a spurious "expected
      // <ann ret param type>, actual Unit" mismatch.
      let filled_body = descend_fn_ret_annotation_into_body(ann_ret, body)
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params=filled_params,
        ret=filled_ret,
        effects=filled_effects,
        body=filled_body,
        span~,
      )
    }
    _ => raw_expr
  }
}

///|
/// If `body` is a single-expression block `{ Fn(..) }` and `ann_ret` is a
/// `Type::Func`, re-build the body with the inner Fn's placeholders filled
/// from `ann_ret`. Returns the original body otherwise.
fn descend_fn_ret_annotation_into_body(
  ann_ret : @core.Type,
  body : @core.Module,
) -> @core.Module {
  if body.stmts.length() != 1 {
    return body
  }
  match body.stmts[0] {
    @core.Stmt::Expr(expr~, span=stmt_span) =>
      match (ann_ret, expr) {
        (@core.Type::Func(_), @core.Expr::Fn(_)) => {
          let new_expr = fill_fn_ret_from_annotation(ann_ret, expr)
          @core.Module::{
            stmts: [@core.Stmt::Expr(expr=new_expr, span=stmt_span)],
          }
        }
        _ => body
      }
    _ => body
  }
}

///|
fn type_contains_param(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::Param(_) => true
    @core.Type::Func(params~, ret~, ..) =>
      params.iter().any(fn(p) { type_contains_param(p.ty) }) ||
      type_contains_param(ret)
    @core.Type::Array(inner) => type_contains_param(inner)
    @core.Type::Map(k, v) => type_contains_param(k) || type_contains_param(v)
    @core.Type::Set(inner) => type_contains_param(inner)
    @core.Type::Tuple(items) =>
      items.iter().any(fn(item) { type_contains_param(item) })
    @core.Type::Named(args~, ..) =>
      args.iter().any(fn(arg) { type_contains_param(arg) })
    _ => false
  }
}

///|
fn wrap_local_let_with_annotation(
  ann_ty : @core.Type,
  raw_expr : @core.Expr,
  span : @core.Span,
) -> @core.Expr {
  let helper_name = "__vibe_local_type_assert_" + span.start.to_string()
  let helper_param_name = "__vibe_local_type_assert_value"
  let helper_param = @core.FuncParam::{
    name: helper_param_name,
    label: @core.ParamLabel::Positional,
    ty: ann_ty,
    bounds: [],
  }
  let helper_body_expr = @core.Expr::Ident(name=helper_param_name, span~)
  let helper_body = @core.Module::{
    stmts: [@core.Stmt::Expr(expr=helper_body_expr, span~)],
  }
  let helper_expr = @core.Expr::Fn(
    type_params=[],
    type_bounds={},
    params=[helper_param],
    ret=Some(ann_ty),
    effects=[],
    body=helper_body,
    span~,
  )
  let helper_stmt = @core.Stmt::Let(
    rec=false,
    name=helper_name,
    expr=helper_expr,
    span~,
  )
  let call_arg_span = raw_expr.span()
  let call_expr = @core.Expr::Call(
    name=helper_name,
    type_args=[],
    args=[@core.CallArg::{ label: None, expr: raw_expr, span: call_arg_span }],
    span~,
  )
  @core.Expr::Block(
    body=@core.Module::{
      stmts: [helper_stmt, @core.Stmt::Expr(expr=call_expr, span~)],
    },
    span~,
  )
}

///|
fn AstParser::parse_type_member_name(
  self : AstParser,
  label : String,
) -> String raise ParseError {
  let base_tok = self.expect_name_like(label)
  let mut out = base_tok.text()
  self.skip_trivia()
  if self.peek_kind() == double_colon() {
    let _ = self.bump()
    self.skip_trivia()
    let member_tok = self.expect_name_like(label + " member")
    out = out + "::" + member_tok.text()
  }
  out
}

///|
fn is_compound_assign(kind : @cst.SyntaxKind) -> Bool {
  kind == plus_eq() ||
  kind == minus_eq() ||
  kind == star_eq() ||
  kind == slash_eq() ||
  kind == percent_eq()
}

///|
fn compound_to_op(kind : @cst.SyntaxKind) -> String {
  if kind == plus_eq() {
    "__add"
  } else if kind == minus_eq() {
    "__sub"
  } else if kind == star_eq() {
    "__mul"
  } else if kind == slash_eq() {
    "__div"
  } else {
    "__mod"
  }
}

///|
fn AstParser::parse_assign_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let binding_name = self.parse_type_member_name("name")
  self.skip_trivia()
  let op_kind = self.peek_kind()
  if op_kind == eq() {
    let _ = self.bump()
    let expr = self.parse_expr()
    let _ = self.eat(semicolon())
    let span = self.span_from(start)
    @core.Stmt::Assign(name=binding_name, expr~, span~)
  } else {
    let _ = self.bump() // compound assign token
    let op_name = compound_to_op(op_kind)
    let rhs = self.parse_expr()
    let name_span = self.span_from(start)
    let ident : @core.Expr = @core.Expr::Ident(
      name=binding_name,
      span=name_span,
    )
    let desugared = call2(op_name, ident, rhs)
    let _ = self.eat(semicolon())
    let span = self.span_from(start)
    @core.Stmt::Assign(name=binding_name, expr=desugared, span~)
  }
}

///|
/// Parse an expression statement, or an indexed assignment if `=` follows.
fn AstParser::parse_expr_or_index_assign_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let expr = self.parse_expr()
  self.skip_trivia()
  // Check if this is an indexed assignment: expr[index] = value
  if self.peek_kind() == eq() {
    match expr {
      @core.Expr::Call(name="__index", args~, ..) =>
        if args.length() == 2 {
          let _ = self.bump() // consume =
          let value = self.parse_expr()
          let _ = self.eat(semicolon())
          let span = self.span_from(start)
          @core.Stmt::IndexAssign(
            target=args[0].expr,
            index=args[1].expr,
            value~,
            span~,
          )
        } else {
          raise ParseError::UnexpectedToken(
            expected="indexed expression",
            got="=",
            span=self.token_span(),
          )
        }
      _ =>
        raise ParseError::UnexpectedToken(
          expected="assignment target",
          got="=",
          span=self.token_span(),
        )
    }
  } else {
    let _ = self.eat(semicolon())
    let span = self.span_from(start)
    @core.Stmt::Expr(expr~, span~)
  }
}

///|
fn AstParser::expect_decl_separator(
  self : AstParser,
  separator_name : String,
) -> Unit raise ParseError {
  self.skip_trivia()
  match self.peek_kind() {
    k if k == semicolon() => {
      let _ = self.bump()
    }
    k if k == comma() =>
      raise ParseError::UnexpectedToken(
        expected="; (" + separator_name + ")",
        got=self.peek().text(),
        span=self.token_span(),
      )
    k if k == rbrace() => ()
    k if k == eof() => raise ParseError::UnexpectedEof(span=self.token_span())
    _ =>
      raise ParseError::UnexpectedToken(
        expected="; (" + separator_name + ")",
        got=self.peek().text(),
        span=self.token_span(),
      )
  }
}

///|
fn AstParser::parse_enum_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(enum_kw(), "enum")
  self.skip_trivia()
  let name_tok = self.expect(name(), "enum name")
  let params = self.parse_type_params()
  let param_set = param_set_from_params(params)
  self.skip_trivia()
  let _ = self.expect(lbrace(), "{")
  let ctors : Array[@core.TypeCtor] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    ctors.push(self.parse_type_ctor(param_set))
    self.expect_decl_separator("enum variant separator")
  }
  let _ = self.expect(rbrace(), "}")
  let derives = self.parse_derive_clause()
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  self.queue_derive_impls(name_tok.text(), params, derives, span)
  @core.Stmt::EnumDef(name=name_tok.text(), params~, ctors~, span~)
}

///|
fn AstParser::parse_suberror_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(name(), "suberror")
  self.skip_trivia()
  let name_tok = self.expect(name(), "suberror name")
  let params = self.parse_type_params()
  let param_set = param_set_from_params(params)
  self.skip_trivia()
  let ctors : Array[@core.TypeCtor] = []
  if self.peek_kind() == lparen() {
    let ctor_start = self.pos
    let _ = self.bump()
    self.skip_trivia()
    let args : Array[@core.Type] = []
    if self.peek_kind() != rparen() {
      args.push(self.parse_type_with_params(param_set))
      while ({
              self.skip_trivia()
              self.peek_kind() == comma()
            }) {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rparen() {
          break
        }
        args.push(self.parse_type_with_params(param_set))
      }
    }
    let _ = self.expect(rparen(), ")")
    ctors.push(@core.TypeCtor::{
      name: name_tok.text(),
      args,
      span: self.span_from(ctor_start),
    })
  } else if self.peek_kind() == lbrace() {
    let _ = self.bump()
    while ({
            self.skip_trivia()
            self.peek_kind() != rbrace()
          }) {
      if self.peek_kind() == eof() {
        raise ParseError::UnexpectedEof(span=self.token_span())
      }
      ctors.push(self.parse_type_ctor(param_set))
      self.expect_decl_separator("suberror variant separator")
    }
    let _ = self.expect(rbrace(), "}")
  } else {
    raise ParseError::UnexpectedToken(
      expected="suberror payload",
      got=self.peek().text(),
      span=self.token_span(),
    )
  }
  let derives = self.parse_derive_clause()
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  self.queue_derive_impls(name_tok.text(), params, derives, span)
  self.queue_suberror_impl(name_tok.text(), params, span)
  @core.Stmt::EnumDef(name=name_tok.text(), params~, ctors~, span~)
}

///|
/// Parse effect declaration:
///   effect Name[T] { Op(ArgType) -> RetType; Op2 -> RetType }
fn AstParser::parse_effect_stmt(
  self : AstParser,
  _exported : Bool,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(name(), "effect")
  self.skip_trivia()
  let name_tok = self.expect(name(), "effect name")
  let params = self.parse_type_params()
  let param_set = param_set_from_params(params)
  self.skip_trivia()
  let _ = self.expect(lbrace(), "{")
  let ops : Array[@core.EffectOp] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    ops.push(self.parse_effect_op(param_set))
    self.expect_decl_separator("effect operation separator")
  }
  let _ = self.expect(rbrace(), "}")
  let span = self.span_from(start)
  @core.Stmt::EffectDef(name=name_tok.text(), params~, ops~, span~)
}

///|
/// Parse a single effect operation:
///   OpName(ArgType, ...) -> RetType
///   OpName -> RetType
fn AstParser::parse_effect_op(
  self : AstParser,
  param_set : Map[String, Bool],
) -> @core.EffectOp raise ParseError {
  let op_start = self.pos
  let op_name_tok = self.expect(name(), "effect operation name")
  self.skip_trivia()
  let op_params : Array[@core.Type] = []
  if self.peek_kind() == lparen() {
    let _ = self.bump()
    self.skip_trivia()
    if self.peek_kind() != rparen() {
      op_params.push(self.parse_type_with_params(param_set))
      while ({
              self.skip_trivia()
              self.peek_kind() == comma()
            }) {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rparen() {
          break
        }
        op_params.push(self.parse_type_with_params(param_set))
      }
    }
    let _ = self.expect(rparen(), ")")
    self.skip_trivia()
  }
  let _ = self.expect(thin_arrow(), "->")
  self.skip_trivia()
  let ret = self.parse_type_with_params(param_set)
  @core.EffectOp::{
    name: op_name_tok.text(),
    params: op_params,
    ret,
    span: self.span_from(op_start),
  }
}

///|
fn AstParser::parse_struct_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(struct_kw(), "struct")
  self.skip_trivia()
  let name_tok = self.expect(name(), "struct name")
  let params = self.parse_type_params()
  let param_set = param_set_from_params(params)
  self.skip_trivia()
  let _ = self.expect(lbrace(), "{")
  let fields : Array[@core.StructField] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    let field_start = self.pos
    let field_name = self.expect(name(), "field name")
    self.skip_trivia()
    let _ = self.expect(colon(), ":")
    let field_ty = self.parse_type_with_params(param_set)
    fields.push(@core.StructField::{
      name: field_name.text(),
      ty: field_ty,
      span: self.span_from(field_start),
    })
    self.expect_decl_separator("struct field separator")
  }
  let _ = self.expect(rbrace(), "}")
  let derives = self.parse_derive_clause()
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  self.queue_derive_impls(name_tok.text(), params, derives, span)
  @core.Stmt::StructDef(name=name_tok.text(), params~, fields~, span~)
}

///|
fn AstParser::parse_derive_clause(
  self : AstParser,
) -> Array[String] raise ParseError {
  self.skip_trivia()
  if self.peek_kind() != derive_kw() {
    return []
  }
  let _ = self.bump()
  self.skip_trivia()
  let _ = self.expect(lparen(), "(")
  let traits : Array[String] = []
  self.skip_trivia()
  if self.peek_kind() != rparen() {
    let first = self.expect(name(), "trait name")
    traits.push(first.text())
    while ({
            self.skip_trivia()
            self.peek_kind() == comma()
          }) {
      let _ = self.bump()
      self.skip_trivia()
      if self.peek_kind() == rparen() {
        break
      }
      let next = self.expect(name(), "trait name")
      traits.push(next.text())
    }
  }
  let _ = self.expect(rparen(), ")")
  traits
}

///|
fn AstParser::queue_derive_impls(
  self : AstParser,
  type_name : String,
  type_params : Array[String],
  derives : Array[String],
  span : @core.Span,
) -> Unit {
  let target_args : Array[@core.Type] = []
  for type_param in type_params {
    target_args.push(@core.Type::Param(type_param))
  }
  let target = @core.Type::Named(name=type_name, args=target_args)
  let seen : Map[String, Bool] = {}
  for trait_name in derives {
    if seen.contains(trait_name) {
      continue
    }
    seen[trait_name] = true
    let type_bounds : Map[String, Array[String]] = {}
    for type_param in type_params {
      type_bounds[type_param] = [trait_name]
    }
    self.pending_stmts.push(
      @core.Stmt::TraitImpl(
        type_params=type_params.copy(),
        type_bounds~,
        trait_name~,
        target~,
        methods=[],
        span~,
      ),
    )
  }
}

///|
fn AstParser::queue_suberror_impl(
  self : AstParser,
  type_name : String,
  type_params : Array[String],
  span : @core.Span,
) -> Unit {
  let target_args : Array[@core.Type] = []
  for type_param in type_params {
    target_args.push(@core.Type::Param(type_param))
  }
  let target = @core.Type::Named(name=type_name, args=target_args)
  self.pending_stmts.push(
    @core.Stmt::TraitImpl(
      type_params=type_params.copy(),
      type_bounds={},
      trait_name="Error",
      target~,
      methods=[],
      span~,
    ),
  )
}

///|
fn AstParser::parse_type_alias_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(type_kw(), "type")
  self.skip_trivia()
  let name_tok = self.expect(name(), "type name")
  let params = self.parse_type_params()
  let param_set = param_set_from_params(params)
  let _ = self.expect(eq(), "=")
  let target = self.parse_type_with_params(param_set)
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  @core.Stmt::TypeAlias(name=name_tok.text(), params~, target~, span~)
}

///|
fn AstParser::parse_trait_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(trait_kw(), "trait")
  self.skip_trivia()
  let name_tok = self.expect(name(), "trait name")
  self.skip_trivia()
  let supertraits = if self.peek_kind() == colon() {
    let _ = self.bump()
    self.skip_trivia()
    self.parse_trait_bounds()
  } else {
    []
  }
  self.skip_trivia()
  let methods : Array[@core.TraitMethodSig] = []
  if self.peek_kind() == lbrace() {
    let _ = self.bump()
    while ({
            self.skip_trivia()
            self.peek_kind() != rbrace() && self.peek_kind() != eof()
          }) {
      let method_start = self.pos
      let method_tok = self.expect(name(), "method name")
      self.skip_trivia()
      let params : Array[@core.FuncParam] = []
      if self.peek_kind() == lparen() {
        let _ = self.bump()
        self.skip_trivia()
        let mut param_idx = 0
        while self.peek_kind() != rparen() && self.peek_kind() != eof() {
          if param_idx > 0 {
            let _ = self.expect(comma(), ",")
            self.skip_trivia()
          }
          let ty = self.parse_type()
          params.push(@core.FuncParam::{
            name: "_" + param_idx.to_string(),
            label: @core.ParamLabel::Positional,
            ty,
            bounds: [],
          })
          param_idx += 1
          self.skip_trivia()
        }
        let _ = self.expect(rparen(), ")")
      }
      self.skip_trivia()
      let ret = if self.peek_kind() == thin_arrow() {
        let _ = self.bump()
        self.parse_type()
      } else {
        @core.Type::Unit
      }
      self.skip_trivia()
      let _ = self.eat(semicolon())
      methods.push({
        name: method_tok.text(),
        params,
        ret,
        span: self.span_from(method_start),
      })
    }
    let _ = self.expect(rbrace(), "}")
  } else {
    let _ = self.eat(semicolon())
  }
  let span = self.span_from(start)
  @core.Stmt::TraitDef(
    name=name_tok.text(),
    supertraits~,
    methods~,
    open_impl=false,
    exported=false,
    span~,
  )
}

///|
fn AstParser::parse_impl_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(impl_kw(), "impl")
  let parsed = self.parse_fn_type_params()
  let type_params = parsed.names
  let type_bounds = parsed.bounds
  self.skip_trivia()
  let trait_tok = self.expect(name(), "trait name")
  self.skip_trivia()
  let _ = self.expect(for_kw(), "for")
  let target = self.parse_type_with_params(param_set_from_params(type_params))
  self.skip_trivia()
  let methods : Array[@core.ImplMethodDef] = []
  if self.peek_kind() == lbrace() {
    let _ = self.bump()
    while ({
            self.skip_trivia()
            self.peek_kind() != rbrace() && self.peek_kind() != eof()
          }) {
      let method_start = self.pos
      let method_tok = self.expect(name(), "method name")
      self.skip_trivia()
      let _ = self.expect(eq(), "=")
      self.skip_trivia()
      let expr = self.parse_expr()
      self.skip_trivia()
      let _ = self.eat(semicolon())
      methods.push(@core.ImplMethodDef::{
        name: method_tok.text(),
        expr,
        span: self.span_from(method_start),
      })
    }
    let _ = self.expect(rbrace(), "}")
  } else {
    let _ = self.eat(semicolon())
  }
  let span = self.span_from(start)
  @core.Stmt::TraitImpl(
    type_params~,
    type_bounds~,
    trait_name=trait_tok.text(),
    target~,
    methods~,
    span~,
  )
}

///|
fn AstParser::parse_type_ctor(
  self : AstParser,
  params : Map[String, Bool],
) -> @core.TypeCtor raise ParseError {
  let start = self.pos
  let name_tok = self.expect(name(), "ctor")
  if !@core.is_ctor_name(name_tok.text()) {
    raise ParseError::UnexpectedToken(
      expected="ctor",
      got=name_tok.text(),
      span=self.token_span(),
    )
  }
  let args : Array[@core.Type] = []
  self.skip_trivia()
  if self.peek_kind() == lparen() {
    let _ = self.bump()
    self.skip_trivia()
    if self.peek_kind() != rparen() {
      if self.peek_kind() == mut_kw() {
        raise ParseError::MutableEnumFieldUnsupported(span=self.token_span())
      }
      args.push(self.parse_type_with_params(params))
      while ({
              self.skip_trivia()
              self.peek_kind() == comma()
            }) {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rparen() {
          break
        }
        if self.peek_kind() == mut_kw() {
          raise ParseError::MutableEnumFieldUnsupported(span=self.token_span())
        }
        args.push(self.parse_type_with_params(params))
      }
    }
    let _ = self.expect(rparen(), ")")
  }
  let span = self.span_from(start)
  @core.TypeCtor::{ name: name_tok.text(), args, span }
}

///|
fn AstParser::parse_type_params(
  self : AstParser,
) -> Array[String] raise ParseError {
  let params : Array[String] = []
  self.skip_trivia()
  if self.peek_kind() == lbracket() {
    let _ = self.bump()
    self.skip_trivia()
    if self.peek_kind() != rbracket() {
      let first = self.expect(name(), "type param")
      params.push(first.text())
      while ({
              self.skip_trivia()
              self.peek_kind() == comma()
            }) {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rbracket() {
          break
        }
        let tok = self.expect(name(), "type param")
        params.push(tok.text())
      }
    }
    let _ = self.expect(rbracket(), "]")
  }
  params
}

///|
fn param_set_from_params(params : Array[String]) -> Map[String, Bool] {
  let set : Map[String, Bool] = {}
  for p in params {
    set[p] = true
  }
  set
}

///|
fn AstParser::parse_test_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(test_kw(), "test")
  self.skip_trivia()
  let mut test_name : String? = None
  if self.peek_kind() == string_lit() || self.peek_kind() == name() {
    let name_tok = self.bump()
    test_name = Some(name_tok.text())
    self.skip_trivia()
  }
  let body = self.parse_block()
  let span = self.span_from(start)
  @core.Stmt::Test(name=test_name, body~, span~)
}

///|
fn AstParser::parse_bench_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(bench_kw(), "bench")
  self.skip_trivia()
  let mut bench_name : String? = None
  if self.peek_kind() == string_lit() || self.peek_kind() == name() {
    let name_tok = self.bump()
    bench_name = Some(name_tok.text())
    self.skip_trivia()
  }
  let body = self.parse_block()
  let span = self.span_from(start)
  @core.Stmt::Bench(name=bench_name, body~, span~)
}

///|
fn AstParser::parse_internal_export_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let internal_tok = self.expect(name(), "internal")
  if internal_tok.text() != "internal" {
    raise ParseError::UnexpectedToken(
      expected="`internal export ...`",
      got=internal_tok.text(),
      span=self.token_span(),
    )
  }
  self.skip_trivia()
  if self.peek_kind() != export_kw() {
    raise ParseError::UnexpectedToken(
      expected="`export` after `internal`",
      got=self.peek().text(),
      span=self.token_span(),
    )
  }
  let _ = self.expect(export_kw(), "export")
  self.skip_trivia()
  if self.peek_kind() == enum_kw() {
    let enum_stmt = self.parse_enum_stmt()
    match enum_stmt {
      @core.Stmt::EnumDef(name~, params~, ctors~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::InternalExportEnumDef(name~, params~, ctors~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="enum definition",
          got="other statement",
          span~,
        )
      }
    }
  } else if self.peek_kind() == name() && self.peek().text() == "suberror" {
    let suberror_stmt = self.parse_suberror_stmt()
    match suberror_stmt {
      @core.Stmt::EnumDef(name~, params~, ctors~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::InternalExportEnumDef(name~, params~, ctors~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="suberror definition",
          got="other statement",
          span~,
        )
      }
    }
  } else if self.peek_kind() == name() && self.peek().text() == "effect" {
    let effect_stmt = self.parse_effect_stmt(false)
    match effect_stmt {
      @core.Stmt::EffectDef(name~, params~, ops~, ..) => {
        let span = self.span_from(start)
        // internal export effects are not yet supported; treat as non-exported
        @core.Stmt::EffectDef(name~, params~, ops~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="effect definition",
          got="other statement",
          span~,
        )
      }
    }
  } else if self.peek_kind() == struct_kw() {
    let struct_stmt = self.parse_struct_stmt()
    match struct_stmt {
      @core.Stmt::StructDef(name~, params~, fields~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::InternalExportStructDef(name~, params~, fields~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="struct definition",
          got="other statement",
          span~,
        )
      }
    }
  } else if self.peek_kind() == type_kw() {
    let type_stmt = self.parse_type_alias_stmt()
    match type_stmt {
      @core.Stmt::TypeAlias(name~, params~, target~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::InternalExportTypeAlias(name~, params~, target~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="type alias",
          got="other statement",
          span~,
        )
      }
    }
  } else if self.peek_kind() == let_kw() {
    let let_stmt = self.parse_let_stmt()
    match let_stmt {
      @core.Stmt::Let(rec~, name~, expr~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::InternalExportLet(rec~, name~, expr~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="let statement",
          got="other statement",
          span~,
        )
      }
    }
  } else if self.peek_kind() == trait_kw() ||
    (self.peek_kind() == name() && self.peek().text() == "open") {
    let mut open_impl = false
    if self.peek_kind() == name() && self.peek().text() == "open" {
      let _ = self.bump()
      self.skip_trivia()
      open_impl = true
    }
    if self.peek_kind() != trait_kw() {
      let span = self.span_from(start)
      raise ParseError::UnexpectedToken(
        expected="trait definition",
        got=self.peek().text(),
        span~,
      )
    }
    let trait_stmt = self.parse_trait_stmt()
    match trait_stmt {
      @core.Stmt::TraitDef(name~, supertraits~, methods~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::InternalTraitDef(
          name~,
          supertraits~,
          methods~,
          open_impl~,
          span~,
        )
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="trait definition",
          got="other statement",
          span~,
        )
      }
    }
  } else {
    raise ParseError::UnexpectedToken(
      expected="`internal export let/type/enum/struct/trait ...`",
      got=self.peek().text(),
      span=self.token_span(),
    )
  }
}

///|
fn AstParser::parse_percent_symbol_name(
  self : AstParser,
  label : String,
) -> String raise ParseError {
  let _ = self.expect(percent(), "%")
  self.skip_trivia()
  let name_tok = self.expect(name(), label)
  "%" + name_tok.text()
}

///|
fn AstParser::parse_extern_let_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let extern_tok = self.expect(name(), "extern")
  if extern_tok.text() != "extern" {
    raise ParseError::UnexpectedToken(
      expected="`extern let %name: Type`",
      got=extern_tok.text(),
      span=self.token_span(),
    )
  }
  self.skip_trivia()
  let _ = self.expect(let_kw(), "let")
  self.skip_trivia()
  let name = self.parse_percent_symbol_name("%symbol")
  self.skip_trivia()
  let _ = self.expect(colon(), ":")
  self.skip_trivia()
  let ty = self.parse_type()
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  @core.Stmt::ExternLet(name~, ty~, span~)
}

///|
fn module_qualified_name(module_name : String, member_name : String) -> String {
  if member_name.contains("::") {
    member_name
  } else {
    module_name + "::" + member_name
  }
}

///|
fn collect_module_decl_names(stmts : Array[@core.Stmt]) -> Map[String, String] {
  let out : Map[String, String] = {}
  for stmt in stmts {
    match stmt {
      @core.Stmt::Let(name~, ..)
      | @core.Stmt::ExportLet(name~, ..)
      | @core.Stmt::InternalExportLet(name~, ..)
      | @core.Stmt::LetMut(name~, ..) =>
        if !name.contains("::") {
          out[name] = name
        }
      _ => ()
    }
  }
  out
}

///|
fn local_module_name(
  module_name : String,
  name : String,
  locals : Map[String, String],
) -> String {
  match locals.get(name) {
    Some(_) => module_qualified_name(module_name, name)
    None => name
  }
}

///|
fn module_locals_without(
  locals : Map[String, String],
  names : Array[String],
) -> Map[String, String] {
  let out : Map[String, String] = {}
  for key, value in locals {
    let mut shadowed = false
    for name in names {
      if key == name {
        shadowed = true
        break
      }
    }
    if !shadowed {
      out[key] = value
    }
  }
  out
}

///|
fn collect_pat_bindings_for_module(
  pat : @core.Pat,
  out : Array[String],
) -> Unit {
  match pat {
    @core.Pat::Bind(name~, ..) => if name != "_" { out.push(name) }
    @core.Pat::Ctor(args~, ..) =>
      for arg in args {
        collect_pat_bindings_for_module(arg, out)
      }
    @core.Pat::Tuple(items~, ..) =>
      for item in items {
        collect_pat_bindings_for_module(item, out)
      }
    @core.Pat::Record(fields~, ..) =>
      for field in fields {
        collect_pat_bindings_for_module(field.pat, out)
      }
    @core.Pat::Struct(fields~, ..) =>
      for field in fields {
        collect_pat_bindings_for_module(field.pat, out)
      }
    @core.Pat::Or(pats~, ..) =>
      for p in pats {
        collect_pat_bindings_for_module(p, out)
      }
    _ => ()
  }
}

///|
fn rewrite_module_expr(
  module_name : String,
  expr : @core.Expr,
  locals : Map[String, String],
) -> @core.Expr {
  match expr {
    @core.Expr::Ident(name~, span~) =>
      @core.Expr::Ident(
        name=local_module_name(module_name, name, locals),
        span~,
      )
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let next_args : Array[@core.CallArg] = []
      for arg in args {
        next_args.push(@core.CallArg::{
          label: arg.label,
          expr: rewrite_module_expr(module_name, arg.expr, locals),
          span: arg.span,
        })
      }
      @core.Expr::Call(
        name=local_module_name(module_name, name, locals),
        type_args~,
        args=next_args,
        span~,
      )
    }
    @core.Expr::Tuple(items~, span~) => {
      let next_items : Array[@core.Expr] = []
      for item in items {
        next_items.push(rewrite_module_expr(module_name, item, locals))
      }
      @core.Expr::Tuple(items=next_items, span~)
    }
    @core.Expr::TupleIndex(expr~, index~, span~) =>
      @core.Expr::TupleIndex(
        expr=rewrite_module_expr(module_name, expr, locals),
        index~,
        span~,
      )
    @core.Expr::Record(fields~, span~) => {
      let next_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        next_fields.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: rewrite_module_expr(module_name, field.expr, locals),
          span: field.span,
        })
      }
      @core.Expr::Record(fields=next_fields, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let next_items : Array[@core.Expr] = []
      for item in items {
        next_items.push(rewrite_module_expr(module_name, item, locals))
      }
      @core.Expr::Array(items=next_items, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let next_fields : Array[@core.MapFieldExpr] = []
      for field in fields {
        next_fields.push(@core.MapFieldExpr::{
          key: field.key,
          expr: rewrite_module_expr(module_name, field.expr, locals),
          span: field.span,
        })
      }
      @core.Expr::Map(fields=next_fields, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=rewrite_module_expr(module_name, cond, locals),
        then_body=rewrite_module_block(module_name, then_body, locals),
        else_body=rewrite_module_block(module_name, else_body, locals),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(
        body=rewrite_module_block(module_name, body, locals),
        span~,
      )
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      for arm in arms {
        let pat_bindings : Array[String] = []
        collect_pat_bindings_for_module(arm.pat, pat_bindings)
        let arm_locals = module_locals_without(locals, pat_bindings)
        let next_cond = match arm.cond {
          Some(cond) => Some(rewrite_module_expr(module_name, cond, arm_locals))
          None => None
        }
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: next_cond,
          expr: rewrite_module_expr(module_name, arm.expr, arm_locals),
          span: arm.span,
        })
      }
      @core.Expr::Match(
        scrutinee=rewrite_module_expr(module_name, scrutinee, locals),
        arms=next_arms,
        span~,
      )
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let for_locals = module_locals_without(locals, [value_name])
      let for_locals = match index_name {
        Some(idx) => module_locals_without(for_locals, [idx])
        None => for_locals
      }
      @core.Expr::ForIn(
        value_name~,
        index_name~,
        iterable=rewrite_module_expr(module_name, iterable, locals),
        body=rewrite_module_block(module_name, body, for_locals),
        span~,
      )
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      for arm in arms {
        let pat_bindings : Array[String] = []
        collect_pat_bindings_for_module(arm.pat, pat_bindings)
        let arm_locals = module_locals_without(locals, pat_bindings)
        let next_cond = match arm.cond {
          Some(c) => Some(rewrite_module_expr(module_name, c, arm_locals))
          None => None
        }
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: next_cond,
          expr: rewrite_module_expr(module_name, arm.expr, arm_locals),
          span: arm.span,
        })
      }
      @core.Expr::Handle(
        body=rewrite_module_block(module_name, body, locals),
        arms=next_arms,
        span~,
      )
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
      let shadow : Array[String] = []
      for param in params {
        shadow.push(param.name)
      }
      let inner_locals = module_locals_without(locals, shadow)
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects~,
        body=rewrite_module_block(module_name, body, inner_locals),
        span~,
      )
    }
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=rewrite_module_expr(module_name, cond, locals),
        body=rewrite_module_block(module_name, body, locals),
        span~,
      )
    @core.Expr::Yield(expr~, span~) =>
      @core.Expr::Yield(
        expr=rewrite_module_expr(module_name, expr, locals),
        span~,
      )
    @core.Expr::StructLit(name~, type_args~, fields~, span~) => {
      let next_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        next_fields.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: rewrite_module_expr(module_name, field.expr, locals),
          span: field.span,
        })
      }
      @core.Expr::StructLit(name~, type_args~, fields=next_fields, span~)
    }
    _ => expr
  }
}

///|
fn rewrite_module_stmt(
  module_name : String,
  stmt : @core.Stmt,
  locals : Map[String, String],
  exported_module : Bool,
) -> @core.Stmt raise ParseError {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      // Only qualify names that appear in the module's top-level decl set.
      // Nested `Let` stmts inside a RHS block (e.g. the type-assert helper
      // emitted by `wrap_local_let_with_annotation` for `export let f: T = ...`)
      // are block-local; qualifying them would break their call-sites which
      // reference the bare helper name inside the same block.
      let next_name = if locals.contains(name) {
        module_qualified_name(module_name, name)
      } else {
        name
      }
      @core.Stmt::Let(
        rec~,
        name=next_name,
        expr=rewrite_module_expr(module_name, expr, locals),
        span~,
      )
    }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
      let next_expr = rewrite_module_expr(module_name, expr, locals)
      let qualified_name = module_qualified_name(module_name, name)
      if exported_module {
        @core.Stmt::ExportLet(rec~, name=qualified_name, expr=next_expr, span~)
      } else {
        @core.Stmt::Let(rec~, name=qualified_name, expr=next_expr, span~)
      }
    }
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) => {
      let next_expr = rewrite_module_expr(module_name, expr, locals)
      let qualified_name = module_qualified_name(module_name, name)
      @core.Stmt::InternalExportLet(
        rec~,
        name=qualified_name,
        expr=next_expr,
        span~,
      )
    }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let next_name = if locals.contains(name) {
        module_qualified_name(module_name, name)
      } else {
        name
      }
      @core.Stmt::LetMut(
        name=next_name,
        expr=rewrite_module_expr(module_name, expr, locals),
        span~,
      )
    }
    @core.Stmt::Assign(name~, expr~, span~) =>
      @core.Stmt::Assign(
        name=local_module_name(module_name, name, locals),
        expr=rewrite_module_expr(module_name, expr, locals),
        span~,
      )
    @core.Stmt::IndexAssign(target~, index~, value~, span~) =>
      @core.Stmt::IndexAssign(
        target=rewrite_module_expr(module_name, target, locals),
        index=rewrite_module_expr(module_name, index, locals),
        value=rewrite_module_expr(module_name, value, locals),
        span~,
      )
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(
        expr=rewrite_module_expr(module_name, expr, locals),
        span~,
      )
    @core.Stmt::Import(..) => stmt
    @core.Stmt::Export(names~, span~) =>
      if !exported_module {
        @core.Stmt::Export(names=[], span~)
      } else {
        let qualified_names : Array[String] = []
        for name in names {
          qualified_names.push(module_qualified_name(module_name, name))
        }
        @core.Stmt::Export(names=qualified_names, span~)
      }
    @core.Stmt::Test(name~, body~, span~) =>
      @core.Stmt::Test(
        name~,
        body=rewrite_module_block(module_name, body, locals),
        span~,
      )
    @core.Stmt::Bench(name~, body~, span~) =>
      @core.Stmt::Bench(
        name~,
        body=rewrite_module_block(module_name, body, locals),
        span~,
      )
    _ =>
      raise ParseError::UnexpectedToken(
        expected="module body statement (let/export let/internal export let/let mut/assign/expr/import/test/bench)",
        got="unsupported statement",
        span=stmt.span(),
      )
  }
}

///|
fn rewrite_module_block(
  module_name : String,
  body : @core.Module,
  locals : Map[String, String],
) -> @core.Module {
  let next_stmts : Array[@core.Stmt] = []
  let mut active_locals = locals
  for stmt in body.stmts {
    let rewritten = rewrite_module_stmt(module_name, stmt, active_locals, false) catch {
      _ => stmt
    }
    next_stmts.push(rewritten)
    match stmt {
      @core.Stmt::Let(name~, ..) | @core.Stmt::LetMut(name~, ..) => {
        let shadow = [name]
        active_locals = module_locals_without(active_locals, shadow)
      }
      @core.Stmt::LetPat(pat~, ..) => {
        let shadow : Array[String] = []
        collect_pat_bindings_for_module(pat, shadow)
        active_locals = module_locals_without(active_locals, shadow)
      }
      @core.Stmt::Import(spec~, ..) =>
        for item in spec.items {
          let local_name = match item.rename {
            Some(rename) => rename
            None => item.name
          }
          let shadow = [local_name]
          active_locals = module_locals_without(active_locals, shadow)
        }
      _ => ()
    }
  }
  @core.Module::{ stmts: next_stmts }
}

///|
fn AstParser::parse_module_stmt(
  self : AstParser,
  exported : Bool,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let module_tok = self.expect(name(), "module")
  if module_tok.text() != "module" {
    raise ParseError::UnexpectedToken(
      expected="module",
      got=module_tok.text(),
      span=self.token_span(),
    )
  }
  self.skip_trivia()
  let name_tok = self.expect(name(), "module name")
  let module_name = name_tok.text()
  self.skip_trivia()
  let body = self.parse_block()
  let span = self.span_from(start)
  let locals = collect_module_decl_names(body.stmts)
  let lowered : Array[@core.Stmt] = []
  for stmt in body.stmts {
    lowered.push(rewrite_module_stmt(module_name, stmt, locals, exported))
  }
  if lowered.length() == 0 {
    raise ParseError::UnexpectedToken(
      expected="non-empty module body",
      got="}",
      span~,
    )
  }
  let first = lowered[0]
  let mut i = 1
  while i < lowered.length() {
    self.pending_stmts.push(lowered[i])
    i += 1
  }
  first
}

///|
fn AstParser::parse_block(self : AstParser) -> @core.Module raise ParseError {
  let _ = self.expect(lbrace(), "{")
  let stmts : Array[@core.Stmt] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    match self.parse_stmt() {
      Some(stmt) => stmts.push(stmt)
      None => ()
    }
    for pending in self.pending_stmts {
      stmts.push(pending)
    }
    self.pending_stmts = []
  }
  let _ = self.expect(rbrace(), "}")
  @core.Module::{ stmts, }
}

///|
fn AstParser::parse_import_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  if self.peek_kind() != import_kw() {
    raise ParseError::UnexpectedToken(
      expected="`import <module-ref> { ... }`",
      got=self.peek().text(),
      span=self.token_span(),
    )
  }
  let _ = self.bump()
  self.skip_trivia()
  let source = self.parse_module_ref()
  self.skip_trivia()
  // Check for alias declaration: `import ./path @alias_name`
  if self.peek_kind() == name() && self.peek().text().has_prefix("@") {
    match source {
      @core.ModuleRef::Alias(_) =>
        raise ParseError::UnexpectedToken(
          expected="path or hash before alias (not another alias)",
          got=self.peek().text(),
          span=self.token_span(),
        )
      _ => ()
    }
    let alias_tok = self.bump()
    let alias_text = alias_tok.text()
    let alias_name = alias_text.unsafe_substring(
      start=1,
      end=alias_text.length(),
    )
    let _ = self.eat(semicolon())
    let span = self.span_from(start)
    return @core.Stmt::AliasDecl(alias_name~, source~, span~)
  }
  if self.peek_kind() != lbrace() {
    raise ParseError::UnexpectedToken(
      expected="`{` after import source or `@alias` for alias declaration",
      got=self.peek().text(),
      span=self.token_span(),
    )
  }
  let items = self.parse_import_items("import name")
  let spec = @core.ImportSpec::{ items, }
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  @core.Stmt::Import(spec~, source~, span~)
}

///|
fn AstParser::parse_module_item_name(
  self : AstParser,
  label : String,
) -> String raise ParseError {
  let base_tok = self.expect(name(), label)
  let mut out = base_tok.text()
  self.skip_trivia()
  while self.peek_kind() == slash() {
    let _ = self.bump()
    self.skip_trivia()
    let seg_tok = self.expect(name(), label + " segment")
    out = out + "/" + seg_tok.text()
    self.skip_trivia()
  }
  out
}

///|
fn AstParser::parse_import_items(
  self : AstParser,
  item_label : String,
) -> Array[@core.ImportItem] raise ParseError {
  let _ = self.expect(lbrace(), "{")
  let items : Array[@core.ImportItem] = []
  while true {
    self.skip_trivia()
    if self.peek_kind() == rbrace() {
      break
    }
    if self.peek_kind() == comma() {
      raise ParseError::UnexpectedToken(
        expected=item_label + " after `,`",
        got=self.peek().text(),
        span=self.token_span(),
      )
    }
    let kind = self.parse_import_item_kind()
    self.skip_trivia()
    let import_name = if kind == @core.ImportKind::Module {
      self.parse_module_item_name("module name")
    } else {
      self.parse_type_member_name(item_label)
    }
    if kind == @core.ImportKind::Module && self.peek_kind() == double_colon() {
      raise ParseError::UnexpectedToken(
        expected="`import <module-ref> { module foo }` (module namespace only)",
        got=self.peek().text(),
        span=self.token_span(),
      )
    }
    self.skip_trivia()
    let rename : String? = if self.peek_kind() == as_kw() {
      let _ = self.bump()
      self.skip_trivia()
      let alias_tok = self.expect(name(), "alias name")
      Some(alias_tok.text())
    } else {
      None
    }
    items.push(@core.ImportItem::{ kind, name: import_name, rename })
    self.skip_trivia()
    if self.peek_kind() == comma() {
      let _ = self.bump()
      self.skip_trivia()
      if self.peek_kind() == rbrace() {
        break
      }
    } else if self.peek_kind() != rbrace() {
      raise ParseError::UnexpectedToken(
        expected="`,` or `}` in import list",
        got=self.peek().text(),
        span=self.token_span(),
      )
    }
  }
  let _ = self.expect(rbrace(), "}")
  items
}

///|
fn AstParser::parse_import_item_kind(self : AstParser) -> @core.ImportKind {
  if self.peek_kind() == type_kw() {
    let _ = self.bump()
    @core.ImportKind::Type
  } else if self.peek_kind() == trait_kw() {
    let _ = self.bump()
    @core.ImportKind::Trait
  } else if self.peek_kind() == struct_kw() {
    let _ = self.bump()
    @core.ImportKind::Struct
  } else if self.peek_kind() == name() && self.peek().text() == "module" {
    let _ = self.bump()
    @core.ImportKind::Module
  } else if self.peek_kind() == name() && self.peek().text() == "effect" {
    let _ = self.bump()
    @core.ImportKind::Effect
  } else if self.peek_kind() == name() && self.peek().text() == "suberror" {
    let _ = self.bump()
    @core.ImportKind::Suberror
  } else {
    @core.ImportKind::Value
  }
}

///|
/// Find the position of '#' in a path string for hash pinning.
/// Returns -1 if not found. Skips '#' at position 0 (hash refs like #abc).
fn find_hash_in_path(path : String) -> Int {
  let mut i = 1 // skip position 0 to avoid matching hash_ref (#abc)
  while i < path.length() {
    if path[i].to_int() == '#'.to_int() {
      return i
    }
    i += 1
  }
  -1
}

///|
/// Parse a module reference: path, hash, version ref, or symbol ref.
/// After parsing a Path, checks for trailing #hash to produce PinnedPath.
fn AstParser::parse_module_ref(
  self : AstParser,
) -> @core.ModuleRef raise ParseError {
  let result = self.parse_module_ref_inner()
  // Check for path#hash pin: ./types#abc123 → PinnedPath("./types", "abc123")
  match result {
    @core.ModuleRef::Path(path~) => {
      let hash_idx = find_hash_in_path(path)
      if hash_idx >= 0 {
        let clean_path = path.unsafe_substring(start=0, end=hash_idx)
        let hash = path.unsafe_substring(start=hash_idx + 1, end=path.length())
        @core.ModuleRef::PinnedPath(path=clean_path, hash~)
      } else if self.peek_kind() == hash_ref() {
        let hash_tok = self.bump()
        let hash_text = hash_tok.text()
        let hash = if hash_text.length() > 1 {
          hash_text.unsafe_substring(start=1, end=hash_text.length())
        } else {
          ""
        }
        @core.ModuleRef::PinnedPath(path~, hash~)
      } else {
        result
      }
    }
    _ => result
  }
}

///|
fn AstParser::parse_module_ref_inner(
  self : AstParser,
) -> @core.ModuleRef raise ParseError {
  // Check for alias reference: @name
  if self.peek_kind() == name() && self.peek().text().has_prefix("@") {
    let tok = self.bump()
    let text = tok.text()
    let alias_name = text.unsafe_substring(start=1, end=text.length())
    return @core.ModuleRef::Alias(name=alias_name)
  }
  if self.peek_kind() == string_lit() {
    let tok = self.peek()
    raise ParseError::UnexpectedToken(
      expected="module path without quotes (e.g. ./vibe/prelude/string.vibe)",
      got=tok.text(),
      span=self.token_span(),
    )
  }
  if self.peek_kind() == hash_ref() {
    let hash_tok = self.bump()
    // Remove leading '#' from hash
    let hash_text = hash_tok.text()
    let hash = if hash_text.length() > 1 {
      hash_text.unsafe_substring(start=1, end=hash_text.length())
    } else {
      ""
    }
    @core.ModuleRef::Hash(hash~)
  } else if self.peek_kind() == slash() {
    let buf = StringBuilder::new()
    self.skip_trivia()
    while self.peek_kind() == slash() {
      let _ = self.bump()
      buf.write_char('/')
      self.skip_trivia()
    }
    if self.peek_kind() == name() {
      let seg = self.bump()
      buf.write_string(seg.text())
      self.skip_trivia()
    }
    while true {
      self.skip_trivia()
      if self.peek_kind() != dot() &&
        self.peek_kind() != dotdot() &&
        self.peek_kind() != slash() {
        break
      }
      if self.peek_kind() == dotdot() {
        let _ = self.bump()
        buf.write_string("..")
      } else if self.peek_kind() == dot() {
        let _ = self.bump()
        buf.write_char('.')
      } else {
        let _ = self.bump()
        buf.write_char('/')
      }
      self.skip_trivia()
      if self.peek_kind() == name() {
        let seg = self.bump()
        buf.write_string(seg.text())
        self.skip_trivia()
      }
    }
    @core.ModuleRef::Path(path=buf.to_string())
  } else if self.peek_kind() == name() {
    let tok = self.peek()
    let text = tok.text()
    if text.has_prefix("version@") && text.length() > 8 {
      let _ = self.bump()
      let name = text.unsafe_substring(start=8, end=text.length())
      @core.ModuleRef::Version(name~)
    } else if text.has_prefix("symbol@") && text.length() > 7 {
      let _ = self.bump()
      let name = text.unsafe_substring(start=7, end=text.length())
      @core.ModuleRef::Symbol(name~)
    } else if text.has_prefix("version:") && text.length() > 8 {
      let _ = self.bump()
      let name = text.unsafe_substring(start=8, end=text.length())
      @core.ModuleRef::Version(name~)
    } else if text.has_prefix("symbol:") && text.length() > 7 {
      let _ = self.bump()
      let name = text.unsafe_substring(start=7, end=text.length())
      @core.ModuleRef::Symbol(name~)
    } else {
      // Path: ./foo/bar.vibe or foo.vibe
      let buf = StringBuilder::new()
      // Handle leading ./ or ../
      self.skip_trivia()
      while self.peek_kind() == dot() || self.peek_kind() == dotdot() {
        if self.peek_kind() == dotdot() {
          let _ = self.bump()
          buf.write_string("..")
          self.skip_trivia()
        } else {
          let _ = self.bump()
          buf.write_char('.')
          self.skip_trivia()
          if self.peek_kind() == dot() {
            let _ = self.bump()
            buf.write_char('.')
            self.skip_trivia()
          }
        }
        if self.peek_kind() == slash() {
          let _ = self.bump()
          buf.write_char('/')
          self.skip_trivia()
        }
      }
      // Path segments
      self.skip_trivia()
      if self.peek_kind() == name() {
        let seg = self.bump()
        buf.write_string(seg.text())
        self.skip_trivia()
      }
      while true {
        self.skip_trivia()
        if self.peek_kind() != dot() &&
          self.peek_kind() != dotdot() &&
          self.peek_kind() != slash() {
          break
        }
        if self.peek_kind() == dotdot() {
          let _ = self.bump()
          buf.write_string("..")
        } else if self.peek_kind() == dot() {
          let _ = self.bump()
          buf.write_char('.')
        } else {
          let _ = self.bump()
          buf.write_char('/')
        }
        self.skip_trivia()
        if self.peek_kind() == name() {
          let seg = self.bump()
          buf.write_string(seg.text())
          self.skip_trivia()
        }
      }
      @core.ModuleRef::Path(path=buf.to_string())
    }
  } else {
    let tok = self.peek()
    if tok.kind() == dot() || tok.kind() == dotdot() {
      let buf = StringBuilder::new()
      self.skip_trivia()
      while self.peek_kind() == dot() || self.peek_kind() == dotdot() {
        if self.peek_kind() == dotdot() {
          let _ = self.bump()
          buf.write_string("..")
          self.skip_trivia()
        } else {
          let _ = self.bump()
          buf.write_char('.')
          self.skip_trivia()
          if self.peek_kind() == dot() {
            let _ = self.bump()
            buf.write_char('.')
            self.skip_trivia()
          }
        }
        if self.peek_kind() == slash() {
          let _ = self.bump()
          buf.write_char('/')
          self.skip_trivia()
        }
      }
      self.skip_trivia()
      if self.peek_kind() == name() {
        let seg = self.bump()
        buf.write_string(seg.text())
        self.skip_trivia()
      }
      while true {
        self.skip_trivia()
        if self.peek_kind() != dot() &&
          self.peek_kind() != dotdot() &&
          self.peek_kind() != slash() {
          break
        }
        if self.peek_kind() == dotdot() {
          let _ = self.bump()
          buf.write_string("..")
        } else if self.peek_kind() == dot() {
          let _ = self.bump()
          buf.write_char('.')
        } else {
          let _ = self.bump()
          buf.write_char('/')
        }
        self.skip_trivia()
        if self.peek_kind() == name() {
          let seg = self.bump()
          buf.write_string(seg.text())
          self.skip_trivia()
        }
      }
      @core.ModuleRef::Path(path=buf.to_string())
    } else {
      raise ParseError::UnexpectedToken(
        expected="path, hash, version ref, or symbol ref",
        got=tok.text(),
        span=self.token_span(),
      )
    }
  }
}

///|
fn AstParser::parse_export_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(export_kw(), "export")
  self.skip_trivia()
  if self.peek_kind() == enum_kw() {
    let enum_stmt = self.parse_enum_stmt()
    match enum_stmt {
      @core.Stmt::EnumDef(name~, params~, ctors~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="enum definition",
          got="other statement",
          span~,
        )
      }
    }
  } else if self.peek_kind() == name() && self.peek().text() == "suberror" {
    let suberror_stmt = self.parse_suberror_stmt()
    match suberror_stmt {
      @core.Stmt::EnumDef(name~, params~, ctors~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="suberror definition",
          got="other statement",
          span~,
        )
      }
    }
  } else if self.peek_kind() == name() && self.peek().text() == "effect" {
    let effect_stmt = self.parse_effect_stmt(false)
    match effect_stmt {
      @core.Stmt::EffectDef(name~, params~, ops~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::ExportEffectDef(name~, params~, ops~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="effect definition",
          got="other statement",
          span~,
        )
      }
    }
  } else if self.peek_kind() == struct_kw() {
    let struct_stmt = self.parse_struct_stmt()
    match struct_stmt {
      @core.Stmt::StructDef(name~, params~, fields~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::ExportStructDef(name~, params~, fields~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="struct definition",
          got="other statement",
          span~,
        )
      }
    }
  } else if self.peek_kind() == type_kw() {
    let type_stmt = self.parse_type_alias_stmt()
    match type_stmt {
      @core.Stmt::TypeAlias(name~, params~, target~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::ExportTypeAlias(name~, params~, target~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="type alias",
          got="other statement",
          span~,
        )
      }
    }
  } else if self.peek_kind() == let_kw() {
    let let_stmt = self.parse_let_stmt()
    match let_stmt {
      @core.Stmt::Let(rec~, name~, expr~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::ExportLet(rec~, name~, expr~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="let statement",
          got="other statement",
          span~,
        )
      }
    }
  } else if self.peek_kind() == name() &&
    self.peek().text() == "module" &&
    self.peek_non_trivia_ahead(1) == name() &&
    self.peek_non_trivia_ahead(2) == lbrace() {
    self.parse_module_stmt(true)
  } else if self.peek_kind() == trait_kw() ||
    (self.peek_kind() == name() && self.peek().text() == "open") {
    let mut open_impl = false
    if self.peek_kind() == name() && self.peek().text() == "open" {
      let _ = self.bump()
      self.skip_trivia()
      open_impl = true
    }
    if self.peek_kind() != trait_kw() {
      let span = self.span_from(start)
      raise ParseError::UnexpectedToken(
        expected="trait definition",
        got=self.peek().text(),
        span~,
      )
    }
    let trait_stmt = self.parse_trait_stmt()
    match trait_stmt {
      @core.Stmt::TraitDef(name~, supertraits~, methods~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::TraitDef(
          name~,
          supertraits~,
          methods~,
          open_impl~,
          exported=true,
          span~,
        )
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="trait definition",
          got="other statement",
          span~,
        )
      }
    }
  } else if self.peek_kind() == lbrace() {
    let _ = self.expect(lbrace(), "{")
    let names : Array[String] = []
    while self.peek_kind() != rbrace() {
      self.skip_trivia()
      names.push(self.parse_type_member_name("export name"))
      self.skip_trivia()
      if self.peek_kind() == comma() {
        let _ = self.bump()
      }
    }
    let _ = self.expect(rbrace(), "}")
    let _ = self.eat(semicolon())
    let span = self.span_from(start)
    @core.Stmt::Export(names~, span~)
  } else {
    let source = self.parse_module_ref()
    self.skip_trivia()
    if self.peek_kind() != lbrace() {
      raise ParseError::UnexpectedToken(
        expected="`{` after export source",
        got=self.peek().text(),
        span=self.token_span(),
      )
    }
    let items = self.parse_import_items("re-export item")
    let spec = @core.ImportSpec::{ items, }
    let _ = self.eat(semicolon())
    let span = self.span_from(start)
    @core.Stmt::ReExport(spec~, source~, span~)
  }
}
