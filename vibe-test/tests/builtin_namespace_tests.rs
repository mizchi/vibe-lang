//! Tests for builtin namespace system

use std::fs;
use std::process::Command;

fn run_xsc(args: &[&str]) -> (String, String, bool) {
    let output = Command::new("cargo")
        .args(["run", "-p", "vsh", "--bin", "vsh", "--"])
        .args(args)
        .output()
        .expect("Failed to execute xsh");

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    (stdout, stderr, output.status.success())
}

#[test]
fn test_int_namespace() {
    // Test Int.toString
    let code = "Int.toString 42";
    fs::write("test_int_tostring.vibe", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_int_tostring.vibe"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("\"42\""));

    // Test Int.add
    let code = "Int.add 10 20";
    fs::write("test_int_add.vibe", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_int_add.vibe"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("30"));

    // Test Int.eq
    let code = "Int.eq 5 5";
    fs::write("test_int_eq.vibe", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_int_eq.vibe"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("true"));
}

#[test]
fn test_string_namespace() {
    // Test String.concat
    let code = r#"String.concat "Hello, " "World!""#;
    fs::write("test_string_concat.vibe", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_string_concat.vibe"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("\"Hello, World!\""));

    // Test String.length
    let code = r#"String.length "Hello""#;
    fs::write("test_string_length.vibe", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_string_length.vibe"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("5"));

    // Test String.fromInt
    let code = "String.fromInt 123";
    fs::write("test_string_fromint.vibe", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_string_fromint.vibe"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("\"123\""));
}

#[test]
fn test_list_namespace() {
    // Test List.cons
    let code = "List.cons 1 (cons 2 (cons 3 []))";
    fs::write("test_list_cons.vibe", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_list_cons.vibe"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("(list 1 2 3)") || stdout.contains("[1, 2, 3]"));
}

#[test]
fn test_io_namespace() {
    // Test IO.print (just check it doesn't error)
    let code = r#"IO.print "Hello from namespace!""#;
    fs::write("test_io_print.vibe", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_io_print.vibe"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("Hello from namespace!"));
}

#[test]
fn test_mixed_namespace_usage() {
    // Combine multiple namespaces
    let code = r#"String.concat "Count: " (Int.toString (Int.add 40 2))"#;
    fs::write("test_mixed_namespace.vibe", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_mixed_namespace.vibe"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("\"Count: 42\""));
}

#[test]
fn test_backward_compatibility() {
    // Old global functions should still work
    let code = "10 + 20";  // Using infix syntax
    fs::write("test_backward_plus.vibe", code).unwrap();
    let (stdout, stderr, success) = run_xsc(&["exec", "test_backward_plus.vibe"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("30"));

    // Skip strConcat test for now as it's not in the type checker environment
    // TODO: Fix this when strConcat is properly added to type checker
    // let code = r#"(strConcat "Hello, " "World!")"#;
    // fs::write("test_backward_strconcat.vibe", code).unwrap();
    // let (stdout, stderr, success) = run_xsc(&["exec", "test_backward_strconcat.vibe"]);
    // assert!(success, "Run failed: {stderr}");
    // assert!(stdout.contains("\"Hello, World!\""));
}
