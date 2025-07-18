use std::fs;
use std::path::Path;

use parser::parse;
use checker::type_check;
use interpreter::eval;
use xs_core::{Type, Value};

#[test]
fn test_example_files() {
    let examples_dir = Path::new("../examples");
    
    // Test hello.xs
    let hello_src = fs::read_to_string(examples_dir.join("hello.xs")).unwrap();
    let hello_expr = parse(&hello_src).unwrap();
    let hello_type = type_check(&hello_expr).unwrap();
    assert_eq!(hello_type, Type::String);
    let hello_val = eval(&hello_expr).unwrap();
    assert_eq!(hello_val, Value::String("Hello, XS!".to_string()));
    
    // Test arithmetic.xs
    let arith_src = fs::read_to_string(examples_dir.join("arithmetic.xs")).unwrap();
    let arith_expr = parse(&arith_src).unwrap();
    let arith_type = type_check(&arith_expr).unwrap();
    assert_eq!(arith_type, Type::Int);
    let arith_val = eval(&arith_expr).unwrap();
    assert_eq!(arith_val, Value::Int(37));
    
    // Test lambda.xs
    let lambda_src = fs::read_to_string(examples_dir.join("lambda.xs")).unwrap();
    let lambda_expr = parse(&lambda_src).unwrap();
    let lambda_type = type_check(&lambda_expr).unwrap();
    assert_eq!(lambda_type, Type::Int);
    let lambda_val = eval(&lambda_expr).unwrap();
    assert_eq!(lambda_val, Value::Int(30));
    
    // Test list.xs
    let list_src = fs::read_to_string(examples_dir.join("list.xs")).unwrap();
    let list_expr = parse(&list_src).unwrap();
    let list_type = type_check(&list_expr).unwrap();
    match list_type {
        Type::List(elem_type) => assert_eq!(*elem_type, Type::Int),
        _ => panic!("Expected List type"),
    }
    let list_val = eval(&list_expr).unwrap();
    match list_val {
        Value::List(elems) => {
            assert_eq!(elems.len(), 3);
            assert_eq!(elems[0], Value::Int(1));
            assert_eq!(elems[1], Value::Int(2));
            assert_eq!(elems[2], Value::Int(3));
        }
        _ => panic!("Expected List value"),
    }
    
    // Test identity.xs
    let id_src = fs::read_to_string(examples_dir.join("identity.xs")).unwrap();
    let id_expr = parse(&id_src).unwrap();
    let id_type = type_check(&id_expr).unwrap();
    match id_type {
        Type::Function(_, _) => {}, // Polymorphic identity function
        _ => panic!("Expected Function type"),
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