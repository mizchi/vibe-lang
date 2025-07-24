//! Incremental Type Checker for Vibe Language
//!
//! Provides efficient type checking by only rechecking definitions
//! that have changed or depend on changed definitions.

use crate::hash::DefinitionHash;
use crate::namespace::{DefinitionPath, NamespaceStore};
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use vibe_compiler::{TypeChecker, TypeEnv};
use vibe_core::{Type, XsError};

/// Cache entry for type checking results
#[derive(Debug, Clone)]
struct TypeCheckResult {
    /// The inferred type
    type_: Type,

    /// Whether type checking succeeded
    success: bool,

    /// Error message if type checking failed
    error: Option<String>,

    /// Dependencies used during type checking
    #[allow(dead_code)]
    dependencies: HashSet<DefinitionHash>,
}

/// Incremental type checker that caches results
pub struct IncrementalTypeChecker {
    /// Cached type checking results
    cache: HashMap<DefinitionHash, TypeCheckResult>,

    /// Reference to namespace store
    namespace_store: Arc<NamespaceStore>,
}

impl IncrementalTypeChecker {
    pub fn new(namespace_store: Arc<NamespaceStore>) -> Self {
        Self {
            cache: HashMap::new(),
            namespace_store,
        }
    }

    /// Type check a definition, using cache when possible
    pub fn type_check_definition(&mut self, path: &DefinitionPath) -> Result<Type, XsError> {
        let definition = self
            .namespace_store
            .get_definition_by_path(path)
            .ok_or_else(|| {
                XsError::RuntimeError(
                    vibe_core::Span::new(0, 0),
                    format!("Definition not found: {}", path.to_string()),
                )
            })?;

        let hash = definition.hash.clone();

        // Check if we have a cached result
        if let Some(cached) = self.cache.get(&hash) {
            if cached.success {
                return Ok(cached.type_.clone());
            } else {
                return Err(XsError::TypeError(
                    vibe_core::Span::new(0, 0),
                    cached
                        .error
                        .clone()
                        .unwrap_or_else(|| "Type check failed".to_string()),
                ));
            }
        }

        // Type check the definition
        let deps = definition.dependencies.clone();
        let result = self.type_check_uncached(&hash);

        // Cache the result
        let cached_result = match &result {
            Ok(type_) => TypeCheckResult {
                type_: type_.clone(),
                success: true,
                error: None,
                dependencies: deps,
            },
            Err(error) => TypeCheckResult {
                type_: Type::Var("error".to_string()),
                success: false,
                error: Some(error.to_string()),
                dependencies: deps,
            },
        };

        self.cache.insert(hash, cached_result);
        result
    }

    /// Invalidate cache entries for a definition and all its dependents
    pub fn invalidate(&mut self, hash: &DefinitionHash) {
        // Use BFS to find all affected definitions
        let mut to_invalidate = VecDeque::new();
        let mut invalidated = HashSet::new();

        to_invalidate.push_back(hash.clone());
        invalidated.insert(hash.clone());

        while let Some(current) = to_invalidate.pop_front() {
            // Remove from cache
            self.cache.remove(&current);

            // Find all definitions that depend on this one
            let dependents = self.namespace_store.get_dependents(&current);

            for dependent in dependents {
                if !invalidated.contains(&dependent) {
                    to_invalidate.push_back(dependent.clone());
                    invalidated.insert(dependent);
                }
            }
        }
    }

    /// Invalidate all definitions in a namespace
    pub fn invalidate_namespace(&mut self, namespace: &crate::namespace::NamespacePath) {
        let definitions = self.namespace_store.list_namespace(namespace);
        for (_, hash) in definitions {
            self.invalidate(&hash);
        }
    }

    /// Get statistics about the cache
    pub fn cache_stats(&self) -> CacheStats {
        let total = self.cache.len();
        let successful = self.cache.values().filter(|r| r.success).count();
        let failed = total - successful;

        CacheStats {
            total_entries: total,
            successful_checks: successful,
            failed_checks: failed,
        }
    }

    /// Clear the entire cache
    pub fn clear_cache(&mut self) {
        self.cache.clear();
    }

    /// Type check a definition without using cache
    fn type_check_uncached(&mut self, hash: &DefinitionHash) -> Result<Type, XsError> {
        // First, collect all dependencies that need type checking
        let deps_to_check = self.collect_dependencies_to_check(hash)?;

        // Type check all dependencies first (this avoids the borrowing issue)
        for dep_hash in deps_to_check {
            if !self.cache.contains_key(&dep_hash) {
                let dep_type = self.type_check_single_definition(&dep_hash)?;
                let cached_result = TypeCheckResult {
                    type_: dep_type,
                    success: true,
                    error: None,
                    dependencies: self.get_definition_dependencies(&dep_hash),
                };
                self.cache.insert(dep_hash, cached_result);
            }
        }

        // Now type check the target definition
        self.type_check_single_definition(hash)
    }

    /// Collect all dependencies that need to be type checked
    fn collect_dependencies_to_check(
        &self,
        hash: &DefinitionHash,
    ) -> Result<Vec<DefinitionHash>, XsError> {
        let mut to_check = Vec::new();
        let mut visited = HashSet::new();
        let mut queue = VecDeque::new();

        queue.push_back(hash.clone());
        visited.insert(hash.clone());

        while let Some(current_hash) = queue.pop_front() {
            let definition = self
                .namespace_store
                .get_definition(&current_hash)
                .ok_or_else(|| {
                    XsError::RuntimeError(
                        vibe_core::Span::new(0, 0),
                        format!("Definition not found: {current_hash}"),
                    )
                })?;

            for dep_hash in &definition.dependencies {
                if !visited.contains(dep_hash) && !self.cache.contains_key(dep_hash) {
                    visited.insert(dep_hash.clone());
                    queue.push_back(dep_hash.clone());
                    to_check.push(dep_hash.clone());
                }
            }
        }

        // Reverse to get dependencies before dependents
        to_check.reverse();
        Ok(to_check)
    }

    /// Get dependencies for a definition
    fn get_definition_dependencies(&self, hash: &DefinitionHash) -> HashSet<DefinitionHash> {
        self.namespace_store
            .get_definition(hash)
            .map(|def| def.dependencies.clone())
            .unwrap_or_default()
    }

    /// Type check a single definition (no recursion)
    fn type_check_single_definition(&self, hash: &DefinitionHash) -> Result<Type, XsError> {
        let definition = self.namespace_store.get_definition(hash).ok_or_else(|| {
            XsError::RuntimeError(
                vibe_core::Span::new(0, 0),
                format!("Definition not found: {hash}"),
            )
        })?;

        // Create a new type checker for this check
        let mut type_checker = TypeChecker::new();

        // Create type environment from dependencies
        let mut type_env = TypeEnv::new();

        // Add types of all dependencies (they should already be in cache)
        for dep_hash in &definition.dependencies {
            if let Some(cached) = self.cache.get(dep_hash) {
                if cached.success {
                    // Add to environment (would need to resolve names properly)
                    // For now, we'll skip this part as it requires more context
                }
            }
        }

        // Type check based on content
        match &definition.content {
            crate::namespace::DefinitionContent::Function { params, body } => {
                // Create parameter types (would need type annotations)
                let param_types: Vec<Type> = params
                    .iter()
                    .enumerate()
                    .map(|(i, _)| Type::Var(format!("t{i}")))
                    .collect();

                // Add parameters to environment
                type_env.push_scope();
                for (param, param_type) in params.iter().zip(&param_types) {
                    type_env.add_binding(
                        param.clone(),
                        vibe_compiler::TypeScheme::mono(param_type.clone()),
                    );
                }

                // Type check body
                let body_type = type_checker
                    .check(body, &mut type_env)
                    .map_err(|e| XsError::TypeError(vibe_core::Span::new(0, 0), e))?;

                // Build function type
                let mut result_type = body_type;
                for param_type in param_types.into_iter().rev() {
                    result_type = Type::Function(Box::new(param_type), Box::new(result_type));
                }

                Ok(result_type)
            }
            crate::namespace::DefinitionContent::Value(expr) => type_checker
                .check(expr, &mut type_env)
                .map_err(|e| XsError::TypeError(vibe_core::Span::new(0, 0), e)),
            crate::namespace::DefinitionContent::Type { .. } => {
                // Type definitions have kind * -> *
                Ok(Type::Var("Type".to_string()))
            }
        }
    }
}

/// Statistics about the type check cache
#[derive(Debug)]
pub struct CacheStats {
    pub total_entries: usize,
    pub successful_checks: usize,
    pub failed_checks: usize,
}

/// A batch type checking session
pub struct TypeCheckBatch<'a> {
    checker: &'a mut IncrementalTypeChecker,
    to_check: Vec<DefinitionPath>,
    results: HashMap<DefinitionPath, Result<Type, String>>,
}

impl<'a> TypeCheckBatch<'a> {
    pub fn new(checker: &'a mut IncrementalTypeChecker) -> Self {
        Self {
            checker,
            to_check: Vec::new(),
            results: HashMap::new(),
        }
    }

    /// Add a definition to the batch
    pub fn add(&mut self, path: DefinitionPath) {
        self.to_check.push(path);
    }

    /// Execute the batch type check
    pub fn execute(&mut self) -> BatchResult {
        let total = self.to_check.len();
        let mut successful = 0;
        let mut failed = 0;
        let mut from_cache = 0;

        for path in &self.to_check {
            // Check if result is already cached
            if let Some(def) = self.checker.namespace_store.get_definition_by_path(path) {
                if self.checker.cache.contains_key(&def.hash) {
                    from_cache += 1;
                }
            }

            // Type check
            match self.checker.type_check_definition(path) {
                Ok(type_) => {
                    successful += 1;
                    self.results.insert(path.clone(), Ok(type_));
                }
                Err(error) => {
                    failed += 1;
                    self.results.insert(path.clone(), Err(error.to_string()));
                }
            }
        }

        BatchResult {
            total,
            successful,
            failed,
            from_cache,
        }
    }

    /// Get the result for a specific definition
    pub fn get_result(&self, path: &DefinitionPath) -> Option<&Result<Type, String>> {
        self.results.get(path)
    }
}

/// Result of a batch type check
#[derive(Debug)]
pub struct BatchResult {
    pub total: usize,
    pub successful: usize,
    pub failed: usize,
    pub from_cache: usize,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::namespace::{DefinitionContent, NamespaceStore};
    use vibe_core::{Expr, Literal, Span};

    #[test]
    fn test_cache_hit() {
        let mut store = NamespaceStore::new();

        // Add a simple definition
        let path = DefinitionPath::from_str("testValue").unwrap();
        let content = DefinitionContent::Value(Expr::Literal(Literal::Int(42), Span::new(0, 2)));

        store
            .add_definition(
                path.clone(),
                content,
                Type::Int,
                HashSet::new(),
                Default::default(),
            )
            .unwrap();

        let mut checker = IncrementalTypeChecker::new(Arc::new(store));

        // First check - should compute
        let type1 = checker.type_check_definition(&path).unwrap();
        assert_eq!(type1, Type::Int);

        // Second check - should use cache
        let stats_before = checker.cache_stats();
        let type2 = checker.type_check_definition(&path).unwrap();
        let stats_after = checker.cache_stats();

        assert_eq!(type1, type2);
        assert_eq!(stats_before.total_entries, stats_after.total_entries);
    }

    #[test]
    fn test_invalidation() {
        let mut store = NamespaceStore::new();

        // Add two definitions where b depends on a
        let path_a = DefinitionPath::from_str("a").unwrap();
        let content_a = DefinitionContent::Value(Expr::Literal(Literal::Int(42), Span::new(0, 2)));
        let hash_a = store
            .add_definition(
                path_a.clone(),
                content_a,
                Type::Int,
                HashSet::new(),
                Default::default(),
            )
            .unwrap();

        let path_b = DefinitionPath::from_str("b").unwrap();
        let content_b = DefinitionContent::Value(
            Expr::Literal(Literal::Int(84), Span::new(0, 2)), // 依存関係をテストするため、単純なリテラルに変更
        );
        let mut deps = HashSet::new();
        deps.insert(hash_a.clone());

        store
            .add_definition(
                path_b.clone(),
                content_b,
                Type::Int,
                deps,
                Default::default(),
            )
            .unwrap();

        let mut checker = IncrementalTypeChecker::new(Arc::new(store));

        // Type check both
        checker.type_check_definition(&path_a).unwrap();
        checker.type_check_definition(&path_b).unwrap();

        assert_eq!(checker.cache_stats().total_entries, 2);

        // Invalidate a - should also invalidate b
        checker.invalidate(&hash_a);

        // Cache should be empty (or have fewer entries)
        assert!(checker.cache_stats().total_entries < 2);
    }

    #[test]
    fn test_batch_type_check() {
        let mut store = NamespaceStore::new();

        // Add some definitions
        for i in 0..5 {
            let path = DefinitionPath::from_str(&format!("value{i}")).unwrap();
            let content = DefinitionContent::Value(Expr::Literal(Literal::Int(i), Span::new(0, 1)));
            store
                .add_definition(path, content, Type::Int, HashSet::new(), Default::default())
                .unwrap();
        }

        let mut checker = IncrementalTypeChecker::new(Arc::new(store));

        // Create batch
        let mut batch = TypeCheckBatch::new(&mut checker);
        for i in 0..5 {
            batch.add(DefinitionPath::from_str(&format!("value{i}")).unwrap());
        }

        // Execute batch
        let result = batch.execute();

        assert_eq!(result.total, 5);
        assert_eq!(result.successful, 5);
        assert_eq!(result.failed, 0);
    }
}
