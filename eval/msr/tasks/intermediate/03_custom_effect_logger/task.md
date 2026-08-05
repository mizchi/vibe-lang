# intermediate/03_custom_effect_logger — 初期実装

ログを蓄積する `Logger` effect を定義する: op `Log(String)`。handler は
`perform Logger::Log(...)` を Array に集めて、body の戻り値と集めた
ログの Array のペアを返す (resume で継続すること)。

`fn run_logged(body: () -> Int with Logger) -> (Int, Array[String])`
のような形で、body 内で `perform Logger::Log("a")` を複数回行い、
最終的な戻り値とログ配列を両方確認できるようにする。

`test { ... }` で、ログを2〜3件出す body を実行し、戻り値とログの件数・
内容の両方を `assert` すること。
