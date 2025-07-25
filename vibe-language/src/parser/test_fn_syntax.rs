//! Tests for fn syntax parsing

use super::*;
use crate::{Expr, Ident};

#[test]
fn test_parse_fn_minimal() {
    // Test: fn {}
    let source = "fn {}";
    let expr = parse(source).unwrap();
    match expr {
        Expr::Lambda { params, body, .. } => {
            assert_eq!(params.len(), 0);
            // Body should be a block
            match body.as_ref() {
                Expr::Block { .. } | Expr::RecordLiteral { .. } => {}
                _ => panic!("Expected Block or RecordLiteral in body, got {:?}", body),
            }
        }
        _ => panic!("Expected Lambda, got {:?}", expr),
    }
}

#[test]
fn test_parse_fn_with_new_param_syntax() {
    // Test: fn x: Int -> y: Int = { x + y }
    let source = "fn x: Int -> y: Int = { x + y }";
    let expr = parse(source).unwrap();
    match expr {
        Expr::Lambda { params, body, .. } => {
            assert_eq!(params.len(), 1);
            assert_eq!(params[0].0, Ident("x".to_string()));
            assert!(params[0].1.is_some()); // Should have Int type
            
            // Body should be another lambda for y
            match body.as_ref() {
                Expr::Lambda { params: inner_params, .. } => {
                    assert_eq!(inner_params.len(), 1);
                    assert_eq!(inner_params[0].0, Ident("y".to_string()));
                    assert!(inner_params[0].1.is_some()); // Should have Int type
                }
                _ => panic!("Expected nested Lambda, got {:?}", body),
            }
        }
        _ => panic!("Expected Lambda, got {:?}", expr),
    }
}

#[test]
fn test_parse_fn_single_arg() {
    // Test: fn x = x + 1 (new syntax)
    let source = "fn x = x + 1";
    let expr = parse(source).unwrap();
    match expr {
        Expr::Lambda { params, body, .. } => {
            assert_eq!(params.len(), 1);
            assert_eq!(params[0].0, Ident("x".to_string()));
            // Check body is x + 1
            match body.as_ref() {
                Expr::Apply { .. } => {} // x + 1 is application
                _ => panic!("Expected Apply in body"),
            }
        }
        _ => panic!("Expected Lambda"),
    }
}

#[test]
fn test_parse_fn_multiple_args() {
    // Test: fn x -> y = x + y (new syntax with ->)
    let source = "fn x -> y = x + y";
    let expr = parse(source).unwrap();
    match expr {
        Expr::Lambda { params, body, .. } => {
            assert_eq!(params.len(), 1);
            assert_eq!(params[0].0, Ident("x".to_string()));
            // Should be nested lambda
            match body.as_ref() {
                Expr::Lambda { params: inner_params, .. } => {
                    assert_eq!(inner_params.len(), 1);
                    assert_eq!(inner_params[0].0, Ident("y".to_string()));
                }
                _ => panic!("Expected nested Lambda"),
            }
        }
        _ => panic!("Expected Lambda"),
    }
}

#[test]
fn test_parse_fn_with_parens() {
    // Test: fn x = x (parentheses are not supported in new syntax)
    let source = "fn x = x";
    let expr = parse(source).unwrap();
    match expr {
        Expr::Lambda { params,  .. } => {
            assert_eq!(params.len(), 1);
            assert_eq!(params[0].0, Ident("x".to_string()));
        }
        _ => panic!("Expected Lambda"),
    }
}

#[test]
fn test_parse_fn_with_type_annotation() {
    // Test: fn x: Int = x + 1 (new syntax)
    let source = "fn x: Int = x + 1";
    let expr = parse(source).unwrap();
    match expr {
        Expr::Lambda { params,  .. } => {
            assert_eq!(params.len(), 1);
            assert_eq!(params[0].0, Ident("x".to_string()));
            assert!(params[0].1.is_some()); // Should have type annotation
        }
        _ => panic!("Expected Lambda"),
    }
}

#[test]
fn test_parse_fn_block_body() {
    // Test: fn x -> { x + 1 }
    let source = "fn x -> { x + 1 }";
    let expr = parse(source).unwrap();
    match expr {
        Expr::Lambda { params,  .. } => {
            assert_eq!(params.len(), 1);
            // Body should be a block or the expression inside
        }
        _ => panic!("Expected Lambda"),
    }
}

#[test]
fn test_parse_let_with_fn() {
    // Test: let f = fn x = x + 1
    let source = "let f = fn x = x + 1";
    let expr = parse(source).unwrap();
    match expr {
        Expr::Let { name, value, .. } => {
            assert_eq!(name, Ident("f".to_string()));
            match value.as_ref() {
                Expr::Lambda { .. } => {}
                _ => panic!("Expected Lambda in let value"),
            }
        }
        _ => panic!("Expected Let"),
    }
}

#[test]
fn test_parse_fn_in_application() {
    // Test: map (fn x = x + 1) list
    // Now parses as a single application
    let source = "map (fn x = x + 1) list";
    let expr = parse(source).unwrap();
    
    // The parser now treats this as a single function application
    match expr {
        Expr::Apply { func, args, .. } => {
            // func should be "map" applied to the lambda
            match func.as_ref() {
                Expr::Apply { func: map_func, args: map_args, .. } => {
                    // Check that map_func is "map"
                    match map_func.as_ref() {
                        Expr::Ident(Ident(name), _) => assert_eq!(name, "map"),
                        _ => panic!("Expected Ident(map)"),
                    }
                    // Check that map_args contains the lambda
                    assert_eq!(map_args.len(), 1);
                    match &map_args[0] {
                        Expr::Lambda { .. } => {},
                        _ => panic!("Expected Lambda as first argument to map"),
                    }
                }
                _ => panic!("Expected Apply for map with lambda"),
            }
            // args should contain "list"
            assert_eq!(args.len(), 1);
            match &args[0] {
                Expr::Ident(Ident(name), _) => assert_eq!(name, "list"),
                _ => panic!("Expected Ident(list)"),
            }
        }
        _ => panic!("Expected Apply, got {:?}", expr),
    }
}

#[test]
fn test_parse_fn_equals_syntax() {
    // Test: fn x = x + 1
    let source = "fn x = x + 1";
    let expr = parse(source).unwrap();
    match expr {
        Expr::Lambda { params,  .. } => {
            assert_eq!(params.len(), 1);
            assert_eq!(params[0].0, Ident("x".to_string()));
        }
        _ => panic!("Expected Lambda"),
    }
}

#[test]
fn test_parse_nested_fn() {
    // Test: fn x = fn y = x + y
    let source = "fn x = fn y = x + y";
    let expr = parse(source).unwrap();
    match expr {
        Expr::Lambda { params, body, .. } => {
            assert_eq!(params.len(), 1);
            match body.as_ref() {
                Expr::Lambda { params: inner_params, .. } => {
                    assert_eq!(inner_params.len(), 1);
                }
                _ => panic!("Expected nested Lambda"),
            }
        }
        _ => panic!("Expected Lambda"),
    }
}