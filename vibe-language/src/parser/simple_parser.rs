//! Simple parser implementation for testing parser
//! This is a minimal implementation to test the lexer and basic parsing

use super::lexer::{Lexer, Token};
use crate::{Expr, Ident, Literal, Span, XsError};

pub struct SimpleParser<'a> {
    lexer: Lexer<'a>,
    current_token: Option<(Token, Span)>,
}

impl<'a> SimpleParser<'a> {
    pub fn new(input: &'a str) -> Result<Self, XsError> {
        let mut lexer = Lexer::new(input);
        let current_token = lexer.next_token()?;

        Ok(SimpleParser {
            lexer,
            current_token,
        })
    }

    pub fn parse_expr(&mut self) -> Result<Expr, XsError> {
        match &self.current_token {
            Some((Token::Int(n), span)) => {
                let val = *n;
                let span = span.clone();
                self.advance()?;
                Ok(Expr::Literal(Literal::Int(val), span))
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
                Ok(Expr::Ident(Ident(val), span))
            }
            _ => Err(XsError::ParseError(
                self.position(),
                format!("Unexpected token: {:?}", self.current_token),
            )),
        }
    }

    fn advance(&mut self) -> Result<(), XsError> {
        self.current_token = self.lexer.next_token()?;
        Ok(())
    }

    fn position(&self) -> usize {
        self.current_token
            .as_ref()
            .map(|(_, span)| span.start)
            .unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Literal;

    #[test]
    fn test_parse_int() {
        let mut parser = SimpleParser::new("42").unwrap();
        let expr = parser.parse_expr().unwrap();
        match expr {
            Expr::Literal(Literal::Int(42), _) => {}
            _ => panic!("Expected Int literal"),
        }
    }

    #[test]
    fn test_parse_bool() {
        let mut parser = SimpleParser::new("true").unwrap();
        let expr = parser.parse_expr().unwrap();
        match expr {
            Expr::Literal(Literal::Bool(true), _) => {}
            _ => panic!("Expected Bool literal"),
        }
    }

    #[test]
    fn test_parse_string() {
        let mut parser = SimpleParser::new("\"hello\"").unwrap();
        let expr = parser.parse_expr().unwrap();
        match expr {
            Expr::Literal(Literal::String(s), _) if s == "hello" => {}
            _ => panic!("Expected String literal"),
        }
    }

    #[test]
    fn test_parse_identifier() {
        let mut parser = SimpleParser::new("foo").unwrap();
        let expr = parser.parse_expr().unwrap();
        match expr {
            Expr::Ident(Ident(name), _) if name == "foo" => {}
            _ => panic!("Expected Identifier"),
        }
    }
}
