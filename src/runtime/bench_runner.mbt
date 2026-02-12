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
/// Run all benchmarks in a module.
pub fn Runtime::run_benches(
  self : Runtime,
  ast : @core.Module,
  count : Int,
  warmup : Int,
) -> BenchReport raise EvalError {
  if count <= 0 {
    raise EvalError::BadCall("bench: count must be > 0")
  }
  if warmup < 0 {
    raise EvalError::BadCall("bench: warmup must be >= 0")
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
    let start = @env.now()
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
    let end = @env.now()
    let elapsed_ms = (end - start).to_double()
    let per_us = elapsed_ms * 1000.0 / count.to_double()
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
