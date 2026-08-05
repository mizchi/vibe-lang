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
bash scripts/vibe_md.sh check docs/tutorial/01_values_functions.vibe.md
bash scripts/vibe_md.sh check docs/tutorial/*.vibe.md   # 全章を一括検証
bash scripts/vibe_md.sh write docs/tutorial/*.vibe.md   # 実行して ```output を書き直す
pkf run vibe-md-tutorial                                # check を task 化したもの
```

| 章 | テーマ |
| --- | --- |
| [01 値と関数](01_values_functions.vibe.md) | let / mut / 基本型 / 文字列補間 / fn / ラムダ |
| [02 制御フロー](02_control_flow.vibe.md) | if / while / loop / for-in / return / パイプ |
| [03 データ](03_data.vibe.md) | tuple / array / record / struct / enum / パターンマッチ |
| [04 Option](04_option.vibe.md) | Option / `let*` / `?` |
| [05 エフェクト](05_effects.vibe.md) | `with ...` / Exception / handle / perform / resume |
| [06 テスト](06_tests.vibe.md) | test ブロック / assert / CLI ツーリング |
| [07 モジュールとパッケージ](07_modules_packages.vibe.md) | import / export / @scope パッケージ / 契約 / pin |

各 `*.vibe.md` の ` ```vibe run ` ブロックは、**現在の**ソースコードと出力だけを
`bash scripts/vibe_md.sh check` (`pkf run vibe-md-tutorial`) でコンパイル・実行して
突き合わせる。この検証は prose、API 選定、学習順序の正しさまでは保証しない。
` ```vibe skip ` ブロックは目標設計の非実行例であり、コンパイル済みとは主張しない。
目標の言語形式を示す skip block は
[#1279 Exception](https://github.com/mizchi/vibe-lang/issues/1279)、
[#1280 reserved fn](https://github.com/mizchi/vibe-lang/issues/1280) で追跡する
([#1281 top-level patterns](https://github.com/mizchi/vibe-lang/issues/1281) は
実装済みで、03 の該当ブロックは runnable になった)。

より網羅的なリファレンスは [docs/cheatsheet.md](../cheatsheet.md) と
[docs/language-tour/](../language-tour/)。ただし一部の記述は実装より
先行している (差分に気づいたら本チュートリアルの実行結果が正)。

## 曖昧な構文・既知の落とし穴

本チュートリアルを見直す過程で確認・整理したもの。それぞれ本文中に
runnable な例がある箇所は実行結果 (`vibe run`/`output`) 付きで検証済み:

- **`break(a, b)` は `continue(a, b)` と非対称**: `continue(a, b)` は
  ループの次状態 (call のような多引数構文) だが、`break(a, b)` の丸括弧は
  ただの式の括弧で、`break` に渡るのは**タプル 1 個** `(a, b)`。
  構文方針は [#1284](https://github.com/mizchi/vibe-lang/issues/1284) で追跡する。
  [02 制御フロー](02_control_flow.vibe.md#loop--パラメータ付き末尾再帰)。

以前ここに載っていた次の3件は、現在のコンパイラでは再現しないことを
runnable な例で確認したので落とした (#1270):

- トップレベル関数を `f` / `g` と名付けると壊れた wasm になる
  ([#1203](https://github.com/mizchi/vibe-lang/issues/1203)) — `compose`/`flip`
  と同居しても正しく動く。
- `Double` の `\{expr}` 補間 / `Double::to_string` が使えない
  ([#1153](https://github.com/mizchi/vibe-lang/issues/1153)) — どちらも出力
  できる。[01 値と関数](01_values_functions.vibe.md#値と基本型) で実行している。
- `Array::push` を生 `Array` に使うと backend 依存になる
  ([#1285](https://github.com/mizchi/vibe-lang/issues/1285)) — linear / RC /
  wasm-gc で同一の in-place 追加であることを compiler test に固定した。
  [03 データ](03_data.vibe.md#蓄積は-arraybuilder)。
