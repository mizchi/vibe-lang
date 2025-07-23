//! Enhanced store implementation that processes multiple definitions from a file

use anyhow::Result;
use std::path::Path;
use xs_core::{Expr, parser::parse};
use xs_compiler::type_check;
use xs_workspace::Codebase;

/// Extract individual definitions from a parsed expression
pub fn extract_definitions(expr: &Expr) -> Vec<(String, Expr)> {
    let mut definitions = Vec::new();
    extract_definitions_recursive(expr, &mut definitions);
    definitions
}

fn extract_definitions_recursive(expr: &Expr, definitions: &mut Vec<(String, Expr)>) {
    match expr {
        // Top-level let binding
        Expr::Let { name, value, .. } => {
            definitions.push((name.0.clone(), *value.clone()));
        }
        
        // Top-level recursive function
        Expr::Rec { name, params, body, span, .. } => {
            // Convert rec to a recursive closure expression
            let rec_expr = Expr::Rec {
                name: name.clone(),
                params: params.clone(),
                return_type: None,
                body: body.clone(),
                span: span.clone(),
            };
            definitions.push((name.0.clone(), rec_expr));
        }
        
        // Module with multiple definitions
        Expr::Module { body, .. } => {
            // Process each expression in the module body
            for expr in body {
                extract_definitions_recursive(expr, definitions);
            }
        }
        
        // List of expressions (common pattern for multiple definitions)
        Expr::List(exprs, _) => {
            for expr in exprs {
                extract_definitions_recursive(expr, definitions);
            }
        }
        
        // Apply expression might be a sequence of lets
        Expr::Apply { func, args, .. } => {
            // Check if this is a let sequence pattern
            extract_definitions_recursive(func, definitions);
            for arg in args {
                extract_definitions_recursive(arg, definitions);
            }
        }
        
        _ => {
            // Other expression types are not top-level definitions
        }
    }
}

/// Store multiple definitions from a file into a codebase
pub fn store_file_with_multiple_defs(file_path: &Path, codebase: &mut Codebase) -> Result<usize> {
    let content = std::fs::read_to_string(file_path)?;
    
    // Try to parse as a sequence of expressions
    let lines: Vec<&str> = content.lines()
        .filter(|line| !line.trim().is_empty() && !line.trim().starts_with(';'))
        .collect();
    
    let mut count = 0;
    
    // Process each non-empty, non-comment line as a potential definition
    for line in lines {
        // Skip if line doesn't start with '('
        if !line.trim().starts_with('(') {
            continue;
        }
        
        match parse(line) {
            Ok(expr) => {
                let defs = extract_definitions(&expr);
                for (name, def_expr) in defs {
                    match type_check(&def_expr) {
                        Ok(ty) => {
                            codebase.add_term(Some(name.clone()), def_expr, ty)?;
                            count += 1;
                            println!("  Added: {}", name);
                        }
                        Err(e) => {
                            eprintln!("  Type error for {}: {}", name, e);
                        }
                    }
                }
            }
            Err(e) => {
                // Try parsing as part of a larger expression
                eprintln!("  Parse error: {}", e);
            }
        }
    }
    
    Ok(count)
}