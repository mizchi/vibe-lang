use std::collections::{HashMap, HashSet};
use crate::Type;

impl Type {
    pub fn free_vars(&self) -> HashSet<String> {
        match self {
            Type::Int | Type::Bool | Type::String => HashSet::new(),
            Type::List(t) => t.free_vars(),
            Type::Function(from, to) => {
                let mut vars = from.free_vars();
                vars.extend(to.free_vars());
                vars
            }
            Type::Var(v) => {
                let mut vars = HashSet::new();
                vars.insert(v.clone());
                vars
            }
        }
    }

    pub fn apply_subst(&self, subst: &HashMap<String, Type>) -> Type {
        match self {
            Type::Int | Type::Bool | Type::String => self.clone(),
            Type::List(t) => Type::List(Box::new(t.apply_subst(subst))),
            Type::Function(from, to) => Type::Function(
                Box::new(from.apply_subst(subst)),
                Box::new(to.apply_subst(subst)),
            ),
            Type::Var(v) => subst.get(v).cloned().unwrap_or_else(|| self.clone()),
        }
    }
}