//! XS Workspace - Structured codebase and incremental compilation
//!
//! This crate combines Unison-style content-addressed code storage
//! with incremental compilation using Salsa.

use thiserror::Error;

// Codebase modules
pub mod codebase;
pub mod test_cache;

// Incremental compilation modules
pub mod database;

// Namespace system modules
pub mod hash;
pub mod namespace;
pub mod dependency_extractor;
pub mod ast_command;
pub mod incremental_type_checker;
pub mod differential_test_runner;

// Code query modules
pub mod code_query;
pub mod query_engine;

// Pipeline processing modules
pub mod structured_data;
pub mod pipeline;
pub mod shell_syntax;
pub mod unified_parser;

// Re-export important types
pub use codebase::{
    Branch, Codebase, CodebaseError, CodebaseManager, EditAction, EditSession, Hash, Patch, Term,
    TypeDef,
};
pub use database::{
    CodebaseQueries, CompilerQueries, Definition, Dependencies, DependencyQueries, ExpressionId,
    ModuleId, SourcePrograms, XsDatabase,
};
pub use test_cache::{CachedTestRunner, TestCache, TestOutcome, TestResult};

/// Workspace errors
#[derive(Debug, Error)]
pub enum WorkspaceError {
    #[error("Codebase error: {0}")]
    CodebaseError(#[from] CodebaseError),

    #[error("Compilation error: {0}")]
    CompilationError(String),

    #[error("Incremental compilation error: {0}")]
    IncrementalError(String),

    #[error("Test cache error: {0}")]
    TestCacheError(String),

    #[error("IO error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("Parse error: {0}")]
    ParseError(String),
}

/// Simple source file representation
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SourceFile {
    pub path: String,
    pub content: String,
}

/// Database for incremental compilation
pub type Database = database::XsDatabaseImpl;

/// Incremental compiler for XS language
pub struct IncrementalCompiler {
    db: Database,
}

impl IncrementalCompiler {
    /// Create a new incremental compiler
    pub fn new() -> Self {
        Self {
            db: Database::new(),
        }
    }

    /// Set file content
    pub fn set_file_content(&mut self, path: String, content: String) {
        // Create a SourcePrograms instance
        let source = SourcePrograms {
            path,
            content: content.clone(),
        };
        // This will trigger re-computation if the content has changed
        self.db
            .set_source_text(source.clone(), std::sync::Arc::new(content));
    }

    /// Type check a file
    pub fn type_check(&self, path: &str) -> Result<xs_core::Type, xs_core::XsError> {
        // Use the type_check query
        // Set empty content for now - it should be in cache
        let source = SourcePrograms {
            path: path.to_string(),
            content: self
                .db
                .source_text(SourcePrograms {
                    path: path.to_string(),
                    content: String::new(),
                })
                .to_string(),
        };
        database::CompilerQueries::type_check(&self.db, source)
    }
}

impl Default for IncrementalCompiler {
    fn default() -> Self {
        Self::new()
    }
}

/// Combined workspace for XS language development
pub struct Workspace {
    codebase: Codebase,
    compiler: IncrementalCompiler,
    test_cache: TestCache,
}

impl Workspace {
    /// Create a new workspace with the specified data directory
    pub fn new<P: AsRef<std::path::Path>>(data_dir: P) -> Result<Self, WorkspaceError> {
        let codebase_path = data_dir.as_ref().join("codebase.bin");
        let codebase = if codebase_path.exists() {
            Codebase::load(&codebase_path)?
        } else {
            Codebase::new()
        };

        let compiler = IncrementalCompiler::new();
        let test_cache = TestCache::new(data_dir.as_ref().join("test_cache"))
            .map_err(|e| WorkspaceError::TestCacheError(e.to_string()))?;

        Ok(Self {
            codebase,
            compiler,
            test_cache,
        })
    }

    /// Save the workspace to disk
    pub fn save<P: AsRef<std::path::Path>>(&self, data_dir: P) -> Result<(), WorkspaceError> {
        let codebase_path = data_dir.as_ref().join("codebase.bin");
        self.codebase.save(&codebase_path)?;
        Ok(())
    }

    /// Get a reference to the codebase
    pub fn codebase(&self) -> &Codebase {
        &self.codebase
    }

    /// Get a mutable reference to the codebase
    pub fn codebase_mut(&mut self) -> &mut Codebase {
        &mut self.codebase
    }

    /// Get a reference to the incremental compiler
    pub fn compiler(&self) -> &IncrementalCompiler {
        &self.compiler
    }

    /// Get a mutable reference to the incremental compiler
    pub fn compiler_mut(&mut self) -> &mut IncrementalCompiler {
        &mut self.compiler
    }

    /// Get a reference to the test cache
    pub fn test_cache(&self) -> &TestCache {
        &self.test_cache
    }

    /// Get a mutable reference to the test cache
    pub fn test_cache_mut(&mut self) -> &mut TestCache {
        &mut self.test_cache
    }

    /// Compile a file incrementally
    pub fn compile_file(
        &mut self,
        path: &str,
        content: &str,
    ) -> Result<xs_core::Type, WorkspaceError> {
        self.compiler
            .set_file_content(path.to_string(), content.to_string());
        self.compiler
            .type_check(path)
            .map_err(|e| WorkspaceError::CompilationError(e.to_string()))
    }

    /// Add a term to the codebase
    pub fn add_term(
        &mut self,
        name: Option<String>,
        expr: xs_core::Expr,
        ty: xs_core::Type,
    ) -> Result<Hash, WorkspaceError> {
        Ok(self.codebase.add_term(name, expr, ty)?)
    }

    /// Run tests with caching
    pub fn run_test(&mut self, hash: &Hash) -> Result<TestResult, WorkspaceError> {
        let term = self.codebase.get_term(hash).ok_or_else(|| {
            WorkspaceError::CodebaseError(CodebaseError::HashNotFound(hash.to_hex()))
        })?;

        // Use the test cache to run tests
        let mut runner = CachedTestRunner::new(&mut self.test_cache, &self.codebase);

        // Run the test with a simple executor
        let result = runner.run_test(&term.expr, |expr| {
            // Simple test executor - just evaluate and check if it's true
            match xs_runtime::eval(expr) {
                Ok(xs_core::Value::Bool(true)) => Ok("Test passed".to_string()),
                Ok(xs_core::Value::Bool(false)) => Err("Test failed".to_string()),
                Ok(v) => Err(format!("Test returned non-boolean value: {v:?}")),
                Err(e) => Err(format!("Test error: {e}")),
            }
        });

        Ok(result)
    }

    /// Edit a term by name
    pub fn edit_term(&self, name: &str) -> Result<String, WorkspaceError> {
        Ok(self.codebase.edit(name)?)
    }

    /// Update a term after editing
    pub fn update_term(&mut self, name: &str, new_expr: &str) -> Result<Hash, WorkspaceError> {
        Ok(self.codebase.update(name, new_expr)?)
    }

    /// Create a patch from a set of changes
    pub fn create_patch(&self) -> Patch {
        Patch::new()
    }

    /// Apply a patch to the codebase
    pub fn apply_patch(&mut self, patch: &Patch) -> Result<(), WorkspaceError> {
        Ok(patch.apply(&mut self.codebase)?)
    }
}
