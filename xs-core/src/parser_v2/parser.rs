use crate::{Expr, Span, XsError, Ident, Literal, Pattern, Type, TypeDefinition, Constructor};
use super::lexer::{Lexer, Token};

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
            if matches!(self.current_token, Some((Token::Semicolon, _)) | Some((Token::Newline, _))) {
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
                span: Span::new(0, self.position()) 
            })
        }
    }

    fn parse_top_level(&mut self) -> Result<Expr, XsError> {
        match &self.current_token {
            Some((Token::Let, _)) => self.parse_let_binding(),
            Some((Token::Type, _)) => self.parse_type_definition(),
            Some((Token::Data, _)) => self.parse_data_definition(),
            Some((Token::Effect, _)) => self.parse_effect_definition(),
            Some((Token::Import, _)) => self.parse_import(),
            Some((Token::Module, _)) => self.parse_module_definition(),
            _ => self.parse_expression(),
        }
    }

    fn parse_let_binding(&mut self) -> Result<Expr, XsError> {
        let start_span = self.expect_token(Token::Let)?;
        let name = self.parse_identifier()?;
        
        // Check for function syntax: let name args = body
        if !matches!(self.current_token, Some((Token::Equals, _))) {
            // Function definition
            let mut params = vec![];
            
            // Parse parameters
            while !matches!(self.current_token, Some((Token::Equals, _))) {
                params.push((Ident(self.parse_identifier()?), None));
            }
            
            self.expect_token(Token::Equals)?;
            let body = self.parse_expression()?;
            
            // Convert to nested lambdas
            let lambda = params.into_iter()
                .rev()
                .fold(body, |acc, param| {
                    Expr::Lambda {
                        params: vec![param],
                        body: Box::new(acc),
                        span: Span::new(start_span.start, self.position())
                    }
                });
            
            // Check for 'in' keyword
            if matches!(self.current_token, Some((Token::In, _))) {
                self.advance()?;
                let in_body = self.parse_expression()?;
                Ok(Expr::LetIn {
                    name: Ident(name),
                    type_ann: None,
                    value: Box::new(lambda),
                    body: Box::new(in_body),
                    span: Span::new(start_span.start, self.position())
                })
            } else {
                Ok(Expr::Let {
                    name: Ident(name),
                    type_ann: None,
                    value: Box::new(lambda),
                    span: Span::new(start_span.start, self.position())
                })
            }
        } else {
            // Simple let binding
            self.expect_token(Token::Equals)?;
            let value = self.parse_expression()?;
            
            // Check for 'in' keyword
            if matches!(self.current_token, Some((Token::In, _))) {
                self.advance()?;
                let body = self.parse_expression()?;
                Ok(Expr::LetIn {
                    name: Ident(name),
                    type_ann: None,
                    value: Box::new(value),
                    body: Box::new(body),
                    span: Span::new(start_span.start, self.position())
                })
            } else {
                Ok(Expr::Let {
                    name: Ident(name),
                    type_ann: None,
                    value: Box::new(value),
                    span: Span::new(start_span.start, self.position())
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
            let op = self.parse_identifier()?;
            let right = self.parse_pipeline()?;
            
            // First apply operator to left operand
            let partial = Expr::Apply {
                func: Box::new(Expr::Ident(Ident(op), op_span.clone())),
                args: vec![left],
                span: op_span.clone()
            };
            
            // Then apply the result to right operand
            left = Expr::Apply {
                func: Box::new(partial),
                args: vec![right],
                span: Span::new(op_span.start, self.position())
            };
        }
        
        Ok(left)
    }

    fn parse_pipeline(&mut self) -> Result<Expr, XsError> {
        let mut left = self.parse_application()?;
        
        while matches!(self.current_token, Some((Token::Pipe, _)) | Some((Token::PipeForward, _))) {
            let op_span = self.current_span();
            self.advance()?;
            let right = self.parse_application()?;
            
            left = Expr::Pipeline {
                expr: Box::new(left),
                func: Box::new(right),
                span: Span::new(op_span.start, self.position())
            };
        }
        
        Ok(left)
    }

    fn parse_application(&mut self) -> Result<Expr, XsError> {
        let mut expr = self.parse_primary()?;
        
        // Handle function application
        while self.is_application_start() {
            let arg = self.parse_primary()?;
            let span_start = expr.span().start;
            expr = Expr::Apply {
                func: Box::new(expr),
                args: vec![arg],
                span: Span::new(span_start, self.position())
            };
        }
        
        // Handle record access
        while matches!(self.current_token, Some((Token::Dot, _))) {
            self.advance()?;
            let field = self.parse_identifier()?;
            let span_start = expr.span().start;
            expr = Expr::RecordAccess {
                record: Box::new(expr),
                field: Ident(field),
                span: Span::new(span_start, self.position())
            };
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
            Some((Token::LeftParen, _)) => {
                self.advance()?;
                let expr = self.parse_expression()?;
                self.expect_token(Token::RightParen)?;
                Ok(expr)
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
            Some((Token::If, span)) => {
                let start = span.start;
                self.parse_if(start)
            }
            Some((Token::Case, span)) => {
                let start = span.start;
                self.parse_case(start)
            }
            Some((Token::Let, _)) => {
                self.parse_let_binding()
            }
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
                Ok(Expr::Hole { name, type_hint, span })
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
            _ => Err(XsError::ParseError(
                self.position(),
                format!("Unexpected token: {:?}", self.current_token)
            ))
        }
    }

    fn parse_block_or_record(&mut self, start: usize) -> Result<Expr, XsError> {
        self.expect_token(Token::LeftBrace)?;
        
        // Peek ahead to determine if it's a record or block
        if self.is_record_syntax() {
            self.parse_record_literal(start)
        } else {
            self.parse_block(start)
        }
    }

    fn is_record_syntax(&self) -> bool {
        // Check if next tokens look like "field: value"
        matches!(self.current_token, Some((Token::Symbol(_), _))) &&
        matches!(self.peek_token, Some((Token::Colon, _)))
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
            span: Span::new(start, self.position())
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
            if matches!(self.current_token, Some((Token::Semicolon, _)) | Some((Token::Newline, _))) {
                self.advance()?;
            }
        }
        
        self.expect_token(Token::RightBrace)?;
        
        if exprs.is_empty() {
            Ok(Expr::Literal(Literal::Int(0), Span::new(start, self.position())))
        } else if exprs.len() == 1 {
            Ok(exprs.into_iter().next().unwrap())
        } else {
            Ok(Expr::Block {
                exprs,
                span: Span::new(start, self.position())
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
                    "Expected ',' or ']' in list".to_string()
                ));
            }
        }
        
        self.expect_token(Token::RightBracket)?;
        Ok(Expr::List(elements, Span::new(start, self.position())))
    }

    fn parse_lambda(&mut self, start: usize) -> Result<Expr, XsError> {
        self.expect_token(Token::Fn)?;
        
        // Parse parameters
        let mut params = Vec::new();
        
        // Check if parameters are in parentheses
        if matches!(self.current_token, Some((Token::LeftParen, _))) {
            self.advance()?;
            while !matches!(self.current_token, Some((Token::RightParen, _))) {
                let param_name = self.parse_identifier()?;
                let type_ann = if matches!(self.current_token, Some((Token::Colon, _))) {
                    self.advance()?;
                    Some(self.parse_type_expression()?)
                } else {
                    None
                };
                params.push((Ident(param_name), type_ann));
                
                if matches!(self.current_token, Some((Token::Comma, _))) {
                    self.advance()?;
                }
            }
            self.expect_token(Token::RightParen)?;
        } else {
            // Single parameter without parentheses
            let param_name = self.parse_identifier()?;
            params.push((Ident(param_name), None));
        }
        
        self.expect_token(Token::Arrow)?;
        let body = self.parse_expression()?;
        
        // Create nested lambdas for multiple parameters
        let lambda = params.into_iter()
            .rev()
            .fold(body, |acc, param| {
                Expr::Lambda {
                    params: vec![param],
                    body: Box::new(acc),
                    span: Span::new(start, self.position())
                }
            });
        
        Ok(lambda)
    }

    fn parse_if(&mut self, start: usize) -> Result<Expr, XsError> {
        self.expect_token(Token::If)?;
        
        // Parse condition - it might be a complex expression
        let mut condition = self.parse_primary()?;
        
        // Handle infix operators in condition
        while self.is_infix_operator() {
            let op = self.parse_identifier()?;
            let right = self.parse_primary()?;
            condition = Expr::Apply {
                func: Box::new(Expr::Ident(Ident(op), self.current_span())),
                args: vec![condition, right],
                span: Span::new(start, self.position())
            };
        }
        
        // Expect block for then branch
        if !matches!(self.current_token, Some((Token::LeftBrace, _))) {
            return Err(XsError::ParseError(
                self.position(),
                "Expected '{' after if condition".to_string()
            ));
        }
        
        let then_start = self.position();
        let then_expr = self.parse_block_or_record(then_start)?;
        
        self.expect_token(Token::Else)?;
        
        // Else branch must also be a block
        if !matches!(self.current_token, Some((Token::LeftBrace, _))) {
            return Err(XsError::ParseError(
                self.position(),
                "Expected '{' after else".to_string()
            ));
        }
        
        let else_start = self.position();
        let else_expr = self.parse_block_or_record(else_start)?;
        
        Ok(Expr::If {
            cond: Box::new(condition),
            then_expr: Box::new(then_expr),
            else_expr: Box::new(else_expr),
            span: Span::new(start, self.position())
        })
    }

    fn parse_case(&mut self, start: usize) -> Result<Expr, XsError> {
        self.expect_token(Token::Case)?;
        let expr = self.parse_expression()?;
        self.expect_token(Token::Of)?;
        
        // Expect block for case branches
        if !matches!(self.current_token, Some((Token::LeftBrace, _))) {
            return Err(XsError::ParseError(
                self.position(),
                "Expected '{' after 'of'".to_string()
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
            if matches!(self.current_token, Some((Token::Semicolon, _)) | Some((Token::Newline, _))) {
                self.advance()?;
            }
        }
        
        self.expect_token(Token::RightBrace)?;
        
        Ok(Expr::Match {
            expr: Box::new(expr),
            cases,
            span: Span::new(start, self.position())
        })
    }

    fn parse_pattern(&mut self) -> Result<Pattern, XsError> {
        match &self.current_token {
            Some((Token::Symbol(s), span)) => {
                let name = s.clone();
                let span = span.clone();
                self.advance()?;
                
                // Check for constructor pattern
                if self.is_pattern_continuation() {
                    let mut patterns = vec![];
                    while self.is_pattern_continuation() {
                        patterns.push(self.parse_pattern()?);
                    }
                    Ok(Pattern::Constructor {
                        name: Ident(name),
                        patterns,
                        span
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
            Some((Token::LeftBracket, _)) => {
                self.parse_list_pattern()
            }
            Some((Token::LeftParen, _)) => {
                self.advance()?;
                let pattern = self.parse_pattern()?;
                self.expect_token(Token::RightParen)?;
                Ok(pattern)
            }
            _ => Err(XsError::ParseError(
                self.position(),
                format!("Invalid pattern: {:?}", self.current_token)
            ))
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
            span: Span::new(start, self.position())
        })
    }

    fn parse_with_handler(&mut self, start: usize) -> Result<Expr, XsError> {
        self.expect_token(Token::With)?;
        let handler = self.parse_primary()?;
        let body = self.parse_primary()?;
        
        Ok(Expr::WithHandler {
            handler: Box::new(handler),
            body: Box::new(body),
            span: Span::new(start, self.position())
        })
    }

    fn parse_do_block(&mut self, start: usize) -> Result<Expr, XsError> {
        self.expect_token(Token::Do)?;
        
        // Parse optional effect annotations
        let effects = if let Some((Token::Symbol(s), _)) = &self.current_token {
            if s == "<" {
                self.advance()?;
                let mut effs = Vec::new();
                
                while !matches!(&self.current_token, Some((Token::Symbol(s), _)) if s == ">") {
                    effs.push(self.parse_identifier()?);
                    if matches!(self.current_token, Some((Token::Comma, _))) {
                        self.advance()?;
                    }
                }
                
                // Consume the ">"
                if let Some((Token::Symbol(s), _)) = &self.current_token {
                    if s == ">" {
                        self.advance()?;
                    }
                }
                effs
            } else {
                Vec::new()
            }
        } else {
            Vec::new()
        };
        
        let body = self.parse_expression()?;
        
        Ok(Expr::Do {
            effects,
            body: Box::new(body),
            span: Span::new(start, self.position())
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
            span: Span::new(start, self.position())
        })
    }
    
    fn parse_handler(&mut self, start: usize) -> Result<Expr, XsError> {
        self.expect_token(Token::Handler)?;
        
        // Expect block for handler cases
        if !matches!(self.current_token, Some((Token::LeftBrace, _))) {
            return Err(XsError::ParseError(
                self.position(),
                "Expected '{' after 'handler'".to_string()
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
            if matches!(self.current_token, Some((Token::Semicolon, _)) | Some((Token::Newline, _))) {
                self.advance()?;
            }
        }
        
        self.expect_token(Token::RightBrace)?;
        
        // For now, use a dummy body
        let body = Box::new(Expr::Literal(Literal::Int(0), Span::new(start, start)));
        
        Ok(Expr::Handler {
            cases,
            body,
            span: Span::new(start, self.position())
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
        
        // For now, just parse type expression as a dummy
        let _type_expr = self.parse_type_expression()?;
        
        // Create a dummy TypeDef expression
        Ok(Expr::TypeDef {
            definition: TypeDefinition {
                name: name.clone(),
                type_params,
                constructors: vec![]
            },
            span: Span::new(start, self.position())
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
            while self.is_type_expression_start() && !self.is_end_of_definition() && !matches!(self.current_token, Some((Token::Pipe, _))) {
                fields.push(self.parse_type_expression()?);
            }
            
            constructors.push(Constructor {
                name: constructor_name,
                fields
            });
        }
        
        Ok(Expr::TypeDef {
            definition: TypeDefinition {
                name,
                type_params,
                constructors
            },
            span: Span::new(start, self.position())
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
            
            if matches!(self.current_token, Some((Token::Semicolon, _)) | Some((Token::Newline, _))) {
                self.advance()?;
            }
        }
        
        self.expect_token(Token::RightBrace)?;
        
        // For now, return a placeholder
        Ok(Expr::Ident(Ident("effect_def".to_string()), Span::new(start, self.position())))
    }

    fn parse_import(&mut self) -> Result<Expr, XsError> {
        let start = self.position();
        self.expect_token(Token::Import)?;
        let module_path = self.parse_module_path()?;
        
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
            span: Span::new(start, self.position())
        })
    }

    fn parse_module_definition(&mut self) -> Result<Expr, XsError> {
        let start = self.position();
        self.expect_token(Token::Module)?;
        let name = self.parse_identifier()?;
        
        self.expect_token(Token::LeftBrace)?;
        
        let mut body = Vec::new();
        
        // Parse module body
        while !matches!(self.current_token, Some((Token::RightBrace, _))) {
            if matches!(self.current_token, Some((Token::Newline, _))) {
                self.advance()?;
                continue;
            }
            
            // Parse module members
            let member = self.parse_top_level()?;
            body.push(member);
            
            if matches!(self.current_token, Some((Token::Semicolon, _)) | Some((Token::Newline, _))) {
                self.advance()?;
            }
        }
        
        self.expect_token(Token::RightBrace)?;
        
        Ok(Expr::Module {
            name: Ident(name),
            exports: vec![],  // TODO: Parse export list
            body,
            span: Span::new(start, self.position())
        })
    }

    fn parse_type_expression(&mut self) -> Result<Type, XsError> {
        // Parse basic types
        match &self.current_token {
            Some((Token::Symbol(s), _)) => {
                let type_name = s.clone();
                self.advance()?;
                
                match type_name.as_str() {
                    "Int" => Ok(Type::Int),
                    "Float" => Ok(Type::Float),
                    "Bool" => Ok(Type::Bool),
                    "String" => Ok(Type::String),
                    "Unit" => Ok(Type::Unit),
                    _ => {
                        // Check for type parameters
                        let mut type_params = Vec::new();
                        while self.is_type_expression_start() && !self.is_type_delimiter() {
                            type_params.push(self.parse_type_expression()?);
                        }
                        
                        if type_params.is_empty() {
                            Ok(Type::Var(type_name))
                        } else {
                            Ok(Type::UserDefined {
                                name: type_name,
                                type_params
                            })
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
                    Ok(Type::Function(Box::new(from_type), Box::new(to_type)))
                } else {
                    // List type
                    self.expect_token(Token::Symbol("List".to_string()))?;
                    let elem_type = self.parse_type_expression()?;
                    self.expect_token(Token::RightParen)?;
                    Ok(Type::List(Box::new(elem_type)))
                }
            }
            _ => Err(XsError::ParseError(
                self.position(),
                "Expected type expression".to_string()
            ))
        }
    }

    fn is_type_delimiter(&self) -> bool {
        matches!(
            self.current_token,
            Some((Token::RightParen, _)) |
            Some((Token::Comma, _)) |
            Some((Token::Arrow, _)) |
            Some((Token::Pipe, _)) |
            Some((Token::Newline, _)) |
            Some((Token::Semicolon, _))
        )
    }

    fn parse_module_path(&mut self) -> Result<String, XsError> {
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
                format!("Expected identifier, got {:?}", self.current_token)
            ))
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
        
        match &self.current_token {
            Some((Token::Int(_), _)) |
            Some((Token::Float(_), _)) |
            Some((Token::Bool(_), _)) |
            Some((Token::String(_), _)) |
            Some((Token::Symbol(_), _)) |
            Some((Token::LeftParen, _)) |
            Some((Token::LeftBrace, _)) |
            Some((Token::LeftBracket, _)) |
            Some((Token::Fn, _)) |
            Some((Token::If, _)) |
            Some((Token::Case, _)) |
            Some((Token::Let, _)) |
            Some((Token::At, _)) => true,
            _ => false
        }
    }

    fn is_pattern_continuation(&self) -> bool {
        match &self.current_token {
            Some((Token::Symbol(_), _)) |
            Some((Token::Underscore, _)) |
            Some((Token::Int(_), _)) |
            Some((Token::Bool(_), _)) |
            Some((Token::String(_), _)) |
            Some((Token::LeftBracket, _)) |
            Some((Token::LeftParen, _)) => true,
            _ => false
        }
    }

    fn is_infix_operator(&self) -> bool {
        match &self.current_token {
            Some((Token::Symbol(s), _)) => {
                matches!(s.as_str(), "+" | "-" | "*" | "/" | "%" | 
                        "<" | ">" | "<=" | ">=" | "==" | "!=" |
                        "&&" | "||" | "++")
            }
            _ => false
        }
    }

    fn is_type_expression_start(&self) -> bool {
        matches!(self.current_token, Some((Token::Symbol(_), _)) | Some((Token::LeftParen, _)))
    }

    fn is_end_of_definition(&self) -> bool {
        matches!(
            self.current_token,
            Some((Token::Newline, _)) |
            Some((Token::Semicolon, _)) |
            Some((Token::RightBrace, _)) |
            Some((Token::Let, _)) |
            Some((Token::Type, _)) |
            Some((Token::Data, _)) |
            Some((Token::Effect, _)) |
            Some((Token::Module, _)) |
            Some((Token::Import, _)) |
            None
        )
    }

    fn expect_token(&mut self, expected: Token) -> Result<Span, XsError> {
        match &self.current_token {
            Some((token, span)) if std::mem::discriminant(token) == std::mem::discriminant(&expected) => {
                let span = span.clone();
                self.advance()?;
                Ok(span)
            }
            _ => Err(XsError::ParseError(
                self.position(),
                format!("Expected {:?}, got {:?}", expected, self.current_token)
            ))
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
}