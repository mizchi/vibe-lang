#[cfg(test)]
mod test_gll_parser_multi_statements {
    use vibe_language::parser::experimental::parse_with_gll;
    use vibe_language::{Expr, Ident, Type};

    fn parse_source(source: &str) -> Result<Vec<Expr>, String> {
        let exprs = parse_with_gll(source)?;
        Ok(exprs)
    }

    #[test]
    fn test_parse_option_type_sugar() {
        let source = "let x : String? = None\nlet y : Int? = Some 42\n";

        let result = parse_source(source);
        assert!(result.is_ok(), "Parse failed: {:?}", result);

        let exprs = result.unwrap();
        assert_eq!(exprs.len(), 2);

        // Check first let binding
        if let Expr::Let { name, type_ann, .. } = &exprs[0] {
            assert_eq!(name.0, "x");
            assert_eq!(
                type_ann.as_ref().unwrap(),
                &Type::Option(Box::new(Type::String))
            );
        } else {
            panic!("Expected Let expression for x");
        }

        // Check second let binding
        if let Expr::Let { name, type_ann, .. } = &exprs[1] {
            assert_eq!(name.0, "y");
            assert_eq!(
                type_ann.as_ref().unwrap(),
                &Type::Option(Box::new(Type::Int))
            );
        } else {
            panic!("Expected Let expression for y");
        }
    }

    #[test]
    fn test_parse_none_constructor() {
        let source = "let x = None\n";

        let result = parse_source(source);
        assert!(result.is_ok(), "Parse failed: {:?}", result);

        let exprs = result.unwrap();
        assert_eq!(exprs.len(), 1);

        if let Expr::Let { value, .. } = &exprs[0] {
            if let Expr::Constructor { name, args, .. } = value.as_ref() {
                assert_eq!(name.0, "None");
                assert_eq!(args.len(), 0);
            } else {
                panic!("Expected Constructor expression for None, got: {:?}", value);
            }
        } else {
            panic!("Expected Let expression");
        }
    }

    #[test]
    fn test_parse_some_constructor() {
        let source = "let x = Some 42\n";

        let result = parse_source(source);
        assert!(result.is_ok(), "Parse failed: {:?}", result);

        let exprs = result.unwrap();
        assert_eq!(exprs.len(), 1);

        if let Expr::Let { value, .. } = &exprs[0] {
            if let Expr::Apply { func, args, .. } = value.as_ref() {
                if let Expr::Ident(Ident(name), _) = func.as_ref() {
                    assert_eq!(name, "Some");
                } else {
                    panic!("Expected Some identifier");
                }
                assert_eq!(args.len(), 1);
                if let Expr::Literal(vibe_language::Literal::Int(val), _) = &args[0] {
                    assert_eq!(*val, 42);
                } else {
                    panic!("Expected integer literal");
                }
            } else {
                panic!("Expected Apply expression for Some 42");
            }
        } else {
            panic!("Expected Let expression");
        }
    }

    #[test]
    fn test_parse_option_pattern_match() {
        let source = "match x {\n  None -> 0\n  Some v -> v\n}\n";

        let result = parse_source(source);
        assert!(result.is_ok(), "Parse failed: {:?}", result);

        let exprs = result.unwrap();
        assert_eq!(exprs.len(), 1);

        if let Expr::Match { cases, .. } = &exprs[0] {
            assert_eq!(cases.len(), 2);

            // Check None pattern
            let (none_pattern, _) = &cases[0];
            if let vibe_language::Pattern::Constructor { name, patterns, .. } = none_pattern {
                assert_eq!(name.0, "None");
                assert_eq!(patterns.len(), 0);
            } else {
                panic!("Expected Constructor pattern for None");
            }

            // Check Some pattern
            let (some_pattern, _) = &cases[1];
            if let vibe_language::Pattern::Constructor { name, patterns, .. } = some_pattern {
                assert_eq!(name.0, "Some");
                assert_eq!(patterns.len(), 1);
            } else {
                panic!("Expected Constructor pattern for Some");
            }
        } else {
            panic!("Expected Match expression");
        }
    }

    #[test]
    fn test_parse_nested_option_type() {
        let source = "let x : String?? = None\n";

        let result = parse_source(source);
        assert!(result.is_ok(), "Parse failed: {:?}", result);

        let exprs = result.unwrap();
        assert_eq!(exprs.len(), 1);

        if let Expr::Let { type_ann, .. } = &exprs[0] {
            // String?? should be Option<Option<String>>
            assert_eq!(
                type_ann.as_ref().unwrap(),
                &Type::Option(Box::new(Type::Option(Box::new(Type::String))))
            );
        } else {
            panic!("Expected Let expression");
        }
    }

    #[test]
    fn test_parse_option_in_function_type() {
        let source = "let f : Int? -> String? = fn x -> None\n";

        let result = parse_source(source);
        assert!(result.is_ok(), "Parse failed: {:?}", result);

        let exprs = result.unwrap();
        assert_eq!(exprs.len(), 1);

        if let Expr::Let { type_ann, .. } = &exprs[0] {
            if let Type::Function(from, to) = type_ann.as_ref().unwrap() {
                assert_eq!(from.as_ref(), &Type::Option(Box::new(Type::Int)));
                assert_eq!(to.as_ref(), &Type::Option(Box::new(Type::String)));
            } else {
                panic!("Expected function type");
            }
        } else {
            panic!("Expected Let expression");
        }
    }
}
