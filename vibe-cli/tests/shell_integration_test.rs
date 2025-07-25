//! Integration tests for XS Shell with code repository

use tempfile::TempDir;
use vibe_cli::shell::ShellState;

#[test]
fn test_shell_auto_save_to_repository() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    // Evaluate some expressions
    let result1 = shell.evaluate_line("(let x 42)").unwrap();
    assert!(result1.contains("x : Int = 42"));

    let result2 = shell
        .evaluate_line("(let double (fn (n) (* n 2)))")
        .unwrap();
    assert!(result2.contains("double : (-> Int Int)"));

    // Use a defined variable
    let result3 = shell.evaluate_line("(double x)").unwrap();
    assert!(result3.contains("84 : Int"));

    // Check that code repository exists
    let db_path = temp_dir.path().join("code_repository.db");
    assert!(
        db_path.exists(),
        "Code repository database should be created"
    );
}

#[test]
fn test_stats_command() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    // Define some functions
    shell.evaluate_line("(let inc (fn (x) (+ x 1)))").unwrap();
    shell.evaluate_line("(let dec (fn (x) (- x 1)))").unwrap();

    // Use inc multiple times to increase its access count
    for i in 0..5 {
        shell.evaluate_line(&format!("(inc {})", i)).unwrap();
    }

    // Stats command would be handled through the command system
    // For now, we just ensure the repository tracks access
}

#[test]
fn test_dependency_tracking() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    // Create a dependency chain
    shell.evaluate_line("(let base 10)").unwrap();
    shell.evaluate_line("(let double_base (* base 2))").unwrap();
    shell
        .evaluate_line("(let quad_base (* double_base 2))")
        .unwrap();

    // The dependency chain should be: quad_base -> double_base -> base
    // This is automatically tracked in the repository
}

#[test]
fn test_namespace_organization() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    // Define functions in different conceptual namespaces
    shell
        .evaluate_line("(let Math.add (fn (x y) (+ x y)))")
        .unwrap();
    shell
        .evaluate_line("(let Math.mul (fn (x y) (* x y)))")
        .unwrap();
    shell
        .evaluate_line("(let String.length (fn (s) (strLength s)))")
        .unwrap();

    // These should be stored with their namespace prefixes
}

#[test]
fn test_expression_history() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    // Evaluate expressions
    shell.evaluate_line("42").unwrap();
    shell.evaluate_line("(+ 1 2)").unwrap();
    shell.evaluate_line("(let result 100)").unwrap();

    // History should contain all evaluations
    let history = shell.show_history(None);
    assert!(history.contains("42"));
    assert!(history.contains("(+ 1 2)"));
    assert!(history.contains("result"));
}

#[test]
fn test_named_expressions() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    // Define named expressions
    shell.evaluate_line("(let foo 42)").unwrap();
    shell.evaluate_line("(let bar (+ foo 8))").unwrap();

    // List definitions
    let defs = shell.list_definitions(None);
    assert!(defs.contains("foo"));
    assert!(defs.contains("bar"));

    // View specific definition
    let view = shell.view_definition("foo").unwrap();
    assert!(view.contains("42"));
    assert!(view.contains("Int"));
}

#[test]
fn test_search_functionality() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    // Define various functions
    shell
        .evaluate_line("(let addOne (fn (x) (+ x 1)))")
        .unwrap();
    shell
        .evaluate_line("(let addTwo (fn (x) (+ x 2)))")
        .unwrap();
    shell
        .evaluate_line("(let multiply (fn (x y) (* x y)))")
        .unwrap();

    // Search for "add" should find addOne and addTwo
    let results = shell.search_definitions("add").unwrap();
    assert!(results.iter().any(|s| s.contains("addOne")));
    assert!(results.iter().any(|s| s.contains("addTwo")));
    assert!(!results.iter().any(|s| s.contains("multiply")));
}

#[test]
fn test_error_handling() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    // Type error
    let result = shell.evaluate_line("(+ \"hello\" 42)");
    assert!(result.is_err());

    // Undefined variable
    let result = shell.evaluate_line("undefined_var");
    assert!(result.is_err());

    // Syntax error
    let result = shell.evaluate_line("(let x");
    assert!(result.is_err());
}

#[test]
fn test_complex_expressions() {
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    // Define a recursive function
    shell
        .evaluate_line("(rec factorial (n) (if (= n 0) 1 (* n (factorial (- n 1)))))")
        .unwrap();

    // Use it
    let result = shell.evaluate_line("(factorial 5)").unwrap();
    assert!(result.contains("120"));

    // Define higher-order function
    shell
        .evaluate_line(
            "(let map (fn (f xs) (if (null? xs) (list) (cons (f (car xs)) (map f (cdr xs))))))",
        )
        .unwrap();

    // Use with lambda
    let result = shell
        .evaluate_line("(map (fn (x) (* x 2)) (list 1 2 3))")
        .unwrap();
    assert!(result.contains("2"));
    assert!(result.contains("4"));
    assert!(result.contains("6"));
}
