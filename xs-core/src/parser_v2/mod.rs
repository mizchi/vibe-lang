//! Parser V2 - New shell-friendly syntax parser for XS language
//! 
//! This parser implements the new syntax design described in docs/new_syntax.md
//! Goals:
//! - Shell-friendly syntax with block scopes using {}
//! - Pipeline operators with | as primary
//! - Interactive hole-filling with @ notation
//! - Automatic type inference embedding
//! - Algebraic data types with keyword arguments
//! - Content-addressing with hash-based references
//! - Effect System with Koka-style with/ctl

pub mod lexer;
pub mod parser;
pub mod ast_bridge;
pub mod simple_parser;

pub use lexer::Lexer;
pub use parser::Parser;
pub use simple_parser::SimpleParser;

#[cfg(test)]
mod tests;