//! Koka-style effect system for Vibe Language
//! 
//! This module implements an effect system inspired by Koka,
//! with first-class handlers and row-polymorphic effects.

use crate::normalized_ast::{NormalizedExpr, NormalizedHandler};
use crate::Type;
use std::collections::{BTreeMap, BTreeSet};
use serde::{Serialize, Deserialize};

/// Effect row - a set of effects
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct EffectRow {
    /// Named effects in this row
    pub effects: BTreeSet<EffectType>,
    /// Row variable for polymorphism (e.g., 'e in <IO, State | e>)
    pub row_var: Option<String>,
}

impl EffectRow {
    /// Create an empty effect row (pure)
    pub fn pure() -> Self {
        Self {
            effects: BTreeSet::new(),
            row_var: None,
        }
    }
    
    /// Create an effect row with a single effect
    pub fn single(effect: EffectType) -> Self {
        let mut effects = BTreeSet::new();
        effects.insert(effect);
        Self {
            effects,
            row_var: None,
        }
    }
    
    /// Create a polymorphic effect row
    pub fn polymorphic(var: String) -> Self {
        Self {
            effects: BTreeSet::new(),
            row_var: Some(var),
        }
    }
    
    /// Union two effect rows
    pub fn union(&self, other: &Self) -> Self {
        let mut effects = self.effects.clone();
        effects.extend(other.effects.clone());
        
        // Handle row variables
        let row_var = match (&self.row_var, &other.row_var) {
            (Some(v1), Some(v2)) if v1 == v2 => Some(v1.clone()),
            (Some(v), None) | (None, Some(v)) => Some(v.clone()),
            _ => None,
        };
        
        Self { effects, row_var }
    }
    
    /// Remove an effect from the row (for handling)
    pub fn without(&self, effect: &EffectType) -> Self {
        let mut effects = self.effects.clone();
        effects.remove(effect);
        Self {
            effects,
            row_var: self.row_var.clone(),
        }
    }
}

/// Type of effect
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum EffectType {
    /// I/O operations
    IO,
    /// Mutable state with type
    State(String), // Type name
    /// Exceptions with type
    Exn(String),   // Exception type
    /// Asynchronous operations
    Async,
    /// Nondeterminism
    Amb,
    /// User-defined effect
    User(String),
}

/// Effect operation
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EffectOp {
    /// Effect type
    pub effect: EffectType,
    /// Operation name
    pub operation: String,
    /// Parameter types
    pub param_types: Vec<Type>,
    /// Return type
    pub return_type: Type,
}

/// Effect handler definition
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EffectHandler {
    /// Effect being handled
    pub effect: EffectType,
    /// Operation handlers
    pub operations: BTreeMap<String, HandlerClause>,
    /// Return handler (optional)
    pub return_handler: Option<ReturnHandler>,
}

/// Handler clause for an operation
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HandlerClause {
    /// Parameter names
    pub params: Vec<String>,
    /// Resume continuation parameter
    pub resume: String,
    /// Handler body
    pub body: NormalizedExpr,
}

/// Return handler
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReturnHandler {
    /// Value parameter
    pub param: String,
    /// Return transformation
    pub body: NormalizedExpr,
}

/// Transform Koka-style with/handler to normalized form
pub fn desugar_with_handler(
    handler_expr: NormalizedExpr,
    body: NormalizedExpr,
) -> NormalizedExpr {
    // with handler { body } becomes handle { body } { handler }
    match handler_expr {
        NormalizedExpr::Record(fields) => {
            // Convert record-style handler to handler cases
            let handlers = fields.into_iter()
                .filter_map(|(name, expr)| {
                    parse_handler_field(&name, expr)
                })
                .collect();
            
            NormalizedExpr::Handle {
                expr: Box::new(body),
                handlers,
            }
        }
        _ => {
            // Direct handler reference
            // This would be resolved from the environment
            NormalizedExpr::Handle {
                expr: Box::new(body),
                handlers: vec![], // Would be filled by type checker
            }
        }
    }
}

/// Parse a handler field from record notation
fn parse_handler_field(name: &str, expr: NormalizedExpr) -> Option<NormalizedHandler> {
    // Parse "Effect.operation" style names
    if let Some(dot_pos) = name.find('.') {
        let effect = &name[..dot_pos];
        let operation = &name[dot_pos + 1..];
        
        // Extract parameters and body from lambda
        if let NormalizedExpr::Lambda { param, body } = expr {
            // Nested lambda for resume continuation
            if let NormalizedExpr::Lambda { param: resume, body: handler_body } = *body {
                return Some(NormalizedHandler {
                    effect: effect.to_string(),
                    operation: operation.to_string(),
                    params: vec![param],
                    resume,
                    body: *handler_body,
                });
            }
        }
    }
    
    None
}

/// Koka-style function type with effects
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FunctionType {
    /// Parameter types
    pub params: Vec<Type>,
    /// Effect row
    pub effects: EffectRow,
    /// Return type
    pub result: Type,
}

impl FunctionType {
    /// Create a pure function type
    pub fn pure(params: Vec<Type>, result: Type) -> Self {
        Self {
            params,
            effects: EffectRow::pure(),
            result,
        }
    }
    
    /// Create an effectful function type
    pub fn effectful(params: Vec<Type>, effects: EffectRow, result: Type) -> Self {
        Self {
            params,
            effects,
            result,
        }
    }
}

/// Transform do-notation to Koka-style with/handler
pub fn desugar_do_notation(
    statements: Vec<DoStatement>,
    implicit_effect: Option<EffectType>,
) -> NormalizedExpr {
    match statements.as_slice() {
        [] => panic!("Empty do block"),
        [DoStatement::Expr(e)] => e.clone(),
        [DoStatement::Bind(var, expr), rest @ ..] => {
            // Transform x <- expr to with handler for implicit effect
            let continuation = desugar_do_notation(rest.to_vec(), implicit_effect.clone());
            
            if let Some(effect) = implicit_effect {
                // Wrap in implicit effect handler
                let handler = create_bind_handler(&effect, var, &continuation);
                NormalizedExpr::Handle {
                    expr: Box::new(expr.clone()),
                    handlers: vec![handler],
                }
            } else {
                // Regular let binding
                NormalizedExpr::Let {
                    name: var.clone(),
                    value: Box::new(expr.clone()),
                    body: Box::new(continuation),
                }
            }
        }
        _ => panic!("Invalid do block structure"),
    }
}

/// Create a bind handler for monadic do-notation
fn create_bind_handler(effect: &EffectType, var: &str, continuation: &NormalizedExpr) -> NormalizedHandler {
    NormalizedHandler {
        effect: format!("{:?}", effect), // Simplified
        operation: "bind".to_string(),
        params: vec![var.to_string()],
        resume: "_".to_string(), // Not used for bind
        body: continuation.clone(),
    }
}

/// Do-notation statement
#[derive(Debug, Clone)]
pub enum DoStatement {
    /// Pattern <- expression
    Bind(String, NormalizedExpr),
    /// let pattern = expression  
    Let(String, NormalizedExpr),
    /// expression
    Expr(NormalizedExpr),
}

/// Example: State effect with get/put operations
pub fn state_effect_handler(initial: NormalizedExpr) -> Vec<NormalizedHandler> {
    vec![
        // get : () -> State s
        NormalizedHandler {
            effect: "State".to_string(),
            operation: "get".to_string(),
            params: vec![],
            resume: "k".to_string(),
            body: NormalizedExpr::Apply {
                func: Box::new(NormalizedExpr::Var("k".to_string())),
                arg: Box::new(NormalizedExpr::Var("_state".to_string())),
            },
        },
        // put : s -> ()
        NormalizedHandler {
            effect: "State".to_string(),
            operation: "put".to_string(),
            params: vec!["new_state".to_string()],
            resume: "k".to_string(),
            body: NormalizedExpr::Let {
                name: "_state".to_string(),
                value: Box::new(NormalizedExpr::Var("new_state".to_string())),
                body: Box::new(NormalizedExpr::Apply {
                    func: Box::new(NormalizedExpr::Var("k".to_string())),
                    arg: Box::new(NormalizedExpr::Literal(crate::Literal::String("()".to_string()))),
                }),
            },
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Literal;
    
    #[test]
    fn test_effect_row_operations() {
        let row1 = EffectRow::single(EffectType::IO);
        let row2 = EffectRow::single(EffectType::State("Int".to_string()));
        
        let combined = row1.union(&row2);
        assert_eq!(combined.effects.len(), 2);
        assert!(combined.effects.contains(&EffectType::IO));
        assert!(combined.effects.contains(&EffectType::State("Int".to_string())));
        
        let handled = combined.without(&EffectType::IO);
        assert_eq!(handled.effects.len(), 1);
        assert!(!handled.effects.contains(&EffectType::IO));
    }
    
    #[test]
    fn test_with_handler_desugaring() {
        // Create a simple handler as a record
        let handler = NormalizedExpr::Record({
            let mut fields = BTreeMap::new();
            fields.insert(
                "IO.print".to_string(),
                NormalizedExpr::Lambda {
                    param: "msg".to_string(),
                    body: Box::new(NormalizedExpr::Lambda {
                        param: "k".to_string(),
                        body: Box::new(NormalizedExpr::Apply {
                            func: Box::new(NormalizedExpr::Var("k".to_string())),
                            arg: Box::new(NormalizedExpr::Literal(Literal::String("printed".to_string()))),
                        }),
                    }),
                },
            );
            fields
        });
        
        let body = NormalizedExpr::Perform {
            effect: "IO".to_string(),
            operation: "print".to_string(),
            args: vec![NormalizedExpr::Literal(Literal::String("hello".to_string()))],
        };
        
        let result = desugar_with_handler(handler, body);
        
        match result {
            NormalizedExpr::Handle { handlers, .. } => {
                assert_eq!(handlers.len(), 1);
                assert_eq!(handlers[0].effect, "IO");
                assert_eq!(handlers[0].operation, "print");
            }
            _ => panic!("Expected Handle expression"),
        }
    }
    
    #[test]
    fn test_polymorphic_effects() {
        let poly = EffectRow::polymorphic("e".to_string());
        let with_io = EffectRow::single(EffectType::IO);
        
        let combined = poly.union(&with_io);
        assert!(combined.effects.contains(&EffectType::IO));
        assert_eq!(combined.row_var, Some("e".to_string()));
    }
}