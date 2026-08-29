# Structured Shell Design: shellscript superset + nushell-style data pipelines

## ビジョン

vibe shell の posix mode は **shellscript のスーパーセット** として設計する。

1. **既存の shellscript がそのまま動く** — 認識できないコマンドは `sh_lines()` にフォールバック
2. **認識できるコマンドは構造化データで返す** — `ls` → `Array[FileEntry]`, `cat` → `String`
3. **vibe 式で拡張できる** — `|>`, `match`, `if`, `let`, lambda はそのまま使える

つまり: `bash の全コマンド + vibe の型付きパイプライン + nushell の構造化データ`

## 設計原則

### 1. shellscript 互換 (フォールバック)

```bash
# 全て動く — 認識できないコマンドは sh_lines() 経由で /bin/sh に委譲
git status
docker build -t myapp .
curl -s https://api.example.com
grep -r "TODO" src/
```

### 2. 認識コマンドは構造化データに昇格

```bash
# ls は Array[FileEntry] を返す (テーブル表示)
ls .

# cat は String を返す (そのまま表示)
cat README.md

# env は String を返す
env HOME
```

### 3. vibe 式でシームレスに拡張

```bash
# パイプで構造化フィルタ
ls . |> where_entry(e -> e.is_dir)

# let 束縛
let files = ls .
Array::length(files)

# if/match も混在可能
if exists "package.json" { cat package.json |> jq .name } else { "no package" }
```

### 4. 段階的に認識コマンドを増やす

将来的に `grep`, `find`, `sort`, `head`, `tail` 等も vibe 実装で置き換え可能。
ただし **常にフォールバックが動く** ので、未実装コマンドでもブロックされない。

## 現状

### 既存の基盤
- `vibe/shell/types.vibe`: `FileEntry { name, path, is_dir }`
- `vibe/shell/pipeline.vibe`: grep, cut, lines, split, jq, where_entry, filter_str 等
- `vibe/shell/commands.vibe`: ls → `Array[FileEntry]`, cat → `String`
- vibe の `|>` パイプ演算子: `expr |> f` = `f(expr)`
- posix preprocessor: `ls /tmp` → `Fs::readdir("/tmp")`

### ギャップ
- `|>` は compiled WASM で動くが、shell の posix preprocessor がパイプを解釈しない
- `where` は関数呼び出しだが、posix 風の `ls | where is_dir` 構文がない
- 表示 (table format) がない

## 設計

### Phase 1: パイプライン式の posix preprocessor 対応

```bash
# 現在の vibe 式 (動作する)
Fs::readdir(".") |> where_entry(e -> e.is_dir)

# 目標: posix 風の構文
ls . |> where is_dir
ls . |> where name == "src"
ls . |> sort_by name |> take 5
cat data.csv |> from_csv |> where age > 30
```

posix preprocessor が `ls . |> where is_dir` を以下に変換:
```vibe skip
// doctest-skip: design sketch: the syntax below is not implemented (preprocessor output sketch)
Fs::readdir(".") |> where_entry(e -> e.is_dir)
```

### Phase 2: テーブル表示

```
vibe> ls .
┌─────┬──────────┬───────┐
│ #   │ name     │ is_dir│
├─────┼──────────┼───────┤
│ 0   │ src      │ true  │
│ 1   │ vibe     │ true  │
│ 2   │ README.md│ false │
└─────┴──────────┴───────┘
```

`Array[FileEntry]` や `Array[Record]` を自動的にテーブル形式で表示。

### Phase 3: 構造化データ変換

```
# JSON → テーブル
cat package.json |> jq .dependencies |> from_json

# CSV → テーブル
cat data.csv |> from_csv

# YAML → テーブル
cat config.yaml |> from_yaml

# テーブル → JSON
ls . |> to_json

# テーブルの列選択
ls . |> select name, is_dir

# テーブルのソート
ls . |> sort_by name

# テーブルの集約
ls . |> group_by is_dir |> count
```

## パイプライン変換ルール

posix preprocessor の拡張:

| 入力 | 変換 |
|------|------|
| `ls .` | `Fs::readdir(".")` |
| `ls . \|> where is_dir` | `Fs::readdir(".") \|> where_entry(e -> e.is_dir)` |
| `ls . \|> where name == "src"` | `Fs::readdir(".") \|> where_entry(e -> e.name == "src")` |
| `ls . \|> sort_by name` | `Fs::readdir(".") \|> sort_entries_by(e -> e.name)` |
| `ls . \|> count` | `Array::length(Fs::readdir("."))` |
| `cat f.csv \|> from_csv` | `from_csv(Fs::read_file("f.csv"))` |
| `cat f.json \|> jq .name` | `jq(Fs::read_file("f.json"), ".name")` |

## ワークフロー: REPL → ファイル → リファクタ

vibe shell の典型的な開発ワークフロー:

### 1. REPL で探索的にコードを書く

```
vibe> import @vibe/builtin { trait Iterator }
vibe> let data = cat data.csv |> from_csv
vibe> let filtered = data |> where age > 30
vibe> let names = filtered |> select name
vibe> Array::length(names)
last: 5
vibe> let avg = Iterator::fold(filtered |> select age, 0, (acc, x) -> acc + x) / 5
last: 42
```

### 2. セッションを `.vibe` ファイルに吐き出す

```
vibe> :save analysis.vibe
saved: analysis.vibe (6 bindings)
```

`:save` コマンドが scratch_source の全バインディングを normalize してファイルに書き出す。

### 3. normalize でクリーンアップ

```bash
vibe normalize analysis.vibe
```

- import の整理・ソート
- 未使用バインディングの除去
- 関数定義の並び替え (トポロジカルソート)
- フォーマット統一

### 4. エディタでリファクタ

```bash
vim analysis.vibex   # or vscode with vibe extension
vibe check analysis.vibex
vibe run analysis.vibex
```

### 5. テストを追加して品質保証

```bash
# analysis.vibex の末尾にテストブロックを追加
vibe test analysis.vibe
```

### 設計上の要件

- **scratch_source はバインディングを蓄積**: `let x = ...` は後続行から参照可能
- **`:save` コマンド**: 現在の scratch_source を normalize してファイルに書き出す
- **`:load` コマンド**: ファイルを scratch_source に読み込んで REPL で継続
- **`:clear` コマンド**: scratch_source をリセット
- **normalize との統合**: `:save` は `vibe normalize` と同等の整形を適用

## フォールバック戦略

```
入力行
  │
  ├─ vibe keyword (let, if, match, ...) → vibe 式としてコンパイル
  ├─ 関数呼び出し f(...) → vibe 式としてコンパイル
  ├─ 認識コマンド (cat, ls, cd, ...) → vibe builtin 呼び出しに変換
  └─ 不明コマンド → sh_lines("...") でシステムシェルに委譲
```

これにより:
- `git push` → そのまま動く (sh_lines)
- `cat file.txt |> lines |> grep "TODO"` → 構造化パイプライン
- `let count = ls . |> where_entry(e -> e.is_dir) |> Array::length` → 型安全

## 実装計画

| Phase | 内容 | 依存 |
|-------|------|------|
| Phase 0 | `ls .` が動く (fs_host_imports) | #44 |
| Phase 1 | `ls . \|> where is_dir` パイプライン変換 | posix preprocessor 拡張 |
| Phase 2 | テーブル表示 (Array[FileEntry] の format) | Show trait / REPL display |
| Phase 3 | from_csv/from_yaml/to_json 変換 | 既存 vibe/shell/from_*.vibe |
| Phase 4 | grep/find/sort 等の vibe native 実装 | 段階的 |

## 既存ライブラリとの対応

| nushell | vibe/shell |
|---------|-----------|
| `ls` | `ls(dir)` → `Array[FileEntry]` |
| `where` | `where_entry(pred)` / `filter_str(pred)` |
| `sort-by` | (未実装) `sort_entries_by(key_fn)` |
| `select` | (未実装) `select_fields(fields)` |
| `get` | `jq(data, expr)` |
| `from csv` | `from_csv(text)` |
| `from yaml` | `from_yaml(text)` |
| `lines` | `lines(text)` |
| `count` | `Array::length(arr)` |
