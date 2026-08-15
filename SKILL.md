---
name: vibe-scratch-workflow
description: `vibe new` から `vibe shell-stdin --restore` で scratch-db を積み上げ、`finalize`/`normalize`/`apply` まで安全に回すための実践手順。
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

2. scratch-db を固定する

```bash
export VIBE_SCRATCH_DB_PATH="$PWD/.vibe/namespaces/my_lib.db"
```

3. `shell-stdin --restore` で定義を積み上げる

```bash
printf '%s\n' \
  'export enum MyType { A; B }' \
  'export let f = (x: Int) -> Int { x + 1 }' \
  'exit' | vibe shell-stdin --no-prompt --restore
```

4. 追加の式や確認を同じ scratch-db で続ける

```bash
printf '%s\n' \
  'f(1)' \
  'exit' | vibe shell-stdin --no-prompt --restore
```

5. 仕上げ

```bash
vibe finalize --db "$VIBE_SCRATCH_DB_PATH" --library --export my_lib.vibe
vibe normalize --write my_lib.vibe
vibe check my_lib.vibe
vibe test my_lib.vibe
vibe fetch my_lib.vibe
vibe apply my_lib.vibe
```

## ベストプラクティス

- `shell-stdin` は `--restore` を付けないと空の scratch source から始まる。
- 長い式や複数行入力は heredoc / `printf '%s\n' ...` でまとめて `shell-stdin` に渡す。
  - 直接クオートを重ねるより parse 崩れを起こしにくい。
- scratch-db を明示的に分けたいときは `VIBE_SCRATCH_DB_PATH` を固定する。
- `finalize --library` は未使用定義と副作用文を落としてからエクスポートできるため、ライブラリ整形の基準にする。
- scratch の破棄は `vibe history reset`、または対象 DB ファイルの削除で行う。
- エクスポート後の確認は `vibe test my_lib.vibe` と `vibe symbols --json my_lib.vibe` を基準にする。

## Qualified Names（修飾名）

`@` で始まるパッケージ参照では `-`（ハイフン）と `/`（スラッシュ）が識別子の一部として扱われる。
`@` なしの場合、`-` は減算演算子、`/` は除算演算子になる。
詳細は `docs/cheatsheet.md` の "Qualified names" セクションを参照。

## 反復デバッグ

- 同じワークフローの連続実行:

```bash
pkf run debug-scratch-workflow
```

- 便利な環境変数:
  - `VIBE_SCRATCH_RUNS=50` 実行回数
  - `VIBE_SCRATCH_KEEP_SUCCESS=1` 成功ケースも保持
  - `VIBE_SCRATCH_CLI_BUILD=debug|release|skip` CLI ビルドモード

## scratch 反映後の検証

- exported module を lock/apply まで含めて確認する場合:

```bash
vibe finalize --db "$VIBE_SCRATCH_DB_PATH" --library --export my_lib.vibe
vibe fetch my_lib.vibe
vibe apply my_lib.vibe
vibe test my_lib.vibe
```

- scratch-db 自体は中間生成物なので、共有・レビュー対象は `finalize` 後の `.vibe` を優先する。
