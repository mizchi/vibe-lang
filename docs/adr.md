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
| 0044 | **Iterator trait による map/filter/fold 汎用化**。`trait Iterator[T] { next(Self) -> Option[T] }` + `trait Iterable[T] { iter(Self) -> Iterator[T] }`。Phase 1: Iterable トレイト + Array impl + index ベースの eager 結合子 (`vibe/prelude/iterator.vibe`: `Iterator::map/filter/fold/find/any/all/flatmap`、`C: Iterable` で任意コレクションに適用) は実装済み。lazy variant (`vibe/prelude/lazy_iter.vibe`: `() -> Option[T]` を iterator として `lazy_iter_arr/map/filter/fold/collect/count` を pipe-first で連結) も Phase 1 に追加。Phase 2: `for-in` を Iterable ベースにデシュガー統一は実装済み。checker (`src/checker/typecheck_expr.mbt`: String 以外のすべての iterable を `iter_require[C: Iterable]` / `iter_length` / `iter_get` 経路へ統一) と codegen (`src/codegen/wasm_codegen_builtin_collection.mbt`: `iter_length` / `iter_get` builtin を `Array::length` / `Array::get` と同等に拡張、`obj_array_view` も dispatch) を揃え、user 定義の `impl Iterable for T` + `T::iter_length` / `T::iter_get` で `for x in ...` が動く。Phase 3 を順次実装: (a) String — `impl Iterable for String` + `String::iter_length` (= `String::length`) + `String::iter_get` (= `String::char_code_at`、要素型 `Int` char code) を prelude に追加。(b) Map[K, V] — `impl [K, V] Iterable for Map[K, V]` + `Map::iter_length` (= `Map::size`) + `Map::iter_get(m, i)` で K (キー) を yield。compiled backends は `Map::iter_length` / `Map::iter_get` を map storage への直接アクセスへ lower し、generic `Iterator::fold(map, ...)` / `for k in map` が per-element `Map::keys` allocation で O(n²) 化しない。List は built-in 型なし — user 定義 enum + 自前 `impl Iterable` で既に動く。method-bearing trait と struct-field-closure codegen が揃ったタイミングで `next(Self)` 形式へ再 skin し、Phase 4 (旧 builtin deprecated) を進める。 | accepted |
| 0045 | **`derive(Eq)` の実装** (#148)。ユーザー定義 enum/struct で `derive(Eq)` 宣言時に `==` / `assert_eq` が自動有効化。実装: parser の `parse_derive_clause` + `queue_derive_impls` で `Stmt::TraitImpl` を生成、checker の `ObligationSolver` が impl を見つけて Eq 充足、codegen は構造比較を発行。`derive(Eq)` 忘れ時のエラーは ADR-0051 の `TraitWitness` を活用して `type mismatch (argument: no impl `Eq` for `Vec2`)` + `hint: annotate the type with `derive(Eq)` or add `impl Eq for <type>`` を出す。 | accepted |
| 0046 | **`Option[T]` sugar `T?`** (#149)。parser で `T?` → `Option[T]` に展開、`T??` / `T?[]` も chain 可。実装は `src/parser/parser_ast_patterns.mbt` (parse_type_post_suffixes)。 | accepted |
| 0047 | **`loop` 式 — `break(value)` で値返却** (#151)。checker (`typecheck_expr.mbt`: `env.loop_break_types` から最初の break 値の型を採用) と codegen (`wasm_codegen_expr_loop.mbt`: `block (result i64)` を発行し break が値を push) で実装済み。`loop (i = 0) { break 42 }` は `Int` を返す。 | accepted |
| 0048 | **`map` コンテキストキーワード化** (#152)。`map {` の場合のみキーワード、それ以外は識別子。`Array::map` が `r#` なしで使用可能に。 | accepted |
| 0052 | **struct field の `mut` 修飾子**。`struct S { mut field: T }` を許容。実装は `Array[T]` sugar ではなく **wasm-gc は `struct.set` / linear は (name_ptr, value) ペアの値スロット in-place 上書き** という backend native の direct mutation。Checker は非 mut field への `r.field = e` を error にする (`ADR-0052` ヒント付き)。content-address hash は `mut` flag を含めて区別する。`vibe x/zlib` の BitReader / BitWriter は実際に mut field に書き換え済み (zlib_test 9/9)。 | accepted |

## Effect System

| # | Decision | Status |
|---|----------|--------|
| 0003 | **エフェクトセット検証**。`with { Effect }` 宣言で追跡。`do` 境界検証は廃止 (v2)。エフェクト名の個別追跡は ADR-0021 で拡張予定。 | accepted |
| 0017 | **`let mut` は局所可変状態として許可**。`Ref[T]` は abandoned → ADR-0021 の Effect Handler で代替。 | superseded (→0021) |
| 0021 | **ミュータビリティを Effect Handler で表現**。`effect Mut<T> { push(); build() }` + `handle ... with Mut<T>`。Phase 1 (tail-resumptive Mut handler) は実装済み: parser の `effect`/`perform`/`handle ... with` 構文、checker の effect set 追跡 (`src/checker/typecheck_effects*.mbt`)、tail-resumptive inline pass (`src/frontend/rewrite_effect_handle.mbt`) でゼロコスト化。state は外側の `ArrayBuilder` / `let mut` を handler arms が close over する形で表現可能 (`examples/effect_mut_test.vibe`)。Phase 2 (Component Model `#import` 統合) と Phase 3 (WASI P3 HTTP capability effect, single-shot non-tail-resumptive handler の CPS lowering) は引き続き作業中。 | proposed |
| 0041 | **`_start` は `() -> Unit` 固定**。`with { Effects }` で capability 宣言。exit code は panic/Process::exit。REPL は例外。 | proposed |
| 0042 | **トップレベル未処理 effect 禁止**。ファイルモジュール top-level は pure (effect_scope_none)。shell/REPL/test は別スコープ。 | proposed |
| 0043 | **Capability-driven DCE + 定数分岐**。`--allow-*`/`--deny-*` で capability 指定 → 不要コード除去。`@build.*` 定数 + dead branch elimination。`--profile` プリセット (minimal/sandbox/server/edge/agent)。 | proposed |
| 0050 | **`handle` を汎用 effect handler に統一**。canonical syntax は `handle { expr } with EffectName { Op(...) => ...; }`。`Error` も built-in effect として一般化し、`throw(e)` は `perform Error::Throw(e)` の sugar (両形式が等価動作)。`resume` は one-shot / lexical-scope 限定、arm は exhaustive・top-to-bottom first-match、複数 effect は nested handle で表現する。実装: parser の `handle ... with` デシュガー (`src/parser/parser_ast_expr.mbt`)、checker の effect 検証 (`src/checker/typecheck_effects.mbt`, `typecheck_expr.mbt`)、codegen は CPS 変換相当。 | accepted |
| 0051 | **Trait 解決レイヤを 3 層化**。`TypeEnv` 連結リスト走査を (1) **TraitGraph** (`src/checker/trait_graph.mbt`: trait 定義 / supertrait 閉包 / `is_subtrait` のメモ化 / cycle 検出 / `register_def` / `import_def`)、(2) **ImplIndex** (`src/checker/impl_index.mbt`: `trait -> target` の索引 / `would_overlap` / `register_impl` / `import_impl`)、(3) **ObligationSolver** (`src/checker/obligation_solver.mbt`: `type_implements_trait` と bound 充足判定) へ分離。trait の storage は `TraitState` (`src/checker/trait_state.mbt`) に切り出し、`TypeEnv` は trait API についての互換アダプタへ縮小。`trait_is_subtrait` / `trait_bound_satisfied` / `type_implements_trait` は shim として残置。runtime の DB ローダ (`runtime/db_type_import.mbt`, `runtime/db_query.mbt`) も import-side の `ImplIndex::import_impl` / `TraitGraph::import_def` 経由に統一。 | accepted |

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
| 0054 | **SIMD-first baseline (linear backend)**。wasm SIMD 拡張を「常に有効」と仮定し、`FixedArray` / `Bytes` 系の hot path を v128 命令で高速化する方針。第一歩として `array_new` / `FixedArray::make` の cell fill を `i32x4.splat` + 16-byte `v128.store`（4 要素/反復）+ scalar tail へ置き換え (`src/codegen/wasm_codegen_builtin_collection.mbt::emit_simd_fill_i32`)。`Bytes` の bulk copy/fill は既に `memory.copy`/`memory.fill` で最適。SIMD を baseline 化したため内製 wasm eval interpreter (`src/tests/vibe_wasm_eval_test.mbt`) も v128 local + `i32x4.splat`/`v128.store`（splat-broadcast 限定）をサポートする。検証は wasmtime 実行 + interpreter の両経路、vector/tail 境界 (size 3/4/7/9) を pin。第二歩として文字列等価比較を v128 化: `==` は `impl Eq for String` 経由で `String::equals` builtin に lower されるため、実 codegen は `wasm_codegen_builtin_string.mbt::"String::equals"` の byte ループ（`compile_binary_cmp_op` の generic パスではない）。16-byte `v128.load`×2 + `i8x16.eq` + `i8x16.all_true` + scalar tail へ置換し、`bench/bench_string_eq.vibe`（畳み込み回避のため引数経由の `eq_count` で計測）で baseline 比 **3.3–5.9×**（1024B 等価 270→48µs=5.65×、末尾1byte差 282→48µs=5.9×、wasmtime JIT）。併せて既存 SIMD 比較 builtin の opcode バグを修正: `i8x16.eq`=0x23(35)/`le_u`=0x2A(42)/`ge_u`=0x2C(44)（従来 38/44/46 は別命令を指していた; 旧テストは compile 可否のみ検証で実行結果未検証のため露見せず）。interpreter は v128 を 16-byte pool 値として持つ方式へ拡張（`v128.load`/`i8x16.eq`/`i8x16.all_true`/`i8x16.splat`/`v128.any_true` 対応）。第三歩として `String::index_of` / `String::contains` の substring search を SIMD memchr 化: needle 先頭バイトを `i8x16.splat` し、16-byte window を `i8x16.eq` + `v128.any_true` で走査、候補バイトが無い window は16byte一気に skip、候補 window のみ scalar full-match で検証。`bench/bench_string_index_of.vibe` で baseline 比 **約5.1×**（1024B absent 17.7→3.2µs / late 18.6→3.5µs、wasmtime JIT）。正しさは wasmtime 経路（`tests/string_index_of_simd_test.vibe`）に加え、内製 interpreter の値レベルテスト（`src/tests/vibe_wasm_eval_test.mbt::"String::index_of values (found / not found)"`、16-byte SIMD window 経路を含む）で担保。当初 interpreter が index_of の not-found 時に 127 を返す不具合があり SIMD 起因と疑ったが、真因は SIMD 無関係の既存バグ — interpreter が `i32.const` 即値を**符号なし** LEB128 (`read_leb_u32`) で読んでおり、`result = -1`（バイト `0x7F`）が 127 にデコードされていた（found 時は `result` が `outer_i` で上書きされるためマスクされ、not-found のみ露見）。符号付き `read_leb_i32`（`read_leb_i64` 同様の符号拡張）を追加し `i32.const` の2デコード箇所を切替えて解消。第四歩として `String::starts_with` / `String::ends_with` を `String::equals` と同型の 16-byte chunk loop（`v128.load`×2 + `i8x16.eq` + `i8x16.all_true` + scalar tail）で SIMD 化。正しさは wasmtime で確認（境界長・先頭/末尾不一致・長さ違い）。ベンチ (`bench/bench_string_prefix.vibe`) は引数経由の recursion で 1008B-match を実計測: SIMD ~30µs。同一 codegen で SIMD chunk loop を強制 off（純 scalar byte loop、`prefix_len`/`suffix_len` & ~15 を 0 に差し替え）にした baseline と比較し starts_with **~10.6×**（316→30µs）/ ends_with **~10.9×**（318→29µs）。prefix/suffix 完全一致で共通領域を丸ごと chunk skip できるため equals(5.65×) より高倍率（lex 11.5× に近い）。計測時は build 切替えごとに bench cache (`bench/.vibe/bench`) を消す必要あり（cache key が codegen 差を区別せず stale wasm を返し倍率が二峰化する）。第五歩として文字列 lex 比較を SIMD 化: `<` / `>` / `<=` / `>=` は `emit_string_lex_cmp_to_bool` (`wasm_codegen_call.mbt`) の byte ループで lower され、`String::compare`（prelude が `a<b`/`a>b` を使用）もこれ経由。共通 prefix を 16-byte chunk（`v128.load`×2 + `i8x16.eq` + `i8x16.all_true`）で skip し、最初の不一致 chunk のみ scalar で差分バイトを特定。`bench/bench_string_compare.vibe`（引数経由の `lt_count`）で baseline 比 **11.5×**（1024B 末尾1byte差 407→35µs、wasmtime JIT; 共通 prefix を丸ごと飛ばせるため equals より高倍率）。併せて既存 lex 比較の length tie-break バグを修正: scalar ループが共通 prefix 一致時に `diff` を毎反復 0 で上書きし、長さ差を潰していた（`"ab" < "abc"` が誤って `false`）。`diff` は不一致バイト検出時のみ設定するよう変更。lex SIMD は equals 同型構造で内製 interpreter でも動作（全1371テスト pass）。正しさは `tests/string_lex_compare_simd_test.vibe`。第六歩として `string_compare` / `String::compare` を **1パス** の SIMD lex builtin 化: 第五歩の `emit_string_lex_cmp_to_bool` から共通 prefix scan + 差分バイト特定部を `emit_string_lex_diff` (`wasm_codegen_call.mbt`) として抽出し、bool 版（`<`/`<=`/`>`/`>=`）と signum 版で共有。`compile_builtin_string` に `"String::compare" | "string_compare"` ハンドラを追加（`String::equals` 同様 is_user_fn ガード無しで prelude 定義を傍受）し、`diff` の signum = `(diff>0)-(diff<0)` を tagged int (-1/0/1) で返す。従来 prelude の `if a<b{-1}else if a>b{1}else 0` は `a>=b` のとき共通 prefix を **2回** scan していた（`a<b` 失敗 → `a>b` で再 scan）。1パス化で `b>a` 方向 1024B 末尾1byte差 70.2→36.7µs=**1.91×**、equal 1024B 59.0→30.7µs=**1.92×**（`bench/bench_string_compare_signum.vibe`、wasmtime JIT; `a<b` 方向は短絡で元々1 scan のため同等）。js-string backend は linear layout が無いため prelude 実装へ fallback。`String::compare` は checker builtin ではなく prelude 内部関数のため外部ファイルからは未呼び出し（外部公開は selfhost parity 影響を避け別スコープ）。正しさは `vibe/prelude/cmp_test.vibe`（`cmp_string_compare` / `cmp_string_compare_simd_chunk`、>16B chunk-skip 経路含む）と内製 interpreter（locally-defined `string_compare` を傍受、`"String::compare signum"` テスト）で end-to-end 検証。参考: mizchi/simd（MoonBit wasm SIMD で memcpy/memset/sum 等が 5–90× 高速化）。 | accepted |

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
| 0050 | **selfhost bench は wasmtime AOT を host-side accelerator としてサポート**。`tools/moonrun_wasmtime` (binary `moonrun_wt`) で moonrun 互換 host を実装（spectest::print_char + `__moonbit_{fs,time,sys}_unstable::*` 全 32 imports を Rust+wasmtime+externref で再実装）、`scripts/bench_selfhost_perf.sh` に `VIBE_SELFHOST_PERF_RUNTIME=wasmtime\|wasmtime-aot` を追加。AOT は engine.precompile_module で `.cwasm` を吐き Cranelift cost を per-run から除去。debug-profile 5-case 平均で compile ratio 5.7→1.2 (~5×)（TODO #295）。`moonrun_wt` / daemon / `moonrun_wt_client` は CI・bench・IDE/LSP 向けの host-side accelerator に限定し、canonical selfhost compiler/checker artifact は引き続き WASI wasm 単体で実行可能でなければならない。Rust/wasmtime daemon を配布 selfhost CLI の必須実行経路にしない。CI は native-accelerated KPI と別に one-shot portable wasm path の correctness/parity gate を維持する。| accepted |
| 0052 | **persistent session worker は opt-in**。`vibe run/check/test` は既定で one-shot 経路を使う。`session-http` daemon は `VIBE_USE_SESSION_HTTP=1` で明示した場合だけ使う host-side accelerator とし、portable selfhost path や配布 CLI の必須経路にしない。 | accepted |
| 0053 | **background linked cache build は opt-in**。`vibe run` 成功後の `vibe build --debug` fire-and-forget 起動は `VIBE_LINKED_CACHE_BACKGROUND=1` で明示した場合だけ有効にする。既定経路は foreground の one-shot compile/run に留める。 | accepted |

## Deferred

| # | Decision | Status |
|---|----------|--------|
| 0012 | **Async/Await (Stack Switching + WASI P3)**。`{Async}` effect + Future[T] + Stream[T]。WASM Stack Switching 安定化待ち。P3 HTTP は ADR-0021 の同期 effect で対応可能。 | deferred |

---

*旧個別ファイルは `docs/archive/adr/` に移動。*
