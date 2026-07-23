# intermediate/02_expr_eval — 初期実装

単純な算術式の評価器を実装する。`enum Expr { Num(Int); Add(Expr, Expr);
Sub(Expr, Expr); Mul(Expr, Expr) }` を定義し、`fn eval(e: Expr) -> Int` を
`match` で実装する。

`test { ... }` で最低4ケース (単一の `Num`、`Add`、`Sub`、ネストした式
例: `Mul(Add(Num(1), Num(2)), Num(3))`) を `assert` すること。
