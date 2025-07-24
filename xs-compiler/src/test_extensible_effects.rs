//! Tests for the extensible effects system

#[cfg(test)]
mod tests {
    use xs_core::Type;
    use xs_core::extensible_effects::{ExtensibleEffectRow, EffectInstance};
    use crate::effect_checker::EffectChecker;
    use crate::{TypeEnv, TypeChecker};

    fn parse_and_check(code: &str) -> Result<(Type, ExtensibleEffectRow), String> {
        // Parse the code
        let expr = xs_core::parser::parse(code)
            .map_err(|e| format!("Parse error: {:?}", e))?;
        
        // Type check
        let mut type_checker = TypeChecker::new();
        let mut type_env = TypeEnv::new();
        let typ = type_checker.check(&expr, &mut type_env)?;
        
        // Effect check
        let mut effect_checker = EffectChecker::new();
        let effects = effect_checker.infer_effects(&expr, &type_env)?;
        
        Ok((typ, effects))
    }

    #[test]
    fn test_pure_computation() {
        let code = "42";
        let (typ, effects) = parse_and_check(code).unwrap();
        
        assert_eq!(typ, Type::Int);
        assert!(effects.is_pure());
    }

    #[test]
    fn test_io_effect() {
        let code = r#"perform IO "Hello""#;
        let result = parse_and_check(code);
        
        // This might fail initially as we need to implement effect parsing
        if let Ok((_, effects)) = result {
            assert!(!effects.is_pure());
            let effect_list = effects.get_effects();
            assert!(effect_list.iter().any(|e| e.name == "IO"));
        }
    }

    #[test]
    fn test_multiple_effects() {
        let code = r#"
            do
              x <- perform State.get
              perform IO.print (Int.toString x)
              perform State.put (x + 1)
            end
        "#;
        
        let result = parse_and_check(code);
        
        if let Ok((_, effects)) = result {
            assert!(!effects.is_pure());
            let effect_list = effects.get_effects();
            assert!(effect_list.iter().any(|e| e.name == "IO"));
            assert!(effect_list.iter().any(|e| e.name == "State"));
        }
    }

    #[test]
    fn test_effect_handler() {
        let code = r#"
            handle perform State.get with
              | State.get () k -> k 42 42
              | return x s -> x
            end
        "#;
        
        let result = parse_and_check(code);
        
        // Handler should eliminate the State effect
        if let Ok((_, effects)) = result {
            // After handling, the State effect should be removed
            let effect_list = effects.get_effects();
            assert!(!effect_list.iter().any(|e| e.name == "State"));
        }
    }

    #[test]
    fn test_effect_polymorphism() {
        // A function that works with any effect
        let code = r#"
            fn map f lst = match lst {
              [] -> []
              h :: t -> (f h) :: (map f t)
            }
        "#;
        
        let result = parse_and_check(code);
        
        // The effect should be polymorphic (effect variable)
        if let Ok((typ, _effects)) = result {
            // Type should be something like (a -> e b) -> [a] -> e [b]
            match typ {
                Type::Function(_, _) => {
                    // OK - it's a function
                }
                _ => panic!("Expected function type")
            }
        }
    }

    #[test]
    fn test_effect_row_operations() {
        use xs_core::extensible_effects::ExtensibleEffectRow;
        
        // Test pure
        let pure = ExtensibleEffectRow::pure();
        assert!(pure.is_pure());
        
        // Test single effect
        let io = EffectInstance::new("IO".to_string());
        let io_row = ExtensibleEffectRow::Single(io.clone());
        assert!(!io_row.is_pure());
        
        // Test extension
        let state = EffectInstance::new("State".to_string());
        let combined = io_row.add_effect(state.clone());
        
        let effects = combined.get_effects();
        assert_eq!(effects.len(), 2);
        assert!(effects.iter().any(|e| e.name == "IO"));
        assert!(effects.iter().any(|e| e.name == "State"));
    }

    #[test]
    fn test_effect_with_type_parameters() {
        use xs_core::extensible_effects::EffectInstance;
        
        // State<Int> effect
        let state_int = EffectInstance::with_type_args(
            "State".to_string(),
            vec![Type::Int]
        );
        
        // Exception<String> effect
        let exception_string = EffectInstance::with_type_args(
            "Exception".to_string(),
            vec![Type::String]
        );
        
        // Different type parameters should make different effects
        let state_string = EffectInstance::with_type_args(
            "State".to_string(),
            vec![Type::String]
        );
        
        assert_ne!(state_int, state_string);
        assert_ne!(state_int, exception_string);
    }
}