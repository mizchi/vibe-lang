pub mod manifest;
pub mod hash;
pub mod cache;
pub mod registry;
pub mod resolver;
pub mod utils;

use sha2::{Sha256, Digest};

/// Package hash type (SHA256)
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PackageHash(pub [u8; 32]);

impl PackageHash {
    pub fn from_bytes(bytes: &[u8]) -> Self {
        let mut hasher = Sha256::new();
        hasher.update(bytes);
        let result = hasher.finalize();
        let mut hash = [0u8; 32];
        hash.copy_from_slice(&result);
        PackageHash(hash)
    }

    pub fn to_hex(&self) -> String {
        hex::encode(&self.0)
    }

    pub fn from_hex(hex_str: &str) -> Result<Self> {
        let bytes = hex::decode(hex_str)
            .map_err(|_| PackageError::InvalidHash(hex_str.to_string()))?;
        if bytes.len() != 32 {
            return Err(PackageError::InvalidHash(
                format!("Invalid hash length: expected 32 bytes, got {}", bytes.len())
            ));
        }
        let mut hash = [0u8; 32];
        hash.copy_from_slice(&bytes);
        Ok(PackageHash(hash))
    }
}

/// Package identifier
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackageId {
    pub name: String,
    pub hash: PackageHash,
}

/// Package metadata
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PackageMetadata {
    pub name: String,
    pub author: Option<String>,
    pub license: Option<String>,
    pub description: Option<String>,
    pub version: Option<String>,
}

/// Dependency specification
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Dependency {
    pub name: String,
    pub hash: String, // Hex string representation
}

/// Entry points
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct EntryPoints {
    pub main: Option<String>,
    pub lib: Option<String>,
}

/// Error types
#[derive(Debug, thiserror::Error)]
pub enum PackageError {
    #[error("Package not found: {0}")]
    NotFound(String),
    
    #[error("Invalid package hash: {0}")]
    InvalidHash(String),
    
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    
    #[error("Parse error: {0}")]
    Parse(String),
    
    #[error("Network error: {0}")]
    Network(#[from] reqwest::Error),
    
    #[error("Cache error: {0}")]
    Cache(String),
}

pub type Result<T> = std::result::Result<T, PackageError>;