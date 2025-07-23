//! XS Language - Unified CLI

use anyhow::Result;
use clap::{Parser, Subcommand};
use xsh::{run_repl, cli};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "xsh")]
#[command(author, version, about = "XS Language Shell and Compiler", long_about = None)]
struct Args {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Interactive shell (default if no command specified)
    Shell,
    
    /// Run an expression and exit
    Run {
        /// The expression to evaluate
        expression: String,
        /// Persist the result to index.xbin
        #[arg(long, short)]
        persist: bool,
    },
    
    /// Parse a file and display the AST
    Parse {
        /// The XS file to parse
        file: PathBuf,
    },
    
    /// Type check a file or directory
    Check {
        /// The XS file or directory to type check
        path: PathBuf,
        /// Show details for each file
        #[arg(long, short)]
        verbose: bool,
    },
    
    /// Run a file
    Exec {
        /// The XS file to run
        file: PathBuf,
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
        command: cli::ComponentCommand,
    },
    
    /// Manage XBin codebase storage
    Codebase {
        #[command(subcommand)]
        command: cli::CodebaseCommand,
    },
}

fn main() -> Result<()> {
    let args = Args::parse();
    
    match args.command {
        Some(Command::Shell) | None => {
            // Run interactive REPL
            run_repl()
        }
        Some(Command::Run { expression, persist }) => {
            run_expression(&expression, persist)
        }
        Some(cmd) => {
            // Convert to cli::Command and run
            let cli_command = match cmd {
                Command::Parse { file } => cli::Command::Parse { file },
                Command::Check { path, verbose } => cli::Command::Check { path, verbose },
                Command::Exec { file } => cli::Command::Run { file },
                Command::Test { file, all, verbose } => cli::Command::Test { file, all, verbose },
                Command::Bench { file, iterations } => cli::Command::Bench { file, iterations },
                Command::Component { command } => cli::Command::Component { command },
                Command::Codebase { command } => cli::Command::Codebase { command },
                _ => unreachable!(),
            };
            
            // Create cli::Args and run
            let cli_args = cli::Args { command: cli_command };
            cli::run_cli_with_args(cli_args)
        }
    }
}

fn run_expression(expr: &str, persist: bool) -> Result<()> {
    use xs_core::parser::parse;
    use xs_compiler::type_check;
    use xs_runtime::Interpreter;
    use xs_workspace::Codebase;
    use std::path::PathBuf;
    
    // Parse the expression
    let parsed = parse(expr)?;
    
    // Type check
    let ty = type_check(&parsed)?;
    
    // Evaluate
    let mut interpreter = Interpreter::new();
    let mut env = Interpreter::create_initial_env();
    
    // Load index.xbin if it exists to populate the environment
    let index_path = PathBuf::from("index.xbin");
    let mut codebase = if index_path.exists() {
        use xs_workspace::xbin::XBinStorage;
        let mut storage = XBinStorage::new(index_path.to_string_lossy().to_string());
        match storage.load_full() {
            Ok(cb) => {
                // Add loaded definitions to environment
                for (name, hash) in cb.names() {
                    if let Some(term) = cb.get_term(&hash) {
                        match interpreter.eval(&term.expr, &env) {
                            Ok(value) => {
                                env = env.extend(xs_core::Ident(name), value);
                            }
                            Err(_) => {} // Ignore evaluation errors for now
                        }
                    }
                }
                cb
            }
            Err(_) => Codebase::new(),
        }
    } else {
        Codebase::new()
    };
    
    let result = interpreter.eval(&parsed, &env)?;
    
    // Print result
    println!("{}", xsh::cli::format_value(&result));
    
    // Save to index.xbin if persist is enabled
    if persist {
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let name = format!("run_{}", timestamp);
        
        match codebase.add_term(Some(name.clone()), parsed.clone(), ty.clone()) {
            Ok(hash) => {
                // Save the updated codebase
                use xs_workspace::xbin::XBinStorage;
                let mut storage = XBinStorage::new(index_path.to_string_lossy().to_string());
                if let Err(e) = storage.save_full(&mut codebase) {
                    eprintln!("Warning: Failed to save to index.xbin: {}", e);
                } else {
                    eprintln!("Expression saved as {} [{}]", name, hash.to_hex());
                }
            }
            Err(e) => {
                eprintln!("Warning: Failed to add to codebase: {}", e);
            }
        }
    }
    
    Ok(())
}
