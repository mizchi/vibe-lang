//! Code Query System for XS Language
//!
//! Provides structured querying capabilities for searching code by type patterns,
//! AST patterns, and dependencies. Designed for AI-friendly code exploration.

use xs_core::{Type, XsError};
use crate::hash::DefinitionHash;
use crate::namespace::{NamespacePath, DefinitionPath};

/// Query type for searching code
#[derive(Debug, Clone)]
pub enum CodeQuery {
    /// Search by type pattern (e.g., "Int -> Int" for functions from Int to Int)
    TypePattern(TypePattern),
    
    /// Search by AST pattern (e.g., functions containing match expressions)
    AstPattern(AstPattern),
    
    /// Search by dependencies
    DependsOn {
        target: DefinitionPath,
        transitive: bool,
    },
    
    /// Search by dependents (what depends on this)
    DependedBy {
        target: DefinitionPath,
        transitive: bool,
    },
    
    /// Search by name pattern (supports wildcards)
    NamePattern(String),
    
    /// Search within a specific namespace
    InNamespace(NamespacePath),
    
    /// Combine queries with AND
    And(Box<CodeQuery>, Box<CodeQuery>),
    
    /// Combine queries with OR
    Or(Box<CodeQuery>, Box<CodeQuery>),
    
    /// Negate a query
    Not(Box<CodeQuery>),
}

/// Type pattern for matching types
#[derive(Debug, Clone)]
pub enum TypePattern {
    /// Match exact type
    Exact(Type),
    
    /// Match function types with specific input/output patterns
    Function {
        input: Option<Box<TypePattern>>,
        output: Option<Box<TypePattern>>,
    },
    
    /// Match list types
    List(Box<TypePattern>),
    
    /// Match any type (wildcard)
    Any,
    
    /// Match types containing a specific type variable
    ContainsVar(String),
}

/// AST pattern for matching expressions
#[derive(Debug, Clone)]
pub enum AstPattern {
    /// Match expressions containing specific node types
    Contains(AstNodeType),
    
    /// Match function definitions with specific patterns
    FunctionWith {
        param_count: Option<usize>,
        contains: Option<Box<AstPattern>>,
        recursive: Option<bool>,
    },
    
    /// Match expressions using specific built-ins
    UsesBuiltin(String),
    
    /// Match pattern matching expressions
    HasPatternMatch {
        min_cases: Option<usize>,
        pattern_type: Option<PatternType>,
    },
}

/// Types of AST nodes
#[derive(Debug, Clone, PartialEq)]
pub enum AstNodeType {
    Lambda,
    Application,
    Let,
    LetIn,
    If,
    Match,
    Literal,
    Identifier,
    List,
    Cons,
    TypeAnnotation,
}

/// Types of patterns in pattern matching
#[derive(Debug, Clone)]
pub enum PatternType {
    Constructor,
    List,
    Cons,
    Literal,
    Variable,
    Wildcard,
}

/// Query builder for fluent API
pub struct QueryBuilder {
    query: Option<CodeQuery>,
}

#[allow(clippy::derivable_impls)]
impl Default for QueryBuilder {
    fn default() -> Self {
        Self { query: None }
    }
}

impl QueryBuilder {
    pub fn new() -> Self {
        Self::default()
    }
    
    /// Search for functions with specific type signature
    pub fn with_type(self, type_pattern: &str) -> Result<Self, XsError> {
        // Parse type pattern string
        let pattern = Self::parse_type_pattern(type_pattern)?;
        Ok(self.add_query(CodeQuery::TypePattern(pattern)))
    }
    
    /// Search for definitions containing specific AST nodes
    pub fn contains_ast(self, node_type: AstNodeType) -> Self {
        self.add_query(CodeQuery::AstPattern(AstPattern::Contains(node_type)))
    }
    
    /// Search for definitions that depend on a target
    pub fn depends_on(self, target: &str, transitive: bool) -> Result<Self, XsError> {
        let path = DefinitionPath::from_str(target)
            .ok_or_else(|| XsError::RuntimeError(
                xs_core::Span::new(0, 0),
                format!("Invalid definition path: {target}")
            ))?;
        
        Ok(self.add_query(CodeQuery::DependsOn { target: path, transitive }))
    }
    
    /// Search for definitions in a specific namespace
    pub fn in_namespace(self, namespace: &str) -> Self {
        let path = NamespacePath::from_str(namespace);
        self.add_query(CodeQuery::InNamespace(path))
    }
    
    /// Search by name pattern (supports * wildcard)
    pub fn with_name(self, pattern: &str) -> Self {
        self.add_query(CodeQuery::NamePattern(pattern.to_string()))
    }
    
    /// Combine with AND
    pub fn and(self, other: QueryBuilder) -> Self {
        match (self.query, other.query) {
            (Some(q1), Some(q2)) => Self {
                query: Some(CodeQuery::And(Box::new(q1), Box::new(q2)))
            },
            (Some(q), None) | (None, Some(q)) => Self { query: Some(q) },
            (None, None) => Self { query: None },
        }
    }
    
    /// Combine with OR
    pub fn or(self, other: QueryBuilder) -> Self {
        match (self.query, other.query) {
            (Some(q1), Some(q2)) => Self {
                query: Some(CodeQuery::Or(Box::new(q1), Box::new(q2)))
            },
            (Some(q), None) | (None, Some(q)) => Self { query: Some(q) },
            (None, None) => Self { query: None },
        }
    }
    
    /// Negate the query
    #[allow(clippy::should_implement_trait)]
    pub fn not(self) -> Self {
        match self.query {
            Some(q) => Self {
                query: Some(CodeQuery::Not(Box::new(q)))
            },
            None => self,
        }
    }
    
    /// Build the final query
    pub fn build(self) -> Option<CodeQuery> {
        self.query
    }
    
    // Helper methods
    
    fn add_query(mut self, query: CodeQuery) -> Self {
        self.query = Some(match self.query {
            Some(existing) => CodeQuery::And(Box::new(existing), Box::new(query)),
            None => query,
        });
        self
    }
    
    fn parse_type_pattern(pattern: &str) -> Result<TypePattern, XsError> {
        // Simple parser for type patterns
        // Examples: "Int -> Int", "List a", "a -> b", etc.
        
        if pattern == "_" || pattern == "Any" {
            return Ok(TypePattern::Any);
        }
        
        if pattern.contains("->") {
            // Function type pattern
            let parts: Vec<&str> = pattern.split("->").map(|s| s.trim()).collect();
            if parts.len() == 2 {
                let input = if parts[0] == "_" {
                    None
                } else {
                    Some(Box::new(Self::parse_type_pattern(parts[0])?))
                };
                
                let output = if parts[1] == "_" {
                    None
                } else {
                    Some(Box::new(Self::parse_type_pattern(parts[1])?))
                };
                
                return Ok(TypePattern::Function { input, output });
            }
        }
        
        if pattern.starts_with("List ") {
            return Ok(TypePattern::List(Box::new(Self::parse_type_pattern(pattern.strip_prefix("List<").unwrap())?)));
        }
        
        // Check for type variables
        if pattern.len() == 1 && pattern.chars().next().unwrap().is_lowercase() {
            return Ok(TypePattern::ContainsVar(pattern.to_string()));
        }
        
        // Try to parse as exact type
        match pattern {
            "Int" => Ok(TypePattern::Exact(Type::Int)),
            "Float" => Ok(TypePattern::Exact(Type::Float)),
            "String" => Ok(TypePattern::Exact(Type::String)),
            "Bool" => Ok(TypePattern::Exact(Type::Bool)),
            _ => Err(XsError::RuntimeError(
                xs_core::Span::new(0, 0),
                format!("Unknown type pattern: {pattern}")
            )),
        }
    }
}

/// Search result
#[derive(Debug, Clone)]
pub struct SearchResult {
    pub path: DefinitionPath,
    pub hash: DefinitionHash,
    pub type_signature: Type,
    pub relevance_score: f64,
    pub match_reason: String,
}

impl SearchResult {
    pub fn new(
        path: DefinitionPath,
        hash: DefinitionHash,
        type_signature: Type,
        match_reason: String,
    ) -> Self {
        Self {
            path,
            hash,
            type_signature,
            relevance_score: 1.0,
            match_reason,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_query_builder() {
        let query = QueryBuilder::new()
            .with_type("Int -> Int").unwrap()
            .in_namespace("Math")
            .build()
            .unwrap();
        
        match query {
            CodeQuery::And(left, right) => {
                matches!(*left, CodeQuery::TypePattern(_));
                matches!(*right, CodeQuery::InNamespace(_));
            }
            _ => panic!("Expected And query"),
        }
    }
    
    #[test]
    fn test_type_pattern_parsing() {
        let pattern = QueryBuilder::parse_type_pattern("Int -> Int").unwrap();
        match pattern {
            TypePattern::Function { input, output } => {
                assert!(input.is_some());
                assert!(output.is_some());
            }
            _ => panic!("Expected function pattern"),
        }
        
        let pattern = QueryBuilder::parse_type_pattern("List Int").unwrap();
        assert!(matches!(pattern, TypePattern::List(_)));
        
        let pattern = QueryBuilder::parse_type_pattern("a").unwrap();
        assert!(matches!(pattern, TypePattern::ContainsVar(_)));
    }
}