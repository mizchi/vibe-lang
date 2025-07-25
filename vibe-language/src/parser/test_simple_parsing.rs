//! Simple parsing tests to debug issues

use super::*;
use crate::{Expr, Ident};

#[test]
fn test_parse_single_identifier() {
    let mut parser = Parser::new("x").unwrap();
    let expr = parser.parse().unwrap();
    
    match expr {
        Expr::Ident(Ident(name), _) => assert_eq!(name, "x"),
        _ => panic!("Expected Ident, got {:?}", expr),
    }
}

#[test]
fn test_parse_two_identifiers() {
    // Test with proper string
    let input = "x y";
    let mut parser = match Parser::new(input) {
        Ok(p) => p,
        Err(e) => panic!("Failed to create parser: {:?}", e),
    };
    let expr = match parser.parse() {
        Ok(e) => e,
        Err(e) => panic!("Parse failed: {:?}", e),
    };
    
    // Should parse as application: x y
    match expr {
        Expr::Apply { func, args, .. } => {
            match func.as_ref() {
                Expr::Ident(Ident(name), _) => assert_eq!(name, "x"),
                _ => panic!("Expected Ident(x)"),
            }
            assert_eq!(args.len(), 1);
            match &args[0] {
                Expr::Ident(Ident(name), _) => assert_eq!(name, "y"),
                _ => panic!("Expected Ident(y)"),
            }
        }
        _ => panic!("Expected Apply, got {:?}", expr),
    }
}