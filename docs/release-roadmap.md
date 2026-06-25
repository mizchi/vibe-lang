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

### マイルストーン

- [ ] **1-0 配布形態の決定（ADR）** — 下記オプションから canonical を選び ADR 化。
- [ ] **1-1 self-contained ランチャ** — 選んだ形態で `vibe` 単体が
      wasm + runner を内包/解決して動く（PATH に runtime 前提を置かない）。
- [ ] **1-2 マルチプラットフォーム CI** — release.yml を拡張し、
      対象 OS/arch ごとに artifact をビルド + smoke test（`vibe run` / `vibe check`）。
- [ ] **1-3 ワンライナー installer** — `install.sh`（+ Windows 用）で
      最新 release を取得 → PATH 設定。バージョン pin 可能に。
- [ ] **1-4 パッケージマネージャ配布**（M4 向け）— npm / Homebrew tap 等のうち
      1-0 で決めた経路を 1 つ以上整備。
- [ ] **1-5 docs** — README に「Install」節、`docs/install.md` を新設。

### 決めるべきこと（1-0 の選択肢）

| 案 | 内容 | 長所 | 短所 |
| --- | --- | --- | --- |
| **A. npm package** | `@vibe-lang/cli`。selfhost wasm + node 製 wasm runner を同梱 | クロスプラットフォーム 1 本、`npx` 即実行、JS 資産(`js/vibe/`)と整合 | node 依存、起動オーバーヘッド |
| **B. native binary** | `moonrun_wt`(Rust) に selfhost wasm を埋め込んだ単一実行ファイル | 依存ゼロ、最速起動 | OS/arch ごとビルド・署名が必要 |
| **C. curl installer** | `curl … | sh` で B の binary を取得 | UNIX で慣習的 | Windows 別経路、供給網の信頼が前提 |

> 推奨たたき台: **B を canonical**（依存ゼロの単一バイナリ）+ **C で配布**、
> JS 埋め込み用途に **A を補助**。最終判断は 1-0 ADR で。

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

### マイルストーン

- [ ] **2-0 配布モデルの決定（ADR）** — registry 集中か、git/URL 分散か。
- [ ] **2-1 リモート import 解決** — 決めた経路で外部ソースを取得し
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

- [ ] **3-P0 source map 基盤**（= 横断土台 B、M2）— `vibe.func_map` +
      wasm name section 出力。**まずランタイム trap がソース行を表示**できる所まで。
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

### マイルストーン

- [ ] **4-0 ホスト方針の決定（ADR）** — LSP サーバーを (a) node bridge(`js/vibe/`)
      + wasm、(b) native runner + selfhost wasm のどちらで動かすか。
- [ ] **4-A parser error recovery**（= 横断土台 A、M2 前提）— 編集中ソースで
      部分 AST + 診断を返せるようにする。
- [ ] **4-1 LSP MVP**（M2）— 既存 transport + index を結線し
      `textDocument/{publishDiagnostics, documentSymbol, definition, hover, formatting}`。
      診断は既存 checker、symbol は既存 index を流用。
- [ ] **4-2 selfhost への index 移植**（M2–M3）— `src/frontend/symbol_index.mbt`
      相当を `vibe/compiler/` 側に持ち、host 依存を外す。
- [ ] **4-3 completion / references / rename**（M3）— checker に部分型情報 API を
      足して補完を実装。
- [ ] **4-4 incremental**（M4, 任意）— 大規模プロジェクト向けに incremental
      parse/check。まずは module 単位キャッシュ（実装済み）で十分か評価。
- [ ] **4-5 editor 配線** — `integrations/*` 各拡張から `vibe lsp` を起動する設定。

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

## 未決事項（ADR 化が必要な決定）

1. install canonical artifact（テーマ 1-0）— native binary か npm か。
2. module 配布モデル（テーマ 2-0）— git/URL 分散か中央 registry か。
3. LSP ホスト（テーマ 4-0）— node bridge か native runner か。
4. 言語仕様 freeze の範囲（M4）— どこまでを 1.0 で凍結し SemVer 保証するか。

> 上記 1–3 は互いにある程度独立だが、**ランタイム前提（node を要求するか否か）**を
> install と LSP で揃えると保守が楽。先に 1-0 を決めると 4-0 が従う。
