# advanced/01_generic_stack — 変更

`fn map[T, U](s: Stack[T], f: (T) -> U) -> Stack[U]` を追加する。
スタックの各要素に `f` を適用した新しい `Stack[U]` を返す (要素の順序は
保持すること — pop したときに元と対応する順で出てくること)。

既存の API (`new`/`push`/`pop`/`peek`/`is_empty`) のシグネチャは変えない。
`map` で型を変える (例: `Stack[Int]` → `Stack[String]`、`Int::to_string`
を使う) テストを最低2ケース追加すること。
