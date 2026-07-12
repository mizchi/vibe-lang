# 評価 rubric

7 dimension、各 1–5。**ラウンド間で不変に保つ** (追加は可、既存の定義変更は
不可 — 変えるとスコア推移が比較不能になる)。

## スコアの一般定義

- **5** — 業界最良水準。この軸で他言語に劣る点を挙げるのが難しい
- **4** — 良い。minor な不満はあるが日常使用で困らない
- **3** — 使える。既知の穴・不整合があり、中級者がときどきつまずく
- **2** — 目立つ欠陥がある。初見者が高確率でつまずく / 回避策の知識が要る
- **1** — この軸が実用の妨げになっている

## Dimensions

### 1. syntax_clarity (文法のわかりやすさ)

表記の一貫性・驚きの少なさ・冗長性。同じことを書く方法が複数ないか
(interpolation の `\(x)` vs `\{x}`、`let` vs `fn` など)、構文から意味が
予測できるか、docs の説明と実装が一致しているか。

### 2. writability (コードの書きやすさ)

`tasks/` の仕様を docs/cheatsheet.md だけを頼りに書いたときの成功率と
friction 数で測る。1 タスクあたりのコンパイルエラー回数、docs に無くて
推測が必要だった箇所、known-gotcha を踏んだ回数を記録する。

### 3. semantics_consistency (意味論の一貫性)

評価順序、mutation の規律、等価性 (`==` の構造的等価)、パターンマッチの
網羅性と束縛、文字列/配列の値意味論、effect handler の resume 意味論などが
一貫していて説明可能か。実地プローブで「予想と違う結果」を数える。

### 4. type_soundness (型システムの健全性)

ill-typed プログラムが reject されるか (silent miscompile / garbage 束縛が
無いか)。ADR「型健全性」系列で塞いだ穴の回帰確認 + 新しい穴の探索。
generic instantiation・inference の完全性の欠けは「健全だが不便」として
writability 側に振り分け、こちらは unsound (誤って通る) を重く数える。

### 5. effect_system (エフェクトシステム)

effect row の宣言・伝播・放電 (`handle`) の規律が明確か。capability
effect (Fs/Env/...) の transitive 強制、`Error`/`Async` の設計判断の
妥当性、effect まわりの診断の質。

### 6. diagnostics (エラーメッセージ / 診断)

コンパイルエラーが位置 (line:col) と原因を正しく指すか。メッセージから
修正方法が推測できるか。parse error recovery で複数診断が出るか。

### 7. concurrency_readiness (並行設計適合性)

**目標モデル: Go channel / Elixir 風軽量プロセス** (ADR-0068)。現行の
言語・ランタイム設計 (bump/RC アロケータ、effect handler の replay 実装、
グローバル可変状態、`Task`/`Stream` surface) がこのモデルへの進化を
妨げていないかを評価する。「未実装」は減点しない — **妨げる設計**
(後から直せない前提の混入) を減点する。

## レビュアープロンプト (subagent に与える)

共通ヘッダ (全レビュアー):

> あなたは vibe 言語 (このリポジトリ) の言語設計レビュアー。担当 dimension
> をレビューし、最後に必ず次の JSON だけを返すこと:
> `{"reviewer": "<name>", "dimensions": {"<dim>": {"score": N, "rationale": "..."}},
>   "findings": [{"severity": "major|minor", "area": "...", "summary": "...",
>   "evidence": "...", "suggestion": "..."}]}`
> スコアは eval/lang-review/rubric.md の定義に従う。プローブコードは
> `_build/evalprobe-<name>/` 以下に書き、リポジトリの既存ファイルは変更
> しない。compile+run の方法は eval/lang-review/README.md の検証コマンド。

- **writability** — 担当: syntax_clarity, writability。
  `eval/lang-review/tasks/*.md` を順に、docs/cheatsheet.md (+ docs/vibe.md)
  だけを頼りに解く。golden/ は見ない。タスクごとにコンパイルエラー回数と
  friction を記録。全タスク終了後にスコア。解答ファイルは残す
  (golden 候補になる)。
- **semantics** — 担当: semantics_consistency, diagnostics。
  docs/cheatsheet.md・docs/spec/decisions.md を読み、意味論のコーナー
  ケース (評価順序、mut、==、match、文字列、effect resume) を 10 個以上
  プローブし、「予想と違う」「docs と違う」を全部記録。診断の質も
  エラーを意図的に起こして評価。
- **type-soundness** — 担当: type_soundness, effect_system。
  ill-typed プログラムを 15 個以上書き、reject されるか確認 (通ったら
  major finding)。ADR の型健全性系列 (docs/adr.md の 0066 近辺の長大
  エントリ) を参照して既知の残穴 (generic struct field 等) の現状も確認。
  effect の宣言漏れ・放電・transitive 強制もプローブする。
- **concurrency** — 担当: concurrency_readiness。
  docs/adr.md の ADR-0012 (Task/Stream)・ADR-0055 (RC/値表現)・
  ADR-0068 (並行設計原則)、TODO/#488 系を読み、Go channel / Elixir 軽量
  プロセスモデルに向けて「妨げになる既存設計」を列挙する。コードは
  読むだけでよい (プローブ任意)。
