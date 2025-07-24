//! Unified handling of keyword-based forms
//! 
//! This module provides a unified approach to parsing keyword-based constructs
//! like match, do, handle, etc. as function-like forms with block arguments.

use crate::{Expr, XsError, Span};
use super::Parser;

impl Parser {
    /// Parse any keyword form that takes a block argument
    /// Examples: match expr { ... }, do { ... }, handle expr { ... }
    pub fn parse_keyword_block_form(&mut self, keyword: &str, start: usize) -> Result<Expr, XsError> {
        match keyword {
            "match" => self.parse_match_unified(start),
            "do" => self.parse_do_unified(start),
            "handle" => self.parse_handle_unified(start),
            _ => Err(XsError::ParseError(
                self.position(),
                format!("Unknown keyword form: {}", keyword)
            ))
        }
    }
    
    /// Parse match expr { patterns }
    fn parse_match_unified(&mut self, start: usize) -> Result<Expr, XsError> {
        // Expression before block
        let expr = self.parse_expression()?;
        
        // Optional 'of' for compatibility
        if matches!(self.current_token, Some((crate::parser::lexer::Token::Of, _))) {
            self.advance()?;
        }
        
        // Block with patterns
        self.expect_block_start()?;
        let cases = self.parse_match_cases()?;
        self.expect_block_end()?;
        
        Ok(Expr::Match {
            expr: Box::new(expr),
            cases,
            span: Span::new(start, self.position())
        })
    }
    
    /// Parse do { statements }
    fn parse_do_unified(&mut self, start: usize) -> Result<Expr, XsError> {
        // Block with statements
        self.expect_block_start()?;
        let statements = self.parse_do_statements()?;
        self.expect_block_end()?;
        
        Ok(Expr::Do {
            statements,
            span: Span::new(start, self.position())
        })
    }
    
    /// Parse handle expr { handlers }
    fn parse_handle_unified(&mut self, start: usize) -> Result<Expr, XsError> {
        // Expression before block
        let expr = self.parse_expression()?;
        
        // Optional 'with' for compatibility
        if matches!(self.current_token, Some((crate::parser::lexer::Token::With, _))) {
            self.advance()?;
        }
        
        // Block with handlers
        self.expect_block_start()?;
        let (handlers, return_handler) = self.parse_handlers()?;
        self.expect_block_end()?;
        
        Ok(Expr::HandleExpr {
            expr: Box::new(expr),
            handlers,
            return_handler,
            span: Span::new(start, self.position())
        })
    }
    
    fn expect_block_start(&mut self) -> Result<(), XsError> {
        self.skip_newlines();
        self.expect_token(crate::parser::lexer::Token::LeftBrace)?;
        self.skip_newlines();
        Ok(())
    }
    
    fn expect_block_end(&mut self) -> Result<(), XsError> {
        self.expect_token(crate::parser::lexer::Token::RightBrace)?;
        Ok(())
    }
}