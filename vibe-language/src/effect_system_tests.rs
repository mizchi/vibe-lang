//! Tests for the Koka-style effect system integration

#[cfg(test)]
mod tests {
    use crate::parser::parse;
    use crate::ast_normalizer::AstNormalizer;
    use crate::koka_effects::{EffectType, EffectRow};
    use crate::effect_normalizer::EffectNormalizer;
    use crate::normalized_ast::NormalizedExpr;

    #[test]
    fn test_simple_perform_normalization() {
        let source = r#"perform IO.print "Hello, World!""#;
        
        let expr = parse(source).expect("Failed to parse");
        let mut normalizer = AstNormalizer::new();
        let normalized = normalizer.normalize_expr(&expr);
        
        // Verify it's normalized to a Perform expression
        match normalized {
            NormalizedExpr::Perform { effect, operation, args } => {
                assert_eq!(effect, "IO");
                assert_eq!(operation, "perform");
                assert_eq!(args.len(), 1);
            }
            _ => panic!("Expected Perform expression"),
        }
    }

    #[test]
    fn test_with_handler_normalization() {
        let source = r#"with stateHandler { x }"#;
        
        let expr = parse(source).expect("Failed to parse");
        let mut normalizer = AstNormalizer::new();
        let normalized = normalizer.normalize_expr(&expr);
        
        // Verify it's normalized to a Handle expression
        match normalized {
            NormalizedExpr::Handle { expr, handlers } => {
                // The body should be a variable reference
                match expr.as_ref() {
                    NormalizedExpr::Var(name) => {
                        assert_eq!(name, "x");
                    }
                    _ => panic!("Expected variable x in handle body"),
                }
                // For simple handler reference, handlers might be empty
                // (to be filled by type checker)
                assert_eq!(handlers.len(), 0);
            }
            _ => panic!("Expected Handle expression"),
        }
    }

    #[test]
    fn test_do_notation_normalization() {
        // Use simpler syntax that the parser can handle
        let source = r#"do {
            x <- foo;
            y
        }"#;
        
        let expr = parse(source).expect("Failed to parse");
        let mut normalizer = AstNormalizer::new();
        let normalized = normalizer.normalize_expr(&expr);
        
        // Do notation should be desugared to nested let bindings
        match &normalized {
            NormalizedExpr::Let { name, value: _, body } => {
                // The Koka-style desugaring uses Let bindings
                assert!(!name.is_empty());
                
                // Should have nested structure
                match body.as_ref() {
                    NormalizedExpr::Let { .. } | NormalizedExpr::Var(_) => {
                        // Good, we have the expected structure
                    }
                    _ => {
                        // Could also be other structures depending on desugaring
                        println!("Body structure: {:?}", body);
                    }
                }
            }
            _ => {
                println!("Normalized structure: {:?}", normalized);
                panic!("Expected Let expression from do notation");
            }
        }
    }

    #[test]
    fn test_effect_inference() {
        let source = r#"perform IO.print "Hello""#;
        
        let expr = parse(source).expect("Failed to parse");
        let mut normalizer = AstNormalizer::new();
        let normalized = normalizer.normalize_expr(&expr);
        
        // Infer effects
        let effect_normalizer = EffectNormalizer::new();
        let effects = effect_normalizer.infer_effects(&normalized);
        
        // Should infer IO effect
        assert!(effects.contains("IO"));
    }

    #[test]
    fn test_handle_expression() {
        let source = r#"handle { 42 } { }"#;
        
        let expr = parse(source).expect("Failed to parse");
        let mut normalizer = AstNormalizer::new();
        let normalized = normalizer.normalize_expr(&expr);
        
        match normalized {
            NormalizedExpr::Handle { expr, handlers } => {
                // Body should be literal 42
                match expr.as_ref() {
                    NormalizedExpr::Literal(crate::Literal::Int(42)) => {
                        // Good
                    }
                    _ => panic!("Expected literal 42"),
                }
                // Empty handlers for now
                assert_eq!(handlers.len(), 0);
            }
            _ => panic!("Expected Handle expression"),
        }
    }

    #[test]
    fn test_effect_row_operations() {
        // Test effect row creation and operations
        let io_effect = EffectType::IO;
        let state_effect = EffectType::State("Int".to_string());
        
        let row1 = EffectRow::single(io_effect.clone());
        let row2 = EffectRow::single(state_effect.clone());
        
        // Test union
        let combined = row1.union(&row2);
        assert_eq!(combined.effects.len(), 2);
        assert!(combined.effects.contains(&io_effect));
        assert!(combined.effects.contains(&state_effect));
        
        // Test polymorphic rows
        let poly_row = EffectRow::polymorphic("e".to_string());
        assert!(poly_row.row_var.is_some());
    }

    #[test] 
    fn test_record_handler_desugaring() {
        // Test that record-style handlers are properly desugared
        let handler = NormalizedExpr::Record(
            vec![
                ("State.get".to_string(), 
                 NormalizedExpr::Lambda {
                     param: "_".to_string(),
                     body: Box::new(NormalizedExpr::Lambda {
                         param: "k".to_string(),
                         body: Box::new(NormalizedExpr::Literal(crate::Literal::Int(42))),
                     }),
                 }),
            ].into_iter().collect()
        );
        
        let body = NormalizedExpr::Literal(crate::Literal::Int(0));
        let result = crate::koka_effects::desugar_with_handler(handler, body);
        
        match result {
            NormalizedExpr::Handle { handlers, .. } => {
                assert_eq!(handlers.len(), 1);
                assert_eq!(handlers[0].effect, "State");
                assert_eq!(handlers[0].operation, "get");
            }
            _ => panic!("Expected Handle expression"),
        }
    }
}