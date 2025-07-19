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

#[cfg(test)]
mod tests {
    use super::*;
    use xs_core::{Type, Literal};
    use xs_core::ir::TypedIrExpr;
    
    #[test]
    fn test_runtime_creation() {
        let backend = InterpreterBackend::new();
        let _runtime = Runtime::new(backend);
        // Runtime created successfully
    }
    
    #[test]
    fn test_literal_evaluation() {
        let backend = InterpreterBackend::new();
        let mut runtime = Runtime::new(backend);
        
        // Test integer literal
        let ir = TypedIrExpr::Literal {
            value: Literal::Int(42),
            ty: Type::Int,
        };
        
        let result = runtime.eval(&ir).unwrap();
        assert_eq!(result, Value::Int(42));
        
        // Test boolean literal
        let ir = TypedIrExpr::Literal {
            value: Literal::Bool(true),
            ty: Type::Bool,
        };
        
        let result = runtime.eval(&ir).unwrap();
        assert_eq!(result, Value::Bool(true));
    }
    
    #[test]
    fn test_undefined_variable() {
        let backend = InterpreterBackend::new();
        let mut runtime = Runtime::new(backend);
        
        let ir = TypedIrExpr::Var {
            name: "undefined".to_string(),
            ty: Type::Int,
        };
        
        let result = runtime.eval(&ir);
        assert!(matches!(result, Err(RuntimeError::UndefinedVariable(_))));
    }
    
    #[test]
    fn test_if_expression() {
        let backend = InterpreterBackend::new();
        let mut runtime = Runtime::new(backend);
        
        // if true then 1 else 2
        let ir = TypedIrExpr::If {
            cond: Box::new(TypedIrExpr::Literal {
                value: Literal::Bool(true),
                ty: Type::Bool,
            }),
            then_expr: Box::new(TypedIrExpr::Literal {
                value: Literal::Int(1),
                ty: Type::Int,
            }),
            else_expr: Box::new(TypedIrExpr::Literal {
                value: Literal::Int(2),
                ty: Type::Int,
            }),
            ty: Type::Int,
        };
        
        let result = runtime.eval(&ir).unwrap();
        assert_eq!(result, Value::Int(1));
    }
    
    #[test]
    fn test_list_construction() {
        let backend = InterpreterBackend::new();
        let mut runtime = Runtime::new(backend);
        
        // [1, 2, 3]
        let ir = TypedIrExpr::List {
            elements: vec![
                TypedIrExpr::Literal {
                    value: Literal::Int(1),
                    ty: Type::Int,
                },
                TypedIrExpr::Literal {
                    value: Literal::Int(2),
                    ty: Type::Int,
                },
                TypedIrExpr::Literal {
                    value: Literal::Int(3),
                    ty: Type::Int,
                },
            ],
            elem_ty: Type::Int,
            ty: Type::List(Box::new(Type::Int)),
        };
        
        let result = runtime.eval(&ir).unwrap();
        match result {
            Value::List(elems) => {
                assert_eq!(elems.len(), 3);
                assert_eq!(elems[0], Value::Int(1));
                assert_eq!(elems[1], Value::Int(2));
                assert_eq!(elems[2], Value::Int(3));
            }
            _ => panic!("Expected list"),
        }
    }
}