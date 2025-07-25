#[cfg(test)]
mod tests {
    use vibe_language::parser;
    use vibe_language::{Expr, Ident, Span};

    #[test]
    fn test_simple_addition() {
        let result = parser::parse("x + y").unwrap();
        match result {
            Expr::Apply { func, args, .. } => {
                match &*func {
                    Expr::Ident(Ident(name), _) => assert_eq!(name, "+"),
                    _ => panic!("Expected + operator, got {:?}", func),
                }
                assert_eq!(args.len(), 2);
                match &args[0] {
                    Expr::Ident(Ident(name), _) => assert_eq!(name, "x"),
                    _ => panic!("Expected identifier x, got {:?}", args[0]),
                }
                match &args[1] {
                    Expr::Ident(Ident(name), _) => assert_eq!(name, "y"),
                    _ => panic!("Expected identifier y, got {:?}", args[1]),
                }
            }
            _ => panic!("Expected Apply expression, got {:?}", result),
        }
    }

    #[test]
    fn test_subtraction() {
        let result = parser::parse("a - b").unwrap();
        match result {
            Expr::Apply { func, args, .. } => {
                match &*func {
                    Expr::Ident(Ident(name), _) => assert_eq!(name, "-"),
                    _ => panic!("Expected - operator"),
                }
                assert_eq!(args.len(), 2);
            }
            _ => panic!("Expected Apply expression"),
        }
    }

    #[test]
    fn test_multiplication() {
        let result = parser::parse("p * q").unwrap();
        match result {
            Expr::Apply { func, args, .. } => {
                match &*func {
                    Expr::Ident(Ident(name), _) => assert_eq!(name, "*"),
                    _ => panic!("Expected * operator"),
                }
                assert_eq!(args.len(), 2);
            }
            _ => panic!("Expected Apply expression"),
        }
    }

    #[test]
    fn test_complex_expression() {
        let result = parser::parse("a + b * c").unwrap();
        // Should parse as a + (b * c) due to precedence
        match result {
            Expr::Apply { func, args, .. } => {
                match &*func {
                    Expr::Ident(Ident(name), _) => assert_eq!(name, "+"),
                    _ => panic!("Expected + operator"),
                }
                assert_eq!(args.len(), 2);
                // Second argument should be b * c
                match &args[1] {
                    Expr::Apply { func: inner_func, args: inner_args, .. } => {
                        match &**inner_func {
                            Expr::Ident(Ident(name), _) => assert_eq!(name, "*"),
                            _ => panic!("Expected * operator"),
                        }
                        assert_eq!(inner_args.len(), 2);
                    }
                    _ => panic!("Expected multiplication as second argument"),
                }
            }
            _ => panic!("Expected Apply expression"),
        }
    }
}