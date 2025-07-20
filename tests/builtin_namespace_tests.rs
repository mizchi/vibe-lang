//! Tests for builtin namespace system

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
fn test_int_namespace() {
    // Test Int.toString
    let code = "(Int.toString 42)";
    fs::write("test_int_tostring.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["run", "test_int_tostring.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("\"42\""));
    
    // Test Int.add
    let code = "(Int.add 10 20)";
    fs::write("test_int_add.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["run", "test_int_add.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("30"));
    
    // Test Int.eq
    let code = "(Int.eq 5 5)";
    fs::write("test_int_eq.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["run", "test_int_eq.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("true"));
}

#[test]
fn test_string_namespace() {
    // Test String.concat
    let code = r#"(String.concat "Hello, " "World!")"#;
    fs::write("test_string_concat.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["run", "test_string_concat.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("\"Hello, World!\""));
    
    // Test String.length
    let code = r#"(String.length "Hello")"#;
    fs::write("test_string_length.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["run", "test_string_length.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("5"));
    
    // Test String.fromInt
    let code = "(String.fromInt 123)";
    fs::write("test_string_fromint.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["run", "test_string_fromint.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("\"123\""));
}

#[test]
fn test_list_namespace() {
    // Test List.cons
    let code = "(List.cons 1 (cons 2 (cons 3 (list))))";
    fs::write("test_list_cons.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["run", "test_list_cons.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("(list 1 2 3)"));
}

#[test]
fn test_io_namespace() {
    // Test IO.print (just check it doesn't error)
    let code = r#"(IO.print "Hello from namespace!")"#;
    fs::write("test_io_print.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["run", "test_io_print.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("Hello from namespace!"));
}

#[test]
fn test_mixed_namespace_usage() {
    // Combine multiple namespaces
    let code = r#"(String.concat "Count: " (Int.toString (Int.add 40 2)))"#;
    fs::write("test_mixed_namespace.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["run", "test_mixed_namespace.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("\"Count: 42\""));
}

#[test]
fn test_backward_compatibility() {
    // Old global functions should still work
    let code = "(+ 10 20)";
    fs::write("test_backward_plus.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["run", "test_backward_plus.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("30"));
    
    let code = r#"(str-concat "Hello, " "World!")"#;
    fs::write("test_backward_strconcat.xs", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["run", "test_backward_strconcat.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("\"Hello, World!\""));
}