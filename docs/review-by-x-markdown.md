# Vibe Language Review: Lessons from vibe/x/markdown

Feedback from implementing a block-level markdown parser, serializer, and code block extractor in vibe.

## String concatenation operator (#7)

Writing `String::concat(String::concat(a, b), c)` for multi-part string concatenation is painful. String interpolation `"\(a)\(b)\(c)"` helps but isn't always natural (e.g. building strings in loops).

If `+` overloading with Int causes type inference issues, a dedicated operator like `++` or `<>` would work.

## Forward references (#8)

The biggest structural pain point. Functions must be defined before they are referenced, forcing manual dependency ordering. Mutual recursion is impossible.

`parse` → `parse_blocks` → `serialize` → `serialize_block` all had to be carefully ordered. Rust-style file-scoped forward references would eliminate this.

## String equality via == (#9)

String comparison requires `String::equals(a, b)` instead of `a == b`. Every string comparison in the parser needed the verbose form. Trait-based `==` dispatch (Eq for String) would be the natural fix.

## let rec reliability (#10)

`let rec` works for simple recursive functions but shows inconsistent behavior with large function bodies (~150 lines). The same function works when called via one path but fails via another, suggesting scoping or closure capture issues.

## while + continue semantics (#11)

`continue` in `while` loops skips the manual increment (`i += 1`), causing infinite loops. Every `continue` requires careful `i += 1` before it. A C-style `for` with an update expression would solve this, or clearer documentation of `continue` semantics.

## ArrayBuilder verbosity (#12)

The ArrayBuilder pattern (new/push/freeze) is functional but verbose. `vibe/x/markdown` creates ~20 builders. Method call syntax (`buf.push(item)`) or mutable arrays would reduce boilerplate.

## Priority

1. String concatenation operator (`+` or `++`) — #7
2. Forward reference support — #8
3. `==` for String (trait dispatch) — #9
4. `let rec` reliability — #10
5. `while`/`continue` semantics — #11
6. ArrayBuilder verbosity — #12
