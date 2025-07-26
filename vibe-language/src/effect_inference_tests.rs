//! Integration tests for effect inference

#[cfg(test)]
mod tests {
    use crate::parser::parse;
    use crate::ast_normalizer::AstNormalizer;
    use crate::effect_inference::infer_effects;
    use crate::koka_effects::EffectType;
    use crate::Type;

    #[test]
    fn test_pure_function_inference() {
        let source = r#"fn x -> x + 1"#;
        
        let expr = parse(source).expect("Failed to parse");
        let mut normalizer = AstNormalizer::new();
        let normalized = normalizer.normalize_expr(&expr);
        
        let (ty, effects) = infer_effects(&normalized).expect("Failed to infer effects");
        
        // Pure function should have no effects
        assert!(effects.effects.is_empty());
        println!("Type: {:?}, Effects: {:?}", ty, effects);
    }

    #[test]
    fn test_io_effect_inference() {
        let source = r#"fn msg -> perform IO.print msg"#;
        
        let expr = parse(source).expect("Failed to parse");
        let mut normalizer = AstNormalizer::new();
        let normalized = normalizer.normalize_expr(&expr);
        
        let (ty, effects) = infer_effects(&normalized).expect("Failed to infer effects");
        
        // Should infer IO effect in the function type
        match ty {
            Type::FunctionWithEffect { effects: eff, .. } => {
                // The effects would be in the function's effect annotation
                println!("Function effects: {:?}", eff);
            }
            _ => {
                println!("Type: {:?}", ty);
            }
        }
    }

    #[test]
    fn test_simple_perform_inference() {
        let source = r#"perform IO.print "Hello""#;
        
        let expr = parse(source).expect("Failed to parse");
        let mut normalizer = AstNormalizer::new();
        let normalized = normalizer.normalize_expr(&expr);
        
        let (ty, effects) = infer_effects(&normalized).expect("Failed to infer effects");
        
        // Should have IO effect
        assert!(effects.effects.contains(&EffectType::IO));
        println!("Type: {:?}, Effects: {:?}", ty, effects);
    }

    #[test]
    fn test_handled_effect_inference() {
        let source = r#"
            handle {
                perform IO.print "Hello"
            } {
                IO.print msg k -> k "Handled"
            }
        "#;
        
        let expr = parse(source).expect("Failed to parse");
        let mut normalizer = AstNormalizer::new();
        let normalized = normalizer.normalize_expr(&expr);
        
        let (ty, effects) = infer_effects(&normalized).expect("Failed to infer effects");
        
        // IO effect should be handled, so no effects remain
        assert!(!effects.effects.contains(&EffectType::IO));
        println!("Type: {:?}, Effects: {:?}", ty, effects);
    }

    #[test]
    fn test_effect_sequencing() {
        let source = r#"
            let x = perform IO.print "Hello" in
            perform State.get
        "#;
        
        let expr = parse(source).expect("Failed to parse");
        let mut normalizer = AstNormalizer::new();
        let normalized = normalizer.normalize_expr(&expr);
        
        let (ty, effects) = infer_effects(&normalized).expect("Failed to infer effects");
        
        // Should have both IO and State effects
        assert!(effects.effects.contains(&EffectType::IO));
        assert!(effects.effects.iter().any(|e| matches!(e, EffectType::State(_))));
        println!("Type: {:?}, Effects: {:?}", ty, effects);
    }
}