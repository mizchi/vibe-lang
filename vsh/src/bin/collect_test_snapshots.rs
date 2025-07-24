//! Collect test snapshots from existing XS test files

use std::fs;
use tempfile::TempDir;
use vsh::shell::ShellState;
use serde::{Serialize, Deserialize};

#[derive(Debug, Serialize, Deserialize)]
struct TestSnapshot {
    file_path: String,
    file_name: String,
    input: String,
    output: Result<String, String>,
    is_error_test: bool,
}

fn main() {
    let mut snapshots = Vec::new();
    
    // Collect all test files from tests/xs_tests
    let test_dir = "tests/xs_tests";
    
    // Walk through all subdirectories
    for entry in walkdir::WalkDir::new(test_dir) {
        let entry = entry.unwrap();
        let path = entry.path();
        
        // Skip directories and non-.xs files
        if !path.is_file() || path.extension() != Some(std::ffi::OsStr::new("xs")) {
            continue;
        }
        
        if let Ok(content) = fs::read_to_string(path) {
            let temp_dir = TempDir::new().unwrap();
            let mut shell = ShellState::new(temp_dir.path().to_path_buf()).unwrap();
            
            let result = shell.evaluate_line(&content)
                .map_err(|e| e.to_string());
            
            let file_name = path.file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("unknown")
                .to_string();
            
            snapshots.push(TestSnapshot {
                file_path: path.to_string_lossy().to_string(),
                file_name: file_name.clone(),
                input: content,
                output: result,
                is_error_test: file_name.contains("fail") || file_name.contains("error"),
            });
            
            println!("Processed: {}", path.display());
        }
    }
    
    // Write snapshots as JSON
    let json = serde_json::to_string_pretty(&snapshots).unwrap();
    fs::write("test_snapshots.json", json).unwrap();
    
    println!("\nGenerated {} test snapshots", snapshots.len());
}