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
| [04 Option と railway](04_option_result.vibe.md) | Option / `let*` / `?` |
| [05 エフェクト](05_effects.vibe.md) | `with { ... }` / throw / handle / perform / resume |
| [06 テスト](06_tests.vibe.md) | test ブロック / assert / CLI ツーリング |
| [07 モジュールとパッケージ](07_modules_packages.vibe.md) | import / export / @scope パッケージ / 契約 / pin |

各 `*.vibe.md` の ` ```vibe run ` ブロックはコンパイラが変わるたびに
`bash scripts/vibe_md.sh check` (`pkf run vibe-md-tutorial`) で実際に
コンパイル・実行され、埋め込み済みの ` ```output ` と突き合わせられる —
つまりここの例文と実行結果は**腐らない** (ズレたら FAIL する)。

より網羅的なリファレンスは [docs/cheatsheet.md](../cheatsheet.md) と
[docs/language-tour/](../language-tour/)。ただし一部の記述は実装より
先行している (差分に気づいたら本チュートリアルの実行結果が正)。

## 曖昧な構文・既知の落とし穴

本チュートリアルを見直す過程で確認・整理したもの。それぞれ本文中に
runnable な例がある箇所は実行結果 (`vibe run`/`output`) 付きで検証済み:

- **`break(a, b)` は `continue(a, b)` と非対称**: `continue(a, b)` は
  ループの次状態 (call のような多引数構文) だが、`break(a, b)` の丸括弧は
  ただの式の括弧で、`break` に渡るのは**タプル 1 個** `(a, b)`。
  [02 制御フロー](02_control_flow.vibe.md#loop--パラメータ付き末尾再帰)。
- **関数本体の途中に non-Unit な式を裸で置くと壊れた wasm を生成する
  既知バグ** ([#1203](https://github.com/mizchi/vibe-lang/issues/1203))。
  型検査 (`vibe check`) は通過し、`vibe run` で初めて失敗する。
  途中の式は `let _ = expr` で明示的に捨てること。
  [02 制御フロー](02_control_flow.vibe.md#while-と早期-return)。
- **`Double` の `\{expr}` 文字列補間 / `to_string` は checker/codegen の
  既知ギャップ** ([#1153](https://github.com/mizchi/vibe-lang/issues/1153))。
  `Double::to_int` で丸めるのが安全な代替。
  [01 値と関数](01_values_functions.vibe.md#値と基本型)。
- **無名 record のドットアクセス (`r.name`) は「どこかの struct が同名
  field を宣言しているとき」しか解決しない**。ad-hoc な record は分配束縛
  (`let record { name: n, ... } = ...`) を使う。
  [03 データ](03_data.vibe.md#tuple--array--record)。
- **`Array::push` を生 `Array` に使うのはアンチパターン** (backend 依存の
  未定義動作)。蓄積は必ず `ArrayBuilder` を使う。
  [03 データ](03_data.vibe.md#蓄積は-arraybuilder)。
- **`let*`/`?` は組み込みの `Option` はどこでも使えるが、`Result` は
  standalone ファイルでは文脈依存の制限がある** (コンビネータは workspace
  の prelude 提供)。[04 Option と railway](04_option_result.vibe.md#result-について)。
