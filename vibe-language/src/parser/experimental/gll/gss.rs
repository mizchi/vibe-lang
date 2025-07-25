use std::collections::{HashMap, HashSet};
use std::hash::Hash;
use std::fmt::Debug;

/// Node in the Graph Structured Stack
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct GSSNode {
    /// Grammar slot (position in grammar rule)
    pub slot: usize,
    /// Input position
    pub position: usize,
    /// Unique identifier for this node
    pub id: usize,
}

/// Edge in the Graph Structured Stack
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GSSEdge {
    /// Source node
    pub from: usize,
    /// Target node
    pub to: usize,
    /// SPPF node associated with this edge
    pub sppf_node: Option<usize>,
}

/// Graph Structured Stack for GLL parsing
pub struct GraphStructuredStack {
    /// All nodes in the GSS
    pub nodes: Vec<GSSNode>,
    /// Node ID to index mapping
    pub node_map: HashMap<(usize, usize), usize>, // (slot, position) -> node_id
    /// Edges between nodes
    pub edges: Vec<GSSEdge>,
    /// Adjacency list for efficient traversal
    pub adjacency: HashMap<usize, Vec<usize>>,
    /// Current top nodes (frontier)
    pub tops: HashSet<usize>,
    /// Node counter for unique IDs
    pub next_id: usize,
}

impl GraphStructuredStack {
    pub fn new() -> Self {
        Self {
            nodes: Vec::new(),
            node_map: HashMap::new(),
            edges: Vec::new(),
            adjacency: HashMap::new(),
            tops: HashSet::new(),
            next_id: 0,
        }
    }

    /// Create or find a GSS node
    pub fn create_node(&mut self, slot: usize, position: usize) -> usize {
        let key = (slot, position);
        
        if let Some(&node_id) = self.node_map.get(&key) {
            return node_id;
        }
        
        let node = GSSNode {
            slot,
            position,
            id: self.next_id,
        };
        
        let node_id = self.next_id;
        self.nodes.push(node);
        self.node_map.insert(key, node_id);
        self.adjacency.insert(node_id, Vec::new());
        self.next_id += 1;
        
        node_id
    }

    /// Add an edge between two nodes
    pub fn add_edge(&mut self, from: usize, to: usize, sppf_node: Option<usize>) {
        // Check if edge already exists
        if let Some(targets) = self.adjacency.get(&from) {
            if targets.contains(&to) {
                return;
            }
        }
        
        let edge = GSSEdge {
            from,
            to,
            sppf_node,
        };
        
        self.edges.push(edge);
        self.adjacency.entry(from).or_default().push(to);
    }

    /// Push a new node onto the stack
    pub fn push(&mut self, slot: usize, position: usize, parent: Option<usize>) -> usize {
        let node_id = self.create_node(slot, position);
        
        if let Some(parent_id) = parent {
            self.add_edge(parent_id, node_id, None);
        }
        
        self.tops.insert(node_id);
        node_id
    }

    /// Pop from a specific node
    pub fn pop(&mut self, node_id: usize) {
        self.tops.remove(&node_id);
    }

    /// Get all nodes at the top of the stack
    pub fn get_tops(&self) -> Vec<usize> {
        self.tops.iter().copied().collect()
    }

    /// Get children of a node
    pub fn get_children(&self, node_id: usize) -> Vec<usize> {
        self.adjacency
            .get(&node_id)
            .map(|v| v.clone())
            .unwrap_or_default()
    }
    
    /// Get parents of a node (nodes that have edges to this node)
    pub fn get_parents(&self, node_id: usize) -> Vec<usize> {
        let mut parents = Vec::new();
        for edge in &self.edges {
            if edge.to == node_id {
                parents.push(edge.from);
            }
        }
        parents
    }

    /// Get the node by ID
    pub fn get_node(&self, node_id: usize) -> Option<&GSSNode> {
        self.nodes.get(node_id)
    }

    /// Check if a node exists
    pub fn has_node(&self, slot: usize, position: usize) -> bool {
        self.node_map.contains_key(&(slot, position))
    }

    /// Get node ID by slot and position
    pub fn get_node_id(&self, slot: usize, position: usize) -> Option<usize> {
        self.node_map.get(&(slot, position)).copied()
    }

    /// Clear the GSS
    pub fn clear(&mut self) {
        self.nodes.clear();
        self.node_map.clear();
        self.edges.clear();
        self.adjacency.clear();
        self.tops.clear();
        self.next_id = 0;
    }

    /// Get the number of nodes
    pub fn node_count(&self) -> usize {
        self.nodes.len()
    }

    /// Get the number of edges
    pub fn edge_count(&self) -> usize {
        self.edges.len()
    }

    /// Debug print the GSS structure
    pub fn debug_print(&self) {
        println!("GSS Nodes:");
        for node in &self.nodes {
            println!("  Node {}: slot={}, pos={}", node.id, node.slot, node.position);
        }
        
        println!("GSS Edges:");
        for edge in &self.edges {
            println!("  Edge: {} -> {} (sppf: {:?})", edge.from, edge.to, edge.sppf_node);
        }
        
        println!("Top nodes: {:?}", self.tops);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_gss_creation() {
        let mut gss = GraphStructuredStack::new();
        
        let node1 = gss.create_node(0, 0);
        let node2 = gss.create_node(1, 1);
        
        assert_eq!(gss.node_count(), 2);
        assert_eq!(node1, 0);
        assert_eq!(node2, 1);
    }

    #[test]
    fn test_gss_duplicate_nodes() {
        let mut gss = GraphStructuredStack::new();
        
        let node1 = gss.create_node(0, 0);
        let node2 = gss.create_node(0, 0); // Same slot and position
        
        assert_eq!(node1, node2); // Should return the same node
        assert_eq!(gss.node_count(), 1);
    }

    #[test]
    fn test_gss_edges() {
        let mut gss = GraphStructuredStack::new();
        
        let node1 = gss.create_node(0, 0);
        let node2 = gss.create_node(1, 1);
        
        gss.add_edge(node1, node2, Some(42));
        
        assert_eq!(gss.edge_count(), 1);
        assert_eq!(gss.get_children(node1), vec![node2]);
    }

    #[test]
    fn test_gss_push_pop() {
        let mut gss = GraphStructuredStack::new();
        
        let node1 = gss.push(0, 0, None);
        let node2 = gss.push(1, 1, Some(node1));
        
        assert_eq!(gss.get_tops().len(), 2);
        
        gss.pop(node1);
        assert_eq!(gss.get_tops(), vec![node2]);
    }
}