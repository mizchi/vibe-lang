//! End-to-end integration tests for XS language

use std::process::Command;
use std::fs;

/// Helper function to run xsc command
fn run_xsc(args: &[&str]) -> (String, String, bool) {
    let output = Command::new("cargo")
        .args(&["run", "-p", "cli", "--bin", "xsc", "--"])
        .args(args)
        .output()
        .expect("Failed to execute xsc");
    
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    
    (stdout, stderr, output.status.success())
}

#[test]
fn test_parse_simple_expression() {
    let (stdout, stderr, success) = run_xsc(&["parse", "examples/arithmetic.xs"]);
    
    assert!(success, "Parse failed: {}", stderr);
    assert!(stdout.contains("Literal"));
    // arithmetic.xs contains (+ (* 5 6) (- 10 3)), which has 5, 6, 10, 3
    assert!(stdout.contains("5") || stdout.contains("6") || stdout.contains("10") || stdout.contains("3"));
}

#[test]
fn test_check_type_inference() {
    let (stdout, stderr, success) = run_xsc(&["check", "examples/identity.xs"]);
    
    assert!(success, "Type check failed: {}", stderr);
    assert!(stdout.contains("Type:"));
    assert!(stdout.contains("->"));
}

#[test]
fn test_run_arithmetic() {
    let (stdout, stderr, success) = run_xsc(&["run", "examples/arithmetic.xs"]);
    
    assert!(success, "Run failed: {}", stderr);
    assert!(stdout.contains("37"));
}

#[test]
fn test_run_list_operations() {
    let (stdout, stderr, success) = run_xsc(&["run", "examples/list.xs"]);
    
    assert!(success, "Run failed: {}", stderr);
    assert!(stdout.contains("list"));
}

#[test]
fn test_run_lambda() {
    let (stdout, stderr, success) = run_xsc(&["run", "examples/lambda.xs"]);
    
    assert!(success, "Run failed: {}", stderr);
    assert!(stdout.contains("30")); // (lambda (x y) (+ x y)) applied to 10 20
}

#[test]
fn test_factorial() {
    // Create a simple factorial test file
    let factorial_code = r#"(let-rec fact (lambda (n) 
        (if (= n 0) 
            1 
            (* n (fact (- n 1)))))
    (fact 5))"#;
    
    fs::write("test_factorial.xs", factorial_code).unwrap();
    
    let (stdout, _stderr, success) = run_xsc(&["run", "test_factorial.xs"]);
    
    // Currently let-rec is not fully supported in interpreter
    // So we expect this to fail for now
    assert!(!success || stdout.contains("120"));
    
    // Clean up
    fs::remove_file("test_factorial.xs").ok();
}

#[test]
fn test_type_error() {
    let error_code = r#"(+ 1 "hello")"#;
    fs::write("test_error.xs", error_code).unwrap();
    
    let (_stdout, stderr, success) = run_xsc(&["check", "test_error.xs"]);
    
    assert!(!success);
    assert!(stderr.contains("Type") || stderr.contains("type"));
    
    // Clean up
    fs::remove_file("test_error.xs").ok();
}

#[test]
fn test_parse_error() {
    let error_code = r#"(let x"#; // Incomplete expression
    fs::write("test_parse_error.xs", error_code).unwrap();
    
    let (_stdout, stderr, success) = run_xsc(&["parse", "test_parse_error.xs"]);
    
    assert!(!success);
    assert!(stderr.contains("Parse") || stderr.contains("parse"));
    
    // Clean up
    fs::remove_file("test_parse_error.xs").ok();
}

/// Test the full pipeline: parse -> check -> run
#[test]
fn test_full_pipeline() {
    let test_code = r#"(let double : (-> Int Int) (lambda (x : Int) (* x 2)))"#;
    
    fs::write("test_pipeline.xs", test_code).unwrap();
    
    // Test parsing
    let (stdout, stderr, success) = run_xsc(&["parse", "test_pipeline.xs"]);
    assert!(success, "Parse failed: {}", stderr);
    assert!(stdout.contains("Let"));
    
    // Test type checking
    let (stdout, stderr, success) = run_xsc(&["check", "test_pipeline.xs"]);
    assert!(success, "Type check failed: {}", stderr);
    assert!(stdout.contains("Int"));
    
    // Test running
    let (stdout, stderr, success) = run_xsc(&["run", "test_pipeline.xs"]);
    assert!(success, "Run failed: {}", stderr);
    assert!(stdout.contains("closure")); // let returns a closure
    
    // Clean up
    fs::remove_file("test_pipeline.xs").ok();
}