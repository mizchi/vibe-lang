//! Component Model command handlers

use anyhow::{Context, Result};
use parser::parse;
use std::fs;
use std::path::PathBuf;
use colored::Colorize;
use wasm_backend::component::{generate_wit_interface, generate_wit_file};

use crate::ComponentCommands;

pub fn handle_component_command(cmd: ComponentCommands) -> Result<()> {
    match cmd {
        ComponentCommands::Wit { file, output } => generate_wit_command(file, output),
        ComponentCommands::Build { file, output, version } => build_component_command(file, output, version),
    }
}

fn generate_wit_command(file: PathBuf, output: Option<PathBuf>) -> Result<()> {
    // Read and parse the XS file
    let source = fs::read_to_string(&file)
        .with_context(|| format!("Failed to read file: {}", file.display()))?;
    
    let expr = parse(&source)
        .map_err(|e| anyhow::anyhow!("Parse error: {}", e))?;
    
    // Type check the entire module
    let _module_type = checker::type_check(&expr)
        .map_err(|e| anyhow::anyhow!("Type error: {}", e))?;
    
    // Extract module information
    match &expr {
        xs_core::Expr::Module { name, exports, body, .. } => {
            // For now, we'll use a simplified approach to extract types
            // In a real implementation, we'd get this from the type checker's environment
            let mut exported_types = Vec::new();
            
            // Extract types from the module body
            let mut binding_types: HashMap<String, xs_core::Type> = HashMap::new();
            use std::collections::HashMap;
            
            for expr in body {
                if let xs_core::Expr::Let { name: bind_name, value, .. } = expr {
                    // Type check the individual binding
                    if let Ok(typ) = checker::type_check(value) {
                        binding_types.insert(bind_name.0.clone(), typ);
                    }
                }
            }
            
            // Collect exported types
            for export in exports {
                if let Some(typ) = binding_types.get(&export.0) {
                    exported_types.push((export.0.clone(), typ.clone()));
                }
            }
            
            // Generate WIT interface
            let interface = generate_wit_interface(&name.0, &exported_types);
            
            // Generate WIT file content
            let package_name = format!("xs:{}", name.0.to_lowercase());
            let wit_content = generate_wit_file(&package_name, "0.1.0", &interface);
            
            // Output WIT
            if let Some(output_path) = output {
                fs::write(&output_path, wit_content)
                    .with_context(|| format!("Failed to write WIT file: {}", output_path.display()))?;
                println!("{} Generated WIT interface: {}", "✓".green(), output_path.display());
            } else {
                println!("{wit_content}");
            }
            
            Ok(())
        }
        _ => {
            Err(anyhow::anyhow!("Input file must contain a module definition"))
        }
    }
}

fn build_component_command(file: PathBuf, _output: PathBuf, _version: String) -> Result<()> {
    // Read and parse the XS file
    let source = fs::read_to_string(&file)
        .with_context(|| format!("Failed to read file: {}", file.display()))?;
    
    let expr = parse(&source)
        .map_err(|e| anyhow::anyhow!("Parse error: {}", e))?;
    
    // Type check
    let _typ = checker::type_check(&expr)
        .map_err(|e| anyhow::anyhow!("Type error: {}", e))?;
    
    // For now, just indicate that component building is not yet implemented
    eprintln!("{} Component building is not yet fully implemented", "⚠".yellow());
    eprintln!("  This feature requires wasm-tools integration.");
    eprintln!("  For now, you can:");
    eprintln!("  1. Generate WIT with: xsc component wit {}", file.display());
    eprintln!("  2. Build WASM module with standard compilation");
    eprintln!("  3. Use wasm-tools to create component manually");
    
    Ok(())
}