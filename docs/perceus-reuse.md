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

### 結論: seed 固有。out-line 化した RC コンパイラは fixpoint する

quarantine を戻した HEAD (poison は trap のみで意味論的に中立) で、
seed を介さない2段を回した:

```
final_bump/stage2.wasm  --VIBE_RC=1-->  F_stage1.wasm   2,645,681 B   PASS
F_stage1.wasm           --VIBE_RC=1-->  F_stage2.wasm   2,645,681 B   PASS
```

**F_stage1 と F_stage2 は同サイズ = fixpoint。** out-line 版 RC
コンパイラは自分自身を再生産できる。落ちるのは
`bootstrap/seed/compiler.wasm` が出力した stage1 だけである。

| stage1 を作ったコンパイラ | dup guard | サイズ | 結果 |
| --- | --- | --- | --- |
| seed | inline | 6,332,395 | **OOB** |
| 現行 (bump ビルド) | out-line | 2,645,681 | **PASS (fixpoint)** |

したがって #1262 の blocker は「out-line 化のバグ」でも「現行 RC/allocator
の潜在不整合」でもなく、**pin された seed が この source 形状を RC で
誤コンパイルする**という一点に還元される。対処は
[bootstrap.md](bootstrap.md) の bootstrap bump — seed を現行ビルドで
貼り替えれば all-RC bootstrap は通るはずである (未実施)。

`main` が all-RC で通るのは、seed がたまたま `main` の source 形状を
正しく扱えるからで、seed のバグが無いことの証明ではない。bisect が
「単一 site ではなく累積的」と出たのも、seed が踏む形状かどうかが
site 集合で変わるためと読める。

### 検証: seed を差し替えたら all-RC bootstrap が通った (fixpoint 一致)

seed をローカルで現行ビルド (`_build/final_bump/stage2.wasm`) へ adopt して
`VIBE_RC=1 scripts/generations.sh build --stage3` を回した (計装は撤去済み、
out-line 化だけの状態):

```
stage0 (差し替えた seed)   1,842,511 B
stage1                     2,644,914 B   OK
stage2                     2,644,652 B   OK
stage3                     2,644,652 B   OK
stage2 == stage3           byte-identical  = FIXPOINT
```

stage1/2/3 それぞれの sample 検証も通過。**旧 seed で必ず OOB していた
`stage1 -> stage2` が、seed を替えただけで通る。** source は1バイトも
変えていない。これで #1262 の blocker が seed 起因であることは確定した。

同時に、out-line 化の効果が all-RC 経路でそのまま出ることも確認できた:

| | bump stage2 | RC stage2 | 比 |
| --- | --- | --- | --- |
| inline guard (従来) | 1,841,905 | 6,213,090 | 3.37x |
| **out-line (本変更)** | 1,842,511 | **2,644,652** | **1.44x** |

seed の正式な bump は GitHub Release の publish を伴う ([bootstrap.md](bootstrap.md)
の手順) ため、この確認では `bootstrap/seed.json` は commit していない
(存在しない tag を pin すると全クローン/CI の `ensure_seed.sh` が失敗する)。

