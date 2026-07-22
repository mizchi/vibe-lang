# intermediate/03_custom_effect_logger — 変更

ログにレベルを持たせたい。`Logger::Log(String)` の代わりに
`Logger::LogAt(Level, String)` を使うように変更する (`enum Level { Info;
Warn; Error }` を追加)。呼び出し側は `perform Logger::LogAt(Level::Warn,
"...")` のように呼ぶ。

さらに、`Info` を除外して `Warn`/`Error` のみを収集する
`run_logged_filtered` を追加する (シグネチャは `run_logged` に準じる)。
`run_logged` (フィルタ無し版) は全レベルを収集する既存の挙動を維持する
こと。

既存の test は `Log("...")` 呼び出しを `LogAt(Level::Info, "...")` に
書き換えて動作を維持する形に更新する。`run_logged_filtered` が `Info` を
除外することを確認する test を最低1つ追加すること。
