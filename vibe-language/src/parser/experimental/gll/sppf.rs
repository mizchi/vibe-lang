use std::collections::HashMap;
use std::fmt::Debug;

/// Type of SPPF node
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SPPFNodeType {
    /// Terminal symbol
    Terminal(String),
    /// Non-terminal symbol
    NonTerminal(String),
    /// Intermediate node (for binarization)
    Intermediate { slot: usize },
    /// Packed node (for ambiguity)
    Packed { slot: usize },
    /// Epsilon (empty)
    Epsilon,
}

/// Node in the Shared Packed Parse Forest
#[derive(Debug, Clone)]
pub struct SPPFNode {
    /// Unique identifier
    pub id: usize,
    /// Type of node
    pub node_type: SPPFNodeType,
    /// Start position in input
    pub start: usize,
    /// End position in input
    pub end: usize,
    /// Children nodes (for packed nodes, these are alternatives)
    pub children: Vec<Vec<usize>>,
}

/// Shared Packed Parse Forest for representing all parse trees
pub struct SharedPackedParseForest {
    /// All nodes in the SPPF
    nodes: Vec<SPPFNode>,
    /// Node cache for deduplication: (type, start, end) -> node_id
    node_cache: HashMap<(String, usize, usize), usize>,
    /// Root nodes (successful parses)
    roots: Vec<usize>,
    /// Node counter
    next_id: usize,
}

impl SharedPackedParseForest {
    pub fn new() -> Self {
        Self {
            nodes: Vec::new(),
            node_cache: HashMap::new(),
            roots: Vec::new(),
            next_id: 0,
        }
    }

    /// Create or find a terminal node
    pub fn create_terminal(&mut self, symbol: String, start: usize, end: usize) -> usize {
        let cache_key = (format!("T:{}", symbol), start, end);
        
        if let Some(&node_id) = self.node_cache.get(&cache_key) {
            return node_id;
        }
        
        let node = SPPFNode {
            id: self.next_id,
            node_type: SPPFNodeType::Terminal(symbol.clone()),
            start,
            end,
            children: vec![],
        };
        
        let node_id = self.next_id;
        self.nodes.push(node);
        self.node_cache.insert(cache_key, node_id);
        self.next_id += 1;
        
        node_id
    }

    /// Create or find a non-terminal node
    pub fn create_nonterminal(&mut self, symbol: String, start: usize, end: usize) -> usize {
        let cache_key = (format!("N:{}", symbol), start, end);
        
        if let Some(&node_id) = self.node_cache.get(&cache_key) {
            return node_id;
        }
        
        let node = SPPFNode {
            id: self.next_id,
            node_type: SPPFNodeType::NonTerminal(symbol.clone()),
            start,
            end,
            children: vec![],
        };
        
        let node_id = self.next_id;
        self.nodes.push(node);
        self.node_cache.insert(cache_key, node_id);
        self.next_id += 1;
        
        node_id
    }

    /// Create or find an intermediate node
    pub fn create_intermediate(&mut self, slot: usize, start: usize, end: usize) -> usize {
        let cache_key = (format!("I:{}", slot), start, end);
        
        if let Some(&node_id) = self.node_cache.get(&cache_key) {
            return node_id;
        }
        
        let node = SPPFNode {
            id: self.next_id,
            node_type: SPPFNodeType::Intermediate { slot },
            start,
            end,
            children: vec![],
        };
        
        let node_id = self.next_id;
        self.nodes.push(node);
        self.node_cache.insert(cache_key, node_id);
        self.next_id += 1;
        
        node_id
    }

    /// Create an epsilon node
    pub fn create_epsilon(&mut self, position: usize) -> usize {
        let node = SPPFNode {
            id: self.next_id,
            node_type: SPPFNodeType::Epsilon,
            start: position,
            end: position,
            children: vec![],
        };
        
        let node_id = self.next_id;
        self.nodes.push(node);
        self.next_id += 1;
        
        node_id
    }

    /// Add children to a node (creates ambiguity if children already exist)
    pub fn add_children(&mut self, parent_id: usize, children: Vec<usize>) {
        if let Some(parent) = self.nodes.get_mut(parent_id) {
            // Check if these children already exist
            if !parent.children.contains(&children) {
                parent.children.push(children);
            }
        }
    }

    /// Add a root node
    pub fn add_root(&mut self, node_id: usize) {
        if !self.roots.contains(&node_id) {
            self.roots.push(node_id);
        }
    }

    /// Get node by ID
    pub fn get_node(&self, node_id: usize) -> Option<&SPPFNode> {
        self.nodes.get(node_id)
    }

    /// Get all root nodes
    pub fn get_roots(&self) -> &[usize] {
        &self.roots
    }

    /// Check if the forest is ambiguous
    pub fn is_ambiguous(&self) -> bool {
        self.nodes.iter().any(|node| node.children.len() > 1)
    }

    /// Count the number of parse trees
    pub fn count_trees(&self) -> usize {
        let mut memo = HashMap::new();
        self.roots.iter()
            .map(|&root| self.count_trees_recursive(root, &mut memo))
            .sum()
    }

    fn count_trees_recursive(&self, node_id: usize, memo: &mut HashMap<usize, usize>) -> usize {
        if let Some(&count) = memo.get(&node_id) {
            return count;
        }
        
        let count = if let Some(node) = self.get_node(node_id) {
            if node.children.is_empty() {
                1
            } else {
                node.children.iter()
                    .map(|children| {
                        children.iter()
                            .map(|&child| self.count_trees_recursive(child, memo))
                            .product::<usize>()
                    })
                    .sum()
            }
        } else {
            0
        };
        
        memo.insert(node_id, count);
        count
    }

    /// Extract all parse trees (warning: can be exponential!)
    pub fn extract_trees(&self, max_trees: usize) -> Vec<ParseTree> {
        let mut trees = Vec::new();
        
        for &root in &self.roots {
            self.extract_trees_recursive(root, &mut trees, max_trees);
            if trees.len() >= max_trees {
                break;
            }
        }
        
        trees
    }

    fn extract_trees_recursive(&self, node_id: usize, trees: &mut Vec<ParseTree>, max_trees: usize) {
        if trees.len() >= max_trees {
            return;
        }
        
        if let Some(_node) = self.get_node(node_id) {
            let tree = self.build_parse_tree(node_id);
            trees.push(tree);
        }
    }

    fn build_parse_tree(&self, node_id: usize) -> ParseTree {
        if let Some(node) = self.get_node(node_id) {
            let children = if node.children.is_empty() {
                vec![]
            } else {
                // For simplicity, take the first alternative
                node.children[0].iter()
                    .map(|&child| self.build_parse_tree(child))
                    .collect()
            };
            
            ParseTree {
                node_type: format!("{:?}", node.node_type),
                start: node.start,
                end: node.end,
                children,
            }
        } else {
            ParseTree {
                node_type: "Error".to_string(),
                start: 0,
                end: 0,
                children: vec![],
            }
        }
    }

    /// Clear the forest
    pub fn clear(&mut self) {
        self.nodes.clear();
        self.node_cache.clear();
        self.roots.clear();
        self.next_id = 0;
    }

    /// Get statistics about the forest
    pub fn stats(&self) -> SPPFStats {
        let ambiguous_nodes = self.nodes.iter()
            .filter(|n| n.children.len() > 1)
            .count();
        
        SPPFStats {
            total_nodes: self.nodes.len(),
            ambiguous_nodes,
            total_roots: self.roots.len(),
            is_ambiguous: self.is_ambiguous(),
        }
    }
}

/// Simple parse tree representation
#[derive(Debug, Clone)]
pub struct ParseTree {
    pub node_type: String,
    pub start: usize,
    pub end: usize,
    pub children: Vec<ParseTree>,
}

/// Statistics about the SPPF
#[derive(Debug, Clone)]
pub struct SPPFStats {
    pub total_nodes: usize,
    pub ambiguous_nodes: usize,
    pub total_roots: usize,
    pub is_ambiguous: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sppf_terminal() {
        let mut sppf = SharedPackedParseForest::new();
        
        let node1 = sppf.create_terminal("a".to_string(), 0, 1);
        let node2 = sppf.create_terminal("a".to_string(), 0, 1);
        
        assert_eq!(node1, node2); // Should be deduplicated
        assert_eq!(sppf.nodes.len(), 1);
    }

    #[test]
    fn test_sppf_nonterminal() {
        let mut sppf = SharedPackedParseForest::new();
        
        let term = sppf.create_terminal("x".to_string(), 0, 1);
        let nonterm = sppf.create_nonterminal("Expr".to_string(), 0, 1);
        
        sppf.add_children(nonterm, vec![term]);
        
        assert_eq!(sppf.nodes.len(), 2);
        assert!(!sppf.is_ambiguous());
    }

    #[test]
    fn test_sppf_ambiguity() {
        let mut sppf = SharedPackedParseForest::new();
        
        let term1 = sppf.create_terminal("a".to_string(), 0, 1);
        let term2 = sppf.create_terminal("b".to_string(), 1, 2);
        let nonterm = sppf.create_nonterminal("S".to_string(), 0, 2);
        
        // Add two different derivations
        sppf.add_children(nonterm, vec![term1]);
        sppf.add_children(nonterm, vec![term2]);
        
        // Add as root to enable tree counting
        sppf.add_root(nonterm);
        
        assert!(sppf.is_ambiguous());
        assert_eq!(sppf.count_trees(), 2);
    }

    #[test]
    fn test_sppf_stats() {
        let mut sppf = SharedPackedParseForest::new();
        
        let term = sppf.create_terminal("x".to_string(), 0, 1);
        let nonterm = sppf.create_nonterminal("E".to_string(), 0, 1);
        sppf.add_children(nonterm, vec![term]);
        sppf.add_root(nonterm);
        
        let stats = sppf.stats();
        assert_eq!(stats.total_nodes, 2);
        assert_eq!(stats.ambiguous_nodes, 0);
        assert_eq!(stats.total_roots, 1);
        assert!(!stats.is_ambiguous);
    }
}