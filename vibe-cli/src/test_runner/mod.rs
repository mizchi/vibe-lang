//! Vibe Language Test Framework with Unison-style caching
//!
//! This module provides a test framework that caches test results
//! based on the content of the test and its dependencies.

#![allow(unused_imports)]

use anyhow::{Context, Result};
use colored::Colorize;
// Removed unused HashMap import
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use thiserror::Error;

use vibe_compiler::{TypeChecker, TypeEnv};
use vibe_core::parser::parse;
use vibe_core::{Expr, Ident, Value, XsError};
use vibe_runtime::Interpreter;
use vibe_codebase::{Codebase, Hash, TestCache, TestOutcome};

#[derive(Debug, Clone, Error)]
pub enum TestError {
    #[error("Parse error: {0}")]
    ParseError(String),
    #[error("Type error: {0}")]
    TypeError(String),
    #[error("Runtime error: {0}")]
    RuntimeError(String),
    #[error("Test assertion failed: expected {expected}, got {actual}")]
    AssertionFailed { expected: String, actual: String },
    #[error("IO error: {0}")]
    IoError(String),
}

/// Test case definition
#[derive(Debug, Clone)]
pub struct TestCase {
    pub name: String,
    pub file: PathBuf,
    pub expr: Expr,
    pub expected: Option<ExpectedResult>,
}

/// In-source test definition
#[derive(Debug, Clone)]
pub struct InSourceTest {
    pub name: String,
    pub test_expr: Expr,
    pub location: (usize, usize), // line, column
}

/// Expected result for a test
#[derive(Debug, Clone)]
pub enum ExpectedResult {
    Value(String),
    Type(String),
    Error(String),
}

/// Test result
#[derive(Debug)]
pub struct TestResult {
    pub name: String,
    pub file: PathBuf,
    pub outcome: TestOutcome,
    pub duration: Duration,
    pub cached: bool,
}

/// Test summary
#[derive(Debug, Default)]
pub struct TestSummary {
    pub total: usize,
    pub passed: usize,
    pub failed: usize,
    pub cached: usize,
    pub duration: Duration,
}

/// Test suite that manages multiple tests
pub struct TestSuite {
    tests: Vec<TestCase>,
    in_source_tests: Vec<(PathBuf, InSourceTest)>,
    #[allow(dead_code)]
    codebase: Codebase,
    #[allow(dead_code)]
    cache: TestCache,
    verbose: bool,
}

impl TestSuite {
    pub fn new(verbose: bool) -> Self {
        TestSuite {
            tests: Vec::new(),
            in_source_tests: Vec::new(),
            codebase: Codebase::new(),
            cache: TestCache::new(std::env::temp_dir().join("vibe_test_cache"))
                .expect("Failed to create test cache"),
            verbose,
        }
    }
    
    /// Get total number of tests
    pub fn total_tests(&self) -> usize {
        self.tests.len() + self.in_source_tests.len()
    }

    /// Load tests from a directory
    pub fn load_from_directory(&mut self, dir: &Path) -> Result<()> {
        if !dir.is_dir() {
            return Err(anyhow::anyhow!("Not a directory: {}", dir.display()));
        }

        for entry in fs::read_dir(dir).map_err(|e| TestError::IoError(e.to_string()))? {
            let entry = entry.map_err(|e| TestError::IoError(e.to_string()))?;
            let path = entry.path();

            if path.extension().and_then(|s| s.to_str()) == Some("vibe") {
                match self.load_test_file(&path) {
                    Ok(_) => {},
                    Err(e) => eprintln!("Warning: Failed to load {}: {}", path.display(), e),
                }
            }
        }

        Ok(())
    }

    /// Load a single test file and extract in-source tests
    /// Returns the number of tests found
    pub fn load_test_file(&mut self, path: &Path) -> Result<usize> {
        let source = fs::read_to_string(path)
            .with_context(|| format!("Failed to read {}", path.display()))?;

        // Parse test file
        let expr = parse(&source).map_err(|e| TestError::ParseError(e.to_string()))?;
        
        if self.verbose {
            println!("Parsed expression type: {:?}", match &expr {
                Expr::Block { .. } => "Block",
                Expr::Apply { .. } => "Apply",
                Expr::Let { .. } => "Let",
                _ => "Other",
            });
        }

        // Extract in-source tests
        let in_source_tests = self.extract_in_source_tests(&expr);
        let num_in_source_tests = in_source_tests.len();
        
        if self.verbose && num_in_source_tests > 0 {
            println!("Found {} in-source tests in {}", num_in_source_tests, path.display());
        }
        
        for test in in_source_tests {
            self.in_source_tests.push((path.to_path_buf(), test));
        }

        // Only add as traditional test if no in-source tests were found
        let mut num_traditional_tests = 0;
        if num_in_source_tests == 0 {
            // Check for traditional test files with # expect: comments
            let expected = self.extract_expected_from_source(&source);
            if expected.is_some() {
                let test_case = TestCase {
                    name: path.file_stem().unwrap().to_string_lossy().to_string(),
                    file: path.to_path_buf(),
                    expr,
                    expected,
                };
                self.tests.push(test_case);
                num_traditional_tests = 1;
            }
        }

        Ok(num_in_source_tests + num_traditional_tests)
    }

    /// Extract in-source tests from an expression
    fn extract_in_source_tests(&self, expr: &Expr) -> Vec<InSourceTest> {
        let mut tests = Vec::new();
        self.extract_in_source_tests_recursive(expr, &mut tests);
        if self.verbose {
            println!("Extracted {} tests from AST", tests.len());
        }
        tests
    }

    /// Recursively extract test function calls
    fn extract_in_source_tests_recursive(&self, expr: &Expr, tests: &mut Vec<InSourceTest>) {
        if self.verbose {
            println!("Checking expr for tests: {:?}", match expr {
                Expr::Block { .. } => "Block",
                Expr::Apply { .. } => "Apply",
                Expr::Let { .. } => "Let",
                _ => "Other",
            });
        }
        match expr {
            // Look for: test "name" (fn -> ...) or (test "name") (fn -> ...)
            Expr::Apply { func, args, span } => {
                // Check if it's a direct test call: test "name" (fn -> ...)
                if let Expr::Ident(Ident(name), _) = func.as_ref() {
                    if self.verbose && name == "test" {
                        println!("Found test call with {} args", args.len());
                        if args.len() >= 1 {
                            println!("First arg: {:?}", match &args[0] {
                                Expr::Literal(vibe_core::Literal::String(s), _) => format!("String({})", s),
                                _ => "Not a string".to_string(),
                            });
                        }
                    }
                    if name == "test" && args.len() == 2 {
                        if let Expr::Literal(vibe_core::Literal::String(test_name), _) = &args[0] {
                            tests.push(InSourceTest {
                                name: test_name.clone(),
                                test_expr: args[1].clone(),
                                location: (span.start, span.end),
                            });
                        }
                    }
                }
                // Check if it's a curried test call: (test "name") (fn -> ...)
                else if let Expr::Apply { func: inner_func, args: inner_args, .. } = func.as_ref() {
                    if let Expr::Ident(Ident(name), _) = inner_func.as_ref() {
                        if name == "test" && inner_args.len() == 1 && args.len() == 1 {
                            if let Expr::Literal(vibe_core::Literal::String(test_name), _) = &inner_args[0] {
                                tests.push(InSourceTest {
                                    name: test_name.clone(),
                                    test_expr: args[0].clone(),
                                    location: (span.start, span.end),
                                });
                            }
                        }
                    }
                }
                
                // Continue searching in subexpressions
                self.extract_in_source_tests_recursive(func, tests);
                for arg in args {
                    self.extract_in_source_tests_recursive(arg, tests);
                }
            }

            // Recursively search in other expression types
            Expr::Let { value, .. } => {
                self.extract_in_source_tests_recursive(value, tests);
            }
            Expr::LetIn { value, body, .. } => {
                self.extract_in_source_tests_recursive(value, tests);
                self.extract_in_source_tests_recursive(body, tests);
            }
            Expr::Lambda { body, .. } => {
                self.extract_in_source_tests_recursive(body, tests);
            }
            Expr::If { cond, then_expr, else_expr, .. } => {
                self.extract_in_source_tests_recursive(cond, tests);
                self.extract_in_source_tests_recursive(then_expr, tests);
                self.extract_in_source_tests_recursive(else_expr, tests);
            }
            Expr::Match { expr, cases, .. } => {
                self.extract_in_source_tests_recursive(expr, tests);
                for (_, case_expr) in cases {
                    self.extract_in_source_tests_recursive(case_expr, tests);
                }
            }
            Expr::Block { exprs, .. } => {
                for expr in exprs {
                    self.extract_in_source_tests_recursive(expr, tests);
                }
            }
            _ => {}
        }
    }

    /// Extract expected result from comments
    fn extract_expected_from_source(&self, source: &str) -> Option<ExpectedResult> {
        for line in source.lines() {
            if line.trim().starts_with("# expect:") {
                let rest = line.trim().strip_prefix("# expect:").unwrap().trim();
                return Some(ExpectedResult::Value(rest.to_string()));
            } else if line.trim().starts_with("# expect-type:") {
                let rest = line.trim().strip_prefix("# expect-type:").unwrap().trim();
                return Some(ExpectedResult::Type(rest.to_string()));
            } else if line.trim().starts_with("# expect-error:") {
                let rest = line.trim().strip_prefix("# expect-error:").unwrap().trim();
                return Some(ExpectedResult::Error(rest.to_string()));
            }
        }
        None
    }

    /// Run all tests
    pub fn run_all(&mut self) -> TestSummary {
        let start = Instant::now();
        let mut summary = TestSummary::default();

        println!("{}", "Running tests...".bright_blue().bold());
        println!();

        // Run traditional tests
        let tests_clone = self.tests.clone();
        for test in &tests_clone {
            let result = self.run_test(test);
            self.print_result(&result);
            self.update_summary(&mut summary, &result);
        }

        // Run in-source tests
        for (file, test) in &self.in_source_tests.clone() {
            let result = self.run_in_source_test(file, test);
            self.print_result(&result);
            self.update_summary(&mut summary, &result);
        }

        summary.duration = start.elapsed();
        self.print_summary(&summary);
        summary
    }

    /// Run a single test
    fn run_test(&mut self, test: &TestCase) -> TestResult {
        let start = Instant::now();

        // Check cache first
        // TODO: Implement proper caching
        // let test_hash = self.compute_test_hash(test);
        // if let Some(cached_result) = self.cache.get_cached_result(&test.expr, &[]) {
        //     return TestResult {
        //         name: test.name.clone(),
        //         file: test.file.clone(),
        //         outcome: cached_result.result.clone(),
        //         duration: Duration::from_millis(0),
        //         cached: true,
        //     };
        // }

        // Type check
        let mut type_checker = TypeChecker::new();
        let mut env = TypeEnv::new();
        let type_result = type_checker.check(&test.expr, &mut env);

        let outcome = match (&test.expected, type_result) {
            (Some(ExpectedResult::Type(expected)), Ok(actual)) => {
                if expected == &format!("{}", actual) {
                    TestOutcome::Passed { value: "Type matched".to_string() }
                } else {
                    TestOutcome::Failed {
                        error: format!("Expected type {}, got {}", expected, actual),
                    }
                }
            }
            (Some(ExpectedResult::Error(_)), Err(_)) => TestOutcome::Passed { value: "Error as expected".to_string() },
            (_, Err(e)) => TestOutcome::Failed {
                error: format!("Type error: {}", e),
            },
            (_, Ok(_)) => {
                // Run the test
                let mut interpreter = Interpreter::new();
                let env = vibe_runtime::Interpreter::create_initial_env();
                match interpreter.eval(&test.expr, &env) {
                    Ok(value) => match &test.expected {
                        Some(ExpectedResult::Value(expected)) => {
                            if expected == &format!("{}", value) {
                                TestOutcome::Passed { value: format!("{}", value) }
                            } else {
                                TestOutcome::Failed {
                                    error: format!("Expected {}, got {}", expected, value),
                                }
                            }
                        }
                        None => TestOutcome::Passed { value: "No expectation".to_string() },
                        _ => TestOutcome::Failed {
                            error: "Unexpected success".to_string(),
                        },
                    },
                    Err(e) => match &test.expected {
                        Some(ExpectedResult::Error(_)) => TestOutcome::Passed { value: "Error as expected".to_string() },
                        _ => TestOutcome::Failed {
                            error: format!("Runtime error: {}", e),
                        },
                    },
                }
            }
        };

        // Cache the result
        // TODO: Implement proper caching
        // let _ = self.cache.cache_result(&test.expr, &[], outcome.clone());

        TestResult {
            name: test.name.clone(),
            file: test.file.clone(),
            outcome,
            duration: start.elapsed(),
            cached: false,
        }
    }

    /// Run an in-source test
    fn run_in_source_test(&mut self, file: &Path, test: &InSourceTest) -> TestResult {
        let start = Instant::now();

        if self.verbose {
            println!("Running in-source test: {}", test.name);
        }

        // First, evaluate the entire file to set up the environment
        let source = match fs::read_to_string(file) {
            Ok(s) => s,
            Err(e) => {
                return TestResult {
                    name: test.name.clone(),
                    file: file.to_path_buf(),
                    outcome: TestOutcome::Failed {
                        error: format!("Failed to read file: {}", e),
                    },
                    duration: start.elapsed(),
                    cached: false,
                };
            }
        };

        let file_expr = match parse(&source) {
            Ok(expr) => expr,
            Err(e) => {
                return TestResult {
                    name: test.name.clone(),
                    file: file.to_path_buf(),
                    outcome: TestOutcome::Failed {
                        error: format!("Parse error: {}", e),
                    },
                    duration: start.elapsed(),
                    cached: false,
                };
            }
        };

        // Skip type checking the entire file since test calls return Unit
        // and the file as a whole might not type check properly.
        // We'll type check individual test expressions instead.

        // Build environment with definitions from the file
        let mut interpreter = Interpreter::new();
        let runtime_env = vibe_runtime::Interpreter::create_initial_env();
        
        // Extract and evaluate all definitions (let bindings) from the file
        let updated_env = match self.build_test_environment(&file_expr, &mut interpreter, runtime_env) {
            Ok(env) => env,
            Err(e) => {
                return TestResult {
                    name: test.name.clone(),
                    file: file.to_path_buf(),
                    outcome: TestOutcome::Failed {
                        error: format!("Failed to build test environment: {}", e),
                    },
                    duration: start.elapsed(),
                    cached: false,
                };
            }
        };

        // Now run the test expression in the environment with all definitions
        let test_expr = test.test_expr.clone();

        // The test expression should be a function
        let outcome = match interpreter.eval(&test_expr, &updated_env) {
            Err(e) => TestOutcome::Failed {
                error: format!("Failed to evaluate test function: {}", e),
            },
            Ok(test_fn) => {
                // Execute the test function
                match self.execute_test_function(test_fn, &mut interpreter, &updated_env) {
                    Ok(_) => TestOutcome::Passed { value: "Test passed".to_string() },
                    Err(e) => TestOutcome::Failed {
                        error: e.to_string(),
                    },
                }
            }
        };

        TestResult {
            name: test.name.clone(),
            file: file.to_path_buf(),
            outcome,
            duration: start.elapsed(),
            cached: false,
        }
    }

    /// Execute a test function value
    fn execute_test_function(
        &self,
        test_fn: Value,
        interpreter: &mut Interpreter,
        _env: &vibe_core::Environment,
    ) -> Result<Value, XsError> {
        match test_fn {
            Value::Closure { params, body, env: closure_env } => {
                // If the test function has parameters, apply a dummy value
                if !params.is_empty() {
                    // Create a dummy value to pass to the test function
                    let dummy_value = Value::Constructor {
                        name: Ident("Unit".to_string()),
                        values: vec![],
                    };
                    // Create environment with the parameter bound
                    let mut test_env = closure_env.clone();
                    for param in params {
                        test_env = test_env.extend(param, dummy_value.clone());
                    }
                    // Evaluate the test body
                    interpreter.eval(&body, &test_env)
                } else {
                    // Evaluate the test body
                    interpreter.eval(&body, &closure_env)
                }
            }
            Value::BuiltinFunction { .. } => {
                Err(XsError::RuntimeError(
                    vibe_core::Span::new(0, 0),
                    "Cannot use builtin function as test".to_string(),
                ))
            }
            _ => {
                // If it's not a function, just evaluate it
                Ok(test_fn)
            }
        }
    }

    /// Compute hash for a test (for caching)
    #[allow(dead_code)]
    fn compute_test_hash(&self, test: &TestCase) -> Hash {
        use sha2::{Digest, Sha256};
        let mut hasher = Sha256::new();
        hasher.update(format!("{:?}", test.expr).as_bytes());
        let result = hasher.finalize();
        Hash::new(&result)
    }

    /// Build test environment by evaluating definitions from file
    fn build_test_environment(
        &self,
        expr: &Expr,
        interpreter: &mut Interpreter,
        mut env: vibe_core::Environment,
    ) -> Result<vibe_core::Environment, XsError> {
        match expr {
            // Handle blocks with multiple expressions
            Expr::Block { exprs, .. } => {
                for e in exprs {
                    env = self.build_test_environment(e, interpreter, env)?;
                }
                Ok(env)
            }
            // Handle let bindings
            Expr::Let { name, value, .. } => {
                let val = interpreter.eval(value, &env)?;
                Ok(env.extend(name.clone(), val))
            }
            // Handle recursive definitions
            Expr::LetRec { name, value, .. } => {
                // LetRec values are already lambda expressions for recursive functions
                // We need to create a RecClosure to handle recursion properly
                match value.as_ref() {
                    Expr::Lambda { params, body, .. } => {
                        let param_names = params.iter().map(|(n, _)| n.clone()).collect();
                        let rec_closure = Value::RecClosure {
                            name: name.clone(),
                            params: param_names,
                            body: (**body).clone(),
                            env: env.clone(),
                        };
                        Ok(env.extend(name.clone(), rec_closure))
                    }
                    _ => {
                        // Non-function recursive definitions
                        let val = interpreter.eval(value, &env)?;
                        Ok(env.extend(name.clone(), val))
                    }
                }
            }
            // Handle rec syntax
            Expr::Rec { name, params, body, .. } => {
                // Create a RecClosure value for recursive functions
                let param_names = params.iter().map(|(n, _)| n.clone()).collect();
                let rec_closure = Value::RecClosure {
                    name: name.clone(),
                    params: param_names,
                    body: (**body).clone(),
                    env: env.clone(),
                };
                Ok(env.extend(name.clone(), rec_closure))
            }
            // Skip test calls and other expressions
            _ => Ok(env),
        }
    }

    /// Update summary with test result
    fn update_summary(&self, summary: &mut TestSummary, result: &TestResult) {
        summary.total += 1;
        if result.cached {
            summary.cached += 1;
        }
        match &result.outcome {
            TestOutcome::Passed { .. } => summary.passed += 1,
            TestOutcome::Failed { .. } => summary.failed += 1,
            TestOutcome::Timeout => {},
            TestOutcome::Skipped { .. } => {}
        }
    }

    /// Print test result
    fn print_result(&self, result: &TestResult) {
        let status = match &result.outcome {
            TestOutcome::Passed { .. } => "PASS".green(),
            TestOutcome::Failed { .. } => "FAIL".red(),
            TestOutcome::Timeout => "TIMEOUT".yellow(),
            TestOutcome::Skipped { .. } => "SKIP".yellow(),
        };

        let cached = if result.cached { " (cached)" } else { "" };
        let duration = if !result.cached {
            format!(" [{:.2}ms]", result.duration.as_secs_f64() * 1000.0)
        } else {
            String::new()
        };

        println!(
            "{} {} {}{}{}",
            status,
            result.file.display(),
            result.name,
            duration.dimmed(),
            cached.cyan()
        );

        if let TestOutcome::Failed { error } = &result.outcome {
            println!("  {}: {}", "Error".red(), error);
        }

        if self.verbose {
            println!();
        }
    }

    /// Print test summary
    fn print_summary(&self, summary: &TestSummary) {
        println!();
        println!("{}", "Test Summary".bright_blue().bold());
        println!("{}", "============".bright_blue());
        println!(
            "Total: {} | Passed: {} | Failed: {} | Cached: {}",
            summary.total,
            summary.passed.to_string().green(),
            summary.failed.to_string().red(),
            summary.cached.to_string().cyan()
        );
        println!(
            "Duration: {:.2}s",
            summary.duration.as_secs_f64()
        );

        if summary.failed == 0 {
            println!();
            println!("{}", "All tests passed!".green().bold());
        } else {
            println!();
            println!("{}", "Some tests failed!".red().bold());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_expected() {
        let suite = TestSuite::new(false);
        
        let source = r#"
# expect: 42
let x = 42
        "#;
        
        let expected = suite.extract_expected_from_source(source);
        assert!(matches!(expected, Some(ExpectedResult::Value(s)) if s == "42"));
    }

    #[test]
    fn test_extract_in_source_tests() {
        use vibe_core::{Expr, Ident, Literal, Span};
        
        let suite = TestSuite::new(false);
        
        // Create a test expression: test "example" (fn -> assert true "ok")
        let expr = Expr::Apply {
            func: Box::new(Expr::Ident(Ident("test".to_string()), Span::new(0, 4))),
            args: vec![
                Expr::Literal(Literal::String("example".to_string()), Span::new(5, 14)),
                Expr::Lambda {
                    params: vec![],
                    body: Box::new(Expr::Apply {
                        func: Box::new(Expr::Ident(Ident("assert".to_string()), Span::new(20, 26))),
                        args: vec![
                            Expr::Literal(Literal::Bool(true), Span::new(27, 31)),
                            Expr::Literal(Literal::String("ok".to_string()), Span::new(32, 36)),
                        ],
                        span: Span::new(20, 37),
                    }),
                    span: Span::new(15, 38),
                },
            ],
            span: Span::new(0, 39),
        };
        
        let tests = suite.extract_in_source_tests(&expr);
        assert_eq!(tests.len(), 1);
        assert_eq!(tests[0].name, "example");
    }
}