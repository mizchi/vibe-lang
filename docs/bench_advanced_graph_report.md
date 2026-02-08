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
- `bench: graph_remote.apply_full_snapshot`
- `bench: graph_remote.apply_delta`

## 結果
- graph_build.current_symbol_index_cold: `401.69 ms ± 18.31 ms`
- graph_build.advanced_graph_index_cold: `960.49 ms ± 55.06 ms`
- graph_search.current_cli_like: `364.28 ms ± 31.32 ms`
- graph_search.graph_snapshot_query: `117.48 µs ± 0.47 µs`
- graph_search.graph_json_load_query: `1.44 ms ± 265.59 µs`
- graph_remote.apply_full_snapshot: `1.20 ms ± 5.52 µs`
- graph_remote.apply_delta: `1.02 ms ± 3.05 µs`

## 比較
- 検索 (current_cli_like -> graph_snapshot_query): 約 `3100.78x` 高速
- 検索 (current_cli_like -> graph_json_load_query): 約 `252.97x` 高速
- remote apply (full -> delta): 約 `1.18x` 高速（約 `15.0%` 短縮）

## 解釈メモ
- `graph_snapshot_query` は index 事前構築済みの warm パス測定。
- `current_cli_like` は DB + symbol index 構築込みの cold 寄り測定。
- build コストは現状 `advanced graph` が重い (`960ms`) ため、初回生成の最適化余地が大きい。
- ただし、反復検索では snapshot/path の効果が非常に大きい。

## リモート差分シナリオ
- `AdvancedGraphDelta` の diff/apply と JSON roundtrip は `src/xsh/advanced_graph_poc_test.mbt` で検証済み。
- 転送時間の簡易推定 API:
  - `estimate_transfer_time_ms(payload_bytes, bandwidth_mbps, rtt_ms, round_trips)`
- テストでは LAN/CI/mobile 相当プロファイルで `delta < full` を確認。

## 再現メモ
- ベンチワークロード定義: `src/benches/advanced_graph_bench.mbt`
- 実装: `src/xsh/advanced_graph_poc.mbt`
- テスト: `src/xsh/advanced_graph_poc_test.mbt`
