# basic/03_list_stats — 初期実装

`fn stats(xs: Array[Int]) -> (Int, Int, Int)` を実装する。戻り値は
`(min, max, sum)`。`xs` は非空であることを前提してよい (空配列の挙動は
未規定でよい)。

`test { ... }` で最低3ケース (通常の配列、単一要素、負数を含む配列) を
`assert` すること。
