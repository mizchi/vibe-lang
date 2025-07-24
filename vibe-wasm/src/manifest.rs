//! Permission manifest parsing and management

use crate::permissions::{HostPattern, PathPattern, Permission, PortRange};
use crate::wasi_error::Result;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::Path;

/// Permission manifest for an XS application
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PermissionManifest {
    pub name: String,
    pub version: String,
    #[serde(default)]
    pub permissions: Permissions,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Permissions {
    #[serde(default)]
    pub filesystem: FilesystemPermissions,
    #[serde(default)]
    pub network: NetworkPermissions,
    #[serde(default)]
    pub environment: EnvironmentPermissions,
    #[serde(default)]
    pub process: ProcessPermissions,
    #[serde(default)]
    pub capabilities: Capabilities,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FilesystemPermissions {
    #[serde(default)]
    pub read: Vec<String>,
    #[serde(default)]
    pub write: Vec<String>,
    #[serde(default)]
    pub create: Vec<String>,
    #[serde(default)]
    pub delete: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct NetworkPermissions {
    #[serde(default)]
    pub connect: Vec<String>,
    #[serde(default)]
    pub listen: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct EnvironmentPermissions {
    #[serde(default)]
    pub read: Vec<String>,
    #[serde(default)]
    pub write: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ProcessPermissions {
    #[serde(default)]
    pub spawn: Vec<String>,
    #[serde(default)]
    pub signal: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Capabilities {
    #[serde(default)]
    pub random: bool,
    #[serde(default)]
    pub clock_read: bool,
    #[serde(default)]
    pub clock_set: bool,
}

impl PermissionManifest {
    /// Load manifest from TOML file
    pub fn from_toml_file(path: impl AsRef<Path>) -> Result<Self> {
        let content = std::fs::read_to_string(path)?;
        Self::from_toml_str(&content)
    }

    /// Parse manifest from TOML string
    pub fn from_toml_str(content: &str) -> Result<Self> {
        Ok(toml::from_str(content)?)
    }

    /// Load manifest from JSON file
    pub fn from_json_file(path: impl AsRef<Path>) -> Result<Self> {
        let content = std::fs::read_to_string(path)?;
        Self::from_json_str(&content)
    }

    /// Parse manifest from JSON string
    pub fn from_json_str(content: &str) -> Result<Self> {
        Ok(serde_json::from_str(content)?)
    }

    /// Convert to a set of permissions
    pub fn to_permission_set(&self) -> HashSet<Permission> {
        let mut permissions = HashSet::new();

        // Filesystem permissions
        for path in &self.permissions.filesystem.read {
            permissions.insert(Permission::FileRead(PathPattern::new(path)));
        }
        for path in &self.permissions.filesystem.write {
            permissions.insert(Permission::FileWrite(PathPattern::new(path)));
        }
        for path in &self.permissions.filesystem.create {
            permissions.insert(Permission::FileCreate(PathPattern::new(path)));
        }
        for path in &self.permissions.filesystem.delete {
            permissions.insert(Permission::FileDelete(PathPattern::new(path)));
        }

        // Network permissions
        for spec in &self.permissions.network.connect {
            if let Some((host, port_spec)) = spec.split_once(':') {
                let port_range = parse_port_range(port_spec).unwrap_or(PortRange::new(1, 65535));
                permissions.insert(Permission::NetworkConnect(
                    HostPattern::new(host),
                    port_range,
                ));
            }
        }
        for spec in &self.permissions.network.listen {
            let port_range = parse_port_range(spec).unwrap_or(PortRange::new(1, 65535));
            permissions.insert(Permission::NetworkListen(port_range));
        }

        // Environment permissions
        for var in &self.permissions.environment.read {
            permissions.insert(Permission::EnvRead(var.clone()));
        }
        for var in &self.permissions.environment.write {
            permissions.insert(Permission::EnvWrite(var.clone()));
        }

        // Process permissions
        for cmd in &self.permissions.process.spawn {
            permissions.insert(Permission::ProcessSpawn(cmd.clone()));
        }
        if self.permissions.process.signal {
            permissions.insert(Permission::ProcessSignal);
        }

        // Capabilities
        if self.permissions.capabilities.random {
            permissions.insert(Permission::Random);
        }
        if self.permissions.capabilities.clock_read {
            permissions.insert(Permission::ClockRead);
        }
        if self.permissions.capabilities.clock_set {
            permissions.insert(Permission::ClockSet);
        }

        permissions
    }
}

fn parse_port_range(spec: &str) -> Option<PortRange> {
    if let Some((start, end)) = spec.split_once('-') {
        let start = start.parse().ok()?;
        let end = end.parse().ok()?;
        Some(PortRange::new(start, end))
    } else if let Ok(port) = spec.parse() {
        Some(PortRange::single(port))
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_toml_manifest() {
        let toml = r#"
name = "test-app"
version = "1.0.0"

[permissions.filesystem]
read = ["/app/data/*", "/config/app.conf"]
write = ["/app/output/"]

[permissions.network]
connect = ["api.example.com:443", "*.internal.net:8080-8090"]

[permissions.environment]
read = ["LOG_LEVEL", "APP_CONFIG"]

[permissions.capabilities]
random = true
clock_read = true
        "#;

        let manifest = PermissionManifest::from_toml_str(toml).unwrap();
        assert_eq!(manifest.name, "test-app");
        assert_eq!(manifest.version, "1.0.0");

        let permissions = manifest.to_permission_set();
        assert!(permissions.contains(&Permission::FileRead(PathPattern::new("/app/data/*"))));
        assert!(permissions.contains(&Permission::Random));
    }

    #[test]
    fn test_parse_json_manifest() {
        let json = r#"{
            "name": "test-app",
            "version": "1.0.0",
            "permissions": {
                "filesystem": {
                    "read": ["/app/data/*"],
                    "write": ["/app/output/"]
                },
                "capabilities": {
                    "random": true
                }
            }
        }"#;

        let manifest = PermissionManifest::from_json_str(json).unwrap();
        assert_eq!(manifest.name, "test-app");

        let permissions = manifest.to_permission_set();
        assert!(permissions.contains(&Permission::FileRead(PathPattern::new("/app/data/*"))));
        assert!(permissions.contains(&Permission::Random));
    }
}
