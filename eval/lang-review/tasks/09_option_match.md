# 09 option_match — Option・match guard・let else 系

`Array[Int]` から「最初の 5 より大きい要素」を `Option[Int]` で返す関数を
書き、`[1,3,7,9]` → `found: 7`、`[1,2]` → `none` を出力する。match
(guard `if` 付き arm を 1 箇所) を使うこと。
