//! Block attributes for effect permissions and reference scopes
//! 
//! Each block in the AST can have associated metadata that describes:
//! - What effects are permitted within the block
//! - What variables are in scope and their lifetimes
//! - Capture semantics for closures

use crate::{metadata::NodeId, Ident};
use serde::{Serialize, Deserialize};
use std::collections::{HashSet, HashMap};

/// Attributes associated with a block expression
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlockAttributes {
    /// Unique identifier for this block
    pub block_id: NodeId,
    
    /// Effects that are permitted within this block
    pub permitted_effects: EffectPermissions,
    
    /// Variables in scope and their attributes
    pub scope: ScopeAttributes,
    
    /// Parent block ID (if nested)
    pub parent_block: Option<NodeId>,
}

/// Effect permissions for a block
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum EffectPermissions {
    /// All effects are permitted (default)
    All,
    
    /// Only pure computation allowed
    Pure,
    
    /// Specific effects are permitted
    Only(HashSet<String>),
    
    /// All except specific effects
    Except(HashSet<String>),
    
    /// Inherited from parent block
    Inherited,
}

/// Scope attributes for variables
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScopeAttributes {
    /// Variables defined in this scope
    pub bindings: HashMap<Ident, BindingAttributes>,
    
    /// Variables captured from outer scopes
    pub captures: HashSet<Ident>,
    
    /// Whether this scope allows shadowing
    pub allows_shadowing: bool,
}

/// Attributes for a single binding
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BindingAttributes {
    /// Whether the binding is mutable (for future extensions)
    pub mutable: bool,
    
    /// Whether the binding escapes this scope
    pub escapes: bool,
    
    /// Effects produced by the binding's initializer
    pub init_effects: HashSet<String>,
    
    /// Reference count information for Perceus
    pub ref_count: Option<usize>,
}

impl Default for BlockAttributes {
    fn default() -> Self {
        Self {
            block_id: NodeId::fresh(),
            permitted_effects: EffectPermissions::Inherited,
            scope: ScopeAttributes::default(),
            parent_block: None,
        }
    }
}

impl Default for ScopeAttributes {
    fn default() -> Self {
        Self {
            bindings: HashMap::new(),
            captures: HashSet::new(),
            allows_shadowing: true,
        }
    }
}

/// Block attribute registry that persists with the codebase
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockAttributeRegistry {
    /// Map from block ID to its attributes
    attributes: HashMap<NodeId, BlockAttributes>,
}

impl BlockAttributeRegistry {
    pub fn new() -> Self {
        Self {
            attributes: HashMap::new(),
        }
    }
    
    /// Register attributes for a block
    pub fn register(&mut self, attrs: BlockAttributes) {
        self.attributes.insert(attrs.block_id.clone(), attrs);
    }
    
    /// Get attributes for a block
    pub fn get(&self, block_id: &NodeId) -> Option<&BlockAttributes> {
        self.attributes.get(block_id)
    }
    
    /// Update attributes for a block
    pub fn update(&mut self, block_id: &NodeId, f: impl FnOnce(&mut BlockAttributes)) {
        if let Some(attrs) = self.attributes.get_mut(block_id) {
            f(attrs);
        }
    }
    
    /// Get the number of blocks in the registry
    pub fn len(&self) -> usize {
        self.attributes.len()
    }
    
    /// Check if the registry is empty
    pub fn is_empty(&self) -> bool {
        self.attributes.is_empty()
    }
}