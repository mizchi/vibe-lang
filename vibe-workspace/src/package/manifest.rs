use super::{PackageMetadata, Dependency, EntryPoints, PackageError, Result};
use serde::{Serialize, Deserialize};
use std::collections::HashMap;
use std::path::Path;
use std::fs;

/// Package manifest structure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackageManifest {
    pub package: PackageMetadata,
    pub dependencies: HashMap<String, Dependency>,
    pub exports: Vec<String>,
    pub entry: EntryPoints,
}

impl PackageManifest {
    /// Create a new package manifest
    pub fn new(name: String) -> Self {
        PackageManifest {
            package: PackageMetadata {
                name,
                author: None,
                license: None,
                description: None,
                version: None,
            },
            dependencies: HashMap::new(),
            exports: Vec::new(),
            entry: EntryPoints {
                main: None,
                lib: None,
            },
        }
    }

    /// Load manifest from a file
    pub fn load_from_file(path: &Path) -> Result<Self> {
        let content = fs::read_to_string(path)?;
        Self::parse(&content)
    }

    /// Parse manifest from Vibe syntax
    pub fn parse(content: &str) -> Result<Self> {
        // TODO: Implement proper Vibe syntax parser for manifest
        // For now, use JSON as intermediate format
        let json_content = Self::vibe_to_json(content)?;
        serde_json::from_str(&json_content)
            .map_err(|e| PackageError::Parse(e.to_string()))
    }

    /// Convert Vibe syntax to JSON (temporary implementation)
    fn vibe_to_json(content: &str) -> Result<String> {
        // Simple parser for Vibe manifest syntax
        let mut package_name = "".to_string();
        let mut package_version = None;
        let mut package_author = None;
        let mut package_license = None;
        let mut package_description = None;
        let mut entry_main = None;
        let mut entry_lib = None;
        let mut dependencies = HashMap::new();
        let mut exports = Vec::new();
        
        let lines: Vec<&str> = content.lines().collect();
        let mut i = 0;
        
        while i < lines.len() {
            let line = lines[i].trim();
            
            if line.starts_with("package {") {
                // Parse package block
                i += 1;
                while i < lines.len() && !lines[i].trim().starts_with("}") {
                    let inner_line = lines[i].trim();
                    if let Some(pos) = inner_line.find(':') {
                        let key = inner_line[..pos].trim();
                        let value = inner_line[pos+1..].trim().trim_matches('"');
                        
                        match key {
                            "name" => package_name = value.to_string(),
                            "version" => package_version = Some(value.to_string()),
                            "author" => package_author = Some(value.to_string()),
                            "license" => package_license = Some(value.to_string()),
                            "description" => package_description = Some(value.to_string()),
                            _ => {}
                        }
                    }
                    i += 1;
                }
            } else if line.starts_with("dependencies {") {
                // Parse dependencies block
                i += 1;
                while i < lines.len() && !lines[i].trim().starts_with("}") {
                    let inner_line = lines[i].trim();
                    if let Some(pos) = inner_line.find(':') {
                        let name = inner_line[..pos].trim();
                        let hash = inner_line[pos+1..].trim().trim_start_matches('#');
                        dependencies.insert(name.to_string(), Dependency {
                            name: name.to_string(),
                            hash: hash.to_string(),
                        });
                    }
                    i += 1;
                }
            } else if line.starts_with("exports {") {
                // Parse exports block
                i += 1;
                while i < lines.len() && !lines[i].trim().starts_with("}") {
                    let export = lines[i].trim();
                    if !export.is_empty() {
                        exports.push(export.to_string());
                    }
                    i += 1;
                }
            } else if line.starts_with("entry {") {
                // Parse entry block
                i += 1;
                while i < lines.len() && !lines[i].trim().starts_with("}") {
                    let inner_line = lines[i].trim();
                    if let Some(pos) = inner_line.find(':') {
                        let key = inner_line[..pos].trim();
                        let value = inner_line[pos+1..].trim().trim_matches('"');
                        
                        match key {
                            "main" => entry_main = Some(value.to_string()),
                            "lib" => entry_lib = Some(value.to_string()),
                            _ => {}
                        }
                    }
                    i += 1;
                }
            }
            
            i += 1;
        }
        
        // Create JSON structure
        let manifest = PackageManifest {
            package: PackageMetadata {
                name: package_name,
                version: package_version,
                author: package_author,
                license: package_license,
                description: package_description,
            },
            dependencies,
            exports,
            entry: EntryPoints {
                main: entry_main,
                lib: entry_lib,
            },
        };
        
        serde_json::to_string(&manifest)
            .map_err(|e| PackageError::Parse(format!("Failed to serialize manifest: {}", e)))
    }

    /// Save manifest to a file
    pub fn save_to_file(&self, path: &Path) -> Result<()> {
        let content = self.to_vibe_syntax();
        fs::write(path, content)?;
        Ok(())
    }

    /// Convert to Vibe syntax
    pub fn to_vibe_syntax(&self) -> String {
        let mut result = String::new();
        
        // Package metadata
        result.push_str("package {\n");
        result.push_str(&format!("  name: \"{}\"\n", self.package.name));
        if let Some(author) = &self.package.author {
            result.push_str(&format!("  author: \"{}\"\n", author));
        }
        if let Some(license) = &self.package.license {
            result.push_str(&format!("  license: \"{}\"\n", license));
        }
        if let Some(description) = &self.package.description {
            result.push_str(&format!("  description: \"{}\"\n", description));
        }
        result.push_str("}\n\n");

        // Dependencies
        if !self.dependencies.is_empty() {
            result.push_str("dependencies {\n");
            for (name, dep) in &self.dependencies {
                result.push_str(&format!("  {}: #{}\n", name, dep.hash));
            }
            result.push_str("}\n\n");
        }

        // Exports
        if !self.exports.is_empty() {
            result.push_str("exports {\n");
            for export in &self.exports {
                result.push_str(&format!("  {}\n", export));
            }
            result.push_str("}\n\n");
        }

        // Entry points
        result.push_str("entry {\n");
        if let Some(main) = &self.entry.main {
            result.push_str(&format!("  main: \"{}\"\n", main));
        }
        if let Some(lib) = &self.entry.lib {
            result.push_str(&format!("  lib: \"{}\"\n", lib));
        }
        result.push_str("}\n");

        result
    }

    /// Add a dependency
    pub fn add_dependency(&mut self, name: String, hash: String) {
        self.dependencies.insert(name.clone(), Dependency { name, hash });
    }

    /// Add an export
    pub fn add_export(&mut self, name: String) {
        if !self.exports.contains(&name) {
            self.exports.push(name);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_manifest() {
        let mut manifest = PackageManifest::new("test-package".to_string());
        manifest.package.author = Some("test-author".to_string());
        manifest.add_dependency("http".to_string(), "abc123def456".to_string());
        manifest.add_export("main".to_string());
        
        assert_eq!(manifest.package.name, "test-package");
        assert_eq!(manifest.dependencies.len(), 1);
        assert_eq!(manifest.exports.len(), 1);
    }

    #[test]
    fn test_to_vibe_syntax() {
        let mut manifest = PackageManifest::new("web-framework".to_string());
        manifest.package.author = Some("vibe-community".to_string());
        manifest.package.license = Some("MIT".to_string());
        manifest.add_dependency("http".to_string(), "a3f2b1c4d5e6f7890".to_string());
        manifest.add_export("createServer".to_string());
        manifest.entry.main = Some("src/main.vibe".to_string());
        
        let syntax = manifest.to_vibe_syntax();
        assert!(syntax.contains("name: \"web-framework\""));
        assert!(syntax.contains("author: \"vibe-community\""));
        assert!(syntax.contains("http: #a3f2b1c4d5e6f7890"));
    }
}