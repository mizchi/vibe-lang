# Done

Completed items archived from `TODO.md`.

## ビルドパイプライン (2026-03-20)

### `vibe build --debug` linked compilation

- `vibe compile --library` — `_start` なし export-only .wasm 生成
- codegen: linked imports — import した関数を wasm import として emit
- `bundle_for_wasm_linked` — import 先を inline せず linked imports リスト返却
- `vibe build --debug` — import 先を `.vibe/debug/` にキャッシュ、linked compile
- `vibe build --release` — monolithic + wite -Oz 最適化 (exceptions 非対応時フォールバック)
- `vibe run` デフォルト linked debug — 初回はバックグラウンドでキャッシュ自動作成
- `vibe clean` — debug linked build cache 削除
- lazy heap init — `require_heap` で遅延初期化
- multivalue return — tuple 返り値の linked import シグネチャ対応
- memory/heap_ptr 共有 — user module が library の memory と __heap_ptr を import
- data section オフセット調整 — user module の string を 64KB offset に配置
- ソース hash ベースのキャッシュ判定 — content_address_hash でソース変更検出
- linked import builtin shadowing 修正 — is_user_fn で builtin 回避
- HOF (高階関数) auto-inline — HOF export を含むモジュールは自動 monolithic フォールバック
- `.vibe/debug` cache ホイスティング — nearest parent `.vibe/` (with cache.json) に集約
- debug/release parity: 11 テストケース + 257 fixture で検証済み (0 mismatch)

**計測結果:**
- `vibe build --debug` cached: **10ms** (monolithic 250ms → 48x)
- `vibe run` cached: **31ms** (monolithic 270ms → 8x)

### テスト高速化

- `ensure_native_cli.sh` — ビルドキャッシュ (250ms → 20ms)、20 スクリプト + justfile 移行
- `VIBE_SKIP_FIXTURES=1` — `just test` から fixture インタプリタ実行をスキップ
- `just test-wasm-heavy` — wasm_opt/wasm_runtime を分離 (wasm_opt 258s → 10s with minify_zlib disabled)
- テストバッチ化 — 同一ファイル内テストを 1 WASM にまとめてコンパイル
- fixture isolation テスト (`test_fixtures_isolation.sh`) — abort/crash/timeout をプロセス単位で検出
- build parity テスト (`test_build_parity.sh`) — debug vs release 結果一致検証
- minify_zlib_test 無効化 — 4分超のテストを disabled (#13)
- vibe.exe test linked build 検証 — 効果なし (支配要因は wasmtime 上の WASM interpreter 実行)

### バグ修正

- effect rewrite 無限再帰修正 — `reh_replace_performs_expr` で内側 Handle の再帰呼出しを回避
- eval.mbt abort → raise — perform/spread で EvalError を raise (プロセス crash 防止)
- cross-module string data offset 二重適用修正

## Effect System (2026-03-18)

- effect 宣言、perform 式、handle/resume (tail-resumptive inline)
- with { Effect } スコープ追跡
- perform Error::Throw → Raise desugar
- effect rewrite の無限再帰修正

## WASM Exceptions + suberror (2026-03-18)

- throw は常に tagged string object を投げるように変更
- catch 側で tagged string が正しく復元される
- suberror constructor → Error 型への自動変換
- suberror payload, pattern match 対応

## vbundle 廃止

vbundle 形式を廃止し、`.vibe/cache.json` + `index.lock` に完全移行済み。
