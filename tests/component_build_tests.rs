//! Integration tests for WebAssembly Component build functionality

use std::fs;
use std::path::PathBuf;
use std::process::Command;
use tempfile::TempDir;

/// Helper to create a test XS module file
fn create_test_module(dir: &TempDir, name: &str, content: &str) -> PathBuf {
    let file_path = dir.path().join(format!("{name}.xs"));
    fs::write(&file_path, content).unwrap();
    file_path
}

#[test]
#[ignore = "WebAssembly Component Model implementation in progress"]
fn test_simple_component_build() {
    let temp_dir = TempDir::new().unwrap();

    // Create a simple XS module
    let module_content = r#"
(module Math
  (export add multiply)
  
  (let add (fn (x y) (+ x y)))
  (let multiply (fn (x y) (* x y))))"#;

    let module_path = create_test_module(&temp_dir, "math", module_content);
    let output_path = temp_dir.path().join("math.wasm");

    // Run the component build command
    let output = Command::new("cargo")
        .args([
            "run",
            "-p",
            "xsh",
            "--bin",
            "xsh",
            "--",
            "component",
            "build",
        ])
        .arg(&module_path)
        .arg("-o")
        .arg(&output_path)
        .output()
        .expect("Failed to run xsc component build");

    if !output.status.success() {
        eprintln!("stdout: {}", String::from_utf8_lossy(&output.stdout));
        eprintln!("stderr: {}", String::from_utf8_lossy(&output.stderr));
        panic!("Component build failed");
    }

    // Verify the component was created
    assert!(output_path.exists(), "Component file was not created");

    // Verify it's a valid wasm file (starts with magic bytes)
    let component_bytes = fs::read(&output_path).unwrap();
    assert!(component_bytes.len() > 4, "Component file is too small");
    assert_eq!(&component_bytes[0..4], b"\0asm", "Invalid WASM magic bytes");
}

#[test]
#[ignore = "WebAssembly Component Model implementation in progress"]
fn test_component_build_with_complex_types() {
    let temp_dir = TempDir::new().unwrap();

    let module_content = r#"
(module Calculator
  (export factorial fibonacci average)
  
  (rec factorial (n)
    (if (= n 0)
        1
        (* n (factorial (- n 1)))))
  
  (rec fibonacci (n)
    (if (< n 2)
        n
        (+ (fibonacci (- n 1)) (fibonacci (- n 2)))))
        
  (let average (fn (xs) 42)))"#; // Simplified for testing

    let module_path = create_test_module(&temp_dir, "calculator", module_content);
    let output_path = temp_dir.path().join("calculator.wasm");

    // Run the component build command
    let output = Command::new("cargo")
        .args([
            "run",
            "-p",
            "xsh",
            "--bin",
            "xsh",
            "--",
            "component",
            "build",
        ])
        .arg(&module_path)
        .arg("-o")
        .arg(&output_path)
        .output()
        .expect("Failed to run xsc component build");

    if !output.status.success() {
        eprintln!("stdout: {}", String::from_utf8_lossy(&output.stdout));
        eprintln!("stderr: {}", String::from_utf8_lossy(&output.stderr));
        panic!("Component build failed");
    }

    // Verify the component was created
    assert!(output_path.exists(), "Component file was not created");
}

#[test]
#[ignore = "WebAssembly Component Model implementation in progress"]
fn test_component_build_error_handling() {
    let temp_dir = TempDir::new().unwrap();

    // Create an invalid module (missing exports)
    let module_content = r#"
(module InvalidModule
  (export nonexistent)
  
  (let add (fn (x y) (+ x y))))"#;

    let module_path = create_test_module(&temp_dir, "invalid", module_content);
    let output_path = temp_dir.path().join("invalid.wasm");

    // Run the component build command
    let output = Command::new("cargo")
        .args([
            "run",
            "-p",
            "xsh",
            "--bin",
            "xsh",
            "--",
            "component",
            "build",
        ])
        .arg(&module_path)
        .arg("-o")
        .arg(&output_path)
        .output()
        .expect("Failed to run xsc component build");

    // This should fail
    assert!(
        !output.status.success(),
        "Build should have failed for invalid module"
    );
    assert!(String::from_utf8_lossy(&output.stderr).contains("Export 'nonexistent' not found"));
}

#[test]
#[ignore = "WebAssembly Component Model implementation in progress"]
fn test_component_build_with_wit() {
    let temp_dir = TempDir::new().unwrap();

    // Create a module with string operations
    let module_content = r#"
(module StringOps
  (export concat repeat capitalize)
  
  (let concat (fn (s1 s2) s1))
  (let repeat (fn (s n) s))
  (let capitalize (fn (s) s)))"#; // Simplified for testing

    let module_path = create_test_module(&temp_dir, "string_ops", module_content);
    let output_path = temp_dir.path().join("string_ops.wasm");

    // First generate WIT
    let wit_output = Command::new("cargo")
        .args([
            "run",
            "-p",
            "xsh",
            "--bin",
            "xsh",
            "--",
            "component",
            "generate-wit",
        ])
        .arg(&module_path)
        .output()
        .expect("Failed to run xsc component wit");

    assert!(wit_output.status.success(), "WIT generation failed");

    // Then build component
    let output = Command::new("cargo")
        .args([
            "run",
            "-p",
            "xsh",
            "--bin",
            "xsh",
            "--",
            "component",
            "build",
        ])
        .arg(&module_path)
        .arg("-o")
        .arg(&output_path)
        .arg("--version")
        .arg("1.0.0")
        .output()
        .expect("Failed to run xsc component build");

    if !output.status.success() {
        eprintln!("stdout: {}", String::from_utf8_lossy(&output.stdout));
        eprintln!("stderr: {}", String::from_utf8_lossy(&output.stderr));
        panic!("Component build failed");
    }

    // Verify the component was created
    assert!(output_path.exists(), "Component file was not created");

    // Verify version in output
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Version: 1.0.0"));
}
