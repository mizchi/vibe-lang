# The RC cutover (ADR-0055, #493)

```
linear-default: RC
```

That line is the fact this document exists to record, and
`scripts/check_rc_default.sh` (`pkf run check-rc-default`) reads it. The gate
compiles the same program three ways — `VIBE_RC` unset, `VIBE_RC=1`,
`VIBE_RC=0` — and fails if the line above disagrees with which artifact the
unset build is byte-identical to. Measured 2026-08-20: unset == `VIBE_RC=1`.

The cutover named in the title happened. This file was a readiness assessment
asking whether it *should*; that question is answered, so the assessment is
gone rather than preserved under a banner (`git log` and the #493 thread hold
the path). What is kept below is what is still load-bearing.

## Two lanes, two defaults — do not conflate them

| what is being compiled | default | pinned where |
|---|---|---|
| a **user program**, via the CLI | **RC** | the compiler's own `VIBE_RC` fallback |
| the **compiler itself**, self-build | **bump** (`VIBE_RC=0`) | `scripts/generations.sh:3` |

The bootstrap pin is a **performance** choice, not a correctness one: an RC
self-build is ~1.7× wall and ~2.9× output size (#705). RC self-hosting is
correct end to end — a bump stage2 compiling the flat source under `VIBE_RC=1`
yields a `stage2_rc` whose own recompile is byte-identical, and the
`VIBE_RC=shadow` instrumented build completes the same self-compile trap-free
(#705/#715/#720). `scripts/test_rc_bootstrap.sh`, run from
`tests/gates/bootstrap/run.sh`, holds that.

`seed → stage1` must still run bump for a separate reason: the pinned seed
predates RC and fails `not EFn` under `VIBE_RC=1`.

## The mixed-feature probe — now a regression guard

`scripts/rc_cutover_readiness.sh` compiles a corpus of allocation-heavy
programs that **mix** RC features (the reclaim suite and the heap-e2e gate
exercise them in isolation) both ways, and per program asserts: RC compiles and
runs, default == RC result parity, and RC heap bounded (`heap(N1) == heap(N2)`
rather than scaling with N).

It pins its own baseline with `: "${VIBE_RC:=0}"`, which is what keeps it
usable now that the default moved — it compares bump against RC whatever the
compiler's default is, so it still answers "did RC regress against bump"
rather than comparing RC with itself.

```bash
bash scripts/rc_cutover_readiness.sh              # N1=1000 N2=11000
bash scripts/rc_cutover_readiness.sh 1000 101000  # tighter per-iter signal
```

Its `READY` / `NOT READY` wording predates the cutover and now reads as
"no regression" / "regression".

## Known residuals

- **A matched heap field bound but unused leaks** — dup on extraction with no
  consuming drop. A safe over-keep, not a use-after-free; write `_` for a field
  you do not use. Bounded-heap regression is pinned by the leak-guard gate
  (`compiler_gate.sh` step 40d) over tuple + cell + closure + recursive enum.
- **Replay-based handlers spill past ~16K performs per `handle`** — a hard
  bound of the replay-memo design, not a sizing bug. See
  [uniform-value-repr.md](uniform-value-repr.md).
- The *safe* leaks catalogued in [uniform-value-repr.md](uniform-value-repr.md)
  (escaping lambdas, deep-projection opaque args, container-outlives-scope).
