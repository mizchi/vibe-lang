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
fn main allows Console {
  println("hello world")
}
```

`print` is the same without the trailing newline. `@vibe/console` publishes the
rest of the tty surface (`eprint` / `eprintln` on `Stderr`, `read_line`,
`read_all`). `@vibe/builtin`'s older `stdout_write` / `stdout_writeln` are
gone (#2102) -- they duplicated names above.

The row you write is `Console`, and a missing `println` row is reported
as `Console`. Codegen still emits the stdout host imports. Declaring
`Console` authorizes the legacy `Stdin` / `Stdout` / `Stderr` labels
(#2102/#2117) -- one way only, so a row declaring just `Stdout` cannot reach
`Console::read_stream`. The book, README and installer teach this same
program; `scripts/test_vibe_install_hello.sh` checks they still agree.

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
[AGENTS.md の Code Navigation 節](../../../AGENTS.md#code-navigation-important)。

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
| Cross-call / handler-mediated state | declare your own effect, then `handle ... with <YourEffect>` | ADR-0050/0021; there is no builtin `Mut` effect. A `perform` **directly inside the handler body** is inline-eliminated; a call through an intervening function still goes through evidence-dict dispatch, measured at ~2× a captured `let mut` ([side-effect-consolidation.md §2.5](../../internal/design/side-effect-consolidation.md)) |

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

### Reserving Array storage

`Array::with_capacity(n)` creates an empty mutable `Array[T]` with room for at
least `n` elements. It works on linear bump, RC, and GC. The current minimum is
two slots; reservation does not initialize elements or change the length.
The first `n` pushes require no buffer growth. Further pushes grow normally,
and aliases observe every push and truncation.

```vibe
fn reserved_values() -> Array[Int] {
  let xs = Array::with_capacity(128)
  Array::push(xs, 42)
  xs
}
```

The capacity expression is evaluated once and must be an `Int`. Negative
values and values above 536,870,908 trap before narrowing to wasm32; an
allocation must also fit available linear memory. Growth that would overflow
the buffer size or heap address traps before changing the array. New linear
allocations also leave room for the memory-growth guard page; RC can still
reuse an existing free block when the frontier cannot grow. Each array has
one element type, inferred from its uses or an annotation, just like `[]`.

If a trait implementation requires another trait on the elements
(`impl [E: Element] Measured for Array[E]`), annotate the reservation explicitly,
for example `let xs: Array[Int] = Array::with_capacity(128)`. Trait lowering
does not recover the element type from later pushes. When it cannot construct
the required element witness, the compiler rejects the call with an annotation
diagnostic. A first-class alias such as `let reserve = Array::with_capacity`
also needs an annotated result (`let xs: Array[Int] = reserve(128)`) before a
trait call, even for an unbounded `impl [E] Trait for Array[E]`: the alias's
result head is not recovered by trait lowering. Unresolved receiver types
produce an annotation diagnostic before code generation.

`Array::truncate(xs, n)` retains the allocated capacity for subsequent pushes.
It currently does not release the removed elements' RC references: saved
element views can still refer to them. Capacity reservation preserves that
existing lifetime behavior; repeated truncation of owned elements is not yet
a bounded-memory scratch-buffer contract.

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
[concurrency.md](../../internal/design/concurrency.md#send-と-capture-safety), pinned by
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
compiler source は `freeze` のままでなければならない (docs/internal/operations/bootstrap.md)。

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
fn hello() -> Unit with Console { println("hi") }
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
import @vibe/builtin {
  trait Iterator
}

Iterator::map(xs, x -> x * 2)
Iterator::map(xs, _ * 2)         // placeholder
Iterator::fold(xs, 0, _ + _)
```

## Operators (precedence: high to low)

| Prec | Operators | Notes |
|------|-----------|-------|
| 1 | `.` `()` `[]` | field, call, index |
| 2 | `-x` `!x` `~x` | unary (`~` is bit-not, #2344) |
| 3 | `*` `/` `%` | |
| 4 | `+` `-` | |
| 5 | `<<` `>>` | >> is arithmetic (sign-extending) |
| 6-8 | `&` `^` `\|` | bitwise AND, XOR, OR |
| 9 | `==` `!=` `<` `<=` `>` `>=` `is` | non-assoc; `is` is the pattern-test operator (see below) |
| 10 | `\|>` | pipe |
| 11-12 | `&&` `\|\|` | short-circuit (desugar to if) |

Assignment: `=` `+=` `-=` `*=` `/=` `%=` (statement, not expr)

A line that starts with a binary operator continues the line above it. A
line-leading `-`, `!` or `~` is a **prefix** operator when no whitespace
follows it (ADR-0115 / #3041), so a line `-1` starts a new expression while a
line `- 1` (space after) continues the previous one as a subtraction, and so
does a `-` that ends the previous line:

```vibe
fn tail_value() -> Int {
  let a = 10
  let wrapped = a
    - 1              // binary: 9
  let _ = wrapped
  -1                 // prefix: the block's value is -1
}
```

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
variable (`[T: Eq]`) is answered by the `Eq` witness, not by a second
erasure — see "the bound is required, and a real `Eq` dispatches" below.

#### The bound is required, and a real `Eq` dispatches

**Required** (#2474). A generic body is lowered once for every
instantiation, so `==` / `!=` on an operand whose type mentions a type
parameter with no `Eq` bound — bare `T`, `Option[T]`, `(T, Int)`,
`Array[T]` — has no comparator to reach and used to answer by reference
identity for an aggregate (`same_some(Pt::{ v: 1 }, Pt::{ v: 1 })` was
`false` while `same_some(1, 1)` was `true`). The checker now rejects the
site and names the edit. A bound counts when it is `Eq` or has `Eq` among
its supertraits (`Ord: Eq` does; a user `trait Key: Eq` does):

```vibe skip
// rejected: `==` compares two values of type `Option[T]`, but the type
// parameter `T` has no `Eq` bound, so they cannot be compared by content
// here; declare the bound (`[T: Eq]`) or compare at a concrete type
fn same_some[T](x: T, y: T) -> Bool {
  Some(x) == Some(y)
}
```

```vibe
fn same_some[T: Eq](x: T, y: T) -> Bool {
  Some(x) == Some(y)
}
```

**The builtin `Eq` dispatches** (#2523). `builtin_traits.vibe` still spells
`export trait Eq` with no methods, but the checker registers that trait as
method-bearing and the lowering injects `equals(Self, Self) -> Bool` when a
program carries the bound. `derive (Eq)` registers the impl. `[T: Eq]` at a
`derive (Eq)` struct compares by content, and so does `Double` — the scalar
whose erased comparison used to read the box. Pinned by
`fixtures/eq_bound_derive_test.vibe`, including `Box[Double]` /
`Box[Array[Int]]` through the bound.

A program may still declare its **own** marker `trait Eq` with no methods.
That bound is refused, and `Ord` is still a marker. Those refusals stay in
`lib/@vibe/compiler/tests/marker_cmp_bound_test.vibe`. Writing both
`derive (Eq)` and `impl Eq for T` for the same type is an overlap: the derive
already supplied the impl.

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

A pushed **name** or **call result** does not resolve syntactically, and that is
deliberate: reading the value's type out of an environment means deciding
scope, shadowing, annotations and type formals in a pass that has no types,
which produced a silently wrong answer (an outer `let v = 1` read for an inner
`v` of another type, so `==` said `false` for two equal `[1, 2]` arrays). With
no environment the element type can be absent but never wrong. What the scan
leaves absent, the checker supplies on the lane `vibe test` / `vibe run` use
(#2391, after #2447): it types the binding, records the `==` site's operand
type, and the comparison dispatches by content where the allow-list below
admits the element — so a pushed name, and pushes made inside a function the
array is merely passed to, answer.

A **generic** struct literal preserves its concrete type arguments in the
equality shape (#2195): the compiler emits a comparator per concrete
instantiation and substitutes the arguments into its field types, so
`Box[Int]`, `Box[Double]`, `Box[Bytes]`, `Box[Array[Int]]` — and declared
fields containing them — all compare structurally (measured 2026-08-24, two
distinct allocations of equal content answer `true`). A self-describing
literal with an omitted argument, such as `Box::{ value: [1, 2] }`, recovers a
single directly-used type parameter from the field value; anything more
ambiguous remains unresolved and traps.

A **generic enum** is specialized the same way (#2467): `enum Wrap[T] { W(T);
Empty }` at `Wrap[Int]` gets `Wrap::equals__<key>` with `Int` substituted into
every payload, so the payload compares exactly (through the derived comparator
it went through the erased `==`, where `W(64 << 32) == W(65 << 32)` answered
`true`), and `Wrap[String]` / `Wrap[Array[Int]]` compare by content where they
used to trap — directly and through the untyped-empty arm alike. A program's
own `Wrap::equals` still wins for exactly the instantiation its parameters
name. What still fails closed: an instantiation whose argument is a formal of
an enclosing binder (unless no payload reads it), and a non-regular recursion
(`Nest[T]` holding `Nest[Array[T]]`), whose specializations never close.

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
instantiations, and since #2467 a generic enum's. `Map` was the one measured outlier until #2218 gave it a
comparator; any head nobody has measured still costs its owner a trap rather
than the benefit of the doubt.

**What does not resolve is a build error** once BOTH sides are non-empty.
`vibe build` / `vibe run` / `vibe test` name the edit. They do not fall back
to reference equality or to a length-only answer, and they do not leave a
trap for run time. `vibe check` does not run this pass. On the lane those
three commands use, a pushed name whose element is on the allow-list above
already answers by content (#2391). The build error is an element the
allow-list rejects (a closure field, an opaque nominal field). A lane
without the checker's rows (the flat single-source lane) still fails for
the syntactic residual. Annotate those bindings
(`let xs: Array[Int] = []`). While either side is still empty the lengths
decide the answer, annotation or not.

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

**The `_` rule (frozen, ADR-0117 / #3044).** `_` has two roles, and which
one it plays is decided by syntax alone:

1. **A bare `_` that IS a whole argument** of the call directly on the right
   of `|>` is the **pipe slot**: the piped value goes there, and nothing is
   prepended. Every such `_` receives it (`7 |> pair(_, _)` is `pair(7, 7)`).
2. **A `_` that is an operand of an operator** is a **lambda section**: the
   operator expression it sits in, up to the nearest enclosing call argument,
   becomes a lambda with one parameter per `_`, in order. `_ * 2` is
   `(v) -> v * 2`, `_ * 10 + 1` is `(v) -> v * 10 + 1`, `_ + _` is
   `(a, b) -> a + b`, and `inc(_ * 10)` passes the lambda `(v) -> v * 10` to
   `inc` (it is not `(v) -> inc(v * 10)`).
3. Without a bare `_` argument, the piped value becomes the **first** argument.
4. A bare `_` anywhere else -- outside a pipe (`inc(_)`), or as an argument of
   a call nested inside the piped call -- is refused: `` `_` is not a value
   here``.

So `xs |> Iterator::map(_, _ * 2)` reads as `Iterator::map(xs, (v) -> v * 2)`
after importing `trait Iterator`: the first `_` is rule 1, the second rule 2.
There is no separate pipe-placeholder token; `_` keeps both roles, and this
rule is the whole of the disambiguation.

Every method-bearing trait exposes its operations through the trait namespace:
`Trait::operation(value, args)` or `value |> Trait::operation(args)`. The
operation is derived from the trait declaration; no forwarding function is
needed. Importing `trait Trait` also activates its exported `Trait::*`
operations, but never introduces a bare `operation` binding. A subtrait exposes
inherited methods through its own namespace as well. These generated operation
names are reserved: a source declaration cannot replace `Trait::operation`.

The finite indexed `Iterator` protocol is one instance of this general rule.
Implementing `iter_length` and `iter_get` activates its eager operations
(ADR-0110):

```vibe
import @vibe/builtin {
  trait Iterator
}

let arrays = [1, 2]
  |> Iterator::map((x) -> { x + 1 })
  |> Iterator::map((x) -> { x * 2 })
```

`Iterator::map` and `filter` return arrays; `fold`, `find`, `any`, and `all`
are eager terminals. Array calls devirtualize to the existing `Array::*`
intrinsics, so the trait spelling adds no loop or allocation overhead. Option
does not implement `Iterator`. `AsyncIter` is the separate pull layer
(ADR-0099), entered explicitly with `Array::iter`:

```vibe
import @vibe/builtin {
  Array::iter,
  AsyncIter::collect,
  AsyncIter::filter,
  AsyncIter::map
}

fn evens_times_ten() -> Array[Int] with Async {
  [1, 2, 3, 4]
    |> Array::iter
    |> AsyncIter::filter((x: Int) -> Bool { x % 2 == 0 })
    |> AsyncIter::map((x) -> { x * 10 })
    |> AsyncIter::collect
}
```

`AsyncIter::map`, `filter`, `take`, and `take_while` are lazy. `collect`,
`fold`, `count`, `find`, `any`, and `all` are terminals and carry `Async`.
A plain `for x in array` remains an eager Array loop; importing
`Array::iter` does not change it implicitly.

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
[`eval/call-style/findings/2026-07-28-r1.md`](../../../eval/call-style/findings/2026-07-28-r1.md)
found a reader given only a text excerpt (no compiler, no LSP) can recover
the callee's type from the qualified spelling but not from bare
`recv.method(...)` when annotations are sparse — so the qualified spelling
is what should land in git history/diffs/greps, while the terser dot
spelling stays legal to type. This does **not** help positional-argument-order
ambiguity between same-typed parameters — that's a separate problem no call
notation solves (`eval/call-style/scenarios/02_arg_order`). Implementation:
`normalize_dot_calls` in
[`lib/@vibe/compiler/normalize/normalize.vibe`](../../../lib/@vibe/compiler/normalize/normalize.vibe);
tests in `lib/@vibe/compiler/tests/normalize_dot_calls_test.vibe`.

### Function combinators (point-free)

`compose` / `identity` / `flip` live in the prelude (`lib/@vibe/builtin/func.vibe`);
import them before use (`import ./func.vibe { compose, identity, flip }`).

<!-- doctest-skip: 未定義名 (f / g / xs / parse / render) を参照する構文提示の断片 -->
```vibe skip
import @vibe/builtin {
  compose, flip, identity, trait Iterator
}

// vibe has no `>>` compose operator (`>>` is arithmetic shift) — use functions
compose(f, g)            // (x) -> g(f(x))   apply f then g
identity                 // (x) -> x         no-op stage / default
flip(f)                  // (b, a) -> f(a, b)
Iterator::map(xs, compose(parse, render))
```

> Runnable reference for the pipe `_` slot, combinators, `let*`, and `tap`:
> [`lib/@vibe/builtin/pipeline_ergonomics_test.vibe`](../../../lib/@vibe/builtin/pipeline_ergonomics_test.vibe)
> (`vibe test lib/@vibe/builtin/pipeline_ergonomics_test.vibe`). The
> combinators are `@vibe/builtin` exports and `tap` / `tap_some` moved to
> `@vibe/console` (#2102 — they carry `Console`), so a file must `import` them
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

// for-in (collects into array; a discarded value allocates nothing)
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

**A `for` over a builtin collection collects, and a discarded one allocates
no array** (ADR-0116, #3043). The collecting rule is the specification, not
an accident: `let ys = for x in xs { f(x) }` is how an eager map is written.
When the loop's value is discarded -- a block statement followed by more
statements, the last statement of a `while` body, or a branch of an `if` /
`match` in such a position -- no result array is built, so a `for` run for
its side effects costs what a `while` costs. `let _ = for ...` binds the
value and does build it, and a `for` as the tail of a `-> Unit` function is a
type error (`expected (), got Array[()]`), so end that body with `()`. Measured
on the default linear backend (bump and RC; `fixtures/for_discard_no_alloc_test.vibe`,
mid gate 40e3); the opt-in wasm-gc backend still builds the array.

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
// ONE exception, and it is an absence rather than a rule: `Option` has no
// qualified spelling. `Option::Some(5)` reports `unknown name: Option::Some`;
// write `Some(5)`. Everything else measured (#2830, ADR-0096) takes both --
// a local enum, a type alias, an imported enum plain or aliased, and the
// WIT-local `@vibe/wit_runtime` `Result`.

struct Point { x: Int; y: Int } derive(Eq, Ord, Show)
let p = Point::{ x: 1, y: 2 }
let px = p.x                              // field access

struct Box[T] { v: T }                    // generic struct (#829)
let b1 = Box::{ v: 1 }                    // type args inferred from fields -> Box[Int]
let b2 = Box[Int]::{ v: 2 }               // explicit type args PIN the instantiation (#886)
// arity-checked: Box[Int, Int]::{ .. } は checker error; pinning resolves
// inference-ambiguous fields (e.g. struct Bag[T] { xs: Array[T] } の
// Bag[Int]::{ xs: [] })
// struct derive(Ord) -> Point::compare(a, b) : Ordering   (lexicographic)
// enum derive(Ord) -> E::compare(a, b) : Ordering   (variant order, then payload)
// `Ordering` is a prelude enum { Less; Equal; Greater } (#3042, ADR-0118):
// no import, and a `match` on it must cover all three. `@vibe/builtin` adds
// `Ordering::to_int` (-1 / 0 / 1) and `Ordering::reverse`.
let ord = Point::compare(p, Point::{ x: 1, y: 3 })     // Less
let ord_text = match ord {
  Less => "before",
  Equal => "same",
  Greater => "after"
}
// struct derive(Show) -> Point::to_string(p) : String ("Point { x: 1, y: 2 }")
// enum derive(Show) -> E::to_string(v) : String ("B(3)" / "A")
// derive(Hash) -> T::hash_key(v) (構造キー、to_string も併せて生成)
// derive(Default) -> T::default() + `impl Default for T` 登録 (#1847) —
//   derive した型はそのまま `[T: Default]` bound を満たす
// (Eq は marker: 構造的 `==` は T::equals として常に生成される)
// #1392: `"\{v}"` は解決できた型の `T::to_string` を呼ぶ。prelude の
// `to_string(v)` も同じ (body が `__to_string(x)` そのものの 1 引数 pass-through
// は call site で inline され、補間と同じ書き換えを受ける) — ただし
// A generic body needs a method-bearing renderer witness or an explicit
// `(T) -> String` callback. The builtin marker Show supplies no witness (#2840).

trait Eq
trait Ord: Eq                              // supertrait
export open trait Show                     // extensible outside module

impl Eq for Int
impl [T: Eq] Eq for Array[T]              // 宣言はできるが bound には使えない (下記)

// `Send` (ADR-0068) is a COMPILER-JUDGED structural marker, not a user
// trait; `impl Send for X` is an error. The allowlist is stated once, in
// docs/internal/design/concurrency.md "Send と capture safety".

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

Generic interpolation requires a renderer when the operand still has a type
parameter, including inside a container or tuple. For example, write `render(value)` using a `(T) -> String` callback
inside `fn format[T]`; adding the builtin marker `Show` alone does not provide
a callable renderer. A top-level bound on a trait declaring
`to_string(Self) -> String` can dispatch through its witness. Direct top-level
rendering shims still expand at their call sites; pass a concrete lambda when a renderer
is needed as a function value.

`StringSet` key helpers take that callback explicitly:
`StringSet::add_by(set, key, value)`, `remove_by(set, key, value)`,
`contains_by(set, key, value)`, and the bare `from_array_by(values, key)`.
Use the same key function for insertion, lookup, and removal. The imported
`@vibe/core` snapshot helper is `inspect(value, expected, render)`;
the usual unimported `inspect(value, expected)` syntax remains unchanged.


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

### Higher-kinded type parameters (`F[A]` and `F[_]`)

**A type formal may stand in constructor position — `F[A]`.** Unification
binds `F` to a type constructor (`F := Array` yields `Array[A]`). This is
independent of the element-indexed `Iterator[T]` protocol: constructor-indexed
traits remain available for APIs whose result must preserve an arbitrary
`F[_]`. A formal used both unapplied (`x: F`) and applied (`y: F[A]`) is
rejected as mixed-kind. Ascribing `F[A]` to a concrete constructor
(`let ys: Array[Int] = xs`) is rejected.

A constructor parameter may also declare its arity with underscore slots
(`F[_]`, `F[_, _]`). Applied constructor variables participate in ordinary
unification, so their element arguments remain distinct and the shared
constructor head must match:

```vibe
fn pair[F[_], A, B](left: F[A], right: F[B]) -> (F[A], F[B]) {
  (left, right)
}

let arrays = pair([1], ["vibe"])
let options = pair(Some(1), Some("vibe"))

type Apply[F[_], A] = F[A]
let optional: Apply[Option, Int] = Some(42)
```

Kinded binders and applied types are preserved across package interfaces.
Passing a complete type where a constructor is required is rejected with the
expected and actual arities. Unkinded `F[A]` remains legal.

Constructor parameters may carry applied trait bounds. `LocalFunctor[F]`
selects a witness for the constructor itself, while `F[A]` and `F[B]` remain
ordinary applied value types:

```vibe
import @vibe/builtin {
  trait Iterator
}

trait LocalFunctor[F[_]] {
  map[A, B](F[A], (A) -> B) -> F[B]
}

impl LocalFunctor[Array] for Array {
  map(xs: Array[A], f: (A) -> B) -> Array[B] {
    Array::map(xs, f)
  }
}

let mapped = LocalFunctor::map([1, 2], (x) -> { x + 1 })
```

Missing or duplicate constructor instances are checker errors; an unresolved
trait witness never reaches code generation. The implementation-side
`F::map` spelling is internal dictionary dispatch; public calls use
`LocalFunctor::map`.

<!-- doctest-skip: mixed-kind is deliberately rejected -->
```vibe skip
fn bad[F](x: F, y: F[Int]) -> Int {  // rejected: mixed kind
  1
}
```

The same `F[A]` shape is legal in a parameterized alias body, a generic
effect operation, and a trait method signature. Mixed-kind (`F` and `F[A]`
together) is still rejected on every declaration surface.

Concrete applied impl targets are preserved and matched exactly (#2335):
`impl M for Array[Int]` does not satisfy `M` for `Array[String]`. Distinct
concrete targets may coexist and dispatch to their own method bodies. Generic
targets retain their complete argument pattern as well, so a declaration such
as `impl [A, B] M for Pair[B, A]` maps each bound to the corresponding target
slot. Duplicate or overlapping targets are rejected and the diagnostic names
both targets.

## Collections

```vibe
import @vibe/builtin {
  trait Iterator
}

// Array
let a = [1, 2, 3]
let first = a[0]              // index
let len = Array::length(a)
let doubled = Iterator::map(a, _ * 2)

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

// Map (#960: the `map { ... }` literal was removed; use the Map:: API).
// The builtin map is STRING-KEYED; its type is spelled `StringMap[V]`
// (no import needed). `Map[K, V]` with a concrete non-String key is
// rejected where it is written -- generic keys are #2263. For another
// key type today, use `MutMap[K, V]` from `@vibe/core` (below).
let m = Map::from_pairs([("key", 42)])
let e = Map::new()                    // empty map
let mv = m["key"]
// `Map::set` is FUNCTIONAL: it returns a new map and leaves the receiver
// alone. Measured on the RC lane -- `Map::set(m, "b", 2)` as a statement is a
// silent no-op (`Map::size(m)` stays 1, `Map::has_key(m, "b")` is false), and
// nothing warns about the discarded result. Bind it.
let m2 = Map::set(m, "b", 2)
let sized: (StringMap[Int]) -> Int = (mm) -> { Map::size(mm) }

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
>   `keys` and the `m["k"]` index sugar all lower correctly -- but `set` is
>   FUNCTIONAL (`let m2 = Map::set(m, k, v)`), so writing it as a statement
>   updates nothing and nothing warns. **`Map::get` / `m[k]` on a missing key
>   traps** (#2990) -- it used to answer the zero bit pattern typed as the value
>   type (`0`, `""`, an Array at address 0), indistinguishable from data. Guard
>   with `Map::has_key`, or use `@vibe/core`'s `get` for an `Option`. The old
>   `map { ... }` literal was removed in #960 (it now reports a located parse
>   error naming the replacement API). (`lib/@vibe/core`'s `get`/`get_or`/
>   `has_key`/`keys`/`values` remain available for a richer Map API, #766.)

## Effects (core concept)

Semantic effects, including `Exception`, are tracked in the type system. An
**empty row excludes host capabilities and algebraic effects** -- no printing,
no files, no escaping exception. It does not guarantee termination or exclude
panic, Wasm trap, or resource exhaustion (ADR-0073), and it does **not**
exclude mutating values reachable from the arguments (#3045): `fn grow(xs:
Array[Int]) -> Unit { Array::push(xs, 9) }` has an empty row, as does a
function writing a parameter's `mut` field. **`Mut` is a reserved row label**
for a future marker of that mutation (ADR-0100 (2)): `with Mut` / `with
Mut[..]` is refused (the diagnostic starts ``remove `Mut` from the row``),
and so is declaring `effect Mut` or `effectset Mut`.
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

**`Async` is charged like any other label** (#2967): a caller of a `with Async`
function declares `Async` in its own row (`main` writes `allows Async`), and a
`test` / `bench` block has it in its ambient row. It used to be decorative: a
row-less caller was accepted. Builtins carrying `Async` stay exempt from the
row check, because the runtime discharges them.

**Every row label must name an effect** (#2968): a declared or imported
`effect`, an `effectset`, a standard provider, `Exception` / `Exception[K]`,
`Async`, or a row variable. `with Excepton` is refused as an unknown effect that
suggests `Exception`, `with Fs::no_such_op` names the missing operation, and
a handler arm for an undeclared effect is refused the same way. An exception
kind may not name a type parameter of its declaration (`with Exception[T]`,
#3002): a row is never substituted at a call site, so throw the value inside the
generic function's own `handle`, or return it as a `Result`.

The ordered default and cache-safe owners preserve their existing output.
At a program entry (`main` or `_start`), the checker admits only the union of
host-provider labels and entry/runtime-managed labels. A user effect such as
`Ask` / `Ask::Get` must be discharged by `handle ... with Ask` before that
boundary; adding it to `main`'s `allows` row is rejected with a located
diagnostic (#1683). Ordinary helper functions still fix a missing effect by adding it to
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

A `handle` that names a host operation intercepts **both** spellings, in the
handled body and in every function it calls: `Fs::read_file(p)` two calls
down reaches `Fs::ReadFile(p) => ...` exactly as `perform Fs::ReadFile(p)`
would (#1962). A host operation that no handler answers reaches the host, and
so does a direct call outside every handler. So a `handle` is a real mock, and
a handler that answers `""` to satisfy the checker makes every read inside it
return `""`. Carry the effect on the row instead. The interception applies
when every entry of the artifact is granted the operation. It stands down for
a library whose exported functions the host may call directly.

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
> `import @vibe/wit_runtime { Result }` を使う ([effect-wit-mapping.md](../../internal/design/effect-wit-mapping.md)、
> compiler-gate 89/89 が byte 単位で pin)。それ以外で自前に
> `enum Result[T, E] { Ok(T); Err(E) }` を宣言するのは自由だが、特別扱いは
> 一切なくただのユーザー enum になる。

### Railway bind (`let*`) — `Option` (#635 / #1324)

`let* x = e` unwraps the success case and binds `x`, or short-circuits the
**enclosing block** with the failure case:

- `e: Option[T]` → `match e { Some(x) => <rest of the block>, None => None }`

so the BLOCK must evaluate to an `Option`; the function around it need not.

**`let*` and `?` differ in where they exit, and that is why both exist**
(ADR-0117, #3044): `?` returns `None` from the enclosing **function**, `let*`
makes the enclosing **block** `None` and the function carries on after it. In
a function body's own top-level block the two exit to the same place, so
there `?` is the one spelling: a `let*` directly in a function body (or a
closure's body) is a **warning** naming the `let x = e?` rewrite. Use `let*`
for a nested block whose `None` should stop at the block:

<!-- doctest-skip: 直前 block の定義 (half 等) に依存する断片 (将来の `vibe continue` 候補) -->
```vibe skip
fn halves_or_zero(a: Int, b: Int) -> Int {   // not an Option: `?` is not allowed here
  let total = {
    let* x = half(a)                 // None makes this BLOCK None
    let* y = half(b)
    Some(x + y)                      // last expr is the block's Option
  }
  match total {
    Some(t) => t,
    None => 0
  }
}
```

Pinned by `fixtures/try_let_star_option_test.vibe` (block exit against `?`'s
function exit) and `lib/@vibe/compiler/tests/warning_snapshots/let_star_top_level_test.vibe`
(the warning).

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
carry `Console` in their signature, which is why they live there and not beside
`Int::abs` (#2102) — so import them, and note that observing with a print costs
the `Console` effect on the chain. (`tap_ok` / `tap_err` were removed with
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
`throw NotFound("x")` (#2265). `throw(x)` is `perform Exception::Throw(x)`
(#640). `Exception` is non-resumable: the `Throw` arm's value is the
handle's result, so `resume(...)` inside that arm is a checker error.
Parse desugars `throw(x)` to `perform Exception::Throw(x)`; the printer
re-sugars that shape back to `throw(x)`. Both spellings are the same
effect-row demand: the function must declare `with Exception`, or an
enclosing `handle .. with Exception` must discharge it. An exception
that escapes `fn main allows Exception` becomes a diagnosed abort at the
runtime boundary.

The effect spelling **`Error` is retired** (#1461, #1501). Either place
that named an effect is a parse error:

```
fn f() -> Int with Error { .. }              // row item        -> parse error
handle { .. } with Error { Throw(_) => .. }  // handled effect  -> parse error
```

`vibe fmt` rewrites both to `Exception` (token-level, so it can convert
sources the parser no longer accepts).

一方 **`perform Error::Throw(x)` は今も通る** — operation 修飾子は row 項目では
なく、runtime が dispatch する operation を名指しているだけで、そこに row を
綴っているわけではないため。

### Typed exceptions (`Exception[E]`, ADR-0085 / #1344)

The bare `Exception` is the erased exception row, with no kind. To put the
TYPE of a failure into the row, write `Exception[E]`, where `E` is the static
type of the thrown value.

```vibe
enum IoError {
  NotFound(String)
}

enum ParseError {
  Eof
}

// the row says this function can throw only an IoError
let read_cfg: () -> Int with Exception[IoError] = () -> {
  throw(NotFound("cfg"))
}

// several families are an effectset union, not a subclass hierarchy
effectset ConfigExceptions = {
  Exception[IoError],
  Exception[ParseError]
}

// a handler discharges exactly its kind
let n = handle { read_cfg() } with { Exception[IoError]::Throw(_e) => 0 }
```

Rules:

- `Exception[IoError]` neither authorizes nor discharges `Exception[ParseError]`.
  Throwing a kind that is not in the row is `missing { Exception[IoError] }`.
- **The bare `Exception` is the erased spelling, compatible with every kind.**
  `with Exception` keeps allowing any throw, and an erased
  `handle .. with Exception` also catches kinded throws.
- A throw whose payload kind cannot be resolved (for example `throw(r.cause)`)
  is treated as erased and passes under a function ROW of any `Exception[K]`
  (gradual): it can miss a violation, never invent one.
- The runtime does not distinguish kinds: every spelling is one abortive Wasm
  tag. The exact-kind guarantee is a property of the checker -- which is why a
  **kinded handler arm is strict** (#2985): `handle { .. } with {
  Exception[K]::Throw(e) => .. }` catches EVERY exception its body raises, so
  the body may raise only `Exception[K]`. An erased or unresolved throw, an
  erased callee (`with Exception`), and a throw of another kind that the
  enclosing row would have let propagate are all refused there; the erased
  `Exception::Throw(m)` arm still catches everything, with an untyped payload.
  A closure literal passed straight to a callee is checked against the row
  the callee's PARAMETER declares: a row admitting the erased `Exception`
  (`TaskGroup::spawn`'s `() -> T with Exception + e`) takes any kind, and what
  comes back out is the callee's own declared row, charged strictly like any
  other call; a row naming a kind (`f: () -> Int with Exception[K]`) lets the
  literal throw exactly `K`; a row with no exception label
  (`invoke[e](f: () -> Int with e) -> Int with e`) absorbs nothing, so the
  literal is as strict as the body -- and so is one handed to a callback
  parameter or a builtin, or created and called in the body. An erased
  `handle .. with Exception` nested inside is its own
  catch-all boundary. And a handle may have only ONE exception arm: the
  channel carries no kind and only the first exception arm is compiled, so
  `Exception[A]::Throw` next to `Exception[B]::Throw` is refused -- match on
  the payload inside one erased arm, or nest handles.
- A kinded arm binds its payload at the kind's type (#2963):
  `Exception[IoError]::Throw(e)` gives `e : IoError`, so `e` can be matched or
  passed on directly, and returning it where the handle produces an `Int` is a
  type error. The erased `Exception::Throw(m)` binder is still untyped (it can
  receive any kind).

Details and the v1 limits: [exception-effect.md](../../internal/design/exception-effect.md).

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
option 2 — would let user types opt in; it is not implemented.) `?` is the
spelling at a function body's top level; `let*` is for a nested block (see
"Railway bind" above for the exit-target rule).

### suberror (typed errors)

```vibe
suberror NotFound(String)
suberror InvalidInput(Int, String)   // tuple payload only

suberror AppError {
  Io(String);
  Parse(Int)
}
```

**`suberror` is sugar for an enum that is used as an exception kind** (#2983).
`suberror NotFound(String)` declares the type `NotFound` with one constructor
`NotFound(String)`; the braced form declares the type `AppError` with the
constructors `Io` and `Parse`. The type name is the kind:
`throw(Io("disk"))` needs `with Exception[AppError]`, and
`Exception[AppError]::Throw(e)` binds `e : AppError`. An `enum` works the
same way; `suberror` only says what the type is for.

**Catching a family at once** (measured, `fixtures/exception_family_catch_test.vibe`):

- **Make the family ONE kind.** A braced `suberror` (or an `enum`) with a
  constructor per member is caught by a single kinded arm, and the `match` on
  its payload is exhaustive (example below).
- **An `effectset` of kinds is for ROWS, not handlers.** `effectset IoErrors =
  { Exception[NotFound], Exception[Denied] }` lets a function declare `with
  IoErrors`. A handle cannot catch one of those kinds and let the other
  propagate -- a kinded arm catches everything its body raises, so an arm for
  `Exception[NotFound]` over a body that can also raise `Denied` is refused --
  and a handle has only one exception arm. The arm that takes every kind at
  once is the erased `Exception::Throw(_)`, whose payload is untyped.
- `Exception[K]` requires `K` to be a TYPE in scope, in a row and in a handler
  arm alike: an undeclared name and an effectset name are both refused
  (``unknown type `IoErrors` in an exception kind``; write `with IoErrors` to
  throw the set's kinds).

<!-- doctest-skip: continues the AppError declaration above (load is not defined here) -->
```vibe skip
fn load_or_code(x: Int) -> Int {
  handle { load(x) } with {
    Exception[AppError]::Throw(e) => match e {
      Io(_) => 1,
      Parse(n) => n + 10
    }
  }
}
```

### User-defined effects (algebraic)

```vibe
effect Logger {
  Log(String) -> Unit
}

let greet: (String) -> Unit with Logger = (name) -> {
  perform Logger::Log("hello \{name}")
}

// the handler arm prints, so the executable entry carries Console
fn main allows Console {
  handle { greet("world") } with {
    Logger::Log(msg) => {
      println(msg)
      resume(())         // continue where perform left off
    }
  }
}
```

`resume(v)` is the canonical way to call the continuation (one-shot,
tail-resumptive, ADR-0050).

**Every tail of an arm must resume or leave** (#2969). An arm that does not
store `resume` as a value hands its value back to the `perform` by ending in
`resume(v)` -- on every branch -- or leaves the arm with `return`, `throw(..)`,
`perform Exception::Throw(..)`, `break` or `continue`. A bare tail value is
refused with ``handler arm `E::Op` must pass its value back with resume(...)``,
because nothing in the declaration says whether such an arm resumes or aborts.
A Unit-returning operation resumes with `resume(())`. The resumed value is
typed against the OPERATION's return type: for `Get() -> String`,
`Get() => resume(7)` is refused. A payload binder named `resume` hides the
continuation from the whole arm and is refused -- rename it. An arm that
stores `resume` as a value (the suspend shape below) keeps the other rule: its
own value is the handle's result. Only `Exception` arms abort; a declared
effect has no abortive operations.

Call resolution for an effect row follows the same lexical scope as ordinary
value resolution. When a local closure, a function parameter, or a pattern /
loop binder has the same name as a top-level `fn`, the local binding wins. So
while a pure local `take` shadows a top-level `fn take(..) with Ask`, a call to
`take` is not charged `Ask`; once the local scope ends, the top-level row is in
force again.

> **Evidence-passing implementation (#817; ADR-0076 addendum 34 V2 removed
> replay entirely)**: a handler compiles either to a direct call into the
> evidence dictionary (tail-resumptive) or to suspend CPS (first-class
> resume), and the handle body **always runs exactly once** (the old replay
> implementation's duplicated side effects and its ~16K-perform ceiling are
> gone). The price is that a perform reaching the handle body must be in a
> shape the migration can follow; a non-`Exception` handle over a shape it
> cannot follow (a callee through a row variable `with e`, an outer local
> closure with no row, and so on) is a **compile error** (needle: "cannot be
> compiled here"). The measured table of accepted shapes is the
> [A `handle` that type-checks can still fail to compile](#a-handle-that-type-checks-can-still-fail-to-compile)
> section below.

**`resume` is a first-class one-shot value inside an arm** (ADR-0076 Phase 3a,
#817): the direct call `resume(v)` stays tail-only (#942), but bound or stored
as a value it can be called later, once, like an ordinary closure. This is the
basis of the suspend pattern where a scheduler receives the continuation
(ADR-0068).

```vibe
effect Async { Suspend(Int) -> Int }
let conts: Array[(Int) -> Int] = []

let r = handle {
  let a = perform Async::Suspend(1)
  a * 10
} with {
  Async::Suspend(t) => {
    Array::push(conts, resume)   // store it...
    0 - t                        // ...and the arm's value "suspends" the handle
  }
}
// later, calling (Array::get(conts, 0))(5) runs the rest of the body: 50
```

Constraints (linear backend only): in the body of a handle whose arm
references `resume` as a value, a perform of the handled effect (and a call to
a function whose row carries it) must appear directly in a let / sequence /
tail / branch-tail position. **A let chain standing in the middle of a
statement (the sequence HEAD, as a brace-block statement or the desugaring of
a statement-position async-iterator `for` produces) is accepted: the split
floats it onto the continuation spine** (#1536 (a) v3, ADR-0076 addendum 42;
this is what lets `AsyncIter::collect` / `AsyncIter::fold` /
`AsyncIter::count` be called from a suspend body). **An `if` condition or a
`match` scrutinee that is itself a direct perform, a concrete needing call, or
a CPS-local call is also accepted, evaluated once into a fresh let before the
selection** (addendum 44). The same direct shape as the RHS of an **ordinary
assignment on the continuation spine (`x = perform Op()`)** is assigned once
through a fresh let (addendum 45). **A perform buried inside a compound
expression is accepted too** -- an operand (`acc + perform Op(i)`), a call
argument (`Array::push(out, perform Op(i))`), a constructor argument
(`Some(perform Op(i))`), a compound `while` condition (`perform Next() > 0`),
and compound assignments such as `+=` are **linearized into a let chain in the
original evaluation order** before they go on the spine (#1536 (a) v8); what
was evaluated before the perform is named first, so the order does not change.
Conditional positions are rejected as a rule, with one exception: an `&&` /
`||` whose whole expression is an **immutable `let` initializer**, whose left
side does not suspend, and whose selected right side is a directly supported
suspension or its `let` / sequence spine. Nested short-circuits, compounds such
as call arguments, a spine ending in `return` / `break` / `continue`, the
branches of an `if` / `match`, and other wider conditional or
control-transfer shapes stay rejected. **A call to a top-level function whose
concrete row contains the handled effect is accepted** (3b yield bubbling;
recursion too -- the callee gets a synthesized CPS clone and the original
function stays unchanged for its other callers). Beyond that, what may be
called is a perform, a pure builtin, a constructor, a function whose concrete
row does not contain the effect, and **a call through a row-free closure
parameter when every by-name call site of that function can be statically
shown to pass a closure literal containing no perform (or a parameter of a
delegating caller proven the same way)** (#1536 (a) -- `AsyncIter::find`'s
`pred(v)` has this shape; one site passing a performing literal rejects as
before). **A perform inside `while` / `loop` is accepted** (#1230/#1536: the
loop becomes a recursive closure returning a step; bodies with `break` /
`continue` work, `break` becoming the loop's exit continuation and `continue`
the loop's own call; only a body containing `return` is still a compile error,
because a closure cannot return from the function). A callee with a row
variable (`with e`) and a perform inside a `for` form are compile errors. A
second call of the same continuation traps with a diagnostic on stderr.
Post-processing is written through the value (`let k = resume  let r = k(v)
r + 7`). When a call that cannot be seen through causes a rejection, the
diagnostic has the same form as the handle-eligibility one: **it names the
ineligible call and points at its `line:col`** (`(here: the call to 'pred')`,
#1536/#1514).

**Suspending through a closure value is also accepted** (closure-CPS ABI,
ADR-0076 addendum 31): a suspending body can be passed as a **closure
argument**, as in `fn run_with(f: () -> Int with E) -> Int { handle { f() }
with E {...} }`, so the handle site can live in a library
(`TaskGroup::spawn_suspend` has this shape). A suspending closure literal
**needs an explicit row annotation**: `() -> Int with E { ... }` (an
unannotated lambda's effects are inherited from the enclosing row, #761). A
program that step-compiles a closure while the same effect is mixed between a
"resume-as-value handler" and a "tail-resumptive handler" is a compile error
(the convention-consistency guard).

The `k` convention, which binds one trailing parameter beyond the operation's
declared arity (`Emit(v, k) => v + k(0)`, a non-tail continuation), **was a
feature of the retired MoonBit fixture runner and is not supported on the
current build path**: the checker rejects it with `handler arm ... expects 0
payload binding(s), got 1` (#814). The evidence-passing migration (#817) is
complete but brought no non-tail continuation, and `resume(v)` is **restricted
to the arm's tail position** (`resume(10) + 1` is rejected with `resume(...)
must be the last expression of the handler arm`, #942/ADR-0050). Call the
continuation with a tail `resume(v)`. The convention's details are in
[archive/mut-effect-plan.md](../../archive/mut-effect-plan.md), "継続呼び出し規約"
(#627).

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
(`Array::length`, `Color::Red`, `String::substring`, `MyModule::x`,
`Point::{ x: 1, y: 2 }`)。**`Option::Some` はこの例にならない** — Option の
constructor に qualified 綴りは無く、`unknown name` になる (上の
"Type Definitions" 節、#2830 / ADR-0096)。

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

// A test is an entry point: the row after its name is a GRANT, spelled
// `allows` like `fn main allows ..` (ADR-0088). It widens the ambient row
// test execution supplies (see "test / bench" under 落とし穴).
test "reads a fixture" allows Fs::read_file {
  let _ = Fs::read_file("fixtures/absent.txt")
  assert(true)
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
stability for — is [spec/stable-surface.md](stable-surface.md) §3, and
`pkf run check-freeze-surface` probes every name in it against the compiler.
The bullets here are checked the same way, so a name listed as a builtin here
resolves as one.

- **String**: `length`, `byte_at`, `from_byte`, `char_code_at`,
  `from_char_code`, `concat`, `substring`, `contains`, `index_of`, `split`,
  `trim`, `starts_with`, `ends_with`, `join`
- **Array**: `length`, `get`, `slice`, `concat`

`Map::get` / `has_key` / `keys` / `values` / `set` / `size` and the Array
compatibility operations (`map`, `filter`, `fold`, `find`, `any`, `all`,
`reverse`) are call-only, not first-class values. New generic code imports
`trait Iterator` and calls `Iterator::*`; the `Array::*` spellings remain a
compatibility surface. They live in the Signature reference; they are not
indexed here because the freeze probe is a bare reference.

`String` is a byte string: `length`, indexes and slices use byte counts and
offsets, and iteration yields byte-valued `Int`. The three length views
`String::unicode_length` / `String::utf16_length` / `String::utf8_length`
count code points, UTF-16 code units and bytes of the same string (#2630). A
byte that is not part of a well-formed UTF-8 sequence counts the way the WHATWG
decoder counts it: each maximal invalid subpart is one U+FFFD (one code point,
one UTF-16 unit), so `utf16_length` is `new TextDecoder().decode(bytes).length`
for the same bytes — a stray continuation byte counts as one, an overlong
`C0 80` as two and a surrogate `ED A0 80` as three (no byte of theirs starts a
well-formed sequence, so each is its own subpart), and a truncated but
otherwise well-formed prefix such as `E2 82` as one. Other Unicode code-point
and grapheme operations are not part of this API.

<!-- import-required-builtins: the authoritative list. scripts/check_cheatsheet_signatures.sh
     requires this paragraph to name EXACTLY the entries in the Signature reference
     tables that `lookup_builtin` does not know -- no more, no less. -->

These are **not builtins** — they are library functions, and calling one without
its import is `unknown name`. The Signature reference documents them next to the
real builtins, which is why they are listed here.

From `@vibe/builtin` (`import @vibe/builtin { ... }`):
`String::replace`, `String::replace_all`, `String::trim_start`,
`String::trim_end`, `String::count`, `String::to_lower`, `String::to_upper`,
`Lines::parse`, `Lines::stringify`.

`String::to_lower` and `String::to_upper` joined that list in #2900. They were
typed as builtins unconditionally, so the name resolved whether or not anything
supplied a body: with no import the call passed `vibe check` and died in codegen,
and with any *other* name imported from `@vibe/builtin` it worked by accident of
linkage. They must be imported by name now, like the five above.

`Lines::parse` and `Lines::stringify` joined it in #2913, with the same defect
and found the same way -- by compiling a probe for every declared name and
counting the ones that reach codegen unresolved. Two places in the tree had
already met it and imported around it by hand rather than reporting it.

From `@vibe/json` (`import @vibe/json { ... }`):
`Json::parse`, `Json::stringify`, `Json::type_of`, `Json::get`, `Json::index`,
`Json::is_null`, `Json::length`, `Json::keys`, `Json::stringify_lines`,
`Json::parse_lines`.

**Bytes** (a mutable byte buffer in linear memory. Capacity doubles and grows
via `memory.copy`, so `push` is amortised O(1)):

| function | meaning | backend |
|---|---|---|
| `Bytes::new()` | empty buffer (initial capacity 64) | linear / gc |
| `Bytes::new(n)` | **zero-filled** buffer of length `n` | linear / gc |
| `Bytes::with_capacity(n)` | empty buffer reserving at least `n` bytes in one allocation; minimum 64, rounded to 8 bytes; rejects negative or over-1,073,741,816 capacities | linear / gc |
| `Bytes::length(b)` / `get(b, i)` / `set(b, i, v)` | length, element access | linear / gc |
| `Bytes::push(b, v)` | append one byte (amortised O(1)) | linear / gc |
| `Bytes::append(dst, src)` | **bulk concatenation. One `memory.copy`** | linear / gc |
| `Bytes::concat(a, b)` | concatenation returning a new buffer | linear / gc |
| `Bytes::slice(b, start, end)` | subsequence | linear / gc |
| `Bytes::index_of(hay, byte)` | first index holding `byte`, or `-1`. 16-byte SIMD scan | linear / gc |
| `Bytes::last_index_of(hay, byte)` | last index holding `byte`, or `-1`. Same scan, downwards | linear / gc |
| `Bytes::count(hay, byte)` | how many times `byte` occurs | linear / gc |
| `Bytes::compare(a, b)` | lexicographic order: `-1` / `0` / `1`, by **unsigned** byte value | linear / gc |
| `Bytes::index_of_bytes(hay, needle)` | first index of the `needle` **subsequence**, or `-1`. An empty needle answers `0` | linear / gc |
| `Bytes::blit(dst, src, start, end)` | append source range `[start, end)`; bulk copy on the linear lane | linear / gc |
| `Bytes::fill(b, value, count)` | **appends** `count` copies of `value` (a `push` loop) | linear / gc |
| `Bytes::from_array(a)` / `to_array(b)` | conversion to/from `Array[Int]` (**copies**) | linear / gc |

> **`Bytes` has no renderer**, so `"\{b}"` is refused at check time (#2987) rather
> than printing an address. Convert first: `let a: Array[Int] = Bytes::to_array(b)`
> and interpolate `a` for the byte values (`[65, 255]`).
>
> Replacing a `Bytes::push` loop with `Bytes::append` / `Bytes::blit` over a whole
> range is faster — both lower to a single `memory.copy` instruction. Accumulating
> into an `Array[Int]` and then calling `Bytes::from_array` costs one extra copy,
> so write into a `Bytes` from the start.
>
> **`Bytes::index_of` and `Bytes::index_of_bytes` are two builtins, not one
> with two spellings** (#2345). `index_of` takes an `Int` needle and finds a
> single byte; `index_of_bytes` takes a `Bytes` needle and finds a subsequence.
> They cannot be merged: the substring loop compares a needle *span* through
> `str_eq`, and a byte is not a span, so each has its own body. A needle
> outside `0..255` answers `-1`.
>
> All three single-byte searches answer for a needle outside `0..255`: `-1`,
> `-1`, and `0`. `count` needs a guard in its body to do so and the other two do
> not, which is worth knowing if you write a fourth: `i8x16.splat` keeps only
> the low 8 bits, so the vector mask for `300` is the mask for `,`. `index_of`
> and `last_index_of` use that mask only to pick where a scalar loop starts,
> and that loop compares the full value — the mask can cost a scan, never
> change an answer. `count` reads the mask AS the answer (`popcnt`), so it
> checks the needle's range up front instead.
>
> `Bytes::compare` orders by **unsigned** byte value, so `0x80` is greater than
> `0x7F`, and a common prefix falls through to the lengths — `"ab" < "abc"`.
> That second part is what makes it lexicographic rather than a memcmp. There
> is still no `Bytes < Bytes`: the operator is a type error and `compare` is
> the way to order byte strings.
>
> Against a 4 KiB buffer (`bench/bench_simd_bytes_find.vibe`, p50):
> `Bytes::index_of` 216 ns, a **native scalar byte loop** 2413 ns, the
> hand-written `Bytes::get` loop it replaces 23600 ns, `String::index_of`
> 365 ns. So **11× over scalar native** — that is what the SIMD earns — and
> ~109× over the loop a library had to write.
>
> `String::index_of` is **not** the scalar baseline: it goes through the same
> windowed v128 scan (`emit_windowed_substring_search`). The 1.7× against it
> measures specialisation — a single byte needs no needle span verified through
> `str_eq` — not SIMD.
>
> `Bytes::index_of_bytes` runs the SAME windowed search as `String::index_of`
> (ADR-0054): a 16-byte SIMD scan for the needle's first byte, then the SIMD
> `str_eq` on each candidate. The two differ only in how they unpack their
> arguments — `String` is a packed `(ptr << 32) | len`, `Bytes` is a heap handle
> whose length is at offset 4 and data pointer at offset 8.
>
> **`Bytes::fill` is NOT one of that group** (measured 2026-08-27). This table used
> to describe it as `Bytes::fill(b, off, len)`, "range fill, one `memory.fill`".
> Both halves were wrong: the parameters are `(b, value, count)`, the behaviour is
> an **append** rather than an overwrite of a range, and the implementation is the
> `bytes_push` loop in `gen_bytes_fill_body`
> (`codegen/builtin_bodies/bodies_core_a2.vibe`) — a single body shared by the
> linear and gc backends.
>
> **The one-argument `Bytes::new(n)` used to be linear-only** and is not any
> more (#2363, fixed 2026-08-27). `compile_call.vibe` special-cases a
> one-argument `Bytes::new` and synthesises `new()` plus a zero-push loop;
> `codegen/gc/backend_call.vibe` had no counterpart, and the registry declares
> `Bytes::new` with `reg_p0()`, so on wasm-gc the argument was pushed and the
> zero-parameter runtime body called anyway. It type-checked on both lanes,
> passed `wasmtime compile`, and failed at run time on one of them. The gc call
> path now carries the same synthesis, and
> `fixtures/bytes_alloc_backend_parity_test.vibe` pins both spellings on both
> lanes.
>
> `Bytes::new()` + `Bytes::fill(b, 0, n)` remains equivalent and is what
> `MutMap`'s control array uses (`lib/@vibe/core/hashmap.vibe`).

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

**Conversion**: `Int::to_string`, `Int::to_double`, `Double::to_int`, `String::from_byte`, `Int::parse(s) -> Option[Int]` (10 進、先頭 `-` 可; 空文字列・非数字・`Int::max_value` 超えは `None`), `Double::parse(s) -> Option[Double]` (an optional sign, digits, an optional fraction, an optional `e`/`E` exponent, and `NaN` / `Infinity` / `-Infinity`; correctly rounded, so it reads back every spelling `Double::to_string` writes; both backends, #2652), `Double::to_string(d) -> String` (the shortest digits that read back to the same double, in JavaScript's spelling: `1.5`, `100`, `0.000001`, `1e-7`, `1e+21`, `1.7976931348623157e+308`; `NaN`, `Infinity`, `-Infinity`, and `-0` for negative zero; `"\{d}"` and `__to_string(d)` print the same, #2652)

**Reserved prefix**: `__vibe_` is the compiler's. Its generated definitions
carry it (the Double runtime prelude's `__vibe_double_to_string`, the String
length-view prelude's `__vibe_string_unicode_length`) and are found again by
spelling, so `vibe check` refuses a program's own top-level definition spelled
that way, with the edit first (a local binder is fine).

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
| `String::length` | `(String) -> Int` (bytes) |
| `String::unicode_length` / `String::utf16_length` / `String::utf8_length` | `(String) -> Int` (code points / UTF-16 code units / bytes -- `utf8_length` is `length`, #2630; a malformed byte sequence counts as one U+FFFD per maximal subpart, as the WHATWG decoder counts it) |
| `String::concat` | `(String, String) -> String` |
| `String::substring` | `(String, Int, Int) -> String` (start, end) |
| `String::byte_at` | `(String, Int) -> Int` (deprecated alias `String::char_code_at` — `vibe check` warns per use) |
| `String::from_byte` | `(Int) -> String` (deprecated alias `String::from_char_code` — `vibe check` warns per use, including inside `\{...}` interpolations, #2203) |
| `String::equals` | `(String, String) -> Bool` |
| `String::split` / `String::join` | `(String, String) -> Array[String]` / `(Array[String], String) -> String` |
| | `String::split(s, "")` is `[s]` — an empty separator does not split into bytes (#2378; it used to run out of memory) |
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

**Slicing clamps; indexing traps** (#2997). `String::substring(s, start, end)`,
`s[start:end]` and `Array::slice(xs, start, end)` clamp both bounds into
`0..length`, and an `end` before `start` gives the empty slice -- nothing traps:
`"abcdef"[2:10]` is `"cdef"`, `Array::slice([3, 1, 2], -1, 2)` is `[3, 1]`,
`Array::slice([3, 1, 2], 2, 1)` is `[]`. A single-element read is the opposite:
`Array::get(xs, -1)` traps with `index -1 out of bounds for length 3`.

**A shift count saturates at 63** (#2978): `x << n` is `0` and `x >> n` is the
sign (`0` or `-1`) for any `n >= 63` and for a negative `n`, on every lane. It
used to follow wasm's mod-64 masking of the i64 representation, so `1 << 63`
was `0` while `1 << 64` came back as `1`.

**`Double::to_int` truncates toward zero and saturates** (#2978): a value above
the `Int` range (and `+Infinity`) answers `Int::max_value`, below it (and
`-Infinity`) `Int::min_value`, and `NaN` answers `0`, on every lane. It used to
answer `0` for every out-of-range value.

**`Env::get(name)` answers `""` for an UNSET variable** (#2995), so an unset
variable and one set to the empty string read the same. A program that must
tell them apart cannot do so through `Env::get` today.

**Array** (builtin — callable bare, no import):

| function | signature |
|---|---|
| `Array::length` | `(Array[T]) -> Int` |
| `Array::get` | `(Array[T], Int) -> T` |
| `Array::set` | `(Array[T], Int, T) -> Unit` |
| `Array::push` | `(Array[T], T) -> Unit` |
| `Array::truncate` | `(Array[T], Int) -> Unit` |
| `Array::slice` | `(Array[T], Int, Int) -> Array[T]` |
| `Array::concat` | `(Array[T], Array[T]) -> Array[T]` |
| `Array::reverse` | `(Array[T]) -> Array[T]` |
| `Array::with_capacity` | `(Int) -> Array[T]` — see "Reserving array capacity" above |

There is no `Array::pop` and no `Array::is_empty`; both are `unknown name`.
Test emptiness with `Array::length(xs) == 0`.

This list is MEASURED against the compiler (each name compiled bare in a
one-line program), not read off a declaration file. It was wrong in the
direction that file cannot see: `set`, `push`, `truncate` and `with_capacity`
are implemented but were undocumented, because `check_cheatsheet_signatures.sh`
checks that a DOCUMENTED signature is real and not that a real builtin is
documented — and `Array::with_capacity` is handled inline in `checker.vibe`
rather than through the builtin table that gate reads, so it is invisible to it
from both directions (#2554).

**Array compatibility operations** (prelude; collection first, function
last). New generic code should import `trait Iterator` and use the matching
`Iterator::*` operation. These direct Array specializations remain available
for compatibility. `Array::foreach` was listed here until #2900 and never
existed: the checker declared it, nothing lowered it, and a call died in
codegen. Write `for x in xs { .. }`.

| function | signature |
|---|---|
| `Array::map` | `(Array[T], (T) -> U) -> Array[U]` |
| `Array::filter` | `(Array[T], (T) -> Bool) -> Array[T]` |
| `Array::fold` | `(Array[T], U, (U, T) -> U) -> U` |
| `Array::any` / `Array::all` | `(Array[T], (T) -> Bool) -> Bool` |
| `Array::find` | `(Array[T], (T) -> Bool) -> Option[T]` |

**Builder**: `ArrayBuilder::new() -> ArrayBuilder[T]`,
`push(ArrayBuilder[T], T) -> Unit`, `freeze(ArrayBuilder[T]) -> Array[T]`.
`MapBuilder::new() -> MapBuilder[String, V]`,
`set(MapBuilder[String, V], String, V) -> Unit`,
`freeze(MapBuilder[String, V]) -> Map[String, V]` — String-keyed, like `Map`.
A `for-in` comprehension desugars to these builder operations internally.

**Map** — the builtin `Map` is **String-keyed**, not generic in its key, and
its type is spelled **`StringMap[V]`** (no import needed; the operations keep
the `Map::` qualifier). `Map::set(m, 7, 1)` is `argument type mismatch for
Map::set: expected String, got Int`, and an ANNOTATION naming a concrete
non-String key (`fn f(m: Map[Int, String])`) is rejected where it is written
rather than at the first op (#2263). For a generic key, use `MutMap[K, V]`
from `@vibe/core`.
`get: (Map[String, V], String) -> V` (throws when absent),
`set: (Map[String, V], String, V) -> Map[String, V]` (returns a new map),
`has_key: (Map[String, V], String) -> Bool`,
`keys: (Map[String, V]) -> Array[String]`,
`values: (Map[String, V]) -> Array[V]`.


**Math**: `Int::abs`, `Int::max`, `Int::min`, `Int::clamp`, `Int::signum`,
`Int::is_even`, `Int::is_odd`, `Double::abs`, `Double::max`, `Double::min`,
`Double::floor`, `Double::ceil`.

**Bits** (#2344): `Int::popcount`, `Int::ctz`, `Int::clz`, `Int::select1`.
All four are **63-bit** answers, because an `Int` is a 63-bit two's complement
value and not an i64 — so `Int::popcount(-1)` is 63, not 64, and the largest
positive `Int` (2^62-1) tops out at bit 61, giving it a popcount of 62 and a
`clz` of 1. The zero cases are defined rather than inherited from wasm (which
answers 64): `Int::ctz(0)` and `Int::clz(0)` are both 63. `Int::select1(x, k)`
gives the position of the `k`-th set bit counting from 0, or -1 when `x` has
fewer than `k + 1` set bits — so `Int::select1(x, 0)` agrees with `Int::ctz(x)`
for every non-zero `x`. `~x` (prefix bit-not, #2344) completes the set: it is
the complement over the 63-bit two's complement `Int`, so `~x == -x - 1`
(`~0 == -1`, `~5 == -6`, and `~` is its own inverse). It binds like the other
prefix operators, and `Int` is its only operand type — there is no `Double`
form, and `~true` is rejected as `operand of \`~\` must be Int`. The same `~`
still marks a labeled parameter (`x~: Int`); only the expression-start
position is the operator.

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
| `sleep` | `(Int) -> Unit` — the argument is **milliseconds** | `Async` |

The four stdin providers are **direct-call only**. To pass one as a value,
define a wrapper whose `with` row names `Stdin` / `Async` explicitly — the
checker rejects an alias to the builtin itself or a value-position
reference.

**Raw wasm opcodes are not part of this surface.** The `i32_*` / `i64_*` /
`f32_*` / `f64_*` names (`i32_store`, `i32_load8_u`, `f64_neg`,
`f32_demote_f64`, …) that appear in `lib/@vibe/compiler/builtins/declarations.vibe`
under "WASM intrinsics (low-level)" are what the backends emit through: they
have no `checker_visible` registry row and no namespace lookup, so spelling one
in vibe source is `unknown name` (#2343). The block says so at its head and
`tests/gates/early/run.sh` section 4g checks the claim, so their absence here is
a decision, not an omission — do not add them from an old table. The
`__`-prefixed operator names (`__add`, `__index`, `__eq`, …) are internal for the
same reason; the **Operators** table above documents the spellings that reach
them.

**JSON**: `Json::stringify: (Any) -> String`, `parse: (String) -> Json`,
`type_of: (Json) -> String`, `get: (Json, String) -> Json`,
`index: (Json, Int) -> Json`, the `string` / `number` / `bool` extractors,
`is_null: (Json) -> Bool`, `length: (Json) -> Int`,
`keys: (Json) -> Array[String]`, `stringify_lines: (Array[Json]) -> String`,
`parse_lines: (String) -> Array[Json]`.

**Lines**: `Lines::parse: (String) -> Array[String]`,
`Lines::stringify: (Array[String]) -> String`.

**Assertions**: `assert: (Bool) -> Unit`, `eq: (Eq, Eq) -> Bool`,
`assert_eq: (Eq, Eq) -> Unit`. `abort: (String) -> Unit` prints the
message on the same stream a bounds-check abort uses, then traps; it
carries no effect row, so an empty-row library function may call it.

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
import @vibe/builtin {
  trait Iterator
}

let pipes: () -> Array[String] with Process = () -> {
  let a = sh_lines("echo hello | cat")
  let b = sh_lines("printf 'a\\nb\\nc' | sort -r")
  sh_lines("seq 1 10 | head -3")
}

let count_txt: () -> Int with Process = () -> {
  sh_lines("ls /tmp")
  |> Iterator::filter((s) -> { String::contains(s, ".txt") })
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
import @vibe/builtin {
  trait Iterator
}

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
  |> Iterator::map(_, parse_int)
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

- Activate flags at compile time: `VIBE_CFG=dev vibe build app.vibe` (comma-separated for multiple). The set applies to **every module of the program**, imports included, and is part of the build-cache key, so switching flags between two builds is a cache miss, never a replay (#2513).
- A `#cfg(flag)` statement whose flag is inactive is parsed (syntax must stay valid, like Rust's `cfg`) and **dropped before checking/codegen** — zero bytes in the output binary.
- Top-level statements only (`let` / `enum` / `struct` / `impl` / ...).
- `vibe normalize` refuses a `#cfg` source (it prints the parsed program, and an inactive statement is no longer in it). `vibe fmt` is token-based and keeps every directive and both arms, so `#cfg` sources format and pass `check_vibe_fmt.sh` (measured on `fixtures/cfg_flag_test.vibe`).
- The compiler's own sources may use it: the committed seed (seed/cfg-spans-emission-2026-09-04 and later) resolves `#cfg` in module-source emission, so the flattened self-build carries the active statements as themselves. Module-source emission and the span-based tools (`vibe escapes` / `vibe grep` / `vibe type-at`) all resolve against the same active set (#2497 step 0, #2516).

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
- Like `#cfg`, not usable inside the compiler's own source until the seed compiler understands it (see docs/internal/operations/bootstrap.md).

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
  no `where` contracts, params typed `Int`, `Bytes` or `Array[Int]`, return
  type `Int`. A `Bytes` param passes the RAW untagged object pointer (linear
  heap layout: length at `obj+4`, data pointer at `obj+8`) — the body can
  `i32.load offset=8` the data pointer and feed `v128.load`/`v128.store`
  (the pointer is only valid while the Bytes is alive and un-grown). No
  `call_indirect` / `return_call` / `global.*` / `br_table` / `f32.const` /
  `f64.const`.
- **`Array[Int]` params** (#2348): `local.get $xs` yields the array's header
  address — `[capacity@0][length@4][data_ptr@8]`, so the length is
  `i32.load offset=4` and the element block starts at `i32.load offset=8`.
  The **same address on both lanes**: an array value is odd under `VIBE_RC=1`
  (the production default) and even on the bump lane, and the assembler masks
  the tag off every `local.get` of an array param rather than making the
  kernel author pick. The mask is why the slot itself is read-only — writing
  to it would hand RC's epilogue a value it did not allocate — so
  `local.set $xs` / `local.tee $xs` are located errors; copy into a declared
  `(local $tmp i64)` instead. Both spellings of the parameter behave the same:
  the mask is keyed by the resolved wasm index, so `local.get 0` masks exactly
  as `local.get $xs` does. (The valtype lookup is still keyed by name, so the
  numeric spelling types as unknown — #2401's gap, which errs toward accepting
  a body wasm would accept, not toward miscompiling one.) What is NOT normalized, and cannot be, is the
  **element** at `data_ptr + i*8`: it is an `Int` in the lane's own
  representation, tagged `n<<1` under RC and raw under bump, exactly the trap
  a scalar `Int` param already has. So `i64x2.add` straight over the slots is
  correct on both lanes (addition is tag-transparent) while a multiply or a
  shift is not, and an index arriving as a tagged `Int` scales by 4 under RC
  where it scales by 8 on bump. The pointer is only valid while the array is
  alive and un-grown — `Array::push` may reallocate the element block.
- **Calling another kernel** (#2348): a body may `call` another inline-wasm
  `fn` in the same module — `(call $other (local.get $a) (local.get $b))`.
  Write only the real arguments: the assembler adds the closure-env slot
  every user function carries as its last wasm param, then the call. The
  callee may be declared anywhere in the module, before or after the caller.
  Two limits, both deliberate: the callee must itself be an inline-wasm `fn`
  (an ordinary vibe `fn` has an effect row, RC accounting and a real closure
  env that this assembler does not model), and `call` is **folded-form only**
  — the flat spelling's operand count is not knowable in the assembler, so
  its arity could not be checked and a mismatch would surface as a wasm
  validation failure at module load instead of a located error. The operand
  count IS checked against the callee's declared params, and each operand
  must itself **yield one i64** — every inline-wasm parameter is an i64 slot.
  Both halves are located errors rather than a module that fails at load:
  `(call $f (drop (local.get $a)))` counts as one operand but pushes nothing,
  and `(call $f (i32.const 1))` pushes the wrong width. So a `(block ...)` /
  `(if ...)` operand needs an explicit `(result i64)`, a comparison
  (`i64.eq`, `f64.lt`) is i32 and is rejected, and `local.get` of a declared
  `(local $p i32)` is rejected while a parameter — always i64 — is fine. The
  check errs toward rejecting: `unreachable` / `return` / `br` are
  stack-polymorphic and wasm would accept them there, and `select` is not
  typed.
- **Operand types and stack depth are checked** (#2401): the assembler walks
  an abstract value stack, so a body that is not valid wasm is a located error
  from `vibe check` rather than a module that fails when a runtime loads it.
  `(i64.add (i32.const 1) (i64.const 2))` and
  `(block (result i64) (i32.const 1))` both used to assemble. What is checked:
  each instruction's operands against its signature (a lane shift takes an
  i32 amount, a load/store addresses through an i32, `replace_lane` takes the
  shape's scalar, a comparison yields i32 whatever its operand width); a
  `block` / `loop` / `if` actually leaving what its `(result T)` declares, and
  leaving nothing without one; an `if` with a `(result T)` having an `(else
  ...)`; and the depth, in both directions — too few operands for an
  instruction, and a body that leaves other than the single i64 an
  inline-wasm fn returns. A block's frame is a floor, so an instruction inside
  it cannot consume a value produced outside it. Dead code after
  `unreachable` / `br` / `return` is stack-polymorphic but still typed, which
  is what wasm does too — polymorphism lets a frame's declared result come
  from the floor, it does not let values pushed afterwards survive to the
  frame's `end`. Two deliberate gaps, both erring toward accepting: a
  numeric `local.get 3` types as unknown (the locals table is keyed by name)
  and an unknown matches anything, and `br_table` is not in the slice at all.
- **Locals**: the fn's own params (`$name` or index), plus `(local $name
  TYPE)` declarations at the START of the body — types `i32`/`i64`/`v128`,
  grouped in that order (a located error enforces the grouping); declared
  locals index past the params + closure-env slot. v128 locals are what let
  a kernel keep vector state across instructions (e.g. the BLAKE3 compress
  in `lib/@vibe/blake3/simd/simd.vibe`).
- **Integer immediates** accept BOTH spellings the text format defines
  (`iN ::= n:uN | i:sN`), so `(i32.const 2654435761)` and
  `(i32.const -1640531535)` are the same instruction. Out of range for the
  instruction's width — or longer than a vibe `Int` — is a **located error**
  from `vibe check`, not a truncation and not a module that only fails at load
  (#2341). NOTE until the next bootstrap bump: the committed seed predates this,
  and `vibe test` compiles with the seed by default, so inside `lib/**` and
  anything run through `scripts/vibe_test.sh` keep spelling an out-of-signed-range
  i32 immediate the signed way.
- **WAT text**: ordinary string literal(s) — the lexer has no raw/multiline
  strings; adjacent literals after `= wasm` are joined with newlines. `;;`
  line and `(; ;)` block comments work inside the text.
- Folded S-expressions emit operands first (real WAT semantics); flat
  sequences (`local.get $a local.get $b i64.add`) also work. Structured
  control (`block`/`loop`/`if`) is folded-form only:
  `(block $l (result i64) ...)`, `(if (result i64) <cond> (then ...) (else ...))`,
  `br`/`br_if` with `$label` or relative depth. `call` is folded-form only for
  the same reason (see above).
- SIMD (0xFD prefix) is supported: `v128.const i64x2 1 2`, splat /
  extract_lane / replace_lane, `i8x16.shuffle` (16 lane-byte immediates
  0..31), lane arithmetic, bitwise, `all_true` / `any_true` / `bitmask`,
  `v128.load` / `v128.store`.
- Memory instructions address the runtime's linear memory directly — the heap
  layout is NOT a stable interface; loads/stores are at-your-own-risk.
- Not usable inside the compiler's own source until the seed compiler
  understands the syntax (same bump discipline as `#cfg`, docs/internal/operations/bootstrap.md).
- Examples: `fixtures/inline_wasm_test.vibe`.

## RC Debug Mode (`VIBE_RC=shadow`)

`VIBE_RC=shadow vibe build app.vibe` compiles on the Perceus RC path with **shadow-liveness instrumentation**: every freed heap block is marked in a shadow byte table, and the FIRST `rc_dup`/`rc_drop` touching a freed block executes `unreachable` — a deterministic trap at the faulting operation, instead of free-list corruption that crashes later at an unrelated location ("moving target", see issue #715). Debug-only: adds a memory pad + per-dup/drop checks. Normal builds (`VIBE_RC=1`/unset) are byte-identical to before this feature.

## 落とし穴 (measured, not folklore)

判断に迷いやすい規則をここに集める。**すべて現行 stage2 で実測したもの**で、
仕様書の記述ではない。同じことを二度調べ直さないための場所。

### A library `fn X::y` replaces a same-named builtin PROGRAM-WIDE

A top-level definition wins over a builtin of the same name. For a **qualified**
name (`X::y`) the scope of that win is the whole linked program -- not the file,
not the import list. Measured (2026-08-28), three files:

```vibe skip
// dep.vibe
export fn String::index_of(s: String, sub: String) -> Int { -999 }
export fn unrelated_helper(n: Int) -> Int { n + 1 }

// caller.vibe -- imports ONLY unrelated_helper, never String::index_of
import ./dep.vibe { unrelated_helper }
test "t" {
  inspect(String::index_of("hello world", "world"), "")   // -999, not 6
}
```

Drop the `import` line and the same expression answers `6`. Nothing is
reported either way, so the two readings of one source are indistinguishable
without running it.

A **bare** name is contained to its own file. Measured the same way, four
names, each called both from its defining file and from an importer that
imports only an unrelated name:

| definition | shape | what the importer got |
|---|---|---|
| `String::index_of` | qualified | the local definition |
| `String::trim` | qualified | the local definition |
| `eq` | bare | the builtin |
| `not` | bare | the builtin |

So redefining `eq` or `println` in a package does not reach that package's
users. Treat that as today's behaviour rather than a rule: it is an observed
property of the resolver, and #2378 is where the intended one gets decided.

The cost is not theoretical. A scalar re-implementation of a SIMD builtin in a
library is not a second implementation alongside it — it is the one that runs,
for every dependent. Measured on a 22 KiB haystack with one match: a sparse
`String::index_of` costs **0.8 us** against the builtin and **174 us** (~218x)
against a library `fn` of the same name that some other file in the program
happened to define. The answers can differ too, not just the speed:
`String::split(s, "")` trapped on one and returned `[s]` on the other.

`vibe check` reports it twice (#2378): the DEFINING file gets a warning at
the definition (#2628), and the leak itself is refused where it happens, at
the IMPORTER. A `fn` (or a bound lambda) defined at a QUALIFIED name the
builtin registry owns — `export fn String::index_of(..)`, `export`ed or not —
marks the module's published environment, and every module that imports that
file, even for one unrelated name, is rejected with the edit first: rename it
in the dependency; a bare or differently qualified name keeps the builtin. The
entry file's own shadow stays legal (a warning, never an error) — it is
explicit in the program being compiled, and
`fixtures/to_string_shadowed_builtin_test.vibe` relies on it — and so does
what does not leak: a bare name (namespaced per file), a `Trait::operation`
whose trait the same file declares (namespaced the same way), a qualified name
the registry does not own (`Array::map`, which `@vibe/builtin` itself
defines), and a `let` value alias at the qualified name (`export let
Fs::exists = exists` in `lib/@vibe/fs/fs.vibe`), which takes no part in the
name-to-fn-def resolution a real definition hijacks. The rule is the
compiler's, not a lexical scan's — `fn r#String::index_of` reads as `r` to a
scanner, `#deprecated fn X::y` sits off column zero, and `fn` and its name may
sit on separate lines; each of those was a silent miss in a scanner built for
exactly this rule. Deciding what a declaration binds is the compiler's job,
and `scripts/check_builtin_shadowing.sh` keeps asking it about the tree for
the bare-name and alias shapes the rule leaves alone.

A compiler-provided name can still be published from a package without
defining it — a bodyless declaration on the export surface, the shape
`String::utf8_length` uses — so `import @vibe/builtin { String::split }`
resolves without anything shadowing the builtin.

### A builtin can be a value, and the rule is one property

`String::concat` / `Array::get` / `FrozenArray::from_array` can be bound to a
name and called through it. The lowering is an eta-expansion (`(a, b) -> f(a, b)`),
so the binding is an ordinary closure and answers exactly as the direct call does.

```vibe skip
// -- accepted
let get = Array::get
let n: Int = get([1, 2], 0)          // 1
let cat = String::concat
let s = cat("ab", "cd")              // "abcd"

// -- rejected, with the SAME message the direct call gives
let g = Array::get
let bad: String = g([1], 0)          // expected String, got Int
```

A builtin has a value form exactly when the registry knows its **arity**, every
position in its signature is either concrete or a real type variable, and its
**effect row is empty**. The two refusals each say why, and they are not the
same kind of thing:

| refused | why | what to write instead |
|---|---|---|
| `Fs::read_file`, `Env::get` | an effect row is only checked where the call is written, so a value form would launder authority | `(p) -> Fs::read_file(p)` — the wrap form is the answer, not a workaround |
| `Map::get`, `FixedArray::get` | a position is still an unconstrained unknown — an internal handle, or an element type nothing relates to the result | call it directly |

Being **unqualified** is no longer a refusal (#2442). `eq` and `not` bind and
call like any other value form:

```vibe skip
let f = eq
let a: Bool = f(3, 3)                // true
let b: Bool = f("ab", "ac")          // false -- but ONE type per call:
let c: Bool = f(1, "x")              // rejected, expected Int, got String
let g = not
let d: Bool = g(true)                // false
```

It used to be a refusal because the whole-program lambda-site planner was
scope-free and could not tell the builtin from a local of the same name. The
planner now threads a bound set, and codegen resolves a name as
**locals → constants → constructors → value form → func table** — so anything
that can shadow a bare name still wins, and a module that defines its own `eq`
never sees the builtin:

```vibe skip
let eq = 5                           // a module-level constant named `eq`
fn main() -> Unit {
  println("${eq}")                   // 5, not a function
}
```

Being polymorphic is **not** a refusal: `Array::get` is `(Array[T], Int) -> T`
in the registry and each use instantiates its own `T` (#2451). Before that it
was refused as a class, and #1733's two `FrozenArray` conversions were carved
out of the refusal by name — with the hole that made the carve-out visible:
`let freeze = FrozenArray::from_array` then
`let fz: FrozenArray[String] = freeze([1, 2])` checked clean and read the Ints
as Strings. That is now rejected.

Pinned by `fixtures/builtin_value_form_test.vibe` (the runtime answers, all
three lanes) and `lib/@vibe/compiler/tests/builtin_ident_value_test.vibe` (the
admission rule and every diagnostic quoted above).

### A lambda binder's trait bound is its own witness (#2778)

A bound on a nested lambda is honoured. The lambda's bounds are dictionaries
of its own, laid over the enclosing ones, and a formal this binder rebinds
hides the outer dictionary. An inner `[U: Eq]` still sees an outer
`[T: Show]`. An inner `[T: Eq]` uses its own `T`, not the enclosing binder's.

That covers a qualified call (`T::equals`), a UFCS call (`a.equals(b)`),
taking the method as a value (`let cmp = T::equals`), and a kinded binder
(`F[_]`). An inner `[T: Show]` that shadows an outer one renders through its
own witness. Pinned by `fixtures/lambda_bound_nested_witness_test.vibe`.

What still has no renderer is an unbounded formal, at either level:
`let f = [U](a: U) -> String { "\{a}" }`. The checker rejects it. Give the
formal a method-bearing `Show` bound, or interpolate at a concrete type.
A renderless struct is still refused by name (#1445).

### A generic binder may not quantify a slot the lambda CAPTURED

An explicit binder (`[T]`) makes a lambda generic per call. That is only sound
when the thing the binder describes is created per call too. A binder that ends
up naming a slot of an ENCLOSING binding is rejected at its declaration:

```vibe skip
fn main() -> Unit {
  let xs = []

  // -- rejected
  let get = [T]() -> Array[T] { xs }
  // move `xs` inside the lambda, or drop `[T]` and every `T` in its
  // signature: the captured `xs` fixes `T`, so every call would use one
  // value at a different type

  // -- accepted: a fresh array per call, so `T` really does vary
  let mk = [T]() -> Array[T] { [] }
  let a: Array[Int] = mk()
  let b: Array[String] = mk()
}
```

Checking `-> Array[T]` unifies `xs`'s element slot with the binder, so without
the check `fill(get(), 1)` and `fill_s(get(), "s")` both pass and ONE runtime
array holds an Int and a String (#2455). It is the same silent-wrong class as
the empty-array value restriction (#2447: `let xs = []` used at two element
types), one quantifier away — the restriction cannot see it, because after
unification the captured slot and the bound variable are literally one
variable.

The two edits in the message are the whole fix, and which one is right depends
on what you meant: **move the value inside** if each call should get its own,
**drop the binder** if they should share one (the lambda is then monomorphic,
and its element type is decided by the first use).

Drop the binder's `T`s along with the binder. `[T]` and the `T` in
`-> Array[T]` are one declaration and one use, so removing only the first
leaves `unknown type `T`` behind:

```vibe skip
// -- still an error: the binder is gone, its use is not
let get = () -> Array[T] { xs }

// -- accepted
let get = () -> { xs }
let a: Array[Int] = get()
```

Only an OPEN slot is an escape. These all stay clean, measured:

| captured | why it is fine |
|---|---|
| `let n = 1`, `let xs: Array[Int] = []` | no open variable to fix |
| `let xs = [1]` with `[T](v: T) -> Int` | the binder does not touch `xs`'s slot |
| a generic `fn mk[T]()` | a scheme, instantiated fresh at the call |
| the lambda's own recursive name | unified with its signature only after the body is checked |

Pinned by `lib/@vibe/compiler/tests/generic_binder_escape_test.vibe`.

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
`Console::write_stream(42)` が compile も実行も成功して garbage を出した。
今は両方とも check 時にスパン付きで落ちる:

```vibe skip
// doctest-skip: intentionally rejected — the diagnostics are the point
Console::write_stream(42)      // argument type mismatch for Console::write_stream
Console::write_stream()        // function arity mismatch: expected 1 args, got 0
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
test "name" { .. }               // ok  -- the name must be a string literal
test name { .. }                 // NG: expected test name string
test "n" allows { Fs } { .. }    // NG: a braced row is not a spelling -- write `allows Fs`
test "n" with Fs { .. }          // NG: a block grants its row -- write `allows Fs`
```

**A named `test` / `bench` / `example` may write a row after its name**
(#1508). A test is an entry point, so the row is a **grant** and the keyword
is `allows`, as on `fn main allows ..` (ADR-0088). The declared row
**widens** the ambient row (`{ Fs, Env, Stdin, Stdout, Stderr, Console,
Process, Profiler, Error, Exception }`; `Console` is the current name for the
tty, the three older labels are legacy) rather than replacing it -- writing
`allows Http` keeps the defaults `assert` needs, such as `Exception`. An
anonymous `test { .. }` / `bench { .. }` cannot carry a row (there is no name
to key it on). `test "n" with ..` is refused by the parser, which names the
`allows` edit with the row it read.

The row is admitted like `main`'s: what it names must be something the run
can bring in -- a host capability, `Exception`, `Async`, or an effectset of
those. A user-declared effect (`test "x" allows Ask::Get`), a row variable,
or an operation a provider does not own (`allows Console::Get`) is refused,
with the `handle` edit for the user effect: nobody outside the program
provides it, so granting it would only authorize a `perform` no handler
catches. Nor can a block write `perform?` itself: a test artifact runs with
full authority, so the `NotGranted` arm could never run -- put the
`perform?` in a function that requires `with Op?` and call that.

```vibe
// the row may name an effect, an operation, or an effectset
test "declared row widens the ambient one" allows Exception {
  assert_eq(1 + 1, 2)
}

bench "http_get" allows Http {
  let h = Http::request("GET", "http://127.0.0.1:18281/hello", "", "")
  let _ = Http::response_body(h)
  Http::close(h)
}

test "op-granular row" allows Http::request + Http::close {
  let h = Http::request("GET", "http://127.0.0.1:18281/hello", "", "")
  Http::close(h)
  assert(true)
}
```

This is what makes **a test / bench that really calls `Http`** writable --
the design is unchanged: the network is absent from the ambient row and must
be declared. The client builtins (`Http::request` / `response_status` /
`response_header` / `response_body` / `close`) lower to host imports even
when spelled directly in a bare file (the second barrier of #1508, removed;
runnable example: `bench/http_bench.vibe`, which needs `python3
tests/http_echo_server.py 18281`). The server side (`Http::listen` /
`accept` / `respond`) still needs a handler. The old workaround of
discharging the row with `handle { .. } with Http { _ => () }` is no longer
needed for a real HTTP test / bench.

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
> [docs/internal/design/module-system-oracle.md の「現行モデル」節](../../internal/design/module-system-oracle.md#現行モデル-canonical--ここが唯一の現行記述) (#1269)。
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

generated_hash =      // 任意。publish 時に自動挿入 (#pkg:b3:<64hex>; 既存の #pkg:sha1:<40hex> は検証のみ)
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
触らない — 詳細は [docs/user/reference/cli-commands.md](cli-commands.md) の `fmt` 節。

---

*Full reference: [docs/user/reference/syntax.md](syntax.md) — canonical surface syntax*
