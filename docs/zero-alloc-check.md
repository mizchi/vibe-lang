# ADR-0091: `#zero_alloc` — 関数単位の確保検証(OxCaml 型)

Status: proposed

Date: 2026-07-31

Related: ADR-0055(RC)、ADR-0090(region)、ADR-0092(reuse — 実装順は
本 ADR より先)、#510(NaN-boxing)、
[mutability-control-review.md](mutability-control-review.md)、
`docs/spec/profiling.md`(確保サイト計装の要求)。参考: OxCaml
`[@zero_alloc]` / `[@zero_alloc assume]` / `local_`、Swift
`@_noAllocation`、Clang `nonallocating`。

## Context

vibe の確保**計測**は完成度が高い(決定的 `bytes_per_op` の tracked
series、byte-deterministic な selfcompile heap gate、`--mem`/`--mem-sample`/
`--alloc-site` の4層)。欠けているのは**検証** — 「この関数(の call tree)
は確保しない」をコンパイラが保証し、退行をビルド失敗にする機構が無い。
プロファイラで見つけて潰しても、ホットパスに1行足せば黙って戻る。
OxCaml はこれを関数注釈 + backend 検査で反転させた(違反サイトを span +
サイズ付きで全列挙)。linear backend では確保が bump/`__rc_alloc` 呼び出し
に正規化されているため、vibe での実装コストは小さい。

## Decision

### 1. 表面と意味論

```vibe skip
#zero_alloc
fn sum_column(buf: Bytes, col: Int) -> Int { ... }
// 本体 + 推移的 callee のどこかに確保があれば compile error。
// 診断は OxCaml 同様、確保サイトを span + 種別(ctor/closure env/
// mut-cell boxing/float boxing/builtin 名)付きで全列挙する。

#zero_alloc(strict)
fn hot(...) -> Int { ... }        // region/stack 確保も含めて全面禁止

#zero_alloc(assume)
fn host_shim(...) -> Int { ... }  // 検査境界 (FFI/host import 相当)。呼ぶ側は信頼
```

現行 Phase 1 が受理する canonical syntax は引数なしの `#zero_alloc` のみ。
`strict` / `assume` は上記の予約設計であり、実装されるまでは parse error にする。
旧 `@zero_alloc` は移行互換として当面受理するが、新規コードでは使わない。

- **既定は「一般 heap のみ禁止」**: region arena(ADR-0090)への確保と、
  将来の stack 化された確保は数えない(OxCaml の `stack_`/`local_` と同じ
  扱い)。`strict` 変種が全確保禁止。
- **ADR-0092 の reuse による in-place 再利用は確保に数えない**(Koka FP²
  の `fip` と同じ意味論)。このため検査は **Perceus プラン(reuse 決定)
  後の codegen 段**に置く — OxCaml が最適化後 backend で検査するのと同型。
  実装順を ADR-0092 → 本 ADR とするのはこのため(逆順だと reuse 着地の
  たびに「通るようになる」annotation churn が起きる)。
- **確保は effect row の atom にしない**(不採用を明記)。ほぼ全関数が
  確保する言語で row に載せると注釈が爆発する。属性 + backend 検証が
  正しい置き場であり、ADR-0084 の taxonomy にも影響しない。

### 2. 検査の実装

- codegen(linear backend)で関数ごとに「確保命令(bump / `__rc_alloc` /
  arena alloc)を emit したか」のサマリを記録し、call graph で推移閉包を
  取る。`#zero_alloc` 関数の閉包に確保があれば、各サイトを列挙して error。
- **builtin registry に確保フラグを追加**する(registry は per-builtin
  メタデータの既存の置き場)。host import 自体は確保しない扱いだが、
  確保する builtin(`String::concat` 等)はフラグで拒否される。
- **HOF / row 変数 callee は保守的に reject**(不透明な間接呼び出しを
  含む関数は `#zero_alloc` を満たせない)。関数型への `#zero_alloc` 属性
  (「確保しない関数だけ受け取る」)は将来拡張として予約し、v1 では
  導入しない。
- 対象は linear backend のみ(wasm-gc は engine GC 任せで意味を持たない)。

### 3. 予見される診断(= 言語側への圧力、意図的に記録する)

`#zero_alloc` は次の3つの暗黙確保を可視化する。これはバグではなく機能で
あり、それぞれ既知の改善項目への実利的な動機付けになる:

1. **float の heap-box**(ADR-0055 で NaN-boxing 延期中): `#zero_alloc`
   関数内で float を使うとエラーになる。#510 の優先度を実needsで上げる。
2. **closure env の確保**: 非捕獲化(トップレベル関数化)を促す診断を
   出す。
3. **捕獲された `let mut` の RC セル化**(16B): 非捕獲化または region
   への移行を促す。

RC の dup/drop 自体は確保ではない(refcount 操作 + free list)ので、
RC default のまま `#zero_alloc` は成立する。

### 4. 計測基盤との接続

- 確保サイトのサマリ記録は、profiling.md が「正確な per-allocation 属性に
  必要」としている**確保サイト計装と同じ工事の別出口**として実装する
  (`--alloc-site` の関数粒度 leaf 帰属の既知の弱点も同時に解消する)。
- `bench/regression` に `#zero_alloc` 付き bench を追加し、
  `bytes_per_op == 0` を tracked series と検査の両方で二重に固定する
  (検査が「0 であるべき」を、計測が「実際に 0」を保証する)。

## Non-goals

- effect row への `Alloc` atom(Decision 1 で不採用を明記)。
- fip/fbip の独立注釈(ADR-0092 Decision 4 — `#zero_alloc` に一本化)。
- wasm-gc backend、mid-function の部分注釈(ブロック単位)、確保上限の
  数値指定(`@alloc_budget(n)` のような形)— 需要が出てから。

## Implementation sequence

1. builtin registry の確保フラグ + codegen の per-fn 確保サマリ
   (確保サイト計装と同時)。
2. `#zero_alloc` / `(strict)` / `(assume)` の属性構文(新構文 — bootstrap
   運用は ADR-0088/0090 と同じく「compiler source が使うまで bump 遅延」)。
3. 推移閉包 + 全サイト列挙診断。err fixture(ctor / closure env /
   mut-cell / float / builtin / HOF reject)+ 正常系 fixture。
4. ADR-0092 reuse との合流(reuse 済みサイトを非確保として扱う)、
   ADR-0090 region との合流(既定で arena 確保を許容)。
5. `bytes_per_op == 0` bench の tracked series 追加。

## Phase 1 implementation notes (2026-07-31, #1262)

最初の縦串が landed した。設計との差分・既知ギャップ:

- **構文**: `#zero_alloc` は既存の `#cfg` / `#deprecated` と同じ directive
  経路で parse され、内部では互換 marker `SExpr(EIdent("@zero_alloc"))` に
  正規化される。checker(`checker_stmt.vibe` の SExpr branch)が
  この marker だけ ADR-0069 reject と名前解決を skip し、linear backend は
  top-level SExpr を従来どおり drop する。parser は直後が `fn` / `export fn`
  であることをファイル単位で検査し、marker はその宣言
  (lowered: `SLet(_, _, name, _, EFn(..))`)に付く。`(strict)` / `(assume)`
  修飾は未実装。
- **検査**(`common_analysis.vibe::zero_alloc_check`、
  `compile_wasi_module_linked_impl` 冒頭で実行): AST レベルの保守的走査。
  確保扱い = ctor(enum variant / suberror / struct 名、呼び出しと裸 ident
  両方)、tuple/array/record/map literal、string interpolation、closure
  literal、float literal(linear backend の heap-box)、effect handler、
  safe-builtin allowlist(read / in-place write 系のみ)外の builtin 呼び、
  間接呼び出し。top-level fn 呼びは推移的に走査(visited set で再帰安全)。
  診断は `zero_alloc: fn 'X' may allocate: <site>`(経由呼び出しは
  `call to 'Y' which may allocate: ...` で連鎖)。
- **既知ギャップ(Phase 1 で許容)**: 二項演算子は type-blind — String/
  Double 型の**変数**への `+` 等(確保する concat / boxing に落ちる)は
  検出できない(literal operand のみ検出)。per-fn サマリの codegen 計装
  (ADR 本文 step 1 の「確保サイト計装」)は未着手 — 検査は AST 走査で
  先行。module body 内の fn、wasm-gc backend、`bytes_per_op == 0` bench
  series、ADR-0092 reuse / ADR-0090 arena との合流(step 4-5)も未着手。
- **gate**: `compiler_gate.sh` §75(positive `zero_alloc_ok.vibe` = 42 /
  negative `err_zero_alloc_ctor.vibe` needle "zero_alloc")。

## Reconciliation ledger

| 項目 | 根拠 / 観測 | 結論 |
| --- | --- | --- |
| 期待する契約 | 確保ゼロを退行からコンパイラが守る | 属性 + backend 検証(OxCaml 型)。row atom は不採用 |
| 実装観測 | 確保は bump/`__rc_alloc` に正規化済み、計測は決定的 gate 済み | 検証は per-fn サマリ + 推移閉包の小工事。計装は profiling.md の既存要求と同一工事 |
| 実装観測 | float heap-box / closure env / mut-cell RC 化という暗黙確保が3つ | 診断で可視化し、#510 等の優先度根拠にする(意図的) |
| 実装順 | reuse(ADR-0092)後に検査を置くと通過域が最初から広い | ADR-0092 → 本 ADR の順(検査は Perceus プラン後の codegen 段) |
| 回帰ガード | err/正常 fixture、`bytes_per_op == 0` の検査×計測の二重固定 | Phase 3/5 で固定 |
