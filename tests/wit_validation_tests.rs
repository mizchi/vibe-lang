//! Tests for validating generated WIT files
//!
//! These tests ensure that generated WIT files are syntactically valid
//! and can be used with WebAssembly tooling.

use std::fs;
use std::process::Command;
use tempfile::TempDir;

/// Helper to check if wit-bindgen is available
fn wit_bindgen_available() -> bool {
    Command::new("wit-bindgen")
        .arg("--version")
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

/// Helper to check if wasm-tools is available
fn wasm_tools_available() -> bool {
    Command::new("wasm-tools")
        .arg("--version")
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

#[test]
fn test_generated_wit_syntax_validation() {
    // Create a test module
    let module_content = r#"
(module Calculator
  (export add subtract multiply divide square)
  
  (let add (fn (x: Int y: Int) (+ x y)))
  (let subtract (fn (x: Int y: Int) (- x y)))
  (let multiply (fn (x: Int y: Int) (* x y)))
  (let divide (fn (x: Int y: Int) (/ x y)))
  (let square (fn (x: Int) (* x x))))"#;

    let temp_dir = TempDir::new().unwrap();
    let module_path = temp_dir.path().join("calculator.xs");
    let wit_path = temp_dir.path().join("calculator.wit");

    fs::write(&module_path, module_content).unwrap();

    // Generate WIT
    let output = Command::new("cargo")
        .args([
            "run",
            "-p",
            "xs-tools",
            "--bin",
            "xsc",
            "--",
            "component",
            "wit",
            module_path.to_str().unwrap(),
            "-o",
            wit_path.to_str().unwrap(),
        ])
        .output()
        .unwrap();

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        panic!("WIT generation failed.\nstderr: {stderr}\nstdout: {stdout}");
    }
    assert!(wit_path.exists());

    // Read and validate basic structure
    let wit_content = fs::read_to_string(&wit_path).unwrap();

    // Check package declaration
    assert!(wit_content.starts_with("package xs:calculator@0.1.0;"));

    // Check interface structure
    assert!(wit_content.contains("interface exports {"));
    assert!(wit_content.contains("}"));

    // Check world declaration
    assert!(wit_content.contains("world calculator {"));
    assert!(wit_content.contains("export exports;"));

    // Check function signatures
    assert!(wit_content.contains("add: func(arg1: s64, arg2: s64) -> s64;"));
    assert!(wit_content.contains("subtract: func(arg1: s64, arg2: s64) -> s64;"));
    assert!(wit_content.contains("multiply: func(arg1: s64, arg2: s64) -> s64;"));
    assert!(wit_content.contains("divide: func(arg1: s64, arg2: s64) -> s64;"));
    assert!(wit_content.contains("square: func(arg1: s64) -> s64;"));

    // Validate balanced braces
    let open_braces = wit_content.matches('{').count();
    let close_braces = wit_content.matches('}').count();
    assert_eq!(open_braces, close_braces);

    // Validate balanced parentheses
    let open_parens = wit_content.matches('(').count();
    let close_parens = wit_content.matches(')').count();
    assert_eq!(open_parens, close_parens);
}

#[test]
#[ignore = "Requires wit-bindgen tool to be installed"]
fn test_wit_bindgen_compatibility() {
    if !wit_bindgen_available() {
        eprintln!("Skipping test: wit-bindgen not available");
        return;
    }

    let module_content = r#"
(module SimpleAPI
  (export get-version process-data)
  
  (let get-version (fn () "1.0.0"))
  (let process-data (fn (input: String) input)))"#;

    let temp_dir = TempDir::new().unwrap();
    let module_path = temp_dir.path().join("api.xs");
    let wit_path = temp_dir.path().join("api.wit");

    fs::write(&module_path, module_content).unwrap();

    // Generate WIT
    let output = Command::new("cargo")
        .args([
            "run",
            "-p",
            "xs-tools",
            "--bin",
            "xsc",
            "--",
            "component",
            "wit",
            module_path.to_str().unwrap(),
            "-o",
            wit_path.to_str().unwrap(),
        ])
        .output()
        .unwrap();

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        panic!("WIT generation failed.\nstderr: {stderr}\nstdout: {stdout}");
    }

    // Try to generate bindings with wit-bindgen
    let bindgen_output = Command::new("wit-bindgen")
        .args([
            "rust",
            "--out-dir",
            temp_dir.path().to_str().unwrap(),
            wit_path.to_str().unwrap(),
        ])
        .output()
        .unwrap();

    if !bindgen_output.status.success() {
        let stderr = String::from_utf8_lossy(&bindgen_output.stderr);
        panic!("wit-bindgen failed: {stderr}");
    }
}

#[test]
#[ignore = "Requires wasm-tools to be installed"]
fn test_wasm_tools_wit_validation() {
    if !wasm_tools_available() {
        eprintln!("Skipping test: wasm-tools not available");
        return;
    }

    let module_content = r#"
(module DataProcessor
  (export transform filter aggregate)
  
  (let transform (fn (data: Int) (* data 2)))
  (let filter (fn (value: Int) (> value 0)))
  (let aggregate (fn (a: Int b: Int) (+ a b))))"#;

    let temp_dir = TempDir::new().unwrap();
    let module_path = temp_dir.path().join("processor.xs");
    let wit_path = temp_dir.path().join("processor.wit");

    fs::write(&module_path, module_content).unwrap();

    // Generate WIT
    let output = Command::new("cargo")
        .args([
            "run",
            "-p",
            "xs-tools",
            "--bin",
            "xsc",
            "--",
            "component",
            "wit",
            module_path.to_str().unwrap(),
            "-o",
            wit_path.to_str().unwrap(),
        ])
        .output()
        .unwrap();

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        panic!("WIT generation failed.\nstderr: {stderr}\nstdout: {stdout}");
    }

    // Validate with wasm-tools
    let validate_output = Command::new("wasm-tools")
        .args(["component", "wit", wit_path.to_str().unwrap()])
        .output()
        .unwrap();

    if !validate_output.status.success() {
        let stderr = String::from_utf8_lossy(&validate_output.stderr);
        panic!("wasm-tools validation failed: {stderr}");
    }
}

#[test]
fn test_complex_wit_generation() {
    let module_content = r#"
(module ComplexModule
  (export processInt)
  
  (let processInt (fn (x: Int) (+ x 1))))"#;

    let temp_dir = TempDir::new().unwrap();
    let module_path = temp_dir.path().join("complex.xs");
    let wit_path = temp_dir.path().join("complex.wit");

    fs::write(&module_path, module_content).unwrap();

    // Generate WIT
    let output = Command::new("cargo")
        .args([
            "run",
            "-p",
            "xs-tools",
            "--bin",
            "xsc",
            "--",
            "component",
            "wit",
            module_path.to_str().unwrap(),
            "-o",
            wit_path.to_str().unwrap(),
        ])
        .output()
        .unwrap();

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        panic!("WIT generation failed.\nstderr: {stderr}\nstdout: {stdout}");
    }

    let wit_content = fs::read_to_string(&wit_path).unwrap();

    // Verify type mapping
    assert!(wit_content.contains("processint: func(arg1: s64) -> s64;"));
}

#[test]
#[ignore = "WIT generation for simple functions needs fixing"]
fn test_wit_generation_preserves_naming_conventions() {
    let module_content = r#"
(module NamingTest
  (export add subtract)
  
  (let add (fn () 1))
  (let subtract (fn () 2)))"#;

    let temp_dir = TempDir::new().unwrap();
    let module_path = temp_dir.path().join("naming.xs");
    let wit_path = temp_dir.path().join("naming.wit");

    fs::write(&module_path, module_content).unwrap();

    // Generate WIT
    let output = Command::new("cargo")
        .args([
            "run",
            "-p",
            "xs-tools",
            "--bin",
            "xsc",
            "--",
            "component",
            "wit",
            module_path.to_str().unwrap(),
            "-o",
            wit_path.to_str().unwrap(),
        ])
        .output()
        .unwrap();

    let stderr = String::from_utf8_lossy(&output.stderr);
    let stdout = String::from_utf8_lossy(&output.stdout);
    eprintln!("WIT generation stderr: {stderr}");
    eprintln!("WIT generation stdout: {stdout}");

    if !output.status.success() {
        panic!("WIT generation failed.\nstderr: {stderr}\nstdout: {stdout}");
    }

    let wit_content = fs::read_to_string(&wit_path).unwrap();
    eprintln!("Generated WIT content:\n{wit_content}");

    // Verify simple naming
    assert!(wit_content.contains("add: func() -> s64;"));
    assert!(wit_content.contains("subtract: func() -> s64;"));
}
