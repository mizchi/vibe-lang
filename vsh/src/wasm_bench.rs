//! WASM incremental compilation benchmark

use anyhow::{Context, Result};
use colored::Colorize;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};
use vibe_workspace::{
    database::{XsDatabaseImpl, SourcePrograms, CompilerQueries},
    wasm_queries_simple::{WasmCache, generate_wasm_direct},
};

/// Benchmark result
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

/// Run WASM incremental compilation benchmark
pub fn run_wasm_benchmark(file: &Path, iterations: u32) -> Result<()> {
    println!("Running WASM incremental compilation benchmark...\n");

    let source = std::fs::read_to_string(file)
        .with_context(|| format!("Failed to read file: {}", file.display()))?;

    // 1. Type checking only (baseline)
    let type_check_result = benchmark_type_check_only(&source, iterations)?;
    type_check_result.print();

    // 2. WASM generation without caching
    let wasm_no_cache = benchmark_wasm_no_cache(&source, iterations)?;
    wasm_no_cache.print();

    // 3. WASM generation with simple caching
    let wasm_cache = benchmark_wasm_with_cache(&source, iterations)?;
    wasm_cache.print();

    // Compare results
    println!("\n{}", "Performance Summary:".yellow());
    let type_check_avg = type_check_result.average().as_micros();
    let wasm_no_cache_avg = wasm_no_cache.average().as_micros();
    let wasm_cache_avg = wasm_cache.average().as_micros();

    println!(
        "WASM generation overhead: {:.2}x slower than type checking",
        wasm_no_cache_avg as f64 / type_check_avg as f64
    );
    println!(
        "Cache speedup: {:.2}x faster than no cache",
        wasm_no_cache_avg as f64 / wasm_cache_avg as f64
    );

    // Test incremental changes
    println!("\n{}", "Testing incremental changes:".yellow());
    test_incremental_changes(&source)?;

    Ok(())
}

/// Benchmark type checking only
fn benchmark_type_check_only(source: &str, iterations: u32) -> Result<BenchmarkResult> {
    let mut db = XsDatabaseImpl::new();
    let key = SourcePrograms {
        path: "test.vibe".to_string(),
        content: source.to_string(),
    };
    db.set_source_text(key.clone(), Arc::new(source.to_string()));

    let start = Instant::now();
    for _ in 0..iterations {
        let _ = db.type_check(key.clone())?;
    }

    Ok(BenchmarkResult {
        name: "Type check only".to_string(),
        duration: start.elapsed(),
        iterations,
    })
}

/// Benchmark WASM generation without caching
fn benchmark_wasm_no_cache(source: &str, iterations: u32) -> Result<BenchmarkResult> {
    let expr = vibe_core::parser::parse(source)
        .map_err(|e| anyhow::anyhow!("Parse error: {}", e))?;
    
    let start = Instant::now();

    for _ in 0..iterations {
        // Generate WASM without any caching
        let _ = generate_wasm_direct(&expr)?;
    }

    Ok(BenchmarkResult {
        name: "WASM no cache".to_string(),
        duration: start.elapsed(),
        iterations,
    })
}

/// Benchmark WASM generation with simple caching
fn benchmark_wasm_with_cache(source: &str, iterations: u32) -> Result<BenchmarkResult> {
    let expr = vibe_core::parser::parse(source)
        .map_err(|e| anyhow::anyhow!("Parse error: {}", e))?;
    
    let mut cache = WasmCache::new();
    let start = Instant::now();

    for i in 0..iterations {
        if i % 10 == 0 && i > 0 {
            // Every 10th iteration: invalidate cache to simulate change
            cache.invalidate("test");
        }
        
        // Generate with caching
        let _ = cache.get_or_generate("test", &expr)?;
    }

    Ok(BenchmarkResult {
        name: "WASM with cache".to_string(),
        duration: start.elapsed(),
        iterations,
    })
}

/// Test incremental changes with detailed timing
fn test_incremental_changes(source: &str) -> Result<()> {
    let expr = vibe_core::parser::parse(source)
        .map_err(|e| anyhow::anyhow!("Parse error: {}", e))?;
    
    let mut cache = WasmCache::new();

    // Initial compilation
    println!("\n1. Initial WASM generation:");
    let start = Instant::now();
    let _ = cache.get_or_generate("test", &expr)?;
    let initial_time = start.elapsed();
    println!("   Time: {:?}", initial_time);

    // Same query (should be cached)
    println!("\n2. Same query (should be cached):");
    let start = Instant::now();
    let _ = cache.get_or_generate("test", &expr)?;
    let cached_time = start.elapsed();
    println!("   Time: {:?}", cached_time);
    println!("   Speedup: {:.2}x", initial_time.as_nanos() as f64 / cached_time.as_nanos().max(1) as f64);

    // After cache invalidation
    println!("\n3. After cache invalidation:");
    cache.invalidate("test");
    let start = Instant::now();
    let _ = cache.get_or_generate("test", &expr)?;
    let invalidated_time = start.elapsed();
    println!("   Time: {:?}", invalidated_time);

    // Test Salsa for type checking
    println!("\n4. Testing Salsa incremental type checking:");
    let mut db = XsDatabaseImpl::new();
    let key = SourcePrograms {
        path: "test.vibe".to_string(),
        content: source.to_string(),
    };
    db.set_source_text(key.clone(), Arc::new(source.to_string()));
    
    // Initial type check
    let start = Instant::now();
    let _ = db.type_check(key.clone())?;
    println!("   Initial type check: {:?}", start.elapsed());
    
    // Cached type check
    let start = Instant::now();
    let _ = db.type_check(key.clone())?;
    println!("   Cached type check: {:?}", start.elapsed());

    Ok(())
}

/// Compare WASM generation vs interpreter execution
pub fn compare_wasm_vs_interpreter(file: &Path) -> Result<()> {
    println!("Comparing WASM generation vs interpreter execution...\n");

    let source = std::fs::read_to_string(file)
        .with_context(|| format!("Failed to read file: {}", file.display()))?;

    // Parse once
    let expr = vibe_core::parser::parse(&source)
        .map_err(|e| anyhow::anyhow!("Parse error: {}", e))?;

    // 1. Interpreter execution time
    let start = Instant::now();
    let mut interpreter = vibe_runtime::Interpreter::new();
    let env = vibe_core::Environment::default();
    let _ = interpreter.eval(&expr, &env)?;
    let interp_time = start.elapsed();
    println!("Interpreter execution: {:?}", interp_time);

    // 2. WASM generation time (including all compilation steps)
    let start = Instant::now();
    let _ = generate_wasm_direct(&expr)?;
    let wasm_gen_time = start.elapsed();
    println!("WASM generation: {:?}", wasm_gen_time);

    println!(
        "\nWASM generation is {:.2}x slower than interpreter execution",
        wasm_gen_time.as_nanos() as f64 / interp_time.as_nanos() as f64
    );

    println!("\nNote: WASM generation is a one-time cost. After caching:");
    println!("- Subsequent runs would use cached WASM (near-zero cost)");
    println!("- WASM execution would be faster than interpreter");

    Ok(())
}