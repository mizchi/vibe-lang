//! Extract dependencies from XS expressions
//! 
//! This module analyzes XS expressions to find all referenced definitions
//! and resolve them to their content hashes.

use std::collections::HashSet;
use xs_core::{Expr, Pattern, Ident};
use crate::namespace::{NamespaceStore, DefinitionPath, NamespacePath};
use crate::hash::DefinitionHash;

/// Context for dependency extraction
pub struct DependencyExtractor<'a> {
    namespace_store: &'a NamespaceStore,
    current_namespace: NamespacePath,
    /// Stack of local binding scopes
    local_scopes: Vec<HashSet<String>>,
}

impl<'a> DependencyExtractor<'a> {
    pub fn new(namespace_store: &'a NamespaceStore, current_namespace: NamespacePath) -> Self {
        Self {
            namespace_store,
            current_namespace,
            local_scopes: vec![HashSet::new()],
        }
    }

    /// Extract all dependencies from an expression
    pub fn extract_from_expr(&mut self, expr: &Expr) -> HashSet<DefinitionHash> {
        let mut dependencies = HashSet::new();
        self.visit_expr(expr, &mut dependencies);
        dependencies
    }
    
    /// Check if a name is a local binding
    fn is_local_binding(&self, name: &str) -> bool {
        self.local_scopes.iter().any(|scope| scope.contains(name))
    }
    
    /// Push a new scope
    fn push_scope(&mut self) {
        self.local_scopes.push(HashSet::new());
    }
    
    /// Pop the current scope
    fn pop_scope(&mut self) {
        self.local_scopes.pop();
    }
    
    /// Add a binding to the current scope
    fn add_binding(&mut self, name: String) {
        if let Some(scope) = self.local_scopes.last_mut() {
            scope.insert(name);
        }
    }

    fn visit_expr(&mut self, expr: &Expr, deps: &mut HashSet<DefinitionHash>) {
        match expr {
            Expr::Ident(ident, _) => {
                // Check if it's a local binding
                if !self.is_local_binding(&ident.0) {
                    // Try to resolve as a definition
                    if let Some(hash) = self.resolve_ident(ident) {
                        deps.insert(hash);
                    }
                }
            }
            
            Expr::QualifiedIdent { module_name, name, .. } => {
                // Resolve qualified identifier
                if let Some(hash) = self.resolve_qualified_ident(module_name, name) {
                    deps.insert(hash);
                }
            }
            
            Expr::Lambda { params, body, .. } => {
                // Create new scope for lambda
                self.push_scope();
                
                // Add parameters to current scope
                for (param, _) in params {
                    self.add_binding(param.0.clone());
                }
                
                // Visit body
                self.visit_expr(body, deps);
                
                // Pop scope
                self.pop_scope();
            }
            
            Expr::Let { name, value, .. } => {
                // Visit value first
                self.visit_expr(value, deps);
                
                // Add name to current scope for subsequent expressions
                self.add_binding(name.0.clone());
            }
            
            Expr::LetIn { name, value, body, .. } => {
                // Visit value
                self.visit_expr(value, deps);
                
                // Create new scope for body
                self.push_scope();
                self.add_binding(name.0.clone());
                
                // Visit body
                self.visit_expr(body, deps);
                
                // Pop scope
                self.pop_scope();
            }
            
            Expr::LetRec { name, value, .. } => {
                // Add name to current scope before visiting value (for recursion)
                self.add_binding(name.0.clone());
                
                // Visit value
                self.visit_expr(value, deps);
            }
            
            Expr::Rec { name, params, body, .. } => {
                // Create new scope
                self.push_scope();
                
                // Add function name for recursion
                self.add_binding(name.0.clone());
                
                // Add parameters
                for (param, _) in params {
                    self.add_binding(param.0.clone());
                }
                
                // Visit body
                self.visit_expr(body, deps);
                
                // Pop scope
                self.pop_scope();
            }
            
            Expr::If { cond, then_expr, else_expr, .. } => {
                self.visit_expr(cond, deps);
                self.visit_expr(then_expr, deps);
                self.visit_expr(else_expr, deps);
            }
            
            Expr::Apply { func, args, .. } => {
                self.visit_expr(func, deps);
                for arg in args {
                    self.visit_expr(arg, deps);
                }
            }
            
            Expr::Match { expr, cases, .. } => {
                self.visit_expr(expr, deps);
                for (pattern, body) in cases {
                    // Create new scope for pattern bindings
                    self.push_scope();
                    self.add_pattern_bindings(pattern);
                    
                    self.visit_expr(body, deps);
                    
                    // Pop scope
                    self.pop_scope();
                }
            }
            
            Expr::List(items, _) => {
                for item in items {
                    self.visit_expr(item, deps);
                }
            }
            
            Expr::Constructor { args, .. } => {
                for arg in args {
                    self.visit_expr(arg, deps);
                }
            }
            
            Expr::Record { fields, .. } => {
                for (_, value) in fields {
                    self.visit_expr(value, deps);
                }
            }
            
            Expr::FieldAccess { record, .. } => {
                self.visit_expr(record, deps);
            }
            
            Expr::Module { body, .. } => {
                for expr in body {
                    self.visit_expr(expr, deps);
                }
            }
            
            Expr::Import { .. } => {
                // Imports are handled separately
            }
            
            Expr::Handler { cases, body, .. } => {
                for (_, patterns, continuation, handler_body) in cases {
                    // Create new scope
                    self.push_scope();
                    
                    // Add continuation binding
                    self.add_binding(continuation.0.clone());
                    
                    // Add pattern bindings
                    for pattern in patterns {
                        self.add_pattern_bindings(pattern);
                    }
                    
                    self.visit_expr(handler_body, deps);
                    
                    // Pop scope
                    self.pop_scope();
                }
                self.visit_expr(body, deps);
            }
            
            Expr::WithHandler { handler, body, .. } => {
                self.visit_expr(handler, deps);
                self.visit_expr(body, deps);
            }
            
            Expr::Perform { args, .. } => {
                for arg in args {
                    self.visit_expr(arg, deps);
                }
            }
            
            Expr::Pipeline { expr, func, .. } => {
                self.visit_expr(expr, deps);
                self.visit_expr(func, deps);
            }
            
            // Literals and type definitions don't have dependencies
            Expr::Literal(_, _) | Expr::TypeDef { .. } => {}
        }
    }
    
    fn add_pattern_bindings(&mut self, pattern: &Pattern) {
        match pattern {
            Pattern::Variable(ident, _) => {
                self.add_binding(ident.0.clone());
            }
            Pattern::List { patterns, rest, .. } => {
                for p in patterns {
                    self.add_pattern_bindings(p);
                }
                if let Some(rest_pattern) = rest {
                    self.add_pattern_bindings(rest_pattern);
                }
            }
            Pattern::Constructor { patterns, .. } => {
                for p in patterns {
                    self.add_pattern_bindings(p);
                }
            }
            Pattern::Wildcard(_) | Pattern::Literal(_, _) => {}
        }
    }
    
    /// Resolve an identifier to its definition hash
    fn resolve_ident(&self, ident: &Ident) -> Option<DefinitionHash> {
        // First try in current namespace
        let path = DefinitionPath::new(self.current_namespace.clone(), ident.0.clone());
        if let Some(def) = self.namespace_store.get_definition_by_path(&path) {
            return Some(def.hash.clone());
        }
        
        // Then try in parent namespaces
        let mut current = self.current_namespace.clone();
        while let Some(parent) = current.parent() {
            let path = DefinitionPath::new(parent.clone(), ident.0.clone());
            if let Some(def) = self.namespace_store.get_definition_by_path(&path) {
                return Some(def.hash.clone());
            }
            current = parent;
        }
        
        // Finally try in root namespace
        let root_path = DefinitionPath::new(NamespacePath::root(), ident.0.clone());
        self.namespace_store.get_definition_by_path(&root_path)
            .map(|def| def.hash.clone())
    }
    
    /// Resolve a qualified identifier to its definition hash
    fn resolve_qualified_ident(&self, module_name: &Ident, name: &Ident) -> Option<DefinitionHash> {
        // Build namespace path from module name
        let namespace = NamespacePath::from_str(&module_name.0);
        let path = DefinitionPath::new(namespace, name.0.clone());
        
        self.namespace_store.get_definition_by_path(&path)
            .map(|def| def.hash.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::namespace::{NamespaceStore, DefinitionContent};
    use xs_core::{Type, Literal, Span};

    #[test]
    fn test_extract_simple_dependency() {
        let mut store = NamespaceStore::new();
        
        // Add a definition
        let foo_def = DefinitionPath::from_str("foo").unwrap();
        let foo_content = DefinitionContent::Value(
            Expr::Literal(Literal::Int(42), Span::new(0, 2))
        );
        let foo_hash = store.add_definition(
            foo_def,
            foo_content,
            Type::Int,
            HashSet::new(),
            Default::default(),
        ).unwrap();
        
        // Create expression that references foo
        let expr = Expr::Apply {
            func: Box::new(Expr::Ident(Ident("add".to_string()), Span::new(0, 3))),
            args: vec![
                Expr::Ident(Ident("foo".to_string()), Span::new(4, 7)),
                Expr::Literal(Literal::Int(1), Span::new(8, 9)),
            ],
            span: Span::new(0, 10),
        };
        
        // Extract dependencies
        let mut extractor = DependencyExtractor::new(&store, NamespacePath::root());
        let deps = extractor.extract_from_expr(&expr);
        
        // Should find foo
        assert!(deps.contains(&foo_hash));
    }
    
    #[test]
    fn test_local_bindings_not_dependencies() {
        let store = NamespaceStore::new();
        
        // Create let expression
        let expr = Expr::LetIn {
            name: Ident("x".to_string()),
            type_ann: None,
            value: Box::new(Expr::Literal(Literal::Int(42), Span::new(5, 7))),
            body: Box::new(Expr::Apply {
                func: Box::new(Expr::Ident(Ident("add".to_string()), Span::new(11, 14))),
                args: vec![
                    Expr::Ident(Ident("x".to_string()), Span::new(15, 16)),
                    Expr::Literal(Literal::Int(1), Span::new(17, 18)),
                ],
                span: Span::new(10, 19),
            }),
            span: Span::new(0, 19),
        };
        
        // Extract dependencies
        let mut extractor = DependencyExtractor::new(&store, NamespacePath::root());
        let deps = extractor.extract_from_expr(&expr);
        
        // Should not include x as a dependency (it's a local binding)
        assert!(deps.is_empty());
    }
    
    #[test]
    fn test_qualified_identifier() {
        let mut store = NamespaceStore::new();
        
        // Add a definition in Math namespace
        let math_square = DefinitionPath::from_str("Math.square").unwrap();
        let square_content = DefinitionContent::Function {
            params: vec!["x".to_string()],
            body: Expr::Apply {
                func: Box::new(Expr::Ident(Ident("*".to_string()), Span::new(0, 1))),
                args: vec![
                    Expr::Ident(Ident("x".to_string()), Span::new(2, 3)),
                    Expr::Ident(Ident("x".to_string()), Span::new(4, 5)),
                ],
                span: Span::new(0, 6),
            },
        };
        let square_hash = store.add_definition(
            math_square,
            square_content,
            Type::Function(Box::new(Type::Int), Box::new(Type::Int)),
            HashSet::new(),
            Default::default(),
        ).unwrap();
        
        // Create expression with qualified identifier
        let expr = Expr::QualifiedIdent {
            module_name: Ident("Math".to_string()),
            name: Ident("square".to_string()),
            span: Span::new(0, 10),
        };
        
        // Extract dependencies
        let mut extractor = DependencyExtractor::new(&store, NamespacePath::root());
        let deps = extractor.extract_from_expr(&expr);
        
        // Should find Math.square
        assert!(deps.contains(&square_hash));
    }
}