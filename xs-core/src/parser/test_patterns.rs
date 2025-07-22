//! Tests for pattern matching parser

#[cfg(test)]
mod tests {
    use crate::parser::parse;
    use crate::{Pattern, Expr, Ident, Literal};

    #[test]
    fn test_empty_list_pattern() {
        let input = "(match lst ((list) 0))";
        let result = parse(input);
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
        
        if let Ok(Expr::Match { cases, .. }) = result {
            assert_eq!(cases.len(), 1);
            if let Pattern::List { patterns, rest, .. } = &cases[0].0 {
                assert!(patterns.is_empty());
                assert!(rest.is_none());
            } else {
                panic!("Expected List pattern");
            }
        } else {
            panic!("Expected Match expression");
        }
    }

    #[test]
    fn test_single_element_list_pattern() {
        let input = "(match lst ((list x) x))";
        let result = parse(input);
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
        
        if let Ok(Expr::Match { cases, .. }) = result {
            assert_eq!(cases.len(), 1);
            if let Pattern::List { patterns, rest, .. } = &cases[0].0 {
                assert_eq!(patterns.len(), 1);
                assert!(rest.is_none());
                if let Pattern::Variable(Ident(name), _) = &patterns[0] {
                    assert_eq!(name, "x");
                } else {
                    panic!("Expected Variable pattern");
                }
            } else {
                panic!("Expected List pattern");
            }
        } else {
            panic!("Expected Match expression");
        }
    }

    #[test]
    fn test_list_rest_pattern() {
        let input = "(match lst ((list h ... t) h))";
        let result = parse(input);
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
        
        if let Ok(Expr::Match { cases, .. }) = result {
            assert_eq!(cases.len(), 1);
            if let Pattern::List { patterns, rest, .. } = &cases[0].0 {
                assert_eq!(patterns.len(), 1);
                assert!(rest.is_some());
                
                if let Pattern::Variable(Ident(name), _) = &patterns[0] {
                    assert_eq!(name, "h");
                } else {
                    panic!("Expected Variable pattern for head");
                }
                
                if let Some(rest_pattern) = rest {
                    if let Pattern::Variable(Ident(name), _) = rest_pattern.as_ref() {
                        assert_eq!(name, "t");
                    } else {
                        panic!("Expected Variable pattern for rest");
                    }
                } else {
                    panic!("Expected rest pattern");
                }
            } else {
                panic!("Expected List pattern");
            }
        } else {
            panic!("Expected Match expression");
        }
    }

    #[test]
    fn test_multiple_elements_with_rest() {
        let input = "(match lst ((list a b c ... rest) a))";
        let result = parse(input);
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
        
        if let Ok(Expr::Match { cases, .. }) = result {
            assert_eq!(cases.len(), 1);
            if let Pattern::List { patterns, rest, .. } = &cases[0].0 {
                assert_eq!(patterns.len(), 3);
                assert!(rest.is_some());
                
                // Check each pattern is a variable
                for (i, p) in patterns.iter().enumerate() {
                    if let Pattern::Variable(Ident(name), _) = p {
                        match i {
                            0 => assert_eq!(name, "a"),
                            1 => assert_eq!(name, "b"),
                            2 => assert_eq!(name, "c"),
                            _ => panic!("Unexpected pattern index"),
                        }
                    } else {
                        panic!("Expected Variable pattern at index {}", i);
                    }
                }
                
                if let Some(rest_pattern) = rest {
                    if let Pattern::Variable(Ident(name), _) = rest_pattern.as_ref() {
                        assert_eq!(name, "rest");
                    } else {
                        panic!("Expected Variable pattern for rest");
                    }
                }
            } else {
                panic!("Expected List pattern");
            }
        } else {
            panic!("Expected Match expression");
        }
    }

    #[test]
    fn test_literal_in_list_pattern() {
        let input = "(match lst ((list 0 x) x))";
        let result = parse(input);
        assert!(result.is_ok(), "Failed to parse: {:?}", result);
        
        if let Ok(Expr::Match { cases, .. }) = result {
            assert_eq!(cases.len(), 1);
            if let Pattern::List { patterns, rest, .. } = &cases[0].0 {
                assert_eq!(patterns.len(), 2);
                assert!(rest.is_none());
                
                if let Pattern::Literal(Literal::Int(n), _) = &patterns[0] {
                    assert_eq!(*n, 0);
                } else {
                    panic!("Expected Int literal pattern");
                }
                
                if let Pattern::Variable(Ident(name), _) = &patterns[1] {
                    assert_eq!(name, "x");
                } else {
                    panic!("Expected Variable pattern");
                }
            } else {
                panic!("Expected List pattern");
            }
        } else {
            panic!("Expected Match expression");
        }
    }
}