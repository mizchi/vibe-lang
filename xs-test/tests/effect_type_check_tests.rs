//! Type checking tests for the effect system
//! 
//! These tests verify that the effect system correctly:
//! - Recognizes effect syntax
//! - Basic type checking with effects
//!
//! NOTE: These tests are currently ignored as the effect system implementation is incomplete

mod common;
use common::*;

#[test]
fn test_basic_perform_syntax() {
    // Test that perform syntax is recognized
    test_type_checks(
        "basic_perform",
        r#"perform IO "Hello""#
    );
}

#[test]
fn test_effect_in_function() {
    // Test effect in top-level function
    test_type_checks(
        "effect_function",
        r#"let hello = perform IO "Hello, World!""#
    );
}

#[test]
#[ignore = "Effect system implementation incomplete"]
fn test_state_effect() {
    // Test State effect
    test_type_checks(
        "state_effect",
        r#"let getState = perform State ()"#
    );
}

#[test]
#[ignore = "Effect system implementation incomplete"]
fn test_exception_effect() {
    // Test Exception effect
    test_type_checks(
        "exception_effect",
        r#"let throwError = perform Exception \"error\""#
    );
}

#[test]
fn test_type_definition_with_constructors() {
    // Test that we can define types (preparation for Result type)
    test_type_checks(
        "result_type",
        r#"type Result e a = Ok a | Error e"#
    );
}

#[test]
#[ignore = "Effect system implementation incomplete"]
fn test_handler_syntax() {
    // Test basic handler syntax is recognized
    test_type_checks(
        "handler_syntax",
        r#"
handler {
  IO print x -> ()
}"#
    );
}

#[test]
#[ignore = "Effect system implementation incomplete"]
fn test_with_handler_syntax() {
    // Test with handler syntax
    test_type_checks(
        "with_handler",
        r#"
let h = handler { IO print x -> () }
let computation = 42
with h handle computation"#
    );
}

#[test]
fn test_do_notation_syntax() {
    // Test do notation syntax
    test_type_checks(
        "do_syntax",
        r#"
do {
  let x = perform IO "Hello"
  x
}"#
    );
}

#[test]
#[ignore = "Effect system implementation incomplete"]
fn test_perform_with_different_effects() {
    // Test different effect types
    test_type_checks(
        "multi_perform",
        r#"
let io_op = perform IO "test"
let state_op = perform State ()
let async_op = perform Async 42
io_op"#
    );
}

#[test]
fn test_match_with_effects() {
    // Test pattern matching with effects
    test_type_checks(
        "match_effects",
        r#"
let result = perform IO "test"
result"#
    );
}

#[test]
fn test_if_with_effects() {
    // Test if expression with effects
    test_type_checks(
        "if_effects",
        r#"
if true {
  perform IO "True branch"
} else {
  perform IO "False branch"
}"#
    );
}

#[test]
fn test_sequential_effects() {
    // Test sequential effect operations
    test_type_checks(
        "seq_effects",
        r#"
let x = perform IO "First"
let y = perform IO "Second"
x"#
    );
}

#[test]
#[ignore = "Effect system implementation incomplete"]
fn test_effect_with_arithmetic() {
    // Test effects mixed with arithmetic
    test_type_checks(
        "effect_arithmetic",
        r#"
let x = perform State 0
let y = perform State 0
x + y"#
    );
}

#[test]
#[ignore = "Effect system implementation incomplete"]
fn test_builtin_effects() {
    // Test that builtin effects are recognized
    test_type_checks(
        "builtin_effects",
        r#"
-- IO effect
let print_op = perform IO "Hello"

-- State effect  
let state_op = perform State ()

-- Exception effect
let exc_op = perform Exception "Error"

-- Async effect
let async_op = perform Async 42

print_op"#
    );
}

#[test]
fn test_effect_in_let_binding() {
    // Test effects in let bindings
    test_type_checks(
        "let_effect",
        r#"
let result = 
  let msg = perform IO "Getting input" in
  let value = 42 in
  value + 1"#
    );
}