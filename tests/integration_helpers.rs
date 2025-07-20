//! Common integration test helpers

use std::fs;
use std::process::Command;

/// Test configuration builder
pub struct IntegrationTest {
    name: String,
    code: String,
    expected_output: Option<String>,
    expected_error: Option<String>,
    should_fail: bool,
}

impl IntegrationTest {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            code: String::new(),
            expected_output: None,
            expected_error: None,
            should_fail: false,
        }
    }

    pub fn with_code(mut self, code: impl Into<String>) -> Self {
        self.code = code.into();
        self
    }

    pub fn expect_output(mut self, output: impl Into<String>) -> Self {
        self.expected_output = Some(output.into());
        self
    }

    pub fn expect_error(mut self, error: impl Into<String>) -> Self {
        self.expected_error = Some(error.into());
        self.should_fail = true;
        self
    }

    pub fn should_fail(mut self) -> Self {
        self.should_fail = true;
        self
    }

    pub fn run(self) {
        let filename = format!("test_{}.xs", self.name);
        fs::write(&filename, &self.code).unwrap();

        let output = Command::new("cargo")
            .args(["run", "-p", "cli", "--bin", "xsc", "--", "run", &filename])
            .output()
            .expect("Failed to execute xsc");

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);

        if self.should_fail {
            assert!(!output.status.success(), "Expected failure but succeeded");
            if let Some(expected_error) = self.expected_error {
                assert!(
                    stderr.contains(&expected_error),
                    "Expected error '{}' not found in: {}",
                    expected_error,
                    stderr
                );
            }
        } else {
            assert!(
                output.status.success(),
                "Test failed with error: {}",
                stderr
            );
            if let Some(expected_output) = self.expected_output {
                assert!(
                    stdout.contains(&expected_output),
                    "Expected output '{}' not found in: {}",
                    expected_output,
                    stdout
                );
            }
        }

        fs::remove_file(&filename).ok();
    }
}

/// Helper to create an integration test
pub fn test(name: impl Into<String>) -> IntegrationTest {
    IntegrationTest::new(name)
}

/// Test a directory of .xs files
pub fn test_directory(dir: &str, filter: Option<&str>) {
    let entries = fs::read_dir(dir).expect("Failed to read test directory");
    
    for entry in entries {
        let entry = entry.unwrap();
        let path = entry.path();
        
        if path.extension().and_then(|s| s.to_str()) == Some("xs") {
            let filename = path.file_name().unwrap().to_str().unwrap();
            
            if let Some(filter) = filter {
                if !filename.contains(filter) {
                    continue;
                }
            }
            
            println!("Running test: {}", filename);
            let code = fs::read_to_string(&path).unwrap();
            
            // Extract expectations from comments
            let (expected_output, should_fail) = extract_expectations(&code);
            
            let mut test = IntegrationTest::new(filename);
            test.code = code;
            
            if let Some(output) = expected_output {
                test.expected_output = Some(output);
            }
            
            if should_fail {
                test.should_fail = true;
            }
            
            test.run();
        }
    }
}

/// Extract test expectations from comments
fn extract_expectations(code: &str) -> (Option<String>, bool) {
    let mut expected_output = None;
    let mut should_fail = false;
    
    for line in code.lines() {
        if line.starts_with("; expect:") {
            expected_output = Some(line.trim_start_matches("; expect:").trim().to_string());
        } else if line.contains("; should-fail") {
            should_fail = true;
        }
    }
    
    (expected_output, should_fail)
}