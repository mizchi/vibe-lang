use crate::Type;

/// Node identifier for AST nodes
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct NodeId(pub u64);

/// Parser state for tracking effects and verification
#[derive(Debug, Clone, Default)]
pub struct ParserState {
    /// Tracked effects during parsing
    pub effects: Vec<ParseEffect>,
    /// Verification constraints
    pub constraints: Vec<Constraint>,
}

/// Token type for ParseEffect
#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    Let,
    If,
}

/// Effects that occur during parsing (Morpheus-style)
#[derive(Debug, Clone, PartialEq)]
pub enum ParseEffect {
    /// Token consumption
    Consume(Token),
    /// Lookahead
    Lookahead(usize),
    /// Backtracking
    Backtrack,
    /// Error recovery
    ErrorRecovery(String),
    /// Semantic action
    SemanticAction(String),
}

/// Verification constraints (Morpheus-style)
#[derive(Debug, Clone, PartialEq)]
pub enum Constraint {
    /// Type constraint
    TypeConstraint { expr: NodeId, expected: Type },
    /// Effect constraint
    EffectConstraint { expr: NodeId, effects: Vec<String> },
    /// Termination constraint
    Termination { expr: NodeId },
    /// Equivalence constraint
    Equivalence { left: NodeId, right: NodeId },
}