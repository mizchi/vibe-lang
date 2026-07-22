# タスクレベル定義

almide-dojo (basic/intermediate/advanced) を vibe の機能セットに合わせて
具体化したもの。**ラウンド間で不変に保つ** (追加は可、定義変更は不可)。

## basic

単一の言語機能・単一の関数/構造体スコープ。制御フロー・文字列・配列操作・
単純な struct のみ。`modification.md` は既存シグネチャを大きく変えない
拡張 (パラメータ追加、分岐追加) が中心。

## intermediate

複数機能の組み合わせ (enum + match + struct、または custom effect)。
`modification.md` は戻り値型の変更 (例: `Int` → `Result[Int, E]`) や
新しい variant の追加など、呼び出し側の追随を要する変更を含んでよい —
「後方互換に見えて実は破壊的な変更」への耐性を見るのが intermediate の
狙い。

## advanced

generics + trait 境界、または複数モジュール (import/export) にまたがる
設計。`modification.md` は新しい実装 (同じ trait/interface の別
バックエンド) の追加や、既存 API を維持したままの内部設計変更を含む —
「拡張に対して閉じていない設計になっていないか」を見る。

## 難易度校正のガイド (lang-review との対応)

`eval/lang-review/tasks/` の 01–10 は「ゼロから書く」難易度の校正済み
参照点。目安:

- basic ≈ lang-review 01 (fizzbuzz) 〜 03 (collections) 相当の複雑度
- intermediate ≈ lang-review 02 (enum_tree) 〜 05 (custom_effect) 相当
- advanced ≈ lang-review 06 (struct_trait) 〜 10 (package_import) 相当

ただし lang-review タスクをそのまま MSR タスクとして流用はしない — MSR は
「初期実装 + 変更」のペアが要るため、golden をそのまま持ち込むと
"golden を見て書く" 経路が生まれてしまう (lang-review の writability
レビュアーは golden を見ない運用と同じ理由)。
