//! End-to-end tests for XS Shell
//!
//! These tests run actual XS code through the shell and verify the output.
//! Each test case contains the input expression and expected output.

use tempfile::TempDir;
use xsh::shell::ShellState;

/// A test case for shell evaluation
#[derive(Debug)]
struct TestCase {
    name: &'static str,
    input: &'static str,
    expected_output: &'static str,
    should_fail: bool,
}

/// Run a test case through the shell
fn run_test_case(shell: &mut ShellState, test: &TestCase) -> Result<String, String> {
    shell.evaluate_line(test.input).map_err(|e| e.to_string())
}

/// Basic expression tests
fn basic_tests() -> Vec<TestCase> {
    vec![
        TestCase {
            name: "int_literal",
            input: "42",
            expected_output: "42 : Int",
            should_fail: false,
        },
        TestCase {
            name: "string_literal",
            input: r#""hello""#,
            expected_output: r#""hello" : String"#,
            should_fail: false,
        },
        TestCase {
            name: "bool_true",
            input: "true",
            expected_output: "true : Bool",
            should_fail: false,
        },
        TestCase {
            name: "bool_false",
            input: "false",
            expected_output: "false : Bool",
            should_fail: false,
        },
        TestCase {
            name: "list_empty",
            input: "(list)",
            expected_output: "(list ) : (List t0)",
            should_fail: false,
        },
        TestCase {
            name: "list_ints",
            input: "(list 1 2 3)",
            expected_output: "(list 1 2 3) : (List Int)",
            should_fail: false,
        },
    ]
}

/// Arithmetic tests
fn arithmetic_tests() -> Vec<TestCase> {
    vec![
        TestCase {
            name: "add",
            input: "(+ 1 2)",
            expected_output: "3 : Int",
            should_fail: false,
        },
        TestCase {
            name: "subtract",
            input: "(- 10 3)",
            expected_output: "7 : Int",
            should_fail: false,
        },
        TestCase {
            name: "multiply",
            input: "(* 4 5)",
            expected_output: "20 : Int",
            should_fail: false,
        },
        TestCase {
            name: "divide",
            input: "(/ 10 2)",
            expected_output: "5 : Int",
            should_fail: false,
        },
        TestCase {
            name: "nested_arithmetic",
            input: "(+ (* 2 3) (- 10 5))",
            expected_output: "11 : Int",
            should_fail: false,
        },
    ]
}

/// String operation tests
fn string_tests() -> Vec<TestCase> {
    vec![
        TestCase {
            name: "str_concat",
            input: r#"(concat "hello" " world")"#,
            expected_output: r#""hello world" : String"#,
            should_fail: false,
        },
        TestCase {
            name: "int_to_string",
            input: "(intToString 42)",
            expected_output: r#""42" : String"#,
            should_fail: false,
        },
        TestCase {
            name: "string_to_int",
            input: r#"(stringToInt "123")"#,
            expected_output: "123 : Int",
            should_fail: false,
        },
    ]
}

/// Function definition tests
fn function_tests() -> Vec<TestCase> {
    vec![
        TestCase {
            name: "simple_function",
            input: "(let double (fn (x) (* x 2)))",
            expected_output: "double : (-> t0 Int)",
            should_fail: false,
        },
        TestCase {
            name: "function_application",
            input: "(double 21)",
            expected_output: "42 : Int",
            should_fail: false,
        },
        TestCase {
            name: "higher_order_function",
            input: "(let twice (fn (f x) (f (f x))))",
            expected_output: "twice : (-> t0 (-> t1 t3))",
            should_fail: false,
        },
        TestCase {
            name: "partial_application",
            input: "(let add (fn (x y) (+ x y)))",
            expected_output: "add : (-> t0 (-> t1 Int))",
            should_fail: false,
        },
    ]
}

/// List operation tests
fn list_tests() -> Vec<TestCase> {
    vec![TestCase {
        name: "cons",
        input: "(cons 0 (list 1 2))",
        expected_output: "(list 0 1 2) : (List Int)",
        should_fail: false,
    }]
}

/// Pattern matching tests
fn pattern_tests() -> Vec<TestCase> {
    vec![
        TestCase {
            name: "match_list_empty",
            input: "(match (list) ((list) 0) ((list h t) 1))",
            expected_output: "0 : Int",
            should_fail: false,
        },
        TestCase {
            name: "match_list_nonempty",
            input: "(match (list 1 2 3) ((list) 0) ((list h t) h))",
            expected_output: "1 : Int",
            should_fail: false,
        },
        TestCase {
            name: "match_bool",
            input: "(match true (true 1) (false 0))",
            expected_output: "1 : Int",
            should_fail: false,
        },
    ]
}

/// Let-in expression tests
fn let_in_tests() -> Vec<TestCase> {
    vec![
        TestCase {
            name: "simple_let_in",
            input: "(let x 10 in (+ x 5))",
            expected_output: "15 : Int",
            should_fail: false,
        },
        TestCase {
            name: "nested_let_in",
            input: "(let x 5 in (let y 10 in (* x y)))",
            expected_output: "50 : Int",
            should_fail: false,
        },
        TestCase {
            name: "let_in_with_function",
            input: "(let f (fn (x) (* x 2)) in (f 10))",
            expected_output: "20 : Int",
            should_fail: false,
        },
    ]
}

/// Recursive function tests
fn recursive_tests() -> Vec<TestCase> {
    vec![
        TestCase {
            name: "factorial_def",
            input: "(rec factorial (n) (if (= n 0) 1 (* n (factorial (- n 1)))))",
            expected_output: "<rec-closure> : (-> Int Int)",
            should_fail: false,
        },
        TestCase {
            name: "factorial_5",
            input: "(factorial 5)",
            expected_output: "120 : Int",
            should_fail: false,
        },
        TestCase {
            name: "fibonacci_def",
            input: "(rec fib (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))",
            expected_output: "<rec-closure> : (-> Int Int)",
            should_fail: false,
        },
        TestCase {
            name: "fibonacci_10",
            input: "(fib 10)",
            expected_output: "55 : Int",
            should_fail: false,
        },
    ]
}

/// Error case tests
fn error_tests() -> Vec<TestCase> {
    vec![
        TestCase {
            name: "undefined_variable",
            input: "undefined_var",
            expected_output: "Type inference failed",
            should_fail: true,
        },
        TestCase {
            name: "type_error_add_string",
            input: r#"(+ "hello" 42)"#,
            expected_output: "Type inference failed",
            should_fail: true,
        },
        TestCase {
            name: "divide_by_zero",
            input: "(/ 10 0)",
            expected_output: "Evaluation failed",
            should_fail: true,
        },
    ]
}

/// Load and evaluate existing test files
fn load_test_file(_shell: &mut ShellState, path: &str) -> Vec<TestCase> {
    let mut cases = Vec::new();

    // Read the file
    if let Ok(content) = std::fs::read_to_string(path) {
        // Extract the file name for test naming
        let file_name = std::path::Path::new(path)
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("unknown");

        // For simple test files, evaluate the whole file
        cases.push(TestCase {
            name: Box::leak(format!("file_{}", file_name).into_boxed_str()),
            input: Box::leak(content.into_boxed_str()),
            expected_output: "", // Will be determined by actual evaluation
            should_fail: path.contains("fail") || path.contains("error"),
        });
    }

    cases
}

#[test]
fn test_shell_e2e_basic() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    for test in basic_tests() {
        let result = run_test_case(&mut shell, &test);

        if test.should_fail {
            assert!(result.is_err(), "Test {} should have failed", test.name);
        } else {
            assert!(result.is_ok(), "Test {} failed: {:?}", test.name, result);
            let output = result.unwrap();
            assert!(
                output.contains(test.expected_output),
                "Test {} output mismatch.\nExpected: {}\nActual: {}",
                test.name,
                test.expected_output,
                output
            );
        }
    }
}

#[test]
fn test_shell_e2e_arithmetic() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    for test in arithmetic_tests() {
        let result = run_test_case(&mut shell, &test);
        assert!(result.is_ok(), "Test {} failed: {:?}", test.name, result);
        let output = result.unwrap();
        assert!(
            output.contains(test.expected_output),
            "Test {} output mismatch.\nExpected: {}\nActual: {}",
            test.name,
            test.expected_output,
            output
        );
    }
}

#[test]
fn test_shell_e2e_strings() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    for test in string_tests() {
        let result = run_test_case(&mut shell, &test);
        assert!(result.is_ok(), "Test {} failed: {:?}", test.name, result);
        let output = result.unwrap();
        assert!(
            output.contains(test.expected_output),
            "Test {} output mismatch.\nExpected: {}\nActual: {}",
            test.name,
            test.expected_output,
            output
        );
    }
}

#[test]
fn test_shell_e2e_functions() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    // Run function tests in order (some depend on previous definitions)
    for test in function_tests() {
        let result = run_test_case(&mut shell, &test);
        assert!(result.is_ok(), "Test {} failed: {:?}", test.name, result);
        let output = result.unwrap();
        assert!(
            output.contains(test.expected_output),
            "Test {} output mismatch.\nExpected: {}\nActual: {}",
            test.name,
            test.expected_output,
            output
        );
    }
}

#[test]
fn test_shell_e2e_lists() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    for test in list_tests() {
        let result = run_test_case(&mut shell, &test);
        assert!(result.is_ok(), "Test {} failed: {:?}", test.name, result);
        let output = result.unwrap();
        assert!(
            output.contains(test.expected_output),
            "Test {} output mismatch.\nExpected: {}\nActual: {}",
            test.name,
            test.expected_output,
            output
        );
    }
}

#[test]
fn test_shell_e2e_patterns() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    for test in pattern_tests() {
        let result = run_test_case(&mut shell, &test);
        assert!(result.is_ok(), "Test {} failed: {:?}", test.name, result);
        let output = result.unwrap();
        assert!(
            output.contains(test.expected_output),
            "Test {} output mismatch.\nExpected: {}\nActual: {}",
            test.name,
            test.expected_output,
            output
        );
    }
}

#[test]
fn test_shell_e2e_let_in() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    for test in let_in_tests() {
        let result = run_test_case(&mut shell, &test);
        assert!(result.is_ok(), "Test {} failed: {:?}", test.name, result);
        let output = result.unwrap();
        assert!(
            output.contains(test.expected_output),
            "Test {} output mismatch.\nExpected: {}\nActual: {}",
            test.name,
            test.expected_output,
            output
        );
    }
}

#[test]
fn test_shell_e2e_recursive() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    // Run recursive tests in order
    for test in recursive_tests() {
        let result = run_test_case(&mut shell, &test);
        assert!(result.is_ok(), "Test {} failed: {:?}", test.name, result);
        let output = result.unwrap();
        assert!(
            output.contains(test.expected_output),
            "Test {} output mismatch.\nExpected: {}\nActual: {}",
            test.name,
            test.expected_output,
            output
        );
    }
}

#[test]
fn test_shell_e2e_errors() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    for test in error_tests() {
        let result = run_test_case(&mut shell, &test);
        assert!(
            result.is_err(),
            "Test {} should have failed but succeeded with: {:?}",
            test.name,
            result
        );
        if !test.expected_output.is_empty() {
            let error = result.unwrap_err();
            assert!(
                error.contains(test.expected_output),
                "Test {} error mismatch.\nExpected error containing: {}\nActual: {}",
                test.name,
                test.expected_output,
                error
            );
        }
    }
}

/// Test for code repository integration
#[test]
fn test_shell_e2e_repository_tracking() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    // Code repository is automatically enabled for new shells

    // Define some functions
    shell
        .evaluate_line("(let myAdd (fn (x y) (+ x y)))")
        .unwrap();
    shell
        .evaluate_line("(let myDouble (fn (x) (* x 2)))")
        .unwrap();
    shell
        .evaluate_line("(let myQuadruple (fn (x) (myDouble (myDouble x))))")
        .unwrap();

    // These should all be tracked in the repository
    // Verify by checking the database exists
    let db_path = temp_dir.path().join("code_repository.db");
    assert!(db_path.exists(), "Code repository database should exist");
}
