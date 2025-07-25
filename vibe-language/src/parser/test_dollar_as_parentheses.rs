use crate::parser::parse;
use crate::{Expr, Ident};

/// Test that $ operator acts exactly like parentheses
/// The core principle: `f $ expr` is identical to `f (expr)`

#[test]
fn test_dollar_is_parentheses_basic() {
    // Test: f $ x should be identical to f (x)
    let with_dollar = parse("f $ x").unwrap();
    let with_parens = parse("f (x)").unwrap();
    
    // Both should be Apply { func: f, args: [x] }
    assert!(matches!(with_dollar, Expr::Apply { .. }));
    assert!(matches!(with_parens, Expr::Apply { .. }));
}

#[test]
fn test_dollar_with_arithmetic() {
    // Test: f $ x + y should be identical to f (x + y)
    let with_dollar = parse("f $ x + y").unwrap();
    let with_parens = parse("f (x + y)").unwrap();
    
    // Both should parse as: Apply(f, [Apply(+, [x, y])])
    match (&with_dollar, &with_parens) {
        (Expr::Apply { func: f1, args: args1, .. }, 
         Expr::Apply { func: f2, args: args2, .. }) => {
            // Check function is 'f'
            assert!(matches!(f1.as_ref(), Expr::Ident(Ident(s), _) if s == "f"));
            assert!(matches!(f2.as_ref(), Expr::Ident(Ident(s), _) if s == "f"));
            
            // Check single argument which is (x + y)
            assert_eq!(args1.len(), 1);
            assert_eq!(args2.len(), 1);
            assert!(matches!(&args1[0], Expr::Apply { .. }));
            assert!(matches!(&args2[0], Expr::Apply { .. }));
        }
        _ => panic!("Expected Apply expressions"),
    }
}

#[test]
fn test_dollar_right_associative() {
    // Test: f $ g $ h x should be identical to f (g (h x))
    let with_dollar = parse("f $ g $ h x").unwrap();
    let with_parens = parse("f (g (h x))").unwrap();
    
    // Both should have the same structure
    match (&with_dollar, &with_parens) {
        (Expr::Apply { func: f1, args: args1, .. }, 
         Expr::Apply { func: f2, args: args2, .. }) => {
            // Check f
            assert!(matches!(f1.as_ref(), Expr::Ident(Ident(s), _) if s == "f"));
            assert!(matches!(f2.as_ref(), Expr::Ident(Ident(s), _) if s == "f"));
            
            // Check args[0] is g(h x)
            assert_eq!(args1.len(), 1);
            assert_eq!(args2.len(), 1);
            
            match (&args1[0], &args2[0]) {
                (Expr::Apply { func: g1, args: g_args1, .. },
                 Expr::Apply { func: g2, args: g_args2, .. }) => {
                    // Check g
                    assert!(matches!(g1.as_ref(), Expr::Ident(Ident(s), _) if s == "g"));
                    assert!(matches!(g2.as_ref(), Expr::Ident(Ident(s), _) if s == "g"));
                    
                    // Check g's arg is (h x)
                    assert_eq!(g_args1.len(), 1);
                    assert_eq!(g_args2.len(), 1);
                    assert!(matches!(&g_args1[0], Expr::Apply { .. }));
                    assert!(matches!(&g_args2[0], Expr::Apply { .. }));
                }
                _ => panic!("Expected nested Apply"),
            }
        }
        _ => panic!("Expected Apply expressions"),
    }
}

#[test]
fn test_dollar_precedence_vs_application() {
    // Test: f x $ g y
    // This should parse as: (f x) (g y)
    // Because function application has higher precedence than $
    let expr = parse("f x $ g y").unwrap();
    
    match expr {
        Expr::Apply { func, args, .. } => {
            // func should be (f x)
            match func.as_ref() {
                Expr::Apply { func: f_func, args: f_args, .. } => {
                    assert!(matches!(f_func.as_ref(), Expr::Ident(Ident(s), _) if s == "f"));
                    assert_eq!(f_args.len(), 1);
                    assert!(matches!(&f_args[0], Expr::Ident(Ident(s), _) if s == "x"));
                }
                _ => panic!("Expected (f x)"),
            }
            
            // args[0] should be (g y)
            assert_eq!(args.len(), 1);
            match &args[0] {
                Expr::Apply { func: g_func, args: g_args, .. } => {
                    assert!(matches!(g_func.as_ref(), Expr::Ident(Ident(s), _) if s == "g"));
                    assert_eq!(g_args.len(), 1);
                    assert!(matches!(&g_args[0], Expr::Ident(Ident(s), _) if s == "y"));
                }
                _ => panic!("Expected (g y)"),
            }
        }
        _ => panic!("Expected Apply"),
    }
}

#[test]
fn test_dollar_with_complex_expressions() {
    // Test: print $ "Hello " ++ name ++ "!"
    // Should be identical to: print ("Hello " ++ name ++ "!")
    let with_dollar = parse(r#"print $ "Hello " ++ name ++ "!""#).unwrap();
    let with_parens = parse(r#"print ("Hello " ++ name ++ "!")"#).unwrap();
    
    // Both should have print as function with one complex argument
    match (&with_dollar, &with_parens) {
        (Expr::Apply { func: f1, args: args1, .. }, 
         Expr::Apply { func: f2, args: args2, .. }) => {
            assert!(matches!(f1.as_ref(), Expr::Ident(Ident(s), _) if s == "print"));
            assert!(matches!(f2.as_ref(), Expr::Ident(Ident(s), _) if s == "print"));
            assert_eq!(args1.len(), 1);
            assert_eq!(args2.len(), 1);
        }
        _ => panic!("Expected Apply expressions"),
    }
}

#[test]
fn test_dollar_unnecessary_usage() {
    // These pairs should be identical ($ is unnecessary here)
    let tests = vec![
        ("f $ x", "f x"),
        ("print $ message", "print message"),
        ("double $ 5", "double 5"),
    ];
    
    for (with_dollar, without) in tests {
        let expr1 = parse(with_dollar).unwrap();
        let expr2 = parse(without).unwrap();
        
        // Both should produce Apply nodes
        assert!(matches!(expr1, Expr::Apply { .. }), "Failed for: {}", with_dollar);
        assert!(matches!(expr2, Expr::Apply { .. }), "Failed for: {}", without);
    }
}

#[test]
fn test_dollar_with_conditionals() {
    // Test: process $ if flag { getThing } else { getOther }
    // Should be identical to: process (if flag { getThing } else { getOther })
    let code = "process $ if flag { getThing } else { getOther }";
    let expr = parse(code).unwrap();
    
    match expr {
        Expr::Apply { func, args, .. } => {
            assert!(matches!(func.as_ref(), Expr::Ident(Ident(s), _) if s == "process"));
            assert_eq!(args.len(), 1);
            assert!(matches!(&args[0], Expr::If { .. }));
        }
        _ => panic!("Expected Apply with If"),
    }
}

#[test]
fn test_dollar_in_function_composition() {
    // Test function composition pattern
    // compose f $ compose g h
    // Should be: compose f (compose g h)
    let expr = parse("compose f $ compose g h").unwrap();
    
    match expr {
        Expr::Apply { func, args, .. } => {
            // Check compose f
            match func.as_ref() {
                Expr::Apply { func: compose, args: compose_args, .. } => {
                    assert!(matches!(compose.as_ref(), Expr::Ident(Ident(s), _) if s == "compose"));
                    assert_eq!(compose_args.len(), 1);
                    assert!(matches!(&compose_args[0], Expr::Ident(Ident(s), _) if s == "f"));
                }
                _ => panic!("Expected compose f"),
            }
            
            // Check args[0] is (compose g h)
            assert_eq!(args.len(), 1);
            match &args[0] {
                Expr::Apply { func: compose2, args: compose_args2, .. } => {
                    match compose2.as_ref() {
                        Expr::Apply { func: compose_func, args: inner_args, .. } => {
                            assert!(matches!(compose_func.as_ref(), Expr::Ident(Ident(s), _) if s == "compose"));
                            assert_eq!(inner_args.len(), 1);
                            assert!(matches!(&inner_args[0], Expr::Ident(Ident(s), _) if s == "g"));
                        }
                        _ => panic!("Expected compose application"),
                    }
                    assert_eq!(compose_args2.len(), 1);
                    assert!(matches!(&compose_args2[0], Expr::Ident(Ident(s), _) if s == "h"));
                }
                _ => panic!("Expected compose g h"),
            }
        }
        _ => panic!("Expected Apply"),
    }
}