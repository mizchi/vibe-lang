# Advanced Graph Bench Report (2026-02-08)

## 概要
`AdvancedGraphIndex` / `AdvancedGraphDelta` の PoC について、
現行検索経路との比較と、リモート差分適用シナリオを計測した結果。

## 実行コマンド
- `just bench-advanced-graph`

## ベンチ対象
- `bench: graph_build.current_symbol_index_cold`
- `bench: graph_build.advanced_graph_index_cold`
- `bench: graph_search.current_cli_like`
- `bench: graph_search.graph_snapshot_query`
- `bench: graph_search.graph_json_load_query`
- `bench: graph_search.graph_cbor_load_query`
- `bench: graph_search.graph_flexbuffer_load_query`
- `bench: graph_remote.apply_full_snapshot`
- `bench: graph_remote.apply_full_snapshot_cbor`
- `bench: graph_remote.apply_full_snapshot_flexbuffer`
- `bench: graph_remote.apply_delta`
- `bench: graph_remote.apply_delta_cbor`
- `bench: graph_remote.apply_delta_flexbuffer`

## 結果
- graph_build.current_symbol_index_cold: `406.54 ms ± 19.25 ms`
- graph_build.advanced_graph_index_cold: `958.80 ms ± 58.37 ms`
- graph_search.current_cli_like: `363.88 ms ± 28.91 ms`
- graph_search.graph_snapshot_query: `118.16 µs ± 0.64 µs`
- graph_search.graph_json_load_query: `1.36 ms ± 3.57 µs`
- graph_search.graph_cbor_load_query: `2.06 ms ± 14.17 µs`
- graph_search.graph_flexbuffer_load_query: `3.25 ms ± 42.72 µs`
- graph_remote.apply_full_snapshot: `1.22 ms ± 5.57 µs`
- graph_remote.apply_full_snapshot_cbor: `1.99 ms ± 15.03 µs`
- graph_remote.apply_full_snapshot_flexbuffer: `3.07 ms ± 12.67 µs`
- graph_remote.apply_delta: `1.05 ms ± 29.44 µs`
- graph_remote.apply_delta_cbor: `1.57 ms ± 14.05 µs`
- graph_remote.apply_delta_flexbuffer: `3.44 ms ± 93.78 µs`

## 比較
- 検索 (current_cli_like -> graph_snapshot_query): 約 `3079.55x` 高速
- 検索 (current_cli_like -> graph_json_load_query): 約 `267.56x` 高速
- 検索 (current_cli_like -> graph_cbor_load_query): 約 `176.64x` 高速
- 検索 (current_cli_like -> graph_flexbuffer_load_query): 約 `111.96x` 高速
- remote apply (full json -> delta json): 約 `1.16x` 高速（約 `13.9%` 短縮）
- remote apply (full json -> full cbor): cbor は約 `1.63x` 遅い
- remote apply (full json -> full flexbuffer): flexbuffer は約 `2.52x` 遅い

## 解釈メモ
- `graph_snapshot_query` は index 事前構築済みの warm パス測定。
- `current_cli_like` は DB + symbol index 構築込みの cold 寄り測定。
- build コストは現状 `advanced graph` が重い (`958ms`) ため、初回生成の最適化余地が大きい。
- ただし、反復検索では snapshot/path の効果が非常に大きい。
- `cbor` は現実装で `Json <-> CborValue` 変換を経由するため、decode CPU が増えている。
- `flatbuffers` は schema ベースの直接エンコードに移行したことで、以前の JSON 封入 PoC よりは高速化した。
- ただし decode path は依然として JSON load より重く、型変換・string pool 展開の最適化余地が残る。

## リモート差分シナリオ
- `AdvancedGraphDelta` の diff/apply と JSON roundtrip は `src/xsh/advanced_graph_poc_test.mbt` で検証済み。
- 転送時間の簡易推定 API:
  - `estimate_transfer_time_ms(payload_bytes, bandwidth_mbps, rtt_ms, round_trips)`
- テストでは LAN/CI/mobile 相当プロファイルで `delta < full` を確認。

## 再現メモ
- ベンチワークロード定義: `src/benches/advanced_graph_bench.mbt`
- 実装: `src/xsh/advanced_graph_poc.mbt`
- テスト: `src/xsh/advanced_graph_poc_test.mbt`
