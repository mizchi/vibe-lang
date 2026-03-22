# ADR-0032: Adopt `wite.cfp_const_hints` for Wite-facing Wasm Optimization

- Date: 2026-03-21
- Status: accepted
- Related: ADR-0002 (multi-backend compilation), ADR-0010 (WASM Component Model), ADR-0027 (capability DCE), ADR-0031 (component externals)
- External reference: `wite/docs/adr/0001-cfp-const-hints.md`

## Context

`vibe` の wasm ビルドでは、frontend / bundler が wrapper の生成規則を知っている一方、
`wite` は最終 wasm bytes からそれを再推論して最適化する必要がある。

このギャップは特に次の wrapper で効いてくる。

- `const-forward` wrapper
- `interleaved-const` wrapper

これらは source や bundler の位相では自明でも、lowering 後の wasm だけを見ると
判定がやや不安定になる。`wasm-opt` との差分を汎用 CFG 最適化だけで埋めるのはコストが高い。

そのため、`vibe` は intermediate core wasm に custom section を埋め、
`wite` の既存 pass に対して「この wrapper は const-forwarding 候補である」という
seed を渡せるようにする。

当初は `vibe.optimize_hints` のような広い internal metadata も検討したが、
現時点で `wite` 側に実装されている contract は `wite.cfp_const_hints` に絞られている。
`vibe` 側もまずはその contract に合わせる。

## Decision

### 1. `vibe` は `wite.cfp_const_hints` を emit する

`vibe` は `--wite` 経路の intermediate core wasm に、producer 非依存の custom section
`wite.cfp_const_hints` を埋める。

- section 名は `wite.cfp_const_hints`
- section は advisory metadata であり、`wite` は常に無視してよい
- 最適化を強制する contract ではなく、candidate seed を与える contract とする
- final artifact の公開 contract ではない

### 2. v1 の対象は `cfp-const` 系 wrapper のみ

v1 で扱うのは次に限定する。

- `const-forward` wrapper
- `interleaved-const` wrapper

`if-wrapper` や root hint、より強い意味論は v1 には入れない。

### 3. emit の基準は「最終 wasm に対する absolute function index」

hint が参照する `wrapper_index` / `target_index` は、import を含んだ absolute function index
とする。local-only index は使わない。

この index は `call` 命令の operand と同じ意味を持つ必要がある。

### 4. hint payload は raw instruction recipe を使う

v1 payload:

```text
version: u32 = 1
entry_count: u32
repeat entry_count times:
  wrapper_index: u32
  target_index: u32
  arg_instr_count: u32
  repeat arg_instr_count times:
    instr_len: u32
    instr_bytes: byte[instr_len]
```

各 `instr_bytes` は target 呼び出しへ渡す引数 recipe の 1 命令を表す。v1 では次のみ許可する。

- `local.get <wrapper_param_index>`
- `i32.const`
- `i64.const`
- `f32.const`
- `f64.const`

### 5. `vibe` は `wite` 実装済み contract から外れない

`vibe` は次のような情報を hint に載せない。

- `pure`
- `no-trap`
- `alias-free`
- `does-not-escape`
- 任意の CFG 簡約を許す意味論

最初の連携は wrapper shape だけに限定し、optimizer と frontend の結合を最小化する。

## Producer Contract

`vibe` が 1 entry を emit してよいのは、次をすべて満たす場合だけとする。

- `wrapper_index` / `target_index` が emitted wasm の実 index と一致する
- arg recipe が target の全 param を順に埋める
- `local.get` は wrapper param のみを参照する
- wrapper local / temp local を recipe に含めない
- wrapper の各 param は recipe 全体でちょうど 1 回だけ使う
- 1 引数 = 1 instruction とし、余計な bytes を含めない
- block / if / loop / call など複合命令を含めない

言い換えると、`vibe` は「`wite` が構造的に validate できる entry」だけを出す。
少しでも怪しい場合は hint を出さない。

## Consumer Semantics Assumed By `vibe`

`vibe` がこの ADR を前提にするとき、`wite` 側の意味論は次を想定する。

### `cfp-const`

hint は、次を満たすときだけ alias candidate として採用される。

- wrapper が local function
- wrapper / target type が recipe と整合する
- recipe に const arg が 1 つ以上ある
- 各 recipe instruction がちょうど 1 命令として decode できる
- scratch local が必要な場合、wrapper param type を 1-byte value type として再構成できる
- auto detect alias がある場合はそちらを優先する

その上で、既存 profitability 判定を通った場合だけ rewrite される。

### `cfp-const-specialize`

structural に valid な hint でも、specialize はさらに次を満たすときだけ候補になる。

- wrapper が root ではない
- wrapper が local decl を持たない
- target が local function
- target の direct caller 数が 1
- recipe が scratch local を必要とする
- type / profitability / root policy をすべて通る

つまり、hint を emit しても optimize が必ず発火するわけではない。

## Validation And Observability

`vibe` 実装時は、次の観測を前提にする。

### `wite analyze host`

experimental flag 有効時に、少なくとも次を見られる。

- hint section 数
- unknown version section 数
- malformed section 数
- parsed entry 数
- usable entry 数
- `cfp-const` structural reject reason 件数
- `cfp-const-specialize` candidate 数
- `cfp-const-specialize` reject reason 件数

主な reject reason:

`cfp-const` structural reject:

- `wrapper-not-local`
- `self-target`
- `wrapper-index-out-of-range`
- `target-index-out-of-range`
- `wrapper-type-missing`
- `target-type-missing`
- `recipe-type-mismatch`
- `scratch-local-types-unsupported`

`cfp-const-specialize` reject:

- `wrapper-root`
- `wrapper-body-missing`
- `wrapper-index-out-of-range`
- `wrapper-type-missing`
- `wrapper-has-locals`
- `self-target`
- `target-root`
- `target-direct-callers!=1`
- `target-not-local`
- `target-index-out-of-range`
- `target-body-missing`
- `target-type-missing`
- `scratch-not-needed`
- `cfp-const-still-profitable`
- `recipe-type-mismatch`
- `specialize-build-invalid`

### `OptimizeResult.observations`

experimental flag 有効時は、通常の `optimize` / `build` / `treeshake` でも
`OptimizeResult.observations` に同じ hint 集計が入る。

- core optimize では必要に応じて `round#N:` が付く
- component optimize では `core#M:` が付く
- `hint-section-stripped=true|false` で strip 結果も見える

`vibe` 側の導入初期は、この `observations` を benchmark / debug 出力で確認する。

## Emission Point In `vibe`

hint は source AST ではなく、bundling 済み module から core wasm を emit する直前または直後に作る。

```text
bundle_for_wasm
  -> decide final helper / wrapper placement
  -> emit core wasm
  -> append wite.cfp_const_hints
  -> call wite optimize
  -> consume hints
  -> strip only if a hint-driven rewrite succeeded
```

この位相なら、function index と wrapper shape を emitted wasm と一致させやすい。

## Rollout Plan

### Phase 1

`vibe` 側で `wite.cfp_const_hints` writer を実装する。

- feature flag で opt-in
- `const-forward` / `interleaved-const` だけを emit
- malformed になりうる entry は出さない

### Phase 2

`--wite` 経路で experimental flag を opt-in できるようにする。

- `wite` optimize 実行時に `--experimental-cfp-const-hints` を渡せるようにする
- benchmark / debug では `analyze host` と `OptimizeResult.observations` を確認する

### Phase 3

実 corpus で size / behavior を固定する。

- size 改善が出る fixture / corpus を追加
- runtime behavior 回帰がないことを確認する
- producer / consumer version ずれ時に安全に無視されることを確認する

## Consequences

良い面:

- `vibe` が既に知っている wrapper shape を `wite` に安全に渡せる
- `wite` 側で難しい再推論をしなくて済むケースが増える
- 汎用 CFG 最適化を先に増やすより実装 ROI が高い

悪い面:

- `vibe` codegen と `wite` optimizer が section schema で結合する
- function index の整合が崩れると hint が無効化される
- hint は advisory なので、emit しても改善が出ないケースがある
- rewrite 不発時は section が残るので、debug と release の扱いを呼び出し側で意識する必要がある

## Non-goals

現時点では次をやらない。

- `vibe.optimize_hints` のような広い独自 schema への拡張
- root hint の導入
- `if-wrapper` や CFG metadata の導入
- frontend 由来の強い意味論の伝達

それらは `wite` 側で consumer contract が固まってから別 ADR として切る。
