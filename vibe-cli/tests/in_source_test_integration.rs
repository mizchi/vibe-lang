#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;
    use tempfile::tempdir;

    /// Helper to run vibe test command and capture output
    fn run_vsh_test(test_file: &Path) -> Result<(String, i32), std::io::Error> {
        let output = std::process::Command::new("cargo")
            .args(&["run", "-p", "vibe-cli", "--bin", "vibe", "--", "test", test_file.to_str().unwrap()])
            .output()?;
        
        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        let combined = format!("{}\n{}", stdout, stderr);
        let exit_code = output.status.code().unwrap_or(-1);
        
        Ok((combined, exit_code))
    }

    #[test]
    fn test_simple_passing_test() {
        let dir = tempdir().unwrap();
        let test_file = dir.path().join("simple_pass.vibe");
        
        fs::write(&test_file, r#"
# Simple passing test
let add x y = x + y

(test "addition test" (fn dummy = 
  assert (add 2 3 == 5) "2 + 3 should equal 5"
))
"#).unwrap();

        let (output, exit_code) = run_vsh_test(&test_file).unwrap();
        
        assert_eq!(exit_code, 0, "Test should pass with exit code 0");
        assert!(output.contains("PASS"), "Output should contain PASS");
        assert!(output.contains("addition test"), "Output should contain test name");
        assert!(output.contains("All tests passed!"), "Output should show all tests passed");
    }

    #[test]
    fn test_simple_failing_test() {
        let dir = tempdir().unwrap();
        let test_file = dir.path().join("simple_fail.vibe");
        
        fs::write(&test_file, r#"
# Simple failing test
let add x y = x + y

(test "failing addition test" (fn dummy = 
  assert (add 2 3 == 6) "2 + 3 should equal 6 (this will fail)"
))
"#).unwrap();

        let (output, exit_code) = run_vsh_test(&test_file).unwrap();
        
        assert_eq!(exit_code, 1, "Test should fail with exit code 1");
        assert!(output.contains("FAIL"), "Output should contain FAIL");
        assert!(output.contains("failing addition test"), "Output should contain test name");
        assert!(output.contains("Assertion failed"), "Output should contain assertion failure message");
        assert!(output.contains("Some tests failed!"), "Output should show some tests failed");
    }

    #[test]
    fn test_multiple_tests_mixed_results() {
        let dir = tempdir().unwrap();
        let test_file = dir.path().join("mixed_results.vibe");
        
        fs::write(&test_file, r#"
# Mixed results test
let multiply x y = x * y

(test "passing test 1" (fn dummy = 
  assert (multiply 3 4 == 12) "3 * 4 equals 12"
))

(test "failing test" (fn dummy = 
  assert (multiply 2 2 == 5) "2 * 2 should not equal 5"
))

(test "passing test 2" (fn dummy = 
  assert (multiply 5 6 == 30) "5 * 6 equals 30"
))
"#).unwrap();

        let (output, exit_code) = run_vsh_test(&test_file).unwrap();
        
        assert_eq!(exit_code, 1, "Test should fail with exit code 1 when any test fails");
        assert!(output.contains("Total: 3"), "Should show 3 total tests");
        assert!(output.contains("Passed: 2"), "Should show 2 passed tests");
        assert!(output.contains("Failed: 1"), "Should show 1 failed test");
    }

    #[test]
    fn test_inspect_function() {
        let dir = tempdir().unwrap();
        let test_file = dir.path().join("inspect_test.vibe");
        
        fs::write(&test_file, r#"
# Test inspect function
(test "inspect test" (fn dummy =
  let x = inspect 42 "The answer" in
  assert (x == 42) "inspect should return the original value"
))
"#).unwrap();

        let (output, exit_code) = run_vsh_test(&test_file).unwrap();
        
        assert_eq!(exit_code, 0, "Test should pass");
        assert!(output.contains("[The answer] 42"), "Should show inspect output");
        assert!(output.contains("PASS"), "Test should pass");
    }

    #[test]
    fn test_recursive_function() {
        let dir = tempdir().unwrap();
        let test_file = dir.path().join("recursive_test.vibe");
        
        fs::write(&test_file, r#"
# Test with recursive function
rec factorial n = 
  if n == 0 {
    1
  } else {
    n * (factorial (n - 1))
  }

(test "factorial test" (fn dummy =
  assert (factorial 5 == 120) "5! should equal 120"
))
"#).unwrap();

        let (output, exit_code) = run_vsh_test(&test_file).unwrap();
        
        assert_eq!(exit_code, 0, "Test should pass");
        assert!(output.contains("PASS"), "Test should pass");
        assert!(output.contains("factorial test"), "Should show test name");
    }

    #[test]
    fn test_let_in_expression() {
        let dir = tempdir().unwrap();
        let test_file = dir.path().join("let_in_test.vibe");
        
        fs::write(&test_file, r#"
# Test with let-in expressions
(test "let-in test" (fn dummy =
  let result = 
    let x = 10 in
    let y = 20 in
    x + y in
  assert (result == 30) "let-in should work correctly"
))
"#).unwrap();

        let (output, exit_code) = run_vsh_test(&test_file).unwrap();
        
        assert_eq!(exit_code, 0, "Test should pass");
        assert!(output.contains("PASS"), "Test should pass");
    }

    #[test]
    fn test_list_operations() {
        let dir = tempdir().unwrap();
        let test_file = dir.path().join("list_test.vibe");
        
        fs::write(&test_file, r#"
# Test with list operations
rec length lst = 
  match lst {
    [] -> 0
    h :: t -> 1 + (length t)
  }

(test "list length test" (fn dummy =
  let lst = [1, 2, 3, 4, 5] in
  assert (length lst == 5) "List should have 5 elements"
))
"#).unwrap();

        let (output, exit_code) = run_vsh_test(&test_file).unwrap();
        
        assert_eq!(exit_code, 0, "Test should pass");
        assert!(output.contains("PASS"), "Test should pass");
    }

    #[test]
    fn test_type_error() {
        let dir = tempdir().unwrap();
        let test_file = dir.path().join("type_error_test.vibe");
        
        fs::write(&test_file, r#"
# Test with type error
let add x y = x + y

(test "type error test" (fn dummy =
  assert (add "hello" "world") "This should fail with type error"
))
"#).unwrap();

        let (output, exit_code) = run_vsh_test(&test_file).unwrap();
        
        assert_eq!(exit_code, 1, "Test should fail");
        assert!(output.contains("FAIL"), "Test should fail");
        assert!(output.contains("requires arguments of the same numeric type"), "Should show type error message");
    }

    #[test]
    fn test_undefined_variable() {
        let dir = tempdir().unwrap();
        let test_file = dir.path().join("undefined_var_test.vibe");
        
        fs::write(&test_file, r#"
# Test with undefined variable
(test "undefined variable test" (fn dummy =
  assert (someUndefinedFunction 42 == 42) "This should fail"
))
"#).unwrap();

        let (output, exit_code) = run_vsh_test(&test_file).unwrap();
        
        assert_eq!(exit_code, 1, "Test should fail");
        assert!(output.contains("FAIL"), "Test should fail");
        assert!(output.contains("Undefined variable"), "Should show undefined variable error");
    }

    #[test]
    fn test_no_tests() {
        let dir = tempdir().unwrap();
        let test_file = dir.path().join("no_tests.vibe");
        
        fs::write(&test_file, r#"
# File with no tests
let add x y = x + y
let multiply x y = x * y
"#).unwrap();

        let (output, exit_code) = run_vsh_test(&test_file).unwrap();
        
        assert_eq!(exit_code, 0, "Should succeed with no tests");
        assert!(output.contains("Total: 0"), "Should show 0 total tests");
        assert!(output.contains("All tests passed!"), "Should say all tests passed");
    }

    #[test]
    fn test_runtime_error() {
        let dir = tempdir().unwrap();
        let test_file = dir.path().join("runtime_error_test.vibe");
        
        fs::write(&test_file, r#"
# Test with runtime error
(test "division by zero test" (fn dummy =
  let divideByZero x = x / 0 in
  assert (divideByZero 10 == 0) "This should fail with division by zero"
))
"#).unwrap();

        let (output, exit_code) = run_vsh_test(&test_file).unwrap();
        
        assert_eq!(exit_code, 1, "Test should fail");
        assert!(output.contains("FAIL"), "Test should fail");
        assert!(output.contains("Division by zero"), "Should show division by zero error");
    }
}