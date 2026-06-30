# Selfhost RC cutover readiness (ADR-0055 #493)

Status: **READY (re-assessed 2026-06-29, #702 complete).** The broader 8-program
probe (`scripts/rc_cutover_readiness.sh`) now passes in full — every program
compiles under RC with result parity and bounded heap. Getting there fixed three
pre-existing RC gaps the original narrow corpus missed (#702): a `not EFn`
RC-compile error on `let x = if/match {...}` and on closures passed to
higher-order fns; capturing closures passed as arguments leaking; and a recursive
-enum match-destructuring double-free that trapped at scale. See "Broader-corpus
assessment". Measures
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

**Verdict (narrow corpus): READY.** RC compiled every program in this original
6-program corpus with result parity and 0 B/iter. But this corpus was too narrow —
see below. (The script that produced this table was not committed at the time, so
the exact programs are not reproducible; the table is kept for history.)

## Broader-corpus assessment (`scripts/rc_cutover_readiness.sh`, 2026-06-29)

The probe is now a committed, runnable script with a wider 8-program corpus
(`bash scripts/rc_cutover_readiness.sh`, N1=1000 N2=11000, via the FS-compile
path that `vibe run` uses). Result:

| program | mixes | rc compiles | parity | rc heap N1/N2 | bounded |
|---------|-------|:-----------:|:------:|--------------:|:-------:|
| tuple             | tuple per iter | yes | OK | 32 / 32 | yes |
| record_tuples     | struct of tuples | yes | OK | 96 / 96 | yes |
| captured_mut_cell | `let mut` captured by a closure (#699) | yes | OK | 40 / 40 | yes |
| nested_closures   | closure capturing a closure + mut | yes | OK | 64 / 64 | yes |
| enum_ast          | enum AST + recursive match, dropped each iter | yes | OK | 136 / 136 | yes |
| option_enum       | `let o = if … { Som } else { Non }` | yes | OK | 40 / 40 | yes |
| mixed             | `let b = if … { Box } else { Box }` (struct{enum;tuple}) | yes | OK | 120 / 120 | yes |
| hof               | closure passed to a higher-order fn | yes | OK | 24 / 24 | yes |

**Verdict: READY.** All 8 programs compile under RC, results match the default
backend, and RC heap is bounded (constant across N1/N2). Getting here closed
three pre-existing RC gaps the narrow corpus missed (#702), each of which also
reproduced on the source-compile RC path (independent of #699/#701):

- **`not EFn` RC-compile error** (was: option_enum, mixed, hof) — the RC ELet
  classification ran `efn_is_capturing` (→ `get_efn_params`) on every non-heap
  `let` value because `&&` evaluates both operands; `let x = 5` / `let x = if…`
  threw. Fixed by guarding with a nested `is_efn` check (`6632ff2`).
- **capturing closure passed to a HOF leaked** (was: hof) — function-typed params
  were classified non-heap so the callee never dropped them. Fixed by treating a
  bare function type as heap (`22ecfa8`).
- **recursive-enum match double-free trap at scale** (was: enum_ast) — a matched
  ctor field shared the scrutinee's refcount, so consuming the field and the
  scrutinee's recursive drop freed the same block twice. Fixed by dup-ing matched
  fields on extraction (`c085e66`).

Known minor follow-up: a matched heap field bound but **unused** now leaks (dup
with no consuming drop) — safe over-keep, rare (use `_`). The leak-guard gate
(`selfhost_only_gate.sh` step 40d) exercises tuple+cell+closure+recursive-enum
and asserts bounded heap, locking these in against regression.

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

## Whole-compiler RC compile + the RC-vs-default parity gate

`compile_wasi_rc` applied to the **entire merged compiler source**
(`selfhost_cli_adapter_merged_source`, entry `cli_main`), executed on the host
MoonBit runtime, runs to completion with no error — i.e. **no RC codegen gap
across any construct the compiler itself uses**.

The stronger signal is to drive the compiler's *real* self-compile vehicle —
the module-source + source-groups path (`build_selfhost_cli_adapter_bytes`,
entry `cli_main`) — through **stage1** (the selfhost compiler, itself compiled to
wasm). `scripts/test_selfhost_rc_bootstrap.sh` does this under both backends via
new entries `selfbuild_compile_cli_adapter_env` (default) and
`selfbuild_compile_cli_adapter_rc_env` (RC, on the new
`compile_with_source_groups_via_module_source_wasi_unchecked_rc` path), and
asserts **RC-vs-default parity**: RC must reach exactly as far as default. The
gate auto-upgrades to a full whole-compiler-under-RC green signal once the
default-path ceiling below is lifted.

**Measured result (2026-06): parity holds.** Both backends reach the *identical*
point — they fail together at `no functions found to compile`, a **default-path**
stage1 limitation in the source-group merge, **not** an RC issue. This is the
cutover-safety invariant we needed: **RC introduces no compile gap at full
compiler scale that the default bump path does not already have.**

### Default-path blockers found driving the first stage1 whole-compiler self-compile

This was the first time stage1 was asked to compile the *whole* compiler (prior
gates compile only small samples or a stub), so it surfaced several pre-existing
**default-path** selfhost limitations. Two were real source bugs and are fixed:

1. **Newline-separated struct fields** — `struct HeapInferCtx { ctors: …\n
   heap_fns: … }` (no `;`). The host MoonBit parser is lenient; the selfhost
   parser only accepts `;`/`,`/`}` as field separators, so stage1 threw
   `expected ';', ',' or '}' in struct`. Fixed by using `;` (the convention
   every other struct already follows).
2. **Struct-literal field punning** — `PerceusAction::{ kind, name }` (shorthand).
   The selfhost parser mis-parses punned fields and runs into the next token
   (`unexpected token: ->`), per the CLAUDE.md gotcha. Fixed by writing explicit
   `kind: kind, name: name`.

Remaining (tracked separately from RC, all default-path):
- **`no functions found to compile`** in the source-group merge at full scale —
  the current shared ceiling both backends hit.
- **Checker/parser recursion depth** — stage1's recursive-descent parser and
  `env_lookup` overflow the host stack on the ~640 KB self-source; the gate runs
  node with `--stack-size=16000` to push past parse/check before the shared
  ceiling.

## Cutover toggle: `VIBE_RC=1`

The cutover-enabling plumbing (not the default flip itself): the **argv / env
compile entries** route through the RC codegen when `VIBE_RC=1` (env; unset → the
bump default is unchanged). `compile_source_wasi_only_rc`
(`entry/source_compile/wasi_only/preprocess_compile.vibe`) mirrors
`compile_source_wasi_only` on `compile_wasi_module_rc_impl`; `cli_main`
(`selfhost_cli_adapter.vibe`) and `selfbuild_cli_args_entry` (`index.vibe` — the
entry the **cli-adapter** gate uses) consult `VIBE_RC`.

End-to-end verified: the stage1 wasm-compiled selfhost compiler, invoked via
`selfbuild_cli_args_entry` with `VIBE_RC=1`, compiled a real RC-relevant program
(enum `Option` with a nullary variant in an `if`, a closure, tuples) to **valid
wasm that runs to the same result as the default path** (17 == 17):

```bash
# the cli-adapter gate's sample input compiled through the RC path:
VIBE_RC=1 bash scripts/test_selfhost_cli_adapter.sh
```

**Not yet RC-routed (remaining cutover wiring).** The full selfbuild
(`scripts/test_selfhost_wasi_selfbuild.sh`) does *not* honor `VIBE_RC`: its
recursive stage uses `selfbuild_compile_stage2` (`index.vibe`), which calls
`compile_source_wasi_only` unconditionally and has no `Env` effect to read the
toggle. Routing the bootstrap self-build through RC (add `Env` to
`selfbuild_compile_stage2` + its two test callers, branch on `VIBE_RC`) is the
next step before that command can be advertised as an RC bootstrap gate.

The actual #493 cutover is then flipping the default (unset `VIBE_RC` → RC) once
the RC bootstrap gate is green and the throughput tradeoff is signed off.
