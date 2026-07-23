# basic/03_list_stats — 変更

平均値 (`Double`) も返すようにしたい。`stats` の戻り値を `(Int, Int, Int)`
(min, max, sum) から `(Int, Int, Int, Double)` (min, max, sum, average) に
変更する。**既存の全呼び出し箇所 (test 内含む) を新しいタプル形状に
追随させること** — これは意図的にシグネチャを破壊する変更で、呼び出し側の
追随漏れがないかを見る。

average の計算結果を検証する test ケースを最低2つ追加すること。
