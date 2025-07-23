//! Command-line interface for XS language

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use colored::*;
use std::fs;
use std::path::PathBuf;

use xs_compiler::type_check;
use xs_core::parser::parse;
use xs_core::{Type, Value};
use xs_core::pretty_print::pretty_print;
use xs_test::TestSuite;
use xs_workspace::{Codebase, Hash};
use xs_workspace::xbin::XBinStorage;

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
    /// Manage XBin codebase storage
    Codebase {
        #[command(subcommand)]
        command: CodebaseCommand,
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
    /// Store current code as XBin format
    Store {
        /// Directory containing XS files to store
        #[arg(default_value = ".")]
        directory: PathBuf,
        /// Output XBin file
        #[arg(short, long, default_value = "codebase.xbin")]
        output: PathBuf,
    },
    /// Load specific definitions from XBin
    Load {
        /// XBin file to load from
        #[arg(default_value = "codebase.xbin")]
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
    /// Query XBin codebase
    Query {
        /// XBin file to query
        #[arg(default_value = "codebase.xbin")]
        input: PathBuf,
        /// Query type
        #[command(subcommand)]
        query: QueryCommand,
    },
    /// Show XBin statistics
    Stats {
        /// XBin file to analyze
        #[arg(default_value = "codebase.xbin")]
        input: PathBuf,
    },
    /// Generate and run tests for XBin codebase
    Test {
        /// XBin file to test
        #[arg(default_value = "codebase.xbin")]
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

        Command::Run { file } => {
            let source = fs::read_to_string(&file)
                .with_context(|| format!("Failed to read file: {}", file.display()))?;

            // Parse and type check to get effects
            match parse(&source) {
                Ok(expr) => {
                    // Type check
                    match type_check(&expr) {
                        Ok(_ty) => {
                            // Run without permission checks
                            use xs_runtime::Interpreter;
                            use xs_core::{Environment, BuiltinRegistry, Value, Ident};
                            let mut interpreter = Interpreter::new();
                            
                            // Create environment with builtins
                            let mut env = Environment::default();
                            let registry = BuiltinRegistry::new();
                            for builtin in registry.all() {
                                // Get arity from type signature
                                let arity = match &builtin.type_signature() {
                                    xs_core::Type::Function(_, _) => 2, // Binary operators
                                    _ => 1,
                                };
                                env = env.extend(
                                    Ident(builtin.name().to_string()),
                                    Value::BuiltinFunction {
                                        name: builtin.name().to_string(),
                                        arity,
                                        applied_args: Vec::new(),
                                    }
                                );
                            }
                            match interpreter.eval(&expr, &env) {
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
                    println!("Running benchmark with {iterations} iterations...");

                    let start = std::time::Instant::now();
                    use xs_runtime::Interpreter;
                    use xs_core::Environment;
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

        Command::Component { command } => {
            crate::component_commands::handle_component_command(command)?;
        }

        Command::Codebase { command } => {
            handle_codebase_command(command)?;
        }
    }

    Ok(())
}

fn format_type(ty: &Type) -> String {
    format!("{ty}").cyan().to_string()
}

fn format_value(val: &Value) -> String {
    match val {
        Value::Int(n) => n.to_string(),
        Value::Float(f) => f.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::String(s) => format!("\"{s}\""),
        Value::List(_) => {
            // Use the Display implementation which formats as (list ...)
            val.to_string()
        }
        Value::Closure { .. } => "<closure>".to_string(),
        Value::RecClosure { .. } => "<rec-closure>".to_string(),
        Value::BuiltinFunction { name, .. } => format!("<builtin:{name}>"),
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
            let field_strs: Vec<String> = fields.iter()
                .map(|(name, value)| format!("{}: {}", name, format_value(value)))
                .collect();
            format!("{{{}}}", field_strs.join(", "))
        }
    }
}

fn handle_codebase_command(command: CodebaseCommand) -> Result<()> {
    match command {
        CodebaseCommand::Store { directory, output } => {
            println!("Storing codebase from {} to {}", directory.display(), output.display());
            
            // Create a new codebase and scan directory
            let mut codebase = Codebase::new();
            let mut file_count = 0;
            
            // Check if directory is actually a single file
            if directory.is_file() {
                // Process single file with multiple definitions
                println!("Processing file: {}", directory.display());
                let defs_count = crate::multi_store::store_file_with_multiple_defs(&directory, &mut codebase)?;
                file_count += defs_count;
            } else {
                // Recursively find all .xs files
                for entry in walkdir::WalkDir::new(&directory)
                    .follow_links(true)
                    .into_iter()
                    .filter_map(|e| e.ok())
                {
                    if entry.path().extension().and_then(|s| s.to_str()) == Some("xs") {
                        println!("Processing file: {}", entry.path().display());
                        let defs_count = crate::multi_store::store_file_with_multiple_defs(entry.path(), &mut codebase)?;
                        file_count += defs_count;
                    }
                }
            }
            
            // Save as XBin
            let mut storage = XBinStorage::new(output.to_string_lossy().to_string());
            storage.save_full(&codebase)
                .map_err(|e| anyhow::anyhow!("Failed to save xbin: {}", e))?;
            
            println!("{} Stored {} definitions", "Success:".green(), file_count);
        }
        
        CodebaseCommand::Load { input, definition, with_deps: _, output } => {
            let mut storage = XBinStorage::new(input.to_string_lossy().to_string());
            
            // Try to parse as hash or look up by name
            let hash = if definition.starts_with('#') || definition.len() >= 8 {
                Hash::from_hex(&definition)?
            } else {
                // Load full codebase to search by name
                let codebase = storage.load_full()
                    .map_err(|e| anyhow::anyhow!("Failed to load xbin: {}", e))?;
                codebase.get_term_by_name(&definition)
                    .map(|t| t.hash.clone())
                    .ok_or_else(|| anyhow::anyhow!("Definition not found: {}", definition))?
            };
            
            let codebase = storage.retrieve_with_dependencies(&hash)
                .map_err(|e| anyhow::anyhow!("Failed to retrieve: {}", e))?;
            
            // Create output directory
            fs::create_dir_all(&output)?;
            
            // Save extracted definitions
            for (name, _) in codebase.names() {
                if let Some(term) = codebase.get_term_by_name(&name) {
                    let file_path = output.join(format!("{}.xs", name));
                    let content = pretty_print(&term.expr);
                    fs::write(&file_path, content)?;
                    println!("Extracted: {}", file_path.display());
                }
            }
        }
        
        CodebaseCommand::Query { input, query } => {
            let mut storage = XBinStorage::new(input.to_string_lossy().to_string());
            
            match query {
                QueryCommand::List { namespace, terms_only, types_only } => {
                    let codebase = if let Some(ns) = namespace {
                        storage.retrieve_namespace(&ns)
                            .map_err(|e| anyhow::anyhow!("Failed to retrieve namespace: {}", e))?
                    } else {
                        storage.load_full()
                            .map_err(|e| anyhow::anyhow!("Failed to load xbin: {}", e))?
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
                    let codebase = storage.load_full()
                    .map_err(|e| anyhow::anyhow!("Failed to load xbin: {}", e))?;
                    let pattern = pattern.to_lowercase();
                    
                    println!("{}", "Search results:".bold());
                    for (name, hash) in codebase.names() {
                        if name.to_lowercase().contains(&pattern) {
                            println!("  {} [{}]", name, hash.to_hex());
                        }
                    }
                }
                
                QueryCommand::Deps { definition, transitive } => {
                    let mut storage = XBinStorage::new(input.to_string_lossy().to_string());
                    let codebase = storage.load_full()
                    .map_err(|e| anyhow::anyhow!("Failed to load xbin: {}", e))?;
                    
                    let hash = if definition.starts_with('#') || definition.len() >= 8 {
                        Hash::from_hex(&definition)?
                    } else {
                        codebase.get_term_by_name(&definition)
                            .map(|t| t.hash.clone())
                            .ok_or_else(|| anyhow::anyhow!("Definition not found: {}", definition))?
                    };
                    
                    let deps = if transitive {
                        codebase.get_all_dependencies(&hash)?
                    } else {
                        codebase.get_direct_dependencies(&hash).into_iter().collect()
                    };
                    
                    println!("{} of {}:", if transitive { "All dependencies" } else { "Direct dependencies" }, definition);
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
                    let codebase = storage.load_full()
                    .map_err(|e| anyhow::anyhow!("Failed to load xbin: {}", e))?;
                    
                    let hash = if definition.starts_with('#') || definition.len() >= 8 {
                        Hash::from_hex(&definition)?
                    } else {
                        codebase.get_term_by_name(&definition)
                            .map(|t| t.hash.clone())
                            .ok_or_else(|| anyhow::anyhow!("Definition not found: {}", definition))?
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
            let mut storage = XBinStorage::new(input.to_string_lossy().to_string());
            let stats = storage.stats()
                .map_err(|e| anyhow::anyhow!("Failed to get stats: {}", e))?;
            
            println!("{}", "XBin Statistics:".bold());
            println!("  Terms: {}", stats.term_count);
            println!("  Types: {}", stats.type_count);
            println!("  Total definitions: {}", stats.total_definitions);
            println!("  Total size: {} bytes", stats.total_size);
            println!("  Namespaces: {}", stats.namespace_count);
            println!("  Created: {}", chrono::DateTime::<chrono::Utc>::from_timestamp(stats.created_at as i64, 0)
                .map(|dt| dt.format("%Y-%m-%d %H:%M:%S").to_string())
                .unwrap_or_else(|| "Unknown".to_string()));
            println!("  Updated: {}", chrono::DateTime::<chrono::Utc>::from_timestamp(stats.updated_at as i64, 0)
                .map(|dt| dt.format("%Y-%m-%d %H:%M:%S").to_string())
                .unwrap_or_else(|| "Unknown".to_string()));
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
            use xs_workspace::{TestGenerator, TestGenConfig, TestRunner, TestRunConfig, TestCache, TestStats};
            
            let cache_path = input.with_extension("test_cache");
            let mut test_cache = TestCache::new(&cache_path)?;
            
            // Handle cache operations
            if clear_cache {
                test_cache.clear();
                println!("{}", "Test cache cleared".green());
                return Ok(());
            }
            
            if cache_stats {
                let results = test_cache.all_results();
                println!("{}", "Test Cache Statistics:".bold());
                println!("  Total cached results: {}", results.len());
                let passed = results.iter().filter(|r| matches!(r.result, xs_workspace::TestOutcome::Passed { .. })).count();
                let failed = results.iter().filter(|r| matches!(r.result, xs_workspace::TestOutcome::Failed { .. })).count();
                println!("  Passed: {}", passed);
                println!("  Failed: {}", failed);
                return Ok(());
            }
            
            // Load XBin codebase
            let mut storage = XBinStorage::new(input.to_string_lossy().to_string());
            let codebase = storage.load_full()
                .map_err(|e| anyhow::anyhow!("Failed to load xbin: {}", e))?;
            
            // Configure test generation
            let gen_config = TestGenConfig {
                max_tests_per_function: max_tests,
                enable_property_tests: !no_properties,
                enable_edge_cases: !no_edge_cases,
                use_cache: !force,
                name_filter: filter,
            };
            
            // Generate tests
            let generator = TestGenerator::new(gen_config);
            let tests = generator.generate_tests(&codebase);
            
            if tests.is_empty() {
                println!("{}", "No tests generated".yellow());
                return Ok(());
            }
            
            println!("{}", format!("Generated {} tests", tests.len()).green());
            
            // Configure test runner
            let run_config = TestRunConfig {
                use_cache: !force,
                force_rerun: force,
                timeout: std::time::Duration::from_secs(10),
                parallel: !sequential,
                num_threads: threads,
                fail_fast,
                verbosity,
            };
            
            // Run tests
            let runner = TestRunner::new(run_config, test_cache, codebase);
            let results = runner.run_tests(tests);
            
            // Print results
            if verbosity > 0 {
                for result in &results {
                    let status = match &result.outcome {
                        xs_workspace::TestOutcome::Passed { .. } => "PASS".green(),
                        xs_workspace::TestOutcome::Failed { .. } => "FAIL".red(),
                        xs_workspace::TestOutcome::Timeout => "TIMEOUT".yellow(),
                        xs_workspace::TestOutcome::Skipped { .. } => "SKIP".blue(),
                    };
                    
                    let cache_marker = if result.from_cache { " (cached)" } else { "" };
                    println!("{} {} - {}{}", status, result.test.name, result.test.function_name, cache_marker);
                    
                    if verbosity > 1 {
                        match &result.outcome {
                            xs_workspace::TestOutcome::Failed { error } => {
                                println!("  Error: {}", error.red());
                            }
                            xs_workspace::TestOutcome::Passed { value } => {
                                println!("  Result: {}", value);
                            }
                            _ => {}
                        }
                    }
                }
            }
            
            // Print summary
            let stats = TestStats::from_results(&results);
            stats.print_summary();
            
            // Return error if any tests failed
            if stats.failed > 0 {
                std::process::exit(1);
            }
        }
    }
    
    Ok(())
}
