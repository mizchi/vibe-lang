# vibe チュートリアル — 実行して学ぶ言語ツアー

English version: [README.md](README.md) (canonical)

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
| [01 値と関数](01_values_functions-ja.vibe.md) | let / mut / 基本型 / 文字列補間 / fn / ラムダ |
| [02 制御フロー](02_control_flow-ja.vibe.md) | if / while / loop / for-in / return / パイプ |
| [03 データ](03_data-ja.vibe.md) | tuple / array / record / struct / enum / パターンマッチ |
| [04 Option](04_option-ja.vibe.md) | Option / `let*` / `?` |
| [05 エフェクト](05_effects-ja.vibe.md) | `with ...` / Exception / handle / perform / resume |
| [06 テスト](06_tests-ja.vibe.md) | test ブロック / assert / CLI ツーリング |
| [07 モジュールとパッケージ](07_modules_packages-ja.vibe.md) | import / export / @scope パッケージ / 契約 / pin |

各 `*.vibe.md` の ` ```vibe run ` ブロックは、**現在の**ソースコードと出力だけを
`bash scripts/vibe_md.sh check` (`pkf run vibe-md-tutorial`) でコンパイル・実行して
突き合わせる。この検証は prose、API 選定、学習順序の正しさまでは保証しない。

## tutorial breakage の扱い

チュートリアルの runnable block が現行コンパイラで壊れた場合は、ユーザーが正規の
言語ツアーを実行できない **P1 (書けない / 落ちる)** として扱い、GitHub issue に
`tutorial-breakage` ラベルを付けて発見しやすくする。型検査を通り抜けて誤った値を
返す場合は、通常どおり **P0 (silent-wrong)** である。このラベルは優先度を上書き
せず、着手順は [issue triage](../issue-triage.md) の P0 / P1 と `blocker` から
機械的に決める。修正か仕様見直しかも同じ triage とリポジトリ方針の「文法で
詰まったとき」に従い、実装都合の制約を tutorial の暗記項目にしない。

現在の全章は required な `compiler-gate` CI job で、同じ checkout から生成した
stage2 を `VIBE_MD_STAGE2` に明示し、`scripts/vibe_md.sh check` を全章に対して
実行する。`pkf run release-check` も同じ保証を持つ
`vibe-md-tutorial-gated` に依存する。どちらも committed seed への silent fallback を
許さないため、古い compiler で偶然 green にはならない。

` ```vibe skip ` は、拒否される旧構文、未実装の目標構文、実在しない例示パスなど、
**意図的に実行できない例だけ**に使う。block の先頭コメントに skip の理由を書き、
未実装事項には追跡 issue を添える。実行できるようになったら `vibe run` と期待
`output` に変える。単にテストが壊れているコードを skip に移してはならない。
目標の言語形式を示す既存 skip block は
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
  [02 制御フロー](02_control_flow-ja.vibe.md#loop--パラメータ付き末尾再帰)。

以前ここに載っていた次の3件は、現在のコンパイラでは再現しないことを
runnable な例で確認したので落とした (#1270):

- トップレベル関数を `f` / `g` と名付けると壊れた wasm になる
  ([#1203](https://github.com/mizchi/vibe-lang/issues/1203)) — `compose`/`flip`
  と同居しても正しく動く。
- `Double` の `\{expr}` 補間 / `Double::to_string` が使えない
  ([#1153](https://github.com/mizchi/vibe-lang/issues/1153)) — どちらも出力
  できる。[01 値と関数](01_values_functions-ja.vibe.md#値と基本型) で実行している。
- `Array::push` を生 `Array` に使うと backend 依存になる
  ([#1285](https://github.com/mizchi/vibe-lang/issues/1285)) — linear / RC /
  wasm-gc で同一の in-place 追加であることを compiler test に固定した。
  [03 データ](03_data-ja.vibe.md#蓄積は-arraybuilder)。
