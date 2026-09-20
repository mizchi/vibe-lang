# WasmFX effect backend feasibility

The runtime feasibility probe in `tools/wasmfx_effect_probe` pins
`mizchi/wasmtime-threads` revision
`e1fb408fb7258ac8d1207084af4e1988b3c7db87`. That revision supports stack
switching on Apple Silicon macOS **and on Linux x64** -- the second half
measured 2026-09-20, where the pinned revision built in 2m31s under rustc
1.97.1 and all three probe cases passed.

That matters for sequencing rather than for the feasibility claim: #2221's
acceptance gate asks for "Apple Silicon macOS and Linux x64 [to] pass the same
WasmFX test matrix", and until this measurement the probe had only ever been
run on one of the two. It is the runtime half of that gate, not the compiler
half -- nothing here says a backend can be built, only that the platform does
not block one.

The probe demonstrates that WasmFX can represent three cases restricted by
the current suspend-CPS lowering:

- suspension through an opaque call while retaining native frames and operand
  stack values;
- handler processing after a resumed continuation returns;
- dynamic forwarding through an intermediate handler that does not handle the
  operation.

These results establish runtime feasibility only. They do not add a compiler
backend, change the current effect lowering, or change the default artifact
format. The probe also does not establish semantics for stored continuations,
cancellation, failure propagation, or multi-worker scheduling.

The implementation plan and acceptance criteria are tracked in
[issue #2221](https://github.com/mizchi/vibe-lang/issues/2221).
