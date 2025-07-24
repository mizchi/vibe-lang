//! Tests for the print builtin function

use vibe_compiler::type_check;
use vibe_core::parser::parse;
use vibe_core::Value;
use vibe_runtime::eval;

#[test]
fn test_print_returns_value() {
    let source = "print 42";
    let expr = parse(source).unwrap();
    type_check(&expr).unwrap();
    let result = eval(&expr).unwrap();
    assert_eq!(result, Value::Int(42));
}

#[test]
fn test_print_string() {
    let source = r#"print "Hello""#;
    let expr = parse(source).unwrap();
    type_check(&expr).unwrap();
    let result = eval(&expr).unwrap();
    assert_eq!(result, Value::String("Hello".to_string()));
}

#[test]
fn test_print_list() {
    let source = "print [1, 2, 3]";
    let expr = parse(source).unwrap();
    type_check(&expr).unwrap();
    let result = eval(&expr).unwrap();
    match result {
        Value::List(elems) => {
            assert_eq!(elems.len(), 3);
            assert_eq!(elems[0], Value::Int(1));
            assert_eq!(elems[1], Value::Int(2));
            assert_eq!(elems[2], Value::Int(3));
        }
        _ => panic!("Expected list"),
    }
}

#[test]
fn test_print_chaining() {
    // print returns its argument, so it can be chained
    let source = "(print 5) + (print 10)";
    let expr = parse(source).unwrap();
    type_check(&expr).unwrap();
    let result = eval(&expr).unwrap();
    assert_eq!(result, Value::Int(15));
}

#[test]
#[ignore = "Print function syntax not fully supported"]
fn test_print_polymorphic() {
    // Test that print works with different types
    let sources = vec![
        "print 42",
        r#"print "text""#,
        "print true",
        "print [1, 2]",
        "print fn x -> x",
    ];

    for source in sources {
        let expr = parse(source).unwrap();
        // Should type check successfully
        type_check(&expr).unwrap();
    }
}
