//! Vibe Language Test Framework with Unison-style caching
//!
//! This module provides a test framework that caches test results
//! based on the content of the test and its dependencies.

use anyhow::{Context, Result};
use colored::Colorize;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use thiserror::Error;

use vibe_compiler::{TypeChecker, TypeEnv};
use vibe_core::parser::parse;
use vibe_core::{Expr, Value};
use vibe_runtime::Interpreter;
use vibe_workspace::{CachedTestRunner, Codebase, TestCache, TestOutcome};

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

/// Expected result for a test
#[derive(Debug, Clone)]
pub enum ExpectedResult {
    Value(String),
    Type(String),
    Error(String),
}

/// Test suite that manages multiple tests
pub struct TestSuite {
    tests: Vec<TestCase>,
    codebase: Codebase,
    cache: TestCache,
    verbose: bool,
}

impl TestSuite {
    pub fn new(verbose: bool) -> Self {
        TestSuite {
            tests: Vec::new(),
            codebase: Codebase::new(),
            cache: TestCache::new(std::env::temp_dir().join("xs_test_cache"))
                .expect("Failed to create test cache"),
            verbose,
        }
    }

    /// Load tests from a directory
    pub fn load_from_directory(&mut self, dir: &Path) -> Result<()> {
        if !dir.is_dir() {
            return Err(anyhow::anyhow!("Not a directory: {}", dir.display()));
        }

        for entry in fs::read_dir(dir).map_err(|e| TestError::IoError(e.to_string()))? {
            let entry = entry.map_err(|e| TestError::IoError(e.to_string()))?;
            let path = entry.path();

            if path.extension().and_then(|s| s.to_str()) == Some("xs") {
                if let Err(e) = self.load_test_file(&path) {
                    eprintln!("Warning: Failed to load {}: {}", path.display(), e);
                }
            }
        }

        Ok(())
    }

    /// Load a single test file
    pub fn load_test_file(&mut self, path: &Path) -> Result<()> {
        let source = fs::read_to_string(path)
            .with_context(|| format!("Failed to read {}", path.display()))?;

        // Parse test file
        let expr = parse(&source).map_err(|e| TestError::ParseError(e.to_string()))?;

        // Extract test metadata from comments
        let expected = self.extract_expected_from_source(&source);

        let test_case = TestCase {
            name: path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("unknown")
                .to_string(),
            file: path.to_path_buf(),
            expr,
            expected,
        };

        self.tests.push(test_case);
        Ok(())
    }

    /// Run all tests
    pub fn run_all(&mut self) -> TestSummary {
        let mut summary = TestSummary::new();
        let start_time = Instant::now();

        println!("{}", "\n=== Running XS Tests ===\n".bold());

        for test in self.tests.clone() {
            let result = self.run_test(&test);
            summary.add_result(&test.name, result);
        }

        summary.duration = start_time.elapsed();
        self.print_summary(&summary);
        summary
    }

    /// Run a single test
    fn run_test(&mut self, test: &TestCase) -> TestResult {
        if self.verbose {
            println!("Running {}...", test.name.yellow());
        }

        let mut runner = CachedTestRunner::new(&mut self.cache, &self.codebase);

        // Define the executor function that uses the actual interpreter
        let executor = |expr: &Expr| -> Result<String, String> {
            // Type check first
            let mut type_env = TypeEnv::new();
            let mut type_checker = TypeChecker::new();
            type_checker
                .check(expr, &mut type_env)
                .map_err(|e| e.to_string())?;

            // Then interpret
            let env = Interpreter::create_initial_env();
            let mut interpreter = Interpreter::new();
            let value = interpreter.eval(expr, &env).map_err(|e| e.to_string())?;

            // Convert value to string representation for comparison
            Ok(match &value {
                Value::Bool(b) => b.to_string(),
                Value::Int(n) => n.to_string(),
                Value::String(s) => format!("\"{s}\""),
                _ => format!("{value:?}"),
            })
        };

        // Check if we have a cached result
        let test_start = std::time::SystemTime::now();
        let test_result = runner.run_test(&test.expr, executor);
        // If timestamp is before test_start, it was cached
        let is_cached = test_result.timestamp < test_start;

        // Convert to our TestResult type
        match test_result.result {
            TestOutcome::Passed { ref value } => {
                if let Some(ref expected) = test.expected {
                    match expected {
                        ExpectedResult::Value(expected_val) => {
                            if value == expected_val {
                                TestResult::Passed {
                                    duration: test_result.duration,
                                    cached: is_cached,
                                }
                            } else {
                                TestResult::Failed {
                                    error: TestError::AssertionFailed {
                                        expected: expected_val.clone(),
                                        actual: value.clone(),
                                    },
                                    duration: test_result.duration,
                                }
                            }
                        }
                        ExpectedResult::Type(_) => {
                            // Type checking passed implicitly
                            TestResult::Passed {
                                duration: test_result.duration,
                                cached: is_cached,
                            }
                        }
                        ExpectedResult::Error(expected_err) => TestResult::Failed {
                            error: TestError::AssertionFailed {
                                expected: format!("error: {expected_err}"),
                                actual: format!("success: {value}"),
                            },
                            duration: test_result.duration,
                        },
                    }
                } else {
                    TestResult::Passed {
                        duration: test_result.duration,
                        cached: is_cached,
                    }
                }
            }
            TestOutcome::Failed { ref error } => {
                if let Some(ExpectedResult::Error(expected_err)) = &test.expected {
                    if error.contains(expected_err) {
                        TestResult::Passed {
                            duration: test_result.duration,
                            cached: is_cached,
                        }
                    } else {
                        TestResult::Failed {
                            error: TestError::RuntimeError(error.clone()),
                            duration: test_result.duration,
                        }
                    }
                } else {
                    TestResult::Failed {
                        error: TestError::RuntimeError(error.clone()),
                        duration: test_result.duration,
                    }
                }
            }
            TestOutcome::Timeout => TestResult::Failed {
                error: TestError::RuntimeError("Test timed out".to_string()),
                duration: test_result.duration,
            },
            TestOutcome::Skipped { reason } => TestResult::Skipped { reason },
        }
    }

    /// Extract expected result from source comments
    fn extract_expected_from_source(&self, source: &str) -> Option<ExpectedResult> {
        for line in source.lines() {
            if line.trim().starts_with("; expect:") {
                let expect = line.trim().strip_prefix("; expect:").unwrap().trim();
                return Some(ExpectedResult::Value(expect.to_string()));
            } else if line.trim().starts_with("; expect-type:") {
                let expect_type = line.trim().strip_prefix("; expect-type:").unwrap().trim();
                return Some(ExpectedResult::Type(expect_type.to_string()));
            } else if line.trim().starts_with("; expect-error:") {
                let expect_error = line.trim().strip_prefix("; expect-error:").unwrap().trim();
                return Some(ExpectedResult::Error(expect_error.to_string()));
            }
        }
        None
    }

    /// Print test summary
    fn print_summary(&self, summary: &TestSummary) {
        println!("\n{}", "=== Test Summary ===".bold());

        if summary.passed > 0 {
            println!(
                "  {} {}",
                summary.passed.to_string().green(),
                "passed".green()
            );
        }

        if summary.failed > 0 {
            println!("  {} {}", summary.failed.to_string().red(), "failed".red());
        }

        if summary.skipped > 0 {
            println!(
                "  {} {}",
                summary.skipped.to_string().yellow(),
                "skipped".yellow()
            );
        }

        if summary.cached > 0 {
            println!(
                "  {} {} ({})",
                summary.cached.to_string().cyan(),
                "from cache".cyan(),
                format!(
                    "{:.1}% cache hit rate",
                    100.0 * summary.cached as f64 / summary.total as f64
                )
                .cyan()
            );
        }

        println!(
            "\nTotal: {} tests in {:.2}s",
            summary.total,
            summary.duration.as_secs_f64()
        );

        if !summary.failures.is_empty() {
            println!("\n{}", "Failed tests:".red().bold());
            for (name, error) in &summary.failures {
                println!("  - {}: {}", name.red(), error);
            }
        }
    }
}

/// Result of running a single test
#[derive(Debug, Clone)]
pub enum TestResult {
    Passed {
        duration: Duration,
        cached: bool,
    },
    Failed {
        error: TestError,
        duration: Duration,
    },
    Skipped {
        reason: String,
    },
}

/// Summary of test results
#[derive(Debug, Clone)]
pub struct TestSummary {
    pub passed: usize,
    pub failed: usize,
    pub skipped: usize,
    pub cached: usize,
    pub total: usize,
    pub duration: Duration,
    pub failures: Vec<(String, String)>,
}

impl Default for TestSummary {
    fn default() -> Self {
        Self::new()
    }
}

impl TestSummary {
    pub fn new() -> Self {
        TestSummary {
            passed: 0,
            failed: 0,
            skipped: 0,
            cached: 0,
            total: 0,
            duration: Duration::from_secs(0),
            failures: Vec::new(),
        }
    }

    pub fn add_result(&mut self, name: &str, result: TestResult) {
        self.total += 1;

        match result {
            TestResult::Passed { cached, .. } => {
                self.passed += 1;
                if cached {
                    self.cached += 1;
                }
                print!("{}", ".".green());
            }
            TestResult::Failed { ref error, .. } => {
                self.failed += 1;
                self.failures.push((name.to_string(), error.to_string()));
                print!("{}", "F".red());
            }
            TestResult::Skipped { .. } => {
                self.skipped += 1;
                print!("{}", "S".yellow());
            }
        }

        // Flush output
        use std::io::{self, Write};
        io::stdout().flush().unwrap();
    }

    pub fn all_passed(&self) -> bool {
        self.failed == 0
    }
}
