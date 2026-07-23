# msr — Modification Survival Rate

almide (github.com/almide/almide) の評価指標のひとつを vibe に移植した評価
ループ。`docs/pl-survey-2026-07.md` の almide 調査、issue #1056 の Phase B/C
に続く取り込み。`eval/lang-review/` (rubric ベースの言語設計レビュー) とは
別軸: lang-review が「ゼロから書いたときの摩擦」を測るのに対し、MSR は
**「AI が書いたコードに、別の AI (または人) が後から変更を加えても、
コンパイル・テストが通り続けるか」** を測る — almide の定義そのまま
("how reliably code continues to compile and pass tests after AI-driven
changes")。

## なぜ別の指標が要るか

一発書き起こしの成功率 (lang-review の writability) が高くても、
「最初のコードが後続の変更に耐える構造になっているか」は別の性質。
LLM がコード生成を担う運用では、初回実装より**改修が発生する頻度の方が
圧倒的に高い** — MSR は言語・stdlib・診断が「安全に改修できる」設計に
なっているかを直接測る。structured diagnostics + repair action
(pl-survey 高優先度 #4/#820) の効果測定指標としても使える。

## 構成

```
eval/msr/
  README.md         # 本ファイル
  levels.md          # basic/intermediate/advanced の定義 (almide-dojo 相当)
  tasks/
    basic/<NN_name>/task.md          # 初期実装の仕様 (test blocks 込みで書かせる)
    basic/<NN_name>/modification.md  # 初期実装への追加変更の仕様
    intermediate/...
    advanced/...
  attempts/<round>/<task>/initial/entry.vibe    # ラウンドの成果物 (試行者が置く。
  attempts/<round>/<task>/initial/*.vibe        # gitignore 対象、golden 化した
  attempts/<round>/<task>/modified/entry.vibe   # ものだけ commit)
  attempts/<round>/<task>/modified/*.vibe
  run_msr.sh          # 生存判定スクリプト (下記)
  scores/<date>-r<N>.json   # ラウンドごとの MSR 集計
  findings/<date>-r<N>.md   # 生存に失敗したタスクの原因分析 (issue 化の元)
```

## 生存の定義

タスクごとに、成果物は `entry.vibe` を含むディレクトリ (単一ファイルの
タスクなら `entry.vibe` 1個だけ、複数ファイルにまたがるタスク
[advanced/02 など] なら `entry.vibe` + 相対 import する追加ファイル):

1. **initial** — `task.md` の仕様通りに実装し、`entry.vibe` (と必要なら
   追加ファイル) に `test { ... }` ブロックで仕様の受け入れ条件を
   `assert` として書く。`scripts/vibe_test.sh <dir>/entry.vibe` で
   compile して全 test が pass すれば "initial: PASS"。
2. **modified** — `modification.md` の変更を initial の実装に加える
   (既存の test ブロックは基本残す — 仕様が変更を要求する場合のみ
   書き換えてよいが、無関係な既存 test を削除して帳尻を合わせるのは
   反則)。同様に compile+test。

**MSR (ラウンド全体)** = (modified が PASS したタスク数) / (initial が
PASS したタスク数)。initial が落ちたタスクは分母に入れない
(almide の定義: 変更前提の話であり、初回実装の成否は別指標 lang-review
の writability が担当)。

## 実行

```bash
# 1タスク分の生存判定 (initial/, modified/ はそれぞれ entry.vibe を含むディレクトリ)
bash eval/msr/run_msr.sh <task> attempts/<round>/<task>/initial attempts/<round>/<task>/modified

# ラウンド全体 (attempts/<round>/ 以下を全タスク判定して集計)
bash eval/msr/run_msr.sh --round <round>
```

検証コンパイラは `eval/lang-review/README.md` と同じ規約 (stage2 が
あればそれ、無ければ committed seed)。

## ラウンドの回し方

1. **initial 生成** — 各タスクの `task.md` だけを見て (別タスクの解答は
   見ずに) LLM 1 セッションにつき 1 タスクを実装させる。
   `attempts/<round>/<task>/initial.vibe` に保存。
2. **modification 生成** — **initial を書いた文脈を保持したまま** (同一
   セッションの続き、または initial だけを渡した新規セッション — どちらで
   行ったか `findings/` に明記する)、`modification.md` の変更を加えさせる。
   `attempts/<round>/<task>/modified.vibe` に保存。
3. **判定** — `run_msr.sh --round <round>` で機械判定。
4. **記録** — `scores/<date>-r<N>.json` に MSR% とタスク別内訳、
   `findings/<date>-r<N>.md` に落ちたタスクの原因 (コンパイルエラーの
   種類、意味論の誤解、diagnostics が誤誘導したか等)。major finding は
   issue 化 (lang-review と同じ運用)。
5. 気に入った initial/modified ペアは `eval/lang-review/golden/` 同様の
   位置づけで `tasks/<level>/<name>/golden/` に固定してもよい (レベル
   キャリブレーションの参照点として)。**levels.md と tasks/ はラウンド間
   で安定させる** — 追加は可、既存タスクの仕様変更は不可 (lang-review と
   同じルール、スコアの比較可能性のため)。

## スコア記録形式

`scores/<date>-r<N>.json`:

```json
{
  "round": 1,
  "date": "2026-07-22",
  "commit": "<HEAD sha>",
  "session_continuity": "same-session | fresh-session",
  "tasks": {
    "basic/01_string_utils":      {"initial": "pass", "modified": "pass"},
    "basic/02_counter":           {"initial": "pass", "modified": "fail", "fail_reason": "..."},
    "intermediate/02_expr_eval":  {"initial": "pass", "modified": "pass"}
  },
  "msr_percent": 88.9,
  "notes": "1行サマリ"
}
```

## 現状

**ハーネスのみ (2026-07-22)**: `tasks/` の8タスク定義、`run_msr.sh`、
記録フォーマットを用意した段階で、まだ実ラウンドは走っていない
(`scores/`・`findings/` は空)。最初のラウンドを回すには上記手順に従う。
