# Module system Oracle

Status: ADR-0070 の実行可能な正本。2026-07-16。

vibe の package/module policy は `formal/VibeFormal/Module/` の Lean model を
正とし、selfhost loader はその判定を filesystem 上で refinement する。
旧 ADR-0063/0070 の incoming-only boundary と再帰 discovery は supersede する。

## 規則

1. `index.vpkg` だけが boundary である。source の owner は最寄りの祖先
   `index.vpkg`。nested `index.vpkg` は別 package を開始する。
2. implementation target は importer と同じ owner に属さなければならない。
   異なる owner 間では、相手の `index.vpkg` facade だけを import できる。
   この制約は親→子・子→親の両方向に適用する。
3. `index.vibe` と legacy `index.vibei` は boundary ではない。同じ directory に
   複数の index spelling が存在すれば、どれを entry にしても hard error。
4. 暗黙 build root は `index.vpkg` と同じ directory にある通常の `*.vibe`
   だけ。subdirectory を再帰走査せず、必要な source は direct root からの
   relative import/export edge で graph に入れる。
5. `*_test.vibe` / `*_bench.vibe` は通常 build と package hash から除外し、
   import target にできない。明示実行した companion 自身は、最寄り owner の
   private production module と `index.vpkg` の shared import を継承する。
6. `_*.vibe` / `*.draft.vibe` は暗黙 root と自動 hash input から除外する。
   同じ owner の production から明示 relative import された場合は graph と
   content-addressed hash closure の両方に入り、最寄り owner の `index.vpkg`
   shared import を継承する。
7. module source、contract、import target に symlink は使えない。

## Oracle と実装の対応

| 観測可能な規則 | Lean Oracle | selfhost refinement / regression guard |
|---|---|---|
| filename role | `Source.role` | `loader/header_cache.vibe::contract_sibling_impl_raws` |
| regular source・index 排他 | `Valid` | `ensure_regular_source_fs` / `validate_index_layout_fs` |
| boundary・nearest owner | `Boundary` / `Workspace.ownerOf` | `nearest_vpkg_path_fs` |
| direct implicit root | `IsImplicitBuildRoot` | `contract_sibling_impl_raws` |
| companion shared scope | `InheritsSharedImports` | `vpkg_directory_shared_import_prefix_fs` |
| owner visibility | `AllowedImport` | `enforce_incoming_boundary_fs` |
| automatic/reachable hash input | `automaticallyIncludedInPackageHash` / `includedInPackageHash` | `collect_package_hash_source_closure_fs` |
| cache-independent observation | policy functions are pure | `module_policy_context_fingerprint_fs` |
| concrete witnesses | `Proofs/ModuleExamples.lean` | `tests/contract_vpkg_test.vibe`, `tests/contract_vpkg_shared_scope_test.vibe` |

`Fs::stat_token` は bootstrap compatibility のため symlink に予約値 `-1` を返し、
`ensure_regular_source_fs` がこれを拒否する。通常 file の token は従来どおり
metadata hash であり、JS/Rust runner が同じ判定を実装する。

Persistent source cache は external package resolution に加え、各 source の owner、
owner contract の内容、direct production root 一覧を context fingerprint に含める。
したがって index conflict・nested boundary・shared import・direct root が変化した
cache hit は捨てられ、cold graph walk と同じ policy を再評価する。

## Hash closure

`package_hash` は次を hash input とする。

- `index.vpkg` 自身。
- 同 directory の direct production roots。
- そこから relative import/export で到達する同一 owner の source。

外部 package は source bytes を取り込まず、`index.vpkg` に記録された require
pin を hash する。test/bench companion は到達 edge 自体を拒否するため closure
に入らない。これにより、実行結果に影響する同一 package source を変更すれば
package hash も変わる。

## Epistemic status

`pkf run formal-check` が証明するのは、有限 workspace model 上の分類・owner・
visibility・hash-input 判定である。実 filesystem の path normalization、parser、
cache、hash bytes、Wasm codegen が Lean から抽出されているわけではない。
対応する refinement は selfhost regression tests と generation/fixpoint gate で
固定する。将来の強化候補は、fixture graph を Lean 入力へ変換する differential
oracle と、package hash closure の graph reachability を帰納的に証明するモデル。
