---
name: selfhost-miscompile-bisect
description: backend(gc/linear/RC)でコンパイルしたコンパイラ自身が誤動作するとき、probe entry の追記とフェーズ二分で miscompile を特定する手法。コンパイラの self-compile が hang する・誤った診断を出す・出力が linear と食い違うときに使う。
---

# selfhost miscompile bisect — backend バグをコンパイラ自身の実走で特定する

backend X(wasm-gc lane 等)でコンパイルしたコンパイラ(以下「X-compiled compiler」)が
誤動作する(hang / 誤診断 / 出力差分)とき、原因はほぼ確実に backend X の **miscompile**
(コンパイラのソースは linear で実証済みのため)。以下の手順で「どの言語構文がどう
壊れているか」まで最小化する。#538 P4.5(gc lane の self-compile fixpoint 到達)で
7 件の miscompile をこの手法で連続特定した実績がある。

## 前提となる成果物とコマンド

```bash
# 1. 修正入りの linear CLI(stage2e)を作る: committed bundle を最新 stage2 でコンパイル
VIBE_REGEN_MODULE_SOURCE=1 \
  VIBE_ADAPTER_MODULE_SOURCE_OUT=lib/@vibe/compiler/_cli_adapter_module_source.vibe \
  bash scripts/generate_bundle.sh
STAGE2="$(ls -t _build/selfhost/generations/*/stage2.wasm | head -1)"
env VIBE_RC=0 VIBE_PREOPEN_DIR="$PWD" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
  lib/@vibe/compiler/_cli_adapter_module_source.vibe _build/gc538/stage2e.wasm cli_main

# 2. stage2e で bundle を backend X でコンパイル(X-compiled compiler を得る)
env VIBE_BACKEND=gc VIBE_RC=0 VIBE_PREOPEN_DIR="$PWD" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main _build/gc538/stage2e.wasm \
  lib/@vibe/compiler/_cli_adapter_module_source.vibe _build/gc538/bundle_gc.wasm cli_main

# 3. X-compiled compiler を実走(entry は _start: argv は "vibe" host import 経由)
env VIBE_RC=0 VIBE_PREOPEN_DIR="$PWD" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke _start _build/gc538/bundle_gc.wasm \
  <input.vibe> <out.wasm> main
```

常設の総合計測は `bash scripts/test_gc_selfbuild.sh _build/gc538/stage2e.wasm`
(probes / bundle compile / run E2E / self-compile fixpoint)。

## 手順

### 1. 症状の分類

- 出力ファイルなし + `<out>.diag` あり → 誤診断(checker/effect 系の比較 miscompile が典型)
- 出力なし + diag なし + CPU 100% → **hang**(worklist の pop 不全、比較の恒真/恒偽が典型)。
  `timeout N` + `time` で user time を見る(busy loop か I/O 待ちか)
- 出力ありだが linear 版と `cmp` で差分 → `cmp -l` で差分バイトを列挙。**差分が少ないほど
  情報量が多い**(例: f64 定数の上位 2 bytes だけ 0 → float リテラルの 0 化)

### 2. フェーズ二分 — bundle に probe entry を追記する

flat bundle は namespace が平坦なので、末尾に 0 引数 entry を足すだけで
**内部関数を任意に呼べる**。scratch にコピーして追記し、`entry_name` に probe 名を渡す:

```vibe
// bundle コピーの末尾に追記(commit しない)
export let probe_check: () -> Int with Error = () -> {
  let stmts = parse_program(lex("export let main = () -> Int { 40 + 2 }"))
  expand_interp_stmts(stmts)
  let _ = check_program(stmts)
  1
}
```

```bash
env VIBE_BACKEND=gc VIBE_RC=0 ... --invoke cli_main _build/gc538/stage2e.wasm \
  $SCRATCH/bundle_probe.vibe $SCRATCH/bp.probe_check.wasm probe_check
timeout 60 env ... --invoke _start $SCRATCH/bp.probe_check.wasm
```

lex → parse → interp → check → codegen の順に probe を作り、最初に壊れる段を特定。
さらにその段の内部(check_program なら check_stmts / check_program_bounds /
collect_async_effect_errors...)へ probe を掘る。**1 回の bundle compile は ~1 分**
なので、複数の検証は 1 つの probe 関数にまとめて返り値に多重エンコードする
(`a * 1000 + b * 100 + ...`)か、`Fs::write_file` でダンプを書く。

### 3. 単体 probe への最小化

疑わしい構文パターンが見えたら、bundle 不要の単一ファイル probe にして
**gc と linear の両方でコンパイル・実行して比較**する(数十秒):

```bash
for BE in gc ""; do env ${BE:+VIBE_BACKEND=$BE} VIBE_RC=0 ... --invoke cli_main \
  _build/gc538/stage2e.wasm probe.vibe probe.$BE.wasm main; done
wasmtime run -W gc=y,function-references=y,exceptions=y probe.gc.wasm   # gc 側
env VIBE_PREOPEN_DIR="$PWD" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start probe.lin.wasm
```

差分が出れば最小再現。そこから削って 1 構文まで絞る(hang は guard カウンタ
`while cond && guard < 100` を入れて「何回回ったか」を数値で観測すると速い)。

### 4. emit された wasm を直接読む

```bash
wasm-tools print out.wasm | less        # call/drop の並びで stub・欠落が一目で分かる
```

関数 index → 対応の目安: imports(0..hbo) → 生成 builtin(hbo+1..hbo+num_generated) →
user 関数(func_offset = 1 + hbo + num_generated から bundle の SLet-EFn 順)。
trap の `wasm-function[N]` はこの対応で source 関数に翻訳できる。

### 5. 修正 → fixpoint 検証ループ

修正のたびに: bundle 再生成 → stage2e 再ビルド → bundle_gc 再コンパイル →
tiny E2E(`cmp` で linear 出力と一致)→ self-compile
(bundle_gc に bundle 自身をコンパイルさせ、stage2e と `cmp`)。
**byte 一致 = fixpoint** が最終合格。ゲートは
`bash scripts/test_gc_selfbuild.sh` と `bash scripts/compiler_gate.sh`。

## 落とし穴(実際に踏んだもの)

- **probe 内の `print()` は使わない**: gc lane の print は `__to_string` 経由で、
  String を渡すと packed pointer が数値で出る(それ自体が #538 のバグだったが、
  修正後も型により挙動が違う)。数値エンコード返却か `Fs::write_file` を使う。
- **VIBE_RC=0 を常に pin**: RC ビルドの stage は結果が RC-tag されて読み違える。
- **「hang」は miscompile の可能性を先に疑う**: #538 では深い再帰による stack
  overflow に見えたものが、実際は eq 恒偽による異常経路だった。`--stack-size` を
  増やして挙動が変わるかで「正当な深い再帰」と「サイクル」を切り分けられる。
- **診断メッセージの "expected X, got X"**: 表示上同一 = 表示関数(type_to_string 等)
  自身も同じ miscompile を踏んでいるサイン。比較と表示の共通基盤(この時は
  for-in 内包表記)を疑う。
- **runner の終了コードは当てにしない**: パイプ越しの `rc=$?` は tail の rc。
  出力ファイルの有無と `.diag` で判定する。
