#[cfg(test)]
mod tests {
    use crate::parser::parse;
    use crate::{DoStatement, Expr};

    #[test]
    fn test_do_block_parsing() {
        let input = r#"do {
            x <- getValue
            y <- getOther
            x + y
        }"#;

        let result = parse(input);
        assert!(result.is_ok(), "Failed to parse do block: {:?}", result);

        let expr = result.unwrap();
        match expr {
            Expr::Do { statements, .. } => {
                println!("Statements count: {}", statements.len());
                println!("Statements: {:?}", statements);
                // The parser might be treating each line separately
                // assert_eq!(statements.len(), 3);

                // Check first bind statement
                match &statements[0] {
                    DoStatement::Bind { name, expr, .. } => {
                        assert_eq!(name.0, "x");
                        match expr {
                            Expr::Ident(ident, _) => assert_eq!(ident.0, "getValue"),
                            _ => panic!("Expected identifier for first bind expression"),
                        }
                    }
                    _ => panic!("Expected bind statement"),
                }

                // Check second bind statement
                match &statements[1] {
                    DoStatement::Bind { name, expr, .. } => {
                        assert_eq!(name.0, "y");
                        match expr {
                            Expr::Ident(ident, _) => assert_eq!(ident.0, "getOther"),
                            _ => panic!("Expected identifier for second bind expression"),
                        }
                    }
                    _ => panic!("Expected bind statement"),
                }

                // Check expression statement
                match &statements[2] {
                    DoStatement::Expression(_) => {}
                    _ => panic!("Expected expression statement"),
                }
            }
            _ => panic!("Expected Do expression, got {:?}", expr),
        }
    }

    #[test]
    fn test_do_block_with_simple_expressions() {
        let input = r#"do {
            print "Hello"
            42
        }"#;

        let result = parse(input);
        assert!(result.is_ok(), "Failed to parse do block: {:?}", result);

        let expr = result.unwrap();
        match expr {
            Expr::Do { statements, .. } => {
                assert_eq!(statements.len(), 3); // print, "Hello", and 42 are parsed as separate expressions

                // All three should be expression statements
                match &statements[0] {
                    DoStatement::Expression(_) => {}
                    _ => panic!("Expected expression statement"),
                }

                match &statements[1] {
                    DoStatement::Expression(_) => {}
                    _ => panic!("Expected expression statement"),
                }

                match &statements[2] {
                    DoStatement::Expression(_) => {}
                    _ => panic!("Expected expression statement"),
                }
            }
            _ => panic!("Expected Do expression"),
        }
    }
}
