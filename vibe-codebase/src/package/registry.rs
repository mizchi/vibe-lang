use super::{PackageHash, manifest::PackageManifest, PackageError, Result, utils::copy_dir_all};
use std::collections::HashMap;
use std::path::Path;
use serde::{Serialize, Deserialize};

/// Registry index entry
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegistryEntry {
    pub name: String,
    pub versions: Vec<VersionEntry>,
    pub latest: String, // Hash of latest stable version
}

/// Version entry in registry
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VersionEntry {
    pub version: String,
    pub hash: String,
    pub published_at: String,
    pub yanked: bool,
}

/// Local file-based registry (for testing)
pub struct LocalRegistry {
    root_dir: std::path::PathBuf,
    index: HashMap<String, RegistryEntry>,
}

impl LocalRegistry {
    /// Create a new local registry
    pub fn new(root_dir: std::path::PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&root_dir)?;
        
        let index_path = root_dir.join("index.json");
        let index = if index_path.exists() {
            let content = std::fs::read_to_string(&index_path)?;
            serde_json::from_str(&content)
                .map_err(|e| PackageError::Parse(format!("Failed to parse index: {}", e)))?
        } else {
            HashMap::new()
        };

        Ok(LocalRegistry { root_dir, index })
    }

    /// Publish a package
    pub fn publish(&mut self, manifest: &PackageManifest, hash: &PackageHash, package_dir: &Path) -> Result<()> {
        let name = &manifest.package.name;
        let version = manifest.package.version.as_ref()
            .ok_or_else(|| PackageError::Parse("Package version is required for publishing".to_string()))?;

        // Copy package to registry
        let package_dest = self.root_dir.join("packages").join(hash.to_hex());
        std::fs::create_dir_all(&package_dest)?;
        copy_dir_all(package_dir, &package_dest)?;

        // Update index
        let entry = self.index.entry(name.clone()).or_insert_with(|| {
            RegistryEntry {
                name: name.clone(),
                versions: Vec::new(),
                latest: hash.to_hex(),
            }
        });

        // Add version
        entry.versions.push(VersionEntry {
            version: version.clone(),
            hash: hash.to_hex(),
            published_at: chrono::Utc::now().to_rfc3339(),
            yanked: false,
        });

        // Update latest if this is newer
        // TODO: Implement proper version comparison
        entry.latest = hash.to_hex();

        // Save index
        self.save_index()?;

        Ok(())
    }

    /// Save index to disk
    fn save_index(&self) -> Result<()> {
        let index_path = self.root_dir.join("index.json");
        let content = serde_json::to_string_pretty(&self.index)
            .map_err(|e| PackageError::Parse(format!("Failed to serialize index: {}", e)))?;
        std::fs::write(&index_path, content)?;
        Ok(())
    }

    /// Search packages by name
    pub fn search_by_name(&self, query: &str) -> Vec<&RegistryEntry> {
        let query_lower = query.to_lowercase();
        self.index.values()
            .filter(|entry| entry.name.to_lowercase().contains(&query_lower))
            .collect()
    }

    /// Get package directory
    fn package_dir(&self, hash: &PackageHash) -> std::path::PathBuf {
        self.root_dir.join("packages").join(hash.to_hex())
    }
}

impl super::resolver::PackageRegistry for LocalRegistry {
    fn find_package(&self, name: &str, version: Option<&str>) -> Result<PackageHash> {
        let entry = self.index.get(name)
            .ok_or_else(|| PackageError::NotFound(format!("Package '{}' not found", name)))?;

        let hash_str = if let Some(version) = version {
            // Find specific version
            entry.versions.iter()
                .find(|v| v.version == version && !v.yanked)
                .map(|v| &v.hash)
                .ok_or_else(|| PackageError::NotFound(
                    format!("Version '{}' of package '{}' not found", version, name)
                ))?
        } else {
            // Use latest
            &entry.latest
        };

        PackageHash::from_hex(hash_str)
            .map_err(|_| PackageError::InvalidHash(hash_str.to_string()))
    }

    fn get_manifest(&self, hash: &PackageHash) -> Result<PackageManifest> {
        let package_dir = self.package_dir(hash);
        let manifest_path = package_dir.join("package.vibe");
        
        if !manifest_path.exists() {
            return Err(PackageError::NotFound(format!("Package {} not found", hash.to_hex())));
        }

        PackageManifest::load_from_file(&manifest_path)
    }

    fn download_package(&self, hash: &PackageHash, target_dir: &Path) -> Result<()> {
        let package_dir = self.package_dir(hash);
        
        if !package_dir.exists() {
            return Err(PackageError::NotFound(format!("Package {} not found", hash.to_hex())));
        }

        std::fs::create_dir_all(target_dir)?;
        copy_dir_all(&package_dir, target_dir)?;
        
        Ok(())
    }
}

/// HTTP-based registry client
#[allow(dead_code)]
pub struct HttpRegistry {
    base_url: String,
    client: reqwest::Client,
}

impl HttpRegistry {
    /// Create a new HTTP registry client
    pub fn new(base_url: String) -> Self {
        HttpRegistry {
            base_url,
            client: reqwest::Client::new(),
        }
    }
}

impl super::resolver::PackageRegistry for HttpRegistry {
    fn find_package(&self, _name: &str, _version: Option<&str>) -> Result<PackageHash> {
        // TODO: Implement HTTP API calls
        unimplemented!("HTTP registry not yet implemented")
    }

    fn get_manifest(&self, _hash: &PackageHash) -> Result<PackageManifest> {
        // TODO: Implement HTTP API calls
        unimplemented!("HTTP registry not yet implemented")
    }

    fn download_package(&self, _hash: &PackageHash, _target_dir: &Path) -> Result<()> {
        // TODO: Implement HTTP API calls
        unimplemented!("HTTP registry not yet implemented")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::package::resolver::PackageRegistry;
    use tempfile::TempDir;

    #[test]
    fn test_local_registry() -> Result<()> {
        let temp_dir = TempDir::new().unwrap();
        let registry_dir = temp_dir.path().join("registry");
        let mut registry = LocalRegistry::new(registry_dir)?;

        // Create test package
        let package_dir = temp_dir.path().join("test-package");
        std::fs::create_dir(&package_dir)?;
        std::fs::write(package_dir.join("main.vibe"), "let main = fn {} = 42")?;

        // Create manifest
        let mut manifest = PackageManifest::new("test-package".to_string());
        manifest.package.version = Some("1.0.0".to_string());
        manifest.save_to_file(&package_dir.join("package.vibe"))?;

        // Calculate hash
        let hash = crate::package::hash::calculate_package_hash(&package_dir)?;

        // Publish package
        registry.publish(&manifest, &hash, &package_dir)?;

        // Find package
        let found_hash = registry.find_package("test-package", None)?;
        assert_eq!(found_hash, hash);

        // Find specific version
        let version_hash = registry.find_package("test-package", Some("1.0.0"))?;
        assert_eq!(version_hash, hash);

        Ok(())
    }
}