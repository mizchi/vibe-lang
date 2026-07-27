# 06 — テストとツーリング

前章: [05 エフェクト](05_effects.vibe.md)

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
vibe run app.vibex           # コンパイルして fn main を実行
vibe check app.vibe          # 型検査のみ
vibe compile app.vibex -o app.wasm
vibe bench file.vibe         # bench {} ブロックを計測 (ns/op, ops/sec)

# エディタ級のクエリ (LSP と同じ AST 解析)
vibe symbols file.vibe               # 宣言アウトライン
vibe type-at file.vibe <line> <col>  # カーソル位置の型
vibe diagnostics file.vibe           # 全診断
vibe lsp                             # LSP サーバ (stdio)

# パッケージの内容 hash (require pin に使う)
vibe hash lib/@vibe/core
```

## このチュートリアル自身も実行可能ドキュメント

この章まで含め `docs/tutorial/*.vibe.md` はすべて #1142 の `.vibe.md` 形式
— ` ```vibe run ` ブロックは実際にコンパイル・実行され、直後の
` ```output ` は本物の実行結果。手元で検証・再生成するには:

```bash
python3 scripts/vibe_md.py check docs/tutorial/*.vibe.md   # 検証 (embedded output が古ければ FAIL)
python3 scripts/vibe_md.py write docs/tutorial/*.vibe.md   # 実行して output を書き直す
pkf run vibe-md-tutorial                                   # check のタスク化
```

次章: [07 モジュールとパッケージ](07_modules_packages.vibe.md)
