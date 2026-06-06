# Selfhost RC cutover readiness (ADR-0055 #493)

Status: **assessment, 2026-06**. Measures whether the selfhost Perceus RC path is
ready to become the selfhost linear default (cutover, #493 C/F). The reclaim
suite (`scripts/verify_selfhost_rc.sh`) and heap-e2e gate exercise RC features in
**isolation**; cutover needs realistic code that **mixes** them. The probe
`scripts/rc_cutover_readiness.sh` compiles a corpus of feature-combined,
allocation-heavy programs (each a parameterised `main(n)` loop returning a
checksum) both ways — default linear (bump, leaks) and Perceus RC — and reports,
per program: does RC compile+validate, default==RC result parity, and the
per-iteration heap growth of each.

## Result (N1=1000, N2=11000)

| program | what it mixes | rc compiles | parity | def B/iter | **rc B/iter** |
|---------|---------------|:-----------:|:------:|-----------:|--------------:|
| eval    | enum AST + recursive match (compiler-like) | yes | OK | 56 | **0** |
| record  | struct of tuples | yes | OK | 0 | **0** |
| hof     | closure passed to a higher-order fn | yes | OK | 16 | **0** |
| clos    | nested capturing closures + array | yes | OK | 108 | **0** |
| opt     | `Option`-like enum (`Som`/`Non`) in an `if` | yes | OK | 20 | **4** |
| mixed   | struct `{ enum; tuple }` + match | yes | OK | 56 | **0** |

**Verdict: nearly ready.** RC compiles every realistic combination, results are
identical to the default backend (correctness holds on mixed-feature code), and
heap is bounded (0 B/iter) for **5 of 6** — including a compiler-shaped enum AST
evaluator and deeply-nested capturing closures. One concrete gap remains.

## The remaining blocker: nullary enum constructors are outside RC reclaim

`opt` leaks **4 B/iter** (= one 8-byte block on the `Non` half of the iterations).
Isolated:

| pattern | rc B/iter |
|---------|----------:|
| `let o = Som((i, i+1)); … u(o)` (payload ctor) | 0 |
| `let o = Non; … match o { … }` (nullary ctor)  | **8** |

**Root cause** (`vibe/compiler/codegen/expr/compile_expr.vibe`, the nullary-ctor
`EIdent` branch): a nullary constructor bump-allocates an **8-byte, unheadered**
block straight off the heap pointer (`global 0`), **not** via the `__rc_alloc`
free-list, even under RC. It writes `[tag@0][0@4]` and returns `ptr | 1` (the
value points at the block *start*, with no 8-byte uniform header). Payload ctors,
by contrast, allocate a headered block via `__rc_alloc` and return `(block+8)|1`.

Consequences:
- The nullary block carries no `alloc_size` / `rc_count` / drop-class byte, so the
  recursive `__rc_drop` cannot be run on it (it would misread bytes before the
  value as a header). So it **cannot** simply be classified heap and dropped.
- Separately, the `let o = Non` binding is not even classified heap: the ELet
  RC classification (`compile_expr_tail.vibe`) uses `is_ctor_call` (an `ECall`
  with a callee), but a nullary ctor is a bare `EIdent`, so it never enters the
  heap-binding set.

This is a common shape (`None`/`Nil`/`Empty` in `Option`/`Result`/list-like
enums), so it must be closed before cutover.

### Fix options (next task)

1. **Header-ize nullary ctors under RC**: allocate via `__rc_alloc` with the
   uniform header + a no-recurse drop-class, return `(block+8)|1`, classify the
   `let` binding heap (extend the ELet/`is_heap_value` classification to nullary
   ctor `EIdent`s), and verify the enum-`match` tag read still lands (match reads
   the tag at a value-relative offset — must stay consistent with payload ctors).
   Drop-in with the existing recursive free path; ~one more reclaim case.
2. **Immediate-ize nullary ctors**: represent a payload-less variant as an even
   tagged immediate (`(tag<<k)|2`, like capture-less closures) so it never
   allocates — no block, no leak. Smaller heap, but changes enum `match` codegen
   to distinguish immediate (nullary) from headered (payload) variants in every
   arm; larger blast radius.

Option 1 is the more localized, lower-risk path and is recommended.

## Reproduce

```bash
bash scripts/rc_cutover_readiness.sh            # N1=1000 N2=11000
bash scripts/rc_cutover_readiness.sh 1000 101000  # tighter per-iter signal
```

Once the nullary-ctor gap is closed, `opt` should read 0 B/iter and the probe
prints `READY` — the green light for the #493 cutover (alongside the existing
reclaim gate and the residual *safe* leaks documented in
`selfhost-uniform-value-repr.md`, which do not appear in this realistic corpus).
