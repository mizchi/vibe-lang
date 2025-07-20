//! Salsa-based incremental compilation for XS language

pub mod database;

pub use database::{
    XsDatabase, ExpressionId, ModuleId, Definition, Dependencies,
    SourcePrograms, CompilerQueries, CodebaseQueries, DependencyQueries
};
