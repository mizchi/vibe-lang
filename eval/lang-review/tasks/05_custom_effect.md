# 05 custom_effect — effect 定義・perform・resume

値を蓄積する `Logger` effect (op: `Log(String)`) を定義し、handler で
ログを Array に集めて、body 実行後に件数と内容を出力する。body 内では
`perform Logger::Log("a")` などを 3 回行い、resume で継続する。

期待出力例: `logs=3: a,b,c`
