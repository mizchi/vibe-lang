#!/usr/bin/env node
// Map implementation benchmark: linear scan vs open-addressing hash table
// Usage: node run_map_bench.js

const fs = require('fs');
const path = require('path');

async function loadWasm(file) {
  const buf = fs.readFileSync(path.join(__dirname, file));
  const mod = await WebAssembly.compile(buf);
  const inst = await WebAssembly.instantiate(mod, {});
  return inst;
}

function bench(fn, warmup = 5, iters = 50) {
  // Warmup
  for (let i = 0; i < warmup; i++) fn();
  // Measure
  const times = [];
  for (let i = 0; i < iters; i++) {
    const t0 = performance.now();
    fn();
    times.push(performance.now() - t0);
  }
  times.sort((a, b) => a - b);
  const median = times[Math.floor(times.length / 2)];
  const p95 = times[Math.floor(times.length * 0.95)];
  const mean = times.reduce((a, b) => a + b, 0) / times.length;
  return { median, p95, mean, min: times[0], max: times[times.length - 1] };
}

async function main() {
  const linearInst = await loadWasm('map_linear.wasm');
  const hashInst = await loadWasm('map_hash.wasm');

  const sizes = [10, 50, 100, 200, 500];

  console.log('=== Map Benchmark: Linear Scan vs Hash Table ===');
  console.log('Each run: insert N entries + lookup all N (string keys)');
  console.log('');
  console.log('N'.padStart(6) + ' | ' +
    'linear_ms'.padStart(10) + ' | ' +
    'hash_ms'.padStart(10) + ' | ' +
    'speedup'.padStart(8) + ' | ' +
    'linear_sum'.padStart(12) + ' | ' +
    'hash_sum'.padStart(12));
  console.log('-'.repeat(70));

  for (const n of sizes) {
    const linearResult = linearInst.exports.bench_linear(n);
    const hashResult = hashInst.exports.bench_hash(n);

    const linearStats = bench(() => linearInst.exports.bench_linear(n));
    const hashStats = bench(() => hashInst.exports.bench_hash(n));

    const speedup = (linearStats.median / hashStats.median).toFixed(2);

    console.log(
      String(n).padStart(6) + ' | ' +
      linearStats.median.toFixed(3).padStart(10) + ' | ' +
      hashStats.median.toFixed(3).padStart(10) + ' | ' +
      (speedup + 'x').padStart(8) + ' | ' +
      String(linearResult).padStart(12) + ' | ' +
      String(hashResult).padStart(12)
    );
  }

  console.log('');
  console.log('Detailed stats (N=100):');
  const n = 100;
  const ls = bench(() => linearInst.exports.bench_linear(n), 10, 100);
  const hs = bench(() => hashInst.exports.bench_hash(n), 10, 100);
  console.log(`  linear: median=${ls.median.toFixed(3)}ms mean=${ls.mean.toFixed(3)}ms p95=${ls.p95.toFixed(3)}ms min=${ls.min.toFixed(3)}ms`);
  console.log(`  hash:   median=${hs.median.toFixed(3)}ms mean=${hs.mean.toFixed(3)}ms p95=${hs.p95.toFixed(3)}ms min=${hs.min.toFixed(3)}ms`);
  console.log(`  ratio:  ${(ls.median / hs.median).toFixed(2)}x`);

  // Expected sum for verification: sum(0..n-1) = n*(n-1)/2
  const expected = n * (n - 1) / 2;
  console.log(`\nVerification (N=${n}): expected sum=${expected}, linear=${linearInst.exports.bench_linear(n)}, hash=${hashInst.exports.bench_hash(n)}`);
}

main().catch(console.error);
