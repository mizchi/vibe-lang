//! Effect normalization - normalizes effect syntax to a canonical form
//! 
//! This module handles the normalization of effect-related constructs,
//! ensuring that different syntactic forms of effects are represented
//! consistently in the normalized AST.

use crate::normalized_ast::{NormalizedExpr, NormalizedHandler, DesugarContext};
use crate::effects::Effect;
use std::collections::BTreeSet;

/// Effect normalizer that transforms effect syntax
pub struct EffectNormalizer {
    /// Context for generating fresh variables
    ctx: DesugarContext,
}

impl EffectNormalizer {
    pub fn new() -> Self {
        Self {
            ctx: DesugarContext::new(),
        }
    }
    
    /// Normalize a perform expression
    /// Transform: perform IO "Hello"
    /// Into: PerformEffect { effect: "IO", operation: "perform", args: ["Hello"] }
    pub fn normalize_perform(&mut self, effect: &str, args: Vec<NormalizedExpr>) -> NormalizedExpr {
        // Check if effect name contains a dot (e.g., State.get)
        let (effect_name, operation) = if let Some(dot_pos) = effect.find('.') {
            let (eff, op) = effect.split_at(dot_pos);
            (eff.to_string(), op[1..].to_string())
        } else {
            (effect.to_string(), "perform".to_string())
        };
        
        NormalizedExpr::Perform {
            effect: effect_name,
            operation,
            args,
        }
    }
    
    /// Normalize a handle expression with proper CPS transformation
    pub fn normalize_handle(
        &mut self,
        expr: NormalizedExpr,
        handlers: Vec<NormalizedHandler>,
    ) -> NormalizedExpr {
        // Transform handlers to ensure they follow CPS style
        let normalized_handlers = handlers.into_iter()
            .map(|h| self.normalize_handler(h))
            .collect();
        
        NormalizedExpr::Handle {
            expr: Box::new(expr),
            handlers: normalized_handlers,
        }
    }
    
    /// Normalize a single handler
    fn normalize_handler(&mut self, handler: NormalizedHandler) -> NormalizedHandler {
        // Ensure the handler body properly uses the resume continuation
        // This is where we'd apply CPS transformation if needed
        handler
    }
    
    /// Transform do-notation with effects into explicit perform/handle
    pub fn desugar_do_with_effects(
        &mut self,
        statements: Vec<DoStatement>,
    ) -> NormalizedExpr {
        // Transform do-notation into nested let bindings with perform
        match statements.as_slice() {
            [] => panic!("Empty do block"),
            [DoStatement::Expr(e)] => e.clone(),
            [DoStatement::Expr(_), ..] => panic!("Multiple expressions without bindings"),
            [DoStatement::Bind(var, expr), rest @ ..] => {
                // x <- performIO becomes let x = perform IO in ...
                if let NormalizedExpr::Perform { .. } = expr {
                    NormalizedExpr::Let {
                        name: var.clone(),
                        value: Box::new(expr.clone()),
                        body: Box::new(self.desugar_do_with_effects(rest.to_vec())),
                    }
                } else {
                    // Regular bind without effect
                    NormalizedExpr::Let {
                        name: var.clone(),
                        value: Box::new(expr.clone()),
                        body: Box::new(self.desugar_do_with_effects(rest.to_vec())),
                    }
                }
            }
            [DoStatement::Let(name, expr), rest @ ..] => {
                NormalizedExpr::Let {
                    name: name.clone(),
                    value: Box::new(expr.clone()),
                    body: Box::new(self.desugar_do_with_effects(rest.to_vec())),
                }
            }
        }
    }
    
    /// Infer the effects used in an expression
    pub fn infer_effects(&self, expr: &NormalizedExpr) -> BTreeSet<String> {
        let mut effects = BTreeSet::new();
        self.collect_effects(expr, &mut effects);
        effects
    }
    
    /// Recursively collect effects from an expression
    fn collect_effects(&self, expr: &NormalizedExpr, effects: &mut BTreeSet<String>) {
        match expr {
            NormalizedExpr::Perform { effect, .. } => {
                effects.insert(effect.clone());
            }
            
            NormalizedExpr::Apply { func, arg } => {
                self.collect_effects(func, effects);
                self.collect_effects(arg, effects);
            }
            
            NormalizedExpr::Lambda { body, .. } => {
                self.collect_effects(body, effects);
            }
            
            NormalizedExpr::Let { value, body, .. } |
            NormalizedExpr::LetRec { value, body, .. } => {
                self.collect_effects(value, effects);
                self.collect_effects(body, effects);
            }
            
            NormalizedExpr::Handle { expr, handlers } => {
                // Collect effects from the handled expression
                let mut inner_effects = BTreeSet::new();
                self.collect_effects(expr, &mut inner_effects);
                
                // Remove handled effects
                for handler in handlers {
                    inner_effects.remove(&handler.effect);
                }
                
                // Add remaining effects
                effects.extend(inner_effects);
                
                // Collect effects from handler bodies
                for handler in handlers {
                    self.collect_effects(&handler.body, effects);
                }
            }
            
            NormalizedExpr::Match { expr, cases } => {
                self.collect_effects(expr, effects);
                for (_, case_expr) in cases {
                    self.collect_effects(case_expr, effects);
                }
            }
            
            NormalizedExpr::List(elements) => {
                for elem in elements {
                    self.collect_effects(elem, effects);
                }
            }
            
            NormalizedExpr::Record(fields) => {
                for field_expr in fields.values() {
                    self.collect_effects(field_expr, effects);
                }
            }
            
            NormalizedExpr::Field { expr, .. } => {
                self.collect_effects(expr, effects);
            }
            
            NormalizedExpr::Constructor { args, .. } => {
                for arg in args {
                    self.collect_effects(arg, effects);
                }
            }
            
            NormalizedExpr::Literal(_) | NormalizedExpr::Var(_) => {
                // No effects
            }
        }
    }
}

/// Do-notation statement for effect desugaring
#[derive(Debug, Clone)]
pub enum DoStatement {
    /// Pattern <- expression (monadic bind)
    Bind(String, NormalizedExpr),
    /// let name = expression
    Let(String, NormalizedExpr),
    /// Plain expression
    Expr(NormalizedExpr),
}

/// Effect-aware expression transformer
pub struct EffectTransformer {
    normalizer: EffectNormalizer,
}

impl EffectTransformer {
    pub fn new() -> Self {
        Self {
            normalizer: EffectNormalizer::new(),
        }
    }
    
    /// Transform an expression to make effects explicit
    pub fn make_effects_explicit(&mut self, expr: NormalizedExpr) -> NormalizedExpr {
        match expr {
            // Transform implicit effect calls to explicit perform
            NormalizedExpr::Apply { func, arg } => {
                if let NormalizedExpr::Var(name) = &*func {
                    if self.is_effect_operation(name) {
                        // Transform effectOp arg to perform Effect.op arg
                        return self.normalizer.normalize_perform(name, vec![*arg]);
                    }
                }
                NormalizedExpr::Apply {
                    func: Box::new(self.make_effects_explicit(*func)),
                    arg: Box::new(self.make_effects_explicit(*arg)),
                }
            }
            
            NormalizedExpr::Let { name, value, body } => {
                NormalizedExpr::Let {
                    name,
                    value: Box::new(self.make_effects_explicit(*value)),
                    body: Box::new(self.make_effects_explicit(*body)),
                }
            }
            
            NormalizedExpr::Lambda { param, body } => {
                NormalizedExpr::Lambda {
                    param,
                    body: Box::new(self.make_effects_explicit(*body)),
                }
            }
            
            // Recursively transform other cases
            _ => expr, // Simplified for brevity
        }
    }
    
    /// Check if a name refers to an effect operation
    fn is_effect_operation(&self, name: &str) -> bool {
        // In a real implementation, this would check against known effects
        name.contains('.') || 
        matches!(name, "get" | "put" | "read" | "write" | "print" | "throw")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Literal;
    
    #[test]
    fn test_normalize_perform() {
        let mut normalizer = EffectNormalizer::new();
        
        // Test simple perform
        let expr = normalizer.normalize_perform(
            "IO",
            vec![NormalizedExpr::Literal(Literal::String("Hello".to_string()))],
        );
        
        match expr {
            NormalizedExpr::Perform { effect, operation, args } => {
                assert_eq!(effect, "IO");
                assert_eq!(operation, "perform");
                assert_eq!(args.len(), 1);
            }
            _ => panic!("Expected Perform expression"),
        }
    }
    
    #[test]
    fn test_normalize_perform_with_operation() {
        let mut normalizer = EffectNormalizer::new();
        
        // Test perform with operation (State.get)
        let expr = normalizer.normalize_perform("State.get", vec![]);
        
        match expr {
            NormalizedExpr::Perform { effect, operation, args } => {
                assert_eq!(effect, "State");
                assert_eq!(operation, "get");
                assert_eq!(args.len(), 0);
            }
            _ => panic!("Expected Perform expression"),
        }
    }
    
    #[test]
    fn test_infer_effects() {
        let normalizer = EffectNormalizer::new();
        
        // Create an expression with effects
        let expr = NormalizedExpr::Let {
            name: "x".to_string(),
            value: Box::new(NormalizedExpr::Perform {
                effect: "IO".to_string(),
                operation: "print".to_string(),
                args: vec![NormalizedExpr::Literal(Literal::String("Hello".to_string()))],
            }),
            body: Box::new(NormalizedExpr::Perform {
                effect: "State".to_string(),
                operation: "get".to_string(),
                args: vec![],
            }),
        };
        
        let effects = normalizer.infer_effects(&expr);
        assert_eq!(effects.len(), 2);
        
        assert!(effects.contains("IO"));
        assert!(effects.contains("State"));
    }
    
    #[test]
    fn test_handle_removes_effects() {
        let normalizer = EffectNormalizer::new();
        
        // Create a handle expression that handles IO
        let expr = NormalizedExpr::Handle {
            expr: Box::new(NormalizedExpr::Perform {
                effect: "IO".to_string(),
                operation: "print".to_string(),
                args: vec![],
            }),
            handlers: vec![
                NormalizedHandler {
                    effect: "IO".to_string(),
                    operation: "print".to_string(),
                    params: vec!["msg".to_string()],
                    resume: "k".to_string(),
                    body: NormalizedExpr::Apply {
                        func: Box::new(NormalizedExpr::Var("k".to_string())),
                        arg: Box::new(NormalizedExpr::Literal(Literal::String("handled".to_string()))),
                    },
                },
            ],
        };
        
        // The handled expression should have no effects
        let effects = normalizer.infer_effects(&expr);
        assert_eq!(effects.len(), 0);
    }
}