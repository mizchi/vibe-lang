//! Namespace system for XS language
//!
//! Provides Unison-like content-addressed namespace management with
//! hierarchical organization and dependency tracking.

use crate::hash::DefinitionHash;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use vibe_core::{Expr, Type, XsError};

/// A path in the namespace hierarchy (e.g., ["Math", "utils", "fibonacci"])
#[derive(Debug, Clone, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub struct NamespacePath(pub Vec<String>);

impl NamespacePath {
    pub fn new(segments: Vec<String>) -> Self {
        Self(segments)
    }

    pub fn root() -> Self {
        Self(vec![])
    }

    #[allow(clippy::should_implement_trait)]
    pub fn from_str(path: &str) -> Self {
        if path.is_empty() {
            Self::root()
        } else {
            Self(path.split('.').map(String::from).collect())
        }
    }

    #[allow(clippy::inherent_to_string)]
    pub fn to_string(&self) -> String {
        self.0.join(".")
    }

    pub fn append(&self, name: &str) -> Self {
        let mut segments = self.0.clone();
        segments.push(name.to_string());
        Self(segments)
    }

    pub fn parent(&self) -> Option<Self> {
        if self.0.is_empty() {
            None
        } else {
            let mut segments = self.0.clone();
            segments.pop();
            Some(Self(segments))
        }
    }

    pub fn child(&self, name: &str) -> Self {
        let mut segments = self.0.clone();
        segments.push(name.to_string());
        Self(segments)
    }
}

/// A fully qualified definition path (namespace + name)
#[derive(Debug, Clone, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub struct DefinitionPath {
    pub namespace: NamespacePath,
    pub name: String,
}

impl DefinitionPath {
    pub fn new(namespace: NamespacePath, name: String) -> Self {
        Self { namespace, name }
    }

    #[allow(clippy::should_implement_trait)]
    pub fn from_str(path: &str) -> Option<Self> {
        let parts: Vec<&str> = path.split('.').collect();
        if parts.is_empty() {
            return None;
        }

        let name = parts.last()?.to_string();
        let namespace_parts: Vec<String> = parts[..parts.len() - 1]
            .iter()
            .map(|s| s.to_string())
            .collect();

        Some(Self {
            namespace: NamespacePath(namespace_parts),
            name,
        })
    }

    #[allow(clippy::inherent_to_string)]
    pub fn to_string(&self) -> String {
        if self.namespace.0.is_empty() {
            self.name.clone()
        } else {
            format!("{}.{}", self.namespace.to_string(), self.name)
        }
    }
}

/// Content of a definition
#[derive(Debug, Clone)]
pub enum DefinitionContent {
    Function {
        params: Vec<String>,
        body: Expr,
    },
    Type {
        // Type definition details
        params: Vec<String>,
        constructors: Vec<(String, Vec<Type>)>,
    },
    Value(Expr),
}

/// Metadata associated with a definition
#[derive(Debug, Clone)]
pub struct DefinitionMetadata {
    pub created_at: std::time::SystemTime,
    pub author: Option<String>,
    pub documentation: Option<String>,
    pub tests: Vec<DefinitionHash>,
}

impl Default for DefinitionMetadata {
    fn default() -> Self {
        Self {
            created_at: std::time::SystemTime::now(),
            author: None,
            documentation: None,
            tests: vec![],
        }
    }
}

/// A definition in the namespace system
#[derive(Debug, Clone)]
pub struct Definition {
    pub hash: DefinitionHash,
    pub content: DefinitionContent,
    pub dependencies: HashSet<DefinitionHash>,
    pub type_signature: Type,
    pub metadata: DefinitionMetadata,
}

/// A namespace containing definitions and sub-namespaces
#[derive(Debug, Clone)]
pub struct Namespace {
    pub path: NamespacePath,
    pub definitions: HashMap<String, DefinitionHash>,
    pub subnamespaces: HashSet<String>,
}

impl Namespace {
    pub fn new(path: NamespacePath) -> Self {
        Self {
            path,
            definitions: HashMap::new(),
            subnamespaces: HashSet::new(),
        }
    }
}

/// Commands for modifying the namespace
#[derive(Debug, Clone)]
pub enum NamespaceCommand {
    /// Add a new definition
    AddDefinition {
        path: DefinitionPath,
        content: DefinitionContent,
        type_signature: Type,
        metadata: DefinitionMetadata,
    },

    /// Update an existing definition
    UpdateDefinition {
        path: DefinitionPath,
        content: DefinitionContent,
        type_signature: Type,
    },

    /// Move a definition to a new location
    MoveDefinition {
        from: DefinitionPath,
        to: DefinitionPath,
    },

    /// Create an alias for a definition
    CreateAlias {
        target: DefinitionPath,
        alias: DefinitionPath,
    },

    /// Delete a name (definition remains in storage)
    DeleteName { path: DefinitionPath },

    /// Rename all occurrences within a scope
    RenameInScope {
        old_name: String,
        new_name: String,
        scope: NamespacePath,
    },
}

/// The namespace store manages all namespaces and definitions
pub struct NamespaceStore {
    /// All namespaces by path
    namespaces: HashMap<NamespacePath, Namespace>,

    /// All definitions by hash
    definitions: HashMap<DefinitionHash, Arc<Definition>>,

    /// Reverse dependency graph: hash -> set of hashes that depend on it
    reverse_dependencies: HashMap<DefinitionHash, HashSet<DefinitionHash>>,

    /// Name to hash mappings for quick lookup
    name_index: HashMap<DefinitionPath, DefinitionHash>,
}

impl NamespaceStore {
    pub fn new() -> Self {
        let mut store = Self {
            namespaces: HashMap::new(),
            definitions: HashMap::new(),
            reverse_dependencies: HashMap::new(),
            name_index: HashMap::new(),
        };

        // Create root namespace
        store
            .namespaces
            .insert(NamespacePath::root(), Namespace::new(NamespacePath::root()));

        store
    }

    /// Get a namespace by path, creating it if it doesn't exist
    pub fn get_or_create_namespace(&mut self, path: &NamespacePath) -> &mut Namespace {
        // Ensure all parent namespaces exist
        let mut current = NamespacePath::root();
        for segment in &path.0 {
            let parent_path = current.clone();
            current = current.append(segment);

            // Add to parent's subnamespaces
            if let Some(parent) = self.namespaces.get_mut(&parent_path) {
                parent.subnamespaces.insert(segment.clone());
            }

            // Create namespace if it doesn't exist
            self.namespaces
                .entry(current.clone())
                .or_insert_with(|| Namespace::new(current.clone()));
        }

        self.namespaces.get_mut(path).unwrap()
    }

    /// Add a new definition
    pub fn add_definition(
        &mut self,
        path: DefinitionPath,
        content: DefinitionContent,
        type_signature: Type,
        dependencies: HashSet<DefinitionHash>,
        metadata: DefinitionMetadata,
    ) -> Result<DefinitionHash, XsError> {
        // Check if name already exists
        if self.name_index.contains_key(&path) {
            return Err(XsError::RuntimeError(
                vibe_core::Span::new(0, 0),
                format!("Definition '{}' already exists", path.to_string()),
            ));
        }

        // Compute hash for the definition
        let hash = DefinitionHash::compute(&content, &type_signature);

        // Create definition
        let definition = Arc::new(Definition {
            hash: hash.clone(),
            content,
            dependencies: dependencies.clone(),
            type_signature,
            metadata,
        });

        // Store definition
        self.definitions.insert(hash.clone(), definition);

        // Update reverse dependencies
        for dep_hash in &dependencies {
            self.reverse_dependencies
                .entry(dep_hash.clone())
                .or_default()
                .insert(hash.clone());
        }

        // Add to namespace
        let namespace = self.get_or_create_namespace(&path.namespace);
        namespace
            .definitions
            .insert(path.name.clone(), hash.clone());

        // Update name index
        self.name_index.insert(path, hash.clone());

        Ok(hash)
    }

    /// Get a definition by hash
    pub fn get_definition(&self, hash: &DefinitionHash) -> Option<&Arc<Definition>> {
        self.definitions.get(hash)
    }

    /// Get a definition by path
    pub fn get_definition_by_path(&self, path: &DefinitionPath) -> Option<&Arc<Definition>> {
        self.name_index
            .get(path)
            .and_then(|hash| self.definitions.get(hash))
    }

    /// Get all definitions that depend on a given hash
    pub fn get_dependents(&self, hash: &DefinitionHash) -> Vec<DefinitionHash> {
        self.reverse_dependencies
            .get(hash)
            .map(|deps| deps.iter().cloned().collect())
            .unwrap_or_default()
    }

    /// Execute a namespace command
    pub fn execute_command(&mut self, command: NamespaceCommand) -> Result<(), XsError> {
        match command {
            NamespaceCommand::AddDefinition {
                path,
                content,
                type_signature,
                metadata,
            } => {
                // Extract dependencies from content
                let dependencies = self.extract_dependencies(&content)?;
                self.add_definition(path, content, type_signature, dependencies, metadata)?;
            }

            NamespaceCommand::UpdateDefinition {
                path,
                content,
                type_signature,
            } => {
                // Remove old definition name
                if let Some(_old_hash) = self.name_index.remove(&path) {
                    if let Some(namespace) = self.namespaces.get_mut(&path.namespace) {
                        namespace.definitions.remove(&path.name);
                    }
                }

                // Add new definition
                let dependencies = self.extract_dependencies(&content)?;
                self.add_definition(
                    path,
                    content,
                    type_signature,
                    dependencies,
                    DefinitionMetadata::default(),
                )?;
            }

            NamespaceCommand::MoveDefinition { from, to } => {
                // Get the hash
                let hash = self.name_index.remove(&from).ok_or_else(|| {
                    XsError::RuntimeError(
                        vibe_core::Span::new(0, 0),
                        format!("Definition '{}' not found", from.to_string()),
                    )
                })?;

                // Remove from old namespace
                if let Some(namespace) = self.namespaces.get_mut(&from.namespace) {
                    namespace.definitions.remove(&from.name);
                }

                // Add to new namespace
                let namespace = self.get_or_create_namespace(&to.namespace);
                namespace.definitions.insert(to.name.clone(), hash.clone());

                // Update name index
                self.name_index.insert(to, hash);
            }

            NamespaceCommand::CreateAlias { target, alias } => {
                // Get the hash
                let hash = self
                    .name_index
                    .get(&target)
                    .ok_or_else(|| {
                        XsError::RuntimeError(
                            vibe_core::Span::new(0, 0),
                            format!("Definition '{}' not found", target.to_string()),
                        )
                    })?
                    .clone();

                // Add alias
                let namespace = self.get_or_create_namespace(&alias.namespace);
                namespace
                    .definitions
                    .insert(alias.name.clone(), hash.clone());
                self.name_index.insert(alias, hash);
            }

            NamespaceCommand::DeleteName { path } => {
                // Remove from namespace
                if let Some(namespace) = self.namespaces.get_mut(&path.namespace) {
                    namespace.definitions.remove(&path.name);
                }

                // Remove from name index
                self.name_index.remove(&path);

                // Note: The definition itself remains in self.definitions
            }

            NamespaceCommand::RenameInScope {
                old_name: _,
                new_name: _,
                scope: _,
            } => {
                // This would require updating all definitions in the scope
                // that reference old_name to use new_name instead
                // For now, this is a placeholder
                todo!("Implement rename in scope")
            }
        }

        Ok(())
    }

    /// Extract dependencies from definition content
    fn extract_dependencies(
        &self,
        content: &DefinitionContent,
    ) -> Result<HashSet<DefinitionHash>, XsError> {
        use crate::dependency_extractor::DependencyExtractor;

        match content {
            DefinitionContent::Function { body, .. } => {
                let mut extractor = DependencyExtractor::new(self, NamespacePath::root());
                Ok(extractor.extract_from_expr(body))
            }
            DefinitionContent::Value(expr) => {
                let mut extractor = DependencyExtractor::new(self, NamespacePath::root());
                Ok(extractor.extract_from_expr(expr))
            }
            DefinitionContent::Type { .. } => {
                // Type definitions don't have expression dependencies
                Ok(HashSet::new())
            }
        }
    }

    /// List all definitions in a namespace
    pub fn list_namespace(&self, path: &NamespacePath) -> Vec<(String, DefinitionHash)> {
        self.namespaces
            .get(path)
            .map(|ns| {
                ns.definitions
                    .iter()
                    .map(|(name, hash)| (name.clone(), hash.clone()))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Get all sub-namespaces of a namespace
    pub fn list_subnamespaces(&self, path: &NamespacePath) -> Vec<String> {
        self.namespaces
            .get(path)
            .map(|ns| ns.subnamespaces.iter().cloned().collect())
            .unwrap_or_default()
    }
}

impl Default for NamespaceStore {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_namespace_path() {
        let path = NamespacePath::from_str("Math.utils.fibonacci");
        assert_eq!(path.0, vec!["Math", "utils", "fibonacci"]);
        assert_eq!(path.to_string(), "Math.utils.fibonacci");

        let parent = path.parent().unwrap();
        assert_eq!(parent.0, vec!["Math", "utils"]);
    }

    #[test]
    fn test_definition_path() {
        let path = DefinitionPath::from_str("Math.utils.fibonacci").unwrap();
        assert_eq!(path.namespace.0, vec!["Math", "utils"]);
        assert_eq!(path.name, "fibonacci");
        assert_eq!(path.to_string(), "Math.utils.fibonacci");
    }

    #[test]
    fn test_add_definition() {
        let mut store = NamespaceStore::new();

        let path = DefinitionPath::from_str("Math.fibonacci").unwrap();
        let content = DefinitionContent::Value(Expr::Ident(
            vibe_core::Ident("test".to_string()),
            vibe_core::Span::new(0, 4),
        ));
        let type_sig = Type::Int;

        let hash = store
            .add_definition(
                path.clone(),
                content,
                type_sig,
                HashSet::new(),
                DefinitionMetadata::default(),
            )
            .unwrap();

        // Check that definition was added
        assert!(store.get_definition(&hash).is_some());
        assert!(store.get_definition_by_path(&path).is_some());

        // Check that namespace was created
        let math_ns = NamespacePath::from_str("Math");
        assert!(store.namespaces.contains_key(&math_ns));
    }
}
