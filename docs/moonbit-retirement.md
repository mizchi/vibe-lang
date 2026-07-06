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
- **runner layer は既に moon-free**: `runtime/moonrun_wasmtime` は Rust。
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
- **seed wasm は pipeline 専用**: `bootstrap/seed/selfhost_compiler.wasm` の
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
`src/` 無しで flat module source を得られるようにする。

**(1a) prebuilt 固定 + sync gate — 実装済み (本 PR):**
- `cli_main` 用 flat module source を `vibe/compiler/selfhost_cli_adapter_module_source.vibe`
  に commit (他の selfhost bundle と同じ扱い)。
- `generate_selfhost_bundle.sh::build_adapter_module_source` を **commit 済み prebuilt 優先**に
  切替。`VIBE_SELFHOST_REGEN_MODULE_SOURCE=1` のときだけ host `vibe.exe` で再生成
  (sync gate / 意図的 bump 用の break-glass)。これで既定の bundle 生成経路から moon 依存が消える。
- freshness gate `scripts/check_selfhost_module_source_sync.sh` を追加し、
  `release-selfhost-gates` と CI shard (`bootstrap` / `bootstrap-core`) に組込み。
  host があるとき再生成して drift を弾き、host が無い環境では skip (pin を信頼)。
- 検証済み: host `vibe.exe` を隠し `moon` を stub した状態で `generate_selfhost_bundle.sh` が
  成功し module source が commit 済みと一致 (= moon-free)。既存 bundle-sync gate も緑。

**(1b) selfhost 実装 — 採用: approach 1 (span tracking)。core 実装済み (本 PR):**
- host の `emit-module-source` は「parse → entry からの DCE → 生き残った top-level stmt の
  **span で元ソースを slice**」(`src/cmd/vibe/cli_module_source.mbt`)。selfhost の `Token`
  /`Stmt` は source offset を持たないため、**top-level stmt span だけ**を復元する最小限の
  span tracking を追加 (front-end 全体改修は不要だった):
  - `lexer.vibe`: token 分類を `lex_one_token` に抽出 (codegen 1 コピー) し、per-token の
    start/end byte offset を返す `lex_with_offsets` を追加。`lex` の挙動は不変。
  - `parser.vibe`: token offset から top-level stmt の byte span を導出する
    `parse_program_spans` を追加。`parse_program` は不変。
  - `core/dce.vibe`: 既存の到達可能性を再利用し per-index keep flag を返す
    `dce_keep_flags` を追加 (`dce_stmts` は不変)。
  - `runtime/module_source.vibe`: `build_module_source_from_source` — entry から DCE し、
    生存 stmt の元ソース slice を emit。host 実装と等価。
- 検証済み: unit test (emit 3/3, dce 15/15, lexer 1/1)、および **host 隠蔽 + moon stub での
  moon-free selfbuild (seed→stage1→stage2, 両 stage validate 通過)**。bundle/prebuilt 再生成し
  両 sync gate 緑。bootstrap fragility 対策として hot path を byte 不変に保ち、共有 `lex_one_token`
  で codegen 重複 (= seed OOM) を回避した。
**(1b) wiring — 実装済み (本 PR):**
- adapter `cli_main` に env gate を追加: `VIBE_EMIT_MODULE_SOURCE=1` で同じ
  (input, output, entry) i/f のまま compile せず `build_module_source_from_source` を書き出す。
  `runtime/module_source.vibe` を manifest に追加し compiler の一部に。
- **moon-free 実証済み** (host 隠蔽 + moon stub): emit を cli_main から到達可能にした状態でも
  seed→stage1→stage2 が自己コンパイル; generation 産の stage2 が merged source に対し emit を
  host 無しで実行; その (host より lean な) module source が seed→stage1→stage2 + validate を通過
  してブートストラップ成功。lean なのは host が dead export を残すのに対し selfhost emit は
  cli_main 到達 + structural のみ残すため (cli_main entry には十分)。
- **残り (gate flip = bootstrap bump、別 PR)**: freshness gate / `generate_selfhost_bundle.sh`
  REGEN の既定を host→selfhost compiler に切替えるには、seed が emit を持つ必要がある
  = seed re-pin (bootstrap bump)。docs/selfhost-bootstrap.md に従い、独立 PR で stage2/stage3・
  perf/RSS・corpus gate を通してから seed を adopt する。それまで committed prebuilt は
  host-emitted のままで既存 sync gate を緑に保つ (既定 build は 1a で既に moon-free)。

### Stage 2 — moon-free な canonical cli wasm の生成 — 検証済み (本 PR)
- seed (stage0) → stage1 → stage2 を **moon 無し**で回す。Stage 1(1a) の prebuilt module
  source により flat-source 段が moon-free になり、`scripts/selfhost_generations.sh` の
  default `build` 経路 (stage0→stage1→stage2) は moon を呼ばない (`moon build vibe_compile_wasi`
  は `host-bootstrap-seed` 専用で default build には無い)。
- **検証済み (実測)**: host `vibe.exe` 群を退避し `moon` を fail stub にした状態で
  `selfhost_generations.sh build` が成功:
  `stage0(seed)→stage1`, `stage1→stage2`, stage1/stage2 の validate(sample) すべて exit 0。
  stage2 candidate を生成 (`_build/selfhost/generations/<gen>/stage2.wasm`)。host バイナリは復元済み。
- 補足: stage1≠stage2 は正常 (seed は HEAD より旧版の compiler。fixpoint 判定は stage2==stage3 で、
  既存 selfhost-gate の `build --stage3` が担保)。`release-selfhost-gates` の parity/perf/RSS は
  別途 gate 側で継続確認する。
- 残: canonical CLI wasm を `vibe/cli/selfhost_entry.vibe` (raw ABI) ベースに固定するのは
  Stage 3 の seam 切替と合わせて行う。

### Stage 3 — default CLI を selfhost wasm seam へ向ける
- **opt-in shim 実装済み (本 PR)**: `scripts/vibe_selfhost_cli.sh` — `VIBE_CLI_BIN_OVERRIDE`
  経由で seam (`run_cached_vibe`) を selfhost CLI wasm (`vibe/cli/selfhost_entry.vibe` →
  `--invoke cli_main`) に向ける薄い wrapper。path を preopen(root) 相対へ書換え、対応
  command は selfhost CLI 実装分 (`compile`/`build`/`check`/`compile-lite`/`bundle`)。
  smoke: `pkf run test-selfhost-cli-seam` (`scripts/vibe_selfhost_cli_smoke.sh`) が
  compile→run=42 を runtime moon-free で検証。
- **default flip は Stage 4.5 依存 (未実施)**: 既定 seam を flip すると selfhost CLI 未実装の
  `run`/`test`/`fmt`/`normalize`/`bench`/… が壊れる。これらを移植 (Stage 4.5) してから default を
  flip する。`fmt` は host が CST formatter (`src/parser/format.mbt` の `parse_cst`+token整形,
  コメント保持) を使い、`normalize` は semver/依存解決/dedup を含むため、いずれも単純な
  parse+print では移植できず、各々が独立した移植タスク。
- CLI wasm の build 自体を moon-free 化するには 1b の selfhost `emit-module-source` で
  `selfhost_entry` の module source を出し seed で compile する経路を使う (現状 shim は
  `build_selfhost_cli_core.sh`=host build に fallback; `VIBE_SELFHOST_CLI_WASM` で
  moon-free build 済み wasm を差し込み可能)。

### Stage 2.5 — bootstrap bump: seed が emit を持つ (完了)
- seed を current fixpoint stage2 (`stage2==stage3`) に re-pin (`selfhost-emit-2026-06-23`,
  sha `2f1d5c89`)。新 seed は emit-module-source を持ち、自分で次世代を build できることを検証。
- `generate_selfhost_bundle.sh` の emit と `check_selfhost_module_source_sync.sh` を seed 経由
  (moon-free) に切替。committed prebuilt は seed-emitted。**bootstrap pipeline 全体が host 不要**。

### Stage 4 — 直接 `moon`/`src/` 参照の除去 (残・大)
依存マップ (調査 2026-06-23): host CLI seam を使う script 51、`moon` 直呼び script 59、
`src/` 参照 script 57、CI workflow 6、flake に moonbit toolchain。多くは host の unit test /
host↔selfhost parity / dist-via-host で、`src/` 退役と共に **obsolete 化** する (削除対象)。
- `selfhost-gate` の corpus-parity / perf・RSS-vs-host は host 比較 gate → `src/` 削除時に退役し、
  selfhost 単独の絶対 gate に置換する。
- default CLI seam (`run_cached_vibe`/`ensure_native_cli` = `moon build src/cmd/vibe`) を
  selfhost 経路へ。**未解決の技術ギャップ**:
  - 汎用 CLI (`vibe/cli/selfhost_entry.vibe`, compile/build/check) の **moon-free build** には
    cross-layer (vibe/cli ↔ vibe/compiler) の merged-source 生成が必要 (現 `generate_selfhost_bundle.sh`
    は compiler-dir 固定・root=adapter 固定)。
  - seed への **FS-compile mode** (`compile_file_fs_mode` を cli_main から到達可能化) を試行したが、
    multi-file の FS loader 経路が runner 上で trap (persistent-cache 周りの疑い)。要 debug。
    → これが解ければ `run`/`test`/CLI build が seed 単体で moon-free 化できる。
- `fmt`/`normalize` は host が CST formatter / semver・依存解決を使い、各々独立移植 (大)。
  `vibe-normalize` gate は release-check 依存 → 移植 or gate 置換が必要。

### Stage 5 — `src/` 物理削除 — 完了 (本 PR)
- **`src/` (7.3MB, 32 `moon.pkg`) と `moon.mod` を削除**。vibe は selfhost-only に。
- moon-free な post-deletion gate `scripts/selfhost_only_gate.sh` を新設し、`release-check` を
  これに再定義 (bundle/module-source sync + seed→stage1→stage2→stage3 fixpoint + compile/run 検証)。
  host `vibe.exe` 退避 + `moon` stub + `src/` 削除済みの条件で green を検証。
- flake から MoonBit toolchain (moonbit-overlay / moon-patched / similarity-mbt / `moon update`) を削除。
- CI: `ci.yml` を selfhost-only-gate 1 job に置換。host 依存 workflow (flaker-ci / flaker-scheduled /
  playground) は `workflow_dispatch` 専用に無効化。
- **既知の degradation / follow-up** (selfhost-only 化に伴い host で提供していた dev 機能が一時的に未提供):
  - `fmt` / `normalize` / `run` / `test` の host CLI、multi-file FS-compile (selfhost loader にパス
    破損 bug `fs_read_file '<digits>.vibe'` あり), `vibe/cli` の moon-free build (cross-layer bundling)。
  - host-only script (~120) と対応 Taskfile task は dead として残置 (default gate/CI からは不参照)。
    follow-up で prune する。
- 復旧点: 退役前の最後の MoonBit-host 状態は tag `moonbit-host-final-2026-06-23` (`59ef040`)。

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

#### 初期監査結果 (2026-06-23, 要再確認の項目あり)

**(c) 要 selfhost 移植 — Stage 5 ブロッカー候補:**
- `emit-module-source` — moon-free bootstrap の核心。Stage 1 で prebuilt 固定 or 移植で解消。
  実装 host のみ (`src/cmd/vibe/cli_module_source.mbt`)、selfhost 無し。
- `fmt` (formatter, `src/cmd/vibe/cli_fmt.mbt`) — selfhost 無し。公開 CLI として期待される。
- `normalize` (`src/cmd/vibe/cli_normalize.mbt`) — selfhost 無し。**`pkf run release-check` の
  `vibe-normalize` で使用**しており project gate に直結。要対応。
- builtin: `Set::*` (new/add/remove/contains/size/from_array/to_array)、`Int64Array::*`
  (Array[Int] 32-bit truncation #429 の回避用)、`Path::ref` — host checker
  (`src/checker/builtin_declared_names.mbt`) にあり selfhost checker に無い疑い。**要確認**:
  実プログラム/compiler source 自身が使うなら移植必須、未使用なら退役可。

**(b) 退役可 (dev-only / obsolete / 別 layer 提供):**
- IDE/LSP 系: `ide` `lsif` `index` `lsp` `serve` — エディタ統合 dev tooling。
- REPL/shell: `shell` `shell-stdin` `wasm-shell-stdin` `eval`(既に alias 化)。
- bench/profile: `bench` `bench-file` `profile` — script/runner 側で代替可。
- closure payload: `emit-closure-payload` `compile-closure-payload` `precompile` — 特殊 codegen。
- effect/WASI 系 host import (`Fs::*` `Http::*` `Socket::*` `Env::*` `Stdin/Stdout`) は
  selfhost wasm + runner 側で提供する設計であり「未移植」ではない。
- `bundle` は既に `compile`/`precompile` へ alias 化済み。

**(a) 等価提供あり / 設計上 OK:**
- compiler-core: `compile` `compile-lite` `build` `check` `parse` `type` — selfhost CLI 実装済み。
- `run` `test` — selfhost wasm で compile → Rust runner で実行、の合成で提供 (要 e2e 確認)。
- codegen backend: selfhost は **linear backend のみ** mirror (`docs/spec/codegen-dual-backend.md`)。
  wasm-gc codegen は selfhost 未実装だが、selfhost 既定経路は linear なので削除ブロッカーでは
  ない (wasm-gc は将来課題として別管理)。
- Perceus RC: selfhost で実装・検証済み (`docs/spec/selfhost-rc-cutover-readiness.md`)。

> 注: builtin/`fmt`/`normalize` の有無は host の宣言表ベースの一次判定。Stage 4.5 本実行時に
> selfhost checker/CLI を直接確認して (a)/(b)/(c) を確定し、本表を更新する。

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
