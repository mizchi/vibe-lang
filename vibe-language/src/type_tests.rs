//! Tests for type system improvements

#[cfg(test)]
mod tests {
    use crate::Type;

    #[test]
    fn test_option_type_display() {
        let option_string = Type::Option(Box::new(Type::String));
        assert_eq!(format!("{}", option_string), "String?");
        
        let option_int = Type::Option(Box::new(Type::Int));
        assert_eq!(format!("{}", option_int), "Int?");
        
        // Nested option
        let nested_option = Type::Option(Box::new(Type::Option(Box::new(Type::Int))));
        assert_eq!(format!("{}", nested_option), "Int??");
    }

    #[test]
    fn test_tuple_type_display() {
        let empty_tuple = Type::Tuple(vec![]);
        assert_eq!(format!("{}", empty_tuple), "()");
        
        let single_tuple = Type::Tuple(vec![Type::Int]);
        assert_eq!(format!("{}", single_tuple), "(Int)");
        
        let pair_tuple = Type::Tuple(vec![Type::Int, Type::String]);
        assert_eq!(format!("{}", pair_tuple), "(Int, String)");
        
        let triple_tuple = Type::Tuple(vec![Type::Int, Type::Bool, Type::String]);
        assert_eq!(format!("{}", triple_tuple), "(Int, Bool, String)");
    }

    #[test]
    fn test_complex_type_display() {
        // Function returning optional value: Int -> String?
        let func_type = Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Option(Box::new(Type::String)))
        );
        assert_eq!(format!("{}", func_type), "Int -> String?");
        
        // Function taking optional parameter: String? -> Int
        let func_with_opt_param = Type::Function(
            Box::new(Type::Option(Box::new(Type::String))),
            Box::new(Type::Int)
        );
        assert_eq!(format!("{}", func_with_opt_param), "String? -> Int");
        
        // Function returning tuple: Int -> (Bool, String)
        let func_returning_tuple = Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Tuple(vec![Type::Bool, Type::String]))
        );
        assert_eq!(format!("{}", func_returning_tuple), "Int -> (Bool, String)");
    }

    #[test]
    fn test_type_equality() {
        let opt1 = Type::Option(Box::new(Type::Int));
        let opt2 = Type::Option(Box::new(Type::Int));
        assert_eq!(opt1, opt2);
        
        let tuple1 = Type::Tuple(vec![Type::Int, Type::Bool]);
        let tuple2 = Type::Tuple(vec![Type::Int, Type::Bool]);
        assert_eq!(tuple1, tuple2);
        
        let tuple3 = Type::Tuple(vec![Type::Bool, Type::Int]);
        assert_ne!(tuple1, tuple3); // Different order
    }
}