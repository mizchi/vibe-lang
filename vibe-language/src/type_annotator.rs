//! Type annotation embedder for XS expressions
//!
//! This module provides functionality to embed inferred types back into expressions
//! as explicit type annotations.

use crate::{Expr, Type};

/// Embed type annotations into an expression based on inferred types
pub fn embed_type_annotations(expr: &Expr, inferred_type: &Type) -> Expr {
    match expr {
        Expr::Let {
            name,
            type_ann,
            value,
            span,
        } => {
            // If no type annotation exists, add the inferred type
            let new_type_ann = if type_ann.is_none() {
                Some(inferred_type.clone())
            } else {
                type_ann.clone()
            };

            Expr::Let {
                name: name.clone(),
                type_ann: new_type_ann,
                value: value.clone(),
                span: span.clone(),
            }
        }
        Expr::LetRec {
            name,
            type_ann,
            value,
            span,
        } => {
            // For recursive functions, embed the inferred type
            let new_type_ann = if type_ann.is_none() {
                Some(inferred_type.clone())
            } else {
                type_ann.clone()
            };

            Expr::LetRec {
                name: name.clone(),
                type_ann: new_type_ann,
                value: value.clone(),
                span: span.clone(),
            }
        }
        Expr::Lambda { params, body, span } => {
            // For lambdas, we need to extract parameter types from the function type
            if let Type::Function(param_type, _) = inferred_type {
                // For now, just handle single parameter case
                if params.len() == 1 && params[0].1.is_none() {
                    let mut new_params = params.clone();
                    new_params[0].1 = Some((**param_type).clone());

                    Expr::Lambda {
                        params: new_params,
                        body: body.clone(),
                        span: span.clone(),
                    }
                } else {
                    // Multi-parameter case needs more complex handling
                    expr.clone()
                }
            } else {
                expr.clone()
            }
        }
        Expr::Rec {
            name,
            params,
            return_type,
            body,
            span,
        } => {
            // For recursive functions, extract return type from inferred function type
            let new_return_type = if return_type.is_none() {
                extract_return_type(inferred_type)
            } else {
                return_type.clone()
            };

            Expr::Rec {
                name: name.clone(),
                params: params.clone(),
                return_type: new_return_type,
                body: body.clone(),
                span: span.clone(),
            }
        }
        // For other expressions, return as-is
        _ => expr.clone(),
    }
}

/// Extract the return type from a potentially nested function type
fn extract_return_type(typ: &Type) -> Option<Type> {
    match typ {
        Type::Function(_, ret) => extract_return_type(ret).or_else(|| Some((**ret).clone())),
        Type::FunctionWithEffect { to, .. } => Some((**to).clone()),
        _ => Some(typ.clone()),
    }
}

/// Embed types deeply into an expression tree
pub fn deep_embed_types(expr: &Expr, type_env: &std::collections::HashMap<String, Type>) -> Expr {
    match expr {
        Expr::Let {
            name,
            type_ann,
            value,
            span,
        } => {
            // First, recursively embed types in the value expression
            let new_value = Box::new(deep_embed_types(value, type_env));

            // Then add type annotation if missing
            let new_type_ann = if type_ann.is_none() {
                type_env.get(&name.0).cloned()
            } else {
                type_ann.clone()
            };

            Expr::Let {
                name: name.clone(),
                type_ann: new_type_ann,
                value: new_value,
                span: span.clone(),
            }
        }
        Expr::LetIn {
            name,
            type_ann,
            value,
            body,
            span,
        } => {
            // Embed types in both value and body
            let new_value = Box::new(deep_embed_types(value, type_env));
            let new_body = Box::new(deep_embed_types(body, type_env));

            let new_type_ann = if type_ann.is_none() {
                type_env.get(&name.0).cloned()
            } else {
                type_ann.clone()
            };

            Expr::LetIn {
                name: name.clone(),
                type_ann: new_type_ann,
                value: new_value,
                body: new_body,
                span: span.clone(),
            }
        }
        Expr::Apply { func, args, span } => {
            let new_func = Box::new(deep_embed_types(func, type_env));
            let new_args = args
                .iter()
                .map(|arg| deep_embed_types(arg, type_env))
                .collect();

            Expr::Apply {
                func: new_func,
                args: new_args,
                span: span.clone(),
            }
        }
        Expr::Lambda { params, body, span } => {
            let new_body = Box::new(deep_embed_types(body, type_env));

            Expr::Lambda {
                params: params.clone(),
                body: new_body,
                span: span.clone(),
            }
        }
        Expr::If {
            cond,
            then_expr,
            else_expr,
            span,
        } => Expr::If {
            cond: Box::new(deep_embed_types(cond, type_env)),
            then_expr: Box::new(deep_embed_types(then_expr, type_env)),
            else_expr: Box::new(deep_embed_types(else_expr, type_env)),
            span: span.clone(),
        },
        Expr::Match { expr, cases, span } => {
            let new_expr = Box::new(deep_embed_types(expr, type_env));
            let new_cases = cases
                .iter()
                .map(|(pattern, body)| (pattern.clone(), deep_embed_types(body, type_env)))
                .collect();

            Expr::Match {
                expr: new_expr,
                cases: new_cases,
                span: span.clone(),
            }
        }
        Expr::List(items, span) => {
            let new_items = items
                .iter()
                .map(|item| deep_embed_types(item, type_env))
                .collect();

            Expr::List(new_items, span.clone())
        }
        // For other expressions, return as-is
        _ => expr.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Ident, Literal, Span};

    #[test]
    fn test_embed_let_type() {
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
    fn test_embed_lambda_param_type() {
        let expr = Expr::Lambda {
            params: vec![(Ident("x".to_string()), None)],
            body: Box::new(Expr::Ident(Ident("x".to_string()), Span::new(0, 1))),
            span: Span::new(0, 10),
        };

        let inferred_type = Type::Function(Box::new(Type::Int), Box::new(Type::Int));
        let result = embed_type_annotations(&expr, &inferred_type);

        match result {
            Expr::Lambda { params, .. } => {
                assert_eq!(params[0].1, Some(Type::Int));
            }
            _ => panic!("Expected Lambda expression"),
        }
    }
}
