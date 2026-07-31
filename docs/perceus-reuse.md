# ADR-0092: Perceus drop-guided reuse (FBIP) — RC の次段を最優先の実装トラックに引き上げる

Status: proposed

Date: 2026-07-31

Related: ADR-0055(RC cutover、`docs/spec/rc-port.md`), ADR-0062(shadow
liveness), ADR-0090(region), ADR-0091(`@zero_alloc`),
[mutability-control-review.md](mutability-control-review.md),
[pl-survey-2026-07.md](pl-survey-2026-07.md) Medium #7(Koka FP²/TRMC)。

## Context

Perceus RC は production default(ADR-0055 #493 cutover)だが、実装は
dup/drop/alias-dup の挿入と borrow 推論まで — **drop-guided reuse / FBIP /
TRMC / COW はどれも未実装**である(`rc-port.md` Phase 3.5 が明記)。結果:

- RC の実行時コストは bump 比 wall **~1.6–2.1×**。主因は dup/drop と、
  match で分解して作り直す関数型スタイルの「drop 直後に同レイアウトを
  再確保」するパターンにある。
- compiler self-build の gate は**性能理由で `VIBE_RC=0`(bump)に pin**
  されたまま(`scripts/compiler_gate.sh`)。RC で self-build する経路は
  存在するが遅くて常用できない。
- pl-survey は「vibe が世界的に先行している資産(Perceus 等)に対し、
  差分価値が最大なのは **FBIP 系の未取り込み後半**」「コンパイラ自身の
  ビルドが最大の受益者(AST 再構築ホットパス)」と結論している。

[mutability-control-review.md](mutability-control-review.md) は当初 FBIP を
`@zero_alloc`(ADR-0091)の後続に置いたが、本 ADR で**実装優先度を region
(ADR-0090)/ zero_alloc(ADR-0091)より前へ引き上げる**。理由: (a) 表面
構文が無く bootstrap bump も seed 調整も不要で、純粋に Perceus プランナと
codegen の作業として今日始められる。(b) RC が default である以上、利得が
全ユーザーコードに即時に効く。(c) reuse が入ってから `@zero_alloc` を
入れる方が検証通過域が最初から広い(逆順だと「後から通るようになる」
annotation churn が起きる)。(d) region の利得(dup/drop 除去)とも独立に
積算する。

## Decision

### 1. drop-guided reuse(中核)

Perceus 本来の reuse analysis を実装する。match arm で unique な値を分解
(最後の使用)した直後に**同レイアウト**(`alloc_size` が一致し、ヘッダ
規約が同じ)の constructor を確保する場合、drop を **reuse token** に変え、
確保を token の在庫からの in-place 再利用に変える。

- `PerceusAction` の語彙(現行 `PaDup | PaDrop | PaAliasDup`)に
  `PaReuseToken(binding, size_class)` / `PaReuseAlloc(token)` を追加する。
  プランナはスコープ内で「drop される unique 候補」と「後続の同サイズ
  確保」をペアリングする(最初は同一 match arm 内の直線コードに限定)。
- **実行時 uniqueness test**: token 化された値は確保点で
  `rc_count == 1` を検査し、unique なら header を書き換えて in-place 再利用、
  shared なら従来どおり新規確保 + 子の dup(Perceus 論文の標準形)。
  vibe のヘッダ(`[alloc_size@-8][rc+class@-4]`)はサイズ・クラスの照合に
  そのまま使える。
- **free list との関係**: reuse は exact-fit free list への往復
  (drop → free list push → alloc 検索)を丸ごと消す上位互換。free list は
  reuse が成立しない経路の受け皿として残る。

### 2. drop specialization

reuse の成立率を上げるため、静的に ctor が分かっている drop は再帰
`__rc_drop` 呼び出しではなく、その場で子 drop + 自身の解放(または token
化)へ inline 展開する。class-1(field vector)から始め、class-6/7 は
効果測定後に判断する。

### 3. TRMC(後続フェーズ)

cons 再帰のループ化(tail recursion modulo cons)は reuse の効果測定後の
Phase 3 とする。AST 再構築(コンパイラ最大のホットパス)は reuse だけで
大半が in-place 化する見込みが立ってから着手する。

### 4. `@zero_alloc` との合流規約

**reuse による in-place 再利用は「確保」に数えない**(ADR-0091)。これは
Koka FP² の `fip`(fully in-place)注釈と同じ意味論であり、reuse が広がる
ほど `@zero_alloc` を満たす関数が増える。fip/fbip 相当の checked 注釈を
独立に導入することはせず、`@zero_alloc` に一本化する。

## 成功指標(gate に固定する)

1. **selfcompile KPI**(`scripts/selfcompile_kpi.sh`)を `VIBE_RC=1` で
   計測するレーンを追加し、wall / heap を bump 基準と並記する。
   目標: wall の RC/bump 比を現行 ~1.6–2.1× から **≤1.2×** へ。
2. 達成後、`compiler_gate.sh` の `VIBE_RC=0` pin を外し、self-build も RC
   に統一する(bump は fixture/baseline 用の明示 opt-in に降格)。
3. `bench/regression/` に reuse を直接踏む bench(match 分解→再構築
   ループ)を追加し、`bytes_per_op` の激減(理想 0)を tracked series で
   固定する。既存 `alloc_bench` の 10,400 B/op 基準は「reuse 対象外の
   確保」の回帰検出として不変のまま残す。

## 安全性・検証

- **出力の byte 同一性**: reuse は意味論を変えない最適化なので、既存の
  「RC on/off で出力バイト・診断が一致」系 gate をそのまま適用する。
- **shadow lane 拡張**(ADR-0062): reuse された block の liveness を
  shadow バイトで追跡し、token の二重消費・shared 値の in-place 破壊を
  決定的に trap させるデバッグ lane を Phase 1 から用意する。
- fixture: `rc_reuse_*` 系を新設(unique 成立 / shared フォールバック /
  branch 越えの token 不成立 / closure capture との干渉)。#1085/#1097 の
  既存 RC 修正 fixture(over-drop / borrowed capture)を回帰対象に含める。
- 形式面: almide(pl-survey 参照)が RC discipline を Lean で検証している
  前例に倣い、reuse token の「unique 時のみ書き換え」不変条件を
  `formal/` の小さなモデル + oracle corpus として先に固定する(実装との
  correspondence は differential fixture で接地)。

## Non-goals

- COW / `MakeUnique`(vibe の Array/Map は無条件 in-place であり、COW 化は
  別議論。rc-port.md Phase 3.5 の結論を維持)。
- 循環回収(region = ADR-0090 が引き受ける)。
- wasm-gc backend(RC 自体が linear 専用)。
- fip/fbip の独立注釈(Decision 4 のとおり `@zero_alloc` に一本化)。

## Implementation notes (2026-07-31, #1262)

- **Phase 1 reuse 縦串** (PR #1265 + follow-up): let+match fusion、
  fn-param 直 match fusion、arm-body let-spine 拡大まで landed
  (`compile_match.vibe` の mr_* 系 + `compile_expr_tail.vibe` /
  `linked_compile.vibe` の staging)。fn-param fusion は selfcompile KPI に
  有意な改善なし(適格 arm が compiler 実コードにほぼ無い)— #1262 の
  正直な再評価コメント参照。
- **Drop specialization Phase 1** (`common_base.vibe::emit_rc_drop_fast`):
  scope-end let drop(reuse-fusion guarded / borrow-ret dance / plain の
  3経路)と fn epilogue param drop に、inline shared-decrement fast path を
  適用。shared block (rc ∈ [2, 0xFFFFFE]、単一の unsigned range test で
  判定) の drop は call なしの in-place decrement。unique (rc==1、再帰
  field walk + free が必要) と saturated/immortal (0xFFFFFF) は従来どおり
  runtime `vibe_rc_drop` へ。scalar / fat-pointer は dup と同じ tag test で
  inline skip。**VIBE_RC=shadow では fast path を出さない**(freed-block
  検査が runtime drop の入口にあるため、inline decrement はそれを迂回する)。
  トレードオフ: drop site あたり ~5B → ~70B のコードサイズ増(適用は
  hot 2 系統のみに限定)。dup 側 (`emit_rc_dup_guarded`) は元から inline。
- 未着手: プランナ語彙 PaReuseToken/PaReuseAlloc(分岐越え一般化)、
  borrow 推論拡張(dup/drop ペア削減 — KPI 2.6-3.8x の主犯)、
  drop specialization の残り site 系統(match 内 drop 等)、KPI 再計測は
  各段で #1262 に記録。

## Reconciliation ledger

| 項目 | 根拠 / 観測 | 結論 |
| --- | --- | --- |
| 期待する契約 | RC default の wall ~1.6–2.1× は dup/drop と再確保が主因 | reuse で「分解→再構築」を in-place 化する |
| 実装観測 | `perceus.vibe` の action 語彙は dup/drop/alias-dup のみ、reuse token 無し | プランナ拡張が本体。ヘッダ(size+class)は照合に流用可 |
| 実装観測 | 唯一の elision(未参照 alias の dup/drop 除去)は実測インパクト 0 | occurrence-local では足りない。ペアリング解析が必要 |
| 実装観測 | self-build gate が VIBE_RC=0 に pin(性能) | 成功指標 2 で pin 解除を出口条件にする |
| 優先度 | 表面構文なし・bootstrap 不要・全コードに即効・zero_alloc の前提 | region/zero_alloc より先に実装する(本 ADR の主決定) |
| 回帰ガード | 出力 byte 同一 gate、shadow lane、rc_reuse fixture、B/op tracked series | Phase 1 から固定 |
