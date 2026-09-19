# Host runtime execution contract

This document fixes the first machine-checked slice of the host ABI requested by
#1346. The source of truth for the covered names and their core signatures is
[`host-runtime-contract.json`](../../generated/host-runtime-contract.json); run
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

Signatures are checked on the emitter side, and **on the viberun provider side**:
the gate parses each `linker.func_wrap("vibe", ..)` closure, drops the
`Caller<'_, HostState>` host context, maps `Result<T>` to `T`, and compares the
result against the emitter's declared core signature. 51 providers agree today.
Presence-by-name alone caught a provider that was MISSING and said nothing about
one present with the wrong arity or result type -- which wasmtime reports at link
time as an opaque signature error, after the emitter and the runner have each
been reviewed and each looked right on its own.

A closure the parser cannot read FAILS the gate rather than being skipped: an
unreadable provider is exactly where a drift would hide. (Measured while writing
it -- splitting the parameter list on `,` shreds `Caller<'_, HostState>`, which
silently turned 51 readable providers into 49 unreadable ones.)

The Node runner's callable types are still unchecked: its providers are plain
JavaScript functions with no declared parameter types, so arity is the only
comparable property and the emitter's `i64`/`i32` distinction has no counterpart
there.

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

This is deliberately a first slice. The design that closes it -- a generated
`vibe:host` WIT whose functions the raw `vibe.*` imports are the lowering of,
a `vibe.entry` section, and a manifest column for lazy dispatch -- is
[host-contract-artifact-lazy-cli.md](../../internal/design/host-contract-artifact-lazy-cli.md)
(ADR-0112, proposed). The legacy MoonBit-host import list (`runtime/viberun/expected_imports.txt`,
32 `__moonbit_fs_unstable` fields) was RETIRED rather than reconciled: the host
it described went with #594, no code in the tree read the file, and its only
reference was this page. The emitted surface is `vibe.*`, and the honest
inventory of it is the emitters themselves -- measured 2026-09-19, 62 fields
from `codegen/wasi/linked_compile.vibe` and 23 from `codegen/gc/backend_body.vibe`,
agreeing where both emit. `node scripts/host_capability_probe.mjs <module.wasm>`
reports what one artifact actually imports.

#1346 remains open for:

- executable signature comparison against the NODE provider (the viberun half
  has landed: 51 `func_wrap` closures are compared against the emitter's core
  signatures, with mutation tests in
  `tests/gates/tooling-accounting/host-runtime/host_runtime_contract_test.py`);
- semantic conformance fixtures for failures, path rules, handle lifecycle,
  byte sorting, and packed-value edge cases;
- a complete WIT/raw projection inventory for async, socket, HTTP, and generated
  named imports.
