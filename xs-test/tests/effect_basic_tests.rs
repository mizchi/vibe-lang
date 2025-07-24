//! Basic tests for effect system

use xs_compiler::{TypeChecker, TypeEnv};
use xs_core::parser::parse;

#[test]
fn test_perform_io_effect() {
    let code = r#"
        let hello unit = perform IO "Hello, World!"
    "#;
    
    let expr = parse(code).expect("Failed to parse");
    let mut checker = TypeChecker::new();
    let mut env = TypeEnv::new();
    let result = checker.check(&expr, &mut env);
    assert!(result.is_ok(), "Type checking failed: {:?}", result);
    
    // The type should be Unit -> <IO> String
    let typ = result.unwrap();
    println!("Type of hello: {:?}", typ);
}

#[test]
fn test_pure_function() {
    let code = r#"
        let add x y = x + y
    "#;
    
    let expr = parse(code).expect("Failed to parse");
    let mut checker = TypeChecker::new();
    let mut env = TypeEnv::new();
    let result = checker.check(&expr, &mut env);
    assert!(result.is_ok(), "Type checking failed: {:?}", result);
    
    // The type should be Int -> Int -> Int (pure)
    let typ = result.unwrap();
    println!("Type of add: {:?}", typ);
}

#[test]
fn test_function_with_multiple_effects() {
    let code = r#"
        let complexFunction x = {
            let tmp = perform IO "Starting" in
            let state = perform State 0 in
            x + state
        }
    "#;
    
    let expr = parse(code).expect("Failed to parse");
    let mut checker = TypeChecker::new();
    let mut env = TypeEnv::new();
    let result = checker.check(&expr, &mut env);
    assert!(result.is_ok(), "Type checking failed: {:?}", result);
    
    // The type should be Int -> <IO, State> Int
    let typ = result.unwrap();
    println!("Type of complexFunction: {:?}", typ);
}

#[test]
fn test_handle_removes_effect() {
    let code = r#"
        let handled = 
            handle (perform IO "Hello") with {
                | IO msg k -> k msg
            }
    "#;
    
    let expr = parse(code).expect("Failed to parse");
    let mut checker = TypeChecker::new();
    let mut env = TypeEnv::new();
    let result = checker.check(&expr, &mut env);
    assert!(result.is_ok(), "Type checking failed: {:?}", result);
    
    // The type should be String (pure, IO effect removed)
    let typ = result.unwrap();
    println!("Type of handled: {:?}", typ);
}

#[test]
fn test_effect_polymorphic_map() {
    let code = r#"
        let map f lst = {
            match lst {
                [] -> []
                h :: t -> (f h) :: (map f t)
            }
        }
    "#;
    
    let expr = parse(code).expect("Failed to parse");
    let mut checker = TypeChecker::new();
    let mut env = TypeEnv::new();
    let result = checker.check(&expr, &mut env);
    assert!(result.is_ok(), "Type checking failed: {:?}", result);
    
    // The type should be polymorphic in effects:
    // forall a b e. (a -> <e> b) -> List a -> <e> List b
    let typ = result.unwrap();
    println!("Type of map: {:?}", typ);
}

#[test] 
fn test_do_notation_effects() {
    let code = r#"
        let program = do {
            x <- perform IO "Enter number: ";
            y <- perform State 42;
            x
        }
    "#;
    
    let expr = parse(code).expect("Failed to parse");
    let mut checker = TypeChecker::new();
    let mut env = TypeEnv::new();
    let result = checker.check(&expr, &mut env);
    
    // Should have both IO and State effects
    assert!(result.is_ok(), "Type checking failed: {:?}", result);
    let typ = result.unwrap();
    println!("Type of program: {:?}", typ);
}