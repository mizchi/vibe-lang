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
      let name = tok.text()
      let args = self.parse_type_args(params)
      if params.contains(name) {
        if not(args.is_empty()) {
          raise ParseError::UnexpectedToken(
            expected="type param",
            got=name,
            span=name_span,
          )
        }
        @core.Type::Param(name)
      } else {
        @core.Type::Named(name~, args~)
      }
    }
    k if k == lparen() =>
      match self.try_parse_fn_type(params) {
        Some(t) => t
        None => self.parse_tuple_type(params)
      }
    _ =>
      raise ParseError::UnexpectedToken(
        expected="type",
        got=tok.text(),
        span=self.token_span(),
      )
  }
  self.parse_array_type_suffixes(base_ty)
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
          raw = text[0:len - 1].to_string()
        }
      }
      let parsed : Result[Double, @strconv.StrConvError] = try? @strconv.parse_double(
        raw,
      )
      match parsed {
        Ok(v) => {
          let span = self.span_from(start)
          if is_float {
            @core.Pat::Float(value=Float::from_double(v), span~)
          } else {
            @core.Pat::Double(value=v, span~)
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
        // Check for struct pattern: Name::{ x, y }
        if self.peek_kind() == double_colon() {
          let _ = self.bump() // consume ::
          self.skip_trivia()
          let _ = self.expect(lbrace(), "{")
          let fields = self.parse_struct_pat_fields()
          let _ = self.expect(rbrace(), "}")
          let span = self.span_from(start)
          @core.Pat::Struct(name=tok.text(), fields~, span~)
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
