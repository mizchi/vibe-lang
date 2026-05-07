# Architecture Decision Log

軽量な意思決定レコード。各エントリは「何を決めたか」だけを記録する。
詳細な経緯が必要な場合は git log や issue を参照。

細粒度の locked decisions は [spec/decisions.md](spec/decisions.md) を参照。

---

## 凡例

- **accepted** — 採用済み・実装済み
- **proposed** — 方針決定済み・未実装または実装中
- **deferred** — 延期
- **superseded** — 後続の決定で置き換え済み

---

## Core Language

| # | Decision | Status |
|---|----------|--------|
| 0001 | **MoonBit を実装言語に採用**。WASM/JS/Native ターゲット、snapshot テスト、MoonBit ツールチェーン活用。 | accepted |
| 0006 | **62-bit タグ付き Int**。リテラル上限 2^61-1、i64 下位 2bit タグ、`>>` は算術シフト、`~` 非対応。 | accepted |
| 0016 | **エラー制御構文を `handle`/`throw` に統一**。`throw()` で送出、`handle { ... } with Error { Throw(_) => ... }` で捕捉。try/catch/raise は廃止。 | accepted |
| 0020 | **Pipe-first 呼び出し規約**。`x \|> f` → `f(x)`、parser でデシュガー。`.` はデータアクセス専用。名前解決: local > lexical > import > prelude。 | accepted |
| 0023 | **`is` パターンマッチ式**。`expr is pattern` で Bool / binding。`EMatch` にデシュガー。 | accepted |
| 0025 | **else 節を一般の式に統一**。else の後に任意の式を許可。 | accepted |
| 0037 | **トップレベル前方参照**。codegen で topological sort + 前方アノテーション関数の pre-scan。パラメータ型注釈必須、自己再帰は `let rec` + 返り値注釈。 | accepted |
| 0044 | **Iterator trait による map/filter/fold 汎用化**。`trait Iterator[T] { next(Self) -> Option[T] }` + `trait Iterable[T] { iter(Self) -> Iterator[T] }`。現状 `Array::map` 等は Array 固定かつ `(T)->T` で型変換不可。Iterator trait 導入で: (1) 任意コレクションに map/filter/fold を提供 (2) `(T)->U` 型変換対応 (3) lazy evaluation (collect まで実体化しない) (4) `for-in` を Iterable ベースにデシュガー統一。pipe-first との親和性高。段階移行: Phase 1 trait 定義+Array impl → Phase 2 for-in 統一 → Phase 3 String/Map/List 対応 → Phase 4 旧 builtin deprecated。 | proposed |
| 0045 | **`derive(Eq)` の実装** (#148)。ユーザー定義 enum/struct に `==` を自動導出。`assert_eq` のカスタム型対応 (#153) もこれに依存。 | proposed |
| 0046 | **`Option[T]` sugar `T?`** (#149)。parser で `T?` → `Option[T]` に展開。 | proposed |
| 0047 | **`loop` 式 — `break(value)` で値返却** (#151)。現状 loop は Unit 固定。checker+codegen で break の値を loop 式の型に。 | proposed |
| 0048 | **`map` コンテキストキーワード化** (#152)。`map {` の場合のみキーワード、それ以外は識別子。`Array::map` が `r#` なしで使用可能に。 | accepted |

## Effect System

| # | Decision | Status |
|---|----------|--------|
| 0003 | **エフェクトセット検証**。`with { Effect }` 宣言で追跡。`do` 境界検証は廃止 (v2)。エフェクト名の個別追跡は ADR-0021 で拡張予定。 | accepted |
| 0017 | **`let mut` は局所可変状態として許可**。`Ref[T]` は abandoned → ADR-0021 の Effect Handler で代替。 | superseded (→0021) |
| 0021 | **ミュータビリティを Effect Handler で表現**。`effect Mut<T> { push(); build() }` + `handle ... with Mut<T>`。参照脱出を構造的に防止。tail-resumptive inline 最適化。Component Model `#import` 統合。WASI P3 HTTP を capability effect (Model 1) で表現。 | proposed |
| 0041 | **`_start` は `() -> Unit` 固定**。`with { Effects }` で capability 宣言。exit code は panic/Process::exit。REPL は例外。 | proposed |
| 0042 | **トップレベル未処理 effect 禁止**。ファイルモジュール top-level は pure (effect_scope_none)。shell/REPL/test は別スコープ。 | proposed |
| 0043 | **Capability-driven DCE + 定数分岐**。`--allow-*`/`--deny-*` で capability 指定 → 不要コード除去。`@build.*` 定数 + dead branch elimination。`--profile` プリセット (minimal/sandbox/server/edge/agent)。 | proposed |
| 0050 | **`handle` を汎用 effect handler に統一**。canonical syntax は `handle { expr } with EffectName { Op(...) => ...; }`。`Error` も built-in effect として一般化し、`throw(e)` は `perform Error::Throw(e)` の sugar とする。`resume` は one-shot / lexical-scope 限定、arm は exhaustive・top-to-bottom first-match、複数 effect は nested handle で表現する。 | proposed |
| 0051 | **Trait 解決レイヤを 3 層化**。現行の `TypeEnv` 連結リスト走査（`EnvTraitDef`/`EnvTraitImpl`/`EnvTraitImplGen`）を、(1) **TraitGraph**（trait 定義と super 関係の閉包・cycle 検証）、(2) **ImplIndex**（`trait -> target` の実装索引と overlap 事前検証）、(3) **ObligationSolver**（`type_implements_trait` と bound 充足判定）へ分離する。`trait_is_subtrait` と `type_implements_trait` の責務を分割し、trait 多層化（supertrait の深い階層）時の探索コスト・不整合検出・診断品質を改善する。移行は `TypeEnv` 互換アダプタを置く段階移行（read-path 先行）で行う。 | proposed |

## Module & Identity

| # | Decision | Status |
|---|----------|--------|
| 0004 | **コンテンツアドレスモジュール (Unison 式)**。SHA1 ハッシュ。三層 ref: HashRef (実行時), VersionRef, SymbolRef (ユーザー向け)。 | accepted |
| 0005 | **標準ライブラリ階層型境界**。5 層: trait-contract → pure-primitive → pure-data → ref-model → effect-boundary。外部パッケージ分離。 | accepted |
| 0009 | **スクラッチワークフロー**。`vibe shell` / `shell-stdin` で定義を蓄積し、namespace head をコンテンツハッシュで管理、`finalize` で `.vibe` へ反映する。 | accepted |
| 0015 | **分散 Ref (Git Object ストレージ)**。不変データ = Git object、可変ポインタ = `refs/bit/index/<scope>/graph/{head,wal_head}`。delta chain で append。 | accepted |
| 0019 | **Canonical naming**。`domain_verb` パターン (`io_read`, `socket_connect`)。型所有は `Type::method`。 | accepted |

## Compilation & Optimization

| # | Decision | Status |
|---|----------|--------|
| 0024 | **Named 型の遅延展開 (Lazy Enum Expansion)**。`normalize_type(expand_enum=false)` がデフォルト。match/unify/pattern 時のみ展開。parser 5.2x 高速化達成。 | accepted |
| 0032 | **Wite optimize hints**。`wite.cfp_const_hints` カスタムセクションで const-forward ヒントを emit。 | accepted |
| 0034 | **Compiled-only execution surface**。run/test/bench/shell は compiled 固定。interpreter は内部のみ、段階的に削除。 | accepted |
| 0036 | **WASM-GC main backend gate**。`test-wasm-gc-mainlane-e2e` pass で main 候補。`--wasm` → wasm-gc、旧 linear は `--wasm-linear`。 | accepted |
| 0038 | **Perceus RC バイナリサイズ最適化**。4-byte RC header、free-list optional、i64 space tagging、br_table dispatch。1.95x→1.49x 達成。 | accepted |
| 0040 | **Checker/Codegen contract boundary**。`@core` パッケージが checker と codegen の間の安定 contract を提供。codegen は checker に一切依存せず、`@core.Module` / `@core.Type` / `@core.ExprTypeIndex` のみを入力として動作。`runtime_compile` がオーケストレータとして両者を接続。 | accepted |
| 0049 | **Perceus RC isolation boundary**。RC 専用コードは `wasm_codegen_rc.mbt` (1696 LOC) + `perceus_poc.mbt` (2327 LOC) に集約。`wasm_gc_codegen.mbt` は RC に一切依存しない。`enable_rc` フラグで linear backend 内でも RC パスを制御可能。将来の wasm-gc only build flavor では RC ファイルを link graph から除外可能。 | accepted |

## Platform & Runtime

| # | Decision | Status |
|---|----------|--------|
| 0007 | **HTTP バックエンドを純粋 MoonBit 実装に**。vibe/socket (WASI P2) 上の HTTP/1.1。C FFI なし。 | accepted |
| 0010 | **WASM Component Model / WIT 統合**。`--component` ターゲット。stdio→wasi:cli、effect→host import。将来 WIT 自動生成。 | accepted |
| 0011 | **AI エージェント向け WASM ランタイム**。Deno + WASM REPL。typecheck/compile/run/eval API は構造化 JSON 返却。 | accepted |
| 0028 | **Selfhost CLI は pure compile API のみ**。I/O は host/adapter 層。将来 Preview2/Component adapter で WASI 追加。 | accepted |
| 0033 | **Selfhost 0.1.0 release profile**。canonical artifact: `_build/dist/selfhost_compiler.wasm`。linear/WASM 正式、GC experimental。 | accepted |
| 0039 | **WASM-GC / Component dual-track**。当面は component+linear と wasm-gc を並行。Canonical ABI GC 対応後に single-track へ。 | proposed |

## Tooling

| # | Decision | Status |
|---|----------|--------|
| 0008 | **不安定機能フラグ**。`--unstable-async`, `--unstable-threads` で experimental 機能をゲート。 | accepted |
| 0018 | **ライブラリ API を Result ベースへ移行**。throw→Result[T, String]。bind/map_ok 合成。deprecated alias で段階移行。 | accepted |
| 0026 | **純粋テストキャッシュと QuickCheck**。pure test は source hash + deps + compiler version でキャッシュ。fixed-seed QuickCheck は pure 扱い。 | proposed |
| 0035 | **DAP デバッグ**。DWARF 不採用、カバレッジインフラ拡張で独自 DAP サーバー。`vibe.func_map`/`debug_map` カスタムセクション。Node.js ベース。 | proposed |
| 0049 | **CI キャッシュキーに moonc バージョンを含める**。`scripts/install_moonbit.sh` が install 後に `.moon-version` スタンプを書き、全ワークフローの `actions/cache` key が `hashFiles('.moon-version')` を参照する。moonc 上流更新時に古い `_build` 成果物が再利用されるのを防ぐ。きっかけは Linux native CLI 回帰クラスタ (#265/#266/#267/#268/#280/#281) — moon 0.1.20260403 で作られた成果物が、source 未変更のまま stale 再利用されていた。 | accepted |

## Deferred

| # | Decision | Status |
|---|----------|--------|
| 0012 | **Async/Await (Stack Switching + WASI P3)**。`{Async}` effect + Future[T] + Stream[T]。WASM Stack Switching 安定化待ち。P3 HTTP は ADR-0021 の同期 effect で対応可能。 | deferred |

---

*旧個別ファイルは `docs/archive/adr/` に移動。*
