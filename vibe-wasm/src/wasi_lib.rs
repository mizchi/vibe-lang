//! WASI Sandbox Permission System for Vibe Language

pub mod error;
pub mod manifest;
pub mod permissions;
pub mod sandbox;

pub use error::{PermissionError, Result};
pub use manifest::PermissionManifest;
pub use permissions::{HostPattern, PathPattern, Permission, PortRange};
pub use sandbox::SandboxedWasiRuntime;
