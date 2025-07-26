//! Parser - GLL-based parser for Vibe language
//!
//! This parser uses a Generalized LL (GLL) algorithm for parsing
//! Goals:
//! - Handle ambiguous grammars
//! - Shell-friendly syntax with block scopes using {}
//! - Pipeline operators with | as primary
//! - Interactive hole-filling with @ notation
//! - Automatic type inference embedding
//! - Algebraic data types with keyword arguments
//! - Content-addressing with hash-based references
//! - Effect System with Koka-style with/ctl

pub mod ast_bridge;
pub mod lexer;
pub mod experimental;

pub use lexer::Lexer;
pub use experimental::unified_vibe_parser::UnifiedVibeParser;

// Re-export for backward compatibility
pub use UnifiedVibeParser as Parser;

// Convenience function for parsing
pub fn parse(input: &str) -> Result<crate::Expr, crate::XsError> {
    let mut parser = UnifiedVibeParser::new();
    let exprs = parser.parse(input)
        .map_err(|e| crate::XsError::ParseError(0, e.to_string()))?;
    
    // Return the first expression or create a sequence if multiple
    match exprs.len() {
        0 => Err(crate::XsError::ParseError(
            0,
            "No expressions found".to_string()
        )),
        1 => Ok(exprs.into_iter().next().unwrap()),
        _ => {
            // Create a Block expression for multiple expressions
            Ok(crate::Expr::Block {
                exprs,
                span: crate::Span::new(0, 0)
            })
        }
    }
}

#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_do;
#[cfg(test)]
mod tests_handle;
