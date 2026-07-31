# 可変状態の制御レビュー: Scala Capture Checking / Flix region / OxCaml `[@zero_alloc]` の vibe 適合性

> **位置づけ**: [effect-taxonomy-review.md](effect-taxonomy-review.md) と同じく
> ADR ではない設計レビュー文書。可変参照の制御に関する3つの外部設計を、
> vibe の現状(Perceus RC・`let mut`・TaskGroup region 機構)と突き合わせて
> 評価し、方向性が固まった項目から ADR に切り出す前提の検討記録。
> Related: ADR-0021(superseded 経緯), ADR-0052(mut field), ADR-0055(RC
> cutover), ADR-0060(`Write[r]`、proposed 停滞), ADR-0068(TaskGroup/Send),
> ADR-0082(コレクション命名), ADR-0088/0089, #418, #629, #1081。

## 評価対象(外部設計の要点)

1. **Scala Capture Checking**(Scala 3.8 experimental): 型に capture set
   `T^{c1,c2}` を付け、ケイパビリティの到達・エイリアス・脱出を静的追跡。
   拡張の Separation Checking は read-only(`cap.rd`)/ exclusive の区別、
   `consume`(move)、hiding(エイリアス排除)まで扱う。GC 言語のまま
   Rust 的制約を部分導入するのが狙い。
2. **Flix region**: `region rc { ... }` で「すべての可変メモリは region に
   属する」を原則化。可変コレクションは `MutList[t, r]` のように region で
   パラメータ化され、可変メモリに触れる関数は effect row に `\ r` を持つ。
   寿命はレキシカルで、脱出は型(effect)が禁止する。
3. **OxCaml `[@zero_alloc]`**: 関数に注釈すると **call tree 全体が heap
   確保しないことをコンパイラが検証**し、違反箇所を span + バイト数付きで
   全列挙する。`local_`/`stack_`(escape 推論付き stack 確保)と
   `[@zero_alloc assume]`(escape hatch)、FFI の `[@@noalloc]` を併用。
   記事の CSV 集計例では allocation 除去で実測 2.12×。プロファイラで
   探して潰す(そして退行する)サイクルを「コンパイラが退行を拒否する」に
   反転させるのが本質。

## vibe の現状(2026-07-31 実測、main @ 4ce1c30)

評価の前提になる ground truth。

- **`let mut` は「共有・indefinite extent の可変セル」**。判定は単一述語
  `mut_needs_ref_cell`(`codegen/common_analysis/common_analysis.vibe`):
  closure に捕獲されたら heap-box(RC 下では class-8 RC セル、scalar 限定)、
  されなければ plain local。escape は自由で、`fn make_counter()` パターンは
  合法(実測 pin 済み、`docs/archive/mut-effect-plan.md`)。ADR-0060 の
  `Write[r]` 統一はこの実測と矛盾して停滞、taxonomy review が「retrofit は
  撤回し `region[r] {}` を opt-in で別途追加」とすでに結論している。
- **Perceus RC は production default**(ADR-0055 #493 cutover。`VIBE_RC=0`
  が opt-out で、compiler self-build の gate だけが性能理由で bump に pin)。
  実装済み: dup/drop/alias-dup 挿入、borrow-arg0/borrow-ret の whole-program
  fixpoint、owned-captures ABI(closure env が capture を所有、ADR-0076
  追記31)、exact-fit free list、shadow-liveness デバッグ lane。
  **未実装: drop-guided reuse / FBIP / TRMC / COW**(pl-survey の
  Medium #7 が「次の一手」と明記)。RC のコストは bump 比 wall ~1.6–2.1×、
  heap は数桁減。wasm-gc backend 比では **RC が 11–12× 速い**。
  **循環は恒久的にリーク**(意図的制限)。float は heap-box(NaN-boxing
  未着手 #510)。
- **generative region が既に1つ動いている**: `TaskGroup::run`(#1081)が
  rigid skolem `#region_N` を mint し、return 位置と outer binding への
  region 脱出を checker が reject(`err_region_escape_return.vibe` 等)。
  既知の穴2つが正直に記録されている — (a) generalize される `let`/`let mut`
  ローカル経由のリークは検出不能、(b) `TaskGroup::run` の literal 名
  マッチングは alias/HOF で素通り(構造マッチは誤爆で revert 済み)。
- **`Send` は compiler 判定の構造マーカー**(`checker_trait.vibe`):
  scalar / mut field 無し struct/enum / Option/Result / 同一 nursery
  endpoint / `FrozenArray[T]`(phantom-type 追跡)のみ。`Array`/closure は
  一律 non-Send。**`TypeEnv` は束縛の可変性を一切持たない**ため、
  spawn の `let mut` capture 検査は AST 構文 walk で別途実装されている
  (`checker_spawnable.vibe`)。
- **zero-alloc 検証は不在だが計測は異例に強い**: `vibe bench` の
  `bytes_per_op` は bump 決定的で CI が tight に gate(`alloc_bench` =
  10,400 B/op 固定)、selfcompile の `heap_ptr_bytes` も byte-deterministic
  で +10% gate。`--mem`/`--mem-sample`/`--alloc-site` の4層プロファイル。
  ただしコンパイラは「どの値が heap か」(Perceus の heap 分類)は知って
  いても**「この呼び出しが確保するか」を第一級には知らない**。
  profiling.md 自身が「正確な per-allocation 属性には確保サイト計装が要る」
  と書いている。

## 評価 A: Flix region — **採用推奨(vibe は既に半分決めている)**

### 適合性

Flix の形は、taxonomy review が ADR-0060 の訂正として書いた
「`region[r] { ... }` を opt-in で追加、escape-safety は second-class
capability として型検査」と**同型**である。つまりこれは新規判断ではなく、
既決の方向に Flix という実在の先行例と表面設計(region 付きコレクション +
effect row 統合)を与えるものになる。

```vibe skip
// 表面案 (ADR 化時に確定)。Flix: region rc { MutList.empty(rc) ... }
fn build() -> Array[Int] {
  region r {
    let l = MutList::empty[Int](r)     // MutList[T, r] — region でパラメータ化
    MutList::push(l, 1)
    MutList::push(l, 2)
    MutList::freeze(l)                 // 脱出は Frozen 化 / copy-out のみ
  }                                    // ← region 終端で arena 一括解放
}

// 可変コレクションに触れる関数は row に r を持つ (Flix の `\ r`)
fn fill(l: MutList[Int, r]) -> Unit with { r } { ... }
```

既存資産との接続が非常に良い:

- **effect row**: ADR-0071 の正規化は `NormalizedEffectArguments` に region
  引数 kind を既に予約している(`Write[router]` の想定)。`with { r }` は
  row 変数と同じ字面だが、region 変数として別 kind で正規化すれば衝突しない
  (effectset.md が「resource identity と nursery/borrow region を混同する
  な」と既に規定)。ADR-0084 の三分類では region effect は capability でも
  algebraic でもない「region 効果」だが、`main` に到達する前に region 終端
  で必ず discharge される(Flix と同じ)ので entry row 規則とは干渉しない。
- **checker 機構**: `TaskGroup::run` の rigid skolem mint + return/outer
  escape 検査がそのまま雛形。`Spawnable[r]` の同一 region 判定
  (`sp_same_region`)も流用できる。
- **命名**: ADR-0082 の語彙に `Mut-`(region 付き可変)を足すだけで一貫
  する — bare = persistent / `Mut*[T, r]` = region 束縛の可変 / `XBuilder` =
  freeze 前提 builder / `Frozen-` = Send 適格。既存 `HashMap` 等の
  「可変ハンドル」ファミリは region 化の移行候補。

### Perceus との相性(ここが最大の利点)

region は RC の**補完**であり競合しない。Koka 系譜(Perceus)+ region の
組み合わせは:

1. **RC トラフィックの除去**: region 内で確保された値は region より長く
   生きないことが型で保証されるので、**dup/drop を一切挿入しない**
   (Perceus プランナが region 型の値を skip する)。RC の wall コスト
   1.6–2.1× の主因が dup/drop とヘッダ操作である以上、ホットな可変処理を
   region に置くことはそのまま実行時間の回収になる。
2. **arena 一括解放が bump アロケータ上で自明**: linear backend は
   `__heap_ptr` の bump 確保なので、region 進入時に watermark を保存し
   終端で戻すだけで実装できる(region 内確保を連続領域に閉じる規律は
   escape 検査が保証する)。free list も個別 drop も不要。
3. **循環リークの解毒**: Perceus の恒久的制限(循環は回収不能)に対し、
   region 内で作られた循環構造は**終端の一括解放で回収される**。
   RC が構造的に持てない性質を region が足す。
4. **`let mut` は無変更**: taxonomy review の結論どおり、既存の
   heap-boxed `let mut` はそのまま(RC class-8 セルで回収される)。
   region はあくまで opt-in の高速 lane。

### 実行トレードオフと前提作業

- **前提: 既存 region 機構の穴を先に塞ぐ**。(a) generalize された
  `let`/`let mut` 経由の脱出検出 — 一般機能にするなら TaskGroup の
  「正直に未検出」では済まない。`TypeEnv` に可変性/region 情報を足すか、
  region 型の値の generalization を禁止するのが素直。(b) literal 名
  マッチング — `region r { }` を**構文**にすれば(TaskGroup と違い呼び出し
  ではないので)この問題は最初から発生しない。むしろ region 構文の導入は
  TaskGroup の literal-match 問題を後から解消する土台にもなる。
- **freeze/copy-out の境界**: 脱出したい値は `Frozen-` 化(コピー、または
  region 外 heap への move)を明示。ここで ADR-0082 の Frozen = Send 適格が
  効いてくる(region → 一般 heap → task 間、の段階的な自由度)。
- **wasm-gc lane は対象外**(linear 専用機能、suspend CPS と同じ前例。
  gc backend はそもそも CLI 非公開)。
- 注釈コスト: Flix 同様、可変コレクションを受け取る関数の row に `r` が
  増える。ただし vibe は row 推論の LSP 補完方針(taxonomy review)と
  裸 `with` の維持があるので、Flix より負担は小さくできる。

## 評価 B: Scala Capture Checking — **全面採用は非推奨、部品を3つ盗む**

### 非推奨の理由

- **土台が無い**: capture set は「すべての型」に付く第二の注釈次元で、
  subcapturing・boxing/unboxing・universal `cap` の格子を checker 全域に
  通す必要がある。vibe の row は文字列ラベル(OperationRef 正規化すら
  これから)で、`TypeEnv` は可変性情報を持たず、free-var 収集が3パッケージ
  に重複している現状(checker_spawnable が構文 walk へ後退した経緯)に
  capture set を retrofit するのは、ADR-0071/0084 の正規化作業より遥かに
  大きい。
- **本家がまだ experimental**(3.8.0-RC で CC が安定化途上、Separation
  Checking は開発中)。仕様が動く対象への追随は selfhost + seed 運用の
  vibe には特に高くつく。
- **得られるものの多くを既に別手段で持っている**: 「どの外部資源に触れる
  か」は effect row + ADR-0088 の `allows` 句が担い、read/write の分離は
  effectset(`Env::Read` / ADR-0075 の path-scoped read/write authority)が
  担い、task 間のエイリアス安全は `Send`/`Spawnable[r]`/`FrozenArray` が
  担っている。CC が上乗せする固有価値は「**同一スコープ内**のエイリアス・
  可変参照の個体追跡」であり、それは region(評価 A)が安い形で大部分を
  カバーする。

### 盗む部品(採用)

1. **escape/borrow 事実の Perceus 供給**: CC の本質は「この値はここから
   逃げない」の静的証明であり、それは RC では **dup/drop 省略(borrow
   推論)**として現金化できる。vibe は既に borrow-arg0/borrow-ret の
   fixpoint を持つ — これを「引数が escape しない関数」への注釈(推論)に
   一般化するのは CC の 1% のコストで CC の実行時利得の大半を取る。
   Koka の borrow 注釈、pl-survey の almide(alias-safety dataflow)と
   同じ流れ。
2. **`consume`(move)**: ADR-0068 の channel 移転・`Frozen-` 化 API に
   「呼び出し後は使用不可」のマーカーとして限定導入する価値がある
   (Send 判定の move 版)。CC 全体は不要で、関数パラメータ属性1つで足りる。
3. **read-only capability の overlay**(`Ref^{cap.rd}` 相当): region 導入後、
   `MutList[T, r]` に対する読み取り専用ビュー(`with { r.read }` 相当)が
   欲しくなったら、ADR-0071 の effectset(`r` の operation 部分集合)として
   表現できる — 新機構ではなく既存の graded subset(ADR-0088)の応用。

再評価トリガー: Scala の CC が stable になり、かつ region 導入後も
「同一 region 内のエイリアス起因バグ」が実際に頻発する場合。

## 評価 C: OxCaml `[@zero_alloc]` — **採用推奨(計測→検証の一段)**

### 適合性

vibe は OxCaml の記事が描く「プロファイラで探して潰す→退行する」問題への
対策を**計測側では既にやりきっている**(決定的 `bytes_per_op` の CI gate、
selfcompile heap ratchet)。欠けているのは関数単位の**検証**で、これは:

- linear backend では確保 = bump/`__rc_alloc` 呼び出しに正規化されている
  ので、**codegen 時に関数ごとの「確保命令を emit したか」を記録し、
  call graph で推移閉包を取る**だけで OxCaml 同等の検査になる。
  profiling.md が別目的(正確な per-alloc 属性)で要求している
  「確保サイト計装」と同じ工事の別出口。
- 診断も OxCaml の形(違反サイト全列挙 + span)を踏襲できる — vibe の
  diagnostics 基盤はそのまま使える。
- `assume` escape hatch(host import / FFI 相当は `@zero_alloc assume`)と、
  builtin registry へのフラグ追加(どの builtin が確保するか — registry は
  既に per-builtin メタデータの置き場)。

```vibe skip
// 表面案
@zero_alloc
fn sum_column(buf: Bytes, col: Int) -> Int { ... }   // 確保があれば compile error

@zero_alloc(assume)
fn input_unsafe(...) -> Int { ... }                  // 検査境界 (FFI/host)
```

### Perceus / region との相互作用(検討で判明した論点)

1. **RC 操作は確保ではない**: dup/drop は refcount の increment/decrement +
   free list 操作で、bump を進めない。よって RC default のまま
   `@zero_alloc` は成立する。ただし:
2. **暗黙の確保源が3つある** — (a) closure env(owned-captures ABI は
   creation 時に env block を確保)、(b) 捕獲された `let mut` の RC セル化
   (16B)、(c) **float の heap-box**(ADR-0055 で NaN-boxing 延期中)。
   `@zero_alloc` 関数内でこれらは全部エラーになる。特に (c) は
   「float を使うだけで zero_alloc が書けない」ことを意味し、#510
   (NaN-boxing)の優先度を実利で引き上げる。(a)(b) は OxCaml の
   `local_`/`stack_` に相当する回避(非捕獲化・stack 化)を促す診断が
   そのまま設計になる。
3. **region との合流**: region arena への確保を「heap 確保」と数えるかは
   選択の余地がある。OxCaml は `stack_` を確保に数えない — 同型で
   `@zero_alloc` は**region/stack 確保を許し、一般 heap のみ禁止**が
   実用的(strict 変種 `@zero_alloc(strict)` で全確保禁止)。これにより
   「region + zero_alloc」で『このホットパスは一般 heap に触れない』を
   機械検証でき、Flix 側の弱点(region は確保を減らさない、逃がすだけ)を
   OxCaml 側が補う。
4. **FBIP との順序**: drop-guided reuse(未実装、pl-survey Medium #7)が
   入ると match+再構築ループが in-place 化され、いま「確保あり」の
   コードが reuse 後は zero_alloc を満たすようになる。検査は **Perceus
   プラン(reuse 決定)後の codegen 段**に置くべき(OxCaml も最適化後の
   backend で検査している)。つまり実装順は「確保サイト計装 → zero_alloc
   検査 → FBIP で通る範囲を拡大」。
5. **HOF / row 変数**: callee が不透明な高階呼び出しは保守的に reject し、
   関数型への `@zero_alloc` 注釈(型の属性)は将来拡張とする。effect row に
   `Alloc` を足す案は不採用 — ほぼ全関数が確保する言語で row に載せると
   注釈が爆発する。OxCaml 同様「属性 + backend 検証」が正しい置き場
   (ADR-0084 の taxonomy にも「Alloc は effect atom にしない」を明記する)。

## まとめ: 相性マトリクスと実行トレードオフ

| | 型システム工事 | 実行時コスト | Perceus との関係 | vibe 既存資産 |
| --- | --- | --- | --- | --- |
| Flix region | 中(skolem/escape 検査は雛形あり、row の region kind は予約済み) | **負**(dup/drop 除去 + watermark 一括解放、循環も回収) | 補完(region 値を RC 対象から除外) | TaskGroup region、ADR-0082 命名、taxonomy review の既決方向 |
| Capture Checking | **大**(全型に第二注釈次元、TypeEnv 改修、本家 experimental) | ゼロ(純静的) | 中立(borrow 事実の供給源としてのみ有用) | ほぼ無し(consume/borrow の部品のみ接続可) |
| `[@zero_alloc]` | 小(codegen 側の per-fn summary + 推移閉包) | ゼロ(検証のみ。副次的に確保回避を誘導) | 相乗(reuse/FBIP で検証通過域が拡大、NaN-boxing の動機付け) | 決定的 B/op gate、alloc-site 計装要求、builtin registry |

**推奨順序**(すべて設計→ADR 切り出しの候補、実装は含まない):

1. **`region r { ... }` + region 付き可変コレクション**を ADR 化
   (ADR-0060 の後継。taxonomy review の「opt-in 追加」を Flix の表面で
   具体化)。前提として TaskGroup region 検査の穴 (a)(b) の解消方針を含める。
2. **`@zero_alloc`** を ADR 化(確保サイト計装と同時。region/stack 許容の
   既定 + strict 変種、assume、builtin registry のフラグ)。
3. Capture Checking は**不採用を記録**し、borrow 推論(Perceus dup/drop
   省略)・`consume` パラメータ属性・read-only effectset overlay の3部品を
   個別 backlog に。
4. FBIP/drop-guided reuse(pl-survey Medium #7)は zero_alloc の検証通過域を
   広げる後続として接続。

「可変状態を Effect で制御する」という当初の問いへの答えはこうなる:
**cross-scope の可変性は region 効果(`with { r }`)として row に現れ、
region 終端で必ず discharge される**(Flix 型)。`let mut` はローカルな
実装詳細として row に現れないまま(ADR-0060 撤回の維持)、確保の有無という
直交軸は row ではなく `@zero_alloc` 属性が担う(OxCaml 型)。エイリアスの
個体追跡(Scala 型)は、その2つで残る需要が実測されるまで導入しない。
