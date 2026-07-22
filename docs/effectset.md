# ADR-0071: operation-level effect row と `effectset`

Status: proposed

Date: 2026-07-15

Related: ADR-0003, ADR-0021, ADR-0050, ADR-0063, #639, #755, #817

## Context

現在の effect row は `with { Env }` のように effect 宣言全体を単位として
追跡する。`Env` が読み取りと書き込みの operation を両方持つ場合、読み取り
だけを行う関数も `Env` 全体を要求するため、型と package contract が実際より
広い権限を表す。

代数的エフェクトの effect signature は operation の有限集合なので、型で追跡
する最小単位も effect 名ではなく operation identity とする。再利用する集合には
新しい nominal effect や `facet` を導入せず、`effectset` という透明な名前を
与える。

## Decision

effect row の正規形を operation identity の集合へ変更する。`with` 句には
operation を直接書けるほか、閉じた operation 集合を `effectset` として定義し、
参照できる。

```vibe skip
effect Env {
  get(String) -> Option[String]
  args_len() -> Int
  args_get(Int) -> Option[String]
  set(String, String) -> Unit
}

// qualified effectset は指定した effect の部分集合でなければならない
effectset Env::Read = {
  Env::get,
  Env::args_len,
  Env::args_get,
}

// operation を直接列挙する形
fn read_one(key: String) -> Option[String] with { Env::get } {
  perform Env::get(key)
}

// 名前付き集合を再利用する形
fn read_config(key: String) -> Option[String] with { Env::Read } {
  perform Env::get(key)
}
```

effect を丸ごと書く既存形は、その effect が宣言する全 operation の shorthand
とする。

```vibe skip
with { Env }
// equivalent to:
with { Env::get, Env::args_len, Env::args_get, Env::set }
```

複数 effect にまたがる集合には unqualified な名前を使える。

```vibe skip
effectset ReadOnly = { Env::Read, Fs::read_file }

fn load() -> String with { ReadOnly } { ... }
```

generic effect の effectset は通常の型パラメータを持てる。effectset が閉じている
とは row variable を含まないという意味であり、宣言された型・region パラメータ
を operation へ渡すことは許可する。

```vibe skip
effect State[T] {
  get() -> T
  put(T) -> Unit
}

effectset State::Read[T] = { State[T]::get }

fn inspect() -> Int with { State::Read[Int] } { ... }
```

### Row item

`with { ... }` の各要素は次のいずれかとする。

- effect 名: 宣言された全 operation へ展開する
- `Effect::operation`: 単一の operation
- effectset 名: 宣言本体を再帰的に展開する
- effect row variable: 従来どおり open row の tail を表す

`effectset` 本体には effect 名、operation、他の effectset を書ける。
effect row variable、差集合、補集合、wildcard は許可しない。effectset は常に
閉じた集合であり、循環参照は定義エラーとする。順序と重複は意味を持たない。

`effectset Env::Read` のような qualified effectset は、完全展開後のすべての
operation が `Env` に属さなければならない。複数 effect の union は
`effectset ReadOnly` のような unqualified effectset で定義する。

operation と effectset は effect-row member namespace を共有する。
同じ effect に `Read` operation と `Env::Read` effectset を同時に宣言するなど、
参照が曖昧になる定義は reject する。

### Normalization and identity

checker、unification、contract hash、診断、codegen の前に effect 名と effectset
を再帰展開し、row を次の形へ正規化する。

```text
OperationId  = (EffectDefId, OperationIndex)
OperationRef = (OperationId, NormalizedEffectArguments)
EffectRow    = ({OperationRef...}, optional RowVariable)
```

`EffectDefId` は package/module identity を含む定義 ID であり、表示名の文字列では
ない。`NormalizedEffectArguments` は `State[Int]` の型引数、`Write[router]` の
region 引数、`S3[Posts]` の logical resource 引数を別 kind として保持する。
resource identity は nursery/borrow region と混同しない。別 package がそれぞれ宣言した
同名の `effect State`、または同じ generic effect の異なる instantiation は、異なる
参照として扱う。

ADR-0075 の executable contract では resource-qualified operation を authority の最小
単位とする。したがって `S3[Posts]::get_object` と
`S3[Uploads]::get_object` は別 `OperationRef` であり、一方の host binding/evidence で
他方を満たせない。logical resource name、physical ARN、通常の `String` 値は別の
identity space とする。

effectset は compile-time alias であり、runtime identity、独自 handler、独自
continuation を持たない。`perform Env::Read` や
`handle ... with Env::Read` は許可しない。`perform` は operation、handler target
は effect 宣言を参照する。

### Type and handler rules

関数本体が要求する正規化 row を `Rreq`、その関数に宣言された row を `Rdecl`
とすると、次を要求する。

```text
Rreq ⊆ Rdecl
```

ADR-0073 の `Error::Throw` も通常の semantic operation として `Rreq` に含める。
明示 `with { Error }` は高階関数型・subtyping・package contract/hash で意味を持ち、
caller は requirement を宣言するか `handle Error` で放電する。

したがって、少ない operation しか要求しない関数は、より広い row を許可する
context で利用できる。`with { Env::Read }` 内から `Env::set` を perform または
推移的に要求する関数を呼ぶことは型エラーになる。

`handle body with Env { ... }` は body の正規化 row から、実際に存在する `Env`
operation を除く。handler arm 自身が要求する effect は handler 式の結果 row に
加える。effectset は handler の網羅性や dispatch 規則を変更せず、ADR-0050 の
「effect 宣言の operation を exhaustive に扱う」規則を維持する。

### Package contract, WIT, and security surface

effectset は `index.vpkg` の contract symbol として import/export できる。
公開 effectset 宣言の contract には名前と展開後の `OperationRef` 集合を記録する。
関数の effect row、content hash、互換性判定は alias 名ではなく展開後の集合を
使う。同じ関数 row を直接列挙した場合と effectset で書いた場合は、同じ contract
surface とする。

公開関数の effect surface diff は operation 単位で行う。operation または
effectset の追加によって既存関数の展開後 row が広がる変更は、権限拡大として
breaking/security-sensitive change にする。特に `with { Env }` は全 operation
shorthand なので、`Env` への operation 追加で公開 surface も広がる。

WIT world 生成では公開 entry の row を展開し、元の effect ごとに operation の
union を取る。生成する WIT interface には、その world が実際に要求する
operation だけを含める。直接列挙と effectset 参照は同じ WIT を生成し、
effectset を effect 全体へ広げてはならない。

### Diagnostics

不足診断は alias 名だけでなく、展開後の operation 差分を表示する。

```text
effect requirements not satisfied: missing { Env::set }
declared effectset Env::Read expands to
  { Env::get, Env::args_len, Env::args_get }
```

fix-it は、局所的な一回利用なら不足 operation の `with` 句への追加を、既存の
effectset と一致する場合はその effectset の参照を優先する。effectset 定義そのもの
を自動で拡張する fix-it は、複数 consumer の権限を広げるため出さない。

## Rejected alternatives

- **`facet` を新しい宣言種別として導入する**: effectset と別の型・handler
  semantics を持つように見え、operation 集合の alias という実態より概念が重い。
- **`EnvRead` / `EnvWrite` を別々の effect として宣言する**: handler、mock、WIT
  interface が分裂し、同じ algebraic signature の部分集合であることを失う。
- **effectset を nominal capability にする**: full `Env` handler が `Env::Read` を
  満たすための subtyping/evidence 規則が別途必要になる。透明展開なら通常の集合
  包含だけで済む。
- **`with { Env }` の atom を維持したまま alias だけ追加する**: alias が operation
  単位の最小権限を表せず、本件の目的を満たさない。

## Implementation and regression locks

実装は compiler を source of truth とし、次の順で TDD する。

1. parser/printer: direct operation row、qualified/unqualified effectset、round-trip
2. resolver: `OperationId`、import identity、member collision、cycle rejection
3. checker: 展開・包含・推移呼び出し・row variable との合成
4. handler: operation-level discharge と handler-arm effect の再加算
5. contract/WIT/diagnostics: normalized surface と operation-level diff
6. codegen/evidence: 正規化 row を #817 の evidence vector 入力に接続

最低限、次を回帰として固定する。

- `with { Env::Read }` から `Env::set` は reject
- direct row と同じ集合の effectset row は型・contract hash・WIT が一致
- effectset の順序違いと重複は同一、循環は reject
- `State::Read[Int]` と `State::Read[String]` は異なる operation 集合
- `handle ... with Env` 後は body が要求した `Env` operation だけが消える
- 別 package の同名 effect/operation は衝突しない
- effectset の operation 追加を effect surface diff が権限拡大として報告する

新構文を compiler source 自身で使うのは、seed compiler が構文と正規化を理解する
tag を作り、bootstrap bump を完了してからとする。

## References

- D. Hillerström, S. Lindley, [Liberating Effects with Rows and
  Handlers](https://homepages.inf.ed.ac.uk/slindley/papers/links-effect.pdf)
  — operation specification を要素とする Links の effect row
- D. Leijen, [The Koka Programming Language: Effect
  Typing](https://koka-lang.github.io/koka/doc/book.html#sec-effect-types)
  — extensible/scoped effect row と row polymorphism
- N. Xie, D. Leijen, [Generalized Evidence Passing for Effect
  Handlers](https://www.microsoft.com/en-us/research/publication/generalized-evidence-passing-for-effect-handlers/)
  — #817 で予定する正規化 row から evidence vector への lowering
