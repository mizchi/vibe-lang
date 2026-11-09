# Checked local annotation calls (#1978)

## Boundary and classification facts

Current main already removes the identity call on the linear backend (#3413).
The remaining production GC emitter still registers and calls an identity
lambda. The parser's `ascribe_wrap` always supplies no type parameters, bounds,
return annotation or effect, exactly one annotated parameter, and its own
identifier as the body. Both code generators and linear lambda planning now
use one predicate in `core/expr_children.vibe` for that shape. GC registers
lambda bodies as it emits them, so skipping the identity also skips its table
slot. The argument is evaluated once.

Checked annotations remain in the AST until the classification/ownership
analyses have consumed them. The existing `cc_own_cell_compound_args` conversion
and borrowed/projection/loop retains on the linear lane are unchanged. The
unwired structural eraser is not enabled. This is the emission boundary allowed
by #1978's original safety comment, not an assertion that annotation syntax no
longer occupies any frontend or lowering memory.

| Consumer | Source of the fact |
| --- | --- |
| Bool, String, Float64/Float32 codegen classification | The exact checked identity marker's annotation, plus existing checker result channels; never an ordinary lambda's input type |
| Desugaring's call-result head | The declared result or an independently proved unary identity's parameter type; a callee-owned formal is not a caller type identity |
| Caller type formals and trait witnesses | Preserve the enclosing formal's name: withholding it loses the Eq witness on annotated fields and loop items |
| Aggregate equality and ownership | Keep the existing annotation-bearing AST through analysis; preserve the owning-call conversion and retain decisions |
| Linear lambda plan / both emitters | The same core identity predicate |

The classification audit found a supported ordinary Bool-parameter lambda
returning Int was rendered as `true` instead of `42`. A String-parameter case
was classified from its input too. Scalar predicates and desugaring now refuse
that substitution. Generic lambda result formals named Bool/String are not
concrete builtin results. The regression matrix includes those cases and the
caller-formal witness cases a selected set alone missed.

Ordinary unary identity IIFEs retain their result head even without a written
return type: `((x: S) -> x)(s).read()` and a let-bound result both resolve
`S::read`. This is separate result inference: an ordinary identity keeps its
call and lambda slot. A nonidentity body cannot borrow its input head, and
a callee-owned formal is still withheld.

## Measurements (2026-11-09 JST)

The production FS micro probe calls a nonliteral `source()` and returns 42 in
all 48 before/after executions. On GC the annotated program falls from five
defined functions / 478 bytes to four / 406 bytes (code section 215 to 159
bytes). Its complete Wasm is identical to the unannotated control. The linear
backend already emitted identical annotated/unannotated Wasm: 80 functions /
787 bytes, unchanged here. The GC runtime's exported linear heap pointer stays
72: this is a call/table-slot and size improvement, not evidence of reduced
managed-GC allocations. Micro timings include process startup.

The real rejection control runs the unfixed compiler on both sides: all 48
programs still return 42, but the equivalence check fails because the GC
annotation still adds one function. This checks that the probe can reject the
original production defect, using the same measurement-script hash.

The full compiler closure (`codegen_lexer_test.vibe`) and CLI adapter were each
compiled cold and warm, N=3, in alternating AB/BA/AB order. Both compilers
consume the same current source. Literal compiler/cache/output paths are
identical; caches are isolated by lane and round. RC is off, checked-module
cache is off, and experimental AST/ingestion caches are off. No build, test or
archive ran alongside these measurements. All outputs agree byte-for-byte
between before/after and across all rounds.

| Workload | Before heap_ptr (B) | After heap_ptr (B) | Delta | Before wall (s) | After wall (s) | Delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Compiler closure cold | 1,169,663,672 | 1,169,724,728 | +0.0052% | 8.520 | 8.523 | +0.03% |
| Compiler closure warm | 645,452,672 | 645,498,744 | +0.0071% | 4.621 | 4.628 | +0.13% |
| CLI cold | 2,543,101,104 | 2,543,236,408 | +0.0053% | 17.588 | 17.609 | +0.12% |
| CLI warm | 1,383,116,104 | 1,383,211,488 | +0.0069% | 10.150 | 10.137 | -0.12% |

These wall deltas do not establish a whole-build speedup. The tiny deterministic
heap-pointer increase is reported rather than rounded to a memory win. The
counter includes the static base and cumulative bump allocation, not peak live
memory or RSS. A GC runtime linear-heap counter excludes managed GC objects.
The result justifies removing the remaining GC identity call and fixing unsafe
classification; it does not claim that frontend annotation storage was erased.

Host: WSL2 Linux 6.18.54.1, Ryzen 7 7700 (8 cores / 16 threads), Node 24.7.0.
Baseline revision: `7e810fce887734c0cc0b78232c15f5d9b1c660f3`.
Baseline compiler SHA-256:
`c5d7082472c59dcf50eb394cf29c65d031bb48a43acafe9152efd1060844e13b`.
Final compiler SHA-256:
`9e6228868d8ad0308b49905d70e14abffbd09c7339006b10180fc038468ce6b8`.
The receipts carry the staged source tree and artifact/runner hashes; final
report files were added after measuring, without changing compiler sources.

Raw receipts: [micro](micro-cost.json), [full closure/CLI](compile-cost.json),
[real rejected control](micro-rejection.json), [local validation](validation.json).

## Validation and reproduction

The seed-built final stage2 and stage3 are byte-identical. The full current
checkout corpus passes **2,027/2,027 files**, using that explicit compiler with
output cache disabled and RC enabled. The [19-file targeted matrix](targeted-files.txt)
passes 357 tests each in bump, RC and shadow, plus real GC execution of the
ascription fixture. GC byte-equality unit probes cover ordinary, repeated and
mutable annotated bindings. A changed GC expectation was verified to fail with
actual 42 versus expected 99, proving the body executes.

The historical regression list has eight surviving enum equality suites.
`cst_nodekind_eq_test.vibe` and the prototype CST it tested were deleted in
#3335 (`b0530645e`); no obsolete implementation is restored and no exclusions
are added. The baseline above and checkout corpus are pinned; CI additionally
tests the PR with its current merge base.

Build both explicit compiler images from their respective source trees using
`scripts/ensure_generated.sh` and `scripts/generations.sh build --stage3`, and
check stage2 against stage3. Stage the final source before measuring (the
integration harness snapshots the index). Then, from the candidate checkout:

```sh
# BEFORE and AFTER are absolute paths to the explicitly built stage2 images.
# Each measurement output directory must not already exist.
python3 bench/perf/experiments/ascription-1978/measure_micro.py \
  "$BEFORE" "$AFTER" _build/ascription-micro
python3 bench/perf/experiments/invocation-checked-cache-1953/measure_integration.py \
  "$PWD" "$PWD" "$BEFORE" "$AFTER" _build/ascription-cost --same-source
VIBE_STAGE2_WASM="$AFTER" VIBE_UNIT_OUT_CACHE=0 VIBE_RC=1 \
  bash scripts/unit_test_runner.sh
# A real negative control must exit nonzero and record status=fail, 48 rows,
# actual answer=42 in every row, and a GC-after function-count mismatch:
python3 bench/perf/experiments/ascription-1978/measure_micro.py \
  "$BEFORE" "$BEFORE" _build/ascription-rejection
```
