//! Integration tests for WASI sandbox

use std::fs;
use tempfile::TempDir;
use wasi_sandbox::manifest::{
    Capabilities, FilesystemPermissions, NetworkPermissions, Permissions,
};
use wasi_sandbox::*;

#[test]
fn test_manifest_loading() {
    let toml_content = r#"
name = "test-app"
version = "1.0.0"

[permissions.filesystem]
read = ["/tmp/test/*"]
write = ["/tmp/test/output/"]

[permissions.capabilities]
random = true
    "#;

    let manifest = PermissionManifest::from_toml_str(toml_content).unwrap();
    assert_eq!(manifest.name, "test-app");

    let permissions = manifest.to_permission_set();
    assert!(permissions
        .iter()
        .any(|p| matches!(p, Permission::FileRead(_))));
    assert!(permissions.contains(&Permission::Random));
}

#[test]
fn test_permission_patterns() {
    let temp_dir = TempDir::new().unwrap();
    let test_file = temp_dir.path().join("test.txt");
    fs::write(&test_file, "test content").unwrap();

    let pattern = PathPattern::new(format!("{}/*", temp_dir.path().display()));
    assert!(pattern.matches(&test_file.to_string_lossy()));

    let pattern2 = PathPattern::new("/other/path/*");
    assert!(!pattern2.matches(&test_file.to_string_lossy()));
}

#[test]
fn test_ai_friendly_errors() {
    let perm = Permission::FileRead(PathPattern::new("/etc/passwd"));
    let error = PermissionError::NotGranted(perm);

    let message = error.to_ai_friendly(Some(
        "Location: line 10, column 5\nCode: (WASI.read-file \"/etc/passwd\")",
    ));

    assert!(message.contains("ERROR[PERMISSION]"));
    assert!(message.contains("File read permission not granted"));
    assert!(message.contains("Suggestions:"));
    assert!(message.contains("(file-read \"/etc/passwd\")"));
}

#[test]
fn test_sandbox_creation() {
    let manifest = PermissionManifest {
        name: "test".to_string(),
        version: "1.0".to_string(),
        permissions: Permissions {
            filesystem: FilesystemPermissions {
                read: vec!["/tmp/test/*".to_string()],
                ..Default::default()
            },
            capabilities: Capabilities {
                random: true,
                ..Default::default()
            },
            ..Default::default()
        },
    };

    let sandbox = SandboxedWasiRuntime::new(manifest).unwrap();

    // Test permission checking
    let allowed = Permission::FileRead(PathPattern::new("/tmp/test/file.txt"));
    assert!(sandbox.check_permission(&allowed).is_ok());

    let denied = Permission::FileRead(PathPattern::new("/etc/passwd"));
    assert!(sandbox.check_permission(&denied).is_err());
}

#[test]
fn test_network_permissions() {
    let manifest = PermissionManifest {
        name: "test".to_string(),
        version: "1.0".to_string(),
        permissions: Permissions {
            network: NetworkPermissions {
                connect: vec!["api.example.com:443".to_string()],
                ..Default::default()
            },
            ..Default::default()
        },
    };

    let sandbox = SandboxedWasiRuntime::new(manifest).unwrap();

    let allowed =
        Permission::NetworkConnect(HostPattern::new("api.example.com"), PortRange::single(443));
    assert!(sandbox.check_permission(&allowed).is_ok());

    let denied = Permission::NetworkConnect(HostPattern::new("evil.com"), PortRange::single(443));
    assert!(sandbox.check_permission(&denied).is_err());
}
