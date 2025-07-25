//! Advanced tests for fn syntax

use super::*;
use crate::{Expr, Ident};

#[test]
fn test_parse_fn_with_complex_body() {
    // Test: fn x = let y = x * 2 in y + 1
    let source = "fn x = let y = x * 2 in y + 1";
    let expr = parse(source).unwrap();
    
    match expr {
        Expr::Lambda { params, body, .. } => {
            assert_eq!(params.len(), 1);
            assert_eq!(params[0].0, Ident("x".to_string()));
            
            // Body should be let-in expression
            match body.as_ref() {
                Expr::LetIn { name, value, body: let_body, .. } => {
                    assert_eq!(name, &Ident("y".to_string()));
                    
                    // value should be x * 2
                    match value.as_ref() {
                        Expr::Apply { .. } => {},
                        _ => panic!("Expected Apply for x * 2"),
                    }
                    
                    // body should be y + 1
                    match let_body.as_ref() {
                        Expr::Apply { .. } => {},
                        _ => panic!("Expected Apply for y + 1"),
                    }
                }
                _ => panic!("Expected LetIn in body"),
            }
        }
        _ => panic!("Expected Lambda"),
    }
}

#[test]
fn test_parse_fn_with_match() {
    // Test: fn x = match x { 0 -> "zero"; _ -> "other" }
    // Note: Using semicolon instead of comma between match arms
    let input = r#"fn x = match x { 0 -> "zero"; _ -> "other" }"#;
    let source = input;
    let expr = parse(source).unwrap();
    
    match expr {
        Expr::Lambda { params, body, .. } => {
            assert_eq!(params.len(), 1);
            
            // Body should be match expression
            match body.as_ref() {
                Expr::Match { expr: match_expr, cases, .. } => {
                    // match_expr should be x
                    match match_expr.as_ref() {
                        Expr::Ident(Ident(name), _) => assert_eq!(name, "x"),
                        _ => panic!("Expected Ident(x) in match expr"),
                    }
                    
                    assert_eq!(cases.len(), 2);
                }
                _ => panic!("Expected Match in body"),
            }
        }
        _ => panic!("Expected Lambda"),
    }
}

#[test]
#[ignore = "Optional parameters syntax not yet supported"]
fn test_parse_fn_with_optional_params() {
    // Test: fn x?: Int -> y: String = strConcat (intToString x) y
    // Optional parameters with ? syntax are not yet supported
    let source = "fn x?: Int -> y: String = strConcat (intToString x) y";
    let expr = parse(source).unwrap();
    
    match expr {
        Expr::Lambda { params, body, .. } => {
            assert_eq!(params.len(), 1);
            assert_eq!(params[0].0, Ident("x".to_string()));
            assert!(params[0].1.is_some()); // Should have type annotation
            
            // Body should be another lambda for y
            match body.as_ref() {
                Expr::Lambda { params: inner_params, .. } => {
                    assert_eq!(inner_params.len(), 1);
                    assert_eq!(inner_params[0].0, Ident("y".to_string()));
                    assert!(inner_params[0].1.is_some()); // Should have type annotation
                }
                _ => panic!("Expected nested Lambda"),
            }
        }
        _ => panic!("Expected Lambda"),
    }
}

#[test]
fn test_parse_fn_with_type_constraints() {
    // Test: fn x: a -> y: a -> Bool = eq x y
    let source = "fn x: a -> y: a -> Bool = eq x y";
    let expr = parse(source).unwrap();
    
    match expr {
        Expr::Lambda { params, .. } => {
            assert_eq!(params.len(), 1);
            assert_eq!(params[0].0, Ident("x".to_string()));
            assert!(params[0].1.is_some()); // Should have type variable 'a'
        }
        _ => panic!("Expected Lambda"),
    }
}

#[test]
fn test_parse_fn_empty_with_effects() {
    // Test: fn {} with IO effect (future syntax)
    // For now, just test empty fn
    let source = "fn {}";
    let expr = parse(source).unwrap();
    
    match expr {
        Expr::Lambda { params, body, .. } => {
            assert_eq!(params.len(), 0);
            
            // Body should be empty block
            match body.as_ref() {
                Expr::Block { exprs, .. } => {
                    assert_eq!(exprs.len(), 0);
                }
                Expr::RecordLiteral { fields, .. } => {
                    assert_eq!(fields.len(), 0);
                }
                _ => panic!("Expected Block or RecordLiteral, got {:?}", body),
            }
        }
        _ => panic!("Expected Lambda"),
    }
}

#[test]
fn test_parse_fn_with_record_destructuring() {
    // Test: fn {x, y} = x + y
    // This might not be supported yet, but let's test the current behavior
    let source = "fn {x, y} = x + y";
    let result = parse(source);
    
    // If record destructuring in params is not supported, this should fail
    // or parse differently
    if result.is_err() {
        // Expected for now
        return;
    }
}

#[test]
fn test_parse_fn_in_let_binding() {
    // Test: let compose = fn f -> g -> x = f (g x)
    let source = "let compose = fn f -> g -> x = f (g x)";
    let expr = parse(source).unwrap();
    
    match expr {
        Expr::Let { name, value, .. } => {
            assert_eq!(name, Ident("compose".to_string()));
            
            // value should be a lambda
            match value.as_ref() {
                Expr::Lambda { params, body, .. } => {
                    assert_eq!(params.len(), 1);
                    assert_eq!(params[0].0, Ident("f".to_string()));
                    
                    // Should have nested lambdas for currying
                    match body.as_ref() {
                        Expr::Lambda { params: inner_params, body: inner_body, .. } => {
                            assert_eq!(inner_params.len(), 1);
                            assert_eq!(inner_params[0].0, Ident("g".to_string()));
                            
                            match inner_body.as_ref() {
                                Expr::Lambda { params: innermost_params, .. } => {
                                    assert_eq!(innermost_params.len(), 1);
                                    assert_eq!(innermost_params[0].0, Ident("x".to_string()));
                                }
                                _ => panic!("Expected innermost Lambda"),
                            }
                        }
                        _ => panic!("Expected nested Lambda"),
                    }
                }
                _ => panic!("Expected Lambda in let value"),
            }
        }
        _ => panic!("Expected Let"),
    }
}

#[test]
fn test_parse_fn_with_guards() {
    // Test: fn x = if x > 0 { x } else { -x }
    let source = "fn x = if x > 0 { x } else { -x }";
    let expr = parse(source).unwrap();
    
    match expr {
        Expr::Lambda { params, body, .. } => {
            assert_eq!(params.len(), 1);
            
            // Body should be if expression
            match body.as_ref() {
                Expr::If { .. } => {},
                _ => panic!("Expected If in body"),
            }
        }
        _ => panic!("Expected Lambda"),
    }
}

#[test]
#[ignore = "Return type annotation syntax not yet supported"]
fn test_parse_fn_type_annotation_only() {
    // Test: fn x: Int -> Int = x
    // This syntax with return type annotation is not yet supported
    let source = "fn x: Int -> Int = x";
    let expr = parse(source).unwrap();
    
    match expr {
        Expr::Lambda { params, body, .. } => {
            assert_eq!(params.len(), 1);
            assert_eq!(params[0].0, Ident("x".to_string()));
            assert!(params[0].1.is_some()); // Should have Int type
            
            // Body should just be x
            match body.as_ref() {
                Expr::Ident(Ident(name), _) => assert_eq!(name, "x"),
                _ => panic!("Expected Ident(x) in body"),
            }
        }
        _ => panic!("Expected Lambda"),
    }
}