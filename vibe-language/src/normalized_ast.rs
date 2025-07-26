//! Normalized AST for Vibe Language
//! 
//! This module defines a normalized AST that serves as the canonical representation
//! for all surface syntax variations. Different syntactic forms (do notation, shell syntax,
//! block syntax) are desugared into this unified representation.
//!
//! The normalized AST is designed for:
//! - Content addressing (deterministic hashing)
//! - Type inference and checking
//! - Effect system analysis
//! - Compilation to lower-level IR

use crate::{Literal, Type, Pattern};
use crate::effects::Effect;
use serde::{Serialize, Deserialize};
use std::collections::BTreeSet;

/// Normalized expression - the canonical form of all expressions
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum NormalizedExpr {
    /// Literal values
    Literal(Literal),
    
    /// Variable reference
    Var(String),
    
    /// Function application (always curried)
    Apply {
        func: Box<NormalizedExpr>,
        arg: Box<NormalizedExpr>,
    },
    
    /// Lambda abstraction (single parameter, curried)
    Lambda {
        param: String,
        body: Box<NormalizedExpr>,
    },
    
    /// Let binding (non-recursive)
    Let {
        name: String,
        value: Box<NormalizedExpr>,
        body: Box<NormalizedExpr>,
    },
    
    /// Recursive let binding
    LetRec {
        name: String,
        value: Box<NormalizedExpr>,
        body: Box<NormalizedExpr>,
    },
    
    /// Pattern matching
    Match {
        expr: Box<NormalizedExpr>,
        cases: Vec<(NormalizedPattern, NormalizedExpr)>,
    },
    
    /// List construction
    List(Vec<NormalizedExpr>),
    
    /// Record/Object construction
    Record(BTreeMap<String, NormalizedExpr>),
    
    /// Field access
    Field {
        expr: Box<NormalizedExpr>,
        field: String,
    },
    
    /// Type constructor application
    Constructor {
        name: String,
        args: Vec<NormalizedExpr>,
    },
    
    /// Effect operation
    Perform {
        effect: String,
        operation: String,
        args: Vec<NormalizedExpr>,
    },
    
    /// Effect handler
    Handle {
        expr: Box<NormalizedExpr>,
        handlers: Vec<NormalizedHandler>,
    },
}

use std::collections::BTreeMap;

/// Normalized pattern for pattern matching
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum NormalizedPattern {
    /// Wildcard pattern
    Wildcard,
    
    /// Variable binding
    Variable(String),
    
    /// Literal pattern
    Literal(Literal),
    
    /// Constructor pattern
    Constructor {
        name: String,
        patterns: Vec<NormalizedPattern>,
    },
    
    /// List pattern
    List(Vec<NormalizedPattern>),
    
    /// Cons pattern (head :: tail)
    Cons {
        head: Box<NormalizedPattern>,
        tail: Box<NormalizedPattern>,
    },
}

/// Effect handler case
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct NormalizedHandler {
    /// Effect name
    pub effect: String,
    
    /// Operation name
    pub operation: String,
    
    /// Parameter patterns
    pub params: Vec<String>,
    
    /// Resume continuation parameter
    pub resume: String,
    
    /// Handler body
    pub body: NormalizedExpr,
}

/// Top-level definition in normalized form
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NormalizedDef {
    /// Definition name
    pub name: String,
    
    /// Type annotation (if provided or inferred)
    pub ty: Option<Type>,
    
    /// Effect annotations
    pub effects: BTreeSet<Effect>,
    
    /// Definition body
    pub body: NormalizedExpr,
    
    /// Whether this is recursive
    pub is_recursive: bool,
}

/// Desugaring context for transforming surface syntax to normalized form
pub struct DesugarContext {
    /// Counter for generating unique names
    fresh_counter: usize,
}

impl DesugarContext {
    pub fn new() -> Self {
        Self { fresh_counter: 0 }
    }
    
    /// Generate a fresh variable name
    pub fn fresh_var(&mut self, prefix: &str) -> String {
        let var = format!("{}${}", prefix, self.fresh_counter);
        self.fresh_counter += 1;
        var
    }
}

/// Desugaring functions for various syntactic forms
impl NormalizedExpr {
    /// Desugar binary operators to function applications
    pub fn desugar_binop(op: &str, left: NormalizedExpr, right: NormalizedExpr) -> Self {
        // Convert binary operator to curried function application
        // e.g., x + y => ((+) x) y
        NormalizedExpr::Apply {
            func: Box::new(NormalizedExpr::Apply {
                func: Box::new(NormalizedExpr::Var(op.to_string())),
                arg: Box::new(left),
            }),
            arg: Box::new(right),
        }
    }
    
    /// Desugar if-then-else to pattern matching
    pub fn desugar_if(cond: NormalizedExpr, then_expr: NormalizedExpr, else_expr: NormalizedExpr) -> Self {
        NormalizedExpr::Match {
            expr: Box::new(cond),
            cases: vec![
                (NormalizedPattern::Literal(Literal::Bool(true)), then_expr),
                (NormalizedPattern::Literal(Literal::Bool(false)), else_expr),
            ],
        }
    }
    
    /// Desugar multi-parameter lambda to nested single-parameter lambdas
    pub fn desugar_multi_lambda(params: Vec<String>, body: NormalizedExpr) -> Self {
        params.into_iter()
            .rev()
            .fold(body, |acc, param| {
                NormalizedExpr::Lambda {
                    param,
                    body: Box::new(acc),
                }
            })
    }
    
    /// Desugar multi-argument application to nested applications
    pub fn desugar_multi_apply(func: NormalizedExpr, args: Vec<NormalizedExpr>) -> Self {
        args.into_iter()
            .fold(func, |acc, arg| {
                NormalizedExpr::Apply {
                    func: Box::new(acc),
                    arg: Box::new(arg),
                }
            })
    }
    
    /// Desugar do notation to nested binds
    pub fn desugar_do_block(stmts: Vec<DoStatement>, ctx: &mut DesugarContext) -> Self {
        match stmts.as_slice() {
            [] => panic!("Empty do block"),
            [DoStatement::Expr(e)] => e.clone(),
            [DoStatement::Bind(pat, expr), rest @ ..] => {
                let var = ctx.fresh_var("do_bind");
                NormalizedExpr::Let {
                    name: var.clone(),
                    value: Box::new(expr.clone()),
                    body: Box::new(match pat {
                        NormalizedPattern::Variable(name) => {
                            NormalizedExpr::Let {
                                name: name.clone(),
                                value: Box::new(NormalizedExpr::Var(var)),
                                body: Box::new(Self::desugar_do_block(rest.to_vec(), ctx)),
                            }
                        }
                        _ => {
                            NormalizedExpr::Match {
                                expr: Box::new(NormalizedExpr::Var(var)),
                                cases: vec![(pat.clone(), Self::desugar_do_block(rest.to_vec(), ctx))],
                            }
                        }
                    }),
                }
            }
            [DoStatement::Let(name, expr), rest @ ..] => {
                NormalizedExpr::Let {
                    name: name.clone(),
                    value: Box::new(expr.clone()),
                    body: Box::new(Self::desugar_do_block(rest.to_vec(), ctx)),
                }
            }
            _ => panic!("Invalid do block structure"),
        }
    }
    
    /// Desugar sequence/block expressions
    pub fn desugar_sequence(exprs: Vec<NormalizedExpr>, ctx: &mut DesugarContext) -> Self {
        match exprs.as_slice() {
            [] => panic!("Empty sequence"),
            [e] => e.clone(),
            [e, rest @ ..] => {
                let var = ctx.fresh_var("seq");
                NormalizedExpr::Let {
                    name: var,
                    value: Box::new(e.clone()),
                    body: Box::new(Self::desugar_sequence(rest.to_vec(), ctx)),
                }
            }
        }
    }
}

/// Do notation statement
#[derive(Debug, Clone, PartialEq)]
pub enum DoStatement {
    /// Pattern <- expression
    Bind(NormalizedPattern, NormalizedExpr),
    
    /// let name = expression
    Let(String, NormalizedExpr),
    
    /// expression
    Expr(NormalizedExpr),
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_desugar_binop() {
        let left = NormalizedExpr::Literal(Literal::Int(1));
        let right = NormalizedExpr::Literal(Literal::Int(2));
        
        let result = NormalizedExpr::desugar_binop("+", left, right);
        
        match result {
            NormalizedExpr::Apply { func, arg } => {
                match &**func {
                    NormalizedExpr::Apply { func: inner_func, arg: inner_arg } => {
                        assert_eq!(&**inner_func, &NormalizedExpr::Var("+".to_string()));
                        assert_eq!(&**inner_arg, &NormalizedExpr::Literal(Literal::Int(1)));
                    }
                    _ => panic!("Expected nested Apply"),
                }
                assert_eq!(&**arg, &NormalizedExpr::Literal(Literal::Int(2)));
            }
            _ => panic!("Expected Apply"),
        }
    }
    
    #[test]
    fn test_desugar_if() {
        let cond = NormalizedExpr::Var("x".to_string());
        let then_expr = NormalizedExpr::Literal(Literal::Int(1));
        let else_expr = NormalizedExpr::Literal(Literal::Int(2));
        
        let result = NormalizedExpr::desugar_if(cond.clone(), then_expr.clone(), else_expr.clone());
        
        match result {
            NormalizedExpr::Match { expr, cases } => {
                assert_eq!(&**expr, &cond);
                assert_eq!(cases.len(), 2);
                assert_eq!(cases[0].0, NormalizedPattern::Literal(Literal::Bool(true)));
                assert_eq!(cases[0].1, then_expr);
                assert_eq!(cases[1].0, NormalizedPattern::Literal(Literal::Bool(false)));
                assert_eq!(cases[1].1, else_expr);
            }
            _ => panic!("Expected Match"),
        }
    }
    
    #[test]
    fn test_desugar_multi_lambda() {
        let params = vec!["x".to_string(), "y".to_string(), "z".to_string()];
        let body = NormalizedExpr::Var("body".to_string());
        
        let result = NormalizedExpr::desugar_multi_lambda(params, body.clone());
        
        // Should produce: \x -> \y -> \z -> body
        match result {
            NormalizedExpr::Lambda { param, body: inner } => {
                assert_eq!(param, "x");
                match &**inner {
                    NormalizedExpr::Lambda { param, body: inner2 } => {
                        assert_eq!(param, "y");
                        match &**inner2 {
                            NormalizedExpr::Lambda { param, body: inner3 } => {
                                assert_eq!(param, "z");
                                assert_eq!(&**inner3, &body);
                            }
                            _ => panic!("Expected third Lambda"),
                        }
                    }
                    _ => panic!("Expected second Lambda"),
                }
            }
            _ => panic!("Expected Lambda"),
        }
    }
}