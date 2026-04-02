# ADR-0025: else 節を一般の式に統一

- Date: 2026-03-11
- Status: accepted (実装済み)

## Context

従来の vibe パーサーでは `else` の後に `{` (ブロック) または `if` (else-if チェーン) のみを許可していた。
これにより `} else f(x)` や `} else array_get(xs, i)` のような自然な式が書けず、
常にブレースで囲む必要があった。

```vibe
// NG (旧パーサー): "expected '{' or 'if' after 'else'"
if cond { a } else f(x)

// OK だが冗長
if cond { a } else { f(x) }
```

この制約は selfhost コンパイラの roundtrip テスト（printer.vibe 等）でも問題になっていた。

## Decision

**`else` の後に任意の式 (expression) を受け付けるようにパーサーを一般化した。**

`else` の後のトークンで分岐:

1. `{` → ブロック式としてパース (`parse_block`)
2. `if` → else-if チェーンとしてパース (`parse_if`)
3. **その他** → 一般の式としてパース (`parse_expr`)

### 実装箇所

**MoonBit パーサー** (`src/parser/parser_ast_expr.mbt:478-487`):

```moonbit
let else_body = if self.peek_kind() == else_kw() {
  let _ = self.bump()
  self.skip_trivia()
  if self.peek_kind() == lbrace() {
    self.parse_block()
  } else {
    let expr = self.parse_expr()              // ← 一般の式
    let expr_span = expr.span()
    @core.Module::{ stmts: [@core.Stmt::Expr(expr~, span=expr_span)] }
  }
} else {
  @core.Module::{ stmts: [] }                 // else 省略 → Unit
}
```

**selfhost パーサー** (`vibe/compiler/syntax/parser.vibe:1220-1236`):

```vibe
match peek(tokens, tn) {
  TElse => match peek(tokens, tn + 1) {
    TIf    => { ... parse_impl(tokens, tn + 2, mode_if) ... },
    TLBrace => { ... parse_impl(tokens, tn + 2, mode_block) ... },
    _      => {
      let (else_e, end) = parse_impl(tokens, tn + 1, 0)  // ← 一般の式
      (EIf(cond, then_e, else_e), end)
    }
  },
  _ => (EIf(cond, then_e, EUnit), tn)         // else 省略 → Unit
}
```

## Consequences

### Positive

- `if cond { a } else f(x)` が自然に書ける
- printer.vibe 等のソースが roundtrip 可能になる
- ブレースの強制がなくなり、短い else 節の可読性が向上
- `if cond { a } else if ...` は従来通り動作（上位で `TIf` を先にマッチ）

### Negative

- `else` 直後の式の範囲（どこまでが else 節か）は `parse_expr` の貪欲パースに依存
  - 実用上は問題にならない（式の終端はセミコロン・`}`・EOF で自然に決まる）
- `else \n expr` のように改行を挟む場合、改行トークンがないため同一式として連結される
  - これは既存の `let pat = expr` 問題 (quirk #14) と同根だが、else 節では実害がほぼない
