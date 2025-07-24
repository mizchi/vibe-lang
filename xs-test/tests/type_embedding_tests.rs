#[cfg(test)]
mod type_embedding_tests {
    use xs_core::{Expr, Type, Ident, Literal, Span};
    use xs_core::type_annotator::{embed_type_annotations, deep_embed_types};
    use std::collections::HashMap;

    #[test]
    fn test_embed_let_without_annotation() {
        let expr = Expr::Let {
            name: Ident("x".to_string()),
            type_ann: None,
            value: Box::new(Expr::Literal(Literal::Int(42), Span::new(0, 2))),
            span: Span::new(0, 10),
        };
        
        let inferred_type = Type::Int;
        let result = embed_type_annotations(&expr, &inferred_type);
        
        match result {
            Expr::Let { type_ann, .. } => {
                assert_eq!(type_ann, Some(Type::Int));
            }
            _ => panic!("Expected Let expression"),
        }
    }

    #[test]
    fn test_embed_let_with_existing_annotation() {
        let expr = Expr::Let {
            name: Ident("x".to_string()),
            type_ann: Some(Type::Int),
            value: Box::new(Expr::Literal(Literal::Int(42), Span::new(0, 2))),
            span: Span::new(0, 10),
        };
        
        let inferred_type = Type::Int;
        let result = embed_type_annotations(&expr, &inferred_type);
        
        match result {
            Expr::Let { type_ann, .. } => {
                assert_eq!(type_ann, Some(Type::Int));
            }
            _ => panic!("Expected Let expression"),
        }
    }

    #[test]
    fn test_embed_lambda_parameter_type() {
        let expr = Expr::Lambda {
            params: vec![(Ident("x".to_string()), None)],
            body: Box::new(Expr::Ident(Ident("x".to_string()), Span::new(0, 1))),
            span: Span::new(0, 10),
        };
        
        let inferred_type = Type::Function(Box::new(Type::Int), Box::new(Type::Int));
        let result = embed_type_annotations(&expr, &inferred_type);
        
        match result {
            Expr::Lambda { params, .. } => {
                assert_eq!(params.len(), 1);
                assert_eq!(params[0].1, Some(Type::Int));
            }
            _ => panic!("Expected Lambda expression"),
        }
    }

    #[test]
    fn test_embed_rec_return_type() {
        let expr = Expr::Rec {
            name: Ident("factorial".to_string()),
            params: vec![(Ident("n".to_string()), None)],
            return_type: None,
            body: Box::new(Expr::Literal(Literal::Int(1), Span::new(0, 1))),
            span: Span::new(0, 50),
        };
        
        let inferred_type = Type::Function(Box::new(Type::Int), Box::new(Type::Int));
        let result = embed_type_annotations(&expr, &inferred_type);
        
        match result {
            Expr::Rec { return_type, .. } => {
                assert_eq!(return_type, Some(Type::Int));
            }
            _ => panic!("Expected Rec expression"),
        }
    }

    #[test]
    fn test_deep_embed_nested_let() {
        let expr = Expr::LetIn {
            name: Ident("x".to_string()),
            type_ann: None,
            value: Box::new(Expr::Literal(Literal::Int(42), Span::new(0, 2))),
            body: Box::new(Expr::Let {
                name: Ident("y".to_string()),
                type_ann: None,
                value: Box::new(Expr::Ident(Ident("x".to_string()), Span::new(0, 1))),
                span: Span::new(0, 10),
            }),
            span: Span::new(0, 20),
        };
        
        let mut type_env = HashMap::new();
        type_env.insert("x".to_string(), Type::Int);
        type_env.insert("y".to_string(), Type::Int);
        
        let result = deep_embed_types(&expr, &type_env);
        
        match result {
            Expr::LetIn { type_ann: outer_ann, body, .. } => {
                assert_eq!(outer_ann, Some(Type::Int));
                match body.as_ref() {
                    Expr::Let { type_ann: inner_ann, .. } => {
                        assert_eq!(inner_ann, &Some(Type::Int));
                    }
                    _ => panic!("Expected inner Let expression"),
                }
            }
            _ => panic!("Expected LetIn expression"),
        }
    }
}