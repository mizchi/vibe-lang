# Vx: placement in the type, SMT per transfer

Surveyed 2026-09-23. **Identification caveat:** the request named "vx" with no
link. The only active language by that name is Vx ("one language, every core")
at [vx-lang/Vx](https://github.com/vx-lang/Vx), <https://vxlang.org/>, by
Aditya Kumar; version 0.0.2, about 1,800 commits, a compiler (`vxc`) in Rust on
LLVM 22 / MLIR. It has a borrow checker, linear types, a vector type and SMT
obligations, which fits the topic. It is an imperative, Rust-like systems
language for heterogeneous hardware (CPU, GPU, NPU, remote nodes) and does
**not** target wasm. If a different "vx" was meant, this page is about the
wrong language.

## Memory placement is part of the type

A tensor's type records where it lives:
`Tensor<f32, [4,4], Memory::NPU_HBM>` differs from the same tensor in host DRAM,
and `Pinned<T, Topology::NPU[0]>` pins a value to a device. Moving between
memories is an explicit `transfer()` / `.to_device()`. The checker rejects,
statically:

- the host dereferencing a device pointer (E6003);
- a transfer between memories that cannot reach each other (E6002);
- a working set that exceeds the capacity of a target described in a
  "machine file" (twelve hardware specs such as H100, MI300X, M4, Cortex-M7;
  E6009 / E6010).

The design documents frame memory spaces as a category whose morphisms are
transfers, graded by a cost monoid (a graded, parameterised monad in
Katsumata's sense); the cheapest composite transfer is a shortest path over
the cost graph.

## Linear types and the borrow checker

Resource types are linear, "used exactly once" (`E4001: use of moved or
consumed linear variable`); scalars are copyable. References are Rust-like
`&T` / `&mut T`.

The borrow checker is small (about 430 lines plus a HIR borrow context) and
uses a **lexical-depth approximation**: each lifetime parameter is packed into
16 bits of a 256-bit type id (4 variance bits, 12-bit region id), the region id
*is* the lexical scope depth, and "outlives" becomes the integer comparison
`region_a <= region_b`. Its own comments admit that `&mut` invariance is not
enforced (the check is `<=`, not `==`). An NLL-style active-borrow table sits
beside it.

This is fast and simple, and it is not sound in general. It is the part of Vx
**not** to copy.

## Seam obligations: SMT at each transfer

The part worth studying. Every hop of a transfer emits a QF_BV query over a
bit-packed BOT / CONST / TOP lattice describing buffer publication state; a
relaxed transfer sends published buffers to TOP. Z3 discharges the query, and
`sat` is a concrete stale-read counterexample, reported as E6004.

Two properties make this workable:

- the query is **local and small** (one hop, a fixed lattice, bit-vectors
  only), so it is decidable and fast;
- a failure comes with a **counterexample**, which is what makes an SMT result
  a usable diagnostic rather than "unknown".

There is no general effect system; `spawn on(τ) { … }` producing `Pinned<T, τ>`
is the only effect-like construct. SIMD is a first-class `<N x T>` type lowered
to MLIR `vector<NxT>`; there is no auto-vectorizer.

## Lessons for vibe

1. **Placement as a type index is the same move as vibe's region token.**
   `MutList[T, r]` (ADR-0090) indexes storage by a region; Vx indexes it by a
   memory space. If vibe ever maps data to distinct linear memories (a worker's
   own `Store`, per ADR-0068's per-worker heap), the "where it lives" index and
   the explicit transfer are the precedent, and ADR-0068's deep-copy message
   semantics is the `transfer()`.
2. **Emit small, local, decidable obligations; never one big query.** This is
   the right shape for a `where`-contract Phase 3 as well: one query per call
   edge / loop, in a fixed theory, with a counterexample on failure.
3. **A borrow checker built on scope depth is a trap.** It works until the
   first program that needs invariance or a non-lexical lifetime. If vibe adds
   borrow modes, keep them second-class (parameters only) so no lifetime
   comparison is needed at all, rather than approximate one.
