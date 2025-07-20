//! Automatic currying support for XS language

use crate::{Expr, Ident, Span, Type};

/// Transform multi-parameter lambda into nested single-parameter lambdas
pub fn curry_lambda(params: Vec<(Ident, Option<Type>)>, body: Box<Expr>, span: Span) -> Expr {
    if params.is_empty() {
        // No parameters, just return the body
        *body
    } else if params.len() == 1 {
        // Single parameter, return as-is
        Expr::Lambda { params, body, span }
    } else {
        // Multiple parameters, curry them
        let mut result = *body;

        // Build nested lambdas from right to left
        for (param, type_ann) in params.into_iter().rev() {
            result = Expr::Lambda {
                params: vec![(param, type_ann)],
                body: Box::new(result),
                span: span.clone(),
            };
        }

        result
    }
}

/// Transform function application for curried functions
pub fn curry_apply(func: Box<Expr>, args: Vec<Expr>, span: Span) -> Expr {
    if args.is_empty() {
        // No arguments, just return the function
        *func
    } else if args.len() == 1 {
        // Single argument, normal application
        Expr::Apply { func, args, span }
    } else {
        // Multiple arguments, apply one by one
        let mut result = *func;

        for arg in args {
            result = Expr::Apply {
                func: Box::new(result),
                args: vec![arg],
                span: span.clone(),
            };
        }

        result
    }
}

/// Transform a curried type signature
pub fn curry_type(params: Vec<Type>, return_type: Type) -> Type {
    if params.is_empty() {
        return_type
    } else {
        params.into_iter().rev().fold(return_type, |acc, param| {
            Type::Function(Box::new(param), Box::new(acc))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Literal;

    #[test]
    fn test_curry_lambda_single_param() {
        let params = vec![(Ident("x".to_string()), None)];
        let body = Box::new(Expr::Ident(Ident("x".to_string()), Span::new(0, 1)));
        let span = Span::new(0, 10);

        let result = curry_lambda(params.clone(), body.clone(), span.clone());

        match result {
            Expr::Lambda { params: p, .. } => {
                assert_eq!(p.len(), 1);
                assert_eq!(p[0].0, Ident("x".to_string()));
            }
            _ => panic!("Expected Lambda"),
        }
    }

    #[test]
    fn test_curry_lambda_multiple_params() {
        let params = vec![
            (Ident("x".to_string()), None),
            (Ident("y".to_string()), None),
        ];
        let body = Box::new(Expr::Ident(Ident("x".to_string()), Span::new(0, 1)));
        let span = Span::new(0, 10);

        let result = curry_lambda(params, body, span);

        // Should be: (fn (x) (fn (y) x))
        match result {
            Expr::Lambda { params, body, .. } => {
                assert_eq!(params.len(), 1);
                assert_eq!(params[0].0, Ident("x".to_string()));

                match body.as_ref() {
                    Expr::Lambda {
                        params: inner_params,
                        ..
                    } => {
                        assert_eq!(inner_params.len(), 1);
                        assert_eq!(inner_params[0].0, Ident("y".to_string()));
                    }
                    _ => panic!("Expected nested Lambda"),
                }
            }
            _ => panic!("Expected Lambda"),
        }
    }

    #[test]
    fn test_curry_apply_single_arg() {
        let func = Box::new(Expr::Ident(Ident("f".to_string()), Span::new(0, 1)));
        let args = vec![Expr::Literal(Literal::Int(42), Span::new(2, 4))];
        let span = Span::new(0, 5);

        let result = curry_apply(func, args.clone(), span.clone());

        match result {
            Expr::Apply { args: a, .. } => {
                assert_eq!(a.len(), 1);
            }
            _ => panic!("Expected Apply"),
        }
    }

    #[test]
    fn test_curry_apply_multiple_args() {
        let func = Box::new(Expr::Ident(Ident("f".to_string()), Span::new(0, 1)));
        let args = vec![
            Expr::Literal(Literal::Int(1), Span::new(2, 3)),
            Expr::Literal(Literal::Int(2), Span::new(4, 5)),
        ];
        let span = Span::new(0, 6);

        let result = curry_apply(func, args, span);

        // Should be: ((f 1) 2)
        match result {
            Expr::Apply { func, args, .. } => {
                assert_eq!(args.len(), 1);
                match func.as_ref() {
                    Expr::Apply {
                        args: inner_args, ..
                    } => {
                        assert_eq!(inner_args.len(), 1);
                    }
                    _ => panic!("Expected nested Apply"),
                }
            }
            _ => panic!("Expected Apply"),
        }
    }

    #[test]
    fn test_curry_type() {
        let params = vec![Type::Int, Type::String];
        let return_type = Type::Bool;

        let result = curry_type(params, return_type);

        // Should be: Int -> (String -> Bool)
        match result {
            Type::Function(p1, rest) => {
                assert_eq!(*p1, Type::Int);
                match rest.as_ref() {
                    Type::Function(p2, ret) => {
                        assert_eq!(**p2, Type::String);
                        assert_eq!(**ret, Type::Bool);
                    }
                    _ => panic!("Expected nested Function type"),
                }
            }
            _ => panic!("Expected Function type"),
        }
    }
}
