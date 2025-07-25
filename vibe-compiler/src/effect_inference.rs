//! Effect inference for XS language
//!
//! Implements automatic effect inference based on the design in EXTENSIBLE_EFFECTS_DESIGN.md

#![allow(dead_code)]

use std::collections::HashMap;
use vibe_language::{Effect, EffectRow, EffectSet, EffectVar, Expr, Ident, Span, Type, XsError};

/// Effect constraint for inference
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EffectConstraint {
    /// ε1 = ε2
    Equal(EffectRow, EffectRow),
    /// ε1 ⊆ ε2
    Subset(EffectRow, EffectRow),
    /// ε = ε1 ∪ ε2
    Union(EffectRow, EffectRow, EffectRow),
}

/// Effect inference state
pub struct EffectInference {
    /// Collected constraints
    constraints: Vec<EffectConstraint>,
    /// Effect variable substitution
    substitution: HashMap<EffectVar, EffectRow>,
    /// Fresh variable counter
    fresh_counter: u32,
}

impl Default for EffectInference {
    fn default() -> Self {
        Self::new()
    }
}

impl EffectInference {
    pub fn new() -> Self {
        Self {
            constraints: Vec::new(),
            substitution: HashMap::new(),
            fresh_counter: 0,
        }
    }

    /// Generate a fresh effect variable
    pub fn fresh_effect_var(&mut self) -> EffectVar {
        let var = EffectVar(format!("ε{}", self.fresh_counter));
        self.fresh_counter += 1;
        var
    }

    /// Add a constraint
    pub fn add_constraint(&mut self, constraint: EffectConstraint) {
        self.constraints.push(constraint);
    }

    /// Apply substitution to an effect row
    pub fn apply_subst(&self, row: &EffectRow) -> EffectRow {
        match row {
            EffectRow::Concrete(set) => EffectRow::Concrete(set.clone()),
            EffectRow::Variable(var) => self
                .substitution
                .get(var)
                .map(|r| self.apply_subst(r))
                .unwrap_or_else(|| row.clone()),
            EffectRow::Extension(set, var) => match self.substitution.get(var) {
                Some(EffectRow::Concrete(set2)) => EffectRow::Concrete(set.union(set2)),
                Some(EffectRow::Variable(var2)) => EffectRow::Extension(set.clone(), var2.clone()),
                Some(EffectRow::Extension(set2, var2)) => {
                    EffectRow::Extension(set.union(set2), var2.clone())
                }
                None => row.clone(),
            },
        }
    }

    /// Solve constraints and produce substitution
    pub fn solve(&mut self) -> Result<(), XsError> {
        let mut changed = true;

        while changed {
            changed = false;
            let constraints = self.constraints.clone();

            for constraint in constraints {
                match constraint {
                    EffectConstraint::Equal(ref row1, ref row2) => {
                        if self.unify_effects(row1, row2)? {
                            changed = true;
                        }
                    }
                    EffectConstraint::Subset(ref row1, ref row2) => {
                        // For now, treat subset as equality
                        // TODO: Implement proper subset constraints
                        if self.unify_effects(row1, row2)? {
                            changed = true;
                        }
                    }
                    EffectConstraint::Union(ref result, ref row1, ref row2) => {
                        let union = self.union_effects(row1, row2);
                        if self.unify_effects(result, &union)? {
                            changed = true;
                        }
                    }
                }
            }
        }

        Ok(())
    }

    /// Unify two effect rows
    pub fn unify_effects(&mut self, row1: &EffectRow, row2: &EffectRow) -> Result<bool, XsError> {
        let row1 = self.apply_subst(row1);
        let row2 = self.apply_subst(row2);

        match (&row1, &row2) {
            (EffectRow::Concrete(set1), EffectRow::Concrete(set2)) => {
                if set1 == set2 {
                    Ok(false)
                } else {
                    Err(XsError::TypeError(
                        Span::new(0, 0),
                        format!("Cannot unify effects {set1:?} and {set2:?}"),
                    ))
                }
            }
            (EffectRow::Variable(var), row) | (row, EffectRow::Variable(var)) => {
                if let EffectRow::Variable(var2) = row {
                    if var == var2 {
                        return Ok(false);
                    }
                }
                self.substitution.insert(var.clone(), row.clone());
                Ok(true)
            }
            (EffectRow::Extension(set1, var1), EffectRow::Extension(set2, var2)) => {
                if var1 == var2 {
                    if set1 == set2 {
                        Ok(false)
                    } else {
                        Err(XsError::TypeError(
                            Span::new(0, 0),
                            "Cannot unify effect extensions".to_string(),
                        ))
                    }
                } else {
                    // Create a fresh variable for the common tail
                    let fresh = self.fresh_effect_var();
                    let diff1 = set1.difference(set2);
                    let diff2 = set2.difference(set1);

                    self.substitution
                        .insert(var1.clone(), EffectRow::Extension(diff2, fresh.clone()));
                    self.substitution
                        .insert(var2.clone(), EffectRow::Extension(diff1, fresh));
                    Ok(true)
                }
            }
            (EffectRow::Concrete(set), EffectRow::Extension(set2, var))
            | (EffectRow::Extension(set2, var), EffectRow::Concrete(set)) => {
                if let Some(diff) = set.try_difference(set2) {
                    self.substitution
                        .insert(var.clone(), EffectRow::Concrete(diff));
                    Ok(true)
                } else {
                    Err(XsError::TypeError(
                        Span::new(0, 0),
                        "Effect set is not a superset in unification".to_string(),
                    ))
                }
            }
        }
    }

    /// Compute union of two effect rows
    fn union_effects(&self, row1: &EffectRow, row2: &EffectRow) -> EffectRow {
        let row1 = self.apply_subst(row1);
        let row2 = self.apply_subst(row2);

        match (row1, row2) {
            (EffectRow::Concrete(set1), EffectRow::Concrete(set2)) => {
                EffectRow::Concrete(set1.union(&set2))
            }
            (EffectRow::Concrete(set), EffectRow::Variable(var))
            | (EffectRow::Variable(var), EffectRow::Concrete(set)) => {
                EffectRow::Extension(set, var)
            }
            (EffectRow::Variable(var1), EffectRow::Variable(var2)) => {
                if var1 == var2 {
                    EffectRow::Variable(var1)
                } else {
                    // Create a fresh variable that represents the union
                    let fresh = EffectVar(format!("{}∪{}", var1.0, var2.0));
                    EffectRow::Variable(fresh)
                }
            }
            (EffectRow::Extension(set1, var), EffectRow::Concrete(set2))
            | (EffectRow::Concrete(set2), EffectRow::Extension(set1, var)) => {
                EffectRow::Extension(set1.union(&set2), var)
            }
            (EffectRow::Extension(set, var1), EffectRow::Variable(var2))
            | (EffectRow::Variable(var2), EffectRow::Extension(set, var1)) => {
                if var1 == var2 {
                    EffectRow::Extension(set, var1)
                } else {
                    // The union includes both the concrete effects and both variables
                    let fresh = EffectVar(format!("{}∪{}", var1.0, var2.0));
                    EffectRow::Extension(set, fresh)
                }
            }
            (EffectRow::Extension(set1, var1), EffectRow::Extension(set2, var2)) => {
                let union_set = set1.union(&set2);
                if var1 == var2 {
                    EffectRow::Extension(union_set, var1)
                } else {
                    let fresh = EffectVar(format!("{}∪{}", var1.0, var2.0));
                    EffectRow::Extension(union_set, fresh)
                }
            }
        }
    }
}

/// Effect inference context
pub struct EffectContext {
    /// Type environment with effect information
    #[allow(dead_code)]
    env: HashMap<Ident, (Type, EffectRow)>,
    /// Effect inference state
    inference: EffectInference,
}

impl Default for EffectContext {
    fn default() -> Self {
        Self::new()
    }
}

impl EffectContext {
    pub fn new() -> Self {
        Self {
            env: HashMap::new(),
            inference: EffectInference::new(),
        }
    }

    /// Infer effects for an expression
    pub fn infer_effects(&mut self, expr: &Expr) -> Result<EffectRow, XsError> {
        match expr {
            Expr::Literal(_, _) => {
                // Literals are pure
                Ok(EffectRow::pure())
            }
            Expr::Ident(_, _) => {
                // Variables are pure (their effects are in their types)
                Ok(EffectRow::pure())
            }
            Expr::Lambda { body, .. } => {
                // Lambda creation is pure, but the body may have effects
                let _body_effects = self.infer_effects(body)?;
                // The lambda itself is pure, effects are captured in its type
                Ok(EffectRow::pure())
            }
            Expr::Apply { func, args, .. } => {
                // Function application combines effects
                let func_effects = self.infer_effects(func)?;
                let mut arg_effects = EffectRow::pure();

                for arg in args {
                    let eff = self.infer_effects(arg)?;
                    arg_effects = self.inference.union_effects(&arg_effects, &eff);
                }

                // Get the function's latent effects
                let latent_effects = self.get_function_effects(func)?;

                // Union all effects
                let result = self.inference.union_effects(&func_effects, &arg_effects);
                Ok(self.inference.union_effects(&result, &latent_effects))
            }
            Expr::Let { value, .. } => {
                // Let expressions sequence effects
                let value_effects = self.infer_effects(value)?;

                // For let-in, we need the body
                // This is a simplified version - real implementation needs the body
                Ok(value_effects)
            }
            Expr::LetIn { value, body, .. } => {
                // Let-in sequences effects
                let value_effects = self.infer_effects(value)?;
                let body_effects = self.infer_effects(body)?;
                Ok(self.inference.union_effects(&value_effects, &body_effects))
            }
            Expr::If {
                cond,
                then_expr,
                else_expr,
                ..
            } => {
                // If expressions combine effects from all branches
                let cond_effects = self.infer_effects(cond)?;
                let then_effects = self.infer_effects(then_expr)?;
                let else_effects = self.infer_effects(else_expr)?;

                let branch_effects = self.inference.union_effects(&then_effects, &else_effects);
                Ok(self.inference.union_effects(&cond_effects, &branch_effects))
            }
            Expr::Match { expr, cases, .. } => {
                // Match combines effects from scrutinee and all branches
                let expr_effects = self.infer_effects(expr)?;
                let mut case_effects = EffectRow::pure();

                for (_, case_expr) in cases {
                    let eff = self.infer_effects(case_expr)?;
                    case_effects = self.inference.union_effects(&case_effects, &eff);
                }

                Ok(self.inference.union_effects(&expr_effects, &case_effects))
            }
            Expr::Block { exprs, .. } => {
                // Block sequences effects from all expressions
                // For now, treat as application if it looks like one
                if exprs.len() >= 2 {
                    // Try to interpret as function application
                    let func = &exprs[0];
                    let args = &exprs[1..];

                    // Check if this is a function application pattern
                    if matches!(func, Expr::Ident(_, _)) {
                        let func_effects = self.infer_effects(func)?;
                        let mut arg_effects = EffectRow::pure();

                        for arg in args {
                            let eff = self.infer_effects(arg)?;
                            arg_effects = self.inference.union_effects(&arg_effects, &eff);
                        }

                        // Get the function's latent effects
                        let latent_effects = self.get_function_effects(func)?;

                        // Union all effects
                        let result = self.inference.union_effects(&func_effects, &arg_effects);
                        return Ok(self.inference.union_effects(&result, &latent_effects));
                    }
                }

                // Otherwise, sequence all effects
                let mut total_effects = EffectRow::pure();
                for expr in exprs {
                    let eff = self.infer_effects(expr)?;
                    total_effects = self.inference.union_effects(&total_effects, &eff);
                }
                Ok(total_effects)
            }
            _ => {
                // For other expressions, assume pure for now
                Ok(EffectRow::pure())
            }
        }
    }

    /// Get the latent effects of a function
    fn get_function_effects(&self, func: &Expr) -> Result<EffectRow, XsError> {
        // This is a placeholder - real implementation needs type information
        match func {
            Expr::Ident(name, _) => {
                // Check if it's a known effectful builtin
                match name.0.as_str() {
                    "print" | "read" | "read-file" | "write-file" => {
                        Ok(EffectRow::Concrete(EffectSet::single(Effect::IO)))
                    }
                    "ref" | "get" | "set" => {
                        Ok(EffectRow::Concrete(EffectSet::single(Effect::State)))
                    }
                    "error" | "try" | "catch" => {
                        Ok(EffectRow::Concrete(EffectSet::single(Effect::Error)))
                    }
                    _ => Ok(EffectRow::pure()),
                }
            }
            _ => Ok(EffectRow::pure()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_effect_unification() {
        let mut inference = EffectInference::new();

        // Unifying concrete effects
        let io = EffectRow::Concrete(EffectSet::single(Effect::IO));
        let io2 = EffectRow::Concrete(EffectSet::single(Effect::IO));
        assert!(!inference.unify_effects(&io, &io2).unwrap());

        // Unifying with variable
        let var = EffectRow::Variable(EffectVar("e1".to_string()));
        assert!(inference.unify_effects(&var, &io).unwrap());

        // Check substitution
        let subst = inference.apply_subst(&var);
        assert_eq!(subst, io);
    }

    #[test]
    fn test_effect_union() {
        let inference = EffectInference::new();

        let io = EffectRow::Concrete(EffectSet::single(Effect::IO));
        let state = EffectRow::Concrete(EffectSet::single(Effect::State));

        let union = inference.union_effects(&io, &state);
        match union {
            EffectRow::Concrete(set) => {
                assert!(set.contains(&Effect::IO));
                assert!(set.contains(&Effect::State));
            }
            _ => panic!("Expected concrete effect set"),
        }
    }
}
