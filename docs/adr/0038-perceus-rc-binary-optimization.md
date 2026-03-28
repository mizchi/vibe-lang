# ADR-0038: Perceus RC バイナリサイズ最適化

- Date: 2026-03-28
- Status: accepted

## Context

Perceus RC（参照カウント）を WASM リニアメモリバックエンドに導入した結果、RC なしと比較してバイナリサイズが **1.95x** に肥大化していた。主な原因：

- 8 バイトの RC ヘッダー（alloc_size + rc_count）を全オブジェクトに付加
- `$rc_alloc`/`$rc_drop`/`$rc_dup` ヘルパー関数のコードサイズ
- free-list 管理用のグローバル変数とロジック
- 型ディスパッチの逐次 if/else チェーン
- i64 タグ付き値の i32 変換オーバーヘッド

MoonBit の WASM ターゲット（リニアメモリ + RC）を逆アセンブルして比較分析した結果、以下の違いが判明：

| 項目 | MoonBit WASM | Vibe RC (最適化前) |
|---|---|---|
| RC ヘッダー | 4 bytes (ref_count のみ) | 8 bytes (alloc_size + rc_count) |
| アロケータ | 本格 malloc (1382 bytes) | バンプ + free-list (80 bytes) |
| rc_decref | 40 bytes | 70 bytes (型ディスパッチ込み) |
| 値の型 | i32 (タグなし) | i64 (2-bit タグ付き) |

## Decision

以下の最適化を段階的に適用：

### 1. RC ヘルパー関数の最適化
- `$rc_alloc`: free-list の全走査をヘッドのみチェックに変更（~50 bytes 削減）
- `$rc_alloc`: memory.grow チェック簡素化、ローカル変数 6→2 に削減
- `$rc_drop`: `local.tee` で rc_ptr 二重計算を排除
- `$rc_drop`: 型ディスパッチのローカル変数を条件付き宣言（3 or 6）

### 2. i64 空間でのタグチェック（MoonBit 比較から着想）
- `$rc_dup`/`$rc_drop`: val32 ローカルを削除し、i64 空間で直接タグチェック
- 各関数で ~5 bytes + 1 ローカル削減

### 3. br_table による型ディスパッチ
- `$rc_drop` の逐次 if/else を `br_table` に置換（3+ 型カテゴリ時）
- O(n) → O(1) ディスパッチ

### 4. 条件付き free-list + 4 バイトヘッダー（MoonBit 比較から着想）
- `has_assign_drop`（可変再代入）がない場合、free-list を省略
- free-list なし時、RC ヘッダーを 8→4 bytes に縮小（alloc_size 不要）
- `$rc_alloc` から free-list チェックコード全体を省略
- `$rc_drop` から tombstone + free-list prepend を省略
- グローバル変数 1 つ削減

## Consequences

### バイナリサイズ改善

| ベンチマーク | 最適化前 | 最適化後 | 削減 |
|---|---|---|---|
| int_literal | 101 / 75 (1.35x) | 96 / 75 (1.28x) | -5 |
| tuple_alloc | 436 / 172 (2.53x) | 354 / 172 (2.06x) | -82 |
| func_call | 119 / 93 (1.28x) | 114 / 93 (1.23x) | -5 |
| tuple_access | 459 / 191 (2.40x) | 377 / 191 (1.97x) | -82 |
| multi_alloc | 662 / 491 (1.35x) | 580 / 491 (1.18x) | -82 |
| **TOTAL** | **1777 / 1022 (1.95x)** | **1521 / 1022 (1.49x)** | **-256** |

### トレードオフ
- free-list なしモードでは、スコープ終了時に解放されたメモリは再利用されない（バンプアロケータのみ）
- 可変再代入のあるプログラムでは従来通り 8 バイトヘッダー + free-list が有効
- br_table はタプルのみのプログラムでは if/else より大きくなるため、3+ 型カテゴリ時のみ使用

### 残課題
- MoonBit のように i32 値型に切り替えれば更なる削減が可能だが、アーキテクチャ変更が大きすぎる
- while ループ本体での Perceus ドロップ生成が未対応（既知のリーク）
