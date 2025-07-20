//! Common test helpers for XS language tests

use std::fs;
use std::process::Command;

/// Result of running xsc command
pub struct TestResult {
    pub stdout: String,
    pub stderr: String,
    pub success: bool,
}

/// Test configuration
pub struct TestConfig {
    pub name: String,
    pub code: String,
    pub command: TestCommand,
}

#[derive(Clone)]
pub enum TestCommand {
    Run,
    Check,
    Test,
}

impl TestCommand {
    fn as_str(&self) -> &'static str {
        match self {
            TestCommand::Run => "run",
            TestCommand::Check => "check",
            TestCommand::Test => "test",
        }
    }
}

/// Test builder for fluent API
pub struct TestBuilder {
    name: String,
    code: String,
    command: TestCommand,
}

impl TestBuilder {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            code: String::new(),
            command: TestCommand::Run,
        }
    }
    
    pub fn with_code(mut self, code: impl Into<String>) -> Self {
        self.code = code.into();
        self
    }
    
    pub fn check(mut self) -> Self {
        self.command = TestCommand::Check;
        self
    }
    
    pub fn test(mut self) -> Self {
        self.command = TestCommand::Test;
        self
    }
    
    pub fn expect_output(self, expected: &str) -> TestAssertion {
        TestAssertion {
            config: TestConfig {
                name: self.name,
                code: self.code,
                command: self.command,
            },
            assertions: vec![Assertion::OutputContains(expected.to_string())],
        }
    }
    
    pub fn expect_type(self, expected: &str) -> TestAssertion {
        TestAssertion {
            config: TestConfig {
                name: self.name,
                code: self.code,
                command: TestCommand::Check,
            },
            assertions: vec![Assertion::TypeContains(expected.to_string())],
        }
    }
    
    pub fn expect_success(self) -> TestAssertion {
        TestAssertion {
            config: TestConfig {
                name: self.name,
                code: self.code,
                command: self.command,
            },
            assertions: vec![Assertion::Success],
        }
    }
}

pub struct TestAssertion {
    config: TestConfig,
    assertions: Vec<Assertion>,
}

enum Assertion {
    Success,
    OutputContains(String),
    TypeContains(String),
    ErrorContains(String),
}

impl TestAssertion {
    pub fn and_output(mut self, expected: &str) -> Self {
        self.assertions.push(Assertion::OutputContains(expected.to_string()));
        self
    }
    
    pub fn and_type(mut self, expected: &str) -> Self {
        self.assertions.push(Assertion::TypeContains(expected.to_string()));
        self
    }
    
    pub fn and_error(mut self, expected: &str) -> Self {
        self.assertions.push(Assertion::ErrorContains(expected.to_string()));
        self
    }
    
    pub fn run(self) {
        let result = run_test(&self.config);
        
        for assertion in &self.assertions {
            match assertion {
                Assertion::Success => {
                    assert!(result.success, "Test failed: {}", result.stderr);
                }
                Assertion::OutputContains(expected) => {
                    assert!(
                        result.stdout.contains(expected),
                        "Expected output '{}' not found in: {}",
                        expected,
                        result.stdout
                    );
                }
                Assertion::TypeContains(expected) => {
                    assert!(
                        result.stdout.contains(expected),
                        "Expected type '{}' not found in: {}",
                        expected,
                        result.stdout
                    );
                }
                Assertion::ErrorContains(expected) => {
                    assert!(
                        result.stderr.contains(expected),
                        "Expected error '{}' not found in: {}",
                        expected,
                        result.stderr
                    );
                }
            }
        }
    }
}

/// Run a test with given configuration
fn run_test(config: &TestConfig) -> TestResult {
    let filename = format!("test_{}.xs", config.name);
    fs::write(&filename, &config.code).unwrap();
    
    let output = Command::new("cargo")
        .args(["run", "-p", "cli", "--bin", "xsc", "--"])
        .args([config.command.as_str(), &filename])
        .output()
        .expect("Failed to execute xsc");
    
    fs::remove_file(&filename).ok();
    
    TestResult {
        stdout: String::from_utf8_lossy(&output.stdout).to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).to_string(),
        success: output.status.success(),
    }
}

/// Create a new test
pub fn test(name: impl Into<String>) -> TestBuilder {
    TestBuilder::new(name)
}

/// Test data constants for common patterns
pub mod patterns {
    pub const FACTORIAL: &str = r#"
(rec factorial (n : Int) : Int
  (if (= n 0)
      1
      (* n (factorial (- n 1)))))
"#;

    pub const COUNTDOWN: &str = r#"
(rec countdown (n)
  (if (= n 0)
      0
      (countdown (- n 1))))
"#;

    pub const IDENTITY: &str = r#"(rec identity (x) x)"#;
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_helper_works() {
        test("simple")
            .with_code("(+ 1 2)")
            .expect_output("3")
            .run();
    }
    
    #[test]
    fn test_type_check_works() {
        test("type_check")
            .with_code("(let x 42)")
            .check()
            .expect_type("Int")
            .run();
    }
}