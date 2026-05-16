///|
fn AstParser::parse_type(self : AstParser) -> @core.Type raise ParseError {
  self.parse_type_with_params({})
}

///|
fn AstParser::parse_type_with_params(
  self : AstParser,
  params : Map[String, Bool],
) -> @core.Type raise ParseError {
  self.skip_trivia()
  let tok = self.peek()
  let base_ty = match tok.kind() {
    k if k == name() => {
      let name_start = self.pos
      let _ = self.bump()
      let name_span = self.span_from(name_start)
      let raw_name = tok.text()
      // The lexer absorbs trailing `?` into identifier tokens (see
      // `is_ident_extra` in lexer.mbt) so that `y?=val` lexes as one name
      // token "y?" for labeled-optional argument syntax. In *type* position
      // the trailing `?` is the Option sugar (`T? === Option[T]`), so strip
      // any number of `?` from the tail and apply them as post-fix
      // `Option` wrappers after the base type is built.
      let mut q_suffix_count = 0
      let mut core_name = raw_name
      while core_name.length() > 0 && core_name[core_name.length() - 1] == '?' {
        core_name = core_name[0:core_name.length() - 1].to_owned()
        q_suffix_count = q_suffix_count + 1
      }
      let args = self.parse_type_args(params)
      let bare = if params.contains(core_name) {
        if !args.is_empty() {
          raise ParseError::UnexpectedToken(
            expected="type param",
            got=core_name,
            span=name_span,
          )
        }
        @core.Type::Param(core_name)
      } else {
        @core.Type::Named(name=core_name, args~)
      }
      let mut wrapped = bare
      let mut qi = 0
      while qi < q_suffix_count {
        wrapped = @core.Type::Named(name="Option", args=[wrapped])
        qi = qi + 1
      }
      wrapped
    }
    k if k == lparen() =>
      match self.try_parse_fn_type(params) {
        Some(t) => t
        None => self.parse_tuple_type(params)
      }
    k if k == lbracket() => self.parse_generic_fn_type(params)
    _ =>
      raise ParseError::UnexpectedToken(
        expected="type",
        got=tok.text(),
        span=self.token_span(),
      )
  }
  self.parse_type_post_suffixes(base_ty)
}

///|
/// Apply post-fix type constructors: `T[]` → `Array[T]`, `T?` → `Option[T]`.
/// Both suffixes may chain, e.g. `Int?[]` → `Array[Option[Int]]`.
fn AstParser::parse_type_post_suffixes(
  self : AstParser,
  base_ty : @core.Type,
) -> @core.Type raise ParseError {
  let mut out = base_ty
  let mut done = false
  while !done {
    self.skip_trivia()
    let k = self.peek_kind()
    if k == lbracket() && self.peek_non_trivia_ahead(1) == rbracket() {
      let _ = self.bump()
      let _ = self.expect(rbracket(), "]")
      out = @core.Type::Array(out)
    } else if k == question() {
      let _ = self.bump()
      out = @core.Type::Named(name="Option", args=[out])
    } else {
      done = true
    }
  }
  out
}

///|
fn AstParser::parse_array_type_suffixes(
  self : AstParser,
  base_ty : @core.Type,
) -> @core.Type raise ParseError {
  let mut out = base_ty
  while ({
          self.skip_trivia()
          self.peek_kind() == lbracket() &&
          self.peek_non_trivia_ahead(1) == rbracket()
        }) {
    let _ = self.bump()
    let _ = self.expect(rbracket(), "]")
    out = @core.Type::Array(out)
  }
  out
}

///|
fn effect_atom_from_name(name : String) -> @core.EffectAtom {
  if name.length() == 0 {
    @core.EffectAtom::Const(name)
  } else {
    let chars = name.to_array()
    let c = chars[0]
    if c >= 'a' && c <= 'z' {
      @core.EffectAtom::Var(name)
    } else {
      @core.EffectAtom::Const(name)
    }
  }
}

///|
fn AstParser::try_parse_fn_type(
  self : AstParser,
  params : Map[String, Bool],
) -> @core.Type? {
  let saved = self.pos
  let result : @core.Type? = try {
    let params_list = self.parse_fn_type_param_list(params)
    self.skip_trivia()
    if self.peek_kind() != thin_arrow() {
      raise ParseError::UnexpectedToken(
        expected="->",
        got=self.peek().text(),
        span=self.span_from(saved),
      )
    }
    let _ = self.bump()
    let ret = self.parse_type_with_params(params)
    let effects = self.parse_effect_list()
    Some(@core.Type::Func(params=params_list, ret~, effects~))
  } catch {
    _ => None
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
/// Parse generic function type: [T, U](T, U) -> (T, U)
fn AstParser::parse_generic_fn_type(
  self : AstParser,
  params : Map[String, Bool],
) -> @core.Type raise ParseError {
  // Parse type parameters [T, U: Trait, ...]
  let extended_params : Map[String, Bool] = {}
  for k, v in params {
    extended_params[k] = v
  }
  // Capture trait bounds for `parse_let_stmt` to re-attach to the Fn AST
  // (see `AstParser.last_generic_type_bounds`).
  let captured_bounds : Map[String, Array[String]] = {}
  let _ = self.expect(lbracket(), "[")
  self.skip_trivia()
  if self.peek_kind() != rbracket() {
    let name_tok = self.expect(name(), "type parameter name")
    extended_params[name_tok.text()] = true
    self.skip_trivia()
    // Optional bounds: T: Trait
    if self.peek_kind() == colon() {
      let _ = self.bump()
      self.skip_trivia()
      captured_bounds[name_tok.text()] = self.parse_trait_bounds()
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
      extended_params[name_tok.text()] = true
      self.skip_trivia()
      if self.peek_kind() == colon() {
        let _ = self.bump()
        self.skip_trivia()
        captured_bounds[name_tok.text()] = self.parse_trait_bounds()
      }
    }
  }
  self.last_generic_type_bounds = captured_bounds
  let _ = self.expect(rbracket(), "]")
  self.skip_trivia()
  // Now parse (params) -> ret with extended param scope
  match self.try_parse_fn_type(extended_params) {
    Some(t) => t
    None =>
      raise ParseError::UnexpectedToken(
        expected="function type after type parameters",
        got=self.peek().text(),
        span=self.token_span(),
      )
  }
}

///|
fn AstParser::parse_tuple_type(
  self : AstParser,
  params : Map[String, Bool],
) -> @core.Type raise ParseError {
  let _ = self.expect(lparen(), "(")
  let first = self.parse_type_with_params(params)
  self.skip_trivia()
  if self.peek_kind() == comma() {
    let items : Array[@core.Type] = []
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
      items.push(self.parse_type_with_params(params))
    }
    let _ = self.expect(rparen(), ")")
    @core.Type::Tuple(items)
  } else {
    let _ = self.expect(rparen(), ")")
    first
  }
}

///|
fn AstParser::parse_type_args(
  self : AstParser,
  params : Map[String, Bool],
) -> Array[@core.Type] raise ParseError {
  let args : Array[@core.Type] = []
  self.skip_trivia()
  if self.peek_kind() == lbracket() {
    // Keep empty `[]` for postfix array suffix parsing.
    if self.peek_non_trivia_ahead(1) == rbracket() {
      return args
    }
    let _ = self.bump()
    self.skip_trivia()
    if self.peek_kind() != rbracket() {
      args.push(self.parse_type_with_params(params))
      while ({
              self.skip_trivia()
              self.peek_kind() == comma()
            }) {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rbracket() {
          break
        }
        args.push(self.parse_type_with_params(params))
      }
    }
    let _ = self.expect(rbracket(), "]")
  }
  args
}

///|
fn AstParser::parse_pattern(self : AstParser) -> @core.Pat raise ParseError {
  self.skip_trivia()
  let start = self.pos
  let tok = self.peek()
  match tok.kind() {
    k if k == lparen() => self.parse_tuple_pattern()
    k if k == record_kw() => self.parse_record_pattern()
    k if k == int_lit() => {
      let _ = self.bump()
      let span = self.span_from(start)
      let value = parse_int_literal_token(tok, span)
      @core.Pat::Int(value~, span~)
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
        @core.Pat::Float(value=Float::from_double(v), span~)
      } else {
        @core.Pat::Double(value=v, span~)
      }
    }
    k if k == bool_lit() => {
      let _ = self.bump()
      if tok.text() == "true" {
        let span = self.span_from(start)
        @core.Pat::Bool(value=true, span~)
      } else if tok.text() == "false" {
        let span = self.span_from(start)
        @core.Pat::Bool(value=false, span~)
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
      @core.Pat::String(value=tok.text(), span~)
    }
    k if k == char_lit() => {
      let _ = self.bump()
      let chars = tok.text().to_array()
      if chars.length() == 1 {
        let span = self.span_from(start)
        @core.Pat::Char(value=chars[0], span~)
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
      if tok.text() == "_" {
        let span = self.span_from(start)
        @core.Pat::Wildcard(span~)
      } else if @core.is_ctor_name(tok.text()) {
        self.skip_trivia()
        // Check for struct pattern: Name::{ x, y } or qualified ctor: Name::Ctor(args)
        if self.peek_kind() == double_colon() {
          let _ = self.bump() // consume ::
          self.skip_trivia()
          if self.peek_kind() == lbrace() {
            // Struct pattern: Name::{ x, y }
            let _ = self.bump() // consume {
            let fields = self.parse_struct_pat_fields()
            let _ = self.expect(rbrace(), "}")
            let span = self.span_from(start)
            @core.Pat::Struct(name=tok.text(), fields~, span~)
          } else if is_name_like(self.peek_kind()) {
            // Qualified enum ctor: Enum::Ctor or Enum::Ctor(args)
            let ctor_tok = self.bump()
            let qualified = tok.text() + "::" + ctor_tok.text()
            let args : Array[@core.Pat] = []
            self.skip_trivia()
            if self.peek_kind() == lparen() {
              let _ = self.bump()
              self.skip_trivia()
              if self.peek_kind() != rparen() {
                args.push(self.parse_pattern())
                while ({
                        self.skip_trivia()
                        self.peek_kind() == comma()
                      }) {
                  let _ = self.bump()
                  args.push(self.parse_pattern())
                }
              }
              let _ = self.expect(rparen(), ")")
            }
            let span = self.span_from(start)
            @core.Pat::Ctor(name=qualified, args~, span~)
          } else {
            raise ParseError::UnexpectedToken(
              expected="struct pattern or qualified constructor",
              got=self.peek().text(),
              span=self.token_span(),
            )
          }
        } else {
          // Enum constructor pattern: Name(args)
          let args : Array[@core.Pat] = []
          if self.peek_kind() == lparen() {
            let _ = self.bump()
            self.skip_trivia()
            if self.peek_kind() != rparen() {
              args.push(self.parse_pattern())
              while ({
                      self.skip_trivia()
                      self.peek_kind() == comma()
                    }) {
                let _ = self.bump()
                args.push(self.parse_pattern())
              }
            }
            let _ = self.expect(rparen(), ")")
          }
          let span = self.span_from(start)
          @core.Pat::Ctor(name=tok.text(), args~, span~)
        }
      } else {
        let span = self.span_from(start)
        @core.Pat::Bind(name=tok.text(), span~)
      }
    }
    _ =>
      raise ParseError::UnexpectedToken(
        expected="pattern",
        got=tok.text(),
        span=self.token_span(),
      )
  }
}

///|
fn AstParser::parse_tuple_pattern(
  self : AstParser,
) -> @core.Pat raise ParseError {
  let start = self.pos
  let _ = self.expect(lparen(), "(")
  let first = self.parse_pattern()
  self.skip_trivia()
  if self.peek_kind() == comma() {
    let items : Array[@core.Pat] = []
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
      items.push(self.parse_pattern())
    }
    let _ = self.expect(rparen(), ")")
    let span = self.span_from(start)
    @core.Pat::Tuple(items~, span~)
  } else {
    let _ = self.expect(rparen(), ")")
    first
  }
}

///|
fn AstParser::parse_record_pattern(
  self : AstParser,
) -> @core.Pat raise ParseError {
  let start = self.pos
  let _ = self.expect(record_kw(), "record")
  let _ = self.expect(lbrace(), "{")
  let fields : Array[@core.RecordFieldPat] = []
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
    let pat = if self.peek_kind() == colon() {
      let _ = self.bump()
      self.parse_pattern()
    } else {
      let bind_span = self.span_from(field_start)
      @core.Pat::Bind(name=name_tok.text(), span=bind_span)
    }
    let field_span = self.span_from(field_start)
    fields.push(@core.RecordFieldPat::{
      name: name_tok.text(),
      pat,
      span: field_span,
    })
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())
  }
  let _ = self.expect(rbrace(), "}")
  let span = self.span_from(start)
  @core.Pat::Record(fields~, span~)
}

///|
fn AstParser::parse_struct_pat_fields(
  self : AstParser,
) -> Array[@core.RecordFieldPat] raise ParseError {
  let fields : Array[@core.RecordFieldPat] = []
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
    let pat = if self.peek_kind() == colon() {
      let _ = self.bump()
      self.parse_pattern()
    } else {
      let bind_span = self.span_from(field_start)
      @core.Pat::Bind(name=name_tok.text(), span=bind_span)
    }
    let field_span = self.span_from(field_start)
    fields.push(@core.RecordFieldPat::{
      name: name_tok.text(),
      pat,
      span: field_span,
    })
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())
  }
  fields
}
