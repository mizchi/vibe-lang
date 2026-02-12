///|
test "bench: vibe.runtime.eval_script" (b : @bench.T) {
  b.bench(fn() {
    let caps = @capability.CapabilitySet::new()
    let rt = @runtime.Runtime::new(caps)
    b.keep(try? rt.eval_script(sample_script))
  })
}
