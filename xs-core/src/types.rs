use crate::Type;
use std::collections::{HashMap, HashSet};

impl Type {
    pub fn free_vars(&self) -> HashSet<String> {
        match self {
            Type::Int | Type::Float | Type::Bool | Type::String => HashSet::new(),
            Type::List(t) => t.free_vars(),
            Type::Function(from, to) => {
                let mut vars = from.free_vars();
                vars.extend(to.free_vars());
                vars
            }
            Type::FunctionWithEffect { from, to, .. } => {
                let mut vars = from.free_vars();
                vars.extend(to.free_vars());
                vars
            }
            Type::Var(v) => {
                let mut vars = HashSet::new();
                vars.insert(v.clone());
                vars
            }
            Type::UserDefined { type_params, .. } => {
                let mut vars = HashSet::new();
                for param in type_params {
                    vars.extend(param.free_vars());
                }
                vars
            }
            Type::Record { fields } => {
                let mut vars = HashSet::new();
                for (_, ty) in fields {
                    vars.extend(ty.free_vars());
                }
                vars
            }
        }
    }

    pub fn apply_subst(&self, subst: &HashMap<String, Type>) -> Type {
        match self {
            Type::Int | Type::Float | Type::Bool | Type::String => self.clone(),
            Type::List(t) => Type::List(Box::new(t.apply_subst(subst))),
            Type::Function(from, to) => Type::Function(
                Box::new(from.apply_subst(subst)),
                Box::new(to.apply_subst(subst)),
            ),
            Type::FunctionWithEffect { from, to, effects } => Type::FunctionWithEffect {
                from: Box::new(from.apply_subst(subst)),
                to: Box::new(to.apply_subst(subst)),
                effects: effects.clone(), // TODO: effect substitution
            },
            Type::Var(v) => subst.get(v).cloned().unwrap_or_else(|| self.clone()),
            Type::UserDefined { name, type_params } => Type::UserDefined {
                name: name.clone(),
                type_params: type_params.iter().map(|t| t.apply_subst(subst)).collect(),
            },
            Type::Record { fields } => Type::Record {
                fields: fields.iter()
                    .map(|(name, ty)| (name.clone(), ty.apply_subst(subst)))
                    .collect(),
            },
        }
    }
}
