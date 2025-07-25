//! Collect test results from existing XS test files
//!
//! This utility runs all test files and collects their evaluation results
//! to create snapshot tests.

use std::fs;
use std::path::{Path, PathBuf};
use tempfile::TempDir;
use vibe_cli::shell::ShellState;

/// Test file result
#[derive(Debug)]
struct TestFileResult {
    file_path: PathBuf,
    file_name: String,
    content: String,
    result: Result<String, String>,
    is_error_test: bool,
}

/// Collect all test files
fn collect_test_files() -> Vec<PathBuf> {
    let mut test_files = Vec::new();

    // Test patterns to look for
    let test_dirs = vec![
        "tests/xs_tests",
        "tests/xs_archive",
        "tests/xs_experimental",
        "xs/tests",
    ];

    for dir in test_dirs {
        if let Ok(entries) = fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().map_or(false, |ext| ext == "xs") {
                    test_files.push(path);
                }
            }
        }
    }

    // Also collect top-level test files
    if let Ok(entries) = fs::read_dir(".") {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().map_or(false, |ext| ext == "xs") {
                if let Some(name) = path.file_name() {
                    let name_str = name.to_string_lossy();
                    if name_str.starts_with("test_") || name_str.contains("demo") {
                        test_files.push(path);
                    }
                }
            }
        }
    }

    test_files.sort();
    test_files
}

/// Run a test file and collect results
fn run_test_file(path: &Path) -> TestFileResult {
    let file_name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string();

    let content = fs::read_to_string(path).unwrap_or_default();

    // Check if this is an error test
    let is_error_test = file_name.contains("fail")
        || file_name.contains("error")
        || content.contains("should fail")
        || content.contains("error expected");

    // Create a fresh shell for each test
    let temp_dir = TempDir::new().unwrap();
    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();

    // Run the test
    let result = shell.evaluate_line(&content).map_err(|e| e.to_string());

    TestFileResult {
        file_path: path.to_path_buf(),
        file_name,
        content,
        result,
        is_error_test,
    }
}

/// Generate test code from results
fn generate_test_code(results: &[TestFileResult]) -> String {
    let mut code = String::new();

    code.push_str("// Auto-generated test cases from existing XS files\n\n");
    code.push_str("use super::*;\n\n");

    // Group by directory
    let mut by_dir: std::collections::HashMap<String, Vec<&TestFileResult>> =
        std::collections::HashMap::new();

    for result in results {
        let dir = result
            .file_path
            .parent()
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str())
            .unwrap_or("root")
            .to_string();
        by_dir.entry(dir).or_default().push(result);
    }

    for (dir, results) in by_dir {
        code.push_str(&format!(
            "\n#[test]\nfn test_shell_e2e_{}() {{\n",
            dir.replace('-', "_")
        ));
        code.push_str("    let temp_dir = TempDir::new().unwrap();\n");
        code.push_str(
            "    let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();\n\n",
        );

        for result in results {
            code.push_str(&format!("    // Test: {}\n", result.file_name));

            if result.is_error_test {
                code.push_str(&format!("    {{\n"));
                code.push_str(&format!(
                    "        let result = shell.evaluate_line({:?});\n",
                    result.content
                ));
                code.push_str("        assert!(result.is_err(), \"Error test should fail\");\n");

                if let Err(ref err) = result.result {
                    // Extract key error message part
                    let error_key = if err.contains("Type mismatch") {
                        "Type mismatch"
                    } else if err.contains("Undefined variable") {
                        "Undefined variable"
                    } else if err.contains("Division by zero") {
                        "Division by zero"
                    } else {
                        ""
                    };

                    if !error_key.is_empty() {
                        code.push_str(&format!(
                            "        assert!(result.unwrap_err().contains({:?}));\n",
                            error_key
                        ));
                    }
                }
                code.push_str("    }\n\n");
            } else {
                code.push_str(&format!("    {{\n"));
                code.push_str(&format!(
                    "        let result = shell.evaluate_line({:?});\n",
                    result.content
                ));
                code.push_str(&format!(
                    "        assert!(result.is_ok(), \"Test {} failed: {{:?}}\", {:?}, result);\n",
                    result.file_name, result.file_name
                ));

                if let Ok(ref output) = result.result {
                    // Extract the type signature from output
                    if let Some(type_pos) = output.rfind(" : ") {
                        let type_sig = &output[type_pos + 3..];
                        code.push_str(&format!("        let output = result.unwrap();\n"));
                        code.push_str(&format!("        assert!(output.contains(\" : {}\"), \"Type mismatch in {}\");\n", 
                            type_sig.trim(), result.file_name));
                    }
                }
                code.push_str("    }\n\n");
            }
        }

        code.push_str("}\n");
    }

    code
}

#[test]
fn collect_and_print_results() {
    let test_files = collect_test_files();
    println!("Found {} test files", test_files.len());

    let mut results = Vec::new();

    for path in test_files.iter().take(10) {
        // Start with first 10 files
        println!("Running: {:?}", path);
        let result = run_test_file(path);

        match &result.result {
            Ok(output) => println!("  ✓ Success: {}", output.lines().next().unwrap_or("")),
            Err(error) => println!("  ✗ Error: {}", error.lines().next().unwrap_or("")),
        }

        results.push(result);
    }

    // Generate test code
    let test_code = generate_test_code(&results);

    // Write to file
    let output_path = "xs-tools/tests/shell_e2e_generated.rs";
    fs::write(output_path, test_code).unwrap();
    println!("\nGenerated test code written to: {}", output_path);
}
