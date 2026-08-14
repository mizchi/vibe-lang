# 07 — モジュールとパッケージ

前章: [06 テスト](06_tests.vibe.md)
(リポジトリ root か、@vibe/core が materialize 済みの環境で)

## export と相対 import

ここが beginner に必要な部分である。まず 1 ファイル = 1 モジュール、公開したいものに
`export`、使う側は選択 import、という local two-file module を学ぶ。後半の package
contract / pin / publish は advanced な配布手順なので、必要になるまで読み飛ばしてよい。

```vibe skip
// skip: シンタックス一覧 (./lib.vibe と ./subdir はこのリポジトリに実在しない
// 例示パス) — 動く例は次の run ブロック (support/mathx.vibe から triple を import)
// support/mathx.vibe
export fn triple(x: Int) -> Int {
  x * 3
}

// 使う側
import ./support/mathx.vibe {
  triple
}
import ./lib.vibe {
  f as renamed
}
// rename
import ./subdir {
  helper
}
// ディレクトリ import -> index.vibe(i)
```

import パスはエントリファイルの root ディレクトリの外に出られない
(サンドボックス規則)。

実際に [support/mathx.vibe](support/mathx.vibe) から `triple` を import して
動かす:

```vibe run
import @vibe/prelude {
  stdout_write
}
import ./support/mathx.vibe {
  triple
}

fn main with Stdout {
  stdout_write("triple(14) = \{triple(14)}\n")
}
```

```output
triple(14) = 42
```

## @scope/name パッケージ

`@scope/name` は ADR-0065 の解決順で探索される:
`.vibe/store/` (pin 検証済み) → workspace `lib/` → `VIBE_LIB`
(既定 `~/.vibe/lib` — curl インストーラが stdlib をここに置く)。

```vibe run
import @vibe/prelude {
  stdout_write
}
import @vibe/core {
  hex_encode, sha1
}

fn main with Stdout {
  stdout_write("length(sha1(\"vibe\")) = \{String::length(sha1("vibe"))}\n")
  stdout_write("hex_encode(\"hi\") = \{hex_encode("hi")}\n")
}
```

```output
length(sha1("vibe")) = 40
hex_encode("hi") = 6869
```

## Advanced: 契約 (`index.vpkg`) と version

> 境界・可視性・pin の規則の正本は
> [docs/module-system-oracle.md の「現行モデル」節](../module-system-oracle.md#現行モデル-canonical--ここが唯一の現行記述) (#1269)。
> 以下はチュートリアル向けの要約。

パッケージの境界は `index.vpkg` — 公開 API を bodyless 宣言で列挙した
**契約**で、実装との一致はコンパイラが照合する。#1128 以降は構造化ヘッダー
(`name =` / `version =` / `description =` / `deps = { ... }`) が標準形:

```text
// index.vpkg ヘッダー例 (docs/adding-modules.md 参照)。ヘッダ部は vibe 構文
// ではないので ```text — 実物の綴りは lib/@vibe/*/index.vpkg を見る
name = @you/counter
version = 1.0.0
description =
  #|A tiny counter contract
deps = {}

generated_hash =

type Counter
// bodyless: 定義は impl 側
fn add(x: Int, y: Int) -> Int
// 実装が一致しないとコンパイルエラー
```

同じ directory の通常 `*.vibe` は暗黙 build root。subdirectory は再帰走査
されないため、必要な source を root から relative import/export する。
`*_test.vibe` / `*_bench.vibe` は通常 build/hash から除外されるが、明示実行時は
最寄りの `index.vpkg` の package-private module と shared import を利用できる。
`_*.vibe` / `*.draft.vibe` も暗黙 root にはならないが、明示 import された場合は
同じ shared import を継承し、package hash に含まれる。

## Advanced: pin — content hash が唯一の真実

再現可能ビルドでは require 行で **内容 hash** を固定する。ビルドは毎回
オフラインで hash を再検証するので、置き場所や取得経路は信頼しなくてよい。

```text
// require directive は import/export と独立に module header に置く。
// directive は vibe 構文ではないので ```text (loader の受理形は
// contract.vibe の "malformed require line" 診断が正)
require @vibe/core 0.2.0 = #pkg:sha1:<40hex>
// <40hex> は `vibe hash` で計算

import @vibe/core {
  sha1
}
```

`VIBE_REQUIRE_PINS=1` (release/publish の freeze) では pin なしの
dev-mode 解決はエラーになる。

## Advanced: 配布コマンド (`vibe pkg` / scripts/vibe_pkg.sh)

インストール済みの toolchain では `vibe pkg <cmd>`、repo 内では
`scripts/vibe_pkg.sh <cmd>` (同一実装)。publish/yank は transparency log
(`$VIBE_HOME/log`, #805) に追記され、install はその inclusion proof を検証する。

```bash
vibe pkg publish lib/@you/pkg                 # semver gate + cache + log 追記
vibe pkg install @you/pkg@1.0.0               # ~/.vibe/lib へ materialize (log 検証)
vibe pkg add github:owner/repo/dir@ref [#pin] # git から hash 検証付き取得
vibe pkg yank @you/pkg@1.0.0                  # 撤回マーキング (append-only)
vibe pkg update @you/pkg                      # 最新 non-yanked へ (契約 diff 表示)
```

詳細: [docs/adding-modules.md](../adding-modules.md) /
[docs/registry-design.md](../registry-design.md)

— 以上でツアーは終わり。[README](README.md) から任意の章を再実行できる。
