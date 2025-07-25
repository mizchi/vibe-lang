//! Integration of block attributes with the codebase
//!
//! This module handles the persistence and retrieval of block attributes
//! as part of the content-addressed codebase.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use vibe_language::block_attributes::{BlockAttributeRegistry, BlockAttributes};
use vibe_language::metadata::NodeId;

/// Block registry that integrates with the codebase
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodebaseBlockRegistry {
    /// Map from expression hash to its block attributes
    expr_attributes: HashMap<String, BlockAttributeRegistry>,

    /// Map from block ID to expression hash (for reverse lookup)
    block_to_expr: HashMap<NodeId, String>,
}

impl CodebaseBlockRegistry {
    pub fn new() -> Self {
        Self {
            expr_attributes: HashMap::new(),
            block_to_expr: HashMap::new(),
        }
    }

    /// Store block attributes for an expression
    pub fn store_attributes(&mut self, expr_hash: String, registry: BlockAttributeRegistry) {
        // Store the registry
        self.expr_attributes
            .insert(expr_hash.clone(), registry.clone());

        // Update reverse mapping
        // Note: In a real implementation, we'd walk the registry to extract all block IDs
    }

    /// Retrieve block attributes for an expression
    pub fn get_attributes(&self, expr_hash: &str) -> Option<&BlockAttributeRegistry> {
        self.expr_attributes.get(expr_hash)
    }

    /// Get attributes for a specific block
    pub fn get_block_attributes(&self, block_id: &NodeId) -> Option<&BlockAttributes> {
        // First find which expression this block belongs to
        if let Some(expr_hash) = self.block_to_expr.get(block_id) {
            if let Some(registry) = self.expr_attributes.get(expr_hash) {
                return registry.get(block_id);
            }
        }
        None
    }

    /// Compute hash for block attributes (for change detection)
    pub fn hash_attributes(registry: &BlockAttributeRegistry) -> String {
        let mut hasher = Sha256::new();
        let serialized = bincode::serialize(registry).unwrap_or_default();
        hasher.update(&serialized);
        format!("{:x}", hasher.finalize())
    }
}

/// Extension trait for integrating semantic analysis with the codebase
pub trait CodebaseWithBlockAttributes {
    /// Analyze and store block attributes for an expression
    fn analyze_and_store(
        &mut self,
        expr_hash: String,
        expr: &vibe_language::Expr,
    ) -> Result<(), String>;

    /// Get block attributes for an expression
    fn get_block_attributes(&self, expr_hash: &str) -> Option<&BlockAttributeRegistry>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use vibe_language::block_attributes::EffectPermissions;

    #[test]
    fn test_block_registry_storage() {
        let mut registry = CodebaseBlockRegistry::new();
        let mut attrs = BlockAttributeRegistry::new();

        // Create some test attributes
        let block_attrs = BlockAttributes {
            block_id: NodeId::fresh(),
            permitted_effects: EffectPermissions::Pure,
            scope: Default::default(),
            parent_block: None,
        };

        attrs.register(block_attrs);

        // Store and retrieve
        let expr_hash = "test_hash_12345".to_string();
        registry.store_attributes(expr_hash.clone(), attrs);

        assert!(registry.get_attributes(&expr_hash).is_some());
    }
}
