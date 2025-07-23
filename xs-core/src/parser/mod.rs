mod effect_parser;
pub mod lexer;
mod metadata_parser;
mod parser_helpers;
mod test_effects;

pub use crate::metadata::MetadataStore;
pub use metadata_parser::parse_with_metadata;

use crate::{Expr, Span, XsError};
use lexer::{Lexer, Token};

// Re-export the main parse function
pub fn parse(input: &str) -> Result<Expr, XsError> {
    // Use new parser v2 by default
    use crate::parser_v2::Parser as ParserV2;
    let mut parser = ParserV2::new(input)?;
    parser.parse()
}

// Legacy parser function (for backward compatibility)
pub fn parse_legacy(input: &str) -> Result<Expr, XsError> {
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
