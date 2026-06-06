# Selfhost RC cutover readiness (ADR-0055 #493)

Status: **READY (2026-06)** on the realistic corpus below — the one blocker found
by the assessment (nullary enum ctors outside RC reclaim) has been fixed. Measures
whether the selfhost Perceus RC path is ready to become the selfhost linear
default (cutover, #493 C/F). The reclaim
suite (`scripts/verify_selfhost_rc.sh`) and heap-e2e gate exercise RC features in
**isolation**; cutover needs realistic code that **mixes** them. The probe
`scripts/rc_cutover_readiness.sh` compiles a corpus of feature-combined,
allocation-heavy programs (each a parameterised `main(n)` loop returning a
checksum) both ways — default linear (bump, leaks) and Perceus RC — and reports,
per program: does RC compile+validate, default==RC result parity, and the
per-iteration heap growth of each.

## Result (N1=1000, N2=11000) — after the nullary-ctor fix

| program | what it mixes | rc compiles | parity | def B/iter | **rc B/iter** |
|---------|---------------|:-----------:|:------:|-----------:|--------------:|
| eval    | enum AST + recursive match (compiler-like) | yes | OK | 56 | **0** |
| record  | struct of tuples | yes | OK | 0 | **0** |
| hof     | closure passed to a higher-order fn | yes | OK | 16 | **0** |
| clos    | nested capturing closures + array | yes | OK | 108 | **0** |
| opt     | `Option`-like enum (`Som`/`Non`) in an `if` | yes | OK | 20 | **0** |
| mixed   | struct `{ enum; tuple }` + match | yes | OK | 56 | **0** |

**Verdict: READY.** RC compiles every realistic combination, results are identical
to the default backend (correctness holds on mixed-feature code), and heap is
bounded (0 B/iter) for **all 6** — including a compiler-shaped enum AST evaluator,
deeply-nested capturing closures, and an `Option`-like enum. The probe prints
`READY`.

## The fix that landed: nullary enum constructors are now RC blocks

Initially `opt` leaked 4 B/iter (one 8-byte block on the `Non` half). Isolated, a
nullary ctor leaked 8 B/iter while a payload ctor reclaimed:

| pattern | rc B/iter (before) | rc B/iter (after) |
|---------|-----------------:|-----------------:|
| `let o = Som((i, i+1)); … u(o)` (payload ctor) | 0 | 0 |
| `let o = Non; … match o { … }` (nullary ctor)  | **8** | **0** |

**Root cause**: a nullary constructor bump-allocated an **8-byte, unheadered**
block straight off the heap pointer, **not** via `__rc_alloc`, even under RC —
no `alloc_size`/`rc_count`/drop-class byte, so it sat entirely outside RC reclaim
and `__rc_drop` could not be run on it. The `let o = Non` binding was also not
classified heap (the ELet classification used `is_ctor_call`, which only matches
an `ECall`, not the bare `EIdent` of a nullary ctor).

**Fix** (Option 1 — header-ize, the lower-risk path):
- `compile_expr.vibe` nullary-ctor branch: under RC, allocate a headered block
  via `__rc_alloc` — `[alloc_size@0=16][rc_count@4=1][drop-class@7=1][tag@8]
  [field_count@12=0]`, value `(block+8)|1`. The tag sits at value+0 exactly like
  a payload ctor, so enum `match` (which reads the tag at value+0) is unchanged.
  The default (non-RC) path keeps the unheadered bump form.
- `is_nullary_ctor_ident` (`common_base/index.vibe`) classifies a bare ctor
  `EIdent`; the two ELet/ELetMut RC heap-classification sites now use it, so a
  `let o = Non` binding is heap and dropped at scope end. The recursive
  `__rc_drop` reads drop-class 1 with field_count 0 → recurses nothing, frees the
  block.

Pinned by the `nullary_ctor` reclaim case (0 B/iter) and a heap-e2e parity case
(`Option`-in-`if` mixing both variants, default == RC).

## Reproduce

```bash
bash scripts/rc_cutover_readiness.sh            # N1=1000 N2=11000
bash scripts/rc_cutover_readiness.sh 1000 101000  # tighter per-iter signal
```

The probe now prints `READY` on this corpus — a green light for the #493 cutover
on realistic mixed-feature code, alongside the existing reclaim gate. The residual
*safe* leaks documented in `selfhost-uniform-value-repr.md` (escaping lambdas,
deep-projection opaque args, container-outlives-scope) do not appear in this
corpus; the remaining cutover work is the mechanical default→RC switch itself
(#493 C/F) plus any wider-corpus measurement.
