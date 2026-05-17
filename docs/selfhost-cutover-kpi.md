# Selfhost mainline cutover — KPI tracking

## 目的

vibe コンパイラのメインライン実装を MoonBit 版 (`src/cmd/vibe/`、native binary) から
selfhost 版 (vibe 自身で書かれた `vibe/compiler/`、wasm) に切り替える際の判断基準。
**カットオーバー前提**: 「selfhost が host と同等の速度に到達」かつ「bootstrap
fixed-point (stage1 == stage2) が確定」。

このドキュメントは KPI の定義と計測手順、現状の数値、close until parity の作業
ロードマップを集約する。

## 用語

| 用語 | 定義 |
|---|---|
| **host** | `src/cmd/vibe/vibe.exe` (MoonBit native binary)。現メインライン。 |
| **stage-1 selfhost** | host が `src/cmd/vibe_compile_wasi/` (MoonBit) を wasm にビルドしたもの。`_build/wasm/{release,debug}/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm`。selfhost compiler の "seed" として機能。 |
| **stage-2 selfhost** | stage-1 wasm が、自分自身 (vibe で書かれた selfhost compiler の entry source) を wasm に再コンパイルした出力。Cutover 後のメインラインで実際に shipped されるバイナリ。 |
| **bootstrap fixed-point** | stage-1 のバイト列 == stage-2 のバイト列。これが成り立つと「stage-2 が stage-1 と同じ wasm を再生成できる」= self-reproducing。`test-selfhost-bootstrap-gate` が gate。 |
| **cutover** | メインライン実装を host → stage-2 selfhost に切り替えること。CI と shipped CLI が selfhost wasm を使うようになる。 |

## カットオーバー判断基準 (target KPI)

| 指標 | 目標 | 現状 (2026-05、`bench/selfhost_perf/README.md` 抜粋) | 状態 |
|---|---|---|---|
| compile median ratio (selfhost / host) | **≤ 1.5×** | 3.33× (release + -Oz) | 🔴 |
| check median ratio (selfhost / host) | **≤ 1.5×** | 1.92× | 🟡 |
| compile peak RSS ratio | **≤ 2.0×** | 4.51× | 🔴 |
| check peak RSS ratio | **≤ 2.0×** | 2.35× | 🟡 |
| compile wasm size | **≤ 3.0 MB** | 2.00 MB (opt) | 🟢 |
| check wasm size | **≤ 1.5 MB** | 0.91 MB (opt) | 🟢 |
| bootstrap fixed-point (`stage1 == stage2`) | **deterministic** | OK (`test-selfhost-bootstrap-gate` green) | 🟢 |
| `test-selfhost-check-parity` | **all pass** | OK | 🟢 |
| `test-selfhost-cutover-compare` | **all pass** | OK | 🟢 |

「compile ratio ≤ 1.5×」は妥協値で、ユーザ体感の差が出にくい上限として暫定設定。
最終目標は **1.0×** だが、moonrun (wasm interpreter) のオーバヘッド構造的限界が
あるため、wasmtime AOT への移行 (TODO #295) が前提条件になる可能性が高い。

## 計測コマンド

### KPI まとめ取得 (推奨ループ)

```bash
# 全 KPI 指標を一括取得 + history に append
pkf run bench-selfhost-stage2-kpi
```

これは内部的に:

1. host CLI を build (`scripts/ensure_native_cli.sh`)
2. stage-1 wasm を build (`moon build --target wasm`)
3. stage-1 が selfhost source を再コンパイル → stage-2 wasm 生成
4. `sha256(stage-1) == sha256(stage-2)` を verify (fixed-point check)
5. stage-2 wasm を compiler under test として `bench_selfhost_perf.sh` 実行
6. KPI summary を `bench/selfhost_perf/stage2_kpi_history.tsv` に append

### 個別計測

| KPI | コマンド | 出力 |
|---|---|---|
| compile/check ratio | `pkf run bench-selfhost-perf` | `_build/bench/selfhost_perf/summary.tsv` |
| peak RSS | `pkf run bench-selfhost-memory` | `_build/bench/selfhost_memory/rss_summary.tsv` |
| wasm size | `pkf run bench-bundle-size` | `_build/bench/bundle_size/summary.tsv` |
| bootstrap fixed-point | `pkf run test-selfhost-bootstrap-gate` | exit 0 で合格 |

詳細は `bench/selfhost_perf/README.md`。

### 厳しいゲート (CI 用)

```bash
# 現在の生暖かい threshold (compile <= 8.0, check <= 5.5) で gate
pkf run test-selfhost-perf-gate

# 将来 cutover ready に近づいたら threshold を絞る
VIBE_SELFHOST_PERF_MAX_COMPILE_RATIO=1.5 \
VIBE_SELFHOST_PERF_MAX_CHECK_RATIO=1.5 \
  pkf run test-selfhost-perf-gate
```

## 計測上の注意 (重要)

- **bench harness の per-iter overhead に注意** (`docs/knowledge.md#K-021`, `K-022`)。
  `vibe bench` の non-setup statistical mode は cli_bench.mbt の calibration 修正
  (commits `f907dc7`, `95f77af`) 以降は cold-start を構造的に subtract するが、
  古い結果を見るときは harness 律速の可能性を念頭に。
- `bench_selfhost_perf.sh` は `moonrun` を使う。moonrun は wasm interpreter 系で、
  loop unrolling/inlining より instruction count 最小化が効く (`scripts/build_selfhost_wasi_opt.sh`
  が `-Oz` をデフォルトにしている理由)。wasmtime AOT に切り替えると、同じ wasm でも
  cost model が変わる (-O3 が有利になる)。Cutover 時点の runtime によって最適化方針が変わる。
- **RSS 計測は Linux 限定** (`/usr/bin/time -v` の `Maximum resident set size` を読む)。
  macOS は `gnu-time` を install して PATH に通すこと。

## ロードマップ — close until parity

| 期待される効果 | 着手元 | 状態 |
|---|---|---|
| wasm-opt `-Oz` (moonrun では `-O3` より速い、size も小) | done (`build_selfhost_wasi_opt.sh`) | ✅ |
| O(N²) `Array::concat` accumulator → `Array::push` migration | done (#366) | ✅ |
| selfhost runtime `Map::has_key` / `Map::get` を hash-backed table 化 | not-planned (#395 calibrated bench で ROI ≪ 1.5× headroom) | ✅ (skipped) |
| stack-copy cycle detection (typecheck_fs / runtime/index) | done (#384 で push/truncate 化) | ✅ |
| **runtime 切替: moonrun → wasmtime AOT** | blocked: WASI binding reshape (TODO #295) | 🔴 |
| **session-http daemon を selfhost で再実装** | open: 現状 host だけ持つ最適化 | 🟡 |
| **persistent type-env cache の selfhost 実装** | partial: `vibe/compiler/cache/persistent_cache.vibe` | 🟡 |
| **`vibe run` artifact cache の selfhost 実装** | open | 🟡 |

最大の梃子は **wasmtime AOT runtime への切替**。これが解けない限り、algorithmic な
selfhost-side optimization は moonrun の interpreter cost に飲まれて user-visible な
改善にならない (`bench/selfhost_perf/README.md` の "String-keyed lookup postmortem"
が同じ轍を踏んだ実例)。

## 既存実装の信頼度

- **bootstrap-gate** が安定的に green → stage-1 と stage-2 がバイト一致 → 性能特性も同一
- → 当面は「stage-2 用に再ビルド」を毎回やらず、`bench-selfhost-perf` の stage-1
  数値を stage-2 として扱って差し支えない
- ただし bootstrap-gate が落ちている期間は要再計測 (cutover も保留)

`bench-selfhost-stage2-kpi` script は念のため毎回 fixed-point を verify してから
計測する設計にしてある。

## 関連

- `bench/selfhost_perf/README.md` — bench methodology / postmortem
- `docs/knowledge.md#K-021` — bench harness calibration 落とし穴
- `docs/knowledge.md#K-022` — flat measurement 結論前に harness を疑う
- `scripts/bench_selfhost_perf.sh` — host vs selfhost wallclock 計測
- `scripts/test_selfhost_bootstrap_gate.sh` — fixed-point check
- `scripts/test_selfhost_wasi_selfbuild.sh` — selfhost self-build
- TODO #295 — selfhost perf gap cutover 水準まで
