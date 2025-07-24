//! Tests for let-in syntax

use std::fs;
use std::process::Command;

/// Helper function to run xsc command
fn run_xsc(args: &[&str]) -> (String, String, bool) {
    let output = Command::new("cargo")
        .args(["run", "-p", "vsh", "--bin", "vsh", "--"])
        .args(args)
        .output()
        .expect("Failed to execute xsc");

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    (stdout, stderr, output.status.success())
}

/// Helper to create temp file, run test, and clean up
fn test_with_file(name: &str, code: &str, test_fn: impl Fn(&str, &str, bool)) {
    let filename = format!("test_{name}.vibe");
    fs::write(&filename, code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["exec", &filename]);
    test_fn(&stdout, &stderr, success);

    fs::remove_file(&filename).ok();
}

mod basic_let_in_tests {
    use super::*;

    #[test]
    fn test_simple_let_in() {
        test_with_file(
            "simple_let_in",
            "let x = 10 in x + 5",
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("15"));
            },
        );
    }

    #[test]
    fn test_nested_let_in() {
        test_with_file(
            "nested_let_in",
            r#"let x = 10 in
  let y = 20 in
    x + y"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("30"));
            },
        );
    }

    #[test]
    fn test_let_in_with_type_annotation() {
        test_with_file(
            "let_in_type_ann",
            "let x : Int = 42 in x * 2",
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("84"));
            },
        );
    }
}

mod rec_with_let_in_tests {
    use super::*;

    #[test]
    #[ignore = "Recursive function syntax not fully supported"]
    fn test_rec_with_let_in() {
        test_with_file(
            "rec_let_in",
            r#"
((rec factorial (n)
  (let is_zero (= n 0) in
    (if is_zero
        1
        (* n (factorial (- n 1))))))
 5)
"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("120"));
            },
        );
    }

    #[test]
    #[ignore = "Recursive function syntax not fully supported"]
    fn test_rec_with_multiple_let_in() {
        test_with_file(
            "rec_multiple_let_in",
            r#"rec sumSquares n =
  let isZero = eq n 0 in
    if isZero {
      0
    } else {
      let square = n * n in
        square + sumSquares (n - 1)
    }

sumSquares 5"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("55")); // 1 + 4 + 9 + 16 + 25 = 55
            },
        );
    }
}

mod lambda_with_let_in_tests {
    use super::*;

    #[test]
    #[ignore = "Lambda syntax with let-in not fully supported"]
    fn test_lambda_with_let_in() {
        test_with_file(
            "lambda_let_in",
            r#"(fn x ->
  let doubled = x * 2 in
    doubled + 10) 5"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("20")); // 5 * 2 + 10 = 20
            },
        );
    }

    #[test]
    #[ignore = "Higher-order functions with let-in not fully supported"]
    fn test_higher_order_with_let_in() {
        test_with_file(
            "higher_order_let_in",
            r#"let applyTwice = fn f x ->
  let once = f x in
    f once
in
  applyTwice (fn n -> n * 2) 3"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("12")); // ((3 * 2) * 2) = 12
            },
        );
    }
}

mod pattern_matching_with_let_in_tests {
    use super::*;

    #[test]
    #[ignore = "Pattern matching with ... syntax not fully supported"]
    fn test_match_with_let_in() {
        test_with_file(
            "match_let_in",
            r#"match [1, 2, 3] {
  [] -> 0
  [x, ...vibe] ->
    let headSquared = x * x in
      headSquared
}"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("1")); // First element (1) squared = 1
            },
        );
    }
}

mod type_checking_tests {
    use super::*;

    #[test]
    #[ignore = "Type inference output format changed"]
    fn test_let_in_type_inference() {
        let code = r#"let x = 42 in
  let y = x + 1 in
    y"#;
        let filename = "test_let_in_type_inference.vibe";
        fs::write(filename, code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["check", filename]);
        assert!(success, "Type check failed: {stderr}");
        assert!(
            stdout.contains("'t") || stdout.contains("Int"),
            "Expected type variable or Int, got: {stdout}"
        );

        fs::remove_file(filename).ok();
    }

    #[test]
    #[ignore = "Type inference output format changed"]
    fn test_let_in_polymorphism() {
        let code = r#"let id = fn x -> x in
  let intResult = id 42 in
    let boolResult = id true in
      intResult"#;
        let filename = "test_let_in_poly.vibe";
        fs::write(filename, code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["check", filename]);
        assert!(success, "Type check failed: {stderr}");
        assert!(
            stdout.contains("'t") || stdout.contains("Int"),
            "Expected type variable or Int, got: {stdout}"
        );

        fs::remove_file(filename).ok();
    }
}

mod error_cases {
    use super::*;

    #[test]
    fn test_let_in_scope_error() {
        let code = r#"let x = 10 in y"#;
        let filename = "test_let_in_scope_error.vibe";
        fs::write(filename, code).unwrap();

        let (_, stderr, success) = run_xsc(&["check", filename]);
        assert!(!success);
        assert!(stderr.contains("Undefined variable"));

        fs::remove_file(filename).ok();
    }
}
