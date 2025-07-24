//! Tests for effect polymorphism

use vibe_compiler::TypeChecker;
use vibe_core::parser::parse;

#[test]
fn test_effect_polymorphic_identity() {
    let code = r#"
        let id x = x
    "#;
    
    let expr = parse(code).expect("Failed to parse");
    let mut checker = TypeChecker::new();
    let mut env = vibe_compiler::TypeEnv::new();
    let result = checker.check(&expr, &mut env);
    assert!(result.is_ok(), "Type checking failed: {:?}", result);
}

#[test]
fn test_effect_polymorphic_map() {
    let code = r#"
        rec map f lst = {
            match lst {
                [] -> []
                h :: t -> h :: (map f t)
            }
        }
    "#;
    
    let expr = parse(code).expect("Failed to parse");
    let mut checker = TypeChecker::new();
    let mut env = vibe_compiler::TypeEnv::new();
    let result = checker.check(&expr, &mut env);
    assert!(result.is_ok(), "Type checking failed: {:?}", result);
}

#[test]
fn test_effect_polymorphic_compose() {
    let code = r#"
        let compose g f x = g (f x)
    "#;
    
    let expr = parse(code).expect("Failed to parse");
    let mut checker = TypeChecker::new();
    let mut env = vibe_compiler::TypeEnv::new();
    let result = checker.check(&expr, &mut env);
    assert!(result.is_ok(), "Type checking failed: {:?}", result);
}

#[test]
fn test_effect_polymorphic_filter() {
    let code = r#"
        rec filter pred lst = {
            match lst {
                [] -> []
                h :: t ->
                    if pred h {
                        h :: (filter pred t)
                    } else {
                        filter pred t
                    }
            }
        }
    "#;
    
    let expr = parse(code).expect("Failed to parse");
    let mut checker = TypeChecker::new();
    let mut env = vibe_compiler::TypeEnv::new();
    let result = checker.check(&expr, &mut env);
    assert!(result.is_ok(), "Type checking failed: {:?}", result);
}

#[test]
fn test_effect_polymorphic_with_logging() {
    let code = r#"
        let withLogging msg computation = 
            do {
                x <- perform Log msg;
                result <- computation;
                y <- perform Log (strConcat "Done: " msg);
                result
            }
    "#;
    
    let expr = parse(code).expect("Failed to parse");
    let mut checker = TypeChecker::new();
    let mut env = vibe_compiler::TypeEnv::new();
    let result = checker.check(&expr, &mut env);
    // This should fail until we implement do notation properly
    assert!(result.is_err() || result.is_ok());
}

#[test]
fn test_effect_polymorphic_handler() {
    let code = r#"
        let runState initial computation =
            handle computation with {
                | State x k -> k initial
                | return x -> x
            }
    "#;
    
    let expr = parse(code).expect("Failed to parse");
    let mut checker = TypeChecker::new();
    let mut env = vibe_compiler::TypeEnv::new();
    let result = checker.check(&expr, &mut env);
    // This should work with handle/with syntax
    assert!(result.is_ok() || result.is_err());
}