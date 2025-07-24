//! Effect System for Vibe Language
//!
//! This module defines the effect types and operations for tracking
//! side effects at the type level.

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::fmt;

/// Represents a single effect
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum Effect {
    /// Pure computation with no side effects
    Pure,
    /// Input/Output operations
    IO,
    /// State manipulation (simplified without type parameter for now)
    State,
    /// Error that can be thrown (simplified without type parameter for now)
    Error,
    /// Asynchronous computation
    Async,
    /// Network access
    Network,
    /// File system access
    FileSystem,
    /// Random number generation
    Random,
    /// Time operations
    Time,
    /// Logging
    Log,
}

impl fmt::Display for Effect {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Effect::Pure => write!(f, "Pure"),
            Effect::IO => write!(f, "IO"),
            Effect::State => write!(f, "State"),
            Effect::Error => write!(f, "Error"),
            Effect::Async => write!(f, "Async"),
            Effect::Network => write!(f, "Network"),
            Effect::FileSystem => write!(f, "FileSystem"),
            Effect::Random => write!(f, "Random"),
            Effect::Time => write!(f, "Time"),
            Effect::Log => write!(f, "Log"),
        }
    }
}

/// A set of effects
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct EffectSet {
    effects: BTreeSet<Effect>,
}

impl EffectSet {
    /// Create an empty effect set (pure)
    pub fn pure() -> Self {
        let mut effects = BTreeSet::new();
        effects.insert(Effect::Pure);
        EffectSet { effects }
    }

    /// Create an effect set with a single effect
    pub fn single(effect: Effect) -> Self {
        let mut effects = BTreeSet::new();
        effects.insert(effect);
        EffectSet { effects }
    }

    /// Create an effect set from multiple effects
    pub fn from_effects(effects: Vec<Effect>) -> Self {
        let effects = effects.into_iter().collect();
        EffectSet { effects }
    }

    /// Check if this is a pure effect set
    pub fn is_pure(&self) -> bool {
        self.effects.len() == 1 && self.effects.contains(&Effect::Pure)
    }

    /// Add an effect to the set
    pub fn add(&mut self, effect: Effect) {
        // If adding a non-pure effect, remove Pure
        if effect != Effect::Pure && self.effects.contains(&Effect::Pure) {
            self.effects.remove(&Effect::Pure);
        }
        self.effects.insert(effect);
    }

    /// Union of two effect sets
    pub fn union(&self, other: &EffectSet) -> EffectSet {
        let mut result = self.clone();
        for effect in &other.effects {
            result.add(effect.clone());
        }
        result
    }

    /// Check if this effect set is a subset of another
    pub fn is_subset_of(&self, other: &EffectSet) -> bool {
        self.effects.is_subset(&other.effects)
    }

    /// Get iterator over effects
    pub fn iter(&self) -> impl Iterator<Item = &Effect> {
        self.effects.iter()
    }

    /// Check if effect set contains a specific effect
    pub fn contains(&self, effect: &Effect) -> bool {
        self.effects.contains(effect)
    }

    /// Compute the difference of two effect sets
    pub fn difference(&self, other: &EffectSet) -> EffectSet {
        let diff: BTreeSet<Effect> = self.effects.difference(&other.effects).cloned().collect();
        if diff.is_empty() {
            EffectSet::pure()
        } else {
            EffectSet { effects: diff }
        }
    }

    /// Try to compute the difference, returns None if other is not a subset
    pub fn try_difference(&self, other: &EffectSet) -> Option<EffectSet> {
        if other.is_subset_of(self) {
            Some(self.difference(other))
        } else {
            None
        }
    }
}

impl fmt::Display for EffectSet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.is_pure() {
            write!(f, "Pure")
        } else {
            let effects: Vec<String> = self.effects.iter()
                .filter(|e| **e != Effect::Pure)  // Skip Pure in mixed sets
                .map(|e| e.to_string())
                .collect();
            
            if effects.len() == 1 {
                // Single effect: IO instead of {IO}
                write!(f, "{}", effects[0])
            } else {
                // Multiple effects: {IO, State}
                write!(f, "{{")?;
                write!(f, "{}", effects.join(", "))?;
                write!(f, "}}")
            }
        }
    }
}

/// Effect variables for polymorphic effects
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct EffectVar(pub String);

impl fmt::Display for EffectVar {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Effect row - either concrete effects or a variable
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum EffectRow {
    Concrete(EffectSet),
    Variable(EffectVar),
    /// Extension: concrete effects + effect variable (for row polymorphism)
    Extension(EffectSet, EffectVar),
}

impl EffectRow {
    pub fn pure() -> Self {
        EffectRow::Concrete(EffectSet::pure())
    }

    pub fn is_pure(&self) -> bool {
        match self {
            EffectRow::Concrete(set) => set.is_pure(),
            EffectRow::Variable(_) => false,
            EffectRow::Extension(_set, _) => false, // Extension is never pure
        }
    }
}

impl fmt::Display for EffectRow {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EffectRow::Concrete(set) => write!(f, "{set}"),
            EffectRow::Variable(var) => write!(f, "{var}"),
            EffectRow::Extension(set, var) => write!(f, "{set} | {var}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pure_effect_set() {
        let pure = EffectSet::pure();
        assert!(pure.is_pure());
        assert!(pure.contains(&Effect::Pure));
    }

    #[test]
    fn test_effect_set_union() {
        let mut set1 = EffectSet::pure();
        set1.add(Effect::IO);

        let mut set2 = EffectSet::pure();
        set2.add(Effect::Network);

        let union = set1.union(&set2);
        assert!(!union.is_pure());
        assert!(union.contains(&Effect::IO));
        assert!(union.contains(&Effect::Network));
        assert!(!union.contains(&Effect::Pure));
    }

    #[test]
    fn test_effect_display() {
        let pure = EffectSet::pure();
        assert_eq!(pure.to_string(), "Pure");

        let mut effects = EffectSet::pure();
        effects.add(Effect::IO);
        effects.add(Effect::Error);
        assert!(effects.to_string().contains("IO"));
        assert!(effects.to_string().contains("Error"));
    }
}
