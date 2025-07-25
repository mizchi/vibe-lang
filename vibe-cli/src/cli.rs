//! Command-line interface for XS language

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use colored::*;
use std::fs;
use std::path::{Path, PathBuf};

use crate::test_runner::TestSuite;
use vibe_compiler::type_check;
use vibe_language::parser::parse;
use vibe_language::pretty_print::pretty_print;
use vibe_language::{Type, Value};
use vibe_codebase::vbin::VBinStorage;
use vibe_codebase::{Codebase, Hash};

#[derive(Parser)]
#[command(name = "xsc")]
#[command(author, version, about = "Vibe Language Compiler", long_about = None)]
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
    /// Type check a file or directory
    Check {
        /// The XS file or directory to type check
        path: PathBuf,
        /// Show details for each file
        #[arg(long, short)]
        verbose: bool,
    },
    /// Run a file
    Run {
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
        command: ComponentCommand,
    },
    /// Manage VBin codebase storage
    Codebase {
        #[command(subcommand)]
        command: CodebaseCommand,
    },
    /// Package management
    #[command(alias = "pkg")]
    Package {
        #[command(subcommand)]
        command: crate::package_commands::PackageCommand,
    },
    /// Start Language Server Protocol server
    Lsp {
        /// Port to listen on (default: stdio)
        #[arg(long)]
        port: Option<u16>,
        /// Enable debug logging
        #[arg(long)]
        debug: bool,
    },
    /// Start Model Context Protocol server
    Mcp {
        /// Port to listen on (default: 3000)
        #[arg(short, long, default_value = "3000")]
        port: u16,
        /// Enable debug logging
        #[arg(long)]
        debug: bool,
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

#[derive(Subcommand)]
pub enum CodebaseCommand {
    /// Store current code as VBin format
    Store {
        /// Directory containing XS files to store
        #[arg(default_value = ".")]
        directory: PathBuf,
        /// Output VBin file
        #[arg(short, long, default_value = "codebase.vibes")]
        output: PathBuf,
    },
    /// Load specific definitions from VBin
    Load {
        /// VBin file to load from
        #[arg(default_value = "codebase.vibes")]
        input: PathBuf,
        /// Hash or name of definition to load
        definition: String,
        /// Include all dependencies
        #[arg(long)]
        with_deps: bool,
        /// Output directory for extracted definitions
        #[arg(short, long, default_value = "extracted")]
        output: PathBuf,
    },
    /// Query VBin codebase
    Query {
        /// VBin file to query
        #[arg(default_value = "codebase.vibes")]
        input: PathBuf,
        /// Query type
        #[command(subcommand)]
        query: QueryCommand,
    },
    /// Show VBin statistics
    Stats {
        /// VBin file to analyze
        #[arg(default_value = "codebase.vibes")]
        input: PathBuf,
    },
    /// Generate and run tests for VBin codebase
    Test {
        /// VBin file to test
        #[arg(default_value = "codebase.vibes")]
        input: PathBuf,
        /// Filter for function names to test
        #[arg(short, long)]
        filter: Option<String>,
        /// Force re-run all tests (ignore cache)
        #[arg(long)]
        force: bool,
        /// Clear test cache
        #[arg(long)]
        clear_cache: bool,
        /// Show cache statistics
        #[arg(long)]
        cache_stats: bool,
        /// Maximum tests per function
        #[arg(long, default_value = "10")]
        max_tests: usize,
        /// Disable property-based tests
        #[arg(long)]
        no_properties: bool,
        /// Disable edge case tests
        #[arg(long)]
        no_edge_cases: bool,
        /// Run tests sequentially (default is parallel)
        #[arg(long)]
        sequential: bool,
        /// Number of threads for parallel execution
        #[arg(long)]
        threads: Option<usize>,
        /// Stop on first failure
        #[arg(long)]
        fail_fast: bool,
        /// Verbosity level (0-2)
        #[arg(short, long, default_value = "1")]
        verbosity: u8,
    },
}

#[derive(Subcommand)]
pub enum QueryCommand {
    /// List all definitions
    List {
        /// Filter by namespace
        #[arg(long)]
        namespace: Option<String>,
        /// Show only terms
        #[arg(long)]
        terms_only: bool,
        /// Show only types
        #[arg(long)]
        types_only: bool,
    },
    /// Search definitions by name pattern
    Search {
        /// Pattern to search for
        pattern: String,
    },
    /// Show dependencies of a definition
    Deps {
        /// Hash or name of definition
        definition: String,
        /// Show transitive dependencies
        #[arg(long)]
        transitive: bool,
    },
    /// Show dependents of a definition
    Dependents {
        /// Hash or name of definition
        definition: String,
    },
}

pub fn run_cli() -> Result<()> {
    let args = Args::parse();
    run_cli_with_args(args)
}

pub fn run_cli_with_args(args: Args) -> Result<()> {
    match args.command {
        Command::Parse { file } => {
            let source = fs::read_to_string(&file)
                .with_context(|| format!("Failed to read file: {}", file.display()))?;

            match parse(&source) {
                Ok(expr) => {
                    println!("{}", "Parse successful!".green());
                    println!("{expr:#?}");
                }
                Err(e) => {
                    eprintln!("{}: {}", "Parse error".red(), e);
                    std::process::exit(1);
                }
            }
        }

        Command::Check { path, verbose } => {
            use walkdir::WalkDir;

            let mut checked_files = 0;
            let mut errors = 0;

            // Check if path is a file or directory
            if path.is_file() {
                // Single file check
                match check_file(&path, verbose) {
                    Ok(_) => checked_files += 1,
                    Err(e) => {
                        eprintln!("{}: {}", path.display(), e);
                        errors += 1;
                    }
                }
            } else if path.is_dir() {
                // Directory check - find all .vibe and .vibes files
                for entry in WalkDir::new(&path)
                    .follow_links(true)
                    .into_iter()
                    .filter_map(|e| e.ok())
                {
                    let path = entry.path();
                    if path.is_file() {
                        let ext = path.extension().and_then(|s| s.to_str());
                        match ext {
                            Some("vibe") => {
                                if verbose {
                                    print!("Checking {} ... ", path.display());
                                }
                                match check_file(path, false) {
                                    Ok(_) => {
                                        checked_files += 1;
                                        if verbose {
                                            println!("{}", "OK".green());
                                        }
                                    }
                                    Err(e) => {
                                        errors += 1;
                                        if verbose {
                                            println!("{}", "FAILED".red());
                                        }
                                        eprintln!("{}: {}", path.display(), e);
                                    }
                                }
                            }
                            Some("xbin") => {
                                if verbose {
                                    print!("Checking {} ... ", path.display());
                                }
                                match check_vbin_file(path, false) {
                                    Ok(_) => {
                                        checked_files += 1;
                                        if verbose {
                                            println!("{}", "OK".green());
                                        }
                                    }
                                    Err(e) => {
                                        errors += 1;
                                        if verbose {
                                            println!("{}", "FAILED".red());
                                        }
                                        eprintln!("{}: {}", path.display(), e);
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                }
            } else {
                eprintln!("{}: Path does not exist: {}", "Error".red(), path.display());
                std::process::exit(1);
            }

            // Summary
            println!("\n{} Checked {} files", "Summary:".bold(), checked_files);
            if errors > 0 {
                eprintln!("{} {} errors found", "Failed:".red().bold(), errors);
                std::process::exit(1);
            } else {
                println!(
                    "{} All files type check successfully!",
                    "Success:".green().bold()
                );
            }
        }

        Command::Run { file } => {
            let source = fs::read_to_string(&file)
                .with_context(|| format!("Failed to read file: {}", file.display()))?;

            // Check file extension
            let extension = file.extension().and_then(|s| s.to_str()).unwrap_or("");
            
            // Parse and type check to get effects
            match parse(&source) {
                Ok(expr) => {
                    // Type check
                    match type_check(&expr) {
                        Ok(_ty) => {
                            // Run without permission checks
                            use vibe_runtime::Interpreter;
                            let mut interpreter = Interpreter::new();

                            // Create environment with builtins
                            let env = Interpreter::create_initial_env();
                            
                            // For .vibe files, look for and execute main function
                            // For .vsh files (or no extension), execute top-level expression
                            let result = if extension == "vibe" {
                                // For .vibe files, wrap the expression to call main
                                // First evaluate the file content, then call main
                                let wrapped_expr = vibe_language::Expr::Block {
                                    exprs: vec![
                                        expr.clone(),
                                        vibe_language::Expr::Apply {
                                            func: Box::new(vibe_language::Expr::Ident(
                                                vibe_language::Ident("main".to_string()),
                                                vibe_language::Span::new(0, 0)
                                            )),
                                            args: vec![],
                                            span: vibe_language::Span::new(0, 0),
                                        }
                                    ],
                                    span: vibe_language::Span::new(0, 0),
                                };
                                
                                // Evaluate the wrapped expression
                                match interpreter.eval(&wrapped_expr, &env) {
                                    Ok(value) => Ok(value),
                                    Err(e) => {
                                        // Check if the error is about missing main function
                                        if e.to_string().contains("Undefined variable: main") {
                                            eprintln!("{}: No main function found in .vibe file", "Error".red().bold());
                                            eprintln!("Hint: .vibe files require a main function. Use .vsh extension for direct execution.");
                                            std::process::exit(1);
                                        } else {
                                            Err(e)
                                        }
                                    }
                                }
                            } else {
                                // For .vsh files or files without extension, execute top-level
                                interpreter.eval(&expr, &env)
                            };
                            
                            match result {
                                Ok(value) => {
                                    // Don't print empty string values from main function
                                    if extension != "vibe" || !matches!(value, Value::String(ref s) if s.is_empty()) {
                                        println!("{}", format_value(&value));
                                    }
                                }
                                Err(e) => {
                                    eprintln!("{}: {}", "Runtime error".red(), e);
                                    std::process::exit(1);
                                }
                            }
                        }
                        Err(e) => {
                            eprintln!("{}: {}", "Type error".red(), e);
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
            path,
            all: _all,
            verbose,
        } => {
            use walkdir::WalkDir;
            
            let mut suite = TestSuite::new(verbose);
            let mut total_files = 0;
            let mut error_files = 0;
            
            // Check if path is a file or directory
            if path.is_file() {
                // Single file test
                if path.extension().and_then(|s| s.to_str()) == Some("vibe") {
                    match suite.load_test_file(&path) {
                        Ok(tests_found) => {
                            if tests_found > 0 {
                                total_files += 1;
                            }
                        }
                        Err(e) => {
                            eprintln!("{}: {}: {}", "Error".red(), path.display(), e);
                            error_files += 1;
                        }
                    }
                }
            } else if path.is_dir() {
                // Directory scan - find all .vibe files
                for entry in WalkDir::new(&path)
                    .follow_links(true)
                    .into_iter()
                    .filter_map(|e| e.ok())
                {
                    let path = entry.path();
                    if path.is_file() && path.extension().and_then(|s| s.to_str()) == Some("vibe") {
                        match suite.load_test_file(path) {
                            Ok(tests_found) => {
                                if tests_found > 0 {
                                    total_files += 1;
                                    if verbose {
                                        println!("Found {} tests in {}", tests_found, path.display());
                                    }
                                }
                            }
                            Err(e) => {
                                eprintln!("{}: {}: {}", "Error".red(), path.display(), e);
                                error_files += 1;
                            }
                        }
                    }
                }
            } else {
                eprintln!("{}: Path does not exist: {}", "Error".red(), path.display());
                std::process::exit(1);
            }
            
            // Run all collected tests
            if suite.total_tests() == 0 {
                // Print the summary even when no tests are found
                use colored::Colorize;
                println!("{}", "Running tests...".bright_blue().bold());
                println!();
                println!("{}", "Test Summary".bright_blue().bold());
                println!("{}", "============".bright_blue());
                println!("Total: 0 | Passed: {} | Failed: {} | Cached: {}",
                    "0".to_string().green(),
                    "0".to_string().red(),
                    "0".to_string().cyan()
                );
                println!("Duration: 0.00s");
                println!();
                println!("{}", "All tests passed!".green().bold());
                return Ok(());
            }
            
            println!("\nRunning {} tests from {} files...", suite.total_tests(), total_files);
            let summary = suite.run_all();
            
            if error_files > 0 {
                eprintln!("\n{} {} files had errors", "Warning:".yellow(), error_files);
            }

            if summary.failed > 0 {
                std::process::exit(1);
            }
        }

        Command::Bench { file, iterations, incremental, wasm } => {
            if incremental {
                // Run incremental compilation benchmark
                crate::incremental_bench::run_incremental_benchmark(&file, iterations)?;
            } else if wasm {
                // Run WASM generation benchmark
                crate::wasm_bench::run_wasm_benchmark(&file, iterations)?;
            } else {
                // Run interpreter benchmark
                let source = fs::read_to_string(&file)
                    .with_context(|| format!("Failed to read file: {}", file.display()))?;

                match parse(&source) {
                    Ok(expr) => {
                        println!("Running benchmark with {iterations} iterations...");

                        let start = std::time::Instant::now();
                        use vibe_language::Environment;
                        use vibe_runtime::Interpreter;
                        for _ in 0..iterations {
                            let mut interpreter = Interpreter::new();
                            let env = Environment::default();
                            let _ = interpreter.eval(&expr, &env);
                        }
                        let duration = start.elapsed();

                        let avg_time = duration / iterations;
                        println!("Average time: {avg_time:?}");
                        println!("Total time: {duration:?}");
                    }
                    Err(e) => {
                        eprintln!("{}: {}", "Parse error".red(), e);
                        std::process::exit(1);
                    }
                }
            }
        }

        Command::Component { command } => {
            crate::component_commands::handle_component_command(command)?;
        }

        Command::Codebase { command } => {
            handle_codebase_command(command)?;
        }
        
        Command::Package { command } => {
            // Create runtime for async operations
            let runtime = tokio::runtime::Runtime::new()?;
            runtime.block_on(async {
                crate::package_commands::handle_package_command(command).await
            })?;
        }

        Command::Lsp { port, debug } => {
            handle_lsp_command(port, debug)?;
        }

        Command::Mcp { port, debug } => {
            handle_mcp_command(port, debug)?;
        }
    }

    Ok(())
}

fn format_type(ty: &Type) -> String {
    format!("{ty}").cyan().to_string()
}

pub fn format_value(val: &Value) -> String {
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
        Value::UseStatement { .. } => "<use>".to_string(),
        Value::Record { fields } => {
            let field_strs: Vec<String> = fields
                .iter()
                .map(|(name, value)| format!("{}: {}", name, format_value(value)))
                .collect();
            format!("{{{}}}", field_strs.join(", "))
        }
    }
}

fn check_file(path: &Path, verbose: bool) -> Result<Type> {
    let source = fs::read_to_string(path)
        .with_context(|| format!("Failed to read file: {}", path.display()))?;

    let expr = parse(&source).map_err(|e| anyhow::anyhow!("Parse error: {}", e))?;

    let ty = type_check(&expr).map_err(|e| anyhow::anyhow!("Type error: {}", e))?;

    if verbose {
        println!("  Type: {}", format_type(&ty));
    }

    Ok(ty)
}

fn check_vbin_file(path: &Path, verbose: bool) -> Result<()> {
    let mut storage = VBinStorage::new(path.to_string_lossy().to_string());
    let codebase = storage
        .load_full()
        .map_err(|e| anyhow::anyhow!("Failed to load vbin: {}", e))?;

    // Type check all terms in the codebase
    let mut checked = 0;
    let mut errors = Vec::new();

    for (name, hash) in codebase.names() {
        let term = codebase
            .get_term(&hash)
            .ok_or_else(|| anyhow::anyhow!("Term not found for name: {}", name))?;
        // Terms in vbin are already type checked, but we re-check them
        match type_check(&term.expr) {
            Ok(actual_ty) => {
                // Verify the stored type matches
                if format_type(&actual_ty) != format_type(&term.ty) {
                    let name = term.name.as_deref().unwrap_or("<unnamed>");
                    errors.push(format!(
                        "{} [{}]: Type mismatch - stored: {}, actual: {}",
                        name,
                        hash.to_hex(),
                        format_type(&term.ty),
                        format_type(&actual_ty)
                    ));
                } else {
                    checked += 1;
                }
            }
            Err(e) => {
                let name = term.name.as_deref().unwrap_or("<unnamed>");
                errors.push(format!("{} [{}]: {}", name, hash.to_hex(), e));
            }
        }
    }

    if !errors.is_empty() {
        return Err(anyhow::anyhow!(
            "Type errors in {} terms:\n{}",
            errors.len(),
            errors.join("\n")
        ));
    }

    if verbose {
        println!("  Checked {} terms", checked);
    }

    Ok(())
}

fn handle_codebase_command(command: CodebaseCommand) -> Result<()> {
    match command {
        CodebaseCommand::Store { directory, output } => {
            println!(
                "Storing codebase from {} to {}",
                directory.display(),
                output.display()
            );

            // Create a new codebase and scan directory
            let mut codebase = Codebase::new();
            let mut file_count = 0;

            // Check if directory is actually a single file
            if directory.is_file() {
                // Process single file with multiple definitions
                println!("Processing file: {}", directory.display());
                let defs_count =
                    crate::multi_store::store_file_with_multiple_defs(&directory, &mut codebase)?;
                file_count += defs_count;
            } else {
                // Recursively find all .vibe files
                for entry in walkdir::WalkDir::new(&directory)
                    .follow_links(true)
                    .into_iter()
                    .filter_map(|e| e.ok())
                {
                    if entry.path().extension().and_then(|s| s.to_str()) == Some("vibe") {
                        println!("Processing file: {}", entry.path().display());
                        let defs_count = crate::multi_store::store_file_with_multiple_defs(
                            entry.path(),
                            &mut codebase,
                        )?;
                        file_count += defs_count;
                    }
                }
            }

            // Save as VBin
            let mut storage = VBinStorage::new(output.to_string_lossy().to_string());
            storage
                .save_full(&codebase)
                .map_err(|e| anyhow::anyhow!("Failed to save vbin: {}", e))?;

            println!("{} Stored {} definitions", "Success:".green(), file_count);
        }

        CodebaseCommand::Load {
            input,
            definition,
            with_deps: _,
            output,
        } => {
            let mut storage = VBinStorage::new(input.to_string_lossy().to_string());

            // Try to parse as hash or look up by name
            let hash = if definition.starts_with('#') || definition.len() >= 8 {
                Hash::from_hex(&definition)?
            } else {
                // Load full codebase to search by name
                let codebase = storage
                    .load_full()
                    .map_err(|e| anyhow::anyhow!("Failed to load vbin: {}", e))?;
                codebase
                    .get_term_by_name(&definition)
                    .map(|t| t.hash.clone())
                    .ok_or_else(|| anyhow::anyhow!("Definition not found: {}", definition))?
            };

            let codebase = storage
                .retrieve_with_dependencies(&hash)
                .map_err(|e| anyhow::anyhow!("Failed to retrieve: {}", e))?;

            // Create output directory
            fs::create_dir_all(&output)?;

            // Save extracted definitions
            for (name, _) in codebase.names() {
                if let Some(term) = codebase.get_term_by_name(&name) {
                    let file_path = output.join(format!("{}.vibe", name));
                    let content = pretty_print(&term.expr);
                    fs::write(&file_path, content)?;
                    println!("Extracted: {}", file_path.display());
                }
            }
        }

        CodebaseCommand::Query { input, query } => {
            let mut storage = VBinStorage::new(input.to_string_lossy().to_string());

            match query {
                QueryCommand::List {
                    namespace,
                    terms_only,
                    types_only,
                } => {
                    let codebase = if let Some(ns) = namespace {
                        storage
                            .retrieve_namespace(&ns)
                            .map_err(|e| anyhow::anyhow!("Failed to retrieve namespace: {}", e))?
                    } else {
                        storage
                            .load_full()
                            .map_err(|e| anyhow::anyhow!("Failed to load vbin: {}", e))?
                    };

                    if !types_only {
                        println!("{}", "Terms:".bold());
                        for (name, hash) in codebase.names() {
                            println!("  {} [{}]", name, hash.to_hex());
                        }
                    }

                    if !terms_only {
                        println!("\n{}", "Types:".bold());
                        // TODO: Add type listing support to Codebase
                    }
                }

                QueryCommand::Search { pattern } => {
                    let codebase = storage
                        .load_full()
                        .map_err(|e| anyhow::anyhow!("Failed to load vbin: {}", e))?;
                    let pattern = pattern.to_lowercase();

                    println!("{}", "Search results:".bold());
                    for (name, hash) in codebase.names() {
                        if name.to_lowercase().contains(&pattern) {
                            println!("  {} [{}]", name, hash.to_hex());
                        }
                    }
                }

                QueryCommand::Deps {
                    definition,
                    transitive,
                } => {
                    let mut storage = VBinStorage::new(input.to_string_lossy().to_string());
                    let codebase = storage
                        .load_full()
                        .map_err(|e| anyhow::anyhow!("Failed to load vbin: {}", e))?;

                    let hash = if definition.starts_with('#') || definition.len() >= 8 {
                        Hash::from_hex(&definition)?
                    } else {
                        codebase
                            .get_term_by_name(&definition)
                            .map(|t| t.hash.clone())
                            .ok_or_else(|| {
                                anyhow::anyhow!("Definition not found: {}", definition)
                            })?
                    };

                    let deps = if transitive {
                        codebase.get_all_dependencies(&hash)?
                    } else {
                        codebase
                            .get_direct_dependencies(&hash)
                            .into_iter()
                            .collect()
                    };

                    println!(
                        "{} of {}:",
                        if transitive {
                            "All dependencies"
                        } else {
                            "Direct dependencies"
                        },
                        definition
                    );
                    for dep in deps {
                        if let Some(term) = codebase.get_term(&dep) {
                            if let Some(name) = &term.name {
                                println!("  {} [{}]", name, dep.to_hex());
                            } else {
                                println!("  <unnamed> [{}]", dep.to_hex());
                            }
                        }
                    }
                }

                QueryCommand::Dependents { definition } => {
                    let codebase = storage
                        .load_full()
                        .map_err(|e| anyhow::anyhow!("Failed to load vbin: {}", e))?;

                    let hash = if definition.starts_with('#') || definition.len() >= 8 {
                        Hash::from_hex(&definition)?
                    } else {
                        codebase
                            .get_term_by_name(&definition)
                            .map(|t| t.hash.clone())
                            .ok_or_else(|| {
                                anyhow::anyhow!("Definition not found: {}", definition)
                            })?
                    };

                    let deps = codebase.get_dependents(&hash);

                    println!("Dependents of {}:", definition);
                    for dep in deps {
                        if let Some(term) = codebase.get_term(&dep) {
                            if let Some(name) = &term.name {
                                println!("  {} [{}]", name, dep.to_hex());
                            } else {
                                println!("  <unnamed> [{}]", dep.to_hex());
                            }
                        }
                    }
                }
            }
        }

        CodebaseCommand::Stats { input } => {
            let mut storage = VBinStorage::new(input.to_string_lossy().to_string());
            let stats = storage
                .stats()
                .map_err(|e| anyhow::anyhow!("Failed to get stats: {}", e))?;

            println!("{}", "VBin Statistics:".bold());
            println!("  Terms: {}", stats.term_count);
            println!("  Types: {}", stats.type_count);
            println!("  Total definitions: {}", stats.total_definitions);
            println!("  Total size: {} bytes", stats.total_size);
            println!("  Namespaces: {}", stats.namespace_count);
            println!(
                "  Created: {}",
                chrono::DateTime::<chrono::Utc>::from_timestamp(stats.created_at as i64, 0)
                    .map(|dt| dt.format("%Y-%m-%d %H:%M:%S").to_string())
                    .unwrap_or_else(|| "Unknown".to_string())
            );
            println!(
                "  Updated: {}",
                chrono::DateTime::<chrono::Utc>::from_timestamp(stats.updated_at as i64, 0)
                    .map(|dt| dt.format("%Y-%m-%d %H:%M:%S").to_string())
                    .unwrap_or_else(|| "Unknown".to_string())
            );
        }

        CodebaseCommand::Test {
            input,
            filter,
            force,
            clear_cache,
            cache_stats,
            max_tests,
            no_properties,
            no_edge_cases,
            sequential,
            threads,
            fail_fast,
            verbosity,
        } => {
            println!("{}", "Test command is temporarily disabled due to refactoring".yellow());
            // TODO: Re-implement test functionality without TestCache
        }
    }

    Ok(())
}

fn handle_lsp_command(port: Option<u16>, debug: bool) -> Result<()> {
    use crate::lsp::backend::XSLanguageServer;
    use tower_lsp::{LspService, Server};

    // Set up logging
    if debug {
        tracing_subscriber::fmt()
            .with_max_level(tracing::Level::DEBUG)
            .init();
    }

    // Create runtime for async operations
    let runtime = tokio::runtime::Runtime::new()?;

    runtime.block_on(async {
        let (service, socket) = LspService::new(|client| XSLanguageServer::new(client));

        if let Some(port) = port {
            // TCP mode
            let addr = format!("127.0.0.1:{}", port);
            println!("Starting LSP server on {}", addr);

            let listener = tokio::net::TcpListener::bind(&addr).await?;
            let (stream, _) = listener.accept().await?;
            let (input, output) = stream.into_split();

            Server::new(input, output, socket).serve(service).await;
        } else {
            // Stdio mode (default)
            let stdin = tokio::io::stdin();
            let stdout = tokio::io::stdout();

            Server::new(stdin, stdout, socket).serve(service).await;
        }

        Ok(())
    })
}

fn handle_mcp_command(port: u16, debug: bool) -> Result<()> {
    use crate::mcp::server::run_server;

    // Set up logging
    if debug {
        tracing_subscriber::fmt()
            .with_max_level(tracing::Level::DEBUG)
            .init();
    } else {
        tracing_subscriber::fmt()
            .with_max_level(tracing::Level::INFO)
            .init();
    }

    // Create runtime and run server
    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(async { run_server(port).await })
}
