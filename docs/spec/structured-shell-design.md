# Structured Shell Design: nushell-style data pipelines

## ビジョン

vibe shell は PowerShell/nushell のように**構造化データ**をパイプラインで変形する。
文字列ストリームではなく、vibe のファーストクラス値 (Array, Record, FileEntry 等) がパイプラインを流れる。

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
```vibe
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

## 実装計画

| Phase | 内容 | 依存 |
|-------|------|------|
| Phase 0 | `ls .` が動く (fs_host_imports) | #44 |
| Phase 1 | `ls . \|> where is_dir` パイプライン変換 | posix preprocessor 拡張 |
| Phase 2 | テーブル表示 (Array[FileEntry] の format) | Show trait / REPL display |
| Phase 3 | from_csv/from_yaml/to_json 変換 | 既存 vibe/shell/from_*.vibe |

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
