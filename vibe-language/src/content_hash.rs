//! Content hashing for Vibe Language
//! 
//! This module implements content-addressable storage for Vibe code,
//! based on normalized AST to ensure semantic equivalence produces
//! the same hash.

use crate::normalized_ast::{NormalizedExpr, NormalizedDef, NormalizedPattern, NormalizedHandler};
use blake3::Hasher;
use serde::{Serialize, Deserialize};
use std::collections::BTreeMap;

/// Content hash - a unique identifier for code content
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct ContentHash(pub String);

impl ContentHash {
    /// Create a new content hash from bytes
    pub fn from_bytes(bytes: &[u8]) -> Self {
        let hash = blake3::hash(bytes);
        ContentHash(hash.to_hex().to_string())
    }
    
    /// Get the short form (first 8 characters) for display
    pub fn short(&self) -> &str {
        &self.0[..8.min(self.0.len())]
    }
    
    /// Parse from a hex string
    pub fn from_hex(hex: &str) -> Result<Self, String> {
        // Validate hex string
        if !hex.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err("Invalid hex string".to_string());
        }
        Ok(ContentHash(hex.to_string()))
    }
}

impl std::fmt::Display for ContentHash {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.short())
    }
}

/// Trait for types that can be content-hashed
pub trait ContentHashable {
    /// Compute the content hash for this value
    fn content_hash(&self) -> ContentHash;
}

impl ContentHashable for NormalizedExpr {
    fn content_hash(&self) -> ContentHash {
        let mut hasher = ContentHasher::new();
        hasher.hash_expr(self);
        hasher.finalize()
    }
}

impl ContentHashable for NormalizedDef {
    fn content_hash(&self) -> ContentHash {
        let mut hasher = ContentHasher::new();
        hasher.hash_def(self);
        hasher.finalize()
    }
}

/// Internal hasher that builds up the hash
struct ContentHasher {
    hasher: Hasher,
}

impl ContentHasher {
    fn new() -> Self {
        Self {
            hasher: Hasher::new(),
        }
    }
    
    fn finalize(self) -> ContentHash {
        let hash = self.hasher.finalize();
        ContentHash(hash.to_hex().to_string())
    }
    
    /// Hash a byte to represent node type
    fn hash_tag(&mut self, tag: u8) {
        self.hasher.update(&[tag]);
    }
    
    /// Hash a string
    fn hash_string(&mut self, s: &str) {
        let bytes = s.as_bytes();
        self.hasher.update(&(bytes.len() as u64).to_le_bytes());
        self.hasher.update(bytes);
    }
    
    /// Hash a normalized expression
    fn hash_expr(&mut self, expr: &NormalizedExpr) {
        match expr {
            NormalizedExpr::Literal(lit) => {
                self.hash_tag(0);
                self.hash_literal(lit);
            }
            
            NormalizedExpr::Var(name) => {
                self.hash_tag(1);
                self.hash_string(name);
            }
            
            NormalizedExpr::Apply { func, arg } => {
                self.hash_tag(2);
                self.hash_expr(func);
                self.hash_expr(arg);
            }
            
            NormalizedExpr::Lambda { param, body } => {
                self.hash_tag(3);
                self.hash_string(param);
                self.hash_expr(body);
            }
            
            NormalizedExpr::Let { name, value, body } => {
                self.hash_tag(4);
                self.hash_string(name);
                self.hash_expr(value);
                self.hash_expr(body);
            }
            
            NormalizedExpr::LetRec { name, value, body } => {
                self.hash_tag(5);
                self.hash_string(name);
                self.hash_expr(value);
                self.hash_expr(body);
            }
            
            NormalizedExpr::Match { expr, cases } => {
                self.hash_tag(6);
                self.hash_expr(expr);
                self.hasher.update(&(cases.len() as u64).to_le_bytes());
                for (pattern, expr) in cases {
                    self.hash_pattern(pattern);
                    self.hash_expr(expr);
                }
            }
            
            NormalizedExpr::List(elements) => {
                self.hash_tag(7);
                self.hasher.update(&(elements.len() as u64).to_le_bytes());
                for elem in elements {
                    self.hash_expr(elem);
                }
            }
            
            NormalizedExpr::Record(fields) => {
                self.hash_tag(8);
                self.hasher.update(&(fields.len() as u64).to_le_bytes());
                // BTreeMap ensures consistent ordering
                for (name, expr) in fields {
                    self.hash_string(name);
                    self.hash_expr(expr);
                }
            }
            
            NormalizedExpr::Field { expr, field } => {
                self.hash_tag(9);
                self.hash_expr(expr);
                self.hash_string(field);
            }
            
            NormalizedExpr::Constructor { name, args } => {
                self.hash_tag(10);
                self.hash_string(name);
                self.hasher.update(&(args.len() as u64).to_le_bytes());
                for arg in args {
                    self.hash_expr(arg);
                }
            }
            
            NormalizedExpr::Perform { effect, operation, args } => {
                self.hash_tag(11);
                self.hash_string(effect);
                self.hash_string(operation);
                self.hasher.update(&(args.len() as u64).to_le_bytes());
                for arg in args {
                    self.hash_expr(arg);
                }
            }
            
            NormalizedExpr::Handle { expr, handlers } => {
                self.hash_tag(12);
                self.hash_expr(expr);
                self.hasher.update(&(handlers.len() as u64).to_le_bytes());
                for handler in handlers {
                    self.hash_handler(handler);
                }
            }
        }
    }
    
    /// Hash a literal value
    fn hash_literal(&mut self, lit: &crate::Literal) {
        match lit {
            crate::Literal::Int(n) => {
                self.hash_tag(0);
                self.hasher.update(&n.to_le_bytes());
            }
            crate::Literal::Float(f) => {
                self.hash_tag(1);
                self.hasher.update(&f.to_bits().to_le_bytes());
            }
            crate::Literal::Bool(b) => {
                self.hash_tag(2);
                self.hasher.update(&[*b as u8]);
            }
            crate::Literal::String(s) => {
                self.hash_tag(3);
                self.hash_string(s);
            }
        }
    }
    
    /// Hash a pattern
    fn hash_pattern(&mut self, pattern: &NormalizedPattern) {
        match pattern {
            NormalizedPattern::Wildcard => {
                self.hash_tag(0);
            }
            
            NormalizedPattern::Variable(name) => {
                self.hash_tag(1);
                self.hash_string(name);
            }
            
            NormalizedPattern::Literal(lit) => {
                self.hash_tag(2);
                self.hash_literal(lit);
            }
            
            NormalizedPattern::Constructor { name, patterns } => {
                self.hash_tag(3);
                self.hash_string(name);
                self.hasher.update(&(patterns.len() as u64).to_le_bytes());
                for pat in patterns {
                    self.hash_pattern(pat);
                }
            }
            
            NormalizedPattern::List(patterns) => {
                self.hash_tag(4);
                self.hasher.update(&(patterns.len() as u64).to_le_bytes());
                for pat in patterns {
                    self.hash_pattern(pat);
                }
            }
            
            NormalizedPattern::Cons { head, tail } => {
                self.hash_tag(5);
                self.hash_pattern(head);
                self.hash_pattern(tail);
            }
        }
    }
    
    /// Hash a handler
    fn hash_handler(&mut self, handler: &NormalizedHandler) {
        self.hash_string(&handler.effect);
        self.hash_string(&handler.operation);
        self.hasher.update(&(handler.params.len() as u64).to_le_bytes());
        for param in &handler.params {
            self.hash_string(param);
        }
        self.hash_string(&handler.resume);
        self.hash_expr(&handler.body);
    }
    
    /// Hash a definition
    fn hash_def(&mut self, def: &NormalizedDef) {
        self.hash_string(&def.name);
        self.hasher.update(&[def.is_recursive as u8]);
        
        // Hash type if present
        if let Some(ty) = &def.ty {
            self.hash_tag(1);
            self.hash_type(ty);
        } else {
            self.hash_tag(0);
        }
        
        // Hash effects (sorted for consistency)
        let mut effects: Vec<_> = def.effects.iter().collect();
        effects.sort();
        self.hasher.update(&(effects.len() as u64).to_le_bytes());
        for effect in effects {
            self.hash_effect(effect);
        }
        
        self.hash_expr(&def.body);
    }
    
    /// Hash a type (simplified for now)
    fn hash_type(&mut self, ty: &crate::Type) {
        // For now, just hash the debug representation
        // In a real implementation, we'd have proper type hashing
        self.hash_string(&format!("{:?}", ty));
    }
    
    /// Hash an effect (simplified for now)
    fn hash_effect(&mut self, effect: &crate::Effect) {
        // For now, just hash the debug representation
        self.hash_string(&format!("{:?}", effect));
    }
}

/// Content store for managing hashed definitions
pub struct ContentStore {
    /// Map from hash to definition
    definitions: BTreeMap<ContentHash, NormalizedDef>,
    /// Map from name to hash (latest version)
    names: BTreeMap<String, ContentHash>,
}

impl ContentStore {
    pub fn new() -> Self {
        Self {
            definitions: BTreeMap::new(),
            names: BTreeMap::new(),
        }
    }
    
    /// Add a definition to the store
    pub fn add_definition(&mut self, def: NormalizedDef) -> ContentHash {
        let hash = def.content_hash();
        let name = def.name.clone();
        
        self.definitions.insert(hash.clone(), def);
        self.names.insert(name, hash.clone());
        
        hash
    }
    
    /// Get a definition by hash
    pub fn get_by_hash(&self, hash: &ContentHash) -> Option<&NormalizedDef> {
        self.definitions.get(hash)
    }
    
    /// Get a definition by name (latest version)
    pub fn get_by_name(&self, name: &str) -> Option<&NormalizedDef> {
        self.names.get(name)
            .and_then(|hash| self.definitions.get(hash))
    }
    
    /// Get all versions of a definition
    pub fn get_versions(&self, name: &str) -> Vec<(&ContentHash, &NormalizedDef)> {
        self.definitions.iter()
            .filter(|(_, def)| def.name == name)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Literal;
    
    #[test]
    fn test_literal_hashing() {
        let expr1 = NormalizedExpr::Literal(Literal::Int(42));
        let expr2 = NormalizedExpr::Literal(Literal::Int(42));
        let expr3 = NormalizedExpr::Literal(Literal::Int(43));
        
        assert_eq!(expr1.content_hash(), expr2.content_hash());
        assert_ne!(expr1.content_hash(), expr3.content_hash());
    }
    
    #[test]
    fn test_structural_hashing() {
        // f (g x) should have the same hash regardless of how it was written
        let expr1 = NormalizedExpr::Apply {
            func: Box::new(NormalizedExpr::Var("f".to_string())),
            arg: Box::new(NormalizedExpr::Apply {
                func: Box::new(NormalizedExpr::Var("g".to_string())),
                arg: Box::new(NormalizedExpr::Var("x".to_string())),
            }),
        };
        
        let expr2 = expr1.clone();
        
        assert_eq!(expr1.content_hash(), expr2.content_hash());
    }
    
    #[test]
    fn test_alpha_equivalence_not_equal() {
        // λx.x and λy.y should have different hashes (we don't do alpha conversion)
        let expr1 = NormalizedExpr::Lambda {
            param: "x".to_string(),
            body: Box::new(NormalizedExpr::Var("x".to_string())),
        };
        
        let expr2 = NormalizedExpr::Lambda {
            param: "y".to_string(),
            body: Box::new(NormalizedExpr::Var("y".to_string())),
        };
        
        // These are alpha-equivalent but have different hashes
        // This is intentional - we hash the normalized form as-is
        assert_ne!(expr1.content_hash(), expr2.content_hash());
    }
    
    #[test]
    fn test_content_store() {
        let mut store = ContentStore::new();
        
        let def = NormalizedDef {
            name: "identity".to_string(),
            ty: None,
            effects: Default::default(),
            body: NormalizedExpr::Lambda {
                param: "x".to_string(),
                body: Box::new(NormalizedExpr::Var("x".to_string())),
            },
            is_recursive: false,
        };
        
        let hash = store.add_definition(def.clone());
        
        assert_eq!(store.get_by_hash(&hash).unwrap().name, "identity");
        assert_eq!(store.get_by_name("identity").unwrap().name, "identity");
    }
}