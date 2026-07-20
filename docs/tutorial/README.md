# vibe チュートリアル — 実行して学ぶ言語ツアー

各章は **markdown の解説** と **同名の実行可能テストファイル** のペアになっている。
テストファイルの中身が章の例文そのもので、`vibe test` でその場で動かせる —
読んだらすぐ実行、が このチュートリアルの流儀。

```bash
# インストール (詳細: docs/install.md)
curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/scripts/installer.sh | bash
. "$HOME/.vibe/env"

# リポジトリを clone して章を実行
git clone https://github.com/mizchi/vibe-lang && cd vibe-lang
vibe test docs/tutorial/01_values_functions_test.vibe
vibe test docs/tutorial/          # 全章を一括実行
```

| 章 | テーマ | 実行 |
| --- | --- | --- |
| [01 値と関数](01_values_functions.md) | let / mut / 基本型 / 文字列補間 / fn / ラムダ | `vibe test docs/tutorial/01_values_functions_test.vibe` |
| [02 制御フロー](02_control_flow.md) | if / while / loop / for-in / return / パイプ | `vibe test docs/tutorial/02_control_flow_test.vibe` |
| [03 データ](03_data.md) | tuple / array / record / struct / enum / パターンマッチ | `vibe test docs/tutorial/03_data_test.vibe` |
| [04 Option と railway](04_option_result.md) | Option / `let*` / `?` | `vibe test docs/tutorial/04_option_result_test.vibe` |
| [05 エフェクト](05_effects.md) | `with { ... }` / throw / handle / perform / resume | `vibe test docs/tutorial/05_effects_test.vibe` |
| [06 テスト](06_tests.md) | test ブロック / assert / CLI ツーリング | `vibe test docs/tutorial/06_tests_test.vibe` |
| [07 モジュールとパッケージ](07_modules_packages.md) | import / export / @scope パッケージ / 契約 / pin | `vibe test docs/tutorial/07_modules_packages_test.vibe` |

各 `*_test.vibe` はコンパイラの unit バッテリー
(`scripts/unit_test_allowlist.txt`) に登録されていて、コンパイラが
変わるたびに CI がこのチュートリアルを実際にコンパイル・実行する —
つまりここの例文は**腐らない**。

より網羅的なリファレンスは [docs/cheatsheet.md](../cheatsheet.md) と
[docs/language-tour/](../language-tour/)。ただし一部の記述は実装より
先行している (差分に気づいたら本チュートリアルの実行結果が正)。
