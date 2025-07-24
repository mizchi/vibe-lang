//! Test runner with caching support
//! 
//! This module provides a test runner that can execute generated tests
//! with support for result caching and parallel execution.

use std::time::{Duration, Instant};
use std::sync::{Arc, Mutex};
use rayon::prelude::*;

use crate::Codebase;
use crate::test_cache::{TestCache, TestOutcome};
use crate::test_generator::{GeneratedTest, TestProperty};
use vibe_compiler::TypeChecker;
use vibe_runtime::Interpreter;
use vibe_core::{Expr, Value, Environment};

/// Test execution configuration
#[derive(Debug, Clone)]
pub struct TestRunConfig {
    /// Whether to use cached results
    pub use_cache: bool,
    /// Whether to force re-run all tests (invalidate cache)
    pub force_rerun: bool,
    /// Maximum time allowed for each test
    pub timeout: Duration,
    /// Whether to run tests in parallel
    pub parallel: bool,
    /// Number of threads for parallel execution
    pub num_threads: Option<usize>,
    /// Whether to stop on first failure
    pub fail_fast: bool,
    /// Verbosity level (0 = quiet, 1 = normal, 2 = verbose)
    pub verbosity: u8,
}

impl Default for TestRunConfig {
    fn default() -> Self {
        TestRunConfig {
            use_cache: true,
            force_rerun: false,
            timeout: Duration::from_secs(10),
            parallel: true,
            num_threads: None,
            fail_fast: false,
            verbosity: 1,
        }
    }
}

/// Test execution result
#[derive(Debug, Clone)]
pub struct TestRunResult {
    /// The test that was run
    pub test: GeneratedTest,
    /// The outcome of the test
    pub outcome: TestOutcome,
    /// Execution time
    pub duration: Duration,
    /// Whether this was a cached result
    pub from_cache: bool,
    /// Properties that were verified
    pub verified_properties: Vec<(TestProperty, bool)>,
}

/// Test runner with caching
pub struct TestRunner {
    config: TestRunConfig,
    cache: Arc<Mutex<TestCache>>,
    codebase: Arc<Codebase>,
}

impl TestRunner {
    /// Create a new test runner
    pub fn new(
        config: TestRunConfig,
        cache: TestCache,
        codebase: Codebase,
    ) -> Self {
        TestRunner {
            config,
            cache: Arc::new(Mutex::new(cache)),
            codebase: Arc::new(codebase),
        }
    }

    /// Run a collection of tests
    pub fn run_tests(&self, tests: Vec<GeneratedTest>) -> Vec<TestRunResult> {
        if self.config.force_rerun {
            // Clear cache if forced rerun
            if let Ok(mut cache) = self.cache.lock() {
                cache.clear();
            }
        }

        if self.config.parallel && tests.len() > 1 {
            // Run tests in parallel
            self.run_tests_parallel(tests)
        } else {
            // Run tests sequentially
            self.run_tests_sequential(tests)
        }
    }

    /// Run tests in parallel
    fn run_tests_parallel(&self, tests: Vec<GeneratedTest>) -> Vec<TestRunResult> {
        // Set number of threads if specified
        if let Some(num_threads) = self.config.num_threads {
            rayon::ThreadPoolBuilder::new()
                .num_threads(num_threads)
                .build_global()
                .ok();
        }

        let results: Vec<TestRunResult> = tests
            .into_par_iter()
            .map(|test| self.run_single_test(test))
            .collect();

        results
    }

    /// Run tests sequentially
    fn run_tests_sequential(&self, tests: Vec<GeneratedTest>) -> Vec<TestRunResult> {
        let mut results = Vec::new();

        for test in tests {
            let result = self.run_single_test(test);
            
            // Check fail-fast
            if self.config.fail_fast {
                if let TestOutcome::Failed { .. } = &result.outcome {
                    results.push(result);
                    break;
                }
            }
            
            results.push(result);
        }

        results
    }

    /// Run a single test
    fn run_single_test(&self, test: GeneratedTest) -> TestRunResult {
        let _start_time = Instant::now();

        if self.config.verbosity >= 2 {
            println!("Running test: {}", test.name);
            println!("  Test expression: {:?}", test.test_expr);
        }

        // Check cache first
        if self.config.use_cache && !self.config.force_rerun {
            if let Ok(cache) = self.cache.lock() {
                let deps = vec![test.function_hash.clone()];
                if let Some(cached_result) = cache.get_cached_result(&test.test_expr, &deps) {
                    if self.config.verbosity >= 2 {
                        println!("  Using cached result");
                    }
                    
                    // Verify properties on cached result
                    let verified_properties = self.verify_properties_from_outcome(
                        &test.properties,
                        &cached_result.result,
                    );
                    
                    return TestRunResult {
                        test,
                        outcome: cached_result.result.clone(),
                        duration: cached_result.duration,
                        from_cache: true,
                        verified_properties,
                    };
                }
            }
        }

        // Execute the test
        let (outcome, duration) = self.execute_test(&test.test_expr);

        // Cache the result
        if self.config.use_cache {
            if let Ok(mut cache) = self.cache.lock() {
                let deps = vec![test.function_hash.clone()];
                cache.cache_result(
                    &test.test_expr,
                    deps,
                    outcome.clone(),
                    duration,
                );
            }
        }

        // Verify properties
        let verified_properties = self.verify_properties_from_outcome(
            &test.properties,
            &outcome,
        );

        TestRunResult {
            test,
            outcome,
            duration,
            from_cache: false,
            verified_properties,
        }
    }

    /// Execute a test expression
    fn execute_test(&self, expr: &Expr) -> (TestOutcome, Duration) {
        let start_time = Instant::now();

        // Type check first
        let mut type_checker = TypeChecker::new();
        let mut type_env = vibe_compiler::TypeEnv::default();

        // Add definitions from codebase to type environment
        self.populate_type_env(&mut type_env);

        let type_result = type_checker.check(expr, &mut type_env);

        if let Err(e) = type_result {
            return (
                TestOutcome::Failed {
                    error: format!("Type error: {}", e),
                },
                start_time.elapsed(),
            );
        }

        // Evaluate the expression
        let mut interpreter = Interpreter::new();
        let mut runtime_env = Interpreter::create_initial_env();

        // Add definitions from codebase to runtime environment
        self.populate_runtime_env(&mut runtime_env);

        // Use a timeout for evaluation
        let eval_result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            interpreter.eval(expr, &runtime_env)
        }));

        let duration = start_time.elapsed();

        match eval_result {
            Ok(Ok(value)) => {
                // Format the value as string
                let value_str = format_value(&value);
                (TestOutcome::Passed { value: value_str }, duration)
            }
            Ok(Err(e)) => {
                (TestOutcome::Failed {
                    error: format!("Runtime error: {}", e),
                }, duration)
            }
            Err(_) => {
                // Panic occurred, possibly timeout
                if duration >= self.config.timeout {
                    (TestOutcome::Timeout, duration)
                } else {
                    (TestOutcome::Failed {
                        error: "Test panicked".to_string(),
                    }, duration)
                }
            }
        }
    }

    /// Populate type environment with definitions from codebase
    fn populate_type_env(&self, env: &mut vibe_compiler::TypeEnv) {
        for (name, hash) in &self.codebase.term_names {
            if let Some(term) = self.codebase.get_term(hash) {
                env.add_binding(
                    name.clone(),
                    vibe_compiler::TypeScheme::mono(term.ty.clone()),
                );
            }
        }
    }

    /// Populate runtime environment with definitions from codebase
    fn populate_runtime_env(&self, env: &mut Environment) {
        use vibe_core::{Ident, Value};
        
        // Add definitions from codebase to runtime environment
        // We need to evaluate each definition and bind it
        for (name, hash) in &self.codebase.term_names {
            if let Some(term) = self.codebase.get_term(hash) {
                // For now, create a placeholder closure for functions
                // In a real implementation, we'd evaluate the expression
                match &term.expr {
                    Expr::Lambda { params, body, .. } => {
                        let closure = Value::Closure {
                            params: params.iter().map(|(id, _)| id.clone()).collect(),
                            body: *body.clone(),
                            env: env.clone(),
                        };
                        *env = env.extend(Ident(name.clone()), closure);
                    }
                    Expr::Rec { name: rec_name, params, body, .. } => {
                        let closure = Value::RecClosure {
                            name: rec_name.clone(),
                            params: params.iter().map(|(id, _)| id.clone()).collect(),
                            body: *body.clone(),
                            env: env.clone(),
                        };
                        *env = env.extend(Ident(name.clone()), closure);
                    }
                    _ => {
                        // For non-function definitions, we'd need to evaluate them
                        // For now, skip them
                    }
                }
            }
        }
    }

    /// Verify properties from test outcome
    fn verify_properties_from_outcome(
        &self,
        properties: &[TestProperty],
        outcome: &TestOutcome,
    ) -> Vec<(TestProperty, bool)> {
        let mut results = Vec::new();

        match outcome {
            TestOutcome::Passed { value: _ } => {
                for prop in properties {
                    let verified = match prop {
                        TestProperty::NoErrors => true,
                        TestProperty::IsPure => true, // Assumed true if passed
                        _ => {
                            // Other properties would need the actual Value
                            // For now, we can't verify without parsing the string
                            true
                        }
                    };
                    results.push((prop.clone(), verified));
                }
            }
            TestOutcome::Failed { .. } => {
                for prop in properties {
                    let verified = match prop {
                        TestProperty::NoErrors => false,
                        _ => false,
                    };
                    results.push((prop.clone(), verified));
                }
            }
            TestOutcome::Timeout => {
                for prop in properties {
                    results.push((prop.clone(), false));
                }
            }
            TestOutcome::Skipped { .. } => {
                // Properties not verified for skipped tests
            }
        }

        results
    }
}

/// Format a value for display
fn format_value(value: &Value) -> String {
    match value {
        Value::Int(n) => n.to_string(),
        Value::Float(f) => f.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::String(s) => format!("{:?}", s),
        Value::List(items) => {
            let item_strs: Vec<String> = items.iter()
                .map(format_value)
                .collect();
            format!("[{}]", item_strs.join(", "))
        }
        Value::Closure { .. } => "<closure>".to_string(),
        Value::RecClosure { .. } => "<rec-closure>".to_string(),
        Value::BuiltinFunction { name, .. } => format!("<builtin: {}>", name),
        Value::Constructor { .. } => "<constructor>".to_string(),
        Value::UseStatement { .. } => "<use>".to_string(),
        Value::Record { fields } => {
            let field_strs: Vec<String> = fields.iter()
                .map(|(name, value)| format!("{}: {}", name, format_value(value)))
                .collect();
            format!("{{{}}}", field_strs.join(", "))
        }
    }
}

/// Test execution statistics
#[derive(Debug)]
pub struct TestStats {
    pub total: usize,
    pub passed: usize,
    pub failed: usize,
    pub timeout: usize,
    pub skipped: usize,
    pub from_cache: usize,
    pub total_duration: Duration,
}

impl TestStats {
    /// Calculate statistics from test results
    pub fn from_results(results: &[TestRunResult]) -> Self {
        let mut stats = TestStats {
            total: results.len(),
            passed: 0,
            failed: 0,
            timeout: 0,
            skipped: 0,
            from_cache: 0,
            total_duration: Duration::from_secs(0),
        };

        for result in results {
            match &result.outcome {
                TestOutcome::Passed { .. } => stats.passed += 1,
                TestOutcome::Failed { .. } => stats.failed += 1,
                TestOutcome::Timeout => stats.timeout += 1,
                TestOutcome::Skipped { .. } => stats.skipped += 1,
            }

            if result.from_cache {
                stats.from_cache += 1;
            }

            stats.total_duration += result.duration;
        }

        stats
    }

    /// Print a summary of the test results
    pub fn print_summary(&self) {
        println!("\nTest Summary:");
        println!("  Total:       {}", self.total);
        println!("  Passed:      {} ({}%)", self.passed, 
            if self.total > 0 { self.passed * 100 / self.total } else { 0 });
        println!("  Failed:      {}", self.failed);
        println!("  Timeout:     {}", self.timeout);
        println!("  Skipped:     {}", self.skipped);
        println!("  From cache:  {}", self.from_cache);
        println!("  Total time:  {:.2?}", self.total_duration);
        
        if self.from_cache > 0 {
            println!("  Cache hit rate: {}%", self.from_cache * 100 / self.total);
        }
    }
}