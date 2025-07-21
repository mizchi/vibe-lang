#[cfg(test)]
mod tests {
    use crate::parser::Parser;
    use crate::{Effect, EffectRow, Type};

    #[test]
    fn test_parse_pure_function_type() {
        let mut parser = crate::parser::Parser::new("(-> Int Int)");
        let typ = parser.parse_type().unwrap();
        match typ {
            Type::Function(from, to) => {
                assert_eq!(*from, Type::Int);
                assert_eq!(*to, Type::Int);
            }
            _ => panic!("Expected function type, got {typ:?}"),
        }
    }

    #[test]
    fn test_parse_function_with_single_effect() {
        let mut parser = Parser::new("(-> String String ! IO)");
        let typ = parser.parse_type().unwrap();
        match typ {
            Type::FunctionWithEffect { from, to, effects } => {
                assert_eq!(*from, Type::String);
                assert_eq!(*to, Type::String);
                match effects {
                    EffectRow::Concrete(set) => {
                        assert!(set.contains(&Effect::IO));
                    }
                    _ => panic!("Expected concrete effect set"),
                }
            }
            _ => panic!("Expected function with effect type, got {typ:?}"),
        }
    }

    #[test]
    fn test_parse_function_with_multiple_effects() {
        let mut parser = Parser::new("(-> String String ! {IO, Error})");
        let typ = parser.parse_type().unwrap();
        match typ {
            Type::FunctionWithEffect { from, to, effects } => {
                assert_eq!(*from, Type::String);
                assert_eq!(*to, Type::String);
                match effects {
                    EffectRow::Concrete(set) => {
                        assert!(set.contains(&Effect::IO));
                        assert!(set.contains(&Effect::Error));
                    }
                    _ => panic!("Expected concrete effect set"),
                }
            }
            _ => panic!("Expected function with effect type, got {typ:?}"),
        }
    }

    #[test]
    fn test_parse_function_with_effect_variable() {
        let mut parser = Parser::new("(-> Int Int ! e)");
        let typ = parser.parse_type().unwrap();
        match typ {
            Type::FunctionWithEffect { from, to, effects } => {
                assert_eq!(*from, Type::Int);
                assert_eq!(*to, Type::Int);
                match effects {
                    EffectRow::Variable(var) => {
                        assert_eq!(var.0, "e");
                    }
                    _ => panic!("Expected effect variable"),
                }
            }
            _ => panic!("Expected function with effect type, got {typ:?}"),
        }
    }
}
