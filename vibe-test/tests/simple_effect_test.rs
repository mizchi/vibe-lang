use vibe_compiler::{TypeChecker, TypeEnv};
use vibe_core::{parser::parse, Type};

#[test]
fn test_simple_effect_display() {
    // Test pure function
    let code1 = "let id x = x";
    let expr1 = parse(code1).expect("Failed to parse");
    let mut checker1 = TypeChecker::new();
    let mut env1 = TypeEnv::new();
    
    let typ1 = checker1.check(&expr1, &mut env1).expect("Type check failed");
    println!("Type of 'let id x = x': {}", typ1);
    
    // Test function with IO effect
    let code2 = "let hello unit = perform IO \"Hello\"";
    let expr2 = parse(code2).expect("Failed to parse");
    let mut checker2 = TypeChecker::new();
    let mut env2 = TypeEnv::new();
    
    let typ2 = checker2.check(&expr2, &mut env2).expect("Type check failed");
    println!("Type of 'let hello unit = perform IO \"Hello\"': {}", typ2);
    
    // Test function application
    let code3 = "let apply f x = f x";
    let expr3 = parse(code3).expect("Failed to parse");
    let mut checker3 = TypeChecker::new();
    let mut env3 = TypeEnv::new();
    
    let typ3 = checker3.check(&expr3, &mut env3).expect("Type check failed");
    println!("Type of 'let apply f x = f x': {}", typ3);
    
    // Verify effect display
    match &typ2 {
        Type::FunctionWithEffect { from, to, effects } => {
            println!("  from: {}", from);
            println!("  to: {}", to);
            println!("  effects: {:?}", effects);
            assert!(!effects.is_pure(), "Function should have IO effect");
        }
        _ => panic!("Expected FunctionWithEffect type")
    }
}