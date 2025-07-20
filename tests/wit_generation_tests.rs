//! Integration tests for WebAssembly Interface Types (WIT) generation

use std::fs;
use std::process::Command;
use tempfile::TempDir;

/// Helper to run xsc component wit command
fn run_wit_generation(input_file: &str) -> Result<String, String> {
    let output = Command::new("cargo")
        .args(&["run", "-p", "cli", "--bin", "xsc", "--", "component", "wit", input_file])
        .output()
        .map_err(|e| format!("Failed to execute command: {}", e))?;

    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

#[test]
fn test_simple_math_module_wit_generation() {
    let module_content = r#"
(module Math
  (export add subtract multiply)
  
  (let add (fn (x y) (+ x y)))
  (let subtract (fn (x y) (- x y)))
  (let multiply (fn (x y) (* x y))))"#;

    let temp_dir = TempDir::new().unwrap();
    let module_path = temp_dir.path().join("math.xs");
    fs::write(&module_path, module_content).unwrap();

    let wit_output = run_wit_generation(module_path.to_str().unwrap()).unwrap();

    // Verify WIT output structure
    assert!(wit_output.contains("package xs:math@0.1.0;"));
    assert!(wit_output.contains("interface exports {"));
    assert!(wit_output.contains("add: func(arg1: s64, arg2: s64) -> s64;"));
    assert!(wit_output.contains("subtract: func(arg1: s64, arg2: s64) -> s64;"));
    assert!(wit_output.contains("multiply: func(arg1: s64, arg2: s64) -> s64;"));
    assert!(wit_output.contains("world math {"));
    assert!(wit_output.contains("export exports;"));
}

#[test]
fn test_curried_function_wit_generation() {
    let module_content = r#"
(module Curried
  (export curry-add curry-multiply)
  
  (let curry-add (fn (x) (fn (y) (+ x y))))
  (let curry-multiply (fn (x) (fn (y) (fn (z) (* (* x y) z))))))"#;

    let temp_dir = TempDir::new().unwrap();
    let module_path = temp_dir.path().join("curried.xs");
    fs::write(&module_path, module_content).unwrap();

    let wit_output = run_wit_generation(module_path.to_str().unwrap()).unwrap();

    // Verify curried functions are uncurried in WIT
    assert!(wit_output.contains("curry-add: func(arg1: s64, arg2: s64) -> s64;"));
    assert!(wit_output.contains("curry-multiply: func(arg1: s64, arg2: s64, arg3: s64) -> s64;"));
}

#[test]
fn test_mixed_types_module_wit_generation() {
    let module_content = r#"
(module StringUtils
  (export get-length concat is-empty identity)
  
  (let get-length (fn (s) 0)) ; Placeholder - returns 0
  (let concat (fn (s1 s2) s1)) ; Placeholder - returns first string
  (let is-empty (fn (s) true)) ; Placeholder - always returns true
  (let identity (fn (s) s)) ; Returns input string
)"#;

    let temp_dir = TempDir::new().unwrap();
    let module_path = temp_dir.path().join("string_utils.xs");
    fs::write(&module_path, module_content).unwrap();

    let wit_output = run_wit_generation(module_path.to_str().unwrap()).unwrap();

    // Verify different type mappings
    assert!(wit_output.contains("get-length: func(arg1: string) -> s64;"));
    assert!(wit_output.contains("concat: func(arg1: string, arg2: string) -> string;"));
    assert!(wit_output.contains("is-empty: func(arg1: string) -> bool;"));
    assert!(wit_output.contains("identity: func(arg1: string) -> string;"));
}

#[test]
fn test_list_operations_wit_generation() {
    let module_content = r#"
(module ListOps
  (export length sum map-list)
  
  (let length (fn (xs) 0))
  (let sum (fn (xs) 0))
  (let map-list (fn (f xs) xs))
)"#;

    let temp_dir = TempDir::new().unwrap();
    let module_path = temp_dir.path().join("list_ops.xs");
    fs::write(&module_path, module_content).unwrap();

    let wit_output = run_wit_generation(module_path.to_str().unwrap()).unwrap();

    // Verify list type mapping (simplified - xs has no type inference for lists without explicit types)
    assert!(wit_output.contains("length: func(arg1: string) -> s64;"));
    assert!(wit_output.contains("sum: func(arg1: string) -> s64;"));
    assert!(wit_output.contains("map-list: func(arg1: string, arg2: string) -> string;"));
}

#[test]
fn test_float_operations_wit_generation() {
    let module_content = r#"
(module FloatMath
  (export sqrt pow ceil floor)
  
  (let sqrt (fn (x: Float) 1.0))
  (let pow (fn (x: Float y: Float) 1.0))
  (let ceil (fn (x: Float) 1.0))
  (let floor (fn (x: Float) 1.0))
)"#;

    let temp_dir = TempDir::new().unwrap();
    let module_path = temp_dir.path().join("float_math.xs");
    fs::write(&module_path, module_content).unwrap();

    let wit_output = run_wit_generation(module_path.to_str().unwrap()).unwrap();

    // Verify float type mapping
    assert!(wit_output.contains("sqrt: func(arg1: float64) -> float64;"));
    assert!(wit_output.contains("pow: func(arg1: float64, arg2: float64) -> float64;"));
    assert!(wit_output.contains("ceil: func(arg1: float64) -> float64;"));
    assert!(wit_output.contains("floor: func(arg1: float64) -> float64;"));
}

#[test]
fn test_wit_file_output() {
    let module_content = r#"
(module TestModule
  (export test-func)
  
  (let test-func (fn (x) (* x 2))))"#;

    let temp_dir = TempDir::new().unwrap();
    let module_path = temp_dir.path().join("test.xs");
    let wit_path = temp_dir.path().join("test.wit");
    
    fs::write(&module_path, module_content).unwrap();

    // Run with output file
    let output = Command::new("cargo")
        .args(&[
            "run", "-p", "cli", "--bin", "xsc", "--", 
            "component", "wit", 
            module_path.to_str().unwrap(),
            "-o", wit_path.to_str().unwrap()
        ])
        .output()
        .unwrap();

    assert!(output.status.success());
    assert!(wit_path.exists());

    let wit_content = fs::read_to_string(&wit_path).unwrap();
    assert!(wit_content.contains("package xs:test@0.1.0;"));
    assert!(wit_content.contains("test-func: func(arg1: s64) -> s64;"));
}

#[test]
fn test_empty_module_wit_generation() {
    let module_content = r#"
(module Empty
  (export)
  ; No exports
)"#;

    let temp_dir = TempDir::new().unwrap();
    let module_path = temp_dir.path().join("empty.xs");
    fs::write(&module_path, module_content).unwrap();

    let wit_output = run_wit_generation(module_path.to_str().unwrap()).unwrap();

    // Should still generate valid WIT structure
    assert!(wit_output.contains("package xs:empty@0.1.0;"));
    assert!(wit_output.contains("interface exports {"));
    assert!(wit_output.contains("}"));
    assert!(wit_output.contains("world empty {"));
}

#[test]
fn test_non_module_expression_wit_generation() {
    let expr_content = r#"(fn (x y) (+ x y))"#;

    let temp_dir = TempDir::new().unwrap();
    let expr_path = temp_dir.path().join("expr.xs");
    fs::write(&expr_path, expr_content).unwrap();

    let wit_output = run_wit_generation(expr_path.to_str().unwrap()).unwrap();

    // Should treat as single main export
    assert!(wit_output.contains("package xs:expr@0.1.0;"));
    assert!(wit_output.contains("main: func(arg1: s64, arg2: s64) -> s64;"));
    assert!(wit_output.contains("world expr {"));
}

#[test]
fn test_invalid_syntax_error() {
    let invalid_content = r#"(module Invalid (export foo) (let foo"#;

    let temp_dir = TempDir::new().unwrap();
    let invalid_path = temp_dir.path().join("invalid.xs");
    fs::write(&invalid_path, invalid_content).unwrap();

    let result = run_wit_generation(invalid_path.to_str().unwrap());
    assert!(result.is_err());
    assert!(result.unwrap_err().contains("Failed to parse"));
}

#[test]
fn test_type_error_in_export() {
    let module_content = r#"
(module TypeErr
  (export undefined-func)
  (let other-func (fn () 42))
  ; Referencing undefined function
)"#;

    let temp_dir = TempDir::new().unwrap();
    let module_path = temp_dir.path().join("type_err.xs");
    fs::write(&module_path, module_content).unwrap();

    let result = run_wit_generation(module_path.to_str().unwrap());
    // Check that we get an error for undefined export
    if let Err(err) = result {
        assert!(err.contains("not found") || err.contains("Type error") || err.contains("Export"));
    } else {
        panic!("Expected error for undefined export, but got success");
    }
}