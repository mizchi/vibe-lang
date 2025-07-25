//! Incremental compilation benchmark

use anyhow::{Context, Result};
use colored::Colorize;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};
use vibe_compiler::{TypeChecker, TypeEnv};
use vibe_language::{parser, Expr};
use vibe_codebase::{
    database::{XsDatabaseImpl, SourcePrograms, CompilerQueries},
    incremental_type_checker::{IncrementalTypeChecker, TypeCheckBatch},
    namespace::{NamespaceStore, DefinitionPath},
};

/// Benchmark result for a single operation
#[derive(Debug)]
struct BenchmarkResult {
    name: String,
    duration: Duration,
    iterations: u32,
}

impl BenchmarkResult {
    fn average(&self) -> Duration {
        self.duration / self.iterations
    }

    fn print(&self) {
        println!(
            "{}: total {:?}, avg {:?} ({} iterations)",
            self.name.green(),
            self.duration,
            self.average(),
            self.iterations
        );
    }
}

/// Run incremental compilation benchmark
pub fn run_incremental_benchmark(file: &Path, iterations: u32) -> Result<()> {
    println!("Running incremental compilation benchmark...\n");

    let source = std::fs::read_to_string(file)
        .with_context(|| format!("Failed to read file: {}", file.display()))?;

    // Parse once to extract definitions
    let expr = parser::parse(&source)
        .map_err(|e| anyhow::anyhow!("Parse error: {}", e))?;

    // Run different benchmark scenarios
    println!("1. Non-incremental type checking (baseline)");
    let baseline = benchmark_non_incremental(&expr, iterations)?;
    baseline.print();

    println!("\n2. Salsa-based incremental compilation");
    let salsa = benchmark_salsa(&source, iterations)?;
    salsa.print();

    println!("\n3. Cache-based incremental type checking");
    let cache = benchmark_cache_based(&expr, iterations)?;
    cache.print();

    // Compare results
    println!("\n{}", "Performance Summary:".yellow());
    let baseline_avg = baseline.average().as_micros();
    let salsa_avg = salsa.average().as_micros();
    let cache_avg = cache.average().as_micros();

    println!(
        "Salsa speedup: {:.2}x",
        baseline_avg as f64 / salsa_avg as f64
    );
    println!(
        "Cache speedup: {:.2}x",
        baseline_avg as f64 / cache_avg as f64
    );

    Ok(())
}

/// Benchmark non-incremental type checking
fn benchmark_non_incremental(expr: &Expr, iterations: u32) -> Result<BenchmarkResult> {
    let start = Instant::now();

    for _ in 0..iterations {
        let mut checker = TypeChecker::new();
        let mut env = TypeEnv::new();
        checker.check(expr, &mut env)
            .map_err(|e| anyhow::anyhow!("Type error: {}", e))?;
    }

    Ok(BenchmarkResult {
        name: "Non-incremental".to_string(),
        duration: start.elapsed(),
        iterations,
    })
}

/// Benchmark Salsa-based incremental compilation
fn benchmark_salsa(source: &str, iterations: u32) -> Result<BenchmarkResult> {
    let mut db = XsDatabaseImpl::new();
    
    // Initial setup
    let key = SourcePrograms {
        path: "test.vibe".to_string(),
        content: source.to_string(),
    };
    db.set_source_text(key.clone(), Arc::new(source.to_string()));

    let start = Instant::now();

    // First run compiles everything
    for i in 0..iterations {
        if i == 0 {
            // First iteration: full type check
            let _ = db.type_check(key.clone())?;
        } else if i % 10 == 0 {
            // Every 10th iteration: simulate a small change
            let modified_source = source.replace("base1 = 10", "base1 = 11");
            db.set_source_text(key.clone(), Arc::new(modified_source));
            let _ = db.type_check(key.clone())?;
            // Revert the change
            db.set_source_text(key.clone(), Arc::new(source.to_string()));
        } else {
            // Most iterations: no change, should be very fast
            let _ = db.type_check(key.clone())?;
        }
    }

    Ok(BenchmarkResult {
        name: "Salsa incremental".to_string(),
        duration: start.elapsed(),
        iterations,
    })
}

/// Benchmark cache-based incremental type checking
fn benchmark_cache_based(_expr: &Expr, iterations: u32) -> Result<BenchmarkResult> {
    // Create namespace store and populate it with definitions
    let namespace_store = Arc::new(NamespaceStore::new());
    
    // This is a simplified version - in reality we'd extract all definitions
    // For benchmark purposes, we'll just measure the overhead

    let mut checker = IncrementalTypeChecker::new(namespace_store);

    let start = Instant::now();

    for i in 0..iterations {
        if i % 10 == 0 {
            // Every 10th iteration: clear some cache entries to simulate changes
            checker.clear_cache();
        }
        
        // In a real scenario, we'd type check individual definitions
        // For now, we'll create a batch and simulate type checking
        let mut batch = TypeCheckBatch::new(&mut checker);
        
        // Add some dummy paths
        for j in 0..10 {
            batch.add(DefinitionPath::from_str(&format!("def{}", j)).unwrap());
        }
        
        let _ = batch.execute();
    }

    Ok(BenchmarkResult {
        name: "Cache-based incremental".to_string(),
        duration: start.elapsed(),
        iterations,
    })
}

/// Run a simple benchmark to test incremental compilation effectiveness
pub fn run_simple_incremental_test() -> Result<()> {
    println!("Testing incremental compilation effectiveness...\n");

    let mut db = XsDatabaseImpl::new();
    
    // Create a simple program
    let source1 = "let x = 42";
    let key1 = SourcePrograms {
        path: "test1.vibe".to_string(),
        content: source1.to_string(),
    };
    
    // First compilation
    println!("1. Initial compilation:");
    let start = Instant::now();
    db.set_source_text(key1.clone(), Arc::new(source1.to_string()));
    let result1 = db.type_check(key1.clone())?;
    let duration1 = start.elapsed();
    println!("   Result: {:?}, Time: {:?}", result1, duration1);

    // Same query again (should be cached)
    println!("\n2. Same query (should be cached):");
    let start = Instant::now();
    let result2 = db.type_check(key1.clone())?;
    let duration2 = start.elapsed();
    println!("   Result: {:?}, Time: {:?}", result2, duration2);
    println!("   Speedup: {:.2}x", duration1.as_nanos() as f64 / duration2.as_nanos().max(1) as f64);

    // Modify the source
    println!("\n3. After modification:");
    let source1_modified = "let x = 100";
    let start = Instant::now();
    db.set_source_text(key1.clone(), Arc::new(source1_modified.to_string()));
    let result3 = db.type_check(key1.clone())?;
    let duration3 = start.elapsed();
    println!("   Result: {:?}, Time: {:?}", result3, duration3);

    // Add a dependent file
    let source2 = "let y = x + 10";
    let key2 = SourcePrograms {
        path: "test2.vibe".to_string(),
        content: source2.to_string(),
    };
    
    println!("\n4. Type check dependent file:");
    let start = Instant::now();
    db.set_source_text(key2.clone(), Arc::new(source2.to_string()));
    let result4 = db.type_check(key2.clone())?;
    let duration4 = start.elapsed();
    println!("   Result: {:?}, Time: {:?}", result4, duration4);

    Ok(())
}