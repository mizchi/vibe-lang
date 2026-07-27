# vibe チュートリアル — 実行して学ぶ言語ツアー

各章は `*.vibe.md` — markdown そのものが実行可能ドキュメント (#1142)。
` ```vibe run ` ブロックは実際にコンパイル・実行され、直後の
` ```output ` ブロックはその実行結果がそのまま埋め込まれている。
読んだらすぐ実行結果が見える、が このチュートリアルの流儀。

```bash
# インストール (詳細: docs/install.md)
curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/scripts/installer.sh | bash
. "$HOME/.vibe/env"

# リポジトリを clone して検証・再生成
git clone https://github.com/mizchi/vibe-lang && cd vibe-lang
python3 scripts/vibe_md.py check docs/tutorial/01_values_functions.vibe.md
python3 scripts/vibe_md.py check docs/tutorial/*.vibe.md   # 全章を一括検証
python3 scripts/vibe_md.py write docs/tutorial/*.vibe.md   # 実行して ```output を書き直す
pkf run vibe-md-tutorial                                   # check を task 化したもの
```

| 章 | テーマ |
| --- | --- |
| [01 値と関数](01_values_functions.vibe.md) | let / mut / 基本型 / 文字列補間 / fn / ラムダ |
| [02 制御フロー](02_control_flow.vibe.md) | if / while / loop / for-in / return / パイプ |
| [03 データ](03_data.vibe.md) | tuple / array / record / struct / enum / パターンマッチ |
| [04 Option と railway](04_option_result.vibe.md) | Option / `let*` / `?` |
| [05 エフェクト](05_effects.vibe.md) | `with { ... }` / throw / handle / perform / resume |
| [06 テスト](06_tests.vibe.md) | test ブロック / assert / CLI ツーリング |
| [07 モジュールとパッケージ](07_modules_packages.vibe.md) | import / export / @scope パッケージ / 契約 / pin |

各 `*.vibe.md` の ` ```vibe run ` ブロックはコンパイラが変わるたびに
`python3 scripts/vibe_md.py check` (`pkf run vibe-md-tutorial`) で実際に
コンパイル・実行され、埋め込み済みの ` ```output ` と突き合わせられる —
つまりここの例文と実行結果は**腐らない** (ズレたら FAIL する)。

より網羅的なリファレンスは [docs/cheatsheet.md](../cheatsheet.md) と
[docs/language-tour/](../language-tour/)。ただし一部の記述は実装より
先行している (差分に気づいたら本チュートリアルの実行結果が正)。
