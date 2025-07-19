//! Unified runtime for XS language
//! 
//! This module provides a common interface for different execution backends.

use xs_core::{Value, XsError};
use xs_core::ir::TypedIrExpr;
use thiserror::Error;

pub mod backend;

pub use backend::{Backend, InterpreterBackend};

/// Runtime errors
#[derive(Debug, Error)]
pub enum RuntimeError {
    #[error("Type mismatch: {0}")]
    TypeMismatch(String),
    
    #[error("Undefined variable: {0}")]
    UndefinedVariable(String),
    
    #[error("Invalid operation: {0}")]
    InvalidOperation(String),
    
    #[error("Division by zero")]
    DivisionByZero,
    
    #[error("WebAssembly error: {0}")]
    WasmError(String),
    
    #[error("XS error: {0}")]
    XsError(#[from] XsError),
}

/// Runtime environment for managing execution
pub struct Runtime<B: Backend> {
    backend: B,
}

impl<B: Backend> Runtime<B> {
    pub fn new(backend: B) -> Self {
        Self { backend }
    }
    
    /// Compile typed IR to backend-specific format
    pub fn compile(&mut self, ir: &TypedIrExpr) -> Result<B::Output, B::Error> {
        self.backend.compile(ir)
    }
    
    /// Execute compiled code
    pub fn execute(&mut self, compiled: &B::Output) -> Result<Value, RuntimeError> {
        self.backend.execute(compiled)
    }
    
    /// Compile and execute in one step
    pub fn eval(&mut self, ir: &TypedIrExpr) -> Result<Value, RuntimeError> {
        let compiled = self.backend.compile(ir)
            .map_err(|e| RuntimeError::InvalidOperation(format!("{:?}", e)))?;
        self.backend.execute(&compiled)
    }
}