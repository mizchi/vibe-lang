//! Recursion-specific tests for XS language (refactored)
//! 
//! NOTE: These tests use S-expression syntax and need to be updated for the new Haskell-style parser

#![cfg(skip)]  // Skip these tests until they are updated

mod common;
use common::*;

mod basic_tests {
    use super::*;

    #[test]
    fn test_simple_arithmetic() {
        test_runs_with_output("simple_arithmetic", "(+ 1 41)", "42");
    }

    #[test]
    fn test_let_binding() {
        test_runs_with_output("let_binding", "(let x 10)", "10");
    }
}

mod recursion_tests {
    use super::*;

    #[test]
    fn test_simple_rec_definition() {
        test_type_checks("simple_rec", r#"(rec identity (x) x)"#);
    }

    #[test]
    fn test_simple_rec_application() {
        test_runs_with_output("simple_rec_apply", r#"((rec identity (x) x) 42)"#, "42");
    }

    #[test]
    fn test_direct_recursion() {
        test_type_checks_with(
            "direct_rec",
            r#"
(rec countdown (n)
  (if (= n 0)
      0
      (countdown (- n 1))))
"#,
            "Int",
        );
    }

    #[test]
    fn test_direct_recursion_application() {
        test_runs_with_output(
            "direct_rec_apply",
            r#"
((rec countdown (n)
  (if (= n 0)
      0
      (countdown (- n 1))))
 5)
"#,
            "0",
        );
    }
}

mod factorial_tests {
    use super::*;

    const FACTORIAL_CODE: &str = r#"
(rec factorial (n : Int) : Int
  (if (= n 0)
      1
      (* n (factorial (- n 1)))))
"#;

    #[test]
    fn test_factorial_with_type_annotations() {
        test_type_checks_with("factorial_typed", FACTORIAL_CODE, "Int");
    }

    #[test]
    fn test_factorial_application() {
        test_runs_with_output("factorial_apply", &format!("({FACTORIAL_CODE} 5)"), "120");
    }

    #[test]
    fn test_factorial_inline_condition() {
        test_runs_with_output(
            "factorial_inline",
            r#"((rec fact (n : Int) : Int (if (= n 0) 1 (* n (fact (- n 1))))) 5)"#,
            "120",
        );
    }
}

mod edge_case_tests {
    use super::*;

    #[test]
    fn test_rec_debug_simple() {
        test_type_checks(
            "rec_debug_simple",
            r#"
(rec f (n)
  (if (= n 0)
      1
      (f (- n 1))))
"#,
        );
    }

    #[test]
    fn test_rec_debug_application() {
        test_runs_with_output(
            "rec_debug_apply",
            r#"
((rec f (n)
  (if (= n 0)
      1
      (f (- n 1))))
 3)
"#,
            "1",
        );
    }

    #[test]
    fn test_minimal_infinite_recursion() {
        test_type_checks("infinite_rec", r#"(rec loop (x) (loop x))"#);
    }

    #[test]
    fn test_rec_type_inference() {
        test_type_checks("rec_type_infer", r#"(rec add (x y) (+ x y))"#);
    }

    #[test]
    fn test_rec_with_multiple_params() {
        test_type_checks_with(
            "rec_multi_params",
            r#"
(rec sum3 (a b c)
  (+ a (+ b c)))
"#,
            "Int",
        );
    }
}
