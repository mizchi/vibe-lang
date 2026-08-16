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

## Language and documentation policy (English-first)

The prototype phase tolerated Japanese everywhere. It no longer does: **write
new PRs, issue titles and bodies, commit messages, code comments, and documents
in English.** Japanese stays welcome in chat and in review discussion — the rule
covers artifacts that live in the repository or on GitHub, because those are
read by people and tools that do not read Japanese.

This is forward-looking, not a mandate to translate the existing corpus. Do not
open a "translate everything" PR. The unit of migration is whatever a reader
consumes on its own:

- **A short document** — translate the whole file when you edit it for another
  reason. Half in each language is worse than either.
- **A large living document** (this file, `docs/adr.md`, `docs/cheatsheet.md`) —
  migrate a section at a time as sections are revised, and write **new** sections
  and new `docs/adr.md` rows in English from the start. Each is read on its own,
  so it does not inherit the surrounding language.

### Bilingual documents: `-ja` is the translation, not the original

Reader-facing documents (tutorial, language tour, install, README) may carry a
Japanese translation alongside the English one:

- `docs/tutorial/01_values_functions.vibe.md` — **canonical, English**
- `docs/tutorial/01_values_functions-ja.vibe.md` — translation

The English file is the source of truth. Prose and code comments translate;
**the program in each ` ```vibe run ` block stays the same program, so the paired
` ```output ` blocks are identical between the two files.** `scripts/vibe_md.sh
check` (`pkf run vibe-md-tutorial`) proves each file on its own; the pair is
enforced by `pkf run check-tutorial-translation-parity`
(`scripts/check_tutorial_translation_parity.sh`, in `release-check`), which
fails when a chapter has no translation, a translation has no chapter, or the
two record different output.

`docs/tutorial/` is migrated. `docs/language-tour/` was **deleted** and folded
into [docs/cheatsheet.md](docs/cheatsheet.md) — it was a fourth surface next to
the cheatsheet, the tutorial and `docs/spec/syntax.md`, and it rotted the way
this section predicts: doctest compile-checks ` ```vibe ` blocks and is blind to
prose, so it went on calling `String` a UTF-16 string (ADR-0098 made it a byte
string) and `index.vibei` the package boundary (`index.vpkg` has been, since
ADR-0070) with nothing to catch it. Its shell integration, qualified-name and
keyword sections, and its builtin signature tables, now live in the cheatsheet.

Internal documents (spec, ADR, design records, reports) get **one** language —
English — and no translation. They change too often for a second copy to stay
true.

### Documents rot; delete them

`docs/` accumulated status banners: "this is not the current rule", "superseded
by X", "the design changed after this was written". A banner is a document
admitting it already failed at its job. Fix it at the source instead:

- **The design changed mid-flight** → rewrite the document as the final state.
  Do not narrate the path that was abandoned; say what is true now. The route
  taken is in `git log` and the issue thread.
- **The migration landed** → delete the migration document. What it described is
  the implementation now, and the implementation is the honest record.
- **The design was dropped** → delete it.
- **Something still links to it** → repoint the links, then delete.

`git log` is the archive. `docs/archive/` is only for documents still actively
cited as history (e.g. [docs/archive/moonbit-retirement.md](docs/archive/moonbit-retirement.md));
it is not a place to move things you were too cautious to delete.

### ADR log rules ([docs/adr.md](docs/adr.md))

- **An ADR number is permanent and unique.** Numbers are cited from source
  comments, fixtures, gate scripts, and other ADRs, so each must resolve to
  exactly one decision. Never reuse a number, and never start a per-section
  numbering series — the sections are a reading aid, not separate registries.
- **`superseded` is a pointer, not an entry.** When a decision is replaced, fold
  what still holds into the successor and delete the old row, leaving at most a
  `(supersedes NNNN)` note in the successor. A log of dead rows is a log nobody
  reads top to bottom.
- **Delete an entry whose subject no longer exists in the tree.** An ADR about a
  script, flag, or toolchain that has been removed does not become history by
  sitting there; it becomes a false statement about the current build.
- **`proposed` must say what would make it `accepted`.** A `proposed` entry that
  has not moved in a release cycle is a decision nobody made — delete it and
  keep the idea in an issue, where triage can reach it.

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
   #1500 (optional 引数 `x?` — 起票時は未実装、現在は着地済み)

## Quick Commands

タスク runner は [pkfire](https://github.com/mizchi/pkfire) (`pkf`)。
定義は `Taskfile.pkl`。

```bash
pkf list                  # show all tasks
pkf run                   # default: release-check (full sign-off)
pkf run test              # operation gate (commit 前の主チェック)
pkf run test-affected     # affected tests only, import-graph selected (#988)
pkf run test-local        # flaker lane (directory-based selection — see caveat)
pkf run full-gate         # complete operation gate
pkf run run -- args       # run main with args
# 型検査 / 診断: vibe check <file.vibe> (空出力 = clean、診断ありは exit 1)
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
  で更新できる (`lib/@vibe/compiler/inspect_update.vibe`)。**import 不要**
  (#1571): `desugar_inspect_calls` が checker の前に `__to_string` /
  `println` / `assert_true` へ展開するので、import 解決の無い単一ファイル
  レーンで compile される fixture からも呼べる
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

`vibe check` (`--single-file` 込み) / `vibe symbols` / `vibe type-at` /
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
型エラーに `line:col` が付かないこと (**#1567** の残り)、
`vibe check --json` が `--single-file` でしか使えないこと (同 #1567 —
import 解決レーンは診断を文字列で投げるので range が無い)、
`vibe symbols` が doc comment を返さないこと (Coding Convention 節)。

> **解決済み: 「どちらの動詞を使うか」問題 (#1567)。** かつて `vibe check` と
> `vibe diagnostics` が同じ質問に別の答え方をしていた (import 解決の有無・
> clean の表現・exit code・出力先が全部食い違っていた)。今は**動詞は
> `vibe check` 一つ**で、違いは `--single-file` フラグだけ。`vibe diagnostics`
> は deprecated (既存エディタ向けに挙動を凍結したまま残置)。

### Editor query primitives — Semantic Code Navigation

```bash
# 宣言アウトライン (NAME KIND START END / 行)。go-to-def / outline の基盤
vibe symbols file.vibe

# カーソル位置 (1-based line,col) の識別子の推論型。hover の基盤
vibe type-at file.vibe <line> <col>

# カーソル位置の binding の全出現箇所 (START END char offset / 行)。rename/refs の基盤
vibe binding-at file.vibe <line> <col>

# 全 diagnostics (parse error 全件 + 型エラー)。**空出力 = clean、診断ありは
# exit 1**、行は stdout に 1件1行。import は FS から解決するので、これ単体で
# 「このファイルはコンパイルが通るか」に答えられる
vibe check file.vibe

# 同じ質問をバッファ単位で (import を辿らない)。未保存バッファを見る
# エディタ用。`--json` は LSP Diagnostic 配列 (このモードのみ)
vibe check --single-file file.vibe
vibe check --single-file --json file.vibe

# closure に捕獲されて escape する `let mut` (NAME START END / 行)。
# = codegen が wasm local ではなく heap ref cell に落とすもの (#1262)。
# 空出力 = ファイル中の `let mut` は全部ただの local
vibe escapes file.vibe
# --strict は checker 側の**厳密**述語で同じ質問に答える (ADR-0100 (1)、
# `TypeEnv` が `env_bind_mut` で運ぶのがこちら)。既定は lowering の答え
# (「codegen が box するか」= 迷ったら box なので、内側の束縛が外側の
# `let mut` と同名なだけでも報告する)、`--strict` は enforcement の答え
# (「その closure が本当にこの束縛に届くか」= shadowing を引く)。
# **コストを訊くなら既定、権限を訊くなら --strict**。--strict の出力は
# 常に既定の部分集合
vibe escapes --strict file.vibe

# 解決済みの import closure (1行1パス、依存先が先、自分自身は除く。#988)。
# ローダ自身の収集結果 = ビルドが実際にコンパイルする集合なので、実解決
# (index.vibe facade・.vpkg contract とその兄弟実装・@scope/pkg の
# store/lib 解決・directory-shared vpkg import・re-export) からずれない。
# 空出力 = import 無し。**エラーは fatal** (途中まで出た依存リストは
# 「劣化した答え」ではなく誤答なので、黙って返さない)
vibe deps file.vibe
# --direct は 1 hop だけ。index を作るならこちら — 直接エッジはそのファイルの
# テキストだけの関数なので、キャッシュ無効化がコンパイラの header cache と
# 同じ粒度になる (1 ファイル編集 → 1 ファイル再問い合わせ)。closure は
# 中のどこが変わっても全体が無効になるのでこの性質を持たない
vibe deps --direct file.vibe

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

> **`--single-file` は import を解決しない** — これは欠陥ではなく、そのモードの
> 定義。`import ./dep.vibe { Hue as T }` のあるファイルは、正しくても
> `unknown name: T::Crimson` を返す。空出力が意味するのは「**単体ファイルとして**
> clean」であって「コンパイルが通る」ではない。**可否を知りたいならフラグ無しの
> `vibe check`** を使う (`--single-file` は未保存バッファを見るエディタ用で、
> そこでは正しい道具)。逆向き — export されていない名前の import — は
> フラグ無しの `vibe check` が検査時に報告する (#1521/#1533。依存が publish する
> 環境は export surface に制限されるので、private も単なる import 素通しも
> 「is not exported by」になる)。`--single-file` は単一ファイル解析なので
> こちらは見えない。大文字名 (struct / type alias) だけは値環境が判定できず、
> 未検出のまま (#1521 の残り半分)。

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
- `pkf run test-affected` — 変更影響範囲のテストのみ (fast inner loop)。選択は
  コンパイラ自身の解決済み import グラフ (`vibe deps`) を遡る。判定できない
  変更は全件に倒れる。`pkf run test-local` (flaker) はディレクトリ選択なので
  別ディレクトリの依存元を落とす — 詳細は "Local Test Execution" 節。
- 型検査 / 診断は `vibe check <file.vibe>`（空出力 = clean、診断ありは stdout に
  1件1行 + exit 1）。import は FS から解決するので、これ単体で可否を判定できる。
  **未保存バッファ相当の単一ファイル解析が要るときだけ `--single-file`** を足す
  — そのモードは import を辿らないので、import 由来の名前を「未定義」と報告する。
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

**gc レーンは1ファイルを自己完結として compile する** — これが「gc で通らない
test」の圧倒的多数の理由。落ちるのは import した名前を**実際に使ったとき**で、
import 文があること自体ではない:

```console
$ VIBE_TEST_BACKEND=gc vibe test lib/@vibe/core/sha1_test.vibe
internal compiler error: `sha1` (local, @gc_call) reached code generation unresolved.
```

`sha1_test.vibe` は `import ./sha1.vibe { sha1 }` を持ち、それを呼ぶ。`sha1` 自体
には何も問題がない。最小例で境界まで確認できる (実測、2026-08-16):

| | gc | linear |
|---|---|---|
| import した関数を**呼ぶ** | **落ちる** (`@gc_call` unresolved) | ok |
| import はあるが**使わない** | ok | ok |
| 同一ファイル内の関数を呼ぶ | ok | ok |

診断は「compiler のバグなので報告してほしい」と言うが、**メッセージ中の名前が
自分で import したものなら**、これはレーンの仕様であってバグではない。名前が
import 由来でないなら本物の internal error なので、そのまま報告してよい。

`bench` ブロックは gc レーンでは**まだ動かない** — gc backend は
`__bench_<name>` の entry point を出さない (#1701)。`runtime/vibe` の bench 分岐が
それを検出して明示的に落とす。bench cache はモードに backend を含めるので、
`linear → gc` の切り替えでは自動的に再コンパイルされる。

builtin レベルの両レーン差は `scripts/builtin_parity_classification.tsv` に
1行ずつあり、`check_builtin_parity.sh` が gate で強制する。**「gc に無い」と
書かれた行が本当に穴なのはごく一部**で、残りは host import・意図的な非移植・
分類上の artifact。数えるならそのファイルを見ること (#1861)。

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

**変更影響範囲だけ回すなら `pkf run test-affected` を使う** (#988)。全テストを
毎回流す必要はない。

```bash
pkf run test-affected                       # origin/main との merge-base から差分を取る
pkf run test-affected -- --dry-run          # 選ばれるファイルを出すだけ
pkf run test-affected -- --explain          # なぜ選ばれたか (変更 → import 経路) を stderr へ
pkf run test-affected -- --changed lib/@vibe/parser/token.vibe   # 明示指定
```

選択は**コンパイラ自身が解決した import グラフ**を遡る (`vibe deps --direct` →
`scripts/affected_tests.mjs`)。グラフを別途導出していないので、`index.vibe`
facade・`.vpkg` contract とその兄弟実装・`@scope/pkg` の store/lib 解決・
directory-shared vpkg import・re-export といった実際の解決規則から**ずれない**。
インクリメンタルビルドの persistent header cache に乗るので、1 ファイル編集なら
再問い合わせも 1 ファイル (index 全構築は 1068 files / ~32s、warm は ~0.3s)。

**判定できないときは必ず全件に倒れる** (fail open)。import グラフの外の変更
(`scripts/`・seed・`Taskfile.pkl`・`fixtures/`)、stage2 が無い、index が
不完全 — いずれも selector が exit 2 を返し、`test_affected.sh` は全件実行に
切り替える。「判定できなかった」と「影響なし」が同じ green になってはいけない。

> **`pkf run test-local` (flaker) は選択が信用できない。** flaker.toml の
> `[affected] resolver = "simple"` は**ディレクトリ**で選ぶので、別ディレクトリ
> から import しているテストを落とす。実測 (575 entries): `core/types.vibe` の
> 変更は実際には 217 件に影響するが **0 件**しか選ばれない (そのディレクトリに
> `*_test.vibe` が無いため)。`parser/token.vibe` は 190 件に対して 1 件。
> flaker 側に custom resolver フックを入れるのが #988 の残り半分。

```bash
pkf run test-local -- --profile ci          # CI と同じ hybrid サンプリング (30%)
pkf run test-local -- --profile scheduled   # 全テスト (データ蓄積用)
```

`pkf run test` は全テスト実行。commit 前の最終確認や CI 用。

### Which compiler answered? — `vibe test` runs on the seed by default

`scripts/vibe_test.sh` compiles with the **committed seed**
(`cli_wasm="${VIBE_TEST_CLI_WASM:-$seed}"`), not with the compiler sources in
your checkout. That default is right for library code and wrong for a change to
the compiler, and **the two are indistinguishable from the result** — the file
compiles, the tests run, and you get a confident answer about a compiler that
does not contain your change.

A measured instance, one file, `x - y` through a labeled-argument lambda:

| compiler | result |
|---|---:|
| committed seed | 0 — a bug fixed in #1925 |
| stage2 from the same checkout | -7 — the still-open half of #1899 |

Neither run reports an error. So: **when you are testing a compiler change, pass
the compiler explicitly.**

```bash
VIBE_TEST_CLI_WASM=_build/selfhost/generations/<gen>_$(git rev-parse --short HEAD)/stage2.wasm \
  bash scripts/vibe_test.sh <file>
```

`vibe_test.sh` now prints a stderr notice whenever the checkout is ahead of the
seed under `lib/@vibe|@vibex` and no explicit compiler was given
(suppressed by setting `VIBE_TEST_CLI_WASM`, or by
`VIBE_TEST_QUIET_COMPILER_NOTE=1`). Pinned by `scripts/vibe_test_smoke.sh`
(`pkf run test-vibe-test`).

Two related rules, both learned the same way:

- **Establish the baseline before changing anything.** Run the failing case
  first and confirm it reproduces *through the compiler you are about to
  rebuild*. If it does not reproduce, you are measuring the wrong compiler, not
  looking at a fixed bug.
- **Never test argument order with a commutative operator.** `x + y` gives the
  right answer whether or not arguments were reordered; use `x - y`. A
  reordering bug survived a "fix verified" claim this way (#1899).

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
## レビュー・Bug Issue 起点の再発防止

PR レビューや Bug Issue の修正で、同種の問題が今後も起こり得る構造的パターンを見つけたら、
その場限りの修正で終わらせず、決定的に検出する仕組みを追加する。

- 型、effect row、名前解決、capture/escape、公開 contract など、言語の静的意味として
  判定できるものは `vibe check` に実装する。repository 固有の lint で代用しない。
- AST の形だけで判定できる repository/compiler 実装規則は
  `scripts/review_lint.vibex` に `vibe grep` パターンとして追加する。
- `.vibex` 側にパターン、capture の解釈、診断、終了コードをまとめる。shell wrapper は
  staged snapshot の準備や bootstrap compatibility に限定し、新しい判定ロジックを
  `scripts/*.sh` の正規表現として増やさない。
- 追加時は Red → Green で、違反例、非違反例、必要なら理由付き抑制例を
  `scripts/lint_review_regressions_test.sh` または `.vibex` の self-test に固定する。
- pre-commit で実行できる速度を保ち、`pkf run test-review-lint-vibex` と
  `pkf run pre-commit` の両方で検証する。
