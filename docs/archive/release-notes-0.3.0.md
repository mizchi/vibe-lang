# vibe 0.3.0 (GA) リリースノート — 未リリース

> **This release was never cut.** No `v0.3.0` tag exists, and the version was
> renumbered by ADR-0109: the first release usable by anyone but the author is
> `0.1.0`, and everything described below was 0.0.x development. The document is
> kept as the record of what landed between 2026-06 and 2026-07-17; the release
> that ships is [release-notes-0.1.0.md](../release-notes-0.1.0.md).
>
> 2026-07-17 確定。実装はすべて main にマージ済み (PR #927/#933/#935 ほか)。

0.2.0 (既知バグの消化サイクル、ADR-0066) から 0.3.0 (GA、ADR-0067 で
1.0→0.3 に renumber) までの変更点。

## ハイライト

- **Module System v2 完成**: 全パッケージが `.vpkg` 契約に移行し、`.vibei`
  はリポジトリから消滅。契約 = 外部公開面の唯一の定義であり、境界内
  ファイルへの直接 import はコンパイルエラー (ADR-0063/0070、#729 完了 /
  #897 stdlib 側完了)
- **パッケージレジストリ (最小スライス)**: file-based transparency log
  (RFC6962 形状の Merkle inclusion/consistency 証明)、yank (append-only
  marking)、`vibe pkg publish|install|add|yank|update` (#755/#805, PR #927)
- **コンパイル型 REPL `vibe shell`**: 宣言蓄積 + 再コンパイル方式
  (ADR-0034 のインタプリタなし方針を維持)、diagnostics での rollback、
  `:type`/`:load`/`:list` (#805, PR #927)
- **inline wasm**: `fn f(a: Int) -> Int = wasm "(...)"` — linear backend
  限定の WAT 関数 body 直接記述、SIMD (0xFD) 対応の専用アセンブラ内蔵、
  tagged-i64 ABI を明文化 (ADR-0072、#805, PR #933)
- **`fn main {}` エントリポイント特殊化 + トップレベル副作用の制限**
  (ADR-0069 Phase 1)
- **doctest 運用化**: cheatsheet / vibe.md / language-tour 全コードブロックが
  検証対象 (`pkf run doctest`)

## 言語

- 文法の冗長性削減: string interpolation を `\{expr}` に統一、
  型宣言 body のセパレータを `;` に統一
- トップレベル名前付き関数を `let` から `fn` へ全面移行 (ADR-0064、
  4,856 関数) + `where { requires, ensures }` 形式化宣言 (#731 Phase 1)
- generic struct 型パラメータ (#829) + struct literal の明示型引数
  `Pair[Int]::{ .. }` (#886)
- trait bound 付き契約宣言 (`fn get_by[K: Hash, V](...)` を `.vpkg` に
  記述可能; @vibe/core の generic-key API が初めて外部公開)
- effect 診断の精緻化: op シグネチャ検査 (#813)、import 越し row 強制
  (#812)、handler 網羅性 (#828)、row 伝播 soundness (#885)、
  expected/actual の set-diff + `with { ... }` fix-it ヒント (#639, PR #933)
- Error の algebraic effect 化 (#640 Stage 1〜4, PR #933/#935): `throw(x)` は
  parse 時に `perform Error::Throw(x)` へ脱糖され全パイプラインで単一内部形式
  (両綴りの wasm は byte-identical)、Error arm 内の `resume` はコンパイル
  エラー (非再開)、`EThrow` AST node は完全退役
- `Process::exit()` による実 exit code 伝播 (#903)

## 標準ライブラリ

- `@vibe/core` 拡充: BigInt / Rational 昇格、base64 / math / diff / uuid
  統合 (#766/#841)、`[K: Hash]` generic-key API の公開
- `@vibex` に collections / deque / pqueue / immut ほか追加
- `println` / `print` が import なしの単体ファイルでも全 backend で動作
  (#929, PR #933)。`Stdout::write_char` 等の raw-ABI 経路の int 引数
  タグ化バグを修正 (#930, PR #933)

## ツールチェーン

- WASI p3 動作保証 gate (wasmtime 45/46 matrix、ratified wasi:http 0.3.0
  cutover) (#821)
- `vibe normalize` サブコマンド (#882)、`vibe check --missing-vpkg` (#910)
- worktree 間で効くビルドキャッシュ (`VIBE_BUILD_CACHE_DIR`、#849)
- bootstrap seed bump (`vpkg-support-2026-07-16`、byte-identical
  自己再生 fixpoint 検証、#902)

## 既知の残項目 (GA 後継続)

- compiler 内部ディレクトリの `.vpkg` 化残り (cache/syntax/loader/codegen —
  #847 Phase B の codegen/entry facade 設計判断待ち、分析は #847 に記載)
- `Error` は checked semantic effect として ADR-0073 で固定。transitive row 強制は
  デフォルト on (#944 stage A-C)、row なし throw は `missing { Error }` 診断、
  entry boundary handler 実装済み。test 専用 legacy checker エントリ
  (`check_effects_expr` walk / `EEThrowOutsideEffect`) は退役。
  残: builtin-call carve-out sub-decision、`VIBE_CHECK_ERROR_ROW=0` の退役
- evidence-passing handler (#817、0.4 系)
- prelude の契約化 (設計判断待ち)
- unit_test_runner の http echo server ポート衝突 (#934 — ローカル並行
  実行のみ、CI 影響なし)

## リリース運用チェックリスト (owner)

- [ ] 0.3.0 GA tag
- [x] `vibe version` / 配布物の version bump (`VIBE_VERSION=0.3.0`)
- [x] 本ノートの [着地待ち] 解消 (2026-07-17)
- [x] release tag workflow の selfhost-only 化 (`build_release_assets.sh` が
  retired な `moon.mod`/`moon build` を参照していた問題を修正。tag push で
  selfhost seed / module source / manifest が publish される)
- [x] install スクリプト等配布チャネル確認 (release asset 生成 +
  `fetch_compiler.sh` 消費経路をローカル実測、install smoke は
  `cli-install` workflow が multi-OS で検証)
- [x] `docs/spec/1.0-freeze.md` の stable surface 定義を 0.3 に読み替え適用
  (冒頭に発効ノート追記 — v0.3.0 タグから freeze 発効、0.x 間は
  破壊的変更 = Minor で運用)
