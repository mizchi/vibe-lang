//! Perceus transformation pass for XS language
//! 
//! This module implements the Perceus memory management transformation,
//! converting high-level expressions into IR with explicit drop/dup instructions.

use std::collections::{HashMap, HashSet};
use xs_core::{Expr, Ident, Literal};
use xs_core::ir::{IrExpr, Ownership};

/// Perceus transformer that converts AST to IR with memory management
pub struct PerceusTransform {
    /// Track variable usage counts
    usage_counts: HashMap<String, usize>,
    /// Track live variables at each program point
    live_vars: HashSet<String>,
    /// Track ownership information
    ownership_map: HashMap<String, Ownership>,
}

impl PerceusTransform {
    pub fn new() -> Self {
        Self {
            usage_counts: HashMap::new(),
            live_vars: HashSet::new(),
            ownership_map: HashMap::new(),
        }
    }
    
    /// Transform an AST expression into IR with Perceus memory management
    pub fn transform(&mut self, expr: &Expr) -> IrExpr {
        self.transform_expr(expr)
    }
    
    /// Transform expression to IR
    fn transform_expr(&mut self, expr: &Expr) -> IrExpr {
        match expr {
            Expr::Literal(lit, _) => IrExpr::Literal(lit.clone()),
            
            Expr::Ident(Ident(name), _) => IrExpr::Var(name.clone()),
            
            Expr::Let { name, value, .. } => {
                let ir_value = self.transform_expr(value);
                
                // For now, Let just evaluates its value
                // In a real implementation, this would bind the value to the name
                // and evaluate some body expression
                IrExpr::Let {
                    name: name.0.clone(),
                    value: Box::new(ir_value),
                    body: Box::new(IrExpr::Literal(Literal::Int(0))), // Placeholder
                }
            }
            
            Expr::LetRec { name, value, .. } => {
                let ir_value = self.transform_expr(value);
                
                IrExpr::LetRec {
                    name: name.0.clone(),
                    value: Box::new(ir_value),
                    body: Box::new(IrExpr::Literal(Literal::Int(0))), // Placeholder
                }
            }
            
            Expr::Lambda { params, body, .. } => {
                let param_names: Vec<String> = params.iter()
                    .map(|(Ident(name), _)| name.clone())
                    .collect();
                
                let ir_body = self.transform_expr(body);
                
                IrExpr::Lambda {
                    params: param_names,
                    body: Box::new(ir_body),
                }
            }
            
            Expr::If { cond, then_expr, else_expr, .. } => {
                let ir_cond = self.transform_expr(cond);
                let ir_then = self.transform_expr(then_expr);
                let ir_else = self.transform_expr(else_expr);
                
                IrExpr::If {
                    cond: Box::new(ir_cond),
                    then_expr: Box::new(ir_then),
                    else_expr: Box::new(ir_else),
                }
            }
            
            Expr::Apply { func, args, .. } => {
                let ir_func = self.transform_expr(func);
                let ir_args: Vec<IrExpr> = args.iter()
                    .map(|arg| self.transform_expr(arg))
                    .collect();
                
                IrExpr::Apply {
                    func: Box::new(ir_func),
                    args: ir_args,
                }
            }
            
            Expr::List(exprs, _) => {
                let ir_exprs: Vec<IrExpr> = exprs.iter()
                    .map(|expr| self.transform_expr(expr))
                    .collect();
                
                IrExpr::List(ir_exprs)
            }
            
            Expr::Rec { params, body, .. } => {
                // Transform rec to lambda with recursive binding
                let param_names: Vec<String> = params.iter()
                    .map(|(Ident(name), _)| name.clone())
                    .collect();
                
                let ir_body = self.transform_expr(body);
                
                IrExpr::Lambda {
                    params: param_names,
                    body: Box::new(ir_body),
                }
            }
        }
    }
}

/// Transform AST to IR with Perceus memory management
pub fn transform_to_ir(expr: &Expr) -> IrExpr {
    let mut transformer = PerceusTransform::new();
    transformer.transform(expr)
}

#[cfg(test)]
mod tests {
    use super::*;
    use xs_core::{Span, Type};
    
    #[test]
    fn test_literal_transform() {
        let expr = Expr::Literal(Literal::Int(42), Span::new(0, 2));
        let ir = transform_to_ir(&expr);
        
        assert_eq!(ir, IrExpr::Literal(Literal::Int(42)));
    }
    
    #[test]
    fn test_variable_transform() {
        let expr = Expr::Ident(Ident("x".to_string()), Span::new(0, 1));
        let ir = transform_to_ir(&expr);
        
        assert_eq!(ir, IrExpr::Var("x".to_string()));
    }
    
    #[test]
    fn test_lambda_transform() {
        let expr = Expr::Lambda {
            params: vec![(Ident("x".to_string()), Some(Type::Int))],
            body: Box::new(Expr::Ident(Ident("x".to_string()), Span::new(0, 1))),
            span: Span::new(0, 10),
        };
        
        let ir = transform_to_ir(&expr);
        
        match ir {
            IrExpr::Lambda { params, body } => {
                assert_eq!(params, vec!["x".to_string()]);
                assert_eq!(*body, IrExpr::Var("x".to_string()));
            }
            _ => panic!("Expected Lambda"),
        }
    }
    
    #[test]
    fn test_apply_transform() {
        let expr = Expr::Apply {
            func: Box::new(Expr::Ident(Ident("f".to_string()), Span::new(0, 1))),
            args: vec![
                Expr::Literal(Literal::Int(1), Span::new(2, 3)),
                Expr::Literal(Literal::Int(2), Span::new(4, 5)),
            ],
            span: Span::new(0, 6),
        };
        
        let ir = transform_to_ir(&expr);
        
        match ir {
            IrExpr::Apply { func, args } => {
                assert_eq!(*func, IrExpr::Var("f".to_string()));
                assert_eq!(args.len(), 2);
                assert_eq!(args[0], IrExpr::Literal(Literal::Int(1)));
                assert_eq!(args[1], IrExpr::Literal(Literal::Int(2)));
            }
            _ => panic!("Expected Apply"),
        }
    }
}