//! Helper functions to reduce duplication in parser

use super::{Parser, Token};
use crate::{Expr, Ident, Literal, Pattern, Span, Type, TypeDefinition, XsError};
use ordered_float::OrderedFloat;

impl<'a> Parser<'a> {
    /// Parse optional type annotation (: Type)
    fn parse_optional_type_annotation(&mut self) -> Result<Option<Type>, XsError> {
        if self.check_token(&Token::Colon) {
            self.advance()?; // consume ':'
            Ok(Some(self.parse_type()?))
        } else {
            Ok(None)
        }
    }

    /// Create a default span (to be updated with proper span tracking)
    fn default_span(&self) -> Span {
        Span::new(0, 0)
    }
    pub fn new(input: &'a str) -> Self {
        let mut lexer = super::lexer::Lexer::new(input);
        let current_token = lexer.next_token().ok().flatten();
        Parser {
            lexer,
            current_token,
        }
    }

    pub fn advance(&mut self) -> Result<(), XsError> {
        self.current_token = self.lexer.next_token()?;
        Ok(())
    }

    /// Get current token position for error reporting
    pub(crate) fn current_position(&self) -> usize {
        self.current_token
            .as_ref()
            .map(|(_, span)| span.start)
            .unwrap_or(0)
    }

    /// Create a parse error with current position
    pub(crate) fn parse_error(&self, message: impl Into<String>) -> XsError {
        XsError::ParseError(self.current_position(), message.into())
    }

    /// Check if current token matches expected
    pub(crate) fn check_token(&self, token: &Token) -> bool {
        matches!(&self.current_token, Some((t, _)) if std::mem::discriminant(t) == std::mem::discriminant(token))
    }

    /// Parse type parameters for type definitions
    pub(crate) fn parse_type_params(&mut self) -> Result<Vec<String>, XsError> {
        let mut type_params = Vec::new();
        while let Some((Token::Symbol(name), _)) = &self.current_token {
            if name.chars().all(|c| c.is_lowercase()) {
                type_params.push(name.clone());
                self.advance()?;
            } else {
                break;
            }
        }
        Ok(type_params)
    }

    /// Expect a specific token and consume it
    pub(crate) fn expect_token(&mut self, expected: Token, error_msg: &str) -> Result<(), XsError> {
        match &self.current_token {
            Some((token, _))
                if std::mem::discriminant(token) == std::mem::discriminant(&expected) =>
            {
                self.advance()?;
                Ok(())
            }
            _ => Err(XsError::ParseError(
                self.current_token
                    .as_ref()
                    .map(|(_, span)| span.start)
                    .unwrap_or(0),
                error_msg.to_string(),
            )),
        }
    }

    /// Consume closing parenthesis and return end position
    pub(crate) fn parse_closing_paren(&mut self, context: &str) -> Result<usize, XsError> {
        match &self.current_token {
            Some((Token::RightParen, span)) => {
                let end = span.end;
                self.advance()?;
                Ok(end)
            }
            _ => Err(self.parse_error(format!("Expected ')' {context}"))),
        }
    }

    /// Parse a list of items until encountering a specific token
    pub(crate) fn parse_list_until<T, F>(
        &mut self,
        end_token: Token,
        mut parser: F,
    ) -> Result<Vec<T>, XsError>
    where
        F: FnMut(&mut Self) -> Result<T, XsError>,
    {
        let mut items = Vec::new();
        while !self.check_token(&end_token) {
            items.push(parser(self)?);
        }
        Ok(items)
    }

    /// Parse function parameters with optional type annotations
    pub(crate) fn parse_typed_params(&mut self) -> Result<Vec<(Ident, Option<Type>)>, XsError> {
        self.expect_token(Token::LeftParen, "Expected '(' for parameters")?;

        let mut params = Vec::new();
        while let Some((Token::Symbol(param_name), _)) = &self.current_token {
            let ident = Ident(param_name.clone());
            self.advance()?;

            let type_ann = if self.check_token(&Token::Colon) {
                self.advance()?;
                Some(self.parse_type()?)
            } else {
                None
            };

            params.push((ident, type_ann));
        }

        self.parse_closing_paren("after parameters")?;
        Ok(params)
    }

    pub(super) fn parse_expr(&mut self) -> Result<Expr, XsError> {
        match &self.current_token {
            Some((Token::LeftParen, _)) => self.parse_parenthesized(),
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
                Ok(Expr::Literal(Literal::Float(OrderedFloat(val)), span))
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
            Some((Token::Symbol(name), span)) => {
                let module_name = Ident(name.clone());
                let start_span = span.clone();
                self.advance()?;

                // Check for qualified identifier (e.g., Int.toString)
                if let Some((Token::Dot, _)) = &self.current_token {
                    self.advance()?; // consume '.'

                    match &self.current_token {
                        Some((Token::Symbol(field_name), end_span)) => {
                            let name = Ident(field_name.clone());
                            let full_span = Span::new(start_span.start, end_span.end);
                            self.advance()?;
                            Ok(Expr::QualifiedIdent {
                                module_name,
                                name,
                                span: full_span,
                            })
                        }
                        Some((Token::Cons, end_span)) => {
                            // Special case for List.cons
                            let name = Ident("cons".to_string());
                            let full_span = Span::new(start_span.start, end_span.end);
                            self.advance()?;
                            Ok(Expr::QualifiedIdent {
                                module_name,
                                name,
                                span: full_span,
                            })
                        }
                        _ => Err(self.parse_error("Expected identifier after '.'")),
                    }
                } else {
                    Ok(Expr::Ident(module_name, start_span))
                }
            }
            Some((Token::Cons, span)) => {
                let ident = Ident("cons".to_string());
                let span = span.clone();
                self.advance()?;
                Ok(Expr::Ident(ident, span))
            }
            Some((token, _)) => Err(self.parse_error(format!("Unexpected token: {token:?}"))),
            None => Err(self.parse_error("Unexpected end of input".to_string())),
        }
    }

    fn parse_parenthesized(&mut self) -> Result<Expr, XsError> {
        let start = self
            .current_token
            .as_ref()
            .map(|(_, span)| span.start)
            .unwrap_or(0);
        self.advance()?; // consume '('

        if self.check_token(&Token::RightParen) {
            let end = self
                .current_token
                .as_ref()
                .map(|(_, span)| span.end)
                .unwrap_or(start);
            self.advance()?; // consume ')'
            return Ok(Expr::List(vec![], Span::new(start, end)));
        }

        match &self.current_token {
            Some((Token::Let, _)) => {
                let expr = self.parse_let()?;
                self.expect_token(Token::RightParen, "Expected ')'")?;
                Ok(expr)
            }
            Some((Token::LetRec, _)) => {
                let expr = self.parse_let_rec()?;
                self.expect_token(Token::RightParen, "Expected ')'")?;
                Ok(expr)
            }
            Some((Token::Rec, _)) => {
                let expr = self.parse_rec()?;
                self.expect_token(Token::RightParen, "Expected ')'")?;
                Ok(expr)
            }
            Some((Token::If, _)) => {
                let expr = self.parse_if()?;
                self.expect_token(Token::RightParen, "Expected ')'")?;
                Ok(expr)
            }
            Some((Token::Match, _)) => {
                let expr = self.parse_match()?;
                self.expect_token(Token::RightParen, "Expected ')'")?;
                Ok(expr)
            }
            Some((Token::List, _)) => {
                let expr = self.parse_list()?;
                self.expect_token(Token::RightParen, "Expected ')'")?;
                Ok(expr)
            }
            Some((Token::Fn, _)) => {
                let expr = self.parse_lambda()?;
                self.expect_token(Token::RightParen, "Expected ')'")?;
                Ok(expr)
            }
            Some((Token::Type, _)) => self.parse_type_definition(),
            Some((Token::Module, _)) => self.parse_module_expr(),
            Some((Token::Import, _)) => self.parse_import(),
            Some((Token::Symbol(_), _)) => self.parse_application(start),
            _ => self.parse_application(start),
        }
    }

    fn parse_let(&mut self) -> Result<Expr, XsError> {
        self.advance()?; // consume 'let'
        let name = self.parse_ident()?;
        let type_ann = self.parse_optional_type_annotation()?;
        let value = Box::new(self.parse_expr()?);
        
        // Check for 'in' keyword for let-in expression
        if self.check_token(&Token::In) {
            self.advance()?; // consume 'in'
            let body = Box::new(self.parse_expr()?);
            Ok(Expr::LetIn {
                name,
                type_ann,
                value,
                body,
                span: self.default_span(),
            })
        } else {
            Ok(Expr::Let {
                name,
                type_ann,
                value,
                span: self.default_span(),
            })
        }
    }

    fn parse_let_rec(&mut self) -> Result<Expr, XsError> {
        self.advance()?; // consume 'let-rec'
        let name = self.parse_ident()?;
        let type_ann = self.parse_optional_type_annotation()?;
        let value = Box::new(self.parse_expr()?);

        Ok(Expr::LetRec {
            name,
            type_ann,
            value,
            span: self.default_span(),
        })
    }

    fn parse_rec(&mut self) -> Result<Expr, XsError> {
        self.advance()?; // consume 'rec'
        let name = self.parse_ident()?;
        let params = self.parse_typed_params()?;
        let return_type = self.parse_optional_type_annotation()?;
        let body = Box::new(self.parse_expr()?);
        
        Ok(Expr::Rec {
            name,
            params,
            return_type,
            body,
            span: self.default_span(),
        })
    }

    fn parse_if(&mut self) -> Result<Expr, XsError> {
        self.advance()?; // consume 'if'
        let cond = Box::new(self.parse_expr()?);
        let then_expr = Box::new(self.parse_expr()?);
        let else_expr = Box::new(self.parse_expr()?);
        let span = Span::new(0, 0); // Will be updated with proper span tracking
        Ok(Expr::If {
            cond,
            then_expr,
            else_expr,
            span,
        })
    }

    fn parse_match(&mut self) -> Result<Expr, XsError> {
        self.advance()?; // consume 'match'
        let expr = Box::new(self.parse_expr()?);
        let mut cases = Vec::new();

        while !self.check_token(&Token::RightParen) {
            self.expect_token(Token::LeftParen, "Expected '(' for match case")?;
            let pattern = self.parse_pattern()?;
            let body = self.parse_expr()?;
            self.expect_token(Token::RightParen, "Expected ')' after match case")?;
            cases.push((pattern, body));
        }

        let span = Span::new(0, 0); // Will be updated with proper span tracking
        Ok(Expr::Match { expr, cases, span })
    }

    fn parse_list(&mut self) -> Result<Expr, XsError> {
        self.advance()?; // consume 'list'
        let mut elements = Vec::new();

        while !self.check_token(&Token::RightParen) {
            elements.push(self.parse_expr()?);
        }

        let span = Span::new(0, 0); // Will be updated with proper span tracking
        Ok(Expr::List(elements, span))
    }

    fn parse_lambda(&mut self) -> Result<Expr, XsError> {
        self.advance()?; // consume 'fn'
        let params = self.parse_typed_params()?;
        let body = Box::new(self.parse_expr()?);
        let span = Span::new(0, 0); // Will be updated with proper span tracking
        Ok(Expr::Lambda { params, body, span })
    }

    #[allow(dead_code)]
    fn parse_simple_expr(&mut self) -> Result<Expr, XsError> {
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
                Ok(Expr::Literal(Literal::Float(OrderedFloat(val)), span))
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
            Some((Token::Symbol(name), span)) => {
                let ident = Ident(name.clone());
                let span = span.clone();
                self.advance()?;
                Ok(Expr::Ident(ident, span))
            }
            Some((Token::LeftParen, _)) => self.parse_parenthesized(),
            _ => Err(self.parse_error("Expected expression".to_string())),
        }
    }

    fn parse_application(&mut self, start: usize) -> Result<Expr, XsError> {
        let func = Box::new(self.parse_expr()?);
        let mut args = Vec::new();

        while !self.check_token(&Token::RightParen) {
            args.push(self.parse_expr()?);
        }

        let end = self
            .current_token
            .as_ref()
            .map(|(_, span)| span.end)
            .unwrap_or(start);
        self.advance()?; // consume ')'

        Ok(Expr::Apply {
            func,
            args,
            span: Span::new(start, end),
        })
    }

    fn parse_ident(&mut self) -> Result<Ident, XsError> {
        match &self.current_token {
            Some((Token::Symbol(name), _)) => {
                let ident = Ident(name.clone());
                self.advance()?;
                Ok(ident)
            }
            _ => Err(self.parse_error("Expected identifier".to_string())),
        }
    }

    #[allow(dead_code)]
    pub(crate) fn parse_required_ident(&mut self, error_msg: &str) -> Result<Ident, XsError> {
        match &self.current_token {
            Some((Token::Symbol(name), _)) => {
                let ident = Ident(name.clone());
                self.advance()?;
                Ok(ident)
            }
            _ => Err(self.parse_error(error_msg)),
        }
    }

    #[allow(dead_code)]
    pub(crate) fn parse_required_symbol(&mut self, error_msg: &str) -> Result<String, XsError> {
        match &self.current_token {
            Some((Token::Symbol(name), _)) => {
                let symbol = name.clone();
                self.advance()?;
                Ok(symbol)
            }
            _ => Err(self.parse_error(error_msg)),
        }
    }

    fn parse_pattern(&mut self) -> Result<Pattern, XsError> {
        match &self.current_token {
            Some((Token::Underscore, span)) => {
                let span = span.clone();
                self.advance()?;
                Ok(Pattern::Wildcard(span))
            }
            Some((Token::Symbol(name), span)) if name == "_" => {
                let span = span.clone();
                self.advance()?;
                Ok(Pattern::Wildcard(span))
            }
            Some((Token::Symbol(name), span)) => {
                let ident = Ident(name.clone());
                let span = span.clone();
                self.advance()?;
                Ok(Pattern::Variable(ident, span))
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
            Some((Token::LeftParen, _)) => {
                self.advance()?; // consume '('
                match &self.current_token {
                    Some((Token::List, _)) => self.parse_list_pattern(),
                    Some((Token::Symbol(s), _)) if s == "list" => self.parse_list_pattern(),
                    _ => self.parse_constructor_pattern(),
                }
            }
            _ => Err(self.parse_error("Expected pattern".to_string())),
        }
    }

    fn parse_list_pattern(&mut self) -> Result<Pattern, XsError> {
        self.advance()?; // consume 'list'
        let mut patterns = Vec::new();

        while !self.check_token(&Token::RightParen) {
            patterns.push(self.parse_pattern()?);
        }

        let span = Span::new(0, 0); // Will be updated with proper span tracking
        self.advance()?; // consume ')'
        Ok(Pattern::List { patterns, span })
    }

    fn parse_constructor_pattern(&mut self) -> Result<Pattern, XsError> {
        let name = match &self.current_token {
            Some((Token::Symbol(n), _)) => {
                let name = Ident(n.clone());
                self.advance()?;
                name
            }
            _ => return Err(self.parse_error("Expected constructor name".to_string())),
        };

        let mut patterns = Vec::new();
        while !self.check_token(&Token::RightParen) {
            patterns.push(self.parse_pattern()?);
        }

        let span = Span::new(0, 0); // Will be updated with proper span tracking
        self.advance()?; // consume ')'
        Ok(Pattern::Constructor {
            name,
            patterns,
            span,
        })
    }

    pub fn parse_type(&mut self) -> Result<Type, XsError> {
        match &self.current_token {
            Some((Token::Symbol(name), _)) => {
                let type_name = name.clone();
                self.advance()?;
                match type_name.as_str() {
                    "Int" => Ok(Type::Int),
                    "Float" => Ok(Type::Float),
                    "Bool" => Ok(Type::Bool),
                    "String" => Ok(Type::String),
                    _ => Ok(Type::Var(type_name)),
                }
            }
            Some((Token::LeftParen, _)) => {
                self.advance()?; // consume '('

                // Check for arrow first
                if let Some((Token::Arrow, _)) = &self.current_token {
                    self.parse_function_type()
                } else if let Some((Token::Symbol(s), _)) = &self.current_token {
                    if s == "List" {
                        self.parse_list_type()
                    } else {
                        // UserDefined type with parameters
                        let name = s.clone();
                        self.advance()?;
                        let mut params = Vec::new();
                        while !self.check_token(&Token::RightParen) {
                            params.push(self.parse_type()?);
                        }
                        self.advance()?; // consume ')'
                        Ok(Type::UserDefined {
                            name,
                            type_params: params,
                        })
                    }
                } else {
                    // UserDefined type with parameters
                    let name = match &self.current_token {
                        Some((Token::Symbol(n), _)) => {
                            let name = n.clone();
                            self.advance()?;
                            name
                        }
                        _ => return Err(self.parse_error("Expected type name".to_string())),
                    };

                    let mut args = Vec::new();
                    while !self.check_token(&Token::RightParen) {
                        args.push(self.parse_type()?);
                    }

                    self.advance()?; // consume ')'
                    Ok(Type::UserDefined {
                        name,
                        type_params: args,
                    })
                }
            }
            _ => Err(self.parse_error("Expected type".to_string())),
        }
    }

    fn parse_function_type(&mut self) -> Result<Type, XsError> {
        self.advance()?; // consume '->'
        let arg_type = Box::new(self.parse_type()?);
        let return_type = Box::new(self.parse_type()?);

        // Check for effect annotation '!'
        if let Some((Token::Exclamation, _)) = &self.current_token {
            self.advance()?; // consume '!'
            let effects = self.parse_effect_row()?;
            self.advance()?; // consume ')'
            return Ok(Type::FunctionWithEffect {
                from: arg_type,
                to: return_type,
                effects,
            });
        }

        self.advance()?; // consume ')'
        Ok(Type::Function(arg_type, return_type))
    }

    fn parse_list_type(&mut self) -> Result<Type, XsError> {
        self.advance()?; // consume 'List'
        let elem_type = Box::new(self.parse_type()?);
        self.advance()?; // consume ')'
        Ok(Type::List(elem_type))
    }

    fn parse_effect_row(&mut self) -> Result<crate::EffectRow, XsError> {
        use crate::{Effect, EffectRow, EffectSet, EffectVar};

        match &self.current_token {
            Some((Token::Symbol(name), _)) => {
                // Check if it's a known effect name first
                match name.as_str() {
                    "IO" | "Error" | "State" | "Async" | "Network" | "FileSystem" | "Random"
                    | "Time" | "Log" => {
                        // Single effect without braces
                        let effect = match name.as_str() {
                            "IO" => Effect::IO,
                            "Error" => Effect::Error,
                            "State" => Effect::State,
                            "Async" => Effect::Async,
                            "Network" => Effect::Network,
                            "FileSystem" => Effect::FileSystem,
                            "Random" => Effect::Random,
                            "Time" => Effect::Time,
                            "Log" => Effect::Log,
                            _ => unreachable!(),
                        };
                        self.advance()?;
                        Ok(EffectRow::Concrete(EffectSet::single(effect)))
                    }
                    _ => {
                        // Effect variable
                        let var_name = name.clone();
                        self.advance()?;
                        Ok(EffectRow::Variable(EffectVar(var_name)))
                    }
                }
            }
            Some((Token::LeftBrace, _)) => {
                // Effect set {IO, Error}
                self.advance()?; // consume '{'
                let mut effects = Vec::new();

                while !self.check_token(&Token::RightBrace) {
                    if let Some((Token::Symbol(effect_name), _)) = &self.current_token {
                        let effect = match effect_name.as_str() {
                            "IO" => Effect::IO,
                            "Error" => Effect::Error,
                            "State" => Effect::State,
                            "Async" => Effect::Async,
                            "Network" => Effect::Network,
                            "FileSystem" => Effect::FileSystem,
                            "Random" => Effect::Random,
                            "Time" => Effect::Time,
                            "Log" => Effect::Log,
                            _ => {
                                return Err(
                                    self.parse_error(format!("Unknown effect: {effect_name}"))
                                )
                            }
                        };
                        effects.push(effect);
                        self.advance()?;

                        // Skip comma if present
                        if let Some((Token::Comma, _)) = &self.current_token {
                            self.advance()?;
                        }
                    } else {
                        return Err(self.parse_error("Expected effect name"));
                    }
                }

                self.advance()?; // consume '}'
                Ok(EffectRow::Concrete(EffectSet::from_effects(effects)))
            }
            _ => Err(self.parse_error("Expected effect specification")),
        }
    }

    fn parse_type_definition(&mut self) -> Result<Expr, XsError> {
        self.advance()?; // consume 'type'

        let name = self.parse_ident()?;
        let type_params = self.parse_type_params()?;

        let mut constructors = Vec::new();
        while !self.check_token(&Token::RightParen) {
            self.expect_token(Token::LeftParen, "Expected '(' for constructor")?;
            let cons_name = self.parse_ident()?;
            let mut fields = Vec::new();

            while !self.check_token(&Token::RightParen) {
                fields.push(self.parse_type()?);
            }

            self.advance()?; // consume ')'
            constructors.push(crate::Constructor {
                name: cons_name.0,
                fields,
            });
        }

        self.advance()?; // consume ')'

        Ok(Expr::TypeDef {
            definition: TypeDefinition {
                name: name.0,
                type_params,
                constructors,
            },
            span: Span::new(0, 0),
        })
    }

    fn parse_module_expr(&mut self) -> Result<Expr, XsError> {
        self.advance()?; // consume 'module'
        let name = self.parse_ident()?;

        // Parse exports
        let mut exports = Vec::new();
        if self.check_token(&Token::LeftParen) {
            self.advance()?; // consume '('
            if self.check_token(&Token::Export) {
                self.advance()?; // consume 'export'
                while !self.check_token(&Token::RightParen) {
                    exports.push(self.parse_ident()?);
                }
                self.advance()?; // consume ')'
            }
        }

        // Parse body
        let mut body = Vec::new();
        while !self.check_token(&Token::RightParen) {
            body.push(self.parse_expr()?);
        }

        self.advance()?; // consume ')'

        Ok(Expr::Module {
            name,
            exports,
            body,
            span: Span::new(0, 0),
        })
    }

    fn parse_import(&mut self) -> Result<Expr, XsError> {
        self.advance()?; // consume 'import'
        let module_name = self.parse_ident()?;

        let as_name = if let Some((Token::Symbol(s), _)) = &self.current_token {
            if s == "as" {
                self.advance()?; // consume 'as'
                Some(self.parse_ident()?)
            } else {
                None
            }
        } else {
            None
        };

        self.advance()?; // consume ')'

        Ok(Expr::Import {
            module_name,
            items: None, // Simple import without specific items
            as_name,
            span: Span::new(0, 0),
        })
    }

    pub(super) fn parse_module(&mut self) -> Result<crate::Module, XsError> {
        let mut imports = Vec::new();
        let mut definitions = Vec::new();
        let mut type_definitions = Vec::new();

        while self.current_token.is_some() {
            match self.parse_expr()? {
                Expr::Import {
                    module_name,
                    as_name,
                    ..
                } => {
                    imports.push((module_name.0, as_name.map(|n| n.0)));
                }
                Expr::TypeDef { definition, .. } => {
                    type_definitions.push(definition);
                }
                expr => definitions.push(expr),
            }
        }

        Ok(crate::Module {
            name: "main".to_string(),
            imports,
            exports: vec![],
            definitions,
            type_definitions,
        })
    }
}
