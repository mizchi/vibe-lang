use std::fs;
use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use colored::*;

use parser::parse;
use checker::type_check;
use interpreter::eval;
use xs_core::{Type, Value};

#[derive(Parser)]
#[command(name = "xsc")]
#[command(author, version, about = "XS Language Compiler", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Parse a file and display the AST
    Parse {
        /// The XS file to parse
        file: PathBuf,
    },
    /// Type check a file
    Check {
        /// The XS file to check
        file: PathBuf,
    },
    /// Run a file
    Run {
        /// The XS file to run
        file: PathBuf,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Parse { file } => parse_file(&file),
        Commands::Check { file } => check_file(&file),
        Commands::Run { file } => run_file(&file),
    }
}

fn parse_file(path: &PathBuf) -> Result<()> {
    let source = fs::read_to_string(path)
        .with_context(|| format!("Failed to read file: {}", path.display()))?;

    match parse(&source) {
        Ok(expr) => {
            println!("{}", "✓ Parse successful".green());
            println!("\n{}", "AST:".bold());
            println!("{:#?}", expr);
            Ok(())
        }
        Err(e) => {
            eprintln!("{}", "✗ Parse error".red());
            eprintln!("{}", e);
            std::process::exit(1);
        }
    }
}

fn check_file(path: &PathBuf) -> Result<()> {
    let source = fs::read_to_string(path)
        .with_context(|| format!("Failed to read file: {}", path.display()))?;

    let expr = match parse(&source) {
        Ok(expr) => expr,
        Err(e) => {
            eprintln!("{}", "✗ Parse error".red());
            eprintln!("{}", e);
            std::process::exit(1);
        }
    };

    match type_check(&expr) {
        Ok(typ) => {
            println!("{}", "✓ Type check successful".green());
            println!("\n{}: {}", "Type".bold(), format_type(&typ));
            Ok(())
        }
        Err(e) => {
            eprintln!("{}", "✗ Type error".red());
            eprintln!("{}", e);
            std::process::exit(1);
        }
    }
}

fn run_file(path: &PathBuf) -> Result<()> {
    let source = fs::read_to_string(path)
        .with_context(|| format!("Failed to read file: {}", path.display()))?;

    let expr = match parse(&source) {
        Ok(expr) => expr,
        Err(e) => {
            eprintln!("{}", "✗ Parse error".red());
            eprintln!("{}", e);
            std::process::exit(1);
        }
    };

    match type_check(&expr) {
        Ok(_) => {},
        Err(e) => {
            eprintln!("{}", "✗ Type error".red());
            eprintln!("{}", e);
            std::process::exit(1);
        }
    }

    match eval(&expr) {
        Ok(value) => {
            println!("{}", "✓ Execution successful".green());
            println!("\n{}: {}", "Result".bold(), format_value(&value));
            Ok(())
        }
        Err(e) => {
            eprintln!("{}", "✗ Runtime error".red());
            eprintln!("{}", e);
            std::process::exit(1);
        }
    }
}

fn format_type(typ: &Type) -> String {
    match typ {
        Type::Int => "Int".cyan().to_string(),
        Type::Float => "Float".cyan().to_string(),
        Type::Bool => "Bool".cyan().to_string(),
        Type::String => "String".cyan().to_string(),
        Type::List(t) => format!("(List {})", format_type(t)).cyan().to_string(),
        Type::Function(from, to) => {
            format!("({} -> {})", format_type(from), format_type(to)).cyan().to_string()
        }
        Type::Var(name) => format!("'{}", name).yellow().to_string(),
        Type::UserDefined { name, type_params } => {
            if type_params.is_empty() {
                name.cyan().to_string()
            } else {
                let params = type_params.iter()
                    .map(|t| format_type(t))
                    .collect::<Vec<_>>()
                    .join(" ");
                format!("({} {})", name, params).cyan().to_string()
            }
        }
    }
}

fn format_value(value: &Value) -> String {
    match value {
        Value::Int(n) => n.to_string().blue().to_string(),
        Value::Float(f) => f.to_string().blue().to_string(),
        Value::Bool(b) => b.to_string().magenta().to_string(),
        Value::String(s) => format!("{:?}", s).green().to_string(),
        Value::List(elems) => {
            let formatted_elems: Vec<String> = elems.iter().map(format_value).collect();
            format!("(list {})", formatted_elems.join(" "))
        }
        Value::Closure { params, .. } => {
            format!("<closure:{}>", params.len()).yellow().to_string()
        }
        Value::RecClosure { name, params, .. } => {
            format!("<rec-closure:{}:{}>", name.0, params.len()).yellow().to_string()
        }
        Value::Constructor { name, values } => {
            let formatted_values: Vec<String> = values.iter().map(format_value).collect();
            if formatted_values.is_empty() {
                name.0.magenta().to_string()
            } else {
                format!("({} {})", name.0, formatted_values.join(" ")).magenta().to_string()
            }
        }
    }
}
