# Host ABI of `vibe build` output

What a host must provide to run the `.wasm` that `vibe build` writes. Every
statement here was measured: the import and export sections of built modules,
run on plain `wasmtime` (pinned seed `array-capacity-2026-09-20`, wasmtime 47,
2026-10-02). `scripts/test_host_abi.js` pins the contract in CI (see
[CI enforcement](#ci-enforcement)).

This is the contract of the **default linear lane**. `VIBE_BACKEND=gc` selects
the opt-in wasm-gc backend, whose output uses wasm-gc instructions
(`struct.new`, `array.new`, ...); a host for that output also needs the GC
proposal, and this document does not cover it.

## Summary

- The output is a **core wasm module with linear memory**, not a component.
- The host provides **`wasi_snapshot_preview1::fd_write`, always, plus the
  `vibe::*` functions for the effects the program uses**. That includes
  `Console`: `println` imports `vibe::stdout_write_stream` and
  `vibe::stdout_write_char`.
- **The exception-handling proposal is needed only by a module that defines a
  tag.** A program that throws or handles an exception does, and so does the
  measured `Fs` program; both export an `error` tag. A program with no effects,
  or one that only prints, defines no tag and runs on a host without the
  proposal (#716/#733).
- **The fixed-width SIMD proposal (`v128`) is needed by a module that uses
  any builtin implemented with it**, and that set is wider than the names
  suggest. Besides the SIMD scan builtins (`simd_skip_ws` and the other
  `simd_scan_*`), it includes String equality and comparison, and
  `Bytes::index_of` / `last_index_of` / `count` / `compare` and substring
  search. The list is not exhaustive: the builtin bodies under
  `lib/@vibe/compiler/codegen/builtin_bodies/` are authoritative. A builtin's
  body is emitted only when the program uses it, so a program that uses none
  of them carries no `v128` instruction.
- **A program with no host capability runs on any WASI Preview 1 host** that
  also supports SIMD if the program uses one of those builtins. Plain
  `wasmtime run pure.wasm` prints `5`. Effects the program declares and handles
  itself (a user `effect`, or `Exception` caught by a `handle`) import nothing.
- **A program that uses a host capability (`Fs`, `Console`, `Http`, ...)
  needs a host that implements the `vibe::*` ABI**, which today is `viberun`.
  A host with only standard WASI fails to instantiate it with
  `unknown import: vibe::fs_read_file`.
- **The default linear path is not wasip3.** It is Preview 1 `fd_write` plus
  `vibe::*`; wasip3 is the target of the separate component path (§4).

## 1. Artifact shape

| Item | Value |
|---|---|
| module kind | core wasm, linear memory (not a component) |
| proposals | exception-handling, only when the module defines a tag (§3); fixed-width SIMD, only when it uses a `v128` builtin (Summary) |
| exports | `_start` (the WASI command entry), the entry function (`main`, or the name given to `--entry`), `memory`, `__heap_ptr` (global); plus the `error` and `__exception_throw_tag` tags when the module uses exceptions |

`_start` writes the entry's result to stdout through `fd_write`, so **every
program imports `fd_write`**, whether or not it prints anything itself.

## 2. Import contract

### 2.1 Always required

- `wasi_snapshot_preview1::fd_write`, for stdout and stderr (the result and
  panics). This is standard WASI Preview 1.

### 2.2 `vibe::*`, per effect

Values are vibe tagged i64s. A packed string or bytes argument is an i64 that
points into linear memory, and the host reads and writes it through the
exported `memory` (see `vibe_read_packed_str` in `runtime/viberun`).

> **The pointer inside a packed value is an unsigned 32-bit number.** The fat
> pointer is `(ptr << 32) | len`. Once the guest heap passes 2 GiB, bit 31 of
> `ptr` is set, and so is bit 63 of the i64. The JS WebAssembly API hands an
> i64 over as a **signed** BigInt, so a host that extracts the pointer with
> `packed >> 32n` (an arithmetic shift) gets a **negative pointer** and fails
> with `string range out of bounds`. A host must reinterpret the 64 bits as
> unsigned before taking the upper 32 (`unpackFatPointer` in
> `scripts/wasm_vibe_host_runner.js`). Below 2 GiB the two readings agree, so
> the mistake **reproduces only on large inputs**.
>
> A real instance: compiling the whole CLI in FS mode with a cold type-env
> cache peaks at 2.6–2.7 GiB of guest heap. The run wrote a correct 22 MB wasm
> and then hit this bug writing the final `.funcmap` sidecar. With a warm
> cache the heap stays under 2 GiB and the run passes, which is why it looked
> flaky.

| effect | import | signature | meaning |
|---|---|---|---|
| `Console` | `vibe::stdout_write_stream` | `(s: i64) -> ()` | write a packed string to stdout |
| `Console` | `vibe::stdout_write_char` | `(code: i64) -> ()` | write one UTF-16 code unit to stdout |
| `Fs` | `vibe::fs_read_file` | `(path: i64) -> i64` | read a file (returns a packed string) |
| `Fs` | `vibe::fs_write_file` | `(path: i64, content: i64) -> ()` | write text |
| `Fs` | `vibe::fs_publish_immutable_text` | `(path: i64, content: i64) -> i64` | publish immutable text (tagged `Bool`) |
| `Fs` | `vibe::fs_write_bytes` | `(path: i64, bytes: i64) -> ()` | write bytes |
| `Fs` | `vibe::fs_exists` | `(path: i64) -> i64` | existence (tagged `Bool`) |
| `Fs` | `vibe::fs_stat_token` | `(path: i64) -> i64` | stat token |
| debug | `vibe::dbg_line` | `(file_id: i32, line: i32) -> ()` | `--break` builds only |
| debug | `vibe::dbg_break` | `() -> ()` | `--break` builds only |

Notes:

- The table is an excerpt. `viberun` also provides Process, Shell, Http and
  Tcp (`vibe::sh` / `sh_capture*` / `sh_lines`, `vibe::process_exit`,
  `vibe::http_request` / `http_response_*` / `http_close`, `vibe::tcp_connect`
  / `tcp_read` / `tcp_write` / `tcp_close`). The authoritative provider list is
  [host-runtime-contract.md](host-runtime-contract.md) and
  `docs/generated/host-runtime-contract.json`.
- `Fs::publish_immutable_text(path, content) -> Bool with Fs` publishes the
  exact UTF-8 bytes atomically, and only when the final path does not exist.
  If a regular file is already there, it answers `true` when the raw bytes are
  identical and `false` when they differ. The losing writer never overwrites.
  An I/O error, an unsupported filesystem, or a symlink or non-regular target
  fails closed. The official Node and Rust runners write an exclusive temp file
  in the same directory and then hard-link it into place atomically (no
  replace); cleaning up the temp file is best effort.
- `viberun` still links the legacy `__moonbit_fs_unstable::*`,
  `__moonbit_sys_unstable::*` and `spectest::*` modules from the MoonBit-host
  era. **Neither user output nor the selfhost compiler wasm imports them**
  (measured on the pinned seed's `compiler.wasm`), and `test_host_abi.js`
  asserts that an `Fs` program does not.

## 3. Portability tiers

All measured.

- **Tier 0: no host capability.** The only import is `fd_write`, so the
  module runs on any WASI Preview 1 host (wasmtime, wasmer, Node's
  `node:wasi`, a browser WASI shim, ...): without the exception-handling
  proposal unless it throws or handles an exception, and without SIMD unless
  it uses a `v128` builtin. Measured: `wasmtime run pure.wasm` prints `5`
  (`add(2, 3)`).
- **Tier 1: host capabilities.** The module also imports `vibe::*`, so it needs a host
  that implements the vibe ABI. A module that throws or handles an exception
  also defines tags, and so did the measured `Fs` program; such a module needs
  the exception-handling proposal as well. Measured: plain wasmtime refuses the
  `Fs` program with `unknown import: vibe::fs_read_file`.

So "the output is a `.wasm` that runs anywhere" is true for Tier 0, and true
for Tier 1 only on a host that implements the vibe host ABI.

## 4. Relation to wasip3

- **The default linear path** (`vibe build`, `viberun`) uses Preview 1
  `fd_write` plus `vibe::*`. It is **not** wasip3.
- **The component path**
  (`lib/@vibe/compiler/entry/source_compile/wasi_only/component_codegen.vibe`)
  wraps the module as a WASI component through the canonical ABI
  (`cabi_realloc`) and a Preview 1 adapter. Its target is standard I/O over
  `wasi:io` (Preview 2) and then p3 async
  ([wasi-p3-async.md](../../internal/design/wasi-p3-async.md),
  [decisions.md](../../internal/design/decisions.md)).
- So "I/O assumes wasip3" is the **component path's** direction. Moving the
  core path's effects onto wasip3 would need a separate adapter that maps
  `vibe::fs_*` to `wasi:filesystem` / `wasi:cli`.

## 5. Running the output on another host

To run effectful output in another environment (JS, Rust, Go, ...):

1. Enable the **exception-handling proposal** if the module defines a tag,
   and **fixed-width SIMD** if it contains `v128` instructions.
2. Provide `wasi_snapshot_preview1::fd_write` (writing stdout is enough).
3. Implement **only the `vibe::*` functions the module imports** (§2.2).
   Values are tagged i64s; read packed strings and bytes from the exported
   `memory`.
4. Call `_start`, or invoke the entry function directly (`main`, or the name
   given to `--entry`).

Those four points are the contract. A host that meets them runs the output the
same way `viberun` does.

## CI enforcement

`scripts/test_host_abi.js` (run by the `cli-install` workflow) builds two
programs with the installed `vibe` and pins the contract:

- a pure program imports exactly `wasi_snapshot_preview1::fd_write`, defines no
  `error` tag, and exports `_start` and `memory`;
- an `Fs` program lowers to `vibe::fs_*` and imports neither `wasi:*` nor
  `__moonbit_*`.

A change to what the output asks of its host fails there.

## Appendix: reproducing the contract

```bash
vibe build pure.vibe -o pure.wasm        # Tier 0
vibe build fs_prog.vibe -o fs.wasm       # Tier 1 (Fs effect)

# list the imports (any tool that prints module::field works)
wasm-tools print pure.wasm | grep '(import'   # => wasi_snapshot_preview1 "fd_write"
wasm-tools print fs.wasm   | grep '(import'   # => plus vibe "fs_read_file", ...

# Tier 0 runs on plain wasmtime
wasmtime run pure.wasm                        # => 5

# Tier 1 fails without the vibe host ABI
wasmtime run fs.wasm                          # => unknown import: vibe::fs_read_file
```
