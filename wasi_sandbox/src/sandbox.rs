//! WASI sandbox runtime with permission checking

use crate::{Permission, PermissionError, PermissionManifest, Result};
use std::collections::HashSet;
use std::path::PathBuf;
use wasmtime::{Config, Engine, Store};
use wasmtime_wasi::{ambient_authority, Dir, WasiCtx, WasiCtxBuilder};

/// Permission checker for WASI operations
pub struct PermissionChecker {
    granted: HashSet<Permission>,
    denied: HashSet<Permission>,
}

impl PermissionChecker {
    pub fn new(manifest: &PermissionManifest) -> Self {
        Self {
            granted: manifest.to_permission_set(),
            denied: HashSet::new(),
        }
    }

    pub fn check(&self, perm: &Permission) -> Result<()> {
        if self.denied.contains(perm) {
            return Err(PermissionError::Denied(perm.clone()));
        }

        if !self.is_granted(perm) {
            return Err(PermissionError::NotGranted(perm.clone()));
        }

        Ok(())
    }

    fn is_granted(&self, perm: &Permission) -> bool {
        // Direct match
        if self.granted.contains(perm) {
            return true;
        }

        // Pattern matching for paths and hosts
        match perm {
            Permission::FileRead(path) => self.granted.iter().any(|p| {
                if let Permission::FileRead(pattern) = p {
                    pattern.matches(&path.pattern)
                } else {
                    false
                }
            }),
            Permission::FileWrite(path) => self.granted.iter().any(|p| {
                if let Permission::FileWrite(pattern) = p {
                    pattern.matches(&path.pattern)
                } else {
                    false
                }
            }),
            Permission::NetworkConnect(host, port_range) => self.granted.iter().any(|p| {
                if let Permission::NetworkConnect(host_pattern, port_pattern) = p {
                    host_pattern.matches(&host.pattern)
                        && port_pattern.contains(port_range.start)
                        && port_pattern.contains(port_range.end)
                } else {
                    false
                }
            }),
            _ => false,
        }
    }

    pub fn grant(&mut self, perm: Permission) {
        self.granted.insert(perm);
    }

    pub fn deny(&mut self, perm: Permission) {
        self.granted.remove(&perm);
        self.denied.insert(perm);
    }
}

/// WASI runtime with sandboxed permissions
pub struct SandboxedWasiRuntime {
    engine: Engine,
    permissions: PermissionChecker,
}

impl SandboxedWasiRuntime {
    pub fn new(manifest: PermissionManifest) -> Result<Self> {
        let mut config = Config::new();
        config.wasm_component_model(true);

        let engine = Engine::new(&config).map_err(|e| {
            PermissionError::ManifestError(format!("Failed to create engine: {e}"))
        })?;

        let permissions = PermissionChecker::new(&manifest);

        Ok(Self {
            engine,
            permissions,
        })
    }

    pub fn create_store(&self) -> Store<WasiCtx> {
        let wasi_ctx = self.create_wasi_context();
        Store::new(&self.engine, wasi_ctx)
    }

    pub fn create_wasi_context(&self) -> WasiCtx {
        let mut builder = WasiCtxBuilder::new();

        // Configure based on permissions
        self.configure_filesystem(&mut builder);
        self.configure_environment(&mut builder);
        self.configure_capabilities(&mut builder);

        builder.build()
    }

    fn configure_filesystem(&self, builder: &mut WasiCtxBuilder) {
        // Add preopened directories based on permissions
        for perm in &self.permissions.granted {
            match perm {
                Permission::FileRead(pattern) | Permission::FileWrite(pattern) => {
                    if let Ok(dir_path) = self.pattern_to_dir_path(&pattern.pattern) {
                        // Note: In production, we'd need more sophisticated handling
                        // This is a simplified version for the MVP
                        if let Ok(dir) = Dir::open_ambient_dir(&dir_path, ambient_authority()) {
                            builder
                                .preopened_dir(dir, dir_path)
                                .expect("Failed to preopen directory");
                        }
                    }
                }
                _ => {}
            }
        }
    }

    fn configure_environment(&self, builder: &mut WasiCtxBuilder) {
        // Add environment variables based on permissions
        for perm in &self.permissions.granted {
            if let Permission::EnvRead(var) = perm {
                if let Ok(value) = std::env::var(var) {
                    let _ = builder.env(var, &value);
                }
            }
        }
    }

    fn configure_capabilities(&self, _builder: &mut WasiCtxBuilder) {
        // Configure capabilities
        if !self.permissions.granted.contains(&Permission::Random) {
            // Disable random if not granted
            // Note: wasmtime-wasi doesn't expose this directly in the current version
            // In production, we'd need custom WASI implementation
        }

        if !self.permissions.granted.contains(&Permission::ClockRead) {
            // Disable clock access if not granted
            // Note: Similar limitation as above
        }
    }

    fn pattern_to_dir_path(&self, pattern: &str) -> Result<PathBuf> {
        // Extract directory path from pattern
        // This is a simplified implementation
        let path = pattern.trim_end_matches('*').trim_end_matches('/');
        Ok(PathBuf::from(path))
    }

    pub fn check_permission(&self, perm: &Permission) -> Result<()> {
        self.permissions.check(perm)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::PathPattern;

    #[test]
    fn test_permission_checker() {
        let manifest = PermissionManifest {
            name: "test".to_string(),
            version: "1.0".to_string(),
            permissions: Default::default(),
        };

        let mut checker = PermissionChecker::new(&manifest);
        checker.grant(Permission::FileRead(PathPattern::new("/app/data/*")));

        // Should pass
        assert!(checker
            .check(&Permission::FileRead(PathPattern::new(
                "/app/data/file.txt"
            )))
            .is_ok());

        // Should fail
        assert!(checker
            .check(&Permission::FileRead(PathPattern::new("/etc/passwd")))
            .is_err());
    }

    #[test]
    fn test_denied_permissions() {
        let manifest = PermissionManifest {
            name: "test".to_string(),
            version: "1.0".to_string(),
            permissions: Default::default(),
        };

        let mut checker = PermissionChecker::new(&manifest);
        let perm = Permission::FileRead(PathPattern::new("/etc/passwd"));

        checker.grant(perm.clone());
        checker.deny(perm.clone());

        match checker.check(&perm) {
            Err(PermissionError::Denied(_)) => {}
            _ => panic!("Expected Denied error"),
        }
    }
}
