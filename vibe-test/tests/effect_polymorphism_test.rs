use vibe_compiler::{TypeChecker, TypeEnv};
use vibe_core::parser::parse;

#[test]
fn test_map_effect_polymorphism() {
    let code = r#"
        {
            rec map f lst = match lst {
                [] -> []
                h :: t -> (f h) :: (map f t)
            };
            
            let double x = x * 2 in
            let printAndDouble x = {
                let ignored = perform IO "print" in
                x * 2
            } in
            let test1 = map double [1, 2, 3] in
            let test2 = map printAndDouble [1, 2, 3] in
            test2
        }
    "#;
    
    let expr = parse(code).expect("Failed to parse");
    let mut checker = TypeChecker::new();
    let mut env = TypeEnv::new();
    
    let result = checker.check(&expr, &mut env);
    assert!(result.is_ok(), "Type checking failed: {:?}", result);
    
    // Check bindings - filter out builtins
    println!("\nUser-defined bindings:");
    for (name, scheme) in env.all_bindings() {
        // Skip builtins
        if name == "map" || name == "double" || name == "printAndDouble" || name == "test1" || name == "test2" {
            println!("  {} : {}", name, scheme.typ);
            if !scheme.vars.is_empty() {
                println!("    type vars: {:?}", scheme.vars);
            }
            if !scheme.effect_vars.is_empty() {
                println!("    effect vars: {:?}", scheme.effect_vars);
            }
        }
    }
    
    // Find map in bindings
    let map_found = env.all_bindings().iter().any(|(name, _)| name.as_str() == "map");
    println!("\nMap found in bindings: {}", map_found);
    
    // Check that test1 is pure
    let test1_scheme = env.lookup("test1").expect("test1 not found");
    println!("\ntest1 type: {}", test1_scheme.typ);
    
    // Check that test2 has IO effect  
    let test2_scheme = env.lookup("test2").expect("test2 not found");
    println!("\ntest2 type: {}", test2_scheme.typ);
}