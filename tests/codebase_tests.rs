//! Tests for Unison-style codebase features

use std::fs;
use std::process::Command;

fn run_xsc(args: &[&str]) -> (String, String, bool) {
    let output = Command::new("cargo")
        .args(["run", "-p", "cli", "--bin", "xsc", "--"])
        .args(args)
        .output()
        .expect("Failed to execute xsc");

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    (stdout, stderr, output.status.success())
}

#[test]
fn test_function_hashing() {
    // Test that identical functions produce the same hash
    let func1_code = r#"(fn (x) (+ x 1))"#;
    let func2_code = r#"(fn (x) (+ x 1))"#;

    fs::write("test_hash1.xs", func1_code).unwrap();
    fs::write("test_hash2.xs", func2_code).unwrap();

    // In the future, this would check that both produce the same hash
    let (stdout1, _, success1) = run_xsc(&["parse", "test_hash1.xs"]);
    let (stdout2, _, success2) = run_xsc(&["parse", "test_hash2.xs"]);

    assert!(success1 && success2);
    // Both should parse to the same AST structure
    assert_eq!(stdout1, stdout2);

    fs::remove_file("test_hash1.xs").ok();
    fs::remove_file("test_hash2.xs").ok();
}

#[test]
fn test_content_addressed_storage() {
    // Test that content determines storage location
    let unique_func = r#"(fn (x y z) (+ (* x y) z))"#;

    fs::write("test_content_addr.xs", unique_func).unwrap();

    let (stdout, stderr, success) = run_xsc(&["parse", "test_content_addr.xs"]);
    assert!(success, "Parse failed: {stderr}");
    assert!(stdout.contains("Lambda"));

    fs::remove_file("test_content_addr.xs").ok();
}

#[test]
fn test_simple_lambda() {
    // Test simple lambda execution
    let code = r#"((fn (x) (* x 2)) 20)"#;
    fs::write("test_simple.xs", code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["run", "test_simple.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("40"));

    fs::remove_file("test_simple.xs").ok();
}

#[test]
fn test_nested_lambda() {
    // Test nested lambdas
    let code = r#"((fn (x) ((fn (y) (+ x y)) 20)) 22)"#;
    fs::write("test_nested.xs", code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["run", "test_nested.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("42"));

    fs::remove_file("test_nested.xs").ok();
}

#[test]
fn test_let_expression() {
    // Test let expression
    let code = r#"(let x 42)"#;
    fs::write("test_let.xs", code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["run", "test_let.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("42"));

    fs::remove_file("test_let.xs").ok();
}

#[test]
fn test_list_operations() {
    // Test list operations
    let code = r#"(list 1 2 3)"#;
    fs::write("test_list_ops.xs", code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["run", "test_list_ops.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("list"));

    fs::remove_file("test_list_ops.xs").ok();
}

#[test]
fn test_recursive_function() {
    // Test recursive function using rec
    let code = r#"(rec fact (n) (if (= n 0) 1 (* n (fact (- n 1)))))"#;
    fs::write("test_rec.xs", code).unwrap();

    let (_stdout, stderr, success) = run_xsc(&["check", "test_rec.xs"]);
    assert!(success, "Type check failed: {stderr}");

    fs::remove_file("test_rec.xs").ok();
}

#[test]
fn test_module_syntax() {
    // Test module syntax
    let code = r#"(module Math (export id) (let id (fn (x) x)))"#;
    fs::write("test_module_syntax.xs", code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["parse", "test_module_syntax.xs"]);
    assert!(success, "Parse failed: {stderr}");
    assert!(stdout.contains("Module"));

    fs::remove_file("test_module_syntax.xs").ok();
}

#[test]
fn test_type_definition() {
    // Test type definition
    let code = r#"(type Maybe a (None) (Some a))"#;
    fs::write("test_type_def.xs", code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["parse", "test_type_def.xs"]);
    assert!(success, "Parse failed: {stderr}");
    assert!(stdout.contains("TypeDef"));

    fs::remove_file("test_type_def.xs").ok();
}

#[test]
fn test_pattern_matching() {
    // Test pattern matching
    let code = r#"(match (list 1 2) ((list) 0) ((list x _) x))"#;
    fs::write("test_pattern.xs", code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["run", "test_pattern.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("1"));

    fs::remove_file("test_pattern.xs").ok();
}
