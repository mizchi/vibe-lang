use std::fs;
use std::path::Path;

use parser::parse;
use checker::type_check;
use interpreter::eval;
use xs_core::Type;

#[test]
fn test_example_files() {
    // Test that example files can be parsed and type-checked
    let examples_dir = Path::new("examples");
    
    // Test basics.xs
    if let Ok(src) = fs::read_to_string(examples_dir.join("basics.xs")) {
        let expr = parse(&src).unwrap();
        let _ = type_check(&expr).unwrap();
        // Note: We don't eval the whole file as it contains multiple expressions
    }
    
    // Test recursion.xs
    if let Ok(src) = fs::read_to_string(examples_dir.join("recursion.xs")) {
        let expr = parse(&src).unwrap();
        let _ = type_check(&expr).unwrap();
    }
    
    // Test higher-order.xs
    if let Ok(src) = fs::read_to_string(examples_dir.join("higher-order.xs")) {
        let expr = parse(&src).unwrap();
        let _ = type_check(&expr).unwrap();
    }
}

#[test]
fn test_type_errors() {
    // Type mismatch in if
    let bad_if = "(if 42 1 2)";
    let expr = parse(bad_if).unwrap();
    assert!(type_check(&expr).is_err());
    
    // Type mismatch in application
    let bad_app = "(+ true false)";
    let expr = parse(bad_app).unwrap();
    assert!(type_check(&expr).is_err());
    
    // Wrong number of arguments
    let bad_args = "(+ 1)";
    let expr = parse(bad_args).unwrap();
    type_check(&expr).unwrap(); // Type check passes
    assert!(eval(&expr).is_err()); // But runtime fails
}

#[test]
fn test_parse_errors() {
    assert!(parse("(").is_err());
    assert!(parse(")").is_err());
    assert!(parse("(let)").is_err());
    assert!(parse("(lambda)").is_err());
}

#[test]
fn test_advanced_features() {
    // Higher-order function
    let map_inc = r#"
        (let map (lambda (f : (-> Int Int)) 
                   (lambda (xs : (List Int)) 
                     (list))))
    "#;
    let expr = parse(map_inc).unwrap();
    let typ = type_check(&expr).unwrap();
    match typ {
        Type::Function(from, to) => {
            match from.as_ref() {
                Type::Function(_, _) => {},
                _ => panic!("Expected function argument"),
            }
            match to.as_ref() {
                Type::Function(arg, ret) => {
                    match arg.as_ref() {
                        Type::List(_) => {}, // Type variable is ok
                        _ => panic!("Expected List type for argument"),
                    }
                    match ret.as_ref() {
                        Type::List(_) => {}, // Type variable is ok
                        _ => panic!("Expected List type for return"),
                    }
                },
                _ => panic!("Expected function return"),
            }
        }
        _ => panic!("Expected function type"),
    }
}