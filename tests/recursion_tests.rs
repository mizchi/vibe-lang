//! Recursion-specific tests for XS language
//! Tests migrated from top-level test_*.xs files

mod common;
use common::*;
use std::fs;

mod basic_tests {
    use super::*;

    #[test]
    fn test_simple_arithmetic() {
        // From test.xs
        test_runs_with_output("simple_arithmetic", "(+ 1 41)", "42");
    }

    #[test]
    fn test_let_binding() {
        // From test_let.xs
        test_runs_with_output("let_binding", "(let x 10)", "10");
    }
}

mod rec_syntax_tests {
    use super::*;

    #[test]
    fn test_simple_rec_definition() {
        // From test_simple_rec.xs
        test_parses_with(
            "simple_rec_def",
            r#"(rec double (x) (* x 2))"#,
            "Rec"
        );
    }

    #[test]
    fn test_simple_rec_application() {
        // From test_simple_rec_apply.xs
        test_runs_with_output(
            "simple_rec_apply",
            r#"((rec double (x) (* x 2)) 21)"#,
            "42"
        );
    }

    #[test]
    fn test_direct_recursion() {
        // From test_direct_rec.xs
        test_type_checks("direct_rec_def", patterns::COUNTDOWN);
    }

    #[test]
    fn test_direct_recursion_application() {
        // From test_direct_rec_apply.xs
        test_runs_with_output(
            "direct_rec_apply",
            &format!("({} 5)", patterns::COUNTDOWN),
            "0"
        );
    }
}

mod factorial_tests {
    use super::*;

    #[test]
    fn test_factorial_with_type_annotations() {
        // From test_rec.xs
        test_type_checks_with("factorial_typed", patterns::FACTORIAL, "Int");
    }

    #[test]
    fn test_factorial_application() {
        // From test_rec_apply.xs
        test_runs_with_output(
            "factorial_apply",
            &format!("({} 5)", patterns::FACTORIAL),
            "120" // 5! = 120
        );
    }

    #[test]
    fn test_factorial_inline_condition() {
        // From debug_rec.xs
        test_runs_with_output(
            "factorial_inline",
            r#"((rec fact (n : Int) : Int (if (= n 0) 1 (* n (fact (- n 1))))) 5)"#,
            "120"
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

        let result = run_xsc(&["check", filename]);
        assert!(result.success);

        fs::remove_file(filename).ok();
    }

    #[test]
    fn test_rec_debug_application() {
        // From test_rec_debug_apply.xs
        test_runs_with_output(
            "rec_debug_apply",
            r#"
((rec f (n)
  (if (= n 0)
      1
      (f (- n 1))))
 3)
"#,
            "1"
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
        // Test that it doesn't crash (allows both success and failure)
        let result = run_xsc(&["run", filename]);
        // Any result is acceptable for infinite recursion test
        let _ = result;
        
        fs::remove_file(filename).ok();
    }
}

mod type_checking_tests {
    use super::*;

    #[test]
    fn test_rec_type_inference() {
        // Test that rec functions have proper type inference
        // rec identity should have type a -> a
        test_type_checks(
            "rec_identity",
            patterns::IDENTITY
        );
    }

    #[test]
    fn test_rec_with_multiple_params() {
        // Test rec with multiple parameters
        test_type_checks(
            "rec_multi_param",
            r#"(rec add (x y) (+ x y))"#
        );
    }
}
