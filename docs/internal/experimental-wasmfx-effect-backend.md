# Experimental WasmFX effect backend

Status: design and runtime probe only. Compiler and runtime integration has not
started.

## Purpose

Add an opt-in effect backend that lowers Vibe algebraic effects to Wasm
stack-switching instructions. The existing linear suspend-CPS backend remains
the default until the experimental backend reaches semantic parity.

The runtime feasibility probe is in `tools/wasmfx_effect_probe`. It pins
`mizchi/wasmtime-threads` revision
`e1fb408fb7258ac8d1207084af4e1988b3c7db87`, which supports stack switching on
Apple Silicon macOS.

The probe confirms that WasmFX can represent three cases restricted by the
current suspend-CPS lowering:

- suspension through an opaque call while retaining native frames and operand
  stack values;
- handler processing after a resumed continuation returns;
- dynamic forwarding through an intermediate handler that does not handle the
  operation.

## Scope boundaries

- Start with in-process algebraic effects only.
- Add `Async::Suspend` and `TaskGroup` only after algebraic-effect parity.
- Keep WIT capability effects as provider calls. WasmFX must not bypass
  capability authorization.
- Keep Component Model async as a separate boundary.
- Preserve one-shot continuation semantics. Multi-shot continuations are out
  of scope.
- Treat stack switching as cooperative control transfer, not parallelism.
- Do not change Vibe syntax or effect-row checking for the first slice.

## Work required

### 1. Backend selection and feature contract

- Add an explicit experimental option such as `--effect-backend=wasmfx`.
- Keep the current backend as the default.
- Record the selected backend in build inputs and cache keys.
- Reject the option with an actionable diagnostic when the target runtime or
  architecture lacks stack-switching support.
- Declare the required Wasm feature level in emitted artifacts.

### 2. Internal continuation representation

- Add a typed compiler IR representation for continuation references and
  resumption signatures.
- Do not encode `contref` in Vibe's general tagged-`i64` value representation.
- Decide between direct typed Wasm locals/results and an explicit runtime
  handle table for places where a continuation must be stored in a Vibe value.
- Preserve linear ownership and diagnose a second resume deterministically.
- Define how continuation roots interact with the wasm-gc lane.

This decision is the main representation gate. Wasm emission should not start
until the ownership and storage contract is explicit.

### 3. Wasm emitter support

- Emit continuation function types and continuation types.
- Emit typed control tags for algebraic-effect operations.
- Add encoders for `cont.new`, `resume`, `suspend`, and handler clauses.
- Add `resume_throw` and `resume_throw_ref` only after exception and
  cancellation semantics are defined.
- Extend feature validation, disassembly, and artifact inspection.
- Fail closed when a selected target cannot encode or execute the proposal.

### 4. Effect lowering

- Lower one monomorphic effect operation with `Int` payload and resumption
  value end to end.
- Map `perform E::Op(args)` to `suspend $E.Op`.
- Map a handled body to `cont.new` plus `resume` with typed `on` clauses.
- Bind the caught continuation as the arm's one-shot `resume` value.
- Implement deep forwarding by leaving unhandled tags out of intermediate
  handler clauses.
- Preserve the existing evidence-dictionary path for tail-resumptive cases
  unless measurements justify replacing it.
- Keep the current suspend-CPS pass available for the default backend.

### 5. Runtime integration

- Make `runtime/viberun` use the pinned `wasmtime-threads` implementation when
  the experimental backend is selected.
- Enable function references, exceptions, and stack switching together.
- Keep the dependency revision pinned until the required changes are available
  in an upstream release.
- Verify stack sizing, guard pages, traps, backtraces, and host re-entry on
  Apple Silicon.
- Define artifact/runtime compatibility diagnostics instead of allowing an
  unsupported module to fail during instantiation.

### 6. Tests

Run every applicable positive effect fixture against both backends. In
addition, add explicit coverage for:

- opaque and separately compiled callees;
- row-polymorphic calls;
- nested handlers and dynamic forwarding;
- loops, branches, early exits, and higher-order calls around `perform`;
- stored continuations and delayed resume;
- handler post-processing after resume;
- second-resume rejection;
- trap and panic propagation across continuation stacks;
- stack overflow and backtrace quality;
- cancellation and child-failure convergence;
- multiple workers using independent continuations;
- feature-disabled and unsupported-target diagnostics.

The current-backend rejection expectations in
`fixtures/err_effect_resume_store_ineligible.vibe` and
`fixtures/err_effect_needing_value_escape.vibe` must remain. Add parallel
WasmFX-positive expectations rather than weakening the default backend's
fail-closed behavior.

### 7. Async and structured concurrency follow-up

After algebraic-effect parity:

- lower `Async::Suspend` to typed suspension;
- store parked continuations in scheduler-owned state;
- map wake-up to one-shot resume;
- define cancellation delivery using an explicit tag or typed throw;
- specify whether the first child failure cancels siblings before joining;
- ensure task-local handlers are not inherited unless declared fork-safe;
- keep multi-worker execution separate from continuation scheduling.

## Acceptance gates

The backend remains experimental until all of the following hold:

- existing effect programs produce the same observable results on both
  backends;
- programs newly accepted by WasmFX have dedicated regression tests;
- one-shot ownership cannot be bypassed through storage or aliasing;
- traps, cancellation, failure propagation, and backtraces are deterministic;
- unsupported runtimes fail before execution with an actionable diagnostic;
- the default backend and artifacts are unchanged when the option is absent;
- Apple Silicon macOS and Linux x64 pass the same WasmFX test matrix.

## Explicit non-actions

This document does not authorize implementation yet. In particular, do not:

- change the default effect backend;
- modify Vibe syntax or checker semantics;
- replace capability-provider calls with WasmFX tags;
- expose continuation references through the public value ABI;
- claim multi-shot effects, preemption, or parallel execution;
- remove the suspend-CPS backend or its negative fixtures.
