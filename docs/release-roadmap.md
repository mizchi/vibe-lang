# vibe リリースロードマップ

> 作成: 2026-06-25 / 対象: 0.1.0 sign-off 済みの selfhost-only コンパイラを
> 「外部ユーザーが実利用できる公開リリース」まで持っていくための工程表。
>
> 言語コア（parser / checker / codegen / selfhost bootstrap）は 0.1.0 sign-off
> （`docs/report/0-1-0-usability-signoff.md`, TODO.md「0.1.0 release sign-off」）で
> 一定の完成度に達している。本ロードマップは **プロダクトとしての配布・利用・
> 開発体験** に残る 4 テーマを「リリース blocker」として整理する:
>
> 1. install 配布方法の確定
> 2. モジュール配布方法の確定
> 3. debugger の実装
> 4. LSP の実装

各テーマは GitHub Issue（一次管理）と本ファイル（ロードマップ概要）で追う。
設計判断は `docs/adr.md` に記録する。

---

## 実装進捗 (2026-06-25 セッション)

完了・検証済み（selfhost-only gate green、`scripts/test_vibe_cli_install.sh` 12/12）:

- **テーマ1 (install) ほぼ完了** — `moonrun_wt` に selfhost CLI 用 raw-ABI host
  import を実装、`vibe` launcher（run/compile/build/check/test/fetch/version/
  self-update/help）、`scripts/install.sh`（install 時 `.cwasm` AOT）、
  `scripts/build_cli_wasm.sh`、`docs/install.md`、CI（`cli-install.yml`）。
- **診断表面化 (UX/LSP 基盤)** — コンパイルエラーを `<output>.diag` に書き
  launcher が `error: <file>: <message>` 表示（trap/backtrace を置換）。
- **テーマ2 (modules) MVP** — `vibe fetch` で git/URL 分散 deps を content-addressed
  に vendor + `vibe.lock`。

- **テーマ3 (debugger) P0 着手** — wasm name section を実装し、trap backtrace が
  user 関数名を表示するようになった（`<wasm function N>` → `main`/`boom`）。
  DAP 本体（P1-P4）と source-line map は source span が前提で未着手。

残テーマ (3/4/土台) は**共通基盤の不足**がボトルネック。スコープを明確化:

### source span 基盤 — 着手・進行中（2026-06-25）

ユーザー選択に従い着手。**最初の可視スライス（located parse 診断）まで到達。**

完了:

- ✅ **NUL codegen バグ修正** — FS-compile の parse エラー診断が 175 byte の NUL
  garbage になっていた。根因は `loader/header_cache.vibe` が `+` 演算子で
  文字列連結していたこと（`+`-string-concat が selfhost codegen で NUL 化）。
  `String::concat` 化で解消。これが located 診断の前提ブロッカーだった。
- ✅ **token-level span インフラ活用** — 既存の `lex_with_offsets`（トークン
  start/end offset）に `offset_to_line_col` helper を追加。
- ✅ **located parse 診断** — `parse_program_located`（文単位で `line:col` を
  付与）を追加し、FS-compile の header-load parse に配線。`vibe check`/`run` が
  `foo.vibe: line 2:1: unexpected token ...` を表示。LSP は `line N:col M:`
  プレフィックスから正確な range を生成。
- ✅ **located 型エラー（common case）** — FS typecheck の error handler で
  `unknown name:` / `function arity mismatch for` / `unknown field` /
  `unknown constructor` のシンボルを source から探し `line:col` を付与
  （`offset_to_line_col`）。`foo.vibe: line 3:31: unknown name: zzz` のように
  正確な列まで出る。LSP は range を識別子に絞る（`test_vibe_lsp.js` 11/11）。

残り（次スライス、いずれも real AST span が前提で大きい）:

- **type mismatch 等シンボルを含まない型エラー** — 現状 location 無し。正確化には
  AST ノードへの位置付与が必要（式が直接位置を持つ）。
- **式レベルの正確な span** — `EIdent` 1 variant で 183 箇所 × 39 ファイル、全
  variant で数千箇所。parser への offset スレッディングも要る massive refactor。
- **型付き hover / DAP source-line map** — 上の AST span が前提。

- **codegen の関数 index↔name 対応** — ✅ wasm name section（土台B / debugger P0）
  は実装済み（`func_offset + i` で user 関数を正確に命名）。

## 全体方針とリリースの段階

リリースは一括ではなく、テーマ単位のマイルストーンを刻んで段階的にタグを打つ。

| マイルストーン | 内容 | 主テーマ | 状態 |
| --- | --- | --- | --- |
| **M1: 配布確定** | install + module の配布方法を凍結し、外部の人が「入れて使える」 | (1)(2) | 未着手 |
| **M2: 開発体験 MVP** | LSP MVP（診断/シンボル/hover）+ debugger P0（source-mapped trace） | (3)(4) | 一部基盤あり |
| **M3: 開発体験フル** | LSP 補完/リファクタ + DAP step 実行 | (3)(4) | 提案段階 |
| **M4: GA (1.0)** | 上記を統合し、言語仕様 freeze + docs 完備で一般公開 | 全部 | — |

### 横断的な前提（どのテーマにも効く 2 つの土台）

先に潰すと 4 テーマ全部のコストが下がる共有基盤。**優先度高**。

- **A. parser のエラー回復 (error recovery)** — 現状 `vibe/parser/parser.vibe` は
  最初の `expect_tk` 失敗で `with { Error }` throw して停止する。これは
  LSP（編集中の壊れたソースで診断/補完を出す）と UX 両方の天井になっている。
  recovery point（`;` / `}` / トップレベル宣言境界で再同期）を入れる。
- **B. source location / wasm name section** — 現状 codegen は name section も
  source map も出さない（`grep source.?map vibe/compiler/codegen` → 0 件）。
  ランタイム trap / panic がソース行を指せない。ADR-0035 P0 の
  `vibe.func_map` + wasm name section を入れると、debugger だけでなく
  実行時エラーの可読性も上がる。

---

## テーマ 1: install 配布方法の確定

### 現状

- `pkf run install`（`Taskfile.pkl`）が native CLI を `~/.local/bin/vibe` に
  コピーする。これは開発者向けで、外部ユーザー向けの導線ではない。
- `scripts/build_release_assets.sh` が GitHub Release 用 asset を生成する:
  - `vibe-<tag>.wasm`（MoonBit host `src/lib` の wasm-gc library）
  - `vibe-selfhost-<tag>.wasm`（stage0 seed compiler、stock wasmtime で実行可）
  - `vibe-selfhost-module-source-<tag>.vibe` / `-seed-<tag>.json` / `SHA256SUMS.txt`
  - `v*` tag push で `.github/workflows/release.yml` が公開。
- 実行基盤は `tools/moonrun_wasmtime`（Rust, `moonrun_wt`）。compiler は
  selfhost wasm + wasmtime runner で動く（ADR-0056 cutover）。

### ギャップ（未確定）

- **正規の配布物が未定**。「native binary」「selfhost wasm + runner」「npm」の
  どれを *外部ユーザー向けの canonical artifact* にするか決まっていない。
- npm / Homebrew / `cargo install` / `curl | sh` のいずれも未整備。
- README に一般ユーザー向けの「インストール手順」セクションがない。
- wasm を実行するための wasmtime / runner の同梱・前提が未定義。

### ゴール

「3 つの代表 OS（Linux/macOS/Windows）で 1 コマンドで入り、`vibe run hello.vibe`
が通る」状態を、再現可能な CI ジョブで保証する。

### 決定（2026-06-25）

**canonical = 独自ビルドの wasmtime runner + vibe コンパイラ wasm の分離配布。
インストール時に各環境で `.cwasm`（AOT precompile）をビルドする。**

- 実行基盤は `tools/moonrun_wasmtime`（`moonrun_wt`）を「独自ビルドの wasmtime
  runner」として配布する。runner は portable wasm を受け取り、インストール時に
  ホスト固有の `.cwasm` へ AOT コンパイルしてキャッシュする
  （既存の `.cwasm` cache 機構 / ADR-0050・ADR-0056 を install フローに昇格）。
- **runner 層と compiler wasm 層を分離**する（TODO.md「Cutover work」と一致）。
  vibe コンパイラ本体は wasm artifact として runner とは独立に更新できる
  （runner を入れ替えずに `vibe` 自身を bump 可能）。
- これにより DWARF 的なネイティブ依存を増やさず、stock でない wasmtime 拡張も
  自前 runner に閉じ込められる。

> 補足: npm / 単一ネイティブバイナリは canonical からは外す。必要になれば
> 補助配布として後付け検討（JS 埋め込み用途は `js/vibe/` を維持）。

### マイルストーン

- [x] **1-1 runner/compiler 分離の確定** — `moonrun_wt` に selfhost CLI が使う
      raw-ABI host import (`vibe::env-get`/`args-get`/`fs_*`) を実装し、runner が
      compiler wasm を実行基盤として動かせるようにした。compiler wasm は
      差し替え可能 artifact として分離（`tools/moonrun_wasmtime/src/main.rs`）。
- [x] **1-2 install-time `.cwasm` ビルド** — `scripts/install.sh` が runner 取得後に
      `moonrun_wt --precompile` で compiler wasm を host 固有 `.cwasm` へ AOT。
      launcher は runner より古い `.cwasm` を検出すると portable wasm に fallback。
- [x] **1-3 マルチプラットフォーム CI** — `.github/workflows/cli-install.yml` が
      ubuntu/macos で runner build + `scripts/test_vibe_cli_install.sh` smoke test。
      （Windows は launcher が bash 依存のため対象外。残: arch matrix 拡張）
- [x] **1-4 ワンライナー installer** — `scripts/install.sh` が runner build +
      compiler wasm 配置 + `.cwasm` 生成 + `vibe` launcher 配置 + PATH link。
      `--prefix`/`--runner`/`--cli-wasm`/`--bin-dir`/`--no-link` 対応。
- [x] **1-5 compiler-only update 導線** — `vibe self update --cli-wasm <path>` が
      runner 据え置きで compiler wasm を差し替え `.cwasm` を再生成。
- [x] **1-6 docs** — README「Install」節 + `docs/install.md`（layout/options/
      update 手順）。

> 実装メモ: launcher (`runtime/vibe`) が `run`/`compile`/`build`/`check`/
> `test`/`version`/`self update`/`help` を提供。`run`/`test` は compile→別プロセス
> 実行の 2 段（selfhost CLI は compile 専用のため orchestration は launcher 側）。
> 検証済み: 単一/マルチファイル `vibe run` → 42、`vibe check` の成功/失敗、
> `vibe test` の pass/fail 集約、`.cwasm` 経路の利用。installer は
> `scripts/build_cli_wasm.sh` で最新 source からコンパイラ wasm を build（seed
> fallback あり）。残: `vibe fmt` の launcher 統合。
>
> **診断表面化 (UX/LSP 前提)**: コンパイルエラー時、selfhost CLI が整形済み
> 診断 String を `<output>.diag` サイドカーに書き、launcher が `error: <file>:
> <message>` として表示するようにした（`selfhost_cli_adapter.vibe` cli_main を
> `handle ... with Error { Throw(msg) => ... }` で包む）。trap/バックトレースの
> 代わりに `unknown name: zzz` / `type mismatch ...` が出る。selfhost-only gate
> （bundle/module-source sync + stage2==stage3 fixpoint）green。

---

## テーマ 2: モジュール配布方法の確定

### 現状（想定より進んでいる）

- 相対パス import/export（`import ./lib.vibe { f }`、`export use`）は実装済み
  （`docs/module-system.md`, `vibe/compiler/module_*.vibe`）。
- **lock workflow 実装済み**（`docs/spec/decisions.md`）:
  `vibe fetch` / `vibe update-lock` が `index.lock`
  （`path`/`version`/`symbol`/`module`/`annotation` マップ）を維持。
  path import は lock entry に対して検証され、import 診断は compile-fatal。
- **semver の足場あり**: `index.vibe` ルートレジストリは
  `export let version = "x.y.z"` を要求。
- **content-addressed store あり**: `.vdb` が `hash:<sha1>` を指せる。
  alias は `VIBE_LIB_DIR`（fallback `$HOME/.vibe/lib`）から解決。
- **分散 ref PoC**: advanced graph の snapshot/delta を git/bit object として
  `refs/bit/index/<scope>/graph/...` で addressing（実験段階）。
- pinned path import（`import ./dep.vibe#hash`）で content lock 可能。

### ギャップ（未確定）

- **`@pkg` / `@lib/path` 構文は spec 記載のみで未実装**（ADR discussion）。
- **リモートからの third-party 取得が無い**: registry も `vibe publish` も
  URL/git import の解決も未実装。`vibe fetch` はローカル lock 維持に閉じる。
- transitive dependency の自動解決・バージョン整合（SAT/semver resolver）が無い。
- 「公開された vibe ライブラリを 1 行で使う」体験が存在しない。

### ゴール

「第三者のライブラリを宣言 → `vibe fetch` で取得・lock → import して使う」が
content-addressed に再現可能で動く。中央 registry の有無を含め配布モデルを凍結。

### 決定（2026-06-25）

**git/URL 分散モデル（Deno/Go 風）。中央 registry は持たない。**

- import は git/URL を直接指し、取得物は content hash で `index.lock` に固定する。
- 既存資産（content-addressed `.vdb` の `hash:<sha1>`、pinned hash import
  `import ./dep.vibe#hash`、`refs/bit/index/...` 分散 ref、`$HOME/.vibe/lib`
  キャッシュ）の上に最短で接続する。
- `vibe publish` は「git push + tag」で代替し、専用 registry サーバーは建てない。
- 発見性（検索）が必要になれば、後付けで軽量 index（tap 風）を足す余地は残す。

### マイルストーン

- [x] **2-1a fetch + lock MVP（launcher）** — `vibe fetch` が `vibe.deps`
      (`<name> <url>` 行) を読んで vendor + `vibe.lock` を書く:
      - 単一ファイル（`file://`/`http(s)://`/ローカル）→ sha256 で content-addressed
        cache + `./deps/<name>.vibe`、lock に `sha256:<hash>`。
      - **git（`git+<remote>[#<ref>]`）** → clone + ref checkout → `./deps/<name>/`
        ディレクトリに vendor、lock に解決した commit `git:<sha>` を固定。
      検証済み（`scripts/test_vibe_cli_install.sh`、git+ 含め 15/15）。
- [ ] **2-1b seamless `import "<url>"` 構文** — string-literal import を parser で
      受け、resolver で `.vibe/deps/` ミラーに写像する案を試作したが、
      **selfhost codegen の既知の脆さ**（`collect_import_path` の string 補間 /
      import 解決ホットパスでの String 操作が NUL garbage を生む。
      `selfhost_only_gate.sh` step4 のコメント参照）に当たり revert。
      seed 互換な codegen 修正を先に固めてから再導入する。
- [ ] **2-1 リモート import 解決（完全版）** — git/URL から外部ソースを取得し
      `$HOME/.vibe/lib` / content store にキャッシュ。`index.lock` に hash を固定。
- [ ] **2-2 依存解決器** — transitive 依存と semver 整合の最小実装
      （まずは「lock があれば再現、無ければ解決して書き出す」）。
- [ ] **2-3 `vibe add` / `vibe publish`（または equivalent）** — 依存追加と
      公開の CLI 導線。2-0 の選択次第で publish は「git push + tag」かもしれない。
- [ ] **2-4 整合性・供給網** — checksum/hash 検証、（必要なら）署名。
- [ ] **2-5 docs** — `docs/module-system.md` に配布節、チュートリアル追加。

### 決めるべきこと（2-0 の選択肢）

| 案 | 内容 | 長所 | 短所 |
| --- | --- | --- | --- |
| **A. git/URL 分散（Deno/Go 風）** | `import "git+https://…#tag"`、content hash で lock | 中央サーバ不要、既存の `.vdb`/hash/分散 ref 資産と整合 | 名前空間衝突、検索性が低い |
| **B. 中央 registry（npm/crates 風）** | `vibe publish` → registry、`vibe add name` | 検索/発見性、versioning が綺麗 | サーバ運用・ホスティング・モデレーションコスト |
| **C. git + 軽量 index** | 実体は git、index だけ集約（Homebrew tap 風） | 運用軽量、移行容易 | 二段構えの複雑さ |

> 推奨たたき台: 既存実装（content-addressed `.vdb`, 分散 ref, pinned hash import,
> `index.lock`）は **A（git/URL + content-addressed lock）** に最短で接続できる。
> A を MVP として凍結し、発見性が要れば後付けで C の index を足す。

---

## テーマ 3: debugger の実装

### 現状

- **方針は ADR-0035（proposed）で確定済み**
  （`docs/archive/adr/0035-debug-adapter-protocol.md`）:
  - DWARF は不採用（vibe の i64 tagged 値 + closure ABI が C 的メモリモデルと
    impedance mismatch）。
  - 既存の **coverage instrumentation 基盤**（`--coverage`, span/coverage point,
    `.wasm.cov.json` サイドカー）を再利用して独自 DAP サーバーを建てる。
- フェーズ P0–P4 が定義済み。いずれも **未実装**、0.1.0 対象外。
- 関連: `vibe build --debug` は「linked debug build（高速 incremental compile）」で
  あって *対話デバッガではない*（用語の衝突に注意）。

### ギャップ

- name section / `vibe.func_map` / `vibe.debug_map` custom section が未出力（横断土台 B）。
- DAP サーバー本体（breakpoint / variables / step / watch）が未実装。

### ゴール

VS Code（DAP クライアント）から breakpoint を張り、停止・変数検査・step 実行が
できる。最低でも「panic/trap がソース行を指す」を M2 で達成。

### マイルストーン（ADR-0035 のフェーズに対応）

- [~] **3-P0 source map 基盤**（= 横断土台 B、M2）— **wasm name section を実装**
      （`emit_function_name_section`、`compile_wasi_module_linked_impl` から呼ぶ）。
      compiled wasm の function-names subsection が user 関数を命名し、wasmtime の
      trap backtrace が `<wasm function N>` → `boom` 等の関数名表示になった。
      検証済み（`scripts/test_name_section.sh`、selfhost-only gate fixpoint green）。
      残: `vibe.func_map`（命令オフセット→ソース行）= source span 実装が前提。
- [ ] **3-P1 breakpoint DAP**（M3）— stop/continue + source 表示の DAP サーバー。
      coverage point を breakpoint anchor に流用。
- [ ] **3-P2 変数検査**（M3）— locals/args のメタデータ出力 + tagged 値の decode。
- [ ] **3-P3 step 実行**（M3）— next / stepIn / stepOut。
- [ ] **3-P4 watch 式**（M4）— 停止フレームでの式評価。
- [ ] **3-D editor 統合** — `integrations/vscode-vibe` に debug adapter を配線。

> 優先は **P0**。デバッガ全体が無くても「エラーがソース行を指す」だけで
> 実利用の体感が大きく変わるため、M2 の必須項目に格上げする。

---

## テーマ 4: LSP の実装

### 現状

- **transport 層は実装済み**: `js/vibe/lsp.js`
  （`bindLspTransport` / `createLspBridge` / `createWebSocketTransport`、
  stdio/ws 非依存）。`tests/integration-deno/vibe_lsp_transport_test.ts` あり。
- **シンボル index バックエンドは存在**（ただし MoonBit host `src/` 側）:
  `vibe ide`（outline / peek-def / search）と `vibe lsif` が
  共有 symbol index（`src/frontend/symbol_index.mbt`）を消費。
  `js/vibe/index.js` が `createVibeService`（`check`/`ideOutline`/`idePeekDef`/
  `ideSearch`/`checkProject`）を wasm 経由で公開。
- **エディタ拡張は実装済み**（syntax のみ、language server 機能なし）:
  - `integrations/vscode-vibe/`（tmLanguage, language-configuration）
  - `integrations/treesitter-vibe/`（grammar + highlights/tags queries、corpus tests）
  - `integrations/zed-vibe/`（tree-sitter 参照、outline/brackets/indents queries）

### ギャップ

- **LSP サーバー本体が無い**: `vibe lsp` コマンドは docs 記載のみ。
  diagnostics / hover / go-to-def / completion / document symbols / formatting を
  LSP メソッドとして話す層が未実装。
- **バックエンドが host (`src/`) 依存**: selfhost-only 方針に対し、
  symbol index が MoonBit 側にある。selfhost `vibe/compiler/` への移植が要る。
- **parser に error recovery が無い**（横断土台 A）— 編集中ソースで診断/補完が
  破綻する。LSP 品質の最大ボトルネック。
- 型チェッカが部分的な型情報（hover 用の式の型、補完候補）を返す API を持たない。

### ゴール

VS Code / Neovim / Zed で「保存時診断 + hover で型 + 定義ジャンプ + 文書シンボル +
フォーマット」が動く LSP を、selfhost compiler をバックエンドに提供する。

### 決定（2026-06-25）

**LSP サーバーは native runner + selfhost wasm で動かす（node 非依存）。**
install/​debugger と runtime 前提を一本化する。`vibe lsp` を selfhost
コンパイラをバックエンドにした language server として実装し、
`js/vibe/lsp.js` の transport 抽象はブラウザ/embedding 用途の補助に留める。

### マイルストーン

- [ ] **4-A parser error recovery**（= 横断土台 A、M2 前提）— 編集中ソースで
      部分 AST + 診断を返せるようにする。
- [~] **4-1 LSP MVP**（M2）— `js/vibe/lsp_server.js`（stdio JSON-RPC）+ launcher
      `vibe lsp` を実装。`textDocument/publishDiagnostics` を提供（didOpen/
      didChange/didSave で native `vibe check` を駆動 → 診断を publish）。source
      span 未実装のため、診断メッセージ中のシンボルを文書テキストから探して範囲を
      近似。**documentSymbol / definition / hover** をトップレベル宣言のテキスト走査で
      提供（go-to-definition は宣言行へジャンプ、hover は宣言テキストを表示）。
      検証済み（`scripts/test_vibe_lsp.js` 8/8）。残: 型付き hover（checker の型
      クエリ + source span が前提）, 正確な診断範囲（source span）, references/rename。
- [ ] **4-2 selfhost への index 移植**（M2–M3）— `src/frontend/symbol_index.mbt`
      相当を `vibe/compiler/` 側に持ち、host 依存を外す。
- [~] **4-3 definition / hover / completion / references / rename**（M3）—
      definition / hover / completion（キーワード + 文書内シンボル）をテキスト走査
      ベースで実装済み（`scripts/test_vibe_lsp.js` 9/9）。references / rename と
      型付き hover / スコープ精度の高い補完は checker の部分型情報 API + source span が前提。
- [x] **4-5 editor 配線** — `integrations/vscode-vibe` に LSP client
      （`extension.js`、vscode-languageclient）を追加し `vibe lsp` を起動。
      `vibe.serverPath` 設定対応。tree-sitter/zed は grammar 済み（LSP 配線は今後）。
- [ ] **4-4 incremental**（M4, 任意）— 大規模プロジェクト向けに incremental
      parse/check。まずは module 単位キャッシュ（実装済み）で十分か評価。


---

## 依存関係と推奨順序

```
横断土台 A (parser error recovery) ──┬─→ 4 LSP (診断/補完の品質)
横断土台 B (name section/source map) ─┼─→ 3 debugger P0→P4
                                      └─→ 実行時エラーの可読性 (UX 全般)

1 install ──→ 外部ユーザーが触れる前提（最優先で着手可、他テーマと独立）
2 module  ──→ 実プロジェクトで使える前提（install と並行可）
```

- **すぐ着手**: テーマ 1（install）と土台 A/B は他に依存せず並行できる。
- **M2 の核**: 土台 A → LSP MVP、土台 B → debugger P0。この 2 つで
  「実用的な開発体験」の最低ラインに乗る。
- **M1 の核**: install + module の配布凍結。ここが無いと誰も試せない。

## 決定事項・未決事項（ADR 化対象）

決定済み（2026-06-25）:

1. ✅ **install canonical artifact** — 独自ビルドの wasmtime runner +
   compiler wasm の分離配布、install 時に各環境で `.cwasm` AOT ビルド。
   compiler は runner と独立に更新（テーマ 1）。
2. ✅ **module 配布モデル** — git/URL 分散（Deno/Go 風）、中央 registry なし、
   content hash で lock（テーマ 2）。
3. ✅ **LSP ホスト** — **native runner + selfhost wasm に寄せる（node 非依存）**。
   install を独自 wasmtime runner に決めたのと整合させ、runtime 前提を 1 本化する。
   `vibe lsp` は同 runner 上で動く selfhost LSP サーバーとして提供し、
   `js/vibe/lsp.js` の transport 抽象はブラウザ/embedding 用途の補助に留める
   （テーマ 4）。

未決（要 ADR）:

4. **言語仕様 freeze の範囲**（M4）— どこまでを 1.0 で凍結し SemVer 保証するか。

> runtime 前提は install・LSP・debugger すべて「独自 wasmtime runner +
> selfhost wasm」に一本化された。node は補助（`js/vibe/`、ブラウザ playground）
> に限定する。残る ADR は仕様 freeze（4）のみ。
