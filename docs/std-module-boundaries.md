# vibe/std Module Boundaries

`vibe/std` is organized as layered modules. The boundary is validated by `vibe check` and `vibe normalize` for runtime modules under `vibe/std`.

## Layers

| Layer | Modules | Responsibility |
|---|---|---|
| `trait-contract` | `vibe/std/builtin_traits.vibe` | Trait contracts and generic contract helpers |
| `pure-primitive` | `vibe/std/bool.vibe`, `vibe/std/cmp.vibe`, `vibe/std/char.vibe`, `vibe/std/int.vibe`, `vibe/std/float.vibe`, `vibe/std/double.vibe`, `vibe/std/string.vibe` | Pure value operations |
| `pure-data` | `vibe/std/array.vibe`, `vibe/std/map.vibe`, `vibe/std/set.vibe`, `vibe/std/list.vibe`, `vibe/std/option.vibe`, `vibe/std/result.vibe`, `vibe/std/bytes.vibe`, `vibe/std/threads/spec.vibe` | Pure data structures and transforms |
| `ref-model` | `vibe/std/path/ref.vibe`, `vibe/std/path.vibe` | Reference/path model abstractions |
| `effect-boundary` | `vibe/std/io.vibe`, `vibe/std/path/runtime.vibe`, `vibe/std/threads/runtime.vibe`, `vibe/std/threads.vibe` | Runtime side-effect bridges |
| `backend-specific` | `vibe/std/wasm/*.vibe` | Backend-specific experimental APIs |

Test files (`*_test.vibe`, `*_type_import_test.vibe`, `test_import.vibe`) are excluded from this boundary rule.

Compatibility facades:

- `vibe/std/path.vibe` keeps legacy API shape while `vibe/std/path/ref.vibe` and
  `vibe/std/path/runtime.vibe` provide split boundaries.
- `vibe/std/threads.vibe` keeps legacy API shape while
  `vibe/std/threads/spec.vibe` and `vibe/std/threads/runtime.vibe` provide split
  boundaries.

## Allowed Imports

| Source layer | Allowed target layers |
|---|---|
| `trait-contract` | `trait-contract` |
| `pure-primitive` | `trait-contract`, `pure-primitive` |
| `pure-data` | `trait-contract`, `pure-primitive`, `pure-data` |
| `ref-model` | `trait-contract`, `pure-primitive`, `pure-data`, `ref-model` |
| `effect-boundary` | `trait-contract`, `pure-primitive`, `pure-data`, `ref-model`, `effect-boundary` |
| `backend-specific` | `trait-contract`, `pure-primitive`, `pure-data`, `ref-model`, `backend-specific` |

Notably:

- `effect-boundary` must not depend on `backend-specific`.
- `backend-specific` must not depend on `effect-boundary`.
- Pure layers must not depend on effect/backend layers.
