---
name: compiler-perf-profiling
description: vibe compiler の性能改善手順 — node --cpu-prof での実コンパイルのプロファイル取得、phase bench (__bench_ export) の実行、ホットスポットの読み方、修正→fixpoint→回帰の検証ループ。コンパイルが遅い・CI が遅い・bench の退行を調べるときに使う。
---

# compiler perf profiling — 計測してから直す

vibe compiler (selfhost, linear/RC lane) の性能改善は「synthetic bench で当たり
をつける」より「**実コンパイルを node --cpu-prof でプロファイルする**」方が
圧倒的に速く核心に届く。#799 でこの手順により重量級コンパイルを 39s→4s
(約10倍) にした実績がある。

## 0. ワンコマンド: scripts/profile_compile.sh

§1 の cpu-prof + self-time 集計と §3 のメモリ統計 (heap 高水位 / linear
memory / RSS) を 1 コマンドに束ねたもの。まずこれを叩き、深掘りが必要に
なったら §1 以降の手作業に降りる。

```bash
scripts/profile_compile.sh /tmp/gen/stage2.wasm            # 既定 corpus
scripts/profile_compile.sh /tmp/gen/stage2.wasm foo.vibe 30
```

## 0.5 Control the persistent cache, or the numbers lie (#2393)

The FS compile lane consults the persistent caches under `_build/vibe_*`, and
the typing cache is **content-keyed, not compiler-keyed** — so a freshly
rebuilt stage2's FIRST run can be silently WARM, served by entries the
baseline run just wrote. Measured on the same corpus, same machine: cold
8.0s / 1.46GB heap_ptr vs warm 4.7s / 727MB. That gap is bigger than most
real optimizations, and it produced a wrong "−31% wall, −42% heap" claim in
PR #2393 (cold baseline vs warm candidate; the honest cold-vs-cold answer
was +3.5%).

Protocol for ANY before/after comparison on this lane:

- Isolate the cache per run: `VIBE_BUILD_CACHE_DIR=$(mktemp -d)` (the
  override lives in `cache/cache_underlying.vibe`). Fresh dir = cold run;
  a second run in the same dir = warm run.
- Compare **cold-vs-cold AND warm-vs-warm**, never across temperatures.
  Both lanes matter: cold is CI / first build, warm is the dev inner loop.
- **N≥3 runs per configuration** — single-run wall deltas under ~5% are
  noise on a shared machine.
- `scripts/profile_compile.sh` does NOT isolate the cache; wrap it with
  `VIBE_BUILD_CACHE_DIR` yourself before trusting its wall/heap output.
- Cross-check against the PR perf-report's deterministic rows (selfcompile
  heap, B/op, fuel): if the report says ±0 and your local profile says
  −40%, the local measurement is contaminated — believe the deterministic
  lane and find the leak in your method first.

## 1. まず実コンパイルをプロファイルする (最重要)

```bash
S2=<stage2.wasm>   # 現行 stage2 (scripts/generations.sh build の成果物)
VIBE_PREOPEN_DIR="$PWD" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  node --cpu-prof --cpu-prof-dir=/tmp --cpu-prof-name=compile.cpuprofile \
  scripts/wasm_vibe_host_runner.js --invoke cli_main "$S2" \
  lib/@vibe/compiler/tests/codegen_lexer_test.vibe /tmp/out.wasm __no_entry__
```

対象は「compiler closure を丸ごと compile する重いテスト」(codegen_*_test /
cli_test / selfhost_s5_* など) が良い。self 時間の集計:

```python
import json, collections
p = json.load(open("/tmp/compile.cpuprofile"))
nodes = {n["id"]: n for n in p["nodes"]}
c = collections.Counter()
for sid, dt in zip(p["samples"], p["timeDeltas"]):
    c[nodes[sid]["callFrame"]["functionName"] or "(anon)"] += dt
total = sum(c.values())
for fn, us in c.most_common(20):
    print(f"{us/1000:8.1f}ms {us*100/total:5.1f}%  {fn[:100]}")
```

### プロファイルの読み方

- **wasm 関数は name section の名前で出る**。user 関数は
  `foo_exp_lib__vibe_compiler_..._vibe` 形式。生成 runtime helper は
  `__rt_str_eq` / `__rt_arr_get` / `__rt_rc_drop` など (#799 で命名済み。
  もし `wasm-function[N]` が上位に出たら name section の命名漏れ —
  linked_compile.vibe の gen_sec_names に追記する)。
- **ADR-0077 以降、release ビルドは name section を既定で strip する**。
  プロファイル対象の stage2/CLI wasm は **`VIBE_WASM_NAMES=1` を付けて
  ビルドし直す**こと (例: `VIBE_WASM_NAMES=1 bash scripts/generations.sh
  build --out-dir /tmp/prof_gen`)。全フレームが `wasm-function[N]` に
  なったら strip 済み wasm を profiling している。
- **`(garbage collector)`** = V8 側。wasm linear memory の grow コピーや
  runner JS のアロケーション churn が原因のことが多い。
- **runner JS の関数** (findClosureEnv 等) が上位に出たら**ハーネス側の異常**を
  疑う。#799 では `--invoke cli_main` が WASI 慣習の `_start` で全コンパイルを
  先に 1 回走らせ、二重コンパイルになっていた (現 runner は cli_main invoke
  時に pre-start をスキップ。`VIBE_FORCE_RUN_INIT=1` で旧挙動)。
- 過去の頻出パターン: **「巨大な flat 名前配列への文字列線形走査」**
  (array_contains_str / collect_free_vars 系)。ident ごと × 数千名 =
  O(N²)。修正は「compile 単位で 1 回だけ Map index を作り CompileCtx に
  載せる」(capture_name_index / collect_used_builtin_names を参照)。

## 2. phase bench (補助: 相対比較・退行検知向け)

`bench "name" { ... }` block は `__bench_<name>` として export される。
node runner の bench mode で回す:

```bash
# compile (テストと同じ __no_entry__ sentinel で OK)
VIBE_PREOPEN_DIR="$PWD" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$S2" \
  lib/@vibe/compiler/parser_bench.vibe /tmp/b.wasm __no_entry__

# 実行 (合計 µs が出る。/N して µs/iter)
VIBE_PREOPEN_DIR="$PWD" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke "__bench_selfhost/parse_deep_binop_chain" \
  --bench-count 20 --bench-warmup 3 --bench-setup _start /tmp/b.wasm
```

phase bench: selfhost_{lexer,parser,checker,codegen}_bench.vibe。

### bench の罠

- **module-level let がある bench は `--bench-setup _start` が必須**
  (module init 前に bench export を叩くと未初期化 global で即例外)。
- **`_start` は bench body を一巡 smoke 実行する**。どれか 1 つの bench が
  throw すると module ごと落ちる。
- **ファイルを読む probe は `perform Fs::ReadFile` ではなく direct-call
  `Fs::read_file` で書く** (unhandled perform は必ず throw する — #768/#794
  の direct-call 規約)。
- **bench 対象ファイルの stale 化に注意**: パッケージ移動 (#753) で
  `syntax/lexer.vibe` が 14 行の re-export shim になり、それを測り続けて
  いた bench があった。~80µs など不自然に速い数字は corpus を疑う。
- **計測は無負荷で**。バックグラウンドの回帰やビルドと同時に測らない。

## 3. vibe 固有の他の計測手段

| 手段 | 取れるもの |
|---|---|
| `Profiler::now_us` | 任意区間の実時間 (cache_probe_*_bench_test 群が使用) |
| `Profiler::heap_bytes` | 任意区間のアロケーション量 (bump-heap pointer。now_us の allocation 版 — bump は解放しないので delta = その区間の確保量) |
| `vibe test --coverage` | 関数/分岐 hit bitmap (通ったか。回数は取れない) |
| debug_trace (`vibe.trace` section) | 関数 entry の実行順列 (先頭 4096) |
| runner `--bench-count` + `--mem` 系 | ns/op, bytes/op (bump-heap delta) |

### メモリ計測 (runner 側、ゲスト変更不要)

- **`VIBE_WASM_MEMORY_STATS=1`**: run/bench 終了時に `[wasm-memory] ...
  pages= bytes= heap_ptr= rss=` を stderr に 1 行出す。heap_ptr が bump 高水位。
  参考値: 重量級 full-closure compile (codegen_lexer_test) 1 回で
  heap ~362MB / RSS ~428MB (2026-07 計測)。
- **`VIBE_PROFILE_MEMORY_MARKS=1`**: ゲストが `Profiler::now_us` を呼ぶ
  たびに `[profile-memory] mark=N ...` を出す。profiled compile (full CLI
  entry の `--profile-tsv` / `VIBE_PROFILE_TSV`) は stage 境界で now_us を
  呼ぶので、stage ごとのメモリ推移が取れる。**注**: generation の stage2
  (flat low-level entry) は profiled path を持たないため marks は出ない —
  dist / `vibe/cli` entry の wasm で使う。
- ゲスト内で区間を自分で測るなら `Profiler::heap_bytes` (上表)。

## 4. 修正したら必ずこの順で検証する

```bash
# a. bundle regen (compiler source を触ったら必須)
VIBE_REGEN_MODULE_SOURCE=1 \
  VIBE_ADAPTER_MODULE_SOURCE_OUT=lib/@vibe/compiler/_cli_adapter_module_source.vibe \
  bash scripts/generate_bundle.sh

# b. stage rebuild + fixpoint (stage2 == stage3 が絶対条件)
bash scripts/generations.sh build --out-dir /tmp/gen --stage3 --skip-run-validation
cmp /tmp/gen/stage2.wasm /tmp/gen/stage3.wasm

# c. 最適化の同値性: 修正前 stage2 と修正後 stage2 で同じファイルを
#    コンパイルし、出力 wasm を byte 比較 (純最適化なら一致するはず)

# d. 再プロファイル (狙ったホットスポットが消えたか)

# e. 全体回帰
VIBE_SELFHOST_STAGE2_WASM=/tmp/gen/stage2.wasm bash scripts/unit_test_runner.sh
```

### 検証の罠 (実際に踏んだもの)

- **アロケーション churn は RC lane で顕在化する**: 毎呼び出しで大きな
  入れ子構造 (CtFn/Array の表など) を再構築すると、bump では動くが
  RC の in-process コンパイルテストが OOB で落ちる。module-level let で
  メモ化する (module let は一度だけ初期化される —
  fixtures/module_let_memo_test.vibe が仕様)。
- **並列回帰と cache 系テスト**: persistent cache の状態を検査するテストは
  並列 fan-out と競合する (runner は path に "cache" を含むテストを
  シリアル tail で回す)。並列で 1 件だけ落ちたらまず単独再実行で切り分け。
- 実行中の回帰がある間に runner の .sh/.js を編集しない (bash は script を
  逐次読みするため、実行中プロセスの挙動が壊れる)。
