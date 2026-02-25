# vibe Collection Library

Collection-oriented modules are split from `vibe/prelude` and managed in this package.

## Modules

- `array` stays in `vibe/prelude` because it is treated as a core primitive container.
- `list.vibe`: generic cons-list helpers (`List[T]`, `map`, `fold`, `iter`, `zip`, `flatmap`, `filter`, `append`)
- `maps.vibe`: generic map helpers (`has_key`, `get`, `get_or`, `keys`, `values`)
- `r#map.vibe`: internal compatibility endpoint (new imports should use `maps.vibe`)
- `set.vibe`: string set helpers (`add`, `remove`, `contains`, `set_union`, `set_intersect`)

## Naming Policy

`list.vibe` は historical alias (`list_*`) と short API の両方を公開しているが、今後の推奨は short API に統一する。

- canonical: `map`, `fold`, `iter`, `zip`, `flatmap`, `filter`, `append`, `take`, `drop`
- compatibility: `list_map`, `list_fold`, `list_iter`, `list_zip`, `list_flatmap`, ...

互換方針:

1. README / 新規コードは canonical 名を優先する。
2. 既存コード移行のため `list_*` は当面維持する。
3. 互換期間終了時に `list_*` は段階的に縮小し、`vibe normalize` で canonical へ寄せる。

## Running tests

```bash
just run test \
  vibe/collection/map_test.vibe \
  vibe/collection/set_test.vibe \
  vibe/collection/list_test.vibe
```
