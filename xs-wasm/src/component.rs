//! WebAssembly Component Model support for XS language
//!
//! This module provides functionality to build WebAssembly components
//! from XS modules, enabling type-safe composition and distribution.

use crate::{CodeGenError, WasmModule};

/// Component metadata
#[derive(Debug)]
pub struct ComponentMetadata {
    pub name: String,
    pub version: String,
    pub exports: Vec<ComponentExport>,
    pub imports: Vec<ComponentImport>,
}

/// Exported interface from a component
#[derive(Debug)]
pub struct ComponentExport {
    pub name: String,
    pub interface: InterfaceDefinition,
}

/// Imported interface for a component
#[derive(Debug)]
pub struct ComponentImport {
    pub name: String,
    pub package: String,
    pub version: String,
    pub interface: InterfaceDefinition,
}

/// Interface definition (simplified WIT representation)
#[derive(Debug)]
pub struct InterfaceDefinition {
    pub functions: Vec<FunctionSignature>,
    pub types: Vec<TypeDefinition>,
}

/// Function signature in WIT
#[derive(Debug)]
pub struct FunctionSignature {
    pub name: String,
    pub params: Vec<(String, WitType)>,
    pub results: Vec<WitType>,
}

/// Type definition in WIT
#[derive(Debug)]
pub enum TypeDefinition {
    Record {
        name: String,
        fields: Vec<(String, WitType)>,
    },
    Variant {
        name: String,
        cases: Vec<(String, Option<WitType>)>,
    },
    Alias {
        name: String,
        target: WitType,
    },
}

/// WIT type representation
#[derive(Debug, Clone)]
pub enum WitType {
    Bool,
    S8,
    U8,
    S16,
    U16,
    S32,
    U32,
    S64,
    U64,
    Float32,
    Float64,
    String,
    List(Box<WitType>),
    Option(Box<WitType>),
    Result {
        ok: Option<Box<WitType>>,
        err: Option<Box<WitType>>,
    },
    Named(String),
}

/// Component builder for creating WASM components
/// This is a facade that delegates to the actual implementation
pub struct ComponentBuilder {
    inner: crate::component_builder::ComponentBuilderImpl,
}

impl ComponentBuilder {
    pub fn new(name: String, version: String) -> Self {
        let metadata = ComponentMetadata {
            name,
            version,
            exports: Vec::new(),
            imports: Vec::new(),
        };
        Self {
            inner: crate::component_builder::ComponentBuilderImpl::new(metadata),
        }
    }

    /// Add a WASM module to the component
    pub fn add_module(&mut self, name: String, module: WasmModule) {
        self.inner.add_module(name, module);
    }

    /// Add an export to the component
    pub fn add_export(&mut self, export: ComponentExport) {
        self.inner.metadata.exports.push(export);
    }

    /// Add an import to the component
    pub fn add_import(&mut self, import: ComponentImport) {
        self.inner.metadata.imports.push(import);
    }

    /// Set WIT source for the component
    pub fn with_wit_source(mut self, wit: String) -> Self {
        self.inner = self.inner.with_wit_source(wit);
        self
    }

    /// Build the component using the actual implementation
    pub fn build(self) -> Result<Vec<u8>, CodeGenError> {
        self.inner.build()
    }
}

/// Convert XS type to WIT type
pub fn xs_type_to_wit(xs_type: &xs_core::Type) -> WitType {
    use xs_core::Type;

    match xs_type {
        Type::Int => WitType::S64,
        Type::Float => WitType::Float64,
        Type::Bool => WitType::Bool,
        Type::String => WitType::String,
        Type::List(inner) => WitType::List(Box::new(xs_type_to_wit(inner))),
        Type::Function(_, _) | Type::FunctionWithEffect { .. } => {
            // Functions are handled separately in interfaces
            WitType::String // Placeholder
        }
        Type::Var(_) => WitType::String, // Type variables need special handling
        Type::UserDefined { .. } => WitType::String, // ADTs need special handling
    }
}

/// Generate WIT interface from XS module exports
pub fn generate_wit_interface(
    _module_name: &str,
    exports: &[(String, xs_core::Type)],
) -> InterfaceDefinition {
    let mut functions = Vec::new();

    for (name, typ) in exports {
        if let Some(sig) = extract_function_signature(typ) {
            functions.push(FunctionSignature {
                name: name.clone(),
                params: sig.0,
                results: sig.1,
            });
        }
    }

    InterfaceDefinition {
        functions,
        types: Vec::new(), // TODO: Extract type definitions
    }
}

/// Extract function signature from XS type, handling curried functions
fn extract_function_signature(
    typ: &xs_core::Type,
) -> Option<(Vec<(String, WitType)>, Vec<WitType>)> {
    use xs_core::Type;

    let mut params = Vec::new();
    let mut current_type = typ;
    let mut param_count = 0;

    // Unwrap curried functions
    loop {
        match current_type {
            Type::Function(param_type, result_type)
            | Type::FunctionWithEffect {
                from: param_type,
                to: result_type,
                ..
            } => {
                // Check if the result is another function (curried)
                match result_type.as_ref() {
                    Type::Function(..) | Type::FunctionWithEffect { .. } => {
                        // This is a curried function, add parameter and continue
                        param_count += 1;
                        params.push((format!("arg{param_count}"), xs_type_to_wit(param_type)));
                        current_type = result_type;
                    }
                    _ => {
                        // This is the final result
                        param_count += 1;
                        params.push((format!("arg{param_count}"), xs_type_to_wit(param_type)));
                        let results = vec![xs_type_to_wit(result_type)];
                        return Some((params, results));
                    }
                }
            }
            _ => {
                // Not a function
                return None;
            }
        }
    }
}

/// Generate WIT file content from interface definition
pub fn generate_wit_file(
    package_name: &str,
    version: &str,
    interface: &InterfaceDefinition,
) -> String {
    let mut wit = String::new();

    // Package declaration
    wit.push_str(&format!("package {package_name}@{version};\n\n"));

    // Interface declaration
    wit.push_str("interface exports {\n");

    // Type definitions
    for type_def in &interface.types {
        match type_def {
            TypeDefinition::Record { name, fields } => {
                wit.push_str(&format!("  record {name} {{\n"));
                for (field_name, field_type) in fields {
                    wit.push_str(&format!(
                        "    {}: {},\n",
                        field_name,
                        wit_type_to_string(field_type)
                    ));
                }
                wit.push_str("  }\n\n");
            }
            TypeDefinition::Variant { name, cases } => {
                wit.push_str(&format!("  variant {name} {{\n"));
                for (case_name, case_type) in cases {
                    if let Some(typ) = case_type {
                        wit.push_str(&format!(
                            "    {}({}),\n",
                            case_name,
                            wit_type_to_string(typ)
                        ));
                    } else {
                        wit.push_str(&format!("    {case_name},\n"));
                    }
                }
                wit.push_str("  }\n\n");
            }
            TypeDefinition::Alias { name, target } => {
                wit.push_str(&format!(
                    "  type {} = {};\n\n",
                    name,
                    wit_type_to_string(target)
                ));
            }
        }
    }

    // Function signatures
    for func in &interface.functions {
        wit.push_str(&format!("  {}: func(", func.name));

        // Parameters
        let params: Vec<String> = func
            .params
            .iter()
            .map(|(name, typ)| format!("{}: {}", name, wit_type_to_string(typ)))
            .collect();
        wit.push_str(&params.join(", "));

        wit.push(')');

        // Results
        if !func.results.is_empty() {
            wit.push_str(" -> ");
            if func.results.len() == 1 {
                wit.push_str(&wit_type_to_string(&func.results[0]));
            } else {
                let results: Vec<String> = func.results.iter().map(wit_type_to_string).collect();
                wit.push_str(&format!("({})", results.join(", ")));
            }
        }

        wit.push_str(";\n");
    }

    wit.push_str("}\n\n");

    // World declaration
    wit.push_str(&format!("world {package_name} {{\n"));
    wit.push_str("  export exports;\n");
    wit.push_str("}\n");

    wit
}

/// Convert WIT type to string representation
fn wit_type_to_string(typ: &WitType) -> String {
    match typ {
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
        WitType::List(inner) => format!("list<{}>", wit_type_to_string(inner)),
        WitType::Option(inner) => format!("option<{}>", wit_type_to_string(inner)),
        WitType::Result { ok, err } => {
            let ok_str = ok
                .as_ref()
                .map(|t| wit_type_to_string(t))
                .unwrap_or_else(|| "_".to_string());
            let err_str = err
                .as_ref()
                .map(|t| wit_type_to_string(t))
                .unwrap_or_else(|| "_".to_string());
            format!("result<{ok_str}, {err_str}>")
        }
        WitType::Named(name) => name.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_wit_type_conversion() {
        assert_eq!(wit_type_to_string(&WitType::Bool), "bool");
        assert_eq!(wit_type_to_string(&WitType::S64), "s64");
        assert_eq!(wit_type_to_string(&WitType::String), "string");
        assert_eq!(
            wit_type_to_string(&WitType::List(Box::new(WitType::S32))),
            "list<s32>"
        );
        assert_eq!(
            wit_type_to_string(&WitType::Option(Box::new(WitType::String))),
            "option<string>"
        );
    }

    #[test]
    fn test_wit_generation() {
        let interface = InterfaceDefinition {
            functions: vec![
                FunctionSignature {
                    name: "add".to_string(),
                    params: vec![
                        ("a".to_string(), WitType::S64),
                        ("b".to_string(), WitType::S64),
                    ],
                    results: vec![WitType::S64],
                },
                FunctionSignature {
                    name: "concat".to_string(),
                    params: vec![
                        ("s1".to_string(), WitType::String),
                        ("s2".to_string(), WitType::String),
                    ],
                    results: vec![WitType::String],
                },
            ],
            types: vec![],
        };

        let wit = generate_wit_file("xs:math", "0.1.0", &interface);

        assert!(wit.contains("package xs:math@0.1.0;"));
        assert!(wit.contains("add: func(a: s64, b: s64) -> s64;"));
        assert!(wit.contains("concat: func(s1: string, s2: string) -> string;"));
        assert!(wit.contains("world xs:math"));
    }
}
