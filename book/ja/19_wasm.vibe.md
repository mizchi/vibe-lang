# 19 — wasm をターゲットにする

前: [CLI を IDE として使う](18_cli.vibe.md)

English version: [19_wasm.vibe.md](../en/19_wasm.vibe.md) (canonical)

コンパイラは wasm を吐く wasm プログラムである。wasm は「バックエンドとして
選ぶもの」ではなく、表現そのもの。内部の値は tagged i64、String は
byte string。WIT 境界に出られる型は nominal 規則に従うので、境界側が
マッピングを発明する必要がない。

## 2 つの codegen 経路

- **linear memory** (`vibe test` / `vibe build --release` の既定):
  tagged i64 の値、bump/RC ヒープ、所有権のための Perceus 計画。
- **wasm-gc**: 型付きヒープ型、異なるアロケーション特性。
  `VIBE_TEST_BACKEND=gc` でテストをこちらに乗せられる。

```bash
vibe test foo_test.vibe                       # linear
VIBE_TEST_BACKEND=gc vibe test foo_test.vibe  # wasm-gc
vibe build --release app.vibe                 # standalone .wasm
```

すべてのプログラムが両方で有効なわけではない。gc には HOF / Iterator の
穴がまだある。gc 限定の機能が要るのでなければ linear を選ぶこと。bench
キャッシュはバックエンドを鍵に含むので、linear → gc の切り替えでは
再コンパイルされる。

## Feature level

生成されるモジュールは必要とする wasm feature level を宣言する
([docs/wasm/feature-levels.md](../../docs/wasm/feature-levels.md))。
不許可の capability は畳み落とされるので、`Http` に到達しないプログラムが
ネットワーク対応ランタイムを要求することはない。

追跡している level は 2 つ: `v8` (Chrome / Node / Deno) と `web-baseline`
(それらに Firefox と Safari を加えたもの)。ある level にとって提案が安全と
言えるのは、その集合の全エンジンが**フラグなしで**サポートしているとき
だけ。コンパイラのホスト (`viberun`) は実験的提案を有効にしてよいが、
生成されるユーザーコードは違う。

## WIT

WIT 境界に出られる型は nominal 規則に従う (ADR-0089)。`@vibe/wit_runtime`
が WIT の `result<T, E>` に対応する `Result` を提供する — 2 本腕の返り値型
として認められるのはこれだけ。それ以外の場所では `T with Exception[E]` と
書く。

## 「セルフホスト」の意味

`bootstrap/seed/` は pin された compiler wasm。`lib/@vibe/compiler/` が
ソース。`scripts/generations.sh` が stage1 を作り次に stage2 を作る。
fixpoint とは、stage2 がコンパイラをコンパイルした結果が stage3 と同じ
バイト列になること。MoonBit も LLVM もネイティブの vibe コンパイラも
要らない。

次: [落とし穴 (実測)](20_pitfalls.vibe.md)。
