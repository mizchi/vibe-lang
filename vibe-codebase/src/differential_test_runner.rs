//! Differential Test Runner for Vibe Language
//!
//! Runs tests only for code that has changed or depends on changed code.
//! Integrates with the incremental type checker and test cache.

use crate::hash::DefinitionHash;
use crate::incremental_type_checker::IncrementalTypeChecker;
use crate::namespace::{DefinitionContent, DefinitionPath, NamespacePath, NamespaceStore};
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use vibe_language::{Expr, Value, XsError};

/// Test outcome
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TestOutcome {
    Pass,
    Fail,
}

/// Test result for differential testing
#[derive(Debug, Clone)]
pub struct TestResult {
    pub outcome: TestOutcome,
    pub output: String,
    pub duration: std::time::Duration,
    pub dependencies: HashSet<DefinitionHash>,
}

/// Test specification
#[derive(Debug, Clone)]
pub struct TestSpec {
    /// Name of the test
    pub name: String,

    /// Path to the test definition
    pub path: DefinitionPath,

    /// Hash of the test definition
    pub hash: DefinitionHash,

    /// Dependencies of the test
    pub dependencies: HashSet<DefinitionHash>,
}

/// Differential test runner
pub struct DifferentialTestRunner {
    /// Reference to namespace store
    namespace_store: Arc<NamespaceStore>,

    /// Incremental type checker
    type_checker: IncrementalTypeChecker,

    /// Tests that have been discovered
    discovered_tests: HashMap<DefinitionHash, TestSpec>,
}

impl DifferentialTestRunner {
    pub fn new(namespace_store: Arc<NamespaceStore>) -> Self {
        let type_checker = IncrementalTypeChecker::new(namespace_store.clone());

        Self {
            namespace_store,
            type_checker,
            discovered_tests: HashMap::new(),
        }
    }

    /// Discover all tests in the namespace
    pub fn discover_tests(&mut self) -> Result<Vec<TestSpec>, XsError> {
        let mut tests = Vec::new();

        // Find all definitions that look like tests
        // We need to iterate through all namespaces
        let root = NamespacePath::root();
        self.discover_tests_in_namespace(&root, &mut tests)?;

        Ok(tests)
    }

    /// Recursively discover tests in a namespace
    fn discover_tests_in_namespace(
        &mut self,
        namespace: &NamespacePath,
        tests: &mut Vec<TestSpec>,
    ) -> Result<(), XsError> {
        // Get all definitions in this namespace
        for (name, hash) in self.namespace_store.list_namespace(namespace) {
            let path = DefinitionPath::new(namespace.clone(), name);
            if self.is_test_definition(&path) {
                if let Some(def) = self.namespace_store.get_definition(&hash) {
                    let spec = TestSpec {
                        name: path.name.clone(),
                        path: path.clone(),
                        hash: hash.clone(),
                        dependencies: def.dependencies.clone(),
                    };
                    tests.push(spec.clone());
                    self.discovered_tests.insert(hash, spec);
                }
            }
        }

        // Recurse into sub-namespaces
        for sub_ns in self.namespace_store.list_subnamespaces(namespace) {
            let sub_path = namespace.child(&sub_ns);
            self.discover_tests_in_namespace(&sub_path, tests)?;
        }

        Ok(())
    }

    /// Check if a definition path represents a test
    fn is_test_definition(&self, path: &DefinitionPath) -> bool {
        // Check if name starts with "test"
        if path.name.starts_with("test") {
            return true;
        }

        // Check if in a "tests" namespace
        path.namespace.0.iter().any(|part| part == "tests")
    }

    /// Run tests that have changed or depend on changed code
    pub fn run_differential_tests(
        &mut self,
        changed_definitions: &[DefinitionHash],
    ) -> DifferentialTestResult {
        // Find all affected tests
        let affected_tests = self.find_affected_tests(changed_definitions);

        // Invalidate cache for affected definitions
        for hash in changed_definitions {
            self.type_checker.invalidate(hash);
        }

        // Run affected tests
        let mut results = HashMap::new();
        let mut total_tests = 0;
        let mut passed_tests = 0;
        let mut failed_tests = 0;
        let from_cache = 0;

        for test_hash in &affected_tests {
            total_tests += 1;

            // Check if we have a cached result (simplified for now)
            // TODO: Integrate with actual test cache API

            // Run the test
            match self.run_single_test(test_hash) {
                Ok(result) => {
                    match result.outcome {
                        TestOutcome::Pass => passed_tests += 1,
                        TestOutcome::Fail => failed_tests += 1,
                    }

                    // TODO: Cache the result

                    results.insert(test_hash.clone(), result);
                }
                Err(e) => {
                    failed_tests += 1;
                    let result = TestResult {
                        outcome: TestOutcome::Fail,
                        output: format!("Test execution error: {e}"),
                        duration: std::time::Duration::from_secs(0),
                        dependencies: HashSet::new(),
                    };
                    results.insert(test_hash.clone(), result);
                }
            }
        }

        DifferentialTestResult {
            total_tests,
            passed_tests,
            failed_tests,
            from_cache,
            affected_tests: affected_tests.len(),
            results,
        }
    }

    /// Find all tests affected by changed definitions
    fn find_affected_tests(&self, changed_definitions: &[DefinitionHash]) -> Vec<DefinitionHash> {
        let mut affected = HashSet::new();
        let mut queue = VecDeque::new();

        // Start with changed definitions
        for hash in changed_definitions {
            queue.push_back(hash.clone());
            affected.insert(hash.clone());
        }

        // Find all dependents
        while let Some(current) = queue.pop_front() {
            let dependents = self.namespace_store.get_dependents(&current);
            for dependent in dependents {
                if !affected.contains(&dependent) {
                    affected.insert(dependent.clone());
                    queue.push_back(dependent);
                }
            }
        }

        // Filter to only include tests
        affected
            .into_iter()
            .filter(|hash| self.discovered_tests.contains_key(hash))
            .collect()
    }

    /// Run a single test
    fn run_single_test(&mut self, test_hash: &DefinitionHash) -> Result<TestResult, XsError> {
        let start_time = std::time::Instant::now();

        // Get test definition
        let test_def = self
            .namespace_store
            .get_definition(test_hash)
            .ok_or_else(|| {
                XsError::RuntimeError(
                    vibe_language::Span::new(0, 0),
                    format!("Test definition not found: {test_hash}"),
                )
            })?;

        // Type check the test first
        if let Some(test_spec) = self.discovered_tests.get(test_hash) {
            self.type_checker.type_check_definition(&test_spec.path)?;
        }

        // Extract test expression
        let test_expr = match &test_def.content {
            DefinitionContent::Function { body, .. } => body.clone(),
            DefinitionContent::Value(expr) => expr.clone(),
            _ => {
                return Err(XsError::RuntimeError(
                    vibe_language::Span::new(0, 0),
                    "Test must be a function or value".to_string(),
                ))
            }
        };

        // Run the test
        let outcome = match self.execute_test_expr(&test_expr) {
            Ok(true) => TestOutcome::Pass,
            Ok(false) => TestOutcome::Fail,
            Err(e) => {
                return Ok(TestResult {
                    outcome: TestOutcome::Fail,
                    output: format!("Test execution error: {e}"),
                    duration: start_time.elapsed(),
                    dependencies: test_def.dependencies.clone(),
                });
            }
        };

        Ok(TestResult {
            outcome,
            output: if outcome == TestOutcome::Pass {
                "Test passed".to_string()
            } else {
                "Test failed: assertion returned false".to_string()
            },
            duration: start_time.elapsed(),
            dependencies: test_def.dependencies.clone(),
        })
    }

    /// Execute a test expression and return whether it passed
    fn execute_test_expr(&self, expr: &Expr) -> Result<bool, XsError> {
        // Evaluate the expression
        let value = vibe_runtime::eval(expr)?;

        // Test passes if it returns true
        match value {
            Value::Bool(b) => Ok(b),
            _ => Err(XsError::RuntimeError(
                vibe_language::Span::new(0, 0),
                format!("Test must return a boolean value, got: {value:?}"),
            )),
        }
    }

    /// Get test statistics
    pub fn get_stats(&self) -> TestStats {
        TestStats {
            total_discovered: self.discovered_tests.len(),
            cache_size: 0, // TODO: Integrate with actual test cache
        }
    }
}

/// Result of differential test execution
#[derive(Debug)]
pub struct DifferentialTestResult {
    pub total_tests: usize,
    pub passed_tests: usize,
    pub failed_tests: usize,
    pub from_cache: usize,
    pub affected_tests: usize,
    pub results: HashMap<DefinitionHash, TestResult>,
}

impl DifferentialTestResult {
    /// Get a summary of the test results
    pub fn summary(&self) -> String {
        format!(
            "Differential Test Results:\n\
             Total affected tests: {}\n\
             Passed: {} ({} from cache)\n\
             Failed: {}\n\
             Cache hit rate: {:.1}%",
            self.affected_tests,
            self.passed_tests,
            self.from_cache,
            self.failed_tests,
            if self.total_tests > 0 {
                (self.from_cache as f64 / self.total_tests as f64) * 100.0
            } else {
                0.0
            }
        )
    }
}

/// Test statistics
#[derive(Debug)]
pub struct TestStats {
    pub total_discovered: usize,
    pub cache_size: usize,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::namespace::NamespaceStore;
    use vibe_language::{Literal, Span};

    #[test]
    fn test_discover_tests() {
        let mut store = NamespaceStore::new();

        // Add some test definitions
        let test_path = DefinitionPath::from_str("testAdd").unwrap();
        let test_content =
            DefinitionContent::Value(Expr::Literal(Literal::Bool(true), Span::new(0, 4)));
        store
            .add_definition(
                test_path,
                test_content,
                vibe_language::Type::Bool,
                HashSet::new(),
                Default::default(),
            )
            .unwrap();

        // Add a non-test definition
        let other_path = DefinitionPath::from_str("helper").unwrap();
        let other_content =
            DefinitionContent::Value(Expr::Literal(Literal::Int(42), Span::new(0, 2)));
        store
            .add_definition(
                other_path,
                other_content,
                vibe_language::Type::Int,
                HashSet::new(),
                Default::default(),
            )
            .unwrap();

        let mut runner = DifferentialTestRunner::new(Arc::new(store));

        let tests = runner.discover_tests().unwrap();

        // Should find only the test definition
        assert_eq!(tests.len(), 1);
        assert_eq!(tests[0].name, "testAdd");
    }

    #[test]
    fn test_differential_run() {
        let mut store = NamespaceStore::new();

        // Add a helper function
        let helper_path = DefinitionPath::from_str("helper").unwrap();
        let helper_content =
            DefinitionContent::Value(Expr::Literal(Literal::Int(42), Span::new(0, 2)));
        let helper_hash = store
            .add_definition(
                helper_path,
                helper_content,
                vibe_language::Type::Int,
                HashSet::new(),
                Default::default(),
            )
            .unwrap();

        // Add a test that depends on the helper
        let test_path = DefinitionPath::from_str("testHelper").unwrap();
        let test_content =
            DefinitionContent::Value(Expr::Literal(Literal::Bool(true), Span::new(0, 4)));
        let mut deps = HashSet::new();
        deps.insert(helper_hash.clone());

        store
            .add_definition(
                test_path,
                test_content,
                vibe_language::Type::Bool,
                deps,
                Default::default(),
            )
            .unwrap();

        let mut runner = DifferentialTestRunner::new(Arc::new(store));

        // Discover tests
        runner.discover_tests().unwrap();

        // Run tests affected by helper change
        let result = runner.run_differential_tests(&[helper_hash]);

        // Should run the test that depends on helper
        assert_eq!(result.affected_tests, 1);
        assert_eq!(result.passed_tests, 1);
        assert_eq!(result.failed_tests, 0);
    }
}
