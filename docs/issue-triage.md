# Issue triage — 分類と優先順位の機械的な決め方

最終更新: 2026-08-07（初版適用後、同日に done 検証で 4 件クローズ・並列分割の節を追加）

「次に何をやるか」を毎回考え直さずに済むように、**ラベルの意味を一つに固定する**。
各 issue は「種類」「優先度」「順序」の 3 軸で独立にラベルされ、
**着手順はこの 3 つから機械的に決まる**。

## 軸 1: 種類 (kind)

| label | 意味 |
|---|---|
| `bug` | 現在の実装が意図に反する。誤った結果・落ちる・通るべきものが通らない |
| `enhancement` | 新しい能力を足す |
| `refactoring` | 挙動不変の整理 |
| `epic` | **索引**。実作業は sub-issue 側にある |
| `performance` | 速度・メモリ。`bug`/`enhancement` と併用可 |
| `runtime` | 実行時基盤に触る。領域タグ、他と併用可 |

## 軸 2: 優先度 (P0 / P1 / P2)

**「壊れ方の悪質さ」だけで決める。** 「重要そう」「やりたい」は入れない。

| label | 判定基準 | なぜこの順か |
|---|---|---|
| **P0** | **黙って誤る** — 誤った値を返す / miscompile する / 誤ったプログラムを検査が受理して下流まで通す | 気づけない。書いた人が悪くないのに間違いが混入する。言語として最悪の壊れ方 |
| **P1** | **落ちる・書けない** — 正しいコードが弾かれる / 型検査を通って codegen で落ちる / 診断が行動可能でない / 資源枯渇に向かっている | 気づける。回避もできる。ただし体験を確実に損なう |
| **P2** | **機能追加・探索・将来** — 今動いているものは壊れていない | やれば良くなるが、やらなくても嘘はつかない |

判定は **issue が自分で述べている症状**から行う。「重要な機能だから P0」はしない —
それは優先度ではなく好みになる。

## 軸 3: 順序 (`blocker`)

`blocker` = **他の open issue の前提になっている**。優先度とは独立。

`blocker` が付いた issue は「その subtree の中で最初にやるもの」であって、
「今すぐやるべきもの」ではない。この 2 つを混ぜると、実験的サブツリーの
Phase A が実バグと同じ棚に並んでしまう。

## 着手順 (この 3 軸から機械的に導く)

```text
1. P0 を全部
2. P1 のうち blocker が付いているもの
3. 残りの P1
4. 着手したい subtree を選び、その中の blocker から
```

`epic` は索引なので、それ自体は着手対象にしない（sub-issue を見る）。

## 2026-08-07 時点の適用結果

### P0 — 黙って誤る (4)

| # | blocker | 内容 |
|---|---|---|
| #1526 | | `==` が Array に対して 3 通りの答えを返す（裸=参照 / struct・enum の中=構造的 / tuple の中=参照）。**意味論は決定済み: 構造的等価に統一 (ADR-0097)** — あとは実装のみ |
| #1527 | | 関数から返した `Bool` を補間すると `1` / `0` になる |
| #1529 | | bounded 呼び出し `B::method(x)` が、impl 対象の struct がファイル内で最初でないと壊れる |
| #1533 | ✔ | 非 export の名前を import しても検査を素通りする。ADR-0096 (#1455) の import 必須化フェーズの前提 |

（#1525 ローカル enum の miscompile は `ab031d2` のパーサ拒否で解消しクローズ済み）

### P1 — 落ちる・書けない (7)

| # | blocker | 内容 |
|---|---|---|
| #1536 | ✔ | suspend CPS split の see-through。row-free closure param flow 証明と eager `Stream::next` retarget は済み。残り = row-variable callee / literal-param flow |
| #1511 | | `handle` の適格性制約が型検査を通り抜ける。(c) エラー文は済み、(b) は #1536 のスライスと同一機構 |
| #1520 | | builtin レジストリの検証。提案 1 は済み、残り = 85 件の二重宣言の一括整理 + 提案 3 の正例コーパス |
| #1508 | | `Http` を実行する test / bench。row 構文は済み、残り = test/bench 経路での `Http::*` lowering |
| #1514 | | 診断の位置情報が 3 段階に分かれている（C は済み、残りあり） |
| #1446 | | guard の else で abortive effect を発散として受理する |
| #1553 | | cold cache の guest heap 2.6 GiB。決定済み: 目標値は置かず phase 別計測 + 3.5 GiB 監視を先に |

（#1500 optional 引数と #1503 trait instance 解決は実装済みでクローズ、#1547 finalizer は「今は入れない」で決着しクローズ）

### blocker が付いた P2 (subtree の入口)

| # | 何を待たせているか |
|---|---|
| #1541 | wasm-gc Phase C (#1542) / Phase D (#1543) |
| #1548 | incremental P0-3 (#1550) |
| #1549 | incremental P0-3 (#1550) |
| #1550 | incremental P3 codegen reuse (#1552) |

### epic (索引、着手対象ではない)

#1230 async / #1238 formal / #1262 RC・region / #1331 wasm-gc / #1341 ADR-0089 D3 / #1379 incremental

## sub-issue の使い方

GitHub の sub-issue でツリーを作る。**親は索引、子が作業単位**。

```text
#1230 async umbrella
├── #1536 suspend CPS の closure param   ← blocker
├── #1537 M-conc-2 CPS lowering
├── #1341 ADR-0089 D3 (これ自身も索引)
│   ├── #1538 eager Stream 退役
│   ├── #1539 ByteStream の p3 接続
│   └── #1540 serve/host-stream composition 統合
└── #1342 host async import の一般化
```

親 issue の本文には**現在地と子への索引だけ**を置き、経緯はコメントに残す。
本文にチェックリストを積み上げると、着地した項目が増えるほど
「次に何をやるか」が読めなくなる — 5 件の棚卸し (2026-08-07) はその状態の解消だった。

## 並列分割 — コンフリクトしない lane

複数エージェント（または複数 PR）を並走させるときの分割。**conflict の実面は
「同じソースファイルへの編集」「gate/fixture リストへの append」「cheatsheet への
追記」の 3 つだけ** — 生成 bundle は untracked になった (#既存の決定) ので、
かつて必発だった bundle 衝突は構造的に存在しない。

規則: **同じファイル群を触る issue は同じ lane に入れて直列。lane を跨いだ並走は自由。**

| lane | ファイル領域 | 入る issue | 備考 |
|---|---|---|---|
| **A. checker/parser** | `lib/@vibe/compiler/checker/`, `parser/` | #1533、#1536(c)+#1511(b) の check 段検出、#1520 提案 3 | |
| **B. codegen (linear)** | `codegen/expr/compile_call.vibe`, `builtin_bodies/` | #1527、#1529、#1526 (ADR-0097 決定済み)、#1538-1 | compile_call は共有点なので lane 内直列 |
| **C. wasm-gc** | `codegen/gc/` | #1541 → #1542 | linear と無衝突は ADR-0095 が構造的に担保 |
| **D. incremental/cache** | `runtime/typecheck_fs.vibe`, `cache/` | #1548 → #1549 → #1550 | |
| **E. formal** | `formal/` | #1544、#1545、#1546 | 完全無衝突。3 本とも同時並走可 |
| **F. runtime/host** | `scripts/wasm_vibe_host_runner.js`, `runtime/viberun` | #1553 の計測、#1540 | |

lane 内の順序は blocker → P 順。gate スクリプトへのエントリ追加は必ず**末尾 append**
にする（リスト中間への挿入は隣の lane と衝突する）。

## この分類の限界

- `blocker` の辺は、issue 本文が明示している依存だけを採った。
  暗黙の依存は拾えていない
- 新しい issue を立てたら、この 3 軸を付けるところまでを起票の一部とする
- クローズは「fix commit が main にあること」を確認してから行う
  （2026-08-07 の検証: #1500 = `36e7869`、#1503 = `d9a50f6`+`7585b74`、
  #1525 = `ab031d2`。#1508/#1520/#1514 は部分着地なので open のまま残した）
