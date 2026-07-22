# basic/02_counter — 初期実装

`Counter` struct を実装する: `value: Int` フィールド、`Counter::new() ->
Counter` (0 始まり)、`increment(c: Counter) -> Counter` (1 増やした新しい
`Counter` を返す。不変更新)、`decrement(c: Counter) -> Counter` (1 減らす)、
`reset(c: Counter) -> Counter` (0 に戻す)。

`test { ... }` で increment を3回・decrement を1回・reset の3ケース以上を
`assert` すること。
