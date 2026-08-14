# ADR-0090: `region r { ... }` — region 束縛の可変コレクションと effect row 統合

Status: proposed

Date: 2026-07-31

Related: #418, #629, #1081, ADR-0055(RC), ADR-0060(supersede 対象),
ADR-0068(TaskGroup/Send), ADR-0071(row 正規化), ADR-0082(コレクション
命名), ADR-0084(taxonomy), ADR-0088(allows), ADR-0092(reuse)。
比較検討の経緯は [mutability-control-review.md](mutability-control-review.md)、
方向の初出は [effect-taxonomy-review.md](effect-taxonomy-review.md) の
ADR-0060 節(「retrofit ではなく opt-in 追加」)。参考: Flix regions
(`region rc { }`、`MutList[t, r]`、`\ r`)、Effekt second-class capabilities。

## Context

vibe の `let mut` は「共有・indefinite extent の可変セル」であり(実測 pin
済み)、escape 自由のまま維持する — ADR-0060 の `Write[r]` retrofit は実装と
矛盾して停滞し、taxonomy review が撤回を結論済み。一方で、(a) スコープに
閉じた可変処理を **RC の dup/drop 無しで**走らせる高速 lane、(b) RC が
構造的に回収できない**循環**の回収手段、(c) 「この関数はどの可変状態に
触れるか」を row で読める cross-scope 可変性の契約、の3つが欠けている。
Flix の region はこの3つを1つの機構で与える形であり、vibe には
`TaskGroup::run` の generative region(rigid skolem + escape 検査、#1081)
という動く雛形が既にある。

## Decision

### 1. `region r { ... }` を式として導入する

- `region r { body }` は新しい**構文**(式)。generative な region `r` を
  mint し、body の値を返す。region 識別は TaskGroup と同じ rigid skolem
  (`#region_N` 相当)で表現する。
- **構文にすることで TaskGroup の literal-name マッチ問題(alias/HOF での
  素通り)は最初から存在しない**。TaskGroup 側も将来この機構に載せ替える
  移行先とする(本 ADR では移行しない)。

### 2. region 束縛の可変コレクション

- `MutList[T, r]` / `MutMap[K, V, r]` / `MutSet[T, r]` を `lib/@vibe/` に
  追加する。constructor は region token を取る(`MutList::empty[Int](r)`)。
  **確保の routing は API(token 引数)で決まる** — region 内で行われる
  一般 heap 確保(通常の tuple/ctor 等)は従来どおり一般 heap に行き、
  自由に escape できる。dynamic scope で確保先を切り替えることはしない。
- ADR-0082 の命名語彙に **`Mut-` 接頭辞 = region 束縛の可変**を正式追加
  する(bare = persistent / `Hash-`/`Sorted-` = 可変ハンドル / `XBuilder` /
  `Frozen-` は不変)。既存 `HashMap` 等の可変ハンドル族は将来の移行候補
  だが本 ADR では変更しない。
- 脱出の公認経路は **freeze / copy-out** のみ: `MutList::freeze -> 
  FrozenArray[T]`(Send 適格)、`MutList::to_array -> Array[T]`(一般 heap
  へコピー)。これらは**region 外の heap に確保して**返す。

### 3. effect row 統合(Flix の `\ r`)

- region の可変メモリに触れる関数は row に `r` を書く:
  `fn fill(l: MutList[Int, r]) -> Unit with r`。
- 正規化は ADR-0071 が予約済みの **region 引数 kind** を使い、effect 変数
  (`with e`)とは別 kind として扱う(effectset.md の「resource
  identity と nursery/borrow region を混同しない」を維持)。
- `region r { ... }` の終端で `r` は**必ず discharge** される(Flix と
  同じ)。したがって `main` の row に region が残ることはなく、ADR-0084 の
  entry 規則・ADR-0088 の `allows` 句とは干渉しない(region は host が
  解決するものではないので `allows` には書けない — `with` 句側)。

### 4. escape 規則(second-class capability)

region 型(`MutList[T, r]` 等、および `r` を型引数に含む全型)の値は
region の外に出られない。検査は TaskGroup の雛形を一般化する:

- return 位置・outer binding への脱出は skolem 検査で reject(既存機構)。
- **generalization 禁止**: region 型を含む `let`/`let mut` 束縛は
  generalize しない(value-restriction 相当)。これにより TaskGroup 検査の
  既知の穴 (a)(generalize されたローカル経由のリーク)を region では
  塞ぐ。TaskGroup 側への同修正の波及は別作業として起票する。
- closure capture: region 値を捕獲した closure 自体が region 型に感染する
  (row に `r` が付く)ため、region 外へ持ち出せば同じ検査で落ちる。
- spawn 境界: region 値は `Send` 判定で構造的に non-Send(mut 実体)なので
  `Spawnable[r']` 検査がそのまま拒否する。region は task-local。

### 5. lowering(linear backend 専用)

- region = **独立した bump arena セグメント**(main heap から block を
  切り出し、arena 内は watermark bump)。終端で watermark ごと一括解放
  (セグメントを free list へ返す)。main `__heap_ptr` と混ぜないので、
  region 内で行われた一般 heap 確保の escape と干渉しない。
- **Perceus 免除**: region 型の値にはプランナが dup/drop を挿入しない
  (寿命は region が保証)。RC ヘッダも不要(arena 内は headerless で
  よいが、Phase 1 は既存ヘッダ形式のまま挿入だけ省く簡易形から始める)。
- **循環回収**: region 内で作られた循環構造は終端の一括解放で回収される
  (RC の恒久制限の補完)。
- wasm-gc backend は対象外(linear 専用。suspend CPS と同じ前例)。

## Consequences

- ホットな可変処理を region に置くと dup/drop トラフィックが消え、解放は
  O(1) の watermark 戻しになる。ADR-0092(reuse)と独立に積算する。
- `let mut` は無変更(heap-boxed・escape 自由・row に現れない)。region は
  opt-in の追加機能であり、既存コードは1行も変わらない。
- `@zero_alloc`(ADR-0091)の既定は region 確保を許容するので、
  「region + `@zero_alloc`」で『一般 heap に触れないホットパス』を機械
  検証できる。

## Non-goals

- ADR-0060 の `Write[r]` 統一(正式に supersede する)。
- read-only ビュー(`r` の operation 部分集合を effectset で切る案)は
  需要が出てから。
- TaskGroup の region 機構の本 ADR への載せ替え・cross-task region・
  region の第一級化(値としての受け渡しは token 引数のみ、格納は不可)。
- wasm-gc backend 対応。

## Implementation sequence

1. fixture 先行: escape reject(err: return / outer binding / 格納 /
   generalize)+ 正常系(build→freeze、ネスト region LIFO)。
2. parser: `region` キーワード(新構文なので **seed が理解できる tag →
   bootstrap bump** が必要。ただし compiler source 自身が使い始めるまでは
   遅延可 — ADR-0088 の `allows` と同じ運用)。
3. checker: skolem mint(構文由来)、row の region kind、escape +
   no-generalize 検査。
4. lib: `MutList`/`MutMap`/`MutSet`(Phase 1 は `MutList` のみで縦串)。
5. codegen: arena セグメント + watermark、Perceus 免除。
6. gate: heap boundedness(region ループで `__heap_ptr` が有界)、
   RC on/off 出力同一、`bench/regression` に region 版 bench を追加し
   `bytes_per_op`(一般 heap 分)0 を tracked series で固定。

## Phase 1 implementation notes (2026-07-31, #1262)

最初の縦串が landed した。実装の実際の形と、設計との差分・既知ギャップ:

- **parser**: `region` は hard keyword(`TRegion`)。
  `parser_expr_dispatch.vibe` mode 27 が `region r { body }` を
  `__region_run((r) -> { body })` に脱糖する。body は mode 20
  (statement block)で parse する — 単一式ではない。
- **checker**(`checker.vibe` の `__region_run` ECall branch、
  TaskGroup::run 特例のクローン): 引数が literal lambda(parser 由来の
  唯一の形)のとき、**binder を rigid skolem `#region_N` に bind してから
  body を検査する**。bind-first が本質: check-first だと `let l =
  MutList::empty(r)` の時点で region 型がまだ自由変数で、この checker の
  let-generalization が taint を量化して逃がす(ADR-0068 節の generalize
  穴の再演)。skolem は CtNamed なので generalize は量化できず、`let`
  経由の return-position escape も検出される — これが本 ADR の
  「region 型の generalization 禁止」の Phase 1 実装形。非 literal callee
  (手書き `__region_run(f)`)は check-then-unify の弱い経路に落ちる
  (直接 return escape のみ検出、documented gap)。
- **MutList**: checker-only phantom(`CtNamed("MutList", [elem, region])`、
  FrozenArray 手法 #906)。element 型は Phase 1 では tolerant
  (`CtUnknown`)。region 引数の型が第2 type arg に入るので escape scan が
  taint を見る。`freeze -> FrozenArray[T]` / `to_array -> Array[T]` が
  sanctioned exit。**call-site の明示 type application
  (`MutList::empty[Int](r)`)は非対応** — wrapper が builtin 名を ECall
  dispatch から隠すため。
- **codegen**(linear のみ): `compile_call` が `__region_run(lam)` を
  「dummy token 0 での即時 closure call」に、`MutList::empty(r)` を
  `ArrayBuilder::new()`(token 非評価)に書き換え。push は ArrayBuilder
  lowering への alias。**`freeze` / `to_array` は copy-out** (#1262,
  2026-08-14) —— FrozenArray の他の面 (`from_array`/`to_array`) は
  identity cast だが、この2つだけは実体をコピーする。理由は2つあり、
  (a) exit の時点で list ハンドルがまだスコープに居るので、alias だと
  `let out = MutList::freeze(l); MutList::push(l, 3)` が「凍った」配列を
  後から書き換える (黙って誤る)、(b) arena はセグメント全体の watermark
  リセットで解放するので、identity cast は**解放予定のメモリへのポインタ**を
  呼び出し側に渡すことになる。§4 の「脱出は freeze / copy-out のみ」の
  copy-out がこれ。gate 75 の `fixtures/region_ok_freeze_copies_out.vibe`
  が両 exit を pin。wasm-gc backend は未対応。
- **arena セグメント + watermark 一括解放 (#1262, 2026-08-14、bump レーンのみ)**:
  `__region_run` が **独立した bump セグメント**の watermark を保存/復元し、
  region 終端でまとめて捨てる。レイアウトは linear memory 上の
  `[bump ptr @+0][depth @+4][saved bump ptrs @+8, 64 段][data, 256 KiB]` で、
  制御語を wasm global ではなくメモリに置いたのは、呼び出し側で local を
  1本も要らなくするため (codegen の書き換えからは囲む関数の local ベクタに
  手が届かない)。`MutList::empty` は専用 body
  (`gen_region_arr_new_body`) がセグメントから確保し、**`MutList::push` は
  書き換え不要** —— どちらのレーンから regrow するかは**配列の性質**
  (そのブロックがセグメント内か) なので、共有の `arr_push` body の中の
  range 判定にした。
  - **なぜ独立セグメントで、共有 bump の watermark ではないのか**: region
    body は普通の heap 値 (tuple・String) も確保し、それは脱出してよい。
    共有 bump を巻き戻すとそれを回収してしまう。§5 の「main `__heap_ptr` と
    混ぜない」はこの理由。
  - **degradation は常に「回収しない」側**: セグメント枯渇時は main heap に
    fallback、ネストが 64 段を超えたら save も restore もしない。どちらも
    「回収が減る」だけで、誤った答えにはならない。
  - **bump レーン限定**: RC では region ブロックが RC ヘッダを持ち free list に
    載りうるので、一括解放が free list を壊す。Perceus 免除が入るまで RC
    レーンは従来どおり (MutList == ArrayBuilder on main heap)。bump レーンは
    そもそも解放しないので、一括解放の効き目もここが一番大きい。
  - **実測** (200 region × 500 要素、`VIBE_RC=0`、
    `scripts/region_arena_heap_delta.mjs`): main heap 増加が
    **1,644,008 B → 6,408 B (257×)**。残る ~32 B/region は region body の
    closure 環境 (`__region_run(lam)` の lam は毎回 main heap に確保される)
    で、region storage ではない。即時適用される region lambda を確保無しに
    するのは別の最適化。
  - gate 75 が `fixtures/region_arena_release_ok.vibe` (逐次 region の再利用・
    ネスト・普通の heap 値の脱出・inline 容量超えの regrow) を RC 両モードで、
    `fixtures/region_arena_bounded.vibe` を bump レーンで **測って** pin する
    —— 解放をやめた region も値は正しいままなので、値の assertion では
    見えない。
- **Perceus 免除**は未実装 (RC レーンで arena を有効にする前提)。
- **gate**: `compiler_gate.sh` §74 が positive
  (`fixtures/region_arena_ok.vibe`、42)と negative
  (`fixtures/err_region_escape_return_value.vibe`、needle
  "region escapes its scope")を固定。
- **closure capture (#1725、2026-08-14)**: §4 の「捕獲した closure が region
  型に感染する」は **row 統合前提なので Phase 1 では働かない** —— 型は捕獲を
  記録しないので、`region r { let l = MutList::empty(r); () -> Array[Int] {
  MutList::to_array(l) } }` の結果型は `() -> Array[Int]` で skolem 走査から
  見えず、region 値が closure の環境に隠れて脱出できた。arena が入れば
  use-after-free なので stopgap を入れてある:
  `checker/checker_escape.vibe :: region_token_escapes_in_closure` が
  「region body の**結果そのもの**が closure literal で、region token から
  直に束縛された名前(とその別名)を捕獲している」形だけを reject する。
  **capture 自体は正当**(region 内で完結する closure は普通に書く)なので
  過剰approx にしないことが要件で、汚染は「token に言及する初期化式」と
  「汚染名の裸の別名」に限り、shadowing は最後の束縛が勝つ。取りこぼし:
  outer binding / container 経由、helper 関数経由。gate 75 が両方向
  (`fixtures/err_region_escape_closure_capture.vibe` /
  `fixtures/region_ok_closure_local.vibe`)を pin。**正しい規則は §4 の
  row 感染**で、arena スライスの前提はそちら。
- **既知ギャップ(Phase 1 で許容、ADR 本文の設計は不変)**: effect row 統合
  (§3)は未着手 — 別 pass の effect 検査は lambda wrapper を見るため、
  region body 内の effect は enclosing fn に帰属しない。outer-binding scan は
  ADR-0068 と同じく generalize 済み束縛への leak を見ない。heap
  boundedness gate(arena 前提)は arena スライスと同時に入れる。

## Reconciliation ledger

| 項目 | 根拠 / 観測 | 結論 |
| --- | --- | --- |
| 期待する契約 | 可変状態の cross-scope 契約を row で読みたい / RC コストと循環リークの補完が欲しい | region 効果 + arena + escape 検査を1機構で導入 |
| 実装観測 | TaskGroup::run が skolem mint + return/outer escape 検査を既に実装(#1081) | 雛形として一般化。構文化で literal-name 穴は非発生 |
| 実装観測 | generalize された `let`/`let mut` 経由のリークは既知の未検出穴 | region 型の generalization 禁止で塞ぐ(本 ADR の必須要件) |
| 実装観測 | ADR-0071 正規化が region 引数 kind を予約済み | row 統合は予約枠の実装。effect 変数とは別 kind |
| 実装観測 | linear heap は bump(`__heap_ptr`)+ exact-fit free list | arena はセグメント切り出しで実装、main heap と非干渉 |
| 回帰ガード | escape err fixtures、boundedness gate、RC on/off byte 同一 | Phase 1 から固定 |
