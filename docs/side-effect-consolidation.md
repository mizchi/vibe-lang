# 副作用まわりの整理: 可変性の権限を1つの規則に畳む

> **位置づけ**: ADR ではない設計レビュー文書。
> [mutability-control-review.md](mutability-control-review.md) と
> [effect-taxonomy-review.md](effect-taxonomy-review.md) の続きで、
> 「同じことをするのに複数の状況がある」状態 —— `let mut` の可変性、
> #1262 の region 推論、`Map`/`ImmutMap`/`HashMap` の三重化 —— を
> **1つの規則に畳めるか**を、実測を取ってから判断する。
> 参考: [Verse 13. Effects](https://verselang.github.io/book/13_effects/)。
> Related: #1262, ADR-0017, ADR-0021, ADR-0052, ADR-0055, ADR-0060(superseded),
> ADR-0068, ADR-0071, ADR-0075, ADR-0082, ADR-0084, ADR-0088, ADR-0090,
> ADR-0091, ADR-0092。
> 計測スクリプト: [bench/bench_state_representation.vibe](../bench/bench_state_representation.vibe)

## 0. 結論(先出し)

1. **「FBIP があれば State effect で `let mut` と同じ速度が出るか」→ 出ない。**
   実測で3段に分かれる。(a) 現行の ADR-0092 Phase 1 reuse の利得は
   **ゼロか負**(適格形が非適格形より 1.6× 遅く、確保は 0 B/op から
   32 KB/op に**増える**)。(b) 仮に reuse が完璧でも、heap 常駐状態の
   下限は `struct mut` の **3.5×** で、そこで止まる。(c) State effect は
   すでに **7.6×**、つまり heap 常駐状態の下限の 2 倍強しか離れていない。
   残る 2× は**確保ではなく perform dispatch** なので、FBIP は原理的に
   効かない。→ §2

2. **「同じことをする複数の状況」の正体は、可変性が直交2軸を1語で
   語っていること。** 軸 A =「値が書き換わるか」、軸 B =「その書き換えが
   **宣言スコープの外から観測できるか**」。コストも権限も**軸 B だけ**で
   決まるのに、vibe が表面構文で語っているのは軸 A だけで、軸 B は
   codegen 内部の述語 `mut_needs_ref_cell` にしか存在しない。→ §3

3. **一貫規則の提案: 権限は軸 B に置く。**「外部参照を書き換えるには
   明確な権限が要る」を、`mut` かどうかではなく「**セルを作った者以外が
   その書き込みを観測できるか**」で切る。この境界は発明しなくてよい ——
   `mut_needs_ref_cell` を codegen から型へ引き上げるだけで、
   `let mut` / region / State effect / host capability が**1本の梯子**に
   並ぶ。→ §4

4. **コレクション命名は2軸を分離する。** 可変性は閉じた接頭辞集合
   {∅, `Mut`, `Frozen`} + `Builder` 接尾辞、実装/性能は接尾辞。今の
   `Hash-`/`Sorted-` は「可変」と「実装戦略」を同時に背負っていて、
   `ImmutMap` は規則の外にいる。→ §5

5. **最速の形は「状態が wasm local に載っていて RC が触らない形」**
   (0.74 ns/反復、local は個数を増やしても無料)。他の形との差は
   **その形固有のコストではなく、まだ書かれていない最適化の値段**。
   vibe には escape analysis も scalar replacement も unboxing も
   ユーザ関数 inline も無い。→ §2.7

6. **単一で最大の要因は RC の scalar 引数 dup。** top-level 関数呼び出しは
   引数が loop-borrowed local のときだけ RC で **6.4×**(1052 → 6750 ns)に
   なり、定数引数にすると RC=0 と RC=1 が**完全に一致する**(1390/1389)。
   逆アセンブルすると tagged immediate に対して out-of-line の
   `__rt_rc_dup` を毎回呼んでいる。**RC の呼び出しペナルティは 100% これ。**
   codegen が飛ばせないのは local slot の静的型を持っていないから。→ §2.8

7. **収斂は「表面の統一」ではなく「lowering の一点化」。** 非捕獲
   `let mut` と State effect は別の問題を解いているので表面は分けたまま、
   **escape しない状態はすべて wasm local に落とす**。surface の選択が
   性能を決めるのをやめさせる(今は `loop (s = (0,0))` と
   `loop (i = 0, acc = 0)` が意味は同じで 10–28× 違う)。→ §6

8. **#1262 の実装順(ADR-0092 → 0090 → 0091)は根拠が崩れた。**
   0092 を先頭に置いた理由は「RC default の wall ~1.6–2.1× に即効」
   だったが、実測は逆を示した。→ §7

---

## 1. 現状の棚卸し —— いま可変状態を書く方法

cheatsheet の "Choosing a mutation style" は5つ挙げる。実装の実体で並べ直すと、
**5つではなく3つ**しかない。

| 書き方 | 実体 | 軸A (書換) | 軸B (外部観測) | row |
|---|---|---|---|---|
| `let mut x`(非捕獲) | **wasm local** | ○ | **×** | 無し |
| `let mut x`(closure 捕獲) | heap ref cell (RC class-8) | ○ | ○ | 無し |
| `struct S { mut f }` | heap block + in-place 書込 | ○ | ○ | 無し |
| `Array` / `Bytes` | heap block + in-place 書込 | ○ | ○ | 無し |
| `XBuilder` → `freeze` | heap block、freeze で凍結 | ○ | ○(freeze まで) | 無し |
| `effect Mut`/`State` + `handle` | handler が持つセル | ○ | ○ | **有り** |
| `region r { }`(ADR-0090, 未実装) | arena セグメント | ○ | ○(region 内) | **有り** |

読み取れること:

- **`let mut` は1つの機能ではなく2つ**。非捕獲なら wasm local で、
  そもそも「可変状態」ですらない(誰も観測できない式レベルの都合)。
  捕獲された瞬間に heap セルになり、closure を通じて共有される。
  **同じ綴りで、コストも意味論も別物**。判定は codegen の単一述語
  `mut_needs_ref_cell`(`codegen/common_analysis/common_analysis.vibe`)。
- **row に現れるのは最後の2つだけ**。しかもその2つが「権限を明示する」
  という点で**すでに正しい形をしている**。問題は、同じ意味論を持つ
  上の4つが row に何も出さないこと。
- ADR-0060(`Write[r]` 統一)が停滞して supersede されたのは、
  **「すべての `mut` に row を課す」形だったから**で、これは正しい撤回
  だった。だが撤回と同時に「escape する `mut` にだけ課す」も一緒に
  捨ててしまった。ここが本文書の再提案点(§4)。

---

## 2. 実測: FBIP は State effect を `let mut` に近づけるか

### 2.1 方法

[bench/bench_state_representation.vibe](../bench/bench_state_representation.vibe)。
`state/*` は同じ `sum(0..999)` を**反復状態の持ち方だけ**変えた9形、
`fbip/*` は ADR-0092 Phase 1 reuse が**発火する形としない形**の A/B。

```bash
VIBE_RC=0 vibe bench bench/bench_state_representation.vibe --iters 400   # bump
VIBE_RC=1 vibe bench bench/bench_state_representation.vibe --iters 400   # Perceus RC + reuse
```

reuse が実際に emit されたかは、Phase 1 が出す uniqueness test の定数
(`i32.const 16777217` = `1 | class1<<24`)をコードセクションで数えて確認した
(`bytes_per_op` は bump ポインタの前進量なので、**in-place reuse と
exact-fit free list の再利用を区別しない** —— fixture 自身が冒頭で
そう断っている)。

> 計測環境: この開発コンテナ、node/viberun 経由、`--iters 400` の p50。
> `ns_p50` は runner の wall なのでノイズがある(繰り返しで ±3% 程度)。
> 以下で「差」と言うのは、繰り返し3回で符号が安定したものだけ。

### 2.2 反復状態の持ち方 (1000 反復 = 1 op)

| # | 形 | RC=0 p50 | ×base | B/op | RC=1 p50 | ×base | B/op |
|---|---|---|---|---|---|---|---|
| 1 | `let mut`(非捕獲) | 738 ns | **1.00** | 0 | 740 ns | **1.00** | 0 |
| 2 | `loop` パラメータ(scalar) | 738 | 1.00 | 0 | 741 | 1.00 | 0 |
| 3 | `struct { mut n }` | 2599 | 3.52 | 16 | 2605 | 3.52 | 24 |
| 7 | `let mut`(closure 捕獲) | 2794 | 3.79 | 24 | 3620 | 4.89 | 0 |
| 6 | **State effect + handler** | 5795 | **7.85** | 64 | 5599 | **7.57** | 96 |
| 4 | 値状態を毎回組み直す(inline) | 12410 | 16.8 | 24024 | 22179 | 30.0 | 0 |
| 5 | 同(step 関数、fusion 非適格) | 12929 | 17.5 | 24024 | 21128 | 28.6 | 0 |
| 9 | 同(**fusion 適格形**) | 12831 | 17.4 | 24024 | 34171 | 46.2 | **32032** |
| 8 | 値状態を全部生かす | 21823 | 29.6 | 40356 | 40836 | 55.2 | 32032 |

### 2.3 いちばん効いた観測: reuse は**適格形のほうが遅い**

#5 と #9 の**ソース差は `let s = s0` の一行だけ**(Phase 1 の適格条件が
ELet 束縛の scrutinee を要求するため)。仕事は完全に同じ。

| | RC=0 (fusion off) | RC=1 (fusion on) |
|---|---|---|
| #5 非適格 | 12929 ns / 24024 B | **21128 ns / 0 B** |
| #9 適格 | 12831 ns / 24024 B | **34171 ns / 32032 B** |

- **bump では差がない**(12929 vs 12831 = ノイズ内)。余計な `let` 自体は
  無コスト。
- **RC で fusion が入ると 1.62× 遅くなり、確保が 0 B/op → 32 KB/op に
  増える。** 3回繰り返しで p50 = 32977 / 34177 / 32254、符号は安定。
- 理由の説明: `step_fused(s)` の呼び出し側(loop)が `s` を保持したままなので
  実行時 `rc == 1` 判定は**毎回外れ**、shared フォールバック(payload dup +
  guarded release + 新規確保)に落ちる。しかもその確保は、非適格形が
  享受していた exact-fit free list の定常状態を壊す。
  **静的な適格性(構文形)と動的な一意性(所有権)が一致していない。**

### 2.4 FBIP の本丸(リスト map)でも利得ゼロ

Koka 系の正典ワークロード。`map_inc_fused` は Phase 1 の適格条件を全部満たし
(uniqueness test が1サイト emit されることを確認)、`map_inc_plain` は
scrutinee が引数なので発火しない。仕事は同一。

| 形 | RC=0 p50 / B | RC=1 p50 / B |
|---|---|---|
| `array_inplace`(可変配列で in-place) | 11831 / 16332 | 16452 / 8284 |
| `list_map_plain`(非適格) | 37334 / 48016 | 59897 / 32016 |
| `list_map_fused`(適格) | 36557 / 48016 | 60389 / 32016 |
| `list_map5_plain`(中間結果を名前で束縛しない×5) | 146889 / 144048 | 103102 / **0** |
| `list_map5_fused`(同、適格) | 150780 / 144048 | 104709 / **0** |

- **適格/非適格の差は ±1.6%** —— ノイズ帯(±3%)の中。
- **確保量は完全に同じ**。所有権が渡る `map5`(中間結果を名前に束縛しない)
  でさえ 0 B/op は**両方**で達成される —— やっているのは reuse ではなく
  **exact-fit free list の再利用**。
- 一方 `map5` は **RC のほうが bump より速い**(103 µs vs 147 µs)。
  確保が重いワークロードでは RC は既に勝っている。「RC は bump の
  1.6–2.1× 遅い」は**確保が軽いコードでの話**で、一般化してはいけない。

### 2.5 State effect はどこにいるか

| 比較 | 比 |
|---|---|
| State effect ÷ `let mut`(非捕獲) | 7.6–7.9× |
| State effect ÷ `struct mut`(heap 常駐状態の下限) | **2.15–2.23×** |
| State effect ÷ 捕獲された `let mut`(**同じ問題を解く形**) | **1.55–2.07×** |
| 値の付け替え(#4/#5) ÷ State effect | 2.1–4.0× |

**比較対象を間違えないこと。** 非捕獲 `let mut` は「呼び出し境界を越えて
状態を共有する」という問題を**解いていない**(誰も観測できないので)。
State effect が置き換えうるのは捕獲された `let mut` のほうで、そことの差は
**2× 前後、確保はほぼゼロ**(64–96 B/op の定数)。

この比が特に効くのは、**State effect 版の handler 自身が捕獲された
`let mut cell` を使っている**ため。つまり両辺が同じ heap ref cell コストを
払っており、差分は**effect 層だけ**になっている(確保量も 64–96 B/op の
定数で、反復ごとには増えない)。

そしてその 2× は **evidence dict 経由の perform dispatch** であって確保ではない。
FBIP は確保を減らす技術なので、**この 2× には原理的に効かない**。縮めたければ
tail-resumptive handler を呼び出し側に inline して `Get`/`Put` を直接の
local read/write に落とす —— メモリ最適化ではなく**ハンドラ inline**の話になる。

### 2.6 まとめ

```
1.00×  let mut (非捕獲)          ← wasm local。heap に一切触れない
3.5×   struct mut                ← heap 常駐状態の理論下限
3.8–4.9× let mut (捕獲)          ← 同じ下限帯。`mut` の綴りは関係ない
7.6–7.9× State effect            ← 下限の 2× 強。差は perform dispatch
17–46×  値の付け替え              ← FBIP の対象。現状の Phase 1 は利得ゼロ〜負
```

**`let mut` の 1.00× は `mut` キーワードの性質ではなく、
「捕獲されない scalar が wasm local に落ちる」という性質。**
捕獲された途端に 3.8–4.9× 帯へ落ちる。これが §3 の軸 B がコストを
決めているという主張の直接の証拠になっている。

---

## 2.7 「最速の形」の確認 —— 下限と、そこまでの差の分解

「収斂させる先」を決めるには、まず**最速の形が何か**と、
**他の形との差が何に払われているか**を確定する必要がある。
`floor/*` 群がそれを測る(すべて同じ仕事、置き場所だけが違う)。

| 形 | RC=0 p50 | RC=1 p50 | B/op |
|---|---|---|---|
| ループ骨格だけ(加算なし) | 388 ns | 388 ns | 0 |
| **`let mut` 2 個(= 最速)** | **738** | **740** | 0 |
| `let mut` 4 個 | 499 | 721 | 0 |
| top-level 関数呼び出し(定数引数) | 1390 | 1389 | 0 |
| top-level 関数呼び出し(loop-borrowed 引数) | 1052 | **6750** | 0 |
| closure 呼び出し | 2061 | 6072 | 0 |
| `struct` の mut フィールド 4 個 | 2719 | 2753 | 40/48 |
| `loop` パラメータをタプル 1 個に | 7900 | 21120 | 16016/0 |

読み取れること:

- **最速の形は「状態が wasm local に載っていて RC が触らない形」**。
  ループ骨格 0.39 ns/反復 + 加算 0.35 ns/反復 = 0.74 ns/反復で、
  ここはハードウェア下限。**local は個数を増やしても無料**
  (2 個も 4 個も同じ)。
- **`struct` の mut フィールドは、フィールド数を増やしてもほぼ同じ値段**
  (1 個 2604 ns / 4 個 2719 ns)。つまり払っているのはフィールドごとの
  コストではなく **heap ブロックという固定費**。この struct は関数の外へ
  一切出ないので、**scalar replacement があれば丸ごと消える**。
- **`loop (s = (0, 0))` は箱**(16 B/反復)。同じ意味の
  `loop (i = 0, acc = 0)` は local で 738 ns。**意味が同じで 10–28×**。
  これは surface の選択が性能を決めてしまっている一番わかりやすい例。
- **差はどれも「その形固有のコスト」ではなく、欠けている最適化の値段**。
  vibe には escape analysis も scalar replacement も unboxing も
  ユーザ関数の inline も無い(`grep` で確認: codegen の "inline" は
  builtin dispatch と `unbox_float` だけ)。

## 2.8 いちばん大きい単一要因: scalar 引数への `__rt_rc_dup`

上の表で一箇所だけ桁が違う。**top-level 関数呼び出しが、引数が
loop-borrowed な local のときだけ RC で 6.4× になる**(1052 → 6750)。
定数引数にすると **RC=0 と RC=1 が完全に一致する**(1390 / 1389)。

逆アセンブルすると理由がそのまま出ている。`add2(acc, i)` の呼び出し前に:

```wasm
local.get 2 / local.tee 4 / local.get 4 / call __rt_rc_dup   ; acc は Int
local.get 3 / local.tee 5 / local.get 5 / call __rt_rc_dup   ; i   は Int
i64.const 0 / call add2
```

**tagged immediate に対して out-of-line の `__rt_rc_dup` を2回呼んでいる。**
`Int` は 62-bit tagged なので dup は意味論的に no-op で、
`__rt_rc_dup` の中身もタグを見て即 return するだけ。それでも関数呼び出し1回分
(実測 **1 回あたり ~2.2–2.9 ns**)を毎回払う。

分離実測(committed bench の `floor/0` / `floor/2b` / `floor/2`。
3 者はループ骨格も呼び出し頻度も同じで、**call site の dup の有無だけ**が違う):

| ns/1000反復 | RC=0 | RC=1 | 差分の内訳 |
|---|---|---|---|
| `floor/0` 呼び出し無し | 388 | 388 | — |
| `floor/2b` 呼び出し1回、**dup 無し**(定数引数) | 1390 | **1389** | 呼び出し自体 = +1.0 ns/反復。**RC でも増えない** |
| `floor/2` 呼び出し1回、**scalar 引数 dup 2 個** | 1052 | **6750** | **dup = +5.4 ns/反復**(1 個 ~2.7 ns) |

(独立モジュールでも同じ: 404 / 1433 / 5919–7323。)

**RC の呼び出しペナルティは、100% が scalar への dup。** 呼び出し規約自体には
RC のコストが乗っていない。

なぜ codegen が飛ばせないかも、コードのすぐ隣に書いてある —— 
`compile_call.vibe` の `ts_known_int` の doc comment:

> Bare idents are deliberately excluded: **a per-slot "is int" log is unsound
> because slots are reused across scopes without updating it.**

つまり **codegen は local slot の静的型を持っていない**。checker は持っている。
これは §3 で述べる「`TypeEnv` の情報が codegen に届いていない」という
同じ欠落で、**権限規則と最大の性能改善が同じ配管を待っている**。

### #1262 への含意

issue 内の自前プロファイルは `__rt_rc_dup` を **単独で全 CPU の 38.5%**
(4195.5 ms)と記録している。その相当部分が scalar への no-op dup であるなら:

- **削減の形は「guard を inline する」ではなく「guard を消す」**。
  issue で検討・却下された site 選択式 out-line 化は
  「72 B の inline guard か ~5 B の call か」の二択だったが、
  **静的に scalar と分かる引数は 0 B**(コードを出さない)で済む。
  サイズは増えるどころか減る。
- 出口条件「RC/bump wall 比 ≤1.2×」に対して、FBIP より遥かに近い。
- 中間案として、型情報が届く前でも
  **タグ判定だけ inline し、slow path は out-line のまま残す**形が取れる。
  issue が測った 2 点(全 inline = 72 B/サイト / 全 out-line = ~5 B/サイト)の
  **間にある第三の点**。→ **実装して測った。次節。**

### 2.9 実装: タグ判定だけ inline にする(§6.2 の順1')

`emit_rc_dup_guarded` の out-of-line 側を、`local.get v; call __rt_rc_dup`
から次に差し替えた(`emit_rc_dup_tagtest_call`):

```wasm
local.get v; i64.const 1; i64.and; i32.wrap_i64
if (void)  local.get v; call __rt_rc_dup  end
```

`emit_rc_dup_inline` の**最初のテストと同じ判定**(`v & 1`: 奇数 =
heap 候補、偶数 = tagged immediate)を site 側に出し、heap 経路だけ
helper を呼ぶ。helper は入口で同じタグを再判定する(helper 自身が
`emit_rc_dup_inline` から生成されている)ので、**意味論は完全に不変** ——
`VIBE_RC=shadow` の再帰ガードも helper の中にそのまま残る。静的解析は
一切不要で、健全性は構成的に保証される。

**マイクロベンチ(決定的)**。同一バイナリ内の比で読む
(バイナリを跨ぐ絶対 ns はコード配置で ±15% 動くため):

| RC=1、min ns/1000反復 | 変更前 | 変更後 |
|---|---|---|
| `floor/2b` 呼び出しのみ(dup 無し) | 1341 | 1224 |
| `floor/2` 呼び出し + scalar dup 2 個 | 6077 | **2101** |
| **dup 1 個あたり** | **2.37 ns** | **0.44 ns** |
| `floor/2` ÷ `floor/2b` | 4.53× | **1.72×** |

3 回反復で `floor/2` min = 2101 / 2102 / 2101 —— バイナリ内のばらつきは無視できる。

**サイズ**: 2 サイトの probe で RC 出力 911 → 929 B = **+9 B/サイト**
(全 inline の +67 B/サイト に対して)。`VIBE_RC=0` の出力は 793 B で
**バイト単位で不変** —— 変更が RC 経路限定であることの裏付け。

**正しさ**: `rc_corpus_parity` **141/141 (RC worse: 0)**、
`rc_cutover_readiness` READY(全プログラムで parity + heap bounded)、
`pkf run test`(stage2==stage3 fixpoint)green。

**selfcompile ratio —— ここは決定的ではない**。同一セッション A/B
(`selfcompile_kpi_rc_lane.sh 5`、interleaved):

| 形 | paired_ratio | ペアごとの比の分布 |
|---|---|---|
| out-line call | 2.605 | 2.06 / 2.60 / 2.61 / 2.89 / 2.97 |
| tag-test | **2.399** | 1.97 / 2.35 / 2.40 / 2.76 / 3.23 |

中央値は下がったが、**分布は大きく重なっており n=5 では有意ではない**。
lane 自身のヘッダが警告しているとおり、この runner のドリフトは効果より
大きい。**マイクロベンチの利得は決定的、selfcompile への効きは方向のみ**
と読むこと。

理由も推測がつく: **コンパイラの dup は多くが本物の heap 値**
(String / Array / AST ノード)で、そこではタグ判定は素通りして結局
helper を呼ぶ。マイクロベンチ(全部 Int)は上限を測っている。
**同じ理由で、静的型による「dup を完全に消す」版の上限も同じ母集団に
縛られる** —— 実行される dup のうち immediate の割合が効果を決める。
その割合の直接計測(baseline バイナリの `__rt_rc_dup` 入口で
`v & 1` を数える)は未実施で、次にこの軸へ投資するかの判断材料になる。

---

## 3. 問題の再定義: 直交する2軸が1語に潰れている

- **軸 A(可変性)**: この値は書き換わるか。`mut` / persistent が語っている軸。
- **軸 B(観測可能性)**: その書き換えを、**セルを作った者以外**が観測できるか。

§2 が示したのは、**コストは軸 B だけで決まる**ということ
(`let mut` は軸 A を変えずに軸 B が変わるだけで 3.8× になる)。
そして「外部参照を書き換えるには明確な権限が要る」という要求は、
言葉のうえで**そのまま軸 B の定義**である。

いま vibe は:

- 表面構文で語れるのは軸 A だけ(`mut` を書くか書かないか)
- 軸 B は **codegen の述語 `mut_needs_ref_cell` としてのみ存在**し、
  型にもエラーにも `vibe type-at` にも出てこない
- `TypeEnv` は束縛の可変性を一切持たない —— だから `checker_spawnable.vibe` は
  spawn の `let mut` capture 検査を**構文 walk で別実装**している
  (mutability-control-review の実測記録)
- ADR-0090 の region も、TaskGroup region の既知の穴 (a)
  「generalize される `let`/`let mut` 経由の脱出は検出不能」も、
  **同じ欠落の別の顔**

つまり **vibe はすでに必要な述語を計算している。型システムに教えていないだけ。**

---

## 4. 提案: 権限の境界を軸 B に置く

### 4.1 Verse から取るもの・取らないもの

Verse の heap family は `<computes>`(状態を読まない・書かない) /
`<reads>` / `<writes>` / `<allocates>` / `<transacts>`(既定、3つの合成)で、
`set` は既定で `<transacts>`。

**取らない: 全ての書き込みに effect を課す形。** Verse がそれで済むのは、
`<transacts>` が**既定**だからで、Verse の注釈は **subtractive**(純粋性を
主張するために `<computes>` と書く)。vibe の row は **additive**(権限を
主張するために書く)。additive のまま「全ての `set` に権限」をやると
**ほぼ全関数が `with Write` を背負う** —— これは mutability-control-review が
`Alloc` を effect atom にする案を却下したときの理由そのもので、ADR-0091 は
そこで「row ではなく属性」を選んでいる。

**取るもの: 段の分け方と、既定を無注釈にする発想。** additive を保ったまま
権限を語るなら、**境界を狭くする以外に道はない**。そして狭くする切り口として
唯一コストと一致しているのが軸 B である。

**Verse との差分の記録**: Verse は local `var` への `set` も区別せず
`<transacts>` に含める(ドキュメントは local と field を区別していない。
live variable の存在がその理由として挙げられている)。本提案は
**local を明示的に無権限にする**点で Verse より緩く、
「無注釈が既定」という帰結だけを共有する。

### 4.2 1本の梯子

```
段0  local mut          権限不要      非捕獲 `let mut` / `loop` パラメータ
                                      —— セルを作った者しか観測できない
段1  region-bound mut   `with r`      `region r { }` の中の可変コレクション
                                      —— region 終端で必ず discharge
段2  heap mut           handler 経由  `effect State` + `handle`
                                      —— 権限は row に出て、handler が握る
段3  host mut           `with Fs` 等  プロセス外の可変状態(既存)
```

規則は1文で書ける:

> **セルを作った者以外がその書き込みを観測できるなら、権限が要る。
> 権限は「誰がそのセルを握っているか」を名指す(region / handler / host)。**

この梯子に既存機能を落とすと:

| 今 | 梯子の位置 | 変わること |
|---|---|---|
| `let mut`(非捕獲) | 段0 | **何も変わらない**(大多数のコード) |
| `let mut`(捕獲) | 段1 相当 | 宣言スコープを region とみなす。escape 検査が付く |
| `struct { mut f }` | 段1 or 段2 | 確保元の region に属する。一般 heap なら段2 |
| `Array` / `Bytes` | 段1 or 段2 | 同上(既存コード互換のため段階導入、§4.4) |
| `region r { }`(ADR-0090) | 段1 | **明示形**。今は「別機能」だが梯子の一段になる |
| `effect State` | 段2 | **すでに正しい**。変更不要 |
| `Fs` / `Env` / … | 段3 | 変更不要 |

**ADR-0060 の narrowed な復活**: `Write[r]` が停滞したのは
「すべての `mut` に retrofit」だったから。**escape する `mut` にだけ**課す形は
実測(§2.6)と矛盾しない —— escape する `mut` はすでに 3.8× 帯にいて、
段1 の住人と同じコスト構造を持っている。

### 4.3 region 推論との関係(#1262 の重複解消)

いま「region 推論」と「`let mut` の可変性」が別々の機能に見えているのは、
**両者が軸 B の同じ問いに別々に答えているから**である。梯子に載せると
重複が消える:

- ADR-0090 の `region r { }` は、段1 を**明示的に**書く構文になる。
- 捕獲された `let mut` は、**宣言スコープを暗黙の region とする段1** になる。
  ADR-0090 が「`let mut` は無変更」としているのを、
  「`let mut` は**暗黙 region の糖衣**」に読み替える。
- TaskGroup region の既知の穴 (a)(generalize された `let`/`let mut` 経由の
  脱出が検出不能)は、**穴ではなく同じ機構の未接続**になる。
- ADR-0071 が予約済みの region 引数 kind がそのまま器になる。

### 4.4 実装の入口(小さく、検証可能に)

**段階1(型を一切変えない)**: `mut_needs_ref_cell` と同じ述語を checker 側に置き、
**診断としてのみ**出す。`vibe type-at` / hover が「この `let mut` は
escape する(closure 捕獲)」を答えられるようにする。
- 得られるもの: `TypeEnv` に可変性情報が無い問題の最小の突破口、
  `checker_spawnable.vibe` の構文 walk を置き換える土台、
  TaskGroup の穴 (a) の検出。
- リスク: codegen 側の述語と二重実装になると発散する。
  **どちらかを source of truth にして他方を呼ぶ**こと。

**段階2**: 段0/段1 の境界を**エラーにできる**ようにする(opt-in の lint から)。

### 4.5 実装記録: `vibe escapes`(段階1、着地済み)と3つの重複

段階1 は `vibe escapes <file.vibe>` として着地した
(`lib/@vibe/compiler/runtime/escape_spans.vibe`)。escape する `let mut` を
`NAME START END`(名前自身のバイトオフセット)で1行ずつ出す。
**型も row も一切変えず、エラーにもならない** —— 見えなかった判定を
見えるようにするだけ。

```
$ vibe escapes bench/bench_state_representation.vibe
acc 4019 4022      # 25 個の `let mut` のうち escape するのはこの1つだけ
                   # (= state/7_let_mut_captured の acc)
```

**source of truth は codegen の `is_mut_captured_in` をそのまま呼ぶ。**
再導出しないので、答えは構成上「codegen が実際に box するか」と一致する ——
つまりこのクエリは**コストの問いにも権限の問いにも同じ1つの述語で答える**。

着手して分かったのは、重複が2つではなく**3つ**あったこと:

| | 場所 | 状態 | 誤りの向き |
|---|---|---|---|
| 1 | `codegen/common_analysis :: is_mut_captured_in` | live(lowering を決める) | **保守的**: `match` arm / `for-in` の束縛子の shadowing を引かないので、外側の `let mut` と同名の内側束縛を捕獲しても「捕獲」と報告する → 余計に box する(遅いだけで、誤りではない) |
| 2 | `checker/checker_spawnable :: sp_walk_spawnable_mut` | live(spawn 診断) → **§4.6 で `checker/checker_escape :: mut_binding_escapes` + `TypeEnv` に置換、walk は削除** | **厳密**: false positive がそのまま誤診断になるので、shadowing を正しく引く(PR #1150/#1151/#1152 の3ラウンドで到達) |
| 3 | `checker_capture.vibe` | **dead** | 自分の unit test 以外から参照ゼロ |

1 と 2 は**意図的に向きが違う**ので統合してはいけない —— lowering は
「迷ったら box(安全)」、診断は「迷ったら黙る(誤診断を出さない)」が正しい。
`vibe escapes` は **1 を採用**した: 「codegen が box するか」を答えるべき
クエリだから、over-report は嘘ではなく事実である。

3 は削除した。dead であるだけでなく**壊れていた**:
`collect_mut_bindings` は Expr の 5 形しか処理せず残りは `_` に落ちるので
**`EFn` に降りず、closure 捕獲を原理的に観測できない**。
`analyze_captures_with_muts` は `ELet`/params/パターンの shadowing を引かず、
PR #1152 が 2 で直したのと同じ false positive を持っていた。
「次にこの判定が要る人が踏む罠」として残す価値がないので消した
(この作業中に実際に踏みかけた)。

### 4.6 実装記録: escape 事実を `TypeEnv` に載せた(段階1の残り、着地済み)

段階1 の「型を一切変えない診断」までは `vibe escapes` で着地していたが、
**厳密側の判定は依然として AST を再走査していた** —— `TypeEnv` に可変性が
無いので、Spawnable の `let mut` 捕獲検査は `check_spawnable_mut_captures_stmts`
という**2本目の全プログラム walk** を持つしかなかった。ADR-0100 (1) の
「`TypeEnv` に載せるのは厳密側」をそのまま実装して、これを畳んだ。

- `TypeEnv` に **`EnvMutCell(name, escapes, rest)`** を追加。`env_bind_mut` が
  通常の `EnvBind` の**前**に置くマーカーなので、型の引き方 (`env_lookup`) は
  一切変わらず、新しい `env_mut_escape` だけがこれを見る。
- 厳密述語は **`checker/checker_escape.vibe :: mut_binding_escapes`** に独立。
  checker が `ELetMut` を検査する場所で答えを求めて env に焼き込む。
- **shadowing が「走査で再導出するもの」から「env の連鎖の性質」になった**。
  内側の immutable な同名束縛は `EnvBind` として手前に積まれるので、
  `env_mut_escape` は連鎖順だけで正しく `None` を返す。PR #1150/#1151/#1152
  の3ラウンドが直していたのは、まさにこの再導出のバグだった。
- `check_spawnable_mut_captures_stmts` とその補助 (~230 行) を**削除**。
  Spawnable の判定は捕獲が起きるスコープでの `env_mut_escape` 1 回になり、
  副産物として診断に `line:col` が付いた(全プログラム walk は per-call の
  offset を持てず、#1152 P2 で手当てされていた)。
- 観測面: **`vibe escapes --strict`** を追加。既定レーン(lowering)と
  同じ出力形式で厳密側の答えを出す。両者が**どこで食い違うか**
  (= 束縛子の shadowing だけ、かつ strict ⊆ 既定 の一方向) を
  `compiler_gate.sh` 101/101 と `escape_spans_test.vibe` で固定した ——
  「意図的に食い違う2つの述語」は、放っておくと「事故で食い違う2つの述語」に
  なるので、差の場所そのものを pin する。

重複は 3 → **2** になった。残る 2 本 (lowering の `is_mut_captured_in` と
enforcement の `mut_binding_escapes`) は上表のとおり**意図的に向きが違う**ので、
これ以上は畳まない。

**段階3**: ADR-0090 の `region r { }` を段1 の明示形として実装し、
捕獲 `let mut` を暗黙 region として同じ検査に載せる。

**段階4**: 段1 の row 表現(`with r`)を有効化。ここで初めて表面構文が変わる
(bootstrap bump が要る)。

段階1〜2 は seed に手を入れずに始められる。

---

## 5. コレクション命名: 2軸を分離する

### 5.1 いま何が起きているか

| 名前 | 契約 | 置き場 | key | 実装 |
|---|---|---|---|---|
| `Map[K,V]` | persistent(`set` は新値を返す) | builtin | 任意 | assoc |
| `MapBuilder[K,V]` | 可変 builder → `freeze` で `Map` | builtin | 任意 | |
| `ImmutMap[V]` | **persistent** | `@vibex/immut` | **String のみ** | HAMT |
| `HashMap[K,V]` | **可変ハンドル**(`set -> Unit`) | `@vibe/core` | 明示 dict | open addressing |
| `SortedMap[K,V]` | **可変ハンドル** | `@vibe/core` | 明示 cmp | AVL(順序 + range) |
| `MutMap[K,V,r]` | region 束縛の可変(ADR-0090、未実装) | — | | |

規則(ADR-0082)は「bare = persistent / `Hash-`・`Sorted-` = 可変 /
`XBuilder` / `Frozen-` = 不変かつ Send」。破れが3つある:

1. **`ImmutMap` は規則の外**。契約は `Map` と同じ persistent なのに接頭辞が付く。
   規則どおりなら bare であるべきだが、bare は builtin `Map` が使っている。
   **規則には「同じ契約・違う実装/性能」を表す語彙が無い。**
2. **`Hash-`/`Sorted-` が2軸を同時に背負っている**。`Hash` は実装戦略、
   `Sorted` は**インタフェース差**(順序 + `range`)、そして両方が
   「可変」も意味している。だから「persistent な hash map」
   (= まさに `ImmutMap`)や「可変な sorted map」を規則内で綴れない。
3. **ADR-0090 が `Mut-` を「region 束縛の可変」として追加しようとしている** ——
   着地すると `MutMap` と `HashMap` が**どちらも可変な map** になる。
   衝突が仕込まれている状態。

### 5.2 提案: 軸ごとに位置を固定する

- **軸1 可変性 = 接頭辞(閉じた集合)**: ∅ = persistent / `Mut` = 可変ハンドル /
  `Frozen` = persistent かつ Send / `-Builder` 接尾辞 = 書いてから freeze
- **軸2 インタフェース = 基底名**: `Map`(無順序)/ `SortedMap`(順序 + range)/
  `Set` / `SortedSet` / `Array` …
- **軸3 実装・性能 = 接尾辞(開いた集合、必要なときだけ)**: `Hamt`, `Avl`, …
  **性能上の理由で2つを併存させるときにだけ付ける**(ここは「一貫規則の
  例外」ではなく、規則が明示的に用意した逃げ道)

| 今 | 提案 | 根拠 |
|---|---|---|
| `Map[K,V]` | `Map[K,V]` | 変更なし |
| `ImmutMap[V]` | `Map` に統合、または `MapHamt[K,V]` | 契約が同じなので**接頭辞ではなく実装接尾辞**。統合できるなら統合が最善 |
| `HashMap[K,V]` | `MutMap[K,V]` | 可変性は接頭辞。`Hash` は実装であって契約ではない |
| `SortedMap[K,V]` | `MutSortedMap[K,V]` | 今のこれは**可変**。`SortedMap` は persistent 版に空けておく |
| `HashSet` / `SortedSet` | `MutSet` / `MutSortedSet` | 同上 |
| `MapBuilder` / `ArrayBuilder` | 変更なし | すでに規則内 |
| `FrozenArray[T]` | 変更なし | すでに規則内 |
| `MutList[T,r]`(ADR-0090) | `MutList[T,r]` | **同じ `Mut-` に合流**。衝突が解消する |

`Mut-` が「region 束縛」と「一般 heap の可変ハンドル」の両方を指すことになるが、
これは §4 の梯子では**同じ段1〜2**で、region パラメータの有無が段を区別する
(`MutMap[K,V]` = 段2 / `MutMap[K,V,r]` = 段1)。命名と権限モデルが一致する。

`Array` / `Bytes` は ADR-0082 のとおり改名しない(破壊的すぎる)。
規則の外にいる低レベルプリミティブとして据え置き、cheatsheet の警告を維持する。

### 5.3 移行

> **2026-08-07 決定 (ADR-0100): §5.2 の2軸分離を採用。** `ImmutMap` は
> builtin `Map` への統合を試み、性能上併存が要ると判明したら実装接尾辞
> `MapHamt` に落とす。

renames + 旧名の deprecated alias。`vibe` は selfhost なので、
コンパイラ自身の利用箇所が最大の呼び出し元になる。ADR-0082 の子タスクとして
段階実施(#1140 系列)。**§4 の段階3 より前に着手できる**(独立)。

---

### 5.4 Builder 族の決着 (2026-08-07, ADR-0101)

`-Builder` も「可変」の一種なので、§5.2 の軸に載せる前に
**性能上必要かどうかを実測で分けた**(規則:「性能例外は許すが、例外は
明示的に説明する」— この節がその説明)。n=1000 の蓄積、
[bench/bench_builder_vs_mut.vibe](../bench/bench_builder_vs_mut.vibe)、
B/op は VIBE_RC=0 (bump) の値:

| 素材 | Builder | Mut- 相当 | persistent 相当 |
|---|---|---|---|
| arr | 17.2µs / 16332 B | `Array::push` 13.6µs / **16332 B(完全一致)** | concat 90ms / 10.8MB |
| str | **23µs / 17KB** | (可変 String は存在しない) | concat 250µs / 492KB |
| map | 2.43ms / 71KB | `HashMap` **1.49ms** / 337KB | `Map::set` 133ms / 18MB |

決定:

- **ArrayBuilder / MapBuilder は廃止方向**(deprecated alias で段階移行)。
  ArrayBuilder は `Array::push` と ns 誤差内・確保量まで同一で、純粋に
  契約シグナルだけの型だった。MapBuilder は assoc 走査のせいで
  `HashMap`(→`MutMap`)より 1.6× **遅い**。契約シグナル(持ち続けない・
  freeze で終端)は、将来の region 束縛 `MutList[T,r]` / `MutMap[K,V,r]`
  (ADR-0090)が型パラメータとして引き受ける。
- **StringBuilder は性能例外として維持**。唯一の代替(persistent concat の
  付け替え)より 10.6× 速く、確保が 29× 少ない。可変 String 型は導入しない
  ので、これが効率的な文字列蓄積の唯一の手段。Builder 族の規則は
  「**Builder = 性能例外のために存在する accumulator**」の1文になる。
- **語彙の再整列**: 現状は動詞 `freeze` が `Frozen-` 型を産まない
  (最悪例: `ArrayBuilder::freeze -> Array` — freeze の結果が可変)。
  Builder の終端は **`build`**(`StringBuilder::build() -> String`、
  型名と動詞が対応)、**`freeze` は Frozen-(persistent+Send)を産む動詞に
  予約**、Mut- → persistent の非消費変換は **`snapshot`**。
  既存 `XBuilder::freeze` は deprecated alias。

これで可変性軸の閉じた集合は **∅ / `Mut` / `Frozen` / (性能例外としての)
`-Builder`** の4位置、対応する動詞は **`snapshot` / `freeze` / `build`** に
それぞれ固定される。

**配列の最適化誘導先は `FixedArray`**(同決定 (4))。長さが事前に分かる
最適化対象コードは growable `Array` ではなく固定長 `FixedArray` で書く —
bounds が静的に既知(成長 realloc なし・bounds check 除去の余地)で、
長さ不変条件を将来 requires/ensures の形式手法で証明する余地がある
(`unsafe_set` の正当化を証明に置き換える路線)。zlib / regexp / optimizer /
perceus のホットパスは既にこの形。使い分けの1行:
**長さ既知 → `FixedArray`、長さ未知の蓄積 → `Array::push`、
文字列蓄積 → `StringBuilder`(性能例外)**。cheatsheet への明記は
rename 作業と同時に行う(FixedArray は現状 cheatsheet 未記載)。

## 6. 収斂先: 「最速の形」に全部を寄せる

§2.7 が確定させたこと ——

> **最速の形は「状態が wasm local に載っていて、RC が触らない形」。**
> 0.74 ns/反復、local は個数を増やしても無料。

そして重要なのは、他の形との差が**その形固有のコストではない**こと。
どれも「まだ書かれていない最適化の値段」である。

| いまの差 | 値段(RC) | 何を払っているか | 消すのに要るもの |
|---|---|---|---|
| scalar 引数の dup | **+2.2–2.9 ns / 引数 / call** | tagged immediate への no-op dup | **codegen が引数の静的型を知る** |
| ユーザ関数呼び出し | +1.0 ns / call | 呼び出し規約 | inlining |
| 非 escape struct の mut field | +2.0 ns / 反復 | heap ブロックの固定費 | escape analysis + scalar replacement |
| 捕獲された `let mut` | +2.9 ns / 反復 | closure env + ref cell | 同上(+ closure inline) |
| tuple の `loop` パラメータ | +7–21 ns / 反復 | 箱 | unboxing |
| enum 値の付け替え | +20–33 ns / 反復 | 箱 + RC トラフィック | unboxing / FBIP |
| State effect | +4.9 ns / 反復 | evidence dispatch | handler inline |

### 6.1 収斂の形

**表面は分岐させたまま、lowering を1点に収斂させる。**
`let mut` を消して effect に統一する、あるいはその逆、という
「表面の統一」はやらない —— §2 が示したとおり、非捕獲 `let mut` と
State effect は**別の問題を解いている**ので、統一すると片方が
不自然になるだけで速くはならない。

収斂させるのは**下ろし先**のほう:

```
表面 (§4 の梯子どおり、意味で選ぶ)
  段0 非捕獲 let mut / loop パラメータ
  段1 region r { } / 捕獲された let mut
  段2 effect State + handle
  段3 host capability
        │
        │  ← escape 解析が「この状態は外へ出ない」と言えたものは全部
        ▼
lowering (1点)
  **wasm local**。RC も heap も触らない 0.74 ns/反復の形。
```

つまり **surface の選択が性能を決めるのをやめさせる**。今は
`loop (s = (0,0))` と `loop (i = 0, acc = 0)` が意味は同じで 10–28× 違う。
これは利用者が覚えるべき規則ではなく、実装都合の漏れ
(CLAUDE.md の「言語ポリシー」がまさに戒めている形)。

### 6.2 収斂の順序 —— 安い順に、同じ配管を敷きながら

4つの最適化はすべて**同じ前提**を要求する: **checker が持っている事実
(型・escape)が codegen に届いていること**。だから §4 段階1
(checker 側 escape 述語)は性能側の前提工事でもある。同じ配管が
権限規則と性能の両方を通す。

| 順 | やること | 得られるもの | 要る配管 |
|---|---|---|---|
| 1 | **scalar 引数の dup を消す** | 残り 0.44 ns/dup も消える。サイズは 1' より減る | 引数の静的型が codegen に届く (= 2 の配管) |
| 1'| **[実装済]** タグ判定だけ inline、slow path は out-line | dup 1 個 2.37 → **0.44 ns**、+9 B/サイト。selfcompile への効きは方向のみ (§2.9) | 無し(codegen 内で完結) |
| 2 | **[実装済]** escape 述語を可視化(`vibe escapes`、§4.5)+ 厳密側を `TypeEnv` に載せる(§4.6) | 権限規則の土台。重複3件 → 2件(向きが違う分だけ残す)。Spawnable の2本目の walk は削除 | 無し(codegen の述語 + `checker_escape.vibe`) |
| 3 | **scalar replacement**(非 escape struct → local) | struct mut / 捕獲 `let mut` が段0 へ | 2 |
| 4 | **unboxing**(非 escape tuple/enum → 複数 local) | `loop` の箱が消える。10–28× の surface 差が消える | 2 |
| 5 | **handler inline**(monomorphic tail-resumptive) | State effect が段0 へ | 2 + inlining |

**1 は今日始められて、単独で最大**(#1262 の出口条件に対して FBIP より
遥かに近い)。2 は seed 非依存。3–5 は 2 の上に順に積める。

### 6.3 この順序で何が「一つ」になるか

- **性能**: 段0〜段2 のどれで書いても、escape しない限り同じ 0.74 ns/反復。
  surface は意味で選べるようになる。
- **権限**: escape する場合だけ row に出る(§4)。escape 解析が
  「速いか」と「権限が要るか」の**両方の判定を1つで担う**。
- **重複の解消**: `let mut` の可変性(§1)、region 推論(ADR-0090)、
  FBIP(ADR-0092)は、いずれも「この値は外へ出るか」への別々の答えだった。
  1つの解析に寄せると、region は段1 の**構文**、FBIP は unboxing が
  効かなかった残りに対する**後詰め**、という位置に落ち着く。

---

## 6.4 実装記録: tuple loop パラメータ unbox の試行(撤収)

§6.2 の順4を先行して試した(normalize 段の AST 書き換え、conservative な
適格判定 + `continue` の literal tuple 展開)。**動くところまで持ち込めず
撤収した**。branch には fixture
(`fixtures/unbox_tuple_loop_test.vibe` — 適格/非適格 8 形の挙動ピン)だけを
残している。次に試す人への記録:

1. **linear backend の codegen 入口は 1 つではない。**
   `compile_wasi_module_linked_impl`(entry 指定コンパイル)と
   `compile_module_expr`(test/bench の `__no_entry__` module lane)は
   独立で、desugar の呼び場所も違う。「universal codegen convergence
   point」というコメントは entry コンパイルの世界での話で、
   pass は**両方**に(または両者の合流点を作ってから)入れる必要がある。

2. **`bytes_per_op` / `__heap_ptr` delta は RC 下では unbox の証拠にならない。**
   RC は解放された tuple を exact-fit free list が即座に再利用するので、
   heap_ptr の前進は net-live のみ = boxed でも 64 B 定数になる。
   bump(`VIBE_RC=0`)の delta だけが確保の真値。今回この読み違いで
   「発火した」と一度誤認した。

3. **検証面の汚染: pass 入りコンパイラでプローブをコンパイルすると、
   プローブ自身が pass の影響下に入る。** pass のバグを疑い始めた時点で、
   「pass を通っていないコンパイラ」でプローブを建て直さないと
   観測が信用できなくなる(今回 AST タグの矛盾した観測が出て切り分け不能に
   なった)。**pass の unit test は、pass を wire する前のコンパイラで
   green にしてから wire する**のが正しい順序だった。

4. **[解決済] 真の root cause: `loop` は ELoop に parse されない。**
   追加調査(AST ダンプ + `parse_loop_primary` の読解)で判明 ——
   parser がすべての `loop (params)` を parse 時に
   `let mut <p> = <init>` + `let mut __loop_result` + `while true` に脱糖し、
   `continue(args)` は `let __ltK = argK; pK = __ltK; continue` に、
   `let (i, acc) = s` は**単一 arm の tuple EMatch** になる。
   **ELoop ノードは parser が一切生成しない**(codegen の ELoop ハンドラは
   死んだレガシー)。初回実装は「AST に存在しないノード」をマッチしていた。
   前回 3. で「観測汚染」と書いたのも誤診で、プローブに ELetMut アームが
   無かっただけ。

5. **正しいターゲットは「tuple リテラル初期化の `ELetMut`」**で、再実装して
   着地した(§6.5)。教訓 (a) unit test 先行 (b) 2 lane 同時 wiring
   (c) bump lane の heap delta を唯一の発火判定にする、はそのまま有効だった
   —— 実際 (a) が binder カウントのバグを wire 前に捕まえた。

### 6.5 実装記録: tuple `let mut` unbox(着地)

対象: `ELetMut(s, ETuple(n), body)` で、`s` の全出現が
単一 arm tuple match(読み)/ `.K` 射影(読み)/ tuple リテラル代入(書き、
直接または単一使用の `__lt` temp 経由)のもの。書き換えは N 本の scalar
`let mut` + match→ELet 展開 + 要素ごと代入(直接代入は fresh temp を挟むので
`s = (s.1, s.0)` の swap も壊れない。`__lt` temp 形は元々代入前に全評価する
ので、その要素 let をそのまま temp に転用)。

健全性は**出現数の会計**で取る: `utl_count`(全 Expr variant を走査、
binder 再束縛と closure 言及は poison 値)と `utl_recognized`(認識形のみ
数える)が一致したときだけ書き換える。認識漏れ・未知の出現が1つでもあれば
不発 = 常に正しい側に倒れる。

検証(すべて green):
- unit probe(wire **前**のクリーンコンパイラで実行): 適格3形が発火、
  非適格(関数へ丸ごと渡す)は不発
- fixture 8 形の挙動ピン、bench ファイルの test
- **bump lane heap delta: 16016 → 0 B**(entry lane / `__no_entry__`
  module lane の両方で確認 —— 教訓 (b)(c) の適用)
- `pkf run test`(fixpoint)、`rc_corpus_parity` 141/141

効果: **`floor/8_tuple_loop` 12548 → 930 ns / 16016 → 0 B。
`state/2_loop_param`(931 ns)と完全に同着** —— §6.1 の
「surface の選択が性能を決めるのをやめさせる」の最初の実例が実測で成立した。
`loop (s = (0,0))` と `loop (i = 0, acc = 0)` はもう同じコスト。

制限(v1、意図的): enum 値の付け替え(state/4 等)は対象外(FBIP の領分)。
ネストした同名 `__lt` temp を持つ多重ループは保守的に不発。
wasm-gc / interp lane は据え置き(意味論保存なので differential gate は一致)。

---

## 7. #1262 への差分提案

現行の実装順は **ADR-0092(FBIP)→ ADR-0090(region)→ ADR-0091(zero_alloc)** で、
0092 を先頭に引き上げた根拠は issue 本文いわく
「表面構文なし・bootstrap 不要で今日始められ、**RC default の wall ~1.6–2.1× に
全コードで即効**し、reuse 後に zero_alloc を導入するほうが検証通過域が広い」。

§2 の実測はこの根拠のうち**第2項を否定する**:

- Phase 1 reuse の利得は測定範囲で**ゼロ〜負**(適格形が 1.62× 遅く、
  確保が 0 → 32 KB/op に増える、§2.3)。
- FBIP の正典ワークロード(リスト map)でも**差はノイズ帯**(§2.4)。
- 効いていないのは reuse ではなく **exact-fit free list** で、これは既存機能。
- 「RC は bump の 1.6–2.1× 遅い」自体が確保の軽いコード限定の話で、
  確保が重いワークロードでは **RC のほうが 1.4× 速い**(§2.4 の `map5`)。

したがって提案:

1. **ADR-0092 の出口条件を測り直す。** 「RC/bump wall 比 ≤1.2×」を
   reuse で達成する筋は、§2.3 の観測(静的適格性と動的一意性の不一致)から見て
   薄い。ボトルネックは `__rt_rc_dup`(issue 内の実測で単独 38.5% CPU)であって
   確保ではない。**reuse ではなく dup/drop 削減(borrow 推論の一般化)**が
   本線ではないか —— これは mutability-control-review が
   「Capture Checking から盗む部品 (a)」として既に挙げているもの。
2. **少なくとも Phase 1 の適格判定に動的一意性の見込みを入れる**まで、
   fusion は既定 off にすることを検討する。現状は
   「適格条件を満たすが所有権は渡っていない」形で**確実に退行する**。
3. **順序を 0090 → 0091 → 0092 に戻す**ことを検討する。region(§4 の段1)は
   RC 免除をもたらすので dup/drop を**構造的に**消せる。
4. §4 の段階1(checker 側 escape 述語)は**どの ADR より前**に置ける。
   3本すべての前提(`TypeEnv` に可変性情報が無い)を直す工事だから。
5. **その前に、scalar 引数の dup 削除(§2.8 / §6.2 の順1)を単独で置く。**
   ADR 不要・表面構文なし・bootstrap 不要で、コードサイズは**減る**。
   出口条件「RC/bump wall 比 ≤1.2×」への距離は FBIP より遥かに近い。

---

## 8. 未決 → 決着 (2026-08-07, ADR-0100)

上2つは ADR-0100 で決着した。決定内容を各項に注記する。

- **段0/段1 境界の正確な定義**。`mut_needs_ref_cell` は closure 捕獲だけを見る。
  `struct { mut f }` を関数に渡す形、`Array` を渡す形は今の述語の対象外で、
  梯子に載せるなら別途定義が要る。**まず捕獲 `let mut` だけで段階1をやる**のが安全。
  → **決定: closure 捕獲のみを escape とする。** struct mut 渡し・`Array`/`Bytes`
  渡しは対象外と明文化し、拡張は別決定として起こす。定義が現行述語の実装と
  一致した状態から出発するので、既存コードの適法性は変わらない。
- **段2 の綴り**。`effect State` を書かせるのか、`with Mut[c]` のような
  セル名パラメータにするのか。ADR-0075 の resource kind パラメータと
  同じ問題なので、そちらの決着を待てる。
  → **決定: `with Mut[c]` を新設する。** `effect State` + handler は機構として
  残るが、権限の綴りはセル名パラメータ付き row atom に寄せる。詳細設計
  (セル名の kind・スコープ規則、ADR-0075 との整合)は実装前に起こす。
- **`reads` 相当を持つか**。Verse は `<reads>` を分けるが、vibe で
  read 権限が要るのは host 資源(`Env::Read` / ADR-0075 の path-scoped)だけで、
  in-process の読みに権限を課す動機はまだ実測されていない。**当面は持たない。**
- **ハンドラ inline**。§2.5 の残り 2× を縮める唯一の筋。ADR-0076 の
  evidence-passing で tail-resumptive は既に直接呼び出しなので、
  あとは呼び出し側 inline の問題。効果測定から。
- 計測は1マシン・1形状。**region と handler inline を入れる前に、
  実アプリ形状(コンパイラ自身)でも同じ順序になるかを確認する**こと。
