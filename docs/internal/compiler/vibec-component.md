# vibec.wasm — the compiler core as a separate component (#1107 Phase 5 / #857)

This document covers the design and current state of `vibec.component.wasm`,
which exposes only the vibe compiler's pure compile surface through the
component model. It is the implementation of #857's runner-independent
embedding.

## Artifacts and build

```bash
bash scripts/build_vibec.sh            # _build/vibec/{vibec.core.wasm, vibec.component.wasm, vibec.wit}
bash scripts/vibec_browser_poc.sh      # the above + jco transpile + in-memory compile→run PoC
```

- **core**: `lib/@vibe/compiler/cli_direct_component_entry.vibe` compiled with
  `__no_entry__` (library mode). Its surface is
  `compile_cli_request(source, request) -> String`.
  - Sources are passed **inline**, as a hex payload of NUL-separated
    (path, source) pairs.
  - The output wasm comes back in hex chunks.
  - The compile path's effect row carries neither Env nor Fs, so it never
    reaches a host import at run time.
- **componentization**: `scripts/vibec_componentize.vibex` (the same
  script-tool pattern as vibe-opt) calls
  `comp_emit_component_wasm_string_handler_stubbed`. That lifts the core to the
  canonical-ABI `compile: func(source: string, request: string) -> string`.
  - Sibling exports of the library build reference the `vibe.env-get` and
    `vibe.fs_*` imports. Stubs inside the component absorb them:
    - `env-get` returns the empty string (unset);
    - `fs_*` is `unreachable`.
  - The compile surface's row guarantees these are dynamically unreachable. A
    violation shows up immediately as a trap.
  - The serve-handler path still rejects them strictly.

## WIT world (compile surface)

Shipped as `_build/vibec/vibec.wit`:

```wit
package vibe:vibec@0.1.0;

world vibec {
  export compile: func(source: string, request: string) -> string;
}
```

The request protocol is the same as `cli_direct_component_entry.vibe`'s:

| request | meaning |
|---|---|
| `probe-part-count` | number of parts in the payload |
| `probe-main-source-len` | length of the main source |
| `len-mode:<mode>:<entry>` | compile, return the byte length (the result is cached) |
| `hex-chunk-mode:<mode>:<entry>:<n>` | the n-th 1024-byte hex chunk |

Every error is `""`; an Error is discharged internally.

## vfs callback surface (implemented in #1109-2)

This second surface lets a host that has a filesystem pass a large project
without inlining it as hex. `vibec.hosted.component.wasm` implements this world
(shipped as `vibec-hosted.wit`):

```wit
world vibec-hosted {
  import read-file:  func(path: string) -> string;   // traps on a missing path
  import exists:     func(path: string) -> bool;
  import read-dir-nul: func(path: string) -> string; // NUL-joined names (#2957)
  import stat-token: func(path: string) -> s64;      // stable token; -1 = non-regular
  export compile-file: func(input-path: string, request: string) -> string;
}
```

- **Entry:** `compile_file_request(input_path, request)` in
  `cli_direct_component_entry.vibe`.
  - The request protocol is the same as `compile`'s (len-mode / hex-chunk-mode).
  - Compilation goes through `compile_release_file_mode_uncached`.
- **Componentization:** `comp_emit_component_wasm_string_handler_vfs` connects
  the core's `vibe.fs_*` imports to canon-lowered component imports.
  - Instantiation is circular: main imports vfs, and lowering vfs needs main's
    memory. The cycle is broken with the same **shim/fixup scheme** that
    wit-component uses, in this order:
    1. a shim with a funcref table;
    2. main;
    3. a memory / `__heap_ptr` alias;
    4. a bump realloc module;
    5. canon lower (memory + realloc options);
    6. a raw i64 ⇔ canonical ptr/len adapter, whose active element segment
       plants the implementations into the shim's table.
  - The raw ABI requires realloc to keep `__heap_ptr` 8-aligned at all times,
    because the low bits carry tags.
  - The write-side host imports (`fs_write_file` / `fs_write_bytes`) are
    zero-returning no-op stubs, which the compiler treats as a cache miss.
- **Directory framing (#2957):**
  - `read-dir-nul` joins names with NUL, the one byte a POSIX name cannot
    contain.
  - A core built by a compiler from before #2957 — the committed seed, which
    `build_vibec.sh` uses by default — still imports the "\n"-framed
    `vibe.fs_read_dir`. The componentizer detects that import and wraps such a
    core with the legacy `read-dir` import instead, and `build_vibec.sh`
    declares the same in `vibec-hosted.wit`.
  - Both sides therefore keep the framing they were built for. The legacy path
    goes once the seed emits `fs_read_dir_nul`.
- **PoC:** `scripts/vibec_hosted_poc_driver.mjs` uses an in-memory Map as the
  vfs. It compiles a multi-file program (`import ./lib.vibe`) and runs it to 42
  using only browser-equivalent APIs. `vibec_browser_poc.sh` checks both
  surfaces.

## Browser PoC

`scripts/vibec_browser_poc.sh` demonstrates:

1. `jco transpile vibec.component.wasm` produces ESM plus the core wasm. No
   WASI shim is needed, because the component is self-contained.
2. The driver (`scripts/vibec_poc_driver.mjs`) uses only APIs available in a
   browser:
   - `compile(hex_payload, "len-mode:mvp:answer")` returns the byte length;
   - `hex-chunk-mode` collects the chunks into a `Uint8Array`;
   - `WebAssembly.instantiate(bytes, { wasi_snapshot_preview1: { fd_write } })`;
   - 42 is confirmed both by calling `answer(0n)` directly (a user function
     takes a closure-env i64 first) and by capturing `_start`'s stdout.

node is only a headless stand-in. The driver code runs unchanged in a
`<script type="module">`; only loading the sample switches to fetch.

## Switching runtime/vibe over (#857 open question)

- The `vibe` CLI's compile commands currently go through `vibe-cli.wasm` (the
  env-mode adapter). **The launcher already has a substitution seam
  (`VIBE_CLI_WASM` / `VIBE_RUNNER`), and that seam is enough to use vibec for
  the compile surface.**
- Moving the whole CLI to composition (wac) goes together with two other
  changes: the vfs surface, and a new `vibe self update` artifact layout that
  also ships `lib/vibec.component.wasm`.
- **No backward-compatibility alias is needed.** There is no compatibility
  guarantee before the first release (#1107's premise), and the user-facing
  `vibe` subcommands do not change. Only the internal layout of the
  distribution does.

## Relation to size (#1107 Phases 2-4)

- The component core depends on lifting exports by name. ADR-0077's export
  filter therefore leaves `__no_entry__` builds alone, which keeps this safe.
- The core is ~4.9 MB as a library build.
  - By default, `build_vibec.sh` runs `minify_wasm.sh --keep-exports
    compile_cli_request,memory,__heap_ptr --per-pass`. That DCEs the core down
    to the compile surface: **~3.85 MB (-22%)** (#1109-1).
  - The browser PoC passes in full with the reduced component.
  - `VIBE_VIBEC_NO_MINIFY=1` skips the minify step.
- Phase 4 (funcref table minimization) reduces the element roots, which
  directly improves this DCE.
