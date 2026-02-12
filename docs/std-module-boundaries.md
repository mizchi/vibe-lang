# xsh/std Module Boundaries

`xsh/std` is organized as layered modules. The boundary is validated by `xsh check` and `xsh normalize` for runtime modules under `xsh/std`.

## Layers

| Layer | Modules | Responsibility |
|---|---|---|
| `trait-contract` | `xsh/std/builtin_traits.xsh` | Trait contracts and generic contract helpers |
| `pure-primitive` | `xsh/std/bool.xsh`, `xsh/std/int.xsh`, `xsh/std/float.xsh`, `xsh/std/double.xsh`, `xsh/std/string.xsh` | Pure value operations |
| `pure-data` | `xsh/std/list.xsh`, `xsh/std/option.xsh`, `xsh/std/threads/spec.xsh` | Pure data structures and transforms |
| `ref-model` | `xsh/std/path/ref.xsh`, `xsh/std/path.xsh` | Reference/path model abstractions |
| `effect-boundary` | `xsh/std/io.xsh`, `xsh/std/path/runtime.xsh`, `xsh/std/threads/runtime.xsh`, `xsh/std/threads.xsh` | Runtime side-effect bridges |
| `backend-specific` | `xsh/std/wasm/*.xsh` | Backend-specific experimental APIs |

Test files (`*_test.xsh`, `*_type_import_test.xsh`, `test_import.xsh`) are excluded from this boundary rule.

Compatibility facades:

- `xsh/std/path.xsh` keeps legacy API shape while `xsh/std/path/ref.xsh` and
  `xsh/std/path/runtime.xsh` provide split boundaries.
- `xsh/std/threads.xsh` keeps legacy API shape while
  `xsh/std/threads/spec.xsh` and `xsh/std/threads/runtime.xsh` provide split
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
