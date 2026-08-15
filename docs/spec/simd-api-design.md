# SIMD API Design for vibe-lang

## Overview

WASM SIMD (128-bit v128) を活用した 3 層 API 設計。
compiler (`lib/@vibe/compiler/`) で WASM binary を直接生成する。

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

| Phase | 内容 | 対象 | 状態 |
|---|---|---|---|
| Phase 1 | Layer 2 mid-level パターンを vibe で実装 | `lib/@vibe/compiler/codegen/wasm_emit/simd_patterns.vibe` | ✅ done |
| Phase 2 | V128 type を checker/codegen に追加、Layer 1 builtin 実装 | `lib/@vibe/compiler/core/types.vibe` (`CtNamed("V128", [])`)、`lib/@vibe/compiler/checker/builtins_simd.vibe` (intrinsic 署名)、`lib/@vibe/compiler/codegen/expr/compile_call.vibe` (16-byte box lowering)、`lib/@vibe/compiler/codegen/wasm_emit/simd.vibe` (0xFD emit) | ✅ done (#536/#696) |
| Phase 3 | fused SIMD scan builtin (`simd_skip_ws`) | `compile_call.vibe` (codegen) / `builtins_simd.vibe` (checker) | ✅ builtin done; lexer 統合は**見送り**(下記) |
| Phase 4 | String body event scan (`simd_scan_string_special_str`) | builtin registry / shared linear+gc body | ✅ builtin + scalar-oracle gate (#1868); lexer integration waits for seed bump and A/B |

> Phase 2 (V128 first-class 型 + Layer 1 intrinsic の production 化) は #696 で着地。
> `V128` は memory-boxed (16-byte heap block, ポインタ値 `|1` tag) として表現し、
> `v128_*` intrinsic を `compile_call.vibe` で 0xFD prefix 命令に inline lowering する。
> opcode regression は `scripts/compiler_gate.sh` step 40 (V128 intrinsics) で pin
> (`v128.or` の opcode 80 取り違えバグ修正含む)。**wasm-gc backend は v128 非対応**
> (`backend_call.vibe` が unsupported error を throw)。

### Phase 3: fused unboxed builtin + lexer 統合の判断 (#536)

**問題: per-op boxed v128 は hot path に向かない。** Layer 1 intrinsic (`v128_load` 等)
は各 op が結果を 16-byte heap box に bump-alloc する (never-free)。lexer の
whitespace skip ループにそのまま組むと 16 バイト走査ごとに ~14 回 heap alloc し、
self-build (数 MB) で GB 級の heap 成長 + scalar より遅い。

**解決: fused unboxed builtin `simd_skip_ws(Bytes, Int, Int) -> Int`** を追加
(codegen inline、`compile_call.vibe`)。16 バイト単位の v128 scan を**単一の wasm
ループ**として emit し、v128 値を operand stack に載せたまま処理する (heap box ゼロ)。
末尾はスカラ fallback。最初の非空白 index、全空白なら len を返す。`compiler_gate.sh`
step 40b で correctness を pin。

**lexer 統合は見送り (データ判断)。** compiler source (447 files, 2.97MB) の
空白ラン長分布を実測すると:

| 指標 | 値 |
|---|---|
| 空白ラン総数 | 352,183 |
| 長さ ≥16 バイトのラン | 1,363 (**0.39%**) |
| ≥16 バイトランに含まれる空白バイト | 26,114 / 707,349 (**3.69%**) |
| 長さ 1 バイトのラン | 272,786 (**77%**) |

ソースの空白ランは 99.6% が 16 バイト未満 → 16 バイト粒度の SIMD path はほぼ発火せず
scalar tail に落ちる。lexer に組んでも改善せず、共通ケース (短いラン) に setup
overhead を足すだけ。さらに lexer は `String` + comment (`//`) + `saw_newline`
追跡で動く (`skip_ws_with_newline`) ため Bytes ベースの `simd_skip_ws` は素直に差せない。
よって **lexer 統合と seed bump は行わない**。`simd_skip_ws` は「unboxed SIMD codegen の
実証 + 長い空白/データブロック走査向けの building block」として残す。
将来 SIMD が効くのは 16 バイト超が頻出する対象 (identifier scan ではなく、巨大な
data/whitespace block) であり、その時はこの fused パターンを踏襲する。

## Tail Handling

16バイト単位ループの末尾処理はスカラーフォールバックを使用。
理由: 実装が単純、lexer のチャンクは大半が 16 バイト以上、オーバーラップロードは len >= 16 前提。
