//! Component Model commands for the XS CLI

use anyhow::{Context, Result};
use colored::*;
use std::fs;
use std::path::PathBuf;
use vibe_compiler::wasm::wit_generator::WitGenerator;
use vibe_compiler::{type_check, TypeChecker, TypeEnv};
use vibe_core::parser::parse;
use vibe_core::{Expr, Span, Type};

use crate::cli::ComponentCommand;

/// Handle component-related commands
pub fn handle_component_command(cmd: ComponentCommand) -> Result<()> {
    match cmd {
        ComponentCommand::Build {
            input,
            output,
            wit,
            optimize,
        } => build_component(&input, output, wit, optimize),
        ComponentCommand::GenerateWit { input, output } => generate_wit(&input, output),
        ComponentCommand::Run { input, args } => run_component(&input, args),
    }
}

/// Generate WIT interface from XS module
fn generate_wit(file: &PathBuf, output: Option<PathBuf>) -> Result<()> {
    let source = fs::read_to_string(file)
        .with_context(|| format!("Failed to read file: {}", file.display()))?;

    // Parse the module
    let expr =
        parse(&source).with_context(|| format!("Failed to parse file: {}", file.display()))?;

    // Extract module information
    let (_module_name, exports) = extract_module_info(&expr)?;

    // Type check the module and extract export types
    let export_types = extract_export_types(&expr)?;

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
        println!(
            "{}: WIT interface written to {}",
            "Success".green(),
            output_path.display()
        );
    } else {
        println!("{wit_content}");
    }

    Ok(())
}

/// Build WASM component from XS module
#[allow(dead_code)]
fn _build_component_old(file: &PathBuf, output: &PathBuf, version: &str) -> Result<()> {
    let source = fs::read_to_string(file)
        .with_context(|| format!("Failed to read file: {}", file.display()))?;

    // Parse the module
    let expr =
        parse(&source).with_context(|| format!("Failed to parse file: {}", file.display()))?;

    // Extract module information
    let (module_name, _exports) = extract_module_info(&expr)?;

    // Type check the module
    let _typ = type_check(&expr).with_context(|| "Type checking failed")?;

    // Generate WIT for the module
    // Instead of re-type-checking exports, extract types from the already type-checked module
    let export_types = extract_export_types(&expr)?;

    let package_name = if let Some(stem) = file.file_stem() {
        format!("xs:{}", stem.to_string_lossy())
    } else {
        "xs:module".to_string()
    };

    // Re-extract module information to ensure correct order
    let (_module_name, exports) = extract_module_info(&expr)?;

    let mut wit_generator = WitGenerator::new(package_name.clone(), version.to_string());
    for ((name, _), typ) in exports.iter().zip(export_types.iter()) {
        wit_generator.add_export(name.clone(), typ.clone());
    }
    let wit_content = wit_generator.generate();

    // Build the component using the new builder
    use vibe_compiler::wasm::component_builder;
    let component_bytes =
        component_builder::compile_xs_to_component(&module_name, version, &expr, Some(wit_content))
            .with_context(|| "Component building failed")?;

    // Write the component to file
    fs::write(output, &component_bytes)
        .with_context(|| format!("Failed to write component file: {}", output.display()))?;

    println!(
        "{}: Component written to {}",
        "Success".green(),
        output.display()
    );
    println!("  Module: {module_name}");
    println!("  Version: {version}");
    println!("  Size: {} bytes", component_bytes.len());

    Ok(())
}

/// Extract module name and exports from an expression
fn extract_module_info(expr: &Expr) -> Result<(String, Vec<(String, Expr)>)> {
    match expr {
        Expr::Module {
            name,
            exports,
            body,
            ..
        } => {
            let mut export_list = Vec::new();

            // Find exported definitions in the body
            for export_name in exports {
                if let Some(def) = find_definition_in_body_list(&export_name.0, body) {
                    export_list.push((export_name.0.clone(), def));
                } else {
                    // Export not found - return error
                    return Err(anyhow::anyhow!(
                        "Export '{}' not found in module body",
                        export_name.0
                    ));
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
            Expr::Let {
                name: let_name,
                value,
                ..
            } => {
                if let_name.0 == name {
                    return Some((**value).clone());
                }
            }
            Expr::LetRec {
                name: let_name,
                value,
                ..
            } => {
                if let_name.0 == name {
                    return Some((**value).clone());
                }
            }
            Expr::Rec {
                name: rec_name,
                params,
                body,
                ..
            } => {
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

/// Extract export types from a type-checked module
fn extract_export_types(expr: &Expr) -> Result<Vec<Type>> {
    match expr {
        Expr::Module { exports, body, .. } => {
            // Type check the module body to get the types
            let mut checker = TypeChecker::new();
            let mut type_env = TypeEnv::default();

            // Type check the body expressions
            for body_expr in body {
                match body_expr {
                    Expr::Let { name, value, .. } => {
                        let typ = checker
                            .check(value, &mut type_env)
                            .map_err(|e| anyhow::anyhow!("Type error: {:?}", e))?;
                        let scheme = vibe_compiler::TypeScheme::mono(typ);
                        type_env.add_binding(name.0.clone(), scheme);
                    }
                    Expr::Rec {
                        name,
                        params,
                        body: rec_body,
                        ..
                    } => {
                        // Handle rec functions properly
                        type_env.push_scope();

                        // Add self-reference with a type variable
                        let rec_type_var = Type::Var(format!("rec_{}", name.0));
                        type_env.add_binding(
                            name.0.clone(),
                            vibe_compiler::TypeScheme::mono(rec_type_var.clone()),
                        );

                        // Add parameters
                        let mut param_types = Vec::new();
                        for (param, param_type) in params {
                            let param_t = param_type
                                .clone()
                                .unwrap_or_else(|| Type::Var(format!("t{}", param.0)));
                            type_env.add_binding(
                                param.0.clone(),
                                vibe_compiler::TypeScheme::mono(param_t.clone()),
                            );
                            param_types.push(param_t);
                        }

                        // Type check body
                        let body_type = checker
                            .check(rec_body, &mut type_env)
                            .map_err(|e| anyhow::anyhow!("Type error: {:?}", e))?;
                        type_env.pop_scope();

                        // Build function type
                        let func_type =
                            param_types.into_iter().rev().fold(body_type, |acc, param| {
                                Type::Function(Box::new(param), Box::new(acc))
                            });

                        // Store the type
                        let scheme = vibe_compiler::TypeScheme::mono(func_type);
                        type_env.add_binding(name.0.clone(), scheme);
                    }
                    Expr::TypeDef { .. } => {
                        // Skip type definitions for now
                    }
                    _ => {
                        // Skip other expressions
                        checker
                            .check(body_expr, &mut type_env)
                            .map_err(|e| anyhow::anyhow!("Type error: {:?}", e))?;
                    }
                }
            }

            // Now extract types for exports
            let mut export_types = Vec::new();
            for export_name in exports {
                if let Some(scheme) = type_env.lookup(&export_name.0) {
                    // Extract type from type scheme
                    export_types.push(scheme.typ.clone());
                } else {
                    return Err(anyhow::anyhow!(
                        "Export '{}' not found in module",
                        export_name.0
                    ));
                }
            }

            Ok(export_types)
        }
        _ => Err(anyhow::anyhow!("Not a module expression")),
    }
}

/// Type check exports and return their types (legacy function kept for reference)
fn _type_check_exports(
    checker: &mut TypeChecker,
    type_env: &mut TypeEnv,
    exports: &[(String, Expr)],
) -> Result<Vec<Type>> {
    let mut types = Vec::new();

    // First pass: add rec functions to environment
    for (name, expr) in exports {
        if let Expr::Lambda { .. } = expr {
            // For lambdas converted from rec, we need to add them to env first
            // This is a simplified approach - ideally we'd do proper recursive binding
            match checker.check(expr, type_env) {
                Ok(typ) => {
                    type_env
                        .add_binding(name.clone(), vibe_compiler::TypeScheme::mono(typ.clone()));
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
                type_env.add_binding(name.clone(), vibe_compiler::TypeScheme::mono(typ));
            }
            Err(e) => {
                return Err(anyhow::anyhow!("Type error in export '{}': {}", name, e));
            }
        }
    }

    Ok(types)
}

/// Build WebAssembly component from XS source
fn build_component(
    input: &PathBuf,
    _output: Option<PathBuf>,
    wit: Option<PathBuf>,
    optimize: bool,
) -> Result<()> {
    let source = fs::read_to_string(input)
        .with_context(|| format!("Failed to read file: {}", input.display()))?;

    // Parse the module
    let expr = parse(&source)?;

    // Type check
    let _ = type_check(&expr)?;

    println!(
        "{}: Component building not yet implemented",
        "Note".yellow()
    );
    println!(
        "Would build {} with optimization: {}",
        input.display(),
        optimize
    );
    if let Some(wit) = wit {
        println!("Using WIT interface: {}", wit.display());
    }

    Ok(())
}

/// Run WebAssembly component
fn run_component(input: &PathBuf, args: Vec<String>) -> Result<()> {
    println!("{}: Component running not yet implemented", "Note".yellow());
    println!("Would run {} with args: {:?}", input.display(), args);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use vibe_core::{Ident, Span};

    #[test]
    fn test_extract_module_info() {
        let module = Expr::Module {
            name: Ident("Math".to_string()),
            exports: vec![Ident("add".to_string())],
            body: vec![Expr::Let {
                name: Ident("add".to_string()),
                type_ann: None,
                value: Box::new(Expr::Lambda {
                    params: vec![
                        (Ident("x".to_string()), None),
                        (Ident("y".to_string()), None),
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
            }],
            span: Span::new(0, 0),
        };

        let (name, exports) = extract_module_info(&module).unwrap();
        assert_eq!(name, "Math");
        assert_eq!(exports.len(), 1);
        assert_eq!(exports[0].0, "add");
    }
}
