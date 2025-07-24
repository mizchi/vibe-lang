#[cfg(test)]
mod hash_reference_tests {
    use xs_core::parser::parse;
    use xs_core::{Expr, Span};

    #[test]
    fn test_parse_hash_reference() {
        let input = "#abc123def456";
        let result = parse(input);
        assert!(result.is_ok());
        
        match &result.unwrap() {
            Expr::HashRef { hash, .. } => {
                assert_eq!(hash, "abc123def456");
            }
            _ => panic!("Expected HashRef expression"),
        }
    }

    #[test]
    fn test_hash_ref_in_application() {
        let input = "double #abc123";
        let result = parse(input);
        assert!(result.is_ok());
        
        let expr = result.unwrap();
        eprintln!("Parsed expression: {:?}", expr);
        
        match &expr {
            Expr::Apply { func, args, .. } => {
                // Check function is 'double'
                match func.as_ref() {
                    Expr::Ident(name, _) => assert_eq!(name.0, "double"),
                    _ => panic!("Expected identifier 'double'"),
                }
                
                // Check argument is hash reference
                assert_eq!(args.len(), 1);
                match &args[0] {
                    Expr::HashRef { hash, .. } => {
                        assert_eq!(hash, "abc123");
                    }
                    _ => panic!("Expected HashRef as argument, got: {:?}", args[0]),
                }
            }
            _ => panic!("Expected Apply expression, got: {:?}", expr),
        }
    }

    #[test]
    fn test_hash_ref_in_let_binding() {
        let input = "let y = #def456";
        let result = parse(input);
        assert!(result.is_ok());
        
        match &result.unwrap() {
            Expr::Let { name, value, .. } => {
                assert_eq!(name.0, "y");
                match value.as_ref() {
                    Expr::HashRef { hash, .. } => {
                        assert_eq!(hash, "def456");
                    }
                    _ => panic!("Expected HashRef in let value"),
                }
            }
            _ => panic!("Expected Let expression"),
        }
    }
}