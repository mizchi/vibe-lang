# 02 — A small program

Previous: [Installation and Hello, vibe](01_getting_started.vibe.md)

日本語版: [02_a_small_program.vibe.md](../ja/02_a_small_program.vibe.md)

Hello world tells you the toolchain works. It does not tell you whether
the language is worth learning. So before any tour of syntax, here is a
program that does something: a calculator over expression trees, which
evaluates them, prints them back, and copes with division by zero.

It is about forty lines, and you have not been taught any of it yet.
Read it as a whole; the rest of the book fills in the pieces.

```vibe run
enum Expr {
  Num(Int);
  Add(Expr, Expr);
  Mul(Expr, Expr);
  Div(Expr, Expr)
}

fn eval(e: Expr) -> Int with Exception {
  match e {
    Num(n) => n,
    Add(a, b) => eval(a) + eval(b),
    Mul(a, b) => eval(a) * eval(b),
    Div(a, b) => {
      let d = eval(b)
      if d == 0 {
        throw("divide by zero")
      } else {
        eval(a) / d
      }
    }
  }
}

fn show(e: Expr) -> String {
  match e {
    Num(n) => Int::to_string(n),
    Add(a, b) => "(\{show(a)} + \{show(b)})",
    Mul(a, b) => "(\{show(a)} * \{show(b)})",
    Div(a, b) => "(\{show(a)} / \{show(b)})"
  }
}

fn report(e: Expr) -> String {
  handle {
    "\{show(e)} = \{eval(e)}"
  } with Exception {
    Throw(message) => "\{show(e)} failed: \{message}"
  }
}

fn main with Console {
  println(report(Add(Num(2), Mul(Num(4), Num(10)))))
  println(report(Div(Num(84), Num(2))))
  println(report(Div(Num(1), Add(Num(3), Num(-3)))))
}
```

```output
(2 + (4 * 10)) = 42
(84 / 2) = 42
(1 / (3 + -3)) failed: divide by zero
```

## What you just used

**A tree, described once.** `enum Expr` lists the four shapes an
expression can have, and `Div(Expr, Expr)` refers to `Expr` while
defining it. `match` then takes the tree apart; if you add a fifth shape
and forget to handle it, the compiler tells you which function is now
incomplete instead of picking a branch at runtime.
→ [Structs, enums, and match](07_data.vibe.md)

**A function that admits it can fail.** `eval` is written
`-> Int with Exception`. The `with Exception` is not documentation: any
caller either passes the possibility along or deals with it, and the
compiler decides which. `report` deals with it, so `report` returns a
plain `String` — the failure stops there.
→ [Effects](13_effects.vibe.md)

**`main` says what it is allowed to do.** `fn main with Console` is
permission to write to the terminal, and it is the *only* thing this
program may do. It cannot read a file or open a socket, because it never
asked to.
→ [Capabilities](14_capabilities.vibe.md)

That last point is the one worth pausing on. In most languages, "this
function prints" and "this function can fail" are facts you discover by
reading the body, or by being surprised in production. Here they are in
the signature, the compiler checks them, and they compose: a function
that calls `eval` and `println` needs both.

## Make it yours

Two changes that stay small and teach the most:

1. **Add `Sub(Expr, Expr)`.** Add the variant and compile without
   touching anything else — the errors point at every `match` that now
   has a hole.
2. **Make division truncate toward zero explicitly**, or fail on
   negative divisors too. Note that you change `eval` and nothing about
   `report` — the failure channel was already declared.

Next: [Values and functions](03_values_functions.vibe.md).
