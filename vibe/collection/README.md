# vibe Collection Library

Collection-oriented modules are split from `vibe/std` and managed in this package.

## Modules

- `array` stays in `vibe/std` because it is treated as a core primitive container.
- `list.vibe`: generic cons-list helpers (`List[T]`, `map`, `fold`, `filter`, `append`)
- `map.vibe`: generic map helpers (`has_key`, `get`, `get_or`, `keys`, `values`)
- `set.vibe`: string set helpers (`add`, `remove`, `contains`, `set_union`, `set_intersect`)

## Running tests

```bash
just run test \
  vibe/collection/map_test.vibe \
  vibe/collection/set_test.vibe \
  vibe/collection/list_test.vibe
```
