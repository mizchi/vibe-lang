# 04 error_handling — throw/handle・Result・`?`

文字列を Int にパースする関数 (非数値なら失敗) を書き、`"42"` は成功値、
`"abc"` は捕捉したエラーメッセージを出力する。失敗の表現は throw/handle
または Result のリポジトリ規約に従う。`?` 演算子も 1 箇所使ってみる。

期待出力例: `parsed: 42` / `error: invalid int: abc` (文言は任意)
