//! XS Language test runner framework
//! 
//! This module provides a test runner that can execute XS language tests
//! by compiling them to WebAssembly and running them with Wasmtime.

use crate::runner::{WasmTestRunner, RunResult};
use crate::generate_module;
use parser::parse;
use checker::TypeChecker;
use perceus::transform_to_ir;
use std::fs;
use std::path::{Path, PathBuf};
use wasmtime::Val;

/// XS test file representation
#[derive(Debug)]
pub struct XsTest {
    /// Test file path
    pub path: PathBuf,
    /// Test name (derived from filename)
    pub name: String,
    /// Expected output (parsed from test file comments)
    pub expected: Option<TestExpectation>,
}

/// Expected test result
#[derive(Debug, Clone, PartialEq)]
pub enum TestExpectation {
    /// Expect the test to return a specific value (stored as i32/i64/f64)
    ValueI32(i32),
    ValueI64(i64),
    ValueF64(u64), // Store as bits
    /// Expect the test to succeed (return 0)
    Success,
    /// Expect the test to fail with an error
    Error(String),
    /// Expect a type error during compilation
    TypeError(String),
    /// Expect a parse error
    ParseError(String),
}

impl XsTest {
    /// Load a test from a file
    pub fn from_file(path: impl AsRef<Path>) -> Result<Self, Box<dyn std::error::Error>> {
        let path = path.as_ref().to_path_buf();
        let name = path.file_stem()
            .ok_or("Invalid filename")?
            .to_string_lossy()
            .into_owned();
        
        let content = fs::read_to_string(&path)?;
        let expected = Self::parse_expectation(&content);
        
        Ok(Self { path, name, expected })
    }
    
    /// Parse test expectation from comments
    fn parse_expectation(content: &str) -> Option<TestExpectation> {
        // Look for special comments:
        // ; expect: 42
        // ; expect-error: "Type mismatch"
        // ; expect-type-error: "Cannot unify Int with Bool"
        // ; expect-parse-error: "Unexpected token"
        
        for line in content.lines() {
            let line = line.trim();
            if line.starts_with("; expect:") {
                let value_str = line.strip_prefix("; expect:")?.trim();
                
                // Try to parse as different types
                if let Ok(n) = value_str.parse::<i32>() {
                    return Some(TestExpectation::ValueI32(n));
                }
                if let Ok(n) = value_str.parse::<i64>() {
                    return Some(TestExpectation::ValueI64(n));
                }
                if let Ok(f) = value_str.parse::<f64>() {
                    return Some(TestExpectation::ValueF64(f.to_bits()));
                }
                if value_str == "true" {
                    return Some(TestExpectation::ValueI32(1));
                }
                if value_str == "false" {
                    return Some(TestExpectation::ValueI32(0));
                }
                if value_str == "success" {
                    return Some(TestExpectation::Success);
                }
            } else if line.starts_with("; expect-error:") {
                let msg = line.strip_prefix("; expect-error:")?.trim().trim_matches('"');
                return Some(TestExpectation::Error(msg.to_string()));
            } else if line.starts_with("; expect-type-error:") {
                let msg = line.strip_prefix("; expect-type-error:")?.trim().trim_matches('"');
                return Some(TestExpectation::TypeError(msg.to_string()));
            } else if line.starts_with("; expect-parse-error:") {
                let msg = line.strip_prefix("; expect-parse-error:")?.trim().trim_matches('"');
                return Some(TestExpectation::ParseError(msg.to_string()));
            }
        }
        
        None
    }
}

/// XS test runner
pub struct XsTestRunner {
    wasm_runner: WasmTestRunner,
    verbose: bool,
}

impl XsTestRunner {
    /// Create a new test runner
    pub fn new(verbose: bool) -> Result<Self, Box<dyn std::error::Error>> {
        Ok(Self {
            wasm_runner: WasmTestRunner::new()?,
            verbose,
        })
    }
    
    /// Run a single test
    pub fn run_test(&self, test: &XsTest) -> TestResult {
        if self.verbose {
            println!("Running test: {}", test.name);
        }
        
        // Read test file
        let content = match fs::read_to_string(&test.path) {
            Ok(c) => c,
            Err(e) => return TestResult::Error(format!("Failed to read file: {e}")),
        };
        
        // Parse
        let ast = match parse(&content) {
            Ok(ast) => ast,
            Err(e) => {
                if let Some(TestExpectation::ParseError(expected)) = &test.expected {
                    if e.to_string().contains(expected) {
                        return TestResult::Pass;
                    }
                    return TestResult::Fail(format!(
                        "Expected parse error '{expected}', got '{e}'"
                    ));
                }
                return TestResult::Error(format!("Parse error: {e}"));
            }
        };
        
        // Type check
        let mut type_checker = TypeChecker::new();
        let mut env = checker::TypeEnv::new();
        match type_checker.check(&ast, &mut env) {
            Ok(_) => {},
            Err(e) => {
                if let Some(TestExpectation::TypeError(expected)) = &test.expected {
                    if e.to_string().contains(expected) {
                        return TestResult::Pass;
                    }
                    return TestResult::Fail(format!(
                        "Expected type error '{expected}', got '{e}'"
                    ));
                }
                return TestResult::Error(format!("Type error: {e}"));
            }
        }
        
        // Generate IR
        let ir = transform_to_ir(&ast);
        
        // Generate WebAssembly
        let module = match generate_module(&ir) {
            Ok(m) => m,
            Err(e) => return TestResult::Error(format!("Code generation error: {e}")),
        };
        
        // Run the module
        let result = match self.wasm_runner.run_module(&module) {
            Ok(r) => r,
            Err(e) => return TestResult::Error(format!("Execution error: {e}")),
        };
        
        // Check expectation
        match (&test.expected, &result) {
            (None, RunResult::Success(_)) => TestResult::Pass,
            (Some(TestExpectation::Success), RunResult::Success(Val::I32(0))) => TestResult::Pass,
            (Some(TestExpectation::ValueI32(expected)), RunResult::Success(Val::I32(actual))) => {
                if expected == actual {
                    TestResult::Pass
                } else {
                    TestResult::Fail(format!("Expected {expected}, got {actual}"))
                }
            }
            (Some(TestExpectation::ValueI64(expected)), RunResult::Success(Val::I64(actual))) => {
                if expected == actual {
                    TestResult::Pass
                } else {
                    TestResult::Fail(format!("Expected {expected}, got {actual}"))
                }
            }
            (Some(TestExpectation::ValueF64(expected)), RunResult::Success(Val::F64(actual))) => {
                if expected == actual {
                    TestResult::Pass
                } else {
                    TestResult::Fail(format!("Expected {expected:?}, got {actual:?}"))
                }
            }
            (Some(TestExpectation::Error(expected)), RunResult::Error(actual)) => {
                if actual.contains(expected) {
                    TestResult::Pass
                } else {
                    TestResult::Fail(format!(
                        "Expected error '{expected}', got '{actual}'"
                    ))
                }
            }
            _ => TestResult::Fail(format!(
                "Unexpected result. Expected {:?}, got {:?}", test.expected, result
            )),
        }
    }
    
    /// Run all tests in a directory
    pub fn run_directory(&self, dir: impl AsRef<Path>) -> TestSuiteResult {
        let mut results = TestSuiteResult::new();
        
        let entries = match fs::read_dir(dir) {
            Ok(e) => e,
            Err(e) => {
                eprintln!("Failed to read directory: {e}");
                return results;
            }
        };
        
        for entry in entries.filter_map(Result::ok) {
            let path = entry.path();
            if path.extension().is_some_and(|ext| ext == "xs") {
                match XsTest::from_file(&path) {
                    Ok(test) => {
                        let result = self.run_test(&test);
                        match &result {
                            TestResult::Pass => results.passed += 1,
                            TestResult::Fail(_) => results.failed += 1,
                            TestResult::Error(_) => results.errors += 1,
                            TestResult::Skipped => results.skipped += 1,
                        }
                        results.tests.push((test.name.clone(), result));
                    }
                    Err(e) => {
                        eprintln!("Failed to load test {}: {}", path.display(), e);
                        results.errors += 1;
                    }
                }
            }
        }
        
        results
    }
}

/// Test result
#[derive(Debug, Clone)]
pub enum TestResult {
    Pass,
    Fail(String),
    Error(String),
    Skipped,
}

/// Test suite results
#[derive(Debug)]
pub struct TestSuiteResult {
    pub tests: Vec<(String, TestResult)>,
    pub passed: usize,
    pub failed: usize,
    pub errors: usize,
    pub skipped: usize,
}

impl TestSuiteResult {
    fn new() -> Self {
        Self {
            tests: Vec::new(),
            passed: 0,
            failed: 0,
            errors: 0,
            skipped: 0,
        }
    }
    
    /// Print a summary of the test results
    pub fn print_summary(&self) {
        let total = self.passed + self.failed + self.errors + self.skipped;
        
        println!("\nTest Summary:");
        println!("============");
        println!("Total:   {total}");
        println!("Passed:  {} ✓", self.passed);
        println!("Failed:  {} ✗", self.failed);
        println!("Errors:  {} ⚠", self.errors);
        println!("Skipped: {} -", self.skipped);
        
        if self.failed > 0 || self.errors > 0 {
            println!("\nFailures and Errors:");
            for (name, result) in &self.tests {
                match result {
                    TestResult::Fail(msg) => println!("  {name} ✗ {msg}"),
                    TestResult::Error(msg) => println!("  {name} ⚠ {msg}"),
                    _ => {}
                }
            }
        }
        
        let success = self.failed == 0 && self.errors == 0;
        println!("\nResult: {}", if success { "SUCCESS ✓" } else { "FAILURE ✗" });
    }
    
    /// Check if all tests passed
    pub fn all_passed(&self) -> bool {
        self.failed == 0 && self.errors == 0
    }
}

#[cfg(test)]
#[path = "test_runner_tests.rs"]
mod test_runner_tests;