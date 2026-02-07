# xsh Standard Library (Self-hosted)

MoonBit core library からの移植を通じて xsh をセルフホストする試み。

## 実装済み

| モジュール | テスト数 | 説明 |
|-----------|---------|------|
| `option.xsh` | 8 | Option 操作 (is_some, unwrap_or, map, flatmap, filter) |
| `int.xsh` | 11 | 整数操作 (abs, max, min, clamp, pow, gcd, lcm, factorial, fibonacci) |
| `float.xsh` | 7 | Float 操作 (abs, signum, clamp, square, lerp) |
| `double.xsh` | 10 | Double 操作 (abs, signum, floor/ceil/round, lerp) |
| `list.xsh` | 11 | Cons リスト (map, fold, filter, reverse, append, take, drop) |
| `bool.xsh` | 8 | 論理演算 (to_int, implies, xor, nand, nor) |
| `string.xsh` | 10 | 文字列操作 (head, tail, take, drop, repeat, pad, contains, replace) |
| `io.xsh` | 3 | 高水準 stdio (`stdout_write`, `stdout_writeln`, `stdin_read_line`) |
| `wasm/types.xsh` | 6 | WASM 型別名入口 (`i32`/`f32`/`f64`, `I32`/`F32`/`F64`) |
| `wasm/opcodes.xsh` | 5 | 命令名準拠 API (`i32_add`, `i32_div_s`, `f64_promote_f32` など) |

**合計: 79 テスト**

## 発見した言語機能の制限

移植の過程で、以下の言語機能が不足していることがわかった：

### 1. ジェネリクスの制限
- `Option[Int]` と `Option[(Int, Int)]` は別の型として扱われるが、同じ関数で両方を返せない
- 真のパラメトリック多相がない（各型に対して関数を別々に書く必要がある）

**例：本来は書きたい**
```xsh
let option_zip = [A, B](a: Option[A], b: Option[B]) -> Option[(A, B)] { ... }
```

**現状の回避策**
```xsh
// 型ごとに別関数を定義
let option_zip_int = (a: Option[Int], b: Option[Int]) -> Option[Int] { ... }
```

### 2. 大きな負数リテラル
- `-2147483648` がパースエラーになる（`2147483648` が Int 範囲外）
- `0 - 2147483647 - 1` で回避可能

### 3. loop 式（未確認）
- MoonBit の `loop` 式（tail 再帰の最適化構文）がない
- `let rec` + パターンマッチで代用

### 4. mutable tail（list の in-place 変更）
- MoonBit の `More(_, tail~)` のような可変フィールドがない
- 純粋な再帰的構築で代用（効率は劣る）

## 追加したい機能（優先順位順）

### Phase 1: 基本機能強化
1. **ビット演算子** (`>>`, `<<`, `&`, `|`, `^`) - 既存計画あり
2. **loop 式** - tail 再帰の最適化

### Phase 2: ジェネリクス強化
3. **型パラメータ** - `fn[A](x: A) -> A` 形式
4. **trait bounds** - `fn[A: Show](x: A) -> String`

### Phase 3: データ構造強化
5. **可変フィールド** - `enum List { Cons(Int, mut tail: List) }`
6. **Array ビルトイン拡張** - iter, zip, flatmap

## 今後の移植候補

現在の言語機能でも移植可能なもの：
- `string.xsh` - 文字列操作ユーティリティ
- `tuple.xsh` - タプル操作
- `result.xsh` - Result 型（既に enum で定義可能）
- `math.xsh` - 数学関数（Float/Double 版）

ジェネリクス強化後に移植可能：
- `array.xsh` - 配列高階関数（型安全版）
- `hashmap.xsh` - ハッシュマップ
- `set.xsh` - 集合

## テスト実行

```bash
# インタプリタでテスト
just run test \
  examples/std/bool.xsh \
  examples/std/int.xsh \
  examples/std/float.xsh \
  examples/std/double.xsh \
  examples/std/list.xsh \
  examples/std/option.xsh \
  examples/std/string.xsh \
  examples/std/io.xsh \
  examples/std/wasm/types.xsh \
  examples/std/wasm/opcodes.xsh

# WASM コンパイル確認（import/export 使用）
just run compile --wasm examples/std/test_import.xsh -o /tmp/test.wasm
wasmtime run --invoke run /tmp/test.wasm  # → 484 (untagged: 121)
```

## 注意事項

- `examples/std/test_import.xsh` はコンパイル確認用（`test` ブロックなし）
- `examples/std/io.xsh` は `string_*` builtins に依存するため、現状の Core WASM (`--wasm`) ではなく主にインタプリタ向け
