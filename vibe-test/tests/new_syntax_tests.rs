mod common;

#[cfg(test)]
mod new_syntax_tests {
    use crate::common::*;

    #[test]
    fn test_new_function_syntax_basic() {
        test_typecheck_ok(
            "new_function_syntax_basic",
            r#"
            let add x:Int y:Int -> Int = x + y
            add 5 3
            "#,
        );
    }

    #[test]
    fn test_new_function_syntax_with_effects() {
        test_typecheck_ok(
            "new_function_syntax_with_effects",
            r#"
            let printInt x:Int -> <IO> Unit = perform IO (intToString x)
            "#,
        );
    }

    #[test]
    fn test_optional_parameters() {
        test_typecheck_ok(
            "optional_parameters",
            r#"
            let process key:Int flag?:String? -> Int = 
              match flag {
                None -> key
                Some s -> key + (strLength s)
              }
            
            process 42 None
            "#,
        );
    }

    #[test]
    fn test_optional_parameter_order() {
        test_typecheck_ok(
            "optional_parameter_order",
            r#"
            let config port:Int host?:String? debug?:Bool? -> String =
              let hostStr = match host {
                None -> "localhost"
                Some h -> h
              } in
                strConcat hostStr (strConcat ":" (intToString port))
            
            config 8080 (Some "example.com") None
            "#,
        );
    }

    #[test]
    fn test_partial_application_with_optional() {
        test_typecheck_ok(
            "partial_application_optional",
            r#"
            let process key:Int flag?:String? -> Int = 
              match flag {
                None -> key
                Some s -> key + (strLength s)
              }
            
            let process42 = process 42
            process42 (Some "test")
            "#,
        );
    }

    #[test]
    fn test_invalid_optional_parameter_order() {
        test_typecheck_err(
            "invalid_optional_parameter_order",
            r#"
            let invalid flag?:String? key:Int -> Int = key
            "#,
        );
    }

    #[test]
    fn test_recursive_with_new_syntax() {
        test_typecheck_ok(
            "recursive_new_syntax",
            r#"
            let factorial = rec f n:Int -> Int =
              if (eq n 0) {
                1
              } else {
                n * (f (n - 1))
              }
            
            factorial 5
            "#,
        );
    }

    #[test]
    fn test_option_type_sugar() {
        test_typecheck_ok(
            "option_type_sugar",
            r#"
            let maybe n:Int? -> Int =
              match n {
                None -> 0
                Some x -> x
              }
            
            maybe (Some 42)
            "#,
        );
    }
}