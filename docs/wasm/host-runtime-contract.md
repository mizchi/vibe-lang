# Host runtime execution contract

This document fixes the first machine-checked slice of the host ABI requested by
#1346. The source of truth for the covered names and their core signatures is
[`host-runtime-contract.json`](host-runtime-contract.json); run
`python3 scripts/check_host_runtime_contract.py` after changing an emitter or
runner.

## Three boundaries, not one

### Raw core-Wasm imports

The linear backend emits capability calls as functions imported from module
`vibe`. These are an internal core-Wasm ABI used by standalone `.wasm` output.
Imports are demand-gated, so a program need only receive the authority named by
its actual import section. `wasi_snapshot_preview1.fd_write` is separate and is
not part of `vibe.*`.

The portable band in the manifest is emitted by
`codegen/wasi/linked_compile.vibe` and provided by both
`runtime/viberun/src/main.rs` and `scripts/wasm_vibe_host_runner.js`. The gate
extracts names from all three production files. A newly emitted static name,
a removed provider, an undocumented type index, or an import placed in two
bands fails closed.

Values use the compiler's raw core ABI:

- `i64` string arguments/results are packed `(ptr << 32) | byte_len`; strings are
  byte strings. The provider reads/writes guest linear memory.
- `Bytes` is a guest pointer to `{ capacity@0, length@4, data_ptr@8 }`.
- raw integer and boolean host results are untagged `i64`; generated shims convert
  them to the language's tagged value representation where required.
- handles (HTTP, TCP, subprocess) are opaque `i64` values whose lifecycle is
  defined by their matching close operation.

The manifest maps compiler type indices to core signatures. Two generated type
indices are named explicitly: `http_request_type_idx` and `dbg_line_type_idx`.
This first slice checks signatures on the emitter side and provider presence by
name; it does not yet parse Rust/JavaScript callable types.

Two explicit standalone exceptions are contractual rather than omissions:

- `resolve_path` is currently provided only by the Node runner.
- `dbg_break` and `dbg_line` are viberun debugger hooks and are not Node
  portability requirements.

### Residual/WIT component contracts

`host_future_*`, `host_stream_*`, and `stdin_provider_*` may appear as
`vibe.*` imports in an intermediate core module, but they are **not standalone
host imports**. `component_codegen.vibe` supplies them with generated adapter
core modules and projects them to component-model future/stream and
`wasi:cli/stdin` contracts. Named imports use the dynamic forms
`host_future_get$<name>` and `host_stream_get$<name>`.

Consequently the conformance gate requires these names to be emitted and
classified, and rejects their accidental appearance in either standalone
runner. The public component boundary is the residual/WIT contract, not these
private adapter names.

### Wasmtime implementation details

`viberun` uses Wasmtime `Linker::func_wrap`, guest-memory helpers, and sentinel
traps to implement the core contract. Those APIs, engine collection behavior,
backtrace support, and component `func_wrap_concurrent` driving are embedding
choices, not guest ABI. Likewise Node's filesystem/process APIs are provider
choices. A conforming provider must implement the observable imports and value
layout, not copy either implementation.

## Residual scope

This is deliberately a first slice. #1346 remains open for:

- executable signature comparison against both provider implementations;
- semantic conformance fixtures for failures, path rules, handle lifecycle,
  byte sorting, and packed-value edge cases;
- a complete WIT/raw projection inventory for async, socket, HTTP, and generated
  named imports;
- reconciliation or retirement of legacy MoonBit-host imports in
  `runtime/viberun/expected_imports.txt`.
