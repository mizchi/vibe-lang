use crate::{PackageHash, manifest::PackageManifest, PackageError, Result, cache::PackageCache};
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::Path;

/// Dependency resolver
pub struct DependencyResolver<'a> {
    cache: &'a PackageCache,
    registry: Option<&'a dyn PackageRegistry>,
}

/// Package registry trait
pub trait PackageRegistry: Send + Sync {
    /// Find package by name and optional version
    fn find_package(&self, name: &str, version: Option<&str>) -> Result<PackageHash>;
    
    /// Get package manifest by hash
    fn get_manifest(&self, hash: &PackageHash) -> Result<PackageManifest>;
    
    /// Download package to local path
    fn download_package(&self, hash: &PackageHash, target_dir: &Path) -> Result<()>;
}

/// Resolved dependency graph
#[derive(Debug, Clone)]
pub struct DependencyGraph {
    /// Root package hash
    pub root: PackageHash,
    
    /// All resolved dependencies (hash -> manifest)
    pub packages: HashMap<PackageHash, PackageManifest>,
    
    /// Dependency edges (package -> dependencies)
    pub edges: HashMap<PackageHash, Vec<PackageHash>>,
    
    /// Topological order for installation
    pub install_order: Vec<PackageHash>,
}

impl<'a> DependencyResolver<'a> {
    /// Create a new resolver
    pub fn new(cache: &'a PackageCache) -> Self {
        DependencyResolver {
            cache,
            registry: None,
        }
    }

    /// Set package registry
    pub fn with_registry(mut self, registry: &'a dyn PackageRegistry) -> Self {
        self.registry = Some(registry);
        self
    }

    /// Resolve dependencies for a package
    pub fn resolve(&self, root_hash: &PackageHash) -> Result<DependencyGraph> {
        let mut graph = DependencyGraph {
            root: root_hash.clone(),
            packages: HashMap::new(),
            edges: HashMap::new(),
            install_order: Vec::new(),
        };

        // BFS to resolve all dependencies
        let mut queue = VecDeque::new();
        let mut visited = HashSet::new();
        
        queue.push_back(root_hash.clone());
        visited.insert(root_hash.clone());

        while let Some(current_hash) = queue.pop_front() {
            // Get manifest (from cache or registry)
            let manifest = self.get_manifest(&current_hash)?;
            
            // Process dependencies
            let mut deps = Vec::new();
            for (_, dep) in &manifest.dependencies {
                let dep_hash = PackageHash::from_hex(&dep.hash)
                    .map_err(|_| PackageError::InvalidHash(dep.hash.clone()))?;
                
                deps.push(dep_hash.clone());
                
                if !visited.contains(&dep_hash) {
                    visited.insert(dep_hash.clone());
                    queue.push_back(dep_hash);
                }
            }
            
            graph.packages.insert(current_hash.clone(), manifest);
            graph.edges.insert(current_hash, deps);
        }

        // Calculate topological order
        graph.install_order = self.topological_sort(&graph)?;

        Ok(graph)
    }

    /// Get manifest for a package
    fn get_manifest(&self, hash: &PackageHash) -> Result<PackageManifest> {
        // Try cache first
        if self.cache.has_package(hash) {
            let package_dir = self.cache.get_package(hash)?;
            let manifest_path = package_dir.join("package.vibe");
            return PackageManifest::load_from_file(&manifest_path);
        }

        // Try registry
        if let Some(registry) = self.registry {
            return registry.get_manifest(hash);
        }

        Err(PackageError::NotFound(format!("Package {} not found", hash.to_hex())))
    }

    /// Topological sort for installation order
    fn topological_sort(&self, graph: &DependencyGraph) -> Result<Vec<PackageHash>> {
        let mut result = Vec::new();
        let mut in_degree: HashMap<PackageHash, usize> = HashMap::new();
        let mut queue = VecDeque::new();

        // Calculate in-degrees
        for (package, _) in &graph.packages {
            in_degree.entry(package.clone()).or_insert(0);
        }
        
        for (_, deps) in &graph.edges {
            for dep in deps {
                *in_degree.entry(dep.clone()).or_insert(0) += 1;
            }
        }

        // Find nodes with no dependencies
        for (package, &degree) in &in_degree {
            if degree == 0 {
                queue.push_back(package.clone());
            }
        }

        // Process queue
        while let Some(current) = queue.pop_front() {
            result.push(current.clone());

            if let Some(deps) = graph.edges.get(&current) {
                for dep in deps {
                    if let Some(degree) = in_degree.get_mut(dep) {
                        *degree -= 1;
                        if *degree == 0 {
                            queue.push_back(dep.clone());
                        }
                    }
                }
            }
        }

        // Check for cycles
        if result.len() != graph.packages.len() {
            return Err(PackageError::Parse("Circular dependency detected".to_string()));
        }

        // Reverse the result since we want dependencies before dependents
        result.reverse();
        Ok(result)
    }

    /// Install all dependencies
    pub async fn install_dependencies(&self, graph: &DependencyGraph, target_dir: &Path) -> Result<()> {
        for hash in &graph.install_order {
            if !self.cache.has_package(hash) {
                if let Some(registry) = self.registry {
                    // Download to temporary directory
                    let temp_dir = target_dir.join(".tmp").join(hash.to_hex());
                    registry.download_package(hash, &temp_dir)?;
                    
                    // Store in cache
                    // Note: This would need mutable access to cache in real implementation
                    // cache.store_package(hash, &temp_dir)?;
                    
                    // Clean up temp directory
                    let _ = std::fs::remove_dir_all(&temp_dir);
                }
            }
        }
        
        Ok(())
    }
}

/// Check for dependency conflicts
pub fn check_conflicts(graph: &DependencyGraph) -> Vec<DependencyConflict> {
    let mut conflicts = Vec::new();
    let mut seen_names: HashMap<String, Vec<PackageHash>> = HashMap::new();

    // Check for packages with same name but different hashes
    for (hash, manifest) in &graph.packages {
        seen_names.entry(manifest.package.name.clone())
            .or_insert_with(Vec::new)
            .push(hash.clone());
    }

    for (name, hashes) in seen_names {
        if hashes.len() > 1 {
            conflicts.push(DependencyConflict {
                package_name: name,
                conflicting_hashes: hashes,
            });
        }
    }

    conflicts
}

/// Dependency conflict
#[derive(Debug, Clone)]
pub struct DependencyConflict {
    pub package_name: String,
    pub conflicting_hashes: Vec<PackageHash>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_topological_sort() -> Result<()> {
        let temp_dir = TempDir::new().unwrap();
        let cache = PackageCache::new(temp_dir.path().to_path_buf())?;
        let resolver = DependencyResolver::new(&cache);

        // Create a test graph
        let mut graph = DependencyGraph {
            root: PackageHash::from_hex("a" .repeat(64).as_str()).unwrap(),
            packages: HashMap::new(),
            edges: HashMap::new(),
            install_order: Vec::new(),
        };

        // Add test packages
        let hash_a = PackageHash::from_hex("a".repeat(64).as_str()).unwrap();
        let hash_b = PackageHash::from_hex("b".repeat(64).as_str()).unwrap();
        let hash_c = PackageHash::from_hex("c".repeat(64).as_str()).unwrap();

        graph.packages.insert(hash_a.clone(), PackageManifest::new("a".to_string()));
        graph.packages.insert(hash_b.clone(), PackageManifest::new("b".to_string()));
        graph.packages.insert(hash_c.clone(), PackageManifest::new("c".to_string()));

        // A depends on B and C
        // B depends on C
        graph.edges.insert(hash_a.clone(), vec![hash_b.clone(), hash_c.clone()]);
        graph.edges.insert(hash_b.clone(), vec![hash_c.clone()]);
        graph.edges.insert(hash_c.clone(), vec![]);

        let order = resolver.topological_sort(&graph)?;
        
        // C should come before B, and B before A
        assert_eq!(order.len(), 3);
        
        // Debug print the order
        for (i, hash) in order.iter().enumerate() {
            let name = if hash == &hash_a { "A" } 
                      else if hash == &hash_b { "B" } 
                      else { "C" };
            println!("Position {}: {}", i, name);
        }
        
        let c_index = order.iter().position(|h| h == &hash_c).unwrap();
        let b_index = order.iter().position(|h| h == &hash_b).unwrap();
        let a_index = order.iter().position(|h| h == &hash_a).unwrap();
        
        println!("C index: {}, B index: {}, A index: {}", c_index, b_index, a_index);
        
        assert!(c_index < b_index);
        assert!(b_index < a_index);

        Ok(())
    }
}