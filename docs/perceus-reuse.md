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

### bisect 結果: 犯人は `compile_expr_tail.vibe` の 9 サイト

まず **main を `VIBE_WASM_NAMES=1` 付きで all-RC ビルドすると通る**ことを確認した
(names は出力サイズを大きく変える)。よって「出力サイズが変わると壊れる main 側の
潜在バグ」ではなく、本変更由来であることが確定。

そのうえで call 形を残すファイルを1つずつ変えて all-RC bootstrap を回した
(それ以外の site は `-1` を渡して inline 形へ戻す):

| ファイル | site 数 | all-RC bootstrap |
| --- | --- | --- |
| `codegen/wasi/linked_compile.vibe` | 4 | PASS |
| `codegen/expr/compile_call.vibe` | 7 | PASS |
| `codegen/expr/compile_match.vibe` | 6 | PASS |
| `codegen/expr/compile_lambda.vibe` | 4 | PASS |
| `codegen/expr/compile_expr_tail2.vibe` | 2 | PASS |
| `codegen/expr/compile_expr_tail4.vibe` | 1 | PASS |
| `codegen/expr/compile_expr_tail6.vibe` | 1 | PASS |
| **`codegen/expr/compile_expr_tail.vibe`** | **9** | **FAIL** |

**さらに 1 行単位で二分したところ、単一の犯人は存在しなかった**:

| compile_expr_tail.vibe で call 形を残した site | all-RC bootstrap |
| --- | --- |
| 920 / 977 / 1267 / 1377 (前半4) | PASS |
| 1591 / 1604 / 1645 / 1666 / 1714 (後半5) | PASS |
| 1591 / 1604 のみ | PASS |
| 1645 のみ | PASS |
| 1666 のみ | PASS |
| 1714 のみ | PASS |
| **9 site 全部** | **FAIL** |

**前半だけでも後半だけでも通り、両方揃ったときだけ落ちる。** 個々の site の
意味論の問題ではなく、out-line された dup の総数がある閾値を越えて確保
パターンが変わったときに初めて表面化する、**累積的**な事象である。

**同じ helper (`__rt_rc_dup`) を同じ形で呼んでいるのに、この 1 ファイルの site
だけが壊す。** つまり helper 本体でも call 形そのものでもなく、この 9 site の
どれかが置かれている文脈(ELet の scope-end drop / borrow-ret / loop-borrow
まわり)と call 形の組み合わせが問題。したがって **out-line 化そのものは健全**と考えるのが妥当:
各 site は単独では正しく、helper は inline emitter の再利用で意味論が同一、
小規模では compile+run が通り、compiler source 全体の RC コンパイルも通る。
落ちるのは「十分な数の dup を out-line したときの確保パターン」でだけ。

つまりこれは #1262 が4ラウンド繰り返した *set membership shuffles latent
imbalances* と同型で、**既存の潜在的な RC/allocator 不整合を本変更が
可視化している**という読みが最も整合的。次の作業は「out-line を直す」では
なく「その潜在不整合を見つける」であり、#1262 とは独立に価値がある
(見つかれば main のバグ)。ただし `main` を `VIBE_WASM_NAMES=1` で
all-RC ビルドしても再現しないので、出力サイズ変化だけでは引き出せない —
dup の配置そのものが効いている。

なお crash は `__rt_rc_alloc` ← `__rt_arr_new` ← `lc_fresh_int_array` で、
heap に 105MB の余裕がある状態で起きる = free list の壊れた next を辿っている。
`VIBE_RC=shadow` では checker の `expr_children` で落ちる(設定で場所が変わる =
ヒープ破壊の典型)。size bins を無効化しても再現するので bin ロジックでもない。

次の一手は [selfhost-miscompile-bisect](../.claude/skills/selfhost-miscompile-bisect)
の probe entry + phase 二分。最小差分ペア (`emit_rc_dup_guarded` が
どちらの分岐を取るかだけが違う stage1 が2つ) が手元にある。

## Implementation notes (2026-08-03 続き, #1262) — blocker 追跡の前提の訂正

### bisect harness の sed 残骸が生成物として commit されていた

`bisect_sites.sh` / `bisect_lines.sh` は sed で call site を `-1` に潰し、
`resolve_generated_conflicts.sh --regen` で生成物を作り直してからビルドし、
最後に `git checkout -- lib/@vibe/compiler` で戻す。この戻しが効かないまま
commit した結果、**手書き source と生成物が食い違う commit が2つできていた**:

| commit | 手書き source の call site | committed `_cli_adapter_module_source.vibe` |
| --- | --- | --- |
| `84b771ed` / `24cb1afa` / `97c7b559` | 30 | 30 (一致) |
| `b1976ce3` | 30 | **9** (= onlyTail 構成 = FAIL 既知) |
| `334f924a` | 30 | **5** (= bl_half2 構成 = PASS 既知) |

生成物は committed source の決定的関数で、`generations.sh` は
`VIBE_REGEN_MODULE_SOURCE=1` がなければ committed 版をそのまま使う。よって
`334f924a` から `VIBE_RC=1 scripts/generations.sh build` を回すと full
out-line ではなく **bl_half2 構成がビルドされ、通ってしまう**。blocker が
消えたように見える。実際そう見えた (`_build/repro_head` = exit 0)。

再生成して 30 site に戻した (`d9588da9`、bundles は `97c7b559` と byte 一致)
うえで回すと **同じ crash が同じ heap_ptr=757000688 で再現**する。
`84b771ed`〜`97c7b559` は生成物が一致していたので、**前節の bisect 表と
「潰した仮説」は有効**。

`pkf run test` の `scripts/check_module_source_sync.sh` はこの食い違いを
検出する gate だが、この WIP 群は gate を通していなかった。**探索用に
source を機械的に書き換える harness を使うときは、commit 前に必ず
`pkf run test` か最低でも `check_module_source_sync.sh` を通すこと。**

### `VIBE_RC=shadow` は selfcompile 規模では使えない (heap と shadow 表が重なる)

#715 recurrence guard は「1 heap address = 1 byte」の liveness 表を
`rc_shadow_base()` = **256 MB** 固定に置く。`rc_shadow_reserve()` は
memory section の最小ページ数を増やすだけで、**heap の開始位置も上限も
動かさない**。heap は 0 付近から上へ伸びるので、**heap が 256 MB を超えた
瞬間から bump pointer が shadow 表そのものを踏む**。

selfcompile の heap は実測 924 MB (通る側の probe) まで伸びるので、
shadow モードは必ずこの状態に入る。実際 shadow 実行のクラッシュは
`heap_ptr=268501644 (0x1001028c)` — `rc_shadow_base()` = `0x10000000` の
**66 KB 先**で、落ちる場所も checker の `expr_children` (guard ではない
普通の関数) だった。これは「設定で場所が変わる = ヒープ破壊の典型」では
なく、**shadow 機構自身がヒープを壊していた**。

したがって #715 guard は今回の diagnosis に使えない。代替として、block
header の `alloc_size` word の **bit 30** を free-list 在籍マークに使う
poison 方式を入れた (サイズは 2^30 に遠く届かないので追加メモリ 0):
free push で立て、alloc の払い出しで落とし、`__rt_rc_drop` の入口で
立っていたら `unreachable`。bin 払い出し時に `size == 要求 sz` も検査する。

### 落とし穴: **source 側の runtime 計装は crash する binary に入らない**

**落ちるのは stage1 で、stage1 の runtime helper は seed が出力したもの。**
`lib/@vibe/compiler/codegen/builtin_bodies/` を書き換えても、それが効くのは
「stage1 が stage2 へ**出力する** runtime」であって、**stage1 自身の
`__rt_rc_alloc` / `__rt_rc_drop` は seed のまま**である。

これを踏み外して3ラウンド無駄にした。`VIBE_RC=1 generations.sh build` を
poison 版 / poison v2 版 / quarantine 版の tree で回して、いずれも
「トラップせず元と同じ `__rt_rc_alloc` の範囲外アクセスで落ちた」ため
「二重 free ではない」「再利用は無関係」と読んだが、**そもそも計装が
入っていない binary が落ちていた**だけで、これらの結論は支持されない。
撤回する。crash 位置が 757000688 → 757657136 → 757724408 と少しずつ
動いたのは計装の効果ではなく、compiler source が変われば stage1 の挙動と
出力量が変わるため。

**計装を crash する binary に入れる唯一の方法は、seed 以外のコンパイラで
stage1 を作ること。** それを試したのが下の切り分けで、結果は「現行
コンパイラで作った RC stage1 は落ちない」だった。

### 切り分け: seed 固有か、現行 codegen の生きたバグか

| stage1 を作ったコンパイラ | stage1 の dup guard | サイズ | flat source をコンパイル |
| --- | --- | --- | --- |
| **seed** (`bootstrap/seed/compiler.wasm`) | inline (seed に `__rt_rc_dup` はない) | 6,332,395 | **OOB で落ちる** |
| 現行 source からビルドした bump コンパイラ | out-line | 2,896,884 | **通る** |

ここから2つ言える:

1. **落ちる binary に out-line された dup は1つも入っていない。** seed は
   `__rt_rc_dup` を持たないので、out-line 化がどれだけ source に入って
   いても seed の出力は inline guard のままである (6.3MB という
   サイズがその証拠)。out-line 化そのものが crash するコードに存在しない
   以上、out-line の意味論は原因ではありえない。source 変更が stage1 に
   与える影響は「seed がコンパイルする source の形」だけで、これは
   bisect が「単一 site ではなく累積的」と出したことと整合する。

2. 同じ source を現行 codegen で RC コンパイルすると**動く stage1 が
   できる**。つまり疑うべきは pin されている seed の codegen/perceus で
   あって、現行 source ではない。

### 結論 (訂正済み): seed と source の**交互作用**。bootstrap bump は恒久的な修正ではない

> **2026-08-03 訂正**: 当初この節は「blocker は seed 固有」と結論していた。
> その比較は seed と source を**同時に**動かしており、支持されない。
> 実際に bootstrap bump を試したら再発した。以下が訂正後の内容。

「どのコンパイラが stage1 を出力したか」と「どの source をコンパイルしたか」
の2軸で all-RC bootstrap を回した結果:

| stage1 を出力したコンパイラ | source | all-RC |
| --- | --- | --- |
| pin 済み seed | `d9588da9` | **FAIL** |
| `d9588da9` からビルド | `d9588da9` | **PASS** (fixpoint) |
| `89a052b9` からビルド | `d9588da9` | **PASS** |
| `89a052b9` からビルド | `89a052b9` | **FAIL** |

- 行1 vs 行2/3: **source を固定して seed を替えると結果が変わる** → seed が効く
- 行3 vs 行4: **seed を固定して source を替えると結果が変わる** → source も効く

つまりどちらか一方に帰属させることはできない。**(コンパイラ, source 形状) の
組み合わせで出たり出なかったりする潜在的な RC/allocator バグ**であり、#1262 が
何度も踏んだ *set membership shuffles latent imbalances* と同型である。

**bootstrap bump は修正ではない。** その時点の source に対してたまたま当たりを
引く操作でしかなく、以降どんな source 変更でも再発しうる。実際、out-line 化を
マージした main (`89a052b9`) から作った seed で all-RC を回すと、旧 seed と
**同じ `__rt_rc_alloc` ← `__rt_arr_new` で落ちる** (`heap_ptr=730006172`)。

したがって `bootstrap/seed.json` の bump は行わなかった。all-RC 経路を
production で有効にする前に、この潜在バグ自体を見つける必要がある。

#### 依然として有効な結論

- **out-line 化そのものは無罪**: seed は `__rt_rc_dup` を持たないので、
  旧 seed の出力に out-line された dup は1つも含まれない (6.3MB がその証拠)。
  crash するコードに存在しない機能が原因ではありえない。
- **out-line 化の効果**: RC/bump 比 **3.37x → 1.44x** (−57.4%)。
  `pkf run release-check` 緑、default gate は `VIBE_RC=0` pin なので影響なし。

| | bump stage2 | RC stage2 | 比 |
| --- | --- | --- | --- |
| inline guard (従来) | 1,841,905 | 6,213,090 | 3.37x |
| **out-line** | 1,842,511 | **2,644,652** | **1.44x** |

#### 次に潰すべきもの

潜在バグの本体。制約が1つ判明している: **source 側の runtime 計装は seed が
出力する stage1 には入らない** (前節) ので、計装するなら seed 以外で stage1 を
作る必要がある。ただし「seed 以外で作った stage1」は source によって通ったり
落ちたりするので、**落ちる (コンパイラ, source) の組で計装を入れる**のが要件に
なる。`89a052b9` からビルドしたコンパイラ + `89a052b9` の source がその組で、
これは手元で再現する。

## Implementation notes (2026-08-04, #1262) — borrow 推論の残り伸びしろは out-line 化が食べていた

### 試したこと

borrow 推論の「非識別子引数による位置の失格」を per-call-site 化した。
失格の理由は健全で、borrow 位置では caller が transfer dup を出さず callee も
epilogue drop を省くため、**一時値を渡すと解放する持ち主が誰もいなくなる**。
ただしこの判定は `(callee, position)` 単位で**全プログラム**に効くので、
1箇所でも一時値を渡す call site があるとその位置の borrow が全部潰れていた。

borrow かどうかは callee の ABI の性質 (本体は1つ、drop の判断も1つ) なので
位置ごとに変えることはできない。よって修正は call site 側に置く:
一時値を `local.tee` で local に留め、call の**後**に drop する
(callee は本体の間ずっと借りているので drop は call 後でなければならない)。

### 実測: 期待 5.1 ポイントに対して −0.48%

同一入力 (`_build/seedbump/cli_adapter_module_source.vibe`) を2つの codegen で
RC コンパイル:

| codegen | size |
| --- | --- |
| baseline (失格判定あり) | 2,687,364 |
| per-call-site 化 | **2,674,503** (−12,861 B = **−0.48%**) |

固定 fixture (`bench/binary_size/`) では 5本中4本が byte 一致、
**`variant_float` だけ +244 B (+4.9%)**。`scripts/bench_binary_size.sh` は
`VIBE_RC=0` と `VIBE_RC=1` の両方を測るので、これは output-size ratchet
(+2% 上限) に引っかかる。**よって landable ではない。変更は戻した。**

### なぜ伸びしろが消えたか (算数が合う)

5.1 ポイントという数字は **out-line 化の前**に測ったものだった:

```
天井測定 (inline 時代)   6,256,272 -> 5,895,092  = 361,180 B の inline guard が消えた
out-line 後の同じ dup 群  361,180 x (5/72)       = 約 25,081 B
                        = 現行 RC binary 2,674,503 B の 0.94%
実測 (parking コスト差引後)                       = -0.48%
```

inline guard 1個は 72 B だったが、out-line 後は `local.get v; call` の約 5 B。
**removed dup 1個の価値が 1/14 になった**一方、per-call-site の parking は
`tee` (~2 B) + `get`+`call drop` (~5 B) で約 7 B かかる。差し引きが
ほぼ拮抗するところまで来ている。

**教訓: out-line 化と borrow 推論は加算されない。** 両方とも同じ 3.78 MB の
inline dup guard を取り合っており、先に out-line 化が取った。docs や #1262 に
残っていた「borrow の伸びしろ 5.1 ポイント」は out-line 化のマージ (#1405) を
もって **stale** である。

### RC size の次を探すなら

dup guard は out-line 済みで、borrow 推論は上記のとおり頭打ち。
残る size overhead (RC 2.67 MB / bump 1.87 MB = 1.43x、差 0.80 MB) の内訳は
**未測定**。次にやるなら、まず out-line 後のバイナリで内訳を取り直すこと
(以前の「86% は dup guard」はもう成立しない)。

## Implementation notes (2026-08-04, #1262) — out-line 化は wall を悪化させていた

### 現在地: 出口条件は wall ≤1.2、実測 2.07

`scripts/selfcompile_kpi_rc_lane.sh 3` on `0f0ad63c`:

```
bump_runs = 11126 7012 7306   (median 7306)
rc_runs   = 15753 14861 15103 (median 15103)
ratio = 2.067   paired_ratio = 2.067
```

### out-line 化の wall コスト: 1.319x (同一ループ交互計測、5 round)

同じ tree・同じワークロードで、dup guard の形だけを変えた2つの RC stage2:

```
inline_runs  = 11714 13054 11959 12159 11524   median 11959
outline_runs = 15451 15157 17838 15504 16696   median 15504
pair ratios  = 1.3190 1.1611 1.4916 1.2751 1.4488   median 1.319
```

| | RC stage2 size | wall |
| --- | --- | --- |
| inline guard | 6,273,031 | 基準 |
| out-line (#1405) | 2,678,659 (**−57.3%**) | **+32%** |

**ADR-0092 の出口条件は wall (≤1.2x) であって size ではない。** #1405 は測って
いた指標 (size) を改善する代わりに、採点される指標 (wall) を 32% 悪化させて
いた。out-line 無しなら ratio は 11959/7306 ≈ **1.64** で、これは out-line 化
前の履歴値 (1.659 / 1.742) と整合する。

### hybrid (前段フィルタを inline に残す) — 不採用

「奇数判定だけ inline に残し、本当にヒープの時だけ call する」形を試した:

```wat
local.get $v; i64.const 1; i64.and; i32.wrap_i64
if  local.get $v; call __rt_rc_dup  end
```

size は狙いどおり 3,155,484 (inline 比 −49.7% = out-line の削減量の 87%)。
しかし **wall は改善しない** (暫定値で inline 12773 に対し hybrid 15627)。

仮説「dup サイトの多くは Int/Bool を見るので奇数判定で素通りする」が**外れ**
だった。perceus のプランナは「ヒープかもしれない値」にだけ guard を置くので、
実行時に見る値はヒープポインタが多数派である。その場合 hybrid は
「奇数判定 → call → helper 内で同じ奇数判定をもう一度 → 本体」となり、
out-line より1回分多く働く。**32% の wall は無駄な scalar 素通りに対する
call ではなく、実際に rc を触る仕事に対する call overhead そのもの**なので、
前段フィルタでは救済できない。

さらに hybrid tree は all-RC bootstrap で落ちる (後述の潜在バグ)。仮に wall が
良くても、採用すれば main を「落ちる形状」に固定することになるので選べない。

### 潜在バグが #1262 の作業そのものを止めている

このセッション中、同じ潜在バグ (`__rt_rc_alloc` ← `__rt_arr_new` の OOB) が
**source 形状ごとに出たり消えたり**した:

| source 形状 | all-RC bootstrap |
| --- | --- |
| `d9588da9` | FAIL |
| `89a052b9` | FAIL |
| `0f0ad63c` (現行 main) | **PASS** |
| out-line 無効化 (A/B 用) | **PASS** |
| hybrid | **FAIL** |

実務上の影響: RC codegen を触る A/B は、変更のたびに 1/2 程度の確率で
ビルドか計測ができなくなる。今日だけで RC ビルド失敗 2回、計測汚染 2回、
迂回路 (bump stage1 → RC stage2) 1回。

**加えて `scripts/selfcompile_kpi.sh` はコンパイル失敗を「測定値なし」として
静かに落とす** (`set -euo pipefail` で node の非ゼロ終了時に即 exit し、
node の stderr はどこにも残らない)。実際にこれで誤った数字を2回提示しかけた。
計測ループを書くときは、空の測定値を成功として扱わないこと。

**結論: out-line を維持するか revert するかの意思決定は、潜在バグを特定する
までできない。** wall のレバーを探すには RC バイナリを作って測る作業が必須で、
その足場が壊れているため。

### 初めて手に入った、計装可能な再現

これまで落ちるのは**常に seed 製の stage1** で、source 側の runtime 計装が
届かなかった (前節)。今回の hybrid で条件が変わった:

- `_build/hy_bump/stage2.wasm` (私がソースからビルドできる bump コンパイラ)
- が出力した `_build/ab_hybrid_stage2.wasm` (RC コンパイラ) が
- **`lib/@vibe/compiler/tests/codegen_lexer_test.vibe` 1ファイルのコンパイルで落ちる**

落ちる入力が 4.4MB の flat source ではなく単一テストファイルなので、
入力側の絞り込みも現実的になる。**hybrid patch + poison 計装で bump を
ビルドし直せば、落ちるバイナリの runtime に計装が入る** — これが
poison / quarantine を実際に機能させる条件である。

## Implementation notes (2026-08-04 続き, #1262) — 潜在バグ: bin は無罪、legacy free list が壊れている

### ようやく「計装が落ちるバイナリに入った」状態で測れた

前回は計装が seed 製 stage1 に届かず結論を撤回した。今回は届いた:

```
計装なし (ab_hybrid_stage2)  + main ソース  -> CRASH
計装入り (inst_rc)           + main ソース  -> CRASH   <- 計装が効いている
```

**対照の取り方に注意**: `codegen_lexer_test.vibe` は**作業ツリーの `lib/` を
そのままコンパイル対象に引き込む**。patch を当てたまま両方を走らせると
「計装済みソースをコンパイル」同士の比較になり、変数が2つ動く。実際に
一度これで「計装するとバグが隠れる」と誤読した。`lib/` を main に戻してから
対照を取ること。

### 確定した除外

| 検証 | 結果 |
| --- | --- |
| poison 二重解放トラップ (free push 全経路の先頭) | **発火せず** |
| bin 払い出しのサイズ検査 | **発火せず** |
| ダンプから 32 本の bin チェーンを全検証 | **全て健全** (循環なし / heap 内 / size 一致) |

さらに **`__rt_arr_new` は 84 バイトを要求する**。`84 & 7 = 4` なので
`gen_rc_alloc_body` の bin 経路は**条件で弾かれ、legacy walk へ直行する**。

**したがって: 二重解放ではなく、bin 破損でもなく、legacy free list
(global 2) のリンクが壊れている。**

### 再現条件 (これも確定)

- **コールドキャッシュ必須**: `VIBE_BUILD_CACHE_DIR` を毎回まっさらにする。
  温かい永続キャッシュだと同じバイナリ・同じ入力でも落ちない (仕事量が
  激減するため)。
- **重い入力必須**: `codegen_lexer_test.vibe` は落ちるが `fixtures/hello.vibe`
  は落ちない。入力の最小化は「コンパイラ本体を引き込む重さ」が必要条件
  なので、劇的には縮まらない。

### メモリダンプの限界

`VIBE_DEBUG708_MEMDUMP` で 830 MB のダンプは取れる (摂動ゼロ)。しかし
**heap をヘッダで線形走査することはできない** — 文字列/バイト列は
fat pointer `(offset<<32)|length` が指す**ヘッダなしの raw 領域**なので、
heap は「ヘッダ付きブロックの連続」ではない。実際 heap_start から 1 ブロック
進んだだけで `alloc_size=0` + `lib/@vibe/compiler/tests/cod...` という
文字列データに当たる。オフラインでのブロック列挙は原理的に不可。

### 次の一手: global 2 を export する

> **追記 (#1416)**: この export は最終的に **codegen には入れなかった**。
> 全 RC モジュールに 16 バイト恒久課金になり、`scripts/size_ratchet.sh` の
> +2% ラチェットを小さいサンプル (`fib` 780 -> 801) で割ってしまう。
> `scripts/rc_add_freelist_export.py` で**完成済みバイナリに後付けする**方が
> 用途にも合っている (調査中のレイアウト依存の再現をそのまま保てる)。


必要なのは**クラッシュ時の global 2 (legacy free list head) の値**。wasm の
global は linear memory にないのでダンプに映らない。

最小摂動の取り方は **free list の global を wasm の export に加える**こと
(`__heap_ptr` が既にそうなっている)。**export エントリが 1 つ増えるだけで
命令列は変わらない**ので、これまでの計装 (命令を挿入する) より摂動が
小さく、発現条件を壊しにくい。runner は既に
`instance.exports.__heap_ptr` を読んでいるので同じ経路で拾える。

global 2 が取れれば、ダンプ上でリンクを辿って「どこで heap 外へ飛ぶか」
「その値が何に見えるか (タグ付き整数 / 文字列長 / rc ワード)」まで
一気に絞れる。**壊れ方の形から書き込み元を推定する**のが、計装で関数名が
取れない以上の残された筋である。

### 手元に残してある再現資材

- `_build/ab_hybrid_stage2.wasm` — 落ちる RC コンパイラ (計装なし)
- `_build/inst_rc.wasm` — 落ちる RC コンパイラ (poison 計装入り)
- `_build/hy_bump/stage2.wasm`, `_build/inst_bump/stage2.wasm` — 上記を出力した bump コンパイラ
- `git stash@{0}` "poison+hybrid instrumentation" — 計装 + hybrid patch

## 実装メモ (#1262): 潜在バグの正体 — free list に「ブロックでないポインタ」が乗っている

前節の「次の一手」(global 2 を export) を実行した結果、**壊れ方の形が取れた**。
結論から言うと、二重解放でも bin 破損でもリンクの +1 ずれでもなく、
**free list 上のメモリが生きているコードから書き込まれている**
(= premature free / use-after-free) である。

### 取り方: 完成済みバイナリへのバイナリパッチ

source に export を足して再ビルドすると **発現しなくなった**
(`_build/fl_rc.wasm` はクラッシュしない)。この再現はレイアウトに敏感なので、
ソースを触る限りどんな小さな変更でも消える可能性がある。

そこで **既にクラッシュすることが分かっているバイナリの export セクションだけを
バイナリ書き換えする**ことにした
(`scripts/rc_add_freelist_export.py`, 16 バイト増える export エントリ 1 個)。
wasm の**コードは linear memory の外**にあるので、
export セクションを足しても **guest の heap レイアウトも命令列も一切変わらない**。
実際 `_build/inst_rc_fl.wasm` は `_build/inst_rc.wasm` と同じ場所で同じ
`heap_ptr=830559036` を出して落ちる。

> 一般化: **完成済み wasm のコードセクションを弄る計装は heap 中立**である。
> これまで「計装するとクラッシュが逃げる」と言っていたのは、ソースを直すと
> *コンパイラ自身が生成する出力* が変わり、コンパイラ自身の確保量が動く
> ためだった。バイナリ後付けにはその経路がない。

### 観測 (`VIBE_RC_FL_WINDOW=1`)

```
__rc_freelist head=830508928
  fl[0] p=830508928 size=1073741960 next=830536808
  fl[1] p=830536808 size=2          next=233700655
  fl[2] p=233700655 size=544499052  next=543384946   <- low3=7 (奇数)
  fl[3] p=543384946 size=103        next=1768685568
  -> OUT OF HEAP at node 4: p=1768685568 (0x696c0000)
```

各ノードの周辺 96 バイトを見ると、**どれもブロックヘッダではなく生きた
ペイロード**だった。

- `fl[0]` の直前 24 バイトは **wasm バイトコード**:
  `20 08 | 37 03 18 | 20 05 | 42 08 | 7c | 42 01 | 84 | 21 09 | 20 04 | a7 ...`
  = `local.get 8; i64.store 3 24; local.get 5; i64.const 8; i64.add;
  i64.const 1; i64.xor; local.set 9; local.get 4; i32.wrap_i64; ...`
  → **codegen の出力バッファ (`Bytes`) の中身**。
- `fl[1]` の周辺は `(offset<<32)|length` の **String fat pointer の配列**:
  `(0x0dedfd2f<<32)|2`, `(0x050007f7<<32)|84`, `(0x457e<<32)|5` …
  `fl[1]` の "next" 233700655 は、この要素の**上位ワード (= 文字列 offset)**
  をリンクとして読んでしまったもの。
- `fl[2]` は **vibe のソーステキスト**
  (`, end: Int) -> Bool {\n  let rec go: (Int, Int, Bool) -> Bool = ...`)。
- `fl[3]` は **パス文字列**
  (`lib/@vibe/compiler/codegen/wasm_emit/index.vpkg`)。
- 最後に飛ぶ先 `0x696c0000` はバイト列 `00 00 6c 69` = `"li"`
  (`lib/...` の途中) で、**完全に文字列データの中**。

### そこから言えること

push は `store(p-4, head); head = p` なので、健全なら
**どのノードの `next` も「以前の head」= 4 の倍数のヒープポインタ**になる。
ところが `fl[1].next` は**奇数** (233700655)。push が書ける値ではない。
つまり `fl[1]-4` は **push の後に別の何かが上書きした**。上書きした値は
その場所にある String fat pointer の上位ワードそのものだった。

同じく `fl[0]` の `size` (`p-8`) は `0x40000088` で、alloc_size として
あり得ない。`p-8` は **生きたデータ**である。

→ **free list に乗っているメモリが、生きているコードから通常の書き込みを
受けている**。これは「二重解放」でも「dup がリンクを +1 する」でもなく、
**まだ参照が残っているブロックを解放している** (premature free) の症状である。

### なぜ今までの計装で捕まらなかったか

- **size-word poison** は「解放済みブロックの dup / drop」を捕まえる計装
  だった。premature free の後に起きるのは **ただの読み書き**なので、
  poison は原理的に発火しない。
- **bin チェーンが常に健全**だったのも整合する。壊れたポインタは
  `size & 7 == 0 && (size-16) <u 249` をまず満たさないので legacy 側に落ちる。
- **`__rt_arr_new` (fn 22) → `__rt_rc_alloc` (fn 63) で落ちる**理由も
  これで説明がつく。arr_new は 84 バイト (`84 & 7 = 4`) を要求するので
  bin 経路を必ずスキップし、**legacy list を最も頻繁に歩く呼び出し元**に
  なる。壊れたリンクを踏むのが常に arr_new なのは偶然ではない。

クラッシュ時のスタック (name section から復元):

```
[63]   __rt_rc_alloc          <- trap
[22]   __rt_arr_new
[1959] expr_uses_builtin ... codegen/wasi/linked_helpers.vibe
[2030] compile_wasi_module_impl ... codegen/wasi/wasi.vibe
[3371] compile_source_for_rc_flag
```

### free list へ push する 4 箇所

| 箇所 | 何を push するか | bin 経路 |
| --- | --- | --- |
| `gen_rc_drop_body` → `emit_rc_free_push` (bodies_core_a1a2) | rc が 0 になったブロック / array の grown data buffer | あり |
| `gen_arr_push_body` (bodies_core_a1b:306) | 旧 data buffer (`data_ptr != vptr+12` のとき) | **なし** (legacy 直行) |
| `gen_arr_append_body` (bodies_core_a2:1305) | 同上 | **なし** |
| `emit_rc_drop_local` (compile_expr_tail:849) | rc が 0 になったブロック (インライン drop) | **なし**、かつ**フィールドの再帰 drop もしない** |

後ろ 3 つは bin ルーティングを通らないので、8 の倍数で 16..264 のサイズも
legacy list に乗る (健全な走査でも size=136/264 が legacy に見えたのは
これが理由で、それ自体はバグではない)。

`compile_expr_tail:849` の `emit_rc_drop_local` はさらに、rc が 0 になった
ブロックを**フィールドを再帰 drop せずに**そのまま push する。これは
リークであって破壊ではないが、`gen_rc_drop_body` と挙動が食い違う経路が
存在すること自体は次の調査の当たり所である。

### Bytes と Array の非対称 (関連する既知の穴)

- **Array** の data buffer は「`vptr+12` のインライン」か
  「`vibe_rc_alloc` で確保したヘッダ付きブロック」のどちらか、という不変条件を
  持つ (`gen_arr_push_body` / `gen_arr_append_body` / `gen_rc_drop_body` の
  class 5 経路が全部この前提で `data_ptr != vptr+12` を見て解放する)。
- **Bytes** はそうではない。`gen_bytes_new_body` は 76 バイトの **raw bump**
  (ヘッダなし)、`gen_bytes_push_body` / `gen_bytes_append_body` の grow も
  **raw bump のまま**で、旧バッファを解放しない (リークするが安全)。

Bytes 値は偶数 (raw アドレス) なので rc_drop は触らない — 現状この非対称
自体はクラッシュ源ではない。ただし `data_ptr` を持つ 3 ワードのレイアウト
(`[cap@0][len@4][data_ptr@8]`) が Array と Bytes で共通なので、
**型取り違えが 1 回起きれば即座に「ヘッダなしポインタの解放」になる**
構造になっている点は記録しておく。

### 次の一手

「どこで premature free しているか」を出す必要がある。free list に乗った
ブロックが**書き換わったこと**を検出できればよいので、
**完成済みバイナリのコードセクションを後付けパッチ**する路線が使える
(heap 中立が確認できたので、これまでのような「計装で逃げる」問題がない):

1. `__rt_rc_alloc` の legacy 走査に「`cur` が heap 範囲外なら即 trap」を
   挿入し、**壊れたリンクを踏んだ最初の瞬間**で止める。今は 4 ノード先まで
   歩いてから飛んでいるので、head に近い側の履歴が失われている。
2. push 側 (`emit_rc_free_push` 相当のコード列) に「push 時の
   `p-8` を別領域に記録」を入れ、クラッシュ時にホストから読む。
   書き込み先は heap ではなく `rc_bins_base` 手前の reserve 帯を使えば
   bump ポインタを動かさずに済む。

どちらも wasm バイナリ後付けなので、`_build/inst_rc.wasm` の
発現条件をそのまま保てる。

## 実装メモ (#1262): 再現を 830 MB → 1 KB に縮めた + 発生箇所の絞り込み

前節の「次の一手」(バイナリ後付けで `__rt_rc_alloc` に free list head の
健全性チェックを挿す) を実行した。結果、**発現が `fixtures/hello.vibe` で
数秒・heap 1 KB 地点まで縮んだ**。

### 使った計装 (すべてバイナリ後付け = heap 中立)

`scripts/rc_patch_freelist_assert.py` の 3 モード。いずれも完成済み wasm の
コードセクションを書き換えるだけなので、guest の heap レイアウトは不変。

| モード | 挿す先 | 内容 |
| --- | --- | --- |
| head assert (既定) | 任意の関数 | 入口で `global 2` が「heap 内・size が 16..64MiB・`head-8+size <= global0`」を満たさなければ `unreachable` |
| drop assert (`__rt_rc_drop`) | `__rt_rc_drop` | 入口で引数のブロックヘッダが健全かを検査 |
| watchpoint (`VIBE_RC_WATCH_ADDR`) | 任意の関数 | 固定アドレスの i32 が期待値でなくなったら `unreachable` |

`unreachable` は natural な "memory access out of bounds" と区別がつくうえ、
**メモリを一切書かない**ので発現条件を壊さない。

### 得られた事実

1. **普遍的かつ早期**。`fixtures/hello.vibe` でも
   `lib/@vibe/compiler/tests/codegen_lexer_test.vibe` でも、
   **同じ場所** (`heap_ptr` ≈ 59.8–60 KB、heap 使用量 1 KB 程度) で発火する。
   830 MB まで走らせる必要はもうない。
2. **`__rt_rc_drop` 入口のヘッダ検査は一度も発火しない**。
   → drop に渡ってくるブロックのヘッダは、その時点では健全。
3. 上向きに二分すると、**`resolution_env_seed()`
   (`lib/@vibe/compiler/core/module_graph_path.vibe:415`) から戻った直後**が
   境界。`persistent_cache_version_tag()` / `resolution_env_seed()` の入口検査は
   通り、`cache_persistent_source_group_cache_path` の入口検査で落ちる。
4. `__rt_*` 86 関数 + `module_graph_path.vibe` の全関数に固定アドレス
   watchpoint (59248) を仕掛けても、**どの入口も 0 か 84 しか見ない**。
   最初に壊れた値を見るのは `cache_persistent_source_group_cache_path` の入口。
   → 書き込みは **`__rt_rc_drop` の内部**、しかも**最後の再帰呼び出しより後**
   (再帰の入口も watch 済みなので) に起きている。

### 壊れているもの

`resolution_env_seed` の emit 済み wasm を逆アセンブルすると末尾はこう:

```
20 01          local.get 1        ; roots
10 3e          call 62            ; __rt_rc_drop
0b             end
```

`roots` は `external_lib_roots()` が返す `Array[String]`。free list に乗る
ブロックはこれで、中身は

```
vptr    = 59256   block = 59248
cap@+0  = 8   len@+4 = 1   data_ptr@+8 = 59268 (= vptr+12, インライン)
elem[0] = (59332 << 32) | 15    ; String fat pointer, 15 文字
size@block+0 = 0x40000054        ; 84 の byte+3 が 0x40 ('@') に化けている
next@block+4 = 0                 ; push が書いた値 (リストは空だった)
```

15 文字 = `/root/.vibe/lib` の長さと一致する。周辺には `"/root"` と
15 文字の fingerprint `"0374c95819df7e6"` が並んでいる。

`0x40000054` は **`84` の上位バイトだけが `0x40` に化けた形**でもあり、
**`0x40000055` (class=0x40, rc=0x55) を 1 減らした形**でもある。どちらの
読みが正しいかで犯人が変わる:

- 前者なら「free list 上のブロックのサイズワードに 1 バイト書かれた」
- 後者なら「**59252 を value pointer とみなした rc デクリメント**」
  — つまりブロック境界が 4 バイトずれた別解釈が存在している

### 次の一手

watchpoint は「入口」にしか置けないので、**ストア命令の粒度**が要る。
`__rt_rc_drop` の本体を逆アセンブルし、`i32.store` / `i32.store8` の
直前に watchpoint 相当のチェックを挿入する (同じバイナリ後付けで可能)。
これで 0x40000054 を書く命令そのものが特定できる。

補助的に、`59248` が `84` になった瞬間 (= ブロック確保時) を
`__rt_arr_new` 側の watchpoint で確認すれば、上の 2 択も決まる。

### 現状の再現手順 (数秒)

```bash
python3 scripts/rc_add_freelist_export.py  _build/inst_rc.wasm    _build/inst_rc_fl.wasm
python3 scripts/rc_patch_freelist_assert.py _build/inst_rc_fl.wasm _build/inst_rc_assert.wasm
D=$(mktemp -d); mkdir -p $D/cache
VIBE_RC_FL_WINDOW=1 VIBE_PREOPEN_DIR=$PWD VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  VIBE_BUILD_CACHE_DIR=$D/cache \
  node scripts/wasm_vibe_host_runner.js --invoke cli_main \
  _build/inst_rc_assert.wasm fixtures/hello.vibe $D/out.wasm __no_entry__
```

## 訂正 (#1262): 直前2節の「premature free」「1 KB 再現」は **poison マーカーの誤検出**

`_build/inst_rc.wasm` は **size-word poison 計装ツリー**
(`git stash` "poison+hybrid instrumentation") から作ったバイナリで、
`rc_poison_bit() = 1073741824 = 0x40000000` を**解放時に size ワードへ OR
する**。したがって:

```
0x40000054 = 84  | poison     <- 84 バイトブロックの正常な解放マーカー
0x40000088 = 136 | poison     <- 136 バイトブロックの正常な解放マーカー
```

つまり `__rt_rc_alloc` に入れた「size が 16..64MiB か」というアサートは、
**最初の正常な解放で必ず落ちる**。以下は撤回する:

- ❌ 「`fl[0]` が codegen の出力バッファを指している」
  → `fl[0]` は size 136 の**健全な**解放済みブロックだった。手前の wasm
  バイトコードは隣接する別オブジェクトで、ヘッダ境界の読み違い。
- ❌ 「free list 上のメモリが生きたコードから書かれている (premature free)」
  → 主要な根拠が poison マーカーだったので、**未確認に戻す**。
- ❌ 「`fixtures/hello.vibe` で heap 1 KB 地点に縮んだ」
  → poison を masking すると `hello.vibe` は**素通りする**。1 KB 再現は消滅。
- ❌ 「`resolution_env_seed` / `external_lib_roots` が犯人」
  → 上と同じ理由で無効。あれは「最初に解放される任意のブロック」だった。

`scripts/rc_patch_freelist_assert.py` に `VIBE_RC_POISON_MASK` を足して
size を読む前に poison を落とすようにした (runner 側の表示も同様)。
**poison ツリー由来のバイナリを計装するときは必ず指定すること。**

### masking 後に残った本物の異常

`VIBE_RC_POISON_MASK=1073741824` で走らせ直すと:

- `fixtures/hello.vibe` — **通る** (発火しない)
- `codegen_lexer_test.vibe` — 発火する。ただし場所は heap 805 MB 地点

```
heap_ptr=805386044   memory_size=815398912
__rc_freelist head=805386036
  fl[0] p=805386036 low3=4 size=0     next=805317976   <- 異常
  fl[1] p=805317976 low3=0 size=4104  next=805289996   <- 健全
  fl[2] p=805289996 low3=4 size=264   next=805300928   <- 健全
  ...
  8016 nodes walked -> clean (terminated at 0)
```

**8016 ノードのチェーンは完走し、0 で正しく終端する。壊れているのは head 1
ノードだけで、その `alloc_size` が `0`。** 周辺 96 バイトはヘッダと next 以外
すべてゼロ:

```
805386028: 00 00 00 40   <- size ワード = poison | 0
805386032: 58 2d 00 30   <- next = 805317976 (正しい直前 head)
805386036: 1c 02 00 00   <- p (payload 先頭) = 540
```

`p = heap_ptr - 8` なので、このブロックは `[805386028, 805386044)` の 16 バイト、
**bump フロンティア直下**。poison が立っているので確かに解放されている。

### そこから言えること (確定分)

`__rt_rc_alloc` の **bump 経路は size ワードを書かない** — 書くのは呼び出し側
(`gen_arr_new_body` の `store(block+0, 84)` など)。free-list hit 経路も
書かない (既に入っている前提)。よって **`alloc_size == 0` のブロックが free
list に乗っているということは、rc_alloc の呼び出し側のどこかが
ヘッダを書いていない**。

影響:

- exact-fit 検索に永久にヒットしないので **そのブロックはリークする**
- より悪いのは、ヘッダを書いていないなら **class バイト (`block+7`) も未初期化**
  だということ。`gen_rc_drop_body` は `load8(vptr-1)` で class を読んで
  再帰 drop の経路を決めるので、**ゴミの class を踏むとフィールドとして
  無関係なワードを辿る**。元の OOB の候補経路として筋が通る。

トラップ時のスタック (この size 0 ブロックを踏んだ alloc):

```
[63]   __rt_rc_alloc            <- assert
[558]  struct_field_candidates ... codegen/common_base/common_base.vibe
[1463] compile_expr_tail4
[1464] compile_expr_tail3
[1465] compile_expr_tail2
[1488] compile_expr_tail
```

### 次の一手

`vibe_rc_alloc` を呼んでいる箇所を全部洗い、直後に
`store(block+0, size)` と class バイトを書いているか確認する。
書いていない呼び出し側が見つかれば、それが size 0 ブロックの出所。

`emit_rc_free_push` / `gen_rc_drop_body` 側に「size が 0 なら trap」の
アサートを**バイナリ後付けで**入れれば、push した瞬間まで遡れる。

### 教訓

**計装ツリー由来のバイナリを別の計装で調べるときは、先に「そのバイナリが
既に何を書き換えているか」を確認する。** 今回は同じ #1262 の中で自分が
仕込んだ poison を、別の実験で「破損」として読んでしまった。
`_build/*.wasm` の由来は `git stash list` と突き合わせること。

## 根本原因 (#1262): ref cell 契約の片側だけが条件付きだった

`docs` 上で長く「潜在 RC/allocator バグ」と呼んでいたものの正体。
**RC 管理でない (ヘッダなしの) box を、クロージャ側が RC オブジェクトとして
扱っていた。**

### 壊れていた契約

`compile_expr_tail.vibe` の ELetMut ref-cell 経路:

```vibe
if mut_needs_ref_cell(body, name) {
  Array::push(ctx.ref_cell_names, name)        // ← 無条件
  if ctx.enable_rc && rc_alloc_idx >= 0 && rc_drop_idx >= 0
     && expr_is_intish(value, local_names, ctx) {   // ← 条件付き
    // rc_alloc(16) + [alloc_size@0][rc@4|class8@7][payload@8]
  } else {
    // global0 を 8 だけ生バンプ。ヘッダなし。
  }
}
```

一方 `compile_lambda.vibe:658` は **`ref_cell_names` だけ**を見て
「RC が所有する capture」として扱う:

```vibe
if ctx.enable_rc && array_contains_str(ctx.ref_cell_names, cap_name) {
  // capture slot に odd タグ付きで格納
  emit_rc_word_inc_saturating(buf, () -> { ... cap - 4 ... })
  // → クロージャの class-7 drop が __rt_rc_drop を呼ぶ
}
```

**`expr_is_intish` が false のとき、この 2 つが食い違う。**

`expr_is_intish` は tag 6 (EUnaryOp) では `op == "!"` しか true にしない
(`compile_expr_tail.vibe:777`)。つまり **`let mut i = -1` で十分に外れる**
(`-1` は `EUnaryOp("-", EInt(1))`)。`""` / `None` / 関数呼び出しの初期値も同様。

### 何が起きるか

1. `emit_rc_word_inc_saturating(box - 4)` が、**box の手前にある無関係な
   オブジェクトの 4 バイトをインクリメントする**
2. クロージャが drop されると class-7 再帰が `__rt_rc_drop(box|1)` を呼ぶ。
   `__rt_rc_drop` は存在しないヘッダを読む — `class = load8(box-1)` は
   ゴミ、`alloc_size = load(box-8)` もゴミ
3. rc が 0 とみなされると `emit_rc_free_push` が **ヘッダなしポインタを
   free list に積む**
4. 後続の `__rt_rc_alloc` の legacy 走査がそのワイルドなリンクを辿って
   `memory access out of bounds` — これが長年の「all-RC bootstrap の OOB」

### 決定的な観測

`__rt_rc_drop` の入口に「`alloc_size == 0` なら trap」をバイナリ後付けで挿入
(`scripts/rc_patch_freelist_assert.py`, `VIBE_RC_ASSERT_SIZE0_ONLY=1`):

```
RuntimeError: unreachable
  at __rt_rc_drop                      <- 再帰呼び出し (capture)
  at __rt_rc_drop                      <- クロージャ本体の drop
  at emit_rc_word_inc_saturating ... codegen/common_base/common_base.vibe
  at compile_lambda ... codegen/expr/compile_lambda.vibe
```

`compile_lambda` の `let mut __cap_resolve = -1` がまさにこの形。
クラッシュ時の数値も一致する:

```
value = 805386036,  global0 = 805386044   -> 差は 8 = ヘッダなし box そのもの
value+0 = 540 (= tagged Int 270)          -> let mut int のペイロード
value-8 = 0                               -> ヘッダは存在しない
```

### 修正

`expr_is_intish` の条件を落とし、**RC のときは捕捉された `let mut` を必ず
ヘッダ付き RC セルにする**。class 8 はペイロードを drop しないので、
ヒープのペイロードは「解放される」のではなく「リークする」— use-after-free
にはならない。破壊よりリークを取る。

### A/B (計装なし・poison なしの現行 main 由来ビルド、`codegen_lexer_test.vibe`)

| | size-0 アサート | 結果 |
| --- | --- | --- |
| 修正前 | **発火** (`__rt_rc_drop` 再帰、`emit_rc_word_inc_saturating` 経由) | exit 1 |
| 修正後 | 発火せず | **exit 0 / 完走** |

- `pkf run test`: 87/87 ok
- all-RC bootstrap: 完走し、**`fix_rc.wasm` と stage3 が sha256 一致 (fixpoint)**
  `8efad2f3791a61557535cef693394a076a5cb532e228489e13f189cc8f5a5113`
  (ただし修正前の main もこの経路自体は完走するので、これは判別材料ではない)

### 影響範囲

RC は**ユーザプログラムの既定**なので、これはセルフホストだけの話ではない。
**クロージャに捕捉された `let mut` の初期値が intish でない**プログラム
(`let mut i = -1`, `let mut acc = ""`, `let mut found = None` など) は
どれも RC でヒープを壊していた。

## #1262: 修正の検証と out-line 化の再計測

### 元の OOB が消えた (計装なし・素の実行)

`scripts/selfcompile_kpi.sh` と同じ呼び出し
(`VIBE_FS_COMPILE=1 VIBE_WASM_MEMORY_STATS=1`, コールドキャッシュ,
入力 `lib/@vibe/compiler/tests/codegen_lexer_test.vibe`):

```
修正前 RC コンパイラ: exit=1  heap_ptr=829998372  memory access out of bounds
修正後 RC コンパイラ: exit=0  out=2317628 bytes
```

**バイナリパッチも poison も入れていない素の実行**で、長年の OOB が
再現しなくなった。ref cell のヘッダ欠落が原因だったことの直接の裏付け。

(この失敗のせいで KPI lane は修正前のビルドで何も出力しなかった。
`selfcompile_kpi.sh` は `set -euo pipefail` で node の失敗時に黙って
終了するので、「測定値が空」を「速い」と読み違えないこと。)

### out-line 化の再計測 (修正後ツリー、7 ラウンド交互計測)

inline 版は `emit_rc_dup_guarded` を強制的に `emit_rc_dup_inline` へ
落として 1 世代ビルドしたもの (計測後にソースは戻した)。

| 形 | wall median (ms) | rc/bump | RC コンパイラ size |
| --- | --- | --- | --- |
| bump | 4506 | 1.000 | — |
| **inline** | 9883 | **2.193** | 6,528,872 |
| **out-line** | 12567 | **2.789** | 2,934,258 |

- **out-line / inline wall = 1.272** — out-line 化は **27% 遅い**
- **inline / out-line size = 2.225** — out-line 化は **2.2 倍小さい**

### #1405 (out-line 化) の維持/revert 判断

**維持する。**

- 出口条件は wall ≤ 1.2。inline に戻しても **2.789 → 2.193** にしかならず、
  どちらも桁が違う。out-line 化は「1.2 に届かない原因」ではない。
- 一方 size は `bench_binary_size.sh` の **+2% ラチェット**が掛かっている。
  revert すると RC 出力が 2.2 倍になり、ラチェットは即座に落ちる。
  再ベースラインを切る理由が wall 21% では釣り合わない。
- したがって wall は**別のレバー**で取りに行く。

### 次のレバー候補

**site 選択式の out-line 化**。今は全 dup サイトを一律に out-line している
が、ホットな関数だけ inline に戻せば size の大半を保ったまま wall の 27% を
削れる。以前試して否定した「hybrid」(guard の形を変えて odd テストを 2 回
やる) とは別物で、これは**同じ 2 形をサイトごとに選ぶポリシー**の話。

判断材料は既にある: `__rt_rc_dup` の呼び出し回数は profile で取れるので、
呼び出し回数上位の関数だけ inline にする閾値を 1 つ持てばよい。

## #1262: site 選択式 out-line 化は「実装しない」— 実測してから判断した

「分岐を増やすこと自体が今回のバグ (ref cell の片側条件) を生む形なので、
**先に効果を実測してから有効化を判断する**」という方針で測った。結論は
**現時点では実装しない**。

### 測ったこと 1: dup コストの集中度

out-line 版 (`fix_rc.wasm`) の CPU プロファイル:

```
4195.5ms  38.5%  __rt_rc_dup      <- 単独で全 CPU の 4 割弱
 429.7ms   3.9%  __rt_arr_get
 356.1ms   3.3%  __rt_str_char_code_at
 289.0ms   2.7%  __rt_rc_alloc
```

`__rt_rc_dup` の self 時間を**呼び出し元関数ごと**に集計 (201 関数):

| 上位 K 呼び出し元 | dup 時間の割合 | 呼び出し元関数の割合 |
| --- | --- | --- |
| 1 (`mrv_fresh`) | 10.6% | 0.5% |
| 5 | 34.5% | 2.5% |
| 10 | 52.4% | 5.0% |
| 20 | 71.5% | 10.0% |
| 50 | 90.5% | 24.9% |

### 測ったこと 2: 静的な dup サイトの分布

`fix_rc.wasm` の code section を走査して `call __rt_rc_dup` を関数ごとに数えた
(合計 **52,742** サイト / 2,507 関数):

| 上位 K ホット関数 | 静的サイトの割合 |
| --- | --- |
| 5 | 7.2% |
| 10 | 8.9% |
| 20 | 16.0% |

ホット関数は巨大な再帰ウォーカで、サイトも多い (`check_expr` 2258,
`compile_call_core` 2144, `rewrite_expr` 698) が、それでも全体の 1/6 程度。

### 実測端点からの外挿

測定済みの端点: wall `12567 → 9883` (call overhead の総額 = **2684 ms**)、
size `2,934,258 → 6,528,872` (差 3,594,614 B / 52,742 サイト = **68.2 B/サイト**、
72 B の inline guard と ~5 B の call の差にぴたり一致)。

| 形 | wall (ms) | rc/bump | size | out-line 比 |
| --- | --- | --- | --- | --- |
| out-line (現状) | 12567 | 2.789 | 2,934,258 | 1.00x |
| 選択 top 5 | 11641 | 2.583 | 3,193,070 | 1.09x |
| 選択 top 10 | 11161 | 2.477 | 3,254,179 | 1.11x |
| 選択 top 20 | 10648 | 2.363 | 3,509,396 | 1.20x |
| 全 inline | 9883 | 2.193 | 6,528,872 | 2.23x |

top 20 で **wall −15% / size +20%**。カーブとしては悪くない。

### それでも実装しない理由

1. **出口条件に届かない**。2.789 → 2.363 で、目標の **1.2 には遠い**。
   さらに `__rt_rc_dup` は wall の 37.0%
   (4654 ms / 12567 ms) なので、**dup が完全にタダになっても
   rc/bump は 1.756 が天井**。つまり **1.2 は dup を安くする方向では原理的に
   届かない** — dup の *回数* を減らすしかない (Perceus の borrow / reuse 解析)。
2. **+20% の size は `bench_binary_size.sh` の +2% ラチェットを大きく超える**。
   再ベースラインを切る判断がいる。wall 15% ではその判断を正当化しづらい。
3. **新しい分岐を増やす**。ref cell のバグは「同じ契約を 2 箇所が別の述語で
   判定していた」ことが原因だった。

### ただし危険度は ref cell とは違う (記録として)

もし将来実装するなら、この分岐は ref cell より**構造的に安全**である:

- 判定は **`emit_rc_dup_guarded` 1 箇所だけ**。第二の消費者が別の述語で
  判定する余地がない (ref cell は `compile_expr_tail` が `expr_is_intish` で、
  `compile_lambda` が `ref_cell_names` で、別々に判定していた)。
- **2 つの arm は構成上まったく同じ意味**である。`gen_rc_dup_body` は
  `emit_rc_dup_inline` を local 0 で呼んで out-line 版の本体を作っているので、
  両者が意味的に食い違うことはあり得ない。
- 守るべき不変条件は #705 の「両 arm が `buf` をちょうど 1 回使う」だけで、
  これは既に 2 ヘルパへの分割で構造的に強制されている。

### 次に測るべきもの

`__rt_rc_dup` を安くするのではなく **呼ばれる回数を減らす**方向。
52,742 サイトが本当に必要かを Perceus 側 (borrow 推論 / reuse) から見る。
天井 1.756 を割るにはそれ以外に道がない。

## #1416 の CI で踏んだこと: `size_ratchet.sh` は release-check に入っていない

`pkf run release-check` はローカルで通ったのに CI の `compiler-gate` job が落ちた。
落ちたのは gate 本体 (88/88 通過) ではなく、その後に CI だけが走らせている
**`scripts/size_ratchet.sh`** (`bench/binary_size/*.vibe` の出力サイズを
`bench/perf/size_baseline.txt` に対して +2% で締めるラチェット)。

```
FAIL: fib         801 B (baseline 780, max 795)
FAIL: hello_world 837 B (baseline 816, max 832)
```

原因は `__rc_freelist` export で、**ちょうど 16 B/モジュール**だった
(export を剥がすと fib は 785 B で通る。残る +5 B は既存の main の累積ドリフト
で、この PR 由来ではない)。export は codegen から外し、
`scripts/rc_add_freelist_export.py` によるバイナリ後付けに一本化した。

**教訓**: codegen の出力サイズに触る変更は、`pkf run release-check` だけでは
検証しきれない。生成物のサイズを変えうる変更のときは

```bash
bash scripts/size_ratchet.sh <stage2.wasm>
```

を手で回すこと (CI は `_build/selfhost/generations/*/stage2.wasm` の最新を使う)。
