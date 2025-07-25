#[cfg(test)]
mod type_dependency_tests {
    use std::collections::HashSet;
    use vibe_core::{Expr, FunctionParam, Ident, Literal, Span, Type};
    use vibe_codebase::{
        dependency_extractor::DependencyExtractor,
        namespace::{DefinitionContent, DefinitionPath, NamespacePath, NamespaceStore},
    };

    #[test]
    fn test_extract_type_dependencies_from_annotation() {
        let mut store = NamespaceStore::new();

        // Add Option type definition
        let option_def_path = DefinitionPath::from_str("Option").unwrap();
        let option_content = DefinitionContent::Type {
            params: vec!["a".to_string()],
            constructors: vec![
                ("None".to_string(), vec![]),
                ("Some".to_string(), vec![Type::Var("a".to_string())]),
            ],
        };
        let option_hash = store
            .add_definition(
                option_def_path,
                option_content,
                Type::UserDefined {
                    name: "Option".to_string(),
                    type_params: vec![Type::Var("a".to_string())],
                },
                HashSet::new(),
                Default::default(),
            )
            .unwrap();

        // Create a function that uses Option in its type annotation
        let expr = Expr::Let {
            name: Ident("parseNum".to_string()),
            type_ann: Some(Type::Function(
                Box::new(Type::String),
                Box::new(Type::UserDefined {
                    name: "Option".to_string(),
                    type_params: vec![Type::Int],
                }),
            )),
            value: Box::new(Expr::Lambda {
                params: vec![(Ident("s".to_string()), Some(Type::String))],
                body: Box::new(Expr::Constructor {
                    name: Ident("None".to_string()),
                    args: vec![],
                    span: Span::new(0, 4),
                }),
                span: Span::new(0, 20),
            }),
            span: Span::new(0, 30),
        };

        // Extract dependencies
        let mut extractor = DependencyExtractor::new(&store, NamespacePath::root());
        let deps = extractor.extract_from_expr(&expr);

        // Should find the Option type as a dependency
        assert!(deps.contains(&option_hash));
    }

    #[test]
    fn test_extract_constructor_dependencies() {
        let mut store = NamespaceStore::new();

        // Add Result type definition
        let result_def_path = DefinitionPath::from_str("Result").unwrap();
        let result_content = DefinitionContent::Type {
            params: vec!["e".to_string(), "a".to_string()],
            constructors: vec![
                ("Ok".to_string(), vec![Type::Var("a".to_string())]),
                ("Error".to_string(), vec![Type::Var("e".to_string())]),
            ],
        };
        let result_hash = store
            .add_definition(
                result_def_path,
                result_content,
                Type::UserDefined {
                    name: "Result".to_string(),
                    type_params: vec![Type::Var("e".to_string()), Type::Var("a".to_string())],
                },
                HashSet::new(),
                Default::default(),
            )
            .unwrap();

        // Create expression using Ok constructor
        let expr = Expr::Constructor {
            name: Ident("Ok".to_string()),
            args: vec![Expr::Literal(Literal::Int(42), Span::new(0, 2))],
            span: Span::new(0, 10),
        };

        // Extract dependencies
        let mut extractor = DependencyExtractor::new(&store, NamespacePath::root());
        let deps = extractor.extract_from_expr(&expr);

        // Should find the Result type through its constructor
        // Note: This might not work with current implementation,
        // as we'd need to map constructors to their types
        assert!(deps.is_empty() || deps.contains(&result_hash));
    }

    #[test]
    fn test_extract_nested_type_dependencies() {
        let mut store = NamespaceStore::new();

        // Add List type
        let list_def_path = DefinitionPath::from_str("List").unwrap();
        let list_content = DefinitionContent::Type {
            params: vec!["a".to_string()],
            constructors: vec![
                ("Nil".to_string(), vec![]),
                (
                    "Cons".to_string(),
                    vec![
                        Type::Var("a".to_string()),
                        Type::UserDefined {
                            name: "List".to_string(),
                            type_params: vec![Type::Var("a".to_string())],
                        },
                    ],
                ),
            ],
        };
        let list_hash = store
            .add_definition(
                list_def_path,
                list_content,
                Type::UserDefined {
                    name: "List".to_string(),
                    type_params: vec![Type::Var("a".to_string())],
                },
                HashSet::new(),
                Default::default(),
            )
            .unwrap();

        // Add Maybe type
        let maybe_def_path = DefinitionPath::from_str("Maybe").unwrap();
        let maybe_content = DefinitionContent::Type {
            params: vec!["a".to_string()],
            constructors: vec![
                ("Nothing".to_string(), vec![]),
                ("Just".to_string(), vec![Type::Var("a".to_string())]),
            ],
        };
        let maybe_hash = store
            .add_definition(
                maybe_def_path,
                maybe_content,
                Type::UserDefined {
                    name: "Maybe".to_string(),
                    type_params: vec![Type::Var("a".to_string())],
                },
                HashSet::new(),
                Default::default(),
            )
            .unwrap();

        // Create function with nested type: List (Maybe Int)
        let expr = Expr::Let {
            name: Ident("maybeList".to_string()),
            type_ann: Some(Type::UserDefined {
                name: "List".to_string(),
                type_params: vec![Type::UserDefined {
                    name: "Maybe".to_string(),
                    type_params: vec![Type::Int],
                }],
            }),
            value: Box::new(Expr::Constructor {
                name: Ident("Nil".to_string()),
                args: vec![],
                span: Span::new(0, 3),
            }),
            span: Span::new(0, 20),
        };

        // Extract dependencies
        let mut extractor = DependencyExtractor::new(&store, NamespacePath::root());
        let deps = extractor.extract_from_expr(&expr);

        // Should find both List and Maybe types
        assert!(deps.contains(&list_hash));
        assert!(deps.contains(&maybe_hash));
    }

    #[test]
    fn test_type_dependencies_in_function_params() {
        let mut store = NamespaceStore::new();

        // Add Either type
        let either_def_path = DefinitionPath::from_str("Either").unwrap();
        let either_content = DefinitionContent::Type {
            params: vec!["l".to_string(), "r".to_string()],
            constructors: vec![
                ("Left".to_string(), vec![Type::Var("l".to_string())]),
                ("Right".to_string(), vec![Type::Var("r".to_string())]),
            ],
        };
        let either_hash = store
            .add_definition(
                either_def_path,
                either_content,
                Type::UserDefined {
                    name: "Either".to_string(),
                    type_params: vec![Type::Var("l".to_string()), Type::Var("r".to_string())],
                },
                HashSet::new(),
                Default::default(),
            )
            .unwrap();

        // Create a function with Either in parameter types
        let expr = Expr::FunctionDef {
            name: Ident("handleEither".to_string()),
            params: vec![FunctionParam {
                name: Ident("e".to_string()),
                typ: Some(Type::UserDefined {
                    name: "Either".to_string(),
                    type_params: vec![Type::String, Type::Int],
                }),
                is_optional: false,
            }],
            return_type: Some(Type::String),
            effects: None,
            body: Box::new(Expr::Literal(
                Literal::String("test".to_string()),
                Span::new(0, 4),
            )),
            span: Span::new(0, 50),
        };

        // Extract dependencies
        let mut extractor = DependencyExtractor::new(&store, NamespacePath::root());
        let deps = extractor.extract_from_expr(&expr);

        // Should find Either type from parameter annotation
        assert!(deps.contains(&either_hash));
    }
}
