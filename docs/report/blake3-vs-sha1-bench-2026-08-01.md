# blake3 vs sha1 vs compact_string_fingerprint — bench (2026-08-01)

キャッシュ/fingerprint 用ハッシュを sha1 から blake3 (または SIMD 化しやすい
アルゴリズム) へ置き換える検討の一次計測。`lib/@vibex/blake3` に pure-vibe の
BLAKE3 (spec 完全準拠、公式テストベクタで検証済み — `blake3_test.vibe`) を
実装し、`vibe bench` (linear backend, 1000 iters, viberun/wasmtime) で
既存実装と比較した。

## 前提の整理: いま sha1 は「どこ」で使われているか

- **実行時のキャッシュキーは sha1 ではない**: persistent cache の
  fingerprint (`lib/@vibe/cache/cache.vibe`) は
  `compact_string_fingerprint` — 2 本の 31-bit 多項式 rolling hash
  (len:h1:h2 形式、実質 ~62-bit)。
- **sha1 の実際の使用箇所**は contract/package の内容ハッシュ
  (`ct:sha1:<40hex>` / `pkg:sha1:<40hex>`、ADR-0004/ADR-0065 の pin 照合、
  `lib/@vibe/compiler/contract/contract.vibe`) と、
  `scripts/generate_bundle.sh` 系の生成物 fingerprint。衝突耐性が意味を
  持つのはこちら側。

## 計測結果 (mean ns/op、alloc は bump-heap delta bytes/op)

入力構築は bench block 内で行うため、`baseline make_a` (構築のみ) を引いた
net 値も併記する。3 つの bench file は同一の 1KiB/8KiB + baseline ケースを
持つ (`sha1_bench.vibe` / `blake3_bench.vibe` / `cache_bench.vibe`)。

| case | sha1 | blake3 | compact_string_fingerprint |
|---|---:|---:|---:|
| empty | 17.6 µs / 3.4 KiB | 8.4 µs / 2.2 KiB | 0.23 µs / 56 B |
| medium (108 B) | 27.9 µs / 3.4 KiB | 15.6 µs / 3.2 KiB | 1.11 µs / 128 B |
| 1 KiB (net) | ~221 µs / ~20.8 KiB | ~101 µs / ~18.2 KiB | ~9.8 µs / ~0.1 KiB |
| 8 KiB (net) | ~1593 µs / ~142 KiB | ~891 µs / ~145 KiB | ~76 µs / ~0.1 KiB |
| throughput (8 KiB net) | ~5.1 MB/s | ~9.2 MB/s | ~107 MB/s |

## 読み方

1. **blake3 は sha1 の 1.8〜2.2 倍高速** (同一条件の pure-vibe 実装同士)。
   BLAKE3 は SHA-1 より round 構造が浅く (7 rounds/block vs 80 rounds/block)、
   32-bit エミュレーション下でも素直に差が出る。digest は 256-bit で
   衝突耐性も sha1 (既知衝突あり) より強い。
2. **アロケーションはほぼ同等** (~18 B/入力 byte)。どちらも per-block の
   word 配列を都度確保している。blake3 側は compress ごとの
   state/m1/m2 (48 words) + block words が主で、scratch buffer を
   chunk 処理で使い回せば大きく削れる余地がある。
3. **現行の実行時キャッシュキー (`compact_string_fingerprint`) は
   blake3 の約 10 倍高速・実質ゼロアロケーション**。実行時キャッシュの
   ホットパスを blake3 に置き換えるのは純粋な性能後退で、動機は
   「衝突耐性が要るか」だけ。~62-bit 弱ハッシュで足りている限り
   置き換える理由は薄い。
4. **置き換えの本命は contract/pin ハッシュ (`ct:sha1:`/`pkg:sha1:`)**。
   ここは衝突耐性が意味を持ち、頻度も低い (publish/pin 照合時のみ) ので
   blake3 の速度優位はボーナス。ただし hash 形式が `#pkg:sha1:<40hex>` で
   ADR-0004/0065 と `vibe hash` に固定されているため、`pkg:b3:<64hex>` の
   ような format 移行 (= 全 pin の振り直し) を伴う。
5. **SIMD 化の道**: inline wasm (`= wasm`, ADR-0072, linear backend のみ) は
   v128/SIMD 命令をサポート済み。BLAKE3 は設計自体が SIMD 前提
   (4-lane G function 並列) なので、compression 1 回分を inline wasm で
   書くのが次の一手。現状の inline wasm は `call` 不可・locals は
   params のみという制約があるため、80+ 命令の compress を 1 関数に
   展開する形になる。

## 再現手順

```bash
bash scripts/build_cli_wasm.sh            # dist/cli/vibe-cli.wasm
bash scripts/install.sh --cli-wasm dist/cli/vibe-cli.wasm
vibe test  lib/@vibex/blake3/blake3_test.vibe
vibe bench lib/@vibex/blake3/blake3_bench.vibe
vibe bench lib/@vibe/core/sha1_bench.vibe
vibe bench lib/@vibe/cache/cache_bench.vibe
```
