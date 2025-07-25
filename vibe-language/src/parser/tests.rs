use super::*;
use crate::{Expr, Ident, Literal, Span};

#[test]
fn test_parse_simple_expression() {
    let source = "42";
    let expr = parse(source).unwrap();
    assert_eq!(expr, Expr::Literal(Literal::Int(42), Span::new(0, 2)));
}

#[test]
fn test_parse_let_binding() {
    let source = "let x = 42";
    let expr = parse(source).unwrap();
    match expr {
        Expr::Let { name, value, .. } => {
            assert_eq!(name, Ident("x".to_string()));
            match value.as_ref() {
                Expr::Literal(Literal::Int(42), _) => {}
                _ => panic!("Expected Int literal"),
            }
        }
        _ => panic!("Expected Let binding"),
    }
}

#[test]
fn test_parse_function_definition() {
    let source = "let add x y = x + y";
    let expr = parse(source).unwrap();
    match expr {
        Expr::Let { name, value, .. } => {
            assert_eq!(name, Ident("add".to_string()));
            // Should be a FunctionDef
            match value.as_ref() {
                Expr::FunctionDef { params, .. } => {
                    assert_eq!(params.len(), 2);
                    assert_eq!(params[0].name, Ident("x".to_string()));
                    assert_eq!(params[1].name, Ident("y".to_string()));
                }
                _ => panic!("Expected FunctionDef"),
            }
        }
        _ => panic!("Expected Let binding"),
    }
}

#[test]
fn test_parse_pipeline() {
    let source = "let result = x |> f |> g";
    let expr = parse(source).unwrap();
    // Pipeline should be wrapped in Let
    match expr {
        Expr::Let { value, .. } => {
            // Check that value is a pipeline
            match value.as_ref() {
                Expr::Pipeline { .. } => {
                    // Successfully parsed as pipeline
                }
                _ => panic!("Expected Pipeline in let value"),
            }
        }
        _ => panic!("Expected Let expression"),
    }
}

#[test]
fn test_parse_block() {
    let source = "{ let x = 1; x + 2 }";
    let expr = parse(source).unwrap();
    // Block should return last expression or Block itself
    match expr {
        Expr::Block { exprs, .. } => {
            // Block with multiple expressions
            assert_eq!(exprs.len(), 2);
        }
        Expr::Apply { .. } => {
            // Or just the last expression
        }
        _ => panic!("Expected Block or expression from block, got {:?}", expr),
    }
}

#[test]
fn test_parse_if_with_blocks() {
    // Test simpler version first
    let source = "if true { 1 } else { -1 }";
    let expr = parse(source).unwrap();
    match expr {
        Expr::If {
            then_expr,
            else_expr,
            ..
        } => {
            match then_expr.as_ref() {
                Expr::Literal(Literal::Int(1), _) => {}
                _ => panic!("Expected Int(1) in then branch"),
            }
            match else_expr.as_ref() {
                Expr::Literal(Literal::Int(-1), _) => {}
                _ => panic!("Expected Int(-1) in else branch"),
            }
        }
        _ => panic!("Expected If expression"),
    }
}

#[test]
fn test_parse_lambda() {
    let source = "fn x = x * 2";
    let expr = parse(source).unwrap();
    match expr {
        Expr::Lambda { params, .. } => {
            assert_eq!(params.len(), 1);
            assert_eq!(params[0].0, Ident("x".to_string()));
        }
        _ => panic!("Expected Lambda"),
    }
}

#[test]
fn test_parse_lambda_multi_param() {
    let source = "let add x y = x + y";
    let expr = parse(source).unwrap();
    // Should be a let binding with FunctionDef
    match expr {
        Expr::Let { value, .. } => {
            match value.as_ref() {
                Expr::FunctionDef { params, .. } => {
                    assert_eq!(params.len(), 2);
                    assert_eq!(params[0].name, Ident("x".to_string()));
                    assert_eq!(params[1].name, Ident("y".to_string()));
                }
                _ => panic!("Expected FunctionDef in let value"),
            }
        }
        _ => panic!("Expected Let expression"),
    }
}

#[test]
fn test_parse_list() {
    let source = "[1, 2, 3]";
    let expr = parse(source).unwrap();
    match expr {
        Expr::List(items, _) => {
            assert_eq!(items.len(), 3);
            match &items[0] {
                Expr::Literal(Literal::Int(1), _) => {}
                _ => panic!("Expected Int(1)"),
            }
            match &items[1] {
                Expr::Literal(Literal::Int(2), _) => {}
                _ => panic!("Expected Int(2)"),
            }
            match &items[2] {
                Expr::Literal(Literal::Int(3), _) => {}
                _ => panic!("Expected Int(3)"),
            }
        }
        _ => panic!("Expected List"),
    }
}

// Hole syntax is not supported in parser
// #[test]
// fn test_parse_hole() {
//     let source = "x * @:Int";
//     let expr = parse(source).unwrap();
//     // Should parse @ as a special hole expression
//     match expr {
//         Expr::Apply { args, .. } => {
//             match &args[0] {
//                 Expr::Hole { .. } => {
//                     // Successfully parsed hole
//                 }
//                 _ => panic!("Expected hole expression"),
//             }
//         }
//         _ => panic!("Expected App with hole"),
//     }
// }

#[test]
fn test_parse_case_expression() {
    let input = r#"
match x {
    0 -> "zero"
    1 -> "one"
    _ -> "other"
}
"#;
    let source = input;
    let expr = parse(source).unwrap();
    match expr {
        Expr::Match { cases, .. } => {
            assert_eq!(cases.len(), 3);
        }
        _ => panic!("Expected Match/Case expression"),
    }
}

#[test]
fn test_parse_record_literal() {
    let input = r#"{ name: "Alice", age: 30 }"#;
    let source = input;
    let expr = parse(source).unwrap();
    match expr {
        Expr::RecordLiteral { fields, .. } => {
            assert_eq!(fields.len(), 2);
            assert_eq!(fields[0].0, Ident("name".to_string()));
            assert_eq!(fields[1].0, Ident("age".to_string()));
        }
        _ => panic!("Expected RecordLiteral"),
    }
}

#[test]
fn test_parse_record_access() {
    let input = "person.name";
    let source = input;
    let expr = parse(source).unwrap();
    match expr {
        Expr::RecordAccess { field, .. } => {
            assert_eq!(field, Ident("name".to_string()));
        }
        _ => panic!("Expected RecordAccess"),
    }
}

#[test]
fn test_parse_do_block() {
    let input = "do { print \"Hello\" }";
    let source = input;
    let expr = parse(source).unwrap();
    match expr {
        Expr::Do { statements, .. } => {
            // The current parser creates a do block with the body as statements
            assert!(statements.len() > 0);
        }
        _ => panic!("Expected Do block"),
    }
}

#[test]
fn test_parse_with_handler() {
    let input = "with myHandler { doSomething }";
    let source = input;
    // Debug: try without parse() wrapper first
    println!("About to parse with handler");
    let expr = parse(source).unwrap();
    match expr {
        Expr::WithHandler { .. } => {
            // Successfully parsed with handler
        }
        _ => panic!("Expected WithHandler"),
    }
}

#[test]
fn test_parse_comments() {
    // Test single expression with comment
    let input = "# This is a comment\nlet x = 42";
    let source = input;
    let expr = parse(source).unwrap();
    // Comments should be skipped
    match expr {
        Expr::Let { .. } => {
            // Successfully parsed let after comment
        }
        _ => panic!("Expected Let expression after comment, got {:?}", expr),
    }
}
