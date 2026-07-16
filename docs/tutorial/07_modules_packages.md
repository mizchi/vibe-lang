# 07 — モジュールとパッケージ

実行: `vibe test docs/tutorial/07_modules_packages_test.vibe`
(リポジトリ root か、@vibe/core が materialize 済みの環境で)

## export と相対 import

1 ファイル = 1 モジュール。公開したいものに `export`、使う側は選択 import。

```vibe
// support/mathx.vibe
export fn triple(x: Int) -> Int { x * 3 }

// 使う側
import ./support/mathx.vibe { triple }
import ./lib.vibe { f as renamed }        // rename
import ./subdir { helper }                // ディレクトリ import -> index.vibe(i)
```

import パスはエントリファイルの root ディレクトリの外に出られない
(サンドボックス規則)。

## @scope/name パッケージ

`@scope/name` は ADR-0065 の解決順で探索される:
`.vibe/store/` (pin 検証済み) → workspace `lib/` → `VIBE_LIB`
(既定 `~/.vibe/lib` — curl インストーラが stdlib をここに置く)。

```vibe
import @vibe/core { sha1, hex_encode }

test "package import" {
  assert_eq(String::length(sha1("vibe")), 40)
  assert(hex_encode("hi") == "6869")
}
```

## 契約 (`index.vpkg`) と version

パッケージの境界は `index.vpkg` — 公開 API を bodyless 宣言で列挙した
**契約**で、実装との一致はコンパイラが照合する。先頭に `version x.y.z`
directive を置く。

```vibe
version 1.0.0

type Counter                       // bodyless: 定義は impl 側
fn add(x: Int, y: Int) -> Int      // 実装が一致しないとコンパイルエラー
```

同じ directory の通常 `*.vibe` は暗黙 build root。subdirectory は再帰走査
されないため、必要な source を root から relative import/export する。
`*_test.vibe` / `*_bench.vibe` は通常 build/hash から除外されるが、明示実行時は
最寄りの `index.vpkg` の package-private module と shared import を利用できる。
`_*.vibe` / `*.draft.vibe` も暗黙 root にはならないが、明示 import された場合は
同じ shared import を継承し、package hash に含まれる。

## pin — content hash が唯一の真実

再現可能ビルドでは require 行で **内容 hash** を固定する。ビルドは毎回
オフラインで hash を再検証するので、置き場所や取得経路は信頼しなくてよい。

```vibe
require @vibe/core 0.1.0 = #pkg:sha1:<40hex>   // `vibe hash` で計算

import @vibe/core { sha1 }
```

`VIBE_REQUIRE_PINS=1` (release/publish の freeze) では pin なしの
dev-mode 解決はエラーになる。

## 配布コマンド (scripts/vibe_pkg.sh)

```bash
vibe_pkg.sh publish lib/@you/pkg                 # semver gate + cache へ格納
vibe_pkg.sh install @you/pkg@1.0.0               # ~/.vibe/lib へ materialize
vibe_pkg.sh add github:owner/repo/dir@ref [#pin] # git から hash 検証付き取得
```

詳細: [docs/adding-modules.md](../adding-modules.md) /
[docs/registry-design.md](../registry-design.md)

— 以上でツアーは終わり。[README](README.md) から任意の章を再実行できる。
