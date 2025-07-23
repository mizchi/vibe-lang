//! AST Bridge - Converts between new syntax and existing Expr representation
//! 
//! This module provides conversion utilities to bridge the new parser
//! with the existing Expr structure, allowing gradual migration.

use crate::{Expr, Span};

/// Converts new syntax features to existing Expr nodes where possible
pub fn convert_to_legacy_expr(expr: Expr) -> Expr {
    match expr {
        // Direct mappings
        Expr::Literal(lit, span) => Expr::Literal(lit, span),
        Expr::Ident(id, span) => Expr::Ident(id, span),
        Expr::List(items, span) => {
            let converted_items = items.into_iter()
                .map(convert_to_legacy_expr)
                .collect();
            Expr::List(converted_items, span)
        }
        Expr::Lambda { params, body, span } => {
            Expr::Lambda {
                params,
                body: Box::new(convert_to_legacy_expr(*body)),
                span
            }
        }
        Expr::Apply { func, args, span } => {
            Expr::Apply {
                func: Box::new(convert_to_legacy_expr(*func)),
                args: args.into_iter().map(convert_to_legacy_expr).collect(),
                span
            }
        }
        Expr::Let { name, type_ann, value, span } => {
            Expr::Let {
                name,
                type_ann,
                value: Box::new(convert_to_legacy_expr(*value)),
                span
            }
        }
        Expr::LetIn { name, type_ann, value, body, span } => {
            Expr::LetIn {
                name,
                type_ann,
                value: Box::new(convert_to_legacy_expr(*value)),
                body: Box::new(convert_to_legacy_expr(*body)),
                span
            }
        }
        Expr::If { cond, then_expr, else_expr, span } => {
            Expr::If {
                cond: Box::new(convert_to_legacy_expr(*cond)),
                then_expr: Box::new(convert_to_legacy_expr(*then_expr)),
                else_expr: Box::new(convert_to_legacy_expr(*else_expr)),
                span
            }
        }
        Expr::Match { expr, cases, span } => {
            let converted_cases = cases.into_iter()
                .map(|(pattern, body)| {
                    (pattern, convert_to_legacy_expr(body))
                })
                .collect();
            Expr::Match {
                expr: Box::new(convert_to_legacy_expr(*expr)),
                cases: converted_cases,
                span
            }
        }
        Expr::Block { exprs, span } => {
            // Convert block to nested let expressions or just return last expr
            if exprs.is_empty() {
                Expr::Literal(crate::Literal::Int(0), span)
            } else if exprs.len() == 1 {
                convert_to_legacy_expr(exprs.into_iter().next().unwrap())
            } else {
                // For now, just return the last expression
                convert_to_legacy_expr(exprs.into_iter().last().unwrap())
            }
        }
        Expr::Pipeline { expr, func, span } => {
            // Convert pipeline to function application
            Expr::Apply {
                func: Box::new(convert_to_legacy_expr(*func)),
                args: vec![convert_to_legacy_expr(*expr)],
                span
            }
        }
        // Other Expr nodes remain unchanged
        other => other,
    }
}

/// Identifies new syntax features that need special handling
pub fn has_new_syntax_features(expr: &Expr) -> bool {
    match expr {
        // Check for new syntax features
        Expr::Hole { .. } => true,
        Expr::Block { .. } => true,
        Expr::Pipeline { .. } => true,
        Expr::Do { .. } => true,
        Expr::RecordLiteral { .. } => true,
        Expr::RecordAccess { .. } => true,
        Expr::RecordUpdate { .. } => true,
        
        // Check for block expressions
        Expr::List(items, _) => {
            items.iter().any(has_new_syntax_features)
        }
        
        // Recursively check sub-expressions
        Expr::Lambda { body, .. } => has_new_syntax_features(body),
        Expr::Apply { func, args, .. } => {
            has_new_syntax_features(func) || args.iter().any(has_new_syntax_features)
        }
        Expr::Let { value, .. } => has_new_syntax_features(value),
        Expr::LetIn { value, body, .. } => {
            has_new_syntax_features(value) || has_new_syntax_features(body)
        }
        Expr::If { cond, then_expr, else_expr, .. } => {
            has_new_syntax_features(cond) ||
            has_new_syntax_features(then_expr) ||
            has_new_syntax_features(else_expr)
        }
        Expr::Match { expr, cases, .. } => {
            has_new_syntax_features(expr) ||
            cases.iter().any(|(_, b)| has_new_syntax_features(b))
        }
        Expr::WithHandler { handler, body, .. } => {
            has_new_syntax_features(handler) || has_new_syntax_features(body)
        }
        
        _ => false,
    }
}

/// Placeholder for content-addressed hash calculation
pub fn calculate_content_hash(expr: &Expr) -> String {
    // TODO: Implement proper SHA256 hashing of Expr
    format!("hash_{:?}", expr).chars().take(8).collect()
}

/// Extract type holes (@:Type) from Expr
pub fn extract_type_holes(expr: &Expr) -> Vec<(String, Span)> {
    let mut holes = Vec::new();
    
    fn walk(expr: &Expr, holes: &mut Vec<(String, Span)>) {
        match expr {
            Expr::Hole { name, span, .. } => {
                let hole_name = name.clone().unwrap_or_else(|| "@hole".to_string());
                holes.push((hole_name, span.clone()));
            }
            Expr::Lambda { body, .. } => walk(body, holes),
            Expr::Apply { func, args, .. } => {
                walk(func, holes);
                for arg in args {
                    walk(arg, holes);
                }
            }
            Expr::Let { value, .. } => walk(value, holes),
            Expr::LetIn { value, body, .. } => {
                walk(value, holes);
                walk(body, holes);
            }
            Expr::If { cond, then_expr, else_expr, .. } => {
                walk(cond, holes);
                walk(then_expr, holes);
                walk(else_expr, holes);
            }
            Expr::Match { expr, cases, .. } => {
                walk(expr, holes);
                for (_, body) in cases {
                    walk(body, holes);
                }
            }
            Expr::List(items, _) => {
                for item in items {
                    walk(item, holes);
                }
            }
            Expr::Block { exprs, .. } => {
                for expr in exprs {
                    walk(expr, holes);
                }
            }
            Expr::Pipeline { expr, func, .. } => {
                walk(expr, holes);
                walk(func, holes);
            }
            Expr::WithHandler { handler, body, .. } => {
                walk(handler, holes);
                walk(body, holes);
            }
            Expr::Do { body, .. } => walk(body, holes),
            Expr::RecordAccess { record, .. } => walk(record, holes),
            Expr::RecordUpdate { record, updates, .. } => {
                walk(record, holes);
                for (_, value) in updates {
                    walk(value, holes);
                }
            }
            Expr::RecordLiteral { fields, .. } => {
                for (_, value) in fields {
                    walk(value, holes);
                }
            }
            _ => {}
        }
    }
    
    walk(expr, &mut holes);
    holes
}