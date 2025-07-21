//! XS WebAssembly backend - WebAssembly code generation and WASI sandbox
//!
//! This crate combines WebAssembly code generation and WASI sandboxing
//! for the XS language.

use thiserror::Error;
use xs_core::ir::IrExpr;

// WebAssembly code generation modules
pub mod codegen;
pub mod component;
pub mod component_builder;
pub mod emit;
pub mod runner;
pub mod test_runner;
pub mod types;
pub mod wit_generator;

// WASI sandbox modules
pub mod manifest;
pub mod permissions;
pub mod sandbox;
pub mod wasi_error;

// Re-export important types from wasm backend
pub use codegen::CodeGenerator;
pub use runner::{RunResult, WasmTestRunner as WasmRunner};

// Re-export important types from WASI sandbox
pub use manifest::PermissionManifest;
pub use permissions::{HostPattern, PathPattern, Permission, PortRange};
pub use sandbox::SandboxedWasiRuntime;
pub use wasi_error::{PermissionError, Result as SandboxResult};

// Note: WasmModule, WasmFunction, etc. are defined in this file, not re-exported

/// Combined WebAssembly backend errors
#[derive(Debug, Error)]
pub enum WasmError {
    #[error("Code generation error: {0}")]
    CodegenError(#[from] CodeGenError),

    #[error("Runtime error: {0}")]
    RuntimeError(String),

    #[error("Sandbox error: {0}")]
    SandboxError(#[from] PermissionError),

    #[error("Component model error: {0}")]
    ComponentError(String),

    #[error("WASI error: {0}")]
    WasiError(String),

    #[error("Type mismatch: {0}")]
    TypeMismatch(String),

    #[error("Unsupported feature: {0}")]
    UnsupportedFeature(String),
}

/// WebAssembly GC module representation
#[derive(Debug)]
pub struct WasmModule {
    /// Function definitions
    pub functions: Vec<WasmFunction>,
    /// Type definitions for structs and closures
    pub types: Vec<WasmType>,
    /// Global variables
    pub globals: Vec<WasmGlobal>,
    /// Memory configuration
    pub memory: Option<WasmMemory>,
    /// Start function index
    pub start: Option<u32>,
}

/// WebAssembly function definition
#[derive(Debug, Clone)]
pub struct WasmFunction {
    pub name: String,
    pub params: Vec<WasmType>,
    pub results: Vec<WasmType>,
    pub locals: Vec<WasmType>,
    pub body: Vec<WasmInstr>,
}

/// WebAssembly type definitions
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WasmType {
    /// 32-bit integer
    I32,
    /// 64-bit integer
    I64,
    /// 32-bit float
    F32,
    /// 64-bit float
    F64,
    /// Reference to a struct type
    StructRef(u32),
    /// Reference to an array type
    ArrayRef(u32),
    /// Reference to a function type
    FuncRef(u32),
    /// Generic reference type (nullable)
    AnyRef,
    /// Non-nullable reference
    Ref(Box<WasmType>),
}

/// WebAssembly global variable
#[derive(Debug)]
pub struct WasmGlobal {
    pub name: String,
    pub ty: WasmType,
    pub mutable: bool,
    pub init: WasmInstr,
}

/// WebAssembly memory configuration
#[derive(Debug)]
pub struct WasmMemory {
    pub min_pages: u32,
    pub max_pages: Option<u32>,
}

/// WebAssembly instructions
#[derive(Debug, Clone)]
pub enum WasmInstr {
    // Constants
    I32Const(i32),
    I64Const(i64),
    F32Const(f32),
    F64Const(f64),

    // Local operations
    LocalGet(u32),
    LocalSet(u32),
    LocalTee(u32),

    // Global operations
    GlobalGet(u32),
    GlobalSet(u32),

    // Control flow
    Block(Vec<WasmInstr>),
    Loop(Vec<WasmInstr>),
    If {
        result_type: Option<WasmType>,
        then_instrs: Vec<WasmInstr>,
        else_instrs: Vec<WasmInstr>,
    },
    Br(u32),
    BrIf(u32),
    Return,
    Call(u32),
    CallIndirect(u32),

    // Memory operations
    I32Load,
    I64Load,
    I32Store,
    I64Store,

    // Reference operations (GC)
    StructNew(u32),
    StructGet(u32, u32),
    StructSet(u32, u32),
    ArrayNew(u32),
    ArrayGet(u32),
    ArraySet(u32),
    ArrayLen,
    RefNull(WasmType),
    RefIsNull,
    RefCast(WasmType),

    // Arithmetic
    I32Add,
    I32Sub,
    I32Mul,
    I32DivS,
    I32RemS,
    I64Add,
    I64Sub,
    I64Mul,
    I64DivS,
    I64RemS,

    // Comparisons
    I32Eq,
    I32Ne,
    I32LtS,
    I32LeS,
    I32GtS,
    I32GeS,
    I64Eq,
    I64Ne,
    I64LtS,
    I64LeS,
    I64GtS,
    I64GeS,

    // Conversions
    I32ExtendI64S,
    I64ExtendI32S,

    // Stack operations
    Drop,
    Dup,
}

/// Code generation errors
#[derive(Debug, thiserror::Error)]
pub enum CodeGenError {
    #[error("Unsupported IR expression: {0}")]
    UnsupportedExpr(String),

    #[error("Type error: {0}")]
    TypeError(String),

    #[error("Undefined variable: {0}")]
    UndefinedVariable(String),

    #[error("Invalid function call: {0}")]
    InvalidCall(String),
}

/// Generate WebAssembly module from IR
pub fn generate_module(ir: &IrExpr) -> Result<WasmModule, CodeGenError> {
    let mut generator = CodeGenerator::new();
    generator.generate(ir)
}

impl Default for WasmModule {
    fn default() -> Self {
        Self {
            functions: Vec::new(),
            types: Vec::new(),
            globals: Vec::new(),
            memory: None,
            start: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_wasm_type_equality() {
        assert_eq!(WasmType::I32, WasmType::I32);
        assert_ne!(WasmType::I32, WasmType::I64);

        let ref_type = WasmType::Ref(Box::new(WasmType::StructRef(0)));
        assert_eq!(ref_type, WasmType::Ref(Box::new(WasmType::StructRef(0))));
    }
}
