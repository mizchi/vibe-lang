# Known issues

## (RESOLVED) vibe-eh-ci: fresh compiler not built on CI → seed fallback

**Was:** On the GitHub-hosted runners, `vibe diagnostics` / `type-at` / the
`vibe check` error path produced `thrown Wasm exception` / raw wasm bytes
instead of real output, so the LSP and standalone tests that depend on those
features failed — only in CI, never locally.

**Root cause (not a wasm-EH bug).** The *fresh* compiler build
(`scripts/install.sh` → `build_cli_wasm.sh` → `generations.sh`) runs
the committed seed through the **standalone `wasmtime` CLI**
(`scripts/wasmtime_bin.sh`) to produce stage1/stage2. The CI workflow only built
the `viberun` runner and never installed the `wasmtime` CLI, so the fresh
build failed and `install.sh` silently **fell back to the committed seed
compiler**, which predates the diagnostics/type-at/error-handling features.
Local dev worked only because the dev environment already had `wasmtime` on PATH.

**Fix.** `.github/workflows/cli-install.yml` now has a *Set up wasmtime CLI*
step (pinned `v45.0.2`) before any fresh-compiler build, so CI builds the same
fresh compiler as local dev and all the features work.

**Defensive net.** `scripts/test_vibe_lsp.js` still probes once whether the
running compiler can produce diagnostics and skips the dependent assertions if
not (so a future broken toolchain degrades to a clear `skip:` rather than a
confusing failure). The standalone `test_vibe_type_at.sh` / `test_vibe_diagnostics.sh`
/ `test_name_section.sh` steps are NOT guarded, so a missing/!broken fresh build
still fails loudly there.
