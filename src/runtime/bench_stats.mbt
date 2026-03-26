///|
/// Statistical functions for benchmark analysis.
/// Ported from moonbitlang/core/bench/stats.mbt to keep fields accessible.

///|
pub struct BenchSummary {
  name : String?
  runs : Int
  batch_size : Int
  min : Double
  max : Double
  mean : Double
  median : Double
  std_dev : Double
  std_dev_pct : Double
  median_abs_dev : Double
  median_abs_dev_pct : Double
  quartiles : (Double, Double, Double)
  iqr : Double
  wasm_bytes : Int
} derive(Show, Eq)

///|
fn bench_percentile(sorted : Array[Double], pct : Double) -> Double {
  if sorted.length() == 0 {
    return 0.0
  }
  if sorted.length() == 1 {
    return sorted[0]
  }
  if pct >= 100.0 {
    return sorted[sorted.length() - 1]
  }
  let length = (sorted.length() - 1).to_double()
  let rank = pct / 100.0 * length
  let lrank = rank.floor()
  let d = rank - lrank
  let n = lrank.to_int()
  let lo = sorted[n]
  let hi = sorted[n + 1]
  lo + (hi - lo) * d
}

///|
fn bench_sum(data : Array[Double]) -> Double {
  let mut s = 0.0
  for v in data {
    s += v
  }
  s
}

///|
fn bench_mean(data : Array[Double]) -> Double {
  if data.length() == 0 {
    return 0.0
  }
  bench_sum(data) / data.length().to_double()
}

///|
fn bench_median(sorted : Array[Double]) -> Double {
  bench_percentile(sorted, 50.0)
}

///|
fn bench_variance(data : Array[Double], mean : Double) -> Double {
  if data.length() < 2 {
    return 0.0
  }
  let mut v = 0.0
  for x in data {
    let d = x - mean
    v += d * d
  }
  v / (data.length() - 1).to_double()
}

///|
fn bench_std_dev(variance : Double) -> Double {
  variance.sqrt()
}

///|
fn bench_median_abs_dev(sorted : Array[Double], median : Double) -> Double {
  let abs_devs = sorted.map(fn(x) { (median - x).abs() })
  abs_devs.sort()
  bench_percentile(abs_devs, 50.0) * 1.4826
}

///|
fn bench_winsorize(sorted : Array[Double], pct : Double) -> Unit {
  let lo = bench_percentile(sorted, pct)
  let hi = bench_percentile(sorted, 100.0 - pct)
  for i, v in sorted {
    if v > hi {
      sorted[i] = hi
    } else if v < lo {
      sorted[i] = lo
    }
  }
}

///|
fn bench_quartiles(sorted : Array[Double]) -> (Double, Double, Double) {
  (
    bench_percentile(sorted, 25.0),
    bench_percentile(sorted, 50.0),
    bench_percentile(sorted, 75.0),
  )
}

///|
pub fn compute_bench_summary(
  name : String?,
  samples : Array[Double],
  batch_size : Int,
  wasm_bytes : Int,
) -> BenchSummary {
  samples.sort()
  bench_winsorize(samples, 5.0)
  let min = if samples.length() > 0 { samples[0] } else { 0.0 }
  let max = if samples.length() > 0 {
    samples[samples.length() - 1]
  } else {
    0.0
  }
  let mean = bench_mean(samples)
  let median = bench_median(samples)
  let variance = bench_variance(samples, mean)
  let std_dev = bench_std_dev(variance)
  let std_dev_pct = if mean == 0.0 { 0.0 } else { std_dev / mean * 100.0 }
  let mad = bench_median_abs_dev(samples, median)
  let mad_pct = if median == 0.0 { 0.0 } else { mad / median * 100.0 }
  let quartiles = bench_quartiles(samples)
  let (q1, _, q3) = quartiles
  let iqr = q3 - q1
  {
    name,
    runs: samples.length(),
    batch_size,
    min,
    max,
    mean,
    median,
    std_dev,
    std_dev_pct,
    median_abs_dev: mad,
    median_abs_dev_pct: mad_pct,
    quartiles,
    iqr,
    wasm_bytes,
  }
}

///|
pub fn calibrate_batch_size(
  run_n : (Int) -> Double,
  threshold_us : Double,
) -> Int {
  let batch_size = loop 1 {
    trial => {
      let elapsed = run_n(trial)
      let single_us = elapsed / trial.to_double()
      if trial.to_double() * single_us > threshold_us {
        let target = threshold_us /
          (if single_us < 1.0 { 1.0 } else { single_us })
        break if target < 1.0 { 1 } else { target.ceil().to_int() }
      }
      continue trial * 2
    }
  }
  batch_size
}
