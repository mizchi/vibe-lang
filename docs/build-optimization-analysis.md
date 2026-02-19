# Build Optimization Analysis

`moon build ./src/cmd/vibe --target native` のクリーンビルド高速化の調査結果。

## 環境

- macOS Darwin 25.2.0 (Apple Silicon)
- MoonBit toolchain (moonc)
- Apple clang 17.0.0

## ビルドフェーズ構成 (trace.json 分析)

```
build-package (並列) → link-core (逐次) → cc link (逐次)
     ~5-7s (21%)         ~17s (55%)         ~3-8s (12-24%)
```

- **build-package**: `.mbt` → `.core` (IR)。並列実行 (4-10スレッド)
- **link-core**: 全 `.core` → 単一 `.c` ファイル (58MB, 1.19M行)。**単一スレッド、DCE あり**
- **cc link**: `.c` → 実行バイナリ。`-g` (debug info) の有無で 3-8s 変動

## 主要知見

### 1. link-core がボトルネック (全体の 55-66%)

link-core は全 .core ファイルを結合して C コードを生成する。DCE (dead code elimination) が行われるため、**パッケージを除去しても使われていないコードは既に除去済みで C ファイルサイズはほぼ変わらない**。

### 2. パッケージ削減は compile フェーズのみに効く

144 → 101 パッケージに削減しても、link-core の入力 (C ファイル) は 1,191,843 → 1,187,725 行 (0.3% 減)。改善は並列 compile フェーズの短縮に限定される。

### 3. `--strip` は cc link フェーズに大きく効く

`-g` (debug info) を除去する `--strip` フラグで cc link が 7.6s → 3.3s に短縮。全体で約 4s の改善。

### 4. `--release` は開発ビルドでは逆効果

`-O2` 最適化で cc link が遅くなり、全体時間は debug+strip とほぼ同じ。

## 施策と効果

| 施策 | パッケージ削減 | debug ビルド | +strip |
|------|-------------|------------|--------|
| ベースライン | 144 | 33.7s | — |
| tui/render: crater→dispatch 直接参照 | -9 (→135) | — | — |
| tui/editor: syntree 言語パーサー除去 | -20 (→115) | 32.6s | — |
| bit→bit/object 直接参照 (core,runtime) | ±0 (→115) | — | — |
| yacc_parser 除去 (parser top-level) | -1 (→114) | — | 26.0s |
| wite→wite/optimize 直接参照 | -5 (→109) | — | 26.4s |
| similarity: parser 依存除去 | -8 (→101) | 29.7s | 25.9s |

### 最終結果

| 条件 | ベースライン | 最適化後 | 改善 |
|------|------------|---------|------|
| debug | 33.7s | 29.7s | -4.0s (12%) |
| debug + strip | — | 25.9s | -7.8s (23%) |
| パッケージ数 | 144 | 101 | -43 |

## 未実施の施策

### bit/lib の除去 (推定 -1.4MB .core)

`cmd/vibe` と `x/module_graph` が `ObjectDb::load_lazy` と `write_object_bytes` を使用。pack ファイル読み込みが複雑で、インライン化のコストが高い。DCE で既に除去されているため実効果は限定的。

### 並列度 (-j 16)

link-core が逐次のため効果なし。

## 変更方法 (適用する場合)

### 即効性のある変更

1. **`--strip` フラグを dev ビルドに追加** — justfile 等で `moon build --strip` をデフォルトに
2. **tui/render**: `"mizchi/crater"` → `"mizchi/crater/layout/dispatch"` + LayoutContext 手動構築
3. **tui/editor**: syntree 言語パーサーを registry パターンに変更、HighlightTheme をインライン化

### .mooncakes 変更 (moon update で上書きされる)

以下は各ライブラリの publish が必要:

- `moonbitlang/parser/moon.pkg`: yacc_parser import 除去
- `mizchi/similarity/moon.pkg`: parser import 除去 (extractor/detector を分離)
- `mizchi/tui/editor`: 言語パーサーの lazy import 化

### src 変更

- `runtime_compile/moon.pkg`: `mizchi/wite` → `mizchi/wite/optimize`
- `core/moon.pkg`, `runtime/moon.pkg`: `mizchi/bit` → `mizchi/bit/object`

## .core ファイルサイズ上位 (最適化後)

| パッケージ | サイズ | 備考 |
|-----------|-------|------|
| codegen | 1.6MB | vibe 自身 |
| bit/lib | 1.4MB | git 操作 (ObjectDb) |
| cmd/vibe | 1.4MB | メインバイナリ |
| wite/optimize | 1.2MB | wasm 最適化 |
| runtime | 1.0MB | vibe ランタイム |
| checker | 1.0MB | 型チェッカ |
