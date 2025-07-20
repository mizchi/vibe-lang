//! Helper functions to reduce duplication in parser

use crate::{Parser, Token};
use xs_core::{Ident, Type, XsError};

impl<'a> Parser<'a> {
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
    /// Parse a required symbol and return it as a String
    pub(crate) fn parse_required_symbol(&mut self, error_msg: &str) -> Result<String, XsError> {
        match &self.current_token {
            Some((Token::Symbol(name), _)) => {
                let name = name.clone();
                self.advance()?;
                Ok(name)
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

    /// Parse a required identifier
    pub(crate) fn parse_required_ident(&mut self, error_msg: &str) -> Result<Ident, XsError> {
        self.parse_required_symbol(error_msg).map(Ident)
    }

    /// Parse optional type parameters (lowercase symbols)
    pub(crate) fn parse_type_params(&mut self) -> Result<Vec<String>, XsError> {
        let mut type_params = Vec::new();
        while let Some((Token::Symbol(param), _)) = &self.current_token {
            if param.chars().next().is_some_and(|c| c.is_lowercase()) {
                type_params.push(param.clone());
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
            Some((token, _)) if std::mem::discriminant(token) == std::mem::discriminant(&expected) => {
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

    /// Parse a list of items until a closing token
    pub(crate) fn parse_list_until<T, F>(
        &mut self,
        closing: Token,
        mut parse_item: F,
    ) -> Result<Vec<T>, XsError>
    where
        F: FnMut(&mut Self) -> Result<T, XsError>,
    {
        let mut items = Vec::new();
        loop {
            if let Some((token, _)) = &self.current_token {
                if std::mem::discriminant(token) == std::mem::discriminant(&closing) {
                    break;
                }
            }
            items.push(parse_item(self)?);
        }
        Ok(items)
    }

    /// Check if current token matches and return true/false without consuming
    pub(crate) fn check_token(&self, expected: &Token) -> bool {
        match &self.current_token {
            Some((token, _)) => std::mem::discriminant(token) == std::mem::discriminant(expected),
            None => false,
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
            _ => Err(self.parse_error(format!("Expected ')' {}", context))),
        }
    }

    /// Parse a constructor-like structure (Name field1 field2 ...)
    pub(crate) fn parse_constructor_form<F, T>(
        &mut self,
        name_validator: F,
        error_msg: &str,
    ) -> Result<(String, Vec<T>), XsError>
    where
        F: Fn(&str) -> bool,
        T: std::fmt::Debug,
    {
        self.expect_token(Token::LeftParen, "Expected '(' for constructor")?;
        
        let name = match &self.current_token {
            Some((Token::Symbol(name), _)) => {
                if !name_validator(name) {
                    return Err(self.parse_error(error_msg));
                }
                let name = name.clone();
                self.advance()?;
                name
            }
            _ => return Err(self.parse_error(error_msg)),
        };

        Ok((name, Vec::new()))
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
}