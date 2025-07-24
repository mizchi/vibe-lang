#[cfg(test)]
mod tests {
    use crate::parser::parse;
    use crate::Expr;

    #[test]
    fn test_handle_with_parsing() {
        // Simplify to one handler first
        let input = r#"handle computation with {
            | State.get x resume -> resume initial
        }"#;
        
        println!("Parsing: {}", input);
        let result = parse(input);
        if let Err(ref e) = result {
            println!("Parse error: {:?}", e);
        }
        assert!(result.is_ok(), "Failed to parse handle/with: {:?}", result);
        
        let expr = result.unwrap();
        match expr {
            Expr::HandleExpr { handlers, return_handler, .. } => {
                assert_eq!(handlers.len(), 1);
                
                // Check first handler (State.get)
                let handler1 = &handlers[0];
                assert_eq!(handler1.effect.0, "State");
                assert_eq!(handler1.operation.as_ref().unwrap().0, "get");
                assert_eq!(handler1.args.len(), 1); // x
                assert_eq!(handler1.continuation.0, "resume");
                
                // Check return handler
                assert!(return_handler.is_none()); // No return handler in this test
            }
            _ => panic!("Expected HandleExpr, got {:?}", expr),
        }
    }
    
    #[test]
    fn test_handle_without_return() {
        let input = r#"handle doSomething with {
            | IO.print msg k -> k ()
        }"#;
        
        let result = parse(input);
        assert!(result.is_ok(), "Failed to parse handle/with without return: {:?}", result);
        
        let expr = result.unwrap();
        match expr {
            Expr::HandleExpr { handlers, return_handler, .. } => {
                assert_eq!(handlers.len(), 1);
                assert!(return_handler.is_none());
                
                let handler = &handlers[0];
                assert_eq!(handler.effect.0, "IO");
                assert_eq!(handler.operation.as_ref().unwrap().0, "print");
                assert_eq!(handler.continuation.0, "k");
            }
            _ => panic!("Expected HandleExpr"),
        }
    }
    
    #[test]
    fn test_handle_simple_effect() {
        let input = r#"handle getValue with {
            | getValue () k -> k 42
        }"#;
        
        println!("Parsing simple: {}", input);
        let result = parse(input);
        if let Err(ref e) = result {
            println!("Parse error: {:?}", e);
        }
        assert!(result.is_ok(), "Failed to parse simple effect handler: {:?}", result);
        
        let expr = result.unwrap();
        match expr {
            Expr::HandleExpr { handlers, .. } => {
                assert_eq!(handlers.len(), 1);
                
                let handler = &handlers[0];
                assert_eq!(handler.effect.0, "getValue");
                assert!(handler.operation.is_none());
                assert_eq!(handler.continuation.0, "k");
            }
            _ => panic!("Expected HandleExpr"),
        }
    }
    
    #[test]
    fn test_handle_minimal() {
        let input = r#"handle x with {
            | foo k -> k 1
        }"#;
        
        println!("Parsing minimal: {}", input);
        let result = parse(input);
        if let Err(ref e) = result {
            println!("Parse error: {:?}", e);
        }
        assert!(result.is_ok(), "Failed to parse minimal handler: {:?}", result);
    }
    
    #[test]
    fn test_handle_with_args() {
        let input = r#"handle x with {
            | foo x y k -> k (x + y)
        }"#;
        
        println!("Parsing with args: {}", input);
        let result = parse(input);
        if let Err(ref e) = result {
            println!("Parse error: {:?}", e);
        }
        assert!(result.is_ok(), "Failed to parse handler with args: {:?}", result);
        
        let expr = result.unwrap();
        match expr {
            Expr::HandleExpr { handlers, .. } => {
                assert_eq!(handlers.len(), 1);
                let handler = &handlers[0];
                assert_eq!(handler.effect.0, "foo");
                assert_eq!(handler.args.len(), 2); // x and y
                assert_eq!(handler.continuation.0, "k");
            }
            _ => panic!("Expected HandleExpr"),
        }
    }
}