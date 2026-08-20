# PL 研究サーベイと取り込み提案 (2026-07)

> 目的: 最近のプログラミング言語研究・類似傾向の言語から、vibe に取り込める
> ものを特定する。AI レビューエージェントによる web 調査 (2026-07-12 実施、
> 2024–2026 の一次資料優先)。関連: ADR-0109 (ロードマップ)、ADR-0068
> (並行設計原則)、`eval/lang-review/` (評価ループ)。

## 戦略サマリ

1. **WasmFX (stack-switching) はまだ来ないが、JSPI は blocker ではない** —
   WasmFX は stage 2。一方 JSPI は phase 4 で Chrome に出荷済み、Safari 27
   beta も対応を告知し、Firefox は meta bug で実装を追跡している。JSPI は
   Wasm stack の suspend/resume を解決するが、Worker/thread、task lifetime、
   cancel、message isolation は解決しない。したがって browser version matrix を
   0.4.0 の blocker にせず、公開並行モデルと host suspension lowering を分離する。
   replay handler 自体は Koka 式 evidence passing + yield bubbling で置換し、
   副作用の再実行と ~16K bound を解消する。
2. その際 **IR に suspend 点を明示**しておけば、lowering を (a) 今日:
   evidence passing、(b) I/O: WASI 0.3 native async + JSPI、(c) 将来:
   WasmFX、に差し替えられる。ADR-0012 (async) と ADR-0068 (並行) は同じ
   IR に載せるべき。
3. vibe が既に持つもの (Perceus、content-addressed module、純粋テスト
   キャッシュ、capability effect、where 契約 Phase 1) は世界的にも先行。
   差分価値が最大なのは **FBIP 系の未取り込み後半 (drop-guided reuse /
   TRMC)** と **Effekt の 2025 年成果 (one-shot 定数時間 resume /
   dynamic-wind)**。ただし Perceus 実装の**成熟度**では Rust 製の類似言語
   almide (LLM 向け関数型言語、wasm+native dual target) が一歩先を行く
   — alias 解析による rc チェック除去や翻訳検証・形式証明まで踏み込んで
   おり (下記サーベイ表)、vibe の RC drop codegen 着地後の次の一手の
   参考になる。
4. 並行モデルは **nursery = Spawn capability handler**、typed channel、
   task-local heap/evidence を核にする。message は deep-copy snapshot を基準とし、
   Perceus の uniqueness は last-use と transitive arena ownership を証明できる場合の
   move 最適化にだけ使う。Go channel の失敗学 (close 責務不明・goroutine leak) は
   last-sender release + generative scope で構造的に回避する。Verona BoC の cown は
   core 完成後の拡張候補とする。

## サーベイ (主要トピック)

| トピック | 出典 | vibe への含意 |
| --- | --- | --- |
| WasmFX / stack-switching | wasmfx.dev、OOPSLA 2023 | stage 2、Wasmtime のみ。将来の lowering 先。IR 設計で見据える |
| Koka generalized evidence passing | Xie & Leijen, ICFP 2021 | replay 置換の本命。tail-resumptive perform = 直接呼び出し、非 tail は yield bubbling。GC/エンジン拡張不要 |
| Effekt capability passing / region | OOPSLA 2023/2025, ICFP 2025 | vibe の capability effect と同型。one-shot resume の定数時間 capture、dynamic-wind (finalizer) |
| wasm_of_ocaml の effect 実装 | Tarides 2025-02 | 選択的 CPS / JSPI / double translation の 3 モード。pure-by-default の vibe は CPS 対象最小化で有利 |
| JSPI 標準化完了 | WebAssembly proposals, WebKit, Mozilla Bugzilla | phase 4。Chrome 出荷済み、Safari 27 beta 対応、Firefox 実装追跡中。host suspend の手段であり thread model ではない |
| WASI 0.3 native async | Bytecode Alliance 2026-02 | async func / stream / future が canonical ABI 化。ADR-0012 の対象そのもの |
| structured concurrency 主流化 | Trio/JEP 505/asyncio.TaskGroup | nursery を Spawn capability handler として表現すると vibe の transitive 強制と噛み合う |
| OCaml 5 Eio / Picos | ocaml-multicore | scheduler を effect handler で書く見本。capability 注入は _start capability と同発想 |
| Verona BoC (when/cown) | OOPSLA 2023 | actor の弱点 (複数リソース atomic 更新) を region 所有権で解決。ADR-0060/0068 に接続 |
| Go channel 批判 | jtolio ほか | close 責務・方向・leak を型とスコープで表現せよという教訓 |
| BEAM per-process heap | BEAM Book | GC 局所化 + fault isolation。vibe は deep-copy を基準にし、last-use + transitive arena closure を証明できるときだけ move へ最適化する |
| MoonBit / Roc / Grain 動向 | moonbitlang.com ほか | MoonBit: wasm-gc 主軸 + component model + async 静的追跡。直接競合の座標 |
| Flux (Liquid Types for Rust) | PLDI 2023, 2025 | where 契約 Phase 3 (SMT) の実装様式。決定可能述語に制限した二層構成 |
| Modal Effect Types | Tang et al., OOPSLA 2025 | row 多相の注釈爆発を避ける形式化の参照点 (0.4.0 型システム形式化) |
| Flix associated effects / purity reflection | TOPLAS 2024 | trait メソッドの effect 多相への解答。pure なら自動並列化 |
| LLM 時代の言語設計 (Pel) | arXiv 2505.13453 | 構造化診断 + 修復アクション + 正例コーパス同梱が low-resource 言語の生成品質を決める |
| Rust merged doctests / Unison | Rust 2024 edition | doctest は最初から統合コンパイル + content-addressed キャッシュで |
| Koka FP² / TRMC | ICFP 2023, POPL 2023 | Perceus の先: drop-guided reuse、fip/fbip 保証、cons 再帰のループ化 |
| Ante (ownership × effects) | antelang.org 2025-05 | 継続が捕捉した線形資源の所有権問題 — 継続導入時に踏む課題の整理 |
| almide (LLM 向け関数型言語、Rust 実装) | github.com/almide/almide crates/ 2026-07 | Perceus 実装の一般化で先行: `almide-mir/src/alias_safety.rs` が関数ローカル fixpoint dataflow で証明可能 unaliased な値への `MakeUnique` (rc>1 COW チェック) を除去する最適化パスを持つ。vibe は dup/drop 挿入止まり (rc-port.md) でこの段階に未到達。さらに `translation_validation.rs` / `certificate.rs` + 別ワークスペース `almide-perceus-belt` (RC 規律の Lean 形式証明) で正しさを担保しており、vibe の unit test (`perceus_rc_test.vibe` 14 件) より検証が重い |
| almide ベンチマーク手法 | github.com/almide/almide docs/BENCHMARKS.md | Hello World / FizzBuzz / 再帰 Fibonacci / Closure+call_indirect / Variant(match+float) の5本を「as shipped」と `wasm-opt -Oz` 後の両方でサイズ計測し継続運用。vibe は ADR-0038 に一回限りの5ベンチ表 (int_literal 等) はあるが継続計測ドキュメントがない。almide の5本は closure+indirect call・pattern match+float という vibe が手薄なコード生成経路を突いており、バイナリサイズ回帰ベンチとして流用価値が高い。加えて `almide-dojo` の Modification Survival Rate (AI 改変後もコンパイル・テストが通り続ける率) は vibe の「エージェント向け構造化診断」施策 (下記 High priority #4) の効果測定指標として転用できる。**Status (2026-07-22): 両方とも導入済み** — バイナリサイズは #1056 (`docs/BENCHMARKS.md`)、MSR + 同一モデル多言語比較 (almide "minigit" 相当) は `eval/msr/` / `eval/lang-bench/` (ハーネスのみ、初回ラウンド未実施) |

## 取り込み提案 (優先順)

### High priority

1. **evidence-passing handler backend (replay 置換)** — cost: large →
   issue #817。**設計確定 (2026-07-22, ADR-0076)**: effect row を
   evidence vector に落とし、tail-resumptive perform を直接呼び出しへ。
   非 tail は yield bubbling。suspend 点を IR で明示し WasmFX / WASI 0.3
   async へ前方互換 (ADR-0012/0068 と同一 IR)。詳細は
   [effect-evidence-passing.md](effect-evidence-passing.md)、実装は
   5 段階のロールアウト計画に沿って別途着手する。
2. **nursery = Spawn capability handler** — cost: medium → issue #818。
   0.4.0 の軽量プロセスを structured concurrency (スコープ終了時
   join/cancel、Spawn が effect row に現れる) で導入。channel 生存も
   スコープ束縛し leak を型で防ぐ。
3. **merged doctest + 内容アドレスキャッシュ** — cost: small → issue #819。
   0.3.0 doctest (#805) の実装様式: 全 doc 例を 1 wasm に統合コンパイル、
   pure doctest は既存キャッシュ機構で再実行回避。
4. **エージェント向け構造化診断 + 修復アクション** — cost: small →
   issue #820。診断を機械可読 JSON + 適用可能アクションに昇格。正例
   コーパス (cheatsheet 抽出) を AI ハーネス用に CLI 配布。#806 の
   エージェントハーネス直結。

### Medium priority

5. **task-local heap + deep-copy send** (BEAM の isolation + structured
   concurrency) — ADR-0068 の基準実装。所有権移転は root RC だけで判断せず、
   last-use + transitive arena closure を証明できた後の最適化にする。
6. **dynamic-wind (finalizer) セマンティクス** (Effekt OOPSLA 2025) —
   resource effect × 非局所脱出の資源解放規則。継続/cancel 導入の前提。
7. **drop-guided reuse + TRMC** (Koka FP²) — Perceus backend の次の一手。
   コンパイラ自身のビルドが最大の受益者 (AST 再構築ホットパス)。
8. **wasm バイナリサイズ回帰ベンチ** (almide `docs/BENCHMARKS.md` 方式) —
   cost: small。Hello World / FizzBuzz / 再帰 Fibonacci / Closure+call_indirect
   / Variant(match+float) の5本を `wasm-opt -Oz` 前後で継続計測する
   `docs/BENCHMARKS.md` を新設。ADR-0038 の一回限り計測を定常運用に格上げし、
   closure・pattern match 系の回帰を捕捉する。
9. **rc チェック除去の fixpoint 最適化** (almide `alias_safety.rs` 方式) —
   cost: medium、RC drop codegen 着地が前提 (着地済み)。
   関数ローカルな dataflow で証明可能 unaliased な値への rc>1 (MakeUnique
   相当) チェックを除去し、ホットループの不要な refcount 分岐を削る。
   **Status (#1056, 2026-07-22): 狭い occurrence-local な一部分を実装済み**
   — 未使用エイリアス (`let a = t` で `a` が一度も参照されない) の
   dup+drop 相殺ペアを除去する (`perceus.vibe` の `ELet` 処理、
   `rc-port.md` の rc-check elision 節)。vibe の RC には almide の `MakeUnique`
   相当 (COW ガード) がまだ存在しないため、フルの fixpoint 版は
   別途の下部構造が要る。5 本ベンチ・コンパイラ自身のソースいずれにも
   対象パターンが現れず実測インパクトは今のところ 0 (`docs/BENCHMARKS.md`)。

### Low priority

10. **Flux 流 refinement (where 契約 Phase 3)** — 決定可能述語に制限した
    二層 SMT。GA ブロッカーではない。vibe は述語純粋性を effect row で
    機械判定できるため導入条件は既に揃っている。

## 参照

- 発端: ロードマップ 0.3.0/0.4.0 (当時の版数。ADR-0109 で 0.1.0/0.2.0 に renumber、#805/#806)
- 並行設計原則: [ADR-0068 詳細仕様](concurrency.md)
- lang-review round 1 の concurrency 所見 (#806 コメント) と整合
- [WebAssembly proposal registry](https://github.com/WebAssembly/proposals)
- [WebKit: JSPI in Safari 27 beta](https://webkit.org/blog/17967/news-from-wwdc26-webkit-in-safari-27-beta/)
- [Mozilla JSPI tracking bug](https://bugzilla.mozilla.org/show_bug.cgi?id=1897981)
- almide crates (Perceus RC 一般化・ベンチマーク手法の参照点、2026-07-22 調査):
  [crates/almide-mir](https://github.com/almide/almide/tree/develop/crates/almide-mir)、
  [docs/BENCHMARKS.md](https://github.com/almide/almide/blob/develop/docs/BENCHMARKS.md)
