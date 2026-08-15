# Module system Oracle

Status: ADR-0070 の実行可能な正本。2026-07-16 (現行モデル要約 2026-08-01, #1269)。

vibe の package/module policy は `formal/VibeFormal/Module/` の Lean model を
正とし、compiler の loader はその判定を filesystem 上で refinement する。
旧 ADR-0063/0070 の incoming-only boundary と再帰 discovery は supersede する。

## 現行モデル (canonical — ここが唯一の現行記述)

パッケージ境界・可視性・pin/update の**現行の**規則はこの節が正本である
(#1269)。他のドキュメント (spec / cheatsheet / tutorial / install /
module-system*.md) はここへリンクし、独自の説明を持たない。異なる世代の
記述に出会ったら、この節と `formal/VibeFormal/Module/` が勝つ。

**1. 境界は `index.vpkg` だけ。** source の owner は最寄りの祖先
`index.vpkg`。nested な `index.vpkg` は別 package を開始する。`index.vibe` /
legacy `index.vibei` は **境界ではない** — 互換のために読めるだけの
ファイルであり、新しいパッケージは必ず `index.vpkg` を持つ。同じ directory
に複数の index spelling があれば hard error。

**2. 可視性は owner 単位。** owner を持たない source は公開 compatibility
space で、誰からでも import できる。owner を持つ implementation は同じ owner
からしか import できず、他 owner からは相手の `index.vpkg` facade だけを
import できる (親→子・子→親の両方向、ownerless からの bypass も不可)。

**3. 暗黙 build root は直下だけ。** `index.vpkg` と同じ directory の通常
`*.vibe` のみが暗黙 root。subdirectory は再帰走査せず、direct root からの
relative import/export edge で graph に入れる。`*_test.vibe` /
`*_bench.vibe` は通常 build と package hash から除外され import target に
できない (明示実行時のみ、最寄り owner の private production と `index.vpkg`
の shared import を継承する)。`_*.vibe` / `*.draft.vibe` は自動 root/hash から
外れるが、同一 owner からの明示 relative import で到達すれば graph と hash
closure に入る。symlink は module source / contract / import target のいずれ
にも使えない。

**4. 契約とヘッダー。** `index.vpkg` は bodyless 宣言による公開契約 +
`name` / `version` / `description` / `deps` / `main` / `generated_hash` の
key=value ヘッダー (ADR-0080)。`deps = { @scope/pkg : x.y.z }` が依存の版数を
宣言する唯一の場所で、`import @scope/pkg { .. }` は名前解決専用 (版数を
運ばない)。旧 `version x.y.z` (`=` なし) は互換で受理される。

**5. pin と update のワークフロー。** 2つのレイヤがあり、用途が違う:

| やること | コマンド | 記録先 |
|---|---|---|
| 依存の宣言漏れ検査 | `vibe check --deps-missing <root>` | — (CI: compiler_gate 60) |
| package hash の計算・書き戻し | `vibe hash --write <pkg_dir\|index.vpkg>` | `generated_hash` (idempotent) |
| リモート依存の取得と固定 | `vibe fetch` (`vibe.deps` を読む) | `deps/` に vendor + `vibe.lock` |

`@scope/name` の解決順は `.vibe/store/` (pin 検証済み) → workspace `lib/` →
`VIBE_LIB` の各 root (`:` 区切り、既定 `$VIBE_HOME/lib`)。lib/VIBE_LIB 解決は
dev-mode の便宜であり、`VIBE_REQUIRE_PINS=1` では pin なし解決はエラーになる。
`vibe fetch` / `vibe.lock` は **リモート vendoring MVP** (単一ファイル URL と
git repo を `deps/` に取り込む経路、docs/install.md) であって、上の
package 境界モデルとは別レイヤ — in-repo の `lib/@scope/pkg` は
`vibe.lock` を使わない。

**歴史的記述の扱い:** v1 仕様書 (`module-system.md`) は 2026-08 に削除した —
`module {}` ブロック・`vibe.deps`/`vibe.lock` を唯一の依存モデルとする記述・
`index.vibe(i)` を境界とする記述はどれも現行ではなく、残しておくと現行の
ビルドについての嘘になる。経緯が要るときは `git log` を引くこと。
[module-system-v2.md](module-system-v2.md) は ADR-0063/0064 の設計本文として
残しているが、`index.vibei` を契約ファイルとする綴りは現行 (`index.vpkg`) より
前の世代の記述である。

## 規則

1. `index.vpkg` だけが boundary である。source の owner は最寄りの祖先
   `index.vpkg`。nested `index.vpkg` は別 package を開始する。
2. owner を持たない source は公開 compatibility space であり、owner の有無に
   かかわらず import できる。owner を持つ implementation target は importer と
   同じ owner に属さなければならない。異なる owner 間では、相手の
   `index.vpkg` facade だけを import できる。この制約は親→子・子→親の両方向に
   適用する。ownerless importer から owned implementation への bypass もできない。
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

| 観測可能な規則 | Lean Oracle | implementation refinement / regression guard |
|---|---|---|
| filename role | `Source.role` | `loader/header_cache.vibe::contract_sibling_impl_raws` |
| regular source・index 排他 | `Valid` | `ensure_regular_source_fs` / `validate_index_layout_fs` |
| boundary・nearest owner | `Boundary` / `Workspace.ownerOf` | `nearest_vpkg_path_fs` |
| direct implicit root | `IsImplicitBuildRoot` | `contract_sibling_impl_raws` |
| companion shared scope | `InheritsSharedImports` | `vpkg_directory_shared_import_prefix_fs` |
| owner / ownerless visibility | `AllowedImport` | `enforce_incoming_boundary_fs` |
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
対応する refinement は regression tests と generation/fixpoint gate で
固定する。将来の強化候補は、fixture graph を Lean 入力へ変換する differential
oracle と、package hash closure の graph reachability を帰納的に証明するモデル。
