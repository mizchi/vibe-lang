# ADR-0043: ビルド時パーミッション駆動 DCE と定数分岐による強力なコード除去

- Date: 2026-03-31
- Status: proposed

## Context

### 現状の DCE

vibe の DCE (`src/frontend/dce.mbt`) は後方到達可能性分析に基づいている。エントリポイントから参照されない定義を除去する仕組みで、`dce_module()` / `dce_module_gc()` として codegen 前に実行される。

この DCE は「使われていない関数を消す」レベルであり、以下のケースには対応していない:

1. **パーミッション不足で到達不可能なコード**: ビルドプロファイルが `Fs` capability を持たない場合、`Fs::read_file` を呼ぶコードパス全体が実行されることはないが、DCE はそれを知らない
2. **定数分岐**: `if PLATFORM == "edge" { ... } else { ... }` のような定数条件が確定している分岐で、false 側を除去できない

### 設計意図

vibe は capability-based security を言語レベルで持つ (ADR-0041, ADR-0042)。ファイルモジュールのトップレベルは pure であり、副作用は `_start` の `with { Effects }` 宣言で明示する。この設計を活かせば、「宣言されていない capability に依存するコード → 到達不可能 → DCE 対象」という推論が成立する。

同時に、定数分岐（ビルド時に値が確定する条件式）を DCE と組み合わせることで、単一のソースコードから複数のデプロイターゲット向けに最適なバイナリを生成できる。

## Decision

### 1. Capability-driven DCE

ビルド時に利用可能な capability set を指定し、それに基づいて DCE を拡張する。

#### ビルドプロファイル

```bash
# プリセット
vibe compile --profile minimal app.vibe    # ClockMonotonic, FsRead のみ
vibe compile --profile sandbox app.vibe    # sandbox preset
vibe compile --profile edge app.vibe       # Net のみ、Fs なし

# 明示指定
vibe compile --capabilities "Net,ClockRead" app.vibe

# デフォルト (developer) — 全 capability 利用可能、DCE は通常通り
vibe compile app.vibe
```

#### DCE の拡張フェーズ

既存の DCE パイプラインに 2 つのフェーズを追加する:

```
parse → typecheck → [capability pruning] → [constant folding] → DCE → codegen
```

**Phase A: Capability Pruning**

1. ビルドプロファイルから利用可能な effect set を導出
2. 各関数の effect 宣言 (`with { Fs, Net }`) をプロファイルと照合
3. 利用不可能な effect を要求する関数を「到達不可能」としてマーク
4. 到達不可能な関数を呼び出す側も、その呼び出しを含むパスが到達不可能かを伝播

```
// profile: --capabilities "Net"
// → Fs は利用不可能

let read_config = () -> String with { Fs } {    // ← 到達不可能としてマーク
  Fs::read_file("config.json")
}

let fetch_config = () -> String with { Net } {  // ← 残る
  Http::get("https://config.example.com/config.json")
}
```

**Phase B: Constant Branch Elimination**

ビルド時定数が確定している条件分岐の false 側を除去する:

```
let config = if @build.has_capability("Fs") {
  read_config()       // ← Fs なしのプロファイルでは除去
} else {
  fetch_config()      // ← 残る
}
```

### 2. 定数分岐の仕組み

#### ビルド時定数

`@build` 名前空間でビルド時に確定する値を提供する:

```
@build.has_capability("Fs")        // -> Bool  (ビルドプロファイルに Fs があるか)
@build.has_capability("Net")       // -> Bool
@build.profile()                   // -> String ("minimal", "sandbox", "edge", ...)
@build.target()                    // -> String ("wasm", "wasm-gc", "component")
```

これらは checker 通過後、codegen 前に定数に置換される。

#### 定数畳み込みと分岐除去

```
// ソースコード
let result = if @build.has_capability("Fs") {
  Fs::read_file("data.txt")
} else {
  "default"
}

// --profile edge (Fs なし) でビルド後:
// → if false { ... } else { "default" }
// → "default"  (dead branch 除去)
```

#### `match` 式での定数分岐

```
let backend = match @build.target() {
  "wasm-gc" => use_gc_allocator()
  "wasm"    => use_linear_allocator()
  _         => use_fallback()
}

// --target wasm-gc でビルド後:
// → use_gc_allocator() のみ残る
```

### 3. Effect 到達可能性の伝播規則

capability pruning は以下の規則で伝播する:

1. **直接呼び出し**: `f()` が到達不可能 → `f()` を含む式は到達不可能
2. **条件分岐内**: `if cond { f() } else { g() }` — `f` が到達不可能でも `g` が到達可能なら式全体は到達可能（`f` 側の分岐のみ除去）
3. **handle ブロック**: `handle { f() } { Effect(_) => fallback }` — `f` の effect が利用不可能でも、handler の fallback が存在するなら式全体は到達可能
4. **高階関数**: 関数値として渡される場合は静的に判定できないため、pruning しない（保守的）

```
// 規則 3 の例: handle による graceful degradation
let data = handle {
  Fs::read_file("cache.txt")      // Fs なしでも…
} {
  Fs(_) => "no local cache"       // handler があるので式全体は到達可能
}
```

### 4. DCE レポート

ビルド時に除去されたコードの統計を出力する:

```
$ vibe compile --profile edge --report-dce app.vibe

Capability DCE:
  ✓ Net          — available (12 functions retained)
  ✓ ClockRead    — available (2 functions retained)
  ✗ Fs           — unavailable (8 functions removed, ~3.2 KB saved)
  ✗ Process      — unavailable (3 functions removed, ~1.1 KB saved)

Constant branch elimination:
  4 branches folded (2 @build.has_capability, 2 @build.target)

Standard DCE:
  15 unreferenced definitions removed

Total: 26 definitions removed, ~8.5 KB saved
  Output: app.wasm (45.2 KB, gzip 18.1 KB)
```

### 5. 段階的な導入計画

#### Phase 1: 定数分岐の基盤

- `@build.has_capability()` / `@build.target()` / `@build.profile()` を組み込み関数として追加
- checker で型を `Bool` / `String` として扱う
- codegen 前に定数置換パスを追加
- 定数条件の `if` / `match` で dead branch を除去

#### Phase 2: Capability-driven pruning

- `--profile` / `--capabilities` CLI オプションを追加
- effect 宣言からビルドプロファイルへの照合ロジックを追加
- 到達不可能関数のマーキングと伝播
- DCE レポートの出力

#### Phase 3: 高度な最適化

- `handle` ブロックの fallback 解析
- cross-module DCE（複数ファイルバンドル時）
- size budget 制約（`--max-size 100KB` で超過時に警告）

## Consequences

### Good

- **デプロイターゲットごとの最適化**: edge / browser / server で同じソースから最小バイナリを生成できる
- **capability model との一貫性**: 型システムの effect 宣言がそのまま DCE の入力になる。新しい概念を導入しない
- **段階的な導入**: Phase 1 の定数分岐だけでも即効性がある。capability pruning は後から追加できる
- **セキュリティとサイズの同時改善**: 使わない capability のコードが物理的にバイナリから消えることで、attack surface も縮小する
- **wasm-gc / linear の分岐**: `@build.target()` で backend 固有のコードを書き分け、他方を DCE で消せる

### Bad

- **ビルド時定数の導入**: `@build.*` は新しい名前空間。乱用するとソースコードの可読性が下がる
- **DCE の複雑化**: capability pruning の伝播規則が複雑。特に高階関数や動的ディスパッチでは保守的になる
- **ビルドキャッシュの粒度**: プロファイルが変わるとキャッシュが無効になる

### Neutral

- 既存の DCE (`dce_module` 系) は変更なし。新しいフェーズは前段に追加される
- `--profile` を指定しない場合（デフォルト = developer）、capability pruning は何も消さない。後方互換
- effect system 自体の仕様変更は不要。既存の `with { Effects }` 宣言をそのまま利用する
