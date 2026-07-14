# Selfhost Cutover Fail Cases

`bench/cutover/fail_cases.txt` は、`scripts/test_cutover_compare.sh` が使う
expected-fail parity ケース定義です。

## File Format

TSV 4 列で定義します（コメント行 `#` と空行は無視）。

1. `path`
2. `expected_class`
3. `expected_fragment`
4. `allow_missing_source` (`0` or `1`)

例:

```tsv
fixtures/typecheck/import_malformed_separator.vibe	parse	UnexpectedToken	0
bench/cutover/cases/unknown_name.vibe	type	unknown name: foo	0
__cutover_missing_input__.vibe	io	No such file or directory	1
```

## Semantics

- `path`
  - `PROJECT_ROOT` からの相対パス。
  - `allow_missing_source=1` の場合は実ファイルがなくてもよい（synthetic ケース）。
- `expected_class`
  - 失敗分類。現在の分類は `parse`, `type`, `io`, `other`。
- `expected_fragment`
  - host/selfhost 両方の stdout/stderr に含まれるべき文字列断片。
  - 空文字を指定すると断片チェックを省略。
- `allow_missing_source`
  - `0`: ファイル必須
  - `1`: ファイル不存在を許可

## Guard Rails

- `VIBE_CUTOVER_REQUIRED_FAIL_CLASSES`（デフォルト `parse,type,io`）で、最低必要な
  fail class カバレッジを検証します。
- CI では `parse,type,io` を固定しています。

## Update Flow

1. `fail_cases.txt` を編集（必要なら `cases/` に fixture 追加）
2. `scripts/test_cutover_compare.sh` を実行
3. `scripts/test_cutover_gate.sh` を実行
4. 結果が green であることを確認してコミット
