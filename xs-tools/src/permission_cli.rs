//! Permission System CLI Integration
//!
//! This module provides command-line interfaces for managing permissions
//! when running XS programs.

use clap::Args;
use std::path::PathBuf;
use xs_core::permission::{Permission, PermissionSet, PermissionConfig, PathPattern, NetworkPattern, EnvPattern};

/// Permission-related CLI arguments
#[derive(Args, Debug, Clone)]
pub struct PermissionArgs {
    /// Allow all permissions (dangerous!)
    #[arg(long, conflicts_with = "deny_all")]
    pub allow_all: bool,

    /// Deny all permissions (safest)
    #[arg(long, conflicts_with = "allow_all")]
    pub deny_all: bool,

    /// Allow file read access to specific paths
    #[arg(long = "allow-read", value_name = "PATH")]
    pub allow_read: Vec<String>,

    /// Allow file write access to specific paths
    #[arg(long = "allow-write", value_name = "PATH")]
    pub allow_write: Vec<String>,

    /// Allow network access to specific hosts
    #[arg(long = "allow-net", value_name = "HOST")]
    pub allow_net: Vec<String>,

    /// Allow environment variable access
    #[arg(long = "allow-env", value_name = "VAR")]
    pub allow_env: Vec<String>,

    /// Allow process spawning
    #[arg(long)]
    pub allow_process: bool,

    /// Allow system time access
    #[arg(long)]
    pub allow_time: bool,

    /// Allow random number generation
    #[arg(long)]
    pub allow_random: bool,

    /// Allow console I/O
    #[arg(long)]
    pub allow_console: bool,

    /// Deny specific permissions (overrides allows)
    #[arg(long = "deny", value_name = "PERMISSION")]
    pub deny: Vec<String>,

    /// Prompt for permissions interactively
    #[arg(long)]
    pub prompt: bool,
}

impl PermissionArgs {
    /// Convert CLI arguments to PermissionConfig
    pub fn to_config(&self) -> PermissionConfig {
        let mut config = if self.allow_all {
            PermissionConfig::allow_all()
        } else if self.deny_all {
            PermissionConfig::deny_all()
        } else {
            PermissionConfig::new()
        };

        config.prompt = self.prompt;

        // Add allowed permissions
        for path in &self.allow_read {
            config.granted.add(Permission::ReadFile(parse_path_pattern(path)));
        }

        for path in &self.allow_write {
            config.granted.add(Permission::WriteFile(parse_path_pattern(path)));
        }

        for host in &self.allow_net {
            config.granted.add(Permission::NetworkAccess(parse_network_pattern(host)));
        }

        for var in &self.allow_env {
            config.granted.add(Permission::EnvAccess(parse_env_pattern(var)));
        }

        if self.allow_process {
            config.granted.add(Permission::ProcessSpawn);
        }

        if self.allow_time {
            config.granted.add(Permission::TimeAccess);
        }

        if self.allow_random {
            config.granted.add(Permission::RandomAccess);
        }

        if self.allow_console {
            config.granted.add(Permission::ConsoleIO);
        }

        // Add denied permissions
        for perm_str in &self.deny {
            if let Some(perm) = parse_permission(perm_str) {
                config.denied.add(perm);
            }
        }

        config
    }

    /// Get permission requirements from effects
    pub fn check_required_permissions(&self, effects: &xs_core::EffectSet) -> PermissionSet {
        PermissionSet::from_effects(effects)
    }

    /// Print permission summary
    pub fn print_summary(&self, _config: &PermissionConfig) {
        use colored::*;

        println!("{}", "Permission Configuration:".bold());
        
        if self.allow_all {
            println!("  {} All permissions granted", "⚠️ ".yellow());
        } else if self.deny_all {
            println!("  {} All permissions denied", "🔒".red());
        } else {
            println!("  Granted permissions:");
            if !self.allow_read.is_empty() {
                println!("    📖 Read: {}", self.allow_read.join(", ").green());
            }
            if !self.allow_write.is_empty() {
                println!("    ✏️  Write: {}", self.allow_write.join(", ").yellow());
            }
            if !self.allow_net.is_empty() {
                println!("    🌐 Network: {}", self.allow_net.join(", ").blue());
            }
            if !self.allow_env.is_empty() {
                println!("    🔧 Environment: {}", self.allow_env.join(", ").cyan());
            }
            if self.allow_console {
                println!("    💬 Console I/O {}", "✓".green());
            }
            if self.allow_time {
                println!("    ⏰ System time {}", "✓".green());
            }
            if self.allow_random {
                println!("    🎲 Random numbers {}", "✓".green());
            }
            if self.allow_process {
                println!("    🚀 Process spawning {}", "✓".green());
            }
        }

        if !self.deny.is_empty() {
            println!("  {} Explicitly denied: {}", "❌".red(), self.deny.join(", "));
        }

        if self.prompt {
            println!("  {} Will prompt for ungranted permissions", "❓".blue());
        }
    }
}

/// Parse a path pattern from string
fn parse_path_pattern(s: &str) -> PathPattern {
    if s == "*" {
        PathPattern::Any
    } else if s.ends_with("/**") {
        PathPattern::Directory(PathBuf::from(&s[..s.len()-3]))
    } else if s.contains('*') || s.contains('?') {
        PathPattern::Glob(s.to_string())
    } else {
        PathPattern::Exact(PathBuf::from(s))
    }
}

/// Parse a network pattern from string
fn parse_network_pattern(s: &str) -> NetworkPattern {
    if s == "*" {
        NetworkPattern::Any
    } else if s.starts_with("*:") {
        if let Ok(port) = s[2..].parse::<u16>() {
            NetworkPattern::Port(port)
        } else {
            NetworkPattern::Any
        }
    } else if s.ends_with("://*") {
        NetworkPattern::Protocol(s[..s.len()-4].to_string())
    } else if let Some(colon_pos) = s.rfind(':') {
        let host = s[..colon_pos].to_string();
        if let Ok(port) = s[colon_pos+1..].parse::<u16>() {
            NetworkPattern::Host(host, Some(port))
        } else {
            NetworkPattern::Host(s.to_string(), None)
        }
    } else {
        NetworkPattern::Host(s.to_string(), None)
    }
}

/// Parse an environment pattern from string
fn parse_env_pattern(s: &str) -> EnvPattern {
    if s == "*" {
        EnvPattern::Any
    } else if s.ends_with('*') {
        EnvPattern::Prefix(s[..s.len()-1].to_string())
    } else {
        EnvPattern::Exact(s.to_string())
    }
}

/// Parse a permission from string
fn parse_permission(s: &str) -> Option<Permission> {
    let parts: Vec<&str> = s.splitn(2, ':').collect();
    
    match parts[0] {
        "read" => {
            let pattern = if parts.len() > 1 {
                parse_path_pattern(parts[1])
            } else {
                PathPattern::Any
            };
            Some(Permission::ReadFile(pattern))
        }
        "write" => {
            let pattern = if parts.len() > 1 {
                parse_path_pattern(parts[1])
            } else {
                PathPattern::Any
            };
            Some(Permission::WriteFile(pattern))
        }
        "net" | "network" => {
            let pattern = if parts.len() > 1 {
                parse_network_pattern(parts[1])
            } else {
                NetworkPattern::Any
            };
            Some(Permission::NetworkAccess(pattern))
        }
        "env" => {
            let pattern = if parts.len() > 1 {
                parse_env_pattern(parts[1])
            } else {
                EnvPattern::Any
            };
            Some(Permission::EnvAccess(pattern))
        }
        "process" => Some(Permission::ProcessSpawn),
        "time" => Some(Permission::TimeAccess),
        "random" => Some(Permission::RandomAccess),
        "console" | "io" => Some(Permission::ConsoleIO),
        _ => None,
    }
}

/// Interactive permission prompt
pub fn prompt_permission(permission: &Permission) -> bool {
    use std::io::{self, Write};
    
    print!("⚠️  Permission requested: {} [y/N] ", permission);
    io::stdout().flush().unwrap();
    
    let mut input = String::new();
    io::stdin().read_line(&mut input).unwrap();
    
    matches!(input.trim().to_lowercase().as_str(), "y" | "yes")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_path_pattern() {
        match parse_path_pattern("/tmp/**") {
            PathPattern::Directory(path) => assert_eq!(path, PathBuf::from("/tmp")),
            _ => panic!("Expected directory pattern"),
        }

        match parse_path_pattern("*.txt") {
            PathPattern::Glob(s) => assert_eq!(s, "*.txt"),
            _ => panic!("Expected glob pattern"),
        }

        match parse_path_pattern("/etc/passwd") {
            PathPattern::Exact(path) => assert_eq!(path, PathBuf::from("/etc/passwd")),
            _ => panic!("Expected exact pattern"),
        }
    }

    #[test]
    fn test_parse_network_pattern() {
        match parse_network_pattern("example.com:443") {
            NetworkPattern::Host(host, Some(port)) => {
                assert_eq!(host, "example.com");
                assert_eq!(port, 443);
            }
            _ => panic!("Expected host with port"),
        }

        match parse_network_pattern("https://*") {
            NetworkPattern::Protocol(proto) => assert_eq!(proto, "https"),
            _ => panic!("Expected protocol pattern"),
        }
    }
}