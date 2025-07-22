//! Permission System for XS Language
//!
//! This module defines permissions that can be derived from effects
//! and enforced at runtime.

use std::collections::HashSet;
use std::fmt;
use std::path::PathBuf;
use crate::{Effect, EffectSet};

/// Permission represents runtime access rights
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Permission {
    /// Read from filesystem
    ReadFile(PathPattern),
    /// Write to filesystem
    WriteFile(PathPattern),
    /// Network access
    NetworkAccess(NetworkPattern),
    /// Environment variable access
    EnvAccess(EnvPattern),
    /// Process spawning
    ProcessSpawn,
    /// System time access
    TimeAccess,
    /// Random number generation
    RandomAccess,
    /// Console I/O
    ConsoleIO,
}

/// Pattern for file paths
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum PathPattern {
    /// Exact path
    Exact(PathBuf),
    /// Directory and all subdirectories
    Directory(PathBuf),
    /// Any path matching glob pattern
    Glob(String),
    /// Any path
    Any,
}

/// Pattern for network access
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum NetworkPattern {
    /// Specific host and port
    Host(String, Option<u16>),
    /// Any host on specific port
    Port(u16),
    /// Specific protocol (http, https, etc.)
    Protocol(String),
    /// Any network access
    Any,
}

/// Pattern for environment variables
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum EnvPattern {
    /// Specific variable
    Exact(String),
    /// Variables matching prefix
    Prefix(String),
    /// Any environment variable
    Any,
}

impl fmt::Display for Permission {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Permission::ReadFile(pattern) => write!(f, "read:{}", pattern),
            Permission::WriteFile(pattern) => write!(f, "write:{}", pattern),
            Permission::NetworkAccess(pattern) => write!(f, "net:{}", pattern),
            Permission::EnvAccess(pattern) => write!(f, "env:{}", pattern),
            Permission::ProcessSpawn => write!(f, "process"),
            Permission::TimeAccess => write!(f, "time"),
            Permission::RandomAccess => write!(f, "random"),
            Permission::ConsoleIO => write!(f, "console"),
        }
    }
}

impl fmt::Display for PathPattern {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PathPattern::Exact(path) => write!(f, "{}", path.display()),
            PathPattern::Directory(dir) => write!(f, "{}/**", dir.display()),
            PathPattern::Glob(pattern) => write!(f, "{}", pattern),
            PathPattern::Any => write!(f, "*"),
        }
    }
}

impl fmt::Display for NetworkPattern {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            NetworkPattern::Host(host, Some(port)) => write!(f, "{}:{}", host, port),
            NetworkPattern::Host(host, None) => write!(f, "{}", host),
            NetworkPattern::Port(port) => write!(f, "*:{}", port),
            NetworkPattern::Protocol(proto) => write!(f, "{}://*", proto),
            NetworkPattern::Any => write!(f, "*"),
        }
    }
}

impl fmt::Display for EnvPattern {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EnvPattern::Exact(var) => write!(f, "{}", var),
            EnvPattern::Prefix(prefix) => write!(f, "{}*", prefix),
            EnvPattern::Any => write!(f, "*"),
        }
    }
}

/// A set of permissions
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PermissionSet {
    permissions: HashSet<Permission>,
}

impl PermissionSet {
    /// Create an empty permission set
    pub fn empty() -> Self {
        Self {
            permissions: HashSet::new(),
        }
    }

    /// Create a permission set with all permissions
    pub fn all() -> Self {
        let mut permissions = HashSet::new();
        permissions.insert(Permission::ReadFile(PathPattern::Any));
        permissions.insert(Permission::WriteFile(PathPattern::Any));
        permissions.insert(Permission::NetworkAccess(NetworkPattern::Any));
        permissions.insert(Permission::EnvAccess(EnvPattern::Any));
        permissions.insert(Permission::ProcessSpawn);
        permissions.insert(Permission::TimeAccess);
        permissions.insert(Permission::RandomAccess);
        permissions.insert(Permission::ConsoleIO);
        Self { permissions }
    }

    /// Add a permission
    pub fn add(&mut self, permission: Permission) {
        self.permissions.insert(permission);
    }

    /// Check if a permission is granted
    pub fn has(&self, permission: &Permission) -> bool {
        // Check exact match first
        if self.permissions.contains(permission) {
            return true;
        }

        // Check pattern matches
        for p in &self.permissions {
            if self.permission_matches(p, permission) {
                return true;
            }
        }

        false
    }

    /// Check if one permission pattern matches another
    fn permission_matches(&self, pattern: &Permission, requested: &Permission) -> bool {
        match (pattern, requested) {
            // File permissions
            (Permission::ReadFile(PathPattern::Any), Permission::ReadFile(_)) => true,
            (Permission::ReadFile(PathPattern::Directory(dir)), Permission::ReadFile(PathPattern::Exact(path))) => {
                path.starts_with(dir)
            }
            
            // Network permissions
            (Permission::NetworkAccess(NetworkPattern::Any), Permission::NetworkAccess(_)) => true,
            (Permission::NetworkAccess(NetworkPattern::Protocol(proto1)), 
             Permission::NetworkAccess(NetworkPattern::Host(host, _))) => {
                // Simple check - in reality would parse URL
                host.starts_with(&format!("{}://", proto1))
            }
            
            // Environment permissions
            (Permission::EnvAccess(EnvPattern::Any), Permission::EnvAccess(_)) => true,
            (Permission::EnvAccess(EnvPattern::Prefix(prefix)), 
             Permission::EnvAccess(EnvPattern::Exact(var))) => {
                var.starts_with(prefix)
            }
            
            _ => false,
        }
    }

    /// Derive permissions from effects
    pub fn from_effects(effects: &EffectSet) -> Self {
        let mut permissions = HashSet::new();

        for effect in effects.iter() {
            match effect {
                Effect::IO => {
                    permissions.insert(Permission::ConsoleIO);
                }
                Effect::FileSystem => {
                    // By default, grant read/write to current directory only
                    permissions.insert(Permission::ReadFile(PathPattern::Directory(PathBuf::from("."))));
                    permissions.insert(Permission::WriteFile(PathPattern::Directory(PathBuf::from("."))));
                }
                Effect::Network => {
                    // By default, grant HTTPS only
                    permissions.insert(Permission::NetworkAccess(NetworkPattern::Protocol("https".to_string())));
                }
                Effect::Time => {
                    permissions.insert(Permission::TimeAccess);
                }
                Effect::Random => {
                    permissions.insert(Permission::RandomAccess);
                }
                _ => {}
            }
        }

        Self { permissions }
    }

    /// Create a union of two permission sets
    pub fn union(&self, other: &PermissionSet) -> PermissionSet {
        let mut result = self.clone();
        for perm in &other.permissions {
            result.permissions.insert(perm.clone());
        }
        result
    }

    /// Check if this is a subset of another permission set
    pub fn is_subset_of(&self, other: &PermissionSet) -> bool {
        self.permissions.iter().all(|p| other.has(p))
    }
    
    /// Check if the permission set is empty
    pub fn is_empty(&self) -> bool {
        self.permissions.is_empty()
    }
    
    /// Get iterator over permissions
    pub fn iter(&self) -> impl Iterator<Item = &Permission> {
        self.permissions.iter()
    }
}

impl fmt::Display for PermissionSet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.permissions.is_empty() {
            write!(f, "none")
        } else {
            let perms: Vec<String> = self.permissions.iter().map(|p| p.to_string()).collect();
            write!(f, "{}", perms.join(", "))
        }
    }
}

/// Permission enforcement configuration
#[derive(Debug, Clone)]
pub struct PermissionConfig {
    /// Granted permissions
    pub granted: PermissionSet,
    /// Explicitly denied permissions (overrides granted)
    pub denied: PermissionSet,
    /// Whether to prompt for permissions
    pub prompt: bool,
}

impl PermissionConfig {
    /// Create a new permission configuration
    pub fn new() -> Self {
        Self {
            granted: PermissionSet::empty(),
            denied: PermissionSet::empty(),
            prompt: false,
        }
    }

    /// Create a configuration that allows everything
    pub fn allow_all() -> Self {
        Self {
            granted: PermissionSet::all(),
            denied: PermissionSet::empty(),
            prompt: false,
        }
    }

    /// Create a configuration that denies everything
    pub fn deny_all() -> Self {
        Self {
            granted: PermissionSet::empty(),
            denied: PermissionSet::all(),
            prompt: false,
        }
    }

    /// Check if a permission is allowed
    pub fn is_allowed(&self, permission: &Permission) -> bool {
        !self.denied.has(permission) && self.granted.has(permission)
    }
    
    /// Check if a permission is allowed (alias for is_allowed)
    pub fn check(&self, permission: &Permission) -> bool {
        self.is_allowed(permission)
    }
}

impl Default for PermissionConfig {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_permission_from_effects() {
        let mut effects = EffectSet::single(Effect::IO);
        effects.add(Effect::FileSystem);
        
        let perms = PermissionSet::from_effects(&effects);
        assert!(perms.has(&Permission::ConsoleIO));
        assert!(perms.has(&Permission::ReadFile(PathPattern::Exact(PathBuf::from("./test.txt")))));
    }

    #[test]
    fn test_permission_patterns() {
        let mut perms = PermissionSet::empty();
        perms.add(Permission::ReadFile(PathPattern::Directory(PathBuf::from("/tmp"))));
        
        assert!(perms.has(&Permission::ReadFile(PathPattern::Exact(PathBuf::from("/tmp/test.txt")))));
        assert!(!perms.has(&Permission::ReadFile(PathPattern::Exact(PathBuf::from("/etc/passwd")))));
    }

    #[test]
    fn test_permission_config() {
        let mut config = PermissionConfig::new();
        config.granted.add(Permission::ConsoleIO);
        config.denied.add(Permission::NetworkAccess(NetworkPattern::Any));
        
        assert!(config.is_allowed(&Permission::ConsoleIO));
        assert!(!config.is_allowed(&Permission::NetworkAccess(NetworkPattern::Host("example.com".to_string(), None))));
    }
}