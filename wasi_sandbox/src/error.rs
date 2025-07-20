//! Error types for the permission system

use crate::Permission;
use thiserror::Error;

pub type Result<T> = std::result::Result<T, PermissionError>;

#[derive(Debug, Error)]
pub enum PermissionError {
    #[error("Permission denied: {0}")]
    Denied(Permission),

    #[error("Permission not granted: {0}")]
    NotGranted(Permission),

    #[error("Invalid permission pattern: {0}")]
    InvalidPattern(String),

    #[error("Permission conflict: {0} conflicts with {1}")]
    Conflict(Permission, Permission),

    #[error("Manifest error: {0}")]
    ManifestError(String),

    #[error("IO error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("TOML parse error: {0}")]
    TomlError(#[from] toml::de::Error),

    #[error("JSON parse error: {0}")]
    JsonError(#[from] serde_json::Error),
}

impl PermissionError {
    /// Create an AI-friendly error message with suggestions
    pub fn to_ai_friendly(&self, context: Option<&str>) -> String {
        match self {
            PermissionError::NotGranted(perm) => {
                format!(
                    "ERROR[PERMISSION]: {} not granted\n\
                    {}\
                    Required permission: {}\n\n\
                    Suggestions:\n\
                    1. Add permission to module declaration:\n\
                       (permissions\n\
                         ({}))\n\
                    \n\
                    2. Or add to permissions.toml:\n\
                       [[permissions.{}]]\n\
                       {} = [\"{}\"]\n",
                    permission_description(perm),
                    context.map(|c| format!("{}\n", c)).unwrap_or_default(),
                    perm,
                    permission_to_xs(perm),
                    permission_category(perm),
                    permission_action(perm),
                    permission_resource(perm)
                )
            }
            PermissionError::Denied(perm) => {
                format!(
                    "ERROR[PERMISSION]: {} explicitly denied\n\
                    {}\
                    This permission has been explicitly denied and cannot be granted.\n\
                    Security note: {}",
                    permission_description(perm),
                    context.map(|c| format!("{}\n", c)).unwrap_or_default(),
                    security_note(perm)
                )
            }
            _ => self.to_string(),
        }
    }
}

fn permission_description(perm: &Permission) -> &'static str {
    match perm {
        Permission::FileRead(_) => "File read permission",
        Permission::FileWrite(_) => "File write permission",
        Permission::FileCreate(_) => "File create permission",
        Permission::FileDelete(_) => "File delete permission",
        Permission::NetworkConnect(_, _) => "Network connect permission",
        Permission::NetworkListen(_) => "Network listen permission",
        Permission::EnvRead(_) => "Environment variable read permission",
        Permission::EnvWrite(_) => "Environment variable write permission",
        Permission::ProcessSpawn(_) => "Process spawn permission",
        Permission::ProcessSignal => "Process signal permission",
        Permission::ClockRead => "Clock read permission",
        Permission::ClockSet => "Clock set permission",
        Permission::Random => "Random number generation permission",
    }
}

fn permission_to_xs(perm: &Permission) -> String {
    match perm {
        Permission::FileRead(path) => format!("file-read \"{}\"", path.pattern),
        Permission::FileWrite(path) => format!("file-write \"{}\"", path.pattern),
        Permission::FileCreate(path) => format!("file-create \"{}\"", path.pattern),
        Permission::FileDelete(path) => format!("file-delete \"{}\"", path.pattern),
        Permission::NetworkConnect(host, ports) => {
            format!(
                "network-connect \"{}\" {}-{}",
                host.pattern, ports.start, ports.end
            )
        }
        Permission::NetworkListen(ports) => {
            format!("network-listen {}-{}", ports.start, ports.end)
        }
        Permission::EnvRead(var) => format!("env-read \"{}\"", var),
        Permission::EnvWrite(var) => format!("env-write \"{}\"", var),
        Permission::ProcessSpawn(cmd) => format!("process-spawn \"{}\"", cmd),
        Permission::ProcessSignal => "process-signal".to_string(),
        Permission::ClockRead => "clock-read".to_string(),
        Permission::ClockSet => "clock-set".to_string(),
        Permission::Random => "random".to_string(),
    }
}

fn permission_category(perm: &Permission) -> &'static str {
    match perm {
        Permission::FileRead(_)
        | Permission::FileWrite(_)
        | Permission::FileCreate(_)
        | Permission::FileDelete(_) => "filesystem",
        Permission::NetworkConnect(_, _) | Permission::NetworkListen(_) => "network",
        Permission::EnvRead(_) | Permission::EnvWrite(_) => "environment",
        Permission::ProcessSpawn(_) | Permission::ProcessSignal => "process",
        Permission::ClockRead | Permission::ClockSet => "clock",
        Permission::Random => "capabilities",
    }
}

fn permission_action(perm: &Permission) -> &'static str {
    match perm {
        Permission::FileRead(_) | Permission::EnvRead(_) => "read",
        Permission::FileWrite(_) | Permission::EnvWrite(_) => "write",
        Permission::FileCreate(_) => "create",
        Permission::FileDelete(_) => "delete",
        Permission::NetworkConnect(_, _) => "connect",
        Permission::NetworkListen(_) => "listen",
        Permission::ProcessSpawn(_) => "spawn",
        Permission::ProcessSignal => "signal",
        Permission::ClockRead => "read",
        Permission::ClockSet => "set",
        Permission::Random => "random",
    }
}

fn permission_resource(perm: &Permission) -> String {
    match perm {
        Permission::FileRead(path)
        | Permission::FileWrite(path)
        | Permission::FileCreate(path)
        | Permission::FileDelete(path) => path.pattern.clone(),
        Permission::NetworkConnect(host, _) => host.pattern.clone(),
        Permission::NetworkListen(ports) => format!("{}-{}", ports.start, ports.end),
        Permission::EnvRead(var) | Permission::EnvWrite(var) => var.clone(),
        Permission::ProcessSpawn(cmd) => cmd.clone(),
        _ => "".to_string(),
    }
}

fn security_note(perm: &Permission) -> &'static str {
    match perm {
        Permission::FileRead(path) if path.pattern.contains("/etc") => {
            "Reading system files may expose sensitive information."
        }
        Permission::FileWrite(path) if path.pattern.contains("/etc") => {
            "Writing to system files may compromise system security."
        }
        Permission::NetworkConnect(_, _) => {
            "Network connections may expose data to external servers."
        }
        Permission::ProcessSpawn(_) => "Spawning processes may execute arbitrary code.",
        Permission::EnvWrite(_) => "Modifying environment variables may affect system behavior.",
        _ => "Consider if this access is truly necessary.",
    }
}
