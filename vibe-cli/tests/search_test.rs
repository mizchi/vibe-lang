//! Tests for code search functionality

use tempfile::TempDir;
use vibe_cli::shell::ShellState;
use std::fs;

/// Helper to create a shell with some predefined functions
fn create_test_shell() -> (ShellState, TempDir) {
    let temp_dir = TempDir::new().unwrap();
    
    // Create a test vibe file with all definitions
    let test_file = temp_dir.path().join("test_definitions.vibe");
    let test_content = r#"
# Test functions for search tests
let double = fn x -> x * 2
let triple = fn x -> x * 3
let strLen = fn s -> strLength s
let isEven = fn n -> (n % 2) == 0
rec factorial n = if n == 0 { 1 } else { n * factorial (n - 1) }
rec filter pred lst = match lst { [] -> [] | h :: t -> if pred h { h :: filter pred t } else { filter pred t } }
rec map f lst = match lst { [] -> [] | h :: t -> (f h) :: (map f t) }
let add = fn x y -> x + y
let concat = fn s1 s2 -> strConcat s1 s2
"#;
    fs::write(&test_file, test_content).unwrap();
    
    // Create shell and load the file
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();
    
    // Parse and evaluate the entire file content
    use vibe_language::parser;
    match parser::parse(test_content) {
        Ok(expr) => {
            // The parser should return a Block with all the definitions
            if let Err(e) = shell.evaluate_line(&vibe_language::pretty_print::pretty_print(&expr)) {
                eprintln!("Failed to load test definitions: {}", e);
            }
        },
        Err(e) => {
            eprintln!("Failed to parse test definitions: {}", e);
        }
    }

    (shell, temp_dir)
}

#[test]
#[ignore = "Unified parser issue with let expressions"]
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
#[ignore = "Unified parser issue with let expressions"]
fn test_search_by_type_string_to_int() {
    let (shell, _temp_dir) = create_test_shell();

    let results = shell.search_definitions("type:String -> Int").unwrap();
    assert!(!results.is_empty());

    let result_str = results.join("\n");
    assert!(result_str.contains("strLen"));
    assert!(!result_str.contains("double"));
}

#[test]
#[ignore = "Unified parser issue with let expressions"]
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
#[ignore = "Unified parser issue with let expressions"]
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
#[ignore = "Unified parser issue with let expressions"]
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
#[ignore = "Unified parser issue with let expressions"]
fn test_search_by_name() {
    let (shell, _temp_dir) = create_test_shell();

    let results = shell.search_definitions("dou").unwrap();
    assert!(!results.is_empty());

    let result_str = results.join("\n");
    assert!(result_str.contains("double"));
    assert!(!result_str.contains("triple"));
}
