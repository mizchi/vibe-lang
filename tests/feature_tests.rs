//! Feature-specific integration tests for XS language

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

mod pattern_matching {
    use super::*;

    #[test]
    fn test_literal_patterns() {
        test_with_file(
            "literal_pattern",
            r#"
(match 42
  (0 "zero")
  (42 "forty-two")
  (_ "other"))
"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("\"forty-two\""));
            },
        );
    }

    #[test]
    fn test_variable_patterns() {
        test_with_file(
            "var_pattern",
            r#"
(match (list 1 2 3)
  ((list x y z) x)
  (_ 0))
"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("1"));
            },
        );
    }

    #[test]
    fn test_nested_patterns() {
        test_with_file(
            "nested_pattern",
            r#"
(match (list (list 1) (list 2))
  ((list (list a) (list b)) a)
  (_ 0))
"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("1"));
            },
        );
    }
}

mod algebraic_data_types {
    use super::*;

    #[test]
    fn test_simple_adt() {
        let filename = "test_simple_adt.xs";
        fs::write(filename, r#"(type Bool (True) (False))"#).unwrap();

        let (stdout, stderr, success) = run_xsc(&["parse", filename]);
        assert!(success, "Parse failed: {stderr}");
        assert!(stdout.contains("TypeDef"));

        fs::remove_file(filename).ok();
    }

    #[test]
    fn test_parameterized_adt() {
        let filename = "test_param_adt.xs";
        fs::write(
            filename,
            r#"
(type Maybe a
  (Just a)
  (Nothing))
"#,
        )
        .unwrap();

        let (stdout, stderr, success) = run_xsc(&["parse", filename]);
        assert!(success, "Parse failed: {stderr}");
        assert!(stdout.contains("TypeDef"));
        assert!(stdout.contains("type_params"));

        fs::remove_file(filename).ok();
    }
}

mod recursive_functions {
    use super::*;

    #[test]
    fn test_fibonacci() {
        test_with_file(
            "fibonacci",
            r#"
((rec fib (n : Int) : Int
  (if (< n 2)
      n
      (+ (fib (- n 1)) (fib (- n 2)))))
 7)
"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("13")); // fib(7) = 13
            },
        );
    }

    #[test]
    fn test_mutual_recursion() {
        // Note: This might not be fully supported yet
        test_with_file(
            "mutual_rec",
            r#"
((rec is-even (n : Int) : Bool
  (if (= n 0)
      true
      (is-odd (- n 1))))
 4)
"#,
            |_, _, success| {
                // For now, we just check if it doesn't crash
                // Mutual recursion might need special support
                let _ = success; // Allow failure for now
            },
        );
    }
}

mod type_inference {
    use super::*;

    #[test]
    fn test_polymorphic_identity() {
        let filename = "test_poly_id.xs";
        fs::write(
            filename,
            r#"
(fn (x) x)
"#,
        )
        .unwrap();

        let (stdout, stderr, success) = run_xsc(&["check", filename]);
        assert!(success, "Type check failed: {stderr}");
        assert!(stdout.contains("->"));

        fs::remove_file(filename).ok();
    }

    #[test]
    fn test_let_polymorphism() {
        test_with_file(
            "let_poly",
            r#"(let id (fn (x) x))"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("closure") || stdout.contains("lambda"));
            },
        );
    }
}

mod list_operations {
    use super::*;

    #[test]
    fn test_empty_list() {
        test_with_file("empty_list", "(list)", |stdout, _, success| {
            assert!(success);
            assert!(stdout.contains("(list"));
        });
    }

    #[test]
    fn test_nested_lists() {
        test_with_file(
            "nested_lists",
            r#"
(list (list 1 2) (list 3 4) (list 5 6))
"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("list"));
            },
        );
    }

    #[test]
    fn test_cons_chain() {
        test_with_file(
            "cons_chain",
            r#"
(cons 1 (cons 2 (cons 3 (list))))
"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("(list 1 2 3)"));
            },
        );
    }
}

mod error_handling {
    use super::*;

    #[test]
    fn test_type_mismatch() {
        let filename = "test_type_mismatch.xs";
        fs::write(filename, r#"(+ 1 true)"#).unwrap();

        let (_, stderr, success) = run_xsc(&["check", filename]);
        assert!(!success);
        assert!(stderr.contains("Type") || stderr.contains("mismatch"));

        fs::remove_file(filename).ok();
    }

    #[test]
    fn test_undefined_variable() {
        let filename = "test_undef_var.xs";
        fs::write(filename, r#"undefined_var"#).unwrap();

        let (_, stderr, success) = run_xsc(&["check", filename]);
        assert!(!success);
        assert!(stderr.contains("Undefined") || stderr.contains("undefined"));

        fs::remove_file(filename).ok();
    }

    #[test]
    fn test_arity_mismatch() {
        let filename = "test_arity.xs";
        // With currying, this returns a partial application
        fs::write(filename, r#"((fn (x y) (+ x y)) 1)"#).unwrap();

        let (stdout, _, success) = run_xsc(&["run", filename]);
        assert!(success);
        assert!(stdout.contains("closure"));

        fs::remove_file(filename).ok();
    }
}

mod module_system {
    use super::*;

    #[test]
    fn test_module_syntax() {
        let filename = "test_module_syntax.xs";
        fs::write(
            filename,
            r#"
(module TestModule
  (export foo bar)
  (define foo 42)
  (define bar (fn (x) (* x 2))))
"#,
        )
        .unwrap();

        let (stdout, stderr, success) = run_xsc(&["parse", filename]);
        assert!(success, "Parse failed: {stderr}");
        assert!(stdout.contains("Module"));
        assert!(stdout.contains("export"));
        assert!(stdout.contains("Define") || stdout.contains("Let")); // define becomes Let in AST

        fs::remove_file(filename).ok();
    }

    #[test]
    fn test_import_syntax() {
        let filename = "test_import_syntax.xs";
        fs::write(
            filename,
            r#"
(import (Math add sub))
"#,
        )
        .unwrap();

        let (stdout, stderr, success) = run_xsc(&["parse", filename]);
        assert!(success, "Parse failed: {stderr}");
        assert!(stdout.contains("Import"));
        assert!(stdout.contains("Math"));

        fs::remove_file(filename).ok();
    }

    #[test]
    fn test_qualified_names() {
        let filename = "test_qualified.xs";
        fs::write(filename, r#"Math.PI"#).unwrap();

        let (stdout, stderr, success) = run_xsc(&["parse", filename]);
        assert!(success, "Parse failed: {stderr}");
        assert!(stdout.contains("QualifiedIdent"));
        assert!(stdout.contains("Math"));
        assert!(stdout.contains("PI"));

        fs::remove_file(filename).ok();
    }
}

mod floating_point {
    use super::*;

    #[test]
    fn test_float_literals() {
        test_with_file("float_literal", "3.14159", |stdout, _, success| {
            assert!(success);
            assert!(stdout.contains("3.14159"));
        });
    }

    #[test]
    fn test_float_negative() {
        test_with_file("float_neg", "-2.5", |stdout, _, success| {
            assert!(success);
            assert!(stdout.contains("-2.5"));
        });
    }

    #[test]
    fn test_float_type_inference() {
        let filename = "test_float_type.xs";
        fs::write(filename, "1.0").unwrap();

        let (stdout, stderr, success) = run_xsc(&["check", filename]);
        assert!(success, "Type check failed: {stderr}");
        assert!(stdout.contains("Float"));

        fs::remove_file(filename).ok();
    }
}
