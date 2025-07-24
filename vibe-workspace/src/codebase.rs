//! Unison-style structured codebase for XS language
//!
//! This module implements a content-addressed storage system for code,
//! where functions are stored by their hash and can be loaded on demand.

use im::HashMap as ImHashMap;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use thiserror::Error;

use vibe_compiler::{TypeChecker, TypeEnv};
use vibe_core::parser::parse;
use vibe_core::{Expr, Type};

pub use crate::test_cache::{CachedTestRunner, TestCache, TestOutcome, TestResult};

/// Hash of a code element (function, type, etc.)
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Hash(pub(crate) [u8; 32]);

impl Hash {
    pub fn new(data: &[u8]) -> Self {
        let mut hasher = Sha256::new();
        hasher.update(data);
        let result = hasher.finalize();
        let mut hash = [0u8; 32];
        hash.copy_from_slice(&result);
        Hash(hash)
    }

    pub fn to_hex(&self) -> String {
        hex::encode(self.0)
    }

    pub fn from_hex(s: &str) -> Result<Self, hex::FromHexError> {
        let bytes = hex::decode(s)?;
        if bytes.len() != 32 {
            return Err(hex::FromHexError::InvalidStringLength);
        }
        let mut hash = [0u8; 32];
        hash.copy_from_slice(&bytes);
        Ok(Hash(hash))
    }
}

/// A term in the codebase (function, constant, type definition)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Term {
    pub hash: Hash,
    pub name: Option<String>,
    pub expr: Expr,
    pub ty: Type,
    pub dependencies: HashSet<Hash>,
}

/// A type definition in the codebase
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TypeDef {
    pub hash: Hash,
    pub name: String,
    pub definition: vibe_core::TypeDefinition,
}

/// The structured codebase
#[derive(Debug, Clone)]
pub struct Codebase {
    /// Terms indexed by hash
    pub(crate) terms: ImHashMap<Hash, Term>,

    /// Type definitions indexed by hash
    pub(crate) types: ImHashMap<Hash, TypeDef>,

    /// Name index for terms
    pub(crate) term_names: ImHashMap<String, Hash>,

    /// Name index for types
    pub(crate) type_names: ImHashMap<String, Hash>,

    /// Dependency graph
    pub(crate) dependencies: ImHashMap<Hash, HashSet<Hash>>,

    /// Reverse dependency graph (who depends on this)
    pub(crate) dependents: ImHashMap<Hash, HashSet<Hash>>,
}

#[derive(Debug, Error)]
pub enum CodebaseError {
    #[error("Term not found: {0}")]
    TermNotFound(String),

    #[error("Type not found: {0}")]
    TypeNotFound(String),

    #[error("Hash not found: {0}")]
    HashNotFound(String),

    #[error("Circular dependency detected")]
    CircularDependency,

    #[error("Parse error: {0}")]
    ParseError(String),

    #[error("Type error: {0}")]
    TypeError(String),

    #[error("IO error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("Serialization error: {0}")]
    SerializationError(#[from] bincode::Error),
}

impl Codebase {
    pub fn new() -> Self {
        Self {
            terms: ImHashMap::new(),
            types: ImHashMap::new(),
            term_names: ImHashMap::new(),
            type_names: ImHashMap::new(),
            dependencies: ImHashMap::new(),
            dependents: ImHashMap::new(),
        }
    }

    /// Add a term to the codebase
    pub fn add_term(
        &mut self,
        name: Option<String>,
        expr: Expr,
        ty: Type,
    ) -> Result<Hash, CodebaseError> {
        // Extract dependencies from the expression
        let deps = self.extract_dependencies(&expr);

        // Calculate hash based on normalized expression
        let normalized = self.normalize_expr(&expr);
        let serialized =
            bincode::serialize(&normalized).map_err(CodebaseError::SerializationError)?;
        let hash = Hash::new(&serialized);

        let term = Term {
            hash: hash.clone(),
            name: name.clone(),
            expr,
            ty,
            dependencies: deps.clone(),
        };

        // Update indices
        self.terms.insert(hash.clone(), term);
        if let Some(n) = name {
            self.term_names.insert(n, hash.clone());
        }

        // Update dependency graphs
        self.dependencies.insert(hash.clone(), deps.clone());
        for dep in deps {
            self.dependents.entry(dep).or_default().insert(hash.clone());
        }

        Ok(hash)
    }

    /// Get a term by hash
    pub fn get_term(&self, hash: &Hash) -> Option<&Term> {
        self.terms.get(hash)
    }

    /// Get a term by name
    pub fn get_term_by_name(&self, name: &str) -> Option<&Term> {
        self.term_names
            .get(name)
            .and_then(|hash| self.terms.get(hash))
    }

    /// Get all dependencies of a term (transitive closure)
    pub fn get_all_dependencies(&self, hash: &Hash) -> Result<Vec<Hash>, CodebaseError> {
        let mut visited = HashSet::new();
        let mut result = Vec::new();
        let mut stack = vec![hash.clone()];

        while let Some(current) = stack.pop() {
            if visited.contains(&current) {
                continue;
            }
            visited.insert(current.clone());

            if let Some(deps) = self.dependencies.get(&current) {
                for dep in deps {
                    if !visited.contains(dep) {
                        stack.push(dep.clone());
                        result.push(dep.clone());
                    }
                }
            }
        }

        Ok(result)
    }

    /// Edit a term (UCM-style edit command)
    /// Returns the expression with all dependencies expanded inline
    pub fn edit(&self, name: &str) -> Result<String, CodebaseError> {
        let term = self
            .get_term_by_name(name)
            .ok_or_else(|| CodebaseError::TermNotFound(name.to_string()))?;

        // Get all dependencies
        let deps = self.get_all_dependencies(&term.hash)?;

        // Build the expanded expression
        let mut result = String::new();

        // Add all dependencies first
        for dep_hash in deps.iter().rev() {
            if let Some(dep_term) = self.get_term(dep_hash) {
                if let Some(dep_name) = &dep_term.name {
                    result.push_str(&format!("(let {dep_name} "));
                    result.push_str(&self.expr_to_string(&dep_term.expr));
                    result.push('\n');
                }
            }
        }

        // Add the main term
        result.push_str(&self.expr_to_string(&term.expr));

        // Close all let bindings
        for _ in &deps {
            result.push(')');
        }

        Ok(result)
    }

    /// Update a term after editing
    pub fn update(&mut self, name: &str, new_expr_str: &str) -> Result<Hash, CodebaseError> {
        // Parse the new expression
        let new_expr = parse(new_expr_str).map_err(|e| CodebaseError::ParseError(e.to_string()))?;

        // Type check
        let mut checker = TypeChecker::new();
        let mut env = TypeEnv::new();
        let ty = checker
            .check(&new_expr, &mut env)
            .map_err(|e| CodebaseError::TypeError(format!("{e:?}")))?;

        // Remove old version if it exists
        if let Some(old_hash) = self.term_names.get(name).cloned() {
            self.remove_term(&old_hash)?;
        }

        // Add new version
        self.add_term(Some(name.to_string()), new_expr, ty)
    }

    /// Remove a term from the codebase
    pub fn remove_term(&mut self, hash: &Hash) -> Result<(), CodebaseError> {
        // Check if anything depends on this term
        if let Some(dependents) = self.dependents.get(hash) {
            if !dependents.is_empty() {
                return Err(CodebaseError::TermNotFound(format!(
                    "Cannot remove term with {} dependents",
                    dependents.len()
                )));
            }
        }

        // Remove from all indices
        if let Some(term) = self.terms.get(hash) {
            if let Some(name) = &term.name {
                self.term_names.remove(name);
            }
        }

        self.terms.remove(hash);
        self.dependencies.remove(hash);
        self.dependents.remove(hash);

        Ok(())
    }

    /// 依存関係から逆引き依存関係を再構築
    pub fn rebuild_dependents(&mut self) {
        self.dependents.clear();
        
        for (hash, deps) in &self.dependencies {
            for dep in deps {
                self.dependents
                    .entry(dep.clone())
                    .or_insert_with(HashSet::new)
                    .insert(hash.clone());
            }
        }
    }

    /// Get all term names and their hashes
    pub fn names(&self) -> Vec<(String, Hash)> {
        self.term_names.iter()
            .map(|(name, hash)| (name.clone(), hash.clone()))
            .collect()
    }

    /// Get direct dependencies of a term
    pub fn get_direct_dependencies(&self, hash: &Hash) -> HashSet<Hash> {
        self.dependencies.get(hash)
            .cloned()
            .unwrap_or_default()
    }

    /// Get dependents of a term
    pub fn get_dependents(&self, hash: &Hash) -> HashSet<Hash> {
        self.dependents.get(hash)
            .cloned()
            .unwrap_or_default()
    }

    /// Extract dependencies from an expression
    fn extract_dependencies(&self, expr: &Expr) -> HashSet<Hash> {
        let mut deps = HashSet::new();
        self.extract_deps_recursive(expr, &mut deps);
        deps
    }

    fn extract_deps_recursive(&self, expr: &Expr, deps: &mut HashSet<Hash>) {
        match expr {
            Expr::Ident(name, _) => {
                // Check if this identifier refers to a term in the codebase
                if let Some(hash) = self.term_names.get(&name.0) {
                    deps.insert(hash.clone());
                }
            }
            Expr::Apply { func, args, .. } => {
                self.extract_deps_recursive(func, deps);
                for arg in args {
                    self.extract_deps_recursive(arg, deps);
                }
            }
            Expr::Lambda { body, .. } => {
                self.extract_deps_recursive(body, deps);
            }
            Expr::Let { value, .. } | Expr::LetRec { value, .. } => {
                self.extract_deps_recursive(value, deps);
            }
            Expr::If {
                cond,
                then_expr,
                else_expr,
                ..
            } => {
                self.extract_deps_recursive(cond, deps);
                self.extract_deps_recursive(then_expr, deps);
                self.extract_deps_recursive(else_expr, deps);
            }
            Expr::List(exprs, _) => {
                for e in exprs {
                    self.extract_deps_recursive(e, deps);
                }
            }
            Expr::Match { expr, cases, .. } => {
                self.extract_deps_recursive(expr, deps);
                for (_, case_expr) in cases {
                    self.extract_deps_recursive(case_expr, deps);
                }
            }
            Expr::Pipeline { expr, func, .. } => {
                self.extract_deps_recursive(expr, deps);
                self.extract_deps_recursive(func, deps);
            }
            _ => {}
        }
    }

    /// Normalize expression for hashing (alpha-renaming, etc.)
    fn normalize_expr(&self, expr: &Expr) -> Expr {
        // TODO: Implement proper alpha-renaming and normalization
        // For now, just clone
        expr.clone()
    }

    /// Convert expression to string representation
    fn expr_to_string(&self, expr: &Expr) -> String {
        // TODO: Implement proper pretty-printing
        format!("{expr:?}")
    }

    /// Save codebase to disk
    pub fn save(&self, path: &Path) -> Result<(), CodebaseError> {
        let data = bincode::serialize(self).map_err(CodebaseError::SerializationError)?;
        std::fs::write(path, data)?;
        Ok(())
    }

    /// Load codebase from disk
    pub fn load(path: &Path) -> Result<Self, CodebaseError> {
        let data = std::fs::read(path)?;
        let codebase = bincode::deserialize(&data).map_err(CodebaseError::SerializationError)?;
        Ok(codebase)
    }
}

impl Default for Codebase {
    fn default() -> Self {
        Self::new()
    }
}

/// Branch in the codebase
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Branch {
    pub name: String,
    pub hash: String,
    pub patches: Vec<Patch>,
}

/// Edit action for session
#[derive(Debug, Clone)]
pub enum EditAction {
    AddDefinition { name: String, expr: Expr },
    UpdateDefinition { name: String, expr: Expr },
    DeleteDefinition { name: String },
}

/// Edit session for accumulating changes
#[derive(Debug, Clone)]
pub struct EditSession {
    pub branch_hash: String,
    pub edits: Vec<EditAction>,
}

impl EditSession {
    pub fn new(branch_hash: String) -> Self {
        Self {
            branch_hash,
            edits: Vec::new(),
        }
    }

    pub fn add_definition(&mut self, name: String, expr: Expr) -> Result<String, CodebaseError> {
        self.edits.push(EditAction::AddDefinition {
            name,
            expr: expr.clone(),
        });
        let serialized = bincode::serialize(&expr)?;
        Ok(Hash::new(&serialized).to_hex())
    }
}

/// Codebase manager for branch management
pub struct CodebaseManager {
    codebase: Codebase,
    branches: HashMap<String, Branch>,
    #[allow(dead_code)]
    storage_path: std::path::PathBuf,
}

impl CodebaseManager {
    pub fn new(storage_path: std::path::PathBuf) -> Result<Self, CodebaseError> {
        std::fs::create_dir_all(&storage_path)?;
        Ok(Self {
            codebase: Codebase::new(),
            branches: HashMap::new(),
            storage_path,
        })
    }

    pub fn create_branch(&mut self, name: String) -> Result<&Branch, CodebaseError> {
        let branch = Branch {
            name: name.clone(),
            hash: "initial".to_string(),
            patches: Vec::new(),
        };
        self.branches.insert(name.clone(), branch);
        self.branches
            .get(&name)
            .ok_or(CodebaseError::TermNotFound(name))
    }

    pub fn get_branch(&self, name: &str) -> Result<&Branch, CodebaseError> {
        self.branches
            .get(name)
            .ok_or_else(|| CodebaseError::TermNotFound(name.to_string()))
    }

    pub fn hash_expr(&self, expr: &Expr) -> String {
        let serialized = bincode::serialize(&expr).unwrap_or_default();
        Hash::new(&serialized).to_hex()
    }

    pub fn create_patch_from_session(&self, session: &EditSession) -> Result<Patch, CodebaseError> {
        let mut patch = Patch::new();
        for edit in &session.edits {
            match edit {
                EditAction::AddDefinition { name, expr } => {
                    // TODO: Infer type here
                    let ty = Type::Int; // Placeholder
                    patch.add_term(Some(name.clone()), expr.clone(), ty);
                }
                EditAction::UpdateDefinition { name, expr } => {
                    // Convert expr to string representation
                    let expr_str = format!("{expr:?}"); // TODO: Proper formatting
                    patch.update_term(name.clone(), expr_str);
                }
                EditAction::DeleteDefinition { name } => {
                    // Find hash by name
                    if let Some(term) = self.codebase.get_term_by_name(name) {
                        patch.remove_term(term.hash.clone());
                    }
                }
            }
        }
        Ok(patch)
    }

    pub fn apply_patch(&mut self, branch_name: &str, patch: &Patch) -> Result<(), CodebaseError> {
        patch.apply(&mut self.codebase)?;
        if let Some(branch) = self.branches.get_mut(branch_name) {
            branch.patches.push(patch.clone());
            // Update branch hash
            let serialized = bincode::serialize(&branch.patches)?;
            branch.hash = Hash::new(&serialized).to_hex();
        }
        Ok(())
    }
}

/// Patch representation for incremental updates
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Patch {
    pub adds: Vec<(Option<String>, Expr, Type)>,
    pub removes: Vec<Hash>,
    pub updates: Vec<(String, String)>, // (name, new_expr_string)
}

impl Default for Patch {
    fn default() -> Self {
        Self::new()
    }
}

impl Patch {
    pub fn new() -> Self {
        Self {
            adds: Vec::new(),
            removes: Vec::new(),
            updates: Vec::new(),
        }
    }

    pub fn add_term(&mut self, name: Option<String>, expr: Expr, ty: Type) {
        self.adds.push((name, expr, ty));
    }

    pub fn remove_term(&mut self, hash: Hash) {
        self.removes.push(hash);
    }

    pub fn update_term(&mut self, name: String, new_expr: String) {
        self.updates.push((name, new_expr));
    }

    /// Apply this patch to a codebase
    pub fn apply(&self, codebase: &mut Codebase) -> Result<(), CodebaseError> {
        // First, remove terms
        for hash in &self.removes {
            codebase.remove_term(hash)?;
        }

        // Then, add new terms
        for (name, expr, ty) in &self.adds {
            codebase.add_term(name.clone(), expr.clone(), ty.clone())?;
        }

        // Finally, update existing terms
        for (name, new_expr) in &self.updates {
            codebase.update(name, new_expr)?;
        }

        Ok(())
    }
}

// Make Codebase serializable for persistence
impl Serialize for Codebase {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeStruct;

        let mut state = serializer.serialize_struct("Codebase", 6)?;

        // Convert ImHashMap to HashMap for serialization
        let terms: HashMap<_, _> = self
            .terms
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        let types: HashMap<_, _> = self
            .types
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        let term_names: HashMap<_, _> = self
            .term_names
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        let type_names: HashMap<_, _> = self
            .type_names
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        let dependencies: HashMap<_, _> = self
            .dependencies
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        let dependents: HashMap<_, _> = self
            .dependents
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();

        state.serialize_field("terms", &terms)?;
        state.serialize_field("types", &types)?;
        state.serialize_field("term_names", &term_names)?;
        state.serialize_field("type_names", &type_names)?;
        state.serialize_field("dependencies", &dependencies)?;
        state.serialize_field("dependents", &dependents)?;

        state.end()
    }
}

impl<'de> Deserialize<'de> for Codebase {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        #[derive(Deserialize)]
        struct CodebaseData {
            terms: HashMap<Hash, Term>,
            types: HashMap<Hash, TypeDef>,
            term_names: HashMap<String, Hash>,
            type_names: HashMap<String, Hash>,
            dependencies: HashMap<Hash, HashSet<Hash>>,
            dependents: HashMap<Hash, HashSet<Hash>>,
        }

        let data = CodebaseData::deserialize(deserializer)?;

        Ok(Codebase {
            terms: data.terms.into_iter().collect(),
            types: data.types.into_iter().collect(),
            term_names: data.term_names.into_iter().collect(),
            type_names: data.type_names.into_iter().collect(),
            dependencies: data.dependencies.into_iter().collect(),
            dependents: data.dependents.into_iter().collect(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vibe_core::{Ident, Pattern};

    #[test]
    fn test_hash_operations() {
        let data = b"hello world";
        let hash1 = Hash::new(data);
        let hex = hash1.to_hex();
        let hash2 = Hash::from_hex(&hex).unwrap();
        assert_eq!(hash1, hash2);
    }

    #[test]
    fn test_codebase_add_term() {
        let mut codebase = Codebase::new();
        let expr = Expr::Literal(vibe_core::Literal::Int(42), vibe_core::Span::new(0, 2));
        let ty = Type::Int;

        let hash = codebase
            .add_term(Some("answer".to_string()), expr.clone(), ty.clone())
            .unwrap();

        let term = codebase.get_term(&hash).unwrap();
        assert_eq!(term.name, Some("answer".to_string()));

        let term_by_name = codebase.get_term_by_name("answer").unwrap();
        assert_eq!(term_by_name.hash, hash);
    }

    #[test]
    fn test_patch_application() {
        let mut codebase = Codebase::new();
        let mut patch = Patch::new();

        let expr = Expr::Literal(vibe_core::Literal::Int(42), vibe_core::Span::new(0, 2));
        let ty = Type::Int;

        patch.add_term(Some("x".to_string()), expr, ty);
        patch.apply(&mut codebase).unwrap();

        assert!(codebase.get_term_by_name("x").is_some());
    }

    #[test]
    fn test_dependency_extraction() {
        let mut codebase = Codebase::new();

        // Add a base function
        let base_expr = Expr::Literal(vibe_core::Literal::Int(10), vibe_core::Span::new(0, 2));
        let base_hash = codebase
            .add_term(Some("base".to_string()), base_expr, Type::Int)
            .unwrap();

        // Add a function that depends on base
        let dependent_expr = Expr::Apply {
            func: Box::new(Expr::Ident(
                Ident("base".to_string()),
                vibe_core::Span::new(0, 4),
            )),
            args: vec![],
            span: vibe_core::Span::new(0, 6),
        };
        let dependent_hash = codebase
            .add_term(Some("dependent".to_string()), dependent_expr, Type::Int)
            .unwrap();

        // Check dependencies
        let deps = codebase.get_all_dependencies(&dependent_hash).unwrap();
        assert_eq!(deps.len(), 1);
        assert_eq!(deps[0], base_hash);
    }

    #[test]
    fn test_edit_command() {
        let mut codebase = Codebase::new();

        // Add a simple function
        let expr = Expr::Lambda {
            params: vec![(Ident("x".to_string()), Some(Type::Int))],
            body: Box::new(Expr::Ident(
                Ident("x".to_string()),
                vibe_core::Span::new(0, 1),
            )),
            span: vibe_core::Span::new(0, 10),
        };
        codebase
            .add_term(
                Some("identity".to_string()),
                expr,
                Type::Function(Box::new(Type::Int), Box::new(Type::Int)),
            )
            .unwrap();

        // Test edit
        let edited = codebase.edit("identity").unwrap();
        assert!(!edited.is_empty()); // Just check that it returns something
    }

    #[test]
    fn test_update_term() {
        let mut codebase = Codebase::new();

        // Add initial term
        let expr1 = Expr::Literal(vibe_core::Literal::Int(42), vibe_core::Span::new(0, 2));
        codebase
            .add_term(Some("x".to_string()), expr1, Type::Int)
            .unwrap();

        // Update it
        let new_expr_str = "100";
        let result = codebase.update("x", new_expr_str);
        assert!(result.is_ok());

        // Verify update
        let term = codebase.get_term_by_name("x").unwrap();
        match &term.expr {
            Expr::Literal(vibe_core::Literal::Int(n), _) => assert_eq!(*n, 100),
            _ => panic!("Expected int literal"),
        }
    }

    #[test]
    fn test_remove_term() {
        let mut codebase = Codebase::new();

        // Add a term
        let expr = Expr::Literal(vibe_core::Literal::Int(42), vibe_core::Span::new(0, 2));
        let hash = codebase
            .add_term(Some("x".to_string()), expr, Type::Int)
            .unwrap();

        // Remove it
        assert!(codebase.remove_term(&hash).is_ok());
        assert!(codebase.get_term_by_name("x").is_none());
    }

    #[test]
    fn test_remove_term_with_dependents() {
        let mut codebase = Codebase::new();

        // Add base term
        let base_expr = Expr::Literal(vibe_core::Literal::Int(10), vibe_core::Span::new(0, 2));
        let base_hash = codebase
            .add_term(Some("base".to_string()), base_expr, Type::Int)
            .unwrap();

        // Add dependent term
        let dependent_expr = Expr::Ident(Ident("base".to_string()), vibe_core::Span::new(0, 4));
        codebase
            .add_term(Some("dependent".to_string()), dependent_expr, Type::Int)
            .unwrap();

        // Try to remove base (should fail)
        assert!(codebase.remove_term(&base_hash).is_err());
    }

    #[test]
    fn test_complex_dependencies() {
        let mut codebase = Codebase::new();

        // Create a chain of dependencies: a -> b -> c
        let a_expr = Expr::Literal(vibe_core::Literal::Int(1), vibe_core::Span::new(0, 1));
        codebase
            .add_term(Some("a".to_string()), a_expr, Type::Int)
            .unwrap();

        let b_expr = Expr::Apply {
            func: Box::new(Expr::Ident(
                Ident("a".to_string()),
                vibe_core::Span::new(0, 1),
            )),
            args: vec![],
            span: vibe_core::Span::new(0, 3),
        };
        codebase
            .add_term(Some("b".to_string()), b_expr, Type::Int)
            .unwrap();

        let c_expr = Expr::Apply {
            func: Box::new(Expr::Ident(
                Ident("b".to_string()),
                vibe_core::Span::new(0, 1),
            )),
            args: vec![],
            span: vibe_core::Span::new(0, 3),
        };
        let c_hash = codebase
            .add_term(Some("c".to_string()), c_expr, Type::Int)
            .unwrap();

        // Get all dependencies of c
        let deps = codebase.get_all_dependencies(&c_hash).unwrap();
        assert_eq!(deps.len(), 2); // Should include both a and b
    }

    #[test]
    fn test_patch_complex_operations() {
        let mut codebase = Codebase::new();

        // Add initial terms
        let expr1 = Expr::Literal(vibe_core::Literal::Int(1), vibe_core::Span::new(0, 1));
        let hash1 = codebase
            .add_term(Some("x".to_string()), expr1.clone(), Type::Int)
            .unwrap();

        let expr2 = Expr::Literal(vibe_core::Literal::Int(2), vibe_core::Span::new(0, 1));
        codebase
            .add_term(Some("y".to_string()), expr2.clone(), Type::Int)
            .unwrap();

        // Create a complex patch
        let mut patch = Patch::new();
        patch.remove_term(hash1);
        patch.add_term(Some("z".to_string()), expr1, Type::Int);
        patch.update_term("y".to_string(), "3".to_string());

        // Apply patch
        assert!(patch.apply(&mut codebase).is_ok());

        // Verify results
        assert!(codebase.get_term_by_name("x").is_none());
        assert!(codebase.get_term_by_name("z").is_some());

        let y_term = codebase.get_term_by_name("y").unwrap();
        match &y_term.expr {
            Expr::Literal(vibe_core::Literal::Int(n), _) => assert_eq!(*n, 3),
            _ => panic!("Expected int literal"),
        }
    }

    #[test]
    fn test_serialization() {
        let mut codebase = Codebase::new();

        // Add some terms
        let expr1 = Expr::Literal(vibe_core::Literal::Int(42), vibe_core::Span::new(0, 2));
        codebase
            .add_term(Some("x".to_string()), expr1, Type::Int)
            .unwrap();

        let expr2 = Expr::Lambda {
            params: vec![(Ident("y".to_string()), Some(Type::Int))],
            body: Box::new(Expr::Ident(
                Ident("y".to_string()),
                vibe_core::Span::new(0, 1),
            )),
            span: vibe_core::Span::new(0, 10),
        };
        codebase
            .add_term(
                Some("id".to_string()),
                expr2,
                Type::Function(Box::new(Type::Int), Box::new(Type::Int)),
            )
            .unwrap();

        // Serialize and deserialize
        let serialized = bincode::serialize(&codebase).unwrap();
        let deserialized: Codebase = bincode::deserialize(&serialized).unwrap();

        // Verify
        assert!(deserialized.get_term_by_name("x").is_some());
        assert!(deserialized.get_term_by_name("id").is_some());
    }

    #[test]
    fn test_hash_invalid_hex() {
        let result = Hash::from_hex("invalid");
        assert!(result.is_err());

        let result2 = Hash::from_hex("abcd"); // Too short
        assert!(result2.is_err());
    }

    #[test]
    fn test_extract_deps_from_patterns() {
        let mut codebase = Codebase::new();

        // Add a base term
        let base_expr = Expr::Literal(vibe_core::Literal::Int(10), vibe_core::Span::new(0, 2));
        codebase
            .add_term(Some("base".to_string()), base_expr, Type::Int)
            .unwrap();

        // Create a match expression that uses base
        let match_expr = Expr::Match {
            expr: Box::new(Expr::Ident(
                Ident("base".to_string()),
                vibe_core::Span::new(0, 4),
            )),
            cases: vec![(
                Pattern::Literal(vibe_core::Literal::Int(10), vibe_core::Span::new(0, 2)),
                Expr::Literal(vibe_core::Literal::Bool(true), vibe_core::Span::new(0, 4)),
            )],
            span: vibe_core::Span::new(0, 20),
        };

        let deps = codebase.extract_dependencies(&match_expr);
        assert_eq!(deps.len(), 1);
    }
}
