# intermediate/01_shopping_cart — 変更

パーセント割引クーポンを追加する。`apply_coupon(c: Cart, percent_off: Int)
-> Cart` を追加し、カートに「適用中の割引率」を保持させる (`Cart` の
フィールド追加が必要になる — 既存の `Cart::new`/`add_item`/`total` の
シグネチャは変えずに、内部表現の変更だけで対応すること)。`total` は
割引適用後の金額を返すように変更する (`percent_off` が 0 なら従来と
同じ結果)。同一カートに複数回 `apply_coupon` を呼んだ場合は最後の
呼び出しが有効 (積み上げない)。

既存の test は `apply_coupon` を呼ばない限り結果が変わらないことを
確認する形で残す。クーポン適用ありのケースを最低2つ追加すること。
