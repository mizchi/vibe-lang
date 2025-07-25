//! Tests for search pattern parsing and matching

#[cfg(test)]
mod tests {
    use vibe_language::{Expr, Ident, Literal, Span, Type};
    use vibe_cli::search_patterns::{expr_contains_pattern, parse_type_pattern, AstPattern};

    #[test]
    fn test_type_pattern_int() {
        let matcher = parse_type_pattern("Int").unwrap();
        assert!(matcher(&Type::Int));
        assert!(!matcher(&Type::String));
        assert!(!matcher(&Type::Bool));
    }

    #[test]
    fn test_type_pattern_function() {
        let matcher = parse_type_pattern("Int -> Int").unwrap();
        let int_to_int = Type::Function(Box::new(Type::Int), Box::new(Type::Int));
        let string_to_int = Type::Function(Box::new(Type::String), Box::new(Type::Int));

        assert!(matcher(&int_to_int));
        assert!(!matcher(&string_to_int));
    }

    #[test]
    fn test_type_pattern_wildcard() {
        let matcher = parse_type_pattern("_ -> Int").unwrap();
        let int_to_int = Type::Function(Box::new(Type::Int), Box::new(Type::Int));
        let string_to_int = Type::Function(Box::new(Type::String), Box::new(Type::Int));
        let int_to_string = Type::Function(Box::new(Type::Int), Box::new(Type::String));

        assert!(matcher(&int_to_int));
        assert!(matcher(&string_to_int));
        assert!(!matcher(&int_to_string));
    }

    #[test]
    fn test_type_pattern_list() {
        let matcher = parse_type_pattern("[Int]").unwrap();
        let int_list = Type::List(Box::new(Type::Int));
        let string_list = Type::List(Box::new(Type::String));

        assert!(matcher(&int_list));
        assert!(!matcher(&string_list));
    }

    #[test]
    fn test_ast_pattern_match() {
        let pattern = AstPattern::Match;
        let match_expr = Expr::Match {
            expr: Box::new(Expr::Ident(Ident("x".to_string()), Span::new(0, 1))),
            cases: vec![],
            span: Span::new(0, 10),
        };
        let if_expr = Expr::If {
            cond: Box::new(Expr::Literal(Literal::Bool(true), Span::new(0, 4))),
            then_expr: Box::new(Expr::Literal(Literal::Int(1), Span::new(5, 6))),
            else_expr: Box::new(Expr::Literal(Literal::Int(2), Span::new(7, 8))),
            span: Span::new(0, 8),
        };

        assert!(pattern.matches(&match_expr));
        assert!(!pattern.matches(&if_expr));
    }

    #[test]
    fn test_ast_pattern_contains() {
        let pattern = AstPattern::If;
        let nested_expr = Expr::Lambda {
            params: vec![(Ident("x".to_string()), None)],
            body: Box::new(Expr::If {
                cond: Box::new(Expr::Ident(Ident("x".to_string()), Span::new(0, 1))),
                then_expr: Box::new(Expr::Literal(Literal::Int(1), Span::new(2, 3))),
                else_expr: Box::new(Expr::Literal(Literal::Int(2), Span::new(4, 5))),
                span: Span::new(0, 5),
            }),
            span: Span::new(0, 10),
        };

        assert!(expr_contains_pattern(&nested_expr, &pattern));
    }
}
