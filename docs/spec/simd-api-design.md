# SIMD API Design for vibe-lang

## Overview

WASM SIMD (128-bit v128) を活用した 3 層 API 設計。
selfhost compiler (`vibe/compiler/`) で WASM binary を直接生成する。

## Layer 1: Low-level (WASM 命令 1:1 マッピング、builtin)

codegen が WASM opcode に直接展開する builtin 関数群。

| vibe builtin | WASM opcode | 説明 |
|---|---|---|
| `v128_load(bytes, offset)` | `0xFD 0x00` | 16バイト読み込み |
| `v128_store(bytes, offset, v)` | `0xFD 0x0B` | 16バイト書き込み |
| `v128_splat_i8x16(byte)` | `0xFD 0x0F` | 全レーンに同一バイト |
| `v128_eq_i8x16(a, b)` | `0xFD 0x23` | レーンごと等値比較 |
| `v128_le_u_i8x16(a, b)` | `0xFD 0x26` | 符号なし ≤ |
| `v128_bitmask_i8x16(v)` | `0xFD 0x64` | マスク → 16bit Int |
| `v128_any_true(v)` | `0xFD 0x53` | いずれかのレーンが非ゼロ |
| `v128_and(a, b)` | `0xFD 0x4E` | ビットAND |
| `v128_or(a, b)` | `0xFD 0x4F` | ビットOR |
| `v128_not(v)` | `0xFD 0x4D` | ビットNOT |
| `int_ctz(value)` | `0x68` (i32.ctz) | 末尾ゼロカウント |

型: `V128` を opaque primitive type として導入 (WASM type `0x7B`)。

## Layer 2: Mid-level (パターン合成、vibe ライブラリ関数)

Layer 1 を組み合わせた汎用パターン。builtin 不要、vibe で実装。

```
// 16バイトチャンク内でバイト検索 → 位置 (見つからなければ 16)
let v128_find_byte = (chunk: V128, byte: Int) -> Int {
  int_ctz(v128_bitmask_i8x16(v128_eq_i8x16(chunk, v128_splat_i8x16(byte))))
}

// 範囲内バイト判定マスク (low <= byte <= high)
let v128_in_range = (chunk: V128, low: Int, high: Int) -> V128 {
  v128_and(
    v128_le_u_i8x16(v128_splat_i8x16(low), chunk),
    v128_le_u_i8x16(chunk, v128_splat_i8x16(high))
  )
}

// 16バイト memcmp
let bytes_equal_chunk = (a: Bytes, off_a: Int, b: Bytes, off_b: Int) -> Bool {
  let va = v128_load(a, off_a)
  let vb = v128_load(b, off_b)
  not(v128_any_true(v128_not(v128_eq_i8x16(va, vb))))
}
```

## Layer 3: High-level (ユースケース特化)

### Lexer

```
// 空白スキップ (' ', '\t', '\n', '\r')
let lex_skip_whitespace_simd = (src: Bytes, pos: Int, len: Int) -> Int {
  let mut p = pos
  while p + 16 <= len {
    let chunk = v128_load(src, p)
    let is_space = v128_eq_i8x16(chunk, v128_splat_i8x16(0x20))
    let is_tab   = v128_eq_i8x16(chunk, v128_splat_i8x16(0x09))
    let is_nl    = v128_eq_i8x16(chunk, v128_splat_i8x16(0x0A))
    let is_cr    = v128_eq_i8x16(chunk, v128_splat_i8x16(0x0D))
    let is_ws = v128_or(v128_or(is_space, is_tab), v128_or(is_nl, is_cr))
    let mask = v128_bitmask_i8x16(v128_not(is_ws))
    if mask != 0 { return p + int_ctz(mask) }
    p = p + 16
  }
  // scalar fallback
  while p < len {
    let b = bytes_get(src, p)
    if b != 0x20 && b != 0x09 && b != 0x0A && b != 0x0D { return p }
    p = p + 1
  }
  p
}
```

### String ops

```
// SIMD memcmp (任意長)
let bytes_equal_simd = (a: Bytes, off_a: Int, b: Bytes, off_b: Int, len: Int) -> Bool {
  let mut i = 0
  while i + 16 <= len {
    if not(bytes_equal_chunk(a, off_a + i, b, off_b + i)) { return false }
    i = i + 16
  }
  // scalar fallback
  while i < len {
    if bytes_get(a, off_a + i) != bytes_get(b, off_b + i) { return false }
    i = i + 1
  }
  true
}
```

## Implementation Plan

| Phase | 内容 | 対象 |
|---|---|---|
| Phase 1 | Layer 2 mid-level パターンを vibe で実装 | `vibe/compiler/codegen/wasm_emit/simd_patterns.vibe` |
| Phase 2 | V128 type を checker/codegen に追加、Layer 1 builtin 実装 | `src/checker/`, `src/codegen/`, selfhost |
| Phase 3 | Layer 3 lexer 特化関数を selfhost lexer に統合 | `vibe/compiler/syntax/lexer.vibe` |

## Tail Handling

16バイト単位ループの末尾処理はスカラーフォールバックを使用。
理由: 実装が単純、lexer のチャンクは大半が 16 バイト以上、オーバーラップロードは len >= 16 前提。
