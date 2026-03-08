///|
/// vibe bench runner for `bench {}` blocks
struct BenchCase {
  name : String?
  body : @core.Module
} derive(Show, Eq)

///|
pub struct BenchFailure {
  name : String?
  error : String
} derive(Show, Eq)

///|
pub struct BenchResult {
  name : String?
  iterations : Int
  warmup : Int
  elapsed_ms : Double
  per_us : Double
} derive(Show, Eq)

///|
pub struct BenchReport {
  total : Int
  passed : Int
  failed : Int
  results : Array[BenchResult]
  failures : Array[BenchFailure]
} derive(Show, Eq)

///|
fn collect_benches(ast : @core.Module) -> Array[BenchCase] {
  let out : Array[BenchCase] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Bench(name~, body~, span~) => {
        let _ = span
        out.push(BenchCase::{ name, body })
      }
      _ => ()
    }
  }
  out
}

///|
/// Run all benchmarks in a module (legacy: fixed iteration count, single measurement).
pub fn Runtime::run_benches(
  self : Runtime,
  ast : @core.Module,
  count : Int,
  warmup : Int,
) -> BenchReport raise EvalError {
  if count <= 0 {
    raise EvalError::BadCall(E("bench: count must be > 0"))
  }
  if warmup < 0 {
    raise EvalError::BadCall(E("bench: warmup must be >= 0"))
  }
  let _ = self.eval_module(ast)
  let cases = collect_benches(ast)
  let results : Array[BenchResult] = []
  let failures : Array[BenchFailure] = []
  let mut passed = 0
  for case in cases {
    let bench_rt = self.fork_for_test()
    let mut failed = false
    try {
      for _ in 0..<warmup {
        let _ = bench_rt.eval_module(case.body)
      }
    } catch {
      e => {
        failures.push(BenchFailure::{ name: case.name, error: e.to_string() })
        failed = true
      }
    }
    if failed {
      continue
    }
    let start = @bench.monotonic_clock_start()
    try {
      for _ in 0..<count {
        let _ = bench_rt.eval_module(case.body)
      }
    } catch {
      e => {
        failures.push(BenchFailure::{ name: case.name, error: e.to_string() })
        failed = true
      }
    }
    if failed {
      continue
    }
    let elapsed_us = @bench.monotonic_clock_end(start)
    let elapsed_ms = elapsed_us / 1000.0
    let per_us = elapsed_us / count.to_double()
    results.push(BenchResult::{
      name: case.name,
      iterations: count,
      warmup,
      elapsed_ms,
      per_us,
    })
    passed += 1
  }
  {
    total: cases.length(),
    passed,
    failed: failures.length(),
    results,
    failures,
  }
}

///|
/// Run all benchmarks with statistical sampling (like moon bench).
/// Auto-calibrates batch_size, collects `runs` samples, computes stats.
pub fn Runtime::run_benches_statistical(
  self : Runtime,
  ast : @core.Module,
  runs : Int,
  warmup : Int,
) -> BenchSummaryReport raise EvalError {
  if runs <= 0 {
    raise EvalError::BadCall(E("bench: runs must be > 0"))
  }
  if warmup < 0 {
    raise EvalError::BadCall(E("bench: warmup must be >= 0"))
  }
  let _ = self.eval_module(ast)
  let cases = collect_benches(ast)
  let results : Array[BenchSummary] = []
  let failures : Array[BenchFailure] = []
  let mut passed = 0
  for case in cases {
    let bench_rt = self.fork_for_test()
    let mut failed = false
    // Auto-calibrate batch_size (target ~100ms per sample)
    let threshold_us = 100000.0
    let batch_size = calibrate_batch_size(
      fn(trial) {
        let start = @bench.monotonic_clock_start()
        try {
          for _ in 0..<trial {
            let _ = bench_rt.eval_module(case.body)
          }
        } catch {
          _ => ()
        }
        @bench.monotonic_clock_end(start)
      },
      threshold_us,
    )
    // Warmup
    try {
      for _ in 0..<warmup {
        for _ in 0..<batch_size {
          let _ = bench_rt.eval_module(case.body)
        }
      }
    } catch {
      e => {
        failures.push(BenchFailure::{ name: case.name, error: e.to_string() })
        failed = true
      }
    }
    if failed {
      continue
    }
    // Collect samples
    let samples : Array[Double] = []
    try {
      for _ in 0..<runs {
        let start = @bench.monotonic_clock_start()
        for _ in 0..<batch_size {
          let _ = bench_rt.eval_module(case.body)
        }
        let elapsed_us = @bench.monotonic_clock_end(start)
        samples.push(elapsed_us / batch_size.to_double())
      }
    } catch {
      e => {
        failures.push(BenchFailure::{ name: case.name, error: e.to_string() })
        failed = true
      }
    }
    if failed {
      continue
    }
    results.push(compute_bench_summary(case.name, samples, batch_size, 0))
    passed += 1
  }
  {
    total: cases.length(),
    passed,
    failed: failures.length(),
    results,
    failures,
  }
}
