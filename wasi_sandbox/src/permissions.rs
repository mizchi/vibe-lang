//! Permission types and patterns

use serde::{Deserialize, Serialize};
use std::fmt;

/// Core permission types
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "type", content = "value")]
pub enum Permission {
    /// File system read permission
    FileRead(PathPattern),
    /// File system write permission
    FileWrite(PathPattern),
    /// File system create permission
    FileCreate(PathPattern),
    /// File system delete permission
    FileDelete(PathPattern),

    /// Network connect permission
    NetworkConnect(HostPattern, PortRange),
    /// Network listen permission
    NetworkListen(PortRange),

    /// Environment variable read permission
    EnvRead(String),
    /// Environment variable write permission
    EnvWrite(String),

    /// Process spawn permission
    ProcessSpawn(String),
    /// Process signal permission
    ProcessSignal,

    /// Clock read permission
    ClockRead,
    /// Clock set permission
    ClockSet,

    /// Random number generation permission
    Random,
}

/// Path pattern for file system permissions
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct PathPattern {
    pub pattern: String,
    pub recursive: bool,
}

impl PathPattern {
    pub fn new(pattern: impl Into<String>) -> Self {
        let pattern = pattern.into();
        let recursive = pattern.contains("**") || pattern.ends_with('/');
        Self { pattern, recursive }
    }

    pub fn matches(&self, path: &str) -> bool {
        // Simple pattern matching implementation
        // TODO: Implement proper glob pattern matching
        if self.pattern == path {
            return true;
        }

        if self.recursive && path.starts_with(self.pattern.trim_end_matches('*')) {
            return true;
        }

        // Handle wildcard patterns
        if self.pattern.contains('*') {
            let parts: Vec<&str> = self.pattern.split('*').collect();
            if parts.len() == 2 {
                return path.starts_with(parts[0]) && path.ends_with(parts[1]);
            }
        }

        false
    }
}

/// Host pattern for network permissions
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct HostPattern {
    pub pattern: String,
}

impl HostPattern {
    pub fn new(pattern: impl Into<String>) -> Self {
        Self {
            pattern: pattern.into(),
        }
    }

    pub fn matches(&self, host: &str) -> bool {
        if self.pattern == host {
            return true;
        }

        // Handle wildcard patterns like *.example.com
        if self.pattern.starts_with("*.") {
            let suffix = &self.pattern[2..];
            return host.ends_with(suffix);
        }

        // Handle IP patterns like 192.168.1.*
        if self.pattern.ends_with(".*") {
            let prefix = &self.pattern[..self.pattern.len() - 2];
            return host.starts_with(prefix);
        }

        false
    }
}

/// Port range for network permissions
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct PortRange {
    pub start: u16,
    pub end: u16,
}

impl PortRange {
    pub fn new(start: u16, end: u16) -> Self {
        Self { start, end }
    }

    pub fn single(port: u16) -> Self {
        Self {
            start: port,
            end: port,
        }
    }

    pub fn contains(&self, port: u16) -> bool {
        port >= self.start && port <= self.end
    }
}

impl fmt::Display for Permission {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Permission::FileRead(path) => write!(f, "file-read:{}", path.pattern),
            Permission::FileWrite(path) => write!(f, "file-write:{}", path.pattern),
            Permission::FileCreate(path) => write!(f, "file-create:{}", path.pattern),
            Permission::FileDelete(path) => write!(f, "file-delete:{}", path.pattern),
            Permission::NetworkConnect(host, ports) => {
                write!(
                    f,
                    "network-connect:{}:{}-{}",
                    host.pattern, ports.start, ports.end
                )
            }
            Permission::NetworkListen(ports) => {
                write!(f, "network-listen:{}-{}", ports.start, ports.end)
            }
            Permission::EnvRead(var) => write!(f, "env-read:{var}"),
            Permission::EnvWrite(var) => write!(f, "env-write:{var}"),
            Permission::ProcessSpawn(cmd) => write!(f, "process-spawn:{cmd}"),
            Permission::ProcessSignal => write!(f, "process-signal"),
            Permission::ClockRead => write!(f, "clock-read"),
            Permission::ClockSet => write!(f, "clock-set"),
            Permission::Random => write!(f, "random"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_path_pattern_matching() {
        let pattern = PathPattern::new("/app/data/*");
        assert!(pattern.matches("/app/data/file.txt"));
        assert!(!pattern.matches("/app/other/file.txt"));

        let recursive = PathPattern::new("/app/**");
        assert!(recursive.matches("/app/data/file.txt"));
        assert!(recursive.matches("/app/nested/deep/file.txt"));
    }

    #[test]
    fn test_host_pattern_matching() {
        let pattern = HostPattern::new("*.example.com");
        assert!(pattern.matches("api.example.com"));
        assert!(pattern.matches("www.example.com"));
        assert!(!pattern.matches("example.org"));

        let ip_pattern = HostPattern::new("192.168.1.*");
        assert!(ip_pattern.matches("192.168.1.1"));
        assert!(ip_pattern.matches("192.168.1.255"));
        assert!(!ip_pattern.matches("192.168.2.1"));
    }

    #[test]
    fn test_port_range() {
        let range = PortRange::new(8080, 8090);
        assert!(range.contains(8080));
        assert!(range.contains(8085));
        assert!(range.contains(8090));
        assert!(!range.contains(8079));
        assert!(!range.contains(8091));

        let single = PortRange::single(443);
        assert!(single.contains(443));
        assert!(!single.contains(444));
    }
}
