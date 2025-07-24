//! Tests for string operation builtin functions
//!
//! NOTE: These tests use S-expression syntax and need to be updated for the new Haskell-style parser

#![cfg(skip)]  // Skip these tests until they are updated

use std::fs;
use std::process::Command;

fn run_xsc(args: &[&str]) -> (String, String, bool) {
    let output = Command::new("cargo")
        .args(["run", "-p", "xsh", "--bin", "xsh", "--"])
        .args(args)
        .output()
        .expect("Failed to execute xsc");

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    (stdout, stderr, output.status.success())
}

#[test]
fn test_str_concat() {
    let code = r#"(str-concat "Hello, " "World!")"#;
    fs::write("test_str_concat.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_str_concat.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("\"Hello, World!\""));
}

#[test]
fn test_int_to_string() {
    let code = "(int-to-string 42)";
    fs::write("test_int_to_string.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_int_to_string.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("\"42\""));

    let code = "(int-to-string -123)";
    fs::write("test_int_to_string_neg.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_int_to_string_neg.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("\"-123\""));

    let code = "(int-to-string 0)";
    fs::write("test_int_to_string_zero.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_int_to_string_zero.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("\"0\""));
}

#[test]
fn test_string_to_int() {
    let code = r#"(string-to-int "123")"#;
    fs::write("test_string_to_int.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_string_to_int.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("123"));

    let code = r#"(string-to-int "-456")"#;
    fs::write("test_string_to_int_neg.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_string_to_int_neg.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("-456"));

    let code = r#"(string-to-int "0")"#;
    fs::write("test_string_to_int_zero.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_string_to_int_zero.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("0"));
}

#[test]
fn test_string_to_int_error() {
    let code = r#"(string-to-int "not a number")"#;
    fs::write("test_string_to_int_err1.xs", code).unwrap();
    let (_stdout, _stderr, success) = run_xsc(&["exec", "test_string_to_int_err1.xs"]);
    assert!(!success, "Should have failed");

    let code = r#"(string-to-int "")"#;
    fs::write("test_string_to_int_err2.xs", code).unwrap();
    let (_stdout, _stderr, success) = run_xsc(&["exec", "test_string_to_int_err2.xs"]);
    assert!(!success, "Should have failed");
}

#[test]
fn test_string_length() {
    let code = r#"(string-length "Hello")"#;
    fs::write("test_string_length.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_string_length.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("5"));

    let code = r#"(string-length "")"#;
    fs::write("test_string_length_empty.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_string_length_empty.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("0"));

    let code = r#"(string-length "Hello, World!")"#;
    fs::write("test_string_length_long.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_string_length_long.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("13"));
}

#[test]
fn test_string_operations_combined() {
    // Build a message using string operations
    let code = "(let count 42 in (let message (str-concat \"The answer is: \" (int-to-string count)) in message))";
    fs::write("test_string_ops_combined1.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_string_ops_combined1.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("\"The answer is: 42\""));

    // Parse and manipulate numbers
    let code = "(let num-str \"100\" in (let num (string-to-int num-str) in (let doubled (+ num num) in (int-to-string doubled))))";
    fs::write("test_string_ops_combined2.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_string_ops_combined2.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("\"200\""));
}
