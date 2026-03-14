# WASM Codegen 比較分析: MoonBit wasm-gc vs MoonBit WASM MVP

**日付**: 2026-03-14
**対象**: MoonBit コンパイラ自身の WASM 出力における wasm-gc と MVP の差異

## 概要

MoonBit コンパイラが **同じ .mbt ソースコード** を 2 つの異なる WASM ターゲットに
出力した結果を比較する:
- `wasm-gc`: GC proposal 対応 (struct/array/ref 型)
- `wasm` (MVP): linear memory + tagged pointer

これにより、wasm-gc の利点と WASM MVP で避けられないオーバーヘッドを明確にし、
vibe selfhost コンパイラの最適化指針を得る。

**注意**: 両バイナリとも MoonBit コンパイラが .mbt コードから出力したもの。
vibe selfhost コンパイラの出力分析は [vibe-output-analysis.md](vibe-output-analysis.md) を参照。

## バイナリ基本情報

| 指標 | MoonBit wasm-gc (release) | Selfhost MVP (release) | 比率 |
|------|--------------------------|----------------------|------|
| ファイルサイズ | 902 KB | 2,107 KB | 2.3x |
| コードセクション | 692,033 bytes | 1,944,758 bytes | 2.8x |
| データセクション | 169,992 bytes | 149,446 bytes | 0.88x |
| 関数数 | 2,637 | 4,197 | 1.6x |
| 平均関数サイズ | 262 bytes | 463 bytes | 1.8x |
| 型定義数 | 2,642 | 135 | 0.05x |
| グローバル変数 | 892 | 806 | 0.9x |
| WAT 行数 (≈命令数) | 274,800 | 907,082 | 3.3x |
| 実質命令数 | ~264,000 | ~894,000 | 3.4x |

**注目点**: selfhost は MoonBit wasm-gc の **3.4 倍** の命令数を生成している。

## 命令頻度比較

### メモリアクセスパターン

| 命令 | MoonBit wasm-gc | Selfhost MVP | 備考 |
|------|----------------|-------------|------|
| struct.new | 7,290 | 0 | GC struct 割り当て |
| struct.get | 20,893 | 0 | GC struct フィールド読み |
| struct.set | 927 | 0 | GC struct フィールド書き |
| array.new | 1,126 | 0 | GC array 割り当て |
| array.get | 1,944 | 0 | GC array 要素読み |
| array.set | 1,005 | 0 | GC array 要素書き |
| array.copy | 53 | 0 | GC array バルクコピー |
| i32.load | 0 | 40,763 | linear memory 読み |
| i32.store | 0 | 23,135 | linear memory 書き |
| i32.load8 | 1 | 216 | byte 読み |
| i32.store8 | 1 | 127 | byte 書き |

**分析**:
- MoonBit は GC 命令 (struct/array) で全データアクセスを行う → ランタイムが最適化
- Selfhost は i32.load/store で手動メモリ管理 → **40,763 回の load + 23,135 回の store**
- GC 版は load/store **ゼロ**、代わりに struct.get が 20,893 回

### 関数呼び出しパターン

| 命令 | MoonBit wasm-gc | Selfhost MVP | 備考 |
|------|----------------|-------------|------|
| call | 21,384 | 127,430 | 直接呼び出し |
| call_indirect | 0 | 1,020 | テーブル経由（クロージャ） |
| call_ref | 1,080 | 0 | 型付き関数参照呼び出し |
| ref.func | 213 | 1 | 関数参照作成 |
| ref.cast | 3,675 | 0 | 型キャスト |

**分析**:
- MoonBit は `call_ref` (1,080) でクロージャを呼ぶ → 型安全で高速
- Selfhost は `call_indirect` (1,020) → テーブル参照 + 型チェックのオーバーヘッド
- **call 数が 6 倍** (127,430 vs 21,384): selfhost は関数のインライン化が不十分

### 制御フロー

| 命令 | MoonBit wasm-gc | Selfhost MVP | 比率 |
|------|----------------|-------------|------|
| if | 12,861 | 38,052 | 3.0x |
| block | 2,159 | 3,039 | 1.4x |
| loop | 1,414 | 2,787 | 2.0x |
| br | 4,763 | 7,760 | 1.6x |
| br_table | 78 | 127 | 1.6x |
| unreachable | 900 | 1,716 | 1.9x |

**分析**: selfhost の `if` は 3 倍多い。tagged pointer のデコード（タグチェック）や
パターンマッチの展開が冗長な可能性。

### ローカル変数

| 命令 | MoonBit wasm-gc | Selfhost MVP | 比率 |
|------|----------------|-------------|------|
| local.get | 57,829 | 283,775 | 4.9x |
| local.set | 12,887 | 73,325 | 5.7x |
| local.tee | 12,310 | 68,804 | 5.6x |
| drop | 5,069 | 14,095 | 2.8x |

**分析**: selfhost のローカル操作は **5 倍** 多い。
- i32.load → local.set → local.get のパターンが頻出（manual memory management）
- GC 版は struct.get で直接スタックにプッシュ → local 不要

### 型変換

| 命令 | MoonBit wasm-gc | Selfhost MVP | 備考 |
|------|----------------|-------------|------|
| i64.extend_i32 | 739 | 1,087 | i32 → i64 拡張 |
| i32.wrap_i64 | 259 | 480 | i64 → i32 切り詰め |
| i32.shl | 70 | 4,092 | 左シフト |
| i32.and | 565 | 2,167 | ビット AND |

**分析**: selfhost の `i32.shl` が **58 倍** 多い。
- tagged pointer のエンコード/デコード (`(value << 2) | tag`) が原因
- GC 版は型をそのまま GC ref として保持 → シフト不要

## ボトルネックのランク付け

### 1. 関数インライン化の欠如 (最大インパクト)

selfhost の `call` は 127,430 回 (MoonBit の 6 倍)。MoonBit コンパイラは小さな関数を
積極的にインライン化する。selfhost コンパイラにはインライナーがない。

**推定改善**: call 1 回あたり数サイクルのオーバーヘッド × 100K+ → 大きな影響

### 2. Tagged Pointer のオーバーヘッド (高インパクト)

全値が i64 の tagged pointer (shift + mask) でエンコードされている:
- 値の作成: `(value << 2) | tag` → i32.shl + i32.or
- 値の読取: `ptr & ~3` → i32.and + i32.load
- 型チェック: `ptr & 3 == expected_tag` → i32.and + i32.eq

GC 版はこれが一切不要。**i32.shl (4,092)** + **i32.and (2,167)** + **i32.or (69)** の
大部分が tagged pointer 操作。

**推定改善**: タグ操作全体で命令の ~1% だが、ホットパスでは大きな差

### 3. Manual Memory Management (高インパクト)

i32.load (40,763) + i32.store (23,135) = **63,898 回** の linear memory アクセス。
GC 版は struct.get/set/array.get/set で同等の操作をランタイムに委譲。

wasmtime の GC 実装では struct フィールドアクセスは load と同等速度だが、
GC の利点は **アロケーション + 解放の最適化** にある。

### 4. モノモーフィック特殊化の欠如 (中インパクト)

MoonBit は `Array::push` を型パラメータごとに特殊化（13 種の `Array4pushG*` 関数）。
selfhost は単一の汎用実装を tagged pointer 経由で使用。

**影響**:
- 汎用版は毎回タグのエンコード/デコードが必要
- 特殊化版は値を直接操作 → 分岐除去、命令削減

### 5. 冗長な制御フロー (中インパクト)

`if` 命令が 3 倍、`unreachable` が 2 倍。パターンマッチの展開や
エラー処理のガード節が冗長に生成されている可能性。

## 実行可能な改善案

### 短期 (codegen 改善)

| # | 改善案 | 削減見込み | 難易度 |
|---|--------|----------|--------|
| S1 | **peephole 最適化**: local.set + local.get → local.tee 統合 | local 操作 -10~15% | 低 |
| S2 | **定数畳み込み**: const + const + op → const | i32.const -5% | 低 |
| S3 | **dead code 除去**: unreachable 後の命令削除 | 小 | 低 |
| S4 | **br_table 活用**: 連続 if-else chain → br_table | if -20~30% (特定パス) | 中 |

### 中期 (アーキテクチャ改善)

| # | 改善案 | 削減見込み | 難易度 |
|---|--------|----------|--------|
| M1 | **関数インライン化**: 小関数 (≤N 命令) のインライン展開 | call -50~70% | 高 |
| M2 | **wasm-gc バックエンド**: struct/array GC 命令を使用 | load/store 全廃 | 高 |
| M3 | **型特殊化**: ホットな汎用関数のモノモーフィック化 | tagged ptr 操作削減 | 高 |

### 長期 (ランタイム設計変更)

| # | 改善案 | 削減見込み | 難易度 |
|---|--------|----------|--------|
| L1 | **NaN boxing → unboxed locals**: 関数内ローカルは unbox | shl/and 全廃 (ローカル) | 高 |
| L2 | **SSA ベース IR**: 中間表現を導入して最適化パス追加 | 全体 -30~50% | 非常に高 |

## 比較コマンド再現手順

```bash
# MoonBit wasm-gc ビルド
moon build --target wasm-gc --release src/lib

# Selfhost WASM ビルド
moon build --target wasm --release src/cmd/vibe_compile_wasi

# セクション比較
wasm-tools objdump _build/wasm-gc/release/build/lib/lib.wasm
wasm-tools objdump _build/wasm/release/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm

# 命令カウント
wasm-tools print <wasm_file> | grep -c '<pattern>'

# WAT 全出力
wasm-tools print <wasm_file> > output.wat
```

## 補足: 比較の前提と限界

- **両バイナリとも MoonBit コンパイラの出力**: 同じ .mbt ソースを wasm-gc / MVP に出力
- MoonBit wasm-gc (`src/lib`) と MVP (`src/cmd/vibe_compile_wasi`) は
  **異なるエントリポイント**（lib exports vs WASI CLI）のため、含まれる関数セットが異なる
- MoonBit release は DCE + 最適化済み
- 命令数 ≠ 実行時間（GC 命令のコストはランタイム実装依存）
- この比較は「wasm-gc の構造的優位性」を示すもので、vibe codegen の改善指針として活用する
- vibe コンパイラ自体の出力 WASM 分析は [vibe-output-analysis.md](vibe-output-analysis.md) を参照
