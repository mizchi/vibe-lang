# MoonBit `src/` retirement → selfhost-only

このドキュメントは、MoonBit host 実装 (`src/`) を退役させ、vibe を selfhost-only
にするための**段階移行 (staged migration)** 計画を固定する。`docs/selfhost-bootstrap.md`
の「MoonBit `src/` の退役」節 (step 1–5) の具体化であり、各 stage は **単独で検証可能 /
低リスク** であること、`src/` の物理削除は **最後の stage** であることを原則とする。

安全網: 退役前の最後の MoonBit-host 状態は tag `moonbit-host-final-2026-06-23`
(commit `59ef040`) で固定する。各 stage で gate が緑にならない場合はこの tag に戻す。

## 現状の依存マップ (調査結果 2026-06-23)

- **default dev CLI が `src/` 依存**: `scripts/ensure_native_cli.sh` が
  `moon build … src/cmd/vibe` で `vibe.exe` を作り、`scripts/run_cached_vibe.sh`
  経由で全 dev/test がそれを使う。`VIBE_CLI_BIN_OVERRIDE` という差し替え hook が既にある。
- **seam は集中している**: `run_cached_vibe` / `ensure_native_cli` / `VIBE_CLI_BIN`
  を経由する script は約 50。`moon`/`src/` を直接呼ぶ script は約 60、Taskfile.pkl の
  `moon` 呼び出しは 32。seam を 1 点 (`run_cached_vibe`) で selfhost wasm へ向ければ、
  下流の大半が moon-free になる。
- **runner layer は既に moon-free**: `tools/moonrun_wasmtime` は Rust。
  selfhost wasm の実行 (`scripts/run_wasm_vibe_host_runner.sh` → node/wasmtime) は
  `src/` に依存しない。
- **唯一の本質ブロッカー = `emit-module-source`**: flat module source の生成
  (`scripts/generate_selfhost_bundle.sh` L454 `run_host_vibe_cmd emit-module-source …`)
  は MoonBit のみ実装 (`src/cmd/vibe/cli_module_source.mbt`)。`vibe/` 側に実装は無い。
  これが「`src/` 無しで stage1 を作れない」chicken-and-egg の核心。
- **緩和材料は既にある**:
  - flat bundle (`vibe/compiler/selfhost_sources_bundle.vibe` 4MB /
    `selfhost_cli_adapter_bundle.vibe` 2.5MB) は **commit 済み**。merge 工程までは moon 不要。
  - release-asset 経由の moon-free bootstrap (`scripts/fetch_selfhost_compiler.sh` +
    `VIBE_SELFHOST_PREBUILT_MODULE_SOURCE`) が既に存在し、`generate_selfhost_bundle.sh`
    にも prebuilt を優先する decoupling hook がある。
  - bundle 同期 gate (`scripts/check_selfhost_bundle_sync.sh`) が既にある。
- **seed wasm は pipeline 専用**: `bootstrap/selfhost/seed/selfhost_compiler.wasm` の
  `cli_main` は generation pipeline 向けに ABI/呼び出し規約が特化しており
  (tagged ABI で argv を誤デコード → `fs_read_file` garbage、raw で trap)、
  汎用 `vibe` CLI の drop-in には**ならない**。汎用 CLI には `vibe/cli/selfhost_entry.vibe`
  を raw ABI でビルドした cli wasm を使う。

## Stages

### Stage 0 — 準備 (完了)
- [x] 最後の MoonBit-host 状態を tag (`moonbit-host-final-2026-06-23` / `59ef040`)。
- [x] top-level `.codex_*` 実験ログ削除。
- [x] 依存マップ確定 (本ドキュメント)。

### Stage 1 — `emit-module-source` の moon-free 化 (critical path)
`src/` 無しで flat module source を得られるようにする。次のいずれか:
- **(1a) prebuilt 固定 + sync gate (推奨・最小リスク)**: `cli_main` 用 flat module source を
  リポジトリに commit (または release-asset で pin) し、`generate_selfhost_bundle.sh` を
  prebuilt 優先に切替。`check_selfhost_bundle_sync.sh` を拡張し、commit 済み source と
  現 compiler source の決定性を CI で検証 (stale を弾く)。host `vibe.exe` 経由の
  regenerate は break-glass としてのみ残す。
- **(1b) selfhost 実装**: `emit-module-source` (flatten/dedup, `cli_main` entry 解決) を
  `vibe/compiler/` に移植。より純粋だが工数大。
- 検証: moon を使わず flat module source が得られること、その source から
  stage1 が立ち上がること。

### Stage 2 — moon-free な canonical cli wasm の生成
- seed (stage0) → stage1 → stage2 を **moon 無し**で回す
  (`VIBE_SELFHOST_PREBUILT_MODULE_SOURCE` を Stage 1 の成果物で供給)。
- `vibe/cli/selfhost_entry.vibe` (raw ABI) ベースの cli wasm を成果物に固定。
- 検証: `selfhost_generations.sh build --stage3` 相当を moon 無しで緑、
  stage2==stage3、`release-selfhost-gates` の parity/perf/RSS を満たす。

### Stage 3 — default CLI を selfhost wasm seam へ向ける
- `scripts/run_cached_vibe.sh` / `ensure_native_cli.sh` を、`moon build src/cmd/vibe`
  ではなく Stage 2 の cli wasm を runner 経由で呼ぶ薄い shim に置換
  (既存の `VIBE_CLI_BIN_OVERRIDE` hook を活用)。argv 規約 (compile/check/test/run/build)
  を `vibe.exe` と一致させる。
- 検証: 50 seam-script の代表 (compile→run=42, check, test, bench) が moon 無しで緑。

### Stage 4 — 直接 `moon`/`src/` 参照の除去
- `moon` を直接呼ぶ script (~60) と Taskfile.pkl の 32 箇所を、seam か selfhost 経路へ移行。
- moon-only の補助 (coverage_moon, contract_moon, test_moon_info_regen 等) を退役 or 置換。
- CI shard (`scripts/pkfire/selfhost_gates_shard.sh`) が moon 無しで完走することを確認。

### Stage 4.5 — 未移植 (unported) feature の parity 監査 ★deletion gate★
`src/` (MoonBit host) にあって selfhost (`vibe/`) に**まだ無い**機能が残っていないかを、
削除の**前提条件**として網羅監査する。1 つでも load-bearing な未移植があれば Stage 5 に進まない。
監査軸:
- **CLI subcommand**: host (`src/cmd/vibe/cli.mbt`) は ~40 commands を dispatch するが、
  selfhost CLI (`vibe/cli/selfhost.vibe`) が直接持つのは compiler-core 中心
  (compile / compile-lite / build / check / bundle / parse / type / load / write)。
  未カバー候補: `run` `test` `fmt` `normalize` `bench` `bench-file` `profile` `shell`
  `shell-stdin` `wasm-shell-stdin` `eval` `init` `new` `clean` `precompile`
  `session-http` `session-json` `finalize` `apply` `symbols` `history` `write-file`
  `hash` `save` `fetch` `update-lock` `explain-import` `expand` `ide` `lsif` `index`
  `serve` `lsp` `dist` `emit-module-source` 等。各々について「selfhost/script/runner の
  どこかで等価提供されているか」「dev-only/obsolete で退役可か」を判定する。
- **builtin / host import / intrinsic**: host codegen の builtin/import table と
  selfhost 側 (`vibe/compiler/`) を突き合わせ、host のみの builtin が無いか確認。
- **codegen backend**: linear / wasm-gc 双方の gap (HOF/Iterator, read_word, LZ77 等、
  `docs/codegen/wasm-gc-vs-selfhost-analysis.md` / `docs/report/wasm-gc-hof-gap-2026-05-25.md`)。
  selfhost 既定の linear 経路で実利用機能が full carry されているかを確認する。
- **その他**: `src/` の各 module に対応する `vibe/` counterpart が無い機能 (pass, 言語構文, lint 等)。
判定結果は「(a) 等価提供あり / (b) 退役可 (dev-only/obsolete) / (c) **要 selfhost 移植**」に分類し、
(c) を Stage 5 のブロッカーとして潰し切る。既存の parity gate (corpus check parity REAL gap=0、
dist/stage2 parity、cutover gate) はこの監査の自動化部分として活用する。

### Stage 5 — `src/` 物理削除
- gate が moon 無しで継続的に緑であることを確認した上で、`src/`・`moon.mod`・各 `moon.pkg`・
  `.mooncakes`・`target/`・MoonBit 専用 toolchain 設定を削除 (または `docs/archive/` へ退避)。
- `flake.nix` / CI から MoonBit toolchain を除去。
- README / AGENTS.md / docs を selfhost-only 前提に更新。

## Gate (各 stage 共通)
- `pkf run selfhost-gate` が **moon 無し**で緑。
- corpus check parity REAL gap = 0、perf KPI、peak RSS は bootstrap doc の閾値内。
- 退役は一度に行わず、stage ごとに commit を分け、break-glass の `src/` 変更は
  commit message に明記する。
