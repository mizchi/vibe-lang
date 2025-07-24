//! Module environment for managing module imports and exports

use crate::TypeScheme;
use std::collections::HashMap;
#[cfg(test)]
use vibe_core::Type;
use vibe_core::TypeDefinition;

/// Information about an exported item from a module
#[derive(Debug, Clone)]
pub struct ExportedItem {
    pub name: String,
    pub type_scheme: TypeScheme,
}

/// Module information including exports and type definitions
#[derive(Debug, Clone)]
pub struct ModuleInfo {
    pub name: String,
    pub exports: HashMap<String, ExportedItem>,
    pub type_definitions: HashMap<String, TypeDefinition>,
}

impl ModuleInfo {
    pub fn new(name: String) -> Self {
        Self {
            name,
            exports: HashMap::new(),
            type_definitions: HashMap::new(),
        }
    }

    pub fn add_export(&mut self, name: String, type_scheme: TypeScheme) {
        self.exports
            .insert(name.clone(), ExportedItem { name, type_scheme });
    }

    pub fn add_type_definition(&mut self, name: String, definition: TypeDefinition) {
        self.type_definitions.insert(name, definition);
    }

    pub fn get_export(&self, name: &str) -> Option<&ExportedItem> {
        self.exports.get(name)
    }

    pub fn is_exported(&self, name: &str) -> bool {
        self.exports.contains_key(name)
    }
}

/// Module environment for managing multiple modules
#[derive(Debug, Default)]
pub struct ModuleEnv {
    /// Map from module name to module info
    modules: HashMap<String, ModuleInfo>,
    /// Map from alias to actual module name (for import as)
    aliases: HashMap<String, String>,
}

impl ModuleEnv {
    pub fn new() -> Self {
        let mut env = Self::default();
        env.register_builtin_modules();
        env
    }

    fn register_builtin_modules(&mut self) {
        use vibe_core::builtin_modules::BuiltinModuleRegistry;

        let registry = BuiltinModuleRegistry::new();

        for (module_name, builtin_module) in registry.all_modules() {
            let mut module_info = ModuleInfo::new(module_name.clone());

            for (func_name, func_type) in &builtin_module.functions {
                module_info.add_export(func_name.clone(), TypeScheme::mono(func_type.clone()));
            }

            self.register_module(module_info);
        }
    }

    pub fn register_module(&mut self, module: ModuleInfo) {
        self.modules.insert(module.name.clone(), module);
    }

    pub fn add_alias(&mut self, alias: String, module_name: String) {
        self.aliases.insert(alias, module_name);
    }

    pub fn resolve_module(&self, name: &str) -> Option<&ModuleInfo> {
        // First check if it's an alias
        if let Some(actual_name) = self.aliases.get(name) {
            self.modules.get(actual_name)
        } else {
            self.modules.get(name)
        }
    }

    pub fn resolve_qualified_name(&self, module_name: &str, item_name: &str) -> Option<TypeScheme> {
        self.resolve_module(module_name)
            .and_then(|module| module.get_export(item_name))
            .map(|item| item.type_scheme.clone())
    }

    pub fn get_all_modules(&self) -> Vec<&ModuleInfo> {
        self.modules.values().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_module_info() {
        let mut module = ModuleInfo::new("Math".to_string());

        // Add an export
        let add_type = Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
        );
        module.add_export("add".to_string(), TypeScheme::mono(add_type));

        // Check export
        assert!(module.is_exported("add"));
        assert!(!module.is_exported("sub"));

        let export = module.get_export("add").unwrap();
        assert_eq!(export.name, "add");
    }

    #[test]
    fn test_module_env() {
        let mut env = ModuleEnv::new();

        // Create and register a module
        let mut math_module = ModuleInfo::new("Math".to_string());
        let pi_type = Type::Float;
        math_module.add_export("PI".to_string(), TypeScheme::mono(pi_type));

        env.register_module(math_module);

        // Test resolution
        let module = env.resolve_module("Math").unwrap();
        assert_eq!(module.name, "Math");

        // Test qualified name resolution
        let pi_scheme = env.resolve_qualified_name("Math", "PI").unwrap();
        assert_eq!(pi_scheme.typ, Type::Float);

        // Test alias
        env.add_alias("M".to_string(), "Math".to_string());
        let module_via_alias = env.resolve_module("M").unwrap();
        assert_eq!(module_via_alias.name, "Math");
    }
}
