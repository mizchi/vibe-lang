//! Intermediate Representation for XS language with Perceus memory management

use crate::Literal;

/// IR expressions with explicit memory management instructions
#[derive(Debug, Clone, PartialEq)]
pub enum IrExpr {
    /// Literal values
    Literal(Literal),
    
    /// Variable reference
    Var(String),
    
    /// Let binding
    Let {
        name: String,
        value: Box<IrExpr>,
        body: Box<IrExpr>,
    },
    
    /// Let-rec binding for recursive functions
    LetRec {
        name: String,
        value: Box<IrExpr>,
        body: Box<IrExpr>,
    },
    
    /// Lambda abstraction
    Lambda {
        params: Vec<String>,
        body: Box<IrExpr>,
    },
    
    /// Function application
    Apply {
        func: Box<IrExpr>,
        args: Vec<IrExpr>,
    },
    
    /// Conditional expression
    If {
        cond: Box<IrExpr>,
        then_expr: Box<IrExpr>,
        else_expr: Box<IrExpr>,
    },
    
    /// List construction
    List(Vec<IrExpr>),
    
    /// Cons operation
    Cons {
        head: Box<IrExpr>,
        tail: Box<IrExpr>,
    },
    
    /// Sequence of expressions
    Sequence(Vec<IrExpr>),
    
    // Memory management instructions
    
    /// Drop a reference (decrement reference count)
    Drop(String),
    
    /// Duplicate a reference (increment reference count)
    Dup(String),
    
    /// Check if a value can be reused (ref count == 1)
    ReuseCheck {
        var: String,
        reuse_expr: Box<IrExpr>,
        fallback_expr: Box<IrExpr>,
    },
}

/// Ownership information for variables
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ownership {
    /// Owned value (reference count = 1)
    Owned,
    /// Borrowed reference (doesn't affect reference count)
    Borrowed,
    /// Shared value (reference count > 1)
    Shared,
}

/// Variable usage information for Perceus analysis
#[derive(Debug, Clone)]
pub struct UsageInfo {
    pub name: String,
    pub use_count: usize,
    pub ownership: Ownership,
}

impl IrExpr {
    /// Count the number of uses of a variable in an expression
    pub fn count_uses(&self, var: &str) -> usize {
        match self {
            IrExpr::Var(name) => {
                if name == var { 1 } else { 0 }
            }
            IrExpr::Let { value, body, .. } => {
                value.count_uses(var) + body.count_uses(var)
            }
            IrExpr::LetRec { value, body, .. } => {
                value.count_uses(var) + body.count_uses(var)
            }
            IrExpr::Lambda { body, params, .. } => {
                if params.contains(&var.to_string()) {
                    0 // Variable is shadowed
                } else {
                    body.count_uses(var)
                }
            }
            IrExpr::Apply { func, args } => {
                func.count_uses(var) + args.iter().map(|a| a.count_uses(var)).sum::<usize>()
            }
            IrExpr::If { cond, then_expr, else_expr } => {
                cond.count_uses(var) + then_expr.count_uses(var) + else_expr.count_uses(var)
            }
            IrExpr::List(exprs) => {
                exprs.iter().map(|e| e.count_uses(var)).sum()
            }
            IrExpr::Cons { head, tail } => {
                head.count_uses(var) + tail.count_uses(var)
            }
            IrExpr::Sequence(exprs) => {
                exprs.iter().map(|e| e.count_uses(var)).sum()
            }
            IrExpr::Drop(name) | IrExpr::Dup(name) => {
                if name == var { 1 } else { 0 }
            }
            IrExpr::ReuseCheck { var: v, reuse_expr, fallback_expr } => {
                let base = if v == var { 1 } else { 0 };
                base + reuse_expr.count_uses(var) + fallback_expr.count_uses(var)
            }
            IrExpr::Literal(_) => 0,
        }
    }
    
    /// Get all free variables in the expression
    pub fn free_vars(&self) -> Vec<String> {
        match self {
            IrExpr::Var(name) => vec![name.clone()],
            IrExpr::Let { name, value, body } => {
                let mut vars = value.free_vars();
                let body_vars = body.free_vars();
                for v in body_vars {
                    if v != *name {
                        vars.push(v);
                    }
                }
                vars
            }
            IrExpr::LetRec { name, value, body } => {
                let mut vars = vec![];
                for v in value.free_vars() {
                    if v != *name {
                        vars.push(v);
                    }
                }
                for v in body.free_vars() {
                    if v != *name {
                        vars.push(v);
                    }
                }
                vars
            }
            IrExpr::Lambda { params, body } => {
                let mut vars = vec![];
                for v in body.free_vars() {
                    if !params.contains(&v) {
                        vars.push(v);
                    }
                }
                vars
            }
            IrExpr::Apply { func, args } => {
                let mut vars = func.free_vars();
                for arg in args {
                    vars.extend(arg.free_vars());
                }
                vars
            }
            IrExpr::If { cond, then_expr, else_expr } => {
                let mut vars = cond.free_vars();
                vars.extend(then_expr.free_vars());
                vars.extend(else_expr.free_vars());
                vars
            }
            IrExpr::List(exprs) => {
                let mut vars = vec![];
                for expr in exprs {
                    vars.extend(expr.free_vars());
                }
                vars
            }
            IrExpr::Cons { head, tail } => {
                let mut vars = head.free_vars();
                vars.extend(tail.free_vars());
                vars
            }
            IrExpr::Sequence(exprs) => {
                let mut vars = vec![];
                for expr in exprs {
                    vars.extend(expr.free_vars());
                }
                vars
            }
            IrExpr::Drop(name) | IrExpr::Dup(name) => vec![name.clone()],
            IrExpr::ReuseCheck { var, reuse_expr, fallback_expr } => {
                let mut vars = vec![var.clone()];
                vars.extend(reuse_expr.free_vars());
                vars.extend(fallback_expr.free_vars());
                vars
            }
            IrExpr::Literal(_) => vec![],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_count_uses() {
        let expr = IrExpr::Let {
            name: "x".to_string(),
            value: Box::new(IrExpr::Literal(Literal::Int(42))),
            body: Box::new(IrExpr::Apply {
                func: Box::new(IrExpr::Var("f".to_string())),
                args: vec![
                    IrExpr::Var("x".to_string()),
                    IrExpr::Var("x".to_string()),
                ],
            }),
        };
        
        assert_eq!(expr.count_uses("x"), 2);
        assert_eq!(expr.count_uses("f"), 1);
        assert_eq!(expr.count_uses("y"), 0);
    }
    
    #[test]
    fn test_free_vars() {
        let expr = IrExpr::Lambda {
            params: vec!["x".to_string()],
            body: Box::new(IrExpr::Apply {
                func: Box::new(IrExpr::Var("f".to_string())),
                args: vec![IrExpr::Var("x".to_string())],
            }),
        };
        
        let free = expr.free_vars();
        assert_eq!(free, vec!["f"]);
    }
}