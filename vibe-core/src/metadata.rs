//! AST metadata management for comments, temporary variable labels, and other annotations
//! that are semantically separate from the AST structure itself.

use crate::{Expr, Span};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Unique identifier for AST nodes
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct NodeId(pub usize);

impl Default for NodeId {
    fn default() -> Self {
        Self::new()
    }
}

impl NodeId {
    pub fn new() -> Self {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        NodeId(COUNTER.fetch_add(1, Ordering::SeqCst))
    }
    
    pub fn fresh() -> Self {
        Self::new()
    }
}

/// Type of metadata that can be attached to AST nodes
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum MetadataKind {
    /// Comment attached to a node
    Comment(String),
    /// Temporary variable label for stack management
    TempVarLabel(String),
    /// Source location information
    SourceLocation {
        file: String,
        line: usize,
        column: usize,
    },
    /// Type annotation (separate from inferred type)
    TypeAnnotation(String),
    /// Documentation string
    DocString(String),
    /// Custom metadata with key-value pairs
    Custom(HashMap<String, String>),
}

/// Metadata entry for a specific AST node
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MetadataEntry {
    pub node_id: NodeId,
    pub kind: MetadataKind,
    pub span: Option<Span>,
}

/// Metadata store that maps AST nodes to their metadata
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MetadataStore {
    /// Map from node ID to list of metadata entries
    entries: HashMap<NodeId, Vec<MetadataEntry>>,
    /// Map from expression pointer to node ID (for runtime association)
    expr_to_node: HashMap<usize, NodeId>,
}

impl MetadataStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register an expression with a node ID
    pub fn register_expr(&mut self, expr: &Expr, node_id: NodeId) {
        let ptr = expr as *const Expr as usize;
        self.expr_to_node.insert(ptr, node_id);
    }

    /// Get node ID for an expression
    pub fn get_node_id(&self, expr: &Expr) -> Option<&NodeId> {
        let ptr = expr as *const Expr as usize;
        self.expr_to_node.get(&ptr)
    }

    /// Add metadata to a node
    pub fn add_metadata(&mut self, node_id: NodeId, kind: MetadataKind, span: Option<Span>) {
        let entry = MetadataEntry {
            node_id: node_id.clone(),
            kind,
            span,
        };
        self.entries.entry(node_id).or_default().push(entry);
    }

    /// Get all metadata for a node
    pub fn get_metadata(&self, node_id: &NodeId) -> Option<&Vec<MetadataEntry>> {
        self.entries.get(node_id)
    }

    /// Get metadata of a specific kind for a node
    pub fn get_metadata_by_kind(
        &self,
        node_id: &NodeId,
        filter: impl Fn(&MetadataKind) -> bool,
    ) -> Vec<&MetadataEntry> {
        self.entries
            .get(node_id)
            .map(|entries| entries.iter().filter(|e| filter(&e.kind)).collect())
            .unwrap_or_default()
    }

    /// Get comments for a node
    pub fn get_comments(&self, node_id: &NodeId) -> Vec<&str> {
        self.get_metadata_by_kind(node_id, |k| matches!(k, MetadataKind::Comment(_)))
            .into_iter()
            .filter_map(|e| match &e.kind {
                MetadataKind::Comment(s) => Some(s.as_str()),
                _ => None,
            })
            .collect()
    }

    /// Get temp var label for a node
    pub fn get_temp_var_label(&self, node_id: &NodeId) -> Option<&str> {
        self.get_metadata_by_kind(node_id, |k| matches!(k, MetadataKind::TempVarLabel(_)))
            .into_iter()
            .find_map(|e| match &e.kind {
                MetadataKind::TempVarLabel(s) => Some(s.as_str()),
                _ => None,
            })
    }

    /// Merge metadata from another store
    pub fn merge(&mut self, other: MetadataStore) {
        for (node_id, entries) in other.entries {
            self.entries.entry(node_id).or_default().extend(entries);
        }
        self.expr_to_node.extend(other.expr_to_node);
    }

    /// Clear all metadata
    pub fn clear(&mut self) {
        self.entries.clear();
        self.expr_to_node.clear();
    }
}

/// Trait for AST nodes that can have metadata attached
pub trait HasMetadata {
    fn node_id(&self) -> &NodeId;
    fn with_metadata(self, store: &mut MetadataStore) -> Self;
}

/// Builder for constructing AST nodes with metadata
pub struct AstBuilder {
    metadata_store: MetadataStore,
}

impl Default for AstBuilder {
    fn default() -> Self {
        Self::new()
    }
}

impl AstBuilder {
    pub fn new() -> Self {
        Self {
            metadata_store: MetadataStore::new(),
        }
    }

    pub fn with_comment(&mut self, node_id: NodeId, comment: String, span: Option<Span>) {
        self.metadata_store
            .add_metadata(node_id, MetadataKind::Comment(comment), span);
    }

    pub fn with_temp_var(&mut self, node_id: NodeId, label: String, span: Option<Span>) {
        self.metadata_store
            .add_metadata(node_id, MetadataKind::TempVarLabel(label), span);
    }

    pub fn with_doc_string(&mut self, node_id: NodeId, doc: String, span: Option<Span>) {
        self.metadata_store
            .add_metadata(node_id, MetadataKind::DocString(doc), span);
    }

    pub fn finish(self) -> MetadataStore {
        self.metadata_store
    }
}

/// Code formatter that considers metadata when expanding code
pub struct MetadataAwareFormatter<'a> {
    metadata_store: &'a MetadataStore,
}

impl<'a> MetadataAwareFormatter<'a> {
    pub fn new(metadata_store: &'a MetadataStore) -> Self {
        Self { metadata_store }
    }

    pub fn format_expr(&self, expr: &Expr, node_id: &NodeId) -> String {
        let mut result = String::new();

        // Add leading comments
        if let Some(metadata) = self.metadata_store.get_metadata(node_id) {
            for entry in metadata {
                match &entry.kind {
                    MetadataKind::Comment(comment) => {
                        result.push_str(&format!("; {comment}\n"));
                    }
                    MetadataKind::DocString(doc) => {
                        result.push_str(&format!(";; {doc}\n"));
                    }
                    _ => {}
                }
            }
        }

        // Format the expression itself
        result.push_str(&self.format_expr_inner(expr, node_id));

        // Add trailing temp var label if present
        if let Some(label) = self.metadata_store.get_temp_var_label(node_id) {
            result.push_str(&format!(" ; => {label}"));
        }

        result
    }

    fn format_expr_inner(&self, expr: &Expr, _node_id: &NodeId) -> String {
        // TODO: Implement full expression formatting
        // This is a placeholder that should be replaced with proper formatting logic
        format!("{expr:?}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_metadata_store() {
        let mut store = MetadataStore::new();
        let node_id = NodeId::new();

        // Add various metadata
        store.add_metadata(
            node_id.clone(),
            MetadataKind::Comment("This is a comment".to_string()),
            None,
        );
        store.add_metadata(
            node_id.clone(),
            MetadataKind::TempVarLabel("temp1".to_string()),
            None,
        );
        store.add_metadata(
            node_id.clone(),
            MetadataKind::DocString("Function documentation".to_string()),
            None,
        );

        // Check retrieval
        let comments = store.get_comments(&node_id);
        assert_eq!(comments, vec!["This is a comment"]);

        let temp_label = store.get_temp_var_label(&node_id);
        assert_eq!(temp_label, Some("temp1"));

        let metadata = store.get_metadata(&node_id).unwrap();
        assert_eq!(metadata.len(), 3);
    }

    #[test]
    fn test_ast_builder() {
        let mut builder = AstBuilder::new();
        let node_id = NodeId::new();

        builder.with_comment(node_id.clone(), "Helper function".to_string(), None);
        builder.with_temp_var(node_id.clone(), "x_temp".to_string(), None);
        builder.with_doc_string(node_id.clone(), "Calculates the sum".to_string(), None);

        let store = builder.finish();
        assert_eq!(store.get_comments(&node_id).len(), 1);
        assert_eq!(store.get_temp_var_label(&node_id), Some("x_temp"));
    }
}
