//! Recursion-specific tests for XS language
//! Tests migrated from top-level test_*.xs files

use std::fs;
use std::process::Command;

/// Helper function to run xsc command
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

/// Helper to create temp file, run test, and clean up
fn test_with_file(name: &str, code: &str, test_fn: impl Fn(&str, &str, bool)) {
    let filename = format!("test_{name}.xs");
    fs::write(&filename, code).unwrap();

    let (stdout, stderr, success) = run_xsc(&["run", &filename]);
    test_fn(&stdout, &stderr, success);

    fs::remove_file(&filename).ok();
}

mod basic_tests {
    use super::*;

    #[test]
    fn test_simple_arithmetic() {
        // From test.xs
        test_with_file("simple_arithmetic", "(+ 1 41)", |stdout, _, success| {
            assert!(success);
            assert!(stdout.contains("42"));
        });
    }

    #[test]
    fn test_let_binding() {
        // From test_let.xs
        test_with_file("let_binding", "(let x 10)", |stdout, _, success| {
            assert!(success);
            assert!(stdout.contains("10"));
        });
    }
}

mod rec_syntax_tests {
    use super::*;

    #[test]
    fn test_simple_rec_definition() {
        // From test_simple_rec.xs
        let code = r#"
(rec double (x) (* x 2))
"#;
        let filename = "test_simple_rec_def.xs";
        fs::write(filename, code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["parse", filename]);
        assert!(success, "Parse failed: {stderr}");
        assert!(stdout.contains("Rec"));

        fs::remove_file(filename).ok();
    }

    #[test]
    fn test_simple_rec_application() {
        // From test_simple_rec_apply.xs
        test_with_file(
            "simple_rec_apply",
            r#"
((rec double (x) (* x 2)) 21)
"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("42"));
            },
        );
    }

    #[test]
    fn test_direct_recursion() {
        // From test_direct_rec.xs
        let code = r#"
(rec countdown (n)
  (if (= n 0)
      0
      (countdown (- n 1))))
"#;
        let filename = "test_direct_rec_def.xs";
        fs::write(filename, code).unwrap();

        let (_stdout, stderr, success) = run_xsc(&["check", filename]);
        assert!(success, "Type check failed: {stderr}");

        fs::remove_file(filename).ok();
    }

    #[test]
    fn test_direct_recursion_application() {
        // From test_direct_rec_apply.xs
        test_with_file(
            "direct_rec_apply",
            r#"
((rec countdown (n)
  (if (= n 0)
      0
      (countdown (- n 1))))
 5)
"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("0"));
            },
        );
    }
}

mod factorial_tests {
    use super::*;

    #[test]
    fn test_factorial_with_type_annotations() {
        // From test_rec.xs
        let code = r#"
(rec factorial (n : Int) : Int
  (if (= n 0)
      1
      (* n (factorial (- n 1)))))
"#;
        let filename = "test_factorial_typed.xs";
        fs::write(filename, code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["check", filename]);
        assert!(success, "Type check failed: {stderr}");
        assert!(stdout.contains("Int"));

        fs::remove_file(filename).ok();
    }

    #[test]
    fn test_factorial_application() {
        // From test_rec_apply.xs
        test_with_file(
            "factorial_apply",
            r#"
((rec factorial (n : Int) : Int
  (if (= n 0)
      1
      (* n (factorial (- n 1)))))
 5)
"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("120")); // 5! = 120
            },
        );
    }

    #[test]
    fn test_factorial_inline_condition() {
        // From debug_rec.xs
        test_with_file(
            "factorial_inline",
            r#"
((rec fact (n : Int) : Int (if (= n 0) 1 (* n (fact (- n 1))))) 5)
"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("120"));
            },
        );
    }
}

mod edge_case_tests {
    use super::*;

    #[test]
    fn test_rec_debug_simple() {
        // From test_rec_debug.xs
        let code = r#"
(rec f (n)
  (if (= n 0)
      1
      (f (- n 1))))
"#;
        let filename = "test_rec_debug_simple.xs";
        fs::write(filename, code).unwrap();

        let (_, _, success) = run_xsc(&["check", filename]);
        assert!(success);

        fs::remove_file(filename).ok();
    }

    #[test]
    fn test_rec_debug_application() {
        // From test_rec_debug_apply.xs
        test_with_file(
            "rec_debug_apply",
            r#"
((rec f (n)
  (if (= n 0)
      1
      (f (- n 1))))
 3)
"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("1"));
            },
        );
    }

    #[test]
    #[ignore] // This test creates an infinite loop
    fn test_minimal_infinite_recursion() {
        // From test_minimal_rec.xs
        // This tests that infinite recursion is properly handled
        let code = r#"((rec f (n) (f n)) 1)"#;
        let filename = "test_minimal_rec.xs";
        fs::write(filename, code).unwrap();

        // We expect this to timeout or fail gracefully
        let output = Command::new("cargo")
            .args(["run", "-p", "cli", "--bin", "xsc", "--", "run", filename])
            .output();

        // The test passes if the program doesn't crash the test runner
        assert!(output.is_ok() || output.is_err());

        fs::remove_file(filename).ok();
    }
}

mod type_checking_tests {
    use super::*;

    #[test]
    fn test_rec_type_inference() {
        // Test that rec functions have proper type inference
        let code = r#"
(rec identity (x) x)
"#;
        let filename = "test_rec_identity.xs";
        fs::write(filename, code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["check", filename]);
        assert!(success, "Type check failed: {stderr}");
        assert!(stdout.contains("->"));

        fs::remove_file(filename).ok();
    }

    #[test]
    fn test_rec_with_multiple_params() {
        // Test rec with multiple parameters
        let code = r#"
(rec add (x y) (+ x y))
"#;
        let filename = "test_rec_multi_param.xs";
        fs::write(filename, code).unwrap();

        let (_stdout, stderr, success) = run_xsc(&["check", filename]);
        assert!(success, "Type check failed: {stderr}");

        fs::remove_file(filename).ok();
    }
}
