# WasmFX effect backend feasibility

The runtime feasibility probe in `tools/wasmfx_effect_probe` pins
`mizchi/wasmtime-threads` revision
`e1fb408fb7258ac8d1207084af4e1988b3c7db87`. That revision supports stack
switching on Apple Silicon macOS.

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
