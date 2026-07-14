# Vendored WASI p3 WIT (wasi:http, ratified 0.3.0)

Source: crates.io `wasmtime-wasi-http` 46.0.1, `src/p3/wit/` (byte-identical
copy). Version pin: `wasi:http@0.3.0` — the ratified WIT that wasmtime 46
serves by default (component-model-async on by default, no RC flags
required for the WIT surface itself).

Consumers: `scripts/build_wasi_http_p3_full_adapter.sh` (wit-bindgen
generate! path). Previously this pointed at the `deps/wasmtime` submodule's
copy, which broke everywhere the submodule isn't checked out (CI, fresh
clones) — vendoring makes the p3 gates self-contained (#821).

## wasmtime 46 / ratified WASI 0.3.0 cutover (#821, done)

Refreshed from `wasmtime-wasi-http` 45.0.2's RC WIT
(`wasi:http@0.3.0-rc-2026-03-15`) to 46.0.1's ratified WIT
(`wasi:http@0.3.0`). The diff versus the prior vendor drop is purely
mechanical version-string substitution (`0.3.0-rc-2026-03-15` ->
`0.3.0` in every `package`/`@since`/`use`/`import` line) across
`world.wit`, `deps/http.wit`, `deps/clocks.wit`, `deps/filesystem.wit`,
`deps/random.wit`, plus two additional non-structural changes:

- `deps/cli.wit`: the `cli-exit-with-code` interface graduated from
  `@unstable(feature = cli-exit-with-code)` to `@since(version = 0.3.0)` —
  it is now part of the stable 0.3.0 surface, no feature flag needed.
- `deps/sockets.wit`: a doc-comment link update (`-draft.md` -> `.md`),
  no semantic change.

No structural/shape changes to any interface, type, or function signature.

Adapter/gate updates made in lockstep (all under #821):
- `scripts/build_wasi_http_p3_full_adapter.sh`: `include` string bumped to
  `wasi:http/service@0.3.0`.
- `scripts/test_wasi_p3_guarantee_gate.sh`: default `VIBE_P3_WIT_PIN` bumped
  to `0.3.0` (confirmed empirically via `wasm-tools component wit` on a
  wasmtime-46-composed component — it reports `wasi:http/handler@0.3.0`,
  no RC suffix).
- `.github/workflows/ci.yml` / `.github/workflows/cli-install.yml` /
  `scripts/install_wasmtime_release.sh`: wasmtime pin bumped 45.x -> 46.0.1.
- `wasi-p3-gate` CI matrix: the wasmtime 46 leg's `phases` widened back to
  `async,http` now that phase B (http) links against the ratified WIT.

## Re-vendoring procedure (for the next wasmtime bump)

1. Download the target `wasmtime-wasi-http-<version>.crate` from
   `static.crates.io` (or `cargo vendor`/`cargo download`).
2. Extract `src/p3/wit/` and diff it against this directory — expect a pure
   version-string bump in the common case; treat any structural diff
   (new/removed interfaces, changed signatures) as a real migration, not a
   drop-in.
3. Copy `world.wit` and `deps/*.wit` over this directory's copies (same file
   set; if the file set changes, update this doc and the adapter's `path`
   consumer accordingly).
4. Update this file's version pin and source-version reference.
5. Update `scripts/build_wasi_http_p3_full_adapter.sh`'s `include` string and
   `scripts/test_wasi_p3_guarantee_gate.sh`'s default `VIBE_P3_WIT_PIN`
   together — a mismatch between adapter include and gate pin fails loudly
   (wit-bindgen resolution error) rather than silently, but keep them in
   lockstep anyway.
6. Re-run `bash scripts/test_async_component_gate.sh` and
   `VIBE_P3_GATE_REQUIRE_TOOLS=1 VIBE_P3_GATE_PHASES=async,http bash
   scripts/test_wasi_p3_guarantee_gate.sh` against the new wasmtime version
   before bumping the CI pins.
