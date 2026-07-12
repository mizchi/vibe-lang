# Vendored WASI p3 WIT (wasi:http RC)

Source: crates.io `wasmtime-wasi-http` 45.0.2, `src/p3/wit/` (byte-identical
copy). Version pin: `wasi:http@0.3.0-rc-2026-03-15` — the RC WIT that
wasmtime 45.x serves behind flags.

Consumers: `scripts/build_wasi_http_p3_full_adapter.sh` (wit-bindgen
generate! path). Previously this pointed at the `deps/wasmtime` submodule's
copy, which broke everywhere the submodule isn't checked out (CI, fresh
clones) — vendoring makes the p3 gates self-contained (#821).

At the wasmtime 46 / ratified WASI 0.3.0 cutover (#821), refresh this
directory from `wasmtime-wasi-http` 46.x (`wasi:http@0.3.0`) and update the
adapter's `include`/version strings + the gate's VIBE_P3_WIT_PIN together.
