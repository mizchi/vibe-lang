# Vibe Compiler WASM 出力品質分析

**日付**: 2026-03-14
**対象**: vibe コンパイラが `.vibe` ソースから生成する WASM の品質分析

## 概要

vibe コンパイラの出力 WASM (examples/basics.vibe → WASM) のパターンを分析し、
MoonBit コンパイラの出力パターンと比較して最適化余地を特定する。

## テストケース: examples/basics.vibe

73 関数、35,609 bytes のコードセクション（平均 487 bytes/func）。
含まれる機能: 算術、再帰、パターンマッチ、enum、クロージャ、配列操作。

## 致命的な問題: call_indirect の過剰使用

```
vibe output:   70 call_indirect / 7 call  → 91% が indirect
MoonBit output: 0 call_indirect / N call  → 0%  が indirect
```

### 原因

vibe コンパイラの closure ABI では、**全ての関数が closure として表現される**:
- 関数値 = `(fn_index << 2) | tag`
- 呼び出し = テーブルから関数参照を取得 → `call_indirect`
- クロージャかどうかに関わらず同じパス

### 影響

`call_indirect` は `call` より遅い理由:
1. テーブル参照のオーバーヘッド（メモリアクセス）
2. 型チェック（signature mismatch → trap）
3. 分岐予測が効きにくい（間接呼び出し）
4. wasmtime の JIT がインライン化できない

### 改善策: 直接呼び出しの検出

**既知の関数** への呼び出しは `call` に変換可能:
- `let f = (x) -> x + 1; f(42)` → `f` は定数関数 → `call $f`
- `fact(n - 1)` → `fact` はモジュールレベル関数 → `call $fact`
- ラムダが別の関数に渡される場合のみ `call_indirect` が必要

```
推定改善: 70 call_indirect → ~5 call_indirect + ~65 call
= call_indirect を 93% 削減
```

## 命令パターン詳細

| 命令 | カウント | 備考 |
|------|---------|------|
| call_indirect | 70 | **問題**: ほぼ全呼び出し |
| call | 7 | builtin/import のみ |
| local.get | 5,059 | tagged pointer デコードで増加 |
| local.set | 2,366 | |
| i32.wrap_i64 | 702 | i64 tagged → i32 ptr 変換 |
| if | 700 | パターンマッチ展開 |
| i32.load | 475 | ヒープ読み出し |
| i32.and | 311 | タグマスク |
| i64.extend | 274 | i32 → i64 タグ付け |
| i32.store | 268 | ヒープ書き込み |
| drop | 168 | 未使用値 |
| memory.grow | 137 | ヒープ拡張 |
| i32.mul | 98 | 配列インデックス計算 |
| unreachable | 80 | パターンマッチの到達不能分岐 |

## 改善優先度

### P0: call_indirect → call 変換 (最大インパクト)

モジュールレベルの関数呼び出しを直接 `call` に変換。
コンパイル時に「この関数参照は既知の関数インデックスか？」を判定。

**実装方針**:
1. `compile_expr` の `ECall` で callee が `EIdent` かつモジュールレベル関数の場合
2. closure ABI の env パラメータとして `i32.const 0` を渡す
3. `call $func_index` を使う（`call_indirect` の代わり）

### P1: 定数畳み込み

`i32.const + i32.const + i32.add` → `i32.const (a + b)`

### P2: タグ操作の削減

ローカル変数間の代入でタグの encode → decode を繰り返している場合、
中間のタグ操作を省略できる。

### P3: dead code 除去

`unreachable` (80) の前後に不要な命令がある可能性。

## 比較コマンド再現

```bash
# vibe compiler で basics.vibe をコンパイル
_build/native/release/build/cmd/vibe/vibe.exe \
  compile-lite --wasm --no-dce examples/basics.vibe \
  -o _build/analysis/basics_host.wasm

# WAT に変換して分析
wasm-tools print _build/analysis/basics_host.wasm > _build/analysis/basics_host.wat

# 命令カウント
wasm-tools print _build/analysis/basics_host.wasm | grep -c 'call_indirect'
```

## 実装済み: P0 call_indirect → call 変換

`compile_expr_call` の先頭に、`ctx.fn_indices` に名前があり arity が一致する場合に
`compile_call_by_name` → `compile_call_user_fn` （直接 `call`）にフォールスルーする
条件を追加。

### 結果

| ファイル | call_indirect (前) | call_indirect (後) | 削減率 |
|---------|-------------------|-------------------|--------|
| basics.vibe | 70 | 17 | 76% |
| base64.vibe | N/A | 17 | - |
| effects.vibe | N/A | 20 | - |
| module_export.vibe | N/A | 17 | - |

残りの `call_indirect` はクロージャとして関数値が渡されるケース（Array::map 等）で、
これらは正しく indirect が必要。

### fib(30) 再帰呼び出しの改善

```
Before: fib → call_indirect (tag check + table lookup + call_indirect)
After:  fib → call 44 (直接呼び出し)
```

## 実装済み: S1 tagged pointer 整数演算特殊化

`resolve_numeric_kind` で両辺が `I64`（整数確定）の場合、full type dispatch（tag check → f32/f64/int 分岐）を省略し、tagged pointer のまま直接演算する。

### 対象 builtin

| builtin | 特殊化方式 | 備考 |
|---------|-----------|------|
| `eq`, `__eq` | `compile_i32_cmp_tagged` (直接 `i64.eq`) | tag=0 なので tagged 値のまま比較可能 |
| `lt`, `__lt` | `compile_i32_cmp_tagged` (直接 `i64.lt_s`) | 同上 |
| `add`, `__add` | `compile_i32_add_tagged` (直接 `i64.add`) | `(a<<2) + (b<<2) = (a+b)<<2` |
| `sub`, `__sub` | `compile_i32_sub_tagged` (直接 `i64.sub`) | 同上 |
| `mul`, `__mul` | `compile_i32_mul_tagged` (untag → mul → retag) | 乗算は直接不可 |
| `div`, `__div` | `compile_i32_div_tagged` (untag → div → retag) | 除算は直接不可 |

### 結果: fib(30) 関数 WAT

```
Before (P0のみ): 50 locals, ~120 instructions, full type dispatch for n<2, n-1, n-2, +
After  (P0+S1):   3 locals, ~40 instructions, 直接演算のみ
```

### basics.vibe 全体の命令数

```
P0 のみ:  16,371 行 (WAT)
P0 + S1: 10,287 行 (WAT) → 37% 削減
```

## 次のステップ

1. **定数畳み込み**: `i64.const 4; i64.sub` → tagged 演算時のリテラル最適化
2. **dead code 除去**: `unreachable` 後の命令削除
3. **bool タグ操作の簡略化**: 比較結果の bool tagging `(i64.extend + shl 2 + or 3 + shr_u 2 + i32.wrap)` の削減
4. **selfhost codegen にも同等の最適化を適用**
