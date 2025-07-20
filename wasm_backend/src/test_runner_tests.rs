use super::*;
use std::fs;
use std::path::Path;

fn create_test_file(dir: &Path, name: &str, content: &str) -> PathBuf {
    let path = dir.join(format!("{}.xs", name));
    fs::write(&path, content).unwrap();
    path
}

#[test]
fn test_parse_expectation() {
    let test_cases = vec![
        ("; expect: 42", Some(TestExpectation::ValueI32(42))),
        ("; expect: -123", Some(TestExpectation::ValueI32(-123))),
        ("; expect: true", Some(TestExpectation::ValueI32(1))),
        ("; expect: false", Some(TestExpectation::ValueI32(0))),
        ("; expect: success", Some(TestExpectation::Success)),
        (
            "; expect-error: \"Division by zero\"",
            Some(TestExpectation::Error("Division by zero".to_string())),
        ),
        (
            "; expect-type-error: \"Type mismatch\"",
            Some(TestExpectation::TypeError("Type mismatch".to_string())),
        ),
        (
            "; expect-parse-error: \"Unexpected token\"",
            Some(TestExpectation::ParseError("Unexpected token".to_string())),
        ),
        ("(+ 1 2)", None),
    ];

    for (content, expected) in test_cases {
        let result = XsTest::parse_expectation(content);
        assert_eq!(result, expected, "Failed for content: {}", content);
    }
}

#[test]
fn test_xs_test_from_file() {
    use tempfile::TempDir;
    let temp_dir = TempDir::new().unwrap();
    let content = r#"
; expect: 42
(+ 40 2)
"#;
    let path = create_test_file(temp_dir.path(), "test_add", content);

    let test = XsTest::from_file(&path).unwrap();
    assert_eq!(test.name, "test_add");
    assert!(matches!(test.expected, Some(TestExpectation::ValueI32(42))));
}

#[test]
fn test_suite_result_summary() {
    let mut results = TestSuiteResult::new();
    results.tests.push(("test1".to_string(), TestResult::Pass));
    results.tests.push((
        "test2".to_string(),
        TestResult::Fail("Expected 42, got 41".to_string()),
    ));
    results.tests.push((
        "test3".to_string(),
        TestResult::Error("Parse error".to_string()),
    ));
    results
        .tests
        .push(("test4".to_string(), TestResult::Skipped));

    results.passed = 1;
    results.failed = 1;
    results.errors = 1;
    results.skipped = 1;

    assert!(!results.all_passed());

    // Test with all passed
    let mut success_results = TestSuiteResult::new();
    success_results.passed = 5;
    assert!(success_results.all_passed());
}

#[test]
fn test_float_expectation() {
    let content = "; expect: 3.14";
    let expectation = XsTest::parse_expectation(content);
    assert!(matches!(expectation, Some(TestExpectation::ValueF64(_))));
}

#[test]
fn test_i64_expectation() {
    let content = "; expect: 9223372036854775807"; // Max i64
    let expectation = XsTest::parse_expectation(content);
    assert!(matches!(
        expectation,
        Some(TestExpectation::ValueI64(9223372036854775807))
    ));
}

#[test]
fn test_test_result_enum() {
    // Test TestResult enum variants
    match TestResult::Pass {
        TestResult::Pass => assert!(true),
        _ => panic!("Expected Pass"),
    }

    match TestResult::Fail("error".to_string()) {
        TestResult::Fail(msg) => assert_eq!(msg, "error"),
        _ => panic!("Expected Fail"),
    }

    match TestResult::Error("error".to_string()) {
        TestResult::Error(msg) => assert_eq!(msg, "error"),
        _ => panic!("Expected Error"),
    }

    match TestResult::Skipped {
        TestResult::Skipped => assert!(true),
        _ => panic!("Expected Skipped"),
    }
}

#[test]
fn test_test_expectation_enum() {
    // Test all TestExpectation variants
    assert_eq!(TestExpectation::ValueI32(42), TestExpectation::ValueI32(42));
    assert_eq!(
        TestExpectation::ValueI64(100),
        TestExpectation::ValueI64(100)
    );
    assert_eq!(
        TestExpectation::ValueF64(123),
        TestExpectation::ValueF64(123)
    );
    assert_eq!(TestExpectation::Success, TestExpectation::Success);
    assert_eq!(
        TestExpectation::Error("msg".to_string()),
        TestExpectation::Error("msg".to_string())
    );
    assert_eq!(
        TestExpectation::TypeError("type".to_string()),
        TestExpectation::TypeError("type".to_string())
    );
    assert_eq!(
        TestExpectation::ParseError("parse".to_string()),
        TestExpectation::ParseError("parse".to_string())
    );
}
