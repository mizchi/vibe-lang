//! Vibe Language - Unified CLI

use anyhow::Result;
use clap::{Parser, Subcommand};
use std::path::PathBuf;
use vibe_cli::{cli, run_repl};

#[derive(Parser)]
#[command(name = "vibe")]
#[command(author, version, about = "Vibe Language CLI", long_about = None)]
struct Args {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Interactive shell
    Shell,

    /// Run a file
    Run {
        /// The file to run
        file: PathBuf,
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

    /// Run tests in a file or directory
    Test {
        /// The XS file or directory containing tests (defaults to current directory)
        #[arg(default_value = ".")]
        path: PathBuf,
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
        /// Run incremental compilation benchmark
        #[arg(long)]
        incremental: bool,
        /// Run WASM generation benchmark
        #[arg(long)]
        wasm: bool,
    },

    /// Generate WebAssembly Component from XS module
    Component {
        #[command(subcommand)]
        command: cli::ComponentCommand,
    },

    /// Manage VBin codebase storage
    Codebase {
        #[command(subcommand)]
        command: cli::CodebaseCommand,
    },
}

fn main() -> Result<()> {
    let args = Args::parse();

    match args.command {
        Some(Command::Shell) => {
            // Run interactive REPL
            run_repl()
        }
        None => {
            // Default to running shell if no command specified
            run_repl()
        }
        Some(Command::Run { file }) => {
            let cli_command = cli::Command::Run { file };
            cli::run_cli_with_args(cli::Args { command: cli_command })
        }
        Some(cmd) => {
            // Convert to cli::Command and run
            let cli_command = match cmd {
                Command::Parse { file } => cli::Command::Parse { file },
                Command::Check { path, verbose } => cli::Command::Check { path, verbose },
                Command::Exec { file } => cli::Command::Run { file },
                Command::Test { path, all, verbose } => cli::Command::Test { path, all, verbose },
                Command::Bench { file, iterations, incremental, wasm } => cli::Command::Bench { file, iterations, incremental, wasm },
                Command::Component { command } => cli::Command::Component { command },
                Command::Codebase { command } => cli::Command::Codebase { command },
                _ => unreachable!(),
            };

            // Create cli::Args and run
            let cli_args = cli::Args {
                command: cli_command,
            };
            cli::run_cli_with_args(cli_args)
        }
    }
}

// Not used anymore - run file instead
#[allow(dead_code)]
fn run_expression(expr: &str, persist: bool) -> Result<()> {
    use std::path::PathBuf;
    use vibe_compiler::type_check;
    use vibe_language::parser::parse;
    use vibe_runtime::Interpreter;
    use vibe_codebase::Codebase;

    // Parse the expression
    let parsed = parse(expr)?;

    // Type check
    let ty = type_check(&parsed)?;

    // Evaluate
    let mut interpreter = Interpreter::new();
    let mut env = Interpreter::create_initial_env();

    // Load index.vibes if it exists to populate the environment
    let index_path = PathBuf::from("index.vibes");
    let mut codebase = if index_path.exists() {
        use vibe_codebase::vbin::VBinStorage;
        let mut storage = VBinStorage::new(index_path.to_string_lossy().to_string());
        match storage.load_full() {
            Ok(cb) => {
                // Add loaded definitions to environment
                for (name, hash) in cb.names() {
                    if let Some(term) = cb.get_term(&hash) {
                        match interpreter.eval(&term.expr, &env) {
                            Ok(value) => {
                                env = env.extend(vibe_language::Ident(name), value);
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
    println!("{}", vibe_cli::cli::format_value(&result));

    // Save to index.vibes if persist is enabled
    if persist {
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let name = format!("run_{}", timestamp);

        match codebase.add_term(Some(name.clone()), parsed.clone(), ty.clone()) {
            Ok(hash) => {
                // Save the updated codebase
                use vibe_codebase::vbin::VBinStorage;
                let mut storage = VBinStorage::new(index_path.to_string_lossy().to_string());
                if let Err(e) = storage.save_full(&mut codebase) {
                    eprintln!("Warning: Failed to save to index.vibes: {}", e);
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
