//! Effect System for XS Language
//!
//! This module provides types and utilities for tracking side effects
//! at the type level, enabling pure functional programming with controlled effects.

use std::collections::HashSet;
use std::fmt;

/// Effect represents a side effect that a function may perform
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Effect {
    /// Input/Output operations (console, files)
    IO,
    /// Network operations (HTTP, sockets)
    Network,
    /// File system operations (read, write, delete)
    FileSystem,
    /// Environment variable access
    Env,
    /// Process operations (spawn, kill)
    Process,
    /// Random number generation
    Random,
    /// Current time access
    Time,
    /// Mutable state operations
    State(String), // Named state effect
    /// Custom effect
    Custom(String),
}

impl fmt::Display for Effect {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Effect::IO => write!(f, "IO"),
            Effect::Network => write!(f, "Network"),
            Effect::FileSystem => write!(f, "FileSystem"),
            Effect::Env => write!(f, "Env"),
            Effect::Process => write!(f, "Process"),
            Effect::Random => write!(f, "Random"),
            Effect::Time => write!(f, "Time"),
            Effect::State(name) => write!(f, "State({})", name),
            Effect::Custom(name) => write!(f, "{}", name),
        }
    }
}

/// A set of effects that a function may perform
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EffectSet {
    effects: HashSet<Effect>,
}

impl EffectSet {
    /// Create an empty effect set (pure function)
    pub fn pure() -> Self {
        Self {
            effects: HashSet::new(),
        }
    }

    /// Create an effect set with a single effect
    pub fn single(effect: Effect) -> Self {
        let mut effects = HashSet::new();
        effects.insert(effect);
        Self { effects }
    }

    /// Create an effect set from multiple effects
    pub fn from_effects(effects: Vec<Effect>) -> Self {
        Self {
            effects: effects.into_iter().collect(),
        }
    }

    /// Check if the effect set is pure (no effects)
    pub fn is_pure(&self) -> bool {
        self.effects.is_empty()
    }

    /// Add an effect to the set
    pub fn add(&mut self, effect: Effect) {
        self.effects.insert(effect);
    }

    /// Union two effect sets
    pub fn union(&self, other: &EffectSet) -> EffectSet {
        Self {
            effects: self.effects.union(&other.effects).cloned().collect(),
        }
    }

    /// Check if this effect set is a subset of another
    pub fn is_subset_of(&self, other: &EffectSet) -> bool {
        self.effects.is_subset(&other.effects)
    }

    /// Get the effects as a vector
    pub fn to_vec(&self) -> Vec<Effect> {
        self.effects.iter().cloned().collect()
    }

    /// Check if the set contains a specific effect
    pub fn contains(&self, effect: &Effect) -> bool {
        self.effects.contains(effect)
    }

    /// Get the number of effects
    pub fn len(&self) -> usize {
        self.effects.len()
    }

    /// Check if the set is empty
    pub fn is_empty(&self) -> bool {
        self.effects.is_empty()
    }
}

impl fmt::Display for EffectSet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.is_pure() {
            write!(f, "Pure")
        } else {
            write!(f, "{{")?;
            let effects: Vec<_> = self.effects.iter().collect();
            for (i, effect) in effects.iter().enumerate() {
                if i > 0 {
                    write!(f, ", ")?;
                }
                write!(f, "{}", effect)?;
            }
            write!(f, "}}")
        }
    }
}

/// Effect handler trait for interpreting effects
pub trait EffectHandler<T> {
    /// Handle an effectful operation
    fn handle(&mut self, effect: &Effect, operation: EffectOperation) -> Result<T, String>;
}

/// Operations that can be performed with effects
#[derive(Debug, Clone)]
pub enum EffectOperation {
    /// Print to console
    Print(String),
    /// Read from console
    ReadLine,
    /// Read file
    ReadFile(String),
    /// Write file
    WriteFile(String, String),
    /// HTTP GET request
    HttpGet(String),
    /// Get environment variable
    GetEnv(String),
    /// Get current time
    GetTime,
    /// Generate random number
    Random,
    /// Custom operation
    Custom(String, Vec<String>),
}

/// Effect annotation in the type system
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EffectfulType {
    /// The base type
    pub base_type: crate::Type,
    /// The effects this computation may perform
    pub effects: EffectSet,
}

impl EffectfulType {
    /// Create a pure type (no effects)
    pub fn pure(base_type: crate::Type) -> Self {
        Self {
            base_type,
            effects: EffectSet::pure(),
        }
    }

    /// Create an effectful type
    pub fn effectful(base_type: crate::Type, effects: EffectSet) -> Self {
        Self { base_type, effects }
    }
}

impl fmt::Display for EffectfulType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.effects.is_pure() {
            write!(f, "{}", self.base_type)
        } else {
            write!(f, "{} {}", self.effects, self.base_type)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pure_effect_set() {
        let effects = EffectSet::pure();
        assert!(effects.is_pure());
        assert_eq!(effects.len(), 0);
    }

    #[test]
    fn test_single_effect() {
        let effects = EffectSet::single(Effect::IO);
        assert!(!effects.is_pure());
        assert_eq!(effects.len(), 1);
        assert!(effects.contains(&Effect::IO));
    }

    #[test]
    fn test_effect_union() {
        let effects1 = EffectSet::single(Effect::IO);
        let effects2 = EffectSet::single(Effect::Network);
        let union = effects1.union(&effects2);
        
        assert_eq!(union.len(), 2);
        assert!(union.contains(&Effect::IO));
        assert!(union.contains(&Effect::Network));
    }

    #[test]
    fn test_effect_subset() {
        let effects1 = EffectSet::single(Effect::IO);
        let effects2 = EffectSet::from_effects(vec![Effect::IO, Effect::Network]);
        
        assert!(effects1.is_subset_of(&effects2));
        assert!(!effects2.is_subset_of(&effects1));
    }

    #[test]
    fn test_effect_display() {
        let pure = EffectSet::pure();
        assert_eq!(pure.to_string(), "Pure");
        
        let io = EffectSet::single(Effect::IO);
        assert_eq!(io.to_string(), "{IO}");
        
        let multi = EffectSet::from_effects(vec![Effect::IO, Effect::Network]);
        // Note: HashSet order is not guaranteed, so we just check it contains both
        let display = multi.to_string();
        assert!(display.contains("IO"));
        assert!(display.contains("Network"));
    }
}