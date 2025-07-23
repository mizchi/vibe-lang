//! Unified Parser for S-expressions and Shell Syntax
//!
//! This module provides a unified parsing interface that can handle both
//! S-expressions and shell syntax, allowing them to coexist in the same
//! workspace and share the same semantics.

use xs_core::{Expr, XsError};
use crate::shell_syntax::{parse_shell_syntax, shell_to_sexpr};

/// Unified expression that can be either S-expression or shell syntax
#[derive(Debug, Clone)]
pub enum UnifiedExpr {
    /// Traditional S-expression
    SExpr(Expr),
    /// Shell syntax that will be converted to S-expression
    Shell(String),
    /// Mixed expression with embedded shell commands
    Mixed(Vec<UnifiedExpr>),
}

/// Parse a line of input with specified mode
pub fn parse_unified_with_mode(input: &str, mode: SyntaxMode) -> Result<Expr, XsError> {
    let input = input.trim();
    
    // Empty input
    if input.is_empty() {
        return Err(XsError::ParseError(
            0,
            "Empty input".to_string()
        ));
    }
    
    match mode {
        SyntaxMode::SExprOnly => {
            xs_core::parser::parse(input)
        }
        SyntaxMode::ShellOnly => {
            parse_as_shell(input)
        }
        SyntaxMode::Auto => {
            parse_unified(input)
        }
        SyntaxMode::Mixed => {
            // For now, same as Auto. Future: support embedded syntax
            parse_unified(input)
        }
    }
}

/// Parse a line of input, automatically detecting syntax type
pub fn parse_unified(input: &str) -> Result<Expr, XsError> {
    let input = input.trim();
    
    // Empty input
    if input.is_empty() {
        return Err(XsError::ParseError(
            0,
            "Empty input".to_string()
        ));
    }
    
    // Check if it's an S-expression
    if input.starts_with('(') {
        // Try to parse as S-expression first
        match xs_core::parser::parse(input) {
            Ok(expr) => Ok(expr),
            Err(_) => {
                // If S-expression parsing fails, try shell syntax
                parse_as_shell(input)
            }
        }
    } else if looks_like_shell_command(input) {
        // Parse as shell syntax
        parse_as_shell(input)
    } else if looks_like_function_call(input) {
        // Parse as function call in shell syntax
        parse_as_shell(input)
    } else {
        // Try S-expression first (for single identifiers, literals, etc.)
        match xs_core::parser::parse(input) {
            Ok(expr) => Ok(expr),
            Err(_) => {
                // Fall back to shell syntax
                parse_as_shell(input)
            }
        }
    }
}

/// Check if input looks like a shell command
fn looks_like_shell_command(input: &str) -> bool {
    // Pipeline syntax
    if input.contains('|') {
        return true;
    }
    
    // Known shell commands
    let first_word = input.split_whitespace().next().unwrap_or("");
    matches!(
        first_word,
        "ls" | "search" | "filter" | "select" | "sort" | "take" | 
        "group" | "count" | "definitions" | "pipe"
    )
}

/// Check if input looks like a function call (identifier followed by arguments)
fn looks_like_function_call(input: &str) -> bool {
    let parts: Vec<&str> = input.split_whitespace().collect();
    
    // Need at least 2 parts for function call
    if parts.len() < 2 {
        return false;
    }
    
    let first = parts[0];
    
    // Check if first part is a valid identifier (not a number or string literal)
    if first.starts_with('"') || first.parse::<i64>().is_ok() || first.parse::<f64>().is_ok() {
        return false;
    }
    
    // Check if it's not a known shell command
    !matches!(
        first,
        "ls" | "search" | "filter" | "select" | "sort" | "take" | 
        "group" | "count" | "definitions" | "pipe" | "add" | "view" |
        "edit" | "update" | "undo" | "find" | "type-of" | "branch" |
        "merge" | "history" | "log" | "debug" | "trace" | "references" |
        "definition" | "hover" | "stats" | "dead-code" | "reachable" |
        "namespace" | "ns"
    )
}

/// Parse input as shell syntax and convert to S-expression
fn parse_as_shell(input: &str) -> Result<Expr, XsError> {
    match parse_shell_syntax(input) {
        Ok(shell_expr) => Ok(shell_to_sexpr(&shell_expr)),
        Err(e) => Err(XsError::ParseError(
            0,
            format!("Shell syntax error: {e}")
        ))
    }
}

/// Advanced parser that can handle mixed syntax (future enhancement)
pub struct MixedSyntaxParser {
    /// Whether to allow shell syntax
    #[allow(dead_code)]
    allow_shell: bool,
    /// Whether to allow embedded shell in S-expressions
    #[allow(dead_code)]
    allow_embedded: bool,
}

impl Default for MixedSyntaxParser {
    fn default() -> Self {
        Self::new()
    }
}

impl MixedSyntaxParser {
    pub fn new() -> Self {
        Self {
            allow_shell: true,
            allow_embedded: true,
        }
    }
    
    /// Parse with mixed syntax support
    pub fn parse(&self, input: &str) -> Result<Expr, XsError> {
        // For now, delegate to unified parser
        parse_unified(input)
    }
    
    /// Parse S-expression with embedded shell commands
    /// Example: (map $[ls | filter type function] process)
    pub fn parse_with_embedded(&self, input: &str) -> Result<Expr, XsError> {
        // Future enhancement: parse S-expressions with $[...] shell escapes
        parse_unified(input)
    }
}

/// Syntax mode for the REPL
#[derive(Debug, Clone, Copy, PartialEq)]
#[derive(Default)]
pub enum SyntaxMode {
    /// Only S-expressions
    SExprOnly,
    /// Only shell syntax
    ShellOnly,
    /// Auto-detect syntax (default)
    #[default]
    Auto,
    /// Mixed mode with embedded syntax
    Mixed,
}


/// Configuration for unified parsing
pub struct ParserConfig {
    pub mode: SyntaxMode,
    pub shell_aliases: Vec<(String, String)>,
    pub allow_unicode: bool,
}

impl Default for ParserConfig {
    fn default() -> Self {
        Self {
            mode: SyntaxMode::default(),
            shell_aliases: vec![
                ("def".to_string(), "definitions".to_string()),
                ("defs".to_string(), "definitions".to_string()),
                ("ll".to_string(), "ls -l".to_string()),
            ],
            allow_unicode: true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_parse_sexpr() {
        let input = "(+ 1 2)";
        let result = parse_unified(input).unwrap();
        // Should parse as S-expression
        match result {
            Expr::Apply { .. } => {}
            _ => panic!("Expected Apply expression"),
        }
    }
    
    #[test]
    fn test_parse_shell() {
        let input = "ls | filter kind function";
        let result = parse_unified(input).unwrap();
        // Should parse as shell and convert to S-expression
        match result {
            Expr::Apply { .. } => {}
            _ => panic!("Expected Apply expression"),
        }
    }
    
    #[test]
    fn test_auto_detect() {
        // S-expression
        assert!(parse_unified("(let x 10)").is_ok());
        
        // Shell command
        assert!(parse_unified("search type:Int").is_ok());
        
        // Pipeline
        assert!(parse_unified("ls | take 5").is_ok());
    }
}