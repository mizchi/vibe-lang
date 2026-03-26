// TODO(issue#20): evaluator ベンチマーク。evaluator 削除時に削除する。

///|
test "bench: vibe.runtime.eval_script" (b : @bench.T) {
  b.bench(fn() {
    let caps = @capability.CapabilitySet::new()
    let rt = @runtime.Runtime::new(caps)
    b.keep(try? rt.eval_script(sample_script))
  })
}
