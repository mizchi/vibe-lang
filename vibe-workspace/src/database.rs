//! Salsa database for incremental compilation
//!
//! This module defines the Salsa database structure for efficiently
//! tracking dependencies and recomputing only what's changed.

use std::sync::Arc;
// use std::collections::HashMap;
use vibe_compiler::{TypeChecker, TypeEnv};
use vibe_core::{Expr, Type, XsError};

/// Source program input for the database
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SourcePrograms {
    pub path: String,
    pub content: String,
}

/// Module identifier
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ModuleId(pub String);

/// Expression identifier (hash-based)
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ExpressionId(pub String);

/// Dependencies of a module
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dependencies {
    pub imports: Vec<ModuleId>,
    pub exports: Vec<String>,
}

/// Definition in a module
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Definition {
    pub name: String,
    pub expr: Arc<Expr>,
    pub ty: Type,
}

/// XS language database
#[salsa::query_group(CompilerQueriesStorage)]
pub trait CompilerQueries {
    /// Parse source code
    #[salsa::input]
    fn source_text(&self, key: SourcePrograms) -> Arc<String>;

    /// Parse source to AST
    fn parse_source(&self, key: SourcePrograms) -> Result<Arc<Expr>, XsError>;

    /// Type check expression
    fn type_check(&self, key: SourcePrograms) -> Result<Type, XsError>;
}

/// Dependency tracking queries
#[salsa::query_group(DependencyQueriesStorage)]
pub trait DependencyQueries {
    /// Get module dependencies
    fn module_dependencies(&self, module: ModuleId) -> Arc<Dependencies>;

    /// Check if module needs recompilation
    fn needs_recompilation(&self, module: ModuleId) -> bool;
}

/// Codebase queries
#[salsa::query_group(CodebaseQueriesStorage)]
pub trait CodebaseQueries {
    /// Store expression by ID
    #[salsa::input]
    fn expression_source(&self, id: ExpressionId) -> Arc<Expr>;

    /// Get type of expression
    fn expression_type(&self, id: ExpressionId) -> Result<Type, XsError>;

    /// Get all definitions in a module
    fn module_definitions(&self, module: ModuleId) -> Arc<Vec<Definition>>;
}

/// Combined database trait
pub trait XsDatabase: CompilerQueries + DependencyQueries + CodebaseQueries {}

/// Implement parse_source query
fn parse_source(db: &dyn CompilerQueries, key: SourcePrograms) -> Result<Arc<Expr>, XsError> {
    let source = db.source_text(key);
    vibe_core::parser::parse(&source).map(Arc::new)
}

/// Implement type_check query
fn type_check(db: &dyn CompilerQueries, key: SourcePrograms) -> Result<Type, XsError> {
    let expr = db.parse_source(key)?;
    let mut checker = TypeChecker::new();
    let mut env = TypeEnv::new();
    checker
        .check(&expr, &mut env)
        .map_err(|e| XsError::TypeError(vibe_core::Span::new(0, 0), e))
}

/// Implement expression_type query
fn expression_type(db: &dyn CodebaseQueries, id: ExpressionId) -> Result<Type, XsError> {
    let expr = db.expression_source(id);
    let mut checker = TypeChecker::new();
    let mut env = TypeEnv::new();
    checker
        .check(&expr, &mut env)
        .map_err(|e| XsError::TypeError(vibe_core::Span::new(0, 0), e))
}

/// Implement module_dependencies query
fn module_dependencies(_db: &dyn DependencyQueries, _module: ModuleId) -> Arc<Dependencies> {
    // TODO: Implement actual dependency extraction
    Arc::new(Dependencies {
        imports: vec![],
        exports: vec![],
    })
}

/// Implement needs_recompilation query
fn needs_recompilation(db: &dyn DependencyQueries, module: ModuleId) -> bool {
    // Check if any dependencies have changed
    let deps = db.module_dependencies(module.clone());
    for dep in &deps.imports {
        if db.needs_recompilation(dep.clone()) {
            return true;
        }
    }
    false
}

/// Implement module_definitions query
fn module_definitions(_db: &dyn CodebaseQueries, _module: ModuleId) -> Arc<Vec<Definition>> {
    // TODO: Implement actual definition extraction
    Arc::new(vec![])
}

/// Database implementation
#[salsa::database(
    CompilerQueriesStorage,
    DependencyQueriesStorage,
    CodebaseQueriesStorage
)]
pub struct XsDatabaseImpl {
    storage: salsa::Storage<Self>,
}

impl salsa::Database for XsDatabaseImpl {}

impl XsDatabase for XsDatabaseImpl {}

impl Default for XsDatabaseImpl {
    fn default() -> Self {
        Self::new()
    }
}

impl XsDatabaseImpl {
    pub fn new() -> Self {
        Self {
            storage: Default::default(),
        }
    }
}
