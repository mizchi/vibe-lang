# vibe Collection Library

Map-oriented helper modules split from `vibe/prelude`.

> **2026-07-04**: `list.vibe` / `set.vibe` (and `vibe/sha1`, `vibe/leb128`)
> moved to the **`@vibe/core` package** (`lib/@vibe/core/`, ADR-0063 contract
> package). Import them via the package contract:
> `import <path-to>/lib/@vibe/core { list_map, from_array, sha1, ... }`.
> This directory now only carries the map helpers.

## Modules

- `array` stays in `vibe/prelude` because it is treated as a core primitive container.
- `maps.vibe`: generic map helpers (`has_key`, `get`, `get_or`, `keys`, `values`)
- `r#map.vibe`: internal compatibility endpoint (new imports should use `maps.vibe`)
- `index.vibe`: facade re-exporting the map helpers

## Running tests

```bash
vibe test vibe/collection/map_test.vibe
vibe test vibe/collection/index_import_test.vibe
```
