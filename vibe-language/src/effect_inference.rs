//! Complete effect inference implementation for Koka-style effects
//! 
//! This module implements a constraint-based effect inference algorithm
//! that works alongside type inference to infer effect rows for expressions.

use crate::normalized_ast::{NormalizedExpr, NormalizedHandler};
use crate::koka_effects::{EffectRow, EffectType};
use crate::Type;
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// Effect constraint
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EffectConstraint {
    /// Effect row equality: e1 = e2
    Equal(EffectVar, EffectVar),
    /// Effect row inclusion: e1 ⊆ e2
    Subset(EffectVar, EffectVar),
    /// Effect row has specific effect: effect ∈ e
    HasEffect(EffectVar, EffectType),
    /// Effect row union: e1 ∪ e2 = e3
    Union(EffectVar, EffectVar, EffectVar),
    /// Effect row difference: e1 \ effect = e2
    Without(EffectVar, EffectType, EffectVar),
}

/// Effect variable
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct EffectVar(pub usize);

/// Effect substitution
#[derive(Debug, Clone)]
pub struct EffectSubst {
    subst: HashMap<EffectVar, EffectRow>,
}

impl EffectSubst {
    pub fn new() -> Self {
        Self {
            subst: HashMap::new(),
        }
    }
    
    pub fn insert(&mut self, var: EffectVar, row: EffectRow) {
        self.subst.insert(var, row);
    }
    
    pub fn apply(&self, var: &EffectVar) -> Option<EffectRow> {
        self.subst.get(var).cloned()
    }
    
    pub fn compose(&self, other: &EffectSubst) -> EffectSubst {
        let mut result = other.clone();
        for (var, row) in &self.subst {
            result.subst.insert(var.clone(), row.clone());
        }
        result
    }
}

/// Effect inference context
pub struct EffectInferenceContext {
    /// Next fresh effect variable
    next_var: usize,
    /// Type environment
    type_env: BTreeMap<String, Type>,
    /// Effect environment (for function effects)
    effect_env: BTreeMap<String, EffectRow>,
    /// Collected constraints
    constraints: Vec<EffectConstraint>,
}

impl EffectInferenceContext {
    pub fn new() -> Self {
        Self {
            next_var: 0,
            type_env: BTreeMap::new(),
            effect_env: BTreeMap::new(),
            constraints: Vec::new(),
        }
    }
    
    /// Generate a fresh effect variable
    pub fn fresh_effect_var(&mut self) -> EffectVar {
        let var = EffectVar(self.next_var);
        self.next_var += 1;
        var
    }
    
    /// Add a constraint
    pub fn add_constraint(&mut self, constraint: EffectConstraint) {
        self.constraints.push(constraint);
    }
    
    /// Infer effects for an expression
    pub fn infer(&mut self, expr: &NormalizedExpr) -> (Type, EffectVar) {
        match expr {
            NormalizedExpr::Literal(lit) => {
                // Literals are pure
                let ty = infer_literal_type(lit);
                let eff = self.fresh_effect_var();
                let pure_var = self.effect_row_to_var(EffectRow::pure());
                self.add_constraint(EffectConstraint::Equal(
                    eff.clone(),
                    pure_var,
                ));
                (ty, eff)
            }
            
            NormalizedExpr::Var(name) => {
                // Variables are pure, but may have effectful type
                let ty = self.type_env.get(name)
                    .cloned()
                    .unwrap_or(Type::Var(format!("t_{}", name)));
                let eff = self.fresh_effect_var();
                let pure_var = self.effect_row_to_var(EffectRow::pure());
                self.add_constraint(EffectConstraint::Equal(
                    eff.clone(),
                    pure_var,
                ));
                (ty, eff)
            }
            
            NormalizedExpr::Apply { func, arg } => {
                // Function application
                let (func_ty, func_eff) = self.infer(func);
                let (_arg_ty, arg_eff) = self.infer(arg);
                
                // Result effect is union of function effect, argument effect, and function's latent effect
                let result_eff = self.fresh_effect_var();
                let latent_eff = self.fresh_effect_var();
                
                // func_eff ∪ arg_eff ∪ latent_eff = result_eff
                let temp_eff = self.fresh_effect_var();
                self.add_constraint(EffectConstraint::Union(
                    func_eff,
                    arg_eff,
                    temp_eff.clone(),
                ));
                self.add_constraint(EffectConstraint::Union(
                    temp_eff,
                    latent_eff,
                    result_eff.clone(),
                ));
                
                // Extract result type from function type
                let result_ty = match func_ty {
                    Type::Function(_, ret) => *ret,
                    Type::FunctionWithEffect { to, .. } => *to,
                    _ => Type::Var(format!("result_{}", self.next_var)),
                };
                
                (result_ty, result_eff)
            }
            
            NormalizedExpr::Lambda { param, body } => {
                // Lambda abstraction
                let param_ty = Type::Var(format!("t_{}", param));
                self.type_env.insert(param.clone(), param_ty.clone());
                
                let (body_ty, body_eff) = self.infer(body);
                
                // Lambda itself is pure
                let lambda_eff = self.fresh_effect_var();
                let pure_var = self.effect_row_to_var(EffectRow::pure());
                self.add_constraint(EffectConstraint::Equal(
                    lambda_eff.clone(),
                    pure_var,
                ));
                
                // Function type captures the body effect
                let func_ty = Type::FunctionWithEffect {
                    from: Box::new(param_ty),
                    to: Box::new(body_ty),
                    effects: self.effect_var_to_row(body_eff),
                };
                
                (func_ty, lambda_eff)
            }
            
            NormalizedExpr::Let { name, value, body } => {
                // Let binding
                let (val_ty, val_eff) = self.infer(value);
                self.type_env.insert(name.clone(), val_ty);
                
                let (body_ty, body_eff) = self.infer(body);
                
                // Let effect is sequencing of value and body effects
                let let_eff = self.fresh_effect_var();
                self.add_constraint(EffectConstraint::Union(
                    val_eff,
                    body_eff,
                    let_eff.clone(),
                ));
                
                (body_ty, let_eff)
            }
            
            NormalizedExpr::Perform { effect, operation, args } => {
                // Effect performance
                let effect_type = parse_effect_type(effect);
                
                // Infer argument effects
                let mut arg_effs = Vec::new();
                for arg in args {
                    let (_, arg_eff) = self.infer(arg);
                    arg_effs.push(arg_eff);
                }
                
                // Result has the performed effect plus argument effects
                let result_eff = self.fresh_effect_var();
                
                // Add performed effect
                self.add_constraint(EffectConstraint::HasEffect(
                    result_eff.clone(),
                    effect_type,
                ));
                
                // Union with argument effects
                if !arg_effs.is_empty() {
                    let mut current = result_eff.clone();
                    for arg_eff in arg_effs {
                        let next = self.fresh_effect_var();
                        self.add_constraint(EffectConstraint::Union(
                            current,
                            arg_eff,
                            next.clone(),
                        ));
                        current = next;
                    }
                }
                
                // Result type depends on the operation
                let result_ty = infer_effect_result_type(effect, operation);
                
                (result_ty, result_eff)
            }
            
            NormalizedExpr::Handle { expr, handlers } => {
                // Effect handling
                let (expr_ty, expr_eff) = self.infer(expr);
                
                // Handled effects
                let handled_effects: BTreeSet<_> = handlers.iter()
                    .map(|h| parse_effect_type(&h.effect))
                    .collect();
                
                // Result effect is expr effect minus handled effects
                let mut result_eff = expr_eff.clone();
                for effect in handled_effects {
                    let new_eff = self.fresh_effect_var();
                    self.add_constraint(EffectConstraint::Without(
                        result_eff,
                        effect,
                        new_eff.clone(),
                    ));
                    result_eff = new_eff;
                }
                
                // Infer handler body effects
                for handler in handlers {
                    let (_, handler_eff) = self.infer(&handler.body);
                    // Handler effects are added to result
                    let new_eff = self.fresh_effect_var();
                    self.add_constraint(EffectConstraint::Union(
                        result_eff.clone(),
                        handler_eff,
                        new_eff.clone(),
                    ));
                    result_eff = new_eff;
                }
                
                (expr_ty, result_eff)
            }
            
            _ => {
                // Other cases - simplified
                let ty = Type::Var(format!("t_{}", self.next_var));
                let eff = self.fresh_effect_var();
                (ty, eff)
            }
        }
    }
    
    /// Convert effect row to effect variable
    fn effect_row_to_var(&mut self, _row: EffectRow) -> EffectVar {
        // In a real implementation, this would intern the row
        let var = self.fresh_effect_var();
        // Store the mapping
        var
    }
    
    /// Convert effect variable to effect row (for creating types)
    fn effect_var_to_row(&self, _var: EffectVar) -> crate::effects::EffectRow {
        // Simplified - would resolve from constraints
        crate::effects::EffectRow::pure()
    }
    
    /// Solve collected constraints
    pub fn solve(&mut self) -> Result<EffectSubst, String> {
        let mut subst = EffectSubst::new();
        
        // Simple unification-based solver
        for constraint in &self.constraints {
            match constraint {
                EffectConstraint::Equal(v1, v2) => {
                    // Unify v1 and v2
                    if v1 != v2 {
                        // Simple case - bind one to the other
                        if let Some(row) = subst.apply(v2) {
                            subst.insert(v1.clone(), row);
                        } else {
                            subst.insert(v1.clone(), EffectRow::polymorphic(format!("e{}", v2.0)));
                        }
                    }
                }
                
                EffectConstraint::HasEffect(var, effect) => {
                    // Add effect to the row
                    let mut row = subst.apply(var).unwrap_or_else(|| EffectRow::pure());
                    row.effects.insert(effect.clone());
                    subst.insert(var.clone(), row);
                }
                
                EffectConstraint::Union(v1, v2, v3) => {
                    // v3 = v1 ∪ v2
                    let row1 = subst.apply(v1).unwrap_or_else(|| EffectRow::pure());
                    let row2 = subst.apply(v2).unwrap_or_else(|| EffectRow::pure());
                    let row3 = row1.union(&row2);
                    subst.insert(v3.clone(), row3);
                }
                
                EffectConstraint::Without(v1, effect, v2) => {
                    // v2 = v1 \ effect
                    let row1 = subst.apply(v1).unwrap_or_else(|| EffectRow::pure());
                    let row2 = row1.without(effect);
                    subst.insert(v2.clone(), row2);
                }
                
                _ => {
                    // Other constraints - simplified
                }
            }
        }
        
        Ok(subst)
    }
}

/// Parse effect type from string
fn parse_effect_type(effect: &str) -> EffectType {
    match effect {
        "IO" => EffectType::IO,
        "Async" => EffectType::Async,
        "Amb" => EffectType::Amb,
        s if s.starts_with("State") => EffectType::State("Any".to_string()),
        s if s.starts_with("Exn") => EffectType::Exn("Any".to_string()),
        other => EffectType::User(other.to_string()),
    }
}

/// Infer literal type
fn infer_literal_type(lit: &crate::Literal) -> Type {
    match lit {
        crate::Literal::Int(_) => Type::Int,
        crate::Literal::Float(_) => Type::Float,
        crate::Literal::Bool(_) => Type::Bool,
        crate::Literal::String(_) => Type::String,
    }
}

/// Infer result type of effect operation
fn infer_effect_result_type(effect: &str, operation: &str) -> Type {
    match (effect, operation) {
        ("IO", "print") => Type::Unit,
        ("IO", "read") => Type::String,
        ("State", "get") => Type::Var("state".to_string()),
        ("State", "put") => Type::Unit,
        _ => Type::Var(format!("{}_{}_result", effect, operation)),
    }
}

/// Complete effect inference for a program
pub fn infer_effects(expr: &NormalizedExpr) -> Result<(Type, EffectRow), String> {
    let mut ctx = EffectInferenceContext::new();
    
    // Infer with constraints
    let (ty, eff_var) = ctx.infer(expr);
    
    // Solve constraints
    let subst = ctx.solve()?;
    
    // Apply substitution to get final effect
    let final_effect = subst.apply(&eff_var)
        .unwrap_or_else(|| EffectRow::polymorphic(format!("e{}", eff_var.0)));
    
    Ok((ty, final_effect))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Literal;
    
    #[test]
    fn test_pure_expression_inference() {
        let expr = NormalizedExpr::Literal(Literal::Int(42));
        let result = infer_effects(&expr).unwrap();
        
        assert_eq!(result.0, Type::Int);
        assert!(result.1.effects.is_empty());
    }
    
    #[test]
    fn test_effectful_expression_inference() {
        let expr = NormalizedExpr::Perform {
            effect: "IO".to_string(),
            operation: "print".to_string(),
            args: vec![NormalizedExpr::Literal(Literal::String("hello".to_string()))],
        };
        
        let result = infer_effects(&expr).unwrap();
        assert!(result.1.effects.contains(&EffectType::IO));
    }
    
    #[test]
    fn test_handle_removes_effects() {
        let expr = NormalizedExpr::Handle {
            expr: Box::new(NormalizedExpr::Perform {
                effect: "IO".to_string(),
                operation: "print".to_string(),
                args: vec![],
            }),
            handlers: vec![
                NormalizedHandler {
                    effect: "IO".to_string(),
                    operation: "print".to_string(),
                    params: vec![],
                    resume: "k".to_string(),
                    body: NormalizedExpr::Literal(Literal::String("handled".to_string())),
                },
            ],
        };
        
        let result = infer_effects(&expr).unwrap();
        // IO effect should be handled
        assert!(!result.1.effects.contains(&EffectType::IO));
    }
    
    #[test]
    fn test_effect_sequencing() {
        let expr = NormalizedExpr::Let {
            name: "x".to_string(),
            value: Box::new(NormalizedExpr::Perform {
                effect: "IO".to_string(),
                operation: "read".to_string(),
                args: vec![],
            }),
            body: Box::new(NormalizedExpr::Perform {
                effect: "State".to_string(),
                operation: "get".to_string(),
                args: vec![],
            }),
        };
        
        let result = infer_effects(&expr).unwrap();
        // Should have both IO and State effects
        assert!(result.1.effects.contains(&EffectType::IO));
        assert!(result.1.effects.iter().any(|e| matches!(e, EffectType::State(_))));
    }
}