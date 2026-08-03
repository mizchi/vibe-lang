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
- **Drop specialization Phase 1 — 試行して revert (PR #1274)**: inline
  shared-decrement fast path (rc ∈ [2, 0xFFFFFE] は call なし decrement) を
  scope-end let drop + fn epilogue param drop に適用して計測した。結果:
  selfcompile KPI は **flat (ratio 3.858、baseline と同値)** — RC lane の
  支配コストは drop の call overhead ではなく **allocator だった**
  (profiling で `vibe_rc_alloc` が全 CPU の 44.2%: unbounded exact-fit
  free-list walk が O(list)/alloc)。一方でコードサイズは drop site あたり
  ~5B → ~70B に増え、output-size ratchet (+2% 上限) を
  closure_indirect +14% / variant_float +5.8% で fail した。**利得ゼロ +
  サイズ回帰なので call site を plain runtime call に戻した**(経緯コメント
  は compile_expr_tail.vibe の ELet drop 経路に残置)。
- **Allocator 側の実測改善(こちらが本命、output サイズ中立)**:
  1. `gen_rc_alloc_body` の free-list walk を 16 nodes に bound —
     ratio **3.858 → 1.968** (rc wall 14970→7931ms)。コスト: 深い exact
     fit の放棄で heap_ptr 347MB→710MB。
  2. size-segregated bins (32 bins、sizes 16..264 step 8、bump base 直下の
     256B 領域): `gen_rc_drop_body` の2 free site が small block を bin へ
     push、`gen_rc_alloc_body` は bin pop 優先 → bounded walk → bump。
  dup 側 (`emit_rc_dup_guarded`) は元から inline。
- 未着手: プランナ語彙 PaReuseToken/PaReuseAlloc(分岐越え一般化)、
  drop specialization の残り site 系統(match 内 drop 等)、KPI 再計測は
  各段で #1262 に記録。

## Implementation notes (2026-08-03, #1262 continued)

### 計測手順の訂正 — `selfcompile_kpi_rc_lane.sh` は ratio を過小に出していた

**旧 lane script は bump を N 回まとめて回してから rc を N 回回していた。**
2つの self-build 直後の数分は machine がまだ落ち着いておらず、その warm-up が
まるごと bump lane に課金される。**同じ tree・同じ artifact・同じ 3 runs で
all-then-all が 1.193 (bump_med 8304)、interleaved が 1.820 (bump_med 5218)**。
1.193 は「出口条件 (≤1.2) 達成」と読めてしまう数字であり、実際には達成して
いない。

このコンテナでの bump は 7 runs で 4346..7447ms(1.7x の幅)振れる —
**測ろうとしている効果 (~1.8x) より drift の方が大きい**。lane script は
(a) interleave (bump, rc, bump, rc, ...) し、(b) round ごとの rc/bump 比の
中央値 `paired_ratio` も出すようにした(pair 内は数秒差なので slow drift が
相殺される)。**過去の tracking series の数値はこの bias を含む**ので、
比較するなら同一 invocation 内の interleaved 値どうしに限る。

### RC の output size は 3.5x、しかも全関数に一様

code section: bump **1,751,277 B / 3579 fns** → rc **6,153,809 B / 3581 fns**
(**3.51x**)。top-8 の占有率が 16.3% → 16.0% とほぼ不変なので、**数個の
runtime helper が太ったのではなく、per-site の inline RC guard が全関数に
一様に積み上がっている**(rc alloc/drop helper の 2 fn 増加分を除く)。
`emit_rc_dup_guarded` は inline (41 命令)、drop は call。

### borrow 推論の per-position 一般化 — landed、ただし利得 −0.69%

slice 1 (#1282) は **param 0 のみ**を推論していた。これを全 parameter
position へ一般化した(`compute_borrow_param_user_fns` が name→bitmask を
返し、call site / planner / callee 側 drop filter がすべて mask を引く)。
param0 を consume するが param2 は読むだけ、という関数も param2 を borrow
できる。

**差分検証**: mask を `& 1` に制限した build の出力は、main の RC stage2 の
出力と `bench/binary_size/*` 全 5 本で **byte 単位で一致** — 配線が
position 0 において完全に inert であることを先に固定してから、全 mask を
有効化した。

**実測 (RC stage2 の size)**:

| build | size | vs slice 1 |
| --- | --- | --- |
| position 0 のみ (= main) | 6,256,272 | — |
| 全 position (健全) | 6,213,090 | **−0.69%** |
| 天井: non-ident 失格を撤去 (**不健全**) | 5,895,092 | −5.77% |

**利得が小さい理由は測定で特定済み**: `ca_collect_nonident_args` の失格
条件が効きすぎている。ある position はプログラム中の **どこか 1 箇所** でも
非 ident 引数(`f(ctx, i + 1)` のような計算式)を渡されると、その position
全体が owned に落ちる。第 2 引数以降は計算式で渡されるのが普通なので、
ほとんどの position がこれで消える。**天井との差 5.1 ポイントがこの失格
条件のコスト**。

次の slice はここ: 失格を position 単位ではなく **call site 単位**にし、
borrow position に非 ident(= fresh temp)を渡す呼び出し側が call 後に
自分で drop を出す。ident 呼び出し側の dup 除去を保ったまま、temp 側だけ
drop を払う形になる。

### 検証手順の罠2つ(どちらも今回踏んだ)

1. **`generate_bundle.sh` 単体では `_cli_adapter_module_source.vibe` は更新
   されない**。`build_adapter_module_source` は `VIBE_REGEN_MODULE_SOURCE=1`
   でない限り committed 版を優先する。stage1/stage2 はそこから bootstrap
   するので、compiler source を編集して `generations.sh build` しても
   **変更が artifact に入らないまま「ビルドが通った」ように見える**。
   `bash scripts/resolve_generated_conflicts.sh --regen` を使う(5生成物を
   すべて regenerate。lib/ が未整形だと止まるので先に
   `bash scripts/vibe_fmt.sh <file>`)。
2. **`compiler_gate.sh` は arity/型エラーを取りこぼす**。gate は bundle
   flatten 済みソース(DCE 込み)を通すので、flatten で落ちる関数の中の
   エラーは見えない。今回 `build_perceus_plan`(test 専用なので DCE 対象)
   に 3 引数のままの `pctx_new` 呼び出しが残っていたが、**gate は 85/85 で
   通り fixpoint も一致**し、unit battery だけが 107 file の
   `fail(compile)` として検出した。**package 境界をまたぐ signature を
   変えたら battery を必ず回す** — #1262 の `bsearch_leftmost` /
   `mr_spine_tail` 事件と同じクラス。

**ただし size 問題の本命はこれではない**: 天井の −5.8% ですら 3.5x
(=+250%) に対しては誤差である。**残る ~4MB は「本当に必要な」guard の
inline 展開そのもの**なので、size の lever は guard の数をさらに減らすこと
ではなく **dup guard の out-line 化**(41 命令の inline → runtime call)。
drop specialization (PR #1274) が inline 化して size を +14% 悪化させた
のと**逆向き**の操作であり、まだ試されていない。wall とのトレードオフを
測ってから判断する。

## Reconciliation ledger

| 項目 | 根拠 / 観測 | 結論 |
| --- | --- | --- |
| 期待する契約 | RC default の wall ~1.6–2.1× は dup/drop と再確保が主因 | reuse で「分解→再構築」を in-place 化する |
| 実装観測 | `perceus.vibe` の action 語彙は dup/drop/alias-dup のみ、reuse token 無し | プランナ拡張が本体。ヘッダ(size+class)は照合に流用可 |
| 実装観測 | 唯一の elision(未参照 alias の dup/drop 除去)は実測インパクト 0 | occurrence-local では足りない。ペアリング解析が必要 |
| 実装観測 | self-build gate が VIBE_RC=0 に pin(性能) | 成功指標 2 で pin 解除を出口条件にする |
| 優先度 | 表面構文なし・bootstrap 不要・全コードに即効・zero_alloc の前提 | region/zero_alloc より先に実装する(本 ADR の主決定) |
| 回帰ガード | 出力 byte 同一 gate、shadow lane、rc_reuse fixture、B/op tracked series | Phase 1 から固定 |

## Implementation notes (2026-08-03, #1262) — dup guard の out-line 化 (未完)

### 測定: RC の size overhead の 86% は inline dup guard 1 箇所

RC stage2 のバイナリを直接読んで数えた (bump 側は同パターン 0 個なので
判別子として完全):

| | |
| --- | --- |
| inline dup guard | **52,479 sites** |
| 1 site あたり | **きっかり 72 B** (2000 サンプルで min == max) |
| 合計 | 3.78 MB |
| RC の size overhead 実測 | 4.37 MB |
| **dup guard がその** | **86%** |

形状モデルは実測で裏取り済み (guard あたり `push_addr` 3.00 個、
saturating check 1.00 個)。

### 実装と実測 (out-line 版は動く)

runtime helper `__rt_rc_dup` を追加し各 site を `local.get v; call` の
~5 B にする。helper 本体は `emit_rc_dup_inline` をそのまま呼ぶので inline
形と意味論がずれない。

| | size | |
| --- | --- | --- |
| bump stage2 | 1,841,905 B | — |
| rc stage2 (inline) | 6,213,090 B | 3.37x |
| rc stage2 (**out-line**) | **2,644,637 B** | **1.44x** (−57.4%) |

この out-line 版 RC コンパイラは実際に動く (tiny を compile+run して 42、
compiler source 全体の RC コンパイルも通る)。

### 未解決: all-RC bootstrap だけが落ちる

`VIBE_RC=1 scripts/generations.sh build` が stage1 → stage2 で
`memory access out of bounds`。**潰した仮説**: borrow 推論との相互作用
(OFF でも同じ) / seed の source 誤コンパイル (出力を inline に戻すと通る)
/ EIf MIN-merge の分岐非対称 #705 (対称化しても変わらず) / stage1 が壊れて
いる (小入力なら正常) / メモリ上限。

**最後のが一番情報量が大きい**。同じ入力を同じフラグで両 stage1 に
食わせると:

```
probe_inline stage1 : 成功。peak 19,746 pages (1.29 GB) / heap_ptr 924MB / 出力 5,436,015 B
dup_rc2 stage1      : OOB。 memory_size 13,164 pages (862 MB) / heap_ptr 757MB
```

**通る方は 19,746 pages まで伸びているので 13,164 pages は上限ではない** —
落ちる方は伸ばさずに現在サイズの外へアクセスしている。両者は
「1 dup site あたり 72 B 出すか 5 B 出すか」だけが違い、出力量が 5.4MB と
~2.6MB で変わるので確保パターンが変わる。#1262 が4ラウンド繰り返した
「set membership shuffles latent imbalances」と同型で、**既存の
allocator/RC の潜在不整合を本変更が可視化しているだけの可能性がある**。

trace は生成 helper 帯の低番号: `function[63] <- [22] <- [1937] <- [1996]
<- [1997] <- [2582] <- [3316]`。

次の一手は [selfhost-miscompile-bisect](../.claude/skills/selfhost-miscompile-bisect)
の probe entry + phase 二分。最小差分ペア (`emit_rc_dup_guarded` が
どちらの分岐を取るかだけが違う stage1 が2つ) が手元にある。

