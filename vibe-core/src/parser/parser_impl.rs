use super::lexer::{Lexer, Token};
use crate::{
    Constructor, DoStatement, Expr, HandlerCase, Ident, Literal, Pattern, Span, Type,
    TypeDefinition, XsError,
};

pub struct Parser<'a> {
    lexer: Lexer<'a>,
    current_token: Option<(Token, Span)>,
    peek_token: Option<(Token, Span)>,
}

impl<'a> Parser<'a> {
    pub fn new(input: &'a str) -> Result<Self, XsError> {
        let mut lexer = Lexer::new(input);
        let current_token = lexer.next_token()?;
        let peek_token = lexer.next_token()?;

        Ok(Parser {
            lexer,
            current_token,
            peek_token,
        })
    }

    pub fn parse(&mut self) -> Result<Expr, XsError> {
        self.parse_module()
    }

    fn parse_module(&mut self) -> Result<Expr, XsError> {
        let mut exprs = Vec::new();

        while self.current_token.is_some() {
            // Skip newlines at module level
            if matches!(self.current_token, Some((Token::Newline, _))) {
                self.advance()?;
                continue;
            }

            let expr = self.parse_top_level()?;
            exprs.push(expr);

            // Consume optional semicolon or newline
            if matches!(
                self.current_token,
                Some((Token::Semicolon, _)) | Some((Token::Newline, _))
            ) {
                self.advance()?;
            }
        }

        if exprs.is_empty() {
            Ok(Expr::Literal(Literal::Int(0), Span::new(0, 0)))
        } else if exprs.len() == 1 {
            Ok(exprs.into_iter().next().unwrap())
        } else {
            Ok(Expr::Block {
                exprs,
                span: Span::new(0, self.position()),
            })
        }
    }

    fn parse_top_level(&mut self) -> Result<Expr, XsError> {
        match &self.current_token {
            Some((Token::Let, _)) => self.parse_let_binding(),
            Some((Token::LetRec, _)) => self.parse_letrec_binding(),
            Some((Token::Type, _)) => self.parse_type_definition(),
            Some((Token::Data, _)) => self.parse_data_definition(),
            Some((Token::Effect, _)) => self.parse_effect_definition(),
            Some((Token::Import, _)) => self.parse_import(),
            Some((Token::Module, _)) => self.parse_module_definition(),
            Some((Token::Symbol(name), span)) => {
                // Look ahead to determine if this is a function definition
                let start = span.start;
                let name = name.clone();
                let name_span = span.clone();
                self.advance()?; // consume the identifier

                // Check if followed by parameters or '=' (function definition)
                if matches!(self.current_token, Some((Token::Symbol(_), _)))
                    || matches!(self.current_token, Some((Token::Equals, _)))
                    || matches!(self.current_token, Some((Token::Colon, _)))
                {
                    // This is a function definition
                    self.parse_function_definition(name, start)
                } else if matches!(self.current_token, Some((Token::Dot, _))) {
                    // This is a namespace access like String.concat
                    // Put the identifier back and parse as expression
                    let mut expr = Expr::Ident(Ident(name), name_span);

                    // Handle record access
                    while matches!(self.current_token, Some((Token::Dot, _))) {
                        self.advance()?;
                        let field = self.parse_identifier()?;
                        expr = Expr::RecordAccess {
                            record: Box::new(expr),
                            field: Ident(field),
                            span: Span::new(start, self.position()),
                        };
                    }

                    // Now handle function application if any
                    if self.is_application_start() {
                        self.parse_remaining_application(expr)
                    } else {
                        Ok(expr)
                    }
                } else {
                    // Not a function definition, just an identifier expression
                    // Return the identifier and let parse_module handle the rest
                    Ok(Expr::Ident(Ident(name), Span::new(start, self.position())))
                }
            }
            _ => self.parse_expression(),
        }
    }

    fn parse_let_binding(&mut self) -> Result<Expr, XsError> {
        let start_span = self.expect_token(Token::Let)?;
        let name = self.parse_identifier()?;

        // Check for type annotation on the binding
        let type_ann = if matches!(self.current_token, Some((Token::Colon, _))) {
            self.advance()?; // consume ':'
            Some(self.parse_type_expression()?)
        } else {
            None
        };

        // Check for function syntax: let name args = body
        if !matches!(self.current_token, Some((Token::Equals, _))) {
            // Function definition
            let mut params = vec![];

            // Parse parameters with new syntax: name:Type or name?:Type?
            while !matches!(self.current_token, Some((Token::Equals, _)))
                && !matches!(self.current_token, Some((Token::Arrow, _)))
            {
                let param_name = self.parse_identifier()?;

                // Check for optional parameter marker '?'
                let is_optional = if let Some((Token::Symbol(s), _)) = &self.current_token {
                    if s == "?" {
                        self.advance()?; // consume '?'
                        true
                    } else {
                        false
                    }
                } else {
                    false
                };

                // Check for type annotation with ':'
                let param_type = if matches!(self.current_token, Some((Token::Colon, _))) {
                    self.advance()?; // consume ':'
                    let base_type = self.parse_type_expression()?;

                    // Check for optional type marker '?'
                    let final_type = if let Some((Token::Symbol(s), _)) = &self.current_token {
                        if s == "?" {
                            self.advance()?; // consume '?'
                                             // Wrap in Option type
                            Type::UserDefined {
                                name: "Option".to_string(),
                                type_params: vec![base_type],
                            }
                        } else if is_optional {
                            // If parameter is optional but type doesn't have ?, wrap it in Option
                            Type::UserDefined {
                                name: "Option".to_string(),
                                type_params: vec![base_type],
                            }
                        } else {
                            base_type
                        }
                    } else if is_optional {
                        // If parameter is optional but type doesn't have ?, wrap it in Option
                        Type::UserDefined {
                            name: "Option".to_string(),
                            type_params: vec![base_type],
                        }
                    } else {
                        base_type
                    };

                    Some(final_type)
                } else {
                    None
                };

                params.push((Ident(param_name), param_type, is_optional));
            }

            // Parse optional return type annotation with -> syntax
            let (return_type, effects) = if matches!(self.current_token, Some((Token::Arrow, _))) {
                self.advance()?; // consume '->'

                // Check for effect annotation <Effect1, Effect2>
                let effects = if matches!(self.current_token, Some((Token::LessThan, _))) {
                    self.advance()?; // consume '<'
                    let mut effect_list = vec![];

                    // Parse effect list
                    loop {
                        let effect_name = self.parse_identifier()?;
                        effect_list.push(effect_name);

                        if matches!(self.current_token, Some((Token::Comma, _))) {
                            self.advance()?; // consume ','
                        } else {
                            break;
                        }
                    }

                    self.expect_token(Token::GreaterThan)?; // consume '>'
                    Some(effect_list)
                } else {
                    None
                };

                // Parse return type
                let return_type = Some(self.parse_type_expression()?);
                (return_type, effects)
            } else {
                (None, None)
            };

            // Validate parameter ordering: optional parameters must come after required ones
            let mut found_optional = false;
            for (_, _, is_optional) in &params {
                if found_optional && !is_optional {
                    return Err(XsError::ParseError(
                        self.position(),
                        "Optional parameters must come after all required parameters".to_string(),
                    ));
                }
                if *is_optional {
                    found_optional = true;
                }
            }

            self.expect_token(Token::Equals)?;
            self.skip_newlines(); // Allow newlines after '='
            let body = self.parse_expression()?;

            // Convert effects list to EffectRow
            let effect_row = if let Some(effect_names) = effects {
                use crate::effects::{Effect, EffectRow, EffectSet};
                let mut effects = Vec::new();
                for effect_name in effect_names {
                    // Map effect names to known effects
                    let effect = match effect_name.as_str() {
                        "IO" => Effect::IO,
                        "State" => Effect::State,
                        "Error" => Effect::Error,
                        "Async" => Effect::Async,
                        "Network" => Effect::Network,
                        "FileSystem" => Effect::FileSystem,
                        "Random" => Effect::Random,
                        "Time" => Effect::Time,
                        "Log" => Effect::Log,
                        "Pure" => Effect::Pure,
                        _ => {
                            // For unknown effects, we could either error or default to IO
                            // For now, let's error
                            return Err(XsError::ParseError(
                                self.position(),
                                format!("Unknown effect: {}", effect_name),
                            ));
                        }
                    };
                    effects.push(effect);
                }
                Some(EffectRow::Concrete(EffectSet::from_effects(effects)))
            } else {
                None
            };

            // Create FunctionDef expression
            let func_params: Vec<crate::FunctionParam> = params
                .into_iter()
                .map(|(name, typ, is_optional)| crate::FunctionParam {
                    name,
                    typ,
                    is_optional,
                })
                .collect();

            let function_def = Expr::FunctionDef {
                name: Ident(name.clone()),
                params: func_params,
                return_type,
                effects: effect_row,
                body: Box::new(body),
                span: Span::new(start_span.start, self.position()),
            };

            // Check for 'in' keyword
            if matches!(self.current_token, Some((Token::In, _))) {
                self.advance()?;
                self.skip_newlines(); // Allow newlines after 'in'
                let in_body = self.parse_expression()?;
                Ok(Expr::LetIn {
                    name: Ident(name),
                    type_ann,
                    value: Box::new(function_def),
                    body: Box::new(in_body),
                    span: Span::new(start_span.start, self.position()),
                })
            } else {
                Ok(Expr::Let {
                    name: Ident(name),
                    type_ann,
                    value: Box::new(function_def),
                    span: Span::new(start_span.start, self.position()),
                })
            }
        } else {
            // Simple let binding
            self.expect_token(Token::Equals)?;
            self.skip_newlines(); // Allow newlines after '='
            let value = self.parse_expression()?;

            // Check for 'in' keyword
            if matches!(self.current_token, Some((Token::In, _))) {
                self.advance()?;
                self.skip_newlines(); // Allow newlines after 'in'
                let body = self.parse_expression()?;
                Ok(Expr::LetIn {
                    name: Ident(name),
                    type_ann,
                    value: Box::new(value),
                    body: Box::new(body),
                    span: Span::new(start_span.start, self.position()),
                })
            } else {
                Ok(Expr::Let {
                    name: Ident(name),
                    type_ann,
                    value: Box::new(value),
                    span: Span::new(start_span.start, self.position()),
                })
            }
        }
    }

    fn parse_letrec_binding(&mut self) -> Result<Expr, XsError> {
        let start_span = self.expect_token(Token::LetRec)?;
        let name = self.parse_identifier()?;

        // Check for function syntax: letrec name args = body
        if !matches!(self.current_token, Some((Token::Equals, _))) {
            // Function definition
            let mut params = vec![];

            // Parse parameters
            while !matches!(self.current_token, Some((Token::Equals, _))) {
                params.push((Ident(self.parse_identifier()?), None));
            }

            self.expect_token(Token::Equals)?;
            self.skip_newlines(); // Allow newlines after '='
            let body = self.parse_expression()?;

            // Convert to nested lambdas
            let lambda = params
                .into_iter()
                .rev()
                .fold(body, |acc, param| Expr::Lambda {
                    params: vec![param],
                    body: Box::new(acc),
                    span: Span::new(start_span.start, self.position()),
                });

            // Check for 'in' keyword
            if matches!(self.current_token, Some((Token::In, _))) {
                self.advance()?;
                self.skip_newlines(); // Allow newlines after 'in'
                let in_body = self.parse_expression()?;
                Ok(Expr::LetRecIn {
                    name: Ident(name),
                    type_ann: None,
                    value: Box::new(lambda),
                    body: Box::new(in_body),
                    span: Span::new(start_span.start, self.position()),
                })
            } else {
                Ok(Expr::LetRec {
                    name: Ident(name),
                    type_ann: None,
                    value: Box::new(lambda),
                    span: Span::new(start_span.start, self.position()),
                })
            }
        } else {
            // Simple letrec binding
            self.expect_token(Token::Equals)?;
            self.skip_newlines(); // Allow newlines after '='
            let value = self.parse_expression()?;

            // Check for 'in' keyword
            if matches!(self.current_token, Some((Token::In, _))) {
                self.advance()?;
                self.skip_newlines(); // Allow newlines after 'in'
                let body = self.parse_expression()?;
                Ok(Expr::LetRecIn {
                    name: Ident(name),
                    type_ann: None,
                    value: Box::new(value),
                    body: Box::new(body),
                    span: Span::new(start_span.start, self.position()),
                })
            } else {
                Ok(Expr::LetRec {
                    name: Ident(name),
                    type_ann: None,
                    value: Box::new(value),
                    span: Span::new(start_span.start, self.position()),
                })
            }
        }
    }

    fn parse_expression(&mut self) -> Result<Expr, XsError> {
        self.parse_infix()
    }

    fn parse_infix(&mut self) -> Result<Expr, XsError> {
        let mut left = self.parse_pipeline()?;

        // Handle infix operators
        while self.is_infix_operator() {
            let op_span = self.current_span();
            let op = self.parse_infix_operator()?;

            // Skip newlines after operator
            self.skip_newlines();

            let right = self.parse_pipeline()?;

            // First apply operator to left operand
            let partial = Expr::Apply {
                func: Box::new(Expr::Ident(Ident(op), op_span.clone())),
                args: vec![left],
                span: op_span.clone(),
            };

            // Then apply the result to right operand
            left = Expr::Apply {
                func: Box::new(partial),
                args: vec![right],
                span: Span::new(op_span.start, self.position()),
            };
        }

        Ok(left)
    }

    fn parse_infix_operator(&mut self) -> Result<String, XsError> {
        match &self.current_token {
            Some((Token::Symbol(s), _)) => {
                let op = s.clone();
                self.advance()?;
                Ok(op)
            }
            Some((Token::Equals, _)) => {
                self.advance()?;
                Ok("=".to_string())
            }
            Some((Token::EqualsEquals, _)) => {
                self.advance()?;
                Ok("==".to_string())
            }
            Some((Token::DoubleColon, _)) => {
                self.advance()?;
                Ok("::".to_string())
            }
            Some((Token::LessThan, _)) => {
                self.advance()?;
                Ok("<".to_string())
            }
            Some((Token::GreaterThan, _)) => {
                self.advance()?;
                Ok(">".to_string())
            }
            _ => Err(XsError::ParseError(
                self.position(),
                format!("Expected infix operator, got {:?}", self.current_token),
            )),
        }
    }

    fn parse_pipeline(&mut self) -> Result<Expr, XsError> {
        let mut left = self.parse_application()?;

        while matches!(
            self.current_token,
            Some((Token::Pipe, _)) | Some((Token::PipeForward, _))
        ) {
            let op_span = self.current_span();
            self.advance()?;
            let right = self.parse_application()?;

            left = Expr::Pipeline {
                expr: Box::new(left),
                func: Box::new(right),
                span: Span::new(op_span.start, self.position()),
            };
        }

        Ok(left)
    }

    fn parse_application(&mut self) -> Result<Expr, XsError> {
        let mut expr = self.parse_primary()?;

        // Loop to handle interleaved record access and function application
        loop {
            // Handle record access first (higher precedence)
            if matches!(self.current_token, Some((Token::Dot, _))) {
                self.advance()?;
                let field = self.parse_identifier()?;
                let span_start = expr.span().start;
                expr = Expr::RecordAccess {
                    record: Box::new(expr),
                    field: Ident(field),
                    span: Span::new(span_start, self.position()),
                };
            }
            // Then handle function application
            else if self.is_application_start() {
                let arg = self.parse_primary()?;
                let span_start = expr.span().start;
                expr = Expr::Apply {
                    func: Box::new(expr),
                    args: vec![arg],
                    span: Span::new(span_start, self.position()),
                };
            }
            // No more applications or accesses
            else {
                break;
            }
        }

        Ok(expr)
    }

    fn parse_primary(&mut self) -> Result<Expr, XsError> {
        match &self.current_token {
            Some((Token::Int(n), span)) => {
                let val = *n;
                let span = span.clone();
                self.advance()?;
                Ok(Expr::Literal(Literal::Int(val), span))
            }
            Some((Token::Float(f), span)) => {
                let val = *f;
                let span = span.clone();
                self.advance()?;
                Ok(Expr::Literal(Literal::Float(val.into()), span))
            }
            Some((Token::Bool(b), span)) => {
                let val = *b;
                let span = span.clone();
                self.advance()?;
                Ok(Expr::Literal(Literal::Bool(val), span))
            }
            Some((Token::String(s), span)) => {
                let val = s.clone();
                let span = span.clone();
                self.advance()?;
                Ok(Expr::Literal(Literal::String(val), span))
            }
            Some((Token::Symbol(s), span)) => {
                let val = s.clone();
                let span = span.clone();
                self.advance()?;

                // Check for record literal syntax
                if val.chars().all(|c| c.is_alphabetic() || c == '_') {
                    Ok(Expr::Ident(Ident(val), span))
                } else {
                    // It's an operator
                    Ok(Expr::Ident(Ident(val), span))
                }
            }
            Some((Token::LeftParen, span)) => {
                let start_span = span.clone();
                self.advance()?;
                self.skip_newlines(); // Allow newlines after '('

                // Check for unit expression ()
                if matches!(self.current_token, Some((Token::RightParen, _))) {
                    self.advance()?;
                    // Return unit literal (empty record)
                    Ok(Expr::RecordLiteral {
                        fields: vec![],
                        span: start_span,
                    })
                } else {
                    let expr = self.parse_expression()?;
                    self.skip_newlines(); // Allow newlines before ')'
                    self.expect_token(Token::RightParen)?;
                    Ok(expr)
                }
            }
            Some((Token::LeftBrace, span)) => {
                let start = span.start;
                self.parse_block_or_record(start)
            }
            Some((Token::LeftBracket, span)) => {
                let start = span.start;
                self.parse_list(start)
            }
            Some((Token::Fn, span)) => {
                let start = span.start;
                self.parse_lambda(start)
            }
            Some((Token::Backslash, span)) => {
                let start = span.start;
                self.parse_lambda(start)
            }
            Some((Token::If, span)) => {
                let start = span.start;
                self.parse_if(start)
            }
            Some((Token::Match, span)) => {
                let start = span.start;
                self.parse_match(start)
            }
            Some((Token::Let, _)) => self.parse_let_binding(),
            Some((Token::LetRec, _)) => self.parse_letrec_binding(),
            Some((Token::Perform, span)) => {
                let start = span.start;
                self.parse_perform(start)
            }
            Some((Token::At, span)) => {
                let span = span.clone();
                self.advance()?;
                // Parse hole with optional type annotation
                let (name, type_hint) = if matches!(self.current_token, Some((Token::Colon, _))) {
                    self.advance()?;
                    let type_expr = self.parse_type_expression()?;
                    (None, Some(type_expr))
                } else {
                    (Some("hole".to_string()), None)
                };
                Ok(Expr::Hole {
                    name,
                    type_hint,
                    span,
                })
            }
            Some((Token::With, span)) => {
                let start = span.start;
                self.parse_with_handler(start)
            }
            Some((Token::Do, span)) => {
                let start = span.start;
                self.parse_do_block(start)
            }
            Some((Token::Handler, span)) => {
                let start = span.start;
                self.parse_handler(start)
            }
            Some((Token::Handle, span)) => {
                let start = span.start;
                self.parse_handle_expr(start)
            }
            Some((Token::Hash, span)) => {
                let start = span.start;
                self.advance()?;
                // Parse hash reference: #abc123...
                // The hash value should be an identifier (alphanumeric string)
                if let Some((Token::Symbol(hash), _)) = &self.current_token {
                    let hash_str = hash.clone();
                    self.advance()?;
                    Ok(Expr::HashRef {
                        hash: hash_str,
                        span: Span::new(start, self.position()),
                    })
                } else if let Some((Token::Int(n), _)) = &self.current_token {
                    // Handle cases where hash starts with numbers
                    let hash_str = n.to_string();
                    self.advance()?;
                    Ok(Expr::HashRef {
                        hash: hash_str,
                        span: Span::new(start, self.position()),
                    })
                } else {
                    Err(XsError::ParseError(
                        self.position(),
                        "Expected hash value after #".to_string(),
                    ))
                }
            }
            _ => Err(XsError::ParseError(
                self.position(),
                format!("Unexpected token: {:?}", self.current_token),
            )),
        }
    }

    fn parse_block_or_record(&mut self, start: usize) -> Result<Expr, XsError> {
        self.expect_token(Token::LeftBrace)?;
        self.skip_newlines(); // Allow newlines after '{'

        // Peek ahead to determine if it's a record or block
        if self.is_record_syntax() {
            self.parse_record_literal(start)
        } else {
            self.parse_block(start)
        }
    }

    fn is_record_syntax(&self) -> bool {
        // Check if next tokens look like "field: value"
        matches!(self.current_token, Some((Token::Symbol(_), _)))
            && matches!(self.peek_token, Some((Token::Colon, _)))
    }

    fn parse_record_literal(&mut self, start: usize) -> Result<Expr, XsError> {
        let mut fields = Vec::new();

        while !matches!(self.current_token, Some((Token::RightBrace, _))) {
            // Skip newlines
            if matches!(self.current_token, Some((Token::Newline, _))) {
                self.advance()?;
                continue;
            }

            let field_name = self.parse_identifier()?;
            self.expect_token(Token::Colon)?;
            let value = self.parse_expression()?;
            fields.push((Ident(field_name), value));

            if matches!(self.current_token, Some((Token::Comma, _))) {
                self.advance()?;
            } else if !matches!(self.current_token, Some((Token::RightBrace, _))) {
                break;
            }
        }

        self.expect_token(Token::RightBrace)?;
        Ok(Expr::RecordLiteral {
            fields,
            span: Span::new(start, self.position()),
        })
    }

    fn parse_block(&mut self, start: usize) -> Result<Expr, XsError> {
        let mut exprs = Vec::new();

        while !matches!(self.current_token, Some((Token::RightBrace, _))) {
            // Skip newlines in blocks
            if matches!(self.current_token, Some((Token::Newline, _))) {
                self.advance()?;
                continue;
            }

            let expr = self.parse_expression()?;
            exprs.push(expr);

            // Consume optional semicolon or newline
            if matches!(
                self.current_token,
                Some((Token::Semicolon, _)) | Some((Token::Newline, _))
            ) {
                self.advance()?;
            }
        }

        self.expect_token(Token::RightBrace)?;

        if exprs.is_empty() {
            Ok(Expr::Literal(
                Literal::Int(0),
                Span::new(start, self.position()),
            ))
        } else if exprs.len() == 1 {
            Ok(exprs.into_iter().next().unwrap())
        } else {
            Ok(Expr::Block {
                exprs,
                span: Span::new(start, self.position()),
            })
        }
    }

    fn parse_list(&mut self, start: usize) -> Result<Expr, XsError> {
        self.expect_token(Token::LeftBracket)?;
        let mut elements = Vec::new();

        while !matches!(self.current_token, Some((Token::RightBracket, _))) {
            elements.push(self.parse_expression()?);

            if matches!(self.current_token, Some((Token::Comma, _))) {
                self.advance()?;
            } else if !matches!(self.current_token, Some((Token::RightBracket, _))) {
                return Err(XsError::ParseError(
                    self.position(),
                    "Expected ',' or ']' in list".to_string(),
                ));
            }
        }

        self.expect_token(Token::RightBracket)?;
        Ok(Expr::List(elements, Span::new(start, self.position())))
    }

    fn parse_lambda(&mut self, start: usize) -> Result<Expr, XsError> {
        // Accept either 'fn' or '\'
        match &self.current_token {
            Some((Token::Fn, _)) => self.advance()?,
            Some((Token::Backslash, _)) => self.advance()?,
            _ => {
                return Err(XsError::ParseError(
                    self.position(),
                    "Expected 'fn' or '\\'".to_string(),
                ))
            }
        }

        // Parse parameters with new syntax: fn x: Type -> y: Type = body
        let mut params = Vec::new();

        // Parse parameters until we hit '=' or '{'
        loop {
            // Check if we've reached the body
            if matches!(self.current_token, Some((Token::Equals, _)))
                || matches!(self.current_token, Some((Token::LeftBrace, _)))
            {
                break;
            }

            // Parse parameter name
            let param_name = self.parse_identifier()?;

            // Parse optional type annotation
            let type_ann = if matches!(self.current_token, Some((Token::Colon, _))) {
                self.advance()?;
                Some(self.parse_type_expression()?)
            } else {
                None
            };

            params.push((Ident(param_name), type_ann));

            // Check for '->' between parameters
            if matches!(self.current_token, Some((Token::Arrow, _))) {
                self.advance()?;
                // Continue parsing more parameters
            } else {
                // No more parameters
                break;
            }
        }

        // Expect '=' or '{' before body
        let body = if matches!(self.current_token, Some((Token::Equals, _))) {
            self.advance()?;

            // Skip newlines after equals
            while matches!(self.current_token, Some((Token::Newline, _))) {
                self.advance()?;
            }

            self.parse_expression()?
        } else if matches!(self.current_token, Some((Token::LeftBrace, _))) {
            self.parse_block_or_record(self.position())?
        } else {
            return Err(XsError::ParseError(
                self.position(),
                "Expected '=' or '{' after function parameters".to_string(),
            ));
        };

        // Create nested lambdas for multiple parameters
        let lambda = params
            .into_iter()
            .rev()
            .fold(body, |acc, param| Expr::Lambda {
                params: vec![param],
                body: Box::new(acc),
                span: Span::new(start, self.position()),
            });

        Ok(lambda)
    }

    fn parse_if(&mut self, start: usize) -> Result<Expr, XsError> {
        self.expect_token(Token::If)?;

        // Parse condition as a full expression
        let condition = self.parse_expression()?;

        // Expect block for then branch
        if !matches!(self.current_token, Some((Token::LeftBrace, _))) {
            return Err(XsError::ParseError(
                self.position(),
                "Expected '{' after if condition".to_string(),
            ));
        }

        let then_start = self.position();
        let then_expr = self.parse_block_or_record(then_start)?;

        // Check if there's an else branch
        let else_expr = if matches!(self.current_token, Some((Token::Else, _))) {
            self.advance()?; // consume 'else'

            // Else branch must also be a block
            if !matches!(self.current_token, Some((Token::LeftBrace, _))) {
                return Err(XsError::ParseError(
                    self.position(),
                    "Expected '{' after else".to_string(),
                ));
            }

            let else_start = self.position();
            self.parse_block_or_record(else_start)?
        } else {
            // No else branch - return unit (empty record)
            Expr::RecordLiteral {
                fields: vec![],
                span: Span::new(self.position(), self.position()),
            }
        };

        Ok(Expr::If {
            cond: Box::new(condition),
            then_expr: Box::new(then_expr),
            else_expr: Box::new(else_expr),
            span: Span::new(start, self.position()),
        })
    }

    fn parse_match(&mut self, start: usize) -> Result<Expr, XsError> {
        self.expect_token(Token::Match)?;
        let expr = self.parse_expression()?;

        // Expect block for case branches
        if !matches!(self.current_token, Some((Token::LeftBrace, _))) {
            return Err(XsError::ParseError(
                self.position(),
                "Expected '{' after match expression".to_string(),
            ));
        }

        self.advance()?; // consume {

        let mut cases = Vec::new();

        while !matches!(self.current_token, Some((Token::RightBrace, _))) {
            // Skip newlines
            if matches!(self.current_token, Some((Token::Newline, _))) {
                self.advance()?;
                continue;
            }

            // Parse pattern
            let pattern = self.parse_pattern()?;
            self.expect_token(Token::Arrow)?;
            let body = self.parse_expression()?;

            cases.push((pattern, body));

            // Consume optional semicolon or newline
            if matches!(
                self.current_token,
                Some((Token::Semicolon, _)) | Some((Token::Newline, _))
            ) {
                self.advance()?;
            }
        }

        self.expect_token(Token::RightBrace)?;

        Ok(Expr::Match {
            expr: Box::new(expr),
            cases,
            span: Span::new(start, self.position()),
        })
    }

    fn parse_pattern(&mut self) -> Result<Pattern, XsError> {
        match &self.current_token {
            Some((Token::Symbol(s), span)) => {
                let name = s.clone();
                let span = span.clone();
                self.advance()?;

                // Check for cons pattern (x :: xs)
                if matches!(self.current_token, Some((Token::DoubleColon, _))) {
                    self.advance()?; // consume ::
                    let tail_pattern = self.parse_pattern()?;
                    // Use Constructor pattern for cons
                    Ok(Pattern::Constructor {
                        name: Ident("::".to_string()),
                        patterns: vec![Pattern::Variable(Ident(name), span.clone()), tail_pattern],
                        span,
                    })
                }
                // Check for constructor pattern
                else if self.is_pattern_continuation() {
                    let mut patterns = vec![];
                    while self.is_pattern_continuation() {
                        patterns.push(self.parse_pattern()?);
                    }
                    Ok(Pattern::Constructor {
                        name: Ident(name),
                        patterns,
                        span,
                    })
                } else {
                    Ok(Pattern::Variable(Ident(name), span))
                }
            }
            Some((Token::Underscore, span)) => {
                let span = span.clone();
                self.advance()?;
                Ok(Pattern::Wildcard(span))
            }
            Some((Token::Int(n), span)) => {
                let val = *n;
                let span = span.clone();
                self.advance()?;
                Ok(Pattern::Literal(Literal::Int(val), span))
            }
            Some((Token::Bool(b), span)) => {
                let val = *b;
                let span = span.clone();
                self.advance()?;
                Ok(Pattern::Literal(Literal::Bool(val), span))
            }
            Some((Token::String(s), span)) => {
                let val = s.clone();
                let span = span.clone();
                self.advance()?;
                Ok(Pattern::Literal(Literal::String(val), span))
            }
            Some((Token::LeftBracket, _)) => self.parse_list_pattern(),
            Some((Token::LeftParen, span)) => {
                let start_span = span.clone();
                self.advance()?;

                // Check for unit pattern ()
                if matches!(self.current_token, Some((Token::RightParen, _))) {
                    self.advance()?;
                    // Return unit constructor pattern
                    Ok(Pattern::Constructor {
                        name: Ident("Unit".to_string()),
                        patterns: vec![],
                        span: start_span,
                    })
                } else {
                    let pattern = self.parse_pattern()?;
                    self.expect_token(Token::RightParen)?;
                    Ok(pattern)
                }
            }
            _ => Err(XsError::ParseError(
                self.position(),
                format!("Invalid pattern: {:?}", self.current_token),
            )),
        }
    }

    fn parse_list_pattern(&mut self) -> Result<Pattern, XsError> {
        let start = self.position();
        self.expect_token(Token::LeftBracket)?;
        let mut patterns = Vec::new();

        while !matches!(self.current_token, Some((Token::RightBracket, _))) {
            patterns.push(self.parse_pattern()?);

            if matches!(self.current_token, Some((Token::Comma, _))) {
                self.advance()?;
            } else if matches!(self.current_token, Some((Token::Ellipsis, _))) {
                self.advance()?;
                // Rest pattern - for now, just add a wildcard
                patterns.push(Pattern::Wildcard(Span::new(start, self.position())));
                break;
            }
        }

        self.expect_token(Token::RightBracket)?;
        Ok(Pattern::List {
            patterns,
            span: Span::new(start, self.position()),
        })
    }

    fn parse_with_handler(&mut self, start: usize) -> Result<Expr, XsError> {
        // This parses the old "with handler { body }" syntax
        // We might want to keep this for backwards compatibility
        self.expect_token(Token::With)?;
        let handler = self.parse_primary()?;
        let body = self.parse_primary()?;

        Ok(Expr::WithHandler {
            handler: Box::new(handler),
            body: Box::new(body),
            span: Span::new(start, self.position()),
        })
    }

    fn parse_do_block(&mut self, start: usize) -> Result<Expr, XsError> {
        self.expect_token(Token::Do)?;
        self.skip_newlines();

        // Expect opening brace
        self.expect_token(Token::LeftBrace)?;
        self.skip_newlines();

        let mut statements = Vec::new();

        // Parse statements until closing brace
        while !matches!(self.current_token, Some((Token::RightBrace, _))) {
            // Check for bind syntax: "x <- expr"
            if let Some((Token::Symbol(ident_name), ident_span)) = &self.current_token.clone() {
                let bind_start = ident_span.start;
                self.advance()?; // consume identifier

                // Check for "<-" symbol
                if matches!(&self.current_token, Some((Token::Symbol(s), _)) if s == "<-")
                    || matches!(self.current_token, Some((Token::LeftArrow, _)))
                {
                    self.advance()?; // consume "<-"
                    let expr = self.parse_expression()?;
                    statements.push(DoStatement::Bind {
                        name: Ident(ident_name.clone()),
                        expr,
                        span: Span::new(bind_start, self.position()),
                    });
                } else {
                    // Not a bind, parse the identifier as part of an expression
                    // Create identifier expression
                    let ident_expr = Expr::Ident(Ident(ident_name.clone()), ident_span.clone());

                    // For now, just use the identifier as is
                    // TODO: Handle more complex expressions starting with an identifier
                    let expr = ident_expr;

                    statements.push(DoStatement::Expression(expr));
                }
            } else {
                // Parse as expression
                let expr = self.parse_expression()?;
                statements.push(DoStatement::Expression(expr));
            }

            // Skip optional semicolon or newline
            if matches!(self.current_token, Some((Token::Semicolon, _))) {
                self.advance()?;
            }
            self.skip_newlines();
        }

        // Consume closing brace
        self.expect_token(Token::RightBrace)?;

        Ok(Expr::Do {
            statements,
            span: Span::new(start, self.position()),
        })
    }

    fn parse_perform(&mut self, start: usize) -> Result<Expr, XsError> {
        self.expect_token(Token::Perform)?;

        // Parse effect name
        let effect = self.parse_identifier()?;

        // Parse arguments
        let mut args = Vec::new();
        while self.is_application_start() {
            args.push(self.parse_primary()?);
        }

        Ok(Expr::Perform {
            effect: Ident(effect),
            args,
            span: Span::new(start, self.position()),
        })
    }

    fn parse_function_definition(&mut self, name: String, start: usize) -> Result<Expr, XsError> {
        // Parse parameters
        let mut params = Vec::new();

        // Parse parameters until we hit '='
        while !matches!(self.current_token, Some((Token::Equals, _))) {
            let param_name = self.parse_identifier()?;

            // Parse optional type annotation
            let type_ann = if matches!(self.current_token, Some((Token::Colon, _))) {
                self.advance()?;
                Some(self.parse_type_expression()?)
            } else {
                None
            };

            params.push((Ident(param_name), type_ann));

            // Check for '->' between parameters
            if matches!(self.current_token, Some((Token::Arrow, _))) {
                self.advance()?;
            }
        }

        self.expect_token(Token::Equals)?;

        // Skip newlines after equals
        while matches!(self.current_token, Some((Token::Newline, _))) {
            self.advance()?;
        }

        let body = self.parse_expression()?;

        // Create nested lambdas for multiple parameters
        let lambda = params
            .into_iter()
            .rev()
            .fold(body, |acc, param| Expr::Lambda {
                params: vec![param],
                body: Box::new(acc),
                span: Span::new(start, self.position()),
            });

        // Create a Let binding for the function
        Ok(Expr::Let {
            name: Ident(name),
            type_ann: None,
            value: Box::new(lambda),
            span: Span::new(start, self.position()),
        })
    }

    fn parse_handler(&mut self, start: usize) -> Result<Expr, XsError> {
        self.expect_token(Token::Handler)?;

        // Expect block for handler cases
        if !matches!(self.current_token, Some((Token::LeftBrace, _))) {
            return Err(XsError::ParseError(
                self.position(),
                "Expected '{' after 'handler'".to_string(),
            ));
        }

        self.advance()?; // consume {

        let mut cases = Vec::new();

        while !matches!(self.current_token, Some((Token::RightBrace, _))) {
            // Skip newlines
            if matches!(self.current_token, Some((Token::Newline, _))) {
                self.advance()?;
                continue;
            }

            // Parse handler case: effectName patterns continuationName -> body
            let effect_name = self.parse_identifier()?;

            // Parse patterns and continuation
            let mut patterns = Vec::new();
            let mut continuation_name = Ident("k".to_string()); // default continuation name

            while !matches!(self.current_token, Some((Token::Arrow, _))) {
                let pattern = self.parse_pattern()?;

                // Check if this is the last pattern before arrow
                if matches!(self.current_token, Some((Token::Arrow, _))) {
                    // This is the continuation variable
                    if let Pattern::Variable(name, _) = pattern {
                        continuation_name = name;
                    } else {
                        patterns.push(pattern);
                    }
                } else {
                    patterns.push(pattern);
                }
            }

            self.expect_token(Token::Arrow)?;
            let body = self.parse_expression()?;

            cases.push((Ident(effect_name), patterns, continuation_name, body));

            // Consume optional semicolon or newline
            if matches!(
                self.current_token,
                Some((Token::Semicolon, _)) | Some((Token::Newline, _))
            ) {
                self.advance()?;
            }
        }

        self.expect_token(Token::RightBrace)?;

        // For now, use a dummy body
        let body = Box::new(Expr::Literal(Literal::Int(0), Span::new(start, start)));

        Ok(Expr::Handler {
            cases,
            body,
            span: Span::new(start, self.position()),
        })
    }

    fn parse_handle_expr(&mut self, start: usize) -> Result<Expr, XsError> {
        self.expect_token(Token::Handle)?;

        // Parse the expression to handle
        let expr = self.parse_expression()?;

        // Optional "with" for backward compatibility
        if matches!(self.current_token, Some((Token::With, _))) {
            self.advance()?;
        }
        self.skip_newlines();

        // Expect opening brace
        self.expect_token(Token::LeftBrace)?;
        self.skip_newlines();

        let mut handlers = Vec::new();
        let mut return_handler = None;

        // Parse handler cases until closing brace
        while !matches!(self.current_token, Some((Token::RightBrace, _))) {
            // Check for pipe symbol
            if matches!(self.current_token, Some((Token::Pipe, _))) {
                self.advance()?; // consume |
            }
            self.skip_newlines();

            // Check if we've reached the closing brace
            if matches!(self.current_token, Some((Token::RightBrace, _))) {
                break;
            }

            // Check if this is a return handler
            if matches!(&self.current_token, Some((Token::Symbol(s), _)) if s == "return") {
                self.advance()?; // consume "return"
                let var_name = Ident(self.parse_identifier()?);
                self.expect_token(Token::Arrow)?;
                let handler_body = self.parse_expression()?;
                return_handler = Some((var_name, Box::new(handler_body)));
            } else {
                // Parse effect handler: Effect.operation args... continuation -> body
                let effect_name = self.parse_identifier()?;

                let operation = if matches!(self.current_token, Some((Token::Dot, _))) {
                    self.advance()?; // consume .
                    Some(Ident(self.parse_identifier()?))
                } else {
                    None
                };

                // Parse arguments and continuation
                let mut args = Vec::new();
                let continuation;

                // Collect all tokens until arrow
                let mut tokens_before_arrow = Vec::new();

                while !matches!(self.current_token, Some((Token::Arrow, _))) {
                    self.skip_newlines();

                    if matches!(self.current_token, Some((Token::Arrow, _))) {
                        break;
                    }

                    if matches!(self.current_token, Some((Token::Pipe, _)))
                        || matches!(self.current_token, Some((Token::RightBrace, _)))
                    {
                        return Err(XsError::ParseError(
                            self.position(),
                            "Expected arrow in handler".to_string(),
                        ));
                    }

                    tokens_before_arrow.push(self.current_token.clone());
                    self.advance()?;
                }

                // The last token before arrow should be the continuation
                if let Some(Some((Token::Symbol(cont_name), _))) = tokens_before_arrow.pop() {
                    continuation = Some(Ident(cont_name));

                    // Now reset and parse the arguments (everything except the last token)
                    // This is a simplified approach - in a real implementation we'd
                    // properly reset the parser state
                    // For now, we'll just accept that we've consumed the tokens

                    // Convert the remaining tokens to patterns
                    // This is a hack - in production code we'd properly re-parse
                    for token_opt in tokens_before_arrow {
                        if let Some((token, span)) = token_opt {
                            match token {
                                Token::Symbol(s) => {
                                    args.push(Pattern::Variable(Ident(s), span));
                                }
                                Token::LeftParen => {
                                    // Handle unit pattern
                                    args.push(Pattern::Constructor {
                                        name: Ident("Unit".to_string()),
                                        patterns: vec![],
                                        span,
                                    });
                                }
                                _ => {
                                    // Skip other tokens for now
                                }
                            }
                        }
                    }
                } else {
                    return Err(XsError::ParseError(
                        self.position(),
                        "Expected continuation variable before ->".to_string(),
                    ));
                }

                // continuation is already set above, unwrap it
                let continuation = continuation.unwrap();

                self.expect_token(Token::Arrow)?;
                let body = self.parse_expression()?;

                handlers.push(HandlerCase {
                    effect: Ident(effect_name),
                    operation,
                    args,
                    continuation,
                    body,
                    span: Span::new(start, self.position()),
                });
            }

            self.skip_newlines();
        }

        self.expect_token(Token::RightBrace)?;

        Ok(Expr::HandleExpr {
            expr: Box::new(expr),
            handlers,
            return_handler,
            span: Span::new(start, self.position()),
        })
    }

    fn parse_type_definition(&mut self) -> Result<Expr, XsError> {
        let start = self.position();
        self.expect_token(Token::Type)?;
        let name = self.parse_identifier()?;

        // Parse type parameters
        let mut type_params = Vec::new();
        while self.is_identifier() && !matches!(self.current_token, Some((Token::Equals, _))) {
            type_params.push(self.parse_identifier()?);
        }

        self.expect_token(Token::Equals)?;

        // Parse constructors
        let mut constructors = Vec::new();

        // First constructor doesn't need |
        let first_name = self.parse_identifier()?;
        let mut first_fields = Vec::new();

        // Parse constructor fields
        while self.is_type_expression_start()
            && !matches!(self.current_token, Some((Token::Pipe, _)))
            && !self.is_end_of_definition()
        {
            first_fields.push(self.parse_type_expression()?);
        }

        constructors.push(Constructor {
            name: first_name,
            fields: first_fields,
        });

        // Parse remaining constructors
        while matches!(self.current_token, Some((Token::Pipe, _))) {
            self.advance()?;

            let constructor_name = self.parse_identifier()?;
            let mut fields = Vec::new();

            // Parse constructor fields
            while self.is_type_expression_start()
                && !matches!(self.current_token, Some((Token::Pipe, _)))
                && !self.is_end_of_definition()
            {
                fields.push(self.parse_type_expression()?);
            }

            constructors.push(Constructor {
                name: constructor_name,
                fields,
            });
        }

        Ok(Expr::TypeDef {
            definition: TypeDefinition {
                name,
                type_params,
                constructors,
            },
            span: Span::new(start, self.position()),
        })
    }

    fn parse_data_definition(&mut self) -> Result<Expr, XsError> {
        let start = self.position();
        self.expect_token(Token::Data)?;
        let name = self.parse_identifier()?;

        // Parse type parameters
        let mut type_params = Vec::new();
        while self.is_identifier() && !matches!(self.current_token, Some((Token::Equals, _))) {
            type_params.push(self.parse_identifier()?);
        }

        self.expect_token(Token::Equals)?;

        // Parse constructors
        let mut constructors = Vec::new();

        loop {
            if matches!(self.current_token, Some((Token::Pipe, _))) {
                self.advance()?;
            }

            if self.is_end_of_definition() {
                break;
            }

            let constructor_name = self.parse_identifier()?;
            let mut fields = Vec::new();

            // Parse constructor fields
            while self.is_type_expression_start()
                && !self.is_end_of_definition()
                && !matches!(self.current_token, Some((Token::Pipe, _)))
            {
                fields.push(self.parse_type_expression()?);
            }

            constructors.push(Constructor {
                name: constructor_name,
                fields,
            });
        }

        Ok(Expr::TypeDef {
            definition: TypeDefinition {
                name,
                type_params,
                constructors,
            },
            span: Span::new(start, self.position()),
        })
    }

    fn parse_effect_definition(&mut self) -> Result<Expr, XsError> {
        let start = self.position();
        self.expect_token(Token::Effect)?;
        let _name = self.parse_identifier()?;

        self.expect_token(Token::LeftBrace)?;

        while !matches!(self.current_token, Some((Token::RightBrace, _))) {
            // Skip newlines
            if matches!(self.current_token, Some((Token::Newline, _))) {
                self.advance()?;
                continue;
            }

            // Parse effect operations
            let _op_name = self.parse_identifier()?;
            self.expect_token(Token::Colon)?;
            let _op_type = self.parse_type_expression()?;

            if matches!(
                self.current_token,
                Some((Token::Semicolon, _)) | Some((Token::Newline, _))
            ) {
                self.advance()?;
            }
        }

        self.expect_token(Token::RightBrace)?;

        // For now, return a placeholder
        Ok(Expr::Ident(
            Ident("effect_def".to_string()),
            Span::new(start, self.position()),
        ))
    }

    fn parse_import(&mut self) -> Result<Expr, XsError> {
        let start = self.position();
        self.expect_token(Token::Import)?;
        let module_path = self.parse_module_path()?;

        // Check for hash import: import Foo@abc123
        let hash = if matches!(self.current_token, Some((Token::At, _))) {
            self.advance()?;
            // Parse hash value (can be symbol or int for flexibility)
            match &self.current_token {
                Some((Token::Symbol(h), _)) => {
                    let hash_str = h.clone();
                    self.advance()?;
                    Some(hash_str)
                }
                Some((Token::Int(n), _)) => {
                    let hash_str = n.to_string();
                    self.advance()?;
                    Some(hash_str)
                }
                _ => {
                    return Err(XsError::ParseError(
                        self.position(),
                        "Expected hash value after @".to_string(),
                    ));
                }
            }
        } else {
            None
        };

        let (items, as_name) = if matches!(self.current_token, Some((Token::As, _))) {
            self.advance()?;
            let alias = self.parse_identifier()?;
            (None, Some(Ident(alias)))
        } else {
            (None, None)
        };

        Ok(Expr::Import {
            module_name: Ident(module_path),
            items,
            as_name,
            hash,
            span: Span::new(start, self.position()),
        })
    }

    fn parse_module_definition(&mut self) -> Result<Expr, XsError> {
        let start = self.position();
        self.expect_token(Token::Module)?;
        let name = self.parse_identifier()?;

        self.expect_token(Token::LeftBrace)?;

        let mut exports = Vec::new();
        let mut body = Vec::new();

        // Parse module body
        while !matches!(self.current_token, Some((Token::RightBrace, _))) {
            if matches!(self.current_token, Some((Token::Newline, _))) {
                self.advance()?;
                continue;
            }

            // Check for export declaration
            if matches!(self.current_token, Some((Token::Export, _))) {
                self.advance()?;

                // Parse export list
                loop {
                    let export_name = self.parse_identifier()?;
                    exports.push(Ident(export_name));

                    if matches!(self.current_token, Some((Token::Comma, _))) {
                        self.advance()?;
                    } else {
                        break;
                    }
                }

                // Expect semicolon or newline after export
                if matches!(
                    self.current_token,
                    Some((Token::Semicolon, _)) | Some((Token::Newline, _))
                ) {
                    self.advance()?;
                }
            } else {
                // Parse module members
                let member = self.parse_top_level()?;
                body.push(member);

                if matches!(
                    self.current_token,
                    Some((Token::Semicolon, _)) | Some((Token::Newline, _))
                ) {
                    self.advance()?;
                }
            }
        }

        self.expect_token(Token::RightBrace)?;

        Ok(Expr::Module {
            name: Ident(name),
            exports,
            body,
            span: Span::new(start, self.position()),
        })
    }

    fn parse_type_expression(&mut self) -> Result<Type, XsError> {
        // Parse basic types
        let base_type = match &self.current_token {
            Some((Token::Symbol(s), _)) => {
                let type_name = s.clone();
                self.advance()?;

                match type_name.as_str() {
                    "Int" => Type::Int,
                    "Float" => Type::Float,
                    "Bool" => Type::Bool,
                    "String" => Type::String,
                    "Unit" => Type::Unit,
                    _ => {
                        // Check for type parameters
                        let mut type_params = Vec::new();
                        while self.is_type_expression_start() && !self.is_type_delimiter() {
                            type_params.push(self.parse_type_expression()?);
                        }

                        if type_params.is_empty() {
                            Type::Var(type_name)
                        } else {
                            Type::UserDefined {
                                name: type_name,
                                type_params,
                            }
                        }
                    }
                }
            }
            Some((Token::LeftParen, _)) => {
                self.advance()?;

                // Check for function type
                if matches!(self.current_token, Some((Token::Arrow, _))) {
                    self.advance()?;
                    let from_type = self.parse_type_expression()?;
                    let to_type = self.parse_type_expression()?;
                    self.expect_token(Token::RightParen)?;
                    Type::Function(Box::new(from_type), Box::new(to_type))
                } else {
                    // List type
                    self.expect_token(Token::Symbol("List".to_string()))?;
                    let elem_type = self.parse_type_expression()?;
                    self.expect_token(Token::RightParen)?;
                    Type::List(Box::new(elem_type))
                }
            }
            _ => {
                return Err(XsError::ParseError(
                    self.position(),
                    "Expected type expression".to_string(),
                ))
            }
        };

        // Check for optional type marker '?'
        if let Some((Token::Symbol(s), _)) = &self.current_token {
            if s == "?" {
                self.advance()?; // consume '?'
                                 // Wrap in Option type
                Ok(Type::UserDefined {
                    name: "Option".to_string(),
                    type_params: vec![base_type],
                })
            } else {
                Ok(base_type)
            }
        } else {
            Ok(base_type)
        }
    }

    fn is_type_delimiter(&self) -> bool {
        matches!(
            self.current_token,
            Some((Token::RightParen, _))
                | Some((Token::Comma, _))
                | Some((Token::Arrow, _))
                | Some((Token::Pipe, _))
                | Some((Token::Newline, _))
                | Some((Token::Semicolon, _))
        )
    }

    fn parse_module_path(&mut self) -> Result<String, XsError> {
        // Check if it's a string literal (file path)
        if let Some((Token::String(path), _)) = &self.current_token {
            let path = path.clone();
            self.advance()?;
            return Ok(path);
        }

        // Otherwise parse as dotted identifier
        let mut path = self.parse_identifier()?;

        while matches!(self.current_token, Some((Token::Dot, _))) {
            self.advance()?;
            path.push('.');
            path.push_str(&self.parse_identifier()?);
        }

        Ok(path)
    }

    fn parse_identifier(&mut self) -> Result<String, XsError> {
        match &self.current_token {
            Some((Token::Symbol(s), _)) => {
                let name = s.clone();
                self.advance()?;
                Ok(name)
            }
            _ => Err(XsError::ParseError(
                self.position(),
                format!("Expected identifier, got {:?}", self.current_token),
            )),
        }
    }

    fn is_identifier(&self) -> bool {
        matches!(self.current_token, Some((Token::Symbol(_), _)))
    }

    fn is_application_start(&self) -> bool {
        // Don't treat infix operators as application start
        if self.is_infix_operator() {
            return false;
        }

        matches!(
            &self.current_token,
            Some((Token::Int(_), _))
                | Some((Token::Float(_), _))
                | Some((Token::Bool(_), _))
                | Some((Token::String(_), _))
                | Some((Token::Symbol(_), _))
                | Some((Token::LeftParen, _))
                | Some((Token::LeftBracket, _))
                | Some((Token::Fn, _))
                | Some((Token::Backslash, _))
                | Some((Token::If, _))
                | Some((Token::Match, _))
                | Some((Token::Let, _))
                | Some((Token::At, _))
        )
    }

    fn is_pattern_continuation(&self) -> bool {
        matches!(
            &self.current_token,
            Some((Token::Symbol(_), _))
                | Some((Token::Underscore, _))
                | Some((Token::Int(_), _))
                | Some((Token::Bool(_), _))
                | Some((Token::String(_), _))
                | Some((Token::LeftBracket, _))
                | Some((Token::LeftParen, _))
        )
    }

    fn is_infix_operator(&self) -> bool {
        match &self.current_token {
            Some((Token::Symbol(s), _)) => {
                matches!(
                    s.as_str(),
                    "+" | "-" | "*" | "/" | "%" | "<=" | ">=" | "!=" | "&&" | "||" | "++"
                )
            }
            Some((Token::Equals, _)) => true, // Handle '=' as infix operator
            Some((Token::EqualsEquals, _)) => true, // Handle '==' as infix operator
            Some((Token::DoubleColon, _)) => true, // Handle '::' as infix operator (cons)
            Some((Token::LessThan, _)) => true, // Handle '<' as infix operator
            Some((Token::GreaterThan, _)) => true, // Handle '>' as infix operator
            _ => false,
        }
    }

    fn is_type_expression_start(&self) -> bool {
        matches!(
            self.current_token,
            Some((Token::Symbol(_), _)) | Some((Token::LeftParen, _))
        )
    }

    fn is_end_of_definition(&self) -> bool {
        matches!(
            self.current_token,
            Some((Token::Newline, _))
                | Some((Token::Semicolon, _))
                | Some((Token::RightBrace, _))
                | Some((Token::Let, _))
                | Some((Token::Type, _))
                | Some((Token::Data, _))
                | Some((Token::Effect, _))
                | Some((Token::Module, _))
                | Some((Token::Import, _))
                | None
        )
    }

    fn expect_token(&mut self, expected: Token) -> Result<Span, XsError> {
        match &self.current_token {
            Some((token, span))
                if std::mem::discriminant(token) == std::mem::discriminant(&expected) =>
            {
                let span = span.clone();
                self.advance()?;
                Ok(span)
            }
            _ => Err(XsError::ParseError(
                self.position(),
                format!("Expected {:?}, got {:?}", expected, self.current_token),
            )),
        }
    }

    fn advance(&mut self) -> Result<(), XsError> {
        self.current_token = self.peek_token.take();
        self.peek_token = self.lexer.next_token()?;
        Ok(())
    }

    fn position(&self) -> usize {
        self.current_span().start
    }

    fn current_span(&self) -> Span {
        self.current_token
            .as_ref()
            .map(|(_, span)| span.clone())
            .unwrap_or(Span::new(0, 0))
    }

    fn skip_newlines(&mut self) {
        while matches!(self.current_token, Some((Token::Newline, _))) {
            let _ = self.advance();
        }
    }

    fn parse_remaining_application(&mut self, mut expr: Expr) -> Result<Expr, XsError> {
        while self.is_application_start() {
            let arg = self.parse_primary()?;
            let span_start = expr.span().start;
            expr = Expr::Apply {
                func: Box::new(expr),
                args: vec![arg],
                span: Span::new(span_start, self.position()),
            };
        }
        Ok(expr)
    }
}
