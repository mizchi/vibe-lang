---
name: vibe-scratch-workflow
description: `vibe new` から `vibe eval` の積み上げでライブラリを実装し、`finalize`/`normalize`/`apply` まで安全に回すための実践手順。
---

# Vibe Scratch Workflow

## 使う場面

- 新しいライブラリを素早く試作したいとき
- `.vibe` の scratch namespace で段階的に設計を詰めたいとき
- `tmp/tmp-hash-*` 配下で何度も同じ検証を回したいとき

## 標準フロー

1. プロジェクト作成

```bash
vibe new tmp/tmp-hash-<id>/my_lib
cd tmp/tmp-hash-<id>/my_lib
```

2. `eval` で定義を積み上げる

```bash
vibe eval 'export enum MyType { A; B }'
vibe eval 'export let f = (x: Int) -> Int { x + 1 }'
```

3. 関数ごとの sidecar テストを追加し、その場で実行する

```bash
vibe eval --test-for f --run 'test "f/basic" { assert(f(1) == 2) }'
```

4. スコープ確認

```bash
vibe eval --inspect-scope
```

5. 仕上げ

```bash
vibe finalize --library --export my_lib.vibe
vibe normalize --write my_lib.vibe
vibe check my_lib.vibe
vibe fetch my_lib.vibe
vibe apply my_lib.vibe
```

## ベストプラクティス

- 長い式や `test` ブロックはシェルで heredoc 変数に入れてから `vibe eval` に渡す。
  - 直接クオートを重ねると `Parse(UnexpectedToken)` を起こしやすい。
- `--test-for <symbol>` を使うとテストは `.vibe/namespaces/<ns>.tests/` に保存され、本体 DB と `--export` 出力に混ざらない。
- `finalize --library` は未使用定義と副作用文を落としてからエクスポートできるため、ライブラリ整形の基準にする。
- `symbols --json <entry>` の見方:
  - scratch と index が同一定義（同一 module hash / signature）なら `shadowed` にならない。
  - 実際に scratch 側で上書きしたときだけ `shadowed` になる。

## 反復デバッグ

- 同じワークフローの連続実行:

```bash
just debug-scratch-workflow
```

- 便利な環境変数:
  - `VIBE_SCRATCH_RUNS=50` 実行回数
  - `VIBE_SCRATCH_KEEP_SUCCESS=1` 成功ケースも保持
  - `VIBE_SCRATCH_CLI_BUILD=debug|release|skip` CLI ビルドモード

## eval テストのカバレッジ

- `vibe eval --test-for <symbol>` で蓄積した sidecar テストは次で coverage 計測できる:

```bash
just coverage-eval-sidecar <db-path> <symbol>
```

- これは `<db>.tests/<symbol>_test.vibe` を一時エントリへ連結し、
  `compile --coverage --coverage-run-tests` + wasm counter 集計を実行する。
- 注意:
  - 対象コードが wasm backend で未対応機能（`Unsupported(...)`）を使う場合は計測できない。
  - その場合は通常の `vibe eval --test-for ... --run` で動作確認し、coverage は backend 対応後に再計測する。
