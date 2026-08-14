# wasm-gc lane: 参照が値 ABI を越えるための設計 (#1331)

作成日: 2026-08-04 / 対象 issue: [#1331](https://github.com/mizchi/vibe-lang/issues/1331)
前段: #1329 (non-escaping local array のネイティブ化), #1332 (ラムダ本体へ拡張)

## 1. 何が問題なのか

#1329 / #1332 で「**局所に閉じた**配列」だけが `(ref null $array)` の typed
local に載るようになった。それ以外 — 返り値、引数、別名、集約フィールド、
クロージャ捕捉、ジェネリック経路 — は linear memory の fallback のままである。

これは実装の手抜きではなく、**表現の非互換**が理由である。

### 1.1 根本制約

vibe の値表現は全レーン共通で **62-bit tagged i64** (2-bit タグ)。
gc レーンも例外ではなく、型セクションの関数型は全て `i64` (`0x7E`) で構成
されている (`codegen/gc/backend_body.vibe` の `emit_func_type_raw` 群)。

一方、wasm の参照型には**スカラーへ詰める手段が無い**。`(ref $array)` を
i64 に入れることは仕様上不可能で、`i64.reinterpret` 相当も存在しない。
これは意図された設計で、GC が参照を追跡できなくなるからである。

> **したがって「tagged i64 の統一値表現」と「GC 参照」は原理的に共存できない。**
> #1331 は最適化の話ではなく、値表現をどう作り直すかの話である。

この一文が本ドキュメントの全ての判断の根拠になる。

### 1.2 現状の gc レーンで実在する wasm-gc オブジェクト

| 型 idx | 中身 | 用途 |
|---|---|---|
| 11 | `(array (mut i64))` | alloc probe |
| 12 | `(array (mut i64))` | #1329/#1332 のネイティブ局所配列 |
| — | `(struct (mut i64))` | RC セル (#1416) |

**ユーザデータ (文字列・構造体・通常の配列) は linear memory にあり、tagged
i64 で指されている。** gc レーンは「wasm-gc バックエンド」という名前だが、
実体は *linear バックエンドと同じヒープモデル* に、局所配列だけの抜け穴が
空いた状態である。#1331 はこの構造を変える提案になる。

## 2. ご質問への回答: API 境界の externref は要るか

**結論: #1331 のスコープでは不要。ただし「同じ制約の別の顔」なので、設計が
それを塞がないようにする必要がある。**

根拠を分けて示す。

### 2.1 なぜ今は不要か

1. **gc レーンはコンポーネント/WIT 経路を通らない。**
   `cli_adapter.vibe` の `compile_source_gc_only` は「Direct source compile
   only; FS-import mode and the special instrumentation modes stay
   linear-backend-only」。WIT / canonical ABI / wasip3 は linear 専用である。
2. **ホスト import は raw tagged ABI。** gc レーンの host import 型は
   `(i64)->i64` / `()->i64` / `(i64,i64)->()` の3種だけで、文字列・バイト列は
   linear memory のポインタとして渡している。ホストは opaque な参照を持たない。
3. **ホスト側の状態は整数トークンで持つ。** `fs_stat_token` などは i64 を
   返し、実体はホスト側テーブルにある。この「ハンドル」パターンは externref
   無しで成立しており、実際に成立している。
4. **compiler 全体で `externref` / `anyref` / `eqref` の使用箇所はゼロ。**

### 2.2 externref が要求される条件

以下のいずれかが起きたときに初めて必要になる:

- **ホストが所有する不透明オブジェクトを vibe の値として持ちたい**とき
  (JS のオブジェクト、DOM ノード、ホスト側リソース)。これが externref の
  本来の用途であり、#1331 の「内部の参照が vibe 自身の関数境界を越える」
  問題とは**別の問題**である。
- ホスト関数が **GC 参照そのものを受け取る**必要が出たとき。ただし現状の
  JS API では wasm-gc の array を JS 側から添字アクセスする手段が無いため、
  これは近い将来の要求にはなりにくい。

### 2.3 コンポーネント境界では externref は答えにならない

仮に gc レーンが将来 WIT 経路を持ったとしても、**canonical ABI は linear
memory ベース**である。`list<u8>` は (ptr, len) に lower される。つまり
GC 配列はそのままでは越えられず、**境界でコピーする**のが正解であって、
externref を持ち出す話ではない。ここは混同しやすいので明記しておく。

### 2.4 それでも設計に効く点

externref も `(ref $array)` も、**「tagged i64 に詰められない値」**という
同一の制約を持つ。したがって §4 で導入する「参照レーン」— 静的型で決まる
ref 型の値スロット — は、**そのまま externref にも使える器**になる。

> 設計原則として本ドキュメントは、参照レーンの要素型を `$array` に
> ハードコードせず、**「ref 型の値スロット」という抽象**として定義する。
> これにより将来 externref を足すときに ABI の作り直しが起きない。
> 今 externref を実装することはしない (需要が無く、検証もできない)。

## 3. 却下した案

### 3.1 統一 `anyref` 表現 (今はやらない)

全ての値を `anyref` にし、スカラーは `i31ref`、それ以外は struct/array へ
ボックス化する。OCaml / Java / Scheme の wasm-gc バックエンドが取る正攻法。

**却下理由: vibe の `Int` は 62-bit だが `i31ref` は 31-bit しか入らない。**
`2^30` を越える Int が全てボックス化対象になり、コンパイラ自身のような
整数の重いコードで確保が激増する。値表現の全面変更でもあり、blast radius が
#1427 の比ではない。

長期の目標としては正しい方向なので §6 に条件付きで残す。

### 3.2 i64 ハンドルレジストリ

GC オブジェクトをテーブルに入れ、i64 の添字で参照する。

**却下理由: issue の acceptance criteria が明示的に禁止している**
("No i64-handle registry that permanently roots GC objects")。実際、
テーブルに入れた時点で GC から回収されなくなり、wasm-gc を使う意味が消える。

### 3.3 表現を動的に切り替える

値が GC 参照か linear ポインタかを実行時タグで見分ける。

**却下理由: 不健全。** 同じプログラム点で値が2つの表現を取りうると、
#1427 で踏んだ「宣言と実体の不一致」がスケールして再発する。
**表現は静的に一意でなければならない**、というのが本設計の中心的な不変条件。

## 4. 採用する設計: 型主導の参照レーン (phased)

### 4.1 中心となる不変条件

> **プログラムの各点で、各値の表現はただ一つに静的に決まる。**
> 表現が変わる箇所には、**明示的な変換点**が存在する。

この不変条件を破らない限りにおいて、参照が越えられる境界を段階的に広げる。

### 4.2 表現の決定

checker の静的型から、各スロット (パラメータ / 返り値 / ローカル / フィールド)
の表現を決める:

| 静的型 | 表現 |
|---|---|
| `Array[T]` (T が対応要素型) かつ 非ジェネリック文脈 | `(ref null $array)` — 参照レーン |
| それ以外 | tagged i64 — 既存レーン |

ジェネリックな `fn id[T](x: T) -> T` は `T` が配列かどうか静的に決まらない
ので、**ジェネリック関数は常に i64 レーン**とする。配列をジェネリック関数へ
渡す箇所が §4.1 でいう変換点になる (linear memory へ materialize する)。

### 4.3 段階

各段階が単体で健全であること (= 中途で止めても正しい wasm が出ること) を
条件にする。

| Phase | 越えられるようになる境界 | 主な作業 | issue / 備考 |
|---|---|---|---|
| **A** | **返り値・引数** (非ジェネリックな直接呼び出し) | 関数型を静的型から導出。呼び出し側と定義側で型が一致することの検証 | **#1541**。acceptance の1つ目。ここだけで実用価値が出る |
| **B** | **別名・局所束縛** | 既存の `gc_native_array_locals` の追跡を関数間へ拡張 | **#1541** (A と同一スライス)。private concrete `Array[Int]` の直接経路、1 段の immutable local alias、自己/相互再帰、ローカル配列の返却、両腕が参照レーンの `if` join は着地済み。identity fixture と native allocation site 数の gate で固定。import / indirect call / closure capture / aggregate / global、および裸リテラルを腕に持つ join は未対応のまま fail-closed |

#### ジェネリックの共存 (2026-08-13)

Phase A/B の島は当初、**モジュール内にジェネリック宣言が 1 つでもあれば
component 全体で無効**だった。`strip_generic_type_params` が binder を消すので、
消去後の署名を単相なものと区別する手段が無かったためである。これは fail-closed
としては正しいが、実コードにジェネリックが無いことはまずないので、島は
fixture の中でしか点かないという状態だった。

現在は消去前に**ジェネリック宣言の名前**を集めて codegen へ渡す
(`gc_direct_abi_pre_erasure_generic_names`)。拒否の強さは変えていない:

- ジェネリック宣言が参照レーンの型 (`Array[Int]`) を署名に持つ →
  **従来どおり component 全体を i64 レーンへ落とす** (変換点がまだ無い)
- ジェネリック宣言が参照レーンの値を触らない → 島の候補にならないだけで、
  **島は生きたまま**。参照をそこへ渡そうとすれば `gc_direct_abi_expr_kind` が
  従来どおり component 全体を拒否する

binder は 2 か所を見る必要がある。`strip_generic_type_params` の**後**に
`inject_method_generics` が impl メソッドへ binder を貼り直すので、消去前の
名前リストだけでは足りず、post-strip の `type_params` も併せて見る
(`backend_body.vibe` の `dai_is_generic`)。

対の fixture: `fixtures/gc_direct_array_generic_coexist_test.vibe` (島が生きる)
と `fixtures/gc_direct_array_argument_fallback_test.vibe` (ジェネリック自身が
`Array[Int]` を運ぶので落ちる)。

#### 受理判定と escape gate の一致 (2026-08-13)

**これは最適化ではなくバグ修正だった。** component 受理を決める
`gc_direct_abi_expr_kind` と、ローカルが実際に native になるかを決める
`gc_native_array_escape_gate` (旧 `gc_native_array_body_is_safe_tail`) は、
別々に判断していた。前者が「この `let` は参照レーン」と受理したのに後者が
native 化を拒否すると、呼び出し側が存在しない参照を要求し、codegen が
`gc direct ABI proof mismatch` で**コンパイル自体に失敗する**。正しい vibe
プログラムが落ちる:

```vibe skip
fn mutate_first(values: Array[Int]) -> Unit { Array::set(values, 0, 7) }

test "..." {
  let xs = [1, 2]
  let peek = () -> Array::get(xs, 0)   // 捕獲 → escape gate は native を拒否
  mutate_first(xs)                      // 受理側は参照だと思っている
  inspect(peek(), "7")
}
```

受理側が `let` を参照レーンへ入れる前に**同じ gate に問い合わせる**ようにした。
gate が拒否したら束縛は普通の i64 ローカルのままで、参照を要求する呼び出しが
あれば component ごと fallback する (fail-closed)。gate は ctx ではなく
evidence table を直接読む形に分けてあり、両者が同じ述語を見る。

副次的に、`Array::push` を使うローカルが**隣の束縛を巻き添えにしなくなった**
— 従来は component 全体が落ちていたので、`gc_heap_churn_test` の
`let xs = [8]; xs` (ローカル配列を返す) が linear fallback だった。今は
参照レーンに乗り、同 fixture の guest bump 確保は 320 B → 244 B。

#### 制御フロー join (2026-08-13)

両腕が**すでに参照レーン**の値である `if` は、それ自体が
`(ref null $native_i64_array)` を返す。位置は 2 つ: 参照結果を返す関数の tail と、
証明済みの参照引数。

typed reference には 1 バイトの value type 綴りが無いので、blocktype は
**型インデックス**を指す (`(func (result (ref null 12)))` を base type 13 に予約、
`emit_if_type_index`)。base type にしてあるのは、body が type section より先に
生成されるため、インデックスが定数である必要があるから。

**裸の配列リテラルを腕に持つ join は依然 fallback。** リテラルはまだ自分の表現を
持っておらず (消費側が決める)、`if` には寄りかかれる消費側の証明が無い。
対の fixture: `fixtures/gc_direct_array_join_test.vibe` /
`fixtures/gc_direct_array_join_fallback_test.vibe`。

#### 要素型 (2026-08-13)

§7 の未解決 2 のうち「`(array (mut f64))` にするか」は**やらない**で確定済み
(#1542 の 2026-08-07 コメント)。一方、**認識できる要素型**の話はそれとは別で、
`Array[Int]` だけに絞られていたのは保守的な制限だった — native 配列のセルは
`(mut i64)` に**ただの tagged 値**を置いており、それは linear memory が同じ要素に
対して置くバイトと同一なので、要素型は表現を変えない。

`Array[String]` / `Array[Bool]` を許可した。**allowlist のままにしてあるのは
fit の問題ではなく認識の問題** — `strip_generic_type_params` の後、
`fn f[T](xs: Array[T])` の要素は `TyName("T")` と綴られ、同名の具体型と区別が
つかない。よって型変数になり得ない綴り (builtin scalar) だけを入れる。

**ネストした配列は別の理由で対象外**: `Array[Array[Int]]` のセルは参照を持つ
必要があるが、i64 セルに参照を入れる手段は仕様上無い (§1.1 の根本制約そのもの)。

fixture: `fixtures/gc_direct_array_element_types_test.vibe`。

#### export 境界との共存 (2026-08-13)

CLI entry と公開宣言は tagged i64 の host 境界を越えるので参照を運べない。
これは変わらないが、従来は**そういう宣言が 1 つあると component 全体で島が
消えていた** — `export` はライブラリモジュールの通常の形なので、ジェネリックの
件と同じく実コードでは常に消えていたことになる。

今は単に**島の候補にならないだけ**で、署名は従来どおり全 i64 のまま。残りの
component は参照レーンを使える。**変換点は要らない** — 参照を export へ渡す
のは未対応の crossing として `gc_direct_abi_expr_kind` が従来どおり component
全体を拒否し、export から**戻ってくる**値は kind 0 なので native local に
ならない。

対の fixture: `fixtures/gc_direct_array_export_coexist_test.vibe` (島が生きる)
と `fixtures/gc_direct_array_abi_export_fallback_test.vibe` (private な参照を
export 経由で通すので落ちる)。gate は「コンパイルが通った」ではなく
**公開宣言が tagged-i64 ABI のままであること** (参照を運ぶ関数署名は private な
mutator ちょうど 1 つ) を assert する。

なお spelling-routed な衝突 (`Array::get` などの綴りを持つユーザ宣言) は
**署名に参照が無くても component 全体を落とす**ままにしてある。これは過剰では
なく、backend_call が native receiver に届くためにその綴りを横取りしているので、
ユーザ宣言があると横取り自体が誤りになる — この島を必要としない #1329 の
ローカルレーンに対しても誤る。
| **C** | **集約フィールド** | ユーザ構造体を実 wasm-gc struct へ (ADR-0052 の `struct.set` 経路の一般化) | **#1542**。ヒープモデルの変更を含み、最も重い |
| **D** | **クロージャ捕捉** | funcref テーブルの型が現状 arity 別 `(i64...)->i64` のみ。型別に増やすか、捕捉は i64 固定にするか | **#1543**。表が型ごとに増える点が最大の論点 |

**Phase D の注意:** `call_indirect` は型が厳密一致でなければ trap する。
arity のみで型を決めている現状 (`num_closure_types`) に要素型の次元を足すと
テーブル型が組合せで増える。Phase D 着手時に、
(i) クロージャ境界は i64 固定にして変換点を置く、
(ii) 型別テーブルを持つ、
のどちらかを別途決める。**現時点では (i) を暫定の既定とする** — #1332 の
安全述語 `gc_native_array_body_is_safe` が `EFn => false` を返すのは、まさに
この境界が未解決だからで、Phase D までその判定は据え置きでよい。

### 4.4 検証戦略

表現の不一致は **wasm が validate に通らない**形で現れる。これは幸運で、
`wasm-tools validate --features all` が強力な網になる。#1332 で CI 化した
`gc-gate` (`scripts/test_gc_heap_accounting.sh`) をこの網の設置場所とする。

各 Phase で必須:

1. `fixtures/gc_heap_churn_test.vibe` に、その Phase で**越えられるように
   なった**ケースと、**まだ越えられない**ケースの**対**を足す。
   ネイティブ化サイト数の固定値がその境界の証明になる (#1332 で確立した型)。
2. `wasm-tools validate --features all` を通す。
3. `VIBE_MEM=1` の確保量が Phase 前より増えないこと。

### 4.5 linear バックエンドへの影響

**ゼロ。** 表現の決定は gc レーンの codegen 内部に閉じる。checker は静的型を
提供するだけで、表現の選択には関与しない (`Array[T]` という型情報は既にある)。
acceptance の "Linear backend output and behavior remain unchanged" は、
gc レーン外のファイルを触らないことで構造的に担保する。

## 5. wasm proposal 水準への影響

[feature-levels.md](feature-levels.md) の基準では、生成 wasm は
**flag 無しで動く proposal のみ**に依存してよい。

- `gc` proposal は 2026-07-27 スナップショットで `v8` / `web-baseline` の
  両水準で **safe**。Phase A–C は新たな proposal 依存を増やさない。
- Phase D で仮に型別 funcref テーブルを採るなら `function-references` が
  必要になる。着手時に feature matrix を確認すること。
- externref (reference-types) は core wasm 2.0 で全エンジン safe。**要求が
  出たときの障壁は proposal 水準ではなく、§2 の設計上の必要性の有無**である。

## 6. 長期: 完全な wasm-gc ヒープ

§3.1 の統一 `anyref` 表現は、**gc レーンが parity 用の実験レーンである間は
割に合わない**。以下が揃ったときに再検討する:

- gc レーンを production 既定にする意思決定がある (現状の既定は linear)
- `Int` の 62-bit を諦めるか、i31 + ボックス化のコストを実測して許容できる
- linear memory 上の文字列/構造体を全て wasm-gc へ移す工数を取れる

そのときは Phase A–D の型主導レーンが土台になる — 表現の静的決定という
不変条件 (§4.1) は統一表現でもそのまま必要だからである。

## 6.5 `Bytes` は linear memory に留める (実測付き)

本設計の対象は `Array[T]` であり、**`Bytes` は対象外**とする。理由は2つで、
どちらも実測・仕様の裏付けがある。

**1. SIMD は wasm-gc 配列では成立しない。** `v128.load` はメモリアドレスを
取る命令で、GC 配列はアドレス可能なメモリではない。`(array i8)` から v128 へ
一括ロードする命令は wasm-gc に存在しない (`array.copy` / `array.fill` /
`array.new_data` はあるが、配列↔配列・データセグメント間のみ)。
**したがって `Bytes` を GC 化すると SIMD を得るのではなく失う。**
`simd_skip_ws` / `simd_scan_alnum` は当初 linear 専用として登録されていたが、
`Bytes` が両レーンとも linear memory 上にある以上 gc で動かない理由は無く、
単なる登録漏れだった (両レーンへ登録済み。gc-gate が回帰を押さえる)。

**2. バイト経路は既に速い。** 2026-08-04 の実コンパイル計測
(`codegen_lexer_test.vibe` full closure, 7.6s, `node --cpu-prof` の self time):

| ランタイム関数 | self |
|---|---:|
| `__rt_arr_slice` | 8.8% |
| `__rt_arr_new` | 8.3% |
| `__rt_arr_push` | 6.4% |
| `__rt_arr_get` | 3.7% |
| **Array 系 計** | **27.2%** |
| `__rt_bytes_push` | 1.0% |
| `__rt_bytes_append` | 0.9% |
| **Bytes 系 計** | **1.9%** |

wasm 出力バッファは `Bytes` で、`bytebuf_push_buf` は `Bytes::append`
(= `memory.copy` 1発)、`Bytes::push` は容量倍々 (64 起点) の償却 O(1)。
**バイト組み立ての残り伸びしろは全体の 2% 未満**であり、ここを `Bytes::blit`
へ寄せる最適化の期待値は小さい。

対して Array 系が 27%、その最大の呼び出し元は perceus の
`pctx_new` (361ms) + `copy_ints` (225ms) = **全体の 7.7% がコンテキスト複製**
である。**性能改善の当たりはバイト列側ではなく、作業配列の持ち方にある。**
これは #1262 の系列であり、本 ADR のスコープ外として別途扱う。

## 7. 未解決の論点

着手前に決める必要があるもの:

1. **Phase D のクロージャ表現** (§4.3)。暫定は「i64 固定 + 変換点」。
2. **要素型の範囲。** 現状の `$array` は `(array (mut i64))` で要素が tagged
   i64。`Array[Double]` を `(array (mut f64))` にするかは別問題として切り離す
   (今回の対象外)。
3. ~~**変換点のコスト。**~~ **決着 (2026-08-14, #1701)。実測して単相化を採る。**
   下の §7.1 を参照。

### 7.1 変換点の意味論 — 境界の単相化を採る (2026-08-14, #1701)

§4.1 の不変条件は「表現が変わる箇所には明示的な変換点がある」と言うだけで、その
変換点が**何をするか**は決めていなかった。§4.3 の Phase A の記述は「linear memory
へ materialize する」= **コピー**を示唆していたが、`Array[T]` は可変なので
コピーは identity を壊す — 呼び出し先の変更が呼び出し元から見えなくなる、
triage 最上位の「黙って誤る」形になる。

3 候補を**実測して**決めた。Phase A (#1541) が着地して初めて越境が測れるように
なったので、ADR 制定時にできなかった比較ができた。

`bench/regression/gc_boundary_bench.vibe` / `gc_boundary_copy_bench.vibe`
(400 iters, p50、参照レーンが乗っていることを `VIBE_BENCH_EMIT_WASM` で実物確認):

| | 実行時 | サイズ | identity |
|---|---|---|---|
| **境界の単相化 (採用)** | **±0** | +1〜6% (下限見積) | **保たれる** |
| materializing copy | **+76%** (レーン無しより遅い) | ±0 | **壊れる (P0)** |
| 島の外に固定 (現状維持) | ±0 | ±0 | 保たれる |

参照レーン自体の価値は **-22% / guest bump 確保ゼロ** (linear 91ns → gc 71ns)。
コピーは 160ns で、**レーンの利得を食い潰すどころかレーンが無い状態より遅い**ため、
identity の問題を抜きにしてもコストだけで落ちる。

**採用: 境界の単相化。** 越境する呼び出しを参照版と i64 版に複製し、呼び出し側の
表現で選ぶ。コピーが無いので identity は自明に保たれ、越境の実行時コストはゼロ。

サイズの見積もりは**下限**である点に注意 — 複製 1 関数あたり ~43B を、`lib/` の
「`Array[..]` を受けて返す関数」485 件 / 「署名に `Array[..]` を持つ関数」3,166 件に
掛けたもので、**推移的な複製 (複製関数の callee も両版が要る場合) を勘定していない**。
爆発が起きるとしたらそこなので、実装は推移的複製の係数を測りながら進める。
