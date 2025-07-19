//! Salsa-based incremental compilation for XS language

use std::path::PathBuf;
use xs_core::{Expr, Type, XsError};

// Define the Salsa database struct
#[salsa::database(SourceProgramsStorage, CompilerQueriesStorage)]
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

// Group for source programs
#[salsa::query_group(SourceProgramsStorage)]
pub trait SourcePrograms: salsa::Database {
    #[salsa::input]
    fn source_text(&self, path: PathBuf) -> String;
}

// Group for compiler queries
#[salsa::query_group(CompilerQueriesStorage)]
pub trait CompilerQueries: SourcePrograms {
    fn parse_program(&self, path: PathBuf) -> Result<Expr, XsError>;
    fn type_check_program(&self, path: PathBuf) -> Result<Type, XsError>;
}

fn parse_program(db: &dyn CompilerQueries, path: PathBuf) -> Result<Expr, XsError> {
    let text = db.source_text(path);
    parser::parse(&text)
}

fn type_check_program(db: &dyn CompilerQueries, path: PathBuf) -> Result<Type, XsError> {
    let ast = db.parse_program(path)?;
    checker::type_check(&ast)
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_basic_incremental() {
        let mut db = XsDatabase::new();
        
        // Initial compilation
        let path1 = PathBuf::from("test1.xs");
        db.set_source_text(path1.clone(), "42".to_string());
        let type1 = db.type_check_program(path1.clone()).unwrap();
        assert_eq!(type1, Type::Int);
        
        // Change source
        let path2 = PathBuf::from("test2.xs");
        db.set_source_text(path2.clone(), "true".to_string());
        let type2 = db.type_check_program(path2.clone()).unwrap();
        assert_eq!(type2, Type::Bool);
        
        // Check that first result is still cached
        let type1_again = db.type_check_program(path1).unwrap();
        assert_eq!(type1_again, Type::Int);
    }
    
    #[test]
    fn test_parse_error_handling() {
        let mut db = XsDatabase::new();
        
        let path = PathBuf::from("error.xs");
        db.set_source_text(path.clone(), "(invalid".to_string());
        let result = db.type_check_program(path);
        assert!(result.is_err());
    }
}