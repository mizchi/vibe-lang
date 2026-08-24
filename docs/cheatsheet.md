# vibe Language Cheat Sheet

WASM-targeting, pure-by-default language with algebraic effects. The compiler
is self-hosted: it is built from the committed seed (`bootstrap/seed/`) plus
the selfhost sources (`lib/@vibe/compiler/`, `lib/@vibe/cli/`) via the wasm
runner — no MoonBit toolchain is required (the MoonBit host implementation was
retired in #594; see `docs/archive/moonbit-retirement.md`).

## Quick Start

```vibe
// `println` is a builtin — no import — and it needs a tty capability, so the
// entry declares one. A function that declares no row may not print (#2107).
fn main with Console {
  println("hello world")
}
```

`print` is the same without the trailing newline. `@vibe/console` publishes the
rest of the tty surface (`eprint` / `eprintln` on `Stderr`, `read_line`,
`read_all`). `@vibe/builtin`'s older `stdout_write` / `stdout_writeln` are
gone (#2102) -- they duplicated names above.

The row is `Console`, the current tty capability. `println` still *lowers* onto
the legacy `Stdout` label internally, and declaring `Console` authorizes the
legacy three (#2102/#2117) -- one way only, so a row declaring just `Stdout`
cannot reach `Console::read_stream`. The book, README and installer teach this
same program; `scripts/test_vibe_install_hello.sh` checks they still agree.

```bash
vibe run hello.vibex       # compile & execute
vibe shell                 # interactive shell
vibe test file.vibe        # run tests
vibe check file.vibe       # type check only
vibe fmt file.vibe         # format in place (--check / --stdout)
vibe build --release app.vibe  # standalone .wasm
```

### CLI は IDE 相当のクエリ面 (方針)

`vibe check` (`--single-file` 込み) / `vibe symbols` / `vibe type-at` /
`vibe binding-at` / `vibe escapes` / `vibe bench` は、エディタが LSP 越しに
得るのと同じ意味解析を **CLI から直接**取り出すためのもの。想定する第一の
読み手は**人間ではなく LLM** なので、行指向 (1件1行) で grep でき、空出力が
clean を意味し、メッセージは内部用語ではなく「何を書き換えれば直るか」を
述べる、という形を保つ。

**これは自己改善のループとして運用する** — 使っていて欲しい情報が取れない・
出力が読めない・判定に使えないと分かったら、ワークアラウンドを覚えるのでは
なく CLI 側を直すか issue を立てる。詳細と現在わかっている穴は
[AGENTS.md の Code Navigation 節](../AGENTS.md#code-navigation-important)。

---

## Values & Types

```vibe
let x: Int = 42                // 63-bit (RC lane: 1-bit-tagged i64),
                               // max 2^62-1; arithmetic overflow wraps as
                               // 63-bit two's complement, same values on
                               // every backend (#1877): max + 1 == min;
                               // out-of-range literals are rejected with
                               // IntLiteralOverflow
let f: Float = 1.5f            // 32-bit (suffix f)
let d: Double = 3.14           // 64-bit (default decimal)
let s: String = "hello \{x}"   // interpolation with \{expr}
                               // (`\(x)` は非対応、`\{x}` を使う)
                               // #1392: 補間の値に `T::to_string`
                               // (derive(Show)/derive(Hash) 生成物、または
                               // 手書き) があればそれを呼ぶ。`Option`/
                               // タプル/配列は変数・名前関数の戻り値・戻り値が
                               // リテラルの未注釈 lambda・generic の pass-through
                               // 経由でも構造的に展開される
                               // (`"\{Some(p)}"` -> `Some(P { .. })`,
                               // `"\{make_xs()}"` -> `[1, 2]`)。描画できない型
                               // (to_string の無い集約型) は check 時に
                               // `cannot interpolate a value of type ...` で
                               // 落ちる (#1445)。
                               // ただし effect handler の
                               // pattern binder (`Throw(err) => "\{err}"`) は
                               // binder の型を補間 rewrite が回収できず、まだ
                               // 生ポインタの10進値になる。variant を match して
                               // payload を補間する (`Throw(err) => match err {`
                               // `  Kind::Case(v) => "\{v}" })` と回避する
                               // prelude の `to_string(v)` も同じ描画になる
                               // (補間と同じ書き換えを call site で受ける)
let c: Char = 'A'              // byte value 65; Char is a transparent Int alias
let b: Bool = true
let u: Unit = ()
```

### Multi-line raw strings (`#|`)

`#|` spells an ordinary `String` literal (MoonBit-style). Each `#|` takes the
rest of its physical line **verbatim** — no `\{}` interpolation, no `\n`/`\\`
escape processing — and consecutive `#|` lines whose `#` sits at the **same
column** join with `"\n"`. The first following line that does not start with
`#|` simply ends the literal (that is not an error); a continuation `#|` at a
*different* column is a located lex error, never a silently shorter block.
Measured (2026-08-23):

```vibe
test "same column joins with newline" {
  let s = #|line one
          #|line two
  assert_eq(s, "line one\nline two")
}

test "content is raw: no interpolation, no escapes" {
  let s = #|no \{interp} and no \n escapes
  assert_eq(s, "no \\{interp} and no \\n escapes")
}

test "an ordinary String: concat and length work" {
  let s = #|ab
          #|cd
  assert_eq(String::length(s), 5)
  assert_eq(String::concat(s, "!"), "ab\ncd!")
}
```

Because the content runs to end of line, nothing else can share the line: a
closing `)` or `,` after the text becomes part of the string, so `#|` works as
a binding's right-hand side but not inline inside an argument list. Misaligned
continuations are rejected with a position:

```vibe skip
// Both lines are deliberate errors (measured): the first swallows `)` into
// the string, so the parser reports `expected ) but got }`; the second is
// the located lex error "#| multi-line string continuation must start at
// the same column as the opening #|".
test "what NOT to write" {
  assert_eq(#|hello, "hello")
  let s = #|line one
        #|misaligned
}
```

The same alignment rule is what `.vpkg` `description` blocks reuse for their
`#|` continuation lines (see the `index.vpkg` header section below).

Int の範囲 (±2^61) を超える整数は `@vibe/core` の任意精度 `BigInt`
(sign + 30-bit limbs) を使う — `parse`/`to_string`/`add`/`sub`/`mul`/`divmod`/`pow`:

```vibe
import ./lib/@vibe/core { BigInt::from_int, BigInt::pow, BigInt::to_string }

let big_2_64: () -> String = () -> {
  BigInt::to_string(BigInt::pow(BigInt::from_int(2), 64))   // "18446744073709551616" (Int では持てない)
}
```

正確な分数演算は同じく `@vibe/core` の `BigInt` ベース `Rational` (常に gcd 約分・den > 0 に正規化):

```vibe
import ./lib/@vibe/core { Rational::parse, Rational::to_string }

let half: () -> String = () -> {
  match Rational::parse("2/4") {
    Some(r) => Rational::to_string(r),   // "1/2" — 常に gcd 約分 + den > 0 へ正規化
    None => "unreachable"
  }
}
```

## Variables

```vibe
let x = 42            // immutable
let y = {             // mutable is local/block-scoped
  let mut value = 0
  value += 1
  value
}
```

### Choosing a mutation style

vibe has 5 ways to express mutable state. Pick the simplest one that
covers your scope:

| Want | Use | Notes |
|---|---|---|
| Local counter, accumulator | `let mut x = ...` | block-scoped; cannot escape the function via async/spawn (ADR-0017) |
| Growable buffer (bytes / chars) | `Bytes` / `String` | immutable binding, mutable interior |
| Growable array | `ArrayBuilder` → `Array::from_array_builder` | build-then-freeze; `Array::push` also works for growing an existing `Array` in place (#1285) |
| Mutable cursor in a struct | `struct S { mut field: T }` + `r.field = v` | ADR-0052; same responsibility model as `Array[T]` field |
| Cross-call / handler-mediated state | declare your own effect, then `handle ... with <YourEffect>` | ADR-0050/0021; there is no builtin `Mut` effect. A `perform` **directly inside the handler body** is inline-eliminated; a call through an intervening function still goes through evidence-dict dispatch, measured at ~2× a captured `let mut` ([side-effect-consolidation.md §2.5](side-effect-consolidation.md)) |

`Array::push(arr, v)` appends **in place**, and every reference to `arr`
(alias, parameter, struct field, closure capture) observes the growth — the
same on the linear, RC and wasm-gc backends. That contract is pinned by the
`heap e2e: Array::push ..` tests in
`lib/@vibe/compiler/tests/codegen_heap_e2e_test.vibe`, which run all three
lanes (#1285). Earlier revisions of this page called it backend-dependent;
that is no longer true. Prefer `ArrayBuilder` when you build a collection
once and then only read it, `Array::push` when you grow an array you already
hold.

Anti-patterns:
- `Ref[T]` — historically abandoned (ADR-0017), use the table above

### Collection naming convention (#1140, ADR-0082 → ADR-0100 (3))

The bare name / prefix a collection type carries tells you its mutability
contract — this is a naming *rule*, not a per-type coincidence:

| Spelling | Contract | Examples |
|---|---|---|
| bare name | persistent/functional — every "mutating" op returns a NEW value, the receiver is untouched | `Map[K, V]`, `StringSet` (conceptually `Set[String]`) |
| `Mut-` prefix | a deliberate MUTABLE variant with the same conceptual API — ops return `Unit` and mutate in place | `MutMap`, `MutSet`, `MutSortedMap`, `MutSortedSet` |
| `XBuilder` suffix | a mutable, growable builder; not meant to be held onto — finish with the **implemented** terminal: **`::freeze`** for `ArrayBuilder`/`MapBuilder`, **`::build`** for `StringBuilder` | `ArrayBuilder`, `MapBuilder`, `StringBuilder` |
| `Frozen-` prefix | immutable AND `Send`-eligible (structurally, when its element type is `Send`) — a narrower, stronger claim than plain persistence, tied to the structured-concurrency model (ADR-0068, #906) | `FrozenArray[T]` |

**2軸を分離する** (ADR-0100 (3), #1262)。ADR-0082 は `Hash-` / `Sorted-` の
**接頭辞**を「これは可変」と読ませていたが、それは ADR-0090 の `Mut-` と
正面衝突し、1つの語に独立な2軸を担わせていた。今は **可変性が接頭辞**
(∅ = persistent / `Mut` = 可変ハンドル / `Frozen` / `-Builder`)、
**実装・性能の話は接尾辞か置き場所**。`Sorted` は可変性ではなく
**順序付きインタフェース**を指す語に戻った:

| 旧 | 新 |
|---|---|
| `HashMap` | `MutMap` |
| `HashSet` | `MutSet` |
| `SortedMap` | `MutSortedMap` |
| `SortedSet` | `MutSortedSet` |

旧綴りの**関数** (`HashMap::new_string` 等) は `#deprecated` エイリアスとして
残り、`Mut-` 型を返す。したがって**型名を書かないコードはそのまま動く** ——
`let m = HashMap::new_string()` は `MutMap` に推論され、`vibe check` が
移行先を名指しする警告を1行出す (非致命、exit 0)。

旧綴りの**型注釈**も transparent alias として残る (#1700)。たとえば
`let m: HashMap[String, Int] = HashMap::new_string()` は `@vibe/core` の
`index.vpkg` 境界を越えて `MutMap[String, Int]` と同じ型になる。移行先は
引き続き `Mut-` 名。型行に `#deprecated` を書くのは bootstrap bump 待ち
(seed の契約パーサが `#` を拒む) なので、`vibe check` は言語側の表で
同じ名前を警告する。`import { HashMap }` したファイルの注釈が対象。

旧綴りの**関数**を使うと `vibe check` が移行先を名指しする `warning:` 行を
出す (非致命、exit 0)。**これは #1262 follow-up で初めて実際に効くようになった**
—— それまで `check_deprecated_warnings` は loader とは別の素朴なパス解決を
使っていて、`@scope/pkg` が解決できず**パッケージが公開した `#deprecated`
マーカーが 1 つも届いていなかった** (同じ経路が原因で `vibe check` 自体、
`@scope/pkg` を import するファイルで crash していた)。

**"Frozen" and "persistent" are not synonyms.** `Map`/`StringSet` are
persistent (functional-update) but are *not* `Send`-eligible under the
current allowlist — the canonical one is
[concurrency.md](concurrency.md#send-と-capture-safety), pinned by
`send_allowlist_test.vibe`. Reach for `FrozenArray`
specifically when a value needs to cross a `spawn`/task boundary; reach for
a bare-named persistent type for ordinary functional-update code.

**Builder の終端動詞は `build`** (ADR-0101 (3), #1262)。`StringBuilder::build()
-> String` のように**型名と動詞が lexical に対応する**ようにしたもの。
`freeze` は「Frozen-(persistent + `Send`)を産む動詞」に予約されていて、
Builder の終端はそれではない —— 旧綴りの最悪例が
`ArrayBuilder::freeze -> Array` で、**freeze の結果が可変**だった。
**現行 surface の実装終端**はまだ `ArrayBuilder::freeze` / `MapBuilder::freeze`
だけ。`StringBuilder` だけが `build` を公開する (`freeze` と同じ registry
row の alias)。`ArrayBuilder::build` / `MapBuilder::build` は未実装。

```vibe
fn greeting() -> String {
  let b = StringBuilder::new()
  StringBuilder::push(b, "hello ")
  StringBuilder::push(b, "world")
  StringBuilder::build(b)           // 終端 = build
}
```

`StringBuilder::freeze` も同じ registry row・同じ codegen に落ちる
(`canonical_builtin_name` のエイリアス、生成 wasm はバイト一致 —
`compiler_gate.sh` 102/102 が pin) ので既存コードは動くが、新規コードは
`build` を使うこと。**コンパイラ自身のソースの移行と `freeze` の
`#deprecated` 化は bootstrap bump 待ち** —— seed が `build` を知るまで
compiler source は `freeze` のままでなければならない (docs/bootstrap.md)。

`Array`/`Bytes` themselves are NOT renamed under this convention — they
predate it and a rename would be too disruptive. They remain low-level
mutable primitives with backend-identical semantics (see the `Array::push`
note above); reach for `ArrayBuilder` (build-then-freeze accumulation) or
`FrozenArray` (persistent + `Send`) when you want those stronger contracts.

## Functions

```vibe
// Top-level named functions: `fn` (#727, ADR-0064). Full annotations
// required (param types + return type); recursion needs no `rec`.
fn add(x: Int, y: Int) -> Int { x + y }
fn fact(n: Int) -> Int {
  if n < 2 { 1 } else { n * fact(n - 1) }
}
fn identity[T](x: T) -> T { x }                // generic
fn show[T: Eq + Ord](x: T) -> T { x }          // trait bounds
fn hello() -> Unit with Stdout { println("hi") }
// #1429: the effect row has exactly one spelling, plus one for the empty row.
//   with A + B      the row
//   with ()         the explicitly empty row
// The braced `with { A, B }` was accepted through the migration and is now a
// named parse error. `vibe fmt` rewrites it for you (the formatter is a
// token-level pass, so it converts source the compiler no longer accepts).
// (`effectset X = { A, B }` keeps its braces — that is a set literal on the
// right of `=`, not a row.)
// `+` rather than `,` because once the braces are gone a comma cannot be told
// apart from an enclosing list's comma: in `fn g(cb: (Int) -> Int with A, x: Int)`
// the `x` is either a second label or the next parameter. `+` starts neither a
// type nor a parameter, so the row ends unambiguously with no lookahead — and
// it is already the "and another one" separator in trait bounds (`[T: A + B]`).
// `with (A + B)` is rejected: `()` spells the empty row and nothing else.
export fn doubled(x: Int) -> Int { x * 2 }
// where-contract (#731): requires asserts at entry; ensures binds the
// function value as `result` and asserts at exit. Violations trap.
fn checked_add(x: Int, y: Int) -> Int
  where { requires: x >= 0, requires: y >= 0, ensures: result >= x } { x + y }
```

`fn` is top-level only. The declaration — including its `where` clause — is
kept in the AST (`SFnDecl`, #727) and lowered to the `let rec` form below
just before checking/codegen, so checker/codegen semantics are identical.
The optional `where { requires: .., ensures: .. }` contract runs as
always-on runtime asserts (#731 Phase 1): each `requires` condition asserts
at entry; each `ensures` condition sees the function value bound as
`result` and asserts at exit; a violating call traps. Known limits: an
early `return` bypasses `ensures`, and `result` shadows any user binding of
that name inside ensures conditions. `vibe normalize` and the AST printer
round-trip fn declarations in fn + where form — fn sources are no longer
refused or rewritten to `let rec`.

```vibe
// let form: values, computed functions, higher-order returns
let add: (Int, Int) -> Int = (x, y) -> { x + y }
let inc: (Int) -> Int = (x) -> { x + 1 }
let rec fact: (Int) -> Int = (n) -> {     // recursive
  if n < 2 { 1 } else { n * fact(n - 1) }
}
let identity: [T](T) -> T = (x) -> { x }  // generic
let show: [T: Eq + Ord](T) -> T = (x) -> { x } // trait bounds
```

> **Deprecated**: `let f = (x: Int) -> Int { ... }` (inline param types)
> is deprecated. Use `vibe fmt` to auto-convert.

### Labeled arguments

```vibe
let f: (x~: Int, y~: Int) -> Int = (x~, y~) -> { x + y }
let sum = f(x=10, y=20)   // => 30
```

### optional 引数 `z?` (#1500)

`z?` は**省略できる**引数。宣言した型が `T` でも、body で受け取るのは
`Option[T]`（省略された場合に何かを渡す必要があるため）。呼び出し側は
素の値を書けばよく、`Some(..)` は desugar が付ける。

```vibe
fn greet(name: String, times?: Int) -> String {
  let n = match times {
    Some(v) => v,
    None => 1
  }
  "\{name} x\{n}"
}

let a = greet("hi")        // => "hi x1"
let b = greet("hi", 3)     // => "hi x3"
```

- 省略できるのは**末尾の** optional 引数だけ。必須引数を落とすのは従来どおり
  arity エラー
- 関数型でも `(String, times?: Int) -> String` と書ける (この位置は
  `Option[Int]` として記録される)

### Lambda shorthand

<!-- doctest-skip: 未定義名 (xs) を参照する構文提示の断片 -->
```vibe skip
Array::map(xs, x -> x * 2)
Array::map(xs, _ * 2)         // placeholder
Array::fold(xs, 0, _ + _)
```

## Operators (precedence: high to low)

| Prec | Operators | Notes |
|------|-----------|-------|
| 1 | `.` `()` `[]` | field, call, index |
| 2 | `-x` `!x` | unary |
| 3 | `*` `/` `%` | |
| 4 | `+` `-` | |
| 5 | `<<` `>>` | >> is arithmetic (sign-extending) |
| 6-8 | `&` `^` `\|` | bitwise AND, XOR, OR |
| 9 | `==` `!=` `<` `<=` `>` `>=` `is` | non-assoc; `is` is the pattern-test operator (see below) |
| 10 | `\|>` | pipe |
| 11-12 | `&&` `\|\|` | short-circuit (desugar to if) |

Assignment: `=` `+=` `-=` `*=` `/=` `%=` (statement, not expr)

Slice is a postfix `[]` form with four spellings:

```vibe
let s = "hello"
let whole: String = s[:]       // start = 0, end = length
let prefix: String = s[:2]     // start = 0
let suffix: String = s[2:]     // end = length
let middle: String = s[1:4]
```

The receiver must be `String`, `Bytes`, or `Array[T]`, and the result has the
same type as the receiver. Explicit `start` and `end` values are `Int`.
`String` slicing uses byte offsets; it does not imply Unicode code-point or
grapheme boundaries.

### `Array` / `Bytes` の `==` (#1526)

ランタイムの `eq` は型を見ないので、配列の `==` は**コンパイル時に要素型を
決めて**構造比較へ書き換えられる。要素型が分かる限り構造的:

```vibe
test "array equality is structural where the element type is known" {
  let a = [1, 2]
  let b = [1, 2]
  assert([1, 2] == [1, 2])   // リテラル
  assert(a == b)             // let 束縛
  assert(same([1, 2], [1, 2]))
}

fn same(x: Array[Int], y: Array[Int]) -> Bool {
  x == y                     // Array[T] 引数
}
```

tuple の中の配列も同じ (ADR-0097: 裸 / tuple 内 / struct 内の 3 文脈は同じ
答えを返す)。tuple は let 束縛 (束縛時に記録した形で降りる) でも注釈付き
引数でも構造的:

```vibe
test "arrays inside tuples compare structurally too" {
  let t1 = ([1, 2], 0)
  let t2 = ([1, 2], 0)
  assert(t1 == t2)
  assert(((1, [2, 3]), "x") == ((1, [2, 3]), "x"))
}
```

`Bytes` は**内容の等価** (アドレスではなくバイト列)。裸でも tuple 要素でも
`derive(Eq)` の struct field でも同じ:

```vibe
test "Bytes equality is content equality" {
  let a = Bytes::new()
  Bytes::push(a, 65)
  let b = Bytes::new()
  Bytes::push(b, 65)
  assert(a == b)
}
```

ADR-0097's contract does not depend on the spelling or on the route a value
took. An annotated `Array[T]` parameter, a function's return value, a tuple
return, an `Option[Array[T]]` payload, a nested array reached through a name
and `Array[Float]` all get the same structural comparison. An erased type
variable (`[T: Eq]`) uses the `Eq` witness it was handed.

An unannotated `let xs = []` is structural too **when the pushed value
describes itself** (#2157, narrowed by #2192). The element type comes from the
`Array::push(xs, v)` calls in the binding's own scope, and `v` is read from its
own syntax only — a literal, an array / tuple / struct of such values, or a
conditional whose branches agree:

```vibe
test "an unannotated empty binding answers by content after a push" {
  let xs = []
  let ys = []
  Array::push(xs, 1)
  Array::push(ys, 2)
  assert(xs != ys)
}
```

A pushed **name** or **call result** does not resolve, and that is deliberate:
reading the value's type out of an environment means deciding scope, shadowing,
annotations and type formals in a pass that has no types, which produced a
silently wrong answer (an outer `let v = 1` read for an inner `v` of another
type, so `==` said `false` for two equal `[1, 2]` arrays). With no environment
the element type can be absent but never wrong.

A **generic** struct literal preserves its concrete type arguments in the
equality shape (#2195): the compiler emits a comparator per concrete
instantiation and substitutes the arguments into its field types, so
`Box[Int]`, `Box[Double]`, `Box[Bytes]`, `Box[Array[Int]]` — and declared
fields containing them — all compare structurally (measured 2026-08-24, two
distinct allocations of equal content answer `true`). A self-describing
literal with an omitted argument, such as `Box::{ value: [1, 2] }`, recovers a
single directly-used type parameter from the field value; anything more
ambiguous remains unresolved and traps.

A declared name is excluded when any field has **no structural comparator**,
transitively and through type aliases — the exclusion follows fields so a
wrapper cannot smuggle an uncomparable head in one level down. Which field
types keep a struct usable is an allow-list, measured on a
`struct W { f: T } derive (Eq)`:

| declared field type | `==` |
|---|---|
| `Int`, `String`, `Double`, `Bytes` | `true` |
| `Array[Int]`, `Array[Double]`, `Option[Int]`, `(Int, String)` | `true` |
| a declared struct | `true` |
| `Map[String, Int]` | `true`, since #2218 |

`derive` generates a type-directed comparison when the type is known where the
comparison is emitted — since #2195 that includes a generic struct's concrete
instantiations. `Map` was the one measured outlier until #2218 gave it a
comparator; any head nobody has measured still costs its owner a trap rather
than the benefit of the doubt.

**What does not resolve fails at run time** once BOTH sides are non-empty —
it does not fall back to reference equality or to a length-only answer. Annotate
those bindings (`let xs: Array[Int] = []`). While either side is still empty the
lengths decide the answer, annotation or not.

## Pipe Operator

<!-- doctest-skip: 未定義名 (x / f / g) を参照する構文提示の断片 -->
```vibe skip
x |> f            // f(x)
x |> f(a, b)      // f(x, a, b)   — value is prepended
x |> f(a, _)      // f(a, x)      — `_` marks where the value goes
x |> g(a, _, b)   // g(a, x, b)
x |> f |> g       // g(f(x))
arr |> Array::length
s |> String::trim |> String::length
```

Without a `_`, the piped value becomes the **first** argument. A bare `_` in
the call's arguments substitutes the value at that position instead (no
prepend). A *compound* placeholder such as `_ * 2` is a section lambda
(`(v) -> v * 2`), not a pipe slot — so `xs |> Array::map(_, _ * 2)` reads as
`Array::map(xs, (v) -> v * 2)`.

**Method-style calls** (#736): `xs.length()` and `xs |> length` resolve to
`List::length(xs)` when `xs`'s type is a USER type and the method is declared
as a top-level fn in the **`Type::method` spelling** (`fn List::length(xs:
List) -> Int`) — importing just the type is enough
(`import ./list.vibe { List }` makes `List::of3(1,2,3) |> length`
work — the companion call's return type drives the dispatch, #1908).
A BARE top-level `fn total(l: MyList)` is *not* a method: it keeps
normal call semantics (`total(l)`, and `l |> total` — the pipe is just a call),
but `l.total()` does not resolve to it and reports a located
``no method `total` on `MyList` `` diagnostic (#953). A struct FIELD of the same
name wins over a method (field-stored function call). Builtin receivers
(`Array`/`String`/...) keep their builtin `Type::method` forms — no
bare-method sugar for them.

**Canonical on-disk form (#1189, ADR-0081 — implemented 2026-07-28, #1194):**
`recv.method(args)` is legal to *write*, but `Type::method(recv, args)` is the
spelling `vibe normalize` rewrites it to in the committed source (NOT `vibe
fmt`, which is a token-stream-only formatter with no AST and can't do
structural rewrites), whenever the receiver's type is recoverable through a
lightweight, per-function syntactic heuristic mirroring (a subset of)
`desugar_trait_dict.vibe`'s `infer_arg_type_name`/`var_types` (param
annotations, `let x: T = ...`, an immediately preceding `T::ctor(..)` call
whose return type is declared in the SAME file) — deliberately *not* a full
type-check pass, so normalize keeps working on files that don't type-check
yet. When the receiver type isn't recoverable that way, normalize leaves the
dot form untouched rather than guessing — in particular, **a receiver whose
type is declared in a different file (only imported here) is always left as
dot form**, since `vibe normalize` is single-file and never sees that
declaration; this is a known scope limit, not a bug. Rationale:
[`eval/call-style/findings/2026-07-28-r1.md`](../eval/call-style/findings/2026-07-28-r1.md)
found a reader given only a text excerpt (no compiler, no LSP) can recover
the callee's type from the qualified spelling but not from bare
`recv.method(...)` when annotations are sparse — so the qualified spelling
is what should land in git history/diffs/greps, while the terser dot
spelling stays legal to type. This does **not** help positional-argument-order
ambiguity between same-typed parameters — that's a separate problem no call
notation solves (`eval/call-style/scenarios/02_arg_order`). Implementation:
`normalize_dot_calls` in
[`lib/@vibe/compiler/normalize/normalize.vibe`](../lib/@vibe/compiler/normalize/normalize.vibe);
tests in `lib/@vibe/compiler/tests/normalize_dot_calls_test.vibe`.

### Function combinators (point-free)

`compose` / `identity` / `flip` live in the prelude (`lib/@vibe/builtin/func.vibe`);
import them before use (`import ./func.vibe { compose, identity, flip }`).

<!-- doctest-skip: 未定義名 (f / g / xs / parse / render) を参照する構文提示の断片 -->
```vibe skip
// vibe has no `>>` compose operator (`>>` is arithmetic shift) — use functions
compose(f, g)            // (x) -> g(f(x))   apply f then g
identity                 // (x) -> x         no-op stage / default
flip(f)                  // (b, a) -> f(a, b)
Array::map(xs, compose(parse, render))
```

> Runnable reference for the pipe `_` slot, combinators, `let*`, and `tap`:
> [`lib/@vibe/builtin/pipeline_ergonomics_test.vibe`](../lib/@vibe/builtin/pipeline_ergonomics_test.vibe)
> (`vibe test lib/@vibe/builtin/pipeline_ergonomics_test.vibe`). The
> combinators are `@vibe/builtin` exports and `tap` / `tap_some` moved to
> `@vibe/console` (#2102 — they carry `Stdout`), so a file must `import` them
> and sit where it can reach those packages — `import` paths may not escape the file's root
> directory, so standalone `examples/` files cannot reach `lib/@vibe/builtin/`.
> (`Result` and the `tap_ok`/`tap_err` railway taps were prelude exports until
> #1324 removed them; `let*` and `?` now bind `Option` only.)

## Control Flow

<!-- doctest-skip: 未定義名 (cond / opt / arr / pull / body ...) を参照する構文提示の断片 -->
```vibe skip
// if (expression)
let v = if cond { a } else { b }

// match
match opt {
  Some(x) if x > 0 => x,     // guard
  Some(_) => 0,
  None => -1,
}

// while
while cond { body }

// for-in (collects into array)
for x in arr { x * 2 }         // -> Array
for i, x in arr { i + x }      // with index
for b in pull { use(b) }       // statement only: async iterator (struct: next() -> Future[Option[(T,Self)]], await-driven) or a () -> Option[T] pull closure (-> None).
                               // 同期/非同期の選択は iterand の型だけで決まる — `for await` は #1350 で廃止 (suspend は effect row が語る)

// loop (parameterized tail-recursion)
let result = loop (i = 0, sum = 0) {
  if i >= 10 { break sum }       // break = the loop's single RESULT
  continue(i + 1, sum + i)       // continue = the loop's PARAMETERS (all of them)
}
// #1284: the two are not symmetric and stay that way — they count different
// things. `continue` must pass every parameter (a bare `continue` repeats with
// them unchanged); a mismatch is a parse error naming both counts. `break` has
// no arity to match, so `break (a, b)` is one tuple, not two values.
// A break payload must begin on the same line as `break`. `while`, bare
// `loop { ... }`, and `for-in` accept only bare `break`; only parameterized
// `loop (...)` accepts a break value.

// return (early exit from the enclosing function)
let find_first_neg: (Array[Int]) -> Int = (arr) -> {
  let mut i = 0
  while i < Array::length(arr) {
    if Array::get(arr, i) < 0 { return i }   // escapes the function, not just the loop
    i = i + 1
  }
  -1
}
```

`for` が body の値を `Array` に集めるのは Array/String など builtin の
collection iterand だけ。pull closure・trait iterator・HostStream などの
非Array iterator は statement-shaped loop なので、値位置 (`let xs = for ...`)
では located error になる (#1679)。配列が必要なら iterator 固有の `collect`
関数を使うか、文位置の loop から `ArrayBuilder` へ明示的に蓄積する。

## Pattern Matching

<!-- doctest-skip: パターン構文の列挙 (単体プログラムではない) -->
```vibe skip
_                   // wildcard
x                   // binding
42, "hi", true      // literal
Some(x)             // constructor
(a, b, c)           // tuple
record { x, y }     // record
Point::{ x, y }     // struct
A | B               // or-pattern
x if x > 0          // guard (match arm only)
```

### Arm bodies

An arm body is an expression, and **an assignment counts** (#2197) -- `_ => ok =
false` needs no braces, and neither do the compound operators or a field or
index target. The braced form is the same program.

```vibe
let demo_arm_assign: (Int) -> Int = (n) -> {
  let mut total = 0
  let xs = [1, 2, 3]
  match n {
    0 => total = 10,
    1 => total += 5,
    2 => xs[0] = 9,
    _ => total = n
  }
  total + Array::get(xs, 0)
}
```

This used to be a parse error whose position pointed at the enclosing
declaration (`unexpected in pattern: =`), because the body stopped at the `=`
and the arm collector read that token as the NEXT arm's pattern. An
unassignable target now says `invalid assignment target`, the same message the
statement position gives.

### Destructuring let

パターン `let` (tuple destructure `let (a, b) = ..`、named-struct destructure
`let Name::{ .. } = ..`、record destructure `let record { .. } = ..`) は
関数 / block body でも **top-level でも** 使える (#1281)。top-level では
右辺は**ちょうど1回**評価され、各名前はそこからの射影として個別の global
binding になる。

top-level の制約 (いずれも明示的な located error):

- **irrefutable なパターンのみ**。enum variant (`let Some(x) = ..`)、リテラル、
  `|` は失敗しうるので拒否 — 関数内で `match` を使う
- **型注釈を書けない** (`let (a, b): (Int, Int) = ..`)。注釈すべき単一の
  binding が無いため
- **`export let <pattern> = ..` は書けない**。`let <pattern> = ..` と
  `export { a, b }` に分ける

```vibe
let demo: (Option[(Int, Int)], Option[Int]) -> Int = (pt, opt) -> {
  let (a, b) = (1, 2)              // tuple destructure
  let r = record { x: 10, y: 20 }
  let record { x, y } = r          // any field names bind
  let Some((px, py)) = pt          // ctor pattern (partial: traps on mismatch)

  // guard: bind on match, else leave the function (#1283)
  guard opt is Some(v) else { return -1 }   // else must `return` on every path
  a + b + x + y + px + py + v               // v is in scope past the guard
}
```

> **guard semantics (#1283):** `guard e is PAT else { alt }` desugars to
> `match e { PAT => <rest-of-block>, _ => alt }` — the else arm IS the
> continuation's fallthrough, which is why it must diverge. `return` and a
> direct `throw(...)` (equivalently `perform Exception::Throw(...)`) are
> accepted divergence forms. Other `perform` operations may resume, and a
> handled `throw` may produce the handler's value, so neither counts as
> divergence here. For a fall-through *value* fallback, use `if e is PAT { .. }
> else { .. }` or an explicit `match`.
>
> This replaced the `let PAT = e else { .. }` spelling (#760(1)), which is now
> a named parse error. The two are not interchangeable: let-else's else block
> supplied the value of the whole *remaining* block, so `let Some(v) = o else
> { 0 }` silently turned the rest of the function into `0`. Requiring
> divergence removes that shape.

### is expression

<!-- doctest-skip: 未定義名 (expr / use) を参照する構文提示の断片 -->
```vibe skip
if expr is Some(v) { use(v) }   // bind + test
expr is None                     // -> Bool
```

> **Precedence (#979):** `is` binds at the same tier as the comparison
> operators (`==`, `<`, ...) -- strictly *tighter* than `&&`/`||`/`|>`, but no
> tighter than arithmetic/bitwise operators. So `a && b is None` parses as
> `a && (b is None)` (the natural reading), while `a + b is None` parses as
> `(a + b) is None` (same as how `a + b < c` already grouped). Before #979,
> `is` was checked only once, after the *entire* `&&`/`||` ladder had
> already folded, so `a && b is None` misparsed as `(a && b) is None`.

## Type Definitions

```vibe
type Pair = (Int, Int)                   // alias

// enum/struct body members are ';'-separated; ',' as the declaration
// separator is a parse error
enum Color { Red; Green; Blue } derive(Eq)
enum Shape { Circle(Int); Rect(Int, Int) }

// Constructors can be spelled bare or qualified, in expressions AND in
// patterns; both forms mean the same variant (#742/#672).
let c = Color::Red                        // == Red
let s = Shape::Circle(3)                  // == Circle(3)
let r = match s { Shape::Circle(r) => r, _ => 0 }
// The qualifier is CHECKED (#1455): `Shape::Red` is an error ("enum `Shape`
// has no variant `Red`"), in a pattern as well as in an expression. It does
// NOT disambiguate two enums that share a variant name, though — that
// collision is rejected at declaration time instead (#1078).
// Imported enums work the same way, including parameterized ones:
//   import ./m.vibe { Attempt, Good }
//   let a = Attempt::Good(7)

struct Point { x: Int; y: Int } derive(Eq, Ord, Show)
let p = Point::{ x: 1, y: 2 }
let px = p.x                              // field access

struct Box[T] { v: T }                    // generic struct (#829)
let b1 = Box::{ v: 1 }                    // type args inferred from fields -> Box[Int]
let b2 = Box[Int]::{ v: 2 }               // explicit type args PIN the instantiation (#886)
// arity-checked: Box[Int, Int]::{ .. } は checker error; pinning resolves
// inference-ambiguous fields (e.g. struct Bag[T] { xs: Array[T] } の
// Bag[Int]::{ xs: [] })
// struct derive(Ord) -> Point::compare(a, b) : Int   (-1 / 0 / 1, lexicographic)
// struct derive(Show) -> Point::to_string(p) : String ("Point { x: 1, y: 2 }")
// enum derive(Show) -> E::to_string(v) : String ("B(3)" / "A")
// derive(Hash) -> T::hash_key(v) (構造キー、to_string も併せて生成)
// derive(Default) -> T::default() + `impl Default for T` 登録 (#1847) —
//   derive した型はそのまま `[T: Default]` bound を満たす
// (Eq は marker: 構造的 `==` は T::equals として常に生成される)
// #1392: `"\{v}"` は解決できた型の `T::to_string` を呼ぶ。prelude の
// `to_string(v)` も同じ (body が `__to_string(x)` そのものの 1 引数 pass-through
// は call site で inline され、補間と同じ書き換えを受ける) — ただし
// `f[T: Show](x) { to_string(x) }` の内側は型が変数なので従来どおり

trait Eq
trait Ord: Eq                              // supertrait
export open trait Show                     // extensible outside module

impl Eq for Int
impl [T: Eq] Eq for Array[T]              // 宣言はできるが bound には使えない (下記)

// `Send` (ADR-0068) is a COMPILER-JUDGED structural marker, not a user
// trait; `impl Send for X` is an error. The allowlist is stated once, in
// docs/concurrency.md "Send と capture safety".

// `Default` (#1847) は builtin trait: prelude が marker + primitive impl
// (Int/Float/Double/Bool/String) を登録するので `[T: Default]` bound は
// どこでも満たせる。generic code から `T::default()` を呼ぶには
// method-bearing 宣言 (`trait Default { default() -> Self }`) が要るので
// `import @vibe/core { Default }` する — witness は Hash と同じ dict 経由。
// derive(Default) した struct/enum も bound を満たす。witness を運べない
// 定義 (例: `[T: Default]() -> T` — T 型の引数も Array[T] 引数も無い) は
// `vibe check` が「cannot be dispatched here」で拒否する (#1858) —
// T 型の引数 (または Array[T] 引数) を witness carrier にすること。
```

### Marker-trait impls do not satisfy bounds for containers (#1503)

**An impl of a trait with no methods (a marker trait) cannot satisfy a bound
for a container such as `Array` or `Bytes`.** The declaration itself is
accepted, but passing that type to a bounded function is rejected:

```vibe skip
trait Eq                      // No methods: this is a marker trait
impl [T: Eq] Eq for Array[T]  // The declaration is accepted

fn keep[T: Eq](x: T) -> T { x }
let bad = keep([1, 2, 3])     // Rejected
```

The reason is the marker trait's **dispatch target**. Marker traits lower to
the builtin `==` / `<`. Array `==` can compare structurally only when the
element type is statically known (see "`Array` equality" below), while the `T`
inside `keep[T: Eq]` is erased and carries no element type. Honouring this impl
would therefore let `==` fall back to reference equality and silently answer
incorrectly. The diagnostic explains this restriction.

> This gate will be removed when ADR-0097 makes `==` structural in every
> context, because its justification will then be gone. Until that work is
> complete, the rule above remains in force.

To use a trait bound with a container, **give the trait a method**. A
method-bearing trait dispatches through a witness dictionary, so a generic
impl such as `impl [T] M for Array[T]` can be resolved:

```vibe
trait Measured {
  measure(Self) -> Int
}

impl [T] Measured for Array[T] {
  measure(self) -> Int { Array::length(self) }
}

fn keep[T: Measured](x: T) -> T { x }
let ok = keep([1, 2, 3])
```

### A type parameter cannot take type arguments (#2268)

**A type formal in constructor position — `F[A]` — is rejected.** A type
parameter always stands for a complete type; if the shape were accepted, `F`
would unify with the whole applied type and the bracket arguments would be
ignored, so a signature spelled `(F[A], (A) -> B) -> F[B]` would silently
accept the identity function. Higher-kinded parameters are not implemented;
which release implements them is decided on #2269. The diagnostic reads
``type parameter `F` cannot take type arguments in parameter `x` ``.

<!-- doctest-skip: deliberately rejected shapes (#2268 fail-close) -->
```vibe skip
fn fake_map[F, A, B](x: F[A], f: (A) -> B) -> F[B] {  // rejected
  x
}
struct Holder[F] {
  inner: F[Int]                                       // also rejected
}
```

The same rejection covers every declaration surface: a parameterized alias
body (`type Apply[F, A] = F[A]`), a generic effect operation
(`effect Bad[F, A] { Put(F[A]) -> Unit }`), and a trait method signature
(`trait Functor[F] { fmap[A, B](F[A], (A) -> B) -> F[B] }`) all reject with
the same diagnostic, naming the declaration (`` in the signature of
`Functor::fmap` ``). A trait or effect may still DECLARE type parameters and
use them unapplied (`trait Iter[A] { nth(Self, Int) -> Option[A] }`).

> A concrete generic impl target such as `impl M for Array[Int]` is rejected
> (#2262). The impl AST cannot retain the `[Int]` argument; accepting it would
> silently widen the impl to `Array[String]` and every other instantiation.
> Write the honest generic form, `impl [T] M for Array[T]`. Impl specialization
> for one generic instantiation is not supported yet.

## Collections

```vibe
// Array
let a = [1, 2, 3]
let first = a[0]              // index
let len = Array::length(a)
let doubled = Array::map(a, _ * 2)

// Tuple
let t = (1, "two", true)
let t0 = t.0                  // => 1

// Record
let r = record { name: "vibe", ver: 1 }
let rn = r.name                       // dot access (#760/#839, all positions)
let nv = {                            // destructure also works in fn/block body
  let record { name: n, ver: v } = r  // destructuring binds any field name
  (n, v)
}

// Map (#960: the `map { ... }` literal was removed; use the Map:: API)
let m = Map::from_pairs([("key", 42)])
let e = Map::new()                    // empty map
let mv = m["key"]

// Builders (mutable construction)
let arr2 = {
  let b = ArrayBuilder::new()
  ArrayBuilder::push(b, 1)
  ArrayBuilder::freeze(b)     // implemented terminal; `build` is the planned/StringBuilder verb
}

// General-purpose containers live in @vibe/core — MutMap/MutSet (open
// addressing) and MutSortedMap/MutSortedSet (AVL; keys/to_array ascending,
// range(lo, hi) inclusive on both ends). Comparison/hashing is
// explicit-dict style (functions passed as arguments) plus Int/String key
// specializations (MutMap::new_int() / MutSortedSet::new_string() etc).
// Persistent (immutable) collections are @vibex/immut — updates always
// return a new version, the old one stays intact (structural sharing;
// sendable data for the 0.2.0 concurrency model):
//   MapHamt[V] (HAMT, String key): empty/set/get/delete/size/keys/has_key
//     the old name ImmutMap is a #deprecated alias (ADR-0100 (3), #1262)
//   ImmutArray[T] (persistent vector): empty/push/get/set/length/from_array/to_array

// **Need a persistent map? Use `MapHamt`.** `Map` is a flat assoc list, so
// both construction and lookup degrade to O(n²). "The builtin `Map` is for
// small fixed tables" is still the rule, but "small" means SINGLE DIGITS:
// measured 2026-08-19 (VIBE_RC=0, ns/op, median of 3), `MapHamt` already wins
// at n=64, and the two are indistinguishable at n=8 —
//
//   n=8     build 1347 vs 1393, lookup 1411 vs 1540   (noise, no winner)
//   n=64    build 3908 vs 1778, lookup 3886 vs 2082   (MapHamt 1.9-2.2x)
//   n=1000  build 514892 vs 21122                     (MapHamt 24.4x)
//
// so there is no n at which the builtin meaningfully wins. bench/bench_map_vs_immutmap.vibe
// pins all three points; ADR-0100 (3) records the decision. The compiler
// itself has hit the same trap internally (#799).

// Deques / priority queues are @vibe/core (#1842, promoted from @vibex):
//   Deque::new/push_back/pop_front (ring buffer, O(1) at both ends)
//   PriorityQueue::new_int_min / new(cmp) (binary heap; cmp < 0 dequeues first)

// Bytes — growable byte buffer
let bytes_len = {
  let e = Bytes::new()        // empty (length 0), grows via push/append
  let z = Bytes::new(4)       // length 4, zero-filled
  Bytes::set(z, 0, 65)        // in-bounds write (OOB index traps, #811)
  Bytes::push(z, 9)           // append -> length 5
  let b0 = Bytes::get(z, 0)   // => 65
  Bytes::length(z)            // => 5
}
```

```vibe
// Int64Array — fixed-size Int-typed buffer for word/hash workloads
// (SHA-1 schedule, binary-protocol buffers, etc). #835: ported to the
// checker/codegen as a thin alias onto Array[Int]'s own
// make/get/set/length — the linear/gc backends already store the
// full tagged Int per cell (no 32-bit truncation), so no separate i64-cell
// object layout is needed the way the retired MoonBit host required.
let w_check = {
  let w = Int64Array::make(4, 0)   // length 4, default 0
  Int64Array::set(w, 0, 0xffffffff)
  let v0 = Int64Array::get(w, 0)   // => 4294967295 (no truncation)
  let len = Int64Array::length(w)  // => 4
  (v0, len)
}
```

> **status (#760/#839/#1839):**
> - **Anonymous records are structural** (#1839): a named struct that happens
>   to share a `record { ... }` literal's field-name set no longer captures
>   it. The literal keeps its own layout (literal field order), so dot access
>   and same-order destructure read the written values even next to a
>   colliding struct, and a record whose field set is a strict subset of some
>   struct's is accepted (it used to be rejected as a construction of that
>   struct missing fields). Struct construction is spelled `S::{ ... }` only.
>   The literal's checker type is a structural record (`record { start: Int,
>   end: Int }` in diagnostics): passing it where a struct is expected is a
>   located type mismatch (`expected Span, got record { start: Int, end:
>   Int }`), and `.field` reads are typed against the record's own fields
>   (an unknown field is a located error).
> - **Record dot access** (`r.name` on an anonymous `record { ... }`) lowers to
>   the positional field read the destructure uses, and now resolves in every
>   expression position — a `let` initializer (including a top-level `let`
>   reading a binding declared by an EARLIER top-level `let`), a function/test
>   body (including one that closes over a top-level record binding), and a
>   nested call argument (#839, fixed 2026-07-13: both lowering passes
>   — `desugar_railway_binds`/`check_program` and the independent
>   `desugar_trait_dicts` pass the RC/FS-compile codegen entries use — used to
>   reset their binding-shape tracking at every top-level statement boundary,
>   so only a record literal and its `.field` read sharing one statement's own
>   expression tree ever resolved). Destructuring (`let record { name: n } = r`)
>   binds any field name and works in fn/block bodies too.
> - **`Map::from_pairs([...])` / `Map::new()` + `Map::*` builtins + `m[k]`
>   indexing** work standalone (#760/#960): `Map::get` / `has_key` / `set` /
>   `keys` and the `m["k"]` index sugar all lower correctly. The old
>   `map { ... }` literal was removed in #960 (it now reports a located parse
>   error naming the replacement API). (`lib/@vibe/core`'s `get`/`get_or`/
>   `has_key`/`keys`/`values` remain available for a richer Map API, #766.)

## Effects (core concept)

vibe is **pure by default**. Semantic effects, including `Exception`, are tracked
in the type system. An empty row excludes an escaping exception, but does not guarantee
termination or exclude panic, Wasm trap, or resource exhaustion (ADR-0073).
Missing effects are reported as a set difference (`effect row mismatch for 'f':
missing { Fs } (declared { Exception }, requires { Exception, Fs })`) with a `hint:`
line suggesting the exact row to declare (`hint: add 'with Exception + Fs' to
'f'`, #639). The braces in that message render effect SETS, not source
syntax — which is why they survived #1429 while the `hint:` line, being
something you paste into your code, moved to the braceless spelling with
everything else.

### Standard provider and entry-execution policy (#1496)

The compiler keeps independent private policy owners at
`lib/@vibe/compiler/core/standard_effect_policy.vibe`: host-provider resource
defaults, ordered test/bench defaults, ordered entry-cache-safe labels, and
predicates for entry-boundary exceptions and runtime-scheduled `Async`. They
record only the standard execution behavior the current runner needs; they do
**not** assign a source-language effect class. An ordinary user effect such as
`Log`, `State`, or `Ask` has no standard policy record and is handled solely by
its declarations and `handle` expressions.

| policy | execution owner | current standard labels |
|---|---|---|
| host-provider metadata | host / provider outside the Wasm boundary | `Fs` `Http` `Socket` `Env` `Console` (`Stdin`/`Stdout`/`Stderr` = still-accepted legacy labels, same host imports) `Process` `Profiler` |
| entry-boundary exception policy | entry boundary diagnoses an escaping exception | `Exception` / `Exception[E]` (`Error` was retired as a row spelling in #1461) |
| runtime scheduling policy | runtime itself | `Async` |

The ordered default and cache-safe owners preserve their existing output.
At a program entry (`main` or `_start`), the checker admits only the union of
host-provider labels and entry/runtime-managed labels. A user effect such as
`Ask` / `Ask::Get` must be discharged by `handle ... with Ask` before that
boundary; adding it to `main`'s `with` row is rejected with a located diagnostic
(#1683). Ordinary helper functions still fix a missing effect by adding it to
their row so callers can decide where to handle it. WIT mapping and handler
behavior are unchanged. Provider spelling alone grants no authority:
`Fs::Custom` from `effect Fs { Custom() -> Int }` is still a user operation and
must be handled, while the registry-owned `Fs::read_file` remains a host
operation even if another linked module has an unrelated `effect Fs`.
Entry rows must also be concrete; an unresolved `with e` is rejected with a
hint to close the row rather than the invalid suggestion `handle ... with e`.

### Atomic stdin provider stream (#1539)

```text
Stdin::read_via_stream() -> StdinStream with Stdin
StdinStream::next(StdinStream) -> Int with Async
StdinStream::close(StdinStream) -> Unit with Async
StdinStream::read_chunk(StdinStream, Int) -> Option[String] with Async
```

`next` yields `0..255`, then `-1` after successful EOF settlement. `close`
settles an early stop; repeated close and reads after successful settlement are
idempotent. `StdinStream` is opaque, non-`Send`, and unrelated to `HostStream`
or eager `Stream[T]`. All four provider operations are direct-call-only:
referencing one as a value (including through an alias, container, return value,
or unknown higher-order call) is rejected. Wrap a direct call in a user function
whose row explicitly declares `Stdin` or `Async` when transport is needed.
`read_chunk(stream, n)` directly returns exactly `n`
bytes per `Some` except for the final short chunk; it does not preserve provider
read boundaries and preserves arbitrary bytes. EOF settles the provider, after
which calls return `None`. For `n <= 0`, it returns `None` without reading or
settling, so the caller must close the stream. An exact multiple needs one extra
call to settle EOF. The retired pull-closure `stdin_stream(chunk_size)` is no
longer exported. Pull explicitly with `StdinStream::read_chunk` and close the
provider on every early-stop path. A direct `for` adapter remains blocked on
transitive higher-order effect evidence (#1536); do not treat `read_chunk` as
directly iterable. This surface is component-only (linear/RC); GC, standalone
core, `host_stream_named("stdin")`, and mixed named-provider composition are
rejected.

An operation cannot declare its own effect row. Effects are carried by the
handler that interprets it, or by an effectful function in the payload
(`Run(f: () -> Int with Exception) -> Int` is accepted). `#2264`.

```vibe skip
effect E {
  Op(n: Int) -> Int with Fs
}
```

**Naming.** Effect names are CamelCase. A standard provider builtin is a plain
`Effect::snake_case` function call; a declared operation is CamelCase and is
emitted with `perform`:

```vibe
// Standard provider builtin. No `perform`; the row carries `Fs`.
fn read_config() -> String with Fs {
  Fs::read_file("config.toml")
}

// Declared operation, performed and handled in the program.
effect Log {
  Emit(String) -> Unit
}

fn greet() -> Unit with Log {
  perform Log::Emit("hi")
}
```

Declared operations use CamelCase because `Log::Emit` is a constructor-like
operation record, not a function. Standard provider builtins are functions, so
they use `snake_case` and leave the row to carry the execution requirement.

`Fs`, `Env`, and `Profiler` currently expose both a declared-operation surface
and standard provider builtins under the same row label. This coexistence is
intentional: use the builtin for the host operation and a declaration when a
program needs to intercept it with `handle`.

### Failure-carrying pipeline

> **推奨は `throw` + `Exception[E]` row** (ADR-0085 / #1324)。失敗は返り値では
> なく row で運ぶ。成功値がそのまま次段へ流れるので `and_then` の連結が要らない。

<!-- doctest-skip: `...` ellipsis による意図的省略 (パイプライン形の提示) -->
```vibe skip
fn parse_id(raw: String) -> Int with Exception[String] { ... }
fn validate_id(id: Int) -> Int with Exception[String] { ... }
fn load_user(id: Int) -> String with Exception[String] { ... }

fn fetch_user(raw: String) -> String with Exception[String] {
  raw |> parse_id |> validate_id |> load_user
}

// 呼び出し側で捕まえる
handle { fetch_user(input) } with {
  Exception[String]::Throw(msg) => "failed: \{msg}"
}
```

> **status (#1324):** `Result` は**言語からも prelude からも無くなった**。
> slice 4 で `result.vibe` (型と combinator) を削除し、slice 5 で #760(2) の
> auto-injection (`inject_prelude_result`) を撤去した。失敗は `Exception[E]`
> row で運ぶのが標準の形 (ADR-0085)。`Option` (`Some`/`None`) は first-class
> builtin で無変更。
>
> `Ok`/`Err` が本当に要るのは **WIT 境界だけ** — WIT の `result<T,E>` は
> `Exception[E]` row からは射影されないので、そこには
> `import @vibe/wit_runtime { Result }` を使う ([effect-wit-mapping.md](effect-wit-mapping.md)、
> compiler-gate 89/89 が byte 単位で pin)。それ以外で自前に
> `enum Result[T, E] { Ok(T); Err(E) }` を宣言するのは自由だが、特別扱いは
> 一切なくただのユーザー enum になる。

### Railway bind (`let*`) — `Option` (#635 / #1324)

`let* x = e` unwraps the success case and binds `x`, or short-circuits the whole
block with the failure case. The lowering is **type-directed by `e`'s type**:

- `e: Option[T]` → `match e { Some(x) => <rest>, None => None }`

so the enclosing function must return an `Option`. Handy when stages need
names:

<!-- doctest-skip: 直前 block の定義 (half 等) に依存する断片 (将来の `vibe continue` 候補) -->
```vibe skip
let pair: (Int, Int) -> Option[Int] = (a, b) -> {
  let* x = half(a)                 // None short-circuits the block
  let* y = half(b)
  Some(x + y)                      // last expr is the block's Option
}
```

**Adopted scope (#635, narrowed by #1324):** `let*`/`?` lower to **`Option`
only**. They used to type-direct between `Option` and `Result`, defaulting to
`Result` when the operand's head type was undeterminable; #1324 removed
`Result` from the language, so there is nothing to direct between and no
default to get wrong. A user-extensible `Try`/`Bind` trait (option 2) is
**deferred** (it depends on method-bearing traits).

Using `let*`/`?` on something that is not an `Option` is a type error — the
short-circuit arm is `None`, so it is reported where that value meets the
enclosing function's return type (e.g. `return type mismatch: expected
Result[Int, String], got Option[?]` for a `?` inside a function returning a
hand-declared `Result`).

### Debugging a pipeline (`tap`)

`tap` runs a side effect on the value and returns it unchanged — observe a
stage without breaking the `|>` chain. `tap_some` observes only the `Some`
track. Both are `@vibe/console` exports (`lib/@vibe/console/tui.vibe`) — they
carry `Stdout` in their signature, which is why they live there and not beside
`Int::abs` (#2102) — so import them, and note that observing with a print costs
the `Stdout` effect on the chain. (`tap_ok` / `tap_err` were removed with
the prelude `Result` in #1324.)

<!-- doctest-skip: 未定義名 (x / next_stage / opt) を参照する構文提示の断片 -->
```vibe skip
x
|> tap((v) -> println("step: \{v}"))
|> next_stage

opt |> tap_some((v) -> println("got \{v}"))
```

### Error boundary (`throw` / `handle`)

```vibe
let risky: (Int) -> Int with Exception = (x) -> {
  if x == 0 { throw("division by zero") }
  100 / x
}

// handle catches the effect
let safe = handle { risky(0) } with { Exception::Throw(msg) => -1 }
```

`throw` is call-form only: `throw(NotFound("x"))`, not statement-form
`throw NotFound("x")` (#2265). `throw(x)` は `perform Exception::Throw(x)` と等価 (#640)。`Exception` は再開不能
(non-resumable) — `Throw` arm の値がそのまま handle の結果になるため、
arm 内の `resume(...)` は checker がエラーにする。
Stage 2 (#640) で `throw(x)` は parse 時に `perform Exception::Throw(x)` へ脱糖され、
両綴りはパイプライン全体で単一の内部表現になった（printer は `throw(x)` に
再糖衣する）。`perform Exception::Throw(x)` は effect-row 上も `throw` と同じ扱いで、
現在の関数が `with Exception` を宣言するか、囲む `handle .. with Exception` で
放電する必要がある。`fn main with Exception` から escape した例外は runtime
最外周で診断付きの異常終了へ変換される。

なお **effect の綴りとしての `Error` は退役した** (#1461, #1501)。`Error` が
effect を名指す位置は2つあり、どちらも parse error になる:

```
fn f() -> Int with Error { .. }              // row 項目        -> parse error
handle { .. } with Error { Throw(_) => .. }  // handle する effect 名 -> parse error
```

どちらも `vibe fmt` が `Exception` へ書き換える (formatter は token 単位なので、
パーサがもう受理しないソースも変換できる)。

一方 **`perform Error::Throw(x)` は今も通る** — operation 修飾子は row 項目では
なく、runtime が dispatch する operation を名指しているだけで、そこに row を
綴っているわけではないため。

### Typed exceptions (`Exception[E]`, ADR-0085 / #1344)

bracket なしの `Exception` は kind を持たない erased な例外 row。失敗の**型**を
row に出したいときは `Exception[E]` と書く。`E` は投げる値の静的型。

```vibe
enum IoError {
  NotFound(String)
}

enum ParseError {
  Eof
}

// この関数が投げうるのは IoError だけ、と row が言う
let read_cfg: () -> Int with Exception[IoError] = () -> {
  throw(NotFound("cfg"))
}

// 複数 family は subclass ではなく effectset の union で表す
effectset ConfigExceptions = {
  Exception[IoError],
  Exception[ParseError]
}

// handler は exact kind だけを放電する
let n = handle { read_cfg() } with { Exception[IoError]::Throw(_e) => 0 }
```

規則:

- `Exception[IoError]` は `Exception[ParseError]` を authorize も discharge も
  しない。row に無い kind を投げると `missing { Exception[IoError] }`。
- **bracket なしの `Exception` は全 kind と compatible** な erased 綴り。
  `with Exception` は今までどおり何でも投げられるし、erased な
  `handle .. with Exception` は kind 付きの throw も捕まえる。
- payload の kind が解決できない throw (例: `throw(e)` の `e` が local
  binding) は erased 扱いになり、どの `Exception[K]` でも通る (gradual)。
  検出漏れはあるが誤検出はしない。
- runtime は kind を区別しない — すべて単一の abortive Wasm tag。exact-kind
  の保証は checker 側の性質。

詳細と v1 の限界: [exception-effect.md](exception-effect.md)。

### Railway try (`?`) — `Option` (#635 / #1324)

`e?` unwraps `Some` and yields the inner value, or **early-`return`s** `None`
from the enclosing function:

- `e: Option[T]` → `match e { Some(v) => v, None => return None }`

<!-- doctest-skip: 未定義名 (half) を参照する断片 (前セクション依存) -->
```vibe skip
let sum_halves: (Int, Int) -> Option[Int] = (a, b) -> {
  let x = half(a)?                 // None early-returns from sum_halves
  let y = half(b)?
  Some(x + y)
}
```

Same adopted scope as `let*` above: `Option` only. (The deferred `Try` trait —
option 2 — would let user types opt in; it is not implemented.)

### suberror (typed errors)

```vibe
suberror NotFound(String)
suberror InvalidInput(Int, String)   // tuple payload only
```

### User-defined effects (algebraic)

```vibe
effect Logger {
  Log(String) -> Unit
}

let greet: (String) -> Unit with Logger = (name) -> {
  perform Logger::Log("hello \{name}")
}

// the handler arm prints, so the executable entry carries Stdout
fn main with Stdout {
  handle { greet("world") } with {
    Logger::Log(msg) => {
      println(msg)
      resume(())         // continue where perform left off
    }
  }
}
```

継続呼び出しは `resume(v)` が canonical (one-shot tail-resumptive, ADR-0050)。

Effect row の呼び出し解決も通常の値解決と同じ lexical scope に従う。局所
closure・関数 parameter・pattern/loop binder が top-level `fn` と同名なら、
局所 binding が優先される。したがって、純粋な局所 `take` が同名の
`fn take(..) with Ask` を隠している間、その呼び出しに `Ask` は計上されない。
局所 scope を抜けると top-level の row が再び有効になる。

> **evidence-passing 実装 (#817, ADR-0076 追記34 V2 で replay 全廃)**:
> handler は evidence dict への直接呼び出し (tail-resumptive) か
> suspend CPS (first-class resume) にコンパイルされ、handle body は
> **常に一度だけ実行される** (旧 replay 実装の副作用重複と ~16K perform
> 上限は消滅)。代償として、handle body から届く perform は migration が
> 追える形に限られる — 追えない形 (row 変数 `with e` の callee 経由、
> row 無しの外側 local closure 経由など) の非 Exception handle は
> **compile error** になる (needle: "cannot be compiled here")。
> 受理される形の実測表は下の
> [A `handle` that type-checks can still fail to compile](#a-handle-that-type-checks-can-still-fail-to-compile) 節。

**`resume` は arm 内で第一級の one-shot 値** (ADR-0076 Phase 3a, #817):
直接呼び出し `resume(v)` は tail 位置限定のまま (#942) だが、値として
束縛・保存すればふつうの closure として後から (一度だけ) 呼べる —
scheduler が継続を受け取る suspend パターンの基盤 (ADR-0068)。

```vibe
effect Async { Suspend(Int) -> Int }
let conts: Array[(Int) -> Int] = []

let r = handle {
  let a = perform Async::Suspend(1)
  a * 10
} with {
  Async::Suspend(t) => {
    Array::push(conts, resume)   // 保存して…
    0 - t                        // …arm の値で handle が「サスペンド」
  }
}
// あとで (Array::get(conts, 0))(5) を呼ぶと残りの body が走って 50
```

制約 (linear backend のみ): resume を値参照する handle の body では、
対象 effect の perform (と、row にその effect を持つ関数の呼び出し) は
let/seq/tail/分岐 tail に直接現れる必要がある。**let 連鎖 (brace block
文や文位置の async-iterator `for` の脱糖出力) が文の途中 (sequence HEAD)
に立つ形は、split が継続 spine へ float して受理する** (#1536 (a) v3,
ADR-0076 追記42 — `async_iter_collect` / `_fold` / `_count` が suspend
body から呼べるのはこれ)。**`if` condition / `match` scrutinee が direct
perform・concrete needing call・CPS-local call そのものなら、fresh let へ
一回評価してから selection する形も可** (追記44)。同じ direct 形そのものは
**継続 spine 上の通常代入 (`x = perform Op()`) の RHS** でも fresh let を介して
一回だけ代入できる (追記45)。**compound の中に埋まった perform も可** —
被演算子 (`acc + perform Op(i)`)・呼び出し引数
(`Array::push(out, perform Op(i))`)・コンストラクタ引数
(`Some(perform Op(i))`)・compound な `while` 条件 (`perform Next() > 0`)・
`+=` 等の compound assignment は、**元の評価順で let 連鎖へ線形化**されてから
spine に乗る (#1536 (a) v8)。perform より前に評価されるものは先に名前が付くので
順序は変わらない。条件付き位置は原則 reject だが、`&&` / `||` 全体が**不変の
`let` initializer** で、左辺が suspend せず、選択される右辺が直接対応済みの
suspension またはその `let` / sequence spine である場合だけ対応する。入れ子の
short-circuit、呼び出し引数等の compound、`return` / `break` / `continue` で
終わる spine、`if` / `match` の枝など、より広い条件付き・制御移譲形は reject のまま。
**concrete な row に
対象 effect を含む top-level 関数の呼び出しは可** (3b yield bubbling —
再帰も可; callee には CPS clone が合成され、元の関数は他の呼び出し元
向けに無変更)。それ以外に呼べるのは perform / pure builtin / ctor /
「concrete row が対象 effect を含まない関数」、そして **row-free な
closure param 経由の呼び出しのうち、その関数の全 by-name call site が
perform を含まない closure literal (または委譲元の同様に証明済みの
param) を渡すと静的に証明できるもの** (#1536 (a) — `async_iter_find`
の `pred(v)` がこの形。1 site でも perform する literal を渡すと従来
どおり reject)。**`while` / `loop` の中の perform も可** (#1230/#1536 —
ループは step を返す再帰クロージャになる。`break` / `continue` を持つ本体も
可で、`break` はループの脱出継続、`continue` はループ自身の呼び出しになる。
`return` を含む本体だけは今も compile error — クロージャから関数を return
できないため)。row 変数 (`with e`)
付き callee・`for` 形式の中の perform は compile error。同じ継続の 2 回目の
呼び出しは stderr 診断つきで trap する。post-processing は値経由
(`let k = resume  let r = k(v)  r + 7`) で書く。see-through できない
呼び出しで reject されるときの診断は、handle 適格性の診断と同じ形式で
**どの呼び出しが不適格かを名指しし、その `line:col` を指す**
(`(here: the call to 'pred')`, #1536/#1514)。

**closure 値経由の suspend も可** (closure-CPS ABI, ADR-0076 追記31):
`fn run_with(f: () -> Int with E) -> Int { handle { f() } with E
{...} }` のように、suspend する body を **closure 引数**として渡せる
(handle site を library 側に置ける — `TaskGroup::spawn_suspend` が
この形)。suspend する closure literal には**明示 row 注釈が必要**:
`() -> Int with E { ... }` (無注釈 lambda の effect は enclosing の
row へ継承されるため、#761)。同じ effect を「resume 値参照の handler」
と「tail-resumptive handler」で混在させたまま closure を step-compile
するプログラムは compile error (規約整合ガード)。

operation の宣言 arity より 1 つ多い末尾パラメータを束縛する `k` 規約
(`Emit(v, k) => v + k(0)`、non-tail 継続) は **旧 MoonBit fixture runner
専用だった機能で、現行 build path では未サポート** — checker が
`handler arm ... expects 0 payload binding(s), got 1` で reject する
(#814)。evidence-passing 移行 (#817) は完了したが非 tail 継続は入って
おらず、`resume(v)` も **arm の tail 位置限定** (`resume(10) + 1` は
`resume(...) must be the last expression of the handler arm` で reject、
#942/ADR-0050)。継続呼び出しは tail の `resume(v)` を使う。
規約の詳細は [archive/mut-effect-plan.md](archive/mut-effect-plan.md) の
「継続呼び出し規約」(#627) を参照。

### Effect polymorphism

```vibe
let apply: [T](f~: (T) -> T with e, x~: T) -> T with e = (f~, x~) -> {
  f(x)
}
```

### resource 宣言 (ADR-0075 Phase 2 / #1343)

```vibe skip
resource Posts: S3::Bucket
```

executable が binding を要求する **logical resource identity** の宣言。
resource を作るわけではなく、値でも型でもなく、physical name も credential
も持たない (それらは host adapter 側、ADR-0075)。resource kind パラメータを
**名前で** instantiate する (`S3::Read[Posts]`) ための宣言。

- kind は**修飾パス** (`Owner::Kind`) 必須 — 裸の名前は型と区別できず、
  resource kind は型ではない
- `resource` は**文脈キーワード**: 直後が識別子のときだけ宣言。
  `let resource = 1` / `resource(x)` はそのまま使える
- 名前は一度だけ。**singleton kind (`Process::Root`) の resource は宣言
  できない** — 住人は `Process::Root` 自身ただ一つなので、別名は同じ
  process への alias にしかならない
- `export` できない (ADR-0075 は `.vibex` root 限定。再利用モジュールは
  resource 名ではなく resource **kind パラメータ**で抽象化する)

## Module System

<!-- doctest-skip: 存在しない import 先 (./lib.vibe) を参照する構文一覧 -->
```vibe skip
// export
export let f: (Int) -> Int = (x) -> { x + 1 }
export enum Color { Red; Green; Blue }
export { name1, name2 }
export ./lib.vibe { helper1, helper2 }  // re-export

// import
import ./lib.vibe { func1, func2 }
import ./lib.vibe { func1 as renamed }
import ./lib.vibe { type MyType, struct Point, enum Color, effect Console, trait Show, println }
import ./subdir { helper }   // directory import -> subdir/index.vibe(i)
import . { helper }          // own directory's index (same resolution)

// module blocks (`module Math { ... }`) are REMOVED (#728, ADR-0063):
// use file boundaries + import/export. `Type::method` / `Effect::Op`
// qualified access is an independent mechanism and remains.
```

### Selective import kinds

Values use the bare item spelling, including values declared with `fn` or
`let`. A function declaration is sugar for a value binding, so there are no
`fn` or `let` import qualifiers:

```vibe skip
// doctest-skip: illustrative module path
import @vibe/console { effect Console, struct Tty, println }
```

Bare items remain accepted for compatibility. The optional `type`, `struct`,
`enum`, `effect`, and `trait` qualifiers are exact: `type` requests a type alias,
and each other qualifier requests the correspondingly named declaration kind.
For example, requesting `type Color` or `struct Color` when `Color` is an enum is
rejected with a diagnostic that identifies both the requested and exported
kinds. Selective re-exports use the same rules.

A later migration will make qualifiers mandatory for non-value imports. Bare
value imports will stay bare.

### Same-named traits from two packages are rejected (#1910)

When one compile unit can see two **different** `trait` definitions with the
same name — imported explicitly, or pulled in implicitly because an imported
value carries a `[T: Trait]` bound — the checker reports
`trait 'Hash' has two different definitions: '<site1>' and '<site2>'` instead
of letting import order pick one silently. The fix is in the message: alias
one side (`import ./a.vibe { trait Hash as TheirHash }`) or import only one.
The *same* definition reached through re-export paths is not a conflict, and
two different traits forced onto one local name via explicit aliases is the
separate `ambiguous trait import alias` error.

### Qualified names

どの記号が識別子の一部になるかは文脈で決まる。

| 綴り | 意味 | 例 |
|---|---|---|
| `@name` | package 参照 | `@json`, `@lib/path` |
| `@` の後の `-` | package 名の一部 | `@my-pkg` |
| `@` の後の `/` | package path の一部 | `@lib/path` |
| `@` の無い `-` | 減算演算子 | `x - 1` |
| `.` | field / member アクセス | `point.x`, `tuple.0` |
| `::` | 型 / module のメンバ | `Array::length` |

`@` 接頭辞は package 参照を開き、そこから先の `-` と `/` は演算子ではなく
名前の一部になる。`.` は識別子の一部にはならず、常に member アクセス演算子
(優先順位 1) として解釈される。`::` は型・module のメンバを指す
(`Array::length`, `Option::Some`, `String::substring`, `MyModule::x`,
`Point::{ x: 1, y: 2 }`)。

### Keywords

`let`, `rec`, `fn` (文の先頭のみ), `mut`, `if`, `else`, `match`, `do`, `while`,
`loop`, `for`, `in`, `break`, `continue`, `yield`, `throw`, `perform`,
`resume`, `handle`, `test`, `bench`, `enum`, `struct`, `trait`, `impl`,
`type`, `import`, `export`, `internal`, `extern`, `as`, `true`, `false`,
`suberror`, `derive`

`record` と `map` は literal の先頭でだけキーワードになる文脈依存語で、
`map` は予約語ではない。

## Tests and Examples

```vibe
test "arithmetic" {
  assert_eq(1 + 1, 2)
  assert(eq("a", "a"))
}

// #819: a documentation example. Compiled and RUN like a test -- a doc sample
// that stopped compiling is exactly what this form exists to prevent. Lowered
// to a test by the parser, so every later stage treats it as one (checked,
// kept alive by DCE, executed); only LSP hover / doc extraction see the
// difference. Unused bindings inside an example are not reported -- sample
// code is read, not just executed.
example "adding two numbers" {
  assert_eq(add(1, 2), 3)
}
```

```bash
vibe test file.vibe
vibe test dir/            # run all tests in directory (examples run too)
```

## Key Builtins

The list below is the **index**; the normative one — what 0.1.0 promises SemVer
stability for — is [spec/stable-surface.md](spec/stable-surface.md) §3, and
`pkf run check-freeze-surface` probes every name in it against the compiler.
The bullets here are checked the same way, so a name listed as a builtin here
resolves as one.

- **String**: `length`, `byte_at`, `from_byte`, `char_code_at`,
  `from_char_code`, `concat`, `substring`, `contains`, `index_of`, `split`,
  `trim`, `starts_with`, `ends_with`, `join`
- **Array**: `length`, `get`, `slice`, `concat`

`Map::get` / `has_key` / `keys` / `values` / `set` / `size` and the Array
HOFs (`map`, `filter`, `fold`, `find`, `any`, `all`, `reverse`) are call-only
operations, not first-class values (`Array::map(xs, f)`, not
`let g = Array::map`). They live in the Signature reference; they are not
indexed here because the freeze probe is a bare reference.

`String` is a byte string: `length`, indexes and slices use byte counts and
offsets, and iteration yields byte-valued `Int`. Unicode code-point and
grapheme operations are not part of this API.

<!-- import-required-builtins: the authoritative list. scripts/check_cheatsheet_signatures.sh
     requires this paragraph to name EXACTLY the entries in the Signature reference
     tables that `lookup_builtin` does not know -- no more, no less. -->

These are **not builtins** — they are library functions, and calling one without
its import is `unknown name`. The Signature reference documents them next to the
real builtins, which is why they are listed here.

From `@vibe/builtin` (`import @vibe/builtin { ... }`):
`String::replace`, `String::replace_all`, `String::trim_start`,
`String::trim_end`, `String::count`.

From `@vibe/json` (`import @vibe/json { ... }`):
`Json::parse`, `Json::stringify`, `Json::type_of`, `Json::get`, `Json::index`,
`Json::is_null`, `Json::length`, `Json::keys`, `Json::stringify_lines`,
`Json::parse_lines`.

**Bytes** (linear memory 上の可変バイト列。容量倍々 + `memory.copy` で伸長するので
`push` は償却 O(1)):

| 関数 | 意味 | backend |
|---|---|---|
| `Bytes::new()` | 空バッファ (初期容量 64) | linear / gc |
| `Bytes::length(b)` / `get(b, i)` / `set(b, i, v)` | 長さ・要素 | linear / gc |
| `Bytes::push(b, v)` | 1バイト追加 (償却 O(1)) | linear / gc |
| `Bytes::append(dst, src)` | **一括連結。`memory.copy` 1発** | linear / gc |
| `Bytes::concat(a, b)` | 新しいバッファを返す連結 | linear / gc |
| `Bytes::slice(b, start, end)` | 部分列 | linear / gc |
| `Bytes::blit(dst, src, dst_off, len)` | **範囲コピー。`memory.copy` 1発** | linear / gc |
| `Bytes::fill(b, off, len)` | **範囲埋め。`memory.fill` 1発** | linear / gc |
| `Bytes::from_array(a)` / `to_array(b)` | `Array[Int]` との変換 (**コピーが入る**) | linear / gc |

> バイト列を組み立てるループで `Bytes::push` を回すより、まとまった範囲は
> `Bytes::append` / `Bytes::blit` に置き換えるほうが速い — どちらも
> `memory.copy` 1命令に落ちる。`Array[Int]` に貯めてから `Bytes::from_array`
> するのはコピーが1回増えるので、最初から `Bytes` に書くほうがよい。

**SIMD scans** (scan `Bytes` / `String` in 16-byte chunks; available on both
the linear and GC backends):

| Function | Meaning |
|---|---|
| `simd_skip_ws(buf, pos, len) -> Int` | First position that is not whitespace |
| `simd_scan_alnum(buf, pos, len) -> Int` | End of an identifier-byte run |
| `simd_scan_alnum_str(s, pos, len) -> Int` | `String` version of the identifier scan |
| `simd_scan_string_special_str(s, pos, len) -> Int` | First quote, backslash, or ASCII control byte |
| `simd_scan_line_end_str(s, pos, len) -> Int` | First LF (`0x0a`) byte, or `len` if no LF exists |

> SIMD requires linear memory: `v128.load` takes a memory address, while a
> wasm-gc array is not addressable memory and has no bulk load from `(array
> i8)` into a v128. **Keep byte-oriented hot data in linear memory (`Bytes`).**
> `Bytes` remains linear-memory-backed on the GC backend, so these functions
> behave the same in both lanes.

**I/O** (require effects):
<!-- doctest-skip: 未定義名 (s) + effect context 無しの呼び出しシグネチャ一覧 -->
```vibe skip
println(s)         // with Console - builtin, no import
print(s)           // with Console - no trailing newline
read_line()        // with Console - @vibe/console
eprintln(s)        // with Console - @vibe/console
sh("ls -la")       // with Process - shell command
sh_lines("ls")     // -> Array[String]
```

**Profiling** (require `Profiler` effect; linear backend only; use the
direct-call surface — unhandled `perform` throws):
<!-- doctest-skip: effect context (with Profiler) 無しの直接呼び出し例 -->
```vibe skip
Profiler::now_us()      // with Profiler - elapsed µs (wall clock)
Profiler::heap_bytes()  // with Profiler - current bump-heap pointer
                        // (bytes allocated); deltas attribute allocation the
                        // way now_us deltas attribute time (heap never shrinks)
```

**Conversion**: `Int::to_string`, `Int::to_double`, `Double::to_int`, `String::from_byte`, `Int::parse(s) -> Option[Int]` (10 進、先頭 `-` 可; 空文字列・非数字・`Int::max_value` 超えは `None`), `Double::parse(s) -> Option[Double]` (符号・整数部・小数点付き小数部; 指数表記 `1e10` は非対応。linear backend のみ、gc backend は未対応)

### Signature reference

The section above says what exists; this one says how to call it. The
tables were inherited when the deleted `docs/language-tour/` was folded in,
and every row has been checked against the actual `lib/` entity (the three
rows `where` / `path` / `String::from_char_codes` had no entity behind them
and were dropped).

**Operators** — used as operators, not called directly:

| operator | desugars to | types |
|---|---|---|
| `a + b` / `a - b` / `a * b` / `a / b` / `a % b` | `__add` / `__sub` / `__mul` / `__div` / `__mod` | Int, Float, Double |
| `-a` | `__neg(a)` | Int, Float, Double |
| `a == b` | `__eq(a, b)` | Eq types |
| `a < b` | `__lt(a, b)` | Ord types |
| `a & b` / `a \| b` / `a ^ b` | `__bit_and` / `__bit_or` / `__bit_xor` | Int |
| `a << b` / `a >> b` | `__lshift` / `__rshift` (arithmetic shift) | Int |
| `a[i]` | `__index(a, i)` | Array, Map |

prelude wrappers: `add`, `sub`, `mul`, `div`, `eq`, `lt`, `not`, `and`, `or`.

**String**:

| function | signature |
|---|---|
| `String::length` | `(String) -> Int` |
| `String::concat` | `(String, String) -> String` |
| `String::substring` | `(String, Int, Int) -> String` (start, end) |
| `String::byte_at` | `(String, Int) -> Int` (deprecated alias `String::char_code_at` — `vibe check` warns per use) |
| `String::from_byte` | `(Int) -> String` (deprecated alias `String::from_char_code` — `vibe check` warns per use, including inside `\{...}` interpolations, #2203) |
| `String::equals` | `(String, String) -> Bool` |
| `String::split` / `String::join` | `(String, String) -> Array[String]` / `(Array[String], String) -> String` |
| `String::contains` | `(String, String) -> Bool` |
| `String::index_of` / `String::last_index_of` | `(String, String) -> Int` |
| `String::starts_with` / `String::ends_with` | `(String, String) -> Bool` |
| `String::trim` / `String::trim_start` / `String::trim_end` | `(String) -> String` |
| `String::replace` / `String::replace_all` | `(String, String, String) -> String` |
| `String::to_upper` / `String::to_lower` | `(String) -> String` |
| `String::count` | `(String, String) -> Int` |

`String::from_byte(n)` always builds a 1-byte string from the low 8 bits of
`n` (two's complement) and never traps — measured (#2203): `256` → byte 0,
`257` → byte 1, `-1` → byte 255, `1000` → byte 232. A value above 127 is a
raw byte, not a code point (ADR-0098); UTF-8-encoding a code point is a
different, currently nonexistent function.

**Array** (builtin): `length: (Array[T]) -> Int`, `get: (Array[T], Int) -> T`,
`slice: (Array[T], Int, Int) -> Array[T]`,
`concat: (Array[T], Array[T]) -> Array[T]`, `reverse: (Array[T]) -> Array[T]`.

**Array** (prelude; collection first, function last):

| function | signature |
|---|---|
| `Array::map` | `(Array[T], (T) -> U) -> Array[U]` |
| `Array::filter` | `(Array[T], (T) -> Bool) -> Array[T]` |
| `Array::fold` | `(Array[T], U, (U, T) -> U) -> U` |
| `Array::foreach` | `(Array[T], (T) -> Unit) -> Unit` |
| `Array::any` / `Array::all` | `(Array[T], (T) -> Bool) -> Bool` |
| `Array::find` | `(Array[T], (T) -> Bool) -> Option[T]` |

**Builder**: `ArrayBuilder::new() -> ArrayBuilder[T]`,
`push(ArrayBuilder[T], T) -> Unit`, `freeze(ArrayBuilder[T]) -> Array[T]`.
`MapBuilder::new() -> MapBuilder[String, V]`,
`set(MapBuilder[String, V], String, V) -> Unit`,
`freeze(MapBuilder[String, V]) -> Map[String, V]` — String-keyed, like `Map`.
A `for-in` comprehension desugars to these builder operations internally.

**Map** — the builtin `Map` is **String-keyed**, not generic in its key.
`Map::set(m, 7, 1)` is `argument type mismatch for Map::set: expected String,
got Int`. For a generic key, use `MutMap[K, V]` from `@vibe/core`.
`get: (Map[String, V], String) -> V` (throws when absent),
`set: (Map[String, V], String, V) -> Map[String, V]` (returns a new map),
`has_key: (Map[String, V], String) -> Bool`,
`keys: (Map[String, V]) -> Array[String]`,
`values: (Map[String, V]) -> Array[V]`.


**Math**: `Int::abs`, `Int::max`, `Int::min`, `Int::clamp`, `Int::signum`,
`Int::is_even`, `Int::is_odd`, `Double::abs`, `Double::max`, `Double::min`,
`Double::floor`, `Double::ceil`.

**Conversion**: `Int::to_float`, `Int::to_double`, `Float::to_int`,
`Float::to_double`, `Double::to_int`, `Double::to_float`,
`__to_string: (Any) -> String`. **A bare `to_string` cannot be called** —
`to_string(1)` is read as a dot-call on `Int`, and answers
``dot-call syntax is not supported for the builtin method `Int::to_string` ``.
Use the per-type spelling (`Int::to_string(1)`) or `__to_string(x)`.

**I/O** (an effect is required). The current name for the tty is `Console`;
`Stdin` / `Stdout` / `Stderr` are **legacy labels** sharing the same host
imports, and the rows do not authorize each other. `allows
Console::write_stream` does not admit `Console::read_stream` (#1496).

| function | signature | effect |
|---|---|---|
| `sh` | `(String) -> String` (captured stdout) | `Process` |
| `sh_lines` | `(String) -> Array[String]` | `Process` |
| `Console::write_stream` | `(String) -> Unit` | `Console` |
| `Console::write_char` | `(Int) -> Unit` | `Console` |
| `Console::write_err_stream` | `(String) -> Unit` | `Console` |
| `Console::write_err_char` | `(Int) -> Unit` | `Console` |
| `Console::read_stream` | `(Int) -> String` | `Console` |
| `Console::read_char` | `() -> Int` | `Console` |
| `Stdout::write_stream` | `(String) -> Unit` | `Stdout` (legacy) |
| `Stdout::write_char` | `(Int) -> Unit` | `Stdout` (legacy) |
| `Stdin::read_stream` | `(Int) -> String` | `Stdin` (legacy) |
| `Stdin::read_char` | `() -> Int` | `Stdin` (legacy) |
| `Stdin::read_via_stream` | `() -> StdinStream` | `Stdin` |
| `StdinStream::next` | `(StdinStream) -> Int` (`-1` after EOF) | `Async` |
| `StdinStream::close` | `(StdinStream) -> Unit` (idempotent once it succeeds) | `Async` |
| `StdinStream::read_chunk` | `(StdinStream, Int) -> Option[String]` | `Async` |

The four stdin providers are **direct-call only**. To pass one as a value,
define a wrapper whose `with` row names `Stdin` / `Async` explicitly — the
checker rejects an alias to the builtin itself or a value-position
reference.

**JSON**: `Json::stringify: (Any) -> String`, `parse: (String) -> Json`,
`type_of: (Json) -> String`, `get: (Json, String) -> Json`,
`index: (Json, Int) -> Json`, the `string` / `number` / `bool` extractors,
`is_null: (Json) -> Bool`, `length: (Json) -> Int`,
`keys: (Json) -> Array[String]`, `stringify_lines: (Array[Json]) -> String`,
`parse_lines: (String) -> Array[Json]`.

**Lines**: `Lines::parse: (String) -> Array[String]`,
`Lines::stringify: (Array[String]) -> String`.

**Assertions**: `assert: (Bool) -> Unit`, `eq: (Eq, Eq) -> Bool`,
`assert_eq: (Eq, Eq) -> Unit`.

## Shell integration

`sh` / `sh_lines` はどちらも `Process` effect を要求する。

```vibe
let demo: () -> Array[String] with Process = () -> {
  // Execute command; returns the captured output (String)
  let out = sh("echo hello")

  // Execute and capture output lines
  sh_lines("ls /tmp")
  // => Array[String]
}
```

```vibe
let run: () -> Unit with Process = () -> {
  let _ = sh("echo hello")   // sh returns String; discard it in a Unit fn
}

// In tests, effects are implicit
test "shell" {
  let lines = sh_lines("echo hello")
  assert(eq(Array::length(lines), 1))
}
```

シェルのパイプは `sh_lines()` の文字列の中でそのまま使え、vibe の `|>` は
その結果を vibe の関数へ繋ぐ:

```vibe
let pipes: () -> Array[String] with Process = () -> {
  let a = sh_lines("echo hello | cat")
  let b = sh_lines("printf 'a\\nb\\nc' | sort -r")
  sh_lines("seq 1 10 | head -3")
}

let count_txt: () -> Int with Process = () -> {
  sh_lines("ls /tmp")
  |> Array::filter((s) -> { String::contains(s, ".txt") })
  |> Array::length
}
// Works because |> inserts value as first arg, matching collection-first order
```

### PosixMode (`vibe shell` の内部プレビュー)

`vibe shell` の内部 `PosixMode` では、裸のコマンドが `sh_lines()` 呼び出しへ
脱糖される。キーワード (`let` / `if` / `while` / `for` / `match` / `test` 等)
と関数呼び出しは脱糖されない。

```
> ls /tmp
note: posix-mode command-head desugar: ls -> sh_lines("ls")
```

| 入力 | 脱糖先 |
|---|---|
| `ls /tmp` | `sh_lines("ls /tmp")` |
| `cat file.txt` | `sh_lines("cat file.txt")` |
| `echo hello` | `sh_lines("echo hello")` |

`{{ expr }}` は vibe の文字列補間 `\{expr}` に変換される
(`ls {{ dir }}` → `sh_lines("ls \{dir}")`)。`$(cmd)` は POSIX 風のコマンド置換で、
`sh_lines("cmd")` を実行して**最初の 1 行**を差し込む。

## Idioms

<!-- doctest-skip: 未定義名 (read_config / parse / process / risky / xs / parse_int 等) を参照するイディオム断片 -->
```vibe skip
// Failure composition: the row carries it, so stages just chain
// (fn read_config() -> Config with Exception[String] etc.)
let result = read_config() |> parse |> process

// Boundary at the edge
let value = handle { risky(0) } with { Exception::Throw(_) => default_value }

// Builder pattern
let arr = {
  let b = ArrayBuilder::new()
  ArrayBuilder::push(b, 1)
  ArrayBuilder::push(b, 2)
  ArrayBuilder::freeze(b)     // implemented terminal; `build` is the planned/StringBuilder verb
}

// for-in as map
let doubled = for x in xs { x * 2 }

// pipe chain
input
  |> String::trim
  |> String::split(",")
  |> Array::map(_, parse_int)
```

## Conditional Compilation (`#cfg`)

<!-- doctest-skip: `...` ellipsis による意図的省略 -->
```vibe skip
#cfg(dev)
let debug_dump = (x) -> { ... }   // exists ONLY when the `dev` flag is active

#cfg(dev)
let run_mode = () -> Int { debug_dump(run()) }

#cfg(release)
let run_mode = () -> Int { run() }
```

- Activate flags at compile time: `VIBE_CFG=dev vibe build app.vibe` (comma-separated for multiple).
- A `#cfg(flag)` statement whose flag is inactive is parsed (syntax must stay valid, like Rust's `cfg`) and **dropped before checking/codegen** — zero bytes in the output binary.
- Top-level statements only (`let` / `enum` / `struct` / `impl` / ...).
- `vibe fmt` / normalize refuses `#cfg` sources (formatting would delete disabled code).
- Not usable inside the compiler's own source until the seed compiler understands it (see docs/bootstrap.md).

## Allocation contract (`#zero_alloc`)

Use `#zero_alloc` immediately before a top-level function to make any heap
allocation in that function or a transitively called function a compile error.

```vibe
#zero_alloc
fn add_one(x: Int) -> Int {
  x + 1
}
```

- Modes: bare `#zero_alloc` (general heap only), `#zero_alloc(strict)`
  (region/arena too), `#zero_alloc(assume)` (caller trust boundary;
  inspectable source allocations in the assume body are still errors).
- Import merge keeps a per-fn summary `(name, mode, site)`. An imported
  `#zero_alloc(assume)` fn is trusted by the importer; the assume fn's own
  summary still reports allocations in its body.
- It applies to `fn` and `export fn`, and no other declaration.
- Legacy `@zero_alloc` remains accepted for migration, but new code should use
  the `#` directive spelling shared with other declaration metadata.

## Deprecation marker (`#deprecated`)

Mark a top-level declaration deprecated; `vibe check` then reports every use
of that name as a **non-fatal `warning:` line on stderr** (the check still
passes, exit 0). This is the migration tool behind the ADR-0100/0101 renames
(deprecated aliases keep old spellings compiling while warning).

```vibe
#deprecated("use fresh_thing")
fn stale_thing(x: Int) -> Int {
  x + 1
}

fn caller(n: Int) -> Int {
  stale_thing(n)   // vibe check: warning: 'stale_thing' is deprecated: use fresh_thing
}
```

- Bare `#deprecated` or `#deprecated("message")` — the message rides along in the warning.
- Works on `fn` (including `fn Ns::method` forms), `let` / `let mut` / `let rec`, `enum`, `struct`, `type`, `effect`; a leading `export` is fine.
- Markers are collected from the checked file AND its linked dependency files; uses are reported for the checked file only.
- Detection is token-level (no name resolution): uses in any position warn — calls, type annotations, and the `import { ... }` list itself. An `import ... as` alias hides later uses (the aliasing import line still warns).
- Like `#cfg`, not usable inside the compiler's own source until the seed compiler understands it (see docs/bootstrap.md).

## Inline wasm (`= wasm "..."`, linear backend only)

A top-level `fn` may have a raw WAT (S-expression) body instead of a vibe body
(#805, ADR-0072) — for hand-optimized hot paths and SIMD:

<!-- doctest-skip: linear-backend 専用機能の構文提示 -->
```vibe skip
// mul must untag (>>1), multiply, retag (<<1) — see ABI note below
fn fast_mul(a: Int, b: Int) -> Int = wasm
  "(i64.shl (i64.mul (i64.shr_s (local.get $a) (i64.const 1))"
  "                  (i64.shr_s (local.get $b) (i64.const 1)))"
  "         (i64.const 1))"

fn simd_add(a: Int, b: Int) -> Int = wasm
  "(i64x2.extract_lane 0 (i64x2.add (i64x2.splat (local.get $a)) (i64x2.splat (local.get $b))))"
```

- **ABI contract (ADR-0055)**: params and result are RAW 62-bit tagged i64
  values — `Int` n arrives as `n<<1`. There are NO automatic shims: untag with
  `i64.shr_s 1`, retag with `i64.shl 1`. Tag-transparent ops (add/sub/and/or/
  xor/compares) may skip the dance; mul/div/shift must not.
- **Linear backend only** — the wasm-gc backend rejects it with a compile
  error. The declared signature is trusted (extern-let style).
- **v0.3 slice restrictions**: monomorphic only (no `[T]`), empty effect row,
  no `where` contracts, params typed literally `Int` or `Bytes`, return type
  `Int`. A `Bytes` param passes the RAW untagged object pointer (linear heap
  layout: length at `obj+4`, data pointer at `obj+8`) — the body can
  `i32.load offset=8` the data pointer and feed `v128.load`/`v128.store`
  (the pointer is only valid while the Bytes is alive and un-grown). No
  `call` / `global.*` / `br_table` / `f32.const` / `f64.const`.
- **Locals**: the fn's own params (`$name` or index), plus `(local $name
  TYPE)` declarations at the START of the body — types `i32`/`i64`/`v128`,
  grouped in that order (a located error enforces the grouping); declared
  locals index past the params + closure-env slot. v128 locals are what let
  a kernel keep vector state across instructions (e.g. the BLAKE3 compress
  in `lib/@vibe/blake3/simd.vibe`).
- **WAT text**: ordinary string literal(s) — the lexer has no raw/multiline
  strings; adjacent literals after `= wasm` are joined with newlines. `;;`
  line and `(; ;)` block comments work inside the text.
- Folded S-expressions emit operands first (real WAT semantics); flat
  sequences (`local.get $a local.get $b i64.add`) also work. Structured
  control (`block`/`loop`/`if`) is folded-form only:
  `(block $l (result i64) ...)`, `(if (result i64) <cond> (then ...) (else ...))`,
  `br`/`br_if` with `$label` or relative depth.
- SIMD (0xFD prefix) is supported: `v128.const i64x2 1 2`, splat /
  extract_lane / replace_lane, `i8x16.shuffle` (16 lane-byte immediates
  0..31), lane arithmetic, bitwise, `all_true` / `any_true` / `bitmask`,
  `v128.load` / `v128.store`.
- Memory instructions address the runtime's linear memory directly — the heap
  layout is NOT a stable interface; loads/stores are at-your-own-risk.
- Not usable inside the compiler's own source until the seed compiler
  understands the syntax (same bump discipline as `#cfg`, docs/bootstrap.md).
- Examples: `fixtures/inline_wasm_test.vibe`.

## RC Debug Mode (`VIBE_RC=shadow`)

`VIBE_RC=shadow vibe build app.vibe` compiles on the Perceus RC path with **shadow-liveness instrumentation**: every freed heap block is marked in a shadow byte table, and the FIRST `rc_dup`/`rc_drop` touching a freed block executes `unreachable` — a deterministic trap at the faulting operation, instead of free-list corruption that crashes later at an unrelated location ("moving target", see issue #715). Debug-only: adds a memory pad + per-dup/drop checks. Normal builds (`VIBE_RC=1`/unset) are byte-identical to before this feature.

## 落とし穴 (measured, not folklore)

判断に迷いやすい規則をここに集める。**すべて現行 stage2 で実測したもの**で、
仕様書の記述ではない。同じことを二度調べ直さないための場所。

### A `handle` that type-checks can still fail to compile

Eligibility is not part of the type system, so this failure is invisible to
type checking on its own. Since #1511(b)/#1536(c) `vibe check` runs the same
eligibility judgement codegen does (ADR-0076's effect-lowering prelude) right
after typing, so `vibe check` / `vibe build` / `vibe test` / doctest all report
it identically (`vibe check --single-file` is single-file analysis and does
not):

```
line 6:20-24: handle of effect 'Ask' cannot be compiled here: this handle cannot
see what one call in its body performs (here: the call to 'bump'). Make that
call visible -- declare 'bump' as a top-level `fn`, give the binding or
parameter it arrives through an effect row (`with Ask`), or move its `let`
inside the handled body. Moving the `handle` into the function that performs
works too. ...
```

The diagnostic **names the offending call and points at its `line:col`**
(#1514) — the culprit call's position, not the `handle`'s. When the culprit
lives in a dependency module it falls back to no position (better than pointing
at a wrong line in the entry file).

The rule is about **one call at a time**: this pass has to be able to see what
each call in the handled body performs. Where the `handle` sits (top-level
`let` or inside a `fn`) is irrelevant, and so is whether the performing
function was declared with `fn` or as a `let` lambda. Measured on stage2,
2026-08-20; `lib/@vibe/compiler/tests/handle_eligibility_diagnostic_test.vibe`
pins every row except the builtin one, which
`handle_body_row_callee_test.vibe` already owns:

| the handled body calls | result |
|---|---|
| `ask_once()` — a function that performs directly | ok |
| a top-level `fn` | ok |
| a closure through a **parameter carrying the row** (`f: () -> Int with Ask`) | ok |
| a **local binding carrying the row** (`let f: (Int) -> Int with Ask = ...`) | ok |
| a **rowless local closure declared inside the handled body** | ok |
| a local binding that **aliases** a performing top-level `fn` | ok |
| a first-order builtin (`println`, `Fs::read_file`, …) — #2109 | ok |
| a **rowless local closure declared outside the handled body** | **NG** |
| a call through an **expression** (an immediately-applied lambda, `(ops.0)(x)`) | **NG** |

Two more rejections exist that are *not* about the handled body at all: a
function the body calls that reaches its `perform` through a rowless parameter,
and a self-discharging callee that re-performs the effect from a handler arm
(#1591). Both get their own wording.

**When in doubt, hoist what the handled body calls to a top-level `fn`, or give
its binding the effect row.**

(This section previously quoted the message's own enumeration as the rule —
"perform directly, call a named top-level `fn`, or call a closure literal that
carries an effect row annotation … a call through a local binding or a closure
parameter … is what this rejects". #2137 measured that: four of the shapes it
named as rejected compile, and the two that fail fail for reasons it did not
mention. The message was rewritten; this table replaced the enumeration.)

### 補間できるのは Show を持つ型だけ (#1445)

宣言済みの struct / enum を `\{x}` に入れるには **`derive(Show)` か手書きの
`fn T::to_string(v) -> String`** が要る。無いとコンパイルエラー:

```
cannot interpolate a value of type `F`: it has no Show renderer
-- add `derive(Show)` to `F`, or define `fn F::to_string(v) -> String` (#1445)
```

以前は黙って**ポインタの10進数**を出していた (`"\{f}"` → `288`)。型は分かって
いるのだから、それは missing `derive(Show)` であって「描画できない値」では
ないため、エラーにした。

スカラ (`Int`/`String`/...)、`Option`/tuple/`Array`、型が解決できない
値 (generic の `T` など) は対象外 — このパスが「レンダラが無い」と断言できる
のは宣言済みの集約型のときだけなので、それ以外は従来どおり。

### capability builtin の呼び出しも arity と引数型が検査される (#1513 で解決)

かつて `Stdout::*` / `Env::*` / `Stdin::*` / `Fs::read_file` は未検査で、
`Stdout::write_stream(42)` が compile も実行も成功して garbage を出した。
今は両方とも check 時にスパン付きで落ちる:

```vibe skip
// doctest-skip: intentionally rejected — the diagnostics are the point
Stdout::write_stream(42)      // argument type mismatch for Stdout::write_stream
Stdout::write_stream()        // function arity mismatch: expected 1 args, got 0
```

`Array::*` / `String::*` / `Bytes::*` / ユーザー定義関数と同じ扱いに
揃っている。

### 区切り文字は文脈で違う

```vibe skip
// doctest-skip: shows both separators side by side, including the rejected one
enum Shape { Circle(Int); Rect(Int, Int) }        // 宣言メンバは ;
let r = match s { Circle(r) => r, _ => 0 }        // match arm は ,
```

`,` を宣言メンバの区切りに使うのは parse error。逆に match arm を `;` で
区切ると `unexpected in pattern: ;`。この cheatsheet 自身がこの2行を並べて
説明している場所で間違えていた (#1506 で修正)。

### top-level に裸の式は置けない (ADR-0069)

```vibe skip
// doctest-skip: the first form is the ADR-0069 rejection this section documents
let c = add(1, 2)
c                                  // NG: top-level expressions are not allowed
let main = () -> Int { c }         // ok
```

### test / bench

```vibe skip
// doctest-skip: every NG line here is a form the parser rejects on purpose
test "name" { .. }             // ok  — 名前は文字列リテラル必須
test name { .. }               // NG: expected test name string
test "n" with { Fs } { .. }    // NG: braced row は #1429 で削除 — `with Fs` と書く
```

**名前付き `test` / `bench` は名前の後に effect row を書ける** (#1508)。宣言した
row は ambient row (`{ Fs, Env, Console, Stdin, Stdout, Stderr, Process,
Profiler, Error, Exception }`; `Console` が tty の現行名、旧三つは legacy) を**置換ではなく拡張**する — `with Http` を
書いても `assert` に必要な `Exception` などの既定は残る。無名 `test { .. }` /
`bench { .. }` には row を書けない (row を対応付ける名前が無い)。

```vibe
// row は effect 名でも operation 粒度でも書ける
test "declared row widens the ambient one" with Exception {
  assert_eq(1 + 1, 2)
}

bench "http_get" with Http {
  let h = Http::request("GET", "http://127.0.0.1:18281/hello", "", "")
  let _ = Http::response_body(h)
  Http::close(h)
}

test "op-granular row" with Http::request + Http::close {
  let h = Http::request("GET", "http://127.0.0.1:18281/hello", "", "")
  Http::close(h)
  assert(true)
}
```

これで **`Http` を実際に呼ぶ test / bench が書ける** — network は ambient row に
入っておらず明示宣言が必須、という設計はそのまま。クライアント系 builtin
(`Http::request` / `response_status` / `response_header` / `response_body` /
`close`) は bare file の直接綴りでも host import に落ちる (#1508 第2障壁の解消。
実行例: `bench/http_bench.vibe`、要 `python3 tests/http_echo_server.py 18281`)。
server 系 (`Http::listen` / `accept` / `respond`) は今も handler が必要。
`handle { .. } with Http { _ => () }` で row を放電する古い回避策は、実 HTTP の
test/bench にはもう不要。

### 引数

```vibe skip
// doctest-skip: call fragments, including the rejected positional/labeled mix
f(x = 1, y = 2)     // ok  — 全部 labeled
f(1, 2)             // ok  — 全部 positional
f(1, y = 2)         // NG: mixes positional and labeled arguments
```

`x?` (optional) は **top-level function への直接呼び出しでは semantics まで
着地済み** (#1500): body 内では `Option[T]` に束縛され、省略した呼び出し
(`f()`) は `None`、渡すと (`f(7)` / `f(x = 7)`) `Some(7)` になる。call-site の
補完は top-level 宣言を直接 identifier で呼ぶ形だけを追跡する。local optional
lambda (`let f = (x?: Int) -> ...`) や alias 経由の呼び出しには適用されず、通常の
arity/type check に進む。

### `Error` は effect の綴りとしては退役、operation 修飾子としては生存

上の "Error boundary" 節を参照。row 位置 (`with Error`) と handle する effect 名
(`handle .. with Error`) はどちらも parse error、`perform Error::Throw(x)` は
今も通る。

## File Conventions

| File | Purpose |
|------|---------|
| `*.vibe` | Source |
| `*.vibex` | Executable root; exactly one `fn main`, not importable, no `export` surface (#2229 enforces; ADR-0075 target contract) |
| `index.vpkg` | Package boundary, bodyless public contract, dependency/shared-import declarations |
| `index.vibe` / `index.vibei` | Legacy index spellings; not package boundaries |
| `*_test.vibe` | Explicitly-run test companion; excluded from normal build/hash and cannot be imported |
| `*_bench.vibe` | Explicitly-run benchmark companion; same exclusion rules as tests |
| `_*.vibe` / `*.draft.vibe` | Explicit-only source; excluded from discovery, but inherits nearest package shared imports and is hashed when reached by relative import |

> 境界・可視性・pin/update の正本は
> [docs/module-system-oracle.md の「現行モデル」節](module-system-oracle.md#現行モデル-canonical--ここが唯一の現行記述) (#1269)。
> 以下はその要約。

`index.vpkg` と同じ directory の通常 `*.vibe` だけが暗黙 build root。
subdirectory source は direct root からの relative import/export で到達させる。
最寄りの `index.vpkg` がない source は公開 compatibility space として import
できる。owner を持つ package の内部 source は同一 owner またはその
`index.vpkg` facade 経由でのみ参照できる。

### `index.vpkg` ヘッダー (#1128)

契約本体 (bodyless `fn`/`type`) の前に置く、`name`/`version`/`description`/
`deps`/`main`/`generated_hash` のディレクティブ行:

```vpkg
name = @scope/pkg
version = x.y.z
main = true          // 任意。パースのみ、意味づけは未実装 (予約)
description =
  #|一行目
  #|二行目
deps = {
  @scope/dep : x.y.z
}

generated_hash =      // 任意。publish 時に自動挿入 (#pkg:sha1:<40hex>)
```

`name`/`version`/`description` は規約上必須だが、コンパイラはハード
enforce しない (fixtures/contract_* の最小契約テストを壊さないため)。
`description` の `#|` 継続行は言語本体の `#|` 複数行文字列と同じ
インデント一致ルールに従う。`deps` は依存先の版数制約を宣言する場所
であり、`import @scope/pkg { ... }` は名前解決専用のまま (版数を持たない)。
旧 `version x.y.z` (`=` なし) は互換のため引き続き受理される。
`lib/@vibe/compiler/**` とその直接依存 (`@vibe/ast`/`cache`/`core`/
`graph`/`json`/`module`/`parser`/`prelude`、計 36 ファイル) はコンパイラ
自身の bootstrap seed が新形式を理解しないため当初は旧 spelling のまま
据え置かれていたが、bootstrap-bump (#1145 follow-up 1) 後に新形式へ移行
済み — `fixtures/contract_*` (conformance engine の最小契約テスト、`version`
行自体を持たない) のような、意図的に旧/最小形式のままの契約だけがこの
互換パスを使い続ける。

`deps` 宣言と実際の `import` 文の突き合わせは `vibe check --deps-missing
<root>` (#1145 follow-up 2) で検証できる。`compiler_gate.sh` gate 60 が
リポジトリ全体に対してこれを実行するので、`name = ` を持つ (#1128 移行済み)
パッケージで宣言漏れがあれば CI で検出される。`generated_hash` は
`vibe hash --write <pkg_dir|index.vpkg>` (#1145 follow-up 3) で計算・書き
戻しできる — 自己参照 (書き込んだ値が次の計算の入力に混ざる) を避けるため、
ハッシュ計算は常にその index.vpkg 自身の `generated_hash` 行を空白化した
上で行われ、再実行しても同じ値になる (idempotent)。

ヘッダの綴りは **フォーマッタが正規化し、CI が enforce する** (#1435)。
`bash scripts/vibe_fmt.sh <index.vpkg>` / `pkf run fmt` がキーの順序
(`name` → `version` → `main` → `description` → `deps` → `require` → 空行 →
`generated_hash`)、`= ` の後の空白、`#|` と dep 行の 2 スペース字下げ、
`@scope/dep : x.y.z` の空白、deps の名前順ソートを揃える。ヘッダは vibe
構文ではないので `.vibe` 用の CST formatter は通さず、専用の writer が
書き出す (境界判定は `scan_package_header` の行分類をそのまま写したもの)。
ヘッダが loader にとって不正な形の場合、フォーマッタはファイルに一切
触らない — 詳細は [docs/cli-commands.md](cli-commands.md) の `fmt` 節。

---

*Full reference: [docs/spec/syntax.md](spec/syntax.md) — canonical surface syntax*
