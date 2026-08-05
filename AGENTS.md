# vibe (selfhost-only)

> **Status (2026-06-23, #594):** vibe is now **selfhost-only**. The MoonBit host
> implementation (`src/`, `moon.mod`) was retired. The compiler is built,
> checked, and run entirely from the committed seed (`bootstrap/seed/`)
> + selfhost source (`lib/@vibe/compiler/`, `lib/@vibe/cli/`) via the Rust/node wasm runner
> — **no MoonBit toolchain (`moon`) is required**. The default gate is
> `pkf run release-check` → `scripts/compiler_gate.sh`.
>
> Sections below that reference `moon` (`moon fmt/test/check/info`) or `src/`
> describe the **retired** host flow and are kept only for historical context;
> they no longer run. Recovery point for the last MoonBit-host state: tag
> `moonbit-host-final-2026-06-23` (`59ef040`). Migration record:
> [docs/archive/moonbit-retirement.md](docs/archive/moonbit-retirement.md).

## vibe 言語リファレンス

vibe 言語の構文・機能を把握するには、最初に [docs/cheatsheet.md](docs/cheatsheet.md) を読むこと。型、関数、パターンマッチ、エフェクト、モジュールなど全機能を網羅している。

**モジュールを追加・修復するときは [docs/adding-modules.md](docs/adding-modules.md) に従う**
(置き場所の規約、テスト + allowlist ラチェット、検証手順、既知の罠)。

## Quick Commands

タスク runner は [pkfire](https://github.com/mizchi/pkfire) (`pkf`)。
定義は `Taskfile.pkl`。

```bash
pkf list                  # show all tasks
pkf run                   # default: release-check (full sign-off)
pkf run test              # operation gate (commit 前の主チェック)
pkf run test-local        # affected tests only (fast inner loop)
pkf run full-gate         # complete operation gate
pkf run run -- args       # run main with args
# 単一ファイルの型検査 / 診断: vibe diagnostics <file.vibe>
# selfhost の CST-token formatter (lib/@vibe/compiler/fmt/format.vibe,
# scripts/vibe_fmt.sh, #854/#1138) は実装済みで `bash scripts/vibe_fmt.sh
# [--check|--stdout] <file.vibe>` で直接使える。`pkf run fmt`
# (scripts/vibe_fmt_apply.sh) は `lib/**/*.vibe` 全体をこのフォーマッタで
# 一括整形する — 既存コードベースは2026-07-28に一括整形済みで fixpoint。
# **CI では `vibe-fmt-check` job (scripts/check_vibe_fmt.sh, required) が
# `lib/**/*.vibe` 全体を --check で lint しており enforce されている** —
# scripts/generate_bundle.sh が生成する圧縮/ミニファイド bundle 成果物
# (compiler_sources_bundle.vibe 等、手でフォーマットする対象ではない) だけが
# scripts/vibe_fmt_allowlist.txt に恒久的な例外として載っている。
# moon 依存の `check`/`info`/`test-update` や per-package `test:*` は
# dead-task cleanup で Taskfile から削除済み。
```

## Project Structure

selfhost-only (#594) 以降、ソースはすべて vibe (`.vibe`)。旧 MoonBit host の
`moon.mod` / `moon.pkg` / `*.mbt` / `*.mbti` は撤去済み。

- `*.vibe` - Source files (compiler・stdlib・テスト・fixtures すべて)
- `*_test.vibe` - Test files (`test { ... }` / `test "name" { ... }` ブロック)
- `*_bench.vibe` - Benchmark files (`bench { ... }` ブロック)
- `index.vibe` - パッケージのエントリ (`lib/@vibe/<pkg>/index.vibe`)
- `index.vibei` - パッケージの契約 interface (bodyless 宣言 + conformance 照合)
- `Taskfile.pkl` - pkfire タスク定義

### 変更の入れ先

vibe compiler の実装は `lib/@vibe/compiler/` と `lib/@vibe/cli/` が source of
truth。parser/checker/codegen/runtime compile だけでなく、CLI のコマンド挙動、
adapter、bundle、component entry もここへ実装する。旧 MoonBit 実装 `src/` は
#594 で完全に撤去済みなので、迷ったらここ以外に入れる場所はない。

Rust-style seed compiler / stage0-stage2 / bootstrap bump の運用は
[docs/bootstrap.md](docs/bootstrap.md) に従う。新しい syntax を
compiler source 自体で使う場合は、先に seed compiler がその syntax を理解できる
状態を tag し、bootstrap bump を通してから source を移行する。
[docs/operation-gate.md](docs/operation-gate.md) の判断基準に従い、節目で
`pkf run full-gate` を通す。旧 `pkf run selfhost-trial-gate` 互換 alias は #850 Phase B で削除した。

判断目安:
- 「`vibe test foo.vibe` で挙動を変えたい / 新 builtin を追加したい」
  → `lib/@vibe/compiler/` 側だけを変更する
- 「CLI の挙動を変えたい / コマンドを追加したい」
  → `lib/@vibe/compiler/entry` / `lib/@vibe/cli/dispatch.vibe` の
  `selfhost_cli_*` handler / component adapter 側で実装する
- 「コンパイラが正しく自分でコンパイルできない」「dist wasm が壊れて
  いる」 → まず `lib/@vibe/compiler/` / bootstrap scripts / seed 管理を直し、
  `pkf run full-gate` で確認する

CI shard では:
- `scripts/pkfire/gates_shard.sh bootstrap|cli|check|coverage` がゲートを走らせる
- `pkf run full-gate` を継続運用判断の主 gate とする

## Coding Convention

- `///|` は MoonBit (`.mbt`) 時代の block separator 記法。新規コードでは
  使わないこと — ただし移植時の残骸が `lib/@vibe/compiler/core/types.vibe`
  ほか数ファイルにまだ残っている(2026-07-28 時点で4ファイル)。見つけたら
  削除して構わないが、一括削除はこの PR ではやっていない。**vibe の doc
  comment は `///`** (Rust 風、宣言の直前に置くとその宣言の doc として
  hover/`vibe doc-at` から拾われる。実装は `lib/@vibe/parser/lexer.vibe`
  `collect_doc_comments`)。**`vibe symbols` はまだ doc comment を返さない**
  (`runtime/symbol_spans.vibe` は `(name, kind, start, end)` のみ) —
  拾えるのは hover と `doc-at` だけ。既存の `//#` (モジュール冒頭説明・
  セクション見出しに広く使われている非公式記法) は `///` と意味が異なる
  (`//#` は複数宣言にまたがる説明やセクション区切りにも使われており、
  `///` の「直後の1宣言に対応する doc」という意味論とは食い違う) ため、
  一括置換はしていない — 使い分けは書く場所ごとに判断すること。
- variables/functions は snake_case (lowercase only)

## Code Navigation (IMPORTANT)

> `moon ide` / `moon doc` は MoonBit host 退役 (#594) で使えなくなった。
> 今は `vibe lsp` とその基盤になっている editor query primitives を使う
> (#637, [docs/editor-and-debugging.md](docs/editor-and-debugging.md))。

**コード探索は `vibe symbols` / `vibe type-at` / `vibe binding-at` を使う**
(hover・rename・go-to-def と同じ AST 解析を CLI から直接叩ける)。

### Editor query primitives — Semantic Code Navigation

```bash
# 宣言アウトライン (NAME KIND START END / 行)。go-to-def / outline の基盤
vibe symbols file.vibe

# カーソル位置 (1-based line,col) の識別子の推論型。hover の基盤
vibe type-at file.vibe <line> <col>

# カーソル位置の binding の全出現箇所 (START END char offset / 行)。rename/refs の基盤
vibe binding-at file.vibe <line> <col>

# 全 diagnostics (parse error 全件 + 型エラー)。空出力 = clean
vibe diagnostics file.vibe
```

### `vibe lsp` - Language Server

```bash
vibe lsp        # stdin/stdout で LSP を話す。任意の LSP client を向ける
```

diagnostics / hover / document symbols / go-to-def / references / rename /
completion / signature help を提供する。詳細は
[docs/editor-and-debugging.md](docs/editor-and-debugging.md)。標準ライブラリ API
の発見も `vibe symbols` で該当モジュールの `index.vibe` を見るのが速い。

## vibe 言語の Int 型制約

- **リテラル上限**: 2305843009213693951 (2^61-1)。それ以上は `IntLiteralOverflow`
- **ランタイム**: 62-bit tagged (i64 の 2-bit タグ付き)。範囲: -2^61 〜 2^61-1
- **hex リテラル**: `0xFF`, `0X1A2B` (prefix・digits ともに大文字小文字可)
- **`>>` は算術シフト（符号拡張あり）**: 符号なし右シフトには `(x >> n) & ((1 << (32 - n)) - 1)` を使う
- **`~` (bit_not) 非対応**: `x ^ mask` で代用
- **ビット演算子**: `&`, `|`, `^`, `<<`, `>>` は使用可能

## 実装上の Gotcha (MoonBit ホスト側)

- **MoonBit `String <` は length-first**: `"buf" < "acc_bits"` が `true` になる
  (長さ比較が先、その後 char 比較)。**lexicographic な順序が必要なら自前で
  char-by-char 比較する関数を書くこと**。compiler/codegen 内で構造体の
  field を sort する箇所 (`sort_record_fields_expr`, `register_struct_types_gc`
  等) でこの落とし穴で ADR-0052 実装中に wasm-gc cast-failure を生んだ実例
  あり (`src/codegen/wasm_codegen_data.mbt::record_field_name_lt` 参照)。
- **`is_mut~` のような短縮ラベル記法は struct literal 内で使えないことがある**:
  `StructField::{ is_mut~, ... }` が parse error になる場面があった。
  保守的に `is_mut: is_mut` と書くのが無難。
- **`/* */` C-style block comment 非対応**: MoonBit は `//` line comment のみ。
  式の中にコメントを挟みたい場合は別行に分ける。

## Tooling

> `moon fmt/info/test/check` は MoonBit host 退役 (#594) で使えなくなった。
> 検証は `pkf` のゲートと `vibe` CLI を使う。

- `pkf run test` — operation gate (`scripts/compiler_gate.sh`)。commit 前の主チェック。
- `pkf run release-check` — full gate (fmt + info + check + test + operation gates)。
- `pkf run test-local` — 変更影響範囲のテストのみ (fast inner loop、flaker 経由)。
- 単一ファイルの型検査 / 診断は `vibe diagnostics <file.vibe>`（空出力 = clean）。
- selfhost の CST-token formatter は実装済み (`lib/@vibe/compiler/fmt/format.vibe`,
  #854/#1138) — `bash scripts/vibe_fmt.sh [--check|--stdout] <file.vibe>` で
  直接使える。`pkf run fmt` (`scripts/vibe_fmt_apply.sh`) は `lib/**/*.vibe`
  全体をこのフォーマッタで一括整形する（書き込みモード）。
- **CI では `vibe-fmt-check` job (`scripts/check_vibe_fmt.sh`, required) が
  `lib/**/*.vibe` 全体を `--check` で lint し、enforce している** —
  `pkf run check-vibe-fmt` / `pkf run release-check` からも呼べる。既存
  コードベースは2026-07-28に `pkf run fmt` で一括整形済みで fixpoint —
  残る `scripts/vibe_fmt_allowlist.txt` のエントリは
  `scripts/generate_bundle.sh` が生成する圧縮/ミニファイド bundle 成果物
  (`compiler_sources_bundle.vibe` 等、手でフォーマットする対象ではない)
  だけの恒久的な例外。新規に allowlist エントリが増える場合は debt として
  扱い、`bash scripts/vibe_fmt.sh <file>` で整形してから追加を検討する。

### `vibe test` / `vibe bench` backend 切り替え

`vibe test` / `vibe bench` は既定で linear-memory backend を使う
(`vibe build --release` と同じ codegen path)。

**`VIBE_TEST_BACKEND=gc` / `VIBE_BENCH_BACKEND=gc` を設定すると wasm-gc
backend に切り替わる** — HTTP/FS host imports を必要としない pure な
test/bench に限る。wasm-gc 専用機能 (ADR-0052 の `mut` struct field 等)
を test/bench レベルで踏みたいときに使う。

```bash
vibe test foo_test.vibe                        # default: linear
VIBE_TEST_BACKEND=gc vibe test foo_test.vibe   # opt-in: wasm-gc

vibe bench foo_bench.vibe                       # default: linear
VIBE_BENCH_BACKEND=gc vibe bench foo_bench.vibe # opt-in: wasm-gc
```

wasm-gc には HOF / Iterator 系の codegen ギャップ (`src/tests/vibe_wasm_gc_e2e_test.mbt`
冒頭コメント参照) があるため、すべての test/bench が gc で通るわけでは
ない点に注意 (例: sha1 bench は `read_word` 未対応で fail、zlib inflate の
LZ77 backreference 経路は trap)。bench cache はモードに backend を
含めるので、`linear → gc` の切り替えで自動的に再コンパイルされる。

## Task Management

タスクは GitHub Issues (`gh issue`) で管理する。ロードマップは
[docs/release-roadmap.md](docs/release-roadmap.md) 参照 (`TODO.md` は
`docs/archive/TODO.md` へ移動済み、historical のみ)。

```bash
# タスク一覧
gh issue list --state open

# 新規タスク作成
gh issue create --title "タイトル" --body "内容"

# タスク完了
gh issue close <number>

# ラベル付き
gh issue create --title "タイトル" --label bug
```

設計判断は `docs/adr.md` に記録する。旧個別ファイルは `docs/archive/adr/`。

## Local Test Execution

ローカルでのテスト実行には `pkf run test-local` を使う。全テスト（1162件、~2分）を毎回流す必要はない。
これは `scripts/flaker_run.sh` 経由で `flaker` を起動するため、mise の symlink 経由で CLI が no-op になる問題を避けられる。

```bash
# 変更に影響するテストだけ実行（推奨、時間制約120秒）
pkf run test-local

# CI と同じ hybrid サンプリング（30%）
pkf run test-local -- --profile ci

# 全テスト実行（データ蓄積用、定期的に）
pkf run test-local -- --profile scheduled
```

`pkf run test-local` はデフォルトで `--profile local`（affected 戦略）を使い、`git diff` から影響範囲のテストだけを選択する。データが蓄積されるほど選択精度が上がる。

`pkf run test` は全テスト実行。commit 前の最終確認や CI 用。

## Before Commit

```bash
pkf run release-check  # fmt + info + check + test + vibe-normalize + bundle-size + operation gates
```

## 生成物 (ビルド時生成、非 tracked)

`lib/@vibe/compiler/` の5つの生成物 (`compiler_sources_bundle.vibe`,
`cli_adapter_bundle.vibe`, `selfbuild_runtime_entry_bundle.vibe`,
`_cli_adapter_module_source.vibe`, `cache/codegen_fingerprint.vibe`) は
**git 管理下から外れた**。(pinned seed, compiler source) の決定的な関数なので、
必要なときに `scripts/ensure_generated.sh` が作る。

```bash
bash scripts/ensure_generated.sh          # fingerprint が動いていれば再生成、でなければ ~1s の no-op
bash scripts/ensure_generated.sh --check  # 生成せずに鮮度だけ判定 (stale なら exit 1)
```

`pkf run test` / `release-check` / CI shard / SessionStart hook から自動で
呼ばれるので、通常は意識しなくてよい。

以前はこの5つが tracked だったため、compiler source に触る PR 同士が**必ず**
全部で衝突し、しかもどちらの側も正しくない (merge 後の source から regenerate
したものだけが正しい) という状態だった。`resolve_generated_conflicts.sh` は
その後始末専用のスクリプトで、tracking をやめたので一緒に削除した。

詳細は [docs/bootstrap.md](docs/bootstrap.md).

## pkfire

タスク runner は `Taskfile.pkl` (129 tasks、dead-task cleanup 後)。`pkspec/` は
Taskfile から参照されなくなったため削除済み。
CI は `~/.cache/pkfire` を `actions/cache` でキャッシュしているため、
変更がない subgraph は cache hit でスキップされる。
詳細は [docs/pkfire-pkspec.md](docs/pkfire-pkspec.md)。
