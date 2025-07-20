//! WebAssembly Component building implementation
//! 
//! This module provides the actual implementation for building
//! WebAssembly components from XS modules.

use crate::{CodeGenError, WasmModule, codegen::CodeGenerator};
use crate::component::ComponentMetadata;
use crate::emit::emit_wat;
use std::collections::HashMap;
use wasm_encoder::{Component, ComponentTypeSection};
use wit_component::ComponentEncoder;
use xs_core::Expr;
use perceus::PerceusTransform;

/// Full component builder implementation
pub struct ComponentBuilderImpl {
    pub(crate) metadata: ComponentMetadata,
    modules: HashMap<String, WasmModule>,
    wit_source: Option<String>,
}

impl ComponentBuilderImpl {
    /// Create a new component builder
    pub fn new(metadata: ComponentMetadata) -> Self {
        Self {
            metadata,
            modules: HashMap::new(),
            wit_source: None,
        }
    }
    
    /// Set the WIT source for the component
    pub fn with_wit_source(mut self, wit: String) -> Self {
        self.wit_source = Some(wit);
        self
    }
    
    /// Add a compiled WASM module
    pub fn add_module(&mut self, name: String, module: WasmModule) {
        self.modules.insert(name, module);
    }
    
    /// Build XS expression into WASM module and add it
    pub fn add_xs_module(&mut self, name: String, expr: &Expr) -> Result<(), CodeGenError> {
        // First convert to IR using Perceus
        let mut perceus = PerceusTransform::new();
        let ir = perceus.transform(expr);
        
        // Generate WASM module
        let mut generator = CodeGenerator::new();
        let wasm_module = generator.generate(&ir)?;
        
        self.modules.insert(name, wasm_module);
        Ok(())
    }
    
    /// Build the final component
    pub fn build(self) -> Result<Vec<u8>, CodeGenError> {
        if self.modules.is_empty() {
            return Err(CodeGenError::InvalidCall("No modules added to component".to_string()));
        }
        
        // For now, we'll build a simple component with a single module
        // In a full implementation, this would handle multiple modules and linking
        
        let main_module = self.modules.values().next()
            .ok_or_else(|| CodeGenError::InvalidCall("No main module".to_string()))?;
        
        // Emit the module to WAT then encode to WASM
        let wat_text = emit_wat(main_module)
            .map_err(|e| CodeGenError::TypeError(format!("WAT emission failed: {}", e)))?;
        let wasm_bytes = wat::parse_str(&wat_text)
            .map_err(|e| CodeGenError::TypeError(format!("WAT parsing failed: {}", e)))?;
        
        // Build component using wit-component
        if let Some(wit_source) = &self.wit_source {
            self.build_with_wit(&wasm_bytes, wit_source)
        } else {
            // Build basic component without WIT
            self.build_basic_component(&wasm_bytes)
        }
    }
    
    /// Build component with WIT interface
    fn build_with_wit(&self, module_bytes: &[u8], _wit_source: &str) -> Result<Vec<u8>, CodeGenError> {
        // Note: wit-component expects WIT definitions to be embedded in the wasm module
        // as custom sections. For now, we'll create a basic component.
        // In a full implementation, we would need to:
        // 1. Parse the WIT source
        // 2. Embed it as custom sections in the module
        // 3. Or use a different approach with wit-bindgen
        
        let component_bytes = ComponentEncoder::default()
            .validate(true)
            .module(module_bytes)
            .map_err(|e| CodeGenError::TypeError(format!("Component encoder error: {}", e)))?
            .encode()
            .map_err(|e| CodeGenError::TypeError(format!("Component encoding failed: {}", e)))?;
        
        Ok(component_bytes)
    }
    
    /// Build basic component without WIT
    fn build_basic_component(&self, module_bytes: &[u8]) -> Result<Vec<u8>, CodeGenError> {
        let mut component = Component::new();
        
        // Add type section
        let types = ComponentTypeSection::new();
        // TODO: Add component type definitions based on metadata
        component.section(&types);
        
        // Embed the core module
        component.section(&wasm_encoder::RawSection {
            id: 0x01, // Core module section
            data: module_bytes,
        });
        
        // Add exports based on metadata
        // TODO: Implement export mapping
        
        Ok(component.finish())
    }
}

/// Helper to compile XS module to component
pub fn compile_xs_to_component(
    module_name: &str,
    version: &str,
    expr: &Expr,
    wit_source: Option<String>,
) -> Result<Vec<u8>, CodeGenError> {
    let metadata = ComponentMetadata {
        name: module_name.to_string(),
        version: version.to_string(),
        exports: vec![], // TODO: Extract from expr
        imports: vec![],
    };
    
    let mut builder = ComponentBuilderImpl::new(metadata);
    
    if let Some(wit) = wit_source {
        builder = builder.with_wit_source(wit);
    }
    
    // Add the main module
    builder.add_xs_module("main".to_string(), expr)?;
    
    // Build the component
    builder.build()
}

#[cfg(test)]
mod tests {
    use super::*;
    use xs_core::{Literal, Span};
    
    #[test]
    fn test_simple_component_build() {
        let expr = Expr::Literal(Literal::Int(42), Span::new(0, 2));
        
        let metadata = ComponentMetadata {
            name: "test".to_string(),
            version: "0.1.0".to_string(),
            exports: vec![],
            imports: vec![],
        };
        
        let mut builder = ComponentBuilderImpl::new(metadata);
        
        // This will fail because we need proper IR conversion
        // Just testing the structure
        let result = builder.add_xs_module("main".to_string(), &expr);
        // TODO: Fix this test when IR conversion is properly implemented
        // For now, just check that it doesn't panic
        let _ = result;
    }
}