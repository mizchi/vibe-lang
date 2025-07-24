//! Extensible Effects System inspired by Koka and Unison
//!
//! This module provides a more advanced effect system that supports:
//! - Higher-order effects (effects that can handle other effects)
//! - Effect polymorphism
//! - Effect handlers
//! - Algebraic effects

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fmt;

/// Effect operation - represents a specific operation that can be performed
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EffectOp {
    /// The effect this operation belongs to
    pub effect: String,
    /// The operation name
    pub operation: String,
    /// Type signature of the operation (simplified for now)
    pub signature: OperationSignature,
}

/// Signature of an effect operation
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OperationSignature {
    /// Input types
    pub inputs: Vec<crate::Type>,
    /// Output type (before the effect is applied)
    pub output: crate::Type,
}

/// An effect definition with its operations
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EffectDefinition {
    /// Name of the effect
    pub name: String,
    /// Type parameters for the effect (e.g., State<s> has parameter 's')
    pub type_params: Vec<String>,
    /// Operations this effect provides
    pub operations: BTreeMap<String, OperationSignature>,
}

/// Extensible effect row - supports polymorphism and extension
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ExtensibleEffectRow {
    /// Empty effect row (pure)
    Empty,
    /// A single effect
    Single(EffectInstance),
    /// Extension: an effect plus the rest
    Extend(EffectInstance, Box<ExtensibleEffectRow>),
    /// Effect row variable (for polymorphism)
    Variable(String),
    /// Union of two effect rows
    Union(Box<ExtensibleEffectRow>, Box<ExtensibleEffectRow>),
}

/// An instance of an effect (potentially with type arguments)
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EffectInstance {
    /// Name of the effect
    pub name: String,
    /// Type arguments (e.g., State<Int> has [Int])
    pub type_args: Vec<crate::Type>,
}

impl EffectInstance {
    pub fn new(name: String) -> Self {
        EffectInstance {
            name,
            type_args: vec![],
        }
    }

    pub fn with_type_args(name: String, type_args: Vec<crate::Type>) -> Self {
        EffectInstance { name, type_args }
    }
}

impl ExtensibleEffectRow {
    /// Create a pure (empty) effect row
    pub fn pure() -> Self {
        ExtensibleEffectRow::Empty
    }

    /// Check if this effect row is pure
    pub fn is_pure(&self) -> bool {
        matches!(self, ExtensibleEffectRow::Empty)
    }

    /// Add an effect to this row
    pub fn add_effect(self, effect: EffectInstance) -> Self {
        match self {
            ExtensibleEffectRow::Empty => ExtensibleEffectRow::Single(effect),
            _ => ExtensibleEffectRow::Extend(effect, Box::new(self)),
        }
    }

    /// Simplify the effect row by combining duplicates
    pub fn simplify(&self) -> Self {
        // TODO: Implement simplification logic
        self.clone()
    }

    /// Get all concrete effects in this row
    pub fn get_effects(&self) -> Vec<EffectInstance> {
        match self {
            ExtensibleEffectRow::Empty => Vec::new(),
            ExtensibleEffectRow::Single(e) => vec![e.clone()],
            ExtensibleEffectRow::Extend(e, rest) => {
                let mut effects = vec![e.clone()];
                effects.extend(rest.get_effects());
                effects
            }
            ExtensibleEffectRow::Variable(_) => Vec::new(),
            ExtensibleEffectRow::Union(left, right) => {
                let mut effects = left.get_effects();
                effects.extend(right.get_effects());
                // Remove duplicates
                effects.sort_by(|a, b| a.name.cmp(&b.name));
                effects.dedup();
                effects
            }
        }
    }
}

impl fmt::Display for ExtensibleEffectRow {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ExtensibleEffectRow::Empty => write!(f, "⟨⟩"),
            ExtensibleEffectRow::Single(e) => write!(f, "⟨{e}⟩"),
            ExtensibleEffectRow::Extend(e, rest) => write!(f, "⟨{e} | {rest}⟩"),
            ExtensibleEffectRow::Variable(v) => write!(f, "{v}"),
            ExtensibleEffectRow::Union(left, right) => write!(f, "({left} ∪ {right})"),
        }
    }
}

impl fmt::Display for EffectInstance {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.type_args.is_empty() {
            write!(f, "{}", self.name)
        } else {
            write!(f, "{}<", self.name)?;
            for (i, arg) in self.type_args.iter().enumerate() {
                if i > 0 {
                    write!(f, ", ")?;
                }
                write!(f, "{arg}")?;
            }
            write!(f, ">")
        }
    }
}

/// Effect handler - defines how to handle effect operations
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EffectHandler {
    /// The effect being handled
    pub effect: String,
    /// Return type transformation
    pub return_clause: Option<HandlerClause>,
    /// Operation handlers
    pub operation_clauses: BTreeMap<String, HandlerClause>,
}

/// A clause in an effect handler
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HandlerClause {
    /// Parameters for this clause
    pub params: Vec<String>,
    /// The body of the handler
    pub body: crate::Expr,
}

/// Built-in effects that are always available
pub fn builtin_effects() -> BTreeMap<String, EffectDefinition> {
    let mut effects = BTreeMap::new();

    // IO Effect
    effects.insert(
        "IO".to_string(),
        EffectDefinition {
            name: "IO".to_string(),
            type_params: vec![],
            operations: {
                let mut ops = BTreeMap::new();
                ops.insert(
                    "print".to_string(),
                    OperationSignature {
                        inputs: vec![crate::Type::String],
                        output: crate::Type::Unit,
                    },
                );
                ops.insert(
                    "read".to_string(),
                    OperationSignature {
                        inputs: vec![],
                        output: crate::Type::String,
                    },
                );
                ops
            },
        },
    );

    // State Effect (polymorphic)
    effects.insert(
        "State".to_string(),
        EffectDefinition {
            name: "State".to_string(),
            type_params: vec!["s".to_string()],
            operations: {
                let mut ops = BTreeMap::new();
                ops.insert(
                    "get".to_string(),
                    OperationSignature {
                        inputs: vec![],
                        output: crate::Type::Var("s".to_string()),
                    },
                );
                ops.insert(
                    "put".to_string(),
                    OperationSignature {
                        inputs: vec![crate::Type::Var("s".to_string())],
                        output: crate::Type::Unit,
                    },
                );
                ops
            },
        },
    );

    // Exception Effect (polymorphic)
    effects.insert(
        "Exception".to_string(),
        EffectDefinition {
            name: "Exception".to_string(),
            type_params: vec!["e".to_string()],
            operations: {
                let mut ops = BTreeMap::new();
                ops.insert(
                    "throw".to_string(),
                    OperationSignature {
                        inputs: vec![crate::Type::Var("e".to_string())],
                        output: crate::Type::Var("a".to_string()), // polymorphic return
                    },
                );
                ops
            },
        },
    );

    // Async Effect
    effects.insert(
        "Async".to_string(),
        EffectDefinition {
            name: "Async".to_string(),
            type_params: vec![],
            operations: {
                let mut ops = BTreeMap::new();
                ops.insert(
                    "await".to_string(),
                    OperationSignature {
                        inputs: vec![crate::Type::Var("a".to_string())], // Promise<a>
                        output: crate::Type::Var("a".to_string()),
                    },
                );
                ops.insert(
                    "async".to_string(),
                    OperationSignature {
                        inputs: vec![crate::Type::Function(
                            Box::new(crate::Type::Unit),
                            Box::new(crate::Type::Var("a".to_string())),
                        )],
                        output: crate::Type::Var("a".to_string()), // Promise<a>
                    },
                );
                ops
            },
        },
    );

    effects
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pure_effect_row() {
        let row = ExtensibleEffectRow::pure();
        assert!(row.is_pure());
        assert_eq!(format!("{}", row), "⟨⟩");
    }

    #[test]
    fn test_single_effect() {
        let io = EffectInstance::new("IO".to_string());
        let row = ExtensibleEffectRow::Single(io);
        assert!(!row.is_pure());
        assert_eq!(format!("{}", row), "⟨IO⟩");
    }

    #[test]
    fn test_effect_with_type_args() {
        let state_int = EffectInstance::with_type_args("State".to_string(), vec![crate::Type::Int]);
        assert_eq!(format!("{}", state_int), "State<Int>");
    }

    #[test]
    fn test_effect_extension() {
        let io = EffectInstance::new("IO".to_string());
        let state = EffectInstance::new("State".to_string());

        let row = ExtensibleEffectRow::pure().add_effect(io).add_effect(state);

        let effects = row.get_effects();
        assert_eq!(effects.len(), 2);
    }
}
