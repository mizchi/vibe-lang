# CPS Effect Handler — WASM Performance Report

## Benchmark: 10M iterations, sum of 5 values

| 方式 | 時間 | ratio | size | funcs |
|------|------|-------|------|-------|
| direct (`1+2+3+4+5`) | 11ms | 1x | 160B | 5 |
| CPS (5 yields, `v + k(0)`) | 39ms | 3.5x | 271B | 11 |

## WASM 生成コードの特徴

### 良い点
- **direct call**: `call N` であり `call_indirect` ではない。closure 不要
- **heap allocation なし**: continuation lambda は static 関数として生成
- **function table**: entry のみ（call_indirect 不使用）
- **定数伝搬**: handler body `v + k(0)` の `v` が tagged const として embed

### コスト要因
- **関数数**: N performs → N+1 continuation 関数。5 yields → 6 extra funcs
- **call chain depth**: 5 yields → 5 nested calls per iteration
- **tagged value overhead**: 各 continuation で `v` のタグ操作 (shift/add)
- **frame setup**: 各関数に `(local i64)` + `local.set`/`local.get`

### 生成コード (1 continuation):
```wasm
(func (;N;) (type 0) (param i64 i32) (result i64)
  (local i64)
  i64.const <tagged_v>   ;; v = Yield arg
  local.set 2            ;; bind v
  i64.const <tagged_v>   ;; push v for add
  i64.const 0            ;; k(0) arg
  i32.const 0            ;; env (unused)
  call <N+1>             ;; k(0) = rest of computation
  i64.add                ;; v + k(0)
)
```

## 最適化の可能性

### 1. Tail-resumptive detection (ADR-0021)
CPS handler `v + k(0)` は tail-resumptive ではない（k の結果を使う）。
しかし `k` が最後の式の一部でのみ使われるなら、部分 inline が可能:

```wasm
;; Before (CPS, 5 calls):
call 0 → call 1 → call 2 → call 3 → call 4 → return 0

;; After (inlined accumulate):
i64.const 4   ;; 1
i64.const 8   ;; 2
i64.add
i64.const 12  ;; 3
i64.add
...
```

### 2. Loop fusion
`while` ループ内の CPS handle は毎回同じ continuation chain を実行。
ループ不変コードとして hoist 可能（ただし perform 引数が動的な場合は不可）。

### 3. Defunctionalization
CPS lambda を enum tag + switch に変換:
```wasm
;; Instead of 10 functions:
(func $dispatch (param $tag i32) (param $arg i64) (result i64)
  (block $b9 (block $b8 ... (block $b0
    (br_table $b0 $b1 ... $b9 (local.get $tag)))
    ;; case 0: return v0 + dispatch(1, 0)
    ;; case 1: return v1 + dispatch(2, 0)
    ...
  ))
)
```
1 関数に集約、br_table で O(1) dispatch。

## 結論

- **3.5x overhead は実用上許容範囲** (hot loop 以外)
- **heap allocation なし**: GC pressure ゼロ
- direct call chain で call_indirect オーバーヘッドなし
- 最適化余地: defunctionalization で 1 関数に集約可能
- テスト/DI 用途では性能は問題にならない
