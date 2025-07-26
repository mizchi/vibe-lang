//! Expression combiner - combines multiple top-level expressions that should be one
//!
//! This module handles the case where the GLL parser splits a single expression
//! into multiple TopLevelDef nodes due to the Program grammar rule.

use crate::{Expr, Ident, Span};

/// Combine multiple expressions that should be a single expression
pub struct ExpressionCombiner {
    expressions: Vec<Expr>,
}

impl ExpressionCombiner {
    pub fn new(expressions: Vec<Expr>) -> Self {
        Self { expressions }
    }
    
    /// Combine expressions that were incorrectly split
    pub fn combine(self) -> Vec<Expr> {
        if self.expressions.is_empty() {
            return vec![];
        }
        
        let mut result = Vec::new();
        let mut i = 0;
        
        while i < self.expressions.len() {
            match &self.expressions[i] {
                // Check if this is a perform that was split
                Expr::Ident(Ident(name), _) if name == "perform" => {
                    // Try to combine perform with the following expressions
                    if let Some(combined) = self.try_combine_perform(i) {
                        result.push(combined);
                        i += 3; // Skip perform + effect + args
                        continue;
                    }
                }
                
                // Check if this is an effect name after perform
                Expr::Perform { .. } => {
                    // This is already a proper perform expression
                    result.push(self.expressions[i].clone());
                    i += 1;
                    continue;
                }
                
                // Check for function applications that were split
                Expr::Ident(func_name, func_span) => {
                    // Look ahead to see if there are arguments
                    let mut args = Vec::new();
                    let mut j = i + 1;
                    let mut end_span = func_span.end;
                    
                    // Collect consecutive arguments
                    while j < self.expressions.len() {
                        match &self.expressions[j] {
                            // Stop if we hit another statement-like expression
                            Expr::Let { .. } | Expr::LetRec { .. } | 
                            Expr::Import { .. } | Expr::TypeDef { .. } |
                            Expr::Module { .. } => break,
                            
                            // Also stop if we hit a perform or handle
                            Expr::Perform { .. } | Expr::HandleExpr { .. } => break,
                            
                            // Stop if we hit another identifier that looks like a new statement
                            Expr::Ident(Ident(name), _) if self.is_statement_keyword(name) => break,
                            
                            // Otherwise, this is likely an argument
                            expr => {
                                args.push(expr.clone());
                                end_span = expr.span().end;
                                j += 1;
                            }
                        }
                    }
                    
                    if !args.is_empty() {
                        // Create function application
                        result.push(Expr::Apply {
                            func: Box::new(self.expressions[i].clone()),
                            args,
                            span: Span::new(func_span.start, end_span),
                        });
                        i = j;
                    } else {
                        // Just a standalone identifier
                        result.push(self.expressions[i].clone());
                        i += 1;
                    }
                }
                
                _ => {
                    // Keep as-is
                    result.push(self.expressions[i].clone());
                    i += 1;
                }
            }
        }
        
        result
    }
    
    /// Try to combine a perform expression that was split
    fn try_combine_perform(&self, start_idx: usize) -> Option<Expr> {
        // We expect: perform, effect_name, args...
        if start_idx + 2 > self.expressions.len() {
            return None;
        }
        
        // The next expression should be the effect name
        if let Expr::Ident(effect_name, _) = &self.expressions[start_idx + 1] {
            // The expression after that should be the arguments
            let mut args = vec![];
            
            if start_idx + 2 < self.expressions.len() {
                // Check if the next expression is a simple argument
                match &self.expressions[start_idx + 2] {
                    Expr::Literal(_, _) | Expr::List(_, _) | 
                    Expr::RecordLiteral { .. } => {
                        args.push(self.expressions[start_idx + 2].clone());
                    }
                    _ => {
                        // Complex expression, might need more logic
                        args.push(self.expressions[start_idx + 2].clone());
                    }
                }
            }
            
            let start_span = self.expressions[start_idx].span().start;
            let end_span = if !args.is_empty() {
                args.last().unwrap().span().end
            } else {
                self.expressions[start_idx + 1].span().end
            };
            
            return Some(Expr::Perform {
                effect: effect_name.clone(),
                args,
                span: Span::new(start_span, end_span),
            });
        }
        
        None
    }
    
    /// Check if a string is a statement keyword
    fn is_statement_keyword(&self, s: &str) -> bool {
        matches!(s, "let" | "rec" | "type" | "module" | "import" | 
                    "export" | "perform" | "handle" | "with")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Literal;
    
    #[test]
    fn test_combine_perform_split() {
        // Test: perform IO "Hello" split into three expressions
        let exprs = vec![
            Expr::Ident(Ident("perform".to_string()), Span::new(0, 7)),
            Expr::Ident(Ident("IO".to_string()), Span::new(8, 10)),
            Expr::Literal(Literal::String("Hello".to_string()), Span::new(11, 18)),
        ];
        
        let combiner = ExpressionCombiner::new(exprs);
        let result = combiner.combine();
        
        assert_eq!(result.len(), 1);
        match &result[0] {
            Expr::Perform { effect, args, .. } => {
                assert_eq!(effect.0, "IO");
                assert_eq!(args.len(), 1);
                match &args[0] {
                    Expr::Literal(Literal::String(s), _) => assert_eq!(s, "Hello"),
                    _ => panic!("Expected string literal"),
                }
            }
            _ => panic!("Expected Perform expression"),
        }
    }
    
    #[test]
    fn test_combine_function_application() {
        // Test: print x split into two expressions
        let exprs = vec![
            Expr::Ident(Ident("print".to_string()), Span::new(0, 5)),
            Expr::Ident(Ident("x".to_string()), Span::new(6, 7)),
        ];
        
        let combiner = ExpressionCombiner::new(exprs);
        let result = combiner.combine();
        
        assert_eq!(result.len(), 1);
        match &result[0] {
            Expr::Apply { func, args, .. } => {
                match &**func {
                    Expr::Ident(name, _) => assert_eq!(name.0, "print"),
                    _ => panic!("Expected Ident"),
                }
                assert_eq!(args.len(), 1);
                match &args[0] {
                    Expr::Ident(name, _) => assert_eq!(name.0, "x"),
                    _ => panic!("Expected Ident"),
                }
            }
            _ => panic!("Expected Apply expression"),
        }
    }
    
    #[test]
    fn test_keep_separate_statements() {
        // Test: let x = 1; print x should remain separate
        let exprs = vec![
            Expr::Let {
                name: Ident("x".to_string()),
                type_ann: None,
                value: Box::new(Expr::Literal(Literal::Int(1), Span::new(8, 9))),
                span: Span::new(0, 9),
            },
            Expr::Ident(Ident("print".to_string()), Span::new(11, 16)),
            Expr::Ident(Ident("x".to_string()), Span::new(17, 18)),
        ];
        
        let combiner = ExpressionCombiner::new(exprs);
        let result = combiner.combine();
        
        assert_eq!(result.len(), 2);
        // First should be the let binding
        match &result[0] {
            Expr::Let { name, .. } => assert_eq!(name.0, "x"),
            _ => panic!("Expected Let expression"),
        }
        // Second should be print x combined
        match &result[1] {
            Expr::Apply { func, args, .. } => {
                match &**func {
                    Expr::Ident(name, _) => assert_eq!(name.0, "print"),
                    _ => panic!("Expected Ident"),
                }
                assert_eq!(args.len(), 1);
            }
            _ => panic!("Expected Apply expression"),
        }
    }
}