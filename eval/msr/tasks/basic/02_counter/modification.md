# basic/02_counter — 変更

`increment` にオプションのステップ数を持たせたい。`increment(c: Counter) ->
Counter` (デフォルト1) の**呼び出し互換を保ったまま**、`increment_by(c:
Counter, step: Int) -> Counter` を追加する形で実装せよ (`increment` は
`increment_by(c, 1)` に委譲してよい)。`step` は負数も許容する
(decrement 相当の効果になる)。

既存の test は変更しない (`increment` の挙動が変わってはいけない)。
`increment_by` 用に正のステップ・負のステップの2ケース以上を追加すること。
