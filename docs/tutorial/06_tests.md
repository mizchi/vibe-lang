# 06 — テストとツーリング

実行: `vibe test docs/tutorial/06_tests_test.vibe`

## test ブロック

テストはソースファイルに `test "名前" { ... }` を書くだけ。`*_test.vibe` に
まとめるのが規約。

```vibe
test "assert_eq for numbers, assert for booleans" {
  assert_eq(1 + 1, 2)
  assert(2 < 3)
}
```

文字列の比較は `assert(s == "expected")` の形を使う (String に対する
`assert_eq` は束縛経路によって偽陰性になる既知の問題がある)。

```bash
vibe test file_test.vibe     # 1 ファイル
vibe test docs/tutorial/     # ディレクトリ一括
```

## CLI ツーリング

```bash
vibe run app.vibe            # コンパイルして実行 (main の返り値を表示)
vibe check app.vibe          # 型検査のみ
vibe compile app.vibe -o app.wasm
vibe bench file.vibe         # bench {} ブロックを計測 (ns/op, ops/sec)

# エディタ級のクエリ (LSP と同じ AST 解析)
vibe symbols file.vibe               # 宣言アウトライン
vibe type-at file.vibe <line> <col>  # カーソル位置の型
vibe diagnostics file.vibe           # 全診断
vibe lsp                             # LSP サーバ (stdio)

# パッケージの内容 hash (require pin に使う)
vibe hash lib/@vibe/core
```

次章: [07 モジュールとパッケージ](07_modules_packages.md)
