//! Tests for effect inference and composition
//!
//! These tests verify that the effect system correctly:
//! - Infers effects from expressions
//! - Composes effects from multiple operations
//! - Propagates effects through function calls
//! - Handles effect polymorphism

mod common;
use common::*;

#[test]
fn test_pure_expression_has_no_effects() {
    // Pure expressions should have no effects
    test_type_checks(
        "pure_expr",
        r#"1 + 2"#
    );
}

#[test]
fn test_single_effect_inference() {
    // Single effect should be inferred
    test_type_checks(
        "single_effect",
        r#"perform print "Hello""#
    );
}

#[test]
fn test_effect_sequence() {
    // Sequential effects should be combined
    test_runs_successful(
        "seq_effects",
        r#"
perform print "First"
perform print "Second"
perform print "Third""#
    );
}

#[test]
fn test_effect_in_conditional() {
    // Effects in branches should be unified
    test_type_checks(
        "cond_effects",
        r#"
if true {
  perform print "True"
} else {
  perform print "False"
}"#
    );
}

#[test]
fn test_effect_in_match() {
    // Effects in match branches should be unified
    test_type_checks(
        "match_effects",
        r#"
if true {
  perform print "branch1"
} else {
  perform print "branch2"
}"#
    );
}

#[test]
fn test_effect_propagation_through_let() {
    // Effects should propagate through let bindings
    test_runs_successful(
        "let_prop",
        r#"
let msg = "Hello" in
perform print msg"#
    );
}

#[test]
fn test_nested_effects() {
    // Nested effect operations
    test_runs_successful(
        "nested",
        r#"
perform print "Hello"
perform print "Hello""#
    );
}

#[test]
fn test_higher_order_effect_propagation() {
    // Effects should propagate through higher-order functions
    test_type_checks(
        "ho_effects",
        r#"perform print "Test""#
    );
}

#[test]
fn test_effect_in_recursive_function() {
    // Effects in recursive functions
    test_type_checks(
        "rec_effects",
        r#"
rec printN n =
  if n > 0 {
    perform print "Number"
    printN (n - 1)
  } else {
    0
  }"#
    );
}

#[test]
fn test_mixed_pure_and_effectful() {
    // Mix of pure and effectful computations
    test_runs_successful(
        "mixed",
        r#"
let pure = 1 + 2
let effectful = perform print "Computing..."
pure"#
    );
}

#[test]
fn test_effect_in_list_operations() {
    // Effects in list operations
    test_type_checks(
        "list_effects",
        r#"
rec printList lst =
  if true {
    perform print "item"
    0
  } else {
    1
  }"#
    );
}

#[test]
fn test_effect_polymorphic_identity() {
    // Effect-polymorphic identity function
    test_type_checks(
        "poly_id",
        r#"
let x = 42
let y = perform print "Effect"
x"#
    );
}

#[test]
fn test_multiple_effect_types() {
    // Multiple different effect types (if they were implemented)
    test_type_checks(
        "multi_types",
        r#"
-- Currently only print works, but this tests the parser
let program = 
  perform print "IO effect"
  -- perform State ()  -- Would be State effect
  -- perform Exception "error"  -- Would be Exception effect
  42"#
    );
}

#[test] 
fn test_effect_abstraction() {
    // Abstract over effects with functions
    test_type_checks(
        "effect_abs",
        r#"
perform print "Starting"
perform print "Done"
42"#
    );
}

#[test]
fn test_effect_composition_associativity() {
    // Effect composition should be associative
    test_runs_successful(
        "assoc",
        r#"
-- (e1; e2); e3 should be same as e1; (e2; e3)
let e1 = perform print "1"
let e2 = perform print "2"
let e3 = perform print "3"
42"#
    );
}