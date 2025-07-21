//! Built-in functions with their effect signatures

use crate::{Effect, EffectRow, EffectSet, Type};
use std::collections::HashMap;

/// Effect signature for built-in functions
pub struct BuiltinEffects {
    effects: HashMap<String, (Type, EffectRow)>,
}

impl BuiltinEffects {
    pub fn new() -> Self {
        let mut effects = HashMap::new();

        // IO functions
        effects.insert(
            "print".to_string(),
            (
                Type::Function(
                    Box::new(Type::String),
                    Box::new(Type::UserDefined {
                        name: "Unit".to_string(),
                        type_params: vec![],
                    }),
                ),
                EffectRow::Concrete(EffectSet::single(Effect::IO)),
            ),
        );

        effects.insert(
            "read-line".to_string(),
            (
                Type::Function(
                    Box::new(Type::UserDefined {
                        name: "Unit".to_string(),
                        type_params: vec![],
                    }),
                    Box::new(Type::String),
                ),
                EffectRow::Concrete(EffectSet::single(Effect::IO)),
            ),
        );

        effects.insert(
            "read-file".to_string(),
            (
                Type::Function(Box::new(Type::String), Box::new(Type::String)),
                EffectRow::Concrete(EffectSet::single(Effect::FileSystem)),
            ),
        );

        effects.insert(
            "write-file".to_string(),
            (
                Type::Function(
                    Box::new(Type::String),
                    Box::new(Type::Function(
                        Box::new(Type::String),
                        Box::new(Type::UserDefined {
                            name: "Unit".to_string(),
                            type_params: vec![],
                        }),
                    )),
                ),
                EffectRow::Concrete(EffectSet::single(Effect::FileSystem)),
            ),
        );

        // State functions (simplified without refs)
        effects.insert(
            "get-state".to_string(),
            (
                Type::Function(
                    Box::new(Type::UserDefined {
                        name: "Unit".to_string(),
                        type_params: vec![],
                    }),
                    Box::new(Type::Var("a".to_string())),
                ),
                EffectRow::Concrete(EffectSet::single(Effect::State)),
            ),
        );

        effects.insert(
            "set-state".to_string(),
            (
                Type::Function(
                    Box::new(Type::Var("a".to_string())),
                    Box::new(Type::UserDefined {
                        name: "Unit".to_string(),
                        type_params: vec![],
                    }),
                ),
                EffectRow::Concrete(EffectSet::single(Effect::State)),
            ),
        );

        // Error functions
        effects.insert(
            "error".to_string(),
            (
                Type::Function(Box::new(Type::String), Box::new(Type::Var("a".to_string()))),
                EffectRow::Concrete(EffectSet::single(Effect::Error)),
            ),
        );

        effects.insert(
            "try".to_string(),
            (
                Type::Function(
                    Box::new(Type::Function(
                        Box::new(Type::UserDefined {
                            name: "Unit".to_string(),
                            type_params: vec![],
                        }),
                        Box::new(Type::Var("a".to_string())),
                    )),
                    Box::new(Type::Function(
                        Box::new(Type::Function(
                            Box::new(Type::String),
                            Box::new(Type::Var("a".to_string())),
                        )),
                        Box::new(Type::Var("a".to_string())),
                    )),
                ),
                EffectRow::Concrete(EffectSet::single(Effect::Error)),
            ),
        );

        // Time functions
        effects.insert(
            "current-time".to_string(),
            (
                Type::Function(
                    Box::new(Type::UserDefined {
                        name: "Unit".to_string(),
                        type_params: vec![],
                    }),
                    Box::new(Type::Int),
                ),
                EffectRow::Concrete(EffectSet::single(Effect::Time)),
            ),
        );

        // Random functions
        effects.insert(
            "random".to_string(),
            (
                Type::Function(
                    Box::new(Type::UserDefined {
                        name: "Unit".to_string(),
                        type_params: vec![],
                    }),
                    Box::new(Type::Float),
                ),
                EffectRow::Concrete(EffectSet::single(Effect::Random)),
            ),
        );

        // Log functions
        effects.insert(
            "log".to_string(),
            (
                Type::Function(
                    Box::new(Type::String),
                    Box::new(Type::UserDefined {
                        name: "Unit".to_string(),
                        type_params: vec![],
                    }),
                ),
                EffectRow::Concrete(EffectSet::single(Effect::Log)),
            ),
        );

        // Network functions
        effects.insert(
            "http-get".to_string(),
            (
                Type::Function(Box::new(Type::String), Box::new(Type::String)),
                EffectRow::Concrete(EffectSet::single(Effect::Network)),
            ),
        );

        BuiltinEffects { effects }
    }

    pub fn get(&self, name: &str) -> Option<&(Type, EffectRow)> {
        self.effects.get(name)
    }

    pub fn get_effect(&self, name: &str) -> Option<&EffectRow> {
        self.effects.get(name).map(|(_, eff)| eff)
    }

    pub fn get_type(&self, name: &str) -> Option<&Type> {
        self.effects.get(name).map(|(ty, _)| ty)
    }
}

impl Default for BuiltinEffects {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_builtin_effects() {
        let builtins = BuiltinEffects::new();

        // Check IO effect
        let print_eff = builtins.get_effect("print").unwrap();
        match print_eff {
            EffectRow::Concrete(set) => {
                assert!(set.contains(&Effect::IO));
            }
            _ => panic!("Expected concrete effect"),
        }

        // Check FileSystem effect
        let read_file_eff = builtins.get_effect("read-file").unwrap();
        match read_file_eff {
            EffectRow::Concrete(set) => {
                assert!(set.contains(&Effect::FileSystem));
            }
            _ => panic!("Expected concrete effect"),
        }
    }
}
