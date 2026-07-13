# PL 研究サーベイと取り込み提案 (2026-07)

> 目的: 最近のプログラミング言語研究・類似傾向の言語から、vibe に取り込める
> ものを特定する。AI レビューエージェントによる web 調査 (2026-07-12 実施、
> 2024–2026 の一次資料優先)。関連: ADR-0067 (ロードマップ)、ADR-0068
> (並行設計原則)、`eval/lang-review/` (評価ループ)。

## 戦略サマリ

1. **WasmFX (stack-switching) はまだ来ない** — stage 2、実装は Wasmtime
   のみで V8/node には当分入らない。今日エンジンで使えるのは JSPI
   (phase 4、Chrome 137+) だけ。よって **replay handler の置換は Koka 式
   evidence passing + yield bubbling が唯一の現実解**。vibe の静的 effect
   row と相性が良く、replay の意味論的問題 (副作用の再実行、~16K bound)
   も同時に解決する。
2. その際 **IR に suspend 点を明示**しておけば、lowering を (a) 今日:
   evidence passing、(b) I/O: WASI 0.3 native async + JSPI、(c) 将来:
   WasmFX、に差し替えられる。ADR-0012 (async) と ADR-0068 (並行) は同じ
   IR に載せるべき。
3. vibe が既に持つもの (Perceus、content-addressed module、純粋テスト
   キャッシュ、capability effect、where 契約 Phase 1) は世界的にも先行。
   差分価値が最大なのは **FBIP 系の未取り込み後半 (drop-guided reuse /
   TRMC)** と **Effekt の 2025 年成果 (one-shot 定数時間 resume /
   dynamic-wind)**。
4. 並行モデルは ADR-0068 が proposed の今が設計制約の書き込み時:
   **nursery = Spawn capability handler** (structured concurrency)、
   **per-process heap + Perceus uniqueness による move send**、Verona BoC
   の **cown 的な複数リソース atomic 確保** の 3 点。Go channel の失敗学
   (close 責務不明・goroutine leak) は capability + スコープ束縛で構造的に
   回避できる。

## サーベイ (主要トピック)

| トピック | 出典 | vibe への含意 |
| --- | --- | --- |
| WasmFX / stack-switching | wasmfx.dev、OOPSLA 2023 | stage 2、Wasmtime のみ。将来の lowering 先。IR 設計で見据える |
| Koka generalized evidence passing | Xie & Leijen, ICFP 2021 | replay 置換の本命。tail-resumptive perform = 直接呼び出し、非 tail は yield bubbling。GC/エンジン拡張不要 |
| Effekt capability passing / region | OOPSLA 2023/2025, ICFP 2025 | vibe の capability effect と同型。one-shot resume の定数時間 capture、dynamic-wind (finalizer) |
| wasm_of_ocaml の effect 実装 | Tarides 2025-02 | 選択的 CPS / JSPI / double translation の 3 モード。pure-by-default の vibe は CPS 対象最小化で有利 |
| JSPI 標準化完了 | v8.dev, caniuse | Chrome 137+/Firefox 139+。node 上の async effect suspend の今日の手段 |
| WASI 0.3 native async | Bytecode Alliance 2026-02 | async func / stream / future が canonical ABI 化。ADR-0012 の対象そのもの |
| structured concurrency 主流化 | Trio/JEP 505/asyncio.TaskGroup | nursery を Spawn capability handler として表現すると vibe の transitive 強制と噛み合う |
| OCaml 5 Eio / Picos | ocaml-multicore | scheduler を effect handler で書く見本。capability 注入は _start capability と同発想 |
| Verona BoC (when/cown) | OOPSLA 2023 | actor の弱点 (複数リソース atomic 更新) を region 所有権で解決。ADR-0060/0068 に接続 |
| Go channel 批判 | jtolio ほか | close 責務・方向・leak を型とスコープで表現せよという教訓 |
| BEAM per-process heap | BEAM Book | GC 局所化 + fault isolation。Perceus の uniqueness で「refcount==1 は move send」にでき BEAM より有利 |
| MoonBit / Roc / Grain 動向 | moonbitlang.com ほか | MoonBit: wasm-gc 主軸 + component model + async 静的追跡。直接競合の座標 |
| Flux (Liquid Types for Rust) | PLDI 2023, 2025 | where 契約 Phase 3 (SMT) の実装様式。決定可能述語に制限した二層構成 |
| Modal Effect Types | Tang et al., OOPSLA 2025 | row 多相の注釈爆発を避ける形式化の参照点 (0.4.0 型システム形式化) |
| Flix associated effects / purity reflection | TOPLAS 2024 | trait メソッドの effect 多相への解答。pure なら自動並列化 |
| LLM 時代の言語設計 (Pel) | arXiv 2505.13453 | 構造化診断 + 修復アクション + 正例コーパス同梱が low-resource 言語の生成品質を決める |
| Rust merged doctests / Unison | Rust 2024 edition | doctest は最初から統合コンパイル + content-addressed キャッシュで |
| Koka FP² / TRMC | ICFP 2023, POPL 2023 | Perceus の先: drop-guided reuse、fip/fbip 保証、cons 再帰のループ化 |
| Ante (ownership × effects) | antelang.org 2025-05 | 継続が捕捉した線形資源の所有権問題 — 継続導入時に踏む課題の整理 |

## 取り込み提案 (優先順)

### High priority

1. **evidence-passing handler backend (replay 置換)** — cost: large →
   issue #817。effect row を evidence vector に落とし、tail-resumptive
   perform を直接呼び出しへ。非 tail は yield bubbling。suspend 点を IR
   で明示し WasmFX / WASI 0.3 async へ前方互換 (ADR-0012/0068 と同一 IR)。
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

5. **per-process heap + 所有権移転 send** (BEAM + Perceus uniqueness +
   BoC) — ADR-0068 制約 (1)(2) の実装方針。0.4.0 で。方向の ADR 固定は今。
6. **dynamic-wind (finalizer) セマンティクス** (Effekt OOPSLA 2025) —
   resource effect × 非局所脱出の資源解放規則。継続/cancel 導入の前提。
7. **drop-guided reuse + TRMC** (Koka FP²) — Perceus backend の次の一手。
   selfhost ビルド自体が最大の受益者 (AST 再構築ホットパス)。

### Low priority

8. **Flux 流 refinement (where 契約 Phase 3)** — 決定可能述語に制限した
   二層 SMT。GA ブロッカーではない。vibe は述語純粋性を effect row で
   機械判定できるため導入条件は既に揃っている。

## 参照

- 発端: ロードマップ 0.3.0/0.4.0 (ADR-0067、#805/#806)
- 並行設計原則: ADR-0068
- lang-review round 1 の concurrency 所見 (#806 コメント) と整合
