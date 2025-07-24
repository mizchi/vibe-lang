//! Effect checking and inference for XS language
//!
//! This module implements effect inference based on Koka's approach,
//! tracking effects through the program and ensuring effect safety.

use crate::TypeEnv;
use std::collections::{HashMap, HashSet};
use vibe_core::{
    extensible_effects::{EffectDefinition, EffectInstance, ExtensibleEffectRow},
    Expr,
};

/// Effect inference state
pub struct EffectChecker {
    /// Fresh variable counter for effect variables
    #[allow(dead_code)]
    fresh_var_counter: usize,
    /// Effect variable substitutions
    effect_substitutions: HashMap<String, ExtensibleEffectRow>,
    /// Known effect definitions
    #[allow(dead_code)]
    effect_definitions: HashMap<String, EffectDefinition>,
}

/// Effect scheme - like TypeScheme but for effects
#[derive(Debug, Clone, PartialEq)]
pub struct EffectScheme {
    /// Bound effect variables
    pub vars: Vec<String>,
    /// The effect row
    pub effects: ExtensibleEffectRow,
}

impl EffectScheme {
    /// Create a monomorphic effect scheme
    #[allow(dead_code)]
    pub fn mono(effects: ExtensibleEffectRow) -> Self {
        EffectScheme {
            vars: Vec::new(),
            effects,
        }
    }
}

impl EffectChecker {
    pub fn new() -> Self {
        let mut effect_definitions = HashMap::new();
        // Convert BTreeMap to HashMap
        for (name, def) in vibe_core::extensible_effects::builtin_effects() {
            effect_definitions.insert(name, def);
        }

        EffectChecker {
            fresh_var_counter: 0,
            effect_substitutions: HashMap::new(),
            effect_definitions,
        }
    }

    /// Generate a fresh effect variable
    pub fn fresh_effect_var(&mut self) -> ExtensibleEffectRow {
        let var = format!("ε{}", self.fresh_var_counter);
        self.fresh_var_counter += 1;
        ExtensibleEffectRow::Variable(var)
    }

    /// Substitute effect variables
    fn substitute_effects(&self, effects: &ExtensibleEffectRow) -> ExtensibleEffectRow {
        match effects {
            ExtensibleEffectRow::Variable(v) => {
                if let Some(subst) = self.effect_substitutions.get(v) {
                    self.substitute_effects(subst)
                } else {
                    effects.clone()
                }
            }
            ExtensibleEffectRow::Extend(e, rest) => {
                ExtensibleEffectRow::Extend(e.clone(), Box::new(self.substitute_effects(rest)))
            }
            ExtensibleEffectRow::Union(left, right) => ExtensibleEffectRow::Union(
                Box::new(self.substitute_effects(left)),
                Box::new(self.substitute_effects(right)),
            ),
            _ => effects.clone(),
        }
    }

    /// Unify two effect rows
    #[allow(dead_code)]
    fn unify_effects(
        &mut self,
        e1: &ExtensibleEffectRow,
        e2: &ExtensibleEffectRow,
    ) -> Result<(), String> {
        let e1 = self.substitute_effects(e1);
        let e2 = self.substitute_effects(e2);

        match (&e1, &e2) {
            // Same effects
            (ExtensibleEffectRow::Empty, ExtensibleEffectRow::Empty) => Ok(()),
            (ExtensibleEffectRow::Single(eff1), ExtensibleEffectRow::Single(eff2))
                if eff1 == eff2 =>
            {
                Ok(())
            }

            // Variable unification
            (ExtensibleEffectRow::Variable(v), e) | (e, ExtensibleEffectRow::Variable(v)) => {
                if self.occurs_check(v, e) {
                    Err(format!("Infinite effect: {} occurs in {:?}", v, e))
                } else {
                    self.effect_substitutions.insert(v.clone(), e.clone());
                    Ok(())
                }
            }

            // Extension unification - try to match structure
            (ExtensibleEffectRow::Extend(e1, rest1), ExtensibleEffectRow::Extend(e2, rest2)) => {
                if e1 == e2 {
                    self.unify_effects(rest1, rest2)
                } else {
                    // Try to find e1 in the second row
                    if self.contains_effect(rest2, e1) {
                        // Continue checking
                        Ok(())
                    } else {
                        Err(format!("Cannot unify effects: {} not found in {}", e1, e2))
                    }
                }
            }

            _ => Err(format!("Cannot unify effects: {} and {}", e1, e2)),
        }
    }

    /// Check if an effect variable occurs in an effect row (for occurs check)
    fn occurs_check(&self, var: &str, effects: &ExtensibleEffectRow) -> bool {
        match effects {
            ExtensibleEffectRow::Variable(v) => v == var,
            ExtensibleEffectRow::Extend(_, rest) => self.occurs_check(var, rest),
            ExtensibleEffectRow::Union(left, right) => {
                self.occurs_check(var, left) || self.occurs_check(var, right)
            }
            _ => false,
        }
    }

    /// Check if an effect row contains a specific effect
    fn contains_effect(&self, row: &ExtensibleEffectRow, effect: &EffectInstance) -> bool {
        row.get_effects().iter().any(|e| e == effect)
    }

    /// Infer effects for an expression
    pub fn infer_effects(
        &mut self,
        expr: &Expr,
        env: &TypeEnv,
    ) -> Result<ExtensibleEffectRow, String> {
        match expr {
            // Pure expressions
            Expr::Literal(_, _) | Expr::Ident(_, _) => Ok(ExtensibleEffectRow::pure()),

            // Function application - combine effects
            Expr::Apply { func, args, .. } => {
                let func_effects = self.infer_effects(func, env)?;
                let mut all_effects = func_effects;

                for arg in args {
                    let arg_effects = self.infer_effects(arg, env)?;
                    all_effects = self.combine_effects(all_effects, arg_effects);
                }

                Ok(all_effects)
            }

            // Lambda - pure by itself
            Expr::Lambda { body, .. } => {
                // The lambda itself is pure, but we need to track the body's effects
                // for when it's applied
                self.infer_effects(body, env)
            }

            // Let bindings - combine value and body effects
            Expr::Let { value, .. } | Expr::LetRec { value, .. } => self.infer_effects(value, env),

            Expr::LetIn { value, body, .. } | Expr::LetRecIn { value, body, .. } => {
                let value_effects = self.infer_effects(value, env)?;
                let body_effects = self.infer_effects(body, env)?;
                Ok(self.combine_effects(value_effects, body_effects))
            }

            // Control flow
            Expr::If {
                cond,
                then_expr,
                else_expr,
                ..
            } => {
                let cond_effects = self.infer_effects(cond, env)?;
                let then_effects = self.infer_effects(then_expr, env)?;
                let else_effects = self.infer_effects(else_expr, env)?;

                // Effects from condition plus union of branch effects
                let branch_effects = self.union_effects(then_effects, else_effects);
                Ok(self.combine_effects(cond_effects, branch_effects))
            }

            // Pattern matching
            Expr::Match { expr, cases, .. } => {
                let expr_effects = self.infer_effects(expr, env)?;
                let mut case_effects = ExtensibleEffectRow::pure();

                for (_, case_expr) in cases {
                    let effects = self.infer_effects(case_expr, env)?;
                    case_effects = self.union_effects(case_effects, effects);
                }

                Ok(self.combine_effects(expr_effects, case_effects))
            }

            // Effect operations
            Expr::Perform { effect, args, .. } => {
                // Performing an effect adds it to the effect row
                let effect_instance = EffectInstance::new(effect.0.clone());
                let mut effects = ExtensibleEffectRow::Single(effect_instance);

                // Add effects from arguments
                for arg in args {
                    let arg_effects = self.infer_effects(arg, env)?;
                    effects = self.combine_effects(effects, arg_effects);
                }

                Ok(effects)
            }

            // Handlers eliminate effects
            Expr::WithHandler { handler, body, .. } => {
                let _body_effects = self.infer_effects(body, env)?;
                let handler_effects = self.infer_effects(handler, env)?;

                // Handler removes the handled effects from body
                // This is simplified - real implementation needs to check handler cases
                Ok(handler_effects)
            }

            Expr::Handler { body, .. } => {
                // Handler definition itself has the effects of its body
                self.infer_effects(body, env)
            }

            // Other cases
            Expr::List(exprs, _) => {
                let mut effects = ExtensibleEffectRow::pure();
                for e in exprs {
                    let e_effects = self.infer_effects(e, env)?;
                    effects = self.combine_effects(effects, e_effects);
                }
                Ok(effects)
            }

            Expr::Block { exprs, .. } => {
                let mut effects = ExtensibleEffectRow::pure();
                for e in exprs {
                    let e_effects = self.infer_effects(e, env)?;
                    effects = self.combine_effects(effects, e_effects);
                }
                Ok(effects)
            }

            // Handle expression - removes handled effects
            Expr::HandleExpr { expr, handlers, .. } => {
                // Get effects from the handled expression
                let expr_effects = self.infer_effects(expr, env)?;

                // Collect handled effects
                let mut handled_effects = HashSet::new();
                for handler in handlers {
                    // Extract the effect name
                    let effect_name = if let Some(ref op) = handler.operation {
                        format!("{}.{}", handler.effect.0, op.0)
                    } else {
                        handler.effect.0.clone()
                    };
                    handled_effects.insert(effect_name);

                    // Check handler body effects
                    let _body_effects = self.infer_effects(&handler.body, env)?;
                }

                // Remove handled effects from expression effects
                let remaining_effects = self.remove_effects(expr_effects, handled_effects);
                Ok(remaining_effects)
            }

            _ => Ok(ExtensibleEffectRow::pure()), // Default to pure for unhandled cases
        }
    }

    /// Combine two effect rows (sequential composition)
    fn combine_effects(
        &self,
        e1: ExtensibleEffectRow,
        e2: ExtensibleEffectRow,
    ) -> ExtensibleEffectRow {
        match (&e1, &e2) {
            (ExtensibleEffectRow::Empty, e) | (e, ExtensibleEffectRow::Empty) => e.clone(),
            _ => {
                // Get all effects from both rows
                let effects1 = e1.get_effects();
                let effects2 = e2.get_effects();

                // Rebuild as extended row
                let mut result = ExtensibleEffectRow::pure();
                for effect in effects1 {
                    result = result.add_effect(effect);
                }
                for effect in effects2 {
                    result = result.add_effect(effect);
                }
                result
            }
        }
    }

    /// Union two effect rows (for branches)
    fn union_effects(
        &self,
        e1: ExtensibleEffectRow,
        e2: ExtensibleEffectRow,
    ) -> ExtensibleEffectRow {
        match (&e1, &e2) {
            (ExtensibleEffectRow::Empty, ExtensibleEffectRow::Empty) => ExtensibleEffectRow::Empty,
            _ if e1 == e2 => e1,
            _ => ExtensibleEffectRow::Union(Box::new(e1), Box::new(e2)),
        }
    }

    /// Generalize an effect row into a scheme
    pub fn generalize_effects(&self, effects: &ExtensibleEffectRow, env: &TypeEnv) -> EffectScheme {
        let effects = self.substitute_effects(effects);
        let free_vars = self.free_effect_vars(&effects);

        // Get effect variables from the environment
        let env_vars = self.env_effect_vars(env);

        // Only generalize variables that are not in the environment
        let generalizable_vars: Vec<String> = free_vars
            .into_iter()
            .filter(|v| !env_vars.contains(v))
            .collect();

        EffectScheme {
            vars: generalizable_vars,
            effects,
        }
    }

    /// Get free effect variables
    fn free_effect_vars(&self, effects: &ExtensibleEffectRow) -> HashSet<String> {
        match effects {
            ExtensibleEffectRow::Variable(v) => {
                let mut set = HashSet::new();
                set.insert(v.clone());
                set
            }
            ExtensibleEffectRow::Extend(_, rest) => self.free_effect_vars(rest),
            ExtensibleEffectRow::Union(left, right) => {
                let mut vars = self.free_effect_vars(left);
                vars.extend(self.free_effect_vars(right));
                vars
            }
            _ => HashSet::new(),
        }
    }

    /// Remove a set of effects from an effect row
    fn remove_effects(
        &self,
        effects: ExtensibleEffectRow,
        to_remove: HashSet<String>,
    ) -> ExtensibleEffectRow {
        let current_effects = effects.get_effects();
        let mut remaining = ExtensibleEffectRow::pure();

        for effect in current_effects {
            // Check if this effect should be removed
            // Use the effect name directly
            let effect_name = effect.name.clone();

            if !to_remove.contains(&effect_name) {
                remaining = remaining.add_effect(effect);
            }
        }

        remaining
    }

    /// Get effect variables from the environment
    fn env_effect_vars(&self, env: &TypeEnv) -> HashSet<String> {
        let mut vars = HashSet::new();

        // Collect effect variables from all type schemes in the environment
        for binding in env.all_bindings() {
            if let Some(effects) = &binding.1.effects {
                vars.extend(self.free_effect_vars(effects));
            }
            // Also collect from effect_vars field
            vars.extend(binding.1.effect_vars.iter().cloned());
        }

        vars
    }

    /// Instantiate an effect scheme
    pub fn instantiate_effects(&mut self, scheme: &EffectScheme) -> ExtensibleEffectRow {
        let mut substitutions = HashMap::new();

        // Create fresh variables for each bound variable
        for var in &scheme.vars {
            let fresh_var = self.fresh_effect_var();
            if let ExtensibleEffectRow::Variable(fresh_name) = &fresh_var {
                substitutions.insert(var.clone(), fresh_name.clone());
            }
        }

        // Apply substitutions to the effect row
        self.instantiate_effect_row(&scheme.effects, &substitutions)
    }

    /// Helper to instantiate an effect row with substitutions
    fn instantiate_effect_row(
        &self,
        effects: &ExtensibleEffectRow,
        substitutions: &HashMap<String, String>,
    ) -> ExtensibleEffectRow {
        match effects {
            ExtensibleEffectRow::Variable(v) => {
                if let Some(new_var) = substitutions.get(v) {
                    ExtensibleEffectRow::Variable(new_var.clone())
                } else {
                    effects.clone()
                }
            }
            ExtensibleEffectRow::Extend(e, rest) => ExtensibleEffectRow::Extend(
                e.clone(),
                Box::new(self.instantiate_effect_row(rest, substitutions)),
            ),
            ExtensibleEffectRow::Union(left, right) => ExtensibleEffectRow::Union(
                Box::new(self.instantiate_effect_row(left, substitutions)),
                Box::new(self.instantiate_effect_row(right, substitutions)),
            ),
            _ => effects.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vibe_core::{Expr, Ident, Literal, Span};

    #[test]
    fn test_pure_expression() {
        let mut checker = EffectChecker::new();
        let env = TypeEnv::new();

        let expr = Expr::Literal(Literal::Int(42), Span::new(0, 2));
        let effects = checker.infer_effects(&expr, &env).unwrap();

        assert!(effects.is_pure());
    }

    #[test]
    fn test_perform_effect() {
        let mut checker = EffectChecker::new();
        let env = TypeEnv::new();

        let expr = Expr::Perform {
            effect: Ident("IO".to_string()),
            args: vec![Expr::Literal(
                Literal::String("Hello".to_string()),
                Span::new(0, 5),
            )],
            span: Span::new(0, 10),
        };

        let effects = checker.infer_effects(&expr, &env).unwrap();
        assert!(!effects.is_pure());

        let effect_vec = effects.get_effects();
        assert_eq!(effect_vec.len(), 1);
        assert!(effect_vec
            .iter()
            .any(|e| e == &EffectInstance::new("IO".to_string())));
    }

    #[test]
    fn test_handle_removes_effects() {
        let mut checker = EffectChecker::new();
        let env = TypeEnv::new();

        // Create a perform expression
        let perform_expr = Expr::Perform {
            effect: Ident("State".to_string()),
            args: vec![],
            span: Span::new(0, 10),
        };

        // Create a handler
        let handle_expr = Expr::HandleExpr {
            expr: Box::new(perform_expr),
            handlers: vec![vibe_core::HandlerCase {
                effect: Ident("State".to_string()),
                operation: None,
                args: vec![],
                continuation: Ident("k".to_string()),
                body: Expr::Literal(Literal::Int(42), Span::new(0, 2)),
                span: Span::new(0, 20),
            }],
            return_handler: None,
            span: Span::new(0, 30),
        };

        // The handle expression should have no State effect
        let effects = checker.infer_effects(&handle_expr, &env).unwrap();
        assert!(effects.is_pure());
    }

    #[test]
    fn test_handle_partial_removal() {
        let mut checker = EffectChecker::new();
        let env = TypeEnv::new();

        // Create an expression with multiple effects
        let io_perform = Expr::Perform {
            effect: Ident("IO".to_string()),
            args: vec![Expr::Literal(
                Literal::String("Hello".to_string()),
                Span::new(0, 5),
            )],
            span: Span::new(0, 10),
        };
        let state_perform = Expr::Perform {
            effect: Ident("State".to_string()),
            args: vec![],
            span: Span::new(10, 20),
        };

        // Block with both IO and State effects
        let block = Expr::Block {
            exprs: vec![io_perform, state_perform],
            span: Span::new(0, 30),
        };

        // Handler that only handles State
        let handle_expr = Expr::HandleExpr {
            expr: Box::new(block),
            handlers: vec![vibe_core::HandlerCase {
                effect: Ident("State".to_string()),
                operation: None,
                args: vec![],
                continuation: Ident("k".to_string()),
                body: Expr::Literal(Literal::Int(42), Span::new(0, 2)),
                span: Span::new(0, 20),
            }],
            return_handler: None,
            span: Span::new(0, 40),
        };

        // Should still have IO effect but not State
        let effects = checker.infer_effects(&handle_expr, &env).unwrap();
        assert!(!effects.is_pure());

        let effect_vec = effects.get_effects();
        assert_eq!(effect_vec.len(), 1);
        assert!(effect_vec
            .iter()
            .any(|e| e == &EffectInstance::new("IO".to_string())));
        assert!(!effect_vec
            .iter()
            .any(|e| e == &EffectInstance::new("State".to_string())));
    }
}
