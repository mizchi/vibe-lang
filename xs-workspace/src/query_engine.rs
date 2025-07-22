//! Query Engine for executing code searches
//!
//! Implements the search logic for various query types against the namespace store.

use std::collections::HashSet;
use std::sync::Arc;
use xs_core::{Type, Expr, Pattern, XsError};
use crate::namespace::{NamespaceStore, NamespacePath, DefinitionPath, DefinitionContent, Definition};
use crate::hash::DefinitionHash;
use crate::code_query::{CodeQuery, TypePattern, AstPattern, AstNodeType, SearchResult, PatternType};

/// Query engine for executing searches
pub struct QueryEngine {
    namespace_store: Arc<NamespaceStore>,
}

impl QueryEngine {
    pub fn new(namespace_store: Arc<NamespaceStore>) -> Self {
        Self { namespace_store }
    }
    
    /// Execute a query and return matching results
    pub fn search(&self, query: &CodeQuery) -> Result<Vec<SearchResult>, XsError> {
        let mut results = Vec::new();
        
        // Get all definitions to search through
        let all_definitions = self.collect_all_definitions();
        
        // Filter definitions based on query
        for (path, hash) in all_definitions {
            if let Some(def) = self.namespace_store.get_definition(&hash) {
                if self.matches_query(&path, &hash, def, query)? {
                    let match_reason = self.get_match_reason(&path, &hash, def, query)?;
                    results.push(SearchResult::new(
                        path,
                        hash,
                        def.type_signature.clone(),
                        match_reason,
                    ));
                }
            }
        }
        
        // Sort by relevance (for now, just by path)
        results.sort_by(|a, b| a.path.to_string().cmp(&b.path.to_string()));
        
        Ok(results)
    }
    
    /// Check if a definition matches the query
    fn matches_query(
        &self,
        path: &DefinitionPath,
        hash: &DefinitionHash,
        def: &Definition,
        query: &CodeQuery,
    ) -> Result<bool, XsError> {
        match query {
            CodeQuery::TypePattern(pattern) => {
                Ok(self.matches_type_pattern(&def.type_signature, pattern))
            }
            
            CodeQuery::AstPattern(pattern) => {
                Ok(self.matches_ast_pattern(&def.content, pattern))
            }
            
            CodeQuery::DependsOn { target, transitive } => {
                if *transitive {
                    Ok(self.has_transitive_dependency(hash, target))
                } else {
                    if let Some(target_hash) = self.namespace_store.get_definition_by_path(target) {
                        Ok(def.dependencies.contains(&target_hash.hash))
                    } else {
                        Ok(false)
                    }
                }
            }
            
            CodeQuery::DependedBy { target, transitive } => {
                if let Some(target_def) = self.namespace_store.get_definition_by_path(target) {
                    let dependents = self.namespace_store.get_dependents(&target_def.hash);
                    if *transitive {
                        // TODO: Implement transitive dependents
                        Ok(dependents.contains(hash))
                    } else {
                        Ok(dependents.contains(hash))
                    }
                } else {
                    Ok(false)
                }
            }
            
            CodeQuery::NamePattern(pattern) => {
                Ok(self.matches_name_pattern(&path.name, pattern))
            }
            
            CodeQuery::InNamespace(ns_path) => {
                Ok(self.is_in_namespace(path, ns_path))
            }
            
            CodeQuery::And(q1, q2) => {
                Ok(self.matches_query(path, hash, def, q1)? 
                   && self.matches_query(path, hash, def, q2)?)
            }
            
            CodeQuery::Or(q1, q2) => {
                Ok(self.matches_query(path, hash, def, q1)? 
                   || self.matches_query(path, hash, def, q2)?)
            }
            
            CodeQuery::Not(q) => {
                Ok(!self.matches_query(path, hash, def, q)?)
            }
        }
    }
    
    /// Check if a type matches a type pattern
    fn matches_type_pattern(&self, ty: &Type, pattern: &TypePattern) -> bool {
        match pattern {
            TypePattern::Exact(expected) => ty == expected,
            
            TypePattern::Function { input, output } => {
                if let Type::Function(in_ty, out_ty) = ty {
                    let input_match = input.as_ref()
                        .map(|p| self.matches_type_pattern(in_ty, p))
                        .unwrap_or(true);
                    
                    let output_match = output.as_ref()
                        .map(|p| self.matches_type_pattern(out_ty, p))
                        .unwrap_or(true);
                    
                    input_match && output_match
                } else {
                    false
                }
            }
            
            TypePattern::List(inner) => {
                if let Type::List(inner_ty) = ty {
                    self.matches_type_pattern(inner_ty, inner)
                } else {
                    false
                }
            }
            
            TypePattern::Any => true,
            
            TypePattern::ContainsVar(var_name) => {
                self.type_contains_var(ty, var_name)
            }
        }
    }
    
    /// Check if a type contains a specific type variable
    fn type_contains_var(&self, ty: &Type, var_name: &str) -> bool {
        match ty {
            Type::Var(name) => name == var_name,
            Type::Function(in_ty, out_ty) => {
                self.type_contains_var(in_ty, var_name) || 
                self.type_contains_var(out_ty, var_name)
            }
            Type::List(inner) => self.type_contains_var(inner, var_name),
            _ => false,
        }
    }
    
    /// Check if content matches an AST pattern
    fn matches_ast_pattern(&self, content: &DefinitionContent, pattern: &AstPattern) -> bool {
        match pattern {
            AstPattern::Contains(node_type) => {
                match content {
                    DefinitionContent::Function { body, .. } => {
                        self.expr_contains_node_type(body, node_type)
                    }
                    DefinitionContent::Value(expr) => {
                        self.expr_contains_node_type(expr, node_type)
                    }
                    _ => false,
                }
            }
            
            AstPattern::FunctionWith { param_count, contains, recursive } => {
                if let DefinitionContent::Function { params, .. } = content {
                    let param_match = param_count
                        .map(|count| params.len() == count)
                        .unwrap_or(true);
                    
                    let contains_match = contains.as_ref()
                        .map(|p| self.matches_ast_pattern(content, p))
                        .unwrap_or(true);
                    
                    let recursive_match = recursive
                        .map(|_is_rec| {
                            // Check if function is recursive
                            // This would require checking if the function name appears in body
                            // For now, just return true
                            true
                        })
                        .unwrap_or(true);
                    
                    param_match && contains_match && recursive_match
                } else {
                    false
                }
            }
            
            AstPattern::UsesBuiltin(name) => {
                match content {
                    DefinitionContent::Function { body, .. } => {
                        self.expr_uses_builtin(body, name)
                    }
                    DefinitionContent::Value(expr) => {
                        self.expr_uses_builtin(expr, name)
                    }
                    _ => false,
                }
            }
            
            AstPattern::HasPatternMatch { min_cases, pattern_type } => {
                match content {
                    DefinitionContent::Function { body, .. } => {
                        self.expr_has_pattern_match(body, min_cases, pattern_type)
                    }
                    DefinitionContent::Value(expr) => {
                        self.expr_has_pattern_match(expr, min_cases, pattern_type)
                    }
                    _ => false,
                }
            }
        }
    }
    
    /// Check if an expression contains a specific node type
    fn expr_contains_node_type(&self, expr: &Expr, node_type: &AstNodeType) -> bool {
        match (expr, node_type) {
            (Expr::Lambda { .. }, AstNodeType::Lambda) => true,
            (Expr::Apply { .. }, AstNodeType::Application) => true,
            (Expr::Let { .. }, AstNodeType::Let) => true,
            (Expr::LetIn { .. }, AstNodeType::LetIn) => true,
            (Expr::If { .. }, AstNodeType::If) => true,
            (Expr::Match { .. }, AstNodeType::Match) => true,
            (Expr::Literal(..), AstNodeType::Literal) => true,
            (Expr::Ident(..), AstNodeType::Identifier) => true,
            (Expr::List(..), AstNodeType::List) => true,
            _ => {
                // Recursively check sub-expressions
                match expr {
                    Expr::Lambda { body, .. } => self.expr_contains_node_type(body, node_type),
                    Expr::Apply { func, args, .. } => {
                        self.expr_contains_node_type(func, node_type) ||
                        args.iter().any(|arg| self.expr_contains_node_type(arg, node_type))
                    }
                    Expr::Let { value, .. } => self.expr_contains_node_type(value, node_type),
                    Expr::LetIn { value, body, .. } => {
                        self.expr_contains_node_type(value, node_type) ||
                        self.expr_contains_node_type(body, node_type)
                    }
                    Expr::If { cond, then_expr, else_expr, .. } => {
                        self.expr_contains_node_type(cond, node_type) ||
                        self.expr_contains_node_type(then_expr, node_type) ||
                        self.expr_contains_node_type(else_expr, node_type)
                    }
                    Expr::Match { expr, cases, .. } => {
                        self.expr_contains_node_type(expr, node_type) ||
                        cases.iter().any(|(_pat, e)| self.expr_contains_node_type(e, node_type))
                    }
                    Expr::List(items, _) => {
                        items.iter().any(|e| self.expr_contains_node_type(e, node_type))
                    }
                    _ => false,
                }
            }
        }
    }
    
    /// Check if an expression uses a specific builtin
    fn expr_uses_builtin(&self, expr: &Expr, builtin_name: &str) -> bool {
        match expr {
            Expr::Ident(name, _) => name.0 == builtin_name,
            Expr::Lambda { body, .. } => self.expr_uses_builtin(body, builtin_name),
            Expr::Apply { func, args, .. } => {
                self.expr_uses_builtin(func, builtin_name) ||
                args.iter().any(|arg| self.expr_uses_builtin(arg, builtin_name))
            }
            Expr::Let { value, .. } => {
                self.expr_uses_builtin(value, builtin_name)
            }
            Expr::LetIn { value, body, .. } => {
                self.expr_uses_builtin(value, builtin_name) ||
                self.expr_uses_builtin(body, builtin_name)
            }
            Expr::If { cond, then_expr, else_expr, .. } => {
                self.expr_uses_builtin(cond, builtin_name) ||
                self.expr_uses_builtin(then_expr, builtin_name) ||
                self.expr_uses_builtin(else_expr, builtin_name)
            }
            Expr::Match { expr, cases, .. } => {
                self.expr_uses_builtin(expr, builtin_name) ||
                cases.iter().any(|(_, e)| self.expr_uses_builtin(e, builtin_name))
            }
            Expr::List(items, _) => {
                items.iter().any(|e| self.expr_uses_builtin(e, builtin_name))
            }
            _ => false,
        }
    }
    
    /// Check if an expression has pattern matching with specific criteria
    fn expr_has_pattern_match(
        &self,
        expr: &Expr,
        min_cases: &Option<usize>,
        pattern_type: &Option<PatternType>,
    ) -> bool {
        match expr {
            Expr::Match { cases, .. } => {
                let case_count_match = min_cases
                    .map(|min| cases.len() >= min)
                    .unwrap_or(true);
                
                let pattern_type_match = pattern_type.as_ref()
                    .map(|pt| cases.iter().any(|(pat, _)| self.pattern_has_type(pat, pt)))
                    .unwrap_or(true);
                
                case_count_match && pattern_type_match
            }
            // Recursively check sub-expressions
            Expr::Lambda { body, .. } => self.expr_has_pattern_match(body, min_cases, pattern_type),
            Expr::Apply { func, args, .. } => {
                self.expr_has_pattern_match(func, min_cases, pattern_type) ||
                args.iter().any(|arg| self.expr_has_pattern_match(arg, min_cases, pattern_type))
            }
            Expr::Let { value, .. } => {
                self.expr_has_pattern_match(value, min_cases, pattern_type)
            }
            Expr::LetIn { value, body, .. } => {
                self.expr_has_pattern_match(value, min_cases, pattern_type) ||
                self.expr_has_pattern_match(body, min_cases, pattern_type)
            }
            Expr::If { cond, then_expr, else_expr, .. } => {
                self.expr_has_pattern_match(cond, min_cases, pattern_type) ||
                self.expr_has_pattern_match(then_expr, min_cases, pattern_type) ||
                self.expr_has_pattern_match(else_expr, min_cases, pattern_type)
            }
            _ => false,
        }
    }
    
    /// Check if a pattern has a specific type
    fn pattern_has_type(&self, pattern: &Pattern, pattern_type: &PatternType) -> bool {
        match (pattern, pattern_type) {
            (Pattern::Constructor { .. }, PatternType::Constructor) => true,
            (Pattern::List { .. }, PatternType::List) => true,
            (Pattern::Literal(..), PatternType::Literal) => true,
            (Pattern::Variable(..), PatternType::Variable) => true,
            (Pattern::Wildcard(..), PatternType::Wildcard) => true,
            _ => false,
        }
    }
    
    /// Check if a name matches a pattern (supports * wildcard)
    fn matches_name_pattern(&self, name: &str, pattern: &str) -> bool {
        if pattern.contains('*') {
            // Simple wildcard matching
            let parts: Vec<&str> = pattern.split('*').collect();
            if parts.len() == 2 {
                let prefix = parts[0];
                let suffix = parts[1];
                name.starts_with(prefix) && name.ends_with(suffix)
            } else {
                // For now, just support single wildcard
                name == pattern
            }
        } else {
            name == pattern
        }
    }
    
    /// Check if a definition is in a specific namespace
    fn is_in_namespace(&self, path: &DefinitionPath, namespace: &NamespacePath) -> bool {
        if namespace.0.is_empty() {
            true // Root namespace contains everything
        } else if path.namespace.0.len() < namespace.0.len() {
            false
        } else {
            namespace.0.iter()
                .zip(path.namespace.0.iter())
                .all(|(a, b)| a == b)
        }
    }
    
    /// Check if a definition has a transitive dependency
    fn has_transitive_dependency(&self, from: &DefinitionHash, to_path: &DefinitionPath) -> bool {
        if let Some(to_def) = self.namespace_store.get_definition_by_path(to_path) {
            let to_hash = &to_def.hash;
            
            // BFS to find transitive dependencies
            let mut visited = HashSet::new();
            let mut queue = vec![from.clone()];
            
            while let Some(current) = queue.pop() {
                if visited.contains(&current) {
                    continue;
                }
                visited.insert(current.clone());
                
                if let Some(def) = self.namespace_store.get_definition(&current) {
                    if def.dependencies.contains(to_hash) {
                        return true;
                    }
                    
                    for dep in &def.dependencies {
                        queue.push(dep.clone());
                    }
                }
            }
        }
        false
    }
    
    /// Collect all definitions from all namespaces
    fn collect_all_definitions(&self) -> Vec<(DefinitionPath, DefinitionHash)> {
        let mut all_defs = Vec::new();
        let mut queue = vec![NamespacePath::root()];
        
        while let Some(ns_path) = queue.pop() {
            // Get definitions in this namespace
            for (name, hash) in self.namespace_store.list_namespace(&ns_path) {
                let path = DefinitionPath::new(ns_path.clone(), name);
                all_defs.push((path, hash));
            }
            
            // Get sub-namespaces
            for sub_ns in self.namespace_store.list_subnamespaces(&ns_path) {
                queue.push(ns_path.child(&sub_ns));
            }
        }
        
        all_defs
    }
    
    /// Get a human-readable reason for why a definition matched
    fn get_match_reason(
        &self,
        _path: &DefinitionPath,
        _hash: &DefinitionHash,
        def: &Definition,
        query: &CodeQuery,
    ) -> Result<String, XsError> {
        match query {
            CodeQuery::TypePattern(_) => {
                Ok(format!("Type matches: {}", self.type_to_string(&def.type_signature)))
            }
            CodeQuery::AstPattern(pattern) => {
                Ok(format!("AST pattern: {:?}", pattern))
            }
            CodeQuery::DependsOn { target, .. } => {
                Ok(format!("Depends on: {}", target.to_string()))
            }
            CodeQuery::DependedBy { target, .. } => {
                Ok(format!("Depended by: {}", target.to_string()))
            }
            CodeQuery::NamePattern(pattern) => {
                Ok(format!("Name matches pattern: {}", pattern))
            }
            CodeQuery::InNamespace(ns) => {
                Ok(format!("In namespace: {}", ns.to_string()))
            }
            CodeQuery::And(_, _) => Ok("Matches combined criteria".to_string()),
            CodeQuery::Or(_, _) => Ok("Matches one of the criteria".to_string()),
            CodeQuery::Not(_) => Ok("Does not match excluded criteria".to_string()),
        }
    }
    
    /// Convert a type to a readable string
    fn type_to_string(&self, ty: &Type) -> String {
        match ty {
            Type::Int => "Int".to_string(),
            Type::Float => "Float".to_string(),
            Type::String => "String".to_string(),
            Type::Bool => "Bool".to_string(),
            Type::Var(name) => name.clone(),
            Type::Function(from, to) => {
                format!("({} -> {})", self.type_to_string(from), self.type_to_string(to))
            }
            Type::List(inner) => format!("List {}", self.type_to_string(inner)),
            _ => format!("{:?}", ty),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::code_query::QueryBuilder;
    
    #[test]
    fn test_name_pattern_matching() {
        let engine = QueryEngine::new(Arc::new(NamespaceStore::new()));
        
        assert!(engine.matches_name_pattern("testFoo", "test*"));
        assert!(engine.matches_name_pattern("fooTest", "*Test"));
        assert!(!engine.matches_name_pattern("barBaz", "test*"));
    }
    
    #[test]
    fn test_namespace_matching() {
        let engine = QueryEngine::new(Arc::new(NamespaceStore::new()));
        
        let path = DefinitionPath::from_str("Math.Utils.fibonacci").unwrap();
        let ns = NamespacePath::from_str("Math");
        assert!(engine.is_in_namespace(&path, &ns));
        
        let ns = NamespacePath::from_str("Math.Utils");
        assert!(engine.is_in_namespace(&path, &ns));
        
        let ns = NamespacePath::from_str("String");
        assert!(!engine.is_in_namespace(&path, &ns));
    }
}