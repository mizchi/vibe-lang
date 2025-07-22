mod effect_parser;
pub mod lexer;
mod metadata_parser;
mod parser_helpers;
mod test_effects;
mod test_patterns;

pub use crate::metadata::MetadataStore;
pub use metadata_parser::parse_with_metadata;

use crate::{Expr, Span, XsError};
use lexer::{Lexer, Token};

// Re-export the main parse function
pub fn parse(input: &str) -> Result<Expr, XsError> {
    let mut parser = Parser::new(input);
    parser.parse_expr()
}

pub fn parse_module(input: &str) -> Result<crate::Module, XsError> {
    let mut parser = Parser::new(input);
    parser.parse_module()
}

pub struct Parser<'a> {
    lexer: Lexer<'a>,
    current_token: Option<(Token, Span)>,
}

// Import helper implementations
