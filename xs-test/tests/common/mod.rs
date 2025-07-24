//! Common test utilities for XS language tests

use std::fs;
use std::process::Command;
use std::env;

/// Result of running xsc command
pub struct XscResult {
    pub stdout: String,
    pub stderr: String,
    pub success: bool,
}

/// Helper function to run xsc command
pub fn run_xsc(args: &[&str]) -> XscResult {
    let output = Command::new("cargo")
        .args(["run", "-p", "xsh", "--bin", "xsh", "--"])
        .args(args)
        .output()
        .expect("Failed to execute xsc");

    XscResult {
        stdout: String::from_utf8_lossy(&output.stdout).to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).to_string(),
        success: output.status.success(),
    }
}

/// Helper to create temp file, run test, and clean up
pub fn test_with_file(name: &str, code: &str, test_fn: impl Fn(&XscResult)) {
    let temp_dir = env::temp_dir();
    let filename = temp_dir.join(format!("test_{name}.xs"));
    let filename_str = filename.to_str().unwrap();
    fs::write(&filename, code).unwrap();

    let result = run_xsc(&["exec", filename_str]);
    test_fn(&result);

    fs::remove_file(&filename).ok();
}

/// Helper to test type checking
pub fn test_type_check(name: &str, code: &str, test_fn: impl Fn(&XscResult)) {
    let temp_dir = env::temp_dir();
    let filename = temp_dir.join(format!("test_{name}.xs"));
    let filename_str = filename.to_str().unwrap();
    fs::write(&filename, code).unwrap();

    let result = run_xsc(&["check", filename_str]);
    test_fn(&result);

    fs::remove_file(&filename).ok();
}

/// Helper to test that code runs successfully and produces expected output
pub fn test_runs_with_output(name: &str, code: &str, expected_output: &str) {
    test_with_file(name, code, |result| {
        assert!(result.success, "Failed to run: {}", result.stderr);
        assert!(
            result.stdout.contains(expected_output),
            "Expected output '{}' not found in: {}",
            expected_output,
            result.stdout
        );
    });
}

/// Helper to test that code runs successfully (without checking output)
#[allow(dead_code)]
pub fn test_runs_successful(name: &str, code: &str) {
    test_with_file(name, code, |result| {
        assert!(result.success, "Failed to run: {}", result.stderr);
    });
}

/// Helper to test that code type checks successfully
pub fn test_type_checks(name: &str, code: &str) {
    test_type_check(name, code, |result| {
        assert!(result.success, "Type check failed: {}", result.stderr);
    });
}

/// Helper to test that code type checks and contains expected type
#[allow(dead_code)]
pub fn test_type_checks_with(name: &str, code: &str, expected_type: &str) {
    test_type_check(name, code, |result| {
        assert!(result.success, "Type check failed: {}", result.stderr);
        assert!(
            result.stdout.contains(expected_type),
            "Expected type '{}' not found in: {}",
            expected_type,
            result.stdout
        );
    });
}

/// Helper to test parsing
#[allow(dead_code)]
pub fn test_parse(name: &str, code: &str, test_fn: impl Fn(&XscResult)) {
    let temp_dir = env::temp_dir();
    let filename = temp_dir.join(format!("test_{name}.xs"));
    let filename_str = filename.to_str().unwrap();
    fs::write(&filename, code).unwrap();

    let result = run_xsc(&["parse", filename_str]);
    test_fn(&result);

    fs::remove_file(&filename).ok();
}

/// Helper to test that code parses successfully and contains expected output
#[allow(dead_code)]
pub fn test_parses_with(name: &str, code: &str, expected: &str) {
    test_parse(name, code, |result| {
        assert!(result.success, "Parse failed: {}", result.stderr);
        assert!(
            result.stdout.contains(expected),
            "Expected '{}' not found in: {}",
            expected,
            result.stdout
        );
    });
}

/// Helper to test that code parses successfully
pub fn test_parse_ok(name: &str, code: &str) {
    test_parse(name, code, |result| {
        assert!(result.success, "Parse failed: {}", result.stderr);
    });
}

/// Helper to test that code type checks successfully
pub fn test_typecheck_ok(name: &str, code: &str) {
    test_type_check(name, code, |result| {
        assert!(result.success, "Type check failed: {}", result.stderr);
    });
}

/// Helper to test that code type checks and fails
pub fn test_typecheck_err(name: &str, code: &str) {
    test_type_check(name, code, |result| {
        assert!(!result.success, "Expected type check to fail but it succeeded");
    });
}

/// Common test patterns
#[allow(dead_code)]
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

    pub const FIBONACCI: &str = r#"
(rec fib (n : Int) : Int
  (if (< n 2)
      n
      (+ (fib (- n 1)) (fib (- n 2)))))
"#;
}
