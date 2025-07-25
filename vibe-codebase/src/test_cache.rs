//! Unison-style test result caching system
//!
//! This module implements a content-addressed cache for test results,
//! where test expressions and their results are stored by hash.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::time::{Duration, SystemTime};

use crate::Hash;
use vibe_core::Expr;

/// Test result with metadata
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestResult {
    /// The test expression hash
    pub test_hash: Hash,
    /// The result of evaluating the test
    pub result: TestOutcome,
    /// When the test was last run
    pub timestamp: SystemTime,
    /// How long the test took to run
    pub duration: Duration,
    /// Dependencies of the test (function hashes)
    pub dependencies: Vec<Hash>,
}

/// Outcome of running a test
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum TestOutcome {
    /// Test passed with expected value
    Passed { value: String },
    /// Test failed with error
    Failed { error: String },
    /// Test timed out
    Timeout,
    /// Test was skipped
    Skipped { reason: String },
}

/// Cache for test results
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestCache {
    /// Map from test expression hash to test result
    results: HashMap<Hash, TestResult>,
    /// Map from dependency hash to tests that depend on it
    dependency_index: HashMap<Hash, Vec<Hash>>,
}

#[allow(clippy::derivable_impls)]
impl Default for TestCache {
    fn default() -> Self {
        TestCache {
            results: HashMap::new(),
            dependency_index: HashMap::new(),
        }
    }
}

impl TestCache {
    pub fn new<P: AsRef<std::path::Path>>(_path: P) -> std::io::Result<Self> {
        // TODO: Load from disk if exists
        Ok(TestCache {
            results: HashMap::new(),
            dependency_index: HashMap::new(),
        })
    }

    /// Check if we have a cached result for this test
    pub fn get_cached_result(
        &self,
        test_expr: &Expr,
        dependencies: &[Hash],
    ) -> Option<&TestResult> {
        let test_hash = Self::hash_test(test_expr, dependencies);
        self.results.get(&test_hash)
    }

    /// Store a test result in the cache
    pub fn cache_result(
        &mut self,
        test_expr: &Expr,
        dependencies: Vec<Hash>,
        result: TestOutcome,
        duration: Duration,
    ) -> Hash {
        let test_hash = Self::hash_test(test_expr, &dependencies);

        // Update dependency index
        for dep in &dependencies {
            self.dependency_index
                .entry(dep.clone())
                .or_default()
                .push(test_hash.clone());
        }

        let test_result = TestResult {
            test_hash: test_hash.clone(),
            result,
            timestamp: SystemTime::now(),
            duration,
            dependencies,
        };

        self.results.insert(test_hash.clone(), test_result);
        test_hash
    }

    /// Invalidate all tests that depend on a given function
    pub fn invalidate_dependents(&mut self, function_hash: &Hash) {
        if let Some(dependent_tests) = self.dependency_index.get(function_hash).cloned() {
            for test_hash in dependent_tests {
                self.results.remove(&test_hash);
                // Also remove from dependency index
                for deps in self.dependency_index.values_mut() {
                    deps.retain(|h| h != &test_hash);
                }
            }
            self.dependency_index.remove(function_hash);
        }
    }

    /// Get all test results
    pub fn all_results(&self) -> Vec<&TestResult> {
        self.results.values().collect()
    }

    /// Get test results that match a predicate
    pub fn filter_results<F>(&self, predicate: F) -> Vec<&TestResult>
    where
        F: Fn(&TestResult) -> bool,
    {
        self.results.values().filter(|r| predicate(r)).collect()
    }

    /// Clear all cached results
    pub fn clear(&mut self) {
        self.results.clear();
        self.dependency_index.clear();
    }

    /// Hash a test expression with its dependencies
    fn hash_test(expr: &Expr, dependencies: &[Hash]) -> Hash {
        let mut hasher = Sha256::new();

        // Hash the expression
        hasher.update(format!("{expr:?}").as_bytes());

        // Include dependencies in the hash
        for dep in dependencies {
            hasher.update(dep.0);
        }

        let result = hasher.finalize();
        let mut hash = [0u8; 32];
        hash.copy_from_slice(&result);
        Hash(hash)
    }
}

/// Test runner that uses the cache
pub struct CachedTestRunner<'a> {
    cache: &'a mut TestCache,
    codebase: &'a crate::Codebase,
}

impl<'a> CachedTestRunner<'a> {
    pub fn new(cache: &'a mut TestCache, codebase: &'a crate::Codebase) -> Self {
        CachedTestRunner { cache, codebase }
    }

    /// Run a test, using cached result if available
    pub fn run_test<F>(&mut self, test_expr: &Expr, executor: F) -> TestResult
    where
        F: FnOnce(&Expr) -> Result<String, String>,
    {
        // Extract dependencies from the test expression
        let dependencies = self.extract_test_dependencies(test_expr);

        // Check cache first
        if let Some(cached) = self.cache.get_cached_result(test_expr, &dependencies) {
            // Verify dependencies haven't changed
            if self.verify_dependencies(&cached.dependencies) {
                return cached.clone();
            }
        }

        // Run the test
        let start_time = SystemTime::now();
        let result = self.execute_test(test_expr, executor);
        let duration = start_time.elapsed().unwrap_or(Duration::from_secs(0));

        // Cache the result
        let test_hash =
            self.cache
                .cache_result(test_expr, dependencies.clone(), result.clone(), duration);

        TestResult {
            test_hash,
            result,
            timestamp: SystemTime::now(),
            duration,
            dependencies,
        }
    }

    /// Extract function dependencies from a test expression
    fn extract_test_dependencies(&self, expr: &Expr) -> Vec<Hash> {
        let mut deps = Vec::new();
        self.extract_deps_recursive(expr, &mut deps);
        // Sort and dedup by converting to/from hex strings
        let mut hex_deps: Vec<String> = deps.iter().map(|h| h.to_hex()).collect();
        hex_deps.sort();
        hex_deps.dedup();
        deps.clear();
        for hex in hex_deps {
            if let Ok(hash) = Hash::from_hex(&hex) {
                deps.push(hash);
            }
        }
        deps
    }

    fn extract_deps_recursive(&self, expr: &Expr, deps: &mut Vec<Hash>) {
        match expr {
            Expr::Ident(name, _) => {
                if let Some(term) = self.codebase.get_term_by_name(&name.0) {
                    deps.push(term.hash.clone());
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
            Expr::LetIn { value, body, .. } => {
                self.extract_deps_recursive(value, deps);
                self.extract_deps_recursive(body, deps);
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
            Expr::Match { expr, cases, .. } => {
                self.extract_deps_recursive(expr, deps);
                for (_, case_expr) in cases {
                    self.extract_deps_recursive(case_expr, deps);
                }
            }
            Expr::List(items, _) => {
                for item in items {
                    self.extract_deps_recursive(item, deps);
                }
            }
            Expr::Rec { body, .. } => {
                self.extract_deps_recursive(body, deps);
            }
            _ => {}
        }
    }

    /// Verify that dependencies haven't changed
    fn verify_dependencies(&self, dependencies: &[Hash]) -> bool {
        dependencies
            .iter()
            .all(|hash| self.codebase.get_term(hash).is_some())
    }

    /// Execute a test expression
    pub fn execute_test<F>(&self, test_expr: &Expr, executor: F) -> TestOutcome
    where
        F: FnOnce(&Expr) -> Result<String, String>,
    {
        match executor(test_expr) {
            Ok(value) => TestOutcome::Passed { value },
            Err(error) => TestOutcome::Failed { error },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vibe_core::{Expr, Ident, Literal, Span};

    #[test]
    fn test_cache_basic() {
        let mut cache = TestCache::new(std::env::temp_dir().join("test_cache_test")).unwrap();
        let test_expr = Expr::Literal(Literal::Int(42), Span::new(0, 2));

        // First run - should not be cached
        assert!(cache.get_cached_result(&test_expr, &[]).is_none());

        // Cache a result
        let hash = cache.cache_result(
            &test_expr,
            vec![],
            TestOutcome::Passed {
                value: "42".to_string(),
            },
            Duration::from_millis(10),
        );

        // Should now be cached
        let cached = cache.get_cached_result(&test_expr, &[]).unwrap();
        assert_eq!(cached.test_hash, hash);
        assert_eq!(
            cached.result,
            TestOutcome::Passed {
                value: "42".to_string()
            }
        );
    }

    #[test]
    fn test_dependency_invalidation() {
        let mut cache = TestCache::new(std::env::temp_dir().join("test_cache_test")).unwrap();
        let dep_hash = Hash::new(b"dependency");
        let test_expr = Expr::Ident(Ident("test".to_string()), Span::new(0, 4));

        // Cache a result with dependency
        cache.cache_result(
            &test_expr,
            vec![dep_hash.clone()],
            TestOutcome::Passed {
                value: "ok".to_string(),
            },
            Duration::from_millis(5),
        );

        // Should be cached
        assert!(cache
            .get_cached_result(&test_expr, &[dep_hash.clone()])
            .is_some());

        // Invalidate dependency
        cache.invalidate_dependents(&dep_hash);

        // Should no longer be cached
        assert!(cache.get_cached_result(&test_expr, &[dep_hash]).is_none());
    }
}
