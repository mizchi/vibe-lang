//! Component Model commands for the XS CLI

use std::fs;
use std::path::PathBuf;
use anyhow::{Context, Result};
use colored::*;
use parser::parse;
use checker::{TypeChecker, TypeEnv, type_check};
use wasm_backend::wit_generator::WitGenerator;
use xs_core::{Expr, Type, Span};

use crate::ComponentCommands;

/// Handle component-related commands
pub fn handle_component_command(cmd: ComponentCommands) -> Result<()> {
    match cmd {
        ComponentCommands::Wit { file, output } => generate_wit(&file, output),
        ComponentCommands::Build { file, output, version } => build_component(&file, &output, &version),
    }
}

/// Generate WIT interface from XS module
fn generate_wit(file: &PathBuf, output: Option<PathBuf>) -> Result<()> {
    let source = fs::read_to_string(file)
        .with_context(|| format!("Failed to read file: {}", file.display()))?;
    
    // Parse the module
    let expr = parse(&source)
        .with_context(|| format!("Failed to parse file: {}", file.display()))?;
    
    // Extract module information
    let (_module_name, exports) = extract_module_info(&expr)?;
    
    // Type check to get export types
    let mut checker = TypeChecker::new();
    let mut type_env = TypeEnv::default();
    let export_types = type_check_exports(&mut checker, &mut type_env, &exports)?;
    
    // Generate package name from file name
    let package_name = if let Some(stem) = file.file_stem() {
        format!("xs:{}", stem.to_string_lossy())
    } else {
        "xs:module".to_string()
    };
    
    // Create WIT generator
    let mut generator = WitGenerator::new(package_name, "0.1.0".to_string());
    
    // Add exports
    for ((name, _), typ) in exports.iter().zip(export_types.iter()) {
        generator.add_export(name.clone(), typ.clone());
    }
    
    // Generate WIT content
    let wit_content = generator.generate();
    
    // Write output
    if let Some(output_path) = output {
        fs::write(&output_path, &wit_content)
            .with_context(|| format!("Failed to write WIT file: {}", output_path.display()))?;
        println!("{}: WIT interface written to {}", "Success".green(), output_path.display());
    } else {
        println!("{}", wit_content);
    }
    
    Ok(())
}

/// Build WASM component from XS module
fn build_component(file: &PathBuf, output: &PathBuf, version: &str) -> Result<()> {
    let source = fs::read_to_string(file)
        .with_context(|| format!("Failed to read file: {}", file.display()))?;
    
    // Parse the module
    let expr = parse(&source)
        .with_context(|| format!("Failed to parse file: {}", file.display()))?;
    
    // Extract module information
    let (module_name, _exports) = extract_module_info(&expr)?;
    
    // Type check the module
    let _typ = type_check(&expr)
        .with_context(|| "Type checking failed")?;
    
    // Generate WIT for the module
    let mut checker = TypeChecker::new();
    let mut type_env = TypeEnv::default();
    let (_module_name, exports) = extract_module_info(&expr)?;
    let export_types = type_check_exports(&mut checker, &mut type_env, &exports)?;
    
    let package_name = if let Some(stem) = file.file_stem() {
        format!("xs:{}", stem.to_string_lossy())
    } else {
        "xs:module".to_string()
    };
    
    let mut wit_generator = WitGenerator::new(package_name.clone(), version.to_string());
    for ((name, _), typ) in exports.iter().zip(export_types.iter()) {
        wit_generator.add_export(name.clone(), typ.clone());
    }
    let wit_content = wit_generator.generate();
    
    // Build the component using the new builder
    use wasm_backend::component_builder;
    let component_bytes = component_builder::compile_xs_to_component(
        &module_name,
        version,
        &expr,
        Some(wit_content),
    ).with_context(|| "Component building failed")?;
    
    // Write the component to file
    fs::write(output, &component_bytes)
        .with_context(|| format!("Failed to write component file: {}", output.display()))?;
    
    println!("{}: Component written to {}", "Success".green(), output.display());
    println!("  Module: {}", module_name);
    println!("  Version: {}", version);
    println!("  Size: {} bytes", component_bytes.len());
    
    Ok(())
}

/// Extract module name and exports from an expression
fn extract_module_info(expr: &Expr) -> Result<(String, Vec<(String, Expr)>)> {
    match expr {
        Expr::Module { name, exports, body, .. } => {
            let mut export_list = Vec::new();
            
            // Find exported definitions in the body
            for export_name in exports {
                if let Some(def) = find_definition_in_body_list(&export_name.0, body) {
                    export_list.push((export_name.0.clone(), def));
                } else {
                    // Export not found - return error
                    return Err(anyhow::anyhow!("Export '{}' not found in module body", export_name.0));
                }
            }
            
            Ok((name.0.clone(), export_list))
        }
        _ => {
            // If not a module, treat the whole expression as a single export
            Ok(("Main".to_string(), vec![("main".to_string(), expr.clone())]))
        }
    }
}

/// Find a definition in module body (list of expressions)
fn find_definition_in_body_list(name: &str, body: &[Expr]) -> Option<Expr> {
    for expr in body {
        match expr {
            Expr::Let { name: let_name, value, .. } => {
                if let_name.0 == name {
                    return Some((**value).clone());
                }
            }
            Expr::LetRec { name: let_name, value, .. } => {
                if let_name.0 == name {
                    return Some((**value).clone());
                }
            }
            Expr::Rec { name: rec_name, params, body, .. } => {
                if rec_name.0 == name {
                    // Convert Rec to Lambda for export
                    return Some(Expr::Lambda {
                        params: params.clone(),
                        body: body.clone(),
                        span: Span::new(0, 0),
                    });
                }
            }
            _ => {}
        }
    }
    None
}

/// Type check exports and return their types
fn type_check_exports(
    checker: &mut TypeChecker,
    type_env: &mut TypeEnv,
    exports: &[(String, Expr)]
) -> Result<Vec<Type>> {
    let mut types = Vec::new();
    
    // First pass: add rec functions to environment
    for (name, expr) in exports {
        if let Expr::Lambda { .. } = expr {
            // For lambdas converted from rec, we need to add them to env first
            // This is a simplified approach - ideally we'd do proper recursive binding
            match checker.check(expr, type_env) {
                Ok(typ) => {
                    type_env.extend(name.clone(), checker::TypeScheme::mono(typ.clone()));
                }
                Err(_) => {} // Ignore errors in first pass
            }
        }
    }
    
    // Second pass: type check all exports
    for (name, expr) in exports {
        match checker.check(expr, type_env) {
            Ok(typ) => {
                types.push(typ.clone());
                // Update environment (may override first pass)
                type_env.extend(name.clone(), checker::TypeScheme::mono(typ));
            }
            Err(e) => {
                return Err(anyhow::anyhow!("Type error in export '{}': {}", name, e));
            }
        }
    }
    
    Ok(types)
}

#[cfg(test)]
mod tests {
    use super::*;
    use xs_core::{Span, Ident};
    
    #[test]
    fn test_extract_module_info() {
        let module = Expr::Module {
            name: Ident("Math".to_string()),
            exports: vec![Ident("add".to_string())],
            body: vec![
                Expr::Let {
                    name: Ident("add".to_string()),
                    type_ann: None,
                    value: Box::new(Expr::Lambda {
                        params: vec![
                            (Ident("x".to_string()), None), 
                            (Ident("y".to_string()), None)
                        ],
                        body: Box::new(Expr::Apply {
                            func: Box::new(Expr::Ident(Ident("+".to_string()), Span::new(0, 0))),
                            args: vec![
                                Expr::Ident(Ident("x".to_string()), Span::new(0, 0)),
                                Expr::Ident(Ident("y".to_string()), Span::new(0, 0)),
                            ],
                            span: Span::new(0, 0),
                        }),
                        span: Span::new(0, 0),
                    }),
                    span: Span::new(0, 0),
                }
            ],
            span: Span::new(0, 0),
        };
        
        let (name, exports) = extract_module_info(&module).unwrap();
        assert_eq!(name, "Math");
        assert_eq!(exports.len(), 1);
        assert_eq!(exports[0].0, "add");
    }
}