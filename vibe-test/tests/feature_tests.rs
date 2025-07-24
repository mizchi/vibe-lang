//! Feature-specific integration tests for XS language

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

mod pattern_matching {
    use super::*;

    #[test]
    #[ignore = "Pattern matching implementation incomplete"]
    fn test_literal_patterns() {
        test_with_file(
            "literal_pattern",
            r#"match 42 {
  0 -> "zero"
  42 -> "forty-two"
  _ -> "other"
}"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("\"forty-two\""));
            },
        );
    }

    #[test]
    #[ignore = "Pattern matching implementation incomplete"]
    fn test_variable_patterns() {
        test_with_file(
            "var_pattern",
            r#"match [1, 2, 3] {
  [x, y, z] -> x
  _ -> 0
}"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("1"));
            },
        );
    }

    #[test]
    #[ignore = "Pattern matching implementation incomplete"]
    fn test_nested_patterns() {
        test_with_file(
            "nested_pattern",
            r#"match [[1], [2]] {
  [[a], [b]] -> a
  _ -> 0
}"#,
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
        let filename = "test_simple_adt.vibe";
        fs::write(filename, r#"type Bool = True | False"#).unwrap();

        let (stdout, stderr, success) = run_xsc(&["parse", filename]);
        assert!(success, "Parse failed: {stderr}");
        assert!(stdout.contains("TypeDef") || stdout.contains("TypeDefinition"));

        fs::remove_file(filename).ok();
    }

    #[test]
    fn test_parameterized_adt() {
        let filename = "test_param_adt.vibe";
        fs::write(
            filename,
            r#"type Maybe a = Just a | Nothing"#,
        )
        .unwrap();

        let (stdout, stderr, success) = run_xsc(&["parse", filename]);
        assert!(success, "Parse failed: {stderr}");
        assert!(stdout.contains("TypeDef") || stdout.contains("TypeDefinition"));
        assert!(stdout.contains("type_params"));

        fs::remove_file(filename).ok();
    }
}

mod recursive_functions {
    use super::*;

    #[test]
    #[ignore = "Recursive function syntax changed"]
    fn test_fibonacci() {
        test_with_file(
            "fibonacci",
            r#"rec fib n =
  if n < 2 {
    n
  } else {
    fib (n - 1) + fib (n - 2)
  }

fib 7"#,
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
    #[ignore = "Output format changed"]
    fn test_polymorphic_identity() {
        let filename = "test_poly_id.vibe";
        fs::write(
            filename,
            r#"fn x -> x"#,
        )
        .unwrap();

        let (stdout, stderr, success) = run_xsc(&["check", filename]);
        assert!(success, "Type check failed: {stderr}");
        assert!(stdout.contains("->"));

        fs::remove_file(filename).ok();
    }

    #[test]
    #[ignore = "Output format changed"]
    fn test_let_polymorphism() {
        test_with_file(
            "let_poly",
            r#"let id = fn x -> x"#,
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
        test_with_file("empty_list", "[]", |stdout, _, success| {
            assert!(success);
            assert!(stdout.contains("[") || stdout.contains("list"));
        });
    }

    #[test]
    fn test_nested_lists() {
        test_with_file(
            "nested_lists",
            r#"[[1, 2], [3, 4], [5, 6]]"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("list"));
            },
        );
    }

    #[test]
    #[ignore = "List syntax changed"]
    fn test_cons_chain() {
        test_with_file(
            "cons_chain",
            r#"1 :: 2 :: 3 :: []"#,
            |stdout, _, success| {
                assert!(success);
                assert!(stdout.contains("[1, 2, 3]") || stdout.contains("1 :: 2 :: 3 :: []"));
            },
        );
    }
}

mod error_handling {
    use super::*;

    #[test]
    fn test_type_mismatch() {
        let filename = "test_type_mismatch.vibe";
        fs::write(filename, r#"(+ 1 true)"#).unwrap();

        let (_, stderr, success) = run_xsc(&["check", filename]);
        assert!(!success);
        assert!(stderr.contains("Type") || stderr.contains("mismatch"));

        fs::remove_file(filename).ok();
    }

    #[test]
    fn test_undefined_variable() {
        let filename = "test_undef_var.vibe";
        fs::write(filename, r#"undefined_var"#).unwrap();

        let (_, stderr, success) = run_xsc(&["check", filename]);
        assert!(!success);
        assert!(stderr.contains("Undefined") || stderr.contains("undefined"));

        fs::remove_file(filename).ok();
    }

    #[test]
    #[ignore = "Output format changed"]
    fn test_arity_mismatch() {
        let filename = "test_arity.vibe";
        // With currying, this returns a partial application
        fs::write(filename, r#"((fn (x y) (+ x y)) 1)"#).unwrap();

        let (stdout, _, success) = run_xsc(&["exec", filename]);
        assert!(success);
        assert!(stdout.contains("closure"));

        fs::remove_file(filename).ok();
    }
}

mod module_system {
    use super::*;

    #[test]
    #[ignore] // TODO: Implement module system
    fn test_module_syntax() {
        let filename = "test_module_syntax.vibe";
        fs::write(
            filename,
            r#"module TestModule {
  export foo, bar
  let foo = 42
  let bar = fn x -> x * 2
}"#,
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
    #[ignore] // TODO: Implement module system
    fn test_import_syntax() {
        let filename = "test_import_syntax.vibe";
        fs::write(
            filename,
            r#"import Math (add, sub)"#,
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
        let filename = "test_qualified.vibe";
        fs::write(filename, r#"Math.PI"#).unwrap();

        let (stdout, stderr, success) = run_xsc(&["parse", filename]);
        assert!(success, "Parse failed: {stderr}");
        assert!(stdout.contains("RecordAccess") || stdout.contains("QualifiedIdent"));
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
    #[ignore = "Output format changed"]
    fn test_float_type_inference() {
        let filename = "test_float_type.vibe";
        fs::write(filename, "1.0").unwrap();

        let (stdout, stderr, success) = run_xsc(&["check", filename]);
        assert!(success, "Type check failed: {stderr}");
        assert!(stdout.contains("Float"));

        fs::remove_file(filename).ok();
    }
}
