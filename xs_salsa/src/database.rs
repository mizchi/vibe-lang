//! Salsa database implementation for XS language with advanced features

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use xs_core::{Expr, Type, XsError};

/// Expression identified by its hash
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ExpressionId(pub String);

/// Module identifier
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ModuleId(pub String);

/// Definition in the codebase
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Definition {
    pub name: String,
    pub expr_id: ExpressionId,
    pub module_id: ModuleId,
}

/// Dependency information
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dependencies {
    pub direct: Vec<String>,
    pub transitive: Vec<String>,
}

// Enhanced Salsa database
#[salsa::database(
    SourceProgramsStorage,
    CompilerQueriesStorage,
    CodebaseQueriesStorage,
    DependencyQueriesStorage
)]
#[derive(Default)]
pub struct XsDatabase {
    storage: salsa::Storage<Self>,
}

impl salsa::Database for XsDatabase {}

impl XsDatabase {
    pub fn new() -> Self {
        Self::default()
    }
}

// Source programs group
#[salsa::query_group(SourceProgramsStorage)]
pub trait SourcePrograms: salsa::Database {
    #[salsa::input]
    fn source_text(&self, path: PathBuf) -> String;
    
    #[salsa::input]
    fn expression_source(&self, id: ExpressionId) -> Arc<Expr>;
}

// Compiler queries group
#[salsa::query_group(CompilerQueriesStorage)]
pub trait CompilerQueries: SourcePrograms {
    fn parse_program(&self, path: PathBuf) -> Result<Expr, XsError>;
    fn type_check_program(&self, path: PathBuf) -> Result<Type, XsError>;
    fn type_check_expression(&self, id: ExpressionId) -> Result<Type, XsError>;
}

// Codebase queries group
#[salsa::query_group(CodebaseQueriesStorage)]
pub trait CodebaseQueries: CompilerQueries {
    #[salsa::input]
    fn definition(&self, name: String) -> Option<Definition>;
    
    fn all_definitions(&self) -> Vec<Definition>;
    fn find_definitions(&self, pattern: String) -> Vec<Definition>;
    fn get_definition_type(&self, name: String) -> Option<Type>;
}

// Dependency queries group
#[salsa::query_group(DependencyQueriesStorage)]
pub trait DependencyQueries: CodebaseQueries {
    fn dependencies(&self, name: String) -> Dependencies;
    fn dependents(&self, name: String) -> Vec<String>;
    fn dependency_graph(&self) -> HashMap<String, Vec<String>>;
}

// Implementation of query functions
fn parse_program(db: &dyn CompilerQueries, path: PathBuf) -> Result<Expr, XsError> {
    let text = db.source_text(path);
    parser::parse(&text)
}

fn type_check_program(db: &dyn CompilerQueries, path: PathBuf) -> Result<Type, XsError> {
    let ast = db.parse_program(path)?;
    let mut type_checker = checker::TypeChecker::new();
    let mut type_env = checker::TypeEnv::default();
    type_checker.check(&ast, &mut type_env)
}

fn type_check_expression(db: &dyn CompilerQueries, id: ExpressionId) -> Result<Type, XsError> {
    let expr = db.expression_source(id);
    let mut type_checker = checker::TypeChecker::new();
    let mut type_env = checker::TypeEnv::default();
    type_checker.check(&expr, &mut type_env)
}

fn all_definitions(_db: &dyn CodebaseQueries) -> Vec<Definition> {
    // This would be populated by the codebase manager
    Vec::new()
}

fn find_definitions(db: &dyn CodebaseQueries, pattern: String) -> Vec<Definition> {
    db.all_definitions()
        .into_iter()
        .filter(|def| def.name.contains(&pattern))
        .collect()
}

fn get_definition_type(db: &dyn CodebaseQueries, name: String) -> Option<Type> {
    db.definition(name)
        .and_then(|def| db.type_check_expression(def.expr_id).ok())
}

fn dependencies(_db: &dyn DependencyQueries, _name: String) -> Dependencies {
    // TODO: Implement actual dependency analysis
    Dependencies {
        direct: Vec::new(),
        transitive: Vec::new(),
    }
}

fn dependents(_db: &dyn DependencyQueries, _name: String) -> Vec<String> {
    // TODO: Implement actual dependent analysis
    Vec::new()
}

fn dependency_graph(_db: &dyn DependencyQueries) -> HashMap<String, Vec<String>> {
    // TODO: Build full dependency graph
    HashMap::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_expression_caching() {
        let mut db = XsDatabase::new();
        
        let expr_id = ExpressionId("test_hash".to_string());
        let expr = parser::parse("(fn (x) (* x 2))").unwrap();
        db.set_expression_source(expr_id.clone(), Arc::new(expr));
        
        let ty = db.type_check_expression(expr_id.clone()).unwrap();
        assert!(matches!(ty, Type::Arrow(_, _)));
        
        // Should be cached
        let ty2 = db.type_check_expression(expr_id).unwrap();
        assert_eq!(ty, ty2);
    }
}