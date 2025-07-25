//! Tests for top-level function application parsing

use super::*;
use crate::{Expr, Ident, Literal};

#[test]
fn test_parse_top_level_application_simple() {
    // Test: add 3 4
    let source = "add 3 4";
    let expr = parse(source).unwrap();
    
    match expr {
        Expr::Apply { func, args, .. } => {
            // func should be "add 3"
            match func.as_ref() {
                Expr::Apply { func: inner_func, args: inner_args, .. } => {
                    // inner_func should be "add"
                    match inner_func.as_ref() {
                        Expr::Ident(Ident(name), _) => assert_eq!(name, "add"),
                        _ => panic!("Expected Ident(add)"),
                    }
                    // inner_args should be [3]
                    assert_eq!(inner_args.len(), 1);
                    match &inner_args[0] {
                        Expr::Literal(Literal::Int(3), _) => {},
                        _ => panic!("Expected Literal(3)"),
                    }
                }
                _ => panic!("Expected nested Apply"),
            }
            // args should be [4]
            assert_eq!(args.len(), 1);
            match &args[0] {
                Expr::Literal(Literal::Int(4), _) => {},
                _ => panic!("Expected Literal(4)"),
            }
        }
        _ => panic!("Expected Apply, got {:?}", expr),
    }
}

#[test]
fn test_parse_top_level_application_multiple() {
    // Test: fold add 0 list
    let source = "fold add 0 list";
    let expr = parse(source).unwrap();
    
    // Should parse as ((fold add) 0) list
    match expr {
        Expr::Apply {  args, .. } => {
            // Check that it's properly left-associated
            assert_eq!(args.len(), 1);
            match &args[0] {
                Expr::Ident(Ident(name), _) => assert_eq!(name, "list"),
                _ => panic!("Expected Ident(list)"),
            }
        }
        _ => panic!("Expected Apply"),
    }
}

#[test]
fn test_parse_top_level_mixed_expressions() {
    // Test: let f = fn x = x + 1
    //       f 5
    let input = r#"
let f = fn x = x + 1
f 5
"#;
    let source = input;
    let expr = parse(source).unwrap();
    
    match expr {
        Expr::Block { exprs, .. } => {
            assert_eq!(exprs.len(), 2);
            
            // First should be let binding
            match &exprs[0] {
                Expr::Let { name, .. } => {
                    assert_eq!(name, &Ident("f".to_string()));
                }
                _ => panic!("Expected Let"),
            }
            
            // Second should be application f 5
            match &exprs[1] {
                Expr::Apply { func, args, .. } => {
                    match func.as_ref() {
                        Expr::Ident(Ident(name), _) => assert_eq!(name, "f"),
                        _ => panic!("Expected Ident(f)"),
                    }
                    assert_eq!(args.len(), 1);
                }
                _ => panic!("Expected Apply"),
            }
        }
        _ => panic!("Expected Block"),
    }
}

#[test]
fn test_parse_namespace_application() {
    // Test: String.concat "hello" "world"
    let source = "String.concat \"hello\" \"world\"";
    let expr = parse(source).unwrap();
    
    match expr {
        Expr::Apply { func, args, .. } => {
            // func should be String.concat "hello"
            match func.as_ref() {
                Expr::Apply { func: inner_func, args: inner_args, .. } => {
                    // inner_func should be String.concat
                    match inner_func.as_ref() {
                        Expr::RecordAccess { record, field, .. } => {
                            match record.as_ref() {
                                Expr::Ident(Ident(name), _) => assert_eq!(name, "String"),
                                _ => panic!("Expected Ident(String)"),
                            }
                            assert_eq!(field, &Ident("concat".to_string()));
                        }
                        _ => panic!("Expected RecordAccess"),
                    }
                    assert_eq!(inner_args.len(), 1);
                }
                _ => panic!("Expected nested Apply"),
            }
            assert_eq!(args.len(), 1);
        }
        _ => panic!("Expected Apply"),
    }
}

#[test]
fn test_parse_application_with_parentheses() {
    // Test: map (fn x = x + 1) list
    let source = "map (fn x = x + 1) list";
    let expr = parse(source).unwrap();
    
    match expr {
        Expr::Apply { func, args, .. } => {
            // func should be map (fn x = x + 1)
            match func.as_ref() {
                Expr::Apply { func: map_func, args: map_args, .. } => {
                    match map_func.as_ref() {
                        Expr::Ident(Ident(name), _) => assert_eq!(name, "map"),
                        _ => panic!("Expected Ident(map)"),
                    }
                    assert_eq!(map_args.len(), 1);
                    match &map_args[0] {
                        Expr::Lambda { params, .. } => {
                            assert_eq!(params.len(), 1);
                            assert_eq!(params[0].0, Ident("x".to_string()));
                        }
                        _ => panic!("Expected Lambda"),
                    }
                }
                _ => panic!("Expected nested Apply"),
            }
            assert_eq!(args.len(), 1);
        }
        _ => panic!("Expected Apply"),
    }
}

#[test]
fn test_parse_chained_application() {
    // Test: f g h x
    let input = "f g h x";
    println!("Testing input: {:?}", input);
    let source = input;
    let expr = parse(source).unwrap();
    
    // Should parse as ((f g) h) x
    match expr {
        Expr::Apply { func, args, .. } => {
            assert_eq!(args.len(), 1);
            match &args[0] {
                Expr::Ident(Ident(name), _) => assert_eq!(name, "x"),
                _ => panic!("Expected Ident(x)"),
            }
            
            // Check nested structure
            match func.as_ref() {
                Expr::Apply { func: inner, args: inner_args, .. } => {
                    assert_eq!(inner_args.len(), 1);
                    match &inner_args[0] {
                        Expr::Ident(Ident(name), _) => assert_eq!(name, "h"),
                        _ => panic!("Expected Ident(h)"),
                    }
                    
                    match inner.as_ref() {
                        Expr::Apply { func: innermost, args: innermost_args, .. } => {
                            match innermost.as_ref() {
                                Expr::Ident(Ident(name), _) => assert_eq!(name, "f"),
                                _ => panic!("Expected Ident(f)"),
                            }
                            assert_eq!(innermost_args.len(), 1);
                            match &innermost_args[0] {
                                Expr::Ident(Ident(name), _) => assert_eq!(name, "g"),
                                _ => panic!("Expected Ident(g)"),
                            }
                        }
                        _ => panic!("Expected innermost Apply"),
                    }
                }
                _ => panic!("Expected nested Apply"),
            }
        }
        _ => panic!("Expected Apply"),
    }
}

#[test]
fn test_parse_mixed_operators_and_application() {
    // Test: f x + g y
    // NOTE: This test expects the expression to be parsed as (f x) + (g y)
    // which is not a top-level function application but an infix expression
    let source = "f x + g y";
    let expr = parse(source).unwrap();
    
    // Should parse as (f x) + (g y)
    match expr {
        Expr::Apply { func, args, .. } => {
            // This is the + operator applied
            match func.as_ref() {
                Expr::Apply { func: plus_func, args: plus_args, .. } => {
                    match plus_func.as_ref() {
                        Expr::Ident(Ident(name), _) => assert_eq!(name, "+"),
                        _ => panic!("Expected Ident(+)"),
                    }
                    
                    // First arg should be (f x)
                    assert_eq!(plus_args.len(), 1);
                    match &plus_args[0] {
                        Expr::Apply { func, args, .. } => {
                            match func.as_ref() {
                                Expr::Ident(Ident(name), _) => assert_eq!(name, "f"),
                                _ => panic!("Expected Ident(f)"),
                            }
                            assert_eq!(args.len(), 1);
                        }
                        _ => panic!("Expected Apply for (f x)"),
                    }
                }
                _ => panic!("Expected Apply for +"),
            }
            
            // Second arg should be (g y)
            assert_eq!(args.len(), 1);
            match &args[0] {
                Expr::Apply { func, args, .. } => {
                    match func.as_ref() {
                        Expr::Ident(Ident(name), _) => assert_eq!(name, "g"),
                        _ => panic!("Expected Ident(g)"),
                    }
                    assert_eq!(args.len(), 1);
                }
                _ => panic!("Expected Apply for (g y)"),
            }
        }
        _ => panic!("Expected Apply"),
    }
}