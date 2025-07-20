//! Builtin modules for organizing standard library functions
//!
//! This module provides namespace organization for builtin functions,
//! allowing them to be accessed as Int.toString, String.concat, etc.

use crate::{Type, TypeDefinition};
use std::collections::HashMap;

/// Represents a builtin module with its functions
#[derive(Debug, Clone)]
pub struct BuiltinModule {
    pub name: String,
    pub functions: HashMap<String, Type>,
}

impl BuiltinModule {
    pub fn new(name: &str) -> Self {
        Self {
            name: name.to_string(),
            functions: HashMap::new(),
        }
    }

    pub fn add_function(&mut self, name: &str, typ: Type) {
        self.functions.insert(name.to_string(), typ);
    }
}

/// Registry of all builtin modules
pub struct BuiltinModuleRegistry {
    modules: HashMap<String, BuiltinModule>,
}

impl BuiltinModuleRegistry {
    pub fn new() -> Self {
        let mut registry = Self {
            modules: HashMap::new(),
        };
        registry.init_modules();
        registry
    }

    fn init_modules(&mut self) {
        // Int module
        let mut int_module = BuiltinModule::new("Int");
        int_module.add_function(
            "add",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
            ),
        );
        int_module.add_function(
            "sub",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
            ),
        );
        int_module.add_function(
            "mul",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
            ),
        );
        int_module.add_function(
            "div",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
            ),
        );
        int_module.add_function(
            "mod",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
            ),
        );
        int_module.add_function(
            "toString",
            Type::Function(Box::new(Type::Int), Box::new(Type::String)),
        );
        int_module.add_function(
            "fromString",
            Type::Function(Box::new(Type::String), Box::new(Type::Int)),
        );
        int_module.add_function(
            "lt",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool))),
            ),
        );
        int_module.add_function(
            "gt",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool))),
            ),
        );
        int_module.add_function(
            "lte",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool))),
            ),
        );
        int_module.add_function(
            "gte",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool))),
            ),
        );
        int_module.add_function(
            "eq",
            Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool))),
            ),
        );
        self.modules.insert("Int".to_string(), int_module);

        // String module
        let mut string_module = BuiltinModule::new("String");
        string_module.add_function(
            "concat",
            Type::Function(
                Box::new(Type::String),
                Box::new(Type::Function(Box::new(Type::String), Box::new(Type::String))),
            ),
        );
        string_module.add_function(
            "length",
            Type::Function(Box::new(Type::String), Box::new(Type::Int)),
        );
        string_module.add_function(
            "toInt",
            Type::Function(Box::new(Type::String), Box::new(Type::Int)),
        );
        string_module.add_function(
            "fromInt",
            Type::Function(Box::new(Type::Int), Box::new(Type::String)),
        );
        self.modules.insert("String".to_string(), string_module);

        // List module
        let mut list_module = BuiltinModule::new("List");
        // List.cons : a -> List a -> List a
        list_module.add_function(
            "cons",
            Type::Function(
                Box::new(Type::Var("a".to_string())),
                Box::new(Type::Function(
                    Box::new(Type::List(Box::new(Type::Var("a".to_string())))),
                    Box::new(Type::List(Box::new(Type::Var("a".to_string())))),
                )),
            ),
        );
        self.modules.insert("List".to_string(), list_module);

        // IO module
        let mut io_module = BuiltinModule::new("IO");
        io_module.add_function(
            "print",
            Type::Function(
                Box::new(Type::Var("a".to_string())),
                Box::new(Type::Var("a".to_string())),
            ),
        );
        self.modules.insert("IO".to_string(), io_module);

        // Float module
        let mut float_module = BuiltinModule::new("Float");
        float_module.add_function(
            "add",
            Type::Function(
                Box::new(Type::Float),
                Box::new(Type::Function(Box::new(Type::Float), Box::new(Type::Float))),
            ),
        );
        self.modules.insert("Float".to_string(), float_module);
    }

    pub fn get_module(&self, name: &str) -> Option<&BuiltinModule> {
        self.modules.get(name)
    }

    pub fn get_function_type(&self, module_name: &str, function_name: &str) -> Option<&Type> {
        self.modules
            .get(module_name)
            .and_then(|module| module.functions.get(function_name))
    }

    pub fn all_modules(&self) -> &HashMap<String, BuiltinModule> {
        &self.modules
    }
}

impl Default for BuiltinModuleRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_builtin_modules() {
        let registry = BuiltinModuleRegistry::new();
        
        // Test Int module
        assert!(registry.get_module("Int").is_some());
        assert!(registry.get_function_type("Int", "toString").is_some());
        assert!(registry.get_function_type("Int", "add").is_some());
        
        // Test String module
        assert!(registry.get_module("String").is_some());
        assert!(registry.get_function_type("String", "concat").is_some());
        assert!(registry.get_function_type("String", "length").is_some());
        
        // Test non-existent module
        assert!(registry.get_module("NonExistent").is_none());
        assert!(registry.get_function_type("Int", "nonExistent").is_none());
    }
}