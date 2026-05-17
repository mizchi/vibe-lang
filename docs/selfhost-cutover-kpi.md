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
| **stage-2 selfhost** | stage-1 wasm が、`vibe/compiler/index.vibe` (vibe で書かれた selfhost compiler entry) を wasm に再コンパイルした出力。Cutover 後のメインラインで実際に shipped されるバイナリ。 |
| **stage-3 selfhost** | stage-2 wasm が **自分自身を再 emit** した出力。`stage-2 == stage-3` (バイト一致) なら selfhost codegen は自己再生産可能 = 決定論的。 |
| **selfhost determinism (fixed-point)** | stage-2 == stage-3。これが成立して初めて cutover 後の再 build が安定する。**stage-1 と stage-2 はバイト一致を期待しない** (host MoonBit codegen と selfhost vibe codegen は別実装で出力 wasm の bit-level shape も違う; 機能的等価性は `test-selfhost-check-parity` / `test-selfhost-cutover-compare` が gate)。 |
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
| selfhost determinism (`stage2 == stage3`) | **deterministic** | 要計測 (`pkf run bench-selfhost-stage2-kpi`) | ⚠️ |
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
2. stage-1 wasm を build (`moon build --target wasm src/cmd/vibe_compile_wasi`)
3. stage-1 が `vibe/compiler/index.vibe` を compile → stage-2 wasm
4. stage-2 が同じ `vibe/compiler/index.vibe` を compile → stage-3 wasm
5. `sha256(stage-2) == sha256(stage-3)` を verify (selfhost determinism check)
6. stage-2 wasm を compiler under test として `bench_selfhost_perf.sh` 実行
7. KPI summary を `bench/selfhost_perf/stage2_kpi_history.tsv` に append

`VIBE_SELFHOST_KPI_SKIP_FIXED_POINT=1` で 3-4 を skip し stage-1 (host emit) を
proxy として測定可。fast-path、bootstrap が直前で green と分かっている時用。

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
- **check_ratio が 1.0 を切る (selfhost が「速い」) 場合の解釈**: 現状の
  bench_selfhost_perf.sh 内 host check は `vibe check` を直接呼び、コマンド毎に
  session-http daemon spawn / native binary cold start を payback する。1 ファイル
  あたり ~1100ms のうち本来の typecheck cost は数十 ms 程度。selfhost 側は moonrun
  常駐コストのみで、結果として比率が逆転する。**この時点で「selfhost の check が
  host より速い」と結論しない**。正しく比較するなら host 側に session-http persistent
  mode を導入するか、両者の warm-call 時間を測る。次に改善するべき計測項目候補。

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

- 既存 `test-selfhost-bootstrap-gate` は「同じ compiler で同じ source を 2 回 compile
  して bit 一致するか」を測る (determinism)。本 doc の selfhost determinism
  (stage-2 == stage-3) はそれを cutover 文脈に対応付けた呼び方。
- 機能的等価性は `test-selfhost-check-parity` / `test-selfhost-cutover-compare` が
  別途 gate。perf 計測時点で両方 green である前提。
- stage-1 (host emit) と stage-2 (selfhost emit) は **バイトが一致しなくて当然**
  (codegen の実装が違う)。性能だけが等価性の対象。

`bench-selfhost-stage2-kpi` script は毎回 stage-2 → stage-3 を再 emit して
determinism を verify する。それが失敗すると selfhost 自身が壊れている (再 build
できない) 状態で cutover してはいけない。

## 関連

- `bench/selfhost_perf/README.md` — bench methodology / postmortem
- `docs/knowledge.md#K-021` — bench harness calibration 落とし穴
- `docs/knowledge.md#K-022` — flat measurement 結論前に harness を疑う
- `scripts/bench_selfhost_perf.sh` — host vs selfhost wallclock 計測
- `scripts/test_selfhost_bootstrap_gate.sh` — fixed-point check
- `scripts/test_selfhost_wasi_selfbuild.sh` — selfhost self-build
- TODO #295 — selfhost perf gap cutover 水準まで
