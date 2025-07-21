//! Tests for standard library functions

use std::fs;
use std::process::Command;

fn run_xsc(args: &[&str]) -> (String, String, bool) {
    let output = Command::new("cargo")
        .args(["run", "-p", "xs-tools", "--bin", "xsc", "--"])
        .args(args)
        .output()
        .expect("Failed to execute xsc");

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    (stdout, stderr, output.status.success())
}

mod core_tests {
    use super::*;

    #[test]
    fn test_compose() {
        let code = r#"(((fn (f g) (fn (x) (f (g x)))) (fn (x) (+ x 1)) (fn (x) (* x 2))) 5)"#;
        fs::write("test_compose.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_compose.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("11")); // (5 * 2) + 1 = 11

        fs::remove_file("test_compose.xs").ok();
    }

    #[test]
    fn test_identity() {
        let code = r#"((fn (x) x) 42)"#;
        fs::write("test_id.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_id.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("42"));

        fs::remove_file("test_id.xs").ok();
    }

    #[test]
    fn test_flip() {
        let code = r#"(((fn (f) (fn (x y) (f y x))) (fn (x y) (- x y))) 3 10)"#;
        fs::write("test_flip.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_flip.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("7")); // 10 - 3 = 7

        fs::remove_file("test_flip.xs").ok();
    }

    #[test]
    fn test_boolean_ops() {
        let code = r#"(list 
  ((fn (b) (if b false true)) true)
  ((fn (a b) (if a b false)) true false)
  ((fn (a b) (if a true b)) false true))"#;
        fs::write("test_bool.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_bool.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("(list false false true)"));

        fs::remove_file("test_bool.xs").ok();
    }
}

mod list_tests {
    use super::*;

    #[test]
    fn test_length() {
        let code = r#"((rec length (xs)
  (match xs
    ((list) 0)
    ((list h t) (+ 1 (length t))))) (list 1 2 3 4 5))"#;
        fs::write("test_length.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_length.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("5"));

        fs::remove_file("test_length.xs").ok();
    }

    #[test]
    fn test_map() {
        let code = r#"((rec map (f xs)
  (match xs
    ((list) (list))
    ((list h t) (cons (f h) (map f t))))) (fn (x) (* x 2)) (list 1 2 3))"#;
        fs::write("test_map.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_map.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("(list 2 4 6)"));

        fs::remove_file("test_map.xs").ok();
    }

    #[test]
    fn test_filter() {
        let code = r#"((rec filter (p xs)
  (match xs
    ((list) (list))
    ((list h t) 
      (if (p h)
          (cons h (filter p t))
          (filter p t))))) (fn (x) (> x 2)) (list 1 2 3 4))"#;
        fs::write("test_filter.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_filter.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("(list 3 4)"));

        fs::remove_file("test_filter.xs").ok();
    }

    #[test]
    fn test_fold_left() {
        let code = r#"((rec fold-left (f acc xs)
  (match xs
    ((list) acc)
    ((list h t) (fold-left f (f acc h) t)))) + 0 (list 1 2 3 4))"#;
        fs::write("test_fold.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_fold.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("10")); // 1+2+3+4 = 10

        fs::remove_file("test_fold.xs").ok();
    }

    #[test]
    fn test_reverse() {
        let code = r#"((rec reverse (xs)
  ((rec rev-helper (xs acc)
    (match xs
      ((list) acc)
      ((list h t) (rev-helper t (cons h acc))))) xs (list))) (list 1 2 3))"#;
        fs::write("test_reverse.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_reverse.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("(list 3 2 1)"));

        fs::remove_file("test_reverse.xs").ok();
    }
}

mod math_tests {
    use super::*;

    #[test]
    fn test_factorial() {
        let code = r#"((rec factorial (n)
  (if (= n 0)
      1
      (* n (factorial (- n 1))))) 5)"#;
        fs::write("test_factorial.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_factorial.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("120")); // 5! = 120

        fs::remove_file("test_factorial.xs").ok();
    }

    #[test]
    fn test_fibonacci() {
        let code = r#"((rec fib-tail (n)
  ((rec fib-helper (n a b)
    (if (= n 0)
        a
        (fib-helper (- n 1) b (+ a b)))) n 0 1)) 10)"#;
        fs::write("test_fib.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_fib.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("55")); // fib(10) = 55

        fs::remove_file("test_fib.xs").ok();
    }

    #[test]
    fn test_gcd() {
        let code = r#"((rec gcd (a b)
  (if (= b 0)
      a
      (gcd b (% a b)))) 48 18)"#;
        fs::write("test_gcd.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_gcd.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("6")); // gcd(48, 18) = 6

        fs::remove_file("test_gcd.xs").ok();
    }

    #[test]
    fn test_numeric_predicates() {
        let code = r#"(list 
  ((fn (n) (= (% n 2) 0)) 4)
  ((fn (n) ((fn (b) (if b false true)) ((fn (n) (= (% n 2) 0)) n))) 5))"#;
        fs::write("test_preds.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_preds.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("(list true true)"));

        fs::remove_file("test_preds.xs").ok();
    }
}

mod string_tests {
    use super::*;

    #[test]
    fn test_string_concat() {
        let code = r#"(concat "Hello, " "World!")"#;
        fs::write("test_concat.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_concat.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("\"Hello, World!\""));

        fs::remove_file("test_concat.xs").ok();
    }

    #[test]
    fn test_string_repeat() {
        let code = r#"((rec repeat-string (n s)
  (if (= n 0)
      ""
      (concat s (repeat-string (- n 1) s)))) 3 "Hi")"#;
        fs::write("test_repeat.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_repeat.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("\"HiHiHi\""));

        fs::remove_file("test_repeat.xs").ok();
    }
}

mod integration_tests {
    use super::*;

    #[test]
    fn test_list_sum_with_fold() {
        let code = r#"((fn (xs) ((rec fold-left (f acc xs)
  (match xs
    ((list) acc)
    ((list h t) (fold-left f (f acc h) t)))) + 0 xs)) (list 1 2 3 4 5))"#;
        fs::write("test_sum.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_sum.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("15"));

        fs::remove_file("test_sum.xs").ok();
    }

    #[test]
    fn test_range_generation() {
        let code = r#"((rec range (start end)
  (if (> start end)
      (list)
      (cons start (range (+ start 1) end)))) 1 5)"#;
        fs::write("test_range.xs", code).unwrap();

        let (stdout, stderr, success) = run_xsc(&["run", "test_range.xs"]);
        assert!(success, "Run failed: {stderr}");
        assert!(stdout.contains("(list 1 2 3 4 5)"));

        fs::remove_file("test_range.xs").ok();
    }
}
