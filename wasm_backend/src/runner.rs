//! WebAssembly test runner using Wasmtime
//! 
//! This module provides a test runner that compiles and executes
//! WebAssembly modules using the Wasmtime runtime.

use wasmtime::{Engine, Store, Module, Instance, Val};
use crate::{WasmModule, emit::emit_wat};
use std::error::Error;

/// Test runner for WebAssembly modules
pub struct WasmTestRunner {
    engine: Engine,
}

/// Result of running a WebAssembly module
#[derive(Debug, Clone)]
pub enum RunResult {
    /// Successful execution with return value
    Success(Val),
    /// Execution failed with error message
    Error(String),
}

impl PartialEq for RunResult {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (RunResult::Success(a), RunResult::Success(b)) => {
                // Compare Val values
                match (a, b) {
                    (Val::I32(x), Val::I32(y)) => x == y,
                    (Val::I64(x), Val::I64(y)) => x == y,
                    (Val::F32(x), Val::F32(y)) => x == y, // Already u32 bits
                    (Val::F64(x), Val::F64(y)) => x == y, // Already u64 bits
                    _ => false,
                }
            }
            (RunResult::Error(a), RunResult::Error(b)) => a == b,
            _ => false,
        }
    }
}

impl WasmTestRunner {
    /// Create a new test runner
    pub fn new() -> Result<Self, Box<dyn Error>> {
        // Configure engine for testing
        // Note: GC support in Wasmtime is still experimental
        let mut config = wasmtime::Config::new();
        
        // Enable WebAssembly features we might need
        config.wasm_multi_value(true);
        config.wasm_bulk_memory(true);
        
        // Note: When Wasmtime adds full GC support, enable it here:
        // config.wasm_gc(true);
        
        let engine = Engine::new(&config)?;
        
        Ok(Self { engine })
    }
    
    /// Run a WebAssembly module and return the result
    pub fn run_module(&self, wasm_module: &WasmModule) -> Result<RunResult, Box<dyn Error>> {
        // Convert to WAT
        let wat = emit_wat(wasm_module)?;
        
        // For debugging, print the WAT
        #[cfg(debug_assertions)]
        eprintln!("Generated WAT:\n{wat}");
        
        // Compile WAT to WASM
        let wasm_bytes = wat::parse_str(&wat)?;
        
        // Create a store
        let mut store = Store::new(&self.engine, ());
        
        // Compile the module
        let module = Module::new(&self.engine, &wasm_bytes)?;
        
        // Create an instance
        let instance = Instance::new(&mut store, &module, &[])?;
        
        // Get the main function
        let main_func = instance
            .get_func(&mut store, "main")
            .ok_or("No main function found")?;
        
        // Call the main function
        let mut results = vec![Val::I32(0)]; // Assume main returns i32
        match main_func.call(&mut store, &[], &mut results) {
            Ok(_) => Ok(RunResult::Success(results[0])),
            Err(e) => Ok(RunResult::Error(e.to_string())),
        }
    }
    
    /// Run a simple arithmetic expression
    pub fn run_arithmetic(&self, _expr: &str) -> Result<i64, Box<dyn Error>> {
        // This is a helper for testing simple arithmetic
        // In a real implementation, this would parse and compile the expression
        
        // For now, create a simple module that returns a constant
        let module = WasmModule {
            functions: vec![crate::WasmFunction {
                name: "main".to_string(),
                params: vec![],
                results: vec![crate::WasmType::I64],
                locals: vec![],
                body: vec![
                    crate::WasmInstr::I64Const(42), // Placeholder
                ],
            }],
            types: vec![],
            globals: vec![],
            memory: None,
            start: None,
        };
        
        match self.run_module(&module)? {
            RunResult::Success(Val::I64(n)) => Ok(n),
            RunResult::Success(_) => Err("Expected i64 result".into()),
            RunResult::Error(e) => Err(format!("Execution error: {e}").into()),
        }
    }
}

/// Test case for the runner
#[derive(Debug)]
pub struct TestCase {
    pub name: String,
    pub description: String,
    pub module: WasmModule,
    pub expected: RunResult,
}

/// Test suite runner
pub struct TestSuite {
    runner: WasmTestRunner,
    tests: Vec<TestCase>,
}

impl TestSuite {
    /// Create a new test suite
    pub fn new() -> Result<Self, Box<dyn Error>> {
        Ok(Self {
            runner: WasmTestRunner::new()?,
            tests: Vec::new(),
        })
    }
    
    /// Add a test case
    pub fn add_test(&mut self, test: TestCase) {
        self.tests.push(test);
    }
    
    /// Run all tests and report results
    pub fn run_all(&self) -> TestResults {
        let mut results = TestResults::new();
        
        for test in &self.tests {
            println!("Running test: {}", test.name);
            println!("  {}", test.description);
            
            match self.runner.run_module(&test.module) {
                Ok(actual) => {
                    if actual == test.expected {
                        println!("  ✓ PASSED");
                        results.passed += 1;
                    } else {
                        println!("  ✗ FAILED");
                        println!("    Expected: {:?}", test.expected);
                        println!("    Actual:   {actual:?}");
                        results.failed += 1;
                        results.failures.push((test.name.clone(), format!(
                            "Expected {:?}, got {:?}", test.expected, actual
                        )));
                    }
                }
                Err(e) => {
                    println!("  ✗ ERROR: {e}");
                    results.errors += 1;
                    results.failures.push((test.name.clone(), e.to_string()));
                }
            }
            println!();
        }
        
        results
    }
}

/// Test results summary
#[derive(Debug)]
pub struct TestResults {
    pub passed: usize,
    pub failed: usize,
    pub errors: usize,
    pub failures: Vec<(String, String)>,
}

impl TestResults {
    fn new() -> Self {
        Self {
            passed: 0,
            failed: 0,
            errors: 0,
            failures: Vec::new(),
        }
    }
    
    /// Check if all tests passed
    pub fn all_passed(&self) -> bool {
        self.failed == 0 && self.errors == 0
    }
    
    /// Print summary
    pub fn print_summary(&self) {
        let total = self.passed + self.failed + self.errors;
        println!("Test Results: {} passed, {} failed, {} errors out of {} total",
            self.passed, self.failed, self.errors, total);
        
        if !self.failures.is_empty() {
            println!("\nFailures:");
            for (name, reason) in &self.failures {
                println!("  - {name}: {reason}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{WasmFunction, WasmInstr, WasmType};
    
    #[test]
    fn test_runner_creation() {
        let runner = WasmTestRunner::new();
        assert!(runner.is_ok());
    }
    
    #[test]
    fn test_simple_constant() {
        let runner = WasmTestRunner::new().unwrap();
        
        let module = WasmModule {
            functions: vec![WasmFunction {
                name: "main".to_string(),
                params: vec![],
                results: vec![WasmType::I32],
                locals: vec![],
                body: vec![
                    WasmInstr::I32Const(42),
                ],
            }],
            types: vec![],
            globals: vec![],
            memory: None,
            start: None,
        };
        
        let result = runner.run_module(&module).unwrap();
        assert_eq!(result, RunResult::Success(Val::I32(42)));
    }
    
    #[test]
    fn test_arithmetic_operations() {
        let runner = WasmTestRunner::new().unwrap();
        
        let module = WasmModule {
            functions: vec![WasmFunction {
                name: "main".to_string(),
                params: vec![],
                results: vec![WasmType::I32],
                locals: vec![],
                body: vec![
                    WasmInstr::I32Const(10),
                    WasmInstr::I32Const(32),
                    WasmInstr::I32Add,
                ],
            }],
            types: vec![],
            globals: vec![],
            memory: None,
            start: None,
        };
        
        let result = runner.run_module(&module).unwrap();
        assert_eq!(result, RunResult::Success(Val::I32(42)));
    }
}