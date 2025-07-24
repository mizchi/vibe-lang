//! XS WebAssembly Runtime - WASI sandbox and test runner for XS language
//!
//! This crate provides runtime functionality for executing WebAssembly modules
//! in a sandboxed WASI environment with fine-grained permission control.

use thiserror::Error;

// Runtime modules
pub mod runner;
pub mod test_runner;

// WASI sandbox modules
pub mod manifest;
pub mod permissions;
pub mod sandbox;
pub mod wasi_error;

// Re-export important types from runtime
pub use runner::{RunResult, WasmTestRunner as WasmRunner};

// Re-export important types from WASI sandbox
pub use manifest::PermissionManifest;
pub use permissions::{HostPattern, PathPattern, Permission, PortRange};
pub use sandbox::SandboxedWasiRuntime;
pub use wasi_error::{PermissionError, Result as SandboxResult};

/// Runtime errors for WebAssembly execution
#[derive(Debug, Error)]
pub enum WasmRuntimeError {
    #[error("Runtime error: {0}")]
    RuntimeError(String),

    #[error("Sandbox error: {0}")]
    SandboxError(#[from] PermissionError),

    #[error("WASI error: {0}")]
    WasiError(String),

    #[error("Test execution error: {0}")]
    TestError(String),

    #[error("Permission denied: {0}")]
    PermissionDenied(String),
}
