# ADR-0052: struct field の `mut` 修飾子

- Date: 2026-05-23
- Status: accepted (Phase 1 完了)
- Related: ADR-0017 (let mut / Ref[T]), ADR-0021 (Mut effect handler),
  ADR-0004 (content-addressed modules), ADR-0040 (checker/codegen contract)

## Context

現状、struct field は immutable のみ。mutable な内部状態は **`Array[T]` /
`Bytes` / `StringBuilder` などの mutable container を field に持つ** 形で
表現するのが慣習で、コンパイラ自身も多数の箇所でこのパターンを使う:

```moonbit
// src/core/codegen/common_base/index.vibe より
struct FuncTable {
  names: Array[String];       // ← Array::push で mutate
  indices: Array[Int];
  params: Array[Int];
  returns: Array[Int];
  needs_env: Array[Bool]
}
```

これは「意味論的には mutable struct field が既に許されているが、表面構文として
1要素 mutable container を手で書かされている」状態。`vibe/x/zlib` のドッグ
フード作業 (`docs/report/zlib-dogfood-2026-05-23.md`) で同じパターンに遭遇:

```vibe
// 自然な書き方 — parse error
struct BitReader {
  buf: Bytes
  mut byte_pos: Int
  mut bit_pos: Int
}

// 現状の書き方 — ~25% 行数増、indirection 増
struct BitReader {
  buf: Bytes;
  state: Array[Int]    // [byte_pos, bit_pos]
}
```

### ADR との関係

- **ADR-0004** は content-addressed identity を要求するが、これは *構文 hash* に
  対する制約であり、ランタイム時のフィールド値の mutability そのものは制約しない。
  既存の `Array[Int]` を field に持つ struct も hash 可能になっている。
- **ADR-0017** は `let mut` を局所状態として認め、`Ref[T]` を escape 分析の実装
  コストを理由に abandon した。本 ADR は escape 分析を要求しない (理由は §決定)。
- **ADR-0021** は mut state を effect として抽象化する道筋を提供するが、これは
  「大きな状態機械を perform/handle 越しに渡す」ユースケース。bit reader の
  cursor のような **オブジェクトに閉じた極小の局所状態** には effect は過剰で、
  「struct 内部の小箱」として `mut` field の方が適切。

つまり ADR-0017 / ADR-0021 と本 ADR は補完関係であり、どちらかが他方を吸収する
ものではない。

## Decision

**`mut` を struct field 修飾子として認める。表面構文を入れるだけで、新しい
不変条件は導入しない。** 既存の「`Array[T]`-of-length-1 セル」パターンへの純粋な
syntax sugar として実装する。

### 構文

```vibe
struct BitReader {
  buf: Bytes;
  mut byte_pos: Int;
  mut bit_pos: Int
}

let r = BitReader::{ buf: data, byte_pos: 0, bit_pos: 0 }
r.byte_pos = r.byte_pos + take   // assignment 可
let p = r.byte_pos               // read は普通に値を返す
```

### Lowering

Frontend desugar pass (`src/frontend/desugar.mbt`) で:

1. **struct 定義**: `mut name: T` フィールドは内部で `name__cell: Array[T]`
   (長さ 1) として保存する。コンテンツアドレス hash の安定性のため、
   normalize 段階 (`src/core/normalize.mbt`) で同じ表現に潰す。
2. **struct リテラル**: `BitReader::{ byte_pos: e, ... }` の `mut` field は
   `[e]` で wrap。
3. **field read**: `r.byte_pos` は `Array::get(r.byte_pos__cell, 0)`。
4. **field assign**: `r.byte_pos = e` は `Array::set(r.byte_pos__cell, 0, e)`。
   immutable field への代入は既存の checker エラー (assignment to non-mut
   binding) を流用。
5. `r.byte_pos += e` 系の compound assign も既存の `let mut` 経路と統一。

### 不変条件

- **新たな escape 分析は導入しない**。`Array[T]` field の挙動と完全に等価。
  即ち struct 値を別 fn に渡すと、その fn は `mut` field を書き換え得る。
  これは既存の `Bytes::push(buf, ...)` を渡す行儀と同じ責任モデル。
- **content-addressed hash** は struct 定義 (mut 修飾を含む) の構文形に対して
  計算する。値そのものではない。lowering 後の表現は `Array[T]` field と
  同じ shape になるので、`ir_hash` レベルでは「もとから Array[T] で書いていた
  struct」と「mut フィールドで書いた struct」が衝突する可能性がある。これは
  *意図された等価性* として受け入れる。誤って衝突したくなければ、ユーザは
  異なる struct 名を付けるか、メタ情報 (例: `derive(Debug)` の自動生成名)
  を付与すれば良い。
- **shape level の `mut` 情報を AST に残すか?** — 残す。`StructFieldDecl` に
  `is_mut: Bool` を追加し、checker 側で「mut 宣言されていない field への
  代入はエラー」を区別する。lowering 後は型レベルでは Array[T] と同じだが、
  チェック段階で「assign 許可」を判別するために必要。
- **derive(Eq) / derive(Debug)** との関係: `mut` field は単に値の現在状態を
  比較/表示する。`Array::get(_, 0)` 経由になるだけで、特別扱いしない。

### 非対象 (out of scope)

- **mut field を持つ struct を関数の return 値にする** — 許可。`FuncTable` を
  返している既存コードと同じ。
- **mut field を持つ struct をグローバル状態に保持する** — 許可。これは
  ADR-0017 の `state_local` 区分外の振る舞いだが、`Array[T]` を持つ struct も
  同じく許可されている以上、本 ADR で新たな禁止は入れない。
- **mut field の async / spawn 越えの捕捉** — ADR-0017 と同じ立場で禁止 (将来)。
  本 ADR の Phase 1 では検査を入れず、`Array[T]` field と同様の責任モデル。
- **mut field の参照を closure に渡して escape** — 同じく Phase 1 では不問。

### Phase

- **Phase 1** (本 ADR): syntax + checker (非 mut field assignment は error) +
  両 backend codegen (wasm-gc は `struct.set`、linear は record pair の
  値スロット上書き)。escape 分析なし。
- **Phase 2** (別 ADR): ADR-0017 の `state_local` effect 区分が実装された
  ときに `mut` field を持つ struct を `state_local` に分類する。content-
  address の同一性は `pure` / `state_local` を決定的とする既存方針と整合。
- **Phase 3** (別 ADR): mut field の参照 escape を検査する soundness 強化。
  ただし `Array[T]` field との一貫した制約として導入する (本 ADR の sugar
  だけ厳しくしない)。

### 実装メモ (Phase 1 完了時点)

- 採用は最終的に「Array[T] sugar」ではなく **両 backend で native struct
  mutation** に落ち着いた。
  - **wasm-gc**: `try_compile_struct_field_set_gc` / `try_compile_struct_field_get_gc`
    を `__index` / IndexAssign の string-literal case で呼ぶ。
    付随して `sort_record_fields_expr` の lex sort バグを修正
    (MoonBit `String <` が length-first だったため named struct と
    literal の anonymous 型が dedupe で別物になり cast failure を吐いて
    いた; `record_field_name_lt` で char-by-char に統一)。
  - **linear**: `__set_index` の string-literal case で、`__index` と
    同じ (name_ptr, value) ペアレイアウトを線形検索して値スロットを
    in-place 上書き。`emit_i32_store` で wasm linear memory に書き戻す。
- Checker は `core.StructField.is_mut` を `checker.StructFieldDef.is_mut`
  に伝播し、`Stmt::IndexAssign` (typecheck_stmts.mbt と typecheck_expr.mbt
  の両方) で string-literal index の場合に struct を引いて mut チェックを
  実行。
- Content-address hash (`structural_hash`) は `is_mut` を folding する
  ので、`struct S { mut x: T }` と `struct S { x: T }` は別 hash になる。

## Consequences

良い面:
- ユーザーが「単純な mutable cursor 状態」を素直に書ける。bit reader / parser /
  iterator のような stateful object が ~25% 短くなる。
- 既存コンパイラ自身の `FuncTable` 系 struct も将来 `mut` 化することで意図が
  明示化できる (任意)。
- ADR-0021 の Mut effect handler との住み分けが明確化する: 大規模な抽象は
  effect handler、object-local な少量の状態は `mut` field。

悪い面 / トレードオフ:
- AST / parser / checker / desugar / 多数の codegen pass / serialize / structural
  hash / monoify / dce / rewrite-* など、`Expr::Return` 追加と同程度の surface
  area (~30 ファイル) を touch する。
- Phase 1 では soundness 検査を追加しないため、ユーザが mut field を持つ
  struct を外に逃して非決定性を入れる可能性は残る。これは既存の `Array[T]`
  field と同じレベルの責任モデルなので「悪化はしない」が、「sugar を入れた
  ぶんだけ書きやすくなる」分だけ誤用機会も増える。
- Phase 2 で `state_local` を導入する際、既存コードの `Array[T]` field 経由
  mutation も同じ分類に入れる必要があり、effect 注釈の追加が広範に必要に
  なる。これは ADR-0017 / ADR-0021 の合流でいずれにせよ発生する作業。

## 実装メモ

主な touch point:

1. `src/parser/parser_ast_patterns.mbt` (struct field parse) で `mut` 修飾子を
   accept。
2. `src/core/ast.mbt` の `StructFieldDecl` に `is_mut: Bool` を追加。
3. `src/frontend/desugar.mbt` で struct 定義 / リテラル / read / assign の
   4 箇所を lowering。
4. `src/checker/typecheck_expr.mbt` で field assignment の許可判定に `is_mut`
   を反映 (immutable field への代入はエラー、メッセージは既存の `let mut`
   と統一)。
5. `src/core/normalize.mbt` の field info に `is_mut` を保持し、structural
   hash に含める (もしくは lowering 後の shape を hash 対象とする — どちらに
   するかは normalize 設計次第)。
6. 既存 30+ ファイルの `Expr` walker / Stmt walker に `StructFieldDecl` の
   新フィールドを伝播。
7. e2e tests + zlib dogfood の BitReader を `mut` field に書き戻して動作確認。
