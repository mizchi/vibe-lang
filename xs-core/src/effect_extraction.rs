//! Extract effects from typed expressions
//!
//! This module provides utilities to extract effect information from
//! typed expressions for permission checking.

use crate::{Type, EffectSet, EffectRow};

/// Extract effects from a type
pub fn extract_effects_from_type(ty: &Type) -> EffectSet {
    match ty {
        Type::FunctionWithEffect { effects, .. } => {
            // Extract effect set from the effect row
            match effects {
                EffectRow::Concrete(set) => set.clone(),
                EffectRow::Variable(_) => EffectSet::pure(), // Unknown effects, assume pure
                EffectRow::Extension(set, _) => set.clone(), // Take the concrete part
            }
        }
        Type::Function(from, to) => {
            // Pure functions have no effects, but check nested types
            let mut effects = EffectSet::pure();
            
            // But check nested function types
            effects = effects.union(&extract_effects_from_type(from));
            effects = effects.union(&extract_effects_from_type(to));
            
            effects
        }
        Type::List(inner) => {
            // Check inner type for effects
            extract_effects_from_type(inner)
        }
        Type::UserDefined { type_params, .. } => {
            // Check type parameters for effects
            let mut effects = EffectSet::pure();
            for param in type_params {
                effects = effects.union(&extract_effects_from_type(param));
            }
            effects
        }
        Type::Record { fields } => {
            // Check field types for effects
            let mut effects = EffectSet::pure();
            for (_, field_type) in fields {
                effects = effects.union(&extract_effects_from_type(field_type));
            }
            effects
        }
        // Primitive types have no effects
        Type::Int | Type::Float | Type::Bool | Type::String | Type::Var(_) => {
            EffectSet::pure()
        }
    }
}

/// Extract all effects that might be performed by an expression
/// This is a conservative analysis - it may over-approximate
pub fn extract_all_possible_effects(ty: &Type) -> EffectSet {
    let mut effects = extract_effects_from_type(ty);
    
    // For function types, we need to consider what effects might be
    // performed when the function is called
    match ty {
        Type::FunctionWithEffect { to, effects: row, .. } => {
            // Add the function's own effects
            match row {
                EffectRow::Concrete(set) => effects = effects.union(set),
                EffectRow::Extension(set, _) => effects = effects.union(set),
                EffectRow::Variable(_) => {} // Unknown effects
            }
            // And any effects from the return type
            effects = effects.union(&extract_all_possible_effects(to));
        }
        Type::Function(_, to) => {
            // Even pure functions might return effectful functions
            effects = effects.union(&extract_all_possible_effects(to));
        }
        _ => {}
    }
    
    effects
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Effect;

    #[test]
    fn test_extract_effects_from_pure_function() {
        let ty = Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Int),
        );
        
        let effects = extract_effects_from_type(&ty);
        assert!(effects.is_pure());
    }

    #[test]
    fn test_extract_effects_from_effectful_function() {
        let mut effects = EffectSet::pure();
        effects.add(Effect::IO);
        
        let ty = Type::FunctionWithEffect {
            from: Box::new(Type::String),
            to: Box::new(Type::Int),
            effects: EffectRow::Concrete(effects.clone()),
        };
        
        let extracted = extract_effects_from_type(&ty);
        assert_eq!(extracted, effects);
    }

    #[test]
    fn test_extract_effects_from_nested_types() {
        let mut io_effects = EffectSet::pure();
        io_effects.add(Effect::IO);
        
        // List of effectful functions
        let ty = Type::List(Box::new(Type::FunctionWithEffect {
            from: Box::new(Type::String),
            to: Box::new(Type::Int),
            effects: EffectRow::Concrete(io_effects.clone()),
        }));
        
        let extracted = extract_effects_from_type(&ty);
        assert_eq!(extracted, io_effects);
    }
}