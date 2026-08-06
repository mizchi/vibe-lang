# lang-review — 言語評価ループ

vibe を「プログラミング言語として」定点観測・改善するための評価ハーネス。
AI レビューエージェント (subagent) に文法・意味論・型システムの健全性を
レビューさせてスコアをつけ、所見を改善バックログ (GitHub issue) に落とし、
修正後に再評価する — このループを回して言語性能を上げる。

0.4.0 ロードマップ「専用のエージェントハーネス」(#806) の前身。
関連: ADR-0067 (バージョンロードマップ)、ADR-0068 (並行設計原則)。

## 構成

```
eval/lang-review/
  README.md      # 本ファイル (回し方)
  rubric.md      # 評価軸 (7 dimensions) + スコア定義 + レビュアープロンプト
  tasks/         # writability タスクセット (仕様。レビュアーがゼロから書く)
  golden/        # 各タスクの検証済み解答 + 期待出力 (ラウンドの副産物)
  run_golden.sh  # golden が現行コンパイラで compile+run+出力一致するか検証
  scores/        # ラウンドごとのスコア記録 (JSON)
  findings/      # ラウンドごとの所見 (改善バックログ候補、issue 化の元)
```

## 評価ループの回し方 (1 ラウンド)

1. **レビュアーを並列に走らせる** — `rubric.md` の各レビュアープロンプトを
   subagent に与える。レビュアーは担当 dimension について:
   - *writability レビュアー*: `tasks/` の仕様だけを見て (解答を見ずに)
     docs/cheatsheet.md を頼りに vibe コードを書き、下の検証コマンドで
     compile+run し、つまずき (friction) を全部記録する
    - *semantics / type-soundness レビュアー*: docs と実地プローブ
      (小プログラムを書いて動かす) で意味論の一貫性・型健全性の穴を探す
   - *concurrency レビュアー*: ADR-0012/0055/#488 と現行ランタイム設計を
     Go channel / Elixir 軽量プロセスモデルに照らして適合性を評価する
2. **スコア集計** — 各レビュアーの JSON を `scores/<date>-r<N>.json` に集約。
3. **所見の issue 化** — major finding を GitHub issue にする
   (既存 issue と重複しないこと)。`findings/<date>-r<N>.md` に全所見を残す。
4. **golden の更新** — writability レビュアーの解答を検証・修正して
   `golden/` に置く。`run_golden.sh` が green であることを確認して commit。
5. **改善 → 次ラウンド** — issue を消化したら同じ rubric で再評価し、
   スコアの推移を `scores/` で追う。**rubric と tasks はラウンド間で
   安定させる** (変えるとスコアが比較不能になる。追加は可、変更は不可)。

## 検証コマンド (レビュアー / run_golden.sh 共通)

コンテナに `vibe` launcher が無くても、gate が残した stage2 (または
committed seed) で compile+run できる:

```bash
cd <repo-root>
# stage2 (gate 実行後に存在すれば最新の言語) or seed (常に存在、少し古い)
S2=$(ls -td _build/selfhost/generations/*/ 2>/dev/null | head -1)stage2.wasm
[ -f "$S2" ] || S2=bootstrap/seed/compiler.wasm

# compile (entry が let main の場合は main、test ブロックだけなら __no_entry__)
VIBE_PREOPEN_DIR=$PWD VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$S2" path/to/prog.vibe path/to/prog.wasm main

# run
bash scripts/run_wasm_vibe_host_runner.sh --invoke _start path/to/prog.wasm
```

- compile 失敗時は `<out>.diag` サイドカーに診断が書かれる。
- **ソースは repo ツリー内に置く** (prelude 等の相対 import が repo 相対の
  ため)。probe は `_build/evalprobe*/` を使う (gitignored)。
- 型検査だけなら `vibe diagnostics` 相当は未配線のため、compile の
  成功/失敗 + `.diag` で代用する。

## スコア記録形式

`scores/<date>-r<N>.json`:

```json
{
  "round": 1,
  "date": "2026-07-12",
  "commit": "<HEAD sha>",
  "dimensions": {
    "syntax_clarity":        {"score": 3.0, "reviewer": "writability"},
    "writability":           {"score": 3.0, "reviewer": "writability"},
    "semantics_consistency": {"score": 3.0, "reviewer": "semantics"},
    "type_soundness":        {"score": 4.0, "reviewer": "type-soundness"},
    "effect_system":         {"score": 3.0, "reviewer": "type-soundness"},
    "diagnostics":           {"score": 3.0, "reviewer": "semantics"},
    "concurrency_readiness": {"score": 2.0, "reviewer": "concurrency"}
  },
  "notes": "1行サマリ"
}
```

スコアは 1–5 (定義は rubric.md)。ラウンド間で **同じ rubric・同じ tasks**
で比較する。

## 観測モードについて (r3 で追加)

r1/r2 は writability レビュアーが `tasks/` の仕様からゼロ書きして compile する
経路だけで測った。r3 で分かったのは、**この経路では原理的に見えない欠陥がある**
ということ:

1. **compile を通り抜ける欠陥** — `handle` の適格性制約 (#1511) は `vibe check`
   が通り codegen で落ちる。レビュアーが型検査で確認していたら「問題なし」と
   報告する
2. **既存コードの保守でしか出ない摩擦** — 綴りの移行への追随、API 変更への
   追随、docs と実装の乖離 (#1505, #1506)
3. **書けないもの** — capability を要求する test (#1508) は「タスクにしなかった
   から出なかった」だけだった

なので `reviewer` フィールドは writability / semantics / type-soundness /
concurrency に加えて **`maintenance-session`** を取る (r3 がこれ): 1 セッション
分の実在の保守作業中に踏んだ friction をそのまま所見にする形。rubric と tasks を
変えないので、スコアはラウンド間で比較可能なまま。

**所見を書くときは実測値を添える** — 「〜のはず」ではなく、現行 stage2 に何を
食わせて何が返ったか。r3 では最初に立てた仮説を2つ外してから境界を確定させた
(`handle` の適格性は「top-level か否か」でも「引数の中に nest しているか」でも
なく、両者の相互作用だった)。

## tasks に golden の無いものがある場合

`tasks/11_*`〜`13_*` は **現在の言語では解けない**ことが所見なので golden が
無い。`run_golden.sh` は `golden/*.vibe` だけを見るので gate は緑のまま。
解けるようになった時点で golden を作る。
