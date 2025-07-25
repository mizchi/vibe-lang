//! Interactive hole completion for the @ syntax
//!
//! This module provides functionality for interactively filling holes in expressions.

use anyhow::{Context, Result};
use colored::Colorize;
use rustyline::Editor;
use std::collections::HashMap;
use std::io::{self, Write};
use vibe_compiler::TypeChecker;
use vibe_language::{DoStatement, Expr, Type};

/// Information about a hole in an expression
#[derive(Debug, Clone)]
pub struct HoleInfo {
    pub name: Option<String>,
    pub expected_type: Option<Type>,
    pub context: String,
    pub suggestions: Vec<HoleSuggestion>,
}

/// A suggestion for filling a hole
#[derive(Debug, Clone)]
pub struct HoleSuggestion {
    pub value: String,
    pub type_: Type,
    pub description: Option<String>,
    pub confidence: f32, // 0.0 to 1.0
}

/// Interactive hole completer
pub struct HoleCompleter {
    type_env: HashMap<String, Type>,
    #[allow(dead_code)]
    runtime_env: vibe_language::Environment,
}

impl HoleCompleter {
    pub fn new(type_env: HashMap<String, Type>, runtime_env: vibe_language::Environment) -> Self {
        Self {
            type_env,
            runtime_env,
        }
    }

    /// Find all holes in an expression
    pub fn find_holes(&self, expr: &Expr) -> Vec<(Vec<usize>, HoleInfo)> {
        let mut holes = Vec::new();
        self.find_holes_rec(expr, &mut Vec::new(), &mut holes);
        holes
    }

    fn find_holes_rec(
        &self,
        expr: &Expr,
        path: &mut Vec<usize>,
        holes: &mut Vec<(Vec<usize>, HoleInfo)>,
    ) {
        match expr {
            Expr::Hole {
                name, type_hint, ..
            } => {
                let info = self.analyze_hole(expr, name.as_deref(), type_hint.as_ref());
                holes.push((path.clone(), info));
            }
            Expr::Block { exprs, .. } => {
                for (i, e) in exprs.iter().enumerate() {
                    path.push(i);
                    self.find_holes_rec(e, path, holes);
                    path.pop();
                }
            }
            Expr::Apply { func, args, .. } => {
                path.push(0);
                self.find_holes_rec(func, path, holes);
                path.pop();

                for (i, arg) in args.iter().enumerate() {
                    path.push(i + 1);
                    self.find_holes_rec(arg, path, holes);
                    path.pop();
                }
            }
            Expr::If {
                cond,
                then_expr,
                else_expr,
                ..
            } => {
                path.push(0);
                self.find_holes_rec(cond, path, holes);
                path.pop();

                path.push(1);
                self.find_holes_rec(then_expr, path, holes);
                path.pop();

                path.push(2);
                self.find_holes_rec(else_expr, path, holes);
                path.pop();
            }
            Expr::Let { value, .. } => {
                path.push(0);
                self.find_holes_rec(value, path, holes);
                path.pop();
            }
            Expr::LetIn { value, body, .. } => {
                path.push(0);
                self.find_holes_rec(value, path, holes);
                path.pop();

                path.push(1);
                self.find_holes_rec(body, path, holes);
                path.pop();
            }
            Expr::Lambda { body, .. } => {
                path.push(0);
                self.find_holes_rec(body, path, holes);
                path.pop();
            }
            Expr::Match {
                expr: match_expr,
                cases,
                ..
            } => {
                path.push(0);
                self.find_holes_rec(match_expr, path, holes);
                path.pop();

                for (i, (_, case_expr)) in cases.iter().enumerate() {
                    path.push(i + 1);
                    self.find_holes_rec(case_expr, path, holes);
                    path.pop();
                }
            }
            Expr::Pipeline {
                expr: lhs, func, ..
            } => {
                path.push(0);
                self.find_holes_rec(lhs, path, holes);
                path.pop();

                path.push(1);
                self.find_holes_rec(func, path, holes);
                path.pop();
            }
            Expr::Do { statements, .. } => {
                for (i, statement) in statements.iter().enumerate() {
                    path.push(i);
                    match statement {
                        DoStatement::Bind { expr, .. } => {
                            self.find_holes_rec(expr, path, holes);
                        }
                        DoStatement::Expression(expr) => {
                            self.find_holes_rec(expr, path, holes);
                        }
                    }
                    path.pop();
                }
            }
            Expr::RecordLiteral { fields, .. } => {
                for (i, (_, field_expr)) in fields.iter().enumerate() {
                    path.push(i);
                    self.find_holes_rec(field_expr, path, holes);
                    path.pop();
                }
            }
            Expr::RecordAccess { record, .. } => {
                path.push(0);
                self.find_holes_rec(record, path, holes);
                path.pop();
            }
            Expr::RecordUpdate {
                record, updates, ..
            } => {
                path.push(0);
                self.find_holes_rec(record, path, holes);
                path.pop();

                for (i, (_, update_expr)) in updates.iter().enumerate() {
                    path.push(i + 1);
                    self.find_holes_rec(update_expr, path, holes);
                    path.pop();
                }
            }
            Expr::LetRecIn { value, body, .. } => {
                path.push(0);
                self.find_holes_rec(value, path, holes);
                path.pop();
                path.push(1);
                self.find_holes_rec(body, path, holes);
                path.pop();
            }
            Expr::HandleExpr {
                expr,
                handlers,
                return_handler,
                ..
            } => {
                path.push(0);
                self.find_holes_rec(expr, path, holes);
                path.pop();

                for (i, handler) in handlers.iter().enumerate() {
                    path.push(i + 1);
                    self.find_holes_rec(&handler.body, path, holes);
                    path.pop();
                }

                if let Some((_, body)) = return_handler {
                    path.push(handlers.len() + 1);
                    self.find_holes_rec(body, path, holes);
                    path.pop();
                }
            }
            _ => {}
        }
    }

    /// Analyze a hole to gather information about it
    fn analyze_hole(&self, _expr: &Expr, name: Option<&str>, type_hint: Option<&Type>) -> HoleInfo {
        let mut suggestions = Vec::new();

        // Generate suggestions based on type hint
        if let Some(expected_type) = type_hint {
            suggestions.extend(self.suggest_values_for_type(expected_type));
        }

        // Add suggestions from environment
        for (var_name, var_type) in &self.type_env {
            if let Some(expected) = type_hint {
                if self.types_match(var_type, expected) {
                    suggestions.push(HoleSuggestion {
                        value: var_name.clone(),
                        type_: var_type.clone(),
                        description: Some(format!("Variable from environment")),
                        confidence: 0.8,
                    });
                }
            } else {
                // No type hint, suggest all variables with lower confidence
                suggestions.push(HoleSuggestion {
                    value: var_name.clone(),
                    type_: var_type.clone(),
                    description: Some(format!("Variable from environment")),
                    confidence: 0.5,
                });
            }
        }

        // Sort suggestions by confidence
        suggestions.sort_by(|a, b| b.confidence.partial_cmp(&a.confidence).unwrap());

        HoleInfo {
            name: name.map(String::from),
            expected_type: type_hint.cloned(),
            context: format!(
                "Hole{}",
                if let Some(n) = name {
                    format!(" '{}'", n)
                } else {
                    String::new()
                }
            ),
            suggestions,
        }
    }

    /// Generate value suggestions for a given type
    fn suggest_values_for_type(&self, ty: &Type) -> Vec<HoleSuggestion> {
        let mut suggestions = Vec::new();

        match ty {
            Type::Int => {
                suggestions.push(HoleSuggestion {
                    value: "0".to_string(),
                    type_: Type::Int,
                    description: Some("Zero".to_string()),
                    confidence: 0.9,
                });
                suggestions.push(HoleSuggestion {
                    value: "1".to_string(),
                    type_: Type::Int,
                    description: Some("One".to_string()),
                    confidence: 0.8,
                });
                suggestions.push(HoleSuggestion {
                    value: "42".to_string(),
                    type_: Type::Int,
                    description: Some("The answer".to_string()),
                    confidence: 0.6,
                });
            }
            Type::Bool => {
                suggestions.push(HoleSuggestion {
                    value: "true".to_string(),
                    type_: Type::Bool,
                    description: None,
                    confidence: 0.9,
                });
                suggestions.push(HoleSuggestion {
                    value: "false".to_string(),
                    type_: Type::Bool,
                    description: None,
                    confidence: 0.9,
                });
            }
            Type::String => {
                suggestions.push(HoleSuggestion {
                    value: "\"\"".to_string(),
                    type_: Type::String,
                    description: Some("Empty string".to_string()),
                    confidence: 0.8,
                });
                suggestions.push(HoleSuggestion {
                    value: "\"Hello\"".to_string(),
                    type_: Type::String,
                    description: Some("Greeting".to_string()),
                    confidence: 0.6,
                });
            }
            Type::List(elem_ty) => {
                suggestions.push(HoleSuggestion {
                    value: "[]".to_string(),
                    type_: ty.clone(),
                    description: Some("Empty list".to_string()),
                    confidence: 0.9,
                });

                // Suggest a singleton list if we can suggest the element type
                if let Some(elem_suggestions) = self.suggest_values_for_type(elem_ty).first() {
                    suggestions.push(HoleSuggestion {
                        value: format!("[{}]", elem_suggestions.value),
                        type_: ty.clone(),
                        description: Some("Singleton list".to_string()),
                        confidence: 0.7,
                    });
                }
            }
            Type::Function(_, _) => {
                // Suggest common function patterns
                suggestions.push(HoleSuggestion {
                    value: "fn x -> x".to_string(),
                    type_: ty.clone(),
                    description: Some("Identity function".to_string()),
                    confidence: 0.6,
                });
            }
            _ => {}
        }

        suggestions
    }

    /// Check if two types match (simple version)
    fn types_match(&self, t1: &Type, t2: &Type) -> bool {
        match (t1, t2) {
            (Type::Int, Type::Int) => true,
            (Type::Bool, Type::Bool) => true,
            (Type::String, Type::String) => true,
            (Type::Unit, Type::Unit) => true,
            (Type::List(a), Type::List(b)) => self.types_match(a, b),
            (Type::Function(a1, b1), Type::Function(a2, b2)) => {
                self.types_match(a1, a2) && self.types_match(b1, b2)
            }
            _ => false,
        }
    }

    /// Interactively fill holes in an expression
    pub fn fill_holes_interactive(&self, expr: &Expr) -> Result<Expr> {
        let holes = self.find_holes(expr);

        if holes.is_empty() {
            return Ok(expr.clone());
        }

        println!(
            "{}",
            format!("Found {} hole(s) to fill:", holes.len()).yellow()
        );

        let mut filled_expr = expr.clone();
        let mut rl = Editor::<()>::new()?;

        for (i, (path, hole_info)) in holes.iter().enumerate() {
            println!("\n{}", format!("Hole {} of {}:", i + 1, holes.len()).bold());
            println!("  Context: {}", hole_info.context);

            if let Some(expected_type) = &hole_info.expected_type {
                println!("  Expected type: {}", format!("{}", expected_type).cyan());
            }

            if !hole_info.suggestions.is_empty() {
                println!("\n  Suggestions:");
                for (j, suggestion) in hole_info.suggestions.iter().take(5).enumerate() {
                    let desc = suggestion
                        .description
                        .as_ref()
                        .map(|d| format!(" - {}", d))
                        .unwrap_or_default();
                    println!(
                        "    {}) {} : {}{}",
                        j + 1,
                        suggestion.value.green(),
                        format!("{}", suggestion.type_).cyan(),
                        desc.dimmed()
                    );
                }
            }

            // Get user input
            let prompt = format!(
                "? Enter value for hole{}: ",
                hole_info
                    .name
                    .as_ref()
                    .map(|n| format!(" '{}'", n))
                    .unwrap_or_default()
            );

            loop {
                let input = rl.readline(&prompt)?;

                // Try to parse the input as an expression
                match vibe_language::parser::parse(&input) {
                    Ok(hole_value) => {
                        // Type check if we have an expected type
                        if let Some(expected_type) = &hole_info.expected_type {
                            let mut checker = TypeChecker::new();
                            let mut type_env = vibe_compiler::TypeEnv::default();

                            // Add known types to environment
                            for (name, ty) in &self.type_env {
                                type_env.add_binding(
                                    name.clone(),
                                    vibe_compiler::TypeScheme::mono(ty.clone()),
                                );
                            }

                            match checker.check(&hole_value, &mut type_env) {
                                Ok(actual_type) => {
                                    if !self.types_match(&actual_type, expected_type) {
                                        eprintln!(
                                            "{}: Expected type {}, but got {}",
                                            "Type mismatch".red(),
                                            format!("{}", expected_type).cyan(),
                                            format!("{}", actual_type).cyan()
                                        );
                                        continue;
                                    }
                                }
                                Err(e) => {
                                    eprintln!("{}: {}", "Type error".red(), e);
                                    continue;
                                }
                            }
                        }

                        // Replace the hole with the value
                        filled_expr = self.replace_hole_at_path(&filled_expr, path, hole_value)?;
                        break;
                    }
                    Err(e) => {
                        eprintln!("{}: {}", "Parse error".red(), e);
                        eprintln!("Please enter a valid expression.");
                    }
                }
            }
        }

        Ok(filled_expr)
    }

    /// Replace a hole at a specific path with a value
    fn replace_hole_at_path(&self, expr: &Expr, path: &[usize], replacement: Expr) -> Result<Expr> {
        if path.is_empty() {
            return Ok(replacement);
        }

        let index = path[0];
        let rest_path = &path[1..];

        match expr {
            Expr::Block { exprs, span } => {
                let mut new_exprs = exprs.clone();
                if index < new_exprs.len() {
                    new_exprs[index] =
                        self.replace_hole_at_path(&new_exprs[index], rest_path, replacement)?;
                }
                Ok(Expr::Block {
                    exprs: new_exprs,
                    span: span.clone(),
                })
            }
            Expr::Apply { func, args, span } => {
                if index == 0 {
                    Ok(Expr::Apply {
                        func: Box::new(self.replace_hole_at_path(func, rest_path, replacement)?),
                        args: args.clone(),
                        span: span.clone(),
                    })
                } else {
                    let mut new_args = args.clone();
                    let arg_index = index - 1;
                    if arg_index < new_args.len() {
                        new_args[arg_index] = self.replace_hole_at_path(
                            &new_args[arg_index],
                            rest_path,
                            replacement,
                        )?;
                    }
                    Ok(Expr::Apply {
                        func: func.clone(),
                        args: new_args,
                        span: span.clone(),
                    })
                }
            }
            // Add more cases for other expression types as needed
            _ => Ok(expr.clone()),
        }
    }
}

/// Fill holes in an expression using a simple prompt interface
pub fn fill_holes_simple(expr: &Expr) -> Result<Expr> {
    let holes = find_all_holes(expr);

    if holes.is_empty() {
        return Ok(expr.clone());
    }

    println!(
        "{}",
        format!("Found {} hole(s) to fill:", holes.len()).yellow()
    );

    let mut filled_expr = expr.clone();

    for (i, (path, name, type_hint)) in holes.iter().enumerate() {
        let prompt = if let Some(n) = name {
            format!(
                "Enter value for hole '{}' ({}): ",
                n,
                type_hint
                    .as_ref()
                    .map(|t| format!("{}", t))
                    .unwrap_or_else(|| "any type".to_string())
            )
        } else {
            format!(
                "Enter value for hole {} ({}): ",
                i + 1,
                type_hint
                    .as_ref()
                    .map(|t| format!("{}", t))
                    .unwrap_or_else(|| "any type".to_string())
            )
        };

        print!("{}", prompt);
        io::stdout().flush()?;

        let mut input = String::new();
        io::stdin().read_line(&mut input)?;
        let input = input.trim();

        // Parse the input as an expression
        let hole_value = vibe_language::parser::parse(input)
            .with_context(|| format!("Failed to parse input for hole"))?;

        // Replace the hole
        filled_expr = replace_hole(&filled_expr, path, hole_value)?;
    }

    Ok(filled_expr)
}

/// Find all holes in an expression with their paths
fn find_all_holes(expr: &Expr) -> Vec<(Vec<usize>, Option<String>, Option<Type>)> {
    let mut holes = Vec::new();
    find_holes_recursive(expr, &mut Vec::new(), &mut holes);
    holes
}

fn find_holes_recursive(
    expr: &Expr,
    path: &mut Vec<usize>,
    holes: &mut Vec<(Vec<usize>, Option<String>, Option<Type>)>,
) {
    match expr {
        Expr::Hole {
            name, type_hint, ..
        } => {
            holes.push((path.clone(), name.clone(), type_hint.clone()));
        }
        Expr::Block { exprs, .. } => {
            for (i, e) in exprs.iter().enumerate() {
                path.push(i);
                find_holes_recursive(e, path, holes);
                path.pop();
            }
        }
        // Add more cases as needed
        _ => {}
    }
}

/// Replace a hole at a specific path
fn replace_hole(expr: &Expr, path: &[usize], replacement: Expr) -> Result<Expr> {
    if path.is_empty() {
        return Ok(replacement);
    }

    match expr {
        Expr::Block { exprs, span } => {
            let mut new_exprs = exprs.clone();
            let index = path[0];
            if index < new_exprs.len() {
                new_exprs[index] = replace_hole(&new_exprs[index], &path[1..], replacement)?;
            }
            Ok(Expr::Block {
                exprs: new_exprs,
                span: span.clone(),
            })
        }
        // Add more cases as needed
        _ => Ok(expr.clone()),
    }
}
