//! AST normalization - converts surface syntax to normalized form

use crate::{Expr, Pattern, Literal, Ident, DoStatement as SurfaceDoStatement};
use crate::normalized_ast::{
    NormalizedExpr, NormalizedPattern, NormalizedDef, NormalizedHandler,
    DesugarContext, DoStatement
};
use std::collections::BTreeMap;

/// Convert surface AST to normalized AST
pub struct AstNormalizer {
    ctx: DesugarContext,
}

impl AstNormalizer {
    pub fn new() -> Self {
        Self {
            ctx: DesugarContext::new(),
        }
    }
    
    /// Normalize a top-level expression
    pub fn normalize_expr(&mut self, expr: &Expr) -> NormalizedExpr {
        match expr {
            Expr::Literal(lit, _) => NormalizedExpr::Literal(lit.clone()),
            
            Expr::Ident(ident, _) => NormalizedExpr::Var(ident.0.clone()),
            
            Expr::List(elements, _) => {
                NormalizedExpr::List(
                    elements.iter().map(|e| self.normalize_expr(e)).collect()
                )
            }
            
            Expr::Let { name, value, .. } => {
                // Top-level let becomes a definition, not an expression
                // This should be handled at a higher level
                panic!("Top-level let should be handled as a definition")
            }
            
            Expr::LetIn { name, value, body, .. } => {
                NormalizedExpr::Let {
                    name: name.0.clone(),
                    value: Box::new(self.normalize_expr(value)),
                    body: Box::new(self.normalize_expr(body)),
                }
            }
            
            Expr::LetRec { name, value, .. } => {
                // Top-level let-rec becomes a definition
                panic!("Top-level let-rec should be handled as a definition")
            }
            
            Expr::LetRecIn { name, value, body, .. } => {
                NormalizedExpr::LetRec {
                    name: name.0.clone(),
                    value: Box::new(self.normalize_expr(value)),
                    body: Box::new(self.normalize_expr(body)),
                }
            }
            
            Expr::Lambda { params, body, .. } => {
                // Convert multi-parameter lambda to nested single-parameter lambdas
                let param_names: Vec<String> = params.iter()
                    .map(|(ident, _)| ident.0.clone())
                    .collect();
                    
                let normalized_body = self.normalize_expr(body);
                NormalizedExpr::desugar_multi_lambda(param_names, normalized_body)
            }
            
            Expr::FunctionDef { params, body, .. } => {
                // Function definition is similar to lambda
                let param_names: Vec<String> = params.iter()
                    .map(|p| p.name.0.clone())
                    .collect();
                    
                let normalized_body = self.normalize_expr(body);
                NormalizedExpr::desugar_multi_lambda(param_names, normalized_body)
            }
            
            Expr::Rec { name, params, body, .. } => {
                // Recursive function becomes let-rec with lambda
                let param_names: Vec<String> = params.iter()
                    .map(|(ident, _)| ident.0.clone())
                    .collect();
                    
                let normalized_body = self.normalize_expr(body);
                let lambda_body = NormalizedExpr::desugar_multi_lambda(param_names, normalized_body);
                
                // For top-level rec, we need to return just the lambda
                // The recursion will be handled by NormalizedDef
                lambda_body
            }
            
            Expr::Apply { func, args, .. } => {
                let normalized_func = self.normalize_expr(func);
                let normalized_args: Vec<NormalizedExpr> = args.iter()
                    .map(|arg| self.normalize_expr(arg))
                    .collect();
                    
                NormalizedExpr::desugar_multi_apply(normalized_func, normalized_args)
            }
            
            Expr::If { cond, then_expr, else_expr, .. } => {
                let normalized_cond = self.normalize_expr(cond);
                let normalized_then = self.normalize_expr(then_expr);
                let normalized_else = self.normalize_expr(else_expr);
                
                NormalizedExpr::desugar_if(normalized_cond, normalized_then, normalized_else)
            }
            
            Expr::Match { expr, cases, .. } => {
                let normalized_expr = self.normalize_expr(expr);
                let normalized_cases: Vec<(NormalizedPattern, NormalizedExpr)> = cases.iter()
                    .map(|(pat, expr)| {
                        (self.normalize_pattern(pat), self.normalize_expr(expr))
                    })
                    .collect();
                    
                NormalizedExpr::Match {
                    expr: Box::new(normalized_expr),
                    cases: normalized_cases,
                }
            }
            
            Expr::Constructor { name, args, .. } => {
                NormalizedExpr::Constructor {
                    name: name.0.clone(),
                    args: args.iter().map(|arg| self.normalize_expr(arg)).collect(),
                }
            }
            
            Expr::Pipeline { expr, func, .. } => {
                // Pipeline x |> f becomes f x
                let normalized_expr = self.normalize_expr(expr);
                let normalized_func = self.normalize_expr(func);
                
                NormalizedExpr::Apply {
                    func: Box::new(normalized_func),
                    arg: Box::new(normalized_expr),
                }
            }
            
            Expr::Block { exprs, .. } => {
                let normalized_exprs: Vec<NormalizedExpr> = exprs.iter()
                    .map(|e| self.normalize_expr(e))
                    .collect();
                    
                NormalizedExpr::desugar_sequence(normalized_exprs, &mut self.ctx)
            }
            
            Expr::Do { statements, .. } => {
                let normalized_stmts = self.normalize_do_statements(statements);
                NormalizedExpr::desugar_do_block(normalized_stmts, &mut self.ctx)
            }
            
            Expr::Perform { effect, args, .. } => {
                NormalizedExpr::Perform {
                    effect: effect.0.clone(),
                    operation: "perform".to_string(), // Default operation
                    args: args.iter().map(|arg| self.normalize_expr(arg)).collect(),
                }
            }
            
            Expr::HandleExpr { expr, handlers, return_handler, .. } => {
                let normalized_expr = self.normalize_expr(expr);
                let normalized_handlers = self.normalize_handlers(handlers);
                
                // If there's a return handler, add it as a special handler
                let mut all_handlers = normalized_handlers;
                if let Some((var, body)) = return_handler {
                    all_handlers.push(NormalizedHandler {
                        effect: "return".to_string(),
                        operation: "return".to_string(),
                        params: vec![var.0.clone()],
                        resume: "_".to_string(), // No resume for return
                        body: self.normalize_expr(body),
                    });
                }
                
                NormalizedExpr::Handle {
                    expr: Box::new(normalized_expr),
                    handlers: all_handlers,
                }
            }
            
            Expr::RecordLiteral { fields, .. } => {
                let mut normalized_fields = BTreeMap::new();
                for (name, expr) in fields {
                    normalized_fields.insert(name.0.clone(), self.normalize_expr(expr));
                }
                NormalizedExpr::Record(normalized_fields)
            }
            
            Expr::RecordAccess { record, field, .. } => {
                NormalizedExpr::Field {
                    expr: Box::new(self.normalize_expr(record)),
                    field: field.0.clone(),
                }
            }
            
            // Binary operators - these should be desugared during parsing
            // but we handle them here for completeness
            expr => {
                // Check if this is a binary operator application
                if let Expr::Apply { func, args, .. } = expr {
                    if args.len() == 2 {
                        if let Expr::Ident(op, _) = &**func {
                            if is_binary_operator(&op.0) {
                                let left = self.normalize_expr(&args[0]);
                                let right = self.normalize_expr(&args[1]);
                                return NormalizedExpr::desugar_binop(&op.0, left, right);
                            }
                        }
                    }
                }
                
                // For other cases not yet handled
                panic!("Unhandled expression type in normalization: {:?}", expr)
            }
        }
    }
    
    /// Normalize a pattern
    pub fn normalize_pattern(&mut self, pattern: &Pattern) -> NormalizedPattern {
        match pattern {
            Pattern::Wildcard(_) => NormalizedPattern::Wildcard,
            
            Pattern::Literal(lit, _) => NormalizedPattern::Literal(lit.clone()),
            
            Pattern::Variable(ident, _) => NormalizedPattern::Variable(ident.0.clone()),
            
            Pattern::Constructor { name, patterns, .. } => {
                NormalizedPattern::Constructor {
                    name: name.0.clone(),
                    patterns: patterns.iter()
                        .map(|p| self.normalize_pattern(p))
                        .collect(),
                }
            }
            
            Pattern::List { patterns, .. } => {
                // Check if this is a cons pattern (h :: t)
                if patterns.len() == 2 {
                    // This is a simple heuristic - in practice we'd need
                    // to check if there's a :: operator
                    NormalizedPattern::List(
                        patterns.iter()
                            .map(|p| self.normalize_pattern(p))
                            .collect()
                    )
                } else {
                    NormalizedPattern::List(
                        patterns.iter()
                            .map(|p| self.normalize_pattern(p))
                            .collect()
                    )
                }
            }
        }
    }
    
    /// Normalize do statements
    fn normalize_do_statements(&mut self, statements: &[SurfaceDoStatement]) -> Vec<DoStatement> {
        statements.iter().map(|stmt| {
            match stmt {
                SurfaceDoStatement::Bind { name, expr, .. } => {
                    DoStatement::Bind(
                        NormalizedPattern::Variable(name.0.clone()),
                        self.normalize_expr(expr)
                    )
                }
                SurfaceDoStatement::Expression(expr) => {
                    DoStatement::Expr(self.normalize_expr(expr))
                }
            }
        }).collect()
    }
    
    /// Normalize effect handlers
    fn normalize_handlers(&mut self, handlers: &[crate::HandlerCase]) -> Vec<NormalizedHandler> {
        handlers.iter().map(|handler| {
            let effect_name = handler.effect.0.clone();
            let operation = handler.operation.as_ref()
                .map(|op| op.0.clone())
                .unwrap_or_else(|| "perform".to_string());
            
            let params: Vec<String> = handler.args.iter()
                .filter_map(|pat| {
                    if let Pattern::Variable(ident, _) = pat {
                        Some(ident.0.clone())
                    } else {
                        None
                    }
                })
                .collect();
            
            NormalizedHandler {
                effect: effect_name,
                operation,
                params,
                resume: handler.continuation.0.clone(),
                body: self.normalize_expr(&handler.body),
            }
        }).collect()
    }
    
    /// Normalize a top-level definition
    pub fn normalize_definition(&mut self, name: &str, expr: &Expr) -> NormalizedDef {
        let (body, is_recursive) = match expr {
            Expr::Let { value, .. } => {
                (self.normalize_expr(value), false)
            }
            Expr::LetRec { value, .. } => {
                (self.normalize_expr(value), true)
            }
            Expr::Rec { .. } => {
                (self.normalize_expr(expr), true)
            }
            _ => {
                (self.normalize_expr(expr), false)
            }
        };
        
        NormalizedDef {
            name: name.to_string(),
            ty: None, // Type will be inferred later
            effects: Default::default(), // Effects will be inferred later
            body,
            is_recursive,
        }
    }
}

/// Check if a string is a binary operator
fn is_binary_operator(s: &str) -> bool {
    matches!(s, "+" | "-" | "*" | "/" | "%" | "==" | "!=" | "<" | ">" | "<=" | ">=" | 
             "&&" | "||" | "++" | "::" | "|>")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Span;
    
    #[test]
    fn test_normalize_literal() {
        let mut normalizer = AstNormalizer::new();
        let expr = Expr::Literal(Literal::Int(42), Span::new(0, 2));
        let result = normalizer.normalize_expr(&expr);
        
        assert_eq!(result, NormalizedExpr::Literal(Literal::Int(42)));
    }
    
    #[test]
    fn test_normalize_variable() {
        let mut normalizer = AstNormalizer::new();
        let expr = Expr::Ident(Ident("x".to_string()), Span::new(0, 1));
        let result = normalizer.normalize_expr(&expr);
        
        assert_eq!(result, NormalizedExpr::Var("x".to_string()));
    }
    
    #[test]
    fn test_normalize_lambda() {
        let mut normalizer = AstNormalizer::new();
        let expr = Expr::Lambda {
            params: vec![
                (Ident("x".to_string()), None),
                (Ident("y".to_string()), None),
            ],
            body: Box::new(Expr::Ident(Ident("x".to_string()), Span::new(0, 1))),
            span: Span::new(0, 10),
        };
        
        let result = normalizer.normalize_expr(&expr);
        
        // Should produce: \x -> \y -> x
        match result {
            NormalizedExpr::Lambda { param, body } => {
                assert_eq!(param, "x");
                match &*body {
                    NormalizedExpr::Lambda { param, body } => {
                        assert_eq!(param, "y");
                        assert_eq!(**body, NormalizedExpr::Var("x".to_string()));
                    }
                    _ => panic!("Expected nested lambda"),
                }
            }
            _ => panic!("Expected lambda"),
        }
    }
}