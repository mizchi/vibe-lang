# lang-bench — cross-language same-model snapshot bench

almide (github.com/almide/almide) の評価手法のひとつを vibe に移植した
評価ループ。`docs/pl-survey-2026-07.md` の almide 調査、issue #1056 に続く
取り込み (`eval/msr/` の姉妹ハーネス — MSR が「改修への耐性」を測るのに
対し、こちらは almide の "minigit" ベンチ相当: **同じモデルに同じ
プロンプトを与えて複数言語で実装させ、pass 率・行数・ビルド成果物の
サイズを横並び比較する**)。

## なぜ横比較が要るか

`eval/lang-review/` は vibe 単体の絶対評価、`eval/msr/` も vibe 単体の
時系列評価。どちらも「他言語と比べてどうか」には答えない。LLM の
コード生成品質は言語ごとに大きく違い (訓練データの分量・構文の
予測しやすさに強く相関する)、vibe のような低リソース言語では特に
効くレバーが何かを見るために、同一プロンプト・同一モデルでの相対比較が
要る。

## 構成

```
eval/lang-bench/
  README.md            # 本ファイル
  SPEC.md              # ベンチ対象タスクの言語非依存仕様 ("mini-vcs")
  acceptance_test.sh   # 言語非依存の受け入れテスト (バイナリ/起動コマンドを受け取り、固定シナリオで検証)
  langs/
    vibe/README.md         # 言語別のビルド・実行手順
    rust/README.md
    typescript/README.md
    gleam/README.md        # このサンドボックスにはツールチェインが無い旨のメモ
    moonbit/README.md      # 同上
  attempts/<round>/<lang>/...   # ラウンドの成果物 (gitignore 対象)
  results/<date>-r<N>.json      # ラウンドごとの結果集計
```

## タスク

`SPEC.md` — 5 サブコマンド (`init`/`add`/`commit`/`log`/`status`) の
最小 VCS 風 CLI (almide の "minigit" を模した、ハッシュ計算不要の
縮小版 — 実装量を各言語 150〜300 LOC 程度に収める)。

## ラウンドの回し方

1. **同一モデル・同一プロンプト** — `SPEC.md` の "Prompt" セクションを
   言語名だけ変えて各言語に対して独立セッションで与える (前の言語の
   実装を見せない — 横比較なので相互汚染を避ける)。
2. **成果物を配置** — `attempts/<round>/<lang>/` に実装一式を置く
   (各 `langs/<lang>/README.md` のビルド手順に従う)。
3. **受け入れテスト** — 各言語のビルド成果物に対して
   `bash eval/lang-bench/acceptance_test.sh "<run-command>"` を実行し、
   12 チェック全 PASS か確認。
4. **メトリクス収集** — pass/fail、LOC (`wc -l` 相当)、ビルド成果物
   サイズ (バイナリ/wasm。TypeScript は対象外、`langs/typescript/README.md`
   参照)、可能ならビルド時間・起動時間。
5. **記録** — `results/<date>-r<N>.json` に集計 (下記スキーマ)。
   Gleam/MoonBit はこのサンドボックスにツールチェインが無いため
   (2026-07-22 時点)、それらを含むラウンドは別環境で実施し結果だけ
   持ち帰ってよい。

## 結果記録形式

`results/<date>-r<N>.json`:

```json
{
  "round": 1,
  "date": "2026-07-22",
  "model": "<model id/version>",
  "prompt_ref": "SPEC.md#prompt",
  "languages": {
    "vibe":       {"pass": true,  "loc": 210, "artifact_bytes": 7200, "notes": "..."},
    "rust":       {"pass": true,  "loc": 180, "artifact_bytes": 450000, "notes": "stripped"},
    "typescript": {"pass": true,  "loc": 160, "artifact_bytes": null, "notes": "no standalone binary"},
    "gleam":      {"pass": null,  "loc": null, "artifact_bytes": null, "notes": "not run (no toolchain here)"},
    "moonbit":    {"pass": null,  "loc": null, "artifact_bytes": null, "notes": "not run (no toolchain here)"}
  }
}
```

`pass` は `acceptance_test.sh` が 12/12 で通ったかどうか (bool)。
未実施は `null` で明示する (黙って欠落させない — 他の eval ハーネスと
同じ規約)。

## 現状

**ハーネスのみ (2026-07-22)**: `SPEC.md`・`acceptance_test.sh` は
トリビアルなモック実装で検証済み (12/12 pass)。`results/` はまだ空。
最初のラウンドを回すには上記手順に従う。
