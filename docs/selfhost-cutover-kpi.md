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

### Release gate (≥ 75% performance threshold)

selfhost が host の **75% 程度の性能** に達したら mainline 切替の release-gate を通す。
75% 性能 = wallclock 比 ≤ 1/0.75 = **1.33×** (selfhost / host)。

| 指標 | gate (≤) | 現状 (2026-05-17、heavy cases) | 状態 | 改善必要倍率 |
|---|---|---|---|---|
| compile median ratio | **1.33×** | 3.64× | 🔴 | ~2.7× |
| check median ratio | **1.33×** | 2.23× | 🔴 | ~1.7× |
| compile peak RSS ratio | ≤ 2.0× | 4.51× (旧計測) | 🔴 | |
| check peak RSS ratio | ≤ 2.0× | 2.35× (旧計測) | 🟡 | |
| compile wasm size | ≤ 3.0 MB | 2.00 MB (opt) | 🟢 | |
| check wasm size | ≤ 1.5 MB | 0.91 MB (opt) | 🟢 | |
| selfhost determinism | deterministic | `test-selfhost-bootstrap-gate` 委任 | 🟢 | |
| `test-selfhost-check-parity` | all pass | OK | 🟢 | |
| `test-selfhost-cutover-compare` | all pass | OK | 🟢 | |

`scripts/bench_selfhost_stage2_kpi.sh` のデフォルト threshold は `1.33` に
設定 (`VIBE_SELFHOST_KPI_TARGET_COMPILE` / `VIBE_SELFHOST_KPI_TARGET_CHECK` で override 可)。

heavy cases (`bench/selfhost_perf/kpi_heavy_cases.txt`、1.3K-2.7K LOC) を使う前提
で `vibe x/regexp` + `vibe wasm/wat_encoder` の median を計算した値。kpi_cases.txt
(< 71 LOC) では host の binary cold-start (~150-200ms) が typecheck cost を支配する
ため、ratio が realistic でない。

### Stage 内訳と改善優先度

`bench_selfhost_perf.sh` は per-stage プロファイル (load / type / compile_module
/ emit / write etc.) を `stage_summary.tsv` に出す。直近実測 (2026-05-17、heavy
cases) の selfhost 内訳:

| phase | stage | selfhost share | host vs selfhost ratio | 優先度 |
|---|---|---|---|---|
| **check** | **type** | **79%** | **8.26-8.68×** | 🔴🔴 (最大梃子) |
| compile | emit (codegen) | 33% | 3.90-4.08× | 🔴 |
| compile | load (parse + I/O) | 28% | 4.79-5.24× | 🔴 |
| compile | type | 22% | 3.53-4.24× | 🟠 |
| check | load | 5% | 0.15-0.19× (selfhost 速い) | 🟢 |
| compile | bundle | 6-15% | 3.28-3.65× | 🟡 |
| compile | compile_module | 7-14% | 3.59-3.83× | 🟡 |
| compile | write (Fs::write_bytes) | 2-3% | **46-64×** | 🟡 (絶対値小) |

**最大単一梃子は check の `type` stage** — selfhost check の 79% を消費し ratio 8×。
ここを 1.33× まで縮めるだけで check は gate 通過する (regexp.vibe 実例: type を
1.33× にすると total ratio = 0.54×、完全に余裕)。

`type` stage 改善の主候補 (順序: 高い impact / 低い実装コスト):

1. **selfhost-side checker hot path の特定** — 現状 callstack profile は selfhost
   側で crash する (`vibe bench --profile-callstack` の selfhost wasm 経路で
   `RuntimeError: unreachable`)。これを直して fine-grained breakdown を取るのが
   次の作業。host 側 callstack では `checker/type_check_with_env` が type stage の
   ~40% を占める。同パターンが selfhost にも当てはまるなら、`check_program_with_env`
   / `check_stmts` / `unify` / `subst_apply` あたりが top hotspot のはず。
2. **EnvCached map 経由の env_lookup** (`vibe/compiler/core/types.vibe:141`) — #395
   で synthetic では cold/N に関係なく flat だったが、real fixture では type stage
   の重い割合を占めうる。callstack profile で本当に hot だと確認できたら、当時
   not-planned にした runtime Map → hash 化を再評価する材料になる。
3. **trait resolution / instantiation** — `instantiate` / `unify` / 関連の
   `type_implements_trait` などは型変数 substitution を繰り返す。caching layer の
   見直しで効きそうな箇所。
4. **AST walker の generic tree-traversal overhead** — 同じ AST を type stage で
   何度も walk している可能性。worklist 化や single-pass 化で削れる。

compile の 3 大 stage (emit / load / type) は ratio 4-5× だが selfhost share が
それぞれ 22-33% なので、1 つ潰しても total への寄与は限定的。3 つ並列に attack
する必要がある。但し:

- **load (4.79-5.24×)** は I/O + parse。parse は AST 構築 — selfhost で
  `Array::concat`-accumulator 由来の O(N²) は既に潰した (#366) ので、残る overhead
  は string handling / lex / interpretation 由来の constant factor。改善余地は限定的。
- **emit (3.90-4.08×)** は codegen — selfhost コードは vibe-level の AST/IR walker
  で書かれている。host (MoonBit) は native code、emit が 4× で済んでいるのは比較的
  優秀。1.33× まで持っていくのは moonrun interpreter cost が限界点になりそう。
- **compile の write (46-64×)** は selfhost が wasm bytes を Fs::write_bytes で書く
  経路が非効率 (たぶん 1 byte ずつ encode-then-write している)。絶対値は 30ms 程度
  なので、潰しても total ratio への影響は微小だが、**ratio が異常値で目立つ** ので
  まず確認 → 仕組みが分かれば quick win 候補。

### 大規模な梃子: runtime 切替 (moonrun → wasmtime AOT)

`bench/selfhost_perf/README.md` の postmortem にあるとおり、moonrun は wasm
interpreter で execution time が **dispatch instruction count に比例**。algorithmic
改善が algorithmic改善 で本来 5× 効くものでも、moonrun 上だと wasm size 縮小経由で
~1.5-2× にしかならない。

wasmtime AOT に切り替えると:
- moonrun 内蔵 cost が消える (selfhost ratio が大きく改善する)
- ただし shipping artifacts の build pipeline / WASI binding reshape が必要 (TODO #295)

cutover 用 release gate を 1.33× に置く前提として、**まず "algorithmic 改善で 2×、
runtime 切替でさらに 1.5-2×、合計 3-4× 改善" を見込んだロードマップ**を立てる。
algorithmic だけで 1.33× 到達は厳しい (moonrun の interpreter constant factor が
2× 程度乗っているため)。

逆に言うと: wasmtime AOT runtime に切り替えた瞬間 selfhost ratio は ~2× 改善する
可能性があり、algorithmic 改善は最小限で gate 通過するかもしれない。先に runtime
切替を検討する価値はある。

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
- **session-http daemon の影響に注意 (fixed in commit 288793e+1)**: host CLI は
  デフォルトで session-http daemon を auto-spawn し、`vibe check` のような短時間
  call でも ~1.3s の cold-start ペナルティを払う。selfhost (moonrun) はこの daemon を
  使わないので比較が不公平になる。`bench_selfhost_perf.sh` は host check 呼び出しに
  `VIBE_USE_SESSION_HTTP=0` を渡してこの差を消すよう修正済。古い計測結果 (commit
  日付が修正前のもの) と比較しないこと。
- **kpi_cases.txt (小ファイル) と kpi_heavy_cases.txt (1300+ LOC) で ratio が
  だいぶ違う**: 小ファイルは host の startup cost (~150ms) が typecheck cost を
  支配して selfhost が有利に見えがち。heavy cases (regexp.vibe / wat_encoder.vibe) を
  cutover 判断には使う。

## ロードマップ — close until 1.33× gate

下記の順で攻めると、現状 3.64× / 2.23× → gate 1.33× を狙える。

### Phase 0: 計測基盤の修正 (前提)

- [ ] **selfhost callstack profile crash を直す** — `vibe bench --profile-callstack`
      で selfhost wasm が `RuntimeError: unreachable` で落ちる。これが直ると type
      stage 内の関数別 hot path が見えて、以降の改善が data-driven になる。
- [ ] **session-http overhead 修正の CI 適用** — `bench_selfhost_perf.sh` の
      `VIBE_USE_SESSION_HTTP=0` 追加 (commit `b9b95fc`) を `test-selfhost-perf-gate` の
      threshold 見直しと合わせて運用に乗せる。
- [ ] **release gate を 1.33× で CI に組み込む** — 現状 8.0/5.5 (生暖かい
      threshold)。`VIBE_SELFHOST_PERF_MAX_COMPILE_RATIO=1.33` を最終目標として、
      段階的に絞る (3.0 → 2.0 → 1.33)。

### Phase 1: algorithmic (moonrun 上でも刺さるもの)

| 対象 | 期待効果 | 着手元 | 状態 |
|---|---|---|---|
| **check の type stage 内 hot function 特定** | check ratio 8× → 2-3× | Phase 0 後 | 🔴 todo |
| **compile の write stage の 46-64× 異常値を確認** | compile total への寄与小だが原因究明で他に応用可 | grep `Fs::write_bytes` の selfhost 経路 | 🔴 todo |
| wasm-opt `-Oz` | done | `build_selfhost_wasi_opt.sh` | ✅ |
| O(N²) `Array::concat` → `Array::push` | done | #366 | ✅ |
| stack-copy cycle detection | done | #384 | ✅ |
| Map → hash-backed | not-planned (synthetic では headroom 小) | #395 | ✅ (skipped) — Phase 0 の hot path 特定で再評価候補 |

### Phase 2: 大規模変更 (runtime 移行)

| 対象 | 期待効果 | 着手元 | 状態 |
|---|---|---|---|
| **runtime 切替: moonrun → wasmtime AOT** | **全 selfhost ratio が ~1.5-2× 改善** (interpreter overhead の解消) | blocked: WASI binding reshape (TODO #295) | 🔴 |
| session-http daemon を selfhost で再実装 | host の startup 差を縮める (1.33× gate の達成手段) | open | 🟡 |
| persistent type-env cache の selfhost 実装 | check の type stage 削減 | partial: `vibe/compiler/cache/persistent_cache.vibe` | 🟡 |
| `vibe run` artifact cache の selfhost 実装 | compile/E2E の cold/warm gap 縮小 | open | 🟡 |

### 戦略

**Phase 0 → 1 → 2 の順で進む**。Phase 1 だけで 1.33× 到達は moonrun の interpreter
constant factor 上たぶん厳しい (algorithmic 改善で 2× 入れても moonrun cost 2× が
乗る)。**Phase 2 の wasmtime AOT 移行が解けると一気に 1.33× gate が射程に入る**。

ただし wasmtime 移行が遠ければ、Phase 1 を進めて 2.0× → 1.5× ぐらいまで漸近 し、
moonrun-cost を別途 (session-http daemon 等) で吸収する道もある。Phase 0 の hot
path 特定でどちらに振るか決める。

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
