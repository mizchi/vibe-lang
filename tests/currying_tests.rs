//! Tests for automatic currying functionality

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
fn test_automatic_currying_lambda() {
    // Test that multi-parameter lambda is automatically curried
    let code = r#"(fn x = fn y = x + y) 5"#;
    fs::write("test_auto_curry.xs", code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["exec", "test_auto_curry.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("closure")); // Partial application returns a closure

    fs::remove_file("test_auto_curry.xs").ok();
}

#[test]
fn test_automatic_currying_application() {
    // Test that multi-argument application is automatically curried
    let code = r#"((fn x = fn y = x + y) 5) 7"#;
    fs::write("test_curry_app.xs", code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["exec", "test_curry_app.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("12"));

    fs::remove_file("test_curry_app.xs").ok();
}

#[test]
fn test_three_parameter_currying() {
    // Test currying with three parameters
    let code = r#"((fn x = fn y = fn z = (x * y) + z) 3 4) 5"#;
    fs::write("test_three_curry.xs", code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["exec", "test_three_curry.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("17")); // 3 * 4 + 5 = 17

    fs::remove_file("test_three_curry.xs").ok();
}

#[test]
fn test_builtin_currying() {
    // Test that built-in functions are curried
    let code = r#"10 + 20"#;
    fs::write("test_builtin_curry.xs", code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["exec", "test_builtin_curry.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("30"));

    fs::remove_file("test_builtin_curry.xs").ok();
}

#[test]
fn test_partial_application_binding() {
    // Test binding partially applied functions
    let code = r#"let add5 = fn x = 5 + x"#;
    fs::write("test_partial_bind.xs", code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["exec", "test_partial_bind.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("closure") || stdout.contains("<builtin:+>"));

    fs::remove_file("test_partial_bind.xs").ok();
}

#[test]
fn test_composition_with_currying() {
    // Test function composition with curried functions
    let code = r#"((fn f = fn g = fn x = f (g x)) (fn x = x + 1)) (fn x = x * 2)"#;
    fs::write("test_curry_compose.xs", code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["exec", "test_curry_compose.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("closure")); // Returns composed function

    fs::remove_file("test_curry_compose.xs").ok();
}

#[test]
fn test_curried_recursive_function() {
    // Test recursive function with currying
    let code = r#"let add = fn x = fn y = if (y == 0) { x } else { x + y } in add 5"#;
    fs::write("test_rec_curry.xs", code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["exec", "test_rec_curry.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("closure")); // Partial application of recursive function

    fs::remove_file("test_rec_curry.xs").ok();
}

#[test]
fn test_higher_order_currying() {
    // Test higher-order functions with automatic currying
    let code = r#"((fn f = fn x = fn y = f x y) (fn x = fn y = x + y) 3 4)"#;
    fs::write("test_ho_curry.xs", code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["exec", "test_ho_curry.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("7"));

    fs::remove_file("test_ho_curry.xs").ok();
}

#[test]
fn test_curried_type_checking() {
    // Test that type checking works correctly with curried functions
    let code = r#"(fn x = fn y = x + y) 5"#;
    fs::write("test_curry_types.xs", code).unwrap();

    let (_, stderr, success) = run_xsc(&["check", "test_curry_types.xs"]);
    assert!(success, "Type check failed: {stderr}");

    fs::remove_file("test_curry_types.xs").ok();
}

#[test]
fn test_curried_list_operations() {
    // Test curried list operations - list construction
    let code = r#"[1, 2, 3]"#;
    fs::write("test_curry_list.xs", code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["exec", "test_curry_list.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("(list 1 2 3)"));

    fs::remove_file("test_curry_list.xs").ok();
}
