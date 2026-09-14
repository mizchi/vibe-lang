# blake3 vs sha1 vs compact_string_fingerprint — bench (2026-08-01)

キャッシュ/fingerprint 用ハッシュを sha1 から blake3 (または SIMD 化しやすい
アルゴリズム) へ置き換える検討の一次計測。`lib/@vibe/blake3` に pure-vibe の
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

## 追記 (同日): scratch 再利用リファクタ後の再計測

compress の作業配列 (state/message words) を呼び出し 1 回分の `Scratch` に
まとめ全 block/chunk で使い回す + String→Bytes 変換を pre-size する改修
(`blake3.vibe`) 後の net 値:

| case | blake3 (初版) | blake3 (scratch 再利用) |
|---|---:|---:|
| 1 KiB net | ~101 µs / ~18.2 KiB | ~92 µs / **~4.3 KiB** |
| 8 KiB net | ~891 µs / ~145 KiB | ~751 µs / **~22.5 KiB** |

アロケーションは約 1/6 (残りはほぼ入力 Bytes 変換 + chunk/parent ごとの
CV・deferred block)、時間も ~16% 改善。sha1 比は **2.1 倍**に拡大。

## 追記 (同日): SIMD の天井値 (wasmtime, ネイティブ品質 codegen)

「SIMD で速いアルゴリズム」の上限を見るため、Rust の blake3 crate
(公式 SIMD 実装) と sha1 crate を wasm32-wasip1 へコンパイルし、同じ
wasmtime で実測した (input = i % 251 pattern):

| case | sha1 (scalar) | blake3 (scalar) | blake3 (+simd128, wasm32_simd) |
|---|---:|---:|---:|
| 1 KiB | 2.68 µs (382 MB/s) | 1.90 µs (539 MB/s) | 1.38 µs (740 MB/s) |
| 8 KiB | 20.5 µs (400 MB/s) | 16.2 µs (506 MB/s) | **6.86 µs (1195 MB/s)** |
| 64 KiB | 161 µs (408 MB/s) | 129 µs (509 MB/s) | **56.7 µs (1157 MB/s)** |

- BLAKE3 は simd128 で **scalar 比 2.3〜2.4 倍**、SHA-1 は SIMD の恩恵なし
  (構造的に vectorize しない)。
- pure-vibe blake3 (~11 MB/s) とネイティブ品質 scalar (506 MB/s) の差 ~46 倍は
  codegen 品質 (bounds check / boxing / 関数呼び出しコスト)。SIMD 化の前に
  codegen 側の伸び代が支配的。

### 追記 (同日夜): inline wasm 拡張により SIMD compress を実装 — scalar 比 4〜6.6 倍

下の「現状不可能」節の 3 つの壁はコンパイラ拡張で解消した (同ブランチ):

1. **v128/i32/i64 の `(local ...)` 宣言** を inline wasm でサポート
   (`compile_inline_wat_full` + code-entry locals header の v128 run、
   meta_v128 配列を bodies/meta_i32/meta_i64 と並走)。
2. **Bytes param** を許可 — 生の untagged object pointer が渡り、
   `i32.load offset=8` で data pointer、`offset=4` で length が取れる
   (buffer address intrinsic は builtin 追加ではなくこの形で実現)。
3. **`i8x16.shuffle`** (16 lane-byte immediates) を WAT assembler に追加。

これで BLAKE3 の 1-block full compression を flat WAT の kernel として
`lib/@vibe/blake3/simd.vibe` に実装 (命令列は Python 生成器 +
命令レベルシミュレータで公式ベクタ全一致を検証してから出力。rows 方式、
message schedule は各 round の 4 vector を m0..m3 から 2 入力 shuffle 木で
直接 gather、diagonalize は r1/r2/r3 lane 回転)。`simd_test.vibe` が
公式ベクタと scalar/simd 一致を実機で pin。

vibe bench (net of baseline、同一 wasmtime):

| case | scalar blake3 | **simd blake3** | sha1 | 現行 cache key |
|---|---:|---:|---:|---:|
| 1 KiB | ~94 µs | **~14 µs (~72 MB/s)** | ~221 µs | ~9.8 µs |
| 8 KiB | ~799 µs | **~202 µs (~41 MB/s)** | ~1593 µs | ~76 µs |

- SIMD kernel は scalar vibe 比 **4〜6.6 倍**、sha1 比 **8〜16 倍**。
- 現行 `compact_string_fingerprint` にほぼ並ぶ速度になり (1KiB で 14 vs
  9.8 µs)、衝突耐性つきハッシュとしては実用域。
- ネイティブ SIMD 天井 (~1.2 GB/s) との残差は per-call オーバーヘッド
  (RC dup/drop + call) と driver 側の Bytes 構築。kernel を chunk 単位に
  太らせればさらに縮む。

### (歴史) inline wasm (`= wasm`, ADR-0072) での SIMD compress は当初不可能だった

現行の inline wasm 制約 (v0.3 slice) を `fixtures/inline_wasm_test.vibe` と
突き合わせた結論:

1. **v128 locals が無い** — locals は fn の i64 params のみ。BLAKE3 の
   compress は 4 本の v128 row を 7 round 横断で保持する必要があり、
   locals なしの folded expression では row の再利用 (fan-out) が書けない。
2. **ポインタが取れない** — `Bytes`/`Int64Array` の線形メモリ上の
   アドレスを得る手段がなく、`v128.load` で message words を読めない。
   params 経由だと 16 words + cv 8 + counter/blen/flags で 27 個の
   i64 param に手展開することになり、SIMD lane への詰め直しで利益が消える。
3. `call` 不可のため G function を関数分割することもできない。

→ vibe 内 SIMD 化には compiler 拡張 (v128 locals / buffer address intrinsic /
`call` 許可のいずれか) が必要。それまでの現実的な高速化は
(a) codegen 品質改善 (bounds-check 除去等) か、(b) viberun への host builtin
(native blake3) 追加 — ただし (b) は pure/component target に host import を
強いるため契約ハッシュ用途 (compiler 内で完結) に限定するのが筋。

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
bash install/install.sh --cli-wasm dist/cli/vibe-cli.wasm
vibe test  lib/@vibe/blake3/blake3_test.vibe
vibe bench lib/@vibe/blake3/blake3_bench.vibe
vibe bench lib/@vibe/core/sha1_bench.vibe
vibe bench lib/@vibe/cache/cache_bench.vibe
```
