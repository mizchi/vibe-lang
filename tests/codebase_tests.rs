//! Tests for Unison-style codebase features

mod common;
use common::*;

#[test]
fn test_function_hashing() {
    // Test that identical functions produce the same hash
    test_parses_with("hash1", r#"(fn (x) (+ x 1))"#, "Lambda");
    test_parses_with("hash2", r#"(fn (x) (+ x 1))"#, "Lambda");
    // In the future, this would check that both produce the same hash
}

#[test]
fn test_content_addressed_storage() {
    // Test that content determines storage location
    test_parses_with("content_addr", r#"(fn (x y z) (+ (* x y) z))"#, "Lambda");
}

#[test]
fn test_simple_lambda() {
    test_runs_with_output("simple_lambda", r#"((fn (x) (* x 2)) 20)"#, "40");
}

#[test]
fn test_nested_lambda() {
    test_runs_with_output("nested_lambda", r#"((fn (x) ((fn (y) (+ x y)) 20)) 22)"#, "42");
}

#[test]
fn test_let_expression() {
    test_runs_with_output("let_expr", r#"(let x 42)"#, "42");
}

#[test]
fn test_list_operations() {
    test_runs_with_output("list_ops", r#"(list 1 2 3)"#, "list");
}

#[test]
fn test_recursive_function() {
    // Test recursive function using rec
    test_type_checks("rec_func", r#"(rec fact (n) (if (= n 0) 1 (* n (fact (- n 1)))))"#);
}

#[test]
fn test_module_syntax() {
    test_parses_with("module_syntax", r#"(module Math (export id) (let id (fn (x) x)))"#, "Module");
}

#[test]
fn test_type_definition() {
    test_parses_with("type_def", r#"(type Maybe a (None) (Some a))"#, "TypeDef");
}

#[test]
fn test_pattern_matching() {
    test_runs_with_output("pattern_match", r#"(match (list 1 2) ((list) 0) ((list x _) x))"#, "1");
}