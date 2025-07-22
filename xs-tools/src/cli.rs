//! Command-line interface for XS language

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use colored::*;
use std::fs;
use std::path::PathBuf;

use xs_compiler::type_check;
use xs_core::parser::parse;
use xs_core::{Type, Value};
use xs_test::TestSuite;
use crate::permission_cli::PermissionArgs;

#[derive(Parser)]
#[command(name = "xsc")]
#[command(author, version, about = "XS Language Compiler", long_about = None)]
pub struct Args {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand)]
pub enum Command {
    /// Parse a file and display the AST
    Parse {
        /// The XS file to parse
        file: PathBuf,
    },
    /// Type check a file
    Check {
        /// The XS file to type check
        file: PathBuf,
    },
    /// Run a file
    Run {
        /// The XS file to run
        file: PathBuf,
        
        #[command(flatten)]
        permissions: PermissionArgs,
    },
    /// Run tests in a file
    Test {
        /// The XS file containing tests
        file: PathBuf,
        /// Run all tests including those marked as ignored
        #[arg(long)]
        all: bool,
        /// Show test output even for passing tests
        #[arg(long)]
        verbose: bool,
    },
    /// Run a benchmark
    Bench {
        /// The XS file to benchmark
        file: PathBuf,
        /// Number of iterations
        #[arg(short = 'n', long, default_value = "100")]
        iterations: u32,
    },
    /// Generate WebAssembly Component from XS module
    Component {
        #[command(subcommand)]
        command: ComponentCommand,
    },
}

#[derive(Subcommand)]
pub enum ComponentCommand {
    /// Build a WebAssembly component from XS source
    Build {
        /// XS source file
        input: PathBuf,
        /// Output WASM file
        #[arg(short, long)]
        output: Option<PathBuf>,
        /// WIT interface file
        #[arg(short, long)]
        wit: Option<PathBuf>,
        /// Enable optimization
        #[arg(short = 'O', long)]
        optimize: bool,
    },
    /// Generate WIT interface from XS module
    GenerateWit {
        /// XS module file
        input: PathBuf,
        /// Output WIT file
        #[arg(short, long)]
        output: Option<PathBuf>,
    },
    /// Run a WebAssembly component
    Run {
        /// WASM component file
        input: PathBuf,
        /// Arguments to pass to the component
        args: Vec<String>,
    },
}

pub fn run_cli() -> Result<()> {
    let args = Args::parse();

    match args.command {
        Command::Parse { file } => {
            let source = fs::read_to_string(&file)
                .with_context(|| format!("Failed to read file: {}", file.display()))?;

            match parse(&source) {
                Ok(expr) => {
                    println!("{}", "Parse successful!".green());
                    println!("{:#?}", expr);
                }
                Err(e) => {
                    eprintln!("{}: {}", "Parse error".red(), e);
                    std::process::exit(1);
                }
            }
        }

        Command::Check { file } => {
            let source = fs::read_to_string(&file)
                .with_context(|| format!("Failed to read file: {}", file.display()))?;

            match parse(&source) {
                Ok(expr) => match type_check(&expr) {
                    Ok(ty) => {
                        println!("{}", "Type check successful!".green());
                        println!("Type: {}", format_type(&ty));
                    }
                    Err(e) => {
                        eprintln!("{}: {}", "Type error".red(), e);
                        std::process::exit(1);
                    }
                },
                Err(e) => {
                    eprintln!("{}: {}", "Parse error".red(), e);
                    std::process::exit(1);
                }
            }
        }

        Command::Run { file, permissions } => {
            let source = fs::read_to_string(&file)
                .with_context(|| format!("Failed to read file: {}", file.display()))?;

            // Parse and type check to get effects
            match parse(&source) {
                Ok(expr) => {
                    // Type check to get effect information
                    let ty = match type_check(&expr) {
                        Ok(ty) => ty,
                        Err(e) => {
                            eprintln!("{}: {}", "Type error".red(), e);
                            std::process::exit(1);
                        }
                    };
                    
                    // Extract effects from type
                    let effects = xs_core::effect_extraction::extract_all_possible_effects(&ty);
                    
                    // Create permission config
                    let config = permissions.to_config();
                    
                    // Get required permissions from effects
                    let required_permissions = xs_core::permission::PermissionSet::from_effects(&effects);
                    
                    // Print permission summary if not allow-all
                    if !permissions.allow_all && !permissions.deny_all && !effects.is_pure() {
                        permissions.print_summary(&config);
                        
                        // Show required permissions
                        if !required_permissions.is_empty() {
                            println!("\n{}", "Required permissions:".bold());
                            for perm in required_permissions.iter() {
                                println!("  - {}", perm);
                            }
                        }
                        println!();
                    }
                    
                    // Run with permission checks
                    match xs_runtime::runtime_with_permissions::eval_with_permission_check(
                        &expr,
                        &xs_runtime::Interpreter::create_initial_env(),
                        config,
                    ) {
                        Ok(value) => {
                            println!("{}", format_value(&value));
                        }
                        Err(e) => {
                            eprintln!("{}: {}", "Runtime error".red(), e);
                            std::process::exit(1);
                        }
                    }
                }
                Err(e) => {
                    eprintln!("{}: {}", "Parse error".red(), e);
                    std::process::exit(1);
                }
            }
        }

        Command::Test {
            file,
            all: _all,
            verbose,
        } => {
            let source = fs::read_to_string(&file)
                .with_context(|| format!("Failed to read file: {}", file.display()))?;

            match parse(&source) {
                Ok(_expr) => {
                    let mut suite = TestSuite::new(verbose);
                    suite.load_test_file(&file)?;
                    let summary = suite.run_all();

                    if summary.failed > 0 {
                        std::process::exit(1);
                    }
                }
                Err(e) => {
                    eprintln!("{}: {}", "Parse error".red(), e);
                    std::process::exit(1);
                }
            }
        }

        Command::Bench { file, iterations } => {
            let source = fs::read_to_string(&file)
                .with_context(|| format!("Failed to read file: {}", file.display()))?;

            match parse(&source) {
                Ok(expr) => {
                    println!("Running benchmark with {} iterations...", iterations);

                    let start = std::time::Instant::now();
                    for _ in 0..iterations {
                        let _ = xs_runtime::eval(&expr);
                    }
                    let duration = start.elapsed();

                    let avg_time = duration / iterations;
                    println!("Average time: {:?}", avg_time);
                    println!("Total time: {:?}", duration);
                }
                Err(e) => {
                    eprintln!("{}: {}", "Parse error".red(), e);
                    std::process::exit(1);
                }
            }
        }

        Command::Component { command } => {
            crate::component_commands::handle_component_command(command)?;
        }
    }

    Ok(())
}

fn format_type(ty: &Type) -> String {
    format!("{}", ty).cyan().to_string()
}

fn format_value(val: &Value) -> String {
    match val {
        Value::Int(n) => n.to_string(),
        Value::Float(f) => f.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::String(s) => format!("\"{}\"", s),
        Value::List(_) => {
            // Use the Display implementation which formats as (list ...)
            val.to_string()
        }
        Value::Closure { .. } => "<closure>".to_string(),
        Value::RecClosure { .. } => "<rec-closure>".to_string(),
        Value::BuiltinFunction { name, .. } => format!("<builtin:{}>", name),
        Value::Constructor { name, values } => {
            if values.is_empty() {
                name.0.clone()
            } else {
                let args: Vec<String> = values.iter().map(format_value).collect();
                format!("({} {})", name.0, args.join(" "))
            }
        }
        Value::Record { fields } => {
            if fields.is_empty() {
                "{}".to_string()
            } else {
                let field_strs: Vec<String> = fields.iter()
                    .map(|(name, value)| format!("{}: {}", name, format_value(value)))
                    .collect();
                format!("{{ {} }}", field_strs.join(", "))
            }
        }
    }
}
