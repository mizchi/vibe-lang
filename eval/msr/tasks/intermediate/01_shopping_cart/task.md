# intermediate/01_shopping_cart — 初期実装

買い物カートを実装する。`struct Cart` は品目のリストを保持する
(品目は `(name: String, price: Double, qty: Int)` の tuple または struct、
どちらでもよい)。以下を実装:

- `Cart::new() -> Cart`
- `add_item(c: Cart, name: String, price: Double, qty: Int) -> Cart`
  (不変更新。同名品目が既にあっても単純に別エントリとして追加してよい)
- `total(c: Cart) -> Double` (全品目の `price * qty` の合計)

`test { ... }` で最低3ケース (空カート=0、単一品目、複数品目) を
`assert` すること (Double の比較には十分な許容誤差を使うか、割り切れる
値を選ぶこと)。
