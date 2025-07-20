//! WIT (WebAssembly Interface Types) generator from XS modules
//!
//! This module converts XS module definitions to WIT format,
//! enabling WebAssembly Component Model integration.

use std::collections::HashMap;
use std::fmt::Write;
use xs_core::{Type, TypeDefinition};
use crate::component::{WitType, xs_type_to_wit};

/// WIT generator for XS modules
pub struct WitGenerator {
    package_name: String,
    version: String,
    types: HashMap<String, TypeDefinition>,
    exports: Vec<(String, Type)>,
}

impl WitGenerator {
    /// Create a new WIT generator
    pub fn new(package_name: String, version: String) -> Self {
        Self {
            package_name,
            version,
            types: HashMap::new(),
            exports: Vec::new(),
        }
    }

    /// Add a type definition
    pub fn add_type_definition(&mut self, name: String, typ_def: TypeDefinition) {
        self.types.insert(name, typ_def);
    }

    /// Add an exported function
    pub fn add_export(&mut self, name: String, typ: Type) {
        self.exports.push((name, typ));
    }

    /// Generate WIT file content
    pub fn generate(&self) -> String {
        let mut wit = String::new();
        
        // Package declaration
        writeln!(&mut wit, "package {}@{};", self.package_name, self.version).unwrap();
        writeln!(&mut wit).unwrap();
        
        // Generate type definitions
        if !self.types.is_empty() {
            writeln!(&mut wit, "interface types {{").unwrap();
            for (name, typ_def) in &self.types {
                let wit_type = self.generate_type_definition(name, typ_def);
                writeln!(&mut wit, "  {}", wit_type).unwrap();
            }
            writeln!(&mut wit, "}}").unwrap();
            writeln!(&mut wit).unwrap();
        }
        
        // Generate exports interface
        writeln!(&mut wit, "interface exports {{").unwrap();
        for (name, typ) in &self.exports {
            if let Some(func_sig) = self.generate_function_signature(name, typ) {
                writeln!(&mut wit, "  {};", func_sig).unwrap();
            }
        }
        writeln!(&mut wit, "}}").unwrap();
        writeln!(&mut wit).unwrap();
        
        // Generate world
        let world_name = self.package_name.split(':').last().unwrap_or(&self.package_name);
        writeln!(&mut wit, "world {} {{", world_name).unwrap();
        writeln!(&mut wit, "  export exports;").unwrap();
        if !self.types.is_empty() {
            writeln!(&mut wit, "  export types;").unwrap();
        }
        writeln!(&mut wit, "}}").unwrap();
        
        wit
    }
    
    /// Generate type definition for WIT
    fn generate_type_definition(&self, name: &str, typ_def: &TypeDefinition) -> String {
        self.generate_variant_type(name, typ_def)
    }
    
    /// Generate variant type for ADTs
    fn generate_variant_type(&self, name: &str, typ_def: &TypeDefinition) -> String {
        let mut wit = format!("variant {} {{", to_wit_identifier(name));
        
        for constructor in &typ_def.constructors {
            write!(&mut wit, "\n    {}", to_wit_identifier(&constructor.name)).unwrap();
            
            if !constructor.fields.is_empty() {
                write!(&mut wit, "(").unwrap();
                let field_types: Vec<String> = constructor.fields.iter()
                    .map(|field| wit_type_string(&xs_type_to_wit(field)))
                    .collect();
                write!(&mut wit, "{}", field_types.join(", ")).unwrap();
                write!(&mut wit, ")").unwrap();
            }
            
            write!(&mut wit, ",").unwrap();
        }
        
        write!(&mut wit, "\n  }}").unwrap();
        wit
    }
    
    /// Generate function signature for WIT
    fn generate_function_signature(&self, name: &str, typ: &Type) -> Option<String> {
        let (params, result) = self.extract_function_parts(typ)?;
        
        let mut sig = format!("{}: func(", to_wit_identifier(name));
        
        // Add parameters
        let param_strs: Vec<String> = params.iter().enumerate()
            .map(|(i, param_type)| format!("arg{}: {}", i + 1, wit_type_string(&xs_type_to_wit(param_type))))
            .collect();
        sig.push_str(&param_strs.join(", "));
        sig.push(')');
        
        // Add result
        match &result {
            Type::UserDefined { name, .. } if name == "Unit" => {
                // No return value for Unit type
            }
            _ => {
                sig.push_str(" -> ");
                sig.push_str(&wit_type_string(&xs_type_to_wit(&result)));
            }
        }
        
        Some(sig)
    }
    
    /// Extract parameters and result from potentially curried function
    fn extract_function_parts(&self, typ: &Type) -> Option<(Vec<Type>, Type)> {
        let mut params = Vec::new();
        let mut current_type = typ;
        
        loop {
            match current_type {
                Type::Function(param, result) | 
                Type::FunctionWithEffect { from: param, to: result, .. } => {
                    params.push((**param).clone());
                    
                    // Check if result is another function
                    match result.as_ref() {
                        Type::Function(..) | Type::FunctionWithEffect { .. } => {
                            current_type = result;
                        }
                        _ => {
                            return Some((params, (**result).clone()));
                        }
                    }
                }
                _ => return None,
            }
        }
    }
}

/// Convert WIT type to string representation
fn wit_type_string(wit_type: &WitType) -> String {
    match wit_type {
        WitType::Bool => "bool".to_string(),
        WitType::S8 => "s8".to_string(),
        WitType::U8 => "u8".to_string(),
        WitType::S16 => "s16".to_string(),
        WitType::U16 => "u16".to_string(),
        WitType::S32 => "s32".to_string(),
        WitType::U32 => "u32".to_string(),
        WitType::S64 => "s64".to_string(),
        WitType::U64 => "u64".to_string(),
        WitType::Float32 => "float32".to_string(),
        WitType::Float64 => "float64".to_string(),
        WitType::String => "string".to_string(),
        WitType::List(inner) => format!("list<{}>", wit_type_string(inner)),
        WitType::Option(inner) => format!("option<{}>", wit_type_string(inner)),
        WitType::Result { ok, err } => {
            let ok_str = ok.as_ref()
                .map(|t| wit_type_string(t))
                .unwrap_or_else(|| "_".to_string());
            let err_str = err.as_ref()
                .map(|t| wit_type_string(t))
                .unwrap_or_else(|| "_".to_string());
            format!("result<{}, {}>", ok_str, err_str)
        }
        WitType::Named(name) => to_wit_identifier(name),
    }
}

/// Convert XS identifier to WIT-compatible identifier
fn to_wit_identifier(name: &str) -> String {
    // WIT identifiers must be kebab-case
    name.chars()
        .map(|c| if c == '_' { '-' } else { c.to_ascii_lowercase() })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_generate_simple_module() {
        let mut gen = WitGenerator::new("xs:math".to_string(), "0.1.0".to_string());
        
        // Add function: (fn (x y) (+ x y))
        let add_type = Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Int)
            ))
        );
        gen.add_export("add".to_string(), add_type);
        
        let wit = gen.generate();
        assert!(wit.contains("package xs:math@0.1.0;"));
        assert!(wit.contains("add: func(arg1: s64, arg2: s64) -> s64;"));
        assert!(wit.contains("world math {"));
        assert!(wit.contains("export exports;"));
    }
    
    #[test]
    fn test_generate_with_types() {
        use xs_core::Constructor;
        
        let mut gen = WitGenerator::new("xs:data".to_string(), "0.1.0".to_string());
        
        // Add Option type definition
        let option_type_def = TypeDefinition {
            name: "Option".to_string(),
            type_params: vec!["a".to_string()],
            constructors: vec![
                Constructor {
                    name: "None".to_string(),
                    fields: vec![],
                },
                Constructor {
                    name: "Some".to_string(),
                    fields: vec![Type::Var("a".to_string())],
                },
            ],
        };
        gen.add_type_definition("Option".to_string(), option_type_def);
        
        let wit = gen.generate();
        assert!(wit.contains("variant option {"));
        assert!(wit.contains("none,"));
        assert!(wit.contains("some(string),"));
    }
}