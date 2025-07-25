use super::{PackageHash, manifest::PackageManifest, Result, PackageError, utils::copy_dir_all};
use std::path::{Path, PathBuf};
use std::fs;
use std::collections::HashMap;
use serde::{Serialize, Deserialize};

/// Package cache manager
pub struct PackageCache {
    cache_dir: PathBuf,
    metadata: CacheMetadata,
}

/// Cache metadata
#[derive(Debug, Clone, Serialize, Deserialize)]
struct CacheMetadata {
    packages: HashMap<String, PackageEntry>,
}

/// Package entry in cache
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackageEntry {
    pub hash: String,
    pub name: String,
    pub version: Option<String>,
    pub dependencies: Vec<String>,
}

impl PackageCache {
    /// Create a new package cache
    pub fn new(cache_dir: PathBuf) -> Result<Self> {
        // Ensure cache directory exists
        fs::create_dir_all(&cache_dir)?;
        
        let metadata_path = cache_dir.join("metadata.json");
        let metadata = if metadata_path.exists() {
            let content = fs::read_to_string(&metadata_path)?;
            serde_json::from_str(&content)
                .map_err(|e| PackageError::Cache(format!("Failed to load metadata: {}", e)))?
        } else {
            CacheMetadata {
                packages: HashMap::new(),
            }
        };

        Ok(PackageCache { cache_dir, metadata })
    }

    /// Get default cache directory
    pub fn default_cache_dir() -> Result<PathBuf> {
        let home_dir = dirs::home_dir()
            .ok_or_else(|| PackageError::Cache("Failed to get home directory".to_string()))?;
        Ok(home_dir.join(".vibe").join("cache"))
    }

    /// Check if package exists in cache
    pub fn has_package(&self, hash: &PackageHash) -> bool {
        let package_dir = self.package_dir(hash);
        package_dir.exists()
    }

    /// Get package directory path
    pub fn package_dir(&self, hash: &PackageHash) -> PathBuf {
        self.cache_dir.join("packages").join(hash.to_hex())
    }

    /// Store package in cache
    pub fn store_package(&mut self, hash: &PackageHash, source_dir: &Path) -> Result<()> {
        let package_dir = self.package_dir(hash);
        
        // Create package directory
        fs::create_dir_all(&package_dir)?;
        
        // Copy all files
        copy_dir_all(source_dir, &package_dir)?;
        
        // Load manifest to update metadata
        let manifest_path = package_dir.join("package.vibe");
        if manifest_path.exists() {
            let manifest = PackageManifest::load_from_file(&manifest_path)?;
            
            // Update metadata
            let entry = PackageEntry {
                hash: hash.to_hex(),
                name: manifest.package.name.clone(),
                version: manifest.package.version.clone(),
                dependencies: manifest.dependencies.keys().cloned().collect(),
            };
            
            self.metadata.packages.insert(hash.to_hex(), entry);
            self.save_metadata()?;
        }
        
        Ok(())
    }

    /// Get package from cache
    pub fn get_package(&self, hash: &PackageHash) -> Result<PathBuf> {
        let package_dir = self.package_dir(hash);
        if !package_dir.exists() {
            return Err(PackageError::NotFound(format!("Package {} not in cache", hash.to_hex())));
        }
        Ok(package_dir)
    }

    /// List all cached packages
    pub fn list_packages(&self) -> Vec<(&String, &PackageEntry)> {
        self.metadata.packages.iter().collect()
    }

    /// Search packages by name
    pub fn search_by_name(&self, name: &str) -> Vec<&PackageEntry> {
        self.metadata.packages.values()
            .filter(|entry| entry.name.contains(name))
            .collect()
    }

    /// Clear cache
    pub fn clear(&mut self) -> Result<()> {
        let packages_dir = self.cache_dir.join("packages");
        if packages_dir.exists() {
            fs::remove_dir_all(&packages_dir)?;
        }
        
        self.metadata.packages.clear();
        self.save_metadata()?;
        
        Ok(())
    }

    /// Save metadata
    fn save_metadata(&self) -> Result<()> {
        let metadata_path = self.cache_dir.join("metadata.json");
        let content = serde_json::to_string_pretty(&self.metadata)
            .map_err(|e| PackageError::Cache(format!("Failed to serialize metadata: {}", e)))?;
        fs::write(&metadata_path, content)?;
        Ok(())
    }

    /// Remove a specific package from cache
    pub fn remove_package(&mut self, hash: &PackageHash) -> Result<()> {
        let package_dir = self.package_dir(hash);
        if package_dir.exists() {
            fs::remove_dir_all(&package_dir)?;
        }
        
        self.metadata.packages.remove(&hash.to_hex());
        self.save_metadata()?;
        
        Ok(())
    }

    /// Get cache size in bytes
    pub fn cache_size(&self) -> Result<u64> {
        let mut total_size = 0;
        let packages_dir = self.cache_dir.join("packages");
        
        if packages_dir.exists() {
            for entry in fs::read_dir(&packages_dir)? {
                let entry = entry?;
                if entry.file_type()?.is_dir() {
                    total_size += dir_size(&entry.path())?;
                }
            }
        }
        
        Ok(total_size)
    }
}

/// Calculate directory size
fn dir_size(path: &Path) -> Result<u64> {
    let mut size = 0;
    
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let metadata = entry.metadata()?;
        
        if metadata.is_dir() {
            size += dir_size(&entry.path())?;
        } else {
            size += metadata.len();
        }
    }
    
    Ok(size)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;
    use crate::package::hash::calculate_package_hash;

    #[test]
    fn test_cache_operations() -> Result<()> {
        let temp_dir = TempDir::new().unwrap();
        let cache_dir = temp_dir.path().join("cache");
        let mut cache = PackageCache::new(cache_dir)?;
        
        // Create a test package
        let package_dir = temp_dir.path().join("test-package");
        fs::create_dir(&package_dir)?;
        fs::write(package_dir.join("main.vibe"), "let main = fn {} = 42")?;
        
        // Calculate hash
        let hash = calculate_package_hash(&package_dir)?;
        
        // Store package
        assert!(!cache.has_package(&hash));
        cache.store_package(&hash, &package_dir)?;
        assert!(cache.has_package(&hash));
        
        // Get package
        let cached_dir = cache.get_package(&hash)?;
        assert!(cached_dir.exists());
        
        // Remove package
        cache.remove_package(&hash)?;
        assert!(!cache.has_package(&hash));
        
        Ok(())
    }
}