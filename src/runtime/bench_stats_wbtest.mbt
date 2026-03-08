///|
test "bench_percentile basics" {
  assert_eq(bench_percentile([], 50.0), 0.0)
  assert_eq(bench_percentile([42.0], 50.0), 42.0)
  assert_eq(bench_percentile([1.0, 2.0, 3.0], 100.0), 3.0)
  assert_eq(bench_percentile([1.0, 2.0, 3.0], 0.0), 1.0)
  assert_eq(bench_percentile([1.0, 2.0, 3.0], 50.0), 2.0)
}

///|
test "bench_mean" {
  assert_eq(bench_mean([]), 0.0)
  assert_eq(bench_mean([10.0]), 10.0)
  assert_eq(bench_mean([1.0, 2.0, 3.0]), 2.0)
}

///|
test "bench_median" {
  assert_eq(bench_median([1.0, 2.0, 3.0]), 2.0)
  assert_eq(bench_median([1.0, 2.0, 3.0, 4.0]), 2.5)
}

///|
test "bench_variance" {
  // Less than 2 data points => 0
  assert_eq(bench_variance([1.0], 1.0), 0.0)
  // [1, 2, 3] mean=2, variance = ((1+0+1)/2) = 1.0
  assert_true(bench_variance([1.0, 2.0, 3.0], 2.0).is_close(1.0))
}

///|
test "bench_std_dev" {
  assert_true(bench_std_dev(4.0).is_close(2.0))
  assert_true(bench_std_dev(0.0).is_close(0.0))
}

///|
test "bench_quartiles" {
  let (q1, q2, q3) = bench_quartiles([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0])
  assert_true(q1 < q2)
  assert_true(q2 < q3)
}

///|
test "bench_winsorize" {
  let data = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 100.0]
  bench_winsorize(data, 5.0)
  // After winsorize, extreme values should be clipped
  assert_true(data[data.length() - 1] <= 100.0)
}

///|
test "compute_bench_summary" {
  let samples = [10.0, 12.0, 11.0, 13.0, 9.0, 10.5, 11.5, 12.5, 10.0, 11.0]
  let summary = compute_bench_summary(Some("test_bench"), samples, 100, 5000)
  assert_eq(summary.name, Some("test_bench"))
  assert_eq(summary.runs, 10)
  assert_eq(summary.batch_size, 100)
  assert_eq(summary.wasm_bytes, 5000)
  assert_true(summary.min <= summary.max)
  assert_true(summary.mean >= summary.min)
  assert_true(summary.mean <= summary.max)
  assert_true(summary.median >= summary.min)
  assert_true(summary.median <= summary.max)
  assert_true(summary.std_dev >= 0.0)
  assert_true(summary.std_dev_pct >= 0.0)
  assert_true(summary.median_abs_dev >= 0.0)
  let (q1, q2, q3) = summary.quartiles
  assert_true(q1 <= q2)
  assert_true(q2 <= q3)
  assert_true(summary.iqr >= 0.0)
}

///|
test "calibrate_batch_size" {
  // Simulate: each iteration takes ~1000us
  let batch_size = calibrate_batch_size(
    fn(n) { n.to_double() * 1000.0 },
    100000.0,
  )
  // target ~100ms, each iter ~1ms => batch_size ~100
  assert_true(batch_size >= 50)
  assert_true(batch_size <= 200)
}
