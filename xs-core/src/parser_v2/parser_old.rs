use crate::{Expr, Span, XsError, Ident, Literal, Pattern};
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
        let mut bindings = Vec::new();
        
        while self.current_token.is_some() {
            // Skip newlines at module level
            if matches!(self.current_token, Some((Token::Newline, _))) {
                self.advance()?;
                continue;
            }
            
            match &self.current_token {
                Some((Token::Let, _)) => {
                    let binding = self.parse_let_binding()?;
                    bindings.push(binding);
                }
                Some((Token::Type, _)) => {
                    let type_def = self.parse_type_definition()?;
                    bindings.push(type_def);
                }
                Some((Token::Data, _)) => {
                    let data_def = self.parse_data_definition()?;
                    bindings.push(data_def);
                }
                Some((Token::Effect, _)) => {
                    let effect_def = self.parse_effect_definition()?;
                    bindings.push(effect_def);
                }
                Some((Token::Import, _)) => {
                    let import = self.parse_import()?;
                    bindings.push(import);
                }
                Some((Token::Module, _)) => {
                    let module = self.parse_module_definition()?;
                    bindings.push(module);
                }
                _ => {
                    // Try to parse as expression
                    let expr = self.parse_expression()?;
                    bindings.push(expr);
                }
            }
            
            // Consume optional semicolon or newline
            if matches!(self.current_token, Some((Token::Semicolon, _)) | Some((Token::Newline, _))) {
                self.advance()?;
            }
        }
        
        // For now, return the last binding or a placeholder
        if bindings.is_empty() {
            Ok(Expr::Literal(Literal::Int(0), Span::new(0, 0)))
        } else if bindings.len() == 1 {
            Ok(bindings.into_iter().next().unwrap())
        } else {
            // Create a sequence/block expression
            Ok(Expr::Block { exprs: bindings, span: Span::new(0, 0) })
        }
    }

    fn parse_let_binding(&mut self) -> Result<Ast, XsError> {
        let start_span = self.expect_token(Token::Let)?;
        let name = self.parse_identifier()?;
        
        // Check for function syntax: let name args = body
        if !matches!(self.current_token, Some((Token::Equals, _))) {
            // Function definition
            let mut params = vec![name.clone()];
            
            // Parse parameters
            while !matches!(self.current_token, Some((Token::Equals, _))) {
                params.push(self.parse_identifier()?);
            }
            
            self.expect_token(Token::Equals)?;
            let body = self.parse_expression()?;
            
            // Convert to lambda
            let func_name = params.remove(0);
            let lambda = params.into_iter()
                .rev()
                .fold(body, |acc, param| {
                    Ast::Lambda(
                        vec![param],
                        Box::new(acc),
                        Span::new(start_span.start, self.position())
                    )
                });
            
            Ok(Ast::Let(
                func_name,
                Box::new(lambda),
                Box::new(Ast::Int(0, Span::new(0, 0))), // Placeholder for body
                Span::new(start_span.start, self.position())
            ))
        } else {
            // Simple let binding
            self.expect_token(Token::Equals)?;
            let value = self.parse_expression()?;
            
            // Check for 'in' keyword
            if matches!(self.current_token, Some((Token::In, _))) {
                self.advance()?;
                let body = self.parse_expression()?;
                Ok(Ast::Let(
                    name,
                    Box::new(value),
                    Box::new(body),
                    Span::new(start_span.start, self.position())
                ))
            } else {
                // Module-level binding
                Ok(Ast::Let(
                    name,
                    Box::new(value),
                    Box::new(Ast::Int(0, Span::new(0, 0))), // Placeholder
                    Span::new(start_span.start, self.position())
                ))
            }
        }
    }

    fn parse_expression(&mut self) -> Result<Ast, XsError> {
        self.parse_pipeline()
    }

    fn parse_pipeline(&mut self) -> Result<Ast, XsError> {
        let mut left = self.parse_application()?;
        
        while matches!(self.current_token, Some((Token::Pipe, _)) | Some((Token::PipeForward, _))) {
            let op_span = self.current_span();
            self.advance()?;
            let right = self.parse_application()?;
            
            // Convert to function application
            left = Ast::App(
                Box::new(right),
                Box::new(left),
                Span::new(op_span.start, self.position())
            );
        }
        
        Ok(left)
    }

    fn parse_application(&mut self) -> Result<Ast, XsError> {
        let mut expr = self.parse_primary()?;
        
        // Handle function application
        while self.is_application_start() {
            let arg = self.parse_primary()?;
            expr = Ast::App(
                Box::new(expr),
                Box::new(arg),
                Span::new(expr.span().start, self.position())
            );
        }
        
        Ok(expr)
    }

    fn parse_primary(&mut self) -> Result<Ast, XsError> {
        match &self.current_token {
            Some((Token::Int(n), span)) => {
                let val = *n;
                let span = *span;
                self.advance()?;
                Ok(Ast::Int(val, span))
            }
            Some((Token::Float(f), span)) => {
                let val = *f;
                let span = *span;
                self.advance()?;
                Ok(Ast::Float(val, span))
            }
            Some((Token::Bool(b), span)) => {
                let val = *b;
                let span = *span;
                self.advance()?;
                Ok(Ast::Bool(val, span))
            }
            Some((Token::String(s), span)) => {
                let val = s.clone();
                let span = *span;
                self.advance()?;
                Ok(Ast::String(val, span))
            }
            Some((Token::Symbol(s), span)) => {
                let val = s.clone();
                let span = *span;
                self.advance()?;
                Ok(Ast::Symbol(val, span))
            }
            Some((Token::LeftParen, _)) => {
                self.advance()?;
                let expr = self.parse_expression()?;
                self.expect_token(Token::RightParen)?;
                Ok(expr)
            }
            Some((Token::LeftBrace, span)) => {
                let start = span.start;
                self.parse_block(start)
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
            Some((Token::At, span)) => {
                let span = *span;
                self.advance()?;
                // Parse hole with optional type annotation
                if matches!(self.current_token, Some((Token::Colon, _))) {
                    self.advance()?;
                    let _type_expr = self.parse_type_expression()?;
                    // For now, return a placeholder
                    Ok(Ast::Symbol("@hole".to_string(), span))
                } else {
                    Ok(Ast::Symbol("@hole".to_string(), span))
                }
            }
            _ => Err(XsError::ParseError(
                self.position(),
                format!("Unexpected token: {:?}", self.current_token)
            ))
        }
    }

    fn parse_block(&mut self, start: usize) -> Result<Ast, XsError> {
        self.expect_token(Token::LeftBrace)?;
        let mut expressions = Vec::new();
        
        while !matches!(self.current_token, Some((Token::RightBrace, _))) {
            // Skip newlines in blocks
            if matches!(self.current_token, Some((Token::Newline, _))) {
                self.advance()?;
                continue;
            }
            
            let expr = self.parse_expression()?;
            expressions.push(expr);
            
            // Consume optional semicolon or newline
            if matches!(self.current_token, Some((Token::Semicolon, _)) | Some((Token::Newline, _))) {
                self.advance()?;
            }
        }
        
        self.expect_token(Token::RightBrace)?;
        
        if expressions.is_empty() {
            Ok(Ast::Int(0, Span::new(start, self.position())))
        } else if expressions.len() == 1 {
            Ok(expressions.into_iter().next().unwrap())
        } else {
            // Return the last expression
            Ok(expressions.into_iter().last().unwrap())
        }
    }

    fn parse_list(&mut self, start: usize) -> Result<Ast, XsError> {
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
        Ok(Ast::List(elements, Span::new(start, self.position())))
    }

    fn parse_lambda(&mut self, start: usize) -> Result<Ast, XsError> {
        self.expect_token(Token::Fn)?;
        
        // Parse parameters
        let mut params = Vec::new();
        
        // Check if parameters are in parentheses
        if matches!(self.current_token, Some((Token::LeftParen, _))) {
            self.advance()?;
            while !matches!(self.current_token, Some((Token::RightParen, _))) {
                params.push(self.parse_identifier()?);
                if matches!(self.current_token, Some((Token::Comma, _))) {
                    self.advance()?;
                }
            }
            self.expect_token(Token::RightParen)?;
        } else {
            // Single parameter without parentheses
            params.push(self.parse_identifier()?);
        }
        
        self.expect_token(Token::Arrow)?;
        let body = self.parse_expression()?;
        
        // Create nested lambdas for multiple parameters
        let lambda = params.into_iter()
            .rev()
            .fold(body, |acc, param| {
                Ast::Lambda(
                    vec![param],
                    Box::new(acc),
                    Span::new(start, self.position())
                )
            });
        
        Ok(lambda)
    }

    fn parse_if(&mut self, start: usize) -> Result<Ast, XsError> {
        self.expect_token(Token::If)?;
        let condition = self.parse_expression()?;
        
        // Expect block for then branch
        if !matches!(self.current_token, Some((Token::LeftBrace, _))) {
            return Err(XsError::ParseError(
                self.position(),
                "Expected '{' after if condition".to_string()
            ));
        }
        
        let then_branch = self.parse_block(start)?;
        
        self.expect_token(Token::Else)?;
        
        // Else branch must also be a block
        if !matches!(self.current_token, Some((Token::LeftBrace, _))) {
            return Err(XsError::ParseError(
                self.position(),
                "Expected '{' after else".to_string()
            ));
        }
        
        let else_branch = self.parse_block(start)?;
        
        Ok(Ast::If(
            Box::new(condition),
            Box::new(then_branch),
            Box::new(else_branch),
            Span::new(start, self.position())
        ))
    }

    fn parse_case(&mut self, start: usize) -> Result<Ast, XsError> {
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
        
        let mut branches = Vec::new();
        
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
            
            branches.push((pattern, body));
            
            // Consume optional semicolon or newline
            if matches!(self.current_token, Some((Token::Semicolon, _)) | Some((Token::Newline, _))) {
                self.advance()?;
            }
        }
        
        self.expect_token(Token::RightBrace)?;
        
        // Convert to Match AST
        Ok(Ast::Match(
            Box::new(expr),
            branches,
            Span::new(start, self.position())
        ))
    }

    fn parse_pattern(&mut self) -> Result<Ast, XsError> {
        match &self.current_token {
            Some((Token::Symbol(s), span)) => {
                let name = s.clone();
                let span = *span;
                self.advance()?;
                
                // Check for constructor pattern
                if self.is_pattern_continuation() {
                    let mut args = vec![Ast::Symbol(name.clone(), span)];
                    while self.is_pattern_continuation() {
                        args.push(self.parse_pattern()?);
                    }
                    Ok(Ast::List(args, span))
                } else {
                    Ok(Ast::Symbol(name, span))
                }
            }
            Some((Token::Underscore, span)) => {
                let span = *span;
                self.advance()?;
                Ok(Ast::Symbol("_".to_string(), span))
            }
            Some((Token::Int(n), span)) => {
                let val = *n;
                let span = *span;
                self.advance()?;
                Ok(Ast::Int(val, span))
            }
            Some((Token::String(s), span)) => {
                let val = s.clone();
                let span = *span;
                self.advance()?;
                Ok(Ast::String(val, span))
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

    fn parse_list_pattern(&mut self) -> Result<Ast, XsError> {
        let start = self.position();
        self.expect_token(Token::LeftBracket)?;
        let mut elements = Vec::new();
        
        while !matches!(self.current_token, Some((Token::RightBracket, _))) {
            elements.push(self.parse_pattern()?);
            
            if matches!(self.current_token, Some((Token::Comma, _))) {
                self.advance()?;
            } else if matches!(self.current_token, Some((Token::Ellipsis, _))) {
                self.advance()?;
                // Rest pattern
                let rest = self.parse_pattern()?;
                elements.push(Ast::Symbol("...".to_string(), Span::new(start, self.position())));
                elements.push(rest);
                break;
            }
        }
        
        self.expect_token(Token::RightBracket)?;
        Ok(Ast::List(elements, Span::new(start, self.position())))
    }

    fn parse_type_definition(&mut self) -> Result<Ast, XsError> {
        let start = self.position();
        self.expect_token(Token::Type)?;
        let _name = self.parse_identifier()?;
        self.expect_token(Token::Equals)?;
        let _type_expr = self.parse_type_expression()?;
        
        // For now, return a placeholder
        Ok(Ast::Symbol("type_def".to_string(), Span::new(start, self.position())))
    }

    fn parse_data_definition(&mut self) -> Result<Ast, XsError> {
        let start = self.position();
        self.expect_token(Token::Data)?;
        let _name = self.parse_identifier()?;
        
        // Parse type parameters
        while self.is_identifier() {
            let _param = self.parse_identifier()?;
        }
        
        self.expect_token(Token::Equals)?;
        
        // Parse constructors
        while !self.is_end_of_definition() {
            if matches!(self.current_token, Some((Token::Pipe, _))) {
                self.advance()?;
            }
            let _constructor = self.parse_identifier()?;
            
            // Parse constructor arguments
            while self.is_type_expression_start() {
                let _arg_type = self.parse_type_expression()?;
            }
        }
        
        // For now, return a placeholder
        Ok(Ast::Symbol("data_def".to_string(), Span::new(start, self.position())))
    }

    fn parse_effect_definition(&mut self) -> Result<Ast, XsError> {
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
        Ok(Ast::Symbol("effect_def".to_string(), Span::new(start, self.position())))
    }

    fn parse_import(&mut self) -> Result<Ast, XsError> {
        let start = self.position();
        self.expect_token(Token::Import)?;
        let _module_path = self.parse_module_path()?;
        
        if matches!(self.current_token, Some((Token::As, _))) {
            self.advance()?;
            let _alias = self.parse_identifier()?;
        }
        
        // For now, return a placeholder
        Ok(Ast::Symbol("import".to_string(), Span::new(start, self.position())))
    }

    fn parse_module_definition(&mut self) -> Result<Ast, XsError> {
        let start = self.position();
        self.expect_token(Token::Module)?;
        let _name = self.parse_identifier()?;
        
        self.expect_token(Token::LeftBrace)?;
        
        // Parse module body
        while !matches!(self.current_token, Some((Token::RightBrace, _))) {
            if matches!(self.current_token, Some((Token::Newline, _))) {
                self.advance()?;
                continue;
            }
            
            // Parse module members
            let _member = self.parse_expression()?;
            
            if matches!(self.current_token, Some((Token::Semicolon, _)) | Some((Token::Newline, _))) {
                self.advance()?;
            }
        }
        
        self.expect_token(Token::RightBrace)?;
        
        // For now, return a placeholder
        Ok(Ast::Symbol("module".to_string(), Span::new(start, self.position())))
    }

    fn parse_type_expression(&mut self) -> Result<Ast, XsError> {
        // Simple type parser for now
        if self.is_identifier() {
            self.parse_identifier().map(|name| Ast::Symbol(name, self.current_span()))
        } else {
            Err(XsError::ParseError(
                self.position(),
                "Expected type expression".to_string()
            ))
        }
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
            Some((Token::String(_), _)) |
            Some((Token::LeftBracket, _)) |
            Some((Token::LeftParen, _)) => true,
            _ => false
        }
    }

    fn is_type_expression_start(&self) -> bool {
        matches!(self.current_token, Some((Token::Symbol(_), _)))
    }

    fn is_end_of_definition(&self) -> bool {
        matches!(
            self.current_token,
            Some((Token::Newline, _)) |
            Some((Token::Semicolon, _)) |
            Some((Token::RightBrace, _)) |
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