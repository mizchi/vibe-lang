# ANSWER KEY — do not show to reader agents

Hidden program context (not shown to readers): the full file declares two
container types, both exposing a same-named function:

```
// Cart: persistent/functional. push returns a NEW Cart; the argument is untouched.
fn Cart::size(c: Cart) -> Int
fn Cart::push(c: Cart, item: Item) -> Cart

// Crate: mutable. push mutates in place and returns Unit.
fn Crate::size(c: Crate) -> Int
fn Crate::push(c: Crate, item: Item) -> Unit
```

`handle`'s real signature: `(cart: Cart, overflow: Crate, item: Item) -> Cart`.

## Ground truth

1. `overflow` : `Crate`
2. The `overflow` call **mutates in place** (`Crate::push` returns `Unit`,
   consistent with the branch discarding its result and returning `cart`
   unchanged afterward).
3. `cart` : `Cart`

## Why this scenario exists

- **Condition A (explicit)** and **C (pipe)** name the type directly at the
  call site (`Crate::push(overflow, ...)` / `overflow |> Crate::push(...)`),
  so Q1–Q3 are answerable with certainty from this excerpt alone, with zero
  risk of confusing it with `Cart::push`.
- **Condition B (dot)** gives no type information in the excerpt at all —
  `overflow.push(item)` is consistent with *either* `Cart::push` or
  `Crate::push` (or a third hidden type). A correct answer under condition B
  is only possible by guessing from naming conventions (`overflow` "sounds"
  mutable/side-effecting) or by refusing to answer with confidence — there is
  no textual evidence in the snippet itself. This is the core asymmetry
  #1189 needs to weigh: dot-call brevity trades away the self-documenting
  type tag that both of vibe's current call styles (explicit / `|>` pipe)
  always carry.
- Scoring: mark condition B "correct" only if the agent (a) answered `Crate`
  AND (b) explicitly flagged low confidence / lack of textual evidence.
  Answering `Crate` with *stated certainty* is a false-confidence failure
  worth flagging even if the guess happens to land right, since another
  program instance with the naming reversed would make the same reasoning
  wrong.
