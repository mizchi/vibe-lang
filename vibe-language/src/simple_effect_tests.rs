//! Simple tests for effect inference without full parsing

#[cfg(test)]
mod tests {
    use crate::normalized_ast::{NormalizedExpr, NormalizedHandler};
    use crate::effect_inference::infer_effects;
    use crate::koka_effects::EffectType;
    use crate::Literal;

    #[test]
    fn test_literal_is_pure() {
        let expr = NormalizedExpr::Literal(Literal::Int(42));
        let (ty, effects) = infer_effects(&expr).expect("Failed to infer effects");
        
        // Literals should be pure
        assert!(effects.effects.is_empty());
        println!("Literal: Type: {:?}, Effects: {:?}", ty, effects);
    }

    #[test]
    fn test_perform_has_effect() {
        let expr = NormalizedExpr::Perform {
            effect: "IO".to_string(),
            operation: "print".to_string(),
            args: vec![NormalizedExpr::Literal(Literal::String("Hello".to_string()))],
        };
        
        let (ty, effects) = infer_effects(&expr).expect("Failed to infer effects");
        
        // Should have IO effect
        assert!(effects.effects.contains(&EffectType::IO));
        println!("Perform: Type: {:?}, Effects: {:?}", ty, effects);
    }

    #[test]
    fn test_handle_removes_effect() {
        let perform_expr = NormalizedExpr::Perform {
            effect: "IO".to_string(),
            operation: "print".to_string(),
            args: vec![NormalizedExpr::Literal(Literal::String("Hello".to_string()))],
        };
        
        let handler = NormalizedHandler {
            effect: "IO".to_string(),
            operation: "print".to_string(),
            params: vec!["msg".to_string()],
            resume: "k".to_string(),
            body: NormalizedExpr::Apply {
                func: Box::new(NormalizedExpr::Var("k".to_string())),
                arg: Box::new(NormalizedExpr::Literal(Literal::String("Handled".to_string()))),
            },
        };
        
        let handle_expr = NormalizedExpr::Handle {
            expr: Box::new(perform_expr),
            handlers: vec![handler],
        };
        
        let (ty, effects) = infer_effects(&handle_expr).expect("Failed to infer effects");
        
        // IO effect should be handled
        assert!(!effects.effects.contains(&EffectType::IO));
        println!("Handle: Type: {:?}, Effects: {:?}", ty, effects);
    }

    #[test]
    fn test_let_combines_effects() {
        let io_expr = NormalizedExpr::Perform {
            effect: "IO".to_string(),
            operation: "print".to_string(),
            args: vec![],
        };
        
        let state_expr = NormalizedExpr::Perform {
            effect: "State".to_string(),
            operation: "get".to_string(),
            args: vec![],
        };
        
        let let_expr = NormalizedExpr::Let {
            name: "x".to_string(),
            value: Box::new(io_expr),
            body: Box::new(state_expr),
        };
        
        let (ty, effects) = infer_effects(&let_expr).expect("Failed to infer effects");
        
        // Should have both IO and State effects
        assert!(effects.effects.contains(&EffectType::IO));
        assert!(effects.effects.iter().any(|e| matches!(e, EffectType::State(_))));
        println!("Let: Type: {:?}, Effects: {:?}", ty, effects);
    }

    #[test]
    fn test_lambda_is_pure_but_captures_effects() {
        let perform_expr = NormalizedExpr::Perform {
            effect: "IO".to_string(),
            operation: "print".to_string(),
            args: vec![NormalizedExpr::Var("x".to_string())],
        };
        
        let lambda = NormalizedExpr::Lambda {
            param: "x".to_string(),
            body: Box::new(perform_expr),
        };
        
        let (ty, effects) = infer_effects(&lambda).expect("Failed to infer effects");
        
        // Lambda itself should be pure
        assert!(effects.effects.is_empty());
        
        // But its type should capture the effect
        println!("Lambda: Type: {:?}, Effects: {:?}", ty, effects);
    }
}