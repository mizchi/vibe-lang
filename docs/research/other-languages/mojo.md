# Mojo: argument conventions, origins, and explicit SIMD

Surveyed 2026-09-23 against Mojo 1.1.0 (2026-09-17). Docs:
<https://mojolang.org/docs/> (docs.modular.com redirects there). Release notes
are in [modular/modular](https://github.com/modular/modular) under
`Mojo/docs/site/releases/`.

## 1. Ownership without lifetimes in the surface

Mojo is the useful counterexample to "borrowing means Rust". Most code never
names a lifetime, because **the common case is a parameter convention, not a
reference type**.

| convention | meaning | call site |
|---|---|---|
| *(default, formerly `borrowed` / `read`)* | immutable reference; small values go in registers | `f(x)` |
| `mut` (formerly `inout`) | mutable reference | `f(x)` |
| `var` (formerly `owned`) | callee takes ownership | `f(x^)` moves, `f(x)` copies implicitly |
| `out` | uninitialized on entry, must be initialized before return | constructors, named results |
| `deinit` | initialized on entry, uninitialized on return | destructors, `__moveinit__` |
| `ref [origin]` | mutability parametric in the origin | `-> ref [origin] T` returns |

Postfix `x^` ends `x`'s life and transfers it; a later use is a compile error.

**Exclusivity** (since 24.5, modelled on Swift and on Rust's "aliasing xor
mutability"): a callee that receives a `mut` reference to a value cannot receive
any other reference to the same value.

```mojo
def take_two_strings(a: String, mut b: String): b += a
take_two_strings(s, s)   # error: argument exclusivity violation
```

It is not enforced for register-passable types, which are copied anyway.

**ASAP destruction.** "Mojo destroys values as soon as they're no longer used.
It doesn't wait for the end of a code block or even the end of an expression."
A live reference extends its owner through the origin. This is Perceus's
drop-at-last-use, arrived at from the other direction (motivated by freeing GPU
tensors early).

**Linear types (26.1).** `AnyType` no longer implies implicit destruction; a
type must satisfy `ImplicitlyDestructible` to be dropped silently. A type that
does not must be consumed by a named destructor — a must-use resource.

## 2. Origins: lifetimes named after places

When a reference *does* escape a call, Mojo names where it came from rather
than an abstract region. An origin is a compile-time value (`Origin[mut=b]`,
`ImmOrigin`, `MutOrigin`, `ImmStaticOrigin`) obtained with `origin_of(expr)`,
unioned with `origin_of(a, b)` (mutable only if every member is). Most origins
are inferred from arguments.

```mojo
def to_byte_span[is_mutable: Bool, //, origin: Origin[mut=is_mutable]](
    ref[origin] list: List[Byte]) -> Span[Byte, origin]:
    return Span(list)
```

1.0 added experimental **interior origins**, which catch iterator invalidation:

```mojo
var list = [1, 2, 3]
ref elem = list[0]
list.append(4)   # may reallocate
print(elem)      # error: use of invalidated interior reference
```

Escape hatches are explicit and greppable: `MutUntrackedOrigin`,
`MutUnsafeAnyOrigin`, and the 1.0 policy of marking unsafety per operation on
`UnsafePointer`.

The rename history is itself a lesson — `inout`→`mut`, `borrowed`→`read`→default,
`owned`→`var`, `Lifetime`→`Origin` ("where a reference is derived from, not …
where a variable is initialized and destroyed"; proposal
[modular/modular#3623](https://github.com/modular/modular/issues/3623)). Three
years in, the concepts held and only the spellings moved.

**Formal status.** I found no published formalization or soundness proof of
Mojo's origin checker. It is a dataflow checker inside the MLIR-based
compiler. The nearest formal work is on the Rust side: Oxide
(<https://arxiv.org/abs/1903.00982>) and the 2026 Rust "place-based lifetimes"
goal (<https://goals.rust-lang.org/2026/roadmap-borrow-checker-within.html>),
which converges on the same origin-as-place idea.

## 3. SIMD: a value type, a width function, and a library loop

Mojo does **not** rely on a compiler auto-vectorizer. It makes the vector
explicit and generic over width:

- `SIMD[dtype, width]` is *the* numeric primitive. `Scalar[dt]` is
  `SIMD[dt, 1]`; `Int32`, `Float32` and friends are aliases of it. Every
  operator is lane-wise.
- `simd_width_of[dtype, target]()` is a compile-time function: the target's
  SIMD register width divided by the element width.
- `vectorize` is **ordinary library code**:

```mojo
def vectorize[func: def[width: Int](idx: Int) -> None, //, simd_width: Int, /, *,
              unroll_factor: Int = 1](size: Int, closure: func)

comptime simd_width = simd_width_of[DType.int32]()
def closure[width: Int](i: Int) {mut}:
    ptr.store[width=width](i, Int32(i))
vectorize[simd_width](size, closure)
```

  Its body is a main loop whose step is
  `comptime for _ in range(unroll_factor): closure[simd_width](i)` and a scalar
  remainder loop `closure[1](i)`. The user's closure is generic in `width` and
  is monomorphized once per width used.
- `parallelize[func](n)` is the same shape one level up (thread tasks).
- compile-time control is `comptime x = …`, `comptime if`, `comptime for`
  (formerly `alias`, `@parameter if`, `@parameter for`, removed in 1.1).

So "Mojo auto-vectorizes" really means: **the programmer writes one
width-generic kernel, and the library instantiates it at the full width plus a
width-1 tail.** Correctness does not depend on an optimizer succeeding, and
performance is predictable because nothing is left to heuristics.

## Lessons for vibe

1. **Parameter conventions give most of the value of borrowing with none of
   the lifetime syntax.** vibe's compiler already infers a per-parameter
   borrow mask (`compute_borrow_param_user_fns` in
   `codegen/common_analysis/common_analysis.vibe`). What Mojo adds is making
   the convention *declarable and checked*, so it survives a package boundary
   and becomes a contract.
2. **Exclusivity is a call-site check, not a type system.** "A `mut`
   argument may not alias any other argument" needs no lifetime variables.
   In Mojo a syntactic check on identifiers suffices because `let b = a`
   copies; in vibe it shares the heap object, so the check has to be
   restricted to shallow buffers and backed by an identity compare at entry
   ([borrowing-and-vectorization.md](borrowing-and-vectorization.md) §A3). It
   is also exactly the
   property an SMT-based verifier needs (see [moonbit-veri.md](moonbit-veri.md):
   Why3 rejects aliased mutable arguments).
3. **Origins are the upgrade path, not the starting point.** vibe already
   computes `borrow_ret` and `view_ret` (the return value aliases a parameter;
   see `vibe rc-classify`). An origin restricted to "one of my parameters" is
   Mojo's inferred-origin common case and needs no new kind.
4. **Vectorization should be explicit and library-shaped, but vibe cannot copy
   the value type.** Mojo's `SIMD` is a first-class value. vibe decided the
   opposite on measurement: *a vector never becomes a vibe value*, because a
   value is a tagged i64 and a vector value would be boxed
   ([simd-api-design.md](../../internal/design/simd-api-design.md), #2342). The
   transferable part is the *shape* — a width-parametric body plus a scalar
   tail, instantiated by the compiler — with the body restricted to a subset
   the compiler can lower without ever materializing a vector value.
5. **On wasm the width is a constant.** `simd_width_of` exists because Mojo
   targets AVX-512, NEON and GPUs. On wasm, `v128` is 128 bits everywhere,
   flexible vectors are dormant at phase 1, and relaxed SIMD is
   nondeterministic by design. The width function collapses to
   `128 / bits(T)`, which removes a whole axis of Mojo's design.
