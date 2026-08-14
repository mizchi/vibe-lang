# vibe Language Cheat Sheet

WASM-targeting, pure-by-default language with algebraic effects. The compiler
is self-hosted: it is built from the committed seed (`bootstrap/seed/`) plus
the selfhost sources (`lib/@vibe/compiler/`, `lib/@vibe/cli/`) via the wasm
runner — no MoonBit toolchain is required (the MoonBit host implementation was
retired in #594; see `docs/archive/moonbit-retirement.md`).

## Quick Start

```vibe
// `stdout_write` is a prelude helper, not a builtin — import it (otherwise the
// checker reports `unknown function: String::stdout_write`).
import @vibe/prelude { stdout_write }

fn main with Stdout {
  stdout_write("hello world\n")
}
```

```bash
vibe run hello.vibex       # compile & execute
vibe shell                 # interactive shell
vibe test file.vibe        # run tests
vibe check file.vibe       # type check only
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
let x: Int = 42                // 62-bit tagged, max 2^61-1
let f: Float = 1.5f            // 32-bit (suffix f)
let d: Double = 3.14           // 64-bit (default decimal)
let s: String = "hello \{x}"   // interpolation with \{expr}
                               // (旧 `\(x)` は 0.3.0 で削除、`\{x}` を使う)
                               // #1392: 補間の値の型がコンパイラに解決でき、
                               // その型に `T::to_string` (derive(Show)/
                               // derive(Hash) 生成物、または手書き) があれば
                               // それを呼ぶ。`Option`/`Result` と、その場に
                               // 書かれたタプル/配列リテラルは構造的に展開
                               // される (`"\{Some(p)}"` -> `Some(P { .. })`)。
                               // 型が解決できない値、および変数越しの
                               // タプル/配列はまだ生ポインタの10進数 (#1392)
                               // prelude の `to_string(v)` も同じ描画になる
                               // (補間と同じ書き換えを call site で受ける)
let c: Char = 'A'              // byte value 65; Char is a transparent Int alias
let b: Bool = true
let u: Unit = ()
```

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
| Cross-call / handler-mediated state | `effect Mut { ... } + handle ... with Mut` | ADR-0021; tail-resumptive is zero-cost |

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
| `XBuilder` suffix | a mutable, growable builder; not meant to be held onto — call **`::build`** to get the persistent value | `ArrayBuilder`, `MapBuilder`, `StringBuilder` |
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

> **旧綴りの型注釈は動かない。** `let m: HashMap[String, Int] = ...` は
> エラーになる。`type HashMap[K, V] = MutMap[K, V]` という別名を置いても
> **モジュール境界を越えると展開されない** (contract 側に書いても実装側から
> export しても同じで、別名は merge 後のソースには現れるのに checker は
> `HashMap[Int]` と `MutMap[Int]` を別の型として扱う)。守れない約束を
> 置くより、破れる場所を1つに絞って明示するほうを採った ——
> 注釈は `Mut-` 名に書き換えること (穴そのものは #1700)。

旧綴りの**関数**を使うと `vibe check` が移行先を名指しする `warning:` 行を
出す (非致命、exit 0)。**これは #1262 follow-up で初めて実際に効くようになった**
—— それまで `check_deprecated_warnings` は loader とは別の素朴なパス解決を
使っていて、`@scope/pkg` が解決できず**パッケージが公開した `#deprecated`
マーカーが 1 つも届いていなかった** (同じ経路が原因で `vibe check` 自体、
`@scope/pkg` を import するファイルで crash していた)。

**"Frozen" and "persistent" are not synonyms.** `Map`/`StringSet` are
persistent (functional-update) but are *not* `Send`-eligible under the
current allowlist (see `docs/concurrency.md` "Send と capture safety") —
only scalars, `mut`-field-free structs/enums, `Option`/`Result` of those,
same-nursery `Sender`, and `FrozenArray[T]` are. Reach for `FrozenArray`
specifically when a value needs to cross a `spawn`/task boundary; reach for
a bare-named persistent type for ordinary functional-update code.

**Builder の終端動詞は `build`** (ADR-0101 (3), #1262)。`StringBuilder::build()
-> String` のように**型名と動詞が lexical に対応する**ようにしたもの。
`freeze` は「Frozen-(persistent + `Send`)を産む動詞」に予約されていて、
Builder の終端はそれではない —— 旧綴りの最悪例が
`ArrayBuilder::freeze -> Array` で、**freeze の結果が可変**だった。

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
import @vibe/prelude { stdout_write }   // for hello() below

// Top-level named functions: `fn` (#727, ADR-0064). Full annotations
// required (param types + return type); recursion needs no `rec`.
fn add(x: Int, y: Int) -> Int { x + y }
fn fact(n: Int) -> Int {
  if n < 2 { 1 } else { n * fact(n - 1) }
}
fn identity[T](x: T) -> T { x }                // generic
fn show[T: Eq + Ord](x: T) -> T { x }          // trait bounds
fn hello() -> Unit with Stdout { stdout_write("hi\n") }
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

要素型が取れない配列は**参照等価に落ちる** — 消去された型変数 (`[T: Eq]` の
`T`)、関数の戻り値として受けた配列 (tuple ごと戻した場合も含む)、空リテラル
束縛 (`let xs = []`)。戻り値経由の配列を比較したいときは、いま確実なのは
要素を回すか `derive(Eq)` の struct field に入れる方法。
名前経由の**裸**配列が構造比較になるのは**要素がスカラー** (`Int` / `String` /
`Bool` / `Double` / `Char` / `Bytes` / `Unit`) のときだけ。それ以外は**参照等価に
落ちる** — 関数の戻り値として受けた配列 (tuple ごと戻した場合も含む)、空リテラル
束縛 (`let xs = []`)、消去された型変数 (`fn f[T](x: Array[T])` の `T`)、
配列の配列 (`[[1, 2]]` を名前経由で)、要素が struct/enum の裸配列。リテラルとして
書かれていれば入れ子も struct 要素も従来どおり構造比較される
(`[[1, 2]] == [[1, 2]]`)。名前経由でも効かせたいときは `derive(Eq)` の
struct field に入れるのが確実。

> **これは途中の状態**。ADR-0097 (#1526) は「`==` は**全文脈で構造的等価**」を
> 決定済みで、上の残りはそこへ向けた未実装分。文脈で答えが変わること自体が
> 潰す対象なので、この節の境界を覚えるのではなく、当たったら issue に足すこと。

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
(`import ./list.vibe { List, list_of3 }` makes `list_of3(1,2,3) |> length`
work). A BARE top-level `fn total(l: MyList)` is *not* a method: it keeps
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

`compose` / `identity` / `flip` live in the prelude (`lib/@vibe/prelude/func.vibe`);
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
> [`lib/@vibe/prelude/pipeline_ergonomics_test.vibe`](../lib/@vibe/prelude/pipeline_ergonomics_test.vibe)
> (`vibe test lib/@vibe/prelude/pipeline_ergonomics_test.vibe`). `tap` / `tap_some`
> and the combinators are prelude exports, so a file must `import` them and sit
> where it can reach the prelude — `import` paths may not escape the file's root
> directory, so standalone `examples/` files cannot reach `lib/@vibe/prelude/`.
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
for b in pull { b }            // async iterator (struct: next() -> Future[Option[(T,Self)]], await-driven) or a () -> Option[T] pull closure (-> None).
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
// separator was removed in 0.3.0 (parse error)
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
// derive(Default) -> T::default()
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
// trait: `[T: Send]` accepts primitives, tuples, Option/Result, and
// immutable structs/enums built from Send parts; Array/Bytes, closures,
// and `mut`-field structs are rejected. `impl Send for X` is an error.
```

### marker trait の impl は container には効かない (#1503)

**メソッドを持たない trait (marker trait) の impl は、`Array` / `Bytes` の
ような container に対して bound として使えない。** 宣言自体は通るが、
その型を bound 付きの関数へ渡すと拒否される:

```vibe skip
trait Eq                      // メソッド無し = marker trait
impl [T: Eq] Eq for Array[T]  // 宣言は通る

fn keep[T: Eq](x: T) -> T { x }
let bad = keep([1, 2, 3])     // reject される
```

理由は marker trait の**ディスパッチ先**にある。marker trait は builtin の
`==` / `<` に落ちる。`==` が配列を構造的に比較できるのは**要素型が静的に
分かるとき**だけ (下の「`Array` の `==`」参照) で、`keep[T: Eq]` の中の `T` は
消去済み — 要素型は無い。つまりこの impl を認めると `==` は参照等価に落ちて
黙って間違った答えを返す。診断がその旨を述べる。

> このゲートは ADR-0097 (`==` を全文脈で構造的等価に統一) の完了時に**解除
> される** — 根拠そのものが無くなるため。それまでは上の規則が有効。

container に対して効かせたいなら **trait にメソッドを持たせる** —
メソッドがあれば witness dictionary 経由でディスパッチするので、
concrete (`impl M for Array[Int]`) でも generic (`impl [T] M for Array[T]`)
でも解決する:

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

> #1503 以前は、**concrete な impl (`impl M for Array[Int]`) が method-bearing
> trait でも解決しなかった**。パーサが `for` の後ろの `[Int]` を捨てるため、
> 環境には `Array` という頭だけが残る。今は generic 版と同じく**コンストラクタで
> 照合する**ので両方の綴りが同じ挙動になる。裏を返すと、
> `impl M for Array[Int]` は今のところ `Array[String]` にも効く
> (パーサが型引数を保持していないため) — 特定の instantiation だけに
> 絞る書き方はまだ無い。

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
  ArrayBuilder::freeze(b)     // -> Array[Int]
}

// 汎用コンテナは @vibe/core — HashMap/HashSet (open addressing) と
// SortedMap/SortedSet (AVL、keys/to_array 昇順、range(lo, hi) 両端 inclusive)。
// 比較/ハッシュは関数を渡す explicit-dict 方式 + Int/String key 特化
// (HashMap::new_int() / SortedSet::new_string() 等)。
// 永続 (immutable) コレクションは @vibex/immut — 更新は常に新版を返し旧版不変
// (構造共有、0.4.0 並行モデルの sendable データ):
//   ImmutMap[V] (HAMT, String key): empty/set/get/delete/size/keys/has_key
//   ImmutArray[T] (persistent vector): empty/push/get/set/length/from_array/to_array

// 両端キュー / 優先度付きキューは @vibex/deque / @vibex/pqueue:
//   Deque::new/push_back/pop_front (ring buffer、両端 O(1))
//   PriorityQueue::new_int_min / new(cmp) (binary heap、cmp < 0 が先頭)

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

> **status (#760/#839):**
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
| host-provider metadata | host / provider outside the Wasm boundary | `Fs` `Http` `Socket` `Env` `Console` `Stdin` `Stdout` `Stderr` `Process` `Profiler` `Llm` |
| entry-boundary exception policy | entry boundary diagnoses an escaping exception | `Exception` / `Exception[E]` (`Error` was retired as a row spelling in #1461) |
| runtime scheduling policy | runtime itself | `Async` |

The ordered default and cache-safe owners preserve their existing output.
Checker row filtering and WIT import filtering use only the predicate-based
entry/runtime policy; WIT mapping and handler behavior are unchanged.

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
call to settle EOF. The pull-closure/`for` adapter remains blocked on transitive
higher-order effect evidence (#1536); do not treat `read_chunk` as directly
iterable. This surface is component-only (linear/RC); GC, standalone core,
`host_stream_named("stdin")`, and mixed named-provider composition are
rejected. Legacy `stdin_stream(chunk_size)` is standalone-capable and
unchanged.

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
handle { fetch_user(input) } with Exception[String] {
  Throw(msg) => "failed: \{msg}"
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
track. They are prelude exports (`lib/@vibe/prelude/io.vibe`); import them and
note they carry the `Stdout` effect. (`tap_ok` / `tap_err` were removed with
the prelude `Result` in #1324.)

<!-- doctest-skip: 未定義名 (x / next_stage / opt) を参照する構文提示の断片 -->
```vibe skip
x
|> tap((v) -> stdout_write("step: \{v}\n"))
|> next_stage

opt |> tap_some((v) -> stdout_write("got \{v}\n"))
```

### Error boundary (`throw` / `handle`)

```vibe
let risky: (Int) -> Int with Exception = (x) -> {
  if x == 0 { throw("division by zero") }
  100 / x
}

// handle catches the effect
let safe = handle { risky(0) } with Exception { Throw(msg) => -1 }
```

`throw(x)` は `perform Exception::Throw(x)` と等価 (#640)。`Exception` は再開不能
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
let n = handle { read_cfg() } with Exception[IoError] { Throw(_e) => 0 }
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
import @vibe/prelude { stdout_write }

effect Logger {
  Log(String) -> Unit
}

let greet: (String) -> Unit with Logger = (name) -> {
  perform Logger::Log("hello \{name}")
}

// the handler arm calls stdout_write, so the executable entry carries Stdout
fn main with Stdout {
  handle { greet("world") } with Logger {
    Log(msg) => {
      stdout_write(msg)
      resume(())         // continue where perform left off
    }
  }
}
```

継続呼び出しは `resume(v)` が canonical (one-shot tail-resumptive, ADR-0050)。
> **evidence-passing 実装 (#817, ADR-0076 追記34 V2 で replay 全廃)**:
> handler は evidence dict への直接呼び出し (tail-resumptive) か
> suspend CPS (first-class resume) にコンパイルされ、handle body は
> **常に一度だけ実行される** (旧 replay 実装の副作用重複と ~16K perform
> 上限は消滅)。代償として、handle body から届く perform は migration が
> 静的に追える形 (直接 perform / named top-level fn 呼び出し /
> row 注釈付き closure literal / let 束縛の local closure) に限られる —
> 追えない形 (row 変数 `with e` の callee 経由など) の非 Exception handle
> は **compile error** になる ("replay engine was removed")。

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
} with Async {
  Suspend(t) => {
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
`non-tail continuation binder (k-convention) is not supported by the build
path` と reject する (#814)。非 tail 継続は evidence-passing handler 移行
(#817) で対応予定。継続呼び出しは `resume(v)` を使う。
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
import ./lib.vibe { type MyType, trait Show }
import ./subdir { helper }   // directory import -> subdir/index.vibe(i)
import . { helper }          // own directory's index (same resolution)

// module blocks (`module Math { ... }`) are REMOVED (#728, ADR-0063):
// use file boundaries + import/export. `Type::method` / `Effect::Op`
// qualified access is an independent mechanism and remains.
```

Package refs: `@json`, `@lib/path` (hyphen/slash are part of name after `@`).
Qualified access: `Type::method`, `Module::name`.

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

**String**: byte string (`length`/indexes/slices use byte counts and offsets;
iteration yields byte-valued `Int`). `String::length`, `byte_at`, `from_byte`,
`concat`, `substring`, `contains`, `index_of`, `split`, `trim`, `replace`,
`starts_with`, `ends_with`, `join`. Unicode code-point/grapheme operations are
not part of this API.

**Array**: `Array::length`, `get`, `slice`, `map`, `filter`, `fold`, `find`, `any`, `all`, `reverse`, `concat`

**Map**: `Map::get`, `has_key`, `keys`, `values`, `set`

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

**SIMD スキャン** (`Bytes` / `String` 上を 16 バイト単位で走査。linear / gc 両対応):

| 関数 | 意味 |
|---|---|
| `simd_skip_ws(buf, pos, len) -> Int` | 空白でない最初の位置 |
| `simd_scan_alnum(buf, pos, len) -> Int` | 識別子バイトの終端位置 |
| `simd_scan_alnum_str(s, pos, len) -> Int` | 同上の `String` 版 |

> SIMD は linear memory 上でのみ成立する。`v128.load` はメモリアドレスを取る
> 命令で、wasm-gc の配列はアドレス可能なメモリではないため、`(array i8)` から
> v128 へ一括ロードする命令が存在しない。**バイト処理を速くしたいデータは
> linear memory (= `Bytes`) に置くこと。** `Bytes` は gc backend でも linear
> memory 上にあるので、これらは両レーンで同じように使える。

**I/O** (require effects):
<!-- doctest-skip: 未定義名 (s) + effect context 無しの呼び出しシグネチャ一覧 -->
```vibe skip
stdout_write(s)    // with Stdout
stdin_read_line()  // with Stdin
sh("ls -la")       // with Stdout - shell command
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

## Idioms

<!-- doctest-skip: 未定義名 (read_config / parse / process / risky / xs / parse_int 等) を参照するイディオム断片 -->
```vibe skip
// Failure composition: the row carries it, so stages just chain
// (fn read_config() -> Config with Exception[String] etc.)
let result = read_config() |> parse |> process

// Boundary at the edge
let value = handle { risky(0) } with Exception { Throw(_) => default_value }

// Builder pattern
let arr = {
  let b = ArrayBuilder::new()
  ArrayBuilder::push(b, 1)
  ArrayBuilder::push(b, 2)
  ArrayBuilder::freeze(b)
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
  in `lib/@vibex/blake3/simd.vibe`).
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

### `handle` は型検査を通っても**コンパイルできない**ことがある

適格性は型システムの一部ではないので、この失敗は**型検査そのものでは見えない**。
ただし **`vibe check` は #1511(b)/#1536(c) 以降、型検査の後に codegen と同じ
効き方の適格性判定 (ADR-0076 の effect-lowering prelude) を走らせる**ため、
`vibe check` / `vibe build` / `vibe test` / doctest のどれでも同じエラーが出る
(`vibe check --single-file` は単一ファイル解析なので対象外):

```
line 5:12-16: handle of effect 'Ask' cannot be compiled here. Every perform
this handle covers has to be statically visible to it, so the handled body may
only: perform directly, call a named top-level `fn`, or call a closure literal
that carries an effect row annotation. A call through a local binding or a
closure parameter hides the perform and is what this rejects (here: the call
to 'bump') ...
```

診断は**どの呼び出しが不適格かを名指しし、その `line:col` を指す** (#1514)。
`line:col` は handle ではなく犯人の呼び出し (上の例では `bump`) の位置。
複数ファイルで犯人が依存側モジュールにあるときは位置なしに落ちる
(entry ファイルの誤った行を指すより位置なしを選ぶ)。

実測した境界は **handled body が呼ぶ callee の種類**。handle 自体が top-level
`let` にあるか `fn` の中にあるかは**無関係**で、`ask_once` を `fn` で宣言したか
`let` lambda で宣言したかも**無関係**:

| handled body が呼ぶもの | 結果 |
|---|---|
| `handle { ask_once() }` — 直接 perform する関数 | ok |
| `handle { bump(ask_once()) }` — `bump` が top-level `fn` | ok |
| `handle { bump(ask_once()) }` — `bump` が**ローカルのクロージャ** | **NG** |

エラー文が列挙している適格な形がそのまま規則 — 直接 `perform`、**名前付き
top-level 関数**の呼び出し、row 注釈付きクロージャリテラル。

**迷ったら handled body から呼ぶものを top-level `fn` に出す。**

(この表は当初 lang-review r3 で「handle の位置が効く」と誤って記録し、r4 の
再測定で訂正した。#1511 のコメントに経緯。診断に位置情報が付かず、body 内の
どの呼び出しが不適格かも言わないので、複数呼び出しがある body では二分探索が要る。)

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

スカラ (`Int`/`String`/...)、`Option`/`Result`/tuple/`Array`、型が解決できない
値 (generic の `T` など) は対象外 — このパスが「レンダラが無い」と断言できる
のは宣言済みの集約型のときだけなので、それ以外は従来どおり。

### capability builtin の呼び出しは arity も引数型も検査されない (#1513)

**通ったことを正しさの証拠にしないこと。** これは compile も実行も成功して
garbage を出す:

```vibe skip
// doctest-skip: this is the silent miscompile the section documents
Stdout::write_stream(42)      // Int を String の位置に — 診断なし、実行も成功
Stdout::write_stream()        // 0 引数 — 診断なし、不正な wasm を吐く
```

未検査: `Stdout::*` / `Env::*` / `Stdin::*` / `Fs::read_file`。
検査あり: `Array::*` / `String::*` / `Bytes::*` / `Profiler::now_us` および
ユーザー定義関数 (`function arity mismatch ...` がスパン付きで出る)。

capability かどうかでは分かれない — checker の fast path に載っているかどうか。
host import が絡む呼び出しで挙動が変なときは、まず引数の数と型を目で確認する。

### 区切り文字は文脈で違う

```vibe skip
// doctest-skip: shows both separators side by side, including the rejected one
enum Shape { Circle(Int); Rect(Int, Int) }        // 宣言メンバは ;
let r = match s { Circle(r) => r, _ => 0 }        // match arm は ,
```

`,` を宣言メンバの区切りに使うのは 0.3.0 で削除済み。逆に match arm を `;` で
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
row は ambient row (`{ Fs, Env, Stdin, Stdout, Stderr, Console, Process,
Profiler, Error, Exception }`) を**置換ではなく拡張**する — `with Http` を
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

`x?` (optional) は**パーサが受理するだけで semantics は未実装** (#1500)。
省略すると `arity mismatch`、body 内では `Option[T]` ではなく `T` に束縛される。

### `Error` は effect の綴りとしては退役、operation 修飾子としては生存

上の "Error boundary" 節を参照。row 位置 (`with Error`) と handle する effect 名
(`handle .. with Error`) はどちらも parse error、`perform Error::Throw(x)` は
今も通る。

## File Conventions

| File | Purpose |
|------|---------|
| `*.vibe` | Source |
| `*.vibex` | Executable root; exactly one `fn main`, not importable (ADR-0075 target contract) |
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

*Full reference: [docs/spec/syntax.md](spec/syntax.md) / [syntax-reference.md](language-tour/syntax-reference.md) / [language-tour/](language-tour/)*
