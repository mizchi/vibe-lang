//! Integration tests for new parser and syntax features

use xs_compiler::type_check;
use xs_core::parser_v2::Parser;
use xs_core::{Environment, Value};
use xs_runtime::Interpreter;

#[test]
fn test_block_expression() {
    let input = r#"{
        let x = 10;
        let y = 20;
        x + y
    }"#;
    
    let mut parser = Parser::new(input).unwrap();
    let expr = parser.parse().unwrap();
    
    // Type check
    let ty = type_check(&expr).unwrap();
    assert_eq!(ty.to_string(), "Int");
    
    // Evaluate
    let mut interpreter = Interpreter::new();
    let env = Environment::default();
    let result = interpreter.eval(&expr, &env).unwrap();
    
    assert_eq!(result, Value::Int(30));
}

#[test]
fn test_pipeline_operator() {
    let input = r#"
        let double = fn x -> x * 2;
        5 | double
    "#;
    
    let mut parser = Parser::new(input).unwrap();
    let expr = parser.parse().unwrap();
    
    // Type check should pass
    let _ty = type_check(&expr).unwrap();
}

#[test]
fn test_record_literal() {
    let input = r#"{ name: "Alice", age: 30 }"#;
    
    let mut parser = Parser::new(input).unwrap();
    let expr = parser.parse().unwrap();
    
    // Should parse successfully as RecordLiteral
    match expr {
        xs_core::Expr::RecordLiteral { fields, .. } => {
            assert_eq!(fields.len(), 2);
        }
        _ => panic!("Expected RecordLiteral"),
    }
}

#[test]
fn test_hole_syntax() {
    let input = "@";
    
    let mut parser = Parser::new(input).unwrap();
    let expr = parser.parse().unwrap();
    
    // Should parse as Hole
    match expr {
        xs_core::Expr::Hole { .. } => {
            // OK
        }
        _ => panic!("Expected Hole"),
    }
}

#[test]
fn test_do_block() {
    let input = r#"do <IO> { 42 }"#;
    
    let mut parser = Parser::new(input).unwrap();
    let expr = parser.parse().unwrap();
    
    // Should parse as Do
    match expr {
        xs_core::Expr::Do { effects, .. } => {
            assert_eq!(effects.len(), 1);
            assert_eq!(effects[0], "IO");
        }
        _ => panic!("Expected Do block"),
    }
}

#[test]
fn test_complex_expression() {
    let input = r#"
        let add = fn x -> fn y -> x + y;
        let inc = add 1;
        [1, 2, 3] | map inc | sum
    "#;
    
    let mut parser = Parser::new(input).unwrap();
    let _expr = parser.parse().unwrap();
    
    // Should parse without errors
    // Type checking would require map and sum to be defined
}

#[test]
fn test_if_with_blocks() {
    let input = r#"
        if x > 0 {
            "positive"
        } else {
            "non-positive"
        }
    "#;
    
    let mut parser = Parser::new(input).unwrap();
    let expr = parser.parse().unwrap();
    
    // Should parse as If with block expressions
    match expr {
        xs_core::Expr::If { then_expr, else_expr: _, .. } => {
            // Both branches should be strings
            match then_expr.as_ref() {
                xs_core::Expr::Literal(xs_core::Literal::String(s), _) => {
                    assert_eq!(s, "positive");
                }
                _ => panic!("Expected string literal in then branch"),
            }
        }
        _ => panic!("Expected If expression"),
    }
}

#[test]
fn test_case_expression() {
    let input = r#"
        case x of {
            0 -> "zero"
            1 -> "one"
            _ -> "other"
        }
    "#;
    
    let mut parser = Parser::new(input).unwrap();
    let expr = parser.parse().unwrap();
    
    // Should parse as Match
    match expr {
        xs_core::Expr::Match { cases, .. } => {
            assert_eq!(cases.len(), 3);
        }
        _ => panic!("Expected Match expression"),
    }
}

#[test]
fn test_record_access() {
    let input = r#"person.name"#;
    
    let mut parser = Parser::new(input).unwrap();
    let expr = parser.parse().unwrap();
    
    // Should parse as RecordAccess
    match expr {
        xs_core::Expr::RecordAccess { field, .. } => {
            assert_eq!(field.0, "name");
        }
        _ => panic!("Expected RecordAccess"),
    }
}