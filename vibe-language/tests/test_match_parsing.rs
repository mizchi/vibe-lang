#[cfg(test)]
mod tests {
    use vibe_language::parser::parse;
    
    #[test]
    fn test_parse_simple_match() {
        let result = parse("match true { true -> 1 false -> 0 }");
        match result {
            Ok(expr) => {
                println!("Parsed successfully: {:?}", expr);
                // Check if it's a Match expression
                match expr {
                    vibe_language::Expr::Match { .. } => {
                        // Success
                    }
                    _ => panic!("Expected Match expression, got: {:?}", expr),
                }
            }
            Err(e) => {
                panic!("Failed to parse match expression: {:?}", e);
            }
        }
    }
    
    #[test]
    fn test_parse_match_with_variable() {
        let result = parse("match x { true -> 1 false -> 0 }");
        match result {
            Ok(expr) => {
                println!("Parsed successfully: {:?}", expr);
                // Check if it's a Match expression
                match expr {
                    vibe_language::Expr::Match { .. } => {
                        // Success
                    }
                    _ => panic!("Expected Match expression, got: {:?}", expr),
                }
            }
            Err(e) => {
                panic!("Failed to parse match expression: {:?}", e);
            }
        }
    }
}