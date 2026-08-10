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

## 設計ポリシー (迷ったらここに照らして決める)

設計判断で迷ったら、以下の 3 本柱に照らす。柱同士が衝突したときの優先順位は
**「黙って誤らない」> 表現の正直さ > 表面の書き味**。ポリシーで決めきれない
ものは issue にして 3 軸ラベル ([docs/issue-triage.md](docs/issue-triage.md)) を付ける。

**1. モダンな構文、副作用を明示する静的型付け関数型言語** (系譜: Rust /
MoonBit / Koka / Verse)。副作用は戻り値ラッパではなく effect row で表す。
**型と診断は LLM の評価ループに最適化する** — 最悪の壊れ方は「黙って誤る」で
あり triage でも P0 = silent-wrong が「落ちる」より上 (P1)。診断は内部用語
(pass 名・ADR 番号) ではなく**効く編集を先頭に**。1 つの概念に 1 つの綴り —
ただし以下は**決定済み・実装はこれから** (現在の挙動と混同しないこと):
`==` の全文脈構造的統一 (ADR-0097, #1526 — 裸 / tuple 内 / struct 内は構造的に
着地済み (名前経由の裸配列は要素がスカラーのときのみ、#1569)。**残る参照等価**:
消去された型変数 (`[T: Eq]` の `T`)・関数戻り値経由・空リテラル束縛・要素型が
スカラーでない名前経由の裸配列。cheatsheet の「`Array` の `==`」に現在の境界が
ある)、反復の eager `Array::*` + pull AsyncIter 2 層化 (ADR-0099,
#1559)、`Exception` を正として `Error` を 1.0 freeze で deprecated (ADR-0085,
#1564)。docs のコード例は doctest が現行コンパイラで検査する — 仕様と実装を
食い違わせない。

**2. wasm 上でセルフホストし、wasm の最新機能を使う**。コンパイラは vibe 製で
committed seed からビルドする。**内部表現は wasm / WIT と摩擦のない表現に
寄せる** — 値は tagged i64、String は byte string (byte offset インデックス、
ADR-0098 — メモリの実態と一致する正直な意味論)、WIT 境界に出られるものは
nominal 規則で決める (ADR-0089 D4/D5)。継続表現は wasm-gc (型主導参照レーン
ADR-0095)・stack switching (今日は stackful lift + `waitable-set`、JSPI は
別 backend)・threads を前提に設計する。マルチスレッドは**当面 shared-nothing**
(`TaskGroup` + `Send`/region 検査が既にこの形) で、将来の実スレッド化を
見据えた表現を選ぶ。

**3. Vibe Coding の時代に合わせ、権限と副作用を明示的にコントロールできる**。
Deno のパーミッション × Koka の effect system: capability は row が運び、
呼び出し側の式は素の関数呼び出しのまま。認可は build → apply → instantiate の
**最早フェーズで一回だけ**確定し、run 中 authority 不変 (ADR-0075/0084/0088)。
Notebook 駆動の開発に合わせた**インクリメンタルビルド** (`vibe check` レーンは
typing reuse が default-on、semantic module 単位へ拡張中 #1379)。**ビルド時に
決まる Capability で、対象プラットフォームの wasm runtime 仕様に合わせた
プログレッシブなコード生成** — `--allow-*` は const-fold + DCE で不許可
capability のコードを落とし、生成 wasm は要求する feature level を宣言する
([docs/wasm/feature-levels.md](docs/wasm/feature-levels.md))。

## vibe 言語リファレンス

vibe 言語の構文・機能を把握するには、最初に [docs/cheatsheet.md](docs/cheatsheet.md) を読むこと。型、関数、パターンマッチ、エフェクト、モジュールなど全機能を網羅している。

**モジュールを追加・修復するときは [docs/adding-modules.md](docs/adding-modules.md) に従う**
(置き場所の規約、テスト + allowlist ラチェット、検証手順、既知の罠)。

### 文法で詰まったときの方針

構文の可否で迷ったり、同じことを二度調べ直しそうになったら:

1. **実測してから cheatsheet の「落とし穴」節に足す。** 仕様書の記述ではなく、
   現行 stage2 に食わせた結果を書く。仕様と実装は実際に食い違うことがある
   (例: `docs/spec/syntax.md` が `test <識別子>` を「受理される」と書いていたが
   実際は拒否される、#1506 で修正)。書いた例は doctest が検査するので、
   意図的に拒否される形を見せるブロックは理由付きで ```vibe skip にする
2. **同じ文法で繰り返し失敗するなら、文法/実装側の修正を検討して issue にする。**
   「読み手が覚えるべき規則」なのか「実装都合が言語に漏れている」のかを分ける。
   後者の兆候は — 言語ツアーの正規の例が書けない、エラー文が内部用語
   (ADR 番号・pass 名) で行動可能でない、型検査を通り抜けて codegen で初めて
   落ちる、条件が複数軸の相互作用で単独では説明できない。
   実例: #1511 (`handle` の適格性), #1508 (`Http` を使う test/bench が書けない),
   #1500 (optional 引数 `x?` が未実装)

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
# (scripts/vibe_fmt_apply.sh) は `lib/**/*.vibe` と `lib/**/*.vpkg` 全体を
# このフォーマッタで一括整形する (`.vpkg` は #1435 の format_vpkg 経由 —
# ヘッダは vibe 構文ではないので専用の writer、宣言部は同じ CST
# formatter) — 既存コードベースは fixpoint。
# **CI では `vibe-fmt-check` job (scripts/check_vibe_fmt.sh, required) が
# `lib/**/*.vibe` + `lib/**/*.vpkg` 全体を --check で lint しており
# enforce されている** —
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
- `index.vpkg` - パッケージの契約 (ヘッダ + bodyless 宣言、境界かつ公開 API。
  ADR-0070/#1269)。**`index.vibei` は legacy で境界ではなく、リポジトリにも
  もう存在しない** — 詳細は [docs/adding-modules.md](docs/adding-modules.md)
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

### 方針: 期待値は snapshot に寄せる — `__DATA__` と `.diag` は畳む (#1571)

期待値を持つ仕組みが3つある。**`inspect(value, content)` + `vibe test --update`
に一本化していく**方針で、新しいテストはこれで書く。

- **`inspect(...)`** — 本命。期待値がソースの中にあり、`vibe test --update`
  で更新できる (`lib/@vibe/compiler/inspect_update.vibe`)
- **`__DATA__`** — fixture 末尾の `{"last": "..."}`。723 fixture 中 544 が使用。
  vibe の構文ではないので、fixture を単体で `vibe test` に食わせられず、
  `compiler_gate.sh` は**81 箇所で `sed '/^__DATA__$/,$d'` して剥がしている**
- **`.diag`** — `emit_compile_diag` が `<output_path>.diag` に書く sidecar。
  診断が stdout に出ないので、中断した実行が残骸を落とす (`a.wasm.diag` /
  `b.wasm.diag` がリポジトリ root に tracked で残っていた)。stdout へ移す話は
  #1567 と同じ問題

`fixtures/warnings/*.diag` は逆に**意図的にコミットされた期待出力**なので、
これも snapshot 側へ寄せる対象。移行は一括ではなく、触った fixture から。

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
- **effect 名と代数 effect の operation は CamelCase** (#1458)。operation が
  snake_case でないのは、effect が**代数レコードを発行している**からで、
  `Log::Emit` は関数ではなく constructor に当たる。一方 capability builtin
  (`Fs::read_file` / `Env::get` / `Console::write_stream`) は本当に関数なので
  `Effect::snake_case`。この二トラックは揺れではなく用途の違いで、
  `perform` が要るかどうかで見分けられる。分類の表と使い分けは
  [docs/cheatsheet.md](docs/cheatsheet.md) の "Effect classes and how
  operations are spelled" と ADR-0084
  ([docs/effect-taxonomy-entry-policy.md](docs/effect-taxonomy-entry-policy.md))。
- **言語ポリシー: コアロジック以外は、できるだけ「色のない関数」で書けるように
  する** — 権限は row が運び、呼び出し側の式は素の関数呼び出しのままにする
  (capability builtin がその形)。

## Code Navigation (IMPORTANT)

> `moon ide` / `moon doc` は MoonBit host 退役 (#594) で使えなくなった。
> 今は `vibe lsp` とその基盤になっている editor query primitives を使う
> (#637, [docs/editor-and-debugging.md](docs/editor-and-debugging.md))。

**コード探索は `vibe symbols` / `vibe type-at` / `vibe binding-at` を使う**
(hover・rename・go-to-def と同じ AST 解析を CLI から直接叩ける)。

### 方針: CLI を LLM 向けの IDE 相当クエリ面として育てる

`vibe check` / `vibe diagnostics` / `vibe symbols` / `vibe type-at` /
`vibe binding-at` / `vibe escapes` / `vibe bench` は、エディタが LSP 越しに
得るのと同じ意味解析を **CLI から直接**取り出すためのもの。**想定する第一の
読み手は人間ではなく LLM** で、次を満たすことを目標にする:

- **行指向で grep できる** — 1件1行、固定フィールド順。整形された箱や
  カラー装飾を前提にしない
- **空出力 = clean** — 「問題なし」を出力の有無で判定できる
- **判定に使える** — 「このファイルはコンパイルが通るか」に CLI 単体で
  答えられる。答えられないなら、それは診断の穴であって呼び出し側の
  作法の問題ではない
- **メッセージが行動可能** — ADR 番号や pass 名など内部用語ではなく、
  何を書き換えれば直るかを述べる (#1511 の実例)

**これは自己改善のループとして運用する。** 開発中にこれらを使って
「欲しい情報が取れない」「出力が読めない」「嘘をつく」に当たったら、
**その場で CLI 側を直すか issue を立てる** — ワークアラウンドを覚えて
先へ進まない。CLI が答えられない質問はそのまま、LLM がこのリポジトリで
作業するときのコストとして毎回効いてくる。

現に効いている既知の穴 (どれもこの方針違反として扱う):
`vibe check` と `vibe diagnostics` が同じ質問に別の答え方をすること
(**#1567** — 統合提案。import 解決の有無・clean の表現・exit code・
出力先が全部食い違い、どちらを使うかを呼び出し側が覚えている)、
型エラーに `line:col` が付かないこと (同 #1567)、
`vibe symbols` が doc comment を返さないこと (Coding Convention 節)。

### Editor query primitives — Semantic Code Navigation

```bash
# 宣言アウトライン (NAME KIND START END / 行)。go-to-def / outline の基盤
vibe symbols file.vibe

# カーソル位置 (1-based line,col) の識別子の推論型。hover の基盤
vibe type-at file.vibe <line> <col>

# カーソル位置の binding の全出現箇所 (START END char offset / 行)。rename/refs の基盤
vibe binding-at file.vibe <line> <col>

# 全 diagnostics (parse error 全件 + 型エラー)。空出力 = clean
# ただし単一ファイル解析で import を辿らない → import のあるファイルでは
# 「未定義」の誤検知を出す。import があるなら `vibe check` で判定すること
vibe diagnostics file.vibe

# closure に捕獲されて escape する `let mut` (NAME START END / 行)。
# = codegen が wasm local ではなく heap ref cell に落とすもの (#1262)。
# 空出力 = ファイル中の `let mut` は全部ただの local
vibe escapes file.vibe

# AST パターン検索 (#1572)。上の4つが「位置 → 意味」なのに対しこれは逆向きの
# 「構造 → 位置」。メタ変数は `$(name:kind)` (kind: exp/id/const/arg/args/pat/type)。
# 出力は 1件1行 `path:line:col: <マッチ本文>` + tab 区切りの `$var=<capture>`。
# 空出力 = マッチなし (--json では `[]`)
vibe grep --pattern 'Iterator::map($(a:args))' lib
# **文法だけで止まらない**のが moongrep / ast-grep との差: filter は checker の
# 答え (推論型・effect row・解決済み名・型エラー) で書く。これらを付けると
# `vibe check` と同じ import 解決レーンに乗る (typed tier)
vibe grep --pattern 'f($(x:exp))' --where '$x : Array[_]' lib
vibe grep --pattern '$(f:id)($(a:args))' --where '$f = Iterator::map' lib
vibe grep --pattern '$(f:id)($(a:args))' --where-row '$f with Async' lib
vibe grep --pattern 'f($(x:exp))' --only-ill-typed lib
```

> **`vibe diagnostics` は import を解決しない。** `import ./dep.vibe { Hue as T }`
> のあるファイルは、正しくても `unknown name: T::Crimson` を返す。空出力が意味
> するのは「**単体ファイルとして** clean」であって「コンパイルが通る」ではない。
> **import があるファイルの可否は `vibe check`** で見る (diagnostics はエディタの
> バッファ単位フィードバック用で、そこでは正しい道具)。逆向き — export されて
> いない名前の import — は `vibe check` が検査時に報告する (#1521/#1533。
> 依存が publish する環境は export surface に制限されるので、private も
> 単なる import 素通しも「is not exported by」になる)。`vibe diagnostics` は
> 単一ファイル解析なのでこちらは今も見えない。大文字名 (struct / type alias)
> だけは値環境が判定できず、未検出のまま (#1521 の残り半分)。

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
  **import を辿らないので、import のあるファイルは `vibe check <file.vibe>` で
  判定すること** — diagnostics は import 由来の名前を「未定義」と誤検知する。
- selfhost の CST-token formatter は実装済み (`lib/@vibe/compiler/fmt/format.vibe`,
  #854/#1138) — `bash scripts/vibe_fmt.sh [--check|--stdout] <file>` で
  直接使える。`pkf run fmt` (`scripts/vibe_fmt_apply.sh`) は `lib/**/*.vibe`
  と `lib/**/*.vpkg` 全体をこのフォーマッタで一括整形する（書き込みモード）。
- **`.vpkg` は `format_vpkg` (#1435) が扱う**: ヘッダ (`name = @scope/pkg` /
  `version = x.y.z` / `description =` + `#|` / `deps = { ... }` /
  `generated_hash =`) は vibe 構文ではない (`@scope/pkg` は式ではない) ので
  専用の writer で正規化し、その下の bodyless 宣言部だけを `format_script`
  に通す。境界判定は `contract/contract.vibe` の `scan_package_header` の
  行分類をそのまま写したもの — loader が directive と見なさない行は必ず
  宣言部に落ちる。ヘッダが loader にとって不正な形 (未終端の `deps = {`、
  `:` の無い dep 行、`name  =` のような loader が認識しない綴り) の場合は
  **ファイルに一切触らない** (壊すより黙って降りる)。
- **CI では `vibe-fmt-check` job (`scripts/check_vibe_fmt.sh`, required) が
  `lib/**/*.vibe` + `lib/**/*.vpkg` 全体を `--check` で lint し、enforce
  している** —
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

# P0 (黙って誤るもの) だけ / 着手可能な blocker だけ
gh issue list --state open --label P0
gh issue list --state open --label blocker
```

**分類と優先順位の規則は [docs/issue-triage.md](docs/issue-triage.md)。**
3 軸 (種類 / 優先度 P0-P2 / `blocker`) を独立に付け、着手順はそこから機械的に決まる。
優先度は**壊れ方の悪質さだけ**で決める (P0 = 黙って誤る、P1 = 落ちる・書けない、
P2 = 機能追加)。「重要そう」は優先度に入れない。新規起票時は 3 軸を付けるところまでが
起票の一部。

長い issue は **sub-issue でツリー化**する — 親は現在地と子への索引だけを持ち、
経緯はコメントに残す。本文にチェックリストを積み上げると、着地した項目が増えるほど
「次に何をやるか」が読めなくなる。

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
