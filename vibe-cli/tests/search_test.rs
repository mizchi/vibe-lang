//! Tests for code search functionality

use tempfile::TempDir;
use vibe_cli::shell::ShellState;

/// Helper to create a shell with some predefined functions
fn create_test_shell() -> (ShellState, TempDir) {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    // Add some test functions (these are top-level definitions, not let-in expressions)
    let test_functions = vec![
        "double x = x * 2",
        "triple x = x * 3",
        "strLen s = String.length s",
        "isEven n = (n % 2) == 0",
        "letrec factorial n = if n == 0 { 1 } else { n * factorial (n - 1) }",
        "letrec filter pred lst = match lst { [] -> [] | h :: t -> if pred h { h :: filter pred t } else { filter pred t } }",
        "letrec map f lst = match lst { [] -> [] | h :: t -> (f h) :: (map f t) }",
        "add x y = x + y",
        "concat s1 s2 = s1 ++ s2",
    ];

    for code in test_functions {
        // Use the shell's evaluate_line to define the function
        let _result = shell.evaluate_line(code).unwrap();
    }

    (shell, temp_dir)
}

#[test]
fn test_search_by_type_int_to_int() {
    let (shell, _temp_dir) = create_test_shell();

    let results = shell.search_definitions("type:Int -> Int").unwrap();
    assert!(!results.is_empty());

    // Should find double, triple, factorial
    let result_str = results.join("\n");
    assert!(result_str.contains("double"));
    assert!(result_str.contains("triple"));
    assert!(result_str.contains("factorial"));

    // Should not find strLen (String -> Int) or add (Int -> Int -> Int)
    assert!(!result_str.contains("strLen"));
    assert!(!result_str.contains("add"));
}

#[test]
fn test_search_by_type_string_to_int() {
    let (shell, _temp_dir) = create_test_shell();

    let results = shell.search_definitions("type:String -> Int").unwrap();
    assert!(!results.is_empty());

    let result_str = results.join("\n");
    assert!(result_str.contains("strLen"));
    assert!(!result_str.contains("double"));
}

#[test]
fn test_search_by_type_wildcard() {
    let (shell, _temp_dir) = create_test_shell();

    // Search for functions returning Int
    let results = shell.search_definitions("type:_ -> Int").unwrap();
    assert!(!results.is_empty());

    let result_str = results.join("\n");
    assert!(result_str.contains("double"));
    assert!(result_str.contains("triple"));
    assert!(result_str.contains("strLen"));
    assert!(result_str.contains("factorial"));
}

#[test]
fn test_search_by_ast_match() {
    let (shell, _temp_dir) = create_test_shell();

    let results = shell.search_definitions("ast:match").unwrap();
    assert!(!results.is_empty());

    let result_str = results.join("\n");
    assert!(result_str.contains("filter"));
    assert!(result_str.contains("map"));
    assert!(!result_str.contains("double"));
}

#[test]
fn test_search_by_ast_if() {
    let (shell, _temp_dir) = create_test_shell();

    let results = shell.search_definitions("ast:if").unwrap();
    assert!(!results.is_empty());

    let result_str = results.join("\n");
    assert!(result_str.contains("factorial"));
    assert!(result_str.contains("filter"));
    assert!(!result_str.contains("double"));
}

#[test]
fn test_search_by_name() {
    let (shell, _temp_dir) = create_test_shell();

    let results = shell.search_definitions("dou").unwrap();
    assert!(!results.is_empty());

    let result_str = results.join("\n");
    assert!(result_str.contains("double"));
    assert!(!result_str.contains("triple"));
}
