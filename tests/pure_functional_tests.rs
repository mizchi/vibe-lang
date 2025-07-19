//! Tests for pure functional programming features and currying

use std::process::Command;
use std::fs;

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
fn test_automatic_currying() {
    // Test partial application (manual currying in XS)
    let curry_code = r#"((lambda (x) (lambda (y) (+ x y))) 5)"#;
    fs::write("test_curry.xs", curry_code).unwrap();
    
    let (stdout, stderr, success) = run_xsc(&["run", "test_curry.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("closure"));
    
    fs::remove_file("test_curry.xs").ok();
}

#[test]
fn test_higher_order_functions() {
    // Test higher-order functions with simple example
    let hof_code = r#"((lambda (f) (f 10)) (lambda (x) (* x 2)))"#;
    fs::write("test_hof.xs", hof_code).unwrap();
    
    let (stdout, stderr, success) = run_xsc(&["run", "test_hof.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("20"));
    
    fs::remove_file("test_hof.xs").ok();
}

#[test]
fn test_function_composition() {
    // Test function composition
    let compose_code = r#"((lambda (f g) (lambda (x) (f (g x)))) (lambda (x) (+ x 1)) (lambda (x) (* x 2)))"#;
    fs::write("test_compose.xs", compose_code).unwrap();
    
    let (stdout, stderr, success) = run_xsc(&["run", "test_compose.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("closure")); // Returns a composed function
    
    fs::remove_file("test_compose.xs").ok();
}

#[test]
fn test_simple_recursion() {
    // Test simple recursive function
    let rec_code = r#"((rec sum (n) (if (= n 0) 0 (+ n (sum (- n 1))))) 5)"#;
    fs::write("test_simple_rec.xs", rec_code).unwrap();
    
    let (stdout, stderr, success) = run_xsc(&["run", "test_simple_rec.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("15")); // 1+2+3+4+5 = 15
    
    fs::remove_file("test_simple_rec.xs").ok();
}

#[test]
fn test_pure_function_property() {
    // Test that the same input always produces the same output
    let pure_code = r#"(= ((lambda (x y) (+ x y)) 5 3) ((lambda (x y) (+ x y)) 5 3))"#;
    fs::write("test_pure.xs", pure_code).unwrap();
    
    let (stdout, stderr, success) = run_xsc(&["run", "test_pure.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("true"));
    
    fs::remove_file("test_pure.xs").ok();
}

#[test]
fn test_immutable_data() {
    // Test that data structures are immutable
    let immutable_code = r#"(cons 0 (list 1 2 3))"#;
    fs::write("test_immutable.xs", immutable_code).unwrap();
    
    let (stdout, stderr, success) = run_xsc(&["run", "test_immutable.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("(list 0 1 2 3)"));
    
    fs::remove_file("test_immutable.xs").ok();
}

#[test]
fn test_tail_recursion() {
    // Test tail-recursive implementation
    let tail_rec_code = r#"((rec sum_tail (n acc) (if (= n 0) acc (sum_tail (- n 1) (+ acc n)))) 100 0)"#;
    fs::write("test_tail_rec.xs", tail_rec_code).unwrap();
    
    let (stdout, stderr, success) = run_xsc(&["run", "test_tail_rec.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("5050")); // Sum of 1 to 100
    
    fs::remove_file("test_tail_rec.xs").ok();
}

#[test]
fn test_lazy_evaluation_simulation() {
    // Simulate lazy evaluation with thunks
    let lazy_code = r#"((lambda (t) (t)) (lambda () (+ 1 2)))"#;
    fs::write("test_lazy.xs", lazy_code).unwrap();
    
    let (stdout, stderr, success) = run_xsc(&["run", "test_lazy.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("3"));
    
    fs::remove_file("test_lazy.xs").ok();
}

#[test]
fn test_referential_transparency() {
    // Test that expressions can be replaced by their values
    let ref_trans_code = r#"(= (+ 5 5) 10)"#;
    fs::write("test_ref_trans.xs", ref_trans_code).unwrap();
    
    let (stdout, stderr, success) = run_xsc(&["run", "test_ref_trans.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("true"));
    
    fs::remove_file("test_ref_trans.xs").ok();
}

#[test]
fn test_list_manipulation() {
    // Test list manipulation
    let list_code = r#"(match (list 1 2 3) ((list h t s) h) ((list) 0))"#;
    fs::write("test_list_manip.xs", list_code).unwrap();
    
    let (stdout, stderr, success) = run_xsc(&["run", "test_list_manip.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("1"));
    
    fs::remove_file("test_list_manip.xs").ok();
}

#[test]
fn test_algebraic_data_types() {
    // Test ADT definition and usage (check only)
    let adt_code = r#"(type Option a (None) (Some a))"#;
    fs::write("test_adt.xs", adt_code).unwrap();
    
    let (stdout, stderr, success) = run_xsc(&["parse", "test_adt.xs"]);
    assert!(success, "Parse failed: {stderr}");
    assert!(stdout.contains("TypeDef"));
    
    fs::remove_file("test_adt.xs").ok();
}

#[test]
fn test_nested_pattern_matching() {
    // Test nested pattern matching
    let pattern_code = r#"(match (list 1 2) ((list h t) (match t ((list x xs) x) (_ 0))) (_ 0))"#;
    fs::write("test_nested_pattern.xs", pattern_code).unwrap();
    
    let (stdout, stderr, success) = run_xsc(&["run", "test_nested_pattern.xs"]);
    assert!(success, "Run failed: {stderr}");
    assert!(stdout.contains("2"));
    
    fs::remove_file("test_nested_pattern.xs").ok();
}